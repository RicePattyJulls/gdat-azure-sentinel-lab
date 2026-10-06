import tempfile
import unittest
from pathlib import Path

from app import create_app


class NovaShopTestCase(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.database = str(Path(self.tempdir.name) / "test.sqlite3")
        self.app = create_app(
            {
                "TESTING": True,
                "DATABASE": self.database,
                "SECRET_KEY": "test-key",
                "LAB_MODE": True,
            }
        )
        self.client = self.app.test_client()

    def tearDown(self):
        self.tempdir.cleanup()

    def login(self, username="alice.finance", password="AliceLab!2026"):
        return self.client.post(
            "/login",
            data={"username": username, "password": password},
            follow_redirects=True,
        )

    def test_home_and_health(self):
        self.assertEqual(self.client.get("/").status_code, 200)
        self.assertEqual(self.client.get("/health").json["lab_mode"], True)

    def test_sql_injection_returns_all_products_in_lab_mode(self):
        response = self.client.get("/search", query_string={"q": "' OR 1=1 -- "})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Orbit Headphones", response.data)
        self.assertIn(b"Signal Backpack", response.data)
        self.assertIn(b"raw SQL query", response.data)

    def test_idor_is_reproducible_in_lab_mode(self):
        self.login()
        response = self.client.get("/orders/1002")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"bob.hr", response.data)
        self.assertIn(b"without an ownership check", response.data)

    def test_stored_xss_is_rendered_unescaped_in_lab_mode(self):
        self.login()
        marker = "<script>document.body.dataset.novashopXss='executed'</script>"
        self.client.post("/products/1/reviews", data={"body": marker})
        response = self.client.get("/products/1")
        self.assertIn(marker.encode(), response.data)

    def test_remediated_mode_blocks_all_three_cases(self):
        safe_app = create_app(
            {
                "TESTING": True,
                "DATABASE": str(Path(self.tempdir.name) / "safe.sqlite3"),
                "SECRET_KEY": "safe-test-key",
                "LAB_MODE": False,
            }
        )
        safe_client = safe_app.test_client()

        search = safe_client.get("/search", query_string={"q": "' OR 1=1 -- "})
        self.assertNotIn(b"Orbit Headphones", search.data)
        self.assertNotIn(b"raw SQL query", search.data)

        safe_client.post(
            "/login",
            data={"username": "alice.finance", "password": "AliceLab!2026"},
        )
        self.assertEqual(safe_client.get("/orders/1002").status_code, 403)

        marker = "<script>alert('controlled')</script>"
        safe_client.post("/products/1/reviews", data={"body": marker})
        product = safe_client.get("/products/1")
        self.assertNotIn(marker.encode(), product.data)
        self.assertIn(b"&lt;script&gt;", product.data)


if __name__ == "__main__":
    unittest.main()
