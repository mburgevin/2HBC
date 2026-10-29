"""Tests du contrat collecteur/importeur ; aucune requête réseau."""
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_catalogue_collector import product, c, ROOT

spec = importlib.util.spec_from_file_location("importer", ROOT / "scripts/prepare_catalogue_import.py")
imp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp)


class ImportTests(unittest.TestCase):
    def test_images_keep_supplier_provenance_and_reject_wrong_product(self):
        p = product()
        p["offers"][0]["image_url"] = "https://api.rexel.fr/media/api/fr/content/73224603/EXTRA_LARGE"
        self.assertIn('image_url', imp.generate_sql([p]))
        p["offers"][0]["image_url"] = "https://api.rexel.fr/media/api/fr/content/123/EXTRA_LARGE"
        with self.assertRaises(ValueError):
            imp.validate([p])
        p = product("Sonepar")
        p["offers"][0]["image_url"] = "https://fra-connect.mo.cloudinary.net/PRODUCT/IMAGE/1/LG-069511L-WEB-R.jpg?ts=123"
        imp.validate([p])
        p["offers"][0]["image_url"] += "&token=private"
        with self.assertRaises(ValueError):
            imp.validate([p])
    def test_actual_collector_output_compatible_for_both_suppliers(self):
        products = [product()]
        c.merge(products, product("Sonepar"))
        sql = imp.generate_sql(products)
        self.assertIn("importer_catalogue_v3", sql)
        self.assertIn("'::jsonb, false, false)", sql)
        self.assertIn("00001187798", sql)
        products[0]["offers"][0]["url"] = "https://www.rexel.fr/frx/p/73224603"
        imp.validate(products)

    def test_publication_needs_explicit_review_and_flag(self):
        p = product()
        with self.assertRaises(ValueError):
            imp.generate_sql([p], True)
        p["review_status"] = "approved"
        p["category_code"] = "interrupteurs"
        self.assertIn("'::jsonb, false, false)", imp.generate_sql([p]))
        self.assertIn("'::jsonb, true, false)", imp.generate_sql([p], True))

    def test_missing_fields_numeric_refs_and_unknown_data_rejected(self):
        for key in ("brand", "reference", "ean", "name", "categories", "offers", "review_status"):
            p = product()
            del p[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                imp.validate([p])
        for patch in ({"reference": 123}, {"page_sha256": "bad"}, {"cookie": "secret"},
                      {"collected_at": "2026-10-11"}, {"url": "https://evil.test"}):
            p = product()
            p["offers"][0].update(patch)
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                imp.validate([p])

    def test_colliding_identifiers_and_checksum_rejected(self):
        p = product()
        for patch in ({}, {"reference": "other"}, {"brand": "OTHER"}):
            other = copy.deepcopy(p)
            other.update(patch)
            with self.assertRaises(ValueError):
                imp.validate([p, other])
        for value in ("3414971877987", "123456789", 3414971877986):
            self.assertFalse(imp.valid_gtin(value))

    def test_cli_prepares_file_and_rejects_unreviewed_publication(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "products.json"
            dest = Path(folder) / "preparation.sql"
            source.write_text(json.dumps([product()]), encoding="utf-8")
            args = [sys.executable, str(ROOT / "scripts/prepare_catalogue_import.py"), str(source), "--out", str(dest)]
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            before = dest.read_text(encoding="utf-8")
            result = subprocess.run(args + ["--approve"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(dest.read_text(encoding="utf-8"), before)


if __name__ == "__main__":
    unittest.main()
