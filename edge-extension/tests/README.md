Run from `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

The Python runner uses the Lua runtime bundled with Hammerspoon on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua` instead.

The Lua checks execute the config against Hammerspoon mocks and cover Edge-only Option+Tab / Option+Shift+Tab handling, native key pass-through in other applications, delayed app notifications, focus-loss cancellation, immediate Option-release selection and its fallback timer, held keys, keyboard cancellation, grid navigation, window resizing, 96 layouts, and asynchronous icons. A missing focused-window result does not dismiss an already open switcher. An idle-path check verifies that unrelated keys make no app/window queries and allocate no timers; its timing uses mocks and is not an end-to-end latency benchmark.

The JavaScript checks execute the extension worker against browser mocks and cover cached icons, concurrent requests, navigation/close races, scope, background metadata updates, failed or invalid image responses, focused-tab preview capture, thumbnail resizing, bitmap release, bounded preview caches, and recovery after capture failures.

Bridge tests also verify that rejected or missing credentials cannot make a socket healthy, diagnostics contain only aggregate state, and authenticated activations preserve visit order. The worker tests execute a generated `bridge-token.js` when present (using a test-only fixture for a clean checkout) and verify that MRU snapshots follow visit order rather than tab indices.

From the project root, `python3 scripts/test_prepare_install.py` validates installation generation in an isolated temporary directory, including credential alignment, repeat runs, and regeneration after deleting `dist`. It does not read the installed Hammerspoon configuration or live private tokens.
