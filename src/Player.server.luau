local Players = game:GetService("Players")

local ReplicatedInstanceId = require(script.Parent)

local function onPlayerAdded(player: Player)
	ReplicatedInstanceId.AssignId(player)
end

for i, plr in Players:GetPlayers() do
	onPlayerAdded(plr)
end
Players.PlayerAdded:Connect(onPlayerAdded)