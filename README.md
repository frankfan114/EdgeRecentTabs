# Edge MRU Tab Switcher

An experimental Option+Tab switcher for Microsoft Edge on macOS, built with Hammerspoon and a small Edge extension.

Hold **Option (⌥)** and press **Tab** to browse recently used tabs. Release Option to activate the selected tab. The black overlay shows cached page previews, site icons, and numbered cards, and scales with the Edge window.

## Features

- Option+Tab and Option+Shift+Tab to cycle forwards and backwards.
- Arrow keys and number keys 1–9 to select a card while Option is held.
- Escape to cancel without changing tabs.
- Separate recent-tab histories for each Edge window, with an optional all-windows mode.
- 2–25 displayed tabs, configured from the extension popup.
- Black background at 90% opacity, cached previews, and site icons.
- A panel that follows the Edge window's position and size across monitors.
- Persistent recent-tab history and sleep/wake recovery.

## How it works

`init.lua` runs in Hammerspoon. One keyboard event tap handles the shortcut and overlay navigation. It opens only when an Edge window has focus, passes keys through in other apps, draws the overlay, and activates the selected tab. Releasing Option commits immediately; the existing 20 ms watchdog runs only while the panel is open as a fallback.

`edge-extension/background.js` runs in Edge. It tracks tab history, captures previews, loads site icons, and communicates with Hammerspoon over a local bridge at `127.0.0.1:27123`. The extension's HTML, CSS, and `options.js` implement its settings popup.

## Install

You need macOS, [Microsoft Edge](https://www.microsoft.com/edge), [Hammerspoon](https://www.hammerspoon.org/), and Python 3 for the preparation step.

1. Download this repository using **Code → Download ZIP**, or clone it, and open a terminal in the project folder.
2. Generate the installation files:

   ```sh
   python3 scripts/prepare_install.py
   ```

   This creates `dist/init.lua`, `dist/edge-extension/`, and a small `edge-extension/bridge-token.js` file with the same randomly generated local bridge token. Generated files are excluded from Git. Both extension folders work, so an existing source-folder installation can keep its extension ID, settings, and history. Run the script again after source changes; it retains the existing token.

3. Install Hammerspoon in `/Applications`, launch it, and grant the requested Accessibility access in macOS System Settings.
4. Install the generated Lua file. If you already have a Hammerspoon configuration, merge this script into it or load it from a separate file. To replace an existing configuration, first save a backup:

   ```sh
   mkdir -p ~/.hammerspoon
   if [ -f ~/.hammerspoon/init.lua ]; then
     cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup-$(date +%Y%m%d-%H%M%S)
   fi
   cp dist/init.lua ~/.hammerspoon/init.lua
   ```

5. Choose **Reload Config** from Hammerspoon's menu. If macOS asks for permission to control Microsoft Edge when the AppleScript fallback runs, allow it.
6. Open `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select **`edge-extension`** (or **`dist/edge-extension`**). See [Microsoft's sideloading instructions](https://learn.microsoft.com/en-us/microsoft-edge/extensions/getting-started/extension-sideloading).
7. Open the extension popup and select the number of tabs and the tab scope. Visit a few tabs, then try Option+Tab.

Run the preparation script before loading either extension folder; it generates the private `bridge-token.js` configuration. Updating an existing source-folder installation only requires reloading that extension, not replacing it. Preview images live in memory; after a restart, revisit tabs briefly to refill the cache.

Keep the selected extension folder in place after installing it. Edge loads an unpacked extension directly from that folder. Optionally enable **Allow access to file URLs** if you want previews for local files.

## Update

Pull or download the new source, run `python3 scripts/prepare_install.py`, install the updated `dist/init.lua`, reload Hammerspoon, and reload the extension at `edge://extensions`.

## Current status and limitations

Option+Tab uses the existing navigation event tap instead of global hotkey registrations. Focus is checked when handling the shortcut and during an open switch; unrelated idle keys do not query applications or windows. Leaving Edge cancels the panel without selecting a tab. The focused window is checked once when opening, so a transient Accessibility window lookup failure does not dismiss an already open panel.

macOS Secure Input can prevent event taps from receiving keys (for example, while a protected password field is active). This project is experimental; the mock tests check behavior but do not guarantee keyboard reliability on every macOS setup. Some browser pages cannot provide previews, so their cards show a placeholder.

The bridge is local to this Mac. The extension stores recent-tab metadata locally and syncs its display-count and scope settings through Edge's extension storage. Page previews and icons are cached in memory. It has no analytics or project-operated cloud service. The bridge is intended for a trusted local setup; its shared token is not a complete security boundary, and it must not be exposed to the network.

## Diagnosing missing history or previews

The local `http://127.0.0.1:27123/status` endpoint reports only connection and cache counts, without URLs, page titles, or tokens. `socketAuthenticated` and `receivedMruSnapshot` should be true. An increasing `rejectedSocketMessages` count means the running extension has a different token, even if its WebSocket is connected. After updating, reload the existing extension at `edge://extensions`; regenerating files alone does not update an already running worker. Counters are cumulative until Hammerspoon restarts.

Without an authenticated extension snapshot, the AppleScript fallback enumerates open tabs in browser order and has no previews. This is not recovered browsing history. Once authenticated, visit a few ordinary web pages briefly to refill the in-memory preview cache; protected browser pages may have no preview.

See the [2026-10-24 incident report](docs/incidents/2026-10-24-mru-preview-authentication.md) for the diagnosis and verified recovery of a credential mismatch that produced tab-strip ordering and missing previews.

## Development and checks

From `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

From the project root, also run `python3 scripts/test_prepare_install.py` to check that both installation folders keep matching credentials across regeneration and `dist` cleanup.

The Python runner uses Hammerspoon's bundled Lua runtime on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua`. See [the test notes](edge-extension/tests/README.md) for coverage.

Commit source changes before installing a new version, and use tags to mark versions you want to return to. Generated installation files in `dist/` should stay out of commits.

## License

[MIT](LICENSE).
