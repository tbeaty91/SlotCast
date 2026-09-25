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
-- slash commands
--
-- Registered up here, before anything that could fail, and calling a
-- forward-declared Dispatch defined at the bottom. A diagnostic command that
-- only exists if the whole file loaded is useless precisely when it is needed:
-- an error anywhere above would take the commands down with it, and the symptom
-- is a slash command that silently does nothing.
------------------------------------------------------------------------------

local Dispatch  -- defined at the end of this file

SLASH_SLOTCAST1 = "/slotcast"
SLASH_SLOTCAST2 = "/sc"

SlashCmdList.SLOTCAST = function(msg)
    local cmd, restRaw = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    -- Keyword arguments are compared lowercased, but frame names are
    -- case-sensitive globals, so the raw text has to survive too.
    local rest = restRaw:lower()

    if not Dispatch then
        ns.Warn("Core.lua did not finish loading - an error stopped it partway.")
        ns.Warn("Turn on |cffffff00/console scriptErrors 1|r, /reload, and send me the error.")
        return
    end

    -- Errors surface here rather than being left to the client, which swallows
    -- them unless scriptErrors is on.
    local ok, err = pcall(Dispatch, cmd, rest, restRaw)
    if not ok then
        ns.Warn("/slotcast %s failed: %s", cmd ~= "" and cmd or "(no args)", tostring(err))
        ns.Warn("Run |cffffff00/slotcast status|r to see which modules loaded.")
    end
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

    -- Empty on purpose. Anything not listed here is left exactly as the unit
    -- frame had it, which on current clients means Blizzard's own
    -- "*type1 = target" / "*type2 = menu" keep working -- and so do any click
    -- bindings the player set in Blizzard's UI. Claiming plain left and right
    -- by default would override those for no gain, since it would only
    -- reimplement behaviour the frame already has.
    binds       = {},

    -- Rank handling, for clients that have spell ranks.
    --   "slot"    cast exactly the rank sitting in the slot -> Renew(Rank 2)
    --   "highest" cast the highest rank learned             -> Renew
    -- rankMode is the default for every slot; rankOverrides[slotIndex] wins.
    rankMode      = "slot",
    rankOverrides = {},

    -- On clients that have Blizzard's click-binding system, Target and Unit
    -- menu belong to it: SlotCast shows what is bound there instead of
    -- offering a second place to bind them. "off" takes them back, for a
    -- client where that system does not exist or does not work.
    blizzDelegate = "auto",

    -- Suppresses the "bind these in Click Bindings" dialog once the user has
    -- read it. Cleared by /slotcast blizz manual, which is an explicit ask.
    hideClickcastingNotice = false,

    -- Which secure action type opens the unit menu. "auto" picks "menu" only
    -- when the frame has a menu function for SecureUnitButton_OnClick to call,
    -- and "togglemenu" otherwise. Override if a client wants the other one.
    menuVerb = "auto",

    -- Which mouse stroke bindings fire on.
    --   "auto" (default) press, unless the unit menu is bound -- the one action
    --          with no press-stroke equivalent. Casting stays responsive.
    --   "down" always press. Fastest; the unit menu will not work.
    --   "up"   always release. Everything works, casts land a touch later.
    --   "both" register both strokes. Untested on any client; spells may fire
    --          twice. Here to be measured, not recommended.
    clickStroke = "auto",

    -- How "Map grid to clicks" reads a bar's shape. Neither is more correct;
    -- a 3-wide bar wants columns as buttons, a 3-tall one wants rows.
    gridTranspose   = false,      -- false: columns are mouse buttons
    gridButtonOrder = "LMR",      -- or "LRM", for people who find middle-click awkward

    -- "spell" uses type="spell" so the secure handler supplies the unit.
    -- "macro" falls back to /cast [@mouseover] if a client's CastSpellByName
    -- will not take the "Name(Rank N)" form.
    castMode      = "spell",

    warnConflicts  = true,
    announceDefer  = true,
}

-- Tables the user edits by removing entries. Merging defaults into these
-- key-by-key would resurrect anything they deleted on the next login, so they
-- are only seeded when absent entirely.
local USER_TABLES = { binds = true, rankOverrides = true }

local function CopyDefaults(src, dst, top)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if top and USER_TABLES[k] then
            if type(dst[k]) ~= "table" then dst[k] = CopyDefaults(v, {}) end
        elseif type(v) == "table" then
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
    SlotCastDB = CopyDefaults(ns.defaults, SlotCastDB, true)
    ns.db = SlotCastDB

    -- configVersion is deliberately NOT in ns.defaults: CopyDefaults would
    -- stamp it on an old profile and the migration below would never run.
    if (SlotCastDB.configVersion or 1) < 2 then
        -- v1 claimed plain left and right click for target/menu. That overrode
        -- the player's own Blizzard click bindings on those two buttons while
        -- only reproducing what the frame already did. Release them, but only
        -- if they are still sitting at the old defaults.
        if SlotCastDB.binds["1"] == "target" and SlotCastDB.binds["2"] == "menu" then
            SlotCastDB.binds["1"] = nil
            SlotCastDB.binds["2"] = nil
            ns.releasedDefaultClicks = true
        end
        SlotCastDB.configVersion = 2
    end

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

    if ns.releasedDefaultClicks then
        ns.Print("plain left and right click are no longer claimed by default -")
        ns.Print("your unit frames' own behaviour (and Blizzard's click bindings) handle them.")
        ns.Print("Bind them in |cffffff00/slotcast|r if you want SlotCast to take them back.")
    end

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
handlers.LEARNED_SPELL_IN_SKILL_LINE    = function() ns.Refresh() end
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

-- RegisterEvent raises on an unknown event name, and event names differ
-- between clients (LEARNED_SPELL_IN_TAB became LEARNED_SPELL_IN_SKILL_LINE in
-- 11.0). Registering one by one means an absent event costs us that event, not
-- the rest of the addon.
ns.unavailableEvents = {}

for event in pairs(handlers) do
    local ok = pcall(SlotCast.RegisterEvent, SlotCast, event)
    if not ok then
        ns.unavailableEvents[#ns.unavailableEvents + 1] = event
    end
end

table.sort(ns.unavailableEvents)

------------------------------------------------------------------------------
-- command implementations
------------------------------------------------------------------------------

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

function Dispatch(cmd, rest, restRaw)
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

        ns.Print("click stroke: %s -> firing on |cffffffff%s|r", ns.db.clickStroke, ns.ClickStroke())

        if type(ns.FrameVerb) == "function" then
            ns.Print("frame verbs: target=%s menu=%s",
                tostring(ns.FrameVerb("target")), tostring(ns.FrameVerb("menu")))
        end

        if #ns.unavailableEvents > 0 then
            ns.Print("events not on this client (skipped): %s", table.concat(ns.unavailableEvents, ", "))
        end

        if ns.Slots then ns.Slots.PrintPlan() end

    elseif cmd == "check" then
        if Need("Probe") then
            -- "check chat" prints inline; "check <FrameName>" aims at one frame.
            ns.Probe.Check(rest == "chat", rest ~= "chat" and restRaw or nil)
        end

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

    elseif cmd == "blizz" then
        if rest == "auto" or rest == "off" then
            ns.db.blizzDelegate = rest
            ns.Refresh(true)
            ns.Print("Target and Unit menu are %s.",
                rest == "off" and "bound by SlotCast" or "read from Blizzard's click bindings")
        elseif rest == "manual" or rest == "help" or rest == "" then
            -- Asking for the instructions explicitly overrides having dismissed
            -- them before.
            ns.db.hideClickcastingNotice = false
            ns.Conflicts.ExplainManualBinding(nil, "menu")
        else
            ns.Print("usage: |cffffff00/slotcast blizz auto|off|r (current: %s), or |cffffff00blizz manual|r for the steps.",
                ns.db.blizzDelegate)
        end

    elseif cmd == "menuverb" then
        if rest == "auto" or rest == "menu" or rest == "togglemenu" then
            ns.db.menuVerb = rest
            ns.WipeFrameVerbs()
            ns.Refresh(true)
            ns.Print("menu verb: %s (using %s)", rest, ns.FrameVerb("menu"))
        else
            ns.Print("usage: |cffffff00/slotcast menuverb auto|menu|togglemenu|r (current: %s -> using %s)",
                ns.db.menuVerb, ns.FrameVerb("menu"))
        end

    elseif cmd == "clicks" then
        if rest == "auto" or rest == "up" or rest == "down" or rest == "both" then
            ns.db.clickStroke = rest
            ns.Secure.UpdateClickRegistration()
            ns.Refresh(true)
            ns.Print("click stroke: %s (currently firing on %s)", rest, ns.ClickStroke())

            local stranded = ns.StrandedBindings()
            for _, entry in ipairs(stranded) do
                ns.Warn("%s is the unit menu, which cannot fire on press - it will not work.",
                    ns.ComboText(entry.combo))
            end
            if rest == "both" then
                ns.Warn("'both' is experimental: if spells now cast twice per click, it is not supported here.")
            end
        else
            ns.Print("usage: |cffffff00/slotcast clicks auto|up|down|both|r (current: %s -> firing on %s)",
                ns.db.clickStroke, ns.ClickStroke())
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
        ns.Print("commands: |cffffff00/slotcast|r (options), |cffffff00check|r, |cffffff00probe|r, |cffffff00status|r, |cffffff00rank|r, |cffffff00castmode|r, |cffffff00clicks|r, |cffffff00menuverb|r, |cffffff00blizz|r, |cffffff00conflicts|r, |cffffff00dump|r, |cffffff00toggle|r")
    end
end

