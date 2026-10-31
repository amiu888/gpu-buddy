"""Quick checks for gpud's pure logic. They run anywhere (no Mac needed):

    python3 -m unittest discover -s tests
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "daemon"))
import gpud  # noqa: E402

SHIPPED = os.path.join(ROOT, "daemon", "prices.json")


class PricesFile(unittest.TestCase):
    def test_shipped_prices_are_complete(self):
        with open(SHIPPED) as f:
            prices = json.load(f)
        self.assertTrue(prices.get("as_of"))
        self.assertTrue(prices["models"])
        for m in prices["models"]:
            for key in ("provider", "model", "input", "cache_read", "cache_write", "output"):
                self.assertIn(key, m, f"{m.get('model')} has no {key}")
            self.assertGreaterEqual(m["output"], m["input"], m["model"])


class LoadPrices(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = mock.patch.object(gpud, "STATE_DIR", self.tmp.name)
        self.state.start()
        with open(SHIPPED) as f:
            self.shipped = json.load(f)

    def tearDown(self):
        self.state.stop()
        self.tmp.cleanup()

    def write_user_copy(self, prices):
        with open(os.path.join(self.tmp.name, "prices.json"), "w") as f:
            json.dump(prices, f)

    def test_no_user_copy_uses_shipped(self):
        self.assertEqual(gpud.load_prices()["as_of"], self.shipped["as_of"])

    def test_older_user_copy_does_not_hide_newer_shipped_prices(self):
        self.write_user_copy(dict(self.shipped, as_of="2000-01-01", models=[]))
        self.assertEqual(gpud.load_prices()["models"], self.shipped["models"])

    def test_edited_user_copy_with_current_date_wins(self):
        self.write_user_copy(dict(self.shipped, as_of="2999-01-01", models=[]))
        self.assertEqual(gpud.load_prices()["models"], [])

    def test_update_prices_never_writes_user_copy_or_fetches(self):
        with mock.patch.object(gpud, "PRICES_BACKUP_DIR", os.path.join(self.tmp.name, "prices_history")), \
                mock.patch.object(gpud, "http_get", side_effect=AssertionError("no network")):
            self.assertTrue(gpud.update_prices())    # first run records the table in use
            self.assertFalse(gpud.update_prices())   # unchanged: nothing new
            self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "prices.json")))
            self.assertEqual(len(os.listdir(os.path.join(self.tmp.name, "prices_history"))), 1)


class CloudCost(unittest.TestCase):
    def test_one_million_tokens_each_way_at_list_price(self):
        prices = {"models": [{"provider": "X", "model": "m", "input": 3.0, "cache_read": 0.3,
                              "cache_write": 3.75, "output": 15.0, "batch": 0.5}]}
        usage = {"prompt": 1_000_000, "generated": 1_000_000, "from": 0, "to": 86400}
        with mock.patch.object(gpud, "load_prices", return_value=prices):
            self.assertEqual(gpud.cloud_cost(usage)["models"][0]["cost"], 18.0)
            self.assertEqual(gpud.cloud_cost(usage, batch=True)["models"][0]["cost"], 9.0)


class PublicSnapshot(unittest.TestCase):
    def test_paired_macs_never_get_what_people_typed(self):
        snap = {"processes": [{"pid": 1, "explain_quote": "secret"}],
                "llm_requests": {"active": [{"id": 1, "snippet": "hi"}], "recent": [{"id": 2, "snippet": "yo"}]}}
        out = json.dumps(gpud.public_snapshot(snap))
        self.assertNotIn("snippet", out)
        self.assertNotIn("explain_quote", out)


if __name__ == "__main__":
    unittest.main()
