# -*- coding: utf-8 -*-
"""Тесты tools/updates.py без сети: python3 -m unittest discover -s tests"""

import importlib.util
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("updates", os.path.join(ROOT, "tools", "updates.py"))
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)

NOW = datetime(2026, 10, 26, tzinfo=timezone.utc)


def rel(tag, days_ago, prerelease=False):
    when = (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"tag_name": tag, "draft": False, "prerelease": prerelease, "published_at": when}


class BinaryTest(unittest.TestCase):
    def check(self, releases, current="1.12.25"):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("SINGBOX_VERSION=%s\nXRAY_VERSION=26.9.9\n" % current)
        self.addCleanup(os.unlink, f.name)
        with mock.patch.object(updates, "VERSIONS", f.name), \
                mock.patch.object(updates, "github", return_value=releases):
            return updates.check_binary("sing-box", NOW)

    def test_same_line_and_new_line(self):
        it = self.check([rel("v1.13.2", 30), rel("v1.12.27", 20), rel("v1.12.26", 40)])
        self.assertEqual(it.latest, "1.12.27")
        self.assertEqual(it.major, "1.13.2")

    def test_cooldown_and_prerelease(self):
        it = self.check([rel("v1.12.28", 2), rel("v1.13.0-beta.1", 30, True), rel("v1.12.27", 10)])
        self.assertEqual(it.latest, "1.12.27")
        self.assertIsNone(it.major)
        self.assertIn("v1.12.28", it.note)

    def test_up_to_date(self):
        it = self.check([rel("v1.12.25", 30), rel("v1.12.24", 60)])
        self.assertIsNone(it.latest)
        self.assertIsNone(it.major)

    def test_xray_line_is_year(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("SINGBOX_VERSION=1.12.25\nXRAY_VERSION=26.9.9\n")
        self.addCleanup(os.unlink, f.name)
        rels = [rel("v27.1.5", 30), rel("v26.10.2", 30)]
        with mock.patch.object(updates, "VERSIONS", f.name), \
                mock.patch.object(updates, "github", return_value=rels):
            it = updates.check_binary("xray", NOW)
        self.assertEqual((it.latest, it.major), ("26.10.2", "27.1.5"))


class RulesTest(unittest.TestCase):
    def check(self, sources, tags=("20261020", "20261020")):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write(sources)
        self.addCleanup(os.unlink, f.name)
        answers = iter(tags)
        with mock.patch.object(updates, "RULES_SOURCES", f.name), \
                mock.patch.object(updates, "latest_tag", side_effect=lambda _: next(answers)):
            return updates.check_rules(NOW)

    def test_stale_and_new_release(self):
        it = self.check("BUILT=2026-09-01\nGEOSITE_TAG=a\nGEOIP_TAG=b\n")
        self.assertEqual(it.latest, "2026-10-26")

    def test_fresh_build_waits(self):
        it = self.check("BUILT=2026-10-20\nGEOSITE_TAG=a\nGEOIP_TAG=b\n")
        self.assertIsNone(it.latest)
        self.assertIn("2026-11-17", it.note)

    def test_same_tags(self):
        it = self.check("BUILT=2026-01-01\nGEOSITE_TAG=20261020\nGEOIP_TAG=20261020\n")
        self.assertIsNone(it.latest)

    def test_unknown_build_is_stale(self):
        it = self.check("")
        self.assertEqual(it.latest, "2026-10-26")


if __name__ == "__main__":
    unittest.main()
