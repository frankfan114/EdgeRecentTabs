#!/usr/bin/env python3
"""Create local installation files without putting bridge tokens in Git."""

from pathlib import Path
import re
import secrets
import shutil

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist"
PLACEHOLDER = "__EDGE_MRU_LOCAL_TOKEN__"


def main():
    lua = (ROOT / "init.lua").read_text()
    worker = (ROOT / "edge-extension" / "background.js").read_text()
    if lua.count(PLACEHOLDER) != 1:
        raise SystemExit("Expected one bridge-token placeholder in init.lua.")

    token = None
    installed_lua = OUTPUT / "init.lua"
    if installed_lua.exists():
        match = re.search(r'local BRIDGE_TOKEN = "([0-9a-f]{64})"', installed_lua.read_text())
        if match:
            token = match.group(1)
    local_token_file = ROOT / "edge-extension" / "bridge-token.js"
    if token is None and local_token_file.exists():
        match = re.search(r'EDGE_MRU_LOCAL_TOKEN = "([0-9a-f]{64})"', local_token_file.read_text())
        if match:
            token = match.group(1)
    token = token or secrets.token_hex(32)

    extension = OUTPUT / "edge-extension"
    extension.mkdir(parents=True, exist_ok=True)
    installed_lua.write_text(lua.replace(PLACEHOLDER, token))
    token_script = f'globalThis.EDGE_MRU_LOCAL_TOKEN = "{token}";\n'
    local_token_file.write_text(token_script)
    (extension / "bridge-token.js").write_text(token_script)
    (extension / "background.js").write_text(worker)
    for name in ("manifest.json", "options.html", "options.css", "options.js"):
        shutil.copy2(ROOT / "edge-extension" / name, extension / name)
    print("Prepared dist/init.lua and both extension folders with the same local bridge token.")
    print("Install dist/init.lua in Hammerspoon, then reload the existing extension in Edge.")
    print("For a new install, load edge-extension or dist/edge-extension.")


if __name__ == "__main__":
    main()
