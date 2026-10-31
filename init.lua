------------------------------------------------------------
-- EdgeRecentTabs
-- Window-scoped MRU + cached previews + wake recovery
------------------------------------------------------------

hs.dockicon.hide()

------------------------------------------------------------
-- Config
------------------------------------------------------------

local MAX_TABS = 9
local MIN_TABS = 2
local HISTORY_LIMIT = 100
local PREVIEW_CACHE_LIMIT = 50
local FAVICON_CACHE_LIMIT = 100
local TAB_SCOPE = "current" -- "current" or "all"
local OVERLAY_WINDOW_WIDTH = 0.88
local OVERLAY_WINDOW_HEIGHT = 0.80
local CARD_BACKGROUND_ALPHA = 0.65
local SELECTED_CARD_ALPHA = 0.16

local BRIDGE_PORT = 27123
local BRIDGE_TOKEN = "__EDGE_MRU_LOCAL_TOKEN__"
local BRIDGE_HEALTH_SECONDS = 12

------------------------------------------------------------
-- State
------------------------------------------------------------

local recentTabs = {}
local previewImages = {}
local previewLastUsed = {}
local previewUseSerial = 0
local activeEdgeWindowID = nil
local faviconImages = {}
local fallbackIcon = hs.image.imageFromAppBundle("com.microsoft.edgemac")

local switching = false
local switchChoices = {}
local selectedIndex = 1

local overlay = nil
local overlayTheme = nil
local overlayCardElements = {}
local overlayItemCount = 0
local overlayHostWindow = nil
local overlayResizeTimer = nil
local navigationTap = nil
local swallowedKeys = {}

local optionReleaseTimer = nil
local appWatcher = nil
local wakeWatcher = nil
local wakeRecoveryTimer = nil

local bridgeServer = nil
local bridgeSocketLastSeen = 0
local bridgeDiagnostics = { accepted = 0, rejected = 0, invalid = 0, lastType = "" }
local pendingSwitch = nil
local pendingSwitchTimer = nil
local requestCounter = 0
local restoredMruSnapshot = false
local mruDiagnostics = { updates = 0, lastUpdateAt = 0, lastTransport = "", source = "empty" }
local seedTask = nil

local US = string.char(31)
local RS = string.char(30)

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function cleanText(s)
    s = tostring(s or "")
    s = s:gsub("\r", " ")
    s = s:gsub("\n", " ")
    return s
end

local function splitPlain(str, sep)
    local out = {}
    local start = 1
    while true do
        local i, j = string.find(str, sep, start, true)
        if not i then
            table.insert(out, string.sub(str, start))
            break
        end
        table.insert(out, string.sub(str, start, i - 1))
        start = j + 1
    end
    return out
end

local function edgeIsFrontmost()
    local app = hs.application.frontmostApplication()
    if not app then return false end
    return app:bundleID() == "com.microsoft.edgemac"
        or app:name() == "Microsoft Edge"
end

local function nowSeconds()
    return hs.timer.secondsSinceEpoch()
end

local function makeKey(tab)
    if tab.edgeTabID and tostring(tab.edgeTabID) ~= "" then
        return "edge:" .. tostring(tab.edgeTabID)
    end
    return tostring(tab.url or "") .. "\n" .. tostring(tab.text or "")
end

local function normalizeTab(tab)
    if not tab then return nil end
    tab.edgeTabID = tab.edgeTabID and tostring(tab.edgeTabID) or nil
    tab.edgeWindowID = tab.edgeWindowID and tostring(tab.edgeWindowID) or nil
    tab.edgeIndex = tonumber(tab.edgeIndex)
    tab.text = cleanText(tab.text)
    tab.subText = cleanText(tab.subText)
    tab.url = cleanText(tab.url)
    tab.key = makeKey(tab)
    return tab
end

------------------------------------------------------------
-- MRU
--
-- A single chronological list is retained, but each entry carries the
-- Chromium windowId. Filtering by window preserves each window's own MRU
-- order while also supporting an optional all-windows mode.
------------------------------------------------------------

local function recordMruUpdate(source, transport)
    mruDiagnostics.updates = mruDiagnostics.updates + 1
    mruDiagnostics.lastUpdateAt = hs.timer.secondsSinceEpoch()
    mruDiagnostics.lastTransport = transport
    mruDiagnostics.source = source
end

local function bumpRecent(tab)
    tab = normalizeTab(tab)
    if not tab then return end

    local newList = { tab }

    for _, oldTab in ipairs(recentTabs) do
        local sameTab = oldTab.key == tab.key

        if not sameTab
            and tab.edgeTabID
            and not oldTab.edgeTabID
            and oldTab.url == tab.url
            and oldTab.text == tab.text
        then
            sameTab = true
        end

        if not sameTab then
            table.insert(newList, oldTab)
            if #newList >= HISTORY_LIMIT then break end
        end
    end

    recentTabs = newList
end

local function removeEdgeTab(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" then return end

    local newList = {}
    for _, tab in ipairs(recentTabs) do
        if tostring(tab.edgeTabID or "") ~= edgeTabID then
            table.insert(newList, tab)
        end
    end
    recentTabs = newList
    previewImages[edgeTabID] = nil
    previewLastUsed[edgeTabID] = nil
    faviconImages[edgeTabID] = nil
end

local function applyMruSnapshot(items)
    if type(items) ~= "table" then return end

    local restored = {}
    for _, item in ipairs(items) do
        if type(item) == "table" then
            local tab = normalizeTab({
                edgeTabID = item.tabId,
                edgeWindowID = item.windowId,
                edgeIndex = item.index,
                text = item.title ~= "" and item.title or item.url,
                subText = item.url,
                url = item.url,
            })
            if tab and tab.edgeTabID and tab.url ~= "" then
                table.insert(restored, tab)
                if #restored >= HISTORY_LIMIT then break end
            end
        end
    end

    if #restored > 0 then
        recentTabs = restored
        restoredMruSnapshot = true

        local keep = {}
        for _, tab in ipairs(restored) do
            if tab.edgeTabID then keep[tab.edgeTabID] = true end
        end
        for tabId, _ in pairs(previewImages) do
            if not keep[tabId] then
                previewImages[tabId] = nil
                previewLastUsed[tabId] = nil
            end
        end
        for tabId, _ in pairs(faviconImages) do
            if not keep[tabId] then faviconImages[tabId] = nil end
        end
    end
end

local function choicesForCurrentScope()
    local out = {}

    for _, tab in ipairs(recentTabs) do
        local include = true

        if TAB_SCOPE == "current" and activeEdgeWindowID then
            include = tostring(tab.edgeWindowID or "") == tostring(activeEdgeWindowID)
        end

        if include then
            table.insert(out, tab)
            if #out >= MAX_TABS then break end
        end
    end

    -- During the brief startup window before the extension has restored
    -- Chromium windowIds, legacy AppleScript seed rows cannot be mapped to a
    -- Chrome window. Fall back to global MRU rather than making the hotkey dead.
    if #out == 0 and TAB_SCOPE == "current" and #recentTabs > 0 then
        for i = 1, math.min(#recentTabs, MAX_TABS) do
            table.insert(out, recentTabs[i])
        end
    end

    return out
end

------------------------------------------------------------
-- Preview cache
--
-- Keep a hard LRU bound in Hammerspoon as well as in the Edge extension.
-- This prevents decoded hs.image objects from accumulating indefinitely
-- during very long browser sessions with many distinct Chromium tabIds.
------------------------------------------------------------

local function touchPreview(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" or not previewImages[edgeTabID] then return end

    previewUseSerial = previewUseSerial + 1
    previewLastUsed[edgeTabID] = previewUseSerial
end

local function trimPreviewCache()
    local count = 0
    for _ in pairs(previewImages) do count = count + 1 end

    while count > PREVIEW_CACHE_LIMIT do
        local oldestTabID = nil
        local oldestUse = math.huge

        for tabId, _ in pairs(previewImages) do
            local used = previewLastUsed[tabId] or 0
            if used < oldestUse then
                oldestUse = used
                oldestTabID = tabId
            end
        end

        if not oldestTabID then break end

        previewImages[oldestTabID] = nil
        previewLastUsed[oldestTabID] = nil
        count = count - 1
    end
end

local function getPreviewImage(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" then return nil end

    local image = previewImages[edgeTabID]
    if image then touchPreview(edgeTabID) end
    return image
end

local function applyThumbnail(edgeTabID, dataUrl)
    edgeTabID = tostring(edgeTabID or "")
    dataUrl = tostring(dataUrl or "")
    if edgeTabID == "" or dataUrl == "" then return end

    local ok, image = pcall(hs.image.imageFromURL, dataUrl)
    if not ok or not image then return end

    previewImages[edgeTabID] = image
    touchPreview(edgeTabID)
    trimPreviewCache()

    if overlay and switching then
        for i, tab in ipairs(switchChoices) do
            if tostring(tab.edgeTabID or "") == edgeTabID then
                local refs = overlayCardElements[i]
                if refs and refs.preview then
                    overlay:elementAttribute(refs.preview, "image", image)
                    overlay:elementAttribute(refs.preview, "imageAlpha", 1.0)
                    if refs.placeholder then
                        overlay:elementAttribute(refs.placeholder, "text", "")
                    end
                end
                break
            end
        end
    end
end

------------------------------------------------------------
-- Site icon cache
------------------------------------------------------------

local function applyFavicon(edgeTabID, dataUrl)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" or type(dataUrl) ~= "string"
        or not dataUrl:match("^data:image/png;base64,") or #dataUrl > 90000
    then return end

    local known = false
    for _, tab in ipairs(recentTabs) do
        if tostring(tab.edgeTabID or "") == edgeTabID then known = true; break end
    end
    if not known then return end
    local cached = faviconImages[edgeTabID]
    if cached and cached.dataUrl == dataUrl then return end
    local ok, image = pcall(hs.image.imageFromURL, dataUrl)
    if not ok or not image then return end
    faviconImages[edgeTabID] = { image = image, dataUrl = dataUrl }

    local count = 0
    for _ in pairs(faviconImages) do count = count + 1 end
    if count > FAVICON_CACHE_LIMIT then
        for id, _ in pairs(faviconImages) do
            if id ~= edgeTabID then faviconImages[id] = nil; break end
        end
    end
    if overlay and switching then
        for i, tab in ipairs(switchChoices) do
            if tostring(tab.edgeTabID or "") == edgeTabID then
                local refs = overlayCardElements[i]
                if refs and refs.icon then
                    overlay:elementAttribute(refs.icon, "image", image)
                    overlay:elementAttribute(refs.icon, "imageAlpha", 1.0)
                end
                break
            end
        end
    end
end

------------------------------------------------------------
-- AppleScript fallback
------------------------------------------------------------

local function appleScriptString(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", " ")
    s = s:gsub("\n", " ")
    return '"' .. s .. '"'
end

local function activateEdgeTabFallback(choice)
    if not choice then return end

    local targetURL = appleScriptString(choice.url)
    local targetTitle = appleScriptString(choice.text)

    local script = string.format([[
tell application "Microsoft Edge"
    set targetURL to %s
    set targetTitle to %s

    repeat with w in windows
        repeat with i from 1 to count of tabs of w
            set t to tab i of w
            if (URL of t as text) = targetURL then
                if (title of t as text) = targetTitle then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return true
                end if
            end if
        end repeat
    end repeat

    repeat with w in windows
        repeat with i from 1 to count of tabs of w
            set t to tab i of w
            if (URL of t as text) = targetURL then
                set active tab index of w to i
                set index of w to 1
                activate
                return true
            end if
        end repeat
    end repeat

    return false
end tell
]], targetURL, targetTitle)

    local ok, _, err = hs.osascript.applescript(script)
    if not ok then
        print("Edge MRU fallback switch failed: " .. hs.inspect(err))
    end
end

------------------------------------------------------------
-- Bridge
------------------------------------------------------------

local function bridgeHeaders()
    return {
        ["Content-Type"] = "text/plain; charset=utf-8",
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type",
        ["Access-Control-Allow-Private-Network"] = "true",
    }
end

local function clearPendingSwitch()
    if pendingSwitchTimer then
        pendingSwitchTimer:stop()
        pendingSwitchTimer = nil
    end
    pendingSwitch = nil
end

local function bridgeSocketIsReady()
    return bridgeSocketLastSeen > 0
        and (nowSeconds() - bridgeSocketLastSeen) <= BRIDGE_HEALTH_SECONDS
        and bridgeServer ~= nil
end

local function sendSocket(payload)
    if not bridgeServer then return false end
    local ok, encoded = pcall(hs.json.encode, payload)
    if not ok then return false end
    local sent = pcall(function() bridgeServer:send(encoded) end)
    return sent
end

local function activateEdgeTab(choice)
    if not choice then return end
    bumpRecent(choice)

    if choice.edgeWindowID then
        activeEdgeWindowID = tostring(choice.edgeWindowID)
    end

    if choice.edgeTabID and bridgeSocketIsReady() then
        requestCounter = requestCounter + 1
        local requestId = tostring(requestCounter) .. "-" .. tostring(math.floor(nowSeconds() * 1000))

        clearPendingSwitch()
        pendingSwitch = {
            requestId = requestId,
            choice = choice,
        }

        local ok = sendSocket({
            type = "switchTab",
            token = BRIDGE_TOKEN,
            requestId = requestId,
            tabId = tonumber(choice.edgeTabID),
            windowId = tonumber(choice.edgeWindowID),
        })

        if ok then
            pendingSwitchTimer = hs.timer.doAfter(0.25, function()
                if pendingSwitch and pendingSwitch.requestId == requestId then
                    local fallbackChoice = pendingSwitch.choice
                    clearPendingSwitch()
                    activateEdgeTabFallback(fallbackChoice)
                end
            end)
            return
        end
    end

    activateEdgeTabFallback(choice)
end

local function applySettings(payload)
    local maxTabs = tonumber(payload.maxTabs)
    if maxTabs then
        maxTabs = math.floor(maxTabs)
        if maxTabs < MIN_TABS then maxTabs = MIN_TABS end
        if maxTabs > 25 then maxTabs = 25 end
        MAX_TABS = maxTabs
    end

    local scope = tostring(payload.tabScope or "")
    if scope == "current" or scope == "all" then
        TAB_SCOPE = scope
    end
end

local function handleBridgePayload(payload, transport)
    if type(payload) ~= "table" then return end

    if payload.type == "removed" then
        removeEdgeTab(payload.tabId)
        recordMruUpdate("live", transport)
        return
    end

    if payload.type == "activated" or payload.type == "updated" or payload.type == "focusChanged" then
        local url = cleanText(payload.url)
        if url == "" then return end
        local title = cleanText(payload.title)
        local tab = {
            edgeTabID = tostring(payload.tabId or ""),
            edgeWindowID = tostring(payload.windowId or ""),
            edgeIndex = tonumber(payload.index),
            text = title ~= "" and title or url,
            subText = url,
            url = url,
        }
        bumpRecent(tab)
        recordMruUpdate("live", transport)
        if payload.windowFocused == true or payload.type == "focusChanged" then
            activeEdgeWindowID = tab.edgeWindowID
        end
        return
    end

    if payload.type == "heartbeat" then
        bridgeSocketLastSeen = nowSeconds()
        return
    end

    if payload.type == "focusedWindow" then
        bridgeSocketLastSeen = nowSeconds()
        local id = tostring(payload.windowId or "")
        if id ~= "" and id ~= "-1" then activeEdgeWindowID = id end
        return
    end

    if payload.type == "settings" then
        bridgeSocketLastSeen = nowSeconds()
        applySettings(payload)
        return
    end

    if payload.type == "mruSnapshot" then
        bridgeSocketLastSeen = nowSeconds()
        applyMruSnapshot(payload.tabs)
        recordMruUpdate("snapshot", transport)
        return
    end

    if payload.type == "thumbnail" then
        bridgeSocketLastSeen = nowSeconds()
        applyThumbnail(payload.tabId, payload.dataUrl)
        return
    end

    if payload.type == "favicon" then
        bridgeSocketLastSeen = nowSeconds()
        applyFavicon(payload.tabId, payload.dataUrl)
        return
    end

    if payload.type == "switchResult" then
        bridgeSocketLastSeen = nowSeconds()
        if pendingSwitch
            and tostring(payload.requestId or "") == tostring(pendingSwitch.requestId or "")
        then
            local choice = pendingSwitch.choice
            local success = payload.ok == true
            clearPendingSwitch()
            if not success then activateEdgeTabFallback(choice) end
        end
        return
    end
end

local function startBridge()
    if bridgeServer then
        bridgeServer:stop()
        bridgeServer = nil
    end

    bridgeSocketLastSeen = 0

    bridgeServer = hs.httpserver.new(false, false)
    bridgeServer:maxBodySize(10 * 1024 * 1024)
    bridgeServer:setInterface("127.0.0.1")
    bridgeServer:setPort(BRIDGE_PORT)

    bridgeServer:setCallback(function(method, path, headers, body)
        if method == "OPTIONS" then
            return "", 204, bridgeHeaders()
        end

        if method == "GET" and path == "/health" then
            return "edge-mru-ok", 200, bridgeHeaders()
        end

        if method == "GET" and path == "/status" then
            local previewCount = 0
            for _ in pairs(previewImages) do previewCount = previewCount + 1 end
            local headers = bridgeHeaders()
            headers["Content-Type"] = "application/json"
            return hs.json.encode({
                socketAuthenticated = bridgeSocketIsReady(),
                keyboardTapEnabled = EdgeRecentTabs ~= nil
                    and EdgeRecentTabs.navigationTap:isEnabled() or false,
                secureInputEnabled = hs.eventtap.isSecureInputEnabled(),
                acceptedSocketMessages = bridgeDiagnostics.accepted,
                rejectedSocketMessages = bridgeDiagnostics.rejected,
                invalidSocketMessages = bridgeDiagnostics.invalid,
                lastSocketMessage = bridgeDiagnostics.lastType,
                receivedMruSnapshot = restoredMruSnapshot,
                mruSource = mruDiagnostics.source,
                mruUpdates = mruDiagnostics.updates,
                lastMruTransport = mruDiagnostics.lastTransport,
                lastMruUpdateAgeSeconds = mruDiagnostics.lastUpdateAt > 0
                    and math.max(0, nowSeconds() - mruDiagnostics.lastUpdateAt) or -1,
                recentTabCount = #recentTabs,
                previewCount = previewCount,
            }), 200, headers
        end

        if method ~= "POST" or path ~= "/edge-mru" then
            return "not found", 404, bridgeHeaders()
        end

        local ok, payload = pcall(hs.json.decode, body or "")
        if not ok or type(payload) ~= "table" then
            return "bad json", 400, bridgeHeaders()
        end

        if payload.token ~= BRIDGE_TOKEN then
            return "forbidden", 403, bridgeHeaders()
        end

        -- Keep the HTTP fallback compatible with older extension workers.
        handleBridgePayload(payload, "http")
        return "ok", 200, bridgeHeaders()
    end)

    bridgeServer:websocket("/ws", function(message)
        local ok, payload = pcall(hs.json.decode, message or "")
        if not ok or type(payload) ~= "table" then
            bridgeDiagnostics.invalid = bridgeDiagnostics.invalid + 1
        elseif payload.token ~= BRIDGE_TOKEN then
            bridgeDiagnostics.rejected = bridgeDiagnostics.rejected + 1
        else
            bridgeDiagnostics.accepted = bridgeDiagnostics.accepted + 1
            bridgeDiagnostics.lastType = tostring(payload.type or "")
            handleBridgePayload(payload, "websocket")
            if payload.type == "heartbeat" then
                return hs.json.encode({ type = "heartbeatAck", token = BRIDGE_TOKEN })
            end
        end
        return ""
    end)

    bridgeServer:start()
end

------------------------------------------------------------
-- AppleScript seed fallback
------------------------------------------------------------

local seedScript = [[
tell application "Microsoft Edge"
    set unitSep to ASCII character 31
    set recordSep to ASCII character 30
    set outputText to ""

    if (count of windows) is 0 then return outputText

    set maxTabs to 25
    set addedCount to 0

    repeat with w in windows
        if addedCount >= maxTabs then exit repeat
        set windowID to id of w
        set tabCount to count of tabs of w

        repeat with ti from 1 to tabCount
            if addedCount >= maxTabs then exit repeat
            set t to tab ti of w
            set outputText to outputText ¬
                & (windowID as text) & unitSep ¬
                & (ti as text) & unitSep ¬
                & (title of t as text) & unitSep ¬
                & (URL of t as text) & recordSep
            set addedCount to addedCount + 1
        end repeat
    end repeat

    return outputText
end tell
]]

local function seedRecentTabs()
    if restoredMruSnapshot then return end
    if seedTask and seedTask:isRunning() then return end

    seedTask = hs.task.new("/usr/bin/osascript", function(exitCode, stdout, stderr)
        seedTask = nil
        if restoredMruSnapshot or exitCode ~= 0 then return end

        local found = {}
        for _, record in ipairs(splitPlain(stdout or "", RS)) do
            local fields = splitPlain(record, US)
            if #fields >= 4 and cleanText(fields[4]) ~= "" then
                table.insert(found, normalizeTab({
                    windowID = tonumber(fields[1]),
                    tabIndex = tonumber(fields[2]),
                    text = cleanText(fields[3]),
                    subText = cleanText(fields[4]),
                    url = cleanText(fields[4]),
                }))
            end
        end

        if #found > 0 and not restoredMruSnapshot then
            recentTabs = found
            mruDiagnostics.source = "tab-strip-fallback"
        end
    end, { "-e", seedScript })

    if seedTask then seedTask:start() end
end

------------------------------------------------------------
-- UI helpers
------------------------------------------------------------

local OVERLAY_THEMES = {
    Dark = { background = 0.0, foreground = 1.0 },
    Light = { background = 1.0, foreground = 0.0 },
}

local function currentOverlayTheme()
    -- Hammerspoon returns nil for the default (light) macOS appearance.
    return hs.host.interfaceStyle() == "Dark" and OVERLAY_THEMES.Dark or OVERLAY_THEMES.Light
end

local function hideOverlay()
    if overlay then overlay:hide() end
end

local function deleteOverlay()
    if overlay then
        overlay:hide()
        overlay:delete()
        overlay = nil
    end
    overlayCardElements = {}
    overlayItemCount = 0
end

local function domainFromURL(url)
    url = tostring(url or "")
    local domain = url:match("^https?://([^/]+)")
    if domain then return domain:gsub("^www%.", "") end
    if url:match("^file://") then return "Local file" end
    if url:match("^edge://") then return "Microsoft Edge" end
    return url
end

local function cardFillColor(selected)
    local tint = selected and SELECTED_CARD_ALPHA or 0.0
    return { white = overlayTheme.background * (1 - tint) + overlayTheme.foreground * tint,
        alpha = CARD_BACKGROUND_ALPHA }
end

local function cardStrokeColor(selected)
    return { white = overlayTheme.foreground, alpha = selected and 1.0 or 0.35 }
end

local function cardStrokeWidth(selected)
    return selected and 3.0 or 1.0
end

local function setCardSelected(index, selected)
    if not overlay then return end
    local refs = overlayCardElements[index]
    if not refs then return end

    overlay:elementAttribute(refs.rect, "fillColor", cardFillColor(selected))
    overlay:elementAttribute(refs.rect, "strokeColor", cardStrokeColor(selected))
    overlay:elementAttribute(refs.rect, "strokeWidth", cardStrokeWidth(selected))
end

local function updateOverlaySelection(oldIndex, newIndex)
    if oldIndex == newIndex then return end
    if oldIndex and oldIndex >= 1 and oldIndex <= overlayItemCount then
        setCardSelected(oldIndex, false)
    end
    if newIndex and newIndex >= 1 and newIndex <= overlayItemCount then
        setCardSelected(newIndex, true)
    end
end

local function overlayFrameForWindow()
    local win = overlayHostWindow or hs.window.focusedWindow()
    local screen = win and win:screen() or hs.screen.mainScreen()
    screen = screen or hs.screen.mainScreen()
    local sf = screen:frame()
    local wf = win and win:frame() or sf
    -- Keep the panel inside the visible part of a window spanning monitors.
    local left = math.max(wf.x, sf.x)
    local top = math.max(wf.y, sf.y)
    local right = math.min(wf.x + wf.w, sf.x + sf.w)
    local bottom = math.min(wf.y + wf.h, sf.y + sf.h)
    if right <= left or bottom <= top then
        left, top, right, bottom = sf.x, sf.y, sf.x + sf.w, sf.y + sf.h
    end
    local width = (right - left) * OVERLAY_WINDOW_WIDTH
    local height = (bottom - top) * OVERLAY_WINDOW_HEIGHT
    return { x = left + (right - left - width) / 2,
        y = top + (bottom - top - height) / 2, w = width, h = height }
end

-- Balance every row while keeping MRU order and similarly sized previews.
local function layoutCards(count, width, height, gapX, gapY)
    -- Use the same fraction of the available width and height. Percentage gaps
    -- and a dimensionless score keep card sizes proportional on every resize.
    local targetAspect = width / height
    local best, bestScore = nil, math.huge
    for rows = 1, count do
        local columns = math.ceil(count / rows)
        local cardW = (width - gapX * (columns - 1)) / columns
        local cardH = (height - gapY * (rows - 1)) / rows
        if cardW > 0 and cardH > 0 then
            cardW = math.min(cardW, cardH * targetAspect)
            cardH = math.min(cardH, cardW / targetAspect)
            local coverage = count * cardW * cardH / (width * height)
            local score = 1 - coverage
            -- Keep the first (fewest-row) layout on ties, including rounding noise.
            if score < bestScore - 0.000001 then
                bestScore = score
                best = { rows = rows, w = cardW, h = cardH }
            end
        end
    end
    local frames = {}
    local stackH = best.rows * best.h + (best.rows - 1) * gapY
    for row = 0, best.rows - 1 do
        local inRow = math.floor(count / best.rows) + (row < count % best.rows and 1 or 0)
        local rowW = inRow * best.w + (inRow - 1) * gapX
        for column = 0, inRow - 1 do
            frames[#frames + 1] = { x = (width - rowW) / 2 + column * (best.w + gapX),
                y = (height - stackH) / 2 + row * (best.h + gapY),
                w = best.w, h = best.h, row = row }
        end
    end
    return frames, (height + stackH) / 2
end

local function showOverlay()
    if #switchChoices == 0 then return end

    overlayTheme = currentOverlayTheme()
    local frame = overlayFrameForWindow()
    local width, height = frame.w, frame.h

    local itemCount = math.min(#switchChoices, MAX_TABS)
    local padX, padY = width * 0.02, height * 0.02
    local footerH = height * 0.055
    local gapX, gapY = width * 0.018, height * 0.018

    if not overlay then overlay = hs.canvas.new(frame) else overlay:frame(frame) end

    local usableW = width - padX * 2
    local usableH = height - padY * 2 - footerH - gapY
    local layout, stackBottom = layoutCards(itemCount, usableW, usableH, gapX, gapY)
    local elements = {}
    overlayCardElements = {}
    overlayItemCount = itemCount

    -- Only individual cards are painted; the space between them stays transparent.
    for i = 1, itemCount do
        local tab = switchChoices[i]
        local placement = layout[i]
        local cx, cy = padX + placement.x, padY + placement.y
        local cardW, cardH = placement.w, placement.h
        local row = placement.row
        local selected = i == selectedIndex

        local rectIndex = #elements + 1
        table.insert(elements, {
            type = "rectangle",
            action = "strokeAndFill",
            frame = { x = cx, y = cy, w = cardW, h = cardH },
            roundedRectRadii = { xRadius = 9, yRadius = 9 },
            fillColor = cardFillColor(selected),
            strokeColor = cardStrokeColor(selected),
            strokeWidth = cardStrokeWidth(selected),
        })

        local previewInset = math.min(6, cardW * 0.03, cardH * 0.03)
        local textPad = math.min(14, cardW * 0.045)
        local titleSize = math.min(26, math.max(9, math.min(cardW * 0.055, cardH * 0.10)))
        local titleLines = cardH >= 180 and cardW >= 220 and 2 or 1
        local domainSize = math.min(14, math.max(8, titleSize * 0.68))
        local domainH = cardH >= 100 and domainSize * 1.4 or 0
        local titleH = titleSize * 1.35 * titleLines
        local textGap = math.min(5, cardH * 0.02)
        local metaHeight = titleH + domainH + textGap * 3
        local previewH = math.max(1, cardH - metaHeight - previewInset * 2)
        local previewFrame = {
            x = cx + previewInset,
            y = cy + previewInset,
            w = math.max(1, cardW - previewInset * 2),
            h = previewH,
        }

        table.insert(elements, {
            type = "rectangle",
            action = "fill",
            frame = previewFrame,
            roundedRectRadii = { xRadius = 7, yRadius = 7 },
            -- Translucent themed backing for the preview area. This remains
            -- visible around letterboxed images and when no preview exists.
            fillColor = { white = overlayTheme.background, alpha = 0.22 },
        })

        local edgeTabID = tostring(tab.edgeTabID or "")
        local previewImage = getPreviewImage(edgeTabID)

        local previewIndex = #elements + 1
        table.insert(elements, {
            type = "image",
            frame = previewFrame,
            image = previewImage,
            imageScaling = "scaleProportionally",
            imageAlignment = "center",
            imageAlpha = previewImage and 1.0 or 0.0,
        })

        local placeholderIndex = #elements + 1
        table.insert(elements, {
            type = "text",
            frame = previewFrame,
            text = previewImage and "" or "Preview unavailable",
            textSize = math.max(9, math.min(12, cardH * 0.065)),
            textAlignment = "center",
            textColor = { white = overlayTheme.foreground, alpha = 1.0 },
        })

        local titleY = cy + previewInset + previewH + textGap
        local domainY = titleY + titleH + textGap
        local iconSize = math.min(24, titleSize * 1.2)
        local favicon = faviconImages[tostring(tab.edgeTabID or "")]
        local icon = favicon and favicon.image or fallbackIcon
        local iconIndex = #elements + 1
        table.insert(elements, {
            type = "image",
            frame = { x = cx + textPad, y = titleY, w = iconSize, h = iconSize },
            image = icon,
            imageAlpha = icon and 1.0 or 0.0,
            imageScaling = "scaleProportionally",
            imageAlignment = "center",
        })

        local titleIndex = #elements + 1
        table.insert(elements, {
            type = "text",
            frame = { x = cx + textPad + iconSize + textGap, y = titleY,
                w = math.max(1, cardW - textPad * 2 - iconSize - textGap), h = titleH },
            text = tab.text,
            textSize = titleSize,
            textColor = { white = overlayTheme.foreground, alpha = 1.0 },
            textLineBreak = titleLines == 2 and "wordWrap" or "truncateTail",
        })

        if domainH > 0 then
            table.insert(elements, {
                type = "text",
                frame = { x = cx + textPad, y = domainY, w = cardW - textPad * 2, h = domainH },
                text = domainFromURL(tab.url),
                textSize = domainSize,
                textColor = { white = overlayTheme.foreground, alpha = 1.0 },
                textLineBreak = "truncateMiddle",
            })
        end

        table.insert(elements, {
            type = "rectangle",
            action = "strokeAndFill",
            frame = { x = cx + 9, y = cy + 9, w = 23, h = 18 },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            fillColor = { white = overlayTheme.foreground, alpha = 0.72 },
            strokeColor = { white = overlayTheme.background, alpha = 1.0 },
            strokeWidth = 1,
        })

        table.insert(elements, {
            type = "text",
            frame = { x = cx + 9, y = cy + 9, w = 23, h = 17 },
            text = tostring(i),
            textSize = 9,
            textAlignment = "center",
            textColor = { white = overlayTheme.background, alpha = 1.0 },
        })

        overlayCardElements[i] = {
            rect = rectIndex,
            preview = previewIndex,
            placeholder = placeholderIndex,
            title = titleIndex,
            icon = iconIndex,
            row = row,
            centerX = cx + cardW / 2,
        }
    end

    local footerW = math.min(usableW, 360)
    local footerY = padY + stackBottom + gapY
    table.insert(elements, {
        type = "rectangle", action = "fill",
        frame = { x = (width - footerW) / 2, y = footerY, w = footerW, h = footerH },
        roundedRectRadii = { xRadius = footerH / 2, yRadius = footerH / 2 },
        fillColor = { white = overlayTheme.background, alpha = CARD_BACKGROUND_ALPHA },
    })
    table.insert(elements, {
        type = "text",
        frame = { x = (width - footerW) / 2 + 6, y = footerY + 3,
            w = footerW - 12, h = footerH - 3 },
        text = "Hold ⌥ · Tab / arrows · 1–9 select · Esc cancel",
        textSize = math.max(8, math.min(11, footerW / 33)),
        textAlignment = "center",
        textLineBreak = "truncateTail",
        textColor = { white = overlayTheme.foreground, alpha = 1.0 },
    })

    overlay:replaceElements(elements)
    overlay:show()
    overlay:bringToFront(true)
end

local function watchOverlayResize()
    if overlayResizeTimer then return end
    overlayResizeTimer = hs.timer.doEvery(0.10, function()
        if not switching or not overlay then return end
        local frame = overlayFrameForWindow()
        local current = overlay:frame()
        -- Reuse the active-panel timer so appearance changes need no idle polling.
        if overlayTheme ~= currentOverlayTheme()
            or math.abs(frame.x - current.x) > 1 or math.abs(frame.y - current.y) > 1
            or math.abs(frame.w - current.w) > 1 or math.abs(frame.h - current.h) > 1
        then showOverlay() end
    end)
end

------------------------------------------------------------
-- Switching
------------------------------------------------------------

local function beginOrCycle(direction, hostWindow)
    if not switching then
        switchChoices = choicesForCurrentScope()

        if #switchChoices == 0 then
            hs.alert.show(TAB_SCOPE == "current"
                and "No recent tabs for this Edge window"
                or "No recent Edge tabs")
            return
        end

        switching = true
        overlayHostWindow = hostWindow

        if direction > 0 then
            selectedIndex = #switchChoices > 1 and 2 or 1
        else
            selectedIndex = #switchChoices
        end

        showOverlay()
        watchOverlayResize()
        return
    end

    local oldIndex = selectedIndex
    selectedIndex = selectedIndex + direction
    if selectedIndex > #switchChoices then selectedIndex = 1 end
    if selectedIndex < 1 then selectedIndex = #switchChoices end
    updateOverlaySelection(oldIndex, selectedIndex)
end

local function finishSwitch(cancelled)
    if not switching then return end

    local choice = selectedIndex and switchChoices[selectedIndex] or nil
    switching = false

    if optionReleaseTimer then
        optionReleaseTimer:stop()
        optionReleaseTimer = nil
    end
    if overlayResizeTimer then
        overlayResizeTimer:stop()
        overlayResizeTimer = nil
    end

    hideOverlay()
    switchChoices = {}
    overlayHostWindow = nil

    if choice and not cancelled then activateEdgeTab(choice) end
end

local function selectOverlayIndex(index)
    if not switching or index < 1 or index > overlayItemCount then return end
    local oldIndex = selectedIndex
    selectedIndex = index
    updateOverlaySelection(oldIndex, selectedIndex)
end

local function moveOverlaySelection(key)
    if key == "left" or key == "right" then
        local step = key == "right" and 1 or -1
        selectOverlayIndex((selectedIndex - 1 + step) % overlayItemCount + 1)
        return
    end
    local current = overlayCardElements[selectedIndex]
    if not current then return end
    local targetRow = current.row + (key == "down" and 1 or -1)
    local bestIndex, bestDistance = nil, math.huge
    for i, refs in ipairs(overlayCardElements) do
        if refs.row == targetRow then
            local distance = math.abs(refs.centerX - current.centerX)
            if distance < bestDistance then bestIndex, bestDistance = i, distance end
        end
    end
    if bestIndex then selectOverlayIndex(bestIndex) end
end

local numberKeys = {}
for i = 1, 9 do
    numberKeys[hs.keycodes.map[tostring(i)]] = i
end

-- Keep the existing release watchdog only while the panel is open. The
-- flagsChanged event below normally commits immediately, without its 20ms wait.
local function watchOptionRelease()
    if optionReleaseTimer then return end
    optionReleaseTimer = hs.timer.doEvery(0.02, function()
        if not edgeIsFrontmost() then
            finishSwitch(true)
        elseif not hs.eventtap.checkKeyboardModifiers().alt then
            finishSwitch()
        end
    end)
end

local function handleOptionTab(direction)
    if not edgeIsFrontmost() then
        finishSwitch(true)
        swallowedKeys = {}
        return false
    end

    local hostWindow
    if not switching then
        -- Query Accessibility once on opening, not on every cycle or timer tick.
        -- A temporary missing window result while the panel is open is harmless.
        hostWindow = hs.window.focusedWindow()
        local app = hostWindow and hostWindow:application()
        if not app or app:bundleID() ~= "com.microsoft.edgemac" then return false end
    end

    beginOrCycle(direction, hostWindow)
    if switching then watchOptionRelease() end
    return switching
end

-- Reuse the navigation tap instead of registering global Option+Tab hotkeys.
-- Unrelated keys take the cheap path; other apps keep their original key events.
navigationTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
    hs.eventtap.event.types.flagsChanged,
}, function(event)
    local eventType = event:getType()
    if eventType == hs.eventtap.event.types.flagsChanged then
        if switching then
            if not edgeIsFrontmost() then
                finishSwitch(true)
                swallowedKeys = {}
            elseif not event:getFlags().alt then
                finishSwitch()
            end
        end
        return false
    end

    local code = event:getKeyCode()
    local key = hs.keycodes.map[code]
    -- Check focus during an active session, including its final key-up. Do not
    -- depend on application notifications arriving before the next key event.
    if (switching or swallowedKeys[code]) and not edgeIsFrontmost() then
        finishSwitch(true)
        swallowedKeys = {}
        return false
    end
    if eventType == hs.eventtap.event.types.keyUp then
        if swallowedKeys[code] then swallowedKeys[code] = nil; return true end
        return false
    end
    -- Consume held-key repeats after Escape until the physical key is up.
    if swallowedKeys[code] and (not switching or key == "tab") then return true end

    if key == "tab" then
        local flags = event:getFlags()
        if flags.alt and not flags.cmd and not flags.ctrl then
            -- Match the old hotkeys: one cycle per physical press, no auto-repeat.
            if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then
                return false
            end
            if handleOptionTab(flags.shift and -1 or 1) then
                swallowedKeys[code] = true
                return true
            end
        end
        return false
    end

    if not switching then return false end
    if key == "escape" then
        swallowedKeys[code] = true
        finishSwitch(true)
        return true
    end
    local flags = event:getFlags()
    if not flags.alt or flags.cmd or flags.ctrl then return false end
    if key == "left" or key == "right" or key == "up" or key == "down" then
        swallowedKeys[code] = true
        moveOverlaySelection(key)
        return true
    end
    local number = numberKeys[code]
    if number then
        swallowedKeys[code] = true
        selectOverlayIndex(number)
        return true
    end
    return false
end)
navigationTap:start()

appWatcher = hs.application.watcher.new(function(appName, eventType, app)
    if (eventType == hs.application.watcher.deactivated
            and app and app:bundleID() == "com.microsoft.edgemac")
        or (eventType == hs.application.watcher.activated and not edgeIsFrontmost())
    then
        finishSwitch(true)
        swallowedKeys = {}
    end
end)
appWatcher:start()

------------------------------------------------------------
-- Sleep / wake recovery
------------------------------------------------------------

local function scheduleWakeRecovery()
    if wakeRecoveryTimer then
        wakeRecoveryTimer:stop()
        wakeRecoveryTimer = nil
    end

    wakeRecoveryTimer = hs.timer.doAfter(0.75, function()
        wakeRecoveryTimer = nil
        switching = false
        switchChoices = {}
        overlayHostWindow = nil
        swallowedKeys = {}

        if overlayResizeTimer then
            overlayResizeTimer:stop()
            overlayResizeTimer = nil
        end

        if optionReleaseTimer then
            optionReleaseTimer:stop()
            optionReleaseTimer = nil
        end

        hideOverlay()
        clearPendingSwitch()
        navigationTap:start()
        -- Keep the listening server across wake/unlock. Rebinding immediately
        -- after stop() can fail with "Address already in use". The extension's
        -- heartbeat detects stale connections and replays MRU on reconnect.
    end)
end

wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
        or event == hs.caffeinate.watcher.screensDidWake
        or event == hs.caffeinate.watcher.screensDidUnlock
    then
        scheduleWakeRecovery()
    end
end)
wakeWatcher:start()

-- A running native listener retains its callback, not the Lua userdata itself.
-- Keep one global owner so GC cannot silently stop the tap or its recovery watchers.
-- hs.reload() resets this Lua state and releases the previous owner automatically.
EdgeRecentTabs = {
    navigationTap = navigationTap,
    appWatcher = appWatcher,
    wakeWatcher = wakeWatcher,
}

------------------------------------------------------------
-- Reload shortcut
------------------------------------------------------------

hs.hotkey.bind({"cmd", "ctrl", "alt"}, "r", function()
    hs.reload()
end)

------------------------------------------------------------
-- Start
------------------------------------------------------------

startBridge()

-- Give the extension time to reconnect and restore the authoritative snapshot.
hs.timer.doAfter(1.5, function()
    if not restoredMruSnapshot then seedRecentTabs() end
end)

hs.alert.show("Edge MRU window scope loaded")
