-- Refuse to load beside stock PallyPower: both define the same globals and frames.
PALLYPOWER_KRONOS_BLOCKED = nil
local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
if isLoaded("PallyPower") then
	PALLYPOWER_KRONOS_BLOCKED = true
	disable("PallyPower")
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function()
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040PallyPower Kronos:|r the old PallyPower addon is still installed and has been disabled. Delete Interface\\AddOns\\PallyPower and type /reload.")
	end)
end
