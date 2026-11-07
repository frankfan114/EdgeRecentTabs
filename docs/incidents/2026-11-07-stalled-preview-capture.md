# Preview capture stuck in progress — 2026-11-07

## Observed failure

Most MRU cards displayed “Preview unavailable” while tab switching and live history continued working. Installed files matched the repository, and `/status` showed an authenticated WebSocket, zero rejected/invalid messages, and nine native cached previews.

The live service worker had `previewCaptureInFlight === true` with the last capture attempt approximately 64,152,720 milliseconds (17.8 hours) earlier. Its cache held 12 thumbnails and another tab remained queued. A separate direct `captureVisibleTab` plus thumbnail-resize probe completed successfully while the original guard stayed stuck. The original request had no stage diagnostics, so the precise browser operation that stopped returning was not recoverable.

## Cause

`captureThumbnail` held a single boolean guard through several awaited browser and image-processing calls. The guard was released only in `finally`. A promise that never settled prevented `finally` from running; every subsequent capture rescheduled behind that guard indefinitely. Healthy heartbeats and MRU updates did not detect this independent failure.

## Fix

- Apply a five-second deadline to the complete preview operation.
- Give each operation its own identity and discard expired results before they can publish or alter a newer operation.
- Retry once on timeout, preserving a newer queued visit and the normal capture throttle.
- Keep existing cached images, reject captures whose page or window changed, and release late decoded bitmaps.
- Record aggregate capture diagnostics and log the stage of a timeout without page content or credentials.

## Verification

Automated tests cover never-settling capture and decode promises, subsequent successful captures, bounded retries, queued-tab priority, late results during newer captures, navigation races, and timer cleanup. Existing JavaScript simulated-day, Lua rendering/shortcut/lifecycle, and installation-generation checks pass. These simulated checks do not represent an overnight native endurance run.

After reloading the updated extension, the live worker reported ten successful captures, zero failures/timeouts, and no operation left in flight. The actual Option+Tab panel displayed previews in all nine visible cards. The two diagnostic tabs and developer/console windows were then closed.
