"""Offline regression tests: no real supplier or Supabase calls."""
import importlib.util
import json
import tempfile
import unittest
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

    def test_report_never_claims_target_when_only_partial(self):
        data = state()
        data["products"] = [product()]
        with tempfile.TemporaryDirectory() as temp:
            c.save(data, Path(temp), 100)
            report = json.loads((Path(temp) / "report.json").read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(report["products"], 1)
            self.assertEqual(report["single_supplier"], 1)
            self.assertFalse(report["prices_collected"])
            self.assertTrue(report["needs_review"])
            self.assertEqual(json.loads((Path(temp) / "state.json").read_text()), data)


if __name__ == "__main__":
    unittest.main()
