from __future__ import annotations

import json
import pathlib
import unittest

from octoprint_companion import __version__


ROOT = pathlib.Path(__file__).parent.parent


class ManifestCase(unittest.TestCase):
    def test_manifest_identity_and_entrypoint(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "io.github.luxore.octoprint")
        self.assertEqual(manifest["version"], __version__)
        self.assertEqual(manifest["kinds"], ["bar-widget"])
        self.assertTrue((ROOT / manifest["entryPoints"]["barWidget"]).is_file())
        self.assertTrue((ROOT / "SettingsPane.qml").is_file())
        self.assertTrue((ROOT / "assets" / "octoprint.svg").is_file())

    def test_public_identity_and_release_documentation(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        readme = (ROOT / "README.md").read_text()
        self.assertEqual(manifest["name"], "Omarchy OctoPrint")
        self.assertEqual(manifest["barWidget"]["displayName"], "Omarchy OctoPrint")
        self.assertTrue(manifest["repository"].startswith("https://github.com/"))
        self.assertIn("omarchy plugin remove io.github.luxore.octoprint", readme)
        self.assertIn("OctoPrint is a registered trademark", readme)
        self.assertIn("not affiliated with", readme)

    def test_manifest_contains_no_secret_setting(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        keys = {item["key"].lower() for item in manifest["barWidget"]["schema"]}
        self.assertTrue(keys.isdisjoint({"apikey", "api_key", "password", "token", "secret"}))

    def test_manifest_exposes_facts_and_preferences_not_tuning_knobs(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        keys = {item["key"] for item in manifest["barWidget"]["schema"]}
        self.assertTrue(
            {
                "instanceUrl",
                "snapshotPath",
                "streamPath",
                "cameraMode",
                "showProgress",
                "notifyFinished",
                "notifyPaused",
                "notifyError",
            }.issubset(keys)
        )
        self.assertTrue(
            keys.isdisjoint(
                {"refreshMode", "activePollSeconds", "idlePollSeconds", "cameraIntervalMs"}
            )
        )
        self.assertEqual(manifest["barWidget"]["defaults"]["cameraMode"], "stream")

    def test_visible_settings_are_three_small_tabs_with_automatic_saves(self):
        widget = (ROOT / "OctoPrintWidget.qml").read_text()
        pane = (ROOT / "SettingsPane.qml").read_text()
        self.assertIn('{ value: "preferences", label: "Preferences" }', widget)
        self.assertIn('{ value: "setup", label: "Setup" }', widget)
        self.assertIn("onEditingFinished", pane)
        self.assertIn("preferenceRequested", pane)
        self.assertNotIn("Save settings", pane)
        self.assertNotIn("Refresh pace", pane)
        self.assertNotIn("Snapshot path", pane)

if __name__ == "__main__":
    unittest.main()
