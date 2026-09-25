-- SlotCast :: Conflicts
-- Reads bindings set in Blizzard's built-in Click Bindings UI.
--
-- Field names and enum values here are CONFIRMED against retail 12.1.0 (build
-- 69933) rather than guessed:
--
--   entry = { actionID = number, button = "LeftButton", modifiers = 0, type = 3 }
--   Enum.ClickBindingType        = { None=0, Spell=1, Macro=2, Interaction=3, PetAction=4 }
--   Enum.ClickBindingInteraction = { Target=1, OpenContextMenu=2 }
--
-- The reads stay defensive anyway, because this has to run on clients that were
-- never checked.
--
-- The important discovery: Blizzard implements these as *wildcard* attributes
-- (a unit frame carries "*type1 = target", "*type2 = menu"), and a specific
-- attribute beats a wildcard in SecureButton_GetModifiedAttribute's lookup
-- order. So a SlotCast binding does not fight a Blizzard one -- it overrides it.
-- Nothing double-fires, and the two default Interaction entries every client
-- ships are not a conflict at all.

local ADDON, ns = ...

ns.Conflicts = {}
local Conflicts = ns.Conflicts

local function API()
    return _G.C_ClickBindings
end

function Conflicts.Available()
    local api = API()
    return api and type(api.GetProfileInfo) == "function"
end

------------------------------------------------------------------------------
-- normalising Blizzard's entries into our combo strings
------------------------------------------------------------------------------

local BUTTON_FROM_STRING = {
    LEFTBUTTON = 1, RIGHTBUTTON = 2, MIDDLEBUTTON = 3,
    BUTTON1 = 1, BUTTON2 = 2, BUTTON3 = 3, BUTTON4 = 4, BUTTON5 = 5,
}

local function ButtonOf(entry)
    local raw = entry.button or entry.mouseButton or entry.buttonName
    if type(raw) == "number" then return raw end
    if type(raw) ~= "string" then return nil end
    local up = raw:upper()
    return BUTTON_FROM_STRING[up] or tonumber(up:match("BUTTON(%d)") or "")
end

-- Returns alt, ctrl, shift (or nil, nil, nil, rawValue if undecodable).
local function ModifiersOf(entry)
    local mods = entry.modifiers or entry.modifierMask or 0

    -- Zero is unambiguous and by far the common case; do not make it depend on
    -- how GetStringFromModifiers formats an empty set.
    if mods == 0 then return false, false, false end

    local api = API()
    if api and type(api.GetStringFromModifiers) == "function" then
        local ok, str = pcall(api.GetStringFromModifiers, mods)
        if ok and type(str) == "string" then
            str = str:upper()
            return str:find("ALT") ~= nil,
                   (str:find("CTRL") or str:find("CONTROL")) ~= nil,
                   str:find("SHIFT") ~= nil
        end
    end
    return nil, nil, nil, mods
end

-- Returns a human description and a kind: "interaction" for Blizzard's two
-- built-in defaults, "action" for anything a user actually chose.
local function DescribeAction(entry)
    local kind = entry.type
    local id = entry.actionID or entry.actionId or entry.spellID
    local E = _G.Enum and _G.Enum.ClickBindingType

    if not E then
        return ("type %s / id %s"):format(tostring(kind), tostring(id)), "action"
    end

    if kind == E.None then
        return nil, nil

    elseif kind == E.Spell and id then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return "spell: " .. ((info and info.name) or tostring(id)), "action"

    elseif kind == E.Macro and id then
        local name = GetMacroInfo and GetMacroInfo(id)
        return "macro: " .. (name or tostring(id)), "action"

    elseif kind == E.PetAction and id then
        return "pet action: " .. tostring(id), "action"

    elseif kind == E.Interaction then
        -- These two are the client's ordinary target / context-menu behaviour
        -- expressed as click bindings. Every character has them.
        local I = _G.Enum and _G.Enum.ClickBindingInteraction
        if I and id == I.Target then return "target unit (default)", "interaction" end
        if I and id == I.OpenContextMenu then return "unit menu (default)", "interaction" end
        return "interaction " .. tostring(id), "interaction"
    end

    return ("type %s / id %s"):format(tostring(kind), tostring(id)), "action"
end

-- Array of { combo, text, action, kind, raw }
function Conflicts.GetBindings()
    if not Conflicts.Available() then return nil end

    local ok, info = pcall(API().GetProfileInfo)
    if not ok or type(info) ~= "table" then return nil end

    local out = {}
    for _, entry in ipairs(info) do
        if type(entry) == "table" then
            local action, kind = DescribeAction(entry)
            if action then
                local button = ButtonOf(entry)
                local alt, ctrl, shift, rawMods = ModifiersOf(entry)
                local combo, text
                if button and alt ~= nil then
                    combo = ns.MakeCombo(button, alt, ctrl, shift)
                    text = ns.ComboText(combo)
                else
                    text = ("button %s / modifiers %s"):format(tostring(button or "?"), tostring(rawMods or "?"))
                end
                out[#out + 1] = { combo = combo, text = text, action = action, kind = kind, raw = entry }
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- reporting
------------------------------------------------------------------------------

-- Returns: overridden (array of {text, action, kind, mine}), total count.
-- "Overridden" rather than "conflicting" -- see the note at the top of the file.
function Conflicts.Find()
    local blizz = Conflicts.GetBindings()
    if not blizz then return nil, 0 end

    local overridden = {}
    for _, b in ipairs(blizz) do
        if b.combo and ns.db.binds[b.combo] ~= nil then
            local spec = ns.Slots.ResolveBind(ns.db.binds[b.combo])
            overridden[#overridden + 1] = {
                text   = b.text,
                action = b.action,
                kind   = b.kind,
                mine   = spec and spec.label or "(empty slot)",
            }
        end
    end
    return overridden, #blizz
end

-- Only user-chosen bindings are worth mentioning. The two Interaction defaults
-- are overridden on every character that uses SlotCast at all, and saying so
-- would be noise on every single login.
local function RealOverrides(overridden)
    local out = {}
    for _, entry in ipairs(overridden or {}) do
        if entry.kind ~= "interaction" then out[#out + 1] = entry end
    end
    return out
end

function Conflicts.Report(verbose)
    if not Conflicts.Available() then
        ns.Print("this client has no Blizzard click-binding API.")
        return
    end

    local overridden, total = Conflicts.Find()
    if not overridden then
        ns.Print("could not read Blizzard's click bindings.")
        return
    end

    if verbose then
        ns.Print("Blizzard click bindings: %d", total)
        for _, b in ipairs(Conflicts.GetBindings() or {}) do
            ns.Print("  %s -> %s%s", b.text, b.action,
                b.combo and ns.db.binds[b.combo] ~= nil and " |cffffcc00(SlotCast overrides)|r" or "")
        end
    end

    local real = RealOverrides(overridden)
    if #real == 0 then
        if verbose then ns.Print("nothing of yours is being overridden.") end
        return
    end

    ns.Warn("SlotCast overrides %d of your Blizzard click binding(s):", #real)
    for _, entry in ipairs(real) do
        ns.Warn("  %s - Blizzard: %s | SlotCast: %s", entry.text, entry.action, entry.mine)
    end
    ns.Warn("SlotCast wins on those clicks. Unbind one side if that is not what you want.")
end

function Conflicts.ReportOnLogin()
    local overridden = Conflicts.Find()
    if overridden and #RealOverrides(overridden) > 0 then Conflicts.Report(false) end
end

function Conflicts.Clear()
    local api = API()
    if not api then return false end
    if type(api.ResetCurrentProfile) == "function" then
        if pcall(api.ResetCurrentProfile) then return true end
    end
    if type(api.SetProfileByInfo) == "function" then
        if pcall(api.SetProfileByInfo, {}) then return true end
    end
    return false
end

------------------------------------------------------------------------------
-- the actions Blizzard's system owns
------------------------------------------------------------------------------

local INTERACTION_FOR = { target = "Target", menu = "OpenContextMenu" }

------------------------------------------------------------------------------
-- the manual route
--
-- Writing the profile is the convenient path, not the reliable one. Setting the
-- binding by hand in Blizzard's own UI always works, so make that easy to reach
-- and spell out rather than leaving the user to hunt for it.
------------------------------------------------------------------------------

-- What Blizzard's profile currently has bound to one of the actions it owns.
-- Returns display text, or nil if that action is unbound there.
function Conflicts.BindingTextFor(action)
    if not Conflicts.Available() then return nil end

    local E = _G.Enum and _G.Enum.ClickBindingType
    local I = _G.Enum and _G.Enum.ClickBindingInteraction
    if not E or not I then return nil end

    local want = I[INTERACTION_FOR[action]]
    if want == nil then return nil end

    for _, binding in ipairs(Conflicts.GetBindings() or {}) do
        local raw = binding.raw
        if raw and raw.type == E.Interaction and (raw.actionID or raw.actionId) == want then
            return binding.text
        end
    end
    return nil
end

-- Run a slash command by its text, whatever handler the client filed it under.
-- Looking the command up beats hardcoding a frame name: the UI behind
-- /clickcasting has been rebuilt more than once, but the command has not.
local function RunSlashCommand(command)
    command = command:lower()
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "string" and value:lower() == command then
            local handler = key:match("^SLASH_(.+)%d+$")
            if handler and type(SlashCmdList) == "table" and type(SlashCmdList[handler]) == "function" then
                if pcall(SlashCmdList[handler], "") then return true, command end
            end
        end
    end
    return false
end

ns.RunSlashCommand = RunSlashCommand

function Conflicts.OpenBlizzardUI()
    -- The slash command first: it is the documented way in and survives the
    -- frame being renamed or rebuilt.
    local ok, how = RunSlashCommand("/clickcasting")
    if ok then return true, how end

    local attempts = {
        { "ClickBindingFrame", function()
            if _G.ClickBindingFrame then _G.ClickBindingFrame:Show() return true end
        end },
        { "PlayerSpellsUtil", function()
            local util = _G.PlayerSpellsUtil
            if util and util.TogglePlayerSpellsFrame then util.TogglePlayerSpellsFrame() return true end
        end },
        { "ToggleSpellBook", function()
            if _G.ToggleSpellBook then _G.ToggleSpellBook("spell") return true end
        end },
    }

    for _, attempt in ipairs(attempts) do
        local okAttempt, opened = pcall(attempt[2])
        if okAttempt and opened then return true, attempt[1] end
    end
    return false
end

function Conflicts.ExplainManualBinding(combo, action)
    local opened, how = Conflicts.OpenBlizzardUI()

    local body
    if opened then
        body = table.concat({
            "This is WoW's own Click Bindings window, not SlotCast's.",
            "",
            "Bind |cffffffffONLY|r these two here:",
            "     |cffffcc00Target Unit Frame|r",
            "     |cffffcc00Open Context Menu|r",
            "",
            "Then press |cffffffffSave|r.",
            "",
            "SlotCast reads them back and shows them in its own list.",
            "Every other click stays in SlotCast - don't bind spells here,",
            "or the two systems will fight over the same click.",
        }, "\n")
    else
        body = table.concat({
            "Couldn't open it from here. Type |cffffcc00/clickcasting|r to open it yourself.",
            "",
            "Bind |cffffffffONLY|r these two there:",
            "     |cffffcc00Target Unit Frame|r",
            "     |cffffcc00Open Context Menu|r",
            "",
            "Then press |cffffffffSave|r.",
            "",
            "SlotCast reads them back and shows them in its own list.",
        }, "\n")
    end

    if ns.ShowNotice then
        ns.ShowNotice("Bind these in WoW's Click Bindings", body, "hideClickcastingNotice")
    else
        ns.Print("Bind Target Unit Frame and Open Context Menu in /clickcasting, then Save.")
    end

    if not opened then
        ns.Warn("Could not open Click Bindings - type |cffffff00/clickcasting|r.")
    end

    return opened, how
end
