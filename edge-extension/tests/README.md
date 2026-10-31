Run from `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
python3 tests/run_lua_tests.py ../init.lua tests/test_lifecycle.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

The Python runner uses the Lua runtime bundled with Hammerspoon on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua` instead.

The Lua checks execute the config against Hammerspoon mocks and cover Edge-only Option+Tab / Option+Shift+Tab handling, native key pass-through in other applications, delayed app notifications, focus-loss cancellation, immediate Option-release selection and its fallback timer, held keys, keyboard cancellation, grid navigation, window resizing, 96 layouts, and asynchronous icons. A missing focused-window result does not dismiss an already open switcher. An idle-path check verifies that unrelated keys make no app/window queries and allocate no timers; its timing uses mocks and is not an end-to-end latency benchmark.

The JavaScript checks execute the extension worker against browser mocks and cover cached icons, concurrent requests, navigation/close races, scope, background metadata updates, failed or invalid image responses, focused-tab preview capture, thumbnail resizing, bitmap release, bounded preview caches, and recovery after capture failures.

Bridge tests also verify that rejected or missing credentials cannot make a socket healthy, diagnostics contain only aggregate state, and authenticated activations preserve visit order. The worker tests execute a generated `bridge-token.js` when present (using a test-only fixture for a clean checkout) and verify that MRU snapshots follow visit order rather than tab indices.

From the project root, `python3 scripts/test_prepare_install.py` validates installation generation in an isolated temporary directory, including credential alignment, repeat runs, and regeneration after deleting `dist`. It does not read the installed Hammerspoon configuration or live private tokens.

The separate lifecycle suite models native callback references and weak listener ownership. It forces full garbage collection, verifies that all three persistent listeners remain active, then releases their owner and verifies cleanup. It intentionally avoids keeping test-owned strong references to listeners, which would conceal this class of failure.

Appearance regressions cover the default light appearance (`nil`), explicit light/dark modes, changes while the panel is open, and reopening after a change. They verify readable foreground/background pairs, selection and preview retention, stable transparency, no unnecessary redraws, and no appearance queries while idle.

Transport regressions simulate failed HTTP with a working socket, require live visit messages without per-visit HTTP, verify authenticated heartbeat replies, retire silent sockets after 15 seconds, replay visit order on reconnect, ignore late callbacks from replaced sockets, and ensure only one heartbeat timer remains. Lua tests distinguish history freshness from connection health.

Wake regressions deliver repeated system/display/unlock events and assert that recovery preserves exactly one listening server without stopping or rebinding its port; live updates must continue afterward.

The simulated-day check advances a fake clock through at least 24 hours, alternating browsing and idle periods. It checks 4,320 visits, 12 idle hours, 24 silent-socket recoveries, receiver-side order, and bounded timer/cache collections. This runs without real waiting and is not a native 24-hour endurance or memory benchmark.

Layout regressions check all 2–25 tab counts across small, wide, tall, and large windows for non-overlapping cards, balanced row populations, contained labels, and the absence of a full-panel backdrop. Resize checks verify growing title/icon sizes and stable selection and MRU order.

Card-shape regressions verify portrait and wide proportions, plus screen-only size changes that clip the available window area without changing the selected tab.
