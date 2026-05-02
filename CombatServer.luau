-- Connected Discord-GitHub | Discord: cookiesyndrom | Roblox: 03x408

--[[
	CombatServer.lua — Server-side M1 combat handler
	
	This script lives in ServerScriptService and owns all the authoritative
	combat logic: cooldown gating, hitbox projection, damage, knockback, and
	the 3-hit finisher system. Keeping everything server-side means clients
	can never spoof damage or bypass cooldowns — they just fire an event and
	the server decides what actually happens.

	Architecture overview:
	  Client fires "M1" ? server validates ? casts hitbox ? damages targets
	  ? fires back "FINISHER_LOCK" or "KNOCKBACK" to affected clients

	State is stored in plain tables keyed by Player instance. This is safe
	because Player objects are unique and we clean them up on PlayerRemoving,
	so there's no memory leak risk even across long sessions.
--]]

-- --- Services ----------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")
local RunService        = game:GetService("RunService")

-- --- Remote setup ------------------------------------------------------------

-- FindFirstChild first so we don't duplicate if the script hot-reloads in Studio
local CombatEvent = ReplicatedStorage:FindFirstChild("CombatEvent")
if not CombatEvent then
	CombatEvent        = Instance.new("RemoteEvent")
	CombatEvent.Name   = "CombatEvent"
	CombatEvent.Parent = ReplicatedStorage
end

-- --- Assets -------------------------------------------------------------------

local hitSoundTemplate = ReplicatedStorage:WaitForChild("Sounds"):WaitForChild("Hit")

-- --- Tuning constants ---------------------------------------------------------

--[[
	These live at the top so balancing changes never require hunting through
	the logic. HEAVY_KB is intentionally 4x LIGHT_KB — the finisher should
	feel significantly different from a normal swing. FINISHER_LOCK is synced
	client-side too so the UI feedback matches the actual lockout window.
--]]

local DAMAGE         = 10
local HITBOX_SIZE    = Vector3.new(5, 5, 6)   -- width, height, depth in front of player
local HITBOX_REACH   = 3                       -- how far forward the box projects
local LIGHT_KB       = 18
local HEAVY_KB       = 72
local LIGHT_LIFT     = 10
local HEAVY_LIFT     = 25
local COOLDOWN       = 0.35
local FINISHER_LOCK  = 1.2
local COMBO_RESET    = 1.2   -- seconds of inactivity before combo resets to 0
local COMBO_MAX      = 3     -- hit 3 triggers the finisher
local WALK_SLOW      = 6     -- WalkSpeed applied during finisher lockout
local WALK_NORMAL    = 16

-- --- Metatable-based player state --------------------------------------------

--[[
	Instead of juggling three separate tables (lastAttack, combo, locked),
	a metatable with __index gives each player a fresh default state object
	the first time we access it. This keeps all per-player data in one place
	and the __newindex guard prevents silent typos from creating garbage keys.
--]]

local PlayerState = {}
PlayerState.__index = PlayerState

function PlayerState.new()
	return setmetatable({
		lastAttack  = 0,     -- os.clock() timestamp of last accepted swing
		combo       = 0,     -- current hit in the 1-2-3 sequence
		locked      = false, -- true during finisher lockout window
		resetThread = nil,   -- reference to the active combo-reset task
	}, PlayerState)
end

-- central store: Player ? state object, auto-constructed on first access
local stateStore = setmetatable({}, {
	__index = function(t, player)
		local s = PlayerState.new()
		rawset(t, player, s)
		return s
	end,
})

-- --- Cooldown validation ------------------------------------------------------

--[[
	This is the authoritative gate. os.clock() is monotonic and server-local
	so it can't be manipulated from the client. We also check the finisher
	lock here so a spamming client can't land hits during the animation.
--]]

local function canAttack(state)
	if state.locked then return false end
	if os.clock() - state.lastAttack < COOLDOWN then return false end
	state.lastAttack = os.clock()
	return true
end

-- --- Combo tracking -----------------------------------------------------------

--[[
	Advances the combo counter and reschedules the reset timer. The key detail
	is task.cancel on the previous thread — without this, rapid clicks stack
	up multiple reset timers that fight each other and cause the combo to drop
	mid-sequence. One active timer per player at all times.
--]]

local function advanceCombo(state)
	state.combo = state.combo >= COMBO_MAX and 1 or state.combo + 1

	if state.resetThread then
		task.cancel(state.resetThread)
	end

	state.resetThread = task.delay(COMBO_RESET, function()
		state.combo       = 0
		state.resetThread = nil
	end)

	return state.combo
end

-- --- Hitbox projection --------------------------------------------------------

--[[
	We create a real Part so Studio's debug rendering can show us where the
	box actually is during testing. In production you'd flip Transparency to 1.
	The CFrame offsets the box forward along the attacker's look vector so it
	sits in front of them rather than centered on their root.

	OverlapParams excludes the attacker's own character so they can never
	accidentally hit themselves (e.g. if they walk into their own hitbox edge).
--]]

local function projectHitbox(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return {} end

	local boxCFrame = root.CFrame * CFrame.new(0, 0, -HITBOX_REACH)

	-- debug box — set Transparency = 1 when shipping
	local box        = Instance.new("Part")
	box.Size         = HITBOX_SIZE
	box.CFrame       = boxCFrame
	box.Anchored     = true
	box.CanCollide   = false
	box.Transparency = 0.5
	box.Material     = Enum.Material.ForceField
	box.Color        = Color3.fromRGB(255, 50, 50)
	box.Parent       = workspace
	Debris:AddItem(box, 0.12)

	local params = OverlapParams.new()
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character}

	return workspace:GetPartBoundsInBox(boxCFrame, HITBOX_SIZE, params), root
end

-- --- Hit sound ----------------------------------------------------------------

--[[
	Cloning the template and using task.defer means the sound is fully parented
	before Play() is called. Without the defer, Play() sometimes fires before
	the engine registers the new parent and the sound silently does nothing —
	this was the original bug causing inconsistent hit audio.
--]]

local function spawnHitSound(root)
	if not root then return end
	local snd = hitSoundTemplate:Clone()
	snd.RollOffMaxDistance = 60
	snd.Parent = root
	task.defer(function()
		if snd.Parent then snd:Play() end
	end)
	Debris:AddItem(snd, 3)
end

-- --- Knockback ----------------------------------------------------------------

--[[
	Roblox network ownership means the client who owns a character's physics
	simulation will immediately override any velocity the server sets. So we
	set it server-side as a best effort (works when server owns physics, e.g
	Npcs or remote players briefly) AND fire a KNOCKBACK event to the target's
	own client so they apply it locally where it's guaranteed to stick.

	The direction guard handles the edge case where attacker and target share
	the exact same position (magnitude = 0 ? Unit would return NaN).
--]]

local function applyKnockback(targetRoot, attackerRoot, isHeavy)
	if not targetRoot or not attackerRoot then return end

	local diff = targetRoot.Position - attackerRoot.Position
	local dir  = diff.Magnitude > 0 and diff.Unit or attackerRoot.CFrame.LookVector

	local horizontal = isHeavy and HEAVY_KB   or LIGHT_KB
	local vertical   = isHeavy and HEAVY_LIFT or LIGHT_LIFT
	local velocity   = dir * horizontal + Vector3.new(0, vertical, 0)

	-- server-side attempt (catches NPCs and server-owned parts)
	targetRoot.AssemblyLinearVelocity = velocity

	-- authoritative client-side application for player-owned physics
	local targetPlayer = Players:GetPlayerFromCharacter(targetRoot.Parent)
	if targetPlayer then
		CombatEvent:FireClient(targetPlayer, "KNOCKBACK", velocity)
	end
end

-- --- Damage pass -------------------------------------------------------------

--[[
	We collect unique models first (hitModels guard) so a single swing can't
	hit the same character twice if multiple of their parts are inside the box.
	Dead humanoids are skipped — no point damaging a ragdoll, and TakeDamage
	on Health = 0 can occasionally trigger unexpected Died connections.
--]]

local function processDamage(parts, character, attackerRoot, isHeavy)
	local hitModels = {}

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if not model or model == character or hitModels[model] then continue end
		hitModels[model] = true

		local humanoid   = model:FindFirstChildOfClass("Humanoid")
		local targetRoot = model:FindFirstChild("HumanoidRootPart")

		if not humanoid or humanoid.Health <= 0 then continue end

		humanoid:TakeDamage(DAMAGE)
		spawnHitSound(targetRoot)
		applyKnockback(targetRoot, attackerRoot, isHeavy)
	end
end

-- --- Finisher lockout ---------------------------------------------------------

--[[
	On the 3rd hit we want the attacker briefly stuck in place — this sells
	the weight of the finisher animation. We slow WalkSpeed, set locked = true
	so canAttack() rejects further inputs, and fire the client so their UI
	and local canM1 flag sync up. The delay restores everything after the
	FINISHER_LOCK window expires.
--]]

local function triggerFinisher(player, character, state)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	state.locked   = true

	if humanoid then humanoid.WalkSpeed = WALK_SLOW end
	CombatEvent:FireClient(player, "FINISHER_LOCK")

	task.delay(FINISHER_LOCK, function()
		state.locked = false
		-- re-check humanoid in case they died or respawned during the window
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			hum.WalkSpeed = WALK_NORMAL
		end
	end)
end

-- --- Main attack handler ------------------------------------------------------

--[[
	All the pieces come together here. Order matters: validate first so we
	bail early on spam then advance combo (which has its own reset timer),
	then cast the hitbox then check if this swing is the finisher. We don't
	know if it's a finisher until after advanceCombo() returns the new step.
--]]

local function handleAttack(player)
	local character = player.Character
	if not character then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local state = stateStore[player]
	if not canAttack(state) then return end

	local step     = advanceCombo(state)
	local isHeavy  = step == COMBO_MAX
	local parts, _ = projectHitbox(character)

	processDamage(parts, character, root, isHeavy)

	if isHeavy then
		triggerFinisher(player, character, state)
	end
end

-- --- Remote listener ---------------------------------------------------------

CombatEvent.OnServerEvent:Connect(function(player, action)
	if action == "M1" then
		handleAttack(player)
	end
end)

-- --- Cleanup -----------------------------------------------------------------

--[[
	Cancel any pending combo reset thread so we don't get a dangling task
	trying to write to a state object we're about to garbage collect.
	The stateStore entry itself will be collected once the Player reference
	is gone but explicit nil keeps things tidy.
--]]

Players.PlayerRemoving:Connect(function(player)
	local state = rawget(stateStore, player)
	if state then
		if state.resetThread then
			task.cancel(state.resetThread)
		end
		stateStore[player] = nil
	end
end)