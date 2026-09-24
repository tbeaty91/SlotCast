-- SlotCast :: Core
-- Saved variables, event plumbing, refresh scheduling, slash commands.

local ADDON, ns = ...

local SlotCast = CreateFrame("Frame", "SlotCastFrame")
ns.SlotCast = SlotCast
_G.SlotCast = SlotCast

-- Exposed purely so the namespace can be inspected from chat when something is
-- wrong: /dump SlotCast.ns.Probe
SlotCast.ns = ns

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
SlotCast.version = (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"

------------------------------------------------------------------------------
-- output
------------------------------------------------------------------------------

local PREFIX = "|cff66ccffSlotCast|r: "

function ns.Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print(PREFIX .. msg)
end

function ns.Warn(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print(PREFIX .. "|cffffcc00" .. msg .. "|r")
end

------------------------------------------------------------------------------
-- defaults
--
-- binds is keyed by a canonical combo string: "<alt-><ctrl-><shift->" .. button
-- number, e.g. "1", "shift-1", "alt-ctrl-shift-3". That prefix order is not a
-- style choice: SecureButton_GetModifiedAttribute builds its attribute lookup
-- as "alt-" .. "ctrl-" .. "shift-" .. name .. button, so any other order simply
-- never resolves.
--
-- Each value is either a number 1..12 (a slot index on the source bar) or one
-- of the special action strings handled in Slots.lua.
------------------------------------------------------------------------------

ns.defaults = {
    enabled     = true,
    bar         = 8,
    binds       = {
        ["1"] = "target",
        ["2"] = "menu",
    },

    -- Rank handling, for clients that have spell ranks.
    --   "slot"    cast exactly the rank sitting in the slot -> Renew(Rank 2)
    --   "highest" cast the highest rank learned             -> Renew
    -- rankMode is the default for every slot; rankOverrides[slotIndex] wins.
    rankMode      = "slot",
    rankOverrides = {},

    -- "spell" uses type="spell" so the secure handler supplies the unit.
    -- "macro" falls back to /cast [@mouseover] if a client's CastSpellByName
    -- will not take the "Name(Rank N)" form.
    castMode      = "spell",

    warnConflicts  = true,
    announceDefer  = true,
}

local function CopyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

------------------------------------------------------------------------------
-- refresh scheduling
--
-- Everything funnels through ns.Refresh(). It coalesces bursts (roster updates
-- fire several times a second) and it is the single place that knows about
-- combat lockdown.
------------------------------------------------------------------------------

local refreshPending, refreshQueued = false, false

local function DoRefresh()
    refreshQueued = false
    if not ns.db then return end

    if InCombatLockdown() then
        -- SetAttribute on a secure frame is forbidden in combat. Remember that
        -- we owe an update and take it the moment combat drops.
        if not refreshPending and ns.db.announceDefer then
            ns.Warn("binding change held until you leave combat")
        end
        refreshPending = true
        return
    end

    refreshPending = false
    ns.Slots.BuildPlan()
    ns.Secure.ApplyAll()
    if ns.Options and ns.Options.RefreshDisplay then ns.Options.RefreshDisplay() end
end

function ns.Refresh(immediate)
    if immediate then
        DoRefresh()
        return
    end
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.05, DoRefresh)
end

function ns.IsRefreshPending()
    return refreshPending
end

------------------------------------------------------------------------------
-- events
------------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON then return end
    SlotCastDB = CopyDefaults(ns.defaults, SlotCastDB)
    ns.db = SlotCastDB
    SlotCast:UnregisterEvent("ADDON_LOADED")
end

function handlers.PLAYER_LOGIN()
    ns.Secure.Init()
    ns.Options.Init()

    -- The default source bar is 8, which not every client has.
    if not ns.Slots.BarExists(ns.db.bar) then
        local fallback = ns.Slots.MaxBar()
        if fallback > 0 then
            ns.Warn("bar %d is not present on this client - falling back to bar %d.", ns.db.bar, fallback)
            ns.db.bar = fallback
        else
            ns.Warn("no action bars found. Slot bindings are disabled until one exists.")
        end
    end

    ns.Refresh(true)

    -- Blizzard's own click bindings run in a separate secure path and will fire
    -- alongside ours. Say so once, on login, rather than silently double-casting.
    C_Timer.After(3, function()
        if ns.db and ns.db.warnConflicts then ns.Conflicts.ReportOnLogin() end
    end)
end

function handlers.PLAYER_ENTERING_WORLD()
    ns.Secure.Scan()
    ns.Refresh()
end

function handlers.PLAYER_REGEN_ENABLED()
    if refreshPending then ns.Refresh(true) end
    ns.Secure.FlushPending()
end

function handlers.ACTIONBAR_SLOT_CHANGED(slot)
    -- slot 0 means "everything changed" (spec swap, bar page load, etc.)
    if not slot or slot == 0 or ns.Slots.OwnsSlot(slot) then ns.Refresh() end
end

function handlers.ACTIONBAR_PAGE_CHANGED()
    -- Only bar 1 pages. Bars 2-8 are fixed slot ranges, so this is a no-op there.
    if ns.db and ns.db.bar == 1 then ns.Refresh() end
end

handlers.UPDATE_MACROS                  = function() ns.Refresh() end
handlers.LEARNED_SPELL_IN_TAB           = function() ns.Refresh() end
handlers.PLAYER_LEVEL_UP                = function() ns.Refresh() end
handlers.PLAYER_SPECIALIZATION_CHANGED  = function() ns.Refresh() end
handlers.UPDATE_BONUS_ACTIONBAR         = function() if ns.db and ns.db.bar == 1 then ns.Refresh() end end
handlers.UPDATE_VEHICLE_ACTIONBAR       = function() if ns.db and ns.db.bar == 1 then ns.Refresh() end end

function handlers.GROUP_ROSTER_UPDATE()
    ns.Secure.Scan()
    ns.Refresh()
end

function handlers.CVAR_UPDATE(name)
    if name == "ActionButtonUseKeyDown" or name == "lockActionBars" then
        ns.Secure.UpdateClickRegistration()
    end
end

SlotCast:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then fn(...) end
end)

for event in pairs(handlers) do SlotCast:RegisterEvent(event) end

------------------------------------------------------------------------------
-- slash commands
------------------------------------------------------------------------------

SLASH_SLOTCAST1 = "/slotcast"
SLASH_SLOTCAST2 = "/sc"

-- Which files actually loaded. A module missing from the addon folder is
-- otherwise invisible: the slash command just nil-indexes and dies quietly,
-- because retail hides Lua errors unless scriptErrors is on.
ns.MODULES = { "Slots", "Secure", "Conflicts", "Probe", "Options" }

function ns.MissingModules()
    local missing = {}
    for _, name in ipairs(ns.MODULES) do
        if type(ns[name]) ~= "table" then missing[#missing + 1] = name end
    end
    return missing
end

-- Returns the module, or nil after explaining what to do about it.
local function Need(name)
    if type(ns[name]) == "table" then return ns[name] end
    ns.Warn("%s.lua did not load.", name)
    ns.Warn("Copy the whole SlotCast folder over again (the file is new), then /reload.")
    return nil
end

local function Dispatch(cmd, rest)
    if cmd == "" or cmd == "config" or cmd == "options" then
        if Need("Options") then ns.Options.Open() end

    elseif cmd == "status" then
        ns.Print("v%s | %s | source bar %s | %s frames managed",
            SlotCast.version,
            ns.db.enabled and "|cff00ff00enabled|r" or "|cffff0000disabled|r",
            ns.db.bar,
            ns.Secure and ns.Secure.ManagedCount() or "?")

        local missing = ns.MissingModules()
        if #missing == 0 then
            ns.Print("modules: |cff00ff00all %d loaded|r", #ns.MODULES)
        else
            ns.Warn("modules MISSING: %s - copy the addon folder over again and /reload.",
                table.concat(missing, ", "))
        end

        if ns.Slots then ns.Slots.PrintPlan() end

    elseif cmd == "probe" then
        if Need("Probe") then ns.Probe.Show(rest == "chat") end

    elseif cmd == "dump" then
        -- Prints Blizzard's click-binding profile exactly as the API returns it.
        -- The field names in that struct are the one thing here that cannot be
        -- verified outside the game; this is how you confirm them.
        if Need("Conflicts") then ns.Conflicts.Dump() end

    elseif cmd == "conflicts" then
        if Need("Conflicts") then ns.Conflicts.Report(true) end

    elseif cmd == "rank" then
        if rest == "slot" or rest == "highest" then
            ns.db.rankMode = rest
            wipe(ns.db.rankOverrides)
            ns.Print("rank mode: %s (per-slot overrides cleared)",
                rest == "slot" and "cast the rank in the slot" or "cast the highest rank learned")
            ns.Refresh(true)
        else
            ns.Print("usage: |cffffff00/slotcast rank slot|r or |cffffff00/slotcast rank highest|r (current: %s)", ns.db.rankMode)
        end

    elseif cmd == "castmode" then
        if rest == "spell" or rest == "macro" then
            ns.db.castMode = rest
            ns.Print("cast mode: %s", rest)
            ns.Refresh(true)
        else
            ns.Print("usage: |cffffff00/slotcast castmode spell|r or |cffffff00/slotcast castmode macro|r (current: %s)", ns.db.castMode)
        end

    elseif cmd == "toggle" then
        ns.db.enabled = not ns.db.enabled
        ns.Print(ns.db.enabled and "enabled" or "disabled")
        ns.Refresh(true)

    else
        ns.Print("commands: |cffffff00/slotcast|r (options), |cffffff00probe|r, |cffffff00status|r, |cffffff00rank|r, |cffffff00castmode|r, |cffffff00conflicts|r, |cffffff00dump|r, |cffffff00toggle|r")
    end
end

SlashCmdList.SLOTCAST = function(msg)
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")

    -- Errors are surfaced here rather than left to the client, which swallows
    -- them entirely unless the user has turned scriptErrors on. A command that
    -- does nothing at all is the worst possible failure mode to debug.
    local ok, err = pcall(Dispatch, cmd, rest)
    if not ok then
        ns.Warn("/slotcast %s failed: %s", cmd ~= "" and cmd or "(no args)", tostring(err))
        ns.Warn("Run |cffffff00/slotcast status|r to see which modules loaded.")
    end
end
