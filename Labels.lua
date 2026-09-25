-- SlotCast :: Labels
-- Draws each slot's click binding on the action button itself, so the bar is
-- its own reference card. Purely decorative: no secure code, no attributes.

local ADDON, ns = ...

ns.Labels = {}
local Labels = ns.Labels

local pool = {}  -- button frame -> font string

local function LabelFor(button)
    if pool[button] then return pool[button] end

    local ok, fs = pcall(function()
        local text = button:CreateFontString(nil, "OVERLAY")
        -- A narrow outlined font stays readable over a busy icon; fall back to
        -- a font object if that file is not present on this client.
        if not pcall(text.SetFont, text, "Fonts\\ARIALN.TTF", 11, "OUTLINE") then
            text:SetFontObject("GameFontNormalSmall")
        end
        text:SetPoint("TOPLEFT", 2, -2)
        text:SetTextColor(0.55, 0.85, 1)
        text:SetJustifyH("LEFT")
        return text
    end)

    if not ok or not fs then return nil end
    pool[button] = fs
    return fs
end

function Labels.Update()
    for _, fs in pairs(pool) do
        pcall(fs.Hide, fs)
    end

    if not ns.db or not ns.db.showBarLabels or not ns.db.enabled then return end

    local prefix = ns.BarButtonPrefix(ns.db.bar)
    if not prefix then return end

    for index = 1, ns.SLOTS_PER_BAR do
        local combo = ns.ComboForSlot(index)
        if combo then
            local button = _G[prefix .. index]
            if type(button) == "table" and not (button.IsForbidden and button:IsForbidden()) then
                local fs = LabelFor(button)
                if fs then
                    fs:SetText(ns.ShortCombo(combo))
                    fs:Show()
                end
            end
        end
    end
end
