-- SlotCast :: Probe
-- /slotcast probe
--
-- Collects everything about this client that cannot be determined from outside
-- the game, into one copyable block. Deliberately reports what is *missing* as
-- well as what is present: "C_ClickBindings = nil" is as useful an answer as a
-- dump of it.
--
-- Nothing identifying is collected - no character name, no realm, no guild.

local ADDON, ns = ...

ns.Probe = {}
local Probe = ns.Probe

local REPORT_VERSION = 5

------------------------------------------------------------------------------
-- report building
------------------------------------------------------------------------------

local lines

local function add(text)
    lines[#lines + 1] = text or ""
end

-- Every argument is stringified, so data can never be mistaken for a format
-- directive (spell names and macro bodies contain % often enough to matter).
local function addf(pattern, ...)
    local n = select("#", ...)
    local args = {}
    for i = 1, n do args[i] = tostring((select(i, ...))) end
    add((pattern):format(unpack(args, 1, n)))
end

local function section(title)
    add("")
    addf("--- %s ---", title)
end

-- Dotted global lookup that survives anything missing in the middle.
local function Lookup(path)
    local obj = _G
    for part in path:gmatch("[^.]+") do
        if type(obj) ~= "table" then return nil end
        local ok, value = pcall(function() return obj[part] end)
        if not ok or value == nil then return nil end
        obj = value
    end
    return obj
end

local function ReportAPI(path)
    local value = Lookup(path)
    if value == nil then
        addf("  %s = nil", path)
    else
        addf("  %s = %s", path, type(value))
    end
end

-- Call something and report either its returns or why it failed.
local function Call(label, path, ...)
    local fn = Lookup(path)
    if type(fn) ~= "function" then
        addf("  %s: %s is not callable", label, path)
        return
    end
    local packed = { pcall(fn, ...) }
    if not packed[1] then
        addf("  %s: ERROR %s", label, packed[2])
        return
    end
    local out = {}
    for i = 2, #packed do out[#out + 1] = tostring(packed[i]) end
    addf("  %s: %s", label, #out > 0 and table.concat(out, " | ") or "(no returns)")
end

------------------------------------------------------------------------------
-- 1. client identity
------------------------------------------------------------------------------

local function ProbeClient()
    section("1. CLIENT")

    local version, build, date, toc = GetBuildInfo()
    addf("  GetBuildInfo: version=%s build=%s date=%s tocversion=%s", version, build, date, toc)
    addf("  locale: %s", GetLocale and GetLocale() or "?")

    local _, class = UnitClass("player")
    addf("  player: class=%s level=%s", class, UnitLevel("player"))

    -- Scanning for the constants rather than listing the ones I know means a
    -- project ID that did not exist yet still shows up here.
    local projects = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and key:find("^WOW_PROJECT_") then
            projects[#projects + 1] = ("%s=%s"):format(key, tostring(value))
        end
    end
    table.sort(projects)
    addf("  WOW_PROJECT_* : %s", #projects > 0 and table.concat(projects, "  ") or "none defined")

    for _, name in ipairs({ "IsTestBuild", "IsPublicBuild", "GetCurrentRegion" }) do
        if type(_G[name]) == "function" then Call(name, name) end
    end
end

------------------------------------------------------------------------------
-- 2. action bars  (which exist, and which slots they drive)
------------------------------------------------------------------------------

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

local function SlotOfButton(button)
    if type(button) ~= "table" then return nil, "missing" end
    if button.IsForbidden and button:IsForbidden() then return nil, "forbidden" end

    local ok, slot = pcall(function() return button.action end)
    if ok and type(slot) == "number" then return slot, ".action" end

    if type(button.GetAttribute) == "function" then
        local ok2, value = pcall(button.GetAttribute, button, "action")
        if ok2 and type(value) == "number" then return value, "attribute" end
    end
    return nil, "no action field"
end

local function ProbeBars()
    section("2. ACTION BARS")

    addf("  GetActionBarPage=%s  NUM_ACTIONBAR_BUTTONS=%s  NUM_ACTIONBAR_PAGES=%s",
        GetActionBarPage and GetActionBarPage() or "?",
        _G.NUM_ACTIONBAR_BUTTONS, _G.NUM_ACTIONBAR_PAGES)

    for bar = 1, 8 do
        local prefix = BAR_BUTTON[bar]
        local first, how = SlotOfButton(_G[prefix .. "1"])
        local last = SlotOfButton(_G[prefix .. "12"])
        if first then
            addf("  bar %s (%s1): slots %s..%s  [via %s]", bar, prefix, first, last or "?", how)
        else
            addf("  bar %s (%s1): ABSENT (%s)", bar, prefix, how)
        end
    end

    -- The visual grid, measured from where the buttons actually sit. This is
    -- what differs between clients: the same Edit Mode shape can fill in a
    -- different order, so slot 4 may be row 1 col 4 on one client and row 2
    -- col 1 on another.
    local grid, rows, cols = ns.Slots.GridLayout()
    if grid then
        addf("  source bar %s visual grid: %s columns x %s rows", ns.db.bar, cols, rows)
        local cells = {}
        for index = 1, ns.SLOTS_PER_BAR do
            local cell = grid[index]
            cells[#cells + 1] = cell and ("%d=r%dc%d"):format(index, cell.row, cell.col)
                                      or ("%d=?"):format(index)
        end
        addf("    %s", table.concat(cells, "  "))

        -- Same thing drawn as the grid, which makes the fold order obvious.
        for r = 1, rows do
            local line = {}
            for c = 1, cols do
                local found = "  ."
                for index = 1, ns.SLOTS_PER_BAR do
                    local cell = grid[index]
                    if cell and cell.row == r and cell.col == c then
                        found = ("%3d"):format(index)
                        break
                    end
                end
                line[#line + 1] = found
            end
            addf("    row %s: %s", r, table.concat(line, " "))
        end
    else
        addf("  source bar %s: could not read button positions (bar disabled?)", ns.db.bar)
    end

    -- How high do action slots actually go on this client?
    local highest = 0
    for slot = 1, 240 do
        local ok, has = pcall(HasAction, slot)
        if ok and has then highest = slot end
    end
    addf("  highest slot with an action on it: %s", highest)
end

------------------------------------------------------------------------------
-- 3. spell ranks  (the big unknown)
------------------------------------------------------------------------------

local function ProbeSpellAPIs()
    section("3a. SPELL API PRESENCE")
    for _, path in ipairs({
        "GetSpellInfo", "GetSpellSubtext", "CastSpellByName", "CastSpellByID",
        "C_Spell.GetSpellInfo", "C_Spell.GetSpellSubtext", "C_Spell.CastSpell",
        "C_Spell.GetSpellName", "C_SpellBook.GetSpellBookItemInfo",
        "C_SpellBook.GetSpellBookItemName", "C_SpellBook.GetNumSpellBookSkillLines",
        "GetNumSpellTabs", "GetSpellBookItemInfo", "GetSpellBookItemName", "GetSpellTabInfo",
    }) do
        ReportAPI(path)
    end
end

-- Everything the client will tell us about one spell id.
local function DescribeSpell(label, id)
    addf("  %s  id=%s", label, id)

    if type(_G.GetSpellInfo) == "function" then
        local packed = { pcall(GetSpellInfo, id) }
        if packed[1] then
            local out = {}
            for i = 2, math.min(#packed, 8) do out[#out + 1] = tostring(packed[i]) end
            addf("    GetSpellInfo -> %s", table.concat(out, " | "))
        else
            addf("    GetSpellInfo -> ERROR %s", packed[2])
        end
    end

    local cs = Lookup("C_Spell.GetSpellInfo")
    if type(cs) == "function" then
        local ok, info = pcall(cs, id)
        if ok and type(info) == "table" then
            local keys = {}
            for k, v in pairs(info) do keys[#keys + 1] = ("%s=%s"):format(tostring(k), tostring(v)) end
            table.sort(keys)
            addf("    C_Spell.GetSpellInfo -> %s", table.concat(keys, " "))
        else
            addf("    C_Spell.GetSpellInfo -> %s", ok and tostring(info) or ("ERROR " .. tostring(info)))
        end
    end

    local subtext
    for _, path in ipairs({ "C_Spell.GetSpellSubtext", "GetSpellSubtext" }) do
        local fn = Lookup(path)
        if type(fn) == "function" then
            local ok, value = pcall(fn, id)
            addf("    %s -> %s", path, ok and ("[" .. tostring(value) .. "]") or ("ERROR " .. tostring(value)))
            if ok and type(value) == "string" and value ~= "" and not subtext then subtext = value end
        end
    end

    local name
    local getName = Lookup("C_Spell.GetSpellName")
    if type(getName) == "function" then
        local ok, value = pcall(getName, id)
        if ok and type(value) == "string" then name = value end
    end

    if subtext and name and type(ns.RankIsSelectable) == "function" then
        local ok, usable, plainID, rankedID = pcall(ns.RankIsSelectable, name, subtext)
        if ok then
            addf("    rank test [%s(%s)]: plain id=%s ranked id=%s -> %s",
                name, subtext, tostring(plainID), tostring(rankedID),
                usable and "RANK" or "not a rank")
        end
    end
end

local function ProbeRanks()
    section("3b. SPELLS ON THE SOURCE BAR")

    local found = 0
    for index = 1, ns.SLOTS_PER_BAR do
        local slot = ns.Slots.SlotFor(index)
        if HasAction(slot) then
            local kind, id = GetActionInfo(slot)
            addf("  slot %s (action %s): type=%s id=%s", index, slot, kind, id)
            if kind == "spell" and id then
                DescribeSpell(("    slot %s detail"):format(index), id)
                found = found + 1
            end
        end
    end
    if found == 0 then
        addf("  (no spells on bar %s - put some there and run this again)", ns.db.bar)
    end

    section("3c. RANKED SPELLS FOUND IN THE SPELLBOOK")

    -- Classic-era spellbook walk. If this client keeps ranks, this is where the
    -- exact localised rank string will show up.
    local shown = 0
    local getName = _G.GetSpellBookItemName or Lookup("C_SpellBook.GetSpellBookItemName")
    local bookType = _G.BOOKTYPE_SPELL or (Lookup("Enum.SpellBookSpellBank.Player"))

    if type(getName) == "function" and bookType ~= nil then
        for i = 1, 500 do
            local ok, name, sub = pcall(getName, i, bookType)
            if not ok or not name then break end
            if type(sub) == "string" and sub ~= "" then
                -- Runs the SHIPPING guard, not a reimplementation. The ids
                -- are printed because they are the whole test: if naming the
                -- subtext does not change which spell is selected, the
                -- parenthetical was ignored and this is not a rank.
                local verdict, plainID, rankedID = "?", "?", "?"
                if type(ns.RankIsSelectable) == "function" then
                    local okr, usable, pid, rid = pcall(ns.RankIsSelectable, name, sub)
                    if okr then
                        verdict = usable and "RANK <-- treated as a real rank" or "not a rank"
                        plainID, rankedID = tostring(pid), tostring(rid)
                    else
                        verdict = "ERROR"
                    end
                end
                addf("  book %s: [%s] subtext=[%s]", i, name, sub)
                addf("      plain id=%s  ranked id=%s  ->  %s", plainID, rankedID, verdict)
                shown = shown + 1
                if shown >= 8 then break end
            end
        end
        addf("  (walked with %s, bookType=%s)", tostring(getName) ~= "" and "spellbook API" or "?", tostring(bookType))
    else
        addf("  no usable spellbook-name API (getName=%s bookType=%s)", type(getName), tostring(bookType))
    end

    if shown == 0 then
        add("  NO spell in the spellbook has a subtext.")
        add("  -> either this client has no ranks, or ranks are exposed some other way.")
    else
        add("  (without spell ranks, plain id and ranked id must MATCH on every line)")
    end
end

------------------------------------------------------------------------------
-- 4. secure click-casting foundation
------------------------------------------------------------------------------

local UNIT_FRAME_CANDIDATES = {
    "CompactRaidFrame1", "CompactPartyFrameMember1", "CompactRaidGroup1Member1",
    "PartyMemberFrame1", "PlayerFrame", "TargetFrame",
}

local function ProbeSecure()
    section("4a. SECURE API PRESENCE")
    for _, path in ipairs({
        "SecureActionButton_OnClick", "SecureButton_GetModifiedUnit",
        "SecureButton_GetModifiedAttribute", "CompactUnitFrame_SetUpFrame",
        "ClickCastFrames", "RegisterAttributeDriver", "hooksecurefunc",
    }) do
        ReportAPI(path)
    end

    section("4b. ClickCastFrames CONTENTS")
    local reg = _G.ClickCastFrames
    if type(reg) ~= "table" then
        add("  ClickCastFrames does not exist. This is the foundation Clique uses -")
        add("  if it is missing, unit frame addons register click-casting some other way.")
    else
        local count, names = 0, {}
        for frame, value in pairs(reg) do
            if value and type(frame) == "table" then
                count = count + 1
                if #names < 10 then
                    local ok, name = pcall(function() return frame:GetName() end)
                    names[#names + 1] = (ok and name) or "(unnamed)"
                end
            end
        end
        addf("  %s frames registered. First few: %s", count, table.concat(names, ", "))
        if count == 0 then
            add("  (empty is normal on current retail - Blizzard's frames do not self-register;")
            add("   SlotCast finds them by name and via the CompactUnitFrame_SetUpFrame hook)")
        end
    end

    addf("  SlotCast is managing %s frame(s).", ns.Secure and ns.Secure.ManagedCount() or "?")

    section("4c. A REAL UNIT FRAME")
    local target
    for _, name in ipairs(UNIT_FRAME_CANDIDATES) do
        local frame = _G[name]
        if type(frame) == "table" and not (frame.IsForbidden and frame:IsForbidden()) then
            target = frame
            addf("  inspecting: %s", name)
            break
        end
    end

    if not target then
        add("  none of the usual unit frames exist under their usual names.")
        return
    end

    local ok, objType = pcall(function() return target:GetObjectType() end)
    addf("  GetObjectType = %s", ok and objType or "?")
    addf("  has SetAttribute=%s RegisterForClicks=%s",
        type(target.SetAttribute), type(target.RegisterForClicks))

    local okp, protected = pcall(function() return target:IsProtected() end)
    addf("  IsProtected = %s", okp and tostring(protected) or "?")

    -- These are the attributes SlotCast writes. Seeing what is already there
    -- confirms the whole modifier-prefix convention works on this client.
    for _, attr in ipairs({ "unit", "unitsuffix", "type1", "type2", "*type1", "*type2",
                            "shift-type1", "spell1", "macrotext1" }) do
        local oka, value = pcall(target.GetAttribute, target, attr)
        addf("    [%s] = %s", attr, oka and tostring(value) or "ERROR")
    end

    -- The verbs SlotCast will use for "Target unit" and "Unit menu", learned
    -- from the frame above rather than assumed. "togglemenu" is what the
    -- templates document; real frames tend to carry "menu".
    if type(ns.FrameVerb) == "function" then
        addf("  verbs in use: target=%s menu=%s",
            tostring(ns.FrameVerb("target")), tostring(ns.FrameVerb("menu")))
    end
end

------------------------------------------------------------------------------
-- 5. click bindings and cvars
------------------------------------------------------------------------------

local function ProbeClickBindings()
    section("5. BLIZZARD CLICK BINDINGS")

    if not _G.C_ClickBindings then
        add("  C_ClickBindings = nil")
        add("  -> this client has no built-in click casting, so nothing can conflict.")
    else
        for _, path in ipairs({
            "C_ClickBindings.GetProfileInfo", "C_ClickBindings.SetProfileByInfo",
            "C_ClickBindings.GetStringFromModifiers", "C_ClickBindings.ResetCurrentProfile",
            "C_ClickBindings.MakeModifiers", "C_ClickBindings.CanSpellBeClickBound",
        }) do
            ReportAPI(path)
        end

        local fn = Lookup("C_ClickBindings.GetProfileInfo")
        if type(fn) == "function" then
            local ok, info = pcall(fn)
            if not ok then
                addf("  GetProfileInfo ERROR: %s", info)
            elseif type(info) ~= "table" then
                addf("  GetProfileInfo returned %s", type(info))
            elseif #info == 0 then
                add("  GetProfileInfo returned an empty list (no bindings set).")
                add("  -> set ONE binding in the Click Bindings UI and run this again;")
                add("     that is the only way to see the real field names.")
            else
                addf("  %s binding(s):", #info)
                for i, entry in ipairs(info) do
                    local keys = {}
                    for k, v in pairs(entry) do keys[#keys + 1] = ("%s=%s(%s)"):format(tostring(k), tostring(v), type(v)) end
                    table.sort(keys)
                    addf("    [%s] %s", i, table.concat(keys, " "))
                end
            end
        end
    end

    -- Any enum whose name hints at these systems, whether or not I know it.
    if type(_G.Enum) == "table" then
        for enumName, enumTable in pairs(_G.Enum) do
            if type(enumName) == "string" and type(enumTable) == "table"
               and (enumName:find("ClickBinding") or enumName:find("Rank")) then
                local keys = {}
                for k, v in pairs(enumTable) do keys[#keys + 1] = ("%s=%s"):format(tostring(k), tostring(v)) end
                table.sort(keys)
                addf("  Enum.%s: %s", enumName, table.concat(keys, " "))
            end
        end
    end

    section("6. UI / CVARS")
    for _, path in ipairs({
        "Settings.RegisterCanvasLayoutCategory", "Settings.OpenToCategory",
        "InterfaceOptions_AddCategory", "C_CVar.GetCVarBool", "GetCVarBool",
    }) do
        ReportAPI(path)
    end

    local getBool = Lookup("C_CVar.GetCVarBool") or _G.GetCVarBool
    if type(getBool) == "function" then
        for _, cvar in ipairs({ "ActionButtonUseKeyDown", "lockActionBars" }) do
            local ok, value = pcall(getBool, cvar)
            addf("  cvar %s = %s", cvar, ok and tostring(value) or "ERROR")
        end
    end
end

------------------------------------------------------------------------------
-- assembly
------------------------------------------------------------------------------

function Probe.Build()
    lines = {}
    addf("=== SlotCast probe v%s (addon %s) ===", REPORT_VERSION, ns.SlotCast.version)

    local steps = {
        ProbeClient, ProbeBars, ProbeSpellAPIs, ProbeRanks, ProbeSecure, ProbeClickBindings,
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step)
        if not ok then addf("  !! probe step failed: %s", err) end
    end

    add("")
    add("=== end of probe ===")
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------------
-- copy window
--
-- Built from plain frames on purpose: this has to work on a client where the
-- usual templates may not exist, which is the whole reason it is being run.
------------------------------------------------------------------------------

local window

local function BuildWindow()
    local f = CreateFrame("Frame", "SlotCastProbeWindow", UIParent)
    f:SetSize(640, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.92)

    local edge = f:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 1, -1)
    edge:SetPoint("BOTTOMRIGHT", -1, 1)
    edge:SetColorTexture(0.35, 0.45, 0.55, 1)

    local inner = f:CreateTexture(nil, "ARTWORK")
    inner:SetPoint("TOPLEFT", 2, -2)
    inner:SetPoint("BOTTOMRIGHT", -2, 2)
    inner:SetColorTexture(0.04, 0.04, 0.06, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("SlotCast")
    f.title = title

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 12, -28)
    hint:SetText("Press |cffffff00Ctrl+A|r then |cffffff00Ctrl+C|r to copy, then paste it back. Esc closes.")

    local close = CreateFrame("Button", nil, f)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -8, -8)
    local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeText:SetPoint("CENTER")
    closeText:SetText("x")
    close:SetFontString(closeText)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 12, -52)
    scroll:SetPoint("BOTTOMRIGHT", -12, 12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    -- A scroll child needs a real rect before SetScrollChild; a multiline box
    -- grows past this once the text lands.
    edit:SetSize(600, 400)
    edit:SetFontObject(_G.ChatFontNormal or "GameFontHighlightSmall")
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- A copy box is read-only in spirit: typing in it would only corrupt the
    -- report, so put the text straight back after any edit attempt.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(f.reportText or "") end
    end)
    scroll:SetScrollChild(edit)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local max = math.max(0, edit:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, current - delta * 40)))
    end)

    f.edit = edit
    f:Hide()

    -- Escape should close it like any other panel.
    if type(_G.UISpecialFrames) == "table" then
        tinsert(_G.UISpecialFrames, "SlotCastProbeWindow")
    end

    return f
end

local function PrintToChat(text)
    ns.Print("report follows. Widen the chat frame, then drag-select it, or read")
    ns.Print("it from WTF/Account/<account>/SavedVariables/SlotCast.lua after /reload.")
    for line in text:gmatch("[^\n]*") do
        if line ~= "" then print(line) end
    end
end

-- One window, shared by every report. `stashKey` is where the text is kept in
-- saved variables so it survives a /reload regardless of what the window does.
local function Display(text, stashKey, forceChat)
    ns.db[stashKey] = text

    local lineCount = select(2, text:gsub("\n", "\n")) + 1

    if forceChat then
        PrintToChat(text)
        ns.Print("%d lines, also saved as %s.", lineCount, stashKey)
        return
    end

    local built, err = pcall(function()
        window = window or BuildWindow()
        window.title:SetText(stashKey == "lastCheck" and "SlotCast check" or "SlotCast probe")
        window.reportText = text
        window.edit:SetText(text)
        window:Show()
        window.edit:SetFocus()
        window.edit:HighlightText()
    end)

    if not built then
        ns.Warn("could not open the copy window (%s) - falling back to chat.", tostring(err))
        PrintToChat(text)
        return
    end

    ns.Print("%d lines. Ctrl+A then Ctrl+C in the window to copy, or add |cffffff00chat|r to print here.", lineCount)
end

-- `forceChat` is the "chat" argument on either command.
function Probe.Show(forceChat)
    local ok, text = pcall(Probe.Build)
    if not ok then
        ns.Warn("probe failed while collecting data: %s", tostring(text))
        return
    end
    Display(text, "lastProbe", forceChat)
end

local MODIFIED_CLICKS = { "SELFCAST", "FOCUSCAST" }

local MOD_NAME_TO_PREFIX = { ALT = "alt-", CTRL = "ctrl-", SHIFT = "shift-" }

-- Returns { {combo, setting, key} } for bindings whose modifier collides.
function ns.ModifierConflicts()
    if type(_G.GetModifiedClick) ~= "function" then return {} end

    local out = {}
    for _, setting in ipairs(MODIFIED_CLICKS) do
        local ok, key = pcall(GetModifiedClick, setting)
        local prefix = ok and key and MOD_NAME_TO_PREFIX[key]
        if prefix then
            for combo in pairs(ns.db.binds) do
                if combo:find(prefix, 1, true) then
                    out[#out + 1] = { combo = combo, setting = setting, key = key }
                end
            end
        end
    end
    return out
end

function Probe.Check(forceChat)
    lines = {}
    addf("=== SlotCast check (addon %s) ===", ns.SlotCast.version)

    local frame = ns.Secure and ns.Secure.SampleFrame and ns.Secure.SampleFrame()
    if not frame then
        ns.Warn("no unit frames are being managed - nothing to check.")
        ns.Warn("Run |cffffff00/slotcast status|r; if it says 0 frames, discovery is the problem.")
        return
    end

    local okName, name = pcall(frame.GetName, frame)
    local okUnit, unit = pcall(frame.GetAttribute, frame, "unit")
    addf("frame: %s   unit=%s", (okName and name) or "(unnamed)", okUnit and tostring(unit) or "?")
    addf("click stroke: %s -> firing on %s", ns.db.clickStroke, ns.ClickStroke())
    addf("frame verbs: target=%s menu=%s",
        tostring(ns.FrameVerb("target")), tostring(ns.FrameVerb("menu")))

    -- 1. What the config actually holds. If a binding is missing here, the bug
    --    is in the options UI and the secure layer is innocent.
    section("CONFIGURED BINDINGS")
    local any = false
    for combo, value in pairs(ns.db.binds) do
        addf("  [%s] %s -> %s", combo, ns.ComboText(combo),
            type(value) == "number" and ("slot " .. value) or tostring(value))
        any = true
    end
    if not any then add("  (none)") end

    -- 2. Did every attribute we meant to write actually land?
    section("PLANNED ATTRIBUTES vs FRAME")
    local written, wrong = 0, 0
    for _, entry in ipairs(ns.Slots.plan or {}) do
        if entry.value ~= nil then
            local ok, actual = pcall(frame.GetAttribute, frame, entry.attr)
            if ok and actual == entry.value then
                written = written + 1
                addf("  ok   %s = %s", entry.attr, tostring(entry.value))
            else
                wrong = wrong + 1
                addf("  BAD  %s = %s (expected %s)",
                    entry.attr, ok and tostring(actual) or "unreadable", tostring(entry.value))
            end
        end
    end
    addf("  -> %d correct, %d wrong", written, wrong)
    if wrong == 0 and written > 0 then
        add("  Bindings ARE on the frame; if a click does nothing, something is")
        add("  intercepting it rather than the write failing.")
    end

    -- 3. Ground truth: every type/unit attribute on the frame for buttons 1
    --    and 2, ours and Blizzard's alike, including the wildcard forms.
    section("RAW FRAME ATTRIBUTES (buttons 1 and 2)")
    for _, prefix in ipairs({ "", "alt-", "ctrl-", "shift-", "alt-ctrl-", "alt-shift-",
                              "ctrl-shift-", "alt-ctrl-shift-", "*" }) do
        for button = 1, 2 do
            for _, attr in ipairs({ "type", "unit" }) do
                local attrName = prefix .. attr .. button
                local ok, value = pcall(frame.GetAttribute, frame, attrName)
                if ok and value ~= nil then
                    addf("  %s = %s", attrName, tostring(value))
                end
            end
        end
    end

    -- 4. The client's own modified-click hijacks.
    section("MODIFIED CLICKS")
    if type(_G.GetModifiedClick) == "function" then
        for _, setting in ipairs(MODIFIED_CLICKS) do
            local ok, key = pcall(GetModifiedClick, setting)
            addf("  %s = %s", setting, ok and tostring(key) or "?")
        end
    else
        add("  GetModifiedClick is not available")
    end
    for _, attr in ipairs({ "checkselfcast", "checkfocuscast" }) do
        local ok, value = pcall(frame.GetAttribute, frame, attr)
        addf("  frame [%s] = %s", attr, ok and tostring(value) or "?")
    end

    for _, c in ipairs(ns.ModifierConflicts()) do
        addf("  CONFLICT: %s uses %s, which is your %s key.",
            ns.ComboText(c.combo), c.key, c.setting)
    end
    for _, entry in ipairs(ns.StrandedBindings()) do
        addf("  STRANDED: %s is the unit menu and cannot fire on press.", ns.ComboText(entry.combo))
    end

    add("")
    add("=== end of check ===")

    Display(table.concat(lines, "\n"), "lastCheck", forceChat)
end
