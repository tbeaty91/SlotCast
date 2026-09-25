-- SlotCast :: Secure
-- Frame discovery, secure attribute application, original-attribute restore,
-- and the combat-lockdown queue.

local ADDON, ns = ...

ns.Secure = {}
local Secure = ns.Secure

local managed = {}      -- frame -> true
local saved   = {}      -- frame -> { [attrName] = originalValue | false }
local pendingRegister = {}

-- `false` is the sentinel for "this attribute did not exist before we touched
-- it", because nil cannot be stored as a table value.
local NIL = false

------------------------------------------------------------------------------
-- click registration
--
-- Unit frames register only for left/right up by default, so middle-click and
-- the side buttons never reach the secure handler until we widen this. That
-- part is necessary.
--
-- Down-vs-up is not. This used to follow the ActionButtonUseKeyDown cvar, which
-- was a mistake: that cvar governs ACTION BUTTONS. Blizzard's unit frames stay
-- on the up-stroke, and so does Clique. Casting works on the down-stroke, but
-- "target" and "menu" run on the up-stroke -- so registering unit frames for
-- AnyDown left spells working while silently killing target and menu, which is
-- a maddening bug to look at because two thirds of the addon still works.
------------------------------------------------------------------------------

local function ClickRegistration()
    local stroke = ns.ClickStroke()
    if stroke == "both" then return "AnyDown", "AnyUp" end
    return stroke == "down" and "AnyDown" or "AnyUp"
end

------------------------------------------------------------------------------
-- registration
------------------------------------------------------------------------------

local function IsUsable(frame)
    if type(frame) ~= "table" then return false end
    if frame.IsForbidden and frame:IsForbidden() then return false end
    if type(frame.SetAttribute) ~= "function" then return false end
    if type(frame.RegisterForClicks) ~= "function" then return false end
    return true
end

function Secure.Register(frame)
    local ok, usable = pcall(IsUsable, frame)
    if not ok or not usable then return end
    if managed[frame] then return end

    if InCombatLockdown() then
        pendingRegister[frame] = true
        return
    end

    managed[frame] = true
    saved[frame] = saved[frame] or {}
    pcall(frame.RegisterForClicks, frame, ClickRegistration())
    Secure.ApplyToFrame(frame)
end

function Secure.Unregister(frame)
    if not managed[frame] then return end
    if InCombatLockdown() then return end
    Secure.RestoreFrame(frame)
    managed[frame] = nil
end

function Secure.FlushPending()
    if InCombatLockdown() then return end
    if not next(pendingRegister) then return end
    for frame in pairs(pendingRegister) do
        pendingRegister[frame] = nil
        Secure.Register(frame)
    end
end

-- Any managed frame, for reading back what this client's frames actually do.
function Secure.SampleFrame()
    for frame in pairs(managed) do return frame end
    return nil
end

-- Names of everything currently managed, sorted. Answers "is PlayerFrame
-- actually registered?" without guessing.
function Secure.ManagedNames()
    local names = {}
    for frame in pairs(managed) do
        local ok, name = pcall(frame.GetName, frame)
        names[#names + 1] = (ok and name) or "(unnamed)"
    end
    table.sort(names)
    return names
end

function Secure.ManagedCount()
    local n = 0
    for _ in pairs(managed) do n = n + 1 end
    return n
end

function Secure.UpdateClickRegistration()
    if InCombatLockdown() then return end
    for frame in pairs(managed) do
        -- Called last so both return values expand in "both" mode.
        pcall(frame.RegisterForClicks, frame, ClickRegistration())
    end
end

------------------------------------------------------------------------------
-- applying the plan
------------------------------------------------------------------------------

-- Frames that usually hold something hostile. Casting a heal at a boss frame
-- burns a click and sometimes a global cooldown, so allow opting out of them
-- while keeping party, raid, player and pet frames bound.
local ENEMY_FRAME_PATTERNS = { "^TargetFrame", "^FocusFrame", "^Boss%d", "^Arena" }

function ns.FrameExcluded(frame)
    if not ns.db or not ns.db.skipEnemyFrames then return false end
    local ok, name = pcall(frame.GetName, frame)
    if not ok or type(name) ~= "string" then return false end
    for _, pattern in ipairs(ENEMY_FRAME_PATTERNS) do
        if name:find(pattern) then return true end
    end
    return false
end

function Secure.ApplyToFrame(frame)
    if InCombatLockdown() then return end

    -- Excluded frames are actively restored rather than skipped, so turning the
    -- option on takes effect immediately instead of at the next reload.
    if ns.FrameExcluded(frame) then
        Secure.RestoreFrame(frame)
        return
    end

    local store = saved[frame]
    if not store then store = {}; saved[frame] = store end

    local plan, planAttrs = ns.Slots.plan, ns.Slots.planAttrs

    -- Anything we wrote on a previous pass that the current plan no longer
    -- covers goes back to whatever the unit frame originally had. This is what
    -- keeps plain left-click targeting intact when a binding is removed.
    for attr, original in pairs(store) do
        if not planAttrs[attr] then
            pcall(frame.SetAttribute, frame, attr, original ~= NIL and original or nil)
            store[attr] = nil
        end
    end

    for i = 1, #plan do
        local entry = plan[i]
        if store[entry.attr] == nil then
            local ok, existing = pcall(frame.GetAttribute, frame, entry.attr)
            store[entry.attr] = (ok and existing ~= nil) and existing or NIL
        end
        pcall(frame.SetAttribute, frame, entry.attr, entry.value)
    end
end

function Secure.RestoreFrame(frame)
    if InCombatLockdown() then return end
    local store = saved[frame]
    if not store then return end
    for attr, original in pairs(store) do
        pcall(frame.SetAttribute, frame, attr, original ~= NIL and original or nil)
    end
    saved[frame] = {}
end

function Secure.ApplyAll()
    if InCombatLockdown() then return end
    for frame in pairs(managed) do
        Secure.ApplyToFrame(frame)
    end
end

------------------------------------------------------------------------------
-- discovery
--
-- Two sources. ClickCastFrames is the fifteen-year-old convention that Clique
-- established and that Blizzard's compact frames plus most unit frame addons
-- (Grid2, Cell, ElvUI, VuhDo) write into; hooking its __newindex means we pick
-- up their frames without knowing anything about them. The named list below
-- covers Blizzard's non-compact frames, which do not register themselves.
------------------------------------------------------------------------------

-- Clique's default frame list is the reference here; arena was the one group
-- missing from ours. Names that do not exist on a given client cost nothing.
local BLIZZ_FRAMES = {
    "PlayerFrame", "PetFrame",
    "TargetFrame", "TargetFrameToT",
    "FocusFrame", "FocusFrameToT",
    "Boss1TargetFrame", "Boss2TargetFrame", "Boss3TargetFrame",
    "Boss4TargetFrame", "Boss5TargetFrame",
}

local function ScanNamed()
    for _, name in ipairs(BLIZZ_FRAMES) do
        local frame = _G[name]
        if frame then Secure.Register(frame) end
    end

    -- Classic-style party frames (retail, "use raid-style party frames" off).
    for i = 1, 5 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then Secure.Register(frame) end
        if PartyFrame and PartyFrame["MemberFrame" .. i] then
            Secure.Register(PartyFrame["MemberFrame" .. i])
        end
    end

    -- Arena. The naming has changed more than once, so try each.
    for i = 1, 5 do
        for _, pattern in ipairs({ "ArenaEnemyMatchFrame%d", "ArenaEnemyFrame%d",
                                   "CompactArenaFrameMember%d", "ArenaPrepFrame%d" }) do
            local frame = _G[pattern:format(i)]
            if frame then Secure.Register(frame) end
        end
    end

    -- Compact frames. Blizzard registers most of these into ClickCastFrames
    -- itself, but they are created lazily and the grouped raid layout uses a
    -- different naming scheme, so sweep both.
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame then Secure.Register(frame) end
    end
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then Secure.Register(frame) end
    end
    for g = 1, 8 do
        for m = 1, 5 do
            local frame = _G[("CompactRaidGroup%dMember%d"):format(g, m)]
            if frame then Secure.Register(frame) end
        end
    end
end

function Secure.Scan()
    ScanNamed()

    -- Anything already sitting in the registry when we loaded.
    local reg = _G.ClickCastFrames
    if type(reg) == "table" then
        for frame, value in pairs(reg) do
            if value then Secure.Register(frame) end
        end
    end
end

function Secure.Init()
    -- Take over (or create) the shared registry. Writing a frame in registers
    -- it; writing nil/false takes it back out.
    local reg = _G.ClickCastFrames
    if type(reg) ~= "table" then reg = {} end

    if getmetatable(reg) and not reg.__slotcast then
        -- Someone else -- almost certainly Clique -- owns this already. Both
        -- addons writing the same attributes is a fight nobody wins.
        ns.Warn("another click-cast addon already owns ClickCastFrames. Disable Clique (or similar) or SlotCast may be overridden.")
    end

    reg.__slotcast = true
    setmetatable(reg, {
        __newindex = function(t, frame, value)
            rawset(t, frame, value)
            if value then Secure.Register(frame) else Secure.Unregister(frame) end
        end,
    })
    _G.ClickCastFrames = reg

    -- The reliable hook for Blizzard raid/party compact frames, which are built
    -- and rebuilt as the roster changes.
    if type(_G.CompactUnitFrame_SetUpFrame) == "function" then
        hooksecurefunc("CompactUnitFrame_SetUpFrame", function(frame)
            Secure.Register(frame)
        end)
    end

    Secure.Scan()
end
