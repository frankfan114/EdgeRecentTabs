"""Integration checks for local installation generation; never use live credentials."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrepareInstallTests(unittest.TestCase):
    def test_shared_credential_survives_regeneration_and_dist_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="edge-mru-install-test-") as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            (root / "edge-extension").mkdir()
            files = ["init.lua", "scripts/prepare_install.py"] + [
                "edge-extension/" + name for name in (
                    "background.js", "manifest.json", "options.html", "options.css", "options.js"
                )
            ]
            for name in files:
                shutil.copy2(ROOT / name, root / name)

            def prepare():
                subprocess.run(
                    [sys.executable, str(root / "scripts/prepare_install.py")],
                    check=True, capture_output=True, text=True,
                )
                lua = (root / "dist/init.lua").read_text()
                source_config = (root / "edge-extension/bridge-token.js").read_text()
                packaged_config = (root / "dist/edge-extension/bridge-token.js").read_text()
                token = re.search(r'local BRIDGE_TOKEN = "([0-9a-f]{64})"', lua)
                self.assertIsNotNone(token, "Generated Lua must have a private credential")
                extension_token = re.search(r'EDGE_MRU_LOCAL_TOKEN = "([0-9a-f]{64})"', source_config)
                self.assertIsNotNone(extension_token, "Generated extension config must have a credential")
                # Boolean assertions avoid putting private values in failure messages.
                self.assertTrue(token[1] == extension_token[1], "Both sides must authenticate together")
                self.assertTrue(source_config == packaged_config, "Both extension folders must agree")
                self.assertTrue(source_config.endswith(";\n"), "The generated file must end with a real newline")
                self.assertTrue((root / "dist/edge-extension/background.js").read_bytes()
                                == (root / "edge-extension/background.js").read_bytes())
                self.assertIn("__EDGE_MRU_LOCAL_TOKEN__", (root / "init.lua").read_text())
                return token[1]

            first = prepare()
            self.assertTrue(first == prepare(), "Repeated preparation must not rotate credentials")
            shutil.rmtree(root / "dist")
            self.assertTrue(first == prepare(), "The source config must survive dist cleanup")


if __name__ == "__main__":
    unittest.main()
