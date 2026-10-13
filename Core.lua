------------------------------------------------------------
-- Grimfall MythicPlus Timer
-- Compact Mythic+ timer replacement for Grimfall
------------------------------------------------------------

local ADDON_NAME = "GrimfallMythicPlusTimer"

GrimfallMythicPlusTimerDB = GrimfallMythicPlusTimerDB or GrimfallDepleteDB or {}
local DB = GrimfallMythicPlusTimerDB

DB.point = DB.point or "CENTER"
DB.relativePoint = DB.relativePoint or "CENTER"
DB.x = DB.x or 350
DB.y = DB.y or 80
DB.locked = DB.locked or false
if DB.panelVisible == nil then
    DB.panelVisible = false
end

local UPDATE_INTERVAL = 0.05
local MIN_FRAME_WIDTH = 260
local BASE_FRAME_HEIGHT = 132
local OBJECTIVE_HEIGHT = 22
local BAR_HEIGHT = 6
local MAX_OBJECTIVES = 8

local frame
local dungeonText
local levelText
local timerText
local forcesLabel
local forcesText
local forcesBar
local objectiveTexts = {}

local testMode = false
local manuallyHidden = false

local currentRunID = nil
local bossOrder = {}
local bossState = {}
local runAffixNames = {}
local completedSnapshot = nil

local timerRunID = nil
local timerBaseElapsed = nil
local timerBaseLocalTime = nil
local timerLastAPIElapsed = nil

local lastLiveElapsed = 0
local lastLiveLimit = 1800
local lastKnownData = nil

local hookedBlizzardFrame = false

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

local function Msg(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ff00[Grimfall MythicPlus Timer]|r " .. tostring(text)
        )
    end
end

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function FormatTime(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then seconds = 0 end
    return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function IsStillInDungeon()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "party"
end

local function CleanText(text)
    if not text then return nil end
    text = tostring(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return text
end

local function CleanObjectiveName(objective)
    local name

    if type(objective) == "string" then
        name = objective
    elseif type(objective) == "table" then
        name = objective.name
            or objective.text
            or objective.description
            or objective.label
            or objective.objectiveName
            or objective.title
            or objective.target
    end

    name = CleanText(name)
    if not name then return nil end

    name = string.gsub(name, "^%s*%d+%s*/%s*%d+%s+", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    return name
end

local function IsEnemyForcesObjective(name)
    if not name then return false end
    return string.find(string.lower(name), "enemy forces", 1, true) ~= nil
end

local function IsObjectiveComplete(objective)
    if type(objective) ~= "table" then return false end

    if objective.complete ~= nil then return objective.complete and true or false end
    if objective.completed ~= nil then return objective.completed and true or false end
    if objective.isComplete ~= nil then return objective.isComplete and true or false end

    local current = tonumber(
        objective.current
        or objective.currentCount
        or objective.quantity
        or objective.completedCount
        or 0
    ) or 0

    local required = tonumber(
        objective.required
        or objective.requiredCount
        or objective.total
        or objective.totalCount
        or 1
    ) or 1

    return required > 0 and current >= required
end

local function CopyTable(source)
    local copy = {}
    if type(source) ~= "table" then return copy end
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

------------------------------------------------------------
-- Mythic+ data sources
------------------------------------------------------------

local function GetLiveRunData()
    if not C_MythicPlus or not C_MythicPlus.GetRunProgress then
        return nil
    end

    local ok, data = pcall(C_MythicPlus.GetRunProgress)
    if not ok or type(data) ~= "table" then
        return nil
    end

    return data
end

local function GetFrameRunData()
    if MythicPlusRunProgressFrame
    and type(MythicPlusRunProgressFrame.runProgressData) == "table"
    then
        return MythicPlusRunProgressFrame.runProgressData
    end
    return nil
end

local function BuildRunData()
    local live = GetLiveRunData()
    local ui = GetFrameRunData()

    if not live and not ui then
        return nil
    end

    local data = CopyTable(live or ui)

    -- The custom API may omit objectives while the Blizzard frame still has them.
    if (type(data.objectives) ~= "table" or #data.objectives == 0)
    and ui and type(ui.objectives) == "table"
    then
        data.objectives = ui.objectives
    end

    -- Preserve affixes from the UI data when the live API returns an empty list.
    if (type(data.affixes) ~= "table" or #data.affixes == 0)
    and ui and type(ui.affixes) == "table"
    then
        data.affixes = ui.affixes
    end

    data.mapName = data.mapName or (ui and ui.mapName)
    data.level = data.level or (ui and ui.level)
    data.challengeMapID = data.challengeMapID or (ui and ui.challengeMapID)
    data.instanceMapID = data.instanceMapID or (ui and ui.instanceMapID)
    data.startTimeMilliseconds = data.startTimeMilliseconds or (ui and ui.startTimeMilliseconds)
    data.forcesCurrent = data.forcesCurrent or (ui and ui.forcesCurrent)
    data.forcesRequired = data.forcesRequired or (ui and ui.forcesRequired)
    data.forcesPercent = data.forcesPercent or (ui and ui.forcesPercent)
    data.timeLimitSeconds = data.timeLimitSeconds or (ui and ui.timeLimitSeconds)

    return data
end

------------------------------------------------------------
-- Affixes
------------------------------------------------------------

-- IDs confirmed by the user's own Grimfall debug output.
-- These are used only as a final safety fallback when Grimfall exposes the
-- active run affix IDs but does not provide their localized names yet.
local KNOWN_AFFIX_NAMES = {
    [9] = "Tyrannical",
    [10] = "Fortified",
}

local lastAffixRequestTime = 0

local function RequestCurrentAffixData()
    if not C_MythicPlus or not C_MythicPlus.RequestCurrentAffixes then
        return
    end

    local now = GetTime and GetTime() or 0
    if (now - lastAffixRequestTime) < 2 then
        return
    end

    lastAffixRequestTime = now
    pcall(C_MythicPlus.RequestCurrentAffixes)
end

local function CollectAffixCatalog()
    local byID = {}
    local names = {}
    local added = {}

    RequestCurrentAffixData()

    if C_MythicPlus and C_MythicPlus.GetCurrentAffixes then
        local ok, affixes = pcall(C_MythicPlus.GetCurrentAffixes)
        if ok and type(affixes) == "table" then
            -- Use pairs because Grimfall can expose sparse/keyed tables.
            for key, affix in pairs(affixes) do
                local id
                local name

                if type(affix) == "table" then
                    id = affix.id or affix.affixID or affix.keystoneAffixID
                    name = affix.name or affix.affixName
                elseif type(affix) == "number" then
                    id = affix
                elseif type(affix) == "string" then
                    name = affix
                    if type(key) == "number" and key > 8 then
                        id = key
                    end
                end

                if id and name and name ~= "" then
                    byID[tonumber(id) or id] = name
                end

                if name and name ~= "" and not added[name] then
                    added[name] = true
                    table.insert(names, name)
                end
            end
        end
    end

    return byID, names
end

local function ResolveAffixName(affix, catalogByID)
    if not affix then return nil end

    local id
    local name

    if type(affix) == "table" then
        name = affix.name or affix.affixName
        id = affix.id or affix.affixID or affix.keystoneAffixID
    elseif type(affix) == "number" then
        id = affix
    elseif type(affix) == "string" then
        local numeric = tonumber(affix)
        if numeric then
            id = numeric
        else
            name = affix
        end
    end

    if name and name ~= "" then
        return name
    end

    id = tonumber(id) or id

    -- Preferred fallback: resolve the run ID against the current-affix catalog.
    if id and catalogByID and catalogByID[id] then
        return catalogByID[id]
    end

    if id and C_ChallengeMode and C_ChallengeMode.GetAffixInfo then
        local ok, r1, r2, r3, r4 = pcall(C_ChallengeMode.GetAffixInfo, id)
        if ok then
            if type(r1) == "string" and r1 ~= "" then
                return r1
            elseif type(r1) == "table" then
                local resolved = r1.name or r1.affixName or r1.text
                if resolved and resolved ~= "" then
                    return resolved
                end
            end

            if type(r2) == "string" and r2 ~= "" then return r2 end
            if type(r3) == "string" and r3 ~= "" then return r3 end
            if type(r4) == "string" and r4 ~= "" then return r4 end
        end
    end

    -- Final deterministic fallback for the IDs that were explicitly observed
    -- in the foreign-key debug: 10 = Fortified, 9 = Tyrannical.
    if id and KNOWN_AFFIX_NAMES[id] then
        return KNOWN_AFFIX_NAMES[id]
    end

    return nil
end

local function GetAffixNames(data)
    local names = {}
    local added = {}
    local catalogByID, currentNames = CollectAffixCatalog()

    local function AddResolved(affix)
        local name = ResolveAffixName(affix, catalogByID)
        if name and name ~= "" and not added[name] then
            added[name] = true
            table.insert(names, name)
        end
    end

    -- 1. Primary source: affixes attached to the active run.
    -- The foreign-key debug showed entries with IDs only: 10 and 9.
    if data and type(data.affixes) == "table" then
        for _, affix in pairs(data.affixes) do
            AddResolved(affix)
        end
    end

    -- 2. Read the hidden Blizzard/Grimfall frame directly as well. This is
    -- important for another player's key because runProgressData is one of the
    -- confirmed sources for those affix IDs.
    if #names == 0 then
        local ui = GetFrameRunData()
        if ui and type(ui.affixes) == "table" then
            for _, affix in pairs(ui.affixes) do
                AddResolved(affix)
            end
        end
    end

    -- 3. Active keystone fallback. The user's debug confirmed the exact return
    -- shape for a foreign key: r1 = level, r2 = {10, 9}.
    if #names == 0 and C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local ok, _, affixIDs = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
        if ok and type(affixIDs) == "table" then
            for _, id in pairs(affixIDs) do
                AddResolved(id)
            end
        end
    end

    -- 4. Final fallback: names exposed directly by GetCurrentAffixes.
    if #names == 0 then
        for _, name in ipairs(currentNames) do
            if name and name ~= "" and not added[name] then
                added[name] = true
                table.insert(names, name)
            end
        end
    end

    -- Cache the first valid set for the lifetime of the current run so a short
    -- API gap cannot make the header lose its affixes.
    if #names > 0 then
        runAffixNames = {}
        for i, name in ipairs(names) do
            runAffixNames[i] = name
        end
    elseif #runAffixNames > 0 then
        for i, name in ipairs(runAffixNames) do
            names[i] = name
        end
    end

    return names
end

local function BuildHeaderLine(data)
    local parts = {}

    if data and data.level then
        table.insert(parts, "[+" .. tostring(data.level) .. "]")
    end

    for _, name in ipairs(GetAffixNames(data)) do
        table.insert(parts, name)
    end

    return table.concat(parts, " - ")
end

------------------------------------------------------------
-- Boss tracking
------------------------------------------------------------

local function ResetRun(runID)
    currentRunID = runID
    bossOrder = {}
    bossState = {}
    runAffixNames = {}
    completedSnapshot = nil

    timerRunID = nil
    timerBaseElapsed = nil
    timerBaseLocalTime = nil
    timerLastAPIElapsed = nil
end

local function FindBossState(name)
    if not name then return nil end
    if bossState[name] then return bossState[name] end

    local lowerName = string.lower(name)
    for storedName, state in pairs(bossState) do
        local lowerStored = string.lower(storedName)
        if string.find(lowerName, lowerStored, 1, true)
        or string.find(lowerStored, lowerName, 1, true)
        then
            return state
        end
    end

    return nil
end

local function EnsureBoss(name)
    if not name or name == "" or IsEnemyForcesObjective(name) then
        return nil
    end

    local existing = FindBossState(name)
    if existing then return existing end

    local state = {
        name = name,
        complete = false,
        killTime = nil
    }

    bossState[name] = state
    table.insert(bossOrder, name)
    return state
end

local function TrackObjectives(data, elapsedSeconds, finalizeMissingTimes)
    if not data or type(data.objectives) ~= "table" then
        return
    end

    for _, objective in ipairs(data.objectives) do
        local name = CleanObjectiveName(objective)

        if name and not IsEnemyForcesObjective(name) then
            local state = EnsureBoss(name)
            local complete = IsObjectiveComplete(objective)

            if state then
                if complete then
                    state.complete = true
                    if not state.killTime and (finalizeMissingTimes or elapsedSeconds) then
                        state.killTime = FormatTime(elapsedSeconds or 0)
                    end
                end
            end
        end
    end
end

local function RecordEncounterKill(encounterName, elapsedSeconds)
    local cleanName = CleanText(encounterName)
    if not cleanName or cleanName == "" then return end

    local state = FindBossState(cleanName) or EnsureBoss(cleanName)
    if state then
        state.complete = true
        if not state.killTime then
            state.killTime = FormatTime(elapsedSeconds or 0)
        end
    end
end

------------------------------------------------------------
-- Timer
------------------------------------------------------------

local function GetAPIElapsed(data)
    if not data then return nil end

    if type(data.elapsedSeconds) == "number" then
        return data.elapsedSeconds
    end

    if type(data.elapsedMilliseconds) == "number" then
        return data.elapsedMilliseconds / 1000
    end

    if type(data.timerElapsedSeconds) == "number" then
        return data.timerElapsedSeconds
    end

    return nil
end

local function GetTimeLimit(data)
    if data then
        if type(data.timeLimitSeconds) == "number" then
            return data.timeLimitSeconds
        end
        if type(data.timeLimitMilliseconds) == "number" then
            return data.timeLimitMilliseconds / 1000
        end
    end

    if C_MythicPlus and C_MythicPlus.GetRunTimer then
        local _, _, limit = C_MythicPlus.GetRunTimer()
        if type(limit) == "number" then
            if limit > 100000 then return limit / 1000 end
            return limit
        end
    end

    return 1800
end

local function GetSmoothTimer(data)
    local now = GetTime()
    local runID = data and data.startTimeMilliseconds or nil
    local apiElapsed = GetAPIElapsed(data)

    if runID and runID ~= timerRunID then
        timerRunID = runID
        timerBaseElapsed = apiElapsed or 0
        timerLastAPIElapsed = apiElapsed or 0
        timerBaseLocalTime = now
    end

    if timerBaseElapsed == nil then
        timerBaseElapsed = apiElapsed or 0
        timerLastAPIElapsed = apiElapsed or 0
        timerBaseLocalTime = now
    end

    if apiElapsed
    and (timerLastAPIElapsed == nil or math.abs(apiElapsed - timerLastAPIElapsed) > 0.05)
    then
        timerBaseElapsed = apiElapsed
        timerLastAPIElapsed = apiElapsed
        timerBaseLocalTime = now
    end

    local elapsed = (timerBaseElapsed or 0) + (now - (timerBaseLocalTime or now))
    return elapsed, GetTimeLimit(data)
end

------------------------------------------------------------
-- UI
------------------------------------------------------------

local PANEL_WIDTH = 290
local HEADER_HEIGHT = 132
local BOSS_ROW_HEIGHT = 24
local BOTTOM_PADDING = 5
local CONTENT_PADDING = 12

frame = CreateFrame("Frame", "GrimfallMythicPlusTimerFrame", UIParent)
frame:SetWidth(PANEL_WIDTH)
frame:SetHeight(HEADER_HEIGHT)
frame:SetPoint(DB.point, UIParent, DB.relativePoint, DB.x, DB.y)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)

frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 10,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
-- Keep the backdrop objects in place. Their visibility is toggled with /gmpt panel.
local function ApplyPanelStyle()
    if DB.panelVisible then
        -- Light neutral background with a solid black border.
        frame:SetBackdropColor(0.72, 0.74, 0.78, 0.34)
        frame:SetBackdropBorderColor(0, 0, 0, 0.95)
    else
        -- Fully transparent background and border.
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

------------------------------------------------------------
-- Title and drag area
------------------------------------------------------------

dungeonText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dungeonText:SetShadowColor(0, 0, 0, 0.85)
dungeonText:SetShadowOffset(1.5, -1.5)
dungeonText:SetPoint("TOP", frame, "TOP", 0, -11)
dungeonText:SetWidth(PANEL_WIDTH - 24)
dungeonText:SetJustifyH("CENTER")
dungeonText:SetTextColor(1, 1, 1)

local dragArea = CreateFrame("Frame", nil, frame)
dragArea:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -7)
dragArea:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -7)
dragArea:SetHeight(30)
dragArea:EnableMouse(true)
dragArea:RegisterForDrag("LeftButton")

frame:SetMovable(true)

dragArea:SetScript("OnDragStart", function()
    if not DB.locked then
        frame:StartMoving()
    end
end)

dragArea:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    DB.point = point
    DB.relativePoint = relativePoint
    DB.x = x
    DB.y = y
end)

------------------------------------------------------------
-- Key level and affixes
------------------------------------------------------------

levelText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
levelText:SetShadowColor(0, 0, 0, 0.85)
levelText:SetShadowOffset(1.5, -1.5)
levelText:SetPoint("TOP", dungeonText, "BOTTOM", 0, -2)
levelText:SetWidth(PANEL_WIDTH - 24)
levelText:SetJustifyH("CENTER")
levelText:SetTextColor(0.56, 0.58, 0.62)

------------------------------------------------------------
-- Timer
------------------------------------------------------------

timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
timerText:SetShadowColor(0, 0, 0, 0.85)
timerText:SetShadowOffset(1.5, -1.5)
timerText:SetPoint("TOP", levelText, "BOTTOM", 0, -6)
timerText:SetWidth(PANEL_WIDTH - 24)
timerText:SetJustifyH("CENTER")

------------------------------------------------------------
-- Enemy Forces
------------------------------------------------------------

forcesLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
forcesLabel:SetShadowColor(0, 0, 0, 0.85)
forcesLabel:SetShadowOffset(1.5, -1.5)
forcesLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT_PADDING, -91)
forcesLabel:SetText("Enemy Forces")
forcesLabel:SetTextColor(0.90, 0.90, 0.92)

forcesText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
forcesText:SetShadowColor(0, 0, 0, 0.85)
forcesText:SetShadowOffset(1.5, -1.5)
forcesText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -CONTENT_PADDING, -91)
forcesText:SetJustifyH("RIGHT")
forcesText:SetTextColor(1, 1, 1)

forcesBar = CreateFrame("StatusBar", nil, frame)
forcesBar:SetPoint("TOPLEFT", frame, "TOPLEFT", CONTENT_PADDING, -111)
forcesBar:SetWidth(PANEL_WIDTH - (CONTENT_PADDING * 2))
forcesBar:SetHeight(BAR_HEIGHT)
forcesBar:SetMinMaxValues(0, 100)
forcesBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
forcesBar:SetStatusBarColor(0.00, 0.93, 0.93, 1)

local barBackground = forcesBar:CreateTexture(nil, "BACKGROUND")
barBackground:SetAllPoints(forcesBar)
barBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
barBackground:SetVertexColor(0.03, 0.08, 0.09, 0.95)

------------------------------------------------------------
-- Boss rows
-- No decorative separator lines are used in this transparent layout.
------------------------------------------------------------

for i = 1, MAX_OBJECTIVES do
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
text:SetShadowColor(0, 0, 0, 0.85)
text:SetShadowOffset(1.5, -1.5)
    text:SetPoint(
        "TOPLEFT",
        frame,
        "TOPLEFT",
        CONTENT_PADDING + 2,
        -132 - ((i - 1) * BOSS_ROW_HEIGHT)
    )
    text:SetWidth(PANEL_WIDTH - ((CONTENT_PADDING + 2) * 2))
    text:SetJustifyH("LEFT")
    text:Hide()
    objectiveTexts[i] = text

end

local function UpdateFrameSize()
    local bossCount = math.min(#bossOrder, MAX_OBJECTIVES)
    local height = HEADER_HEIGHT

    if bossCount > 0 then
        height = HEADER_HEIGHT + (bossCount * BOSS_ROW_HEIGHT) + BOTTOM_PADDING
    end

    frame:SetWidth(PANEL_WIDTH)
    frame:SetHeight(height)
    forcesBar:SetWidth(PANEL_WIDTH - (CONTENT_PADDING * 2))

end

local function RenderBosses()
    for i = 1, MAX_OBJECTIVES do
        objectiveTexts[i]:Hide()
        objectiveTexts[i]:SetText("")
    end

    local shown = 0

    for _, name in ipairs(bossOrder) do
        if shown >= MAX_OBJECTIVES then
            break
        end

        local state = bossState[name]
        if state then
            shown = shown + 1
            local text = objectiveTexts[shown]

            if state.complete and state.killTime then
                text:SetText(
                    "|cff00ff55[" .. state.killTime .. "]  " .. state.name .. "|r"
                )
            elseif state.complete then
                text:SetText("|cff00ff55" .. state.name .. "|r")
            else
                text:SetText("|cffffffff" .. state.name .. "|r")
            end

            text:Show()
        end
    end

    UpdateFrameSize()
end

local function RenderRun(data, elapsedSeconds, limitSeconds)
    dungeonText:SetText(data.mapName or "Mythic+")
    levelText:SetText(BuildHeaderLine(data))

    local elapsedColor
    if elapsedSeconds <= limitSeconds then
        elapsedColor = "|cff00e9f0"
    else
        elapsedColor = "|cffff5050"
    end

    timerText:SetText(
        elapsedColor
        .. FormatTime(elapsedSeconds)
        .. "|r |cffd8dde3/|r |cffffffff"
        .. FormatTime(limitSeconds)
        .. "|r"
    )

    local current = tonumber(data.forcesCurrent) or 0
    local required = tonumber(data.forcesRequired) or 0
    local percent = tonumber(data.forcesPercent)

    if not percent then
        percent = required > 0 and (current / required * 100) or 0
    end

    percent = Clamp(percent, 0, 100)
    forcesBar:SetValue(percent)
    forcesText:SetText(
        tostring(current)
        .. " / "
        .. tostring(required)
        .. "  "
        .. string.format("%.1f%%", percent)
    )

    if percent >= 100 then
        forcesLabel:SetTextColor(0.00, 1.00, 0.33)
        forcesText:SetTextColor(0.00, 1.00, 0.33)
    else
        forcesLabel:SetTextColor(0.90, 0.90, 0.92)
        forcesText:SetTextColor(1, 1, 1)
    end

    RenderBosses()
end

local function CaptureSnapshot(data, elapsedSeconds, limitSeconds)
    completedSnapshot = {
        mapName = data.mapName or "Mythic+",
        headerLine = BuildHeaderLine(data),
        elapsedSeconds = elapsedSeconds or 0,
        limitSeconds = limitSeconds or 1800,
        forcesCurrent = tonumber(data.forcesCurrent) or 0,
        forcesRequired = tonumber(data.forcesRequired) or 0,
        forcesPercent = tonumber(data.forcesPercent) or 0,
        bosses = {}
    }

    for _, name in ipairs(bossOrder) do
        local state = bossState[name]
        if state then
            table.insert(completedSnapshot.bosses, {
                name = state.name,
                complete = state.complete,
                killTime = state.killTime
            })
        end
    end
end

local function RenderSnapshot()
    if not completedSnapshot then
        return
    end

    dungeonText:SetText(completedSnapshot.mapName)
    levelText:SetText(completedSnapshot.headerLine)

    local elapsedColor
    if completedSnapshot.elapsedSeconds <= completedSnapshot.limitSeconds then
        elapsedColor = "|cff00e9f0"
    else
        elapsedColor = "|cffff5050"
    end

    timerText:SetText(
        elapsedColor
        .. FormatTime(completedSnapshot.elapsedSeconds)
        .. "|r |cffd8dde3/|r |cffffffff"
        .. FormatTime(completedSnapshot.limitSeconds)
        .. "|r"
    )

    local percent = completedSnapshot.forcesPercent
    if not percent or percent == 0 then
        percent = completedSnapshot.forcesRequired > 0
            and (completedSnapshot.forcesCurrent / completedSnapshot.forcesRequired * 100)
            or 0
    end

    forcesBar:SetValue(Clamp(percent, 0, 100))
    forcesText:SetText(
        tostring(completedSnapshot.forcesCurrent)
        .. " / "
        .. tostring(completedSnapshot.forcesRequired)
        .. "  "
        .. string.format("%.1f%%", percent)
    )

    if percent >= 100 then
        forcesLabel:SetTextColor(0.00, 1.00, 0.33)
        forcesText:SetTextColor(0.00, 1.00, 0.33)
    else
        forcesLabel:SetTextColor(0.90, 0.90, 0.92)
        forcesText:SetTextColor(1, 1, 1)
    end

    bossOrder = {}
    bossState = {}

    for _, boss in ipairs(completedSnapshot.bosses) do
        table.insert(bossOrder, boss.name)
        bossState[boss.name] = {
            name = boss.name,
            complete = boss.complete,
            killTime = boss.killTime
        }
    end

    RenderBosses()
end

------------------------------------------------------------
-- Blizzard frame suppression
------------------------------------------------------------

local function HideBlizzardFrame()
    if not MythicPlusRunProgressFrame then return end

    -- Do not actually Hide() the Blizzard frame. Grimfall updates
    -- runProgressData (including affixes/objectives for another player's key)
    -- while this frame is alive. Keeping it shown but fully transparent lets
    -- the underlying data continue to refresh without displaying the UI.
    if not hookedBlizzardFrame then
        hookedBlizzardFrame = true
        MythicPlusRunProgressFrame:HookScript("OnShow", function(self)
            if not testMode then
                self:SetAlpha(0)
                if self.EnableMouse then self:EnableMouse(false) end
            end
        end)
    end

    MythicPlusRunProgressFrame:SetAlpha(0)
    if MythicPlusRunProgressFrame.EnableMouse then
        MythicPlusRunProgressFrame:EnableMouse(false)
    end
end

------------------------------------------------------------
-- Main update
------------------------------------------------------------

local function Update()
    if manuallyHidden then
        frame:Hide()
        return
    end

    if testMode then
        frame:Show()
        return
    end

    local data = BuildRunData()

    if not data then
        if completedSnapshot and IsStillInDungeon() then
            frame:Show()
            HideBlizzardFrame()
            RenderSnapshot()
            return
        end

        if not IsStillInDungeon() then
            completedSnapshot = nil
        end

        frame:Hide()
        return
    end

    local runID = data.startTimeMilliseconds
    if runID and runID ~= currentRunID then
        ResetRun(runID)
    end

    if data.completed or data.finished or data.complete then
        local finalElapsed = GetAPIElapsed(data) or lastLiveElapsed or 0
        local finalLimit = GetTimeLimit(data)

        TrackObjectives(data, finalElapsed, true)
        CaptureSnapshot(data, finalElapsed, finalLimit)

        lastKnownData = data
        lastLiveElapsed = finalElapsed
        lastLiveLimit = finalLimit

        frame:Show()
        HideBlizzardFrame()
        RenderSnapshot()
        return
    end

    local elapsedSeconds, limitSeconds = GetSmoothTimer(data)
    lastLiveElapsed = elapsedSeconds
    lastLiveLimit = limitSeconds
    lastKnownData = data

    TrackObjectives(data, elapsedSeconds, false)

    frame:Show()
    HideBlizzardFrame()
    RenderRun(data, elapsedSeconds, limitSeconds)
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("ENCOUNTER_END")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon == ADDON_NAME then
            -- SavedVariables are guaranteed to be available here.
            GrimfallMythicPlusTimerDB = GrimfallMythicPlusTimerDB or {}
            DB = GrimfallMythicPlusTimerDB

            if DB.point == nil then DB.point = "CENTER" end
            if DB.relativePoint == nil then DB.relativePoint = "CENTER" end
            if DB.x == nil then DB.x = 350 end
            if DB.y == nil then DB.y = 80 end
            if DB.locked == nil then DB.locked = false end
            if DB.panelVisible == nil then DB.panelVisible = false end

            -- Re-apply saved frame position after SavedVariables are restored.
            frame:ClearAllPoints()
            frame:SetPoint(
                DB.point,
                UIParent,
                DB.relativePoint,
                DB.x,
                DB.y
            )

            -- Most importantly: restore the saved panel state after /reload.
            ApplyPanelStyle()
        end

        return
    end

    if event == "PLAYER_LOGIN" then
        -- Safety re-apply in case another UI component changed the backdrop later.
        ApplyPanelStyle()
        Msg("loaded. Use /gmpt help")
        lastAffixRequestTime = 0
        RequestCurrentAffixData()
        HideBlizzardFrame()
        Update()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        if not IsStillInDungeon() then
            completedSnapshot = nil
        end
        Update()
        return
    end

    if event == "CHALLENGE_MODE_START" then
        testMode = false
        manuallyHidden = false
        ResetRun(nil)
        lastAffixRequestTime = 0
        RequestCurrentAffixData()
        HideBlizzardFrame()
        Update()
        return
    end

    if event == "ENCOUNTER_END" then
        local _, encounterName, _, _, success = ...
        if success == 1 and encounterName then
            RecordEncounterKill(encounterName, lastLiveElapsed)
            RenderBosses()
        end
        return
    end

    if event == "CHALLENGE_MODE_COMPLETED" then
        -- After completion, the Blizzard frame contains the authoritative final objectives.
        local finalData = GetFrameRunData() or BuildRunData() or lastKnownData

        if finalData then
            local finalElapsed = GetAPIElapsed(finalData) or lastLiveElapsed or 0
            local finalLimit = GetTimeLimit(finalData)

            -- Every objective marked complete in the final frame is finalized here,
            -- including the last boss when no ENCOUNTER_END event is fired.
            TrackObjectives(finalData, finalElapsed, true)
            CaptureSnapshot(finalData, finalElapsed, finalLimit)

            lastKnownData = finalData
            lastLiveElapsed = finalElapsed
            lastLiveLimit = finalLimit
        end

        frame:Show()
        RenderSnapshot()
        return
    end
end)

------------------------------------------------------------
-- Persistent updater
------------------------------------------------------------

local updaterFrame = CreateFrame("Frame")
updaterFrame.elapsed = 0
updaterFrame:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < UPDATE_INTERVAL then return end
    self.elapsed = 0
    Update()
end)

------------------------------------------------------------
-- Test mode
------------------------------------------------------------

local function ShowTestMode()
    testMode = true
    manuallyHidden = false
    frame:Show()

    dungeonText:SetText("Drak'Tharon Keep")
    levelText:SetText("[+12] - Fortified - Tyrannical")
    timerText:SetText("|cff00e9f012:17|r |cffd8dde3/|r |cffffffff30:00|r")
    forcesBar:SetValue(100)
    forcesText:SetText("58 / 58  100.0%")

    bossOrder = {
        "Trollgore",
        "Novos the Summoner",
        "King Dred",
        "The Prophet Tharon'ja"
    }

    bossState = {
        ["Trollgore"] = { name = "Trollgore", complete = true, killTime = "3:04" },
        ["Novos the Summoner"] = { name = "Novos the Summoner", complete = true, killTime = "7:20" },
        ["King Dred"] = { name = "King Dred", complete = true, killTime = "9:20" },
        ["The Prophet Tharon'ja"] = { name = "The Prophet Tharon'ja", complete = true, killTime = "12:17" }
    }

    RenderBosses()
end

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------

SLASH_GRIMFALLMYTHICPLUSTIMER1 = "/gmpt"
SLASH_GRIMFALLMYTHICPLUSTIMER2 = "/gmt"

SlashCmdList["GRIMFALLMYTHICPLUSTIMER"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "lock" then
        DB.locked = true
        Msg("frame locked")
        return
    end

    if msg == "unlock" then
        DB.locked = false
        Msg("frame unlocked")
        return
    end

    if msg == "reset" then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 350, 80)
        DB.point = "CENTER"
        DB.relativePoint = "CENTER"
        DB.x = 350
        DB.y = 80
        Msg("position reset")
        return
    end

    if msg == "hide" then
        manuallyHidden = true
        frame:Hide()
        return
    end

    if msg == "test" then
        if testMode then
            testMode = false
            bossOrder = {}
            bossState = {}
            Msg("test mode disabled")
            Update()
        else
            ShowTestMode()
            Msg("test mode enabled")
        end
        return
    end

    if msg == "panel" then
        DB.panelVisible = not DB.panelVisible
        ApplyPanelStyle()
        if DB.panelVisible then
            Msg("panel enabled")
        else
            Msg("panel disabled")
        end
        return
    end

    Msg("/gmpt panel - toggle background and border")
    Msg("/gmpt test - toggle test UI")
    Msg("/gmpt lock - lock frame")
    Msg("/gmpt unlock - unlock frame")
    Msg("/gmpt hide - hide frame")
    Msg("/gmpt reset - reset position")
end

frame:Hide()
