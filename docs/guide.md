# Guide

[← EdgeRecentTabs](../README.md)

Setup, updates, troubleshooting, and development notes.

## How it works

`init.lua` runs in Hammerspoon. One keyboard event tap handles the shortcut and overlay navigation. It opens only when an Edge window has focus, passes keys through in other apps, draws the overlay, and activates the selected tab. Releasing Option commits immediately; the existing 20 ms watchdog runs only while the panel is open as a fallback.

`edge-extension/background.js` runs in Edge. It tracks tab history, captures previews, loads site icons, and communicates with Hammerspoon over a local bridge at `127.0.0.1:27123`. The extension's HTML, CSS, and `options.js` implement its settings popup.

The Option+Tab switcher follows macOS **System Settings → Appearance**, including automatic light/dark changes. Individual cards float over the page with 65% opaque light or dark backgrounds; the space between cards is transparent. Titles, icons and previews remain fully opaque, and a contrasting outline marks the selection. The theme updates on opening and while the switcher is visible.

Cards are arranged in balanced, centered rows based on the window shape and number of tabs. Their proportions also follow the visible window/screen area: wide layouts get wider cards, and portrait layouts get taller cards. Resizing the window or moving to a different display updates both size and shape. Extreme proportions are limited to keep previews and labels usable; page images retain their original proportions. The layout avoids sparse trailing rows while preserving recent-tab order. Titles and icons scale with card size; larger cards allow two title lines, and compact cards truncate long names. Very small cards omit the domain to leave room for the title and preview. Arrow navigation follows the closest card in the adjacent row.

To adjust card transparency, edit `CARD_BACKGROUND_ALPHA` in `init.lua` (0 is transparent, 1 is opaque). `SELECTED_CARD_ALPHA` controls the strength of the selection tint. Then follow the update steps below.

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

Long-running keyboard, application, and wake listeners have one explicit owner for the lifetime of the configuration, so Lua garbage collection cannot silently stop them. This adds no polling or extra listener.

## Current status and limitations

Option+Tab uses the existing navigation event tap instead of global hotkey registrations. Focus is checked when handling the shortcut and during an open switch; unrelated idle keys do not query applications or windows. Leaving Edge cancels the panel without selecting a tab. The focused window is checked once when opening, so a transient Accessibility window lookup failure does not dismiss an already open panel.

macOS Secure Input can prevent event taps from receiving keys (for example, while a protected password field is active). This project is experimental; the mock tests check behavior but do not guarantee keyboard reliability on every macOS setup. Some browser pages cannot provide previews, so their cards show a placeholder.

The bridge is local to this Mac. The extension stores recent-tab metadata locally and syncs its display-count and scope settings through Edge's extension storage. Page previews and icons are cached in memory. It has no analytics or project-operated cloud service. The bridge is intended for a trusted local setup; its shared token is not a complete security boundary, and it must not be exposed to the network.

## Diagnosing missing history or previews

If history stops changing, inspect `mruSource`, `mruUpdates`, `lastMruTransport`, and `lastMruUpdateAgeSeconds` at `/status` **before reloading**. Browse another tab: the update count should rise and the age should reset. A heartbeat alone does not prove history is current. `tab-strip-fallback` means the displayed list was enumerated from Edge, not restored from browsing history. The local server stays running across wake/unlock, avoiding port-rebinding failures. The worker now sends live visits over the same socket as snapshots and previews; its existing heartbeat reconnects a socket that receives no authenticated reply for 15 seconds. Update both Hammerspoon and the extension together.

The local `http://127.0.0.1:27123/status` endpoint reports listener, connection, and cache state, without URLs, page titles, or tokens. If the shortcut stops responding, check `keyboardTapEnabled` and `secureInputEnabled` separately from the bridge status. `socketAuthenticated` and `receivedMruSnapshot` should be true. An increasing `rejectedSocketMessages` count means the running extension has a different token, even if its WebSocket is connected. After updating, reload the existing extension at `edge://extensions`; regenerating files alone does not update an already running worker. Counters are cumulative until Hammerspoon restarts.

Without an authenticated extension snapshot, the AppleScript fallback enumerates open tabs in browser order and has no previews. This is not recovered browsing history. Once authenticated, visit a few ordinary web pages briefly to refill the in-memory preview cache; protected browser pages may have no preview.

See the [2026-10-24 incident report](incidents/2026-10-24-mru-preview-authentication.md) for the diagnosis and verified recovery of a credential mismatch that produced tab-strip ordering and missing previews.

See also the [shortcut listener lifetime incident](incidents/2026-10-24-shortcut-listener-lifetime.md) for the garbage-collection regression and its fix.

## Development and checks

From `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
python3 tests/run_lua_tests.py ../init.lua tests/test_lifecycle.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

From the project root, also run `python3 scripts/test_prepare_install.py` to check that both installation folders keep matching credentials across regeneration and `dist` cleanup.

The Python runner uses Hammerspoon's bundled Lua runtime on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua`. See [the test notes](../edge-extension/tests/README.md) for coverage.

Commit source changes before installing a new version, and use tags to mark versions you want to return to. Generated installation files in `dist/` should stay out of commits.

## License

[MIT](../LICENSE).
