-- Run with a Lua 5.4 interpreter: lua tests/test_switcher.lua ../init.lua
local configPath = arg and arg[1] or "../init.lua"
local screenFrame = { x = 0, y = 0, w = 1600, h = 1000 }
local windowFrame = { x = 100, y = 100, w = 1000, h = 700 }
local modifiers = { alt = true }
local clock = 100
local timers, sent, hotkeys = {}, {}, {}
local frontmostEdge = true
local windowOwnerEdge = true
local focusedWindowAvailable = true
local edgeApplication = { bundleID = function() return "com.microsoft.edgemac" end,
    name = function() return "Microsoft Edge" end }
local otherApplication = { bundleID = function() return "other" end,
    name = function() return "Other" end }
local screen = { frame = function() return screenFrame end }
local window = { screen = function() return screen end, frame = function() return windowFrame end,
    application = function() return windowOwnerEdge and edgeApplication or otherApplication end }
local navigationCallback, applicationCallback, httpCallback, websocketCallback, wakeCallback
local serverCreates, serverStarts, serverStops = 0, 0, 0
local frontmostReads, windowReads, tapCount = 0, 0, 0
local function object()
    return setmetatable({}, { __index = function(_, key)
        return function(self, value)
            if key == "send" then table.insert(sent, value) end
            if key == "setCallback" then httpCallback = value end
            return self
        end
    end })
end
local function timer(interval, callback)
    local t = { interval = interval, callback = callback, stopped = false }
    function t:stop() self.stopped = true end
    table.insert(timers, t)
    return t
end
local keys = { escape = 53, left = 123, right = 124, up = 126, down = 125, tab = 48, a = 0 }
for i = 1, 9 do keys[tostring(i)] = i + 60 end
local keyNames = {}
for key, code in pairs(keys) do keyNames[code] = key end
for code, key in pairs(keyNames) do keys[code] = key end
hs = {
    dockicon = { hide = function() end },
    image = { imageFromAppBundle = function() return "edge-icon" end,
        imageFromURL = function(url) return "decoded:" .. url end },
    application = { frontmostApplication = function()
        frontmostReads = frontmostReads + 1
        return frontmostEdge and edgeApplication or otherApplication
    end, watcher = { activated = 1, deactivated = 2, new = function(callback)
        applicationCallback = callback; return object()
    end } },
    timer = { secondsSinceEpoch = function() return clock end, doEvery = timer, doAfter = timer },
    window = { focusedWindow = function()
        windowReads = windowReads + 1
        if focusedWindowAvailable then return window end
    end },
    screen = { mainScreen = function() return screen end },
    canvas = { new = function(frame)
        local c = { bounds = frame }
        function c:frame(f) if f then self.bounds = f; return self end; return self.bounds end
        function c:replaceElements(elements) self.elements = elements end
        function c:elementAttribute(index, name, value) self.elements[index][name] = value end
        function c:show() self.visible = true end
        function c:hide() self.visible = false end
        function c:bringToFront() end
        return c
    end },
    eventtap = { checkKeyboardModifiers = function() return modifiers end,
        isSecureInputEnabled = function() return false end,
        event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 },
            properties = { keyboardEventAutorepeat = 1 } },
        new = function(_, callback)
            tapCount = tapCount + 1; navigationCallback = callback
            local tap = object()
            function tap:isEnabled() return true end
            return tap
        end },
    keycodes = { map = keys },
    hotkey = { new = function(mods, key, callback)
        local hotkey = { mods = mods, key = key, callback = callback, enabled = false }
        function hotkey:enable() self.enabled = true; return self end
        function hotkey:disable() self.enabled = false; return self end
        table.insert(hotkeys, hotkey)
        return hotkey
    end,
        bind = function() end },
    httpserver = { new = function()
        serverCreates = serverCreates + 1
        local server = object()
        function server:start() serverStarts = serverStarts + 1; return self end
        function server:stop() serverStops = serverStops + 1; return self end
        function server:websocket(path, callback) websocketCallback = callback; return self end
        return server
    end },
    json = { encode = function(payload) return payload end, decode = function(payload) return payload end },
    caffeinate = { watcher = { systemDidWake = 1, screensDidWake = 2, screensDidUnlock = 3,
        new = function(callback) wakeCallback = callback; return object() end } },
    alert = { show = function() end },
    osascript = { applescript = function() error("Unexpected AppleScript fallback") end },
}
local file = assert(io.open(configPath))
local source = file:read("*a"); file:close()
local testExports = [[
return {
    begin = handleOptionTab, finish = finishSwitch, payload = handleBridgePayload,
    token = BRIDGE_TOKEN,
    state = function() return switching, selectedIndex, overlay, overlayCardElements,
        overlayResizeTimer, optionReleaseTimer, recentTabs, faviconImages end,
}
]]
local tool = assert(load(source .. testExports, "@" .. configPath))()
local function fixture(count)
    tool.finish(true)
    local tabs = {}
    for i = 1, count do
        tabs[i] = { tabId = i, windowId = 1, index = i - 1,
            title = "Tab " .. i, url = "https://example.com/" .. i }
    end
    tool.payload({ type = "settings", maxTabs = count, tabScope = "current" })
    tool.payload({ type = "mruSnapshot", tabs = tabs })
    tool.payload({ type = "focusedWindow", windowId = 1 })
    modifiers.alt = true
    tool.begin(1)
end
local function event(key, eventType, flags, repeatKey)
    return navigationCallback({ getKeyCode = function() return keys[key] end,
        getType = function() return eventType or 1 end,
        getFlags = function() return flags or modifiers end,
        getProperty = function() return repeatKey and 1 or 0 end })
end
local function press(key, flags)
    local consumed = event(key, 1, flags)
    local consumedUp = event(key, 2, flags)
    return consumed, consumedUp
end
local function near(a, b) assert(math.abs(a - b) < 0.001, tostring(a) .. " != " .. tostring(b)) end
fixture(9)
local switching, selected, overlay, refs, resizeTimer, releaseTimer = tool.state()
assert(switching and selected == 2 and overlay.visible)
local consumed, consumedUp = press("9")
assert(consumed and consumedUp)
local _, index = tool.state(); assert(index == 9)
modifiers.alt = false; releaseTimer.callback()
assert(#sent == 1 and sent[1].tabId == 9)
assert(resizeTimer.stopped and releaseTimer.stopped and not overlay.visible)
fixture(9)
local before = #sent
local _, _, _, _, cancelledResize, cancelledRelease, mru = tool.state()
assert(press("escape"))
assert(not tool.state() and #sent == before and mru[1].edgeTabID == "1")
assert(cancelledResize.stopped and cancelledRelease.stopped)
modifiers.alt = false; cancelledRelease.callback(); assert(#sent == before)
assert(not press("right"), "Arrow leaked into overlay when it is closed")

fixture(9)
assert(not press("a"))
assert(not press("right", { alt = true, cmd = true }))
press("1"); press("left"); local _, last = tool.state(); assert(last == 9, "Left from first selected " .. tostring(last))
press("right"); local _, first = tool.state(); assert(first == 1)
press("up"); local _, top = tool.state(); assert(top == 1)
press("down"); local _, lower, _, grid = tool.state(); assert(grid[lower].row == grid[1].row + 1)

-- The panel responds to a resized window while preserving the chosen tab.
local _, oldIndex, panel, _, liveResize = tool.state()
windowFrame = { x = 300, y = 200, w = 600, h = 450 }
liveResize.callback()
local _, newIndex = tool.state(); assert(newIndex == oldIndex)
near(panel.bounds.w, 600 * 0.88); near(panel.bounds.h, 450 * 0.80)
near(panel.bounds.x, 300 + 600 * 0.06); near(panel.bounds.y, 200 + 450 * 0.10)

-- Exercise every supported tab count over small, wide, tall and full-size windows.
for _, size in ipairs({ {480, 320}, {700, 950}, {1300, 400}, {1600, 1000} }) do
    windowFrame = { x = 0, y = 0, w = size[1], h = size[2] }
    for count = 2, 25 do
        fixture(count)
        local _, _, canvas, cards = tool.state()
        assert(#cards == count)
        for _, element in ipairs(canvas.elements) do
            assert(element.frame.w > 0 and element.frame.h > 0)
            assert(element.frame.x >= 0 and element.frame.y >= 0)
            assert(element.frame.x + element.frame.w <= canvas.bounds.w + 0.001)
            assert(element.frame.y + element.frame.h <= canvas.bounds.h + 0.001)
        end
        for index, card in ipairs(cards) do
            press(tostring(1))
            -- Select via the real navigation path, including cards beyond 9.
            for _ = 2, index do press("right") end
            press("down")
            local _, target = tool.state()
            local best = math.huge
            for _, candidate in ipairs(cards) do
                if candidate.row == card.row + 1 then
                    best = math.min(best, math.abs(candidate.centerX - card.centerX))
                end
            end
            if best == math.huge then assert(target == index)
            else near(math.abs(cards[target].centerX - card.centerX), best) end
        end
    end
end
windowFrame = { x = -100, y = 0, w = 600, h = 500 }
fixture(5)
local _, _, clipped = tool.state()
assert(clipped.bounds.x >= 0 and clipped.bounds.x + clipped.bounds.w <= 500)

-- An asynchronously delivered favicon updates its card and ignores unknown tabs.
local _, _, iconPanel, iconRefs = tool.state()
local iconData = "data:image/png;base64,aWNvbg=="
tool.payload({ type = "favicon", tabId = 2, dataUrl = iconData })
assert(iconPanel.elements[iconRefs[2].icon].image == "decoded:" .. iconData)
tool.payload({ type = "favicon", tabId = 999, dataUrl = iconData })
local _, _, _, _, _, _, _, icons = tool.state(); assert(icons[999] == nil)
tool.payload({ type = "mruSnapshot", tabs = { { tabId = 1, windowId = 1, title = "one", url = "https://one" } } })
assert(icons[2] == nil)

frontmostEdge = false
applicationCallback("Other", 1)
assert(not tool.state() and not iconPanel.visible)

-- Option+Tab shares the single existing event tap, without global hotkeys.
assert(#hotkeys == 0 and tapCount == 1)
frontmostEdge = true
applicationCallback("Microsoft Edge", 1, edgeApplication)
fixture(9); tool.finish(true)
assert(press("tab", { alt = true }))
local open, forward = tool.state()
assert(open and forward == 2)
assert(press("tab", { alt = true, shift = true }))
local _, reverse = tool.state(); assert(reverse == 1)
assert(not press("tab", { ctrl = true }), "Control+Tab should remain native")
assert(not press("tab", { alt = true, cmd = true }))

-- Missing Accessibility results during an open session must not cancel it.
local _, _, panel, _, _, release = tool.state()
focusedWindowAvailable = false
release.callback()
assert(tool.state() and panel.visible)
assert(press("tab", { alt = true }))
focusedWindowAvailable = true
modifiers.alt = false
release.callback()
assert(not tool.state() and not panel.visible)

-- An ordinary physical Option release commits immediately, without a timer tick.
fixture(9)
local countBeforeRelease = #sent
local _, _, _, _, _, fastRelease = tool.state()
assert(not event("a", 3, {}))
assert(not tool.state() and #sent == countBeforeRelease + 1 and fastRelease.stopped)
fastRelease.callback()
assert(#sent == countBeforeRelease + 1, "Release must commit only once")

-- Other apps keep both halves of the shortcut, even without app notifications.
frontmostEdge = false
local countBeforeOther = #sent
assert(not event("tab", 1, { alt = true }))
assert(not event("tab", 2, { alt = true }))
assert(not tool.state() and #sent == countBeforeOther)
-- A missing or differently owned window must not start a new session.
frontmostEdge = true
windowOwnerEdge = false
assert(not press("tab", { alt = true }))
windowOwnerEdge = true
focusedWindowAvailable = false
assert(not press("tab", { alt = true }))
focusedWindowAvailable = true

-- Focus loss before the watcher fires cancels on release, without activating Edge.
fixture(9)
frontmostEdge = false
local beforeLostFocus = #sent
assert(not event("a", 3, {}))
assert(not tool.state() and #sent == beforeLostFocus)
frontmostEdge = true
fixture(9)
local _, _, _, _, _, lostFocusTimer = tool.state()
frontmostEdge = false
modifiers.alt = false
lostFocusTimer.callback()
assert(not tool.state() and #sent == beforeLostFocus)

-- Navigation and outstanding key-ups also pass through immediately after focus loss.
frontmostEdge = true
fixture(9)
assert(event("right", 1, { alt = true }))
frontmostEdge = false
assert(not event("right", 2, { alt = true }))
assert(not press("9", { alt = true }))
assert(not tool.state() and #sent == beforeLostFocus)

-- Edge deactivation cancels even if frontmostApplication has not updated yet.
frontmostEdge = true
fixture(9)
applicationCallback("Microsoft Edge", 2, edgeApplication)
assert(not tool.state() and #sent == beforeLostFocus)

-- Preserve one cycle per Tab press, arrow repeats, and Escape cancellation.
fixture(9); tool.finish(true)
assert(event("tab", 1, { alt = true }))
local _, once = tool.state()
assert(event("tab", 1, { alt = true }, true))
local _, stillOnce = tool.state(); assert(once == stillOnce)
assert(event("tab", 2, { alt = true }))
assert(event("right", 1, { alt = true }))
local _, firstArrow = tool.state()
assert(event("right", 1, { alt = true }, true))
local _, nextArrow = tool.state(); assert(nextArrow == firstArrow + 1)
assert(event("right", 2, { alt = true }))
assert(event("tab", 1, { alt = true }))
assert(press("escape"))
assert(event("tab", 1, { alt = true }, true) and not tool.state())
assert(event("tab", 2, { alt = true }))

-- An inactive tap allocates no timers and queries no apps/windows for ordinary keys.
local readsBefore, windowsBefore, timersBefore = frontmostReads, windowReads, #timers
local started = os.clock()
for _ = 1, 100000 do
    assert(not press("a", {}))
    assert(not event("a", 3, {}))
end
assert(frontmostReads == readsBefore and windowReads == windowsBefore and #timers == timersBefore)
print(string.format("Idle mock path: 300000 events in %.3fs; zero app/window queries or added timers", os.clock() - started))
print("Lua behavior checks passed: Edge-only shortcuts, release/focus races, pass-through, navigation, resize, and icons")

-- A connected socket with stale credentials is not a healthy extension bridge.
clock = clock + 20
local beforeStatus = httpCallback("GET", "/status")
assert(not beforeStatus.socketAuthenticated)
assert(beforeStatus.keyboardTapEnabled and not beforeStatus.secureInputEnabled)
websocketCallback({ token = "old-token", type = "heartbeat" })
local rejectedStatus = httpCallback("GET", "/status")
assert(rejectedStatus.rejectedSocketMessages == beforeStatus.rejectedSocketMessages + 1)
assert(not rejectedStatus.socketAuthenticated)
websocketCallback({ type = "heartbeat" })
assert(not httpCallback("GET", "/status").socketAuthenticated)
websocketCallback({ token = tool.token, type = "heartbeat" })
local authenticatedStatus = httpCallback("GET", "/status")
assert(authenticatedStatus.socketAuthenticated)
assert(authenticatedStatus.acceptedSocketMessages == beforeStatus.acceptedSocketMessages + 1)
assert(authenticatedStatus.lastSocketMessage == "heartbeat")
print("Bridge checks passed: authenticated health, rejected credentials, and aggregate-only diagnostics")

-- The UI retains extension visit order; authenticated activations update it.
tool.finish(true)
frontmostEdge = true
local shuffled = {}
for index, id in ipairs({ 8, 3, 6 }) do
    shuffled[index] = { tabId = id, windowId = 1, index = id - 1,
        title = "Tab " .. id, url = "https://example.com/" .. id }
end
websocketCallback({ token = tool.token, type = "mruSnapshot", tabs = shuffled })
local _, _, _, _, _, _, ordered = tool.state()
assert(ordered[1].edgeTabID == "8" and ordered[2].edgeTabID == "3" and ordered[3].edgeTabID == "6")
httpCallback("POST", "/edge-mru", {}, { token = tool.token, type = "activated",
    tabId = 6, windowId = 1, index = 5, title = "Tab 6", url = "https://example.com/6", windowFocused = true })
local _, _, _, _, _, _, updatedOrder = tool.state()
assert(updatedOrder[1].edgeTabID == "6" and updatedOrder[2].edgeTabID == "8" and updatedOrder[3].edgeTabID == "3")
print("MRU checks passed: extension order and authenticated activation updates")

-- The same live update handler serves WebSocket and the legacy HTTP fallback.
local statusBefore = httpCallback("GET", "/status")
websocketCallback({ token = tool.token, type = "activated",
    tabId = 3, windowId = 1, index = 2, title = "Tab 3", url = "https://example.com/3", windowFocused = true })
local _, _, _, _, _, _, socketOrder = tool.state()
assert(socketOrder[1].edgeTabID == "3" and socketOrder[2].edgeTabID == "6" and socketOrder[3].edgeTabID == "8")
local liveStatus = httpCallback("GET", "/status")
assert(liveStatus.mruSource == "live" and liveStatus.lastMruTransport == "websocket")
assert(liveStatus.mruUpdates == statusBefore.mruUpdates + 1 and liveStatus.lastMruUpdateAgeSeconds == 0)
clock = clock + 7
local ack = websocketCallback({ token = tool.token, type = "heartbeat" })
assert(ack.type == "heartbeatAck" and ack.token == tool.token)
local heartbeatStatus = httpCallback("GET", "/status")
assert(heartbeatStatus.mruUpdates == liveStatus.mruUpdates and heartbeatStatus.lastMruUpdateAgeSeconds == 7,
    "A heartbeat must not pretend that tab history was updated")
assert(websocketCallback({ token = "old-token", type = "heartbeat" }) == "")
websocketCallback({ token = tool.token, type = "removed", tabId = 6 })
local _, _, _, _, _, _, afterRemoval = tool.state()
assert(#afterRemoval == 2 and afterRemoval[1].edgeTabID == "3" and afterRemoval[2].edgeTabID == "8")
print("Live MRU checks passed: socket updates/removals, authenticated heartbeat replies, and independent history freshness")

-- Sleep, display wake and unlock can arrive in a burst. Keep the listening socket
-- instead of stop/start races that produce "Address already in use" on native macOS.
local createsBeforeWake, startsBeforeWake, stopsBeforeWake = serverCreates, serverStarts, serverStops
for _ = 1, 3 do
    for _, wakeEvent in ipairs({ 1, 2, 3 }) do wakeCallback(wakeEvent) end
    timers[#timers].callback()
end
assert(serverCreates == createsBeforeWake and serverStarts == startsBeforeWake and serverStops == stopsBeforeWake,
    "Wake recovery must retain the server instead of rebinding its port")
websocketCallback({ token = tool.token, type = "activated", tabId = 8, windowId = 1,
    title = "Tab 8", url = "https://example.com/8", windowFocused = true })
local _, _, _, _, _, _, afterWake = tool.state()
assert(afterWake[1].edgeTabID == "8", "Live history must still update after repeated wake events")
print("Wake checks passed: retain one listening server through repeated sleep/display/unlock events")
