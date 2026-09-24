-- SlotCast :: Options
-- Hand-rolled settings panel. Deliberately built from plain Frames, Textures and
-- FontStrings rather than Blizzard's menu/dropdown widgets: those were replaced
-- wholesale in 11.0 and the replacements keep moving. The only borrowed template
-- is UIPanelButtonTemplate, with a fallback if even that changes.

local ADDON, ns = ...

ns.Options = {}
local Options = ns.Options

local ROW_H    = 24
local COL_W    = 300
local LEFT_X   = 16
local RIGHT_X  = 336

local panel, category
local barButtons, specialRows, slotRows = {}, {}, {}
local warningText, conflictText, slotHeader, rankDefaultLabel
local rankDefaultButtons = {}

------------------------------------------------------------------------------
-- tiny widget kit
------------------------------------------------------------------------------

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlightSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local function PushButton(parent, w, h, text)
    local ok, btn = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not btn then
        btn = CreateFrame("Button", nil, parent)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
        -- A bare Button has no font string, so SetText would be a no-op.
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        btn:SetFontString(fs)
        btn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    end
    btn:SetSize(w, h)
    btn:SetText(text or "")
    return btn
end

local function CheckBox(parent, text)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)

    local edge = btn:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 1, -1)
    edge:SetPoint("BOTTOMRIGHT", -1, 1)
    edge:SetColorTexture(0.35, 0.35, 0.35, 1)

    local inner = btn:CreateTexture(nil, "ARTWORK")
    inner:SetPoint("TOPLEFT", 2, -2)
    inner:SetPoint("BOTTOMRIGHT", -2, 2)
    inner:SetColorTexture(0.08, 0.08, 0.08, 1)

    btn.check = btn:CreateTexture(nil, "OVERLAY")
    btn.check:SetPoint("TOPLEFT", -2, 2)
    btn.check:SetPoint("BOTTOMRIGHT", 2, -2)
    btn.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")

    btn.label = Label(btn, text, "GameFontHighlight")
    btn.label:SetPoint("LEFT", btn, "RIGHT", 6, 0)

    function btn:SetChecked(value) self.check:SetShown(value and true or false) end
    return btn
end

------------------------------------------------------------------------------
-- binding assignment
------------------------------------------------------------------------------

-- A target is either a number (slot index on the source bar) or a special key.
local function ComboFor(target)
    for combo, value in pairs(ns.db.binds) do
        if value == target then return combo end
    end
end

local function DescribeTarget(target)
    if type(target) == "number" then return "slot " .. target end
    for _, s in ipairs(ns.SPECIALS) do
        if s.key == target then return s.label end
    end
    return tostring(target)
end

local function Assign(target, combo)
    -- One target holds at most one combo, so drop whatever it had first.
    local previous = ComboFor(target)
    if previous then ns.db.binds[previous] = nil end

    if combo then
        local displaced = ns.db.binds[combo]
        ns.db.binds[combo] = target
        if displaced ~= nil and displaced ~= target then
            ns.Print("%s was %s - reassigned to %s.",
                ns.ComboText(combo), DescribeTarget(displaced), DescribeTarget(target))
        end
    end

    ns.Refresh(true)
end

------------------------------------------------------------------------------
-- rows
------------------------------------------------------------------------------

local function CreateRow(parent, hasIcon)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(COL_W, ROW_H)

    local textX = 0
    if hasIcon then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 0, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        textX = 24
    end

    row.label = Label(row, "", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", textX, 0)
    row.label:SetWidth(144 - textX)
    row.label:SetWordWrap(false)

    row.capture = PushButton(row, 96, 20, "")
    row.capture:SetPoint("LEFT", 148, 0)
    row.capture:RegisterForClicks("AnyUp")
    row.capture:SetScript("OnClick", function(self, mouseButton)
        local button = ns.ButtonNumber(mouseButton)
        if not button then return end
        Assign(row.target, ns.MakeCombo(button, IsAltKeyDown(), IsControlKeyDown(), IsShiftKeyDown()))
    end)
    row.capture:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Click here with the mouse button you want to bind.")
        GameTooltip:AddLine("Hold Shift, Ctrl and/or Alt while clicking to include them.", 0.8, 0.8, 0.8, true)
        if row.note then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(row.note, 1, 0.6, 0.2, true)
        end
        GameTooltip:Show()
    end)
    row.capture:SetScript("OnLeave", GameTooltip_Hide)

    -- Rank toggle. Only slot rows have one; special actions have no rank.
    if hasIcon then
        row.rank = PushButton(row, 28, 20, "")
        row.rank:SetPoint("LEFT", 248, 0)
        row.rank:SetScript("OnClick", function()
            local current = ns.RankModeFor(row.target)
            ns.SetRankModeFor(row.target, current == "highest" and "slot" or "highest")
            ns.Refresh(true)
        end)
        row.rank:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if not row.rankText then
                GameTooltip:SetText("No ranks")
                GameTooltip:AddLine("This spell has only one rank, so there is nothing to choose.", 0.8, 0.8, 0.8, true)
            elseif ns.RankModeFor(row.target) == "highest" then
                GameTooltip:SetText("Highest rank")
                GameTooltip:AddLine(("Casts |cffffffff%s|r - always the best rank you know."):format(row.castText or "?"), 0.8, 0.8, 0.8, true)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(("Click to cast %s exactly instead."):format(row.rankText), 0.5, 0.8, 1, true)
            else
                GameTooltip:SetText(row.rankText)
                GameTooltip:AddLine(("Casts |cffffffff%s|r - this rank exactly, for downranking."):format(row.castText or "?"), 0.8, 0.8, 0.8, true)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Click to always cast the highest rank instead.", 0.5, 0.8, 1, true)
            end
            GameTooltip:Show()
        end)
        row.rank:SetScript("OnLeave", GameTooltip_Hide)
    end

    row.clear = PushButton(row, 20, 20, "x")
    row.clear:SetPoint("LEFT", 278, 0)
    row.clear:SetScript("OnClick", function() Assign(row.target, nil) end)

    return row
end

local function UpdateRow(row)
    local combo = ComboFor(row.target)
    row.capture:SetText(combo and ns.ComboText(combo) or "|cff808080unbound|r")
    row.clear:SetEnabled(combo ~= nil)

    if type(row.target) ~= "number" then return end

    local spec = ns.Slots.ReadSlot(ns.Slots.SlotFor(row.target), row.target)
    row.note = spec and spec.note or nil
    row.rankText = spec and spec.rank or nil
    row.castText = spec and spec.cast or nil

    if row.rank then
        if spec and spec.rank then
            row.rank:SetEnabled(true)
            row.rank:SetAlpha(1)
            row.rank:SetText(spec.rankMode == "highest" and "|cffffcc00max|r" or ns.ShortRank(spec.rank))
        else
            row.rank:SetEnabled(false)
            row.rank:SetAlpha(0.3)
            row.rank:SetText("-")
        end
    end

    if row.icon then
        row.icon:SetTexture(spec and spec.icon or nil)
        row.icon:SetAlpha(spec and 1 or 0.25)
        if not spec or not spec.icon then
            row.icon:SetColorTexture(0.15, 0.15, 0.15, 0.6)
        end
    end

    local name = spec and spec.label or "|cff606060empty|r"
    if spec and spec.unsupported then name = "|cffff6060" .. (spec.label or "?") .. "|r" end
    if spec and spec.note and not spec.unsupported then name = name .. " |cffffcc00*|r" end
    row.label:SetText(("|cff808080%d.|r %s"):format(row.target, name))
end

------------------------------------------------------------------------------
-- panel
------------------------------------------------------------------------------

local function SelectBar(bar)
    ns.db.bar = bar
    ns.Refresh(true)
end

local function BuildPanel()
    panel = CreateFrame("Frame", "SlotCastOptionsPanel", UIParent)
    panel.name = "SlotCast"
    panel:Hide()

    local title = Label(panel, "SlotCast", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", LEFT_X, -16)

    local subtitle = Label(panel, "Bind a mouse click to an action bar slot. Whatever you drag into that slot becomes the binding.", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", LEFT_X, -40)
    subtitle:SetWidth(600)

    -- enable ------------------------------------------------------------------
    local enable = CheckBox(panel, "Enable click bindings")
    enable:SetPoint("TOPLEFT", LEFT_X, -68)
    enable:SetScript("OnClick", function(self)
        ns.db.enabled = not ns.db.enabled
        self:SetChecked(ns.db.enabled)
        ns.Refresh(true)
    end)
    panel.enable = enable

    -- bar selector ------------------------------------------------------------
    local barLabel = Label(panel, "Source action bar", "GameFontNormal")
    barLabel:SetPoint("TOPLEFT", LEFT_X, -100)

    for i = 1, 8 do
        local btn = PushButton(panel, 32, 22, tostring(i))
        btn:SetPoint("TOPLEFT", LEFT_X + (i - 1) * 35, -120)
        btn.sel = btn:CreateTexture(nil, "OVERLAY")
        btn.sel:SetAllPoints()
        btn.sel:SetColorTexture(1, 0.82, 0, 0.3)
        btn.sel:Hide()
        btn:SetScript("OnClick", function() SelectBar(i) end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(ns.BAR_NAMES[i])
            if ns.Slots.BarExists(i) then
                local base = ns.Slots.BaseFor(i)
                GameTooltip:AddLine(("action slots %d-%d"):format(base, base + ns.SLOTS_PER_BAR - 1), 0.8, 0.8, 0.8)
            else
                GameTooltip:AddLine("not present on this client", 1, 0.4, 0.4)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
        barButtons[i] = btn
    end

    warningText = Label(panel, "", "GameFontHighlightSmall")
    warningText:SetPoint("TOPLEFT", LEFT_X, -150)
    warningText:SetWidth(COL_W)
    warningText:SetJustifyV("TOP")

    -- specials ----------------------------------------------------------------
    local specialHeader = Label(panel, "Unit frame clicks", "GameFontNormal")
    specialHeader:SetPoint("TOPLEFT", LEFT_X, -196)

    local specialHint = Label(panel, "Unbound clicks keep whatever the unit frame already did.", "GameFontDisableSmall")
    specialHint:SetPoint("TOPLEFT", LEFT_X, -214)
    specialHint:SetWidth(COL_W)

    for i, special in ipairs(ns.SPECIALS) do
        local row = CreateRow(panel, false)
        row:SetPoint("TOPLEFT", LEFT_X, -232 - (i - 1) * ROW_H)
        row.target = special.key
        row.label:SetText(special.label)
        specialRows[i] = row
    end

    -- Blizzard conflicts ------------------------------------------------------
    local conflictHeader = Label(panel, "Blizzard Click Bindings", "GameFontNormal")
    conflictHeader:SetPoint("TOPLEFT", LEFT_X, -370)

    conflictText = Label(panel, "", "GameFontHighlightSmall")
    conflictText:SetPoint("TOPLEFT", LEFT_X, -390)
    conflictText:SetWidth(COL_W)
    conflictText:SetJustifyV("TOP")

    local rescan = PushButton(panel, 142, 22, "Re-check")
    rescan:SetPoint("TOPLEFT", LEFT_X, -444)
    rescan:SetScript("OnClick", function()
        Options.RefreshDisplay()
        ns.Conflicts.Report(true)
    end)

    local clearBlizz = PushButton(panel, 152, 22, "Clear Blizzard's")
    clearBlizz:SetPoint("TOPLEFT", LEFT_X + 148, -444)
    clearBlizz:SetScript("OnClick", function()
        if ns.Conflicts.Clear() then
            ns.Print("cleared Blizzard's click bindings.")
        else
            ns.Warn("could not clear them from here - use the Click Bindings tab in the Spellbook.")
        end
        Options.RefreshDisplay()
    end)

    local clearMine = PushButton(panel, COL_W, 22, "Clear all SlotCast bindings")
    clearMine:SetPoint("TOPLEFT", LEFT_X, -472)
    clearMine:SetScript("OnClick", function()
        wipe(ns.db.binds)
        ns.Refresh(true)
    end)

    -- slots -------------------------------------------------------------------
    slotHeader = Label(panel, "Bar slots", "GameFontNormal")
    slotHeader:SetPoint("TOPLEFT", RIGHT_X, -68)

    local slotHint = Label(panel, "Drag a spell into the slot in-game; the binding follows it.", "GameFontDisableSmall")
    slotHint:SetPoint("TOPLEFT", RIGHT_X, -86)
    slotHint:SetWidth(COL_W)

    -- Default rank handling. Per-slot buttons on each row override this.
    rankDefaultLabel = Label(panel, "Ranks:", "GameFontHighlightSmall")
    rankDefaultLabel:SetPoint("TOPLEFT", RIGHT_X, -108)

    local modes = { { "slot", "in slot" }, { "highest", "highest" } }
    for i, mode in ipairs(modes) do
        local btn = PushButton(panel, 64, 20, mode[2])
        btn:SetPoint("TOPLEFT", RIGHT_X + 44 + (i - 1) * 68, -104)
        btn.sel = btn:CreateTexture(nil, "OVERLAY")
        btn.sel:SetAllPoints()
        btn.sel:SetColorTexture(1, 0.82, 0, 0.3)
        btn.sel:Hide()
        btn:SetScript("OnClick", function()
            ns.db.rankMode = mode[1]
            wipe(ns.db.rankOverrides)
            ns.Refresh(true)
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if mode[1] == "slot" then
                GameTooltip:SetText("Cast the rank in the slot")
                GameTooltip:AddLine("Renew (Rank 2) in the slot casts |cffffffffRenew(Rank 2)|r. This is what downranking needs.", 0.8, 0.8, 0.8, true)
            else
                GameTooltip:SetText("Cast the highest rank")
                GameTooltip:AddLine("Renew (Rank 2) in the slot casts |cffffffffRenew|r, which is always the best rank you know.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Sets the default for every slot and clears per-slot overrides.", 1, 0.6, 0.2, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
        rankDefaultButtons[i] = { button = btn, mode = mode[1] }
    end

    for i = 1, ns.SLOTS_PER_BAR do
        local row = CreateRow(panel, true)
        row:SetPoint("TOPLEFT", RIGHT_X, -132 - (i - 1) * ROW_H)
        row.target = i
        slotRows[i] = row
    end

    panel:SetScript("OnShow", Options.RefreshDisplay)
    return panel
end

------------------------------------------------------------------------------
-- refresh
------------------------------------------------------------------------------

function Options.RefreshDisplay()
    if not panel or not ns.db then return end

    panel.enable:SetChecked(ns.db.enabled)

    for i = 1, 8 do
        local exists = ns.Slots.BarExists(i)
        barButtons[i]:SetEnabled(exists)
        barButtons[i]:SetAlpha(exists and 1 or 0.35)
        barButtons[i].sel:SetShown(ns.db.bar == i)
    end

    slotHeader:SetText(ns.BAR_NAMES[ns.db.bar] or ("Bar " .. ns.db.bar))

    -- The rank controls are meaningless on a client without spell ranks, so
    -- only show them once a ranked spell actually turns up on the bar.
    local hasRanks = false
    for i = 1, ns.SLOTS_PER_BAR do
        local spec = ns.Slots.ReadSlot(ns.Slots.SlotFor(i), i)
        if spec and spec.rank then hasRanks = true break end
    end
    rankDefaultLabel:SetShown(hasRanks)
    for _, entry in ipairs(rankDefaultButtons) do
        entry.button:SetShown(hasRanks)
        entry.button.sel:SetShown(ns.db.rankMode == entry.mode)
    end

    for _, row in ipairs(specialRows) do UpdateRow(row) end
    for _, row in ipairs(slotRows) do UpdateRow(row) end

    -- bar warnings
    local messages = {}
    if not ns.Slots.BarExists(ns.db.bar) then
        messages[#messages + 1] = ("|cffff6060This client has no bar %d. Pick one of the bars still lit above.|r"):format(ns.db.bar)
    end
    if ns.db.bar == 1 then
        messages[#messages + 1] = "|cffffcc00Bar 1 changes pages on stance, stealth, dragonriding and vehicles, so its slots move under your bindings. Bars 6-8 never page.|r"
    end
    local empty = true
    for i = 1, ns.SLOTS_PER_BAR do
        local probe = ns.Slots.SlotFor(i)
        if probe and HasAction(probe) then empty = false break end
    end
    if empty then
        messages[#messages + 1] = "|cffffcc00This bar is empty. Enable it in Edit Mode and drag spells onto it, then hide or fade it.|r"
    end
    if ns.IsRefreshPending() then
        messages[#messages + 1] = "|cffff8080Changes are waiting for you to leave combat.|r"
    end
    warningText:SetText(table.concat(messages, "\n"))

    -- Blizzard conflicts
    if not ns.Conflicts.Available() then
        conflictText:SetText("|cff808080This client has no built-in click bindings to conflict with.|r")
    else
        local overridden, total = ns.Conflicts.Find()
        if not overridden then
            conflictText:SetText("|cff808080Could not read Blizzard's click bindings.|r")
        else
            -- Blizzard writes these as wildcard attributes ("*type1"), which a
            -- specific attribute beats, so SlotCast overrides rather than
            -- collides. The two Interaction entries every character ships with
            -- are not worth reporting.
            local real = {}
            for _, entry in ipairs(overridden) do
                if entry.kind ~= "interaction" then real[#real + 1] = entry end
            end

            if #real == 0 then
                conflictText:SetText(("|cff60ff60%d set, none of yours overridden.|r\n|cff808080SlotCast takes precedence on clicks it binds.|r"):format(total))
            else
                local lines = { ("|cffffcc00SlotCast overrides %d of %d:|r"):format(#real, total) }
                for _, entry in ipairs(real) do
                    lines[#lines + 1] = ("  %s - %s"):format(entry.text, entry.action)
                end
                conflictText:SetText(table.concat(lines, "\n"))
            end
        end
    end
end

------------------------------------------------------------------------------
-- registration
------------------------------------------------------------------------------

function Options.Init()
    BuildPanel()

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, "SlotCast")
        category.ID = "SlotCast"
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function Options.Open()
    if Settings and Settings.OpenToCategory and category then
        Settings.OpenToCategory(category.ID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
