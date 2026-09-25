-- SlotCast :: Slots
-- Bar number -> action slot range, reading a slot's contents, and turning that
-- into the secure attributes a click binding needs.

local ADDON, ns = ...

ns.Slots = {}
local Slots = ns.Slots

------------------------------------------------------------------------------
-- bar -> first action slot
--
-- Nothing here is hard-coded if it can be asked for instead. Slot ranges differ
-- between clients (and the aliasing is genuinely confusing: slots 25-72 are both
-- "pages 3-6 of the main bar" and "the four side/bottom multibars"), so the real
-- mapping is read off the action buttons themselves at runtime.
------------------------------------------------------------------------------

ns.BAR_NAMES = {
    [1] = "Bar 1 (main)",
    [2] = "Bar 2 (bottom left)",
    [3] = "Bar 3 (bottom right)",
    [4] = "Bar 4 (right)",
    [5] = "Bar 5 (right 2)",
    [6] = "Bar 6",
    [7] = "Bar 7",
    [8] = "Bar 8",
}

ns.SLOTS_PER_BAR = 12

-- The button that owns slot 1 of each bar. Asking the button which action slot
-- it drives is the only mapping that survives a client we have never seen:
-- whatever the ranges are, and however many bars exist, the buttons know.
local BAR_BUTTON = {
    [1] = "ActionButton",
    [2] = "MultiBarBottomLeftButton",
    [3] = "MultiBarBottomRightButton",
    [4] = "MultiBarRightButton",
    [5] = "MultiBarLeftButton",
    [6] = "MultiBar5Button",
    [7] = "MultiBar6Button",
    [8] = "MultiBar7Button",
}

-- Ask bar `bar`'s first button which action slot it is currently driving.
-- Returns nil if that bar does not exist on this client.
local function ProbeBase(bar)
    local name = BAR_BUTTON[bar]
    if not name then return nil end

    local button = _G[name .. "1"]
    if type(button) ~= "table" then return nil end
    if button.IsForbidden and button:IsForbidden() then return nil end

    -- `action` is the field Blizzard's action button mixin keeps up to date;
    -- the attribute is the secure copy of the same thing. Either will do.
    local ok, slot = pcall(function() return button.action end)
    if not ok or type(slot) ~= "number" then
        if type(button.GetAttribute) ~= "function" then return nil end
        local ok2, value = pcall(button.GetAttribute, button, "action")
        slot = ok2 and value or nil
    end

    if type(slot) == "number" and slot >= 1 then return slot end
    return nil
end

-- Does this bar exist on this client at all?
function Slots.BarExists(bar)
    return ProbeBase(bar) ~= nil
end

-- Highest bar number this client actually has.
function Slots.MaxBar()
    local max = 0
    for bar = 1, 8 do
        if Slots.BarExists(bar) then max = bar end
    end
    return max
end

-- First action slot of the given bar. Probing wins; the table below is only a
-- fallback for the moment before the bars are built, or a client that names its
-- buttons differently.
-- Only the ranges that have held across every client go here, and 12.1
-- confirmed all five. Bars 6-8 are deliberately absent: they sat at 73-108 when
-- they were introduced and are at 145-180 on 12.1.0, so there is no safe value
-- to guess. An unprobeable bar reports as unavailable instead, because binding
-- the wrong action slot is far worse than binding nothing.
local FALLBACK_BASE = {
    [1] = 1,    -- Action Bar 1  (main bar, page 1)      1-12
    [2] = 61,   -- Action Bar 2  (MultiBarBottomLeft)   61-72
    [3] = 49,   -- Action Bar 3  (MultiBarBottomRight)  49-60
    [4] = 25,   -- Action Bar 4  (MultiBarRight)        25-36
    [5] = 37,   -- Action Bar 5  (MultiBarLeft)         37-48
}

-- Returns nil when the bar cannot be located on this client.
function Slots.BaseFor(bar)
    local probed = ProbeBase(bar)
    if probed then return probed end

    if bar == 1 then
        -- Bar 1 pages on stance, stealth, dragonriding and vehicles. Probing
        -- handles that for free (the button reports its current slot); this is
        -- the arithmetic version for when probing is unavailable.
        local page
        if HasOverrideActionBar and HasOverrideActionBar() and GetOverrideBarIndex then
            page = GetOverrideBarIndex()
        elseif HasVehicleActionBar and HasVehicleActionBar() and GetVehicleBarIndex then
            page = GetVehicleBarIndex()
        else
            page = GetActionBarPage() or 1
        end
        return (page - 1) * ns.SLOTS_PER_BAR + 1
    end

    return FALLBACK_BASE[bar]
end

-- Kept for display only; BaseFor is the truth.
ns.BAR_BASE = FALLBACK_BASE

-- Absolute action slot for index 1..12 on the configured bar, or nil if the bar
-- cannot be located. Every caller must handle nil: no binding beats a wrong one.
function Slots.SlotFor(index)
    local base = Slots.BaseFor(ns.db and ns.db.bar or 8)
    if not base then return nil end
    return base + index - 1
end

-- Does this absolute slot belong to the bar we are sourcing from?
function Slots.OwnsSlot(slot)
    local base = Slots.BaseFor(ns.db and ns.db.bar or 8)
    if not base then return false end
    return slot >= base and slot < base + ns.SLOTS_PER_BAR
end

------------------------------------------------------------------------------
-- visual grid
--
-- Edit Mode lets a bar be laid out as rows x columns, and the order slots fill
-- that shape differs between clients. Rather than hard-code a fold order (which
-- would also break the moment the bar is reshaped), read where the buttons
-- actually are on screen and cluster them into rows and columns. This measures
-- the real layout on any client, including ones that did not exist when this
-- was written.
------------------------------------------------------------------------------

-- Returns grid (slot index -> {row, col}), rowCount, colCount -- or nil.
function Slots.GridLayout(bar)
    bar = bar or (ns.db and ns.db.bar) or 8
    local prefix = BAR_BUTTON[bar]
    if not prefix then return nil end

    local points, w, h = {}, nil, nil
    for index = 1, ns.SLOTS_PER_BAR do
        local button = _G[prefix .. index]
        if type(button) == "table" and not (button.IsForbidden and button:IsForbidden()) then
            local ok, x, y = pcall(function() return button:GetCenter() end)
            if ok and type(x) == "number" and type(y) == "number" then
                points[#points + 1] = { index = index, x = x, y = y }
                if not w then
                    local okw, bw, bh = pcall(function() return button:GetWidth(), button:GetHeight() end)
                    if okw then w, h = bw, bh end
                end
            end
        end
    end

    if #points < 2 then return nil end

    -- Half a button is a forgiving threshold: comfortably larger than the gap
    -- within a row, comfortably smaller than the step between rows.
    local tolY = math.max(4, (h or 30) * 0.5)
    local tolX = math.max(4, (w or 30) * 0.5)

    -- Cluster both axes globally rather than per row, so a ragged final row
    -- still lands in the right columns.
    local byY = {}
    for i, p in ipairs(points) do byY[i] = p end
    table.sort(byY, function(a, b) return a.y > b.y end)  -- top row first
    local row, lastY = 0, nil
    for _, p in ipairs(byY) do
        if lastY == nil or math.abs(p.y - lastY) > tolY then
            row = row + 1
            lastY = p.y
        end
        p.row = row
    end

    local byX = {}
    for i, p in ipairs(points) do byX[i] = p end
    table.sort(byX, function(a, b) return a.x < b.x end)  -- left column first
    local col, lastX = 0, nil
    for _, p in ipairs(byX) do
        if lastX == nil or math.abs(p.x - lastX) > tolX then
            col = col + 1
            lastX = p.x
        end
        p.col = col
    end

    local grid = {}
    for _, p in ipairs(points) do
        grid[p.index] = { row = p.row, col = p.col }
    end
    return grid, row, col
end

------------------------------------------------------------------------------
-- combos
------------------------------------------------------------------------------

ns.BUTTON_NAMES = { [1] = "Left", [2] = "Right", [3] = "Middle", [4] = "Button 4", [5] = "Button 5" }

local BUTTON_FROM_ARG = {
    LeftButton = 1, RightButton = 2, MiddleButton = 3, Button4 = 4, Button5 = 5,
}

function ns.ButtonNumber(arg)
    return BUTTON_FROM_ARG[arg] or tonumber(arg:match("^Button(%d)$") or "")
end

function ns.MakeCombo(button, alt, ctrl, shift)
    local p = ""
    if alt   then p = p .. "alt-"   end
    if ctrl  then p = p .. "ctrl-"  end
    if shift then p = p .. "shift-" end
    return p .. button
end

-- "alt-shift-1" -> "alt-shift-", "1"
function ns.SplitCombo(combo)
    local prefix, button = combo:match("^(.-)(%d+)$")
    return prefix or "", tonumber(button)
end

function ns.ComboText(combo)
    local prefix, button = ns.SplitCombo(combo)
    local parts = {}
    if prefix:find("alt-")   then parts[#parts + 1] = "Alt"   end
    if prefix:find("ctrl-")  then parts[#parts + 1] = "Ctrl"  end
    if prefix:find("shift-") then parts[#parts + 1] = "Shift" end
    parts[#parts + 1] = ns.BUTTON_NAMES[button] or ("Button " .. tostring(button))
    return table.concat(parts, " + ")
end

------------------------------------------------------------------------------
-- special (non-slot) bindings
--
-- These exist so the ordinary left-click-to-target and right-click-for-menu
-- behaviour is something you own rather than something you lose. Anything not
-- listed in the config is left exactly as the unit frame had it.
------------------------------------------------------------------------------

ns.SPECIALS = {
    { key = "target", label = "Target unit" },
    { key = "menu",   label = "Unit menu"   },
    { key = "focus",  label = "Set focus"   },
    { key = "assist", label = "Assist unit" },
    { key = "follow", label = "Follow unit" },
}

-- What this client calls "target the unit" and "open the unit menu".
--
-- Do not guess these. SecureActionButtonTemplate documents "togglemenu", but
-- Blizzard's own unit frames carry "*type2 = menu" -- a different verb, handled
-- by SecureUnitButton_OnClick rather than the generic action handler. Setting
-- the wrong one produces a click that silently does nothing.
--
-- So read the verbs off a real frame instead. Whatever this client uses to open
-- its own menus is what SlotCast uses too.
local DEFAULT_VERBS = { target = "target", menu = "togglemenu" }
local detectedVerbs

function ns.FrameVerb(which)
    if detectedVerbs then return detectedVerbs[which] end

    local sample = ns.Secure and ns.Secure.SampleFrame and ns.Secure.SampleFrame()
    if not sample then
        -- Nothing to learn from yet; answer from the defaults without caching,
        -- so the real values are picked up once frames exist.
        return DEFAULT_VERBS[which]
    end

    local verbs = { target = DEFAULT_VERBS.target, menu = DEFAULT_VERBS.menu }
    for attr, key in pairs({ ["*type1"] = "target", ["*type2"] = "menu" }) do
        local ok, value = pcall(sample.GetAttribute, sample, attr)
        if ok and type(value) == "string" and value ~= "" then verbs[key] = value end
    end

    detectedVerbs = verbs
    return verbs[which]
end

function ns.WipeFrameVerbs()
    detectedVerbs = nil
end

local SPECIAL_SPEC = {
    target = function() return { type = ns.FrameVerb("target") } end,
    menu   = function() return { type = ns.FrameVerb("menu") } end,
    focus  = function() return { type = "focus" } end,
    assist = function() return { type = "assist" } end,
    -- There is no "follow" action type, and RunMacroText gets no unit, so this
    -- one leans on mouseover -- which is always correct for a click-cast, since
    -- the cursor is over the frame by definition.
    follow = function() return { type = "macro", key = "macrotext", value = "/follow [@mouseover,exists]" } end,
}

------------------------------------------------------------------------------
-- reading a slot
------------------------------------------------------------------------------

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name then return info.name end
    end
    if GetSpellInfo then return (GetSpellInfo(id)) end
    return nil
end

-- A spell's subtext. On a rank-enabled client this is the localised rank
-- string -- "Rank 2", "Rang 2", "Rango 2" -- which is exactly the text the
-- cast parser expects inside the parentheses. Never build it by hand: the
-- word is translated and only the client knows the right one.
local function SpellRank(id)
    local rank

    if C_Spell and C_Spell.GetSpellSubtext then
        local ok, value = pcall(C_Spell.GetSpellSubtext, id)
        if ok then rank = value end
    end
    if (not rank or rank == "") and GetSpellSubtext then
        local ok, value = pcall(GetSpellSubtext, id)
        if ok then rank = value end
    end
    if (not rank or rank == "") and GetSpellInfo then
        -- Classic-era signature returns rank as the second value.
        local ok, _, value = pcall(GetSpellInfo, id)
        if ok then rank = value end
    end

    if type(rank) ~= "string" or rank == "" then return nil end

    -- Retail uses subtext for all sorts of things that are not ranks: dungeon
    -- names ("Pit of Saron"), systems ("Skyriding", "Battle Pets") -- and, on
    -- 12.1, "Battle for Azeroth Pathfinder" whose subtext is literally
    -- "Rank 2". A digit test alone is not enough.
    if not rank:find("%d") then return nil end

    return rank
end

-- Is "Name(Rank 2)" a real rank selector on this client?
--
-- The obvious test -- does the parenthesised form resolve to a spell -- is
-- worthless, and retail 12.1 proved it: C_Spell.GetSpellInfo strips the
-- parenthetical and happily resolves the base name, so
-- "Revive Battle Pets(Battle Pets)" came back valid. Every non-rank subtext
-- passed.
--
-- What a parenthetical cannot fake is CHANGING which spell is named. On a
-- client with ranks, "Renew" resolves to the highest rank and "Renew(Rank 2)"
-- resolves to rank 2 -- different spell ids. On a client without ranks both
-- resolve to the same id, because the suffix was ignored.
--
-- The one case this reports "no" on a genuinely ranked client is a slot holding
-- the HIGHEST rank, where both forms name the same spell. Casting rankless
-- there is identical in effect, so the false negative is free.
local rankFormCache = {}

local function ResolveSpellID(identifier)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, identifier)
        if ok and type(info) == "table" then return info.spellID end
        return nil
    end
    if _G.GetSpellInfo then
        -- Classic signature: name, rank, icon, castTime, minRange, maxRange, spellID
        local packed = { pcall(_G.GetSpellInfo, identifier) }
        if packed[1] and packed[2] then return packed[8] end
    end
    return nil
end

ns.ResolveSpellID = ResolveSpellID

-- Returns usable, plainID, rankedID (the ids are for diagnostics).
local function RankIsSelectable(name, rank)
    local key = name .. "\1" .. rank
    local cached = rankFormCache[key]
    if cached ~= nil then return cached[1], cached[2], cached[3] end

    local plainID  = ResolveSpellID(name)
    local rankedID = ResolveSpellID(("%s(%s)"):format(name, rank))

    local usable = (rankedID ~= nil) and (plainID ~= nil) and (rankedID ~= plainID)

    rankFormCache[key] = { usable, plainID, rankedID }
    return usable, plainID, rankedID
end

ns.RankIsSelectable = RankIsSelectable

function ns.WipeRankCache()
    wipe(rankFormCache)
end

-- "Rank 2" -> "R2", for the cramped options row.
function ns.ShortRank(rank)
    local n = rank and rank:match("%d+")
    return n and ("R" .. n) or "R?"
end

------------------------------------------------------------------------------
-- rank mode
--
-- Every action slot holds one specific rank -- in Classic each rank is its own
-- spell ID and its own spellbook entry, so there is no rankless thing to drag.
-- The binding therefore has to choose which string to emit:
--
--   "slot"    -> "Renew(Rank 2)"  cast exactly what is in the slot
--   "highest" -> "Renew"          cast the highest rank learned
--
-- This is per-slot on purpose. Downranking is the entire reason ranks matter,
-- and a healer wants Flash Heal at max and Greater Heal at Rank 3 at the same
-- time, from two different clicks.
------------------------------------------------------------------------------

ns.RANK_MODES = { slot = "slot", highest = "highest" }

function ns.RankModeFor(index)
    if type(index) ~= "number" then return ns.db and ns.db.rankMode or "slot" end
    local overrides = ns.db and ns.db.rankOverrides
    return (overrides and overrides[index]) or (ns.db and ns.db.rankMode) or "slot"
end

function ns.SetRankModeFor(index, mode)
    if not ns.db.rankOverrides then ns.db.rankOverrides = {} end
    ns.db.rankOverrides[index] = (mode ~= ns.db.rankMode) and mode or nil
end

-- Returns a spec table describing what to put on the button, or nil for empty.
--   { type = <secure action type>, key = <payload attribute>, value = <payload>,
--     label = <human text>, icon = <texture>, note = <caveat for the UI> }
-- Wrap a cast string for the configured cast mode.
--   "spell" -> type="spell",  the secure handler passes the frame's unit
--   "macro" -> type="macro",  "/cast [@mouseover] ..." as a fallback if a
--              client's CastSpellByName rejects the parenthesised rank form
local function CastSpec(castString, label, icon, rank, mode)
    if (ns.db and ns.db.castMode) == "macro" then
        return {
            type = "macro", key = "macrotext",
            value = "/cast [@mouseover,exists][] " .. castString,
            label = label, icon = icon, rank = rank, rankMode = mode, cast = castString,
        }
    end
    return {
        type = "spell", key = "spell", value = castString,
        label = label, icon = icon, rank = rank, rankMode = mode, cast = castString,
    }
end

-- `index` is the 1..12 slot position, needed to look up its rank mode. It is
-- optional: without it the global default applies.
function Slots.ReadSlot(slot, index)
    if not slot or not HasAction(slot) then return nil end

    local kind, id = GetActionInfo(slot)
    local icon = GetActionTexture(slot)
    if not kind then return nil end

    if kind == "spell" then
        local name = SpellName(id)
        if not name then return nil end

        local rank = SpellRank(id)
        local mode = ns.RankModeFor(index)

        -- "Renew(Rank 2)" casts that rank exactly; "Renew" casts the highest
        -- rank known. The parentheses are the cast parser's own syntax, so the
        -- rank string has to be the client's localised one, not a rebuilt one.
        -- A subtext is only usable as a rank if naming it actually selects a
        -- different spell than the bare name. Anything else is flavour text.
        if rank and not RankIsSelectable(name, rank) then rank = nil end

        local castString = name
        local label = name
        if rank then
            if mode == "highest" then
                label = ("%s |cff808080(max)|r"):format(name)
            else
                castString = ("%s(%s)"):format(name, rank)
                label = ("%s |cff80c0ff(%s)|r"):format(name, rank)
            end
        end

        -- type="spell" is the one that matters: SecureActionButton_OnClick
        -- resolves the frame's own unit attribute and casts on it, so this
        -- works on any registered unit frame with no per-frame macro text.
        return CastSpec(castString, label, icon, rank, mode)

    elseif kind == "item" then
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
                  or (GetItemInfo and GetItemInfo(id))
                  or ("item:" .. id)
        return { type = "item", key = "item", value = "item:" .. id, label = name, icon = icon }

    elseif kind == "macro" then
        local body = GetMacroBody(id) or ""
        local name = (GetMacroInfo(id)) or ("Macro " .. id)
        -- A macro gets no unit from the secure handler; it runs exactly as
        -- typed. Unless it carries its own @mouseover/@target conditional it
        -- will act on the current target, not the frame you clicked.
        local note = not body:find("@", 1, true)
            and "Macro has no @mouseover - it will act on your current target, not the clicked unit."
            or nil
        return { type = "macro", key = "macrotext", value = body, label = name, icon = icon, note = note }

    elseif kind == "summonmount" then
        local mountName = C_MountJournal and C_MountJournal.GetMountInfoByID and (C_MountJournal.GetMountInfoByID(id))
        if mountName then
            return { type = "macro", key = "macrotext", value = "/cast " .. mountName, label = mountName, icon = icon }
        end
        return { unsupported = true, label = "Mount", icon = icon, note = "Mount could not be resolved." }

    elseif kind == "equipmentset" then
        local name = tostring(id)
        return { type = "macro", key = "macrotext", value = "/equipset " .. name, label = "Equip: " .. name, icon = icon }

    elseif kind == "flyout" then
        return { unsupported = true, label = "Flyout", icon = icon,
                 note = "Flyouts cannot be click-cast - they need a popup. Put the individual spell in the slot instead." }

    else
        return { unsupported = true, label = kind, icon = icon,
                 note = ("Action type '%s' is not supported as a click binding."):format(kind) }
    end
end

-- What a bind value resolves to, whether it is a slot index or a special.
function Slots.ResolveBind(value)
    if type(value) == "number" then
        return Slots.ReadSlot(Slots.SlotFor(value), value)  -- SlotFor may be nil; ReadSlot handles it
    end
    local build = SPECIAL_SPEC[value]
    if not build then return nil end
    local spec = build()
    local label
    for _, s in ipairs(ns.SPECIALS) do
        if s.key == value then label = s.label break end
    end
    return { type = spec.type, key = spec.key, value = spec.value, label = label or value, special = true }
end

------------------------------------------------------------------------------
-- the plan
--
-- A flat list of {attribute name, value} pairs that describes the whole binding
-- set. Building it once and handing the same list to every frame keeps the
-- secure writes identical across frames and makes restoring originals easy.
------------------------------------------------------------------------------

ns.PAYLOAD_KEYS = { "spell", "item", "macrotext", "macro", "action" }

Slots.plan = {}
Slots.planAttrs = {}

function Slots.BuildPlan()
    local plan, attrs = {}, {}

    local function put(name, value)
        plan[#plan + 1] = { attr = name, value = value }
        attrs[name] = true
    end

    if ns.db.enabled then
        for combo, value in pairs(ns.db.binds) do
            local prefix, button = ns.SplitCombo(combo)
            if button then
                local spec = Slots.ResolveBind(value)
                local live = spec and not spec.unsupported and spec.type

                put(prefix .. "type" .. button, live or nil)
                -- Always write every payload key, nil included. Otherwise a
                -- stale "shift-spell1" survives a change from spell to item and
                -- the secure handler picks up the wrong one.
                for _, key in ipairs(ns.PAYLOAD_KEYS) do
                    put(prefix .. key .. button, (live and spec.key == key) and spec.value or nil)
                end
            end
        end
    end

    Slots.plan, Slots.planAttrs = plan, attrs
    return plan
end

function Slots.PrintPlan()
    local n = 0
    for combo, value in pairs(ns.db.binds) do
        local spec = Slots.ResolveBind(value)
        local what = spec and spec.label or "|cff888888empty|r"
        if spec and spec.unsupported then what = "|cffff5555" .. (spec.label or "?") .. " (unsupported)|r" end
        local src = type(value) == "number" and ("slot %d"):format(value) or "action"
        if spec and spec.cast then src = ("%s, casts \"%s\""):format(src, spec.cast) end
        ns.Print("  %s -> %s (%s)", ns.ComboText(combo), what, src)
        n = n + 1
    end
    if n == 0 then ns.Print("  no bindings configured") end
end
