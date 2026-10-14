#!/usr/bin/env python3
"""Collecte 2HBC : photos et codes Rexel/Sonepar publics, sans compte ni prix."""
import argparse
import hashlib
import json
import re
import sys
import time
import unicodedata
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, quote, unquote, urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

COLLECTOR_VERSION = "0.3.0"
AGENT = f"2HBCCatalogue/{COLLECTOR_VERSION} (+https://github.com/mburgevin/2HBC)"
HOSTS = {"www.rexel.fr": "Rexel", "www.sonepar.fr": "Sonepar"}
MAX_BYTES = 8 * 1024 * 1024
MAX_QUEUE = 5000
# Public category URLs verified on 2026-10-11. No inferred private endpoints.
DEFAULT_SEEDS = [
    {
        "category": "Appareillage mural",
        "url": "https://www.rexel.fr/frx/Cat%C3%A9gorie/Appareillage-et-contr%C3%B4le-du-b%C3%A2timent/Appareillage-mural/c/M2_0107"
    },
    {
        "category": "Interrupteurs, prises et boîtes",
        "url": "https://www.sonepar.fr/catalog/fr-fr/category/interrupteur-prise-boite-d-encastrement-SCC03"
    },
    {
        "category": "Protection électrique",
        "url": "https://www.rexel.fr/frx/Cat%C3%A9gorie/Distribution-et-gestion-de-l'%C3%A9nergie/Distribution-et-protection-AC/c/M2_0302"
    },
    {
        "category": "Distribution d’énergie",
        "url": "https://www.sonepar.fr/catalog/fr-fr/category/distribution-d-energie-SCC04"
    },
    {
        "category": "Connectique et raccordement",
        "url": "https://www.rexel.fr/frx/Cat%C3%A9gorie/Produits-Industriels/Connectique-et-raccordement/c/M2_0203"
    },
    {
        "category": "Fils et câbles",
        "url": "https://www.sonepar.fr/catalog/fr-fr/category/fil-et-cable-SCC01"
    },
    {
        "category": "Éclairage",
        "url": "https://www.sonepar.fr/catalog/fr-fr/category/eclairage-SCC06"
    },
    {
        "category": "Outillage et accessoires",
        "url": "https://www.sonepar.fr/catalog/fr-fr/category/outillage-et-accessoires-d-installation-SCC09"
    }
]


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def tidy(value):
    return re.sub(r"\s+", " ", str(value)).strip()


def norm(value):
    return tidy(unicodedata.normalize("NFKC", value)).casefold()


def public_url(value, base=""):
    """Only public product/category pages, with observed pagination links."""
    try:
        u = urlsplit(urljoin(base, value))
        if u.scheme != "https" or u.hostname not in HOSTS or u.username or u.password or u.port:
            return None
        path = quote(unquote(u.path), safe="/-._~'")
        if not (re.fullmatch(r"/frx/(?:[^?#]*/)?(?:p/\d+|c/[A-Za-z0-9_-]+)", path)
                if u.hostname == "www.rexel.fr" else
                re.fullmatch(r"/catalog/fr-fr/(?:products|category)/[A-Za-z0-9_-]+", path)):
            return None
        params = parse_qsl(u.query, keep_blank_values=True)
        if params and (len(params) != 1 or params[0][0] != "page" or
                       not re.fullmatch(r"\d{1,3}", params[0][1])):
            return None
        if is_product_path(path) and params:
            return None
        return urlunsplit(("https", u.hostname, path, u.query, ""))
    except (ValueError, TypeError):
        return None


def is_product_path(path):
    return bool(re.search(r"/p/\d+$|/products/[^/]+$", path))


def page_key(url):
    u = urlsplit(url)
    if is_product_path(u.path):
        # Canonical slug changes must not trigger repeated product downloads.
        sku = re.search(r"/p/(\d+)$", u.path) if u.hostname == "www.rexel.fr" else re.search(r"(\d+)$", u.path)
        if sku:
            return u.hostname + ":product:" + sku[1]
    return url


class Page(HTMLParser):
    """Read visible text, links and image attributes; never execute scripts."""
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.parts, self.links, self.headings, self.title = [], [], [], []
        self.images = []
        self.skip = 0
        self.in_h1 = self.in_title = False
        self.feed(html)
        self.text = tidy(" ".join(self.parts))
        self.name = tidy(" ".join(self.headings))
        self.title = tidy(" ".join(self.title))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in {"script", "style", "noscript", "template"}:
            self.skip += 1
        if self.skip:
            return
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag == "img":
            self.images.append({k: attrs.get(k, "") for k in ("src", "data-src", "alt")})
        if tag == "h1":
            self.in_h1 = True
        if tag == "title":
            self.in_title = True

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript", "template"}:
            self.skip = max(0, self.skip - 1)
        if tag == "h1":
            self.in_h1 = False
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.skip:
            return
        self.parts.append(data)
        if self.in_h1:
            self.headings.append(data)
        if self.in_title:
            self.title.append(data)


def unique_match(pattern, text, field):
    values = {tidy(v) for v in re.findall(pattern, text, re.I)}
    if len(values) != 1:
        raise ValueError(f"{field} absent ou ambigu")
    return values.pop()


def ean_valid(value):
    return bool(re.fullmatch(r"\d{13}", value)) and sum(int(n) * (3 if i % 2 else 1) for i, n in enumerate(value)) % 10 == 0


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


def extract_image(page, url, supplier):
    images = [(a, urljoin(url, a["data-src"] or a["src"])) for a in page.images]
    images = [(a, src) for a, src in images if image_url_valid(src, supplier)]
    if supplier == "Rexel":
        product_id = re.search(r"/p/([0-9]+)$", urlsplit(url).path)[1]
        return next((src for a, src in images if a["alt"].strip().lower() == "main media"
                     and urlsplit(src).path.split("/")[-2] == product_id), None)
    # Use the explicitly labelled first product photo, never brand logos, scenery,
    # recommendation cards or the first arbitrary <img>. Prefer its full-size copy.
    thumb = next((src for a, src in images if re.fullmatch(r"Vignette Photo produit 1", a["alt"], re.I)), None)
    if thumb:
        return next((src for _, src in images if urlsplit(src).path == urlsplit(thumb).path
                     and "type" not in dict(parse_qsl(urlsplit(src).query))), thumb)
    return None


def extract_product(page, url, category, collected_at):
    supplier = HOSTS[urlsplit(url).hostname]
    if not is_product_path(urlsplit(url).path):
        raise ValueError("Pas une fiche produit")
    if not page.name or len(page.name) > 400:
        raise ValueError("Titre produit absent ou ambigu (HTML non rendu ?)")
    text = page.text
    ref_chars = r"([A-Za-z0-9][A-Za-z0-9._/-]{0,79})(?=\s|$)"
    if supplier == "Sonepar":
        # Read the dedicated references section, not neighbouring product cards.
        section = re.search(r"R[ée]f[ée]rences\s+(EAN\b.*?)\s+Caract[ée]ristiques techniques\b", text, re.I)
        if not section:
            raise ValueError("Section Références Sonepar absente (HTML non rendu ?)")
        text = section[1]
        ean = unique_match(r"\bEAN\s*:?\s*(\d{13})(?!\d)", text, "EAN")
        sku = unique_match(r"R[ée]f\.?\s*Sonepar\s*:?\s*(\d{8,15})(?!\d)", text, "Référence Sonepar")
        reference = unique_match(r"R[ée]f\.?\s*Fournisseur\s*:?\s*" + ref_chars, text, "Référence fabricant")
        brand = unique_match(r"\bMarque\s*:?\s*(.{1,80})$", text, "Marque")
        if not re.search(r"(?:/|-)" + re.escape(sku) + r"$", urlsplit(url).path):
            raise ValueError("Référence Sonepar différente de l’URL")
        pack = re.search(r"Conditionnement\s+(.{1,60}?)\s+(?:Article|R[ée]f[ée]rences)", page.text, re.I)
        pack_text = tidy(pack[1]) if pack else "À confirmer dans le compte fournisseur"
    else:
        # All repeated copies of a field must agree; do not choose the first EAN.
        ean = unique_match(r"\bEAN13\s*:?\s*(\d{13})(?!\d)", text, "EAN13")
        sku = unique_match(r"R[ée]f\.?\s*Rexel\s*:?\s*" + ref_chars, text, "Référence Rexel")
        reference = unique_match(r"R[ée]f\.?\s*Fab\s*:?\s*" + ref_chars, text, "Référence fabricant")
        brand = unique_match(r"D[ée]couvrez toute l.offre\s+(.{1,80}?)\s*(?:>|D[ée]tails du produit)", text, "Marque")
        segment = unquote(urlsplit(url).path).split("/")[-3]
        if segment != "frx" and norm(segment) != norm(sku):
            raise ValueError("Référence Rexel différente de l’URL")
        pack_text = "Unité, conditionnement et multiple de vente à confirmer dans le compte"
    if not ean_valid(ean):
        raise ValueError("EAN13 invalide")
    name = page.name
    if supplier == "Sonepar":
        name = re.sub(r"^" + re.escape(brand) + r"\s*-\s*", "", name, flags=re.I)
        name = re.sub(r"\s*-\s*" + re.escape(reference) + r"$", "", name)
    product = {"brand": brand, "reference": reference, "ean": ean, "name": name,
            "categories": [category], "review_status": "pending",
            "offers": [{"supplier": supplier, "reference": sku, "url": url, "pack": pack_text,
                        "collected_at": collected_at, "page_sha256": hashlib.sha256(page.text.encode()).hexdigest()}]}
    photo = extract_image(page, url, supplier)
    if photo:
        product["offers"][0]["image_url"] = photo
    return product


class Robots:
    """Relevant robots rules, including wildcard, longest match and Allow ties."""
    def __init__(self, text):
        groups, agents, rules, delay, directives = [], [], [], 0.0, False
        for raw in text.splitlines() + ["User-agent: __end__"]:
            line = raw.split("#", 1)[0].strip()
            if ":" not in line:
                continue
            key, value = [v.strip() for v in line.split(":", 1)]
            key = key.lower()
            if key == "user-agent":
                if directives:
                    groups.append((agents, rules, delay))
                    agents, rules, delay, directives = [], [], 0.0, False
                agents.append(value.lower())
            elif agents:
                directives = True
                if key in {"allow", "disallow"} and value:
                    rules.append((value, key == "allow"))
                elif key == "crawl-delay":
                    try:
                        delay = max(delay, float(value))
                    except ValueError:
                        pass
        token = AGENT.split("/", 1)[0].lower()
        exact = [g for g in groups if any(a != "*" and a in token for a in g[0])]
        selected = exact or [g for g in groups if "*" in g[0]]
        self.rules = [r for _, rs, _ in selected for r in rs]
        self.delay = max([g[2] for g in selected] or [0])

    def allows(self, url):
        u = urlsplit(url)
        target = u.path + ("?" + u.query if u.query else "")
        matches = []
        for pattern, allow in self.rules:
            anchored = pattern.endswith("$")
            body = pattern[:-1] if anchored else pattern
            regex = "^" + re.escape(body).replace(r"\*", ".*") + ("$" if anchored else "")
            if re.search(regex, target):
                matches.append((len(body.replace("*", "")), allow))
        return max(matches, default=(0, True))[1]


class StopHost(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Fetcher:
    def __init__(self, delay=3, opener=None):
        self.delay, self.last, self.robots = delay, {}, {}
        # No CookieJar, credentials, browser session, proxy rotation or hidden API.
        self.opener = opener or build_opener(NoRedirect())

    def request(self, url, delay):
        host = urlsplit(url).hostname
        time.sleep(max(0, delay - (time.monotonic() - self.last.get(host, 0))))
        self.last[host] = time.monotonic()
        request = Request(url, headers={"User-Agent": AGENT, "Accept": "text/html,text/plain;q=0.9", "Accept-Encoding": "identity"})
        try:
            with self.opener.open(request, timeout=25) as response:
                data = response.read(MAX_BYTES + 1)
                if len(data) > MAX_BYTES:
                    raise ValueError("Page trop volumineuse")
                mime = response.headers.get_content_type()
                if mime not in {"text/html", "text/plain", "application/xhtml+xml"}:
                    raise ValueError("Type de document non pris en charge")
                charset = response.headers.get_content_charset() or "utf-8"
                return data.decode(charset, errors="replace")
        except HTTPError as error:
            if error.code in {401, 403, 429, 503}:
                error.close()
                raise StopHost(f"HTTP {error.code} : fournisseur suspendu pour cette exécution") from error
            raise

    def get(self, url):
        url = public_url(url)
        if not url:
            raise ValueError("URL hors des pages publiques autorisées")
        host = urlsplit(url).hostname
        if host not in self.robots:
            try:
                body = self.request(f"https://{host}/robots.txt", self.delay)
                if "<html" in body.lower():
                    raise StopHost("robots.txt remplacé par une page HTML")
            except HTTPError as error:
                error.close()
                if error.code != 404:
                    raise StopHost("robots.txt inaccessible") from error
                body = ""
            self.robots[host] = Robots(body)
        policy = self.robots[host]
        for _ in range(6):
            if not policy.allows(url):
                raise ValueError("URL exclue par robots.txt")
            try:
                html = self.request(url, max(self.delay, policy.delay))
                page = Page(html)
                if re.search(r"captcha|access denied|just a moment|v[ée]rifiez que vous [êe]tes humain|enable javascript and cookies", page.title, re.I):
                    raise StopHost("Page de contrôle d’accès : arrêt, sans contournement")
                return url, html
            except HTTPError as error:
                location = error.headers.get("Location", "")
                code = error.code
                error.close()
                if code not in {301, 302, 303, 307, 308}:
                    raise ValueError(f"HTTP {code}") from error
                target = public_url(location, url)
                if not target or urlsplit(target).hostname != host:
                    raise ValueError("Redirection hors du catalogue public")
                url = target
        raise ValueError("Trop de redirections")


def merge(products, incoming, allow_new=True):
    identity = lambda p: (norm(p["brand"]), norm(p["reference"]))
    matches = [p for p in products if p["ean"] == incoming["ean"] or identity(p) == identity(incoming)]
    if not matches:
        if allow_new:
            products.append(incoming)
        return allow_new
    if len(matches) != 1 or matches[0]["ean"] != incoming["ean"] or identity(matches[0]) != identity(incoming):
        raise ValueError("Conflit EAN / marque / référence : rapprochement refusé")
    existing = matches[0]
    offer = incoming["offers"][0]
    old = next((o for o in existing["offers"] if o["supplier"] == offer["supplier"]), None)
    if old and old["reference"] != offer["reference"]:
        raise ValueError("Deux références du même fournisseur pour ce produit : contrôle manuel")
    if not old:
        existing["offers"].append(offer)
    elif not old.get("image_url") and offer.get("image_url") and old["url"] == offer["url"]:
        old.update(offer)
    existing["categories"] = sorted(set(existing["categories"] + incoming["categories"]))
    return True


def enqueue(state, url, category):
    url = public_url(url)
    if not url or len(state["pending"]) >= MAX_QUEUE:
        return
    key = page_key(url)
    if key not in state["seen"] and all(page_key(item["url"]) != key for item in state["pending"]):
        state["pending"].append({"url": url, "category": category})


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def catalogue_row(product):
    """Readable projection only; products.json remains the import contract."""
    offers = {o["supplier"]: o for o in product["offers"]}
    row = {"name": product["name"], "brand": product["brand"],
           "manufacturer_reference": product["reference"], "ean": product["ean"],
           "image_url": next((o["image_url"] for o in product["offers"] if o.get("image_url")), None)}
    for supplier in ("Rexel", "Sonepar"):
        offer = offers.get(supplier, {})
        prefix = supplier.lower()
        row[prefix + "_code"] = offer.get("reference")
        row[prefix + "_url"] = offer.get("url")
        row[prefix + "_image_url"] = offer.get("image_url")
    row["missing_fields"] = [key for key in ("rexel_code", "sonepar_code", "image_url") if not row[key]]
    return row


def save(state, output, limit):
    atomic_json(output / "state.json", state)
    atomic_json(output / "products.json", state["products"])
    overview = [catalogue_row(p) for p in state["products"]]
    atomic_json(output / "catalogue.json", overview)
    count = len(state["products"])
    paired = sum(len(p["offers"]) == 2 for p in state["products"])
    pictured = sum(any(o.get("image_url") for o in p["offers"]) for p in state["products"])
    atomic_json(output / "report.json", {"collector_version": COLLECTOR_VERSION,
        "updated_at": now(), "target": limit, "products": count,
        "both_suppliers": paired, "single_supplier": count - paired, "complete": count >= limit,
        "products_with_image": pictured, "products_without_image": count - pictured,
        "both_codes_and_image": sum(not row["missing_fields"] for row in overview),
        "missing_codes": {name: sum(not row[name.lower() + "_code"] for row in overview) for name in ("Rexel", "Sonepar")},
        "images_by_supplier": {name: sum(any(o["supplier"] == name and o.get("image_url") for o in p["offers"]) for p in state["products"]) for name in ("Rexel", "Sonepar")},
        "last_run": state.get("last_run"),
        "pending_pages": len(state["pending"]), "needs_review": True, "prices_collected": False,
        "issues": state["issues"]})


def collect(state, fetcher, limit, max_pages, checkpoint=lambda: None, emit=print, enrich_pages=100):
    blocked, attempted, enriched, last_host = set(), 0, 0, None
    # Product pages unrelated to the selected catalogue are deferred, not lost.
    # They remain available if a later run raises --limit, without being fetched
    # repeatedly while looking for the same missing supplier codes.
    deferred = state.setdefault("deferred", [])
    if len(state["products"]) < limit and deferred:
        state["pending"] = deferred + state["pending"]
        state["deferred"] = deferred = []
    deferred_keys = {page_key(item["url"]) for item in deferred}
    run = state["last_run"] = {"pages_attempted": 0, "enrichment_pages": 0,
                               "deferred_products": 0, "stop_reason": "page_budget"}
    while attempted < max_pages:
        enriching = len(state["products"]) >= limit
        wanted = set(HOSTS)
        if enriching:
            if state["supplier"] != "both" or enriched >= enrich_pages:
                run["stop_reason"] = "target_reached" if state["supplier"] != "both" else "enrichment_budget"
                break
            wanted = {host for host, supplier in HOSTS.items()
                      if any(not any(o["supplier"] == supplier for o in p["offers"]) for p in state["products"])}
            if not wanted:
                run["stop_reason"] = "both_codes_found"
                break
        candidates = [(i, urlsplit(x["url"]).hostname) for i, x in enumerate(state["pending"])
                      if urlsplit(x["url"]).hostname in wanted - blocked]
        # Avoid exhausting a large Rexel category before visiting Sonepar.
        index = next((i for i, host in candidates if host != last_host), candidates[0][0] if candidates else None)
        if index is None:
            run["stop_reason"] = "no_available_pages"
            break
        item = state["pending"].pop(index)
        url, category = item["url"], item["category"]
        key = page_key(url)
        if key in state["seen"] or key in deferred_keys:
            continue
        attempted += 1
        enriched += int(enriching)
        last_host = urlsplit(url).hostname
        run.update(pages_attempted=attempted, enrichment_pages=enriched)
        try:
            final_url, html = fetcher.get(url)
            page = Page(html)
            # Follow product links and same-category pagination only, never login,
            # cart actions, global navigation menus, assets or undocumented APIs.
            for link in page.links:
                candidate = public_url(link, final_url)
                if candidate and urlsplit(candidate).hostname == urlsplit(final_url).hostname and (
                    is_product_path(urlsplit(candidate).path) or
                    urlsplit(candidate).path == urlsplit(final_url).path):
                    enqueue(state, candidate, category)
            retained = True
            if is_product_path(urlsplit(final_url).path):
                retained = merge(state["products"], extract_product(page, final_url, category, now()), allow_new=not enriching)
            keys = {key, page_key(final_url)}
            if retained:
                state["seen"].extend(keys - set(state["seen"]))
            else:
                deferred.append({"url": final_url, "category": category})
                deferred_keys.update(keys)
                run["deferred_products"] += 1
            paired = sum(len(p["offers"]) == 2 for p in state["products"])
            emit(f"{len(state['products'])}/{limit} produits — {paired} avec les deux codes — {HOSTS[urlsplit(url).hostname]} — {category}")
        except StopHost as error:
            blocked.add(urlsplit(url).hostname)
            state["pending"].append(item)
            state["issues"].append({"url": url, "reason": str(error), "at": now(), "retry_next_run": True})
            emit(str(error))
        except KeyboardInterrupt:
            state["pending"].insert(0, item)
            raise
        except (URLError, TimeoutError, OSError) as error:
            blocked.add(urlsplit(url).hostname)
            state["pending"].append(item)
            state["issues"].append({"url": url, "reason": type(error).__name__ + " : réseau indisponible", "at": now(), "retry_next_run": True})
            emit("Réseau indisponible : fournisseur suspendu, progression conservée.")
        except (ValueError, UnicodeError) as error:
            state["seen"].append(key)
            state["issues"].append({"url": url, "reason": str(error), "at": now(), "retry_next_run": False})
            emit(f"Fiche écartée : {error}")
        finally:
            checkpoint()
    return len(state["products"]) >= limit


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version",
                        version=f"2HBC Catalogue {COLLECTOR_VERSION} - photos + codes Rexel/Sonepar")
    parser.add_argument("--limit", type=int, default=100, help="Nombre de produits distincts visé (défaut : 100)")
    parser.add_argument("--supplier", choices=["both", "rexel", "sonepar"], default="both")
    parser.add_argument("--out", type=Path, default=Path.cwd() / "catalogue-2hbc", help="Dossier de résultats et de reprise")
    parser.add_argument("--delay", type=float, default=3, help="Délai minimum par domaine, en secondes (>= 2)")
    parser.add_argument("--max-pages", type=int, default=300, help="Budget de pages par exécution")
    parser.add_argument("--enrich-pages", type=int, default=100,
                        help="Après --limit, pages pour chercher les codes manquants (défaut : 100, incluses dans --max-pages ; 0 pour désactiver)")
    parser.add_argument("--urls", type=Path, help="Liste d’URL publiques (une par ligne), à la place des catégories par défaut")
    args = parser.parse_args(argv)
    if not 1 <= args.limit <= 1000 or not 1 <= args.max_pages <= 2000 or not 2 <= args.delay <= 120 or not 0 <= args.enrich_pages <= 2000:
        parser.error("Limites : 1–1000 produits, 1–2000 pages, 0–2000 pages d’enrichissement, délai 2–120 secondes.")
    state_path = args.out / "state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state.get("version") != 1 or state.get("supplier") != args.supplier:
            parser.error("Dossier de reprise incompatible ; utilisez un autre --out.")
    else:
        state = {"version": 1, "supplier": args.supplier, "products": [], "pending": [], "seen": [], "issues": []}
    seeds = DEFAULT_SEEDS
    if args.urls:
        seeds = [{"url": line.strip(), "category": "Sélection personnalisée"}
                 for line in args.urls.read_text(encoding="utf-8-sig").splitlines() if line.strip() and not line.lstrip().startswith("#")]
        if any(not public_url(s["url"]) for s in seeds):
            parser.error("La liste contient une URL hors catalogue public Rexel/Sonepar.")
    for seed in seeds:
        supplier = HOSTS[urlsplit(seed["url"]).hostname].lower()
        if args.supplier in {"both", supplier}:
            enqueue(state, seed["url"], seed["category"])
    print(f"2HBC Catalogue {COLLECTOR_VERSION} - photos + codes Rexel/Sonepar")
    print("Script exécuté :", Path(__file__).resolve())
    print("Collecte publique, sans connexion ni prix. Reprise automatique dans", args.out)
    snapshot = lambda: save(state, args.out, args.limit)
    snapshot()
    try:
        complete = collect(state, Fetcher(args.delay), args.limit, args.max_pages, snapshot, enrich_pages=args.enrich_pages)
    except KeyboardInterrupt:
        snapshot()
        print("\nInterrompu. Relancez la même commande pour reprendre.")
        return 130
    snapshot()
    print(f"Résultat : {len(state['products'])}/{args.limit} produits. Fichier : {args.out / 'products.json'}")
    overview = [catalogue_row(p) for p in state["products"]]
    print(f"Deux codes + photo : {sum(not row['missing_fields'] for row in overview)}/{len(overview)}. Récapitulatif : {args.out / 'catalogue.json'}")
    print("À contrôler avant import ; aucun changement dans Supabase.")
    if not complete:
        print("Objectif non atteint : voir report.json (blocage, champs absents ou budget épuisé).")
    return 0 if complete else 2


if __name__ == "__main__":
    sys.exit(main())
