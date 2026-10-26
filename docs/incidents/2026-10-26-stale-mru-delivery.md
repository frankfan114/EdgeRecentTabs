# 2026-10-26: Recent tabs stop following visits until Hammerspoon reloads

## Report and evidence

The user reports that the switcher returns to the first tabs in Edge's tab strip rather than recent visits. **Hammerspoon → Reload Config** temporarily restores correct behavior. The user had already reloaded before this investigation, so the original failed runtime state could not be captured.

The first status sample after that reload showed an authenticated socket, an enabled keyboard tap, a received snapshot, 58 history entries, 5 previews, and no rejected credentials. Edge's extension error page also contained a connection-refused WebSocket error, which can occur while Hammerspoon is unavailable or restarting; it does not establish the cause of the earlier freeze.

## Native wake failure found in retained logs

Hammerspoon's console preserved `hs.httpserver:start() Unable to start object` with POSIX code 48, **Address already in use**, at 2026-10-25 08:46:16 and 10:04:12, then 2026-10-26 09:14:15 and 09:14:20. The next recorded configuration reload was 2026-10-26 10:08:24, followed by a successful socket connection.

The wake handler stopped the old server and immediately constructed and started a new one on the same port. System wake, display wake, and unlock all triggered this code. A failed bind leaves the extension unable to deliver updates to the intended new server. Reloading resets the Lua state and creates a new server, which is consistent with the observed recovery. The retained log verifies real bind failures; the exact stale MRU list before reload was not captured.

A new wake regression failed on this implementation: repeated recovery recreated and rebound the listener. The fix keeps the existing listening server and lets the extension reconnect if its client connection becomes stale.

## Additional reproduced delivery failure

Snapshots, previews, and heartbeats used WebSocket, but ordinary visits used separate HTTP requests. HTTP failures and unsuccessful response statuses were silently ignored. The extension could therefore retain correct local history while Hammerspoon continued displaying an older snapshot. Reloading Hammerspoon reconnected the socket and replayed the correct extension history, explaining how a reload could help without clearing any cache.

A regression with a connected socket and failing HTTP reproduced lost live delivery: visits to tabs 8, 3, and 6 produced **zero** live socket updates in the old worker. The previous tests checked the extension's local order and explicitly requested a snapshot; they did not require ordinary visits to reach Lua.

This is a verified implementation defect consistent with the report, not proof that HTTP failure caused this particular user occurrence. Pre-reload diagnostic data is still needed if the symptom returns.

## Repair

- Keep the listening server across system/display wake and unlock; only reset the UI and resume keyboard monitoring.
- Route live visits, focus changes, and removals over the existing WebSocket. Keep authenticated HTTP as a fallback with a two-second timeout.
- Use the same Lua event handler for both transports and wait for history restoration before handling startup visits.
- Reply to authenticated heartbeats. Reuse the existing five-second timer to reconnect when no valid response arrives for 15 seconds; replay history and cached previews on connection.
- Ignore close/error callbacks from replaced sockets and release obsolete heartbeat timers.
- Expose history source, update count, transport, and update age separately from connection health. No URLs, page titles, or credentials are included.

The normal browsing path now makes fewer HTTP requests. No extra idle polling timer, screenshot capture, or larger cache was added. The additional idle traffic is one small heartbeat response every five seconds.

## Validation

The previously failing wake test now passes: nine wake/display/unlock notifications, including three completed recovery cycles, do not stop or recreate the server, and subsequent visits still update MRU. The previously failing HTTP-loss test also passes. Tests also cover authenticated replies, silent-socket recovery, automatic snapshot replay, late close callbacks, HTTP fallback response handling, live Lua updates/removals, and history age remaining unchanged by a heartbeat. Existing Lua behavior, listener lifetime, preview/icon caches, and installation-generation suites pass.

## Native verification

- Installed `dist/init.lua` after backing up the previous configuration; retained the existing bridge token. The installed file matches the generated build.
- Reloaded Hammerspoon from its console and the existing unpacked extension from Edge. The extension UI reports version **1.6.1**.
- After continued normal browsing, `/status` reported **459 MRU updates**, `lastMruTransport: "websocket"`, `mruSource: "live"`, a healthy authenticated socket, an enabled keyboard tap, and zero rejected messages. This is evidence of ongoing live updates, not just a successful reconnect snapshot.
- Prepared three temporary tabs in tab-strip order A/B/C, then visited A/C/B. Automated shortcut synthesis was inconclusive. The user then pressed Option+Tab on the physical keyboard and confirmed it selected C; a subsequent Edge UI observation also showed `example.com/#mru-c`. This verifies visit order rather than tab-strip order with the installed build.

Actual system sleep/wake was not forced during the user's work. Repeated wake-event recovery is covered by the regression suite; another physical sleep/wake cycle remains a real-world validation limit.

## Reference

[Chrome's WebSocket service-worker guidance](https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets) documents keeping an extension worker active through regular WebSocket messages. The fix reuses the existing heartbeat cadence.
