"""Offline regression tests: no real supplier or Supabase calls."""
import importlib.util
import json
import tempfile
import unittest
import subprocess
import sys
from email.message import Message
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("collector", ROOT / "scripts/collect_catalogue.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

R = "https://www.rexel.fr/frx/product/LEG069511L/p/73224603"
S = "https://www.sonepar.fr/catalog/fr-fr/products/product-00001187798"
DATE = "2026-10-11T12:00:00+00:00"
# Synthetic markup using public identifiers from the existing pilot catalogue.
REXEL = """<title>Legrand</title><h1>Interrupteur Plexo</h1>
<div>Réf Rexel <span>LEG069511L</span><i>content_copy</i></div>
<div>Réf Fab : <b>069511L</b></div><div>EAN13 : <b>3414971877986</b></div>
<a>Découvrez toute l'offre Legrand &gt;</a><h2>Détails du produit</h2>
<script>const privatePrice = 42; const unrelated = 'EAN13 1234567890128';</script>"""
SONEPAR = """<h1>Legrand - Interrupteur Plexo - 069511L</h1>
<h2>Conditionnement</h2><ul><li>10 unité(s)</li><li>Article en stock standard</li></ul>
<h3>Références</h3><dl><dt>EAN</dt><dd>3414971877986</dd>
<dt>Réf. Sonepar</dt><dd>00001187798</dd><dt>Réf. Fournisseur</dt><dd>069511L</dd>
<dt>Marque</dt><dd>Legrand</dd></dl><h3>Caractéristiques techniques</h3>
<p>Couleur gris</p><h2>Articles similaires</h2><p>EAN 3414971880092</p>"""


def product(supplier="Rexel"):
    return c.extract_product(c.Page(REXEL if supplier == "Rexel" else SONEPAR), R if supplier == "Rexel" else S, "Appareillage", DATE)


def state():
    return {"version": 1, "supplier": "both", "products": [], "pending": [], "seen": [], "issues": []}


class CollectorTests(unittest.TestCase):
    def test_structured_rexel_attributes_and_breadcrumb_ignore_global_menu(self):
        html = REXEL + '''<nav><a href="/frx/c/M2_999">Menu non pertinent</a></nav>
        <div class="breadcrumb"><a href="/frx/c/M2_010706">Appareillage composable</a></div>
        <mf-pdp-technical-attributes><div>
          <div><p class="w-50">Intensité</p><div><h4>16</h4><span>A</span></div></div>
          <div><p class="w-50">Gamme</p><div><h4>Odace</h4></div></div>
          <div><p class="w-50">Sans halogène</p><div><h4>Non</h4></div></div>
        </div></mf-pdp-technical-attributes>'''
        p = c.extract_product(c.Page(html), R, "Découverte", DATE)
        self.assertEqual(p["schema_version"], 2)
        self.assertEqual(p["range"], "Odace")
        self.assertIsNone(p["category_code"])
        self.assertEqual([x["code"] for x in p["offers"][0]["category_path"]], ["M2_010706"])
        values = {a["code"]: a["value"] for a in p["attributes"]}
        self.assertEqual(values, {"courant": 16, "sans_halogene": False})

    def test_sonepar_attributes_decimal_units_and_unknown_values_preserved(self):
        html = SONEPAR + '''<div data-testid="tech-spec-panel"><p>section nominale du conducteur:</p><p>2,5 mm²</p></div>
        <div data-testid="tech-spec-panel"><p>fréquence:</p><p>50...60 Hz</p></div>
        <div data-testid="tech-spec-panel"><p>couleur:</p><p>blanc</p></div>'''
        p = c.extract_product(c.Page(html), S, "Découverte", DATE)
        self.assertEqual(len(p["offers"][0]["raw_attributes"]), 3)
        self.assertEqual(next(a for a in p["attributes"] if a["code"] == "section")["value"], 2.5)
        self.assertIsNone(c.canonical_attribute("Intensité", "10...16 A"))
        self.assertIsNone(c.canonical_attribute("Intensité", "16 mA"))
        self.assertIsNone(c.canonical_attribute("Nombre de pôles", "1P+N"))

    def test_matching_products_with_conflicting_specs_are_flagged_not_overwritten(self):
        one, two = product(), product("Sonepar")
        one["offers"][0]["raw_attributes"] = [{"label": "Couleur", "value": "blanc"}]
        two["offers"][0]["raw_attributes"] = [{"label": "couleur", "value": "noir"}]
        products = [one]
        c.merge(products, two)
        self.assertEqual(products[0]["attribute_conflicts"], ["couleur"])
        self.assertEqual(products[0]["attributes"], [])
        self.assertEqual(len(products[0]["offers"]), 2)

    def test_old_resume_folder_requires_fresh_collection(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "state.json").write_text(json.dumps(state()))
            with self.assertRaises(SystemExit), patch.object(c.Fetcher, "get") as fetch:
                c.main(["--out", folder])
            fetch.assert_not_called()

    def test_version_is_identifiable_without_network_or_output_files(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/collect_catalogue.py"), "--version"],
                                    cwd=folder, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(c.COLLECTOR_VERSION, result.stdout)
            self.assertIn("photos + codes Rexel/Sonepar", result.stdout)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_rexel_photo_is_main_media_for_exact_product(self):
        html = REXEL + '''<img alt="Rexel logo" src="https://api.rexel.fr/media/api/fr/content/123/LARGE">
        <img alt="Main media" src="https://api.rexel.fr/media/api/fr/content/999/EXTRA_LARGE">
        <img alt="Main media" src="https://api.rexel.fr/media/api/fr/content/73224603/EXTRA_LARGE">'''
        p = c.extract_product(c.Page(html), R, "Test", DATE)
        self.assertEqual(p["offers"][0]["image_url"], "https://api.rexel.fr/media/api/fr/content/73224603/EXTRA_LARGE")

    def test_sonepar_photo_uses_labelled_product_not_logo_or_recommendation(self):
        base = "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/"
        html = SONEPAR + f'''<img src="{base}neighbour.jpg?ts=123">
        <img src="{base}LG-069511L-WEB-R.jpg?ts=123">
        <img alt="Vignette Photo produit ambiance 1" src="{base}scenery.jpg?ts=123">
        <img alt="Vignette Photo produit 1" src="{base}LG-069511L-WEB-R.jpg?ts=123&amp;type=xsmall">'''
        p = c.extract_product(c.Page(html), S, "Test", DATE)
        self.assertEqual(p["offers"][0]["image_url"], base + "LG-069511L-WEB-R.jpg?ts=123")
        self.assertNotIn("image_url", product()["offers"][0])

    def test_unsafe_image_urls_rejected(self):
        for url in ["https://fra-connect.mo.cloudinary.net.evil.test/PRODUCT/IMAGE/1/x.jpg",
                    "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/x.svg",
                    "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/x.jpg?token=secret",
                    "https://user:pass@fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/x.jpg",
                    "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/x.jpg?ts=1&ts=2",
                    "javascript:alert(1)"]:
            self.assertFalse(c.image_url_valid(url, "Sonepar"), url)

    def test_rexel_facts_without_scripts_or_prices(self):
        p = product()
        self.assertEqual((p["brand"], p["reference"], p["ean"]), ("Legrand", "069511L", "3414971877986"))
        self.assertEqual(p["offers"][0]["reference"], "LEG069511L")
        self.assertNotIn("privatePrice", json.dumps(p))
        self.assertNotIn("price", p["offers"][0])
        self.assertEqual(p["review_status"], "pending")

    def test_sonepar_scoped_references_preserve_leading_zeroes(self):
        p = product("Sonepar")
        self.assertEqual(p["name"], "Interrupteur Plexo")
        self.assertEqual(p["ean"], "3414971877986")
        self.assertEqual(p["offers"][0]["reference"], "00001187798")
        self.assertEqual(p["offers"][0]["pack"], "10 unité(s)")

    def test_bad_ean_missing_fields_and_ambiguous_ean_are_rejected(self):
        for html in [REXEL.replace("3414971877986", "3414971877987"),
                     REXEL.replace("Réf Fab", "Autre champ"),
                     REXEL + "<p>EAN13 3414971880092</p>"]:
            with self.subTest(html=html), self.assertRaises(ValueError):
                c.extract_product(c.Page(html), R, "test", DATE)

    def test_wrong_supplier_reference_in_url_is_rejected(self):
        for html, url in [(SONEPAR, S.replace("00001187798", "00001188009")),
                          (REXEL, R.replace("LEG069511L", "LEGOTHER"))]:
            with self.assertRaises(ValueError):
                c.extract_product(c.Page(html), url, "test", DATE)

    def test_public_urls_exclude_actions_credentials_and_tracking(self):
        for url in ["http://www.rexel.fr/frx/p/12", "https://www.rexel.fr.evil.test/frx/p/12",
                    "https://user:pass@www.rexel.fr/frx/p/12", "https://www.rexel.fr/frx/cart",
                    "https://www.sonepar.fr/api/products", "https://www.rexel.fr/frx/login",
                    R + "?token=secret", R + "?page=1", "file:///tmp/page.html",
                    "https://www.rexel.fr/frx/c/LEG?page=0&price=true"]:
            self.assertIsNone(c.public_url(url), url)
        self.assertEqual(c.public_url(R + "#details"), R)
        self.assertIsNotNone(c.public_url("https://www.rexel.fr/frx/c/LEG?page=2"))

    def test_slug_aliases_share_product_identity(self):
        self.assertEqual(c.page_key(R), c.page_key(R.replace("product/", "another-long-slug/")))
        self.assertEqual(c.page_key(S), c.page_key(S.replace("product-", "different-slug-")))

    def test_supplier_matching_requires_all_three_identifiers(self):
        products = [product()]
        c.merge(products, product("Sonepar"))
        self.assertEqual(len(products), 1)
        self.assertEqual(len(products[0]["offers"]), 2)
        c.merge(products, product("Sonepar"))
        self.assertEqual(len(products[0]["offers"]), 2)
        for field, value in [("ean", "3414971880092"), ("brand", "Autre marque"), ("reference", "069611L")]:
            conflicting = product("Sonepar")
            conflicting[field] = value
            with self.assertRaises(ValueError):
                c.merge(products, conflicting)
        conflicting = product("Sonepar")
        conflicting["offers"][0]["reference"] = "00000000001"
        with self.assertRaises(ValueError):
            c.merge(products, conflicting)

    def test_robots_wildcards_specific_rules_allow_tie_and_delay(self):
        policy = c.Robots("""User-agent: ChatGPT-User
Allow: /
User-agent: *
Disallow: */login
Disallow: */search*
Allow: */searchSpring/*
Disallow: /frx/c/LEG$
Allow: /frx/c/LEG$
Crawl-delay: 4
User-agent: Python Requests
Disallow: /
""")
        self.assertTrue(policy.allows(R))
        self.assertFalse(policy.allows("https://www.rexel.fr/frx/login"))
        self.assertFalse(policy.allows("https://www.rexel.fr/frx/search?q=a"))
        self.assertTrue(policy.allows("https://www.rexel.fr/frx/searchSpring/a"))
        self.assertTrue(policy.allows("https://www.rexel.fr/frx/c/LEG"))
        self.assertEqual(policy.delay, 4)
        specific = c.Robots("User-agent: *\nAllow: /\nUser-agent: 2HBCCatalogue\nDisallow: /\n")
        self.assertFalse(specific.allows(R))

    def test_robots_denial_prevents_product_request(self):
        fetcher = c.Fetcher(0)
        with patch.object(fetcher, "request", return_value="User-agent: *\nDisallow: /") as request:
            with self.assertRaisesRegex(ValueError, "robots"):
                fetcher.get(R)
            self.assertEqual(request.call_count, 1)

    def test_redirects_cannot_visit_login_or_other_hosts(self):
        for location in ["/frx/login", "https://elsewhere.test/p/1"]:
            fetcher = c.Fetcher(0)
            headers = Message()
            headers["Location"] = location
            with patch.object(fetcher, "request", side_effect=["User-agent: *\nAllow: /", HTTPError(R, 302, "redirect", headers, None)]) as request:
                with self.assertRaisesRegex(ValueError, "Redirection"):
                    fetcher.get(R)
                self.assertEqual(request.call_count, 2)

    def test_robots_rechecked_after_public_redirect(self):
        fetcher = c.Fetcher(0)
        headers = Message()
        headers["Location"] = R.replace("73224603", "123")
        with patch.object(fetcher, "request", side_effect=["User-agent: *\nDisallow: */p/123$", HTTPError(R, 301, "redirect", headers, None)]) as request:
            with self.assertRaisesRegex(ValueError, "robots"):
                fetcher.get(R)
            self.assertEqual(request.call_count, 2)

    def test_blocking_http_status_stops_without_retry(self):
        for code in [401, 403, 429, 503]:
            fake = unittest.mock.Mock()
            fake.open.side_effect = HTTPError(R, code, "blocked", Message(), None)
            with self.assertRaises(c.StopHost):
                c.Fetcher(0, fake).request(R, 0)
            self.assertEqual(fake.open.call_count, 1)

    def test_collection_limit_discovery_and_resume(self):
        data = state()
        category = "https://www.rexel.fr/frx/c/LEG"
        c.enqueue(data, category, "Appareillage")
        fake = unittest.mock.Mock()
        fake.get.side_effect = [(category, f'<a href="{R}">A</a><a href="/frx/cart">Panier</a>'), (R, REXEL)]
        self.assertFalse(c.collect(data, fake, 1, 1, emit=lambda _: None))
        self.assertEqual(data["pending"], [{"url": R, "category": "Appareillage"}])
        self.assertTrue(c.collect(data, fake, 1, 1, emit=lambda _: None))
        self.assertEqual(len(data["products"]), 1)

    def test_blocked_host_preserves_queue_and_other_supplier_can_continue(self):
        data = state()
        c.enqueue(data, R, "test")
        c.enqueue(data, S, "test")
        fake = unittest.mock.Mock()
        fake.get.side_effect = [c.StopHost("HTTP 403"), (S, SONEPAR)]
        self.assertTrue(c.collect(data, fake, 1, 20, emit=lambda _: None))
        self.assertEqual(fake.get.call_count, 2)
        self.assertEqual(data["pending"][0]["url"], R)
        self.assertTrue(data["issues"][0]["retry_next_run"])

    def test_keyboard_interrupt_keeps_inflight_url_and_saves(self):
        data = state()
        c.enqueue(data, R, "test")
        fake = unittest.mock.Mock()
        fake.get.side_effect = KeyboardInterrupt()
        checkpoint = unittest.mock.Mock()
        with self.assertRaises(KeyboardInterrupt):
            c.collect(data, fake, 1, 1, checkpoint)
        self.assertEqual(data["pending"][0]["url"], R)
        checkpoint.assert_called_once()

    def test_limit_does_not_prevent_second_supplier_code_and_photo(self):
        data = state()
        c.enqueue(data, R, "test")
        c.enqueue(data, S, "test")
        photo = "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/LG-069511L-WEB-R.jpg?ts=123"
        fake = unittest.mock.Mock()
        fake.get.side_effect = [(R, REXEL), (S, SONEPAR + f'<img alt="Vignette Photo produit 1" src="{photo}">')]
        self.assertTrue(c.collect(data, fake, 1, 10, emit=lambda _: None))
        self.assertEqual(fake.get.call_count, 2)
        row = c.catalogue_row(data["products"][0])
        self.assertEqual((row["manufacturer_reference"], row["rexel_code"], row["sonepar_code"]),
                         ("069511L", "LEG069511L", "00001187798"))
        self.assertEqual(row["image_url"], photo)
        self.assertEqual(row["missing_fields"], [])
        self.assertEqual(data["last_run"]["stop_reason"], "both_codes_found")

    def test_enrichment_skips_other_products_and_can_resume_with_larger_limit(self):
        data = state()
        data["products"] = [product()]
        other_url = S.replace("00001187798", "00001188009")
        other_html = SONEPAR.replace("00001187798", "00001188009").replace("069511L", "069611L").replace("3414971877986", "3414971880092")
        c.enqueue(data, other_url, "test")
        c.enqueue(data, S, "test")
        fake = unittest.mock.Mock()
        fake.get.side_effect = [(other_url, other_html), (S, SONEPAR)]
        c.collect(data, fake, 1, 10, emit=lambda _: None)
        self.assertEqual(len(data["products"]), 1)
        self.assertEqual(len(data["products"][0]["offers"]), 2)
        self.assertEqual(data["deferred"], [{"url": other_url, "category": "test"}])
        fake.get.side_effect = [(other_url, other_html)]
        c.collect(data, fake, 2, 1, emit=lambda _: None)
        self.assertEqual(len(data["products"]), 2)
        self.assertEqual(data["deferred"], [])

    def test_enrichment_conflict_is_not_merged_and_reports_reason(self):
        data = state()
        data["products"] = [product()]
        c.enqueue(data, S, "test")
        fake = unittest.mock.Mock()
        fake.get.return_value = S, SONEPAR.replace("069511L", "069611L")
        c.collect(data, fake, 1, 10, emit=lambda _: None)
        self.assertEqual(len(data["products"][0]["offers"]), 1)
        self.assertIn("Conflit EAN", data["issues"][0]["reason"])

    def test_enrichment_budget_and_total_budget_preserve_pending_pages(self):
        for max_pages, enrich_pages, calls in [(20, 0, 0), (1, 100, 1), (20, 1, 1)]:
            with self.subTest(max_pages=max_pages, enrich_pages=enrich_pages):
                data = state()
                data["products"] = [product()]
                category = "https://www.sonepar.fr/catalog/fr-fr/category/test-SCC03"
                c.enqueue(data, category, "test")
                c.enqueue(data, S, "test")
                fake = unittest.mock.Mock()
                fake.get.return_value = category, "<h1>Catalogue</h1>"
                c.collect(data, fake, 1, max_pages, emit=lambda _: None, enrich_pages=enrich_pages)
                self.assertEqual(fake.get.call_count, calls)
                self.assertIn(S, [p["url"] for p in data["pending"]])

    def test_discovery_alternates_suppliers_and_single_supplier_stops_at_limit(self):
        data = state()
        category = "https://www.rexel.fr/frx/c/LEG"
        for url in (category, R, S):
            c.enqueue(data, url, "test")
        fake = unittest.mock.Mock()
        fake.get.side_effect = [(category, "<h1>Catalogue</h1>"), (S, SONEPAR)]
        c.collect(data, fake, 1, 2, emit=lambda _: None)
        self.assertEqual([x.args[0] for x in fake.get.call_args_list], [category, S])
        data["supplier"] = "sonepar"
        fake.reset_mock()
        c.collect(data, fake, 1, 20, emit=lambda _: None)
        fake.get.assert_not_called()

    def test_readable_catalogue_preserves_missing_codes_and_image_provenance(self):
        data = state()
        data["products"] = [product("Sonepar")]
        with tempfile.TemporaryDirectory() as temp:
            c.save(data, Path(temp), 1)
            row = json.loads((Path(temp) / "catalogue.json").read_text())[0]
            report = json.loads((Path(temp) / "report.json").read_text())
            self.assertEqual(row["sonepar_code"], "00001187798")
            self.assertIsNone(row["rexel_code"])
            self.assertIsNone(row["image_url"])
            self.assertEqual(row["missing_fields"], ["rexel_code", "image_url"])
            self.assertEqual(report["missing_codes"], {"Rexel": 1, "Sonepar": 0})
            self.assertEqual(report["both_codes_and_image"], 0)

    def test_report_never_claims_target_when_only_partial(self):
        data = state()
        data["products"] = [product()]
        with tempfile.TemporaryDirectory() as temp:
            c.save(data, Path(temp), 100)
            report = json.loads((Path(temp) / "report.json").read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(report["collector_version"], c.COLLECTOR_VERSION)
            self.assertEqual(report["products"], 1)
            self.assertEqual(report["single_supplier"], 1)
            self.assertFalse(report["prices_collected"])
            self.assertTrue(report["needs_review"])
            self.assertEqual(json.loads((Path(temp) / "state.json").read_text()), data)


if __name__ == "__main__":
    unittest.main()
