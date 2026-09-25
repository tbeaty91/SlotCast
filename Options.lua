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
local CONTENT_W = 652
local CONTENT_H = 676
local LEFT_X   = 16
local RIGHT_X  = 336

local panel, category, standalone, settingsHost
local barButtons, specialRows, slotRows = {}, {}, {}
local warningText, conflictText, slotHeader, rankDefaultLabel
local gridCache, gridIs2D
local gridAxisLabel, gridOrderButton, previewHeader, previewTipBg, previewTipEdge
local blizzDelegateButton
local rankDefaultButtons = {}

------------------------------------------------------------------------------
-- tiny widget kit
------------------------------------------------------------------------------

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlightSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(2)  -- wrapped lines sit too close together without this
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
-- notice dialog
--
-- Hand-rolled rather than StaticPopup, for the same reason the rest of this
-- file is: fewer moving parts that Blizzard can rename underneath us.
------------------------------------------------------------------------------

local notice

local function BuildNotice()
    local f = CreateFrame("Frame", "SlotCastNotice", UIParent)
    f:SetSize(440, 280)
    f:SetPoint("CENTER", 0, 140)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.95)

    local edge = f:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 1, -1)
    edge:SetPoint("BOTTOMRIGHT", -1, 1)
    edge:SetColorTexture(1, 0.82, 0, 0.8)

    local inner = f:CreateTexture(nil, "ARTWORK")
    inner:SetPoint("TOPLEFT", 3, -3)
    inner:SetPoint("BOTTOMRIGHT", -3, 3)
    inner:SetColorTexture(0.06, 0.06, 0.08, 1)

    f.title = Label(f, "", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 18, -16)
    f.title:SetWidth(404)

    f.body = Label(f, "", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 18, -48)
    f.body:SetWidth(404)
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(3)

    f.dontShow = CheckBox(f, "Don't show this again")
    f.dontShow:SetPoint("BOTTOMLEFT", 18, 18)
    f.dontShow:SetScript("OnClick", function(self)
        if f.suppressKey then
            ns.db[f.suppressKey] = not ns.db[f.suppressKey]
            self:SetChecked(ns.db[f.suppressKey])
        end
    end)

    f.ok = PushButton(f, 100, 24, "Got it")
    f.ok:SetPoint("BOTTOMRIGHT", -18, 14)
    f.ok:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    if type(_G.UISpecialFrames) == "table" then
        tinsert(_G.UISpecialFrames, "SlotCastNotice")
    end
    return f
end

-- `suppressKey` is a saved-variable name; when set, the dialog offers a
-- "don't show this again" box and honours it.
function ns.ShowNotice(title, body, suppressKey)
    if suppressKey and ns.db[suppressKey] then return end

    notice = notice or BuildNotice()
    notice.suppressKey = suppressKey
    notice.title:SetText(title)
    notice.body:SetText(body)
    notice.dontShow:SetShown(suppressKey ~= nil)
    notice.dontShow:SetChecked(suppressKey and ns.db[suppressKey])
    notice:Show()
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
-- auto-mapping the visual grid
--
-- Columns become mouse buttons left to right; rows become modifier sets top to
-- bottom. A bar shaped 3 wide by 4 tall then reads exactly as it looks: top row
-- plain, second row Shift, third Ctrl, fourth Alt. Because the grid is measured
-- from the buttons' real positions, this produces the same result whatever
-- order a given client folds its bars in.
------------------------------------------------------------------------------

local BUTTON_ORDERS = {
    LMR = { 1, 3, 2, 4, 5 },  -- left, middle, right
    LRM = { 1, 2, 3, 4, 5 },  -- left, right, middle -- middle-click is awkward on many mice
}

local ROW_MODS = {
    { false, false, false },  -- (none)
    { false, false, true  },  -- Shift
    { false, true,  false },  -- Ctrl
    { true,  false, false },  -- Alt
    { false, true,  true  },  -- Ctrl + Shift
    { true,  false, true  },  -- Alt + Shift
    { true,  true,  false },  -- Alt + Ctrl
    { true,  true,  true  },  -- Alt + Ctrl + Shift
}

-- Every combo in a sensible order, for shapes that have no grid to read:
-- Left, Middle, Right, then the same again with Shift, Ctrl, Alt.
local function EnumerateCombos(buttons)
    local out = {}
    for _, mods in ipairs(ROW_MODS) do
        for _, button in ipairs(buttons) do
            out[#out + 1] = ns.MakeCombo(button, mods[1], mods[2], mods[3])
        end
    end
    return out
end

local function AutoMapGrid()
    local grid, rows, cols = ns.Slots.GridLayout()
    if not grid then
        ns.Warn("could not read the bar's layout - is bar %s enabled in Edit Mode?", ns.db.bar)
        return
    end

    local buttons = BUTTON_ORDERS[ns.db.gridButtonOrder] or BUTTON_ORDERS.LMR
    local axis, forced = ns.ResolvedGridAxis(rows, cols)

    -- Replace slot bindings only. Target/menu and friends are a separate
    -- decision and are left exactly as they are.
    for combo, value in pairs(ns.db.binds) do
        if type(value) == "number" then ns.db.binds[combo] = nil end
    end

    -- A shape with no usable axis (one line of twelve, say) still maps fine:
    -- walk the slots in reading order and hand out combos in order.
    local enumerated, order
    if axis == "enumerate" then
        enumerated = EnumerateCombos(buttons)
        order = {}
        for index = 1, ns.SLOTS_PER_BAR do
            if grid[index] then order[#order + 1] = index end
        end
        table.sort(order, function(a, b)
            local ca, cb = grid[a], grid[b]
            if ca.row ~= cb.row then return ca.row < cb.row end
            return ca.col < cb.col
        end)
    end

    local function ComboFornIndex(index, position)
        if axis == "enumerate" then return enumerated[position] end
        local cell = grid[index]
        local btnAxis = (axis == "row") and cell.row or cell.col
        local modAxis = (axis == "row") and cell.col or cell.row
        if not buttons[btnAxis] or not ROW_MODS[modAxis] then return nil end
        local mods = ROW_MODS[modAxis]
        return ns.MakeCombo(buttons[btnAxis], mods[1], mods[2], mods[3])
    end

    local mapped, skipped, protected = 0, 0, {}
    local sequence = order or (function()
        local list = {}
        for index = 1, ns.SLOTS_PER_BAR do
            if grid[index] then list[#list + 1] = index end
        end
        return list
    end)()

    for position, index in ipairs(sequence) do
        local combo = ComboFornIndex(index, position)
        if not combo then
            skipped = skipped + 1
        else
            local existing = ns.db.binds[combo]
            -- Slot bindings were cleared above, so anything still here is a
            -- unit-frame action the user chose deliberately. A bulk mapping
            -- does not get to overwrite that.
            if existing ~= nil then
                protected[#protected + 1] = ("%s (%s)"):format(ns.ComboText(combo), DescribeTarget(existing))
            else
                ns.db.binds[combo] = index
                mapped = mapped + 1
            end
        end
    end

    ns.db.lastMappedShape = ("%dx%d"):format(cols, rows)

    local how = (axis == "enumerate") and "in order"
             or ((axis == "col") and "columns are mouse buttons" or "rows are mouse buttons")
    ns.Print("mapped a %dx%d grid, %s%s: %d slot(s) bound%s.",
        cols, rows, how, forced and " (forced)" or "", mapped,
        skipped > 0 and (", %d skipped"):format(skipped) or "")

    if #protected > 0 then
        ns.Warn("left alone, already bound to a unit-frame action: %s", table.concat(protected, ", "))
        ns.Warn("Clear those in the left column first if you want the grid to have them.")
    end

    ns.Refresh(true)
end

Options.AutoMapGrid = AutoMapGrid

------------------------------------------------------------------------------
-- rows
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- grid preview
--
-- The mapping is positional, so changing a bar's shape changes which axis
-- carries the mouse buttons -- and the same spell ends up on a different click.
-- That is correct and deeply confusing to read about, so draw it instead.
------------------------------------------------------------------------------

local SHORT_BUTTON = { [1] = "L", [2] = "R", [3] = "M", [4] = "4", [5] = "5" }

local function ShortCombo(combo)
    if not combo then return "-" end
    local prefix, button = ns.SplitCombo(combo)
    local mods = ""
    if prefix:find("alt-")   then mods = mods .. "A" end
    if prefix:find("ctrl-")  then mods = mods .. "C" end
    if prefix:find("shift-") then mods = mods .. "S" end
    return (mods ~= "" and (mods .. "-") or "") .. (SHORT_BUTTON[button] or tostring(button))
end

local previewCells, previewFrame = {}, nil

local function PreviewCell(index)
    if previewCells[index] then return previewCells[index] end

    local cell = CreateFrame("Frame", nil, previewFrame)
    cell:SetSize(48, 18)

    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints()
    cell.bg:SetColorTexture(1, 1, 1, 0.06)

    cell.text = cell:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cell.text:SetPoint("CENTER")

    previewCells[index] = cell
    return cell
end

local function UpdatePreview(grid, rows, cols)
    for _, cell in pairs(previewCells) do cell:Hide() end
    if not grid or not rows or not cols or cols > 6 or rows > 6 then return end

    -- Which click each cell carries, looked up from the live bindings rather
    -- than recomputed, so the picture cannot disagree with the behaviour.
    local comboAt = {}
    for combo, value in pairs(ns.db.binds) do
        if type(value) == "number" and grid[value] then
            local cell = grid[value]
            comboAt[cell.row .. ":" .. cell.col] = combo
        end
    end

    local width = math.min(48, math.floor(COL_W / cols) - 2)
    local n = 0
    for row = 1, rows do
        for col = 1, cols do
            n = n + 1
            local cell = PreviewCell(n)
            cell:SetSize(width, 18)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", (col - 1) * (width + 2), -(row - 1) * 17)
            local combo = comboAt[row .. ":" .. col]
            cell.text:SetText(combo and ShortCombo(combo) or "|cff505050-|r")
            cell.bg:SetColorTexture(1, 1, 1, combo and 0.08 or 0.03)
            cell:Show()
        end
    end
end

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
        if row.blizzardOwned then
            ns.Conflicts.ExplainManualBinding(nil, row.target)
            return
        end
        local button = ns.ButtonNumber(mouseButton)
        if not button then return end
        local combo = ns.MakeCombo(button, IsAltKeyDown(), IsControlKeyDown(), IsShiftKeyDown())
        Assign(row.target, combo)
    end)
    row.capture:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if row.blizzardOwned then
            GameTooltip:SetText("Set in Blizzard's Click Bindings")
            GameTooltip:AddLine("This action moved to the game's own click-binding system, so SlotCast shows what you have set there rather than competing with it.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to open it and see the steps.", 0.5, 0.8, 1, true)
            GameTooltip:Show()
            return
        end
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
    -- Actions Blizzard's click-binding system owns are shown, not offered:
    -- binding them here would silently do nothing and block theirs as well.
    if ns.BlizzardOwns(row.target) then
        local text = ns.Conflicts.BindingTextFor(row.target)
        row.blizzardOwned = true
        row.capture:SetText(text and ("|cff80c0ff" .. text .. "|r") or "|cffffcc00click to set|r")
        row.capture:SetEnabled(true)
        row.clear:SetEnabled(false)
        row.clear:SetAlpha(0.25)
        row.label:SetText(row.labelText .. " |cff808080(Blizzard)|r")
        return
    end

    row.blizzardOwned = false
    row.clear:SetAlpha(1)

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

    -- The index is what the slot IS; the cell is only extra orientation,
    -- and on a plain single row of twelve it is noise.
    local where = ("|cff808080%d.|r"):format(row.target)
    local cell = gridCache and gridCache[row.target]
    if cell and gridIs2D then
        where = where .. (" |cff6699ccr%dc%d|r"):format(cell.row, cell.col)
    end

    local name = spec and spec.label or "|cff606060empty|r"
    if spec and spec.unsupported then name = "|cffff6060" .. (spec.label or "?") .. "|r" end
    if spec and spec.note and not spec.unsupported then name = name .. " |cffffcc00*|r" end
    row.label:SetText(("%s %s"):format(where, name))
end

------------------------------------------------------------------------------
-- panel
------------------------------------------------------------------------------

local function SelectBar(bar)
    ns.db.bar = bar
    ns.Refresh(true)
end

local function BuildPanel()
    -- `panel` holds every widget and nothing else. It is reparented into
    -- whichever host is showing it: the standalone window that /slotcast opens,
    -- or Blizzard's Settings canvas. Widgets anchor to it, so both hosts get an
    -- identical layout with no duplicate construction.
    panel = CreateFrame("Frame", "SlotCastOptionsPanel", UIParent)
    panel:SetSize(CONTENT_W, CONTENT_H)
    panel:Hide()

    local title = Label(panel, "SlotCast", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", LEFT_X, -16)

    local subtitle = Label(panel, "Bind a mouse click to an action bar slot. Whatever you drag into that slot becomes the binding.", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", LEFT_X, -40)
    subtitle:SetWidth(600)

    -- enable ------------------------------------------------------------------
    local enable = CheckBox(panel, "Enable click bindings")
    enable:SetPoint("TOPLEFT", LEFT_X, -76)
    enable:SetScript("OnClick", function(self)
        ns.db.enabled = not ns.db.enabled
        self:SetChecked(ns.db.enabled)
        ns.Refresh(true)
    end)
    panel.enable = enable

    -- bar selector ------------------------------------------------------------
    local barLabel = Label(panel, "Source action bar", "GameFontNormal")
    barLabel:SetPoint("TOPLEFT", LEFT_X, -108)

    for i = 1, 8 do
        local btn = PushButton(panel, 32, 22, tostring(i))
        btn:SetPoint("TOPLEFT", LEFT_X + (i - 1) * 35, -128)
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
    warningText:SetPoint("TOPLEFT", LEFT_X, -158)
    warningText:SetWidth(COL_W)
    warningText:SetHeight(72)
    warningText:SetJustifyV("TOP")

    -- specials ----------------------------------------------------------------
    local specialHeader = Label(panel, "Unit frame clicks", "GameFontNormal")
    specialHeader:SetPoint("TOPLEFT", LEFT_X, -238)

    local specialHint = Label(panel, "Target and Unit menu open WoW's Click Bindings. Unbound rows keep the frame's normal behaviour.", "GameFontDisableSmall")
    specialHint:SetPoint("TOPLEFT", LEFT_X, -256)
    specialHint:SetWidth(COL_W)
    specialHint:SetHeight(36)
    specialHint:SetJustifyV("TOP")

    for i, special in ipairs(ns.SPECIALS) do
        local row = CreateRow(panel, false)
        row:SetPoint("TOPLEFT", LEFT_X, -300 - (i - 1) * ROW_H)
        row.target = special.key
        row.labelText = special.label
        row.label:SetText(special.label)
        specialRows[i] = row
    end

    -- Blizzard conflicts ------------------------------------------------------
    local conflictHeader = Label(panel, "Blizzard Click Bindings", "GameFontNormal")
    conflictHeader:SetPoint("TOPLEFT", LEFT_X, -432)

    conflictText = Label(panel, "", "GameFontHighlightSmall")
    conflictText:SetPoint("TOPLEFT", LEFT_X, -452)
    conflictText:SetWidth(COL_W)
    conflictText:SetHeight(54)
    conflictText:SetJustifyV("TOP")

    local rescan = PushButton(panel, 142, 22, "Re-check")
    rescan:SetPoint("TOPLEFT", LEFT_X, -512)
    rescan:SetScript("OnClick", function()
        Options.RefreshDisplay()
        ns.Conflicts.Report(true)
    end)

    local clearBlizz = PushButton(panel, 152, 22, "Clear Blizzard's")
    clearBlizz:SetPoint("TOPLEFT", LEFT_X + 148, -512)
    clearBlizz:SetScript("OnClick", function()
        if ns.Conflicts.Clear() then
            ns.Print("cleared Blizzard's click bindings.")
        else
            ns.Warn("could not clear them from here - use the Click Bindings tab in the Spellbook.")
        end
        Options.RefreshDisplay()
    end)

    blizzDelegateButton = PushButton(panel, COL_W, 22, "Open Blizzard's Click Bindings (/clickcasting)")
    blizzDelegateButton:SetPoint("TOPLEFT", LEFT_X, -540)
    blizzDelegateButton:SetScript("OnClick", function()
        ns.Conflicts.ExplainManualBinding(nil, "menu")
    end)
    blizzDelegateButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Blizzard's Click Bindings")
        GameTooltip:AddLine("Targeting and the unit menu are set there. SlotCast reads them back and shows them above.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    blizzDelegateButton:SetScript("OnLeave", GameTooltip_Hide)

    local clearMine = PushButton(panel, COL_W, 22, "Clear all SlotCast bindings")
    clearMine:SetPoint("TOPLEFT", LEFT_X, -568)
    clearMine:SetScript("OnClick", function()
        wipe(ns.db.binds)
        ns.Refresh(true)
    end)

    -- slots -------------------------------------------------------------------
    slotHeader = Label(panel, "Bar slots", "GameFontNormal")
    slotHeader:SetPoint("TOPLEFT", RIGHT_X, -68)

    local slotHint = Label(panel, "Drag a spell into the slot; the binding follows it.", "GameFontDisableSmall")
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

    local autoMap = PushButton(panel, COL_W, 22, "Map grid to clicks")
    autoMap:SetPoint("TOPLEFT", RIGHT_X, -428)
    autoMap:SetScript("OnClick", AutoMapGrid)
    panel.autoMap = autoMap
    autoMap:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Map the bar's shape onto clicks")
        GameTooltip:AddLine("The shorter side of the bar becomes Left, Middle, Right; the longer side becomes no modifier, Shift, Ctrl, Alt.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Worked out from the bar's shape - a 3-wide and a 3-tall bar both read correctly.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Read from where the buttons actually sit on screen, so it works whatever order this client folds bars in.", 0.5, 0.8, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Best with the bar set to |cffffffffVertical|r in Edit Mode, 3 columns wide: Left / Middle / Right across the top, Shift / Ctrl / Alt down the side.", 0.5, 1, 0.5, true)
        GameTooltip:AddLine("Replaces existing slot bindings. Target/menu are left alone.", 1, 0.6, 0.2, true)
        GameTooltip:Show()
    end)
    autoMap:SetScript("OnLeave", GameTooltip_Hide)

    -- Orientation is detected, not asked about: the shorter axis carries the
    -- mouse buttons because buttons are scarcer than modifiers. This just says
    -- what it worked out, so the mapping is never a surprise.
    -- Tips and warnings first, then what the grid currently means, then the
    -- grid itself. Reading downwards should answer "why" before "what".
    -- A tinted panel behind the header, so a recommendation reads as one
    -- rather than blending into the surrounding explanatory text.
    previewTipBg = panel:CreateTexture(nil, "BACKGROUND")
    previewTipBg:SetPoint("TOPLEFT", RIGHT_X - 6, -478)
    previewTipBg:SetSize(COL_W + 12, 42)
    previewTipBg:Hide()

    previewTipEdge = panel:CreateTexture(nil, "BORDER")
    previewTipEdge:SetPoint("TOPLEFT", RIGHT_X - 6, -478)
    previewTipEdge:SetSize(3, 42)
    previewTipEdge:Hide()

    previewHeader = Label(panel, "", "GameFontHighlightSmall")
    previewHeader:SetPoint("TOPLEFT", RIGHT_X, -484)
    previewHeader:SetWidth(COL_W)
    previewHeader:SetHeight(30)

    gridAxisLabel = Label(panel, "", "GameFontDisableSmall")
    gridAxisLabel:SetPoint("TOPLEFT", RIGHT_X, -518)
    gridAxisLabel:SetWidth(COL_W)
    gridAxisLabel:SetHeight(34)

    previewFrame = CreateFrame("Frame", nil, panel)
    previewFrame:SetPoint("TOPLEFT", RIGHT_X, -556)
    previewFrame:SetSize(COL_W, 104)
    gridAxisLabel:SetWidth(COL_W)
    gridAxisLabel:SetJustifyV("TOP")

    gridOrderButton = PushButton(panel, 148, 22, "")
    gridOrderButton:SetPoint("TOPLEFT", RIGHT_X, -454)
    gridOrderButton:SetScript("OnClick", function()
        ns.db.gridButtonOrder = (ns.db.gridButtonOrder == "LMR") and "LRM" or "LMR"
        Options.RefreshDisplay()
    end)
    gridOrderButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Mouse button order")
        GameTooltip:AddLine("The order buttons are handed out along that axis. Put middle last if it is awkward on your mouse.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Press Map again after changing this.", 1, 0.6, 0.2, true)
        GameTooltip:Show()
    end)
    gridOrderButton:SetScript("OnLeave", GameTooltip_Hide)

    local editModeButton = PushButton(panel, 148, 22, "Open Edit Mode")
    editModeButton:SetPoint("TOPLEFT", RIGHT_X + 152, -454)
    editModeButton:SetScript("OnClick", function()
        if not ns.OpenEditMode() then
            ns.Warn("could not open Edit Mode - press Escape and choose it from the menu.")
        end
    end)
    editModeButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Change the bar's shape")
        GameTooltip:AddLine("Set the source bar to Vertical, 3 columns wide, then press Map grid to clicks again.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("SlotCast opens Edit Mode but won't change your layout for you - it's shared across characters.", 1, 0.6, 0.2, true)
        GameTooltip:Show()
    end)
    editModeButton:SetScript("OnLeave", GameTooltip_Hide)

    return panel
end

------------------------------------------------------------------------------
-- hosts
--
-- /slotcast opens the standalone window rather than Blizzard's Settings frame.
-- Settings.OpenToCategory depends on category-id plumbing that has been
-- rewritten more than once, and a config panel you tweak while watching your
-- unit frames is better off as a window you can drag anyway. The Settings entry
-- stays registered so the addon is still discoverable in the AddOns tab.
------------------------------------------------------------------------------

local function AttachTo(host)
    if not panel then return end
    panel:SetParent(host)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    panel:Show()
    Options.RefreshDisplay()
end

local function BuildStandalone()
    local f = CreateFrame("Frame", "SlotCastWindow", UIParent)
    f:SetSize(CONTENT_W + 16, CONTENT_H + 40)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.94)

    local edge = f:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 1, -1)
    edge:SetPoint("BOTTOMRIGHT", -1, 1)
    edge:SetColorTexture(0.35, 0.45, 0.55, 1)

    local inner = f:CreateTexture(nil, "ARTWORK")
    inner:SetPoint("TOPLEFT", 2, -2)
    inner:SetPoint("BOTTOMRIGHT", -2, 2)
    inner:SetColorTexture(0.05, 0.05, 0.07, 1)

    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", 8, -8)
    holder:SetSize(CONTENT_W, CONTENT_H)
    f.holder = holder

    -- Built after the holder and lifted above it: the content is reparented
    -- into the holder, so anything that must stay clickable has to sit higher.
    local close = PushButton(f, 24, 22, "x")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetFrameLevel(holder:GetFrameLevel() + 10)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function() AttachTo(holder) end)
    f:Hide()

    if type(_G.UISpecialFrames) == "table" then
        tinsert(_G.UISpecialFrames, "SlotCastWindow")
    end

    return f
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

    local hasBlizzBindings = ns.Conflicts.Available()
    blizzDelegateButton:SetEnabled(hasBlizzBindings)
    blizzDelegateButton:SetAlpha(hasBlizzBindings and 1 or 0.35)

    slotHeader:SetText(ns.BAR_NAMES[ns.db.bar] or ("Bar " .. ns.db.bar))

    local grid, gridRows, gridCols = ns.Slots.GridLayout()
    gridCache = grid
    gridIs2D = grid and gridRows > 1 and gridCols > 1

    gridOrderButton:SetText(ns.db.gridButtonOrder == "LRM" and "L  R  M" or "L  M  R")

    -- Spell out the whole mapping rather than naming an axis. Two different
    -- Edit Mode settings can produce the same shape, so "columns are buttons"
    -- on its own does not tell you what a click will do.
    local axis, forced = ns.ResolvedGridAxis(gridRows, gridCols)
    local buttonWord = (ns.db.gridButtonOrder == "LRM") and "Left / Right / Middle"
                                                        or "Left / Middle / Right"
    local axisText
    if not grid then
        axisText = "bar layout not readable"
    elseif axis == "enumerate" then
        axisText = ("%d slots, mapped in reading order: %s, then the same with Shift, Ctrl and Alt.")
            :format(#slotRows, buttonWord)
    elseif axis == "col" then
        axisText = ("%d wide x %d tall. Columns are %s; rows are none / Shift / Ctrl / Alt.")
            :format(gridCols, gridRows, buttonWord)
    else
        axisText = ("%d wide x %d tall. Rows are %s; columns are none / Shift / Ctrl / Alt.")
            :format(gridCols, gridRows, buttonWord)
    end
    gridAxisLabel:SetText(("|cffa0a0a0Current grid alignment:|r |cff808080%s%s|r")
        :format(axisText, forced and " (forced)" or ""))

    UpdatePreview(grid, gridRows, gridCols)

    -- Reshaping a bar moves every slot to a different cell, so the mapping
    -- made for the old shape no longer describes the new one. Say so rather
    -- than letting it look like the bindings scrambled themselves.
    local shape = grid and ("%dx%d"):format(gridCols, gridRows) or nil
    local function Highlight(r, g, b)
        previewTipBg:SetColorTexture(r, g, b, 0.12)
        previewTipEdge:SetColorTexture(r, g, b, 0.9)
        previewTipBg:Show()
        previewTipEdge:Show()
    end

    previewTipBg:Hide()
    previewTipEdge:Hide()

    if not grid then
        previewHeader:SetText("|cff808080Bar layout not readable.|r")
    elseif ns.db.lastMappedShape and shape ~= ns.db.lastMappedShape then
        Highlight(1, 0.3, 0.3)
        previewHeader:SetText(("|cffff6060This bar was %s when you mapped it and is now %s.|r\n|cffffffffPress Map grid to clicks again.|r")
            :format(ns.db.lastMappedShape, shape))
    elseif gridCols > gridRows then
        -- A bar wider than it is tall puts the mouse buttons on the rows, so
        -- Left / Middle / Right run downwards. It works, and it reads badly
        -- against a mouse, which is laid out left to right.
        Highlight(1, 0.82, 0)
        previewHeader:SetText("|cffffcc00Heads up - this bar is horizontal.|r\n|cffffffffThe grid works best Vertical, 3 columns wide: Left / Middle / Right across the top, modifiers down.|r")
    else
        previewHeader:SetText("|cffa0a0a0Your bar, and the click each slot gets:|r")
    end
    if grid then
        slotHeader:SetText(("%s  |cff6699cc%dx%d|r"):format(
            ns.BAR_NAMES[ns.db.bar] or ("Bar " .. ns.db.bar), gridCols, gridRows))
    end

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
    -- The client's own self-cast / focus-cast modifiers hijack the unit before
    -- any binding runs, so a collision looks exactly like a dead binding.
    local conflicts = ns.ModifierConflicts and ns.ModifierConflicts() or {}
    if #conflicts > 0 then
        local seen, names = {}, {}
        for _, c in ipairs(conflicts) do
            if not seen[c.key] then
                seen[c.key] = true
                names[#names + 1] = ("%s is your %s key"):format(c.key, c.setting)
            end
        end
        messages[#messages + 1] = ("|cffff6060%d binding(s) use a hijacked modifier (%s). Those clicks act on you, not the frame. Rebind, or change it in Options > Combat.|r")
            :format(#conflicts, table.concat(names, ", "))
    end

    for _, entry in ipairs(ns.StrandedBindings and ns.StrandedBindings() or {}) do
        messages[#messages + 1] = ("|cffff6060%s is the unit menu, which cannot fire on press. Use |r|cffffff00/slotcast clicks up|r|cffff6060 if you need it.|r")
            :format(ns.ComboText(entry.combo))
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
    standalone = BuildStandalone()

    -- A separate host frame so Settings owns something that is not the content
    -- itself; the content moves between the two on show.
    settingsHost = CreateFrame("Frame", "SlotCastSettingsHost", UIParent)
    settingsHost.name = "SlotCast"
    settingsHost:Hide()
    settingsHost:SetScript("OnShow", function(self)
        if standalone then standalone:Hide() end
        AttachTo(self)
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local ok, result = pcall(Settings.RegisterCanvasLayoutCategory, settingsHost, "SlotCast")
        if ok and result then
            category = result
            category.ID = "SlotCast"
            pcall(Settings.RegisterAddOnCategory, category)
        end
    elseif InterfaceOptions_AddCategory then
        pcall(InterfaceOptions_AddCategory, settingsHost)
    end
end

function Options.Open()
    if not standalone then
        ns.Warn("options window was never built - run /slotcast status.")
        return
    end
    if standalone:IsShown() then
        standalone:Hide()
    else
        standalone:Show()
    end
end
