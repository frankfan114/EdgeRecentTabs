# Changelog

## Unreleased

- Adapt card proportions to the available screen/window area, with wider cards in landscape layouts and taller cards in portrait layouts; resize live across displays while preserving selection.

- Remove the large switcher backdrop; use individual translucent cards with transparent gaps and a compact keyboard hint.
- Scale tab titles, site icons, and domain labels with card size, with two-line titles on larger cards and compact labels on smaller ones.
- Balance cards across centered rows, adapting to window shape and tab count while preserving MRU order and spatial arrow navigation.

- Follow macOS light/dark appearance for the Option+Tab panel, text, selection, preview backing, and number badges. Update an open panel without changing its selection or cached previews; keep 65% background opacity in both themes.

- Make the Option+Tab panel more transparent with a 65% opaque background and a softer selected-card fill; keep text, icons, and previews at full opacity.

- Preserve the local listening server through wake/unlock instead of rebinding its port; native logs showed repeated address-in-use failures before MRU froze.

- Send live tab visits through the existing WebSocket, with HTTP only as a bounded fallback; this prevents silent HTTP failures from freezing history behind a healthy socket.
- Require authenticated heartbeat replies and reconnect stalled sockets using the existing timer; restore MRU automatically on reconnection.
- Add independent history-update diagnostics and transport/recovery regressions. See the [2026-10-26 investigation](docs/incidents/2026-10-26-stale-mru-delivery.md).

- Rename the project to EdgeRecentTabs and describe its Microsoft Edge, macOS, recently used tabs, and preview features directly.
- Keep keyboard, application, and wake listeners alive across Lua garbage collection; add a lifecycle regression that fails on the previous implementation. No watchdog polling was added.
- Report keyboard tap and Secure Input state alongside bridge diagnostics.

- Document the [2026-10-24 MRU and preview incident](docs/incidents/2026-10-24-mru-preview-authentication.md), including the stale-worker credential mismatch, fallback behavior, and end-to-end recovery evidence.

- Report authenticated bridge state and cache counts at `/status`; rejected WebSocket credentials no longer mark the connection healthy.
- Check generated token scripts and MRU visit order in the regression suites.
- Reuse the existing keyboard event tap for Edge-only Option+Tab; pass keys through in other apps without global shortcut registrations.
- Commit immediately on Option release, retain the active-session watchdog, and cancel on focus loss even before app notifications arrive.
- Preserve preview limits and generate a shared private token file in both extension folders, allowing existing source-folder installations to reload in place.
- Add regression checks for focus races, native key pass-through, idle-path work, thumbnail resizing, bitmap release, and bounded caches.

## 1.6.0 — initial public baseline

- Microsoft Edge tab switcher for macOS using Hammerspoon and a local extension bridge.
- Original Option+Tab / Option+Shift+Tab hotkeys restored before the stricter focused-window implementation.
- Black overlay at 90% opacity, adaptive window sizing, site icons, previews, arrow navigation, number selection, and Escape cancellation.
- Current-window and all-windows recent-tab history with a configurable 2–25 cards.
- Existing Lua and extension-worker regression checks included.
- Installation preparation generates a private local bridge token in Git-ignored files.

Intermittent shortcut failures remain under investigation.
