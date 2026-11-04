if not game:IsLoaded() then
    game.Loaded:Wait()
end

local HttpService = game:GetService("HttpService")

local WorkerURL = "https://mm2-whitelist.oren-sincock.workers.dev"
local Key = getgenv().Key

if type(Key) ~= "string" or Key == "" then
    return
end

local Success, Result = pcall(request, {
    Url = WorkerURL .. "/activate",
    Method = "POST",
    Headers = {
        ["Content-Type"] = "application/json"
    },
    Body = HttpService:JSONEncode({
        key = Key,
        hwid = gethwid()
    })
})

if not Success or not Result or Result.StatusCode ~= 200 then
    return
end

Success, Result = pcall(function()
    return HttpService:JSONDecode(Result.Body)
end)

if not Success or not Result or not Result.success then
    return
end

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

for _, connection in getconnections(LocalPlayer.Idled) do
    connection:Disable()
end

repeat
    task.wait()
until LocalPlayer:GetAttribute("ClientLoaded") and LocalPlayer:GetAttribute("DataLoaded")

local PlayerGui = LocalPlayer.PlayerGui

local CurrentRoundClient = require(ReplicatedStorage.Modules.CurrentRoundClient)
local Sync = require(ReplicatedStorage.Database.Sync)
local ProfileData = require(ReplicatedStorage.Modules.ProfileData)

local Shop = ReplicatedStorage.Remotes.Shop

local autoFarm = getgenv().Config["AutoFarm"]
local weaponTracker = getgenv().Config["New Weapon Tracker"]
local autoBuy = getgenv().Config["Auto Buy"]

local speed = autoFarm.Speed
local depth = autoFarm.Depth

local noclipConnection
local noclipParts = {}

local function getRoot()
    local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

    return Character:WaitForChild("HumanoidRootPart", 5)
end

local function inRound()
    local roundData = CurrentRoundClient.PlayerData
    local playerData = roundData and roundData[LocalPlayer.Name]

    return playerData ~= nil and not playerData.Dead and not playerData.Killed
end

local function getMap()
    for _, model in Workspace:GetChildren() do
        if model:IsA("Model") and model:GetAttribute("MapID") then
            return model
        end
    end

    return nil
end

local function getCoinContainer()
    local map = getMap()

    return map and map:FindFirstChild("CoinContainer")
end

local function coinsStarted()
    local coinContainer = getCoinContainer()
    local timerPart = Workspace:FindFirstChild("RoundTimerPart")

    return coinContainer ~= nil and timerPart ~= nil and timerPart:GetAttribute("Time") ~= -1 and #coinContainer:GetChildren() > 0
end

local function canFarm()
    return inRound() and coinsStarted()
end

local function bagFull()
    local mainGui = PlayerGui:FindFirstChild("MainGUI")
    local container = mainGui and mainGui:FindFirstChild("Game") and mainGui.Game:FindFirstChild("CoinBags") and mainGui.Game.CoinBags:FindFirstChild("Container")

    if not container then
        return false
    end

    for _, bag in container:GetChildren() do
        if bag:IsA("Frame") then
            local full = bag:FindFirstChild("Full")

            if full and full.Visible then
                return true
            end
        end
    end

    return false
end

local function getClosestCoin()
    if not canFarm() then
        return
    end

    local root = getRoot()
    local coinContainer = getCoinContainer()

    if not root or not root.Parent or not coinContainer then
        return
    end

    local closestDistance = math.huge
    local closestCoin

    for _, coin in coinContainer:GetChildren() do
        local coinVisual = coin:FindFirstChild("CoinVisual")

        if coinVisual and coinVisual.Transparency == 0 then
            local distance = (root.Position - coin.Position).Magnitude

            if distance < closestDistance then
                closestDistance = distance
                closestCoin = coin
            end
        end
    end

    return closestCoin
end

local function setNoclip(enabled)
    if enabled then
        if noclipConnection then
            return
        end

        noclipConnection = RunService.Stepped:Connect(function()
            local Character = LocalPlayer.Character

            if not Character then
                return
            end

            for _, part in Character:GetDescendants() do
                if part:IsA("BasePart") then
                    if noclipParts[part] == nil then
                        noclipParts[part] = part.CanCollide
                    end

                    if part.CanCollide then
                        part.CanCollide = false
                    end
                end
            end
        end)
    else
        if not noclipConnection then
            return
        end

        noclipConnection:Disconnect()
        noclipConnection = nil

        for part, canCollide in noclipParts do
            if part.Parent then
                part.CanCollide = canCollide
            end
        end

        table.clear(noclipParts)
    end
end

local function setPlatformStand(enabled)
    local Humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")

    if Humanoid and Humanoid.PlatformStand ~= enabled then
        Humanoid.PlatformStand = enabled
    end
end

local function resetCharacter()
    local oldCharacter = LocalPlayer.Character
    local Humanoid = oldCharacter and oldCharacter:FindFirstChildOfClass("Humanoid")

    if Humanoid then
        Humanoid.Health = 0
    end

    local startTime = os.clock()

    repeat
        task.wait(0.25)
    until LocalPlayer.Character ~= oldCharacter or os.clock() - startTime > 10
end

local function collectCoin(coin)
    local visual = coin:FindFirstChild("CoinVisual")
    local root = getRoot()

    if not visual or not root then
        return
    end

    local startPosition = root.Position
    local offset = coin.Position - Vector3.new(0, depth, 0) - startPosition
    local travelled = 0
    local deadline = os.clock() + 10

    while visual.Parent and visual.Transparency == 0 and canFarm() and not bagFull() and os.clock() < deadline do
        local delta = task.wait()

        root = getRoot()

        if not coin.Parent or not root or not root.Parent then
            break
        end

        travelled = math.min(travelled + speed * delta, offset.Magnitude)
        root.CFrame = CFrame.new(startPosition + (offset.Magnitude > 0 and offset.Unit or Vector3.zero) * travelled)
        root.AssemblyLinearVelocity = Vector3.zero

        firetouchinterest(root, coin, true)
        firetouchinterest(root, coin, false)
    end
end

local function getImage(assetId)
    local response = request({
        Url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. assetId .. "&size=420x420&format=Png&isCircular=false"
    })

    if response.Success then
        local thumbnail = HttpService:JSONDecode(response.Body).data[1]

        return thumbnail and thumbnail.imageUrl
    end
end

local function sendWebhook(itemId, boxId)
    local item = Sync.Weapons[itemId]
    local imageUrl = getImage(item.ItemID)

    request({
        Url = weaponTracker.WebhookURL,
        Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = HttpService:JSONEncode({
            embeds = {{
                description = "**You unboxed a " .. item.Rarity .. " " .. item.ItemType .. "!**\n\n"
                    .. ":package: **Item Info:**\n"
                    .. "> **Item:** `" .. item.ItemName .. "`\n"
                    .. "> **Rarity:** `" .. item.Rarity .. "`\n"
                    .. "> **Box:** `" .. Sync.MysteryBox[boxId].Name .. "`\n\n"
                    .. ":person_frowning: **User Info:**\n"
                    .. "> **User:** ||" .. LocalPlayer.Name .. "||\n"
                    .. "> **In Inventory:** `" .. tostring(ProfileData.Weapons.Owned[itemId]) .. "`",
                color = tonumber(Sync.Rarity[item.Rarity]:ToHex(), 16),
                footer = {text = "Mm2 AutoFarm | " .. os.date("%d/%m/%Y %H:%M")},
                thumbnail = imageUrl and {url = imageUrl}
            }}
        })
    })
end

local function canAfford(boxId)
    local box = Sync.NewShop[boxId]

    if not box or box.Type ~= "MysteryBox" then
        return
    end

    for currency, price in box.Price do
        local balance = ProfileData.Materials.Owned[currency] or 0

        if not currency:find("Gems") and not currency:find("Key") and balance >= price then
            return currency
        end
    end
end

local function buyBox(boxId)
    local currency = canAfford(boxId)

    if not currency then
        return
    end

    local success, itemId = Shop.OpenCrate:InvokeServer(boxId, "MysteryBox", currency)

    if success and itemId then
        Shop.BoxController:Fire({
            {
                MysteryBoxId = boxId,
                RewardedItemId = itemId
            }
        })

        if weaponTracker.Enabled then
            task.spawn(sendWebhook, itemId, boxId)
        end
    end
end

if autoBuy.Enabled then
    task.spawn(function()
        while task.wait(1) do
            for boxId, enabled in autoBuy.Boxes do
                if enabled then
                    buyBox(boxId)
                end
            end
        end
    end)
end

if autoFarm.Enabled then
    task.spawn(function()
        local farming = false

        while task.wait() do
            local success, result = pcall(function()
                if canFarm() then
                    if not farming then
                        setNoclip(true)
                        setPlatformStand(true)
                        farming = true
                    end

                    if bagFull() then
                        resetCharacter()
                    else
                        local coin = getClosestCoin()

                        if coin then
                            collectCoin(coin)
                        end
                    end
                elseif farming then
                    setNoclip(false)
                    setPlatformStand(false)
                    farming = false
                end
            end)

            if not success then
                task.wait(1)
            end
        end
    end)
end
