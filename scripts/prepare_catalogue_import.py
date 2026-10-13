#!/usr/bin/env python3
"""Convertit la collecte publique en SQL contrôlé, sans connexion ni secret."""
import argparse
import json
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urlsplit, parse_qsl

PRODUCT_KEYS = {"brand", "reference", "ean", "name", "categories", "review_status", "offers"}
OFFER_KEYS = {"supplier", "reference", "url", "pack", "collected_at", "page_sha256", "image_url"}
HOSTS = {"Rexel": "www.rexel.fr", "Sonepar": "www.sonepar.fr"}


def required_text(value, limit, label):
    if not isinstance(value, str) or not value.strip() or len(value) > limit or "\x00" in value:
        raise ValueError(f"{label} : texte obligatoire, maximum {limit} caractères")


def valid_gtin(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:[0-9]{8}|[0-9]{12,14})", value):
        return False
    return sum(int(n) * (1 if i % 2 == 0 else 3) for i, n in enumerate(reversed(value))) % 10 == 0


# Kept standalone so the importer can be downloaded without the collector.
def image_url_valid(value, supplier):
    """Only public image routes observed on supplier product pages, no tokens."""
    if not isinstance(value, str) or len(value) > 2000 or re.search(r"[\s\x00-\x1f]", value):
        return False
    try:
        u = urlsplit(value)
        if u.scheme != "https" or u.username or u.password or u.port or u.fragment:
            return False
        if supplier == "Rexel":
            return u.netloc == "api.rexel.fr" and not u.query and bool(re.fullmatch(
                r"/media/api/fr/content/[0-9]+/[A-Z_]+", u.path))
        if supplier == "Sonepar":
            pairs = parse_qsl(u.query, keep_blank_values=True, strict_parsing=True)
            return (u.netloc == "fra-connect.mo.cloudinary.net" and bool(re.fullmatch(
                r"/PRODUCT/IMAGE/[0-9]+/[A-Za-z0-9_.-]+\.(?:jpg|jpeg|png|webp)", u.path, re.I))
                and len({k for k, _ in pairs}) == len(pairs)
                and all((k == "ts" and bool(re.fullmatch(r"[0-9]{1,20}", v))) or
                        (k == "type" and v in {"xsmall", "small", "medium", "large"}) for k, v in pairs))
        return False
    except ValueError:
        return False

def validate(products, approve=False):
    if not isinstance(products, list) or not 1 <= len(products) <= 1000:
        raise ValueError("Attendu : une liste de 1 à 1000 produits")
    identities, gtins, supplier_refs = set(), set(), set()
    for p in products:
        if not isinstance(p, dict) or set(p) - PRODUCT_KEYS:
            raise ValueError("Champs produit inconnus : aucun prix, secret ou HTML accepté")
        for key, limit in (("brand", 200), ("reference", 100), ("name", 1000)):
            required_text(p.get(key), limit, key)
        if not valid_gtin(p.get("ean")):
            raise ValueError("EAN/GTIN invalide : garder une chaîne et ses zéros initiaux")
        if p.get("review_status") not in ("pending", "approved"):
            raise ValueError("review_status doit être pending ou approved")
        if approve and p["review_status"] != "approved":
            raise ValueError("Publication refusée : contrôler chaque fiche puis écrire review_status: approved")
        categories = p.get("categories")
        if not isinstance(categories, list) or len(categories) > 20:
            raise ValueError("categories doit être une liste de 0 à 20 libellés de découverte")
        for c in categories:
            required_text(c, 200, "category")
        identity = (p["brand"].strip().lower(), p["reference"].strip().lower())
        gtin = p["ean"].zfill(14)
        if identity in identities or gtin in gtins:
            raise ValueError("Produit dupliqué ou EAN partagé : résoudre le conflit avant import")
        identities.add(identity)
        gtins.add(gtin)
        offers = p.get("offers")
        if not isinstance(offers, list) or not 1 <= len(offers) <= 2:
            raise ValueError("Chaque produit nécessite 1 ou 2 offres")
        suppliers = set()
        for o in offers:
            if not isinstance(o, dict) or set(o) - OFFER_KEYS:
                raise ValueError("Champs offre inconnus")
            supplier = o.get("supplier")
            if supplier not in HOSTS or supplier in suppliers:
                raise ValueError("Fournisseur inconnu ou dupliqué")
            suppliers.add(supplier)
            required_text(o.get("reference"), 100, "reference fournisseur")
            key = (supplier, o["reference"].strip().lower())
            if key in supplier_refs:
                raise ValueError("Référence fournisseur utilisée pour plusieurs produits")
            supplier_refs.add(key)
            required_text(o.get("url"), 2000, "url")
            u = urlsplit(o["url"])
            path_pattern = r"/frx/(?:[^?#\s]+/)?p/[0-9]+" if supplier == "Rexel" else r"/catalog/fr-fr/products/[^/?#\s]+"
            if (u.scheme != "https" or u.netloc != HOSTS[supplier] or u.query or u.fragment
                    or not re.fullmatch(path_pattern, u.path)):
                raise ValueError("URL produit officielle attendue, sans compte, paramètre ni fragment")
            if o.get("image_url") is not None and not image_url_valid(o["image_url"], supplier):
                raise ValueError("Photo : URL média officielle Rexel/Sonepar requise, sans jeton")
            if o.get("image_url") and supplier == "Rexel" and urlsplit(o["image_url"]).path.split("/")[-2] != u.path.split("/")[-1]:
                raise ValueError("Photo Rexel associée à une autre fiche produit")
            if o.get("pack") is not None:
                required_text(o["pack"], 1000, "pack")
            if not isinstance(o.get("page_sha256"), str) or not re.fullmatch(r"[a-f0-9]{64}", o["page_sha256"]):
                raise ValueError("Empreinte de source SHA-256 obligatoire")
            required_text(o.get("collected_at"), 40, "collected_at")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})", o["collected_at"]):
                raise ValueError("Date de collecte ISO 8601 avec fuseau obligatoire")
            observed = datetime.fromisoformat(o["collected_at"].replace("Z", "+00:00"))
            if observed > datetime.now(timezone.utc) + timedelta(minutes=5):
                raise ValueError("Date de collecte dans le futur")
        if len(json.dumps(p, ensure_ascii=False).encode("utf-8")) > 64000:
            raise ValueError("Fiche trop volumineuse")
    return products


def generate_sql(products, approve=False):
    validate(products, approve)
    lines = ["-- 2HBC : aucun prix importé. Exécuter dans le SQL Editor du projet 2HBC.",
             "-- Mode : " + ("publication des fiches relues" if approve else "préparation privée uniquement"),
             "begin;", "set local standard_conforming_strings = on;"]
    for p in products:
        # JSON as a SQL string literal, not executable identifiers or interpolated SQL.
        payload = json.dumps(p, ensure_ascii=False, separators=(",", ":")).replace("'", "''")
        lines.append(f"select public.importer_produit_collecte('{payload}'::jsonb, {'true' if approve else 'false'});")
    lines.append("commit;")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="products.json du collecteur")
    parser.add_argument("--out", type=Path, default=Path("catalogue-preparation.sql"))
    parser.add_argument("--approve", action="store_true", help="Publier uniquement un fichier entièrement relu et marqué approved")
    args = parser.parse_args()
    try:
        if args.input.resolve() == args.out.resolve():
            raise ValueError("La sortie ne doit pas écraser le fichier source")
        if args.input.stat().st_size > 20 * 1024 * 1024:
            raise ValueError("Fichier trop volumineux (20 Mio maximum)")
        products = json.loads(args.input.read_text(encoding="utf-8"))
        sql = generate_sql(products, args.approve)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(sql, encoding="utf-8")
        print(f"{len(products)} produits contrôlés ; SQL écrit dans {args.out}. Aucune connexion à Supabase effectuée.")
        return 0
    except (ValueError, OSError, TypeError) as exc:
        print(f"Import refusé : {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
