--[[ LazyPig -- Auto Illusions (ported from BuffValet)

Auto Illusions (Remove)  LPCONFIG.ILLUSION_REMOVE
  Cancels an "Illusion: ..." buff when it is in the way:
  - picking a destination at a flight master (cancelled before the flight
    request; the request is repeated once if the server still refused it),
  - any "you are shapeshifted" error (mount, item use, spell, NPC talk...).

Auto Illusions (Recast)  LPCONFIG.ILLUSION_RECAST
  Remembers the last illusion on the player. When it is gone (removed by the
  option above, expired, lost on death...) it is put back as soon as possible:
  not on a flight, alive, out of combat, not mounted, not in a form/stealth,
  not casting. Cancelling the illusion yourself (right-click) forgets it.
  An item in the bags with the same name is used, otherwise the spell is cast.

Casting needs a hardware event on the 1.12 client, so after one passive try
the recast is retried on mouse-wheel zoom and target changes (same trick as
SmartBuff / BuffValet).
]]

local PREFIX = "Illusion: "
local PREFIX_LEN = string.len(PREFIX)

local RETRY_DELAY = 1.5       -- seconds between recast attempts (GCD)
local MAX_ATTEMPTS = 8        -- give up after this many hardware attempts
local AFTER_ERROR_DELAY = 15  -- after an error removal, let the player finish the action
local LANDING_DELAY = 1       -- after landing, let the dismount finish
local TAXI_RETRY_AFTER = 0.75 -- repeat the flight request if still grounded
local TAXI_TIMEOUT = 6        -- no take-off after this long: the flight failed

local ErrorShapeshifted = {}
for _, key in pairs({
	"ERR_MOUNT_SHAPESHIFTED", "SPELL_FAILED_NOT_SHAPESHIFT",
	"SPELL_FAILED_NO_ITEMS_WHILE_SHAPESHIFTED", "SPELL_NOT_SHAPESHIFTED",
	"SPELL_NOT_SHAPESHIFTED_NOSPACE", "ERR_TAXIPLAYERSHAPESHIFTED",
	"ERR_CANT_INTERACT_SHAPESHIFTED", "ERR_NO_ITEMS_WHILE_SHAPESHIFTED",
	"ERR_NOT_WHILE_SHAPESHIFTED",
}) do
	local msg = getglobal(key)
	if msg then ErrorShapeshifted[msg] = true end
end

local lastIllusion       -- name of the last illusion seen on the player
local active = false     -- is it on the player right now
local pending = false    -- waiting to be recast
local notBefore = 0      -- no recast before this time
local attempts = 0
local nextTry = 0
local passiveTried = false
local casting = false
local selfCancel = false -- our own CancelPlayerBuff call, not the player's

local taxiState          -- nil | "departing" | "flying"
local taxiDeadline, taxiRetryAt, taxiSlot

local function Tooltip()
	LazyPig_Buff_Tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	return LazyPig_Buff_Tooltip
end

local function BuffName(index)
	Tooltip():SetPlayerBuff(index)
	return LazyPig_Buff_TooltipTextLeft1:GetText()
end

local function IsIllusion(name)
	return name and string.sub(name, 1, PREFIX_LEN) == PREFIX
end

-- Returns buffIndex, name of the illusion on the player, or nil.
local function FindIllusion()
	for i = 0, 31 do
		local index = GetPlayerBuff(i, "HELPFUL")
		if not index or index < 0 then break end
		local name = BuffName(index)
		if IsIllusion(name) then return index, name end
	end
end

local function IsMounted()
	for i = 0, 31 do
		local index = GetPlayerBuff(i, "HELPFUL")
		if not index or index < 0 then break end
		Tooltip():SetPlayerBuff(index)
		if LazyPig_IsMountBuffText(LazyPig_Buff_TooltipTextLeft2:GetText()) then
			return true
		end
	end
	return false
end

-- Druid forms and rogue stealth: a cast would break or fail them.
local function InFormOrStealth()
	if LazyPig_PlayerClass("Warrior") then return false end
	for i = 1, GetNumShapeshiftForms() do
		local _, _, isActive = GetShapeshiftFormInfo(i)
		if isActive then return true end
	end
	return false
end

-- Hooked so a right-click cancel by the player forgets the illusion.
local Original_CancelPlayerBuff = CancelPlayerBuff
CancelPlayerBuff = function(index, a2, a3)
	if not selfCancel and index then
		local ok, name = pcall(BuffName, index)
		if ok and IsIllusion(name) then
			lastIllusion, pending = nil, false
		end
	end
	return Original_CancelPlayerBuff(index, a2, a3)
end

-- Cancels the illusion, returns true if there was one.
function LazyPig_RemoveIllusion(delay)
	local index, name = FindIllusion()
	if not index then return false end
	lastIllusion = name
	selfCancel = true
	CancelPlayerBuff(index)
	selfCancel = false
	notBefore = GetTime() + (delay or 0)
	return true
end

local function Schedule()
	pending = true
	attempts = 0
	nextTry = 0
	passiveTried = false
end

local function OnAurasChanged()
	local _, name = FindIllusion()
	if name then
		lastIllusion, active, pending = name, true, false
	elseif active then
		active = false
		if lastIllusion and LPCONFIG.ILLUSION_RECAST then Schedule() end
	end
end

local function FindBagItem(name)
	local needle = "[" .. name .. "]"
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			if link and string.find(link, needle, 1, true) then
				return bag, slot
			end
		end
	end
end

local function CanRecast(now)
	return LPCONFIG.ILLUSION_RECAST and pending and lastIllusion
		and not casting and not taxiState and now >= notBefore and now >= nextTry
		and not UnitOnTaxi("player") and not UnitIsDeadOrGhost("player")
		and not UnitAffectingCombat("player")
		and not IsMounted() and not InFormOrStealth()
end

local function Recast(hardware)
	local now = GetTime()
	if not CanRecast(now) then return end
	if not hardware then
		if passiveTried then return end
		passiveTried = true
	else
		attempts = attempts + 1
		if attempts > MAX_ATTEMPTS then
			pending = false
			return
		end
	end
	nextTry = now + RETRY_DELAY

	local bag, slot = FindBagItem(lastIllusion)
	if bag then
		UseContainerItem(bag, slot)
	else
		CastSpellByName(lastIllusion, 1)
	end
	if SpellIsTargeting() then SpellTargetUnit("player") end
end

-- Flight master: cancel before the request is sent.
local Original_TakeTaxiNode = TakeTaxiNode
TakeTaxiNode = function(slot)
	local removed = false
	if LPCONFIG.ILLUSION_REMOVE then
		local ok, r = pcall(LazyPig_RemoveIllusion)
		removed = ok and r
	end
	Original_TakeTaxiNode(slot)
	if removed then
		local now = GetTime()
		taxiState = "departing"
		taxiDeadline = now + TAXI_TIMEOUT
		taxiRetryAt = now + TAXI_RETRY_AFTER
		taxiSlot = slot
	end
end

local function UpdateTaxi(now)
	if not taxiState then return end
	local onTaxi = UnitOnTaxi("player")
	if taxiState == "departing" then
		if onTaxi then
			taxiState = "flying"
		elseif taxiRetryAt and now >= taxiRetryAt then
			taxiRetryAt = nil
			if TaxiFrame and TaxiFrame:IsVisible() then Original_TakeTaxiNode(taxiSlot) end
		elseif now >= taxiDeadline then
			taxiState = nil -- never took off: give the illusion back
		end
	elseif not onTaxi then
		taxiState = nil
		notBefore = now + LANDING_DELAY
	end
end

-- Hardware input sources (camera zoom functions are not protected).
local function HookInput(funcName)
	local orig = getglobal(funcName)
	if type(orig) ~= "function" then return end
	setglobal(funcName, function(a1, a2, a3, a4)
		if pending then pcall(Recast, true) end
		return orig(a1, a2, a3, a4)
	end)
end
HookInput("CameraZoomIn")
HookInput("CameraZoomOut")

local frame = CreateFrame("Frame", "LazyPigIllusionsFrame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_AURAS_CHANGED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_CHANNEL_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
frame:RegisterEvent("SPELLCAST_CHANNEL_STOP")

frame:SetScript("OnEvent", function()
	if event == "PLAYER_AURAS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
		OnAurasChanged()
	elseif event == "PLAYER_TARGET_CHANGED" then
		-- Delivered inside the click / Tab press: counts as hardware input.
		if pending then pcall(Recast, true) end
	elseif event == "UI_ERROR_MESSAGE" then
		if LPCONFIG.ILLUSION_REMOVE and ErrorShapeshifted[arg1] then
			LazyPig_RemoveIllusion(AFTER_ERROR_DELAY)
		end
	elseif event == "SPELLCAST_START" or event == "SPELLCAST_CHANNEL_START" then
		casting = true
	else
		casting = false
	end
end)

local elapsedSum = 0
frame:SetScript("OnUpdate", function()
	elapsedSum = elapsedSum + (arg1 or 0)
	if elapsedSum < 0.2 then return end
	elapsedSum = 0
	local now = GetTime()
	UpdateTaxi(now)
	if pending then pcall(Recast, false) end
end)
