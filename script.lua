local Config = {
    MinCrystalValue = "2m",
    SpeedBoost = 35,
    NormalSpeed = 16,
    FlySpeed = 100,
    AutoRejoinBoulders = false,
    AutoBuyBombs = false,
    RuneGrabRange = 20,
    PickRange = 13,
    PickBurst = 8,
    AutoSellThreshold = 0.5,
    MountainCenter = Vector3.new(42.67, 1066.7, 102.2),
    MountainRadius = 862.7,
    RemotesFolder = "Remotes",
    KeybindMenu = "RightControl",
    KeybindAimTp = "F",
}

if getgenv().UniverseLoaded then
    if getgenv().UniverseUnload then
        pcall(getgenv().UniverseUnload)
    end
end
getgenv().UniverseLoaded = true

local Services = {
    Players = game:GetService("Players"),
    CoreGui = game:GetService("CoreGui"),
    RunService = game:GetService("RunService"),
    Workspace = game:GetService("Workspace"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    UserInputService = game:GetService("UserInputService"),
    HttpService = game:GetService("HttpService"),
    TeleportService = game:GetService("TeleportService"),
    GuiService = game:GetService("GuiService"),
    VirtualUser = game:GetService("VirtualUser"),
}

local LocalPlayer = Services.Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local State = {
    afkRunning = true,
    espActive = false,
    playerEspActive = false,
    aimTpEnabled = false,
    speedActive = false,
    autoPickupActive = false,
    instantPromptActive = false,
    autoBuyBombs = false,
    minValue = 2000000,
    valueFilter = true,
    espScale = 0.7,
    playerScale = 0.6,
    boulderScale = 0.6,
    rootPart = nil,
    lastReport = 0,
    tpState = nil,
    sweepAccumulator = math.huge,
    statsDirty = true,
    statsAccumulator = 0,
    distanceAccumulator = math.huge,
    lastPickup = 0,
    lastBagWarn = 0,
    instantAccumulator = math.huge,
    registryCount = 0,
    espCount = 0,
    containerClock = 0,
    streamMark = 0,
    streamSpot = nil,
    speedHooked = nil,
}

local Storage = {
    afkConns = {},
    registry = {},
    candidates = {},
    dirty = {},
    espCache = {},
    containerConns = {},
    playerCache = {},
    containerList = {},
    sweepSeen = {},
    lastDistanceOrigin = nil,
    pendingActions = {},
    promptRestores = {},
    claimed = {},
    promptCache = setmetatable({}, { __mode = "k" }),
    instantPatched = {},
    netConns = {},
}

local Connections = {}

do
    local function silenceIdle()
        local ok, list = pcall(function()
            return getconnections(LocalPlayer.Idled)
        end)
        if not ok or type(list) ~= "table" then
            return
        end
        for _, connection in ipairs(list) do
            pcall(function()
                connection:Disable()
            end)
        end
    end

    local function nudge()
        pcall(function()
            Services.VirtualUser:CaptureController()
            Services.VirtualUser:ClickButton2(Vector3.new())
        end)
    end

    silenceIdle()
    Storage.afkConns[#Storage.afkConns + 1] = LocalPlayer.Idled:Connect(nudge)

    task.spawn(function()
        while State.afkRunning do
            task.wait(60)
            if not State.afkRunning or not LocalPlayer.Parent then
                break
            end
            silenceIdle()
            nudge()
        end
    end)
end

local function resolveGuiRoot()
    local ok, hidden = pcall(function()
        return gethui()
    end)
    if ok and typeof(hidden) == "Instance" then
        return hidden
    end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        return playerGui
    end

    return LocalPlayer:WaitForChild("PlayerGui", 10) or Services.CoreGui
end

local GuiRoot = resolveGuiRoot()

for _, container in ipairs({ GuiRoot, Services.CoreGui }) do
    for _, name in ipairs({ "UniverseESPGui", "UniverseCrystalEsp" }) do
        pcall(function()
            local existing = container:FindFirstChild(name)
            if existing then
                existing:Destroy()
            end
        end)
    end
end

local function findRemote(name)
    local folder = Services.ReplicatedStorage:FindFirstChild(Config.RemotesFolder) or Services.ReplicatedStorage:WaitForChild(Config.RemotesFolder, 10)
    if not folder then
        return nil
    end
    return folder:FindFirstChild(name) or folder:WaitForChild(name, 5)
end

local Remotes = {
    SellRequest = findRemote("SellRequest"),
    GoHome = findRemote("GoHome"),
    HoldComplete = findRemote("CrystalHoldComplete"),
    ToggleFavorite = findRemote("ToggleFavorite"),
    DigRequest = findRemote("DigRequest"),
    BombShopQuery = findRemote("BombShopQuery"),
    BombBuyRequest = findRemote("BombBuyRequest"),
    BombShopRestocked = findRemote("BombShopRestocked"),
    PlotPlaceRequest = findRemote("PlotPlaceRequest"),
}

local ESP = {
    font = Enum.Font.GothamBold,
    sweep = 0.5,
    budget = 0.005,
    offset = Vector3.new(0, 3, 0),
    width = 250,
    height = 66,
    text = 16,
    ttl = 5,
}

pcall(function()
    ESP.font = Enum.Font.LuckiestGuy
end)

local PLAYER = {
    offset = Vector3.new(0, -8, 0),
    width = 220,
    height = 44,
    text = 15,
}

local PACE = {
    boost = Config.SpeedBoost,
    normal = Config.NormalSpeed,
    stats = 0.25,
    distance = 0.05,
}

local TP = {
    offset = Vector3.new(0, 4.5, 0),
    hold = 0.35,
    clear = {
        Vector3.new(0, 0, 0),
        Vector3.new(0, 3, 0),
        Vector3.new(0, 7, 0),
        Vector3.new(5, 3, 0),
        Vector3.new(-5, 3, 0),
        Vector3.new(0, 3, 5),
        Vector3.new(0, 3, -5),
        Vector3.new(0, 12, 0),
        Vector3.new(9, 6, 0),
        Vector3.new(-9, 6, 0),
        Vector3.new(0, 6, 9),
        Vector3.new(0, 6, -9),
        Vector3.new(0, 20, 0),
    },
}

local PICK = {
    aimRange = 5000,
    aimDot = 0.995,
    range = Config.PickRange,
    cooldown = 0.04,
    restore = 0.2,
    burst = Config.PickBurst,
    retry = 0.15,
    forget = 5,
    pad = 4,
    instantRadius = 60,
    instantTick = 0.25,
}

local COLORS = {
    money = Color3.fromRGB(60, 255, 90),
    default = Color3.fromRGB(0, 225, 255),
    extra = Color3.fromRGB(255, 255, 255),
    player = Color3.fromRGB(255, 40, 140),
    stroke = Color3.fromRGB(0, 0, 0),
    hexDistance = "00E5FF",
    hexLuck = "FFC400",
}

local TIER_NAMES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }

local LUCK = {
    rarity = { 1, 1.6, 2.6, 4.2, 7, 12 },
    base = 0.00045,
    exponent = 0.5,
    cap = 500,
    bomb = 3,
    blood = 4,
}

local MUTATION_LUCK = {
    Verdant = 15,
    Voltaic = 20,
    Gilded = 18,
    Onyx = 28,
    Terminus = 40,
    Frost = 1.4,
    Fire = 1.4,
    Thunder = 1.5,
    Starfall = 1.3,
    Aurora = 2.2,
    Radioactive = 2,
    Poison = 1.5,
    Wet = 1,
}

local WATCHED_ATTRIBUTES = {
    "Value",
    "Collected",
    "WeightKg",
    "Tier",
    "TierName",
    "CrystalName",
    "Mutation",
    "ExtraMutations",
}

local SUFFIXES = { "", "k", "M", "B", "T", "Qa" }
local PARSE_MULTIPLIERS = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15 }
local CONTAINER_NAMES = { "DroppedCrystals", "Crystals" }

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local Window = Library:CreateWindow({
    Title = "TirvoxHub",
    Footer = "by tirvox",
    AutoShow = true,
    NotifySide = "Right",
    ShowCustomCursor = false,
})

local Tabs = {
    crystals = Window:AddTab("Crystals", "gem"),
    players = Window:AddTab("Players", "users"),
    boulders = Window:AddTab("Boulders", "mountain"),
    teleports = Window:AddTab("Teleports", "crosshair"),
    farming = Window:AddTab("Farming", "pickaxe"),
    movement = Window:AddTab("Movement", "zap"),
}

local SettingsTab = Window:AddTab("Settings", "sliders-horizontal")

local EspHolder = Instance.new("Folder")
EspHolder.Name = "UniverseCrystalEsp"
EspHolder.Parent = GuiRoot

local function reportError(context, err)
    local now = os.clock()
    if now - State.lastReport < 5 then
        return
    end
    State.lastReport = now
    warn(string.format("[TirvoxHub] %s: %s", context, tostring(err)))
end

local function formatShort(n, prefix)
    n = tonumber(n) or 0
    prefix = prefix or ""
    local sign = n < 0 and "-" or ""
    n = math.abs(n)
    if n < 1000 then
        return string.format("%s%s%d", sign, prefix, math.floor(n + 0.5))
    end
    local index = 0
    while n >= 1000 and index < #SUFFIXES - 1 do
        n /= 1000
        index += 1
    end
    return string.format("%s%s%.2f%s", sign, prefix, n, SUFFIXES[index + 1])
end

local function formatWeight(kg)
    kg = tonumber(kg) or 0
    if kg >= 1000 then
        return formatShort(kg) .. "kg"
    end
    return string.format("%.1fkg", kg)
end

local function formatDistance(studs)
    studs = tonumber(studs) or 0
    if studs >= 1000 then
        return string.format("%.1fkm", studs / 1000)
    end
    return string.format("%dm", math.floor(studs + 0.5))
end

local function formatLuck(score)
    local pct = (tonumber(score) or 0) * 100
    if pct <= 0 then
        return "+0%"
    end
    if pct < 1 then
        return string.format("+%.2f%%", pct)
    end
    if pct < 10 then
        return string.format("+%.1f%%", pct)
    end
    return string.format("+%.0f%%", pct)
end

local function parseValue(text)
    if type(text) ~= "string" then
        return nil
    end
    local cleaned = text:lower():gsub("[%s,%$_]", "")
    if cleaned == "" then
        return 0
    end
    local number, suffix = cleaned:match("^(%d*%.?%d+)(%a*)$")
    if not number then
        return nil
    end
    local base = tonumber(number)
    if not base then
        return nil
    end
    if suffix == "" then
        return base
    end
    local multiplier = PARSE_MULTIPLIERS[suffix]
    if not multiplier then
        return nil
    end
    return base * multiplier
end

local function bindCharacter(character)
    if not character then
        State.rootPart = nil
        return
    end
    State.rootPart = character:FindFirstChild("HumanoidRootPart")
end

bindCharacter(LocalPlayer.Character)

Connections.characterConn = LocalPlayer.CharacterAdded:Connect(function(character)
    State.rootPart = nil
    State.tpState = nil
    local waiter
    waiter = character.ChildAdded:Connect(function(child)
        if child.Name == "HumanoidRootPart" then
            State.rootPart = child
            waiter:Disconnect()
        end
    end)
    bindCharacter(character)
    if State.rootPart then
        waiter:Disconnect()
    end
end)

local function getRoot()
    if State.rootPart and State.rootPart.Parent then
        return State.rootPart
    end
    bindCharacter(LocalPlayer.Character)
    return State.rootPart
end

local function getAttr(inst, name)
    if not inst then
        return nil
    end
    local ok, value = pcall(inst.GetAttribute, inst, name)
    if ok then
        return value
    end
    return nil
end

local function crystalValue(inst)
    return tonumber(getAttr(inst, "Value")) or 0
end

local function crystalWeight(inst)
    return tonumber(getAttr(inst, "WeightKg")) or 0
end

local function crystalTier(inst)
    return tonumber(getAttr(inst, "Tier")) or 0
end

local function crystalRarity(inst)
    local name = getAttr(inst, "TierName")
    if type(name) == "string" and name ~= "" then
        return name
    end
    return TIER_NAMES[crystalTier(inst)] or "Unknown"
end

local function crystalName(inst)
    local name = getAttr(inst, "CrystalName")
    if type(name) == "string" and name ~= "" then
        return name
    end
    return inst and inst.Name or "Crystal"
end

local function crystalColor(inst)
    local r = tonumber(getAttr(inst, "TierColorR"))
    local g = tonumber(getAttr(inst, "TierColorG"))
    local b = tonumber(getAttr(inst, "TierColorB"))
    if r and g and b then
        return Color3.fromRGB(r, g, b)
    end
    return COLORS.default
end

local function mutationLuck(name)
    if type(name) ~= "string" or name == "" then
        return 1
    end
    return MUTATION_LUCK[name] or 1
end

local function combinedLuckMult(inst)
    local mutation = getAttr(inst, "Mutation")
    local roll = tonumber(getAttr(inst, "MutationLuckRoll"))
    local multiplier = (roll and roll > 0) and roll or mutationLuck(mutation)

    local extra = getAttr(inst, "ExtraMutations")
    if type(extra) == "string" and extra ~= "" then
        for name in string.gmatch(extra, "[^,]+") do
            if name ~= "" then
                multiplier *= mutationLuck(name)
            end
        end
    end

    if getAttr(inst, "IsBloodCrystal") == true then
        multiplier *= LUCK.blood
    end

    if getAttr(inst, "AdminMutation") == "Radioactive" and mutation ~= "Radioactive" then
        local hasRadioactive = type(extra) == "string" and extra:find("Radioactive", 1, true) ~= nil
        if not hasRadioactive then
            multiplier *= mutationLuck("Radioactive")
        end
    end

    return multiplier
end

local function computeLuck(inst)
    local tier = crystalTier(inst)
    if tier <= 0 then
        return 0
    end

    local weight = math.max(0, crystalWeight(inst))
    local base = (LUCK.rarity[tier] or LUCK.rarity[1]) * math.min(weight, LUCK.cap) ^ LUCK.exponent * LUCK.base

    if getAttr(inst, "BombCrystal") == true then
        base *= LUCK.bomb
    end

    return base * combinedLuckMult(inst)
end

local function luckLabel(inst)
    local hover = inst:FindFirstChild("CrystalHover")
    if not hover then
        return nil
    end
    local label = hover:FindFirstChild("LuckBoost")
    if not label or not label:IsA("TextLabel") then
        return nil
    end
    return label
end

local function luckLabelText(inst)
    local label = luckLabel(inst)
    if not label then
        return nil
    end
    return label.Text
end

local function crystalLuck(inst)
    local text = luckLabelText(inst)
    if type(text) == "string" then
        local pct = tonumber(text:match("([%d%.]+)%s*%%"))
        if pct and pct > 0 then
            return pct / 100
        end
    end
    return computeLuck(inst)
end

local function meetsFilter(inst, value)
    if not State.valueFilter then
        return true
    end
    return (value or crystalValue(inst)) >= State.minValue
end

local function ownsGamepass(name)
    local folder = LocalPlayer:FindFirstChild("GamepassesOwned")
    if not folder then
        return false
    end
    local flag = folder:FindFirstChild(name)
    return flag ~= nil and flag:IsA("BoolValue") and flag.Value == true
end

local function realStat(name)
    local data = LocalPlayer:FindFirstChild("PlayerData")
    local stats = data and data:FindFirstChild("RealStats")
    local entry = stats and stats:FindFirstChild(name)
    if not entry then
        return nil
    end
    return tonumber(entry.Value)
end

local function hasActiveRune(keyword)
    local data = LocalPlayer:FindFirstChild("PlayerData")
    local plot = data and data:FindFirstChild("PlotData")
    local runes = plot and plot:FindFirstChild("Runes")
    if not runes then
        return false
    end

    for _, child in ipairs(runes:GetChildren()) do
        local runeName = child:GetAttribute("RuneName")
        if type(runeName) == "string" and runeName:find(keyword, 1, true) then
            if (tonumber(child:GetAttribute("Remaining")) or 0) > 0 then
                return true
            end
        end
    end
    return false
end

local function backpackCapacity()
    if LocalPlayer:GetAttribute("InfBackpack") == true then
        return math.huge
    end

    local base = realStat("CarryWeight") or 10
    if ownsGamepass("CarryKgPlus4") then
        base *= 4
    end

    local total = base + (realStat("CarryWeightBonus") or 0)
    if hasActiveRune("Weight") then
        return total * 2
    end

    return total
end

local function backpackWeight()
    local total = 0

    local function scan(container)
        if not container then
            return
        end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") and getAttr(child, "Tier") ~= nil then
                local kg = tonumber(getAttr(child, "WeightKg"))
                if kg then
                    total += kg
                end
            end
        end
    end

    scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    scan(LocalPlayer.Character)

    return total
end

local function backpackFree()
    local capacity = backpackCapacity()
    if capacity == math.huge then
        return math.huge
    end
    return capacity - backpackWeight()
end

local function looksLikeCrystal(inst)
    if not inst:IsA("BasePart") then
        return false
    end
    return inst.Name:find("Crystal", 1, true) ~= nil
end

local crystalFlags = setmetatable({}, { __mode = "k" })

local function isCrystal(inst)
    local cached = crystalFlags[inst]
    if cached ~= nil then
        return cached
    end

    local result = false
    if inst:IsA("BasePart") and getAttr(inst, "Value") ~= nil then
        result = getAttr(inst, "CrystalName") ~= nil or inst.Name:find("Crystal", 1, true) ~= nil
    end

    crystalFlags[inst] = result
    return result
end

local function rebuildContainers()
    table.clear(Storage.containerList)
    local seen = {}

    local function push(container)
        if not container or seen[container] then
            return
        end
        seen[container] = true
        Storage.containerList[#Storage.containerList + 1] = container
    end

    push(Services.Workspace)
    for _, name in ipairs(CONTAINER_NAMES) do
        push(Services.Workspace:FindFirstChild(name))
    end

    local things = Services.Workspace:FindFirstChild("Things")
    if things then
        for _, name in ipairs(CONTAINER_NAMES) do
            push(things:FindFirstChild(name))
        end
    end
end

local function eachContainer(fn)
    local now = os.clock()
    local stale = #Storage.containerList == 0 or now - State.containerClock >= 1

    if not stale then
        for _, container in ipairs(Storage.containerList) do
            if not container.Parent and container ~= Services.Workspace then
                stale = true
                break
            end
        end
    end

    if stale then
        State.containerClock = now
        rebuildContainers()
    end

    for _, container in ipairs(Storage.containerList) do
        fn(container)
    end
end

local function newLabel(name, parent, order, total, color, rich, maxText)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Size = UDim2.new(1, 0, 1 / total, 0)
    label.Position = UDim2.new(0, 0, order / total, 0)
    label.Font = ESP.font
    label.TextScaled = true
    label.TextTransparency = 0
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3 = COLORS.stroke
    label.TextColor3 = color
    label.RichText = rich == true
    label.Text = ""
    label.Parent = parent

    local constraint = Instance.new("UITextSizeConstraint")
    constraint.MaxTextSize = maxText
    constraint.Parent = label

    return label, constraint
end

local function crystalGuiSize()
    return UDim2.fromOffset(ESP.width * State.espScale, ESP.height * State.espScale)
end

local function crystalTextSize()
    return math.max(6, math.floor(ESP.text * State.espScale + 0.5))
end

local function playerGuiSize()
    return UDim2.fromOffset(PLAYER.width * State.playerScale, PLAYER.height * State.playerScale)
end

local function playerTextSize()
    return math.max(6, math.floor(PLAYER.text * State.playerScale + 0.5))
end

local function createEntry(inst)
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "UniverseEsp"
    billboard.Adornee = inst
    billboard.AlwaysOnTop = true
    billboard.ResetOnSpawn = false
    billboard.LightInfluence = 0
    billboard.Size = crystalGuiSize()
    billboard.StudsOffsetWorldSpace = ESP.offset
    billboard.MaxDistance = math.huge
    billboard.Parent = EspHolder

    local textSize = crystalTextSize()
    local rarity, rarityConstraint = newLabel("Rarity", billboard, 0, 3, COLORS.default, false, textSize)
    local info, infoConstraint = newLabel("Info", billboard, 1, 3, COLORS.money, false, textSize)
    local extra, extraConstraint = newLabel("Extra", billboard, 2, 3, COLORS.extra, true, textSize)

    return {
        gui = billboard,
        rarity = rarity,
        info = info,
        extra = extra,
        constraints = { rarityConstraint, infoConstraint, extraConstraint },
        signature = false,
        luckText = "+0%",
        distanceText = false,
    }
end

local function destroyEntry(inst, entry)
    entry = entry or Storage.espCache[inst]
    if not entry then
        return
    end

    if entry.gui then
        entry.gui:Destroy()
    end

    Storage.espCache[inst] = nil
    State.espCount -= 1
    State.statsDirty = true
end

local function applyEspScale()
    local size = crystalGuiSize()
    local textSize = crystalTextSize()
    for _, entry in pairs(Storage.espCache) do
        if entry.gui then
            entry.gui.Size = size
        end
        for _, constraint in ipairs(entry.constraints) do
            constraint.MaxTextSize = textSize
        end
    end
end

local function applyPlayerScale()
    local size = playerGuiSize()
    local textSize = playerTextSize()
    for _, entry in pairs(Storage.playerCache) do
        if entry.gui then
            entry.gui.Size = size
        end
        for _, constraint in ipairs(entry.constraints) do
            constraint.MaxTextSize = textSize
        end
    end
end

local function applyExtra(entry, distanceText)
    entry.distanceText = distanceText
    entry.extra.Text = string.format(
        '<font color="#%s">%s</font>  \u{2022}  <font color="#%s">%s</font>',
        COLORS.hexDistance,
        distanceText,
        COLORS.hexLuck,
        entry.luckText
    )
end

local function buildTitle(inst)
    local rarity = crystalRarity(inst)
    local name = crystalName(inst)
    local mutation = getAttr(inst, "Mutation")
    if type(mutation) == "string" and mutation ~= "" then
        return string.format("[%s] %s (%s)", rarity, name, mutation)
    end
    return string.format("[%s] %s", rarity, name)
end

local function applyDetails(inst, entry, origin)
    local title = buildTitle(inst)
    local color = crystalColor(inst)
    local money = formatShort(crystalValue(inst), "$")
    local weight = formatWeight(crystalWeight(inst))

    local luckOk, luck = pcall(crystalLuck, inst)
    entry.luckText = formatLuck(luckOk and luck or 0)

    entry.rarity.Text = title
    entry.rarity.TextColor3 = color
    entry.info.Text = string.format("%s  \u{2022}  %s", money, weight)

    local distanceText = "--"
    if origin then
        distanceText = formatDistance((inst.Position - origin).Magnitude)
    end

    applyExtra(entry, distanceText)
end

local function crystalSignature(inst)
    return table.concat({
        tostring(getAttr(inst, "Tier")),
        tostring(getAttr(inst, "TierName")),
        tostring(getAttr(inst, "CrystalName")),
        tostring(getAttr(inst, "Value")),
        tostring(getAttr(inst, "WeightKg")),
        tostring(getAttr(inst, "Mutation")),
        tostring(getAttr(inst, "ExtraMutations")),
        tostring(luckLabelText(inst)),
    }, "|")
end

local function markDirty(inst)
    Storage.dirty[inst] = true
end

local function untrackCrystal(inst)
    local conns = Storage.registry[inst]
    if not conns then
        return
    end

    for _, connection in ipairs(conns) do
        connection:Disconnect()
    end

    Storage.registry[inst] = nil
    State.registryCount -= 1
    Storage.dirty[inst] = nil
    Storage.candidates[inst] = nil
    State.statsDirty = true

    destroyEntry(inst)
end

local function trackCrystal(inst)
    if Storage.registry[inst] then
        return
    end

    local conns = {}
    Storage.registry[inst] = conns
    State.registryCount += 1
    State.statsDirty = true

    local ok = pcall(function()
        conns[#conns + 1] = inst.Destroying:Connect(function()
            untrackCrystal(inst)
        end)

        conns[#conns + 1] = inst.AncestryChanged:Connect(function()
            if not inst:IsDescendantOf(Services.Workspace) then
                untrackCrystal(inst)
            end
        end)

        for _, name in ipairs(WATCHED_ATTRIBUTES) do
            conns[#conns + 1] = inst:GetAttributeChangedSignal(name):Connect(function()
                markDirty(inst)
            end)
        end

        local label = luckLabel(inst)
        if label then
            conns[#conns + 1] = label:GetPropertyChangedSignal("Text"):Connect(function()
                markDirty(inst)
            end)
        end
    end)

    if not ok then
        untrackCrystal(inst)
        return
    end

    markDirty(inst)
end

local function syncCrystal(inst)
    Storage.dirty[inst] = nil

    if not Storage.registry[inst] then
        return
    end

    if not inst.Parent then
        untrackCrystal(inst)
        return
    end

    local entry = Storage.espCache[inst]
    local hidden = not State.espActive or getAttr(inst, "Collected") == true

    if not hidden then
        hidden = not meetsFilter(inst)
    end

    if hidden then
        if entry then
            destroyEntry(inst, entry)
        end
        return
    end

    if not entry then
        local built, result = pcall(createEntry, inst)
        if not built then
            reportError("billboard", result)
            return
        end

        entry = result
        Storage.espCache[inst] = entry
        State.espCount += 1
        State.statsDirty = true
    end

    local signature = crystalSignature(inst)
    if signature == entry.signature then
        return
    end

    local root = getRoot()
    local ok, err = pcall(applyDetails, inst, entry, root and root.Position or nil)
    if ok then
        entry.signature = signature
    else
        reportError("details", err)
    end
end

local function sweep()
    local seen = Storage.sweepSeen
    table.clear(seen)

    eachContainer(function(container)
        for _, child in ipairs(container:GetChildren()) do
            if not seen[child] and isCrystal(child) then
                seen[child] = true
                if not Storage.registry[child] then
                    trackCrystal(child)
                end
            end
        end
    end)

    local stale
    for inst in pairs(Storage.registry) do
        if not seen[inst] then
            stale = stale or {}
            stale[#stale + 1] = inst
        end
    end

    if stale then
        for _, inst in ipairs(stale) do
            untrackCrystal(inst)
        end
    end
end

local function updateDistances()
    local root = getRoot()
    if not root then
        return
    end

    local origin = root.Position
    if Storage.lastDistanceOrigin and (origin - Storage.lastDistanceOrigin).Magnitude < 1 then
        return
    end

    Storage.lastDistanceOrigin = origin

    for inst, entry in pairs(Storage.espCache) do
        if inst.Parent then
            local text = formatDistance((inst.Position - origin).Magnitude)
            if text ~= entry.distanceText then
                applyExtra(entry, text)
            end
        end
    end
end

local function clearEsp()
    for inst, entry in pairs(Storage.espCache) do
        destroyEntry(inst, entry)
    end
    Storage.espCache = {}
    State.espCount = 0
    State.statsDirty = true
end

local function clearRegistry()
    local all
    for inst in pairs(Storage.registry) do
        all = all or {}
        all[#all + 1] = inst
    end

    if all then
        for _, inst in ipairs(all) do
            untrackCrystal(inst)
        end
    end

    clearEsp()
    Storage.registry = {}
    Storage.candidates = {}
    Storage.dirty = {}
    State.registryCount = 0
    State.statsDirty = true
end

local function requestRefresh()
    for inst in pairs(Storage.registry) do
        Storage.dirty[inst] = true
    end
    State.sweepAccumulator = math.huge
end

local function trackingEnabled()
    return State.espActive
end

local function onContainerChild(child)
    if looksLikeCrystal(child) then
        Storage.candidates[child] = os.clock() + ESP.ttl
    end
end

local function watchContainers()
    for container, connection in pairs(Storage.containerConns) do
        if not container:IsDescendantOf(game) then
            connection:Disconnect()
            Storage.containerConns[container] = nil
        end
    end

    eachContainer(function(container)
        if Storage.containerConns[container] then
            return
        end
        Storage.containerConns[container] = container.ChildAdded:Connect(onContainerChild)
    end)
end

local function unwatchContainers()
    for container, connection in pairs(Storage.containerConns) do
        connection:Disconnect()
        Storage.containerConns[container] = nil
    end
end

local function updateTracking()
    if trackingEnabled() then
        State.sweepAccumulator = math.huge
        watchContainers()
        requestRefresh()
    else
        unwatchContainers()
        clearRegistry()
    end
end

local StatsLabel

Connections.espConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
    if State.statsDirty and StatsLabel then
        State.statsDirty = false
        StatsLabel:SetText(string.format("Tracking: %d  |  Shown: %d", State.registryCount, State.espCount))
    end

    if not trackingEnabled() then
        return
    end

    local now = os.clock()

    for inst, expiry in pairs(Storage.candidates) do
        if not inst.Parent then
            Storage.candidates[inst] = nil
        elseif isCrystal(inst) then
            Storage.candidates[inst] = nil
            trackCrystal(inst)
        elseif now > expiry then
            Storage.candidates[inst] = nil
        end
    end

    local deadline = now + ESP.budget
    if next(Storage.dirty) ~= nil then
        for inst in pairs(Storage.dirty) do
            local ok, err = pcall(syncCrystal, inst)
            if not ok then
                Storage.dirty[inst] = nil
                reportError("sync", err)
            end
            if os.clock() > deadline then
                break
            end
        end
    end

    State.sweepAccumulator += deltaTime
    if State.sweepAccumulator >= ESP.sweep then
        State.sweepAccumulator = 0
        local ok, err = pcall(function()
            watchContainers()
            sweep()
        end)
        if not ok then
            reportError("sweep", err)
        end
    end

    State.distanceAccumulator += deltaTime
    if State.distanceAccumulator >= PACE.distance then
        State.distanceAccumulator = 0
        local ok, err = pcall(updateDistances)
        if not ok then
            reportError("distance", err)
        end
    end
end)

local function destroyPlayerEntry(player)
    local entry = Storage.playerCache[player]
    if not entry then
        return
    end

    if entry.gui then
        entry.gui:Destroy()
    end

    Storage.playerCache[player] = nil
end

local function createPlayerEntry(player)
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "UniversePlayerEsp"
    billboard.AlwaysOnTop = true
    billboard.ResetOnSpawn = false
    billboard.LightInfluence = 0
    billboard.Size = playerGuiSize()
    billboard.StudsOffsetWorldSpace = PLAYER.offset
    billboard.MaxDistance = math.huge
    billboard.Parent = EspHolder

    local textSize = playerTextSize()
    local nameLabel, nameConstraint = newLabel("Name", billboard, 0, 2, COLORS.player, false, textSize)
    local distanceLabel, distanceConstraint = newLabel("Distance", billboard, 1, 2, COLORS.extra, false, textSize)

    nameLabel.Text = player.DisplayName

    return {
        gui = billboard,
        name = nameLabel,
        distance = distanceLabel,
        constraints = { nameConstraint, distanceConstraint },
        nameText = player.DisplayName,
        distanceText = false,
    }
end

local function clearPlayerEsp()
    for player in pairs(Storage.playerCache) do
        destroyPlayerEntry(player)
    end
    Storage.playerCache = {}
end

local function updatePlayerEsp()
    if not State.playerEspActive then
        return
    end

    local root = getRoot()
    local origin = root and root.Position or nil

    for _, player in ipairs(Services.Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local character = player.Character
            local target = character and character:FindFirstChild("HumanoidRootPart")

            if target then
                local entry = Storage.playerCache[player]
                if not entry then
                    local built, result = pcall(createPlayerEntry, player)
                    if built then
                        entry = result
                        Storage.playerCache[player] = entry
                    else
                        reportError("player", result)
                    end
                end

                if entry then
                    if entry.gui.Adornee ~= target then
                        entry.gui.Adornee = target
                    end

                    if entry.nameText ~= player.DisplayName then
                        entry.nameText = player.DisplayName
                        entry.name.Text = player.DisplayName
                    end

                    local text = origin and formatDistance((target.Position - origin).Magnitude) or "--"
                    if text ~= entry.distanceText then
                        entry.distanceText = text
                        entry.distance.Text = text
                    end
                end
            else
                destroyPlayerEntry(player)
            end
        end
    end

    local gone
    for player in pairs(Storage.playerCache) do
        if player == LocalPlayer or not player.Parent then
            gone = gone or {}
            gone[#gone + 1] = player
        end
    end

    if gone then
        for _, player in ipairs(gone) do
            destroyPlayerEntry(player)
        end
    end
end

local function requestStream(position)
    if typeof(position) ~= "Vector3" then
        return
    end

    local now = os.clock()
    if State.streamSpot and now - State.streamMark < 0.3 and (State.streamSpot - position).Magnitude < 32 then
        return
    end

    State.streamMark = now
    State.streamSpot = position

    task.spawn(function()
        pcall(function()
            LocalPlayer:RequestStreamAroundAsync(position, 1)
        end)
    end)
end

local function applyPivot(cframe)
    local character = LocalPlayer.Character
    if not character then
        return false
    end

    requestStream(cframe.Position)

    local root = getRoot()
    if not root then
        return false
    end

    local moved = pcall(function()
        character:PivotTo(cframe)
    end)

    if not moved then
        moved = pcall(function()
            root.CFrame = cframe
        end)
    end

    if not moved then
        return false
    end

    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    return true
end

local function findClearGoal(position, ignore)
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore
    params.MaxParts = 1

    for _, offset in ipairs(TP.clear) do
        local candidate = position + offset
        local ok, hits = pcall(function()
            return Services.Workspace:GetPartBoundsInRadius(candidate, 2.5, params)
        end)

        if ok and #hits == 0 then
            return candidate
        end
    end

    return position + TP.clear[#TP.clear]
end

local function finishTeleport()
    if not State.tpState then
        return
    end

    local root = getRoot()
    if root then
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        pcall(function()
            humanoid.PlatformStand = false
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end

    State.tpState = nil
end

local function teleportTo(target)
    local position
    if typeof(target) == "Vector3" then
        position = target
    elseif typeof(target) == "Instance" and target.Parent then
        position = target.Position
    end

    if not position then
        return false
    end

    local character = LocalPlayer.Character
    if not character then
        return false
    end

    local root = getRoot()
    if not root then
        return false
    end

    finishTeleport()

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        pcall(function()
            if humanoid.SeatPart or humanoid.Sit then
                humanoid.Sit = false
            end
            humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        end)
    end

    local ignore = { character }
    if typeof(target) == "Instance" then
        ignore[#ignore + 1] = target
    end

    local goalFrame = CFrame.new(findClearGoal(position + TP.offset, ignore))
    if not applyPivot(goalFrame) then
        return false
    end

    State.tpState = {
        goal = goalFrame,
        holdUntil = os.clock() + TP.hold,
    }

    return true
end

local function schedule(delay, fn)
    Storage.pendingActions[#Storage.pendingActions + 1] = { at = os.clock() + delay, fn = fn }
end

local function crystalPrompt(inst)
    local cached = Storage.promptCache[inst]
    if cached and cached.Parent then
        return cached
    end

    local ok, prompt = pcall(inst.FindFirstChildOfClass, inst, "ProximityPrompt")
    if not (ok and prompt) then
        ok, prompt = pcall(inst.FindFirstChildWhichIsA, inst, "ProximityPrompt", true)
    end

    if ok and prompt then
        Storage.promptCache[inst] = prompt
        return prompt
    end

    Storage.promptCache[inst] = nil
    return nil
end

local function surfaceDistance(part, origin)
    local ok, distance = pcall(function()
        local point = part.CFrame:PointToObjectSpace(origin)
        local half = part.Size * 0.5
        local clamped = Vector3.new(
            math.clamp(point.X, -half.X, half.X),
            math.clamp(point.Y, -half.Y, half.Y),
            math.clamp(point.Z, -half.Z, half.Z)
        )
        return (point - clamped).Magnitude
    end)

    if ok and distance then
        return distance
    end

    return (part.Position - origin).Magnitude
end

local function firePrompt(prompt)
    if not Storage.promptRestores[prompt] then
        Storage.promptRestores[prompt] = {
            hold = prompt.HoldDuration,
            sight = prompt.RequiresLineOfSight,
            enabled = prompt.Enabled,
            range = prompt.MaxActivationDistance,
        }
    end

    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt.Enabled = true
        prompt.MaxActivationDistance = 1000
    end)

    local fired = false

    if typeof(fireproximityprompt) == "function" then
        fired = pcall(fireproximityprompt, prompt, 1)
        if not fired then
            fired = pcall(fireproximityprompt, prompt)
        end
    end

    if not fired then
        fired = pcall(function()
            prompt:InputHoldBegin()
            prompt:InputHoldEnd()
        end)
    end

    schedule(PICK.restore, function()
        local saved = Storage.promptRestores[prompt]
        if not saved then
            return
        end

        Storage.promptRestores[prompt] = nil

        if prompt.Parent then
            prompt.HoldDuration = saved.hold
            prompt.RequiresLineOfSight = saved.sight
            prompt.Enabled = saved.enabled
            prompt.MaxActivationDistance = saved.range
        end
    end)

    return fired
end

local pickupParams = OverlapParams.new()
pickupParams.FilterType = Enum.RaycastFilterType.Exclude

pcall(function()
    pickupParams.MaxParts = 300
    pickupParams.RespectCanCollide = false
end)

local pickupFound = {}
local pickupSeen = {}

local function pickupCandidates(free, origin, filterFunc)
    local found = pickupFound
    local seen = pickupSeen
    table.clear(found)
    table.clear(seen)
    local now = os.clock()

    local function consider(child)
        if not child or seen[child] then
            return
        end
        seen[child] = true

        if not child.Parent or not isCrystal(child) or getAttr(child, "Collected") == true then
            return
        end

        local claim = Storage.claimed[child]
        if claim and now - claim < PICK.retry then
            return
        end

        if filterFunc and not filterFunc(child) then
            return
        end


        local value = crystalValue(child)
        if not meetsFilter(child, value) then
            return
        end

        local weight = crystalWeight(child)
        if weight > free then
            return
        end

        local distance = surfaceDistance(child, origin)
        if distance > PICK.range then
            return
        end

        found[#found + 1] = {
            inst = child,
            prompt = crystalPrompt(child),
            value = value,
            weight = weight,
            distance = distance,
        }
    end

    pickupParams.FilterDescendantsInstances = { LocalPlayer.Character or LocalPlayer }

    local ok, hits = pcall(function()
        return Services.Workspace:GetPartBoundsInRadius(origin, PICK.range + PICK.pad, pickupParams)
    end)

    if ok and hits then
        for _, part in ipairs(hits) do
            consider(part)
        end
    end

    eachContainer(function(container)
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("BasePart") then
                consider(child)
            elseif child:IsA("Model") then
                for _, inner in ipairs(child:GetChildren()) do
                    consider(inner)
                end
            end
        end
    end)

    for inst in pairs(Storage.registry) do
        consider(inst)
    end

    table.sort(found, function(a, b)
        if a.value == b.value then
            return a.distance < b.distance
        end
        return a.value > b.value
    end)

    return found
end

local function grabCrystal(inst, prompt)
    local sent = false

    if Remotes.HoldComplete then
        sent = pcall(function()
            if Remotes.HoldComplete:IsA("RemoteEvent") then
                Remotes.HoldComplete:FireServer(inst)
            end
        end)
    end

    if not prompt then
        prompt = crystalPrompt(inst)
    end

    if prompt and prompt.Parent and firePrompt(prompt) then
        sent = true
    end

    if not sent and typeof(fireclickdetector) == "function" then
        local ok, detector = pcall(inst.FindFirstChildWhichIsA, inst, "ClickDetector", true)
        if ok and detector then
            sent = pcall(fireclickdetector, detector, 0)
        end
    end

    return sent
end

local function instantPromptPatch(prompt)
    if Storage.instantPatched[prompt] or Storage.promptRestores[prompt] then
        return
    end

    Storage.instantPatched[prompt] = {
        hold = prompt.HoldDuration,
        sight = prompt.RequiresLineOfSight,
        enabled = prompt.Enabled,
    }

    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt.Enabled = true
    end)
end

local function restoreInstantPrompts()
    for prompt, saved in pairs(Storage.instantPatched) do
        if prompt.Parent then
            pcall(function()
                prompt.HoldDuration = saved.hold
                prompt.RequiresLineOfSight = saved.sight
                prompt.Enabled = saved.enabled
            end)
        end
    end
    table.clear(Storage.instantPatched)
end

local function nearbyCrystalParts(origin, radius)
    pickupParams.FilterDescendantsInstances = { LocalPlayer.Character or LocalPlayer }
    local ok, hits = pcall(function()
        return Services.Workspace:GetPartBoundsInRadius(origin, radius, pickupParams)
    end)

    if ok and hits then
        return hits
    end
    return nil
end

local function refreshInstantPrompts()
    local root = getRoot()
    if not root then
        return
    end

    for prompt in pairs(Storage.instantPatched) do
        if not prompt.Parent then
            Storage.instantPatched[prompt] = nil
        end
    end

    local hits = nearbyCrystalParts(root.Position, PICK.instantRadius)
    if not hits then
        return
    end

    for _, part in ipairs(hits) do
        if isCrystal(part) and getAttr(part, "Collected") ~= true then
            local prompt = crystalPrompt(part)
            if prompt then
                instantPromptPatch(prompt)
            end
        end
    end
end

local function setInstantPrompt(value)
    State.instantPromptActive = value
    State.instantAccumulator = math.huge

    if not value then
        restoreInstantPrompts()
    end
end

local function instantGrab()
    if not State.instantPromptActive then
        return
    end

    local root = getRoot()
    if not root then
        return
    end

    local hits = nearbyCrystalParts(root.Position, PICK.range + PICK.pad)
    if not hits then
        return
    end

    local best, bestPrompt, bestDistance

    for _, part in ipairs(hits) do
        if part.Parent and isCrystal(part) and getAttr(part, "Collected") ~= true then
            local distance = surfaceDistance(part, root.Position)
            if distance <= PICK.range and (not best or distance < bestDistance) then
                best = part
                bestPrompt = crystalPrompt(part)
                bestDistance = distance
            end
        end
    end

    if not best then
        return
    end

    if bestPrompt then
        instantPromptPatch(bestPrompt)
    end

    if grabCrystal(best, bestPrompt) then
        Storage.claimed[best] = os.clock()
    end
end

local function pickupStep(filterFunc)
    local now = os.clock()
    if now - State.lastPickup < PICK.cooldown then
        return
    end

    local root = getRoot()
    if not root then
        return
    end

    local free = backpackFree()
    if free <= 0 then
        if now - State.lastBagWarn >= 8 then
            State.lastBagWarn = now
            Library:Notify("Backpack full", 2)
        end
        return
    end

    for inst, stamp in pairs(Storage.claimed) do
        if now - stamp >= PICK.forget or not inst.Parent then
            Storage.claimed[inst] = nil
        end
    end

    local candidatesList = pickupCandidates(free, root.Position, filterFunc)
    if #candidatesList == 0 then
        requestStream(root.Position)
        return
    end

    local budget = free
    local grabs = 0

    for _, entry in ipairs(candidatesList) do
        if grabs >= PICK.burst then
            break
        end

        if entry.weight <= budget then
            Storage.claimed[entry.inst] = now
            if grabCrystal(entry.inst, entry.prompt) then
                budget -= entry.weight
                grabs += 1
            end
        end
    end

    if grabs > 0 then
        State.lastPickup = now
    end
end

local BackpackLabel

local function updateBackpackLabel()
    if not BackpackLabel then
        return
    end

    local capacity = backpackCapacity()
    local used = backpackWeight()

    if capacity == math.huge then
        BackpackLabel:SetText(string.format("Bag %.1f / \u{221E} kg", used))
        return
    end

    local free = math.max(0, capacity - used)
    BackpackLabel:SetText(string.format("Bag %.1f / %.1f kg\nFree %.1f kg", used, capacity, free))
end

local function enforceSpeed(humanoid)
    if not humanoid or humanoid.WalkSpeed == PACE.boost then
        return
    end
    pcall(function()
        humanoid.WalkSpeed = PACE.boost
    end)
end

local function watchSpeed(humanoid)
    if State.speedHooked == humanoid then
        return
    end

    if Connections.speedConn then
        Connections.speedConn:Disconnect()
        Connections.speedConn = nil
    end

    State.speedHooked = humanoid
    if not humanoid then
        return
    end

    local ok, connection = pcall(function()
        return humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if State.speedActive then
                enforceSpeed(humanoid)
            end
        end)
    end)

    if ok then
        Connections.speedConn = connection
    end
end

local function setSpeedBoost(value)
    State.speedActive = value

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if value then
        watchSpeed(humanoid)
        enforceSpeed(humanoid)
        return
    end

    watchSpeed(nil)

    if humanoid then
        pcall(function()
            humanoid.WalkSpeed = PACE.normal
        end)
    end
end

Connections.schedulerConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
    if State.tpState then
        local ok, err = pcall(function()
            if not applyPivot(State.tpState.goal) then
                finishTeleport()
                return
            end

            if os.clock() >= State.tpState.holdUntil then
                finishTeleport()
            end
        end)

        if not ok then
            finishTeleport()
            reportError("teleport", err)
        end
    end

    if State.autoPickupActive then
        local ok, err = pcall(pickupStep)
        if not ok then
            reportError("pickup", err)
        end
    end

    if State.instantPromptActive then
        State.instantAccumulator += deltaTime
        if State.instantAccumulator >= PICK.instantTick then
            State.instantAccumulator = 0
            local ok, err = pcall(refreshInstantPrompts)
            if not ok then
                reportError("instant", err)
            end
        end
    end

    if State.speedActive then
        local body = LocalPlayer.Character
        local mover = body and body:FindFirstChildOfClass("Humanoid")
        if mover then
            watchSpeed(mover)
            enforceSpeed(mover)
        end
    end

    if State.playerEspActive then
        local ok, err = pcall(updatePlayerEsp)
        if not ok then
            reportError("playerEsp", err)
        end
    end

    State.statsAccumulator += deltaTime
    if State.statsAccumulator >= PACE.stats then
        State.statsAccumulator = 0
        local ok, err = pcall(updateBackpackLabel)
        if not ok then
            reportError("backpack", err)
        end
    end

    if #Storage.pendingActions == 0 then
        return
    end

    local now = os.clock()
    for index = #Storage.pendingActions, 1, -1 do
        local job = Storage.pendingActions[index]
        if now >= job.at then
            table.remove(Storage.pendingActions, index)
            local ok, err = pcall(job.fn)
            if not ok then
                reportError("action", err)
            end
        end
    end
end)

local function sortedByScore(scoreFn)
    local scored = {}
    local seen = {}

    local function consider(inst)
        if seen[inst] or not inst.Parent then
            return
        end

        if getAttr(inst, "Collected") == true then
            return
        end

        seen[inst] = true
        local ok, score = pcall(scoreFn, inst)
        scored[#scored + 1] = { inst = inst, score = ok and score or 0 }
    end

    for inst in pairs(Storage.registry) do
        consider(inst)
    end

    eachContainer(function(container)
        for _, child in ipairs(container:GetChildren()) do
            if isCrystal(child) then
                consider(child)
            end
        end
    end)

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)

    return scored
end

local Mountain = {}

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude
aimParams.IgnoreWater = true

local function getAimedCrystal()
    local unitRay = Mouse.UnitRay
    local origin = unitRay.Origin
    local direction = unitRay.Direction.Unit

    local character = LocalPlayer.Character
    aimParams.FilterDescendantsInstances = character and { character } or {}

    local hit = Services.Workspace:Raycast(origin, direction * PICK.aimRange, aimParams)
    if hit and hit.Instance and (Storage.registry[hit.Instance] or isCrystal(hit.Instance)) then
        return hit.Instance
    end

    local best, bestDot
    local seen = {}

    local function consider(inst)
        if seen[inst] or not inst.Parent then
            return
        end

        seen[inst] = true

        local offset = (inst.Position + ESP.offset) - origin
        local magnitude = offset.Magnitude
        if magnitude > 0 then
            local dot = direction:Dot(offset / magnitude)
            if not bestDot or dot > bestDot then
                bestDot = dot
                best = inst
            end
        end
    end

    for inst in pairs(Storage.espCache) do
        consider(inst)
    end

    eachContainer(function(container)
        for _, child in ipairs(container:GetChildren()) do
            if isCrystal(child) then
                consider(child)
            end
        end
    end)

    if best and bestDot and bestDot >= PICK.aimDot then
        return best
    end
    return nil
end

local function aimTeleport()
    if not State.espActive then
        Library:Notify("Enable Crystal ESP first", 3)
        return
    end

    local inst = getAimedCrystal()
    if not inst then
        Library:Notify("No crystal aimed", 2)
        return
    end

    if teleportTo(inst) then
        Library:Notify(string.format("TP -> %s", crystalName(inst)), 2)
    else
        Library:Notify("Teleport failed", 2)
    end
end

local function tpToRank(scoreFn, rank, formatter)
    local entry = sortedByScore(scoreFn)[rank]
    if not entry or entry.score <= 0 then
        Library:Notify(string.format("No crystal for #%d", rank), 3)
        return
    end

    if teleportTo(entry.inst) then
        Library:Notify(string.format("TP #%d %s (%s)", rank, crystalName(entry.inst), formatter(entry.inst, entry.score)), 3)
    else
        Library:Notify("Teleport failed", 3)
    end
end

local function fireRemote(remote, ...)
    if not remote or typeof(remote) ~= "Instance" then
        return false
    end

    local args = table.pack(...)
    local ok = pcall(function()
        if remote:IsA("RemoteEvent") then
            remote:FireServer(table.unpack(args, 1, args.n))
        elseif remote:IsA("BindableEvent") then
            remote:Fire(table.unpack(args, 1, args.n))
        elseif remote:IsA("RemoteFunction") then
            remote:InvokeServer(table.unpack(args, 1, args.n))
        end
    end)

    return ok
end

local function unfavoriteAll()
    local cleared = 0

    local function scan(container)
        if not container then
            return
        end

        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") and child:GetAttribute("Favorited") == true then
                pcall(function()
                    child:SetAttribute("Favorited", false)
                end)
                fireRemote(Remotes.ToggleFavorite, child, false)
                cleared += 1
            end
        end
    end

    scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    scan(LocalPlayer.Character)

    return cleared
end

local function mountainSpot()
    local centerX = Services.Workspace:GetAttribute("MountainCenterX") or Config.MountainCenter.X
    local centerZ = Services.Workspace:GetAttribute("MountainCenterZ") or Config.MountainCenter.Z

    if typeof(centerX) == "number" and typeof(centerZ) == "number" then
        local base = Services.Workspace:GetAttribute("MountainBaseY") or 22
        local peak = Services.Workspace:GetAttribute("MountainPeakY") or 1675
        local height = 700

        if typeof(base) == "number" and typeof(peak) == "number" then
            height = base + (peak - base) * 0.55
        end

        return Vector3.new(centerX, height, centerZ)
    end

    local things = Services.Workspace:FindFirstChild("Things")
    local zones = things and things:FindFirstChild("MountainZones")

    if zones then
        for _, child in ipairs(zones:GetChildren()) do
            if child:IsA("BasePart") and child.Name == "MountainZone" then
                return child.Position
            end
        end
    end

    return Config.MountainCenter
end

local function mountainSpan()
    local radius = Services.Workspace:GetAttribute("MountainRadius")
    if typeof(radius) == "number" and radius > 20 then
        return radius
    end
    return Config.MountainRadius
end

local function getSellCFrame()
    local things = Services.Workspace:FindFirstChild("Things")
    local prox = things and things:FindFirstChild("SellProx")
    if prox and prox:IsA("BasePart") then
        return CFrame.new(prox.Position + Vector3.new(0, 3, 0), prox.Position)
    end
    local model = things and things:FindFirstChild("SellModel")
    local part = model and model:FindFirstChild("SellPart")
    if part and part:IsA("BasePart") then
        return CFrame.new(part.Position + Vector3.new(0, 3, 0), part.Position)
    end
    return CFrame.new(-45.85, 32, 1066.58)
end

local function doRemoteSell()
    local now = os.clock()
    if now - sellClock < 1.5 then
        return false
    end

    sellClock = now
    unfavoriteAll()
    fireRemote(Remotes.SellRequest, "all")
    return true
end

local function doSell()
    local now = os.clock()
    if now - sellClock < 1.5 then
        return false
    end

    sellClock = now
    unfavoriteAll()
    fireRemote(Remotes.GoHome, "sell")

    schedule(0.6, function()
        unfavoriteAll()
        fireRemote(Remotes.SellRequest, "all")
    end)

    return true
end

do
    local function install()
        local BOULDER_INFO = {
            Mossite = { rarity = "Common", pickaxe = "Titanium Spike", crystals = "8-11", runes = "Luck / Haste", color = Color3.fromRGB(150, 220, 120) },
            Voltite = { rarity = "Uncommon", pickaxe = "Celestial Apex", crystals = "10-14", runes = "Storm / Weight", color = Color3.fromRGB(110, 190, 240) },
            Gildrite = { rarity = "Rare", pickaxe = "Eclipse Fang", crystals = "11-15", runes = "Fortune / Detonation", color = Color3.fromRGB(255, 200, 60) },
            Rimeveil = { rarity = "Epic", pickaxe = "Voidreign", crystals = "13-18", runes = "Preservation / Warmth", color = Color3.fromRGB(170, 100, 255) },
            Nocturnite = { rarity = "Legendary", pickaxe = "The Terminus", crystals = "16-22", runes = "Excavator / Colossus", color = Color3.fromRGB(255, 80, 180) },
        }

        local BOULDER_OFFSET = Vector3.new(0, 7, 0)
        local BOULDER_WIDTH = 300
        local BOULDER_HEIGHT = 78
        local BOULDER_STEP = 0.4

        local GRAB_RANGE = Config.RuneGrabRange
        local GRAB_STEP = 0.15
        local GRAB_LIMIT = 4
        local GRAB_RETRY = 0.2

        local boulderEsp = false
        local autoGrab = false
        local boulderCache = {}
        local grabbed = {}
        local boulderClock = 0
        local grabClock = 0

        local scanParams = OverlapParams.new()
        scanParams.FilterType = Enum.RaycastFilterType.Exclude

        local function textSize()
            return math.max(6, math.floor(ESP.text * State.boulderScale + 0.5))
        end

        local function anchorPart(inst)
            if not inst then
                return nil
            end
            if inst:IsA("BasePart") then
                return inst
            end
            if inst:IsA("Model") then
                return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
            end
            return nil
        end

        local function createCard(anchor, offset, colors, width, height)
            local billboard = Instance.new("BillboardGui")
            billboard.Name = "UniverseMountainEsp"
            billboard.Adornee = anchor
            billboard.AlwaysOnTop = true
            billboard.ResetOnSpawn = false
            billboard.LightInfluence = 0
            billboard.Size = UDim2.fromOffset(width * State.boulderScale, height * State.boulderScale)
            billboard.StudsOffsetWorldSpace = offset
            billboard.MaxDistance = math.huge
            billboard.Parent = EspHolder

            local total = #colors
            local size = textSize()
            local labels = {}
            local constraints = {}

            for index, color in ipairs(colors) do
                local label, constraint = newLabel("Line" .. index, billboard, index - 1, total, color, false, size)
                labels[index] = label
                constraints[index] = constraint
            end

            return {
                gui = billboard,
                labels = labels,
                constraints = constraints,
                width = width,
                height = height,
                text = {},
            }
        end

        local function scaleCard(entry)
            entry.gui.Size = UDim2.fromOffset(entry.width * State.boulderScale, entry.height * State.boulderScale)
            local size = textSize()
            for _, constraint in ipairs(entry.constraints) do
                constraint.MaxTextSize = size
            end
        end

        local function setLine(entry, index, text)
            if entry.text[index] == text then
                return
            end
            entry.text[index] = text
            entry.labels[index].Text = text
        end

        local function dropCard(cache, key)
            local entry = cache[key]
            if not entry then
                return
            end
            if entry.gui then
                entry.gui:Destroy()
            end
            cache[key] = nil
        end

        local function clearCache(cache)
            for key in pairs(cache) do
                dropCard(cache, key)
            end
        end

        local function boulderKind(inst)
            if not inst then
                return nil
            end
            for kind in pairs(BOULDER_INFO) do
                if inst.Name:find(kind, 1, true) then
                    return kind
                end
            end
            return nil
        end

        local function boulderRoots()
            local roots = {}
            local decorations = Services.Workspace:FindFirstChild("MountainDecorations")
            local folder = decorations and decorations:FindFirstChild("Boulders")
            if folder then
                roots[#roots + 1] = folder
            end
            local test = Services.Workspace:FindFirstChild("BoulderTest")
            if test then
                roots[#roots + 1] = test
            end
            return roots
        end

        local function eachBoulder(fn)
            for _, container in ipairs(boulderRoots()) do
                for _, child in ipairs(container:GetChildren()) do
                    local kind = boulderKind(child)
                    if kind then
                        fn(child, kind)
                    end
                end
            end
        end

        local function isRune(inst)
            if not inst then
                return false
            end
            if getAttr(inst, "RuneId") ~= nil or getAttr(inst, "IsRune") == true or getAttr(inst, "RuneName") ~= nil then
                return true
            end
            return inst.Name:find(" Rune", 1, true) ~= nil
        end

        local function runeTitle(inst)
            local id = getAttr(inst, "RuneId") or getAttr(inst, "RuneName")
            if type(id) == "string" and id ~= "" then
                if id:find("Rune", 1, true) then
                    return id
                end
                return id .. " Rune"
            end
            return inst and inst.Name or "Rune"
        end

        local function eachRune(origin, radius, fn)
            local seen = {}

            local function offer(owner, part)
                if not owner or seen[owner] then
                    return
                end
                local anchor = part or anchorPart(owner)
                if not anchor or not anchor.Parent then
                    return
                end
                if (anchor.Position - origin).Magnitude > radius then
                    return
                end

                seen[owner] = true
                fn(owner, anchor)
            end

            local function scanFolder(container)
                if not container then
                    return
                end
                for _, child in ipairs(container:GetChildren()) do
                    if isRune(child) then
                        offer(child, anchorPart(child))
                    end
                end
            end

            scanFolder(Services.Workspace)
            scanFolder(Services.Workspace:FindFirstChild("Things"))
            scanFolder(Services.Workspace:FindFirstChild("DroppedCrystals"))

            local character = LocalPlayer.Character
            scanParams.FilterDescendantsInstances = character and { character } or {}

            local ok, parts = pcall(function()
                return Services.Workspace:GetPartBoundsInRadius(origin, radius, scanParams)
            end)

            if not ok or not parts then
                return
            end

            for _, part in ipairs(parts) do
                if isRune(part) then
                    offer(part, part)
                else
                    local parent = part.Parent
                    if parent and parent ~= Services.Workspace and isRune(parent) then
                        offer(parent, anchorPart(parent) or part)
                    end
                end
            end
        end

        local function syncBoulders()
            local root = getRoot()
            local origin = root and root.Position or nil
            local seen = {}

            eachBoulder(function(model, kind)
                local anchor = anchorPart(model)
                if not anchor then
                    return
                end

                seen[model] = true
                local info = BOULDER_INFO[kind]
                local entry = boulderCache[model]

                if entry and not entry.gui.Parent then
                    dropCard(boulderCache, model)
                    entry = nil
                end

                if not entry then
                    entry = createCard(anchor, BOULDER_OFFSET, { info.color, COLORS.extra, COLORS.money }, BOULDER_WIDTH, BOULDER_HEIGHT)
                    boulderCache[model] = entry
                end

                if entry.gui.Adornee ~= anchor then
                    entry.gui.Adornee = anchor
                end

                scaleCard(entry)
                setLine(entry, 1, string.format("[%s] %s", info.rarity, kind))
                setLine(entry, 2, string.format("%s  \u{2022}  %s crystals", info.pickaxe, info.crystals))

                local distance = origin and formatDistance((anchor.Position - origin).Magnitude) or "--"
                setLine(entry, 3, string.format("%s  \u{2022}  %s", info.runes, distance))
            end)

            local stale
            for model in pairs(boulderCache) do
                if not seen[model] then
                    stale = stale or {}
                    stale[#stale + 1] = model
                end
            end

            if stale then
                for _, model in ipairs(stale) do
                    dropCard(boulderCache, model)
                end
            end
        end

        local function grabRunes(radius)
            local root = getRoot()
            if not root then
                return 0
            end

            local now = os.clock()
            local fired = 0

            for prompt, stamp in pairs(grabbed) do
                if now - stamp > 5 or not prompt.Parent then
                    grabbed[prompt] = nil
                end
            end

            eachRune(root.Position, radius or GRAB_RANGE, function(owner, part)
                if fired >= GRAB_LIMIT then
                    return
                end

                local prompt = owner:FindFirstChildOfClass("ProximityPrompt")
                if not prompt then
                    prompt = crystalPrompt(owner)
                end
                if not prompt and part ~= owner then
                    prompt = crystalPrompt(part)
                end

                if not prompt or not prompt.Parent then
                    return
                end

                local last = grabbed[prompt]
                if last and now - last < GRAB_RETRY then
                    return
                end

                grabbed[prompt] = now
                if firePrompt(prompt) then
                    fired += 1
                    Library:Notify(string.format("Rune: %s", runeTitle(owner)), 2)
                end
            end)

            return fired
        end

        function Mountain.applyScale()
            for _, entry in pairs(boulderCache) do
                scaleCard(entry)
            end
        end

        function Mountain.boulderList()
            local list = {}
            for _, kind in ipairs({ "Mossite", "Voltite", "Gildrite", "Rimeveil", "Nocturnite" }) do
                local info = BOULDER_INFO[kind]
                list[#list + 1] = string.format("%s  \u{2022}  %s", kind, info.pickaxe)
            end
            return list
        end

        function Mountain.setBoulderEsp(value)
            boulderEsp = value
            if value then
                boulderClock = math.huge
            else
                clearCache(boulderCache)
            end
        end

        function Mountain.setAutoGrab(value)
            autoGrab = value
            if value then
                grabClock = math.huge
            else
                table.clear(grabbed)
            end
        end

        function Mountain.grabRange()
            return GRAB_RANGE
        end

        function Mountain.grabNear(radius)
            local ok, fired = pcall(grabRunes, radius)
            if not ok then
                reportError("runeGrab", fired)
                return 0
            end
            return fired or 0
        end

        function Mountain.runesNear(radius)
            local root = getRoot()
            if not root then
                return 0
            end
            local count = 0
            eachRune(root.Position, radius or GRAB_RANGE, function()
                count += 1
            end)
            return count
        end

        function Mountain.shutdown()
            boulderEsp = false
            autoGrab = false
            clearCache(boulderCache)
            table.clear(grabbed)
        end

        Connections.mountainConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
            if boulderEsp then
                boulderClock += deltaTime
                if boulderClock >= BOULDER_STEP then
                    boulderClock = 0
                    local ok, err = pcall(syncBoulders)
                    if not ok then
                        reportError("boulder", err)
                    end
                end
            end

            if autoGrab then
                grabClock += deltaTime
                if grabClock >= GRAB_STEP then
                    grabClock = 0
                    local ok, err = pcall(grabRunes)
                    if not ok then
                        reportError("runeGrab", err)
                    end
                end
            end
        end)
    end

    install()
end

local Move = {}

do
    local function install()
        local FLY_KEYS = {
            { key = Enum.KeyCode.W, axis = "look", sign = 1 },
            { key = Enum.KeyCode.S, axis = "look", sign = -1 },
            { key = Enum.KeyCode.D, axis = "right", sign = 1 },
            { key = Enum.KeyCode.A, axis = "right", sign = -1 },
            { key = Enum.KeyCode.Space, axis = "up", sign = 1 },
            { key = Enum.KeyCode.LeftControl, axis = "up", sign = -1 },
        }

        local flyActive = false
        local noclipActive = false
        local jumpActive = false
        local flySpeed = Config.FlySpeed

        local velocity
        local gyro
        local flyConn
        local noclipConn
        local jumpConn
        local collisions = {}

        local function humanoidOf()
            local character = LocalPlayer.Character
            return character and character:FindFirstChildOfClass("Humanoid")
        end

        local function dropMovers()
            if velocity then
                pcall(function()
                    velocity:Destroy()
                end)
                velocity = nil
            end
            if gyro then
                pcall(function()
                    gyro:Destroy()
                end)
                gyro = nil
            end
        end

        local function attach(root)
            dropMovers()
            local ok = pcall(function()
                local body = Instance.new("BodyVelocity")
                body.Name = "UniverseFlyVelocity"
                body.MaxForce = Vector3.new(9e9, 9e9, 9e9)
                body.P = 9e4
                body.Velocity = Vector3.zero
                body.Parent = root
                velocity = body

                local spin = Instance.new("BodyGyro")
                spin.Name = "UniverseFlyGyro"
                spin.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
                spin.P = 9e4
                spin.D = 500
                spin.CFrame = root.CFrame
                spin.Parent = root
                gyro = spin
            end)

            if not ok then
                dropMovers()
            end

            return ok
        end

        local function flyStep()
            if State.tpState then
                return
            end

            local root = getRoot()
            if not root then
                return
            end

            if not velocity or velocity.Parent ~= root then
                if not attach(root) then
                    return
                end
            end

            local camera = Services.Workspace.CurrentCamera
            if not camera then
                return
            end

            local humanoid = humanoidOf()
            if humanoid and not humanoid.PlatformStand then
                humanoid.PlatformStand = true
            end

            local frame = camera.CFrame
            local direction = Vector3.zero

            if not Services.UserInputService:GetFocusedTextBox() then
                for _, entry in ipairs(FLY_KEYS) do
                    if Services.UserInputService:IsKeyDown(entry.key) then
                        if entry.axis == "look" then
                            direction += frame.LookVector * entry.sign
                        elseif entry.axis == "right" then
                            direction += frame.RightVector * entry.sign
                        else
                            direction += Vector3.yAxis * entry.sign
                        end
                    end
                end
            end

            if direction.Magnitude > 0.1 then
                velocity.Velocity = direction.Unit * flySpeed
            else
                velocity.Velocity = Vector3.zero
            end

            local flat = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z)
            if flat.Magnitude > 0.05 then
                gyro.CFrame = CFrame.new(root.Position, root.Position + flat)
            end
        end

        local function noclipStep()
            local character = LocalPlayer.Character
            if not character then
                return
            end

            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    if collisions[part] == nil then
                        collisions[part] = true
                    end
                    part.CanCollide = false
                end
            end
        end

        function Move.setFly(value)
            flyActive = value

            if value then
                local root = getRoot()
                if root then
                    attach(root)
                end

                if not flyConn then
                    flyConn = Services.RunService.Heartbeat:Connect(function()
                        if not flyActive then
                            return
                        end
                        local ok, err = pcall(flyStep)
                        if not ok then
                            reportError("fly", err)
                        end
                    end)
                end
                return
            end

            if flyConn then
                flyConn:Disconnect()
                flyConn = nil
            end

            dropMovers()

            local humanoid = humanoidOf()
            if humanoid then
                pcall(function()
                    humanoid.PlatformStand = false
                    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end)
            end
        end

        function Move.setFlySpeed(value)
            flySpeed = math.clamp(value, 10, 500)
        end

        function Move.setNoclip(value)
            noclipActive = value

            if value then
                if not noclipConn then
                    noclipConn = Services.RunService.Heartbeat:Connect(function()
                        if not noclipActive then
                            return
                        end
                        local ok, err = pcall(noclipStep)
                        if not ok then
                            reportError("noclip", err)
                        end
                    end)
                end
                return
            end

            if noclipConn then
                noclipConn:Disconnect()
                noclipConn = nil
            end

            for part, state in pairs(collisions) do
                if part.Parent then
                    pcall(function()
                        part.CanCollide = state
                    end)
                end
            end

            table.clear(collisions)
        end

        function Move.setInfJump(value)
            jumpActive = value

            if value then
                if not jumpConn then
                    jumpConn = Services.UserInputService.JumpRequest:Connect(function()
                        if not jumpActive then
                            return
                        end
                        local humanoid = humanoidOf()
                        if humanoid then
                            pcall(function()
                                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                            end)
                        end
                    end)
                end
                return
            end

            if jumpConn then
                jumpConn:Disconnect()
                jumpConn = nil
            end
        end

        function Move.shutdown()
            Move.setFly(false)
            Move.setNoclip(false)
            Move.setInfJump(false)
            Move.glideStop()
        end
    end

    install()
end

do
    local function install()
        local GLIDE_SPEED = 350
        local AIM_RATE = 9
        local SNAP_GAP = 0.35
        local RESPONSE = 200
        local STREAM_GAP = 0.5
        local HOLD_FORCE = 1e7
        local HOLD_TORQUE = 1e7

        local attachment
        local mover
        local aligner
        local cursor
        local facing
        local goalFrame
        local aimSpot
        local streamClock = 0
        local glideConn
        local running = false

        local function humanoidOf()
            local character = LocalPlayer.Character
            return character and character:FindFirstChildOfClass("Humanoid")
        end

        local function detach()
            if mover then
                pcall(function()
                    mover:Destroy()
                end)
                mover = nil
            end
            if aligner then
                pcall(function()
                    aligner:Destroy()
                end)
                aligner = nil
            end
            if attachment then
                pcall(function()
                    attachment:Destroy()
                end)
                attachment = nil
            end
        end

        local function attach(root)
            detach()
            local ok = pcall(function()
                local point = Instance.new("Attachment")
                point.Name = "UniverseGlidePoint"
                point.Parent = root

                local position = Instance.new("AlignPosition")
                position.Name = "UniverseGlidePosition"
                position.Mode = Enum.PositionAlignmentMode.OneAttachment
                position.Attachment0 = point
                position.RigidityEnabled = false
                position.ApplyAtCenterOfMass = true
                position.ReactionForceEnabled = false
                position.MaxForce = HOLD_FORCE
                position.MaxVelocity = math.huge
                position.Responsiveness = RESPONSE
                position.Position = root.Position
                position.Parent = root

                local orientation = Instance.new("AlignOrientation")
                orientation.Name = "UniverseGlideOrientation"
                orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
                orientation.Attachment0 = point
                orientation.RigidityEnabled = false
                orientation.ReactionTorqueEnabled = false
                orientation.MaxTorque = HOLD_TORQUE
                orientation.MaxAngularVelocity = math.huge
                orientation.Responsiveness = RESPONSE
                orientation.CFrame = root.CFrame.Rotation
                orientation.Parent = root

                attachment = point
                mover = position
                aligner = orientation
            end)

            if not ok then
                detach()
            end

            return ok
        end

        local function step(deltaTime)
            if not goalFrame then
                return
            end

            local root = getRoot()
            if not root then
                return
            end

            if not mover or mover.Parent ~= root or not aligner or aligner.Parent ~= root then
                if not attach(root) then
                    return
                end
                cursor = root.Position
                facing = root.CFrame.Rotation
            end

            local humanoid = humanoidOf()
            if humanoid and not humanoid.PlatformStand then
                pcall(function()
                    humanoid.PlatformStand = true
                end)
            end

            cursor = cursor or root.Position
            facing = facing or root.CFrame.Rotation

            local delta = goalFrame.Position - cursor
            local span = GLIDE_SPEED * deltaTime

            if delta.Magnitude <= math.max(span, SNAP_GAP) then
                cursor = goalFrame.Position
            else
                cursor += delta.Unit * span
            end

            streamClock += deltaTime
            if streamClock >= STREAM_GAP then
                streamClock = 0
                requestStream(goalFrame.Position)
            end

            local look = goalFrame.Rotation
            if aimSpot then
                local gap = aimSpot - cursor
                if gap.Magnitude > 0.1 then
                    look = CFrame.lookAt(cursor, aimSpot).Rotation
                end
            end

            facing = facing:Lerp(look, 1 - math.exp(-AIM_RATE * deltaTime))
            mover.Position = cursor
            aligner.CFrame = facing
        end

        function Move.glide(goal, aim)
            if typeof(goal) ~= "CFrame" then
                return false
            end

            goalFrame = goal
            aimSpot = typeof(aim) == "Vector3" and aim or nil

            if not running then
                running = true
                local root = getRoot()
                if root then
                    cursor = root.Position
                    facing = root.CFrame.Rotation
                    attach(root)
                end
            end

            if not glideConn then
                glideConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
                    if not running then
                        return
                    end
                    local ok, err = pcall(step, deltaTime)
                    if not ok then
                        reportError("glide", err)
                    end
                end)
            end

            return true
        end

        function Move.glideStop()
            running = false
            goalFrame = nil
            aimSpot = nil
            cursor = nil
            facing = nil
            streamClock = 0

            if glideConn then
                glideConn:Disconnect()
                glideConn = nil
            end

            detach()

            local root = getRoot()
            if root then
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end)
            end

            local humanoid = humanoidOf()
            if humanoid then
                pcall(function()
                    humanoid.PlatformStand = false
                    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end)
            end
        end
    end

    install()
end

do
    local function install()
        local CrystalBox = Tabs.crystals:AddLeftGroupbox("Crystal ESP", "gem")

        CrystalBox:AddToggle("CrystalEsp", {
            Text = "Crystal ESP",
            Default = false,
            Callback = function(value)
                State.espActive = value
                if not value then
                    clearEsp()
                end
                updateTracking()
            end,
        })

        CrystalBox:AddSlider("EspSize", {
            Text = "Crystal Size",
            Default = 70,
            Min = 40,
            Max = 250,
            Rounding = 0,
            Suffix = "%",
            Compact = false,
            Callback = function(value)
                State.espScale = value / 100
                applyEspScale()
            end,
        })

        CrystalBox:AddDivider()
        CrystalBox:AddLabel("Min Value hides and skips crystals worth less than this. Example: 500k, 2m, 1.5b. Empty shows everything", true)

        local function setMinValue(text)
            local parsed = parseValue(text)
            if not parsed then
                return
            end
            State.minValue = math.max(parsed, 0)
            State.valueFilter = State.minValue > 0
            requestRefresh()
        end

        CrystalBox:AddInput("EspMinValue", {
            Text = "Min Value",
            Default = Config.MinCrystalValue,
            Placeholder = "2m",
            Numeric = false,
            Finished = false,
            Callback = setMinValue,
        })

        StatsLabel = CrystalBox:AddLabel("Tracking: 0  |  Shown: 0")
    end

    install()
end

do
    local function install()
        local PlayerBox = Tabs.players:AddLeftGroupbox("Player ESP", "users")

        PlayerBox:AddToggle("PlayerEsp", {
            Text = "Player ESP",
            Default = false,
            Callback = function(value)
                State.playerEspActive = value
                if not value then
                    clearPlayerEsp()
                end
            end,
        })

        PlayerBox:AddSlider("PlayerEspSize", {
            Text = "Player Size",
            Default = 60,
            Min = 40,
            Max = 250,
            Rounding = 0,
            Suffix = "%",
            Compact = false,
            Callback = function(value)
                State.playerScale = value / 100
                applyPlayerScale()
            end,
        })
    end

    install()
end

do
    local function install()
        local BoulderBox = Tabs.boulders:AddLeftGroupbox("Boulder ESP", "mountain")

        BoulderBox:AddToggle("BoulderEsp", {
            Text = "Boulder ESP",
            Default = false,
            Callback = Mountain.setBoulderEsp,
        })

        BoulderBox:AddSlider("BoulderEspSize", {
            Text = "Boulder Size",
            Default = 60,
            Min = 40,
            Max = 250,
            Rounding = 0,
            Suffix = "%",
            Compact = false,
            Callback = function(value)
                State.boulderScale = value / 100
                Mountain.applyScale()
            end,
        })

        BoulderBox:AddDivider()

        for _, text in ipairs(Mountain.boulderList()) do
            BoulderBox:AddLabel(text, true)
        end
    end

    install()
end

do
    local function install()
        local TopBox = Tabs.teleports:AddLeftGroupbox("Top Crystals", "trophy")

        local function fmtValue(_, score)
            return formatShort(score, "$")
        end

        local function fmtLuck(_, score)
            return formatLuck(score)
        end

        local function fmtWeight(inst)
            return formatWeight(crystalWeight(inst))
        end

        for rank = 1, 3 do
            TopBox:AddButton(string.format("Top %d Value", rank), function()
                tpToRank(crystalValue, rank, fmtValue)
            end)
        end

        TopBox:AddDivider()

        for rank = 1, 3 do
            TopBox:AddButton(string.format("Top %d Luck", rank), function()
                tpToRank(crystalLuck, rank, fmtLuck)
            end)
        end

        TopBox:AddDivider()

        for rank = 1, 3 do
            TopBox:AddButton(string.format("Top %d Weight", rank), function()
                tpToRank(crystalWeight, rank, fmtWeight)
            end)
        end

        local TeleportBox = Tabs.teleports:AddRightGroupbox("Teleports", "crosshair")

        TeleportBox:AddToggle("AimTeleport", {
            Text = "Aim Teleport",
            Default = false,
            Callback = function(value)
                State.aimTpEnabled = value
            end,
        })

        TeleportBox:AddLabel("Aim Teleport"):AddKeyPicker("AimTeleportKey", {
            Default = Config.KeybindAimTp,
            NoUI = false,
            Text = "Aim Teleport",
            Mode = "Always",
        })

        TeleportBox:AddDivider()

        TeleportBox:AddButton("TP Home", function()
            if fireRemote(Remotes.GoHome, "home") then
                Library:Notify("Teleporting home", 2)
            else
                Library:Notify("Remote unavailable", 2)
            end
        end)

        TeleportBox:AddButton("Sell All", function()
            task.spawn(function()
                local character = LocalPlayer.Character
                local root = getRoot()
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")

                if not character or not root then
                    if Library then
                        Library:Notify("Character not found", 2)
                    end
                    return
                end

                Move.glideStop()

                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end)

                local sellCFrame = getSellCFrame()
                applyPivot(sellCFrame)

                task.wait(0.05)

                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    if humanoid then
                        humanoid.PlatformStand = false
                        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end
                end)

                task.wait(0.15)

                unfavoriteAll()
                fireRemote(Remotes.SellRequest, "all")

                local things = Services.Workspace:FindFirstChild("Things")
                local prox = things and things:FindFirstChild("SellProx")
                local prompt = prox and prox:FindFirstChildOfClass("ProximityPrompt")
                if prompt then
                    firePrompt(prompt)
                end

                task.wait(0.25)
                fireRemote(Remotes.SellRequest, "all")

                if Library then
                    Library:Notify("Teleported to sell station and sold all!", 3)
                end
            end)
        end)
    end

    install()
end

do
    local function install()
        local PickupBox = Tabs.farming:AddLeftGroupbox("Pickup", "pickaxe")

        PickupBox:AddToggle("AutoPickup", {
            Text = "Auto Pickup",
            Default = false,
            Callback = function(value)
                State.autoPickupActive = value
            end,
        })

        PickupBox:AddToggle("InstantPrompt", {
            Text = "Instant Prompt",
            Default = false,
            Callback = setInstantPrompt,
        })

        PickupBox:AddToggle("AutoRunePickup", {
            Text = "Auto Rune Pickup",
            Default = false,
            Callback = Mountain.setAutoGrab,
        })

        PickupBox:AddDivider()
        BackpackLabel = PickupBox:AddLabel("Bag 0.0 / 0.0 kg", true)
    end

    install()
end

do
    local function install()
        local MoveBox = Tabs.movement:AddLeftGroupbox("Movement", "zap")

        MoveBox:AddToggle("SpeedBoost", {
            Text = "Speed Boost",
            Default = false,
            Callback = setSpeedBoost,
        })

        MoveBox:AddToggle("Noclip", {
            Text = "Noclip",
            Default = false,
            Callback = Move.setNoclip,
        })

        MoveBox:AddToggle("InfJump", {
            Text = "Inf Jump",
            Default = false,
            Callback = Move.setInfJump,
        })

        MoveBox:AddDivider()

        MoveBox:AddToggle("Fly", {
            Text = "Fly",
            Default = false,
            Callback = Move.setFly,
        })

        MoveBox:AddSlider("FlySpeed", {
            Text = "Fly Speed",
            Default = Config.FlySpeed,
            Min = 20,
            Max = 300,
            Rounding = 0,
            Compact = false,
            Callback = Move.setFlySpeed,
        })
    end

    install()
end

do
    local function install()
        local MOUSE_KEYS = {
            [Enum.UserInputType.MouseButton1] = "MB1",
            [Enum.UserInputType.MouseButton2] = "MB2",
            [Enum.UserInputType.MouseButton3] = "MB3",
        }

        local function pressedKeyName(input)
            local pressed = MOUSE_KEYS[input.UserInputType]
            if not pressed and input.UserInputType == Enum.UserInputType.Keyboard then
                pressed = input.KeyCode.Name
            end
            return pressed
        end

        Connections.aimInputConn = Services.UserInputService.InputBegan:Connect(function(input, processed)
            if processed or Services.UserInputService:GetFocusedTextBox() then
                return
            end

            local pressed = pressedKeyName(input)
            if not pressed then
                return
            end

            if State.instantPromptActive and pressed == "E" then
                local ok, err = pcall(instantGrab)
                if not ok then
                    reportError("instant", err)
                end
            end

            if not State.aimTpEnabled then
                return
            end

            local aimPicker = Library.Options.AimTeleportKey
            if pressed == (aimPicker and aimPicker.Value or Config.KeybindAimTp) then
                local ok, err = pcall(aimTeleport)
                if not ok then
                    reportError("aim", err)
                end
            end
        end)
    end

    install()
end

local Net = {}

do
    local function install()
        local PLACE = game.PlaceId
        local PAGES = 1
        local POOL_TARGET = 20
        local RETRY_STEP = 1.5
        local RETRY_LIMIT = 10
        local BACK_DELAY = 3
        local REFILL_MARK = 8
        local WARM_STEP = 30

        local visited = {}
        local pool = {}
        local hopping = false
        local reviving = false
        local lastCode = 0
        local alive = true

        local function note(text)
            if Library and Library.Notify then
                pcall(function()
                    Library:Notify("Hop  " .. text, 4)
                end)
            end
        end

        local function grab(link)
            local sender = (syn and syn.request) or (http and http.request) or http_request or request
            if type(sender) == "function" then
                local ok, response = pcall(function()
                    return sender({ Url = link, Method = "GET" })
                end)

                if ok and type(response) == "table" then
                    local code = tonumber(response.StatusCode) or 0
                    if code >= 200 and code < 300 and type(response.Body) == "string" then
                        return response.Body, code
                    end
                    return nil, code
                end
            end

            local ok, body = pcall(function()
                return game:HttpGet(link)
            end)

            if ok and type(body) == "string" then
                return body, 200
            end

            return nil, 0
        end

        local function fetch(cursor)
            local link = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100", PLACE)
            if type(cursor) == "string" and cursor ~= "" then
                link ..= "&cursor=" .. cursor
            end

            local body, code = grab(link)
            if type(body) ~= "string" then
                lastCode = code or 0
                return nil, nil
            end

            lastCode = 200
            local parsed, data = pcall(function()
                return Services.HttpService:JSONDecode(body)
            end)

            if not parsed or type(data) ~= "table" then
                lastCode = -1
                return nil, nil
            end

            return data.data, data.nextPageCursor
        end

        local function refill()
            table.clear(pool)
            local cursor

            for _ = 1, PAGES do
                local entries, nextCursor = fetch(cursor)

                if type(entries) == "table" then
                    for _, entry in ipairs(entries) do
                        local id = type(entry) == "table" and entry.id or nil
                        if type(id) == "string" and id ~= game.JobId and not visited[id] then
                            local playing = tonumber(entry.playing) or 0
                            local room = tonumber(entry.maxPlayers) or 0
                            if room == 0 or playing < room then
                                pool[#pool + 1] = id
                            end
                        end
                    end
                end

                cursor = nextCursor
                if type(cursor) ~= "string" or cursor == "" or #pool >= POOL_TARGET then
                    break
                end
            end

            for index = #pool, 2, -1 do
                local swap = math.random(1, index)
                pool[index], pool[swap] = pool[swap], pool[index]
            end

            return #pool
        end

        function Net.rejoin()
            if reviving then
                return
            end

            reviving = true
            local jobId = game.JobId

            task.spawn(function()
                for _ = 1, RETRY_LIMIT do
                    local sent = pcall(function()
                        Services.TeleportService:TeleportToPlaceInstance(PLACE, jobId, LocalPlayer)
                    end)

                    if not sent then
                        pcall(function()
                            Services.TeleportService:Teleport(PLACE, LocalPlayer)
                        end)
                    end

                    task.wait(RETRY_STEP)
                end

                reviving = false
            end)
        end

        function Net.hop()
            if hopping then
                return false
            end

            hopping = true
            visited[game.JobId] = true

            task.spawn(function()
                for round = 1, RETRY_LIMIT do
                    if #pool == 0 and refill() == 0 then
                        table.clear(visited)
                        visited[game.JobId] = true
                        refill()
                    end

                    local choice = table.remove(pool)
                    if choice then
                        visited[choice] = true
                        note(string.format("try %d  %s", round, string.sub(choice, 1, 8)))

                        local sent, err = pcall(function()
                            Services.TeleportService:TeleportToPlaceInstance(PLACE, choice, LocalPlayer)
                        end)

                        if not sent then
                            note("blocked  " .. tostring(err))
                        end

                        if #pool <= REFILL_MARK then
                            task.spawn(refill)
                        end
                    else
                        note(string.format("no servers  http %d", lastCode))
                    end

                    task.wait(RETRY_STEP)
                end

                hopping = false
            end)

            return true
        end

        function Net.forget()
            table.clear(visited)
            table.clear(pool)
            visited[game.JobId] = true
        end

        function Net.busy()
            return hopping
        end

        function Net.ready()
            return #pool
        end

        function Net.stop()
            alive = false
        end

        task.spawn(function()
            while alive do
                if #pool < POOL_TARGET and not hopping then
                    refill()
                end
                task.wait(WARM_STEP)
            end
        end)

        Storage.netConns[#Storage.netConns + 1] = Services.TeleportService.TeleportInitFailed:Connect(function()
            hopping = false
        end)

        Storage.netConns[#Storage.netConns + 1] = Services.GuiService.ErrorMessageChanged:Connect(function()
            local ok, message = pcall(function()
                return Services.GuiService:GetErrorMessage()
            end)

            if ok and type(message) == "string" and message ~= "" then
                task.delay(BACK_DELAY, Net.rejoin)
            end
        end)

        local prompts = Services.CoreGui:FindFirstChild("RobloxPromptGui")
        local overlay = prompts and prompts:FindFirstChild("promptOverlay")

        if overlay then
            Storage.netConns[#Storage.netConns + 1] = overlay.ChildAdded:Connect(function(child)
                if child.Name:find("ErrorPrompt") then
                    task.delay(BACK_DELAY, Net.rejoin)
                end
            end)
        end
    end

    install()
end

local Farm = {}

do
    local function install()
        local FARM_KINDS = { "Mossite", "Voltite", "Gildrite", "Rimeveil", "Nocturnite" }

        local SCAN_SPOTS = {
            CFrame.new(-12.7105675, 459.090942, 818.847412, 0.993408799, -0.00500036497, -0.11451605, 0.000644713698, 0.999275982, -0.0380407833, 0.114623353, 0.0377162211, 0.992692769),
            CFrame.new(13.0506754, 318.450409, -488.078888, -0.99998939, 0.000884758658, -0.00452193478, -0.000498382491, 0.954864502, 0.297041386, 0.00458064489, 0.297040492, -0.954853892),
            CFrame.new(74.3923645, 610.789368, 210.838226, -0.94896102, -0.27110818, 0.161162555, 2.26557495e-06, 0.51098305, 0.859590769, -0.315393418, 0.815718472, -0.484902382),
        }

        local PLACE_ID = game.PlaceId
        local HOLD_DIST = 8
        local SCAN_HOLD = 1.4
        local SWING_GAP = 0.04
        local SWING_BURST = 6
        local SWING_FLOOR = 0.02
        local COOLDOWN_KEYS = { "SwingCooldown", "DigCooldown", "Cooldown", "SwingSpeed", "DigSpeed" }
        local AIM_ANGLES = { 0, 35, -35, 70, -70, 110, -110, 145, -145, 180 }
        local AIM_LIFT = { 0, 5, -4, 12 }
        local SIGHT_GRACE = 1.5
        local SIGHT_STEPS = 8
        local LOST_GRACE = 1.8
        local DRY_ROUNDS = 3
        local DRY_TIME = 1.0
        local PROBE_DIST = { 0, -3, 4, -5, 8 }
        local CENTER_STEP = 0.75
        local CENTER_SHIFT = 7
        local SPOT_HOLD = 5.0
        local SPOT_SLACK = 12
        local ARRIVE_DIST = 3.5
        local STUCK_TIME = 4.0
        local DRY_SWAP = 4.0
        local SKIP_TIME = 9.0
        local SWEEP_PARTS = 3
        local RUNE_SWEEP = 90
        local LOOT_TIME = 2.5
        local EQUIP_STEP = 0.5
        local RESET_WAIT = 1.5

        local PICK_NAMES = {
            ["Rusty Scrapper"] = true, ["Weathered Wood"] = true, ["Chipped Stone"] = true,
            ["Hardened Iron"] = true, ["Copper Pick"] = true, ["Reinforced Steel"] = true,
            ["Titanium Spike"] = true, ["Frostbite Pick"] = true, ["Emerald Carver"] = true,
            ["Volcano Basalt"] = true, ["Obsidian Edge"] = true, ["Tempest Pick"] = true,
            ["Celestial Apex"] = true, ["Astral Rend"] = true, ["Eclipse Fang"] = true,
            ["Nebular Throne"] = true, Voidreign = true, Singularity = true,
            ["The Terminus"] = true, ["Admin Pickaxe"] = true, ["Shark Pickaxe"] = true,
            ["Diamond Pickaxe"] = true,
        }

        local active = false
        local autoRejoin = Config.AutoRejoinBoulders
        local targets = {}
        local phase = "idle"
        local target, anchor
        local swingClock = 0
        local equipClock = 0
        local waitUntil = 0
        local lastSpot
        local hpMark
        local dryRounds = 0
        local scanned = false
        local scanIndex = 0
        local heldPick
        local spotFrame
        local aimTurn = 0
        local blindClock = 0
        local lostClock = 0
        local dryClock = 0
        local probeIndex = 0
        local partCursor = 0
        local pendingFinish = false
        local lootUntil = 0
        local statusText = "Idle"
        local scanRetries = 0
        local lastPos
        local stuckClock = 0
        local lockedCenter
        local spotCenter
        local centerClock = 0
        local spotClock = 0

        local function toggleValue(name)
            local store = Library and Library.Toggles
            local entry = store and store[name]
            if entry and type(entry.Value) == "boolean" then
                return entry.Value
            end
            return false
        end

        local function isPickaxe(tool)
            if not tool or not tool:IsA("Tool") then
                return false
            end
            if getAttr(tool, "IsPickaxe") == true then
                return true
            end
            if PICK_NAMES[tool.Name] then
                return true
            end
            return getAttr(tool, "DigPower") ~= nil and getAttr(tool, "Tier") == nil
        end

        local function pickScore(tool)
            if not isPickaxe(tool) then
                return 0
            end
            local score = 1
            local power = tonumber(getAttr(tool, "DigPower"))
            if power then
                score += power
            end
            return score
        end

        local function equipPick()
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if not character or not humanoid then
                return nil
            end

            local held = character:FindFirstChildOfClass("Tool")
            if held and isPickaxe(held) then
                return held
            end

            local choice
            local best = 0

            local function consider(tool)
                local score = pickScore(tool)
                if score > best then
                    best = score
                    choice = tool
                end
            end

            consider(held)
            local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
            if backpack then
                for _, tool in ipairs(backpack:GetChildren()) do
                    consider(tool)
                end
            end

            if not choice then
                if backpack then
                    for _, tool in ipairs(backpack:GetChildren()) do
                        if tool:IsA("Tool") then
                            choice = tool
                            break
                        end
                    end
                end
            end

            if not choice then
                return nil
            end
            if choice == held then
                return held
            end

            pcall(function()
                humanoid:EquipTool(choice)
            end)

            local now = character:FindFirstChildOfClass("Tool")
            if now then
                return now
            end

            return choice
        end

        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        rayParams.IgnoreWater = true
        rayParams.RespectCanCollide = false

        local JUNK_WORDS = { "vfx", "effect", "fx", "debris", "particle", "shard", "chunk", "dust", "smoke" }

        local function junkName(instance)
            local name = string.lower(instance.Name)
            for _, word in ipairs(JUNK_WORDS) do
                if string.find(name, word, 1, true) then
                    return true
                end
            end
            return false
        end

        local function ignorable(instance, model)
            if not instance then
                return true
            end
            if model and instance:IsDescendantOf(model) then
                return true
            end
            if instance:IsA("Terrain") then
                return true
            end
            if not instance:IsA("BasePart") then
                return true
            end
            if instance.Transparency >= 0.5 or not instance.CanCollide or not instance.CanQuery then
                return true
            end
            if not instance.Anchored or instance.Massless then
                return true
            end
            if junkName(instance) then
                return true
            end

            local owner = instance:FindFirstAncestorOfClass("Model")
            if owner and Services.Players:GetPlayerFromCharacter(owner) then
                return true
            end
            return false
        end

        local function sightClear(origin, part, model)
            if not part or not part.Parent then
                return true
            end

            local delta = part.Position - origin
            local distance = delta.Magnitude
            if distance < 1 then
                return true
            end

            local skip = { LocalPlayer.Character, Services.Workspace.Terrain }

            for _ = 1, SIGHT_STEPS do
                rayParams.FilterDescendantsInstances = skip
                local hit = Services.Workspace:Raycast(origin, delta.Unit * (distance + 2), rayParams)
                if not hit then
                    return true
                end

                local instance = hit.Instance
                if instance == part or (model and instance:IsDescendantOf(model)) then
                    return true
                end

                if not ignorable(instance, model) then
                    return false
                end

                skip[#skip + 1] = instance
            end

            return true
        end

        local function usablePart(item)
            if not item:IsA("BasePart") then
                return false
            end
            if not item.Anchored or item.Transparency >= 0.9 or item.Massless then
                return false
            end
            return not junkName(item)
        end

        local function partList(model)
            local list = {}
            if not model then
                return list
            end

            if model:IsA("BasePart") then
                list[1] = model
                return list
            end

            local spare = {}
            for _, item in ipairs(model:GetDescendants()) do
                if item:IsA("BasePart") then
                    if usablePart(item) then
                        list[#list + 1] = item
                    else
                        spare[#spare + 1] = item
                    end
                end
            end

            if #list > 0 then
                return list
            end
            return spare
        end

        local function anchorSpot(model, part)
            if part and part.Parent then
                return part.Position
            end
            if not model or not model.Parent then
                return nil
            end
            local ok, pivot = pcall(model.GetPivot, model)
            if ok and pivot then
                return pivot.Position
            end
            return nil
        end

        local function coreSpot(model)
            if not model or not model.Parent then
                return nil
            end
            if model:IsA("BasePart") then
                return model.Position
            end
            local boxed, box = pcall(model.GetBoundingBox, model)
            if boxed and box then
                return box.Position
            end
            local ok, pivot = pcall(model.GetPivot, model)
            if ok and pivot then
                return pivot.Position
            end
            return nil
        end

        local function coreFrame(core, part)
            local look = part and part.Parent and part.Position or nil
            if not look or (look - core).Magnitude < 1 then
                look = core + Vector3.new(0, -2, 0)
            end
            return CFrame.new(core, look)
        end

        local function visibleAnchor(model)
            if not model then
                return nil
            end

            local root = getRoot()
            local origin = root and root.Position
            local pick, pickDistance, fallback, fallbackDistance

            for _, part in ipairs(partList(model)) do
                local distance = origin and (part.Position - origin).Magnitude or 0
                if not fallback or distance < fallbackDistance then
                    fallback = part
                    fallbackDistance = distance
                end

                if origin and sightClear(origin, part, model) then
                    if not pick or distance < pickDistance then
                        pick = part
                        pickDistance = distance
                    end
                end
            end

            return pick or fallback
        end

        local function freshAnchor(model)
            local list = partList(model)
            local count = #list
            if count == 0 then
                return nil
            end

            for _ = 1, count do
                partCursor = partCursor % count + 1
                local item = list[partCursor]
                if item and item.Parent then
                    return item
                end
            end
            return nil
        end

        local function hitSpot(part, model)
            local root = getRoot()
            if not root then
                return part.Position
            end

            local origin = root.Position
            local delta = part.Position - origin
            local distance = delta.Magnitude
            if distance < 1 then
                return part.Position
            end

            local skip = { LocalPlayer.Character, Services.Workspace.Terrain }

            for _ = 1, SIGHT_STEPS do
                rayParams.FilterDescendantsInstances = skip
                local hit = Services.Workspace:Raycast(origin, delta.Unit * (distance + 2), rayParams)
                if not hit then
                    break
                end

                if hit.Instance == part or hit.Instance:IsDescendantOf(model) then
                    return hit.Position
                end

                skip[#skip + 1] = hit.Instance
            end

            return part.Position
        end

        local function swingGap(tool)
            local pick = tool or heldPick
            if pick then
                for _, key in ipairs(COOLDOWN_KEYS) do
                    local value = tonumber(getAttr(pick, key))
                    if value and value > 0 then
                        return math.clamp(value, SWING_FLOOR, 0.5)
                    end
                end
            end
            return SWING_GAP
        end

        local function swing(part, model, center)
            local event = Remotes.DigRequest
            if not event or not heldPick then
                return false
            end

            local name = heldPick.Name
            local core = center or (part and part.Parent and part.Position)
            local spot = core

            if part and part.Parent then
                spot = hitSpot(part, model) or core
            end

            if not spot and not core then
                return false
            end

            spot = spot or core
            core = core or spot

            local sweepList = {}
            if model and model.Parent then
                local list = partList(model)
                local count = #list

                if count > 0 then
                    for _ = 1, math.min(SWEEP_PARTS, count) do
                        partCursor = partCursor % count + 1
                        local item = list[partCursor]
                        if item and item.Parent then
                            sweepList[#sweepList + 1] = item.Position
                        end
                    end
                end
            end

            return pcall(function()
                for index = 1, SWING_BURST do
                    if index % 2 == 0 then
                        fireRemote(event, name, core)
                    else
                        fireRemote(event, name, spot)
                    end
                end

                for _, point in ipairs(sweepList) do
                    fireRemote(event, name, point)
                end
            end)
        end

        local function hold(goal, aim)
            return Move.glide(goal, aim)
        end

        local function restart()
            task.spawn(function()
                pcall(function()
                    LocalPlayer:Kick("Universe: restarting server")
                end)

                for _ = 1, 20 do
                    task.wait(1.5)
                    local sent = pcall(function()
                        Services.TeleportService:Teleport(PLACE_ID, LocalPlayer)
                    end)

                    if not sent then
                        pcall(function()
                            Services.TeleportService:TeleportToPlaceInstance(PLACE_ID, game.JobId, LocalPlayer)
                        end)
                    end
                end
            end)
        end

        local function boulderRoots()
            local roots = {}
            local decorations = Services.Workspace:FindFirstChild("MountainDecorations")
            local folder = decorations and decorations:FindFirstChild("Boulders")
            if folder then
                roots[#roots + 1] = folder
            end
            local test = Services.Workspace:FindFirstChild("BoulderTest")
            if test then
                roots[#roots + 1] = test
            end
            return roots
        end

        local function boulderKind(inst)
            if not inst then
                return nil
            end
            local attrName = getAttr(inst, "BoulderName")
            local str = tostring(attrName or inst.Name)
            for _, kind in ipairs(FARM_KINDS) do
                if str:find(kind, 1, true) then
                    return kind
                end
            end
            return nil
        end

        local function anchorOf(model)
            if not model then
                return nil
            end
            if model:IsA("BasePart") then
                return model
            end

            local list = partList(model)
            if list[1] then
                return list[1]
            end

            local ok, part = pcall(model.FindFirstChildWhichIsA, model, "BasePart", true)
            if ok and part then
                return part
            end
            return nil
        end

        local function boulderHealth(model)
            if not model then
                return nil
            end
            local hp = getAttr(model, "HP")
            if hp == nil then
                hp = getAttr(model, "Health")
            end
            if hp == nil then
                hp = getAttr(model, "Hp")
            end
            if hp == nil then
                hp = getAttr(model, "CurrentHealth")
            end
            return tonumber(hp)
        end

        local blacklistedBoulders = {}
        local lastDamageClock = 0

        local function swingGap(tool)
            local pick = tool or heldPick
            if pick then
                for _, key in ipairs(COOLDOWN_KEYS) do
                    local value = tonumber(getAttr(pick, key))
                    if value and value > 0 then
                        return math.clamp(value, SWING_FLOOR, 0.5)
                    end
                end
            end
            return SWING_GAP
        end

        local function pickTarget()
            local root = getRoot()
            if not root then
                return nil
            end

            local now = os.clock()
            for b, expire in pairs(blacklistedBoulders) do
                if now > expire or not b.Parent then
                    blacklistedBoulders[b] = nil
                end
            end

            local best, bestAnchor, bestScore

            for _, container in ipairs(boulderRoots()) do
                for _, child in ipairs(container:GetChildren()) do
                    if not blacklistedBoulders[child] then
                        local kind = boulderKind(child)
                        if kind and targets[kind] then
                            local part = anchorOf(child)
                            if part then
                                local distance = (part.Position - root.Position).Magnitude
                                local hp = boulderHealth(child) or 0
                                if hp >= 0 then
                                    local priority = 10
                                    for idx, k in ipairs(FARM_KINDS) do
                                        if k == kind then
                                            priority = idx
                                            break
                                        end
                                    end

                                    local score = priority * 1000 + distance

                                    if not best or score < bestScore then
                                        best = child
                                        bestAnchor = part
                                        bestScore = score
                                    end
                                end
                            end
                        end
                    end
                end
            end

            return best, bestAnchor
        end

        local function approach(part, model, turn, spot, pad)
            local root = getRoot()
            if not root then
                return nil
            end

            local center = spot or (part and part.Parent and part.Position)
            if not center then
                return nil
            end

            local away = root.Position - center
            away = Vector3.new(away.X, 0, away.Z)

            if away.Magnitude < 0.5 then
                away = Vector3.new(0, 0, 1)
            end
            away = away.Unit

            local modelSize
            if model and model:IsA("Model") then
                local ok, ext = pcall(model.GetExtentsSize, model)
                if ok and ext then
                    modelSize = ext
                end
            end
            if not modelSize and part and part.Parent then
                modelSize = part.Size
            end
            modelSize = modelSize or Vector3.new(12, 12, 12)

            local outerRadius = math.max(modelSize.X, modelSize.Z) * 0.5
            local reach = math.max(outerRadius + 6.5 + (pad or 0), 8.5)
            local skip = turn or 0

            for _, lift in ipairs(AIM_LIFT) do
                for _, angle in ipairs(AIM_ANGLES) do
                    local dir = (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(angle)) * away).Unit
                    local candidate = center + dir * reach + Vector3.new(0, lift, 0)

                    if sightClear(candidate, part, model) then
                        if skip <= 0 then
                            return CFrame.new(candidate, center)
                        end
                        skip -= 1
                    end
                end
            end

            return CFrame.new(center + away * reach + Vector3.new(0, AIM_LIFT[2], 0), center)
        end

        local function beginLoot(finish)
            pendingFinish = finish == true
            lootUntil = os.clock() + LOOT_TIME
            phase = "loot"
            statusText = "Looting runes"
        end

        local function stop()
            active = false
            phase = "idle"
            target = nil
            anchor = nil
            waitUntil = 0
            Move.glideStop()
            hpMark = nil
            dryRounds = 0
            pendingFinish = false
            lootUntil = 0
            spotFrame = nil
            aimTurn = 0
            blindClock = 0
            lostClock = 0
            dryClock = 0
            probeIndex = 0
            scanRetries = 0
            stuckClock = 0
            lastPos = nil
            lastDamageClock = 0
            lockedCenter = nil
            spotCenter = nil
            centerClock = 0
            spotClock = 0
            table.clear(blacklistedBoulders)
            statusText = "Idle"

            Move.setFly(toggleValue("Fly"))
            Move.setNoclip(toggleValue("Noclip"))
            Mountain.setAutoGrab(toggleValue("AutoRunePickup"))
        end

        local function step(deltaTime)
            local root = getRoot()
            if not root then
                statusText = "Waiting for character"
                return
            end

            local now = os.clock()

            local travelling = spotFrame ~= nil and (root.Position - spotFrame.Position).Magnitude > ARRIVE_DIST

            if travelling and lastPos and (root.Position - lastPos).Magnitude < 0.5 then
                stuckClock += deltaTime
                if stuckClock >= STUCK_TIME then
                    stuckClock = 0
                    spotFrame = nil
                    aimTurn = (aimTurn + 1) % #AIM_ANGLES
                    probeIndex += 1
                end
            else
                stuckClock = 0
                lastPos = root.Position
            end

            if phase == "scan" then
                if not scanned then
                    if scanIndex == 0 then
                        scanIndex = 1
                        waitUntil = now + SCAN_HOLD
                    end

                    if scanIndex <= #SCAN_SPOTS then
                        hold(SCAN_SPOTS[scanIndex])
                        statusText = string.format("Scanning %d/%d", scanIndex, #SCAN_SPOTS)

                        if now >= waitUntil then
                            scanIndex += 1
                            waitUntil = now + SCAN_HOLD
                        end

                        return
                    end

                    scanned = true
                end

                local model = pickTarget()
                if not model then
                    scanRetries += 1
                    if scanRetries <= 3 then
                        statusText = "Waiting for boulders..."
                        waitUntil = now + 1.5
                        return
                    end

                    scanRetries = 0
                    beginLoot(true)
                    statusText = "Final rune sweep"
                    return
                end

                scanRetries = 0
                target = model
                anchor = visibleAnchor(model) or anchorOf(model)
                spotFrame = nil
                spotCenter = nil
                lockedCenter = nil
                centerClock = 0
                spotClock = 0
                aimTurn = 0
                blindClock = 0
                lostClock = 0
                dryClock = 0
                probeIndex = 0
                hpMark = nil
                dryRounds = 0
                lastDamageClock = now
                phase = "mine"
                return
            end

            if phase == "mine" then
                if not target or not target.Parent then
                    lastSpot = root.CFrame
                    beginLoot(false)
                    return
                end

                local kind = boulderKind(target) or "Boulder"
                local hp = boulderHealth(target)

                if hp and hp <= 0 then
                    lastSpot = root.CFrame
                    beginLoot(false)
                    return
                end

                if not anchor or not anchor.Parent or not anchor:IsDescendantOf(target) then
                    anchor = visibleAnchor(target) or anchorOf(target)
                end

                centerClock += deltaTime
                local center = lockedCenter

                if not center or centerClock >= CENTER_STEP then
                    centerClock = 0
                    local fresh = coreSpot(target) or anchorSpot(target, anchor)
                    if fresh and (not center or (fresh - center).Magnitude >= CENTER_SHIFT) then
                        center = fresh
                        lockedCenter = fresh
                    end
                end

                if not center then
                    lostClock += deltaTime
                    if lostClock >= LOST_GRACE then
                        lastSpot = root.CFrame
                        beginLoot(false)
                        return
                    end
                    statusText = string.format("Holding %s", kind)
                    return
                end

                lostClock = 0
                spotClock += deltaTime

                if spotFrame and spotCenter and (spotCenter - center).Magnitude > SPOT_SLACK then
                    spotFrame = nil
                end

                if not spotFrame then
                    spotFrame = approach(anchor, target, aimTurn, center, PROBE_DIST[probeIndex % #PROBE_DIST + 1])
                    spotCenter = center
                    spotClock = 0
                end

                if spotFrame then
                    Move.setNoclip(true)
                    hold(spotFrame, center)
                end

                if heldPick == nil or heldPick.Parent ~= LocalPlayer.Character then
                    equipClock = 0
                    heldPick = equipPick()
                else
                    equipClock += deltaTime
                    if equipClock >= EQUIP_STEP then
                        equipClock = 0
                        heldPick = equipPick() or heldPick
                    end
                end

                if not heldPick then
                    statusText = "Equipping pickaxe..."
                    return
                end

                swingClock += deltaTime
                local gap = swingGap()
                local swung = 0

                if swingClock >= gap then
                    swung = math.min(math.floor(swingClock / gap), 4)
                    swingClock -= swung * gap

                    for _ = 1, swung do
                        swing(anchor, target, center)
                    end
                end

                if hp then
                    if hpMark == nil or hp < (hpMark - 0.001) then
                        hpMark = hp
                        dryRounds = 0
                        dryClock = 0
                        blindClock = 0
                        lastDamageClock = now
                    else
                        dryClock += deltaTime
                        dryRounds += swung

                        if dryClock >= DRY_SWAP then
                            dryClock = 0
                            dryRounds = 0
                            anchor = freshAnchor(target) or visibleAnchor(target) or anchor
                            if spotClock >= SPOT_HOLD then
                                aimTurn = (aimTurn + 1) % #AIM_ANGLES
                                probeIndex += 1
                                spotFrame = nil
                            end
                        end
                    end

                    if now - lastDamageClock >= SKIP_TIME then
                        blacklistedBoulders[target] = now + 15
                        target = nil
                        anchor = nil
                        spotFrame = nil
                        phase = "scan"
                        statusText = "Skipping unhittable boulder"
                        return
                    end

                    statusText = string.format("Mining %s  %.0f hp", kind, hp)
                    return
                end

                if sightClear(root.Position, anchor, target) then
                    blindClock = 0
                else
                    blindClock += deltaTime
                    if blindClock >= SIGHT_GRACE then
                        blindClock = 0
                        anchor = visibleAnchor(target) or anchor
                        if spotClock >= SPOT_HOLD then
                            aimTurn = (aimTurn + 1) % #AIM_ANGLES
                            spotFrame = nil
                        end
                    end
                end

                statusText = string.format("Mining %s", kind)
                return
            end

            if phase == "loot" then
                if lastSpot then
                    hold(lastSpot)
                end

                Mountain.grabNear(RUNE_SWEEP)

                if now < lootUntil then
                    statusText = string.format("Looting runes  %.1fs", lootUntil - now)
                    return
                end

                if pendingFinish then
                    phase = "reset"
                    waitUntil = now + RESET_WAIT
                    statusText = "Runes collected"
                else
                    target = nil
                    anchor = nil
                    phase = "scan"
                    statusText = "Next boulder"
                end

                return
            end

            if phase == "reset" then
                if now < waitUntil then
                    return
                end

                if autoRejoin then
                    statusText = "Restarting server"
                    Library:Notify("No boulders left - rejoining", 3)
                    stop()
                    restart()
                else
                    statusText = "Re-scanning mountain..."
                    Library:Notify("No boulders left - re-scanning in 4s", 3)
                    target = nil
                    anchor = nil
                    scanned = false
                    scanIndex = 0
                    phase = "scan"
                    waitUntil = now + 4.0
                end
            end
        end

        local function setTargets(value)
            table.clear(targets)
            if type(value) == "table" then
                for key, flag in pairs(value) do
                    if type(key) == "string" and flag == true then
                        targets[key] = true
                    elseif type(flag) == "string" then
                        targets[flag] = true
                    end
                end
            elseif type(value) == "string" then
                targets[value] = true
            end
        end

        local function setActive(value)
            if not value then
                stop()
                return
            end

            if not next(targets) then
                Library:Notify("Pick at least one boulder", 2)
                local store = Library and Library.Toggles
                local entry = store and store.AutoFarmBoulders
                if entry and entry.SetValue then
                    entry:SetValue(false)
                end
                return
            end

            active = true
            phase = "scan"
            waitUntil = 0
            target = nil
            anchor = nil
            lastSpot = nil
            swingClock = 0
            equipClock = 0
            hpMark = nil
            dryRounds = 0
            spotFrame = nil
            aimTurn = 0
            blindClock = 0
            lostClock = 0
            dryClock = 0
            probeIndex = 0
            scanned = false
            scanIndex = 0
            heldPick = nil
            pendingFinish = false
            lootUntil = 0
            scanRetries = 0
            stuckClock = 0
            lastPos = nil
            lockedCenter = nil
            spotCenter = nil
            centerClock = 0
            spotClock = 0
            statusText = "Starting"

            Move.setFly(false)
            Move.setNoclip(true)
            Mountain.setAutoGrab(true)
        end

        local FarmBox = Tabs.boulders:AddRightGroupbox("Boulder Farm", "bot")
        FarmBox:AddLabel("Specialized in rune farming", true)
        FarmBox:AddDivider()

        FarmBox:AddDropdown("FarmTargets", {
            Text = "Targets",
            Values = FARM_KINDS,
            Multi = true,
            AllowNull = true,
            Callback = setTargets,
        })

        FarmBox:AddToggle("AutoFarmBoulders", {
            Text = "Auto Farm",
            Default = false,
            Callback = setActive,
        })

        FarmBox:AddToggle("AutoRejoinBoulders", {
            Text = "Auto Rejoin On Finish",
            Default = Config.AutoRejoinBoulders,
            Callback = function(value)
                autoRejoin = value
            end,
        })

        FarmBox:AddDivider()

        local StatusLabel = FarmBox:AddLabel("Idle", true)
        local labelClock = 0

        Connections.farmConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
            if active then
                local ok, err = pcall(step, deltaTime)
                if not ok then
                    reportError("boulderFarm", err)
                end
            end

            labelClock += deltaTime
            if labelClock >= 0.25 then
                labelClock = 0
                StatusLabel:SetText(statusText)
            end
        end)

        Farm.stop = stop
        Farm.equipPick = equipPick
        Farm.swingGap = swingGap
    end

    install()
end

local Money = {}

do
    local function install()
        local SCAN_SPOTS = {
            CFrame.new(-12.7105675, 459.090942, 818.847412, 0.993408799, -0.00500036497, -0.11451605, 0.000644713698, 0.999275982, -0.0380407833, 0.114623353, 0.0377162211, 0.992692769),
            CFrame.new(13.0506754, 318.450409, -488.078888, -0.99998939, 0.000884758658, -0.00452193478, -0.000498382491, 0.954864502, 0.297041386, 0.00458064489, 0.297040492, -0.954853892),
            CFrame.new(74.3923645, 610.789368, 210.838226, -0.94896102, -0.27110818, 0.161162555, 2.26557495e-06, 0.51098305, 0.859590769, -0.315393418, 0.815718472, -0.484902382),
        }

        local SCAN_HOLD = 1.4
        local PEAK_GAP = 8
        local PEAK_STEP = 48
        local PEAK_RINGS = 12
        local COLUMN_STEP = 8
        local RING_MAX = 6
        local RAY_TOP = 120
        local RAY_DROP = 60
        local ZONE_PAD = 12
        local SURFACE_GAP = 0.15
        local COLUMN_DRY = 25
        local DIG_BURST = 7
        local DIG_SINK = 1.2
        local DIG_LIFT = 6
        local EQUIP_STEP = 0.5
        local SELL_MARK = Config.AutoSellThreshold
        local SELL_WAIT = 7
        local DIG_REACH = 12
        local DIG_REFRESH = 5
        local COLLECT_RANGE = 32000
        local COLLECT_LIFT = 5
        local COLLECT_GAP = 0.15
        local GRAB_GAP = 0.05
        local MAX_LOOT_TIME = 4.0

        local OFFSETS = { Vector2.new(0, 0) }
        local PEAK_OFFSETS = { Vector2.new(0, 0) }

        for ring = 1, RING_MAX do
            local slices = ring * 6
            for slice = 0, slices - 1 do
                local angle = slice / slices * math.pi * 2
                local reach = ring * COLUMN_STEP
                OFFSETS[#OFFSETS + 1] = Vector2.new(math.cos(angle) * reach, math.sin(angle) * reach)
            end
        end

        for ring = 1, PEAK_RINGS do
            local slices = ring * 3
            for slice = 0, slices - 1 do
                local angle = slice / slices * math.pi * 2
                local reach = ring * PEAK_STEP
                PEAK_OFFSETS[#PEAK_OFFSETS + 1] = Vector2.new(math.cos(angle) * reach, math.sin(angle) * reach)
            end
        end

        local surfaceParams = RaycastParams.new()
        surfaceParams.FilterType = Enum.RaycastFilterType.Include
        surfaceParams.FilterDescendantsInstances = { Services.Workspace.Terrain }
        surfaceParams.IgnoreWater = true

        local digParams = RaycastParams.new()
        digParams.FilterType = Enum.RaycastFilterType.Include
        digParams.IgnoreWater = true

        local digClock = 0

        local function digFilter(now)
            if digClock > 0 and now - digClock < DIG_REFRESH then
                return
            end
            digClock = now

            local list = { Services.Workspace.Terrain }
            local decorations = Services.Workspace:FindFirstChild("MountainDecorations")
            local boulders = decorations and decorations:FindFirstChild("Boulders")
            if boulders then
                list[#list + 1] = boulders
            end

            local test = Services.Workspace:FindFirstChild("BoulderTest")
            if test then
                list[#list + 1] = test
            end

            digParams.FilterDescendantsInstances = list
        end

        local function pickReach(tool)
            local override = tool and tonumber(getAttr(tool, "OverrideMaxReach"))
            return (override or DIG_REACH) + 3
        end

        local function aimPoint(origin, spot, reach, now)
            digFilter(now)
            local goals = {
                spot,
                spot - Vector3.new(0, 2, 0),
                origin - Vector3.new(0, reach, 0),
            }

            for _, goal in ipairs(goals) do
                local delta = goal - origin
                local distance = delta.Magnitude
                if distance > 0.05 then
                    local span = math.min(distance + 4, reach)
                    local hit = Services.Workspace:Raycast(origin, delta.Unit * span, digParams)
                    if hit then
                        return hit.Position
                    end
                end
            end

            local delta = spot - origin
            if delta.Magnitude <= reach then
                return spot
            end
            return origin + delta.Unit * reach
        end

        local active = false
        local autoSell = false
        local focusLuck = false
        local minLuckPoints = 4
        local autoPlantLuck = false
        local plantClock = 0
        local heldPick
        local loot
        local lootClock = 0
        local grabClock = 0
        local lootHp
        local lootMax
        local lootStartTime = 0
        local lootLastHpChange = 0
        local lootHpMark
        local blacklistedLoot = {}
        local blacklistedColumns = {}
        local target
        local columnY
        local columnDry = 0
        local columnSwings = 0
        local surfaceClock = 0
        local peakClock = 0
        local scanIndex = 0
        local scanUntil = 0
        local loaded = false
        local swingClock = 0
        local equipClock = 0
        local sellPhase = "idle"
        local sellReturnCFrame
        local sellPhaseClock = 0
        local plantPhase = "idle"
        local plantPhaseClock = 0
        local plantReturnCFrame
        local plantTools = {}
        local plantIndex = 1
        local plantPlotPos
        local plantGroundPos
        local lootBlocked = false
        local statusText = "Idle"

        local function toggleValue(name)
            local store = Library and Library.Toggles
            local entry = store and store[name]
            if entry and type(entry.Value) == "boolean" then
                return entry.Value
            end
            return false
        end

        local function getSellCFrame()
            local things = Services.Workspace:FindFirstChild("Things")
            local prox = things and things:FindFirstChild("SellProx")
            if prox and prox:IsA("BasePart") then
                return CFrame.new(prox.Position + Vector3.new(0, 3, 0), prox.Position)
            end
            local model = things and things:FindFirstChild("SellModel")
            local part = model and model:FindFirstChild("SellPart")
            if part and part:IsA("BasePart") then
                return CFrame.new(part.Position + Vector3.new(0, 3, 0), part.Position)
            end
            return CFrame.new(-45.85, 32, 1066.58)
        end

        local function zoneBase()
            local base = Services.Workspace:GetAttribute("MountainBaseY")
            if typeof(base) == "number" then
                return base
            end
            return Config.MountainCenter.Y - 500
        end

        local function zonePeak()
            local peak = Services.Workspace:GetAttribute("MountainPeakY")
            if typeof(peak) == "number" then
                return peak
            end
            return Config.MountainCenter.Y + 600
        end

        local function zoneCenter()
            local spot = mountainSpot()
            if spot then
                return Vector2.new(spot.X, spot.Z)
            end
            return Vector2.new(Config.MountainCenter.X, Config.MountainCenter.Z)
        end

        local function insideZone(x, z)
            local center = zoneCenter()
            if not center then
                return false
            end
            return (Vector2.new(x, z) - center).Magnitude <= mountainSpan() + ZONE_PAD
        end

        local function surfaceAt(x, z)
            if not insideZone(x, z) then
                return nil
            end

            local base = zoneBase()
            local top = zonePeak() + RAY_TOP
            local hit = Services.Workspace:Raycast(
                Vector3.new(x, top, z),
                Vector3.new(0, -(top - base + RAY_DROP), 0),
                surfaceParams
            )

            if not hit or hit.Position.Y <= base + 1 then
                return nil
            end
            return hit.Position
        end

        local function farmOrigin(root)
            if insideZone(root.Position.X, root.Position.Z) then
                return root.Position
            end
            return mountainSpot() or root.Position
        end

        local function gridKey(x, z)
            return string.format("%d_%d", math.floor(x / 4), math.floor(z / 4))
        end

        local function highestColumn(origin, offsets)
            local now = os.clock()
            local best

            for _, offset in ipairs(offsets) do
                local posX = origin.X + offset.X
                local posZ = origin.Z + offset.Y
                local key = gridKey(posX, posZ)

                local expire = blacklistedColumns[key]
                if not expire or now > expire then
                    blacklistedColumns[key] = nil
                    local spot = surfaceAt(posX, posZ)
                    if spot and (not best or spot.Y > best.Y) then
                        best = spot
                    end
                end
            end

            return best
        end

        local function pickTarget(origin, now)
            local center = mountainSpot()
            if center and now - peakClock >= PEAK_GAP then
                peakClock = now
                local high = highestColumn(center, PEAK_OFFSETS)
                if high then
                    return high
                end
            end

            local spot = highestColumn(origin, OFFSETS)
            if spot then
                return spot
            end

            if center then
                peakClock = now
                return highestColumn(center, PEAK_OFFSETS)
            end

            return nil
        end

        local function holdAt(goal, aim)
            return Move.glide(goal, aim)
        end

        local function swing(spot)
            local event = Remotes.DigRequest
            if not event or not heldPick then
                return false
            end

            local name = heldPick.Name
            local root = getRoot()
            local aim = spot

            if root then
                aim = aimPoint(root.Position, spot, pickReach(heldPick), os.clock()) or spot
            end

            return pcall(function()
                for step = 0, DIG_BURST - 1 do
                    fireRemote(event, name, aim - Vector3.new(0, step * DIG_SINK, 0))
                end
            end)
        end

        local function bagRatio()
            local capacity = backpackCapacity()
            if capacity == math.huge or capacity <= 0 then
                return 0
            end
            return backpackWeight() / capacity
        end

        local function getPlayerPlot()
            local lpName = LocalPlayer.Name
            local slots = Services.Workspace:FindFirstChild("Things") and Services.Workspace.Things:FindFirstChild("Plots") and Services.Workspace.Things.Plots:FindFirstChild("Slots")
            if slots then
                local plot = slots:FindFirstChild(lpName)
                if plot then
                    return plot
                end
            end
            return nil
        end

        local function getPlotPlantPosition()
            local plot = getPlayerPlot()
            if not plot then
                return nil
            end
            local spawn = plot:FindFirstChild("Spawn")
            local region = plot:FindFirstChild("Region")
            if region and region:IsA("BasePart") and spawn and spawn:IsA("BasePart") then
                local corner = region.CFrame * CFrame.new(-region.Size.X/2 + 15, 0, -region.Size.Z/2 + 15)
                return Vector3.new(corner.Position.X, spawn.Position.Y - 1.5, corner.Position.Z)
            end
            if spawn and spawn:IsA("BasePart") then
                return spawn.Position - Vector3.new(30, 1.5, 30)
            end
            local ok, pivot = pcall(plot.GetPivot, plot)
            if ok and pivot then
                return pivot.Position
            end
            return nil
        end

        local function getLuckToolsInBackpack()
            local list = {}

            local function scan(container)
                if not container then return end
                for _, child in ipairs(container:GetChildren()) do
                    if child:IsA("Tool") then
                        local isCryst = getAttr(child, "Tier") ~= nil or child:GetAttribute("MeshTemplate") ~= nil
                        if isCryst then
                            local luckPts = math.floor(crystalLuck(child) * 100 + 0.5)
                            if luckPts >= minLuckPoints then
                                list[#list + 1] = child
                            end
                        end
                    end
                end
            end

            scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
            scan(LocalPlayer.Character)
            return list
        end

        -- Replaced with plantPhase state machine in step()

        local function findLoot(free, origin)
            local now = os.clock()
            local best, bestScore, bestDistance
            local blocked = false
            local seen = {}

            for inst, expire in pairs(blacklistedLoot) do
                if now > expire or not inst.Parent then
                    blacklistedLoot[inst] = nil
                end
            end

            local function consider(inst)
                if not inst or seen[inst] or blacklistedLoot[inst] then
                    return
                end
                seen[inst] = true

                if not inst.Parent or not isCrystal(inst) or getAttr(inst, "Collected") == true then
                    return
                end

                local score = 0
                if focusLuck then
                    local luckPts = math.floor(crystalLuck(inst) * 100 + 0.5)
                    if luckPts < minLuckPoints then
                        return
                    end
                    score = luckPts
                else
                    local value = crystalValue(inst)
                    if not meetsFilter(inst, value) then
                        return
                    end
                    score = value
                end

                local distance = (inst.Position - origin).Magnitude
                if distance > COLLECT_RANGE then
                    return
                end

                if crystalWeight(inst) > free then
                    blocked = true
                    return
                end

                local better = false
                if not best then
                    better = true
                elseif score > bestScore then
                    better = true
                elseif score == bestScore and distance < bestDistance then
                    better = true
                end

                if better then
                    best = inst
                    bestScore = score
                    bestDistance = distance
                end
            end

            eachContainer(function(container)
                for _, child in ipairs(container:GetChildren()) do
                    if child:IsA("BasePart") then
                        consider(child)
                    elseif child:IsA("Model") then
                        for _, inner in ipairs(child:GetChildren()) do
                            if inner:IsA("BasePart") then
                                consider(inner)
                            end
                        end
                    end
                end
            end)

            for inst in pairs(Storage.registry) do
                consider(inst)
            end

            return best, blocked
        end

        local function stop()
            active = false
            target = nil
            columnY = nil
            loaded = false
            Move.glideStop()
            scanIndex = 0
            loot = nil
            lootHp = nil
            lootMax = nil
            lootBlocked = false
            lootStartTime = 0
            lootLastHpChange = 0
            lootHpMark = nil
            table.clear(blacklistedLoot)
            table.clear(blacklistedColumns)
            table.clear(blacklistedColumns)
            sellPhase = "idle"
            sellReturnCFrame = nil
            sellPhaseClock = 0
            plantPhase = "idle"
            plantPhaseClock = 0
            plantReturnCFrame = nil
            heldPick = nil
            statusText = "Idle"

            Move.setFly(toggleValue("Fly"))
            Move.setNoclip(toggleValue("Noclip"))
            Mountain.setAutoGrab(toggleValue("AutoRunePickup"))
        end

        local function crystalHealth(inst)
            if not inst then return nil end
            local hp = getAttr(inst, "MinedHP") or getAttr(inst, "Health") or getAttr(inst, "Hp") or getAttr(inst, "CurrentHealth")
            return tonumber(hp)
        end

        local function step(deltaTime)
            local root = getRoot()
            if not root then
                statusText = "Waiting for character"
                return
            end

            local now = os.clock()

            if plantPhase ~= "idle" then
                if plantPhase == "travel" then
                    statusText = "Traveling to plot..."
                    holdAt(plantPlotPos)
                    if (root.Position - plantPlotPos.Position).Magnitude < 10 or (now - plantPhaseClock > 12) then
                        plantPhase = "do_plant"
                        plantPhaseClock = now
                    end
                    return
                end

                if plantPhase == "do_plant" then
                    statusText = "Planting luck crystals..."
                    holdAt(plantPlotPos)
                    if now - plantPhaseClock >= 0.15 then
                        plantPhaseClock = now
                        if plantIndex <= #plantTools then
                            local tool = plantTools[plantIndex]
                            local col = (plantIndex - 1) % 6
                            local row = math.floor((plantIndex - 1) / 6)
                            local plantSpot = plantGroundPos + Vector3.new(col * 4 - 10, 0, row * 4 - 10)
                            pcall(function()
                                Remotes.PlotPlaceRequest:FireServer(tool.Name, plantSpot, 0, tool)
                            end)
                            plantIndex += 1
                        else
                            plantPhase = "return"
                            plantPhaseClock = now
                        end
                    end
                    return
                end

                if plantPhase == "return" then
                    statusText = "Returning to mountain..."
                    local destination = plantReturnCFrame or mountainSpot()
                    holdAt(destination)
                    if (root.Position - destination.Position).Magnitude < 12 or (now - plantPhaseClock > 12) then
                        plantPhase = "idle"
                        plantReturnCFrame = nil
                        target = nil
                        columnY = nil
                        surfaceClock = 0
                    end
                    return
                end
            end

            if autoPlantLuck and plantPhase == "idle" and now - plantClock >= 2.0 then
                plantClock = now
                local tools = getLuckToolsInBackpack()
                if #tools >= 5 then
                    local pos = getPlotPlantPosition()
                    if pos then
                        plantGroundPos = pos
                        plantPlotPos = CFrame.new(pos + Vector3.new(0, 8, 0), pos)
                        plantReturnCFrame = root.CFrame
                        plantTools = tools
                        plantIndex = 1
                        plantPhase = "travel"
                        plantPhaseClock = now
                        statusText = "Heading to plot..."
                        return
                    end
                end
            end

            if not loaded then
                if scanIndex == 0 then
                    scanIndex = 1
                    scanUntil = now + SCAN_HOLD
                end

                if scanIndex <= #SCAN_SPOTS then
                    holdAt(SCAN_SPOTS[scanIndex])
                    statusText = string.format("Loading terrain %d/%d", scanIndex, #SCAN_SPOTS)

                    if now >= scanUntil then
                        scanIndex += 1
                        scanUntil = now + SCAN_HOLD
                    end

                    return
                end

                loaded = true
                peakClock = 0
            end

            if sellPhase ~= "idle" then
                local sellCFrame = getSellCFrame()

                if sellPhase == "travel" then
                    statusText = "Traveling to sell station..."
                    holdAt(sellCFrame)

                    if (root.Position - sellCFrame.Position).Magnitude < 10 or (now - sellPhaseClock > 12) then
                        sellPhase = "do_sell"
                        sellPhaseClock = now
                    end
                    return
                end

                if sellPhase == "do_sell" then
                    statusText = "Selling crystals..."
                    holdAt(sellCFrame)

                    if now - sellPhaseClock >= 0.3 and now - sellPhaseClock < 0.6 then
                        unfavoriteAll()
                        fireRemote(Remotes.SellRequest, "all")

                        local things = Services.Workspace:FindFirstChild("Things")
                        local prox = things and things:FindFirstChild("SellProx")
                        local prompt = prox and prox:FindFirstChildOfClass("ProximityPrompt")
                        if prompt then
                            firePrompt(prompt)
                        end
                    end

                    if (now - sellPhaseClock >= 1.5) or (backpackWeight() <= 0) then
                        lootBlocked = false
                        sellPhase = "return"
                        sellPhaseClock = now
                    end
                    return
                end

                if sellPhase == "return" then
                    statusText = "Returning to mountain..."
                    local destination = sellReturnCFrame or mountainSpot()
                    holdAt(destination)

                    if (root.Position - destination.Position).Magnitude < 12 or (now - sellPhaseClock > 12) then
                        sellPhase = "idle"
                        sellReturnCFrame = nil
                        target = nil
                        columnY = nil
                        surfaceClock = 0
                    end
                    return
                end
            end

            if autoSell and sellPhase == "idle" and (bagRatio() >= SELL_MARK or lootBlocked) then
                sellReturnCFrame = root.CFrame
                sellPhase = "travel"
                sellPhaseClock = now
                statusText = "Heading to sell station..."
                return
            end

            if focusLuck then
                pickupStep(function(inst)
                    local luckPts = math.floor(crystalLuck(inst) * 100 + 0.5)
                    return luckPts >= minLuckPoints
                end)
            else
                pickupStep()
            end

            if heldPick == nil or heldPick.Parent ~= LocalPlayer.Character then
                equipClock = 0
                heldPick = Farm.equipPick()
            else
                equipClock += deltaTime
                if equipClock >= EQUIP_STEP then
                    equipClock = 0
                    heldPick = Farm.equipPick() or heldPick
                end
            end

            if not heldPick then
                statusText = "Equipping pickaxe..."
                return
            end

            swingClock += deltaTime
            local swingNeed = math.max(0.02, Farm.swingGap(heldPick) * 0.4)
            local canSwing = swingClock >= swingNeed
            local free = backpackFree()

            if loot then
                local parented = loot.Parent ~= nil
                local collected = (getAttr(loot, "Collected") == true)
                local currentHp = crystalHealth(loot)

                if currentHp and currentHp > 0 then
                    if lootHpMark == nil or currentHp < (lootHpMark - 0.001) then
                        lootHpMark = currentHp
                        lootLastHpChange = now
                    end
                end

                local hpStuck = (now - lootLastHpChange > 12.0) and (now - lootStartTime > 12.0)
                local maxTimeout = (now - lootStartTime > 40.0)
                local cantFit = (crystalWeight(loot) > free)

                if not parented or collected or hpStuck or maxTimeout or cantFit then
                    if (hpStuck or maxTimeout) and loot and parented then
                        blacklistedLoot[loot] = now + 20
                    end
                    loot = nil
                    lootHp = nil
                    lootMax = nil
                    lootHpMark = nil
                end
            end

            if loot then
                local hp = crystalHealth(loot)
                if hp and (lootMax == nil or hp > lootMax) then
                    lootMax = hp
                end
                lootHp = hp
            end

            if not loot and now - lootClock >= COLLECT_GAP then
                lootClock = now
                loot, lootBlocked = findLoot(free, root.Position)
                if loot then
                    lootStartTime = now
                    lootLastHpChange = now
                    lootHp = crystalHealth(loot)
                    lootMax = lootHp
                    lootHpMark = lootHp
                end
            end

            if loot and loot.Parent then
                local spot = loot.Position
                holdAt(CFrame.new(spot + Vector3.new(0, COLLECT_LIFT, 0), spot), spot)
                requestStream(spot)

                if canSwing then
                    swingClock -= swingNeed
                    swing(spot)
                end

                if now - grabClock >= GRAB_GAP then
                    grabClock = now
                    grabCrystal(loot, crystalPrompt(loot))
                end

                if lootHp and lootHp > 0 then
                    local ratio = 0
                    if lootMax and lootMax > 0 then
                        ratio = math.clamp(1 - lootHp / lootMax, 0, 1)
                    end
                    statusText = string.format("Mining %s (%s) %d%%", crystalName(loot), formatShort(crystalValue(loot), "$"), math.floor(ratio * 100))
                else
                    statusText = string.format("Collecting %s (%s)...", crystalName(loot), formatShort(crystalValue(loot), "$"))
                end

                return
            end

            local origin = farmOrigin(root)

            if target and now - surfaceClock >= SURFACE_GAP then
                surfaceClock = now
                local spot = surfaceAt(target.X, target.Z)

                if not spot then
                    target = nil
                    columnY = nil
                    columnDry = 0
                    columnSwings = 0
                else
                    if not columnY or spot.Y < columnY - 0.05 then
                        columnDry = 0
                    else
                        columnDry += columnSwings
                    end

                    columnSwings = 0
                    columnY = spot.Y
                    target = spot

                    if columnDry >= COLUMN_DRY then
                        blacklistedColumns[gridKey(target.X, target.Z)] = now + 20
                        target = nil
                        columnY = nil
                        columnDry = 0
                    end
                end
            end

            if not target then
                local spot = pickTarget(origin, now)
                if not spot then
                    spot = surfaceAt(origin.X, origin.Z)
                end

                if not spot then
                    requestStream(origin)
                    if canSwing then
                        swingClock -= swingNeed
                        swing(root.Position - Vector3.new(0, DIG_REACH * 0.5, 0))
                    end
                    statusText = "Loading terrain"
                    return
                end

                target = spot
                columnY = spot.Y
                columnDry = 0
                columnSwings = 0
                surfaceClock = now
            end

            holdAt(CFrame.new(target + Vector3.new(0, DIG_LIFT, 0), target), target)

            if canSwing then
                swingClock -= swingNeed
                columnSwings += 1
                swing(target)
            end

            statusText = string.format("Mining surface at %dm", math.floor(target.Y))
        end

        local function setActive(value)
            if not value then
                stop()
                return
            end

            active = true
            target = nil
            columnY = nil
            columnDry = 0
            columnSwings = 0
            surfaceClock = 0
            peakClock = 0
            scanIndex = 0
            scanUntil = 0
            loaded = false
            loot = nil
            lootClock = 0
            lootHp = nil
            lootMax = nil
            lootBlocked = false
            lootStartTime = 0
            table.clear(blacklistedLoot)
            table.clear(blacklistedColumns)
            swingClock = 0
            equipClock = 0
            sellSpot = nil
            sellUntil = 0
            heldPick = nil
            statusText = "Starting"

            Move.setFly(false)
            Move.setNoclip(true)
            Mountain.setAutoGrab(true)
        end

        local MoneyBox = Tabs.farming:AddRightGroupbox("Auto Farm Crystal", "gem")
        MoneyBox:AddLabel("Loads the mountain and digs crystals by cash value or luck points", true)
        MoneyBox:AddDivider()

        MoneyBox:AddToggle("AutoFarmMoney", {
            Text = "Auto Farm",
            Default = false,
            Callback = setActive,
        })

        MoneyBox:AddToggle("FocusLuckCrystals", {
            Text = "Focus Luck Crystals",
            Default = false,
            Callback = function(value)
                focusLuck = value
                loot = nil
            end,
        })

        MoneyBox:AddSlider("MinLuckFilterPoints", {
            Text = "Min Luck Points",
            Default = 10,
            Min = 1,
            Max = 1000,
            Rounding = 0,
            Compact = false,
            Callback = function(val)
                minLuckPoints = val
                Config.MinLuckBoost = val
                loot = nil
            end,
        })

        MoneyBox:AddDivider()

        MoneyBox:AddToggle("AutoPlantLuckCrystals", {
            Text = "Auto Plant Luck Crystals On Plot",
            Default = false,
            Callback = function(value)
                autoPlantLuck = value
            end,
        })

        MoneyBox:AddToggle("MoneyAutoSell", {
            Text = "Auto Sell At 50%",
            Default = false,
            Callback = function(value)
                autoSell = value
            end,
        })

        MoneyBox:AddDivider()

        local StatusLabel = MoneyBox:AddLabel("Idle", true)
        local labelClock = 0

        Connections.moneyConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
            if active then
                local ok, err = pcall(step, deltaTime)
                if not ok then
                    reportError("moneyFarm", err)
                end
            end

            labelClock += deltaTime
            if labelClock >= 0.25 then
                labelClock = 0
                StatusLabel:SetText(statusText)
            end
        end)

        local function buyAllAvailableBombs()
            local query = Remotes.BombShopQuery
            local buyReq = Remotes.BombBuyRequest

            if not query or not buyReq then
                return 0
            end

            local ok, data = pcall(function()
                return query:InvokeServer()
            end)
            if not ok or not data or not data.stock then
                return 0
            end

            local boughtTotal = 0

            for bombId, amount in pairs(data.stock) do
                local count = tonumber(amount) or 0
                if count > 0 then
                    for _ = 1, count do
                        local success, res = pcall(function()
                            return buyReq:InvokeServer(bombId)
                        end)
                        if success and res and res.ok then
                            boughtTotal += 1
                        else
                            break
                        end
                    end
                end
            end

            return boughtTotal
        end

        if Remotes.BombShopRestocked then
            Connections.bombRestockConn = Remotes.BombShopRestocked.OnClientEvent:Connect(function()
                if State.autoBuyBombs then
                    task.spawn(buyAllAvailableBombs)
                end
            end)
        end

        local bombCheckClock = 0
        Connections.bombLoopConn = Services.RunService.Heartbeat:Connect(function(deltaTime)
            if State.autoBuyBombs then
                bombCheckClock += deltaTime
                if bombCheckClock >= 10.0 then
                    bombCheckClock = 0
                    task.spawn(buyAllAvailableBombs)
                end
            end
        end)

        local BombBox = Tabs.farming:AddLeftGroupbox("Bomb Auto Buy", "bomb")
        BombBox:AddLabel("Buys all bombs from shop whenever stock is available", true)
        BombBox:AddDivider()

        BombBox:AddToggle("AutoBuyBombs", {
            Text = "Auto Buy On Restock",
            Default = Config.AutoBuyBombs,
            Callback = function(value)
                State.autoBuyBombs = value
                if value then
                    task.spawn(buyAllAvailableBombs)
                end
            end,
        })

        BombBox:AddButton("Buy All Stock Now", function()
            task.spawn(function()
                local count = buyAllAvailableBombs()
                if Library then
                    Library:Notify(string.format("Purchased %d bombs from shop!", count), 3)
                end
            end)
        end)

        Money.stop = stop
    end

    install()
end

SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("TirvoxHub")

ThemeManager:SetLibrary(Library)
ThemeManager:SetFolder("TirvoxHub")

do
    local function install()
        local ConfigGroupbox = SettingsTab:AddLeftGroupbox("Configuration", "folder-cog")

        ConfigGroupbox:AddInput("SaveManager_ConfigName", {
            Text = "Config name",
            Placeholder = "My Config",
        })

        ConfigGroupbox:AddButton("Create config", function()
            local name = Library.Options.SaveManager_ConfigName.Value
            if name:gsub(" ", "") == "" then
                Library:Notify("Invalid config name (empty)", 2)
                return
            end

            local success, err = SaveManager:Save(name)
            if not success then
                Library:Notify("Failed to create config: " .. err)
                return
            end

            Library:Notify(string.format("Created config %q", name))
            Library.Options.SaveManager_ConfigList:SetValues(SaveManager:RefreshConfigList())
            Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        ConfigGroupbox:AddDivider()

        ConfigGroupbox:AddDropdown("SaveManager_ConfigList", {
            Text = "Config list",
            Values = SaveManager:RefreshConfigList(),
            AllowNull = true,
        })

        ConfigGroupbox:AddButton("Load config", function()
            local name = Library.Options.SaveManager_ConfigList.Value
            local success, err = SaveManager:Load(name)
            if not success then
                Library:Notify("Failed to load config: " .. err)
                return
            end
            Library:Notify(string.format("Loaded config %q", name))
        end)

        ConfigGroupbox:AddButton("Overwrite config", function()
            local name = Library.Options.SaveManager_ConfigList.Value
            local success, err = SaveManager:Save(name)
            if not success then
                Library:Notify("Failed to overwrite config: " .. err)
                return
            end
            Library:Notify(string.format("Overwrote config %q", name))
        end)

        ConfigGroupbox:AddButton("Delete config", function()
            local name = Library.Options.SaveManager_ConfigList.Value
            local success, err = SaveManager:Delete(name)
            if not success then
                Library:Notify("Failed to delete config: " .. err)
                return
            end

            Library:Notify(string.format("Deleted config %q", name))
            Library.Options.SaveManager_ConfigList:SetValues(SaveManager:RefreshConfigList())
            Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        ConfigGroupbox:AddButton("Refresh list", function()
            Library.Options.SaveManager_ConfigList:SetValues(SaveManager:RefreshConfigList())
            Library.Options.SaveManager_ConfigList:SetValue(nil)
        end)

        local AutoloadLabel = ConfigGroupbox:AddLabel("Current autoload config: " .. SaveManager:GetAutoloadConfig(), true)

        ConfigGroupbox:AddButton("Set as autoload", function()
            local name = Library.Options.SaveManager_ConfigList.Value
            local success, err = SaveManager:SaveAutoloadConfig(name)
            if not success then
                Library:Notify("Failed to set autoload config: " .. err)
                return
            end

            Library:Notify(string.format("Set %q to auto load", name))
            AutoloadLabel:SetText("Current autoload config: " .. name)
        end)

        ConfigGroupbox:AddButton("Reset autoload", function()
            local success, err = SaveManager:DeleteAutoLoadConfig()
            if not success then
                Library:Notify("Failed to reset autoload config: " .. err)
                return
            end

            Library:Notify("Set autoload to none")
            AutoloadLabel:SetText("Current autoload config: none")
        end)

        local GamesGroupbox = SettingsTab:AddLeftGroupbox("Supported Games", "gamepad-2")
        GamesGroupbox:AddLabel("Here is the list of currently supported games:", true)
        GamesGroupbox:AddDivider()
        GamesGroupbox:AddLabel("Dingus", true)
        GamesGroupbox:AddLabel("Build a Boat for Treasure", true)
        GamesGroupbox:AddLabel("Gender RNG", true)

        local MenuGroup = SettingsTab:AddRightGroupbox("Menu", "wrench")

        MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
            Default = Config.KeybindMenu,
            NoUI = true,
            Text = "Menu keybind",
        })

        MenuGroup:AddButton("Unload", function()
            Library:Unload()
        end)
    end

    install()
end

SaveManager:SetIgnoreIndexes({ "SaveManager_ConfigList", "SaveManager_ConfigName", "MenuKeybind" })

Library.ToggleKeybind = Library.Options.MenuKeybind
ThemeManager:ApplyToTab(SettingsTab)

SaveManager:LoadAutoloadConfig()

local function cleanupAll()
    State.espActive = false
    State.playerEspActive = false
    State.aimTpEnabled = false
    setSpeedBoost(false)
    finishTeleport()

    unwatchContainers()

    if Mountain.shutdown then
        Mountain.shutdown()
    end

    if Move.shutdown then
        Move.shutdown()
    end

    restoreInstantPrompts()

    table.clear(Storage.pendingActions)
    table.clear(Storage.promptRestores)
    table.clear(Storage.claimed)

    if Net.stop then
        Net.stop()
    end

    for _, connection in ipairs(Storage.netConns) do
        if connection then
            connection:Disconnect()
        end
    end
    table.clear(Storage.netConns)

    State.afkRunning = false
    for _, connection in ipairs(Storage.afkConns) do
        if connection then
            connection:Disconnect()
        end
    end
    table.clear(Storage.afkConns)

    if Farm and Farm.stop then
        Farm.stop()
    end

    if Money and Money.stop then
        Money.stop()
    end

    for key, connection in pairs(Connections) do
        if connection then
            connection:Disconnect()
        end
    end
    table.clear(Connections)

    State.speedHooked = nil

    clearRegistry()
    clearPlayerEsp()

    if EspHolder then
        EspHolder:Destroy()
        EspHolder = nil
    end

    State.rootPart = nil
    getgenv().UniverseLoaded = false
    getgenv().UniverseUnload = nil
end

getgenv().UniverseUnload = cleanupAll
Library:OnUnload(cleanupAll)
