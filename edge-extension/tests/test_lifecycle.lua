-- Hammerspoon keeps callback functions in its registry, not the watcher userdata.
-- Model that ownership so tests do not accidentally keep listeners alive themselves.
local configPath = arg and arg[1] or "../init.lua"
local registry, pendingTimers = {}, {}
local weakListeners = setmetatable({}, { __mode = "v" })
local serial = 0
local function listener(kind, callback)
    serial = serial + 1
    local id = serial
    registry[id] = callback
    local result = { enabled = false }
    function result:start() self.enabled = true; return self end
    function result:stop() self.enabled = false; return self end
    function result:isEnabled() return self.enabled end
    setmetatable(result, { __gc = function()
        registry[id] = nil
    end })
    weakListeners[kind] = result
    return result
end
local function server()
    return setmetatable({}, { __index = function(_, name)
        return function(self, first, second)
            if name == "setCallback" then registry.http = first end
            if name == "websocket" then registry.socket = second end
            return self
        end
    end })
end
hs = {
    dockicon = { hide = function() end },
    image = { imageFromAppBundle = function() return nil end },
    keycodes = { map = {} },
    eventtap = {
        event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 } },
        new = function(_, callback) return listener("keyboard", callback) end,
    },
    application = { watcher = { new = function(callback) return listener("application", callback) end } },
    caffeinate = { watcher = { new = function(callback) return listener("wake", callback) end } },
    timer = { doAfter = function(_, callback)
        table.insert(pendingTimers, callback)
        return { stop = function() end }
    end },
    httpserver = { new = server },
    hotkey = { bind = function() end },
    alert = { show = function() end },
}
for index = 1, 9 do hs.keycodes.map[tostring(index)] = index end
assert(loadfile(configPath))()

local function collect()
    -- Releasing one callback can make another listener unreachable in the next pass.
    for _ = 1, 5 do collectgarbage("collect") end
end
collect()
for _, kind in ipairs({ "keyboard", "application", "wake" }) do
    assert(weakListeners[kind] and weakListeners[kind]:isEnabled(),
        kind .. " listener disappeared after garbage collection")
end
print("Lifecycle checks passed: keyboard, application and wake listeners survive full GC")

-- A single named owner is enough; releasing it allows eventual cleanup.
EdgeRecentTabs = nil
collect()
for _, kind in ipairs({ "keyboard", "application", "wake" }) do
    assert(weakListeners[kind] == nil, kind .. " listener leaked after releasing its owner")
end
print("Lifecycle cleanup passed: no permanent listener ownership cycle")
