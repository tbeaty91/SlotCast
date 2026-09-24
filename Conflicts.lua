-- SlotCast :: Conflicts
-- Detects bindings set in Blizzard's built-in Click Bindings UI (Spellbook ->
-- Click Bindings, retail 10.0+). Those run through their own secure path and
-- will fire *in addition to* ours on the same click, so the overlap needs to be
-- visible rather than mysterious.
--
-- The exact field names in the ClickBindingInfo struct are the one thing in
-- this addon that cannot be checked outside the game, so every read here is
-- defensive and `/slotcast dump` prints the raw structure for verification.

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
    BUTTON1 = 1, BUTTON2 = 2, BUTTON3 = 3, BUTTON4 = 4, BUTTON5 = 5,
    LEFTBUTTON = 1, RIGHTBUTTON = 2, MIDDLEBUTTON = 3,
}

local function ButtonOf(entry)
    local raw = entry.button or entry.mouseButton or entry.buttonName
    if type(raw) == "number" then return raw end
    if type(raw) ~= "string" then return nil end
    local up = raw:upper()
    return BUTTON_FROM_STRING[up] or tonumber(up:match("BUTTON(%d)") or "")
end

-- Returns alt, ctrl, shift. Prefers the API's own formatter over guessing at
-- the bitfield layout.
local function ModifiersOf(entry)
    local mods = entry.modifiers or entry.modifierMask or 0
    local api = API()
    if api and type(api.GetStringFromModifiers) == "function" then
        local ok, str = pcall(api.GetStringFromModifiers, mods)
        if ok and type(str) == "string" then
            str = str:upper()
            return str:find("ALT") ~= nil, (str:find("CTRL") or str:find("CONTROL")) ~= nil, str:find("SHIFT") ~= nil
        end
    end
    return nil, nil, nil, mods
end

local function DescribeAction(entry)
    local kind = entry.type
    local id = entry.actionID or entry.actionId or entry.spellID
    local E = _G.Enum and _G.Enum.ClickBindingType

    if E and kind == E.Spell and id then
        local name = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return "spell: " .. ((name and name.name) or tostring(id))
    elseif E and kind == E.Macro and id then
        return "macro: " .. ((GetMacroInfo and GetMacroInfo(id)) or tostring(id))
    elseif E and kind == E.Interaction then
        return "interaction"
    elseif E and kind == E.None then
        return nil
    end
    return ("type %s / id %s"):format(tostring(kind), tostring(id))
end

-- Array of { combo = "shift-1" | nil, text = "Shift + Left", action = "spell: Renew", raw = entry }
function Conflicts.GetBindings()
    if not Conflicts.Available() then return nil end

    local ok, info = pcall(API().GetProfileInfo)
    if not ok or type(info) ~= "table" then return nil end

    local out = {}
    for _, entry in ipairs(info) do
        if type(entry) == "table" then
            local action = DescribeAction(entry)
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
                out[#out + 1] = { combo = combo, text = text, action = action, raw = entry }
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- reporting
------------------------------------------------------------------------------

-- Returns an array of { text, action, mine } for combos bound on both sides,
-- plus the total count of Blizzard bindings.
function Conflicts.Find()
    local blizz = Conflicts.GetBindings()
    if not blizz then return nil, 0 end

    local clashes = {}
    for _, b in ipairs(blizz) do
        if b.combo and ns.db.binds[b.combo] ~= nil then
            local spec = ns.Slots.ResolveBind(ns.db.binds[b.combo])
            clashes[#clashes + 1] = {
                text   = b.text,
                action = b.action,
                mine   = spec and spec.label or "(empty slot)",
            }
        end
    end
    return clashes, #blizz
end

function Conflicts.Report(verbose)
    if not Conflicts.Available() then
        ns.Print("this client has no Blizzard click-binding API to check.")
        return
    end

    local clashes, total = Conflicts.Find()
    if not clashes then
        ns.Print("could not read Blizzard's click bindings.")
        return
    end

    if verbose then
        ns.Print("Blizzard click bindings: %d", total)
        for _, b in ipairs(Conflicts.GetBindings() or {}) do
            ns.Print("  %s -> %s", b.text, b.action)
        end
    end

    if #clashes == 0 then
        if verbose then ns.Print("no overlap with SlotCast bindings.") end
        return
    end

    ns.Warn("%d click(s) bound in BOTH Blizzard's Click Bindings and SlotCast:", #clashes)
    for _, c in ipairs(clashes) do
        ns.Warn("  %s - Blizzard: %s | SlotCast: %s", c.text, c.action, c.mine)
    end
    ns.Warn("Both will fire. Clear them in the Spellbook's Click Bindings tab, or use /slotcast to move yours.")
end

function Conflicts.ReportOnLogin()
    local clashes = Conflicts.Find()
    if clashes and #clashes > 0 then Conflicts.Report(false) end
end

function Conflicts.Clear()
    local api = API()
    if not api then return false end
    if type(api.ResetCurrentProfile) == "function" then
        local ok = pcall(api.ResetCurrentProfile)
        if ok then return true end
    end
    if type(api.SetProfileByInfo) == "function" then
        local ok = pcall(api.SetProfileByInfo, {})
        if ok then return true end
    end
    return false
end

------------------------------------------------------------------------------
-- raw dump
------------------------------------------------------------------------------

local function DumpValue(value, indent)
    if type(value) ~= "table" then
        return ("%s%s"):format(indent, tostring(value))
    end
    local lines = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            lines[#lines + 1] = ("%s%s = {"):format(indent, tostring(k))
            lines[#lines + 1] = DumpValue(v, indent .. "  ")
            lines[#lines + 1] = indent .. "}"
        else
            lines[#lines + 1] = ("%s%s = %s (%s)"):format(indent, tostring(k), tostring(v), type(v))
        end
    end
    return table.concat(lines, "\n")
end

function Conflicts.Dump()
    if not Conflicts.Available() then
        ns.Print("C_ClickBindings is not present on this client.")
        return
    end
    local ok, info = pcall(API().GetProfileInfo)
    if not ok then
        ns.Print("GetProfileInfo() errored: %s", tostring(info))
        return
    end
    ns.Print("raw C_ClickBindings.GetProfileInfo():")
    print(DumpValue(info, "  "))

    if _G.Enum and _G.Enum.ClickBindingType then
        ns.Print("Enum.ClickBindingType:")
        print(DumpValue(_G.Enum.ClickBindingType, "  "))
    end
end
