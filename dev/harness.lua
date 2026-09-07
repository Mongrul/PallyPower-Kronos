-- Mock-WoW harness: executes the 1.12 PallyPower build under desktop Lua and
-- simulates login, group, events, and UI interaction to surface runtime errors.
-- Run: lua harness.lua <path-to-PallyPower112.lua>

-- ---- Lua 5.0 compat shims (the addon targets WoW 1.12's Lua 5.0) ----
string.gfind = string.gmatch
math.mod = math.fmod
table.getn = function(t) return #t end
tinsert = table.insert
tremove = table.remove

-- ---- frame/region mock ----
frames = {}
registered = {}

local regionMeta
local function newRegion(kind, name, parent)
	local r = {
		__kind = kind, __name = name, __parent = parent, __shown = true,
		__scripts = {}, __checked = nil, __value = 0, __loading = nil,
	}
	setmetatable(r, regionMeta)
	if name then _G[name] = r end
	return r
end

local special = {}
special.SetScript = function(self, ev, fn) self.__scripts[ev] = fn end
special.GetScript = function(self, ev) return self.__scripts[ev] end
special.Show = function(self)
	self.__shown = true
	local function fireShow(r)
		if r.__scripts.OnShow then
			local prev = this
			this = r
			r.__scripts.OnShow()
			this = prev
		end
		for _, f in ipairs(frames) do
			if f.__parent == r then fireShow(f) end
		end
	end
	fireShow(self)
end
special.Hide = function(self) self.__shown = false end
special.IsVisible = function(self) return self.__shown or nil end
special.CreateTexture = function(self, name, layer) return newRegion("Texture", name, self) end
special.CreateFontString = function(self, name, layer) return newRegion("FontString", name, self) end
special.RegisterEvent = function(self, ev)
	registered[ev] = registered[ev] or {}
	table.insert(registered[ev], self)
end
special.SetText = function(self, t) self.__text = t end
special.GetText = function(self) return self.__text end
special.SetPoint = function(self) self.__anchored = true end
special.ClearAllPoints = function(self) self.__anchored = false end
special.SetAllPoints = function(self) self.__anchored = true end
special.SetChecked = function(self, v) self.__checked = v end
special.GetChecked = function(self) return self.__checked end
special.SetValue = function(self, v)
	self.__value = v
	if self.__scripts.OnValueChanged then
		local prev = this
		this = self
		self.__scripts.OnValueChanged()
		this = prev
	end
end
special.GetValue = function(self) return self.__value end
special.GetLeft = function() return 100 end
special.GetTop = function() return 500 end
special.GetRight = function() return 200 end
special.GetBottom = function() return 400 end
special.GetEffectiveScale = function() return 1 end
special.GetName = function(self) return self.__name end

regionMeta = {
	__index = function(t, k)
		local f = special[k]
		if f then return f end
		local m = function() end
		rawset(t, k, m)
		return m
	end,
}

function CreateFrame(kind, name, parent)
	local f = newRegion(kind, name, parent)
	table.insert(frames, f)
	return f
end

-- ---- WoW API stubs ----
UIParent = newRegion("Frame", "UIParent")
GameTooltip = newRegion("GameTooltip", "GameTooltip")
UIErrorsFrame = newRegion("MessageFrame", "UIErrorsFrame")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) print("[chat] " .. tostring(msg)) end }
GameFontHighlightSmall = {}
GameFontHighlight = {}
GameFontNormal = {}
GameFontNormalSmall = {}
UNKNOWNOBJECT = "Unknown"
BOOKTYPE_SPELL = "spell"
SlashCmdList = {}

local group = {
	player = {name = "Testpally", class = "PALADIN"},
	party1 = {name = "Tanky", class = "WARRIOR"},
	party2 = {name = "Maggie", class = "MAGE"},
	partypet2 = {name = "Fluffy", class = "MAGE"},
}
function UnitExists(u) return group[u] ~= nil end
function UnitName(u) return group[u] and group[u].name end
function UnitClass(u)
	if not group[u] then return nil end
	return group[u].class, group[u].class
end
function GetNumRaidMembers() return 0 end
function GetNumPartyMembers() return 2 end
hiddenUnits = {}
function UnitIsVisible(u)
	if hiddenUnits[u] then return nil end
	return 1
end
function UnitIsConnected(u) return 1 end
function UnitIsDeadOrGhost(u) return nil end
function UnitIsPartyLeader(u) return u == "party1" end
function IsRaidLeader() return nil end
function IsRaidOfficer() return nil end
function IsPartyLeader() return nil end
function GetRaidRosterInfo(i) return nil end

local buffs = {}  -- [unit] = {texture, ...}
function UnitBuff(u, i)
	local list = buffs[u]
	return list and list[i]
end

local now = 1000
function GetTime() return now end

sent = {}
function SendAddonMessage(prefix, msg, chan)
	-- 1.12's real SendAddonMessage rejects bare "|" (invalid escape code)
	assert(not string.find(msg, "|", 1, true),
		"outgoing addon message contains '|' which 1.12 rejects: " .. msg)
	-- NASSIGN and pet-class ASSIGNs must bypass the proxy on the second prefix
	if string.find(msg, "^NASSIGN") or string.find(msg, "^ASSIGN %S+ 9 ")
		or string.find(msg, "^ASELF") or string.find(msg, "^FREEASSIGN") then
		assert(prefix == "PLPWRX", "proxy-bypass message on wrong prefix: " .. msg)
	else
		assert(prefix == "PLPWR", "unexpected prefix " .. prefix .. " for: " .. msg)
	end
	table.insert(sent, chan .. ": " .. msg)
end
function SendChatMessage(msg, chan)
	table.insert(sent, "CHAT " .. tostring(chan) .. ": " .. tostring(msg))
end

local spellbook = {
	{"Blessing of Might", "Rank 7"},
	{"Greater Blessing of Might", "Rank 2"},
	{"Blessing of Wisdom", "Rank 6"},
	{"Greater Blessing of Wisdom", "Rank 2"},
	{"Blessing of Kings", ""},
	{"Greater Blessing of Kings", ""},
	{"Blessing of Salvation", ""},
	{"Blessing of Light", "Rank 3"},
	{"Holy Light", "Rank 9"},
	{"Lay on Hands", "Rank 2"},
	{"Divine Intervention", ""},
	{"Devotion Aura", "Rank 5"},
	{"Retribution Aura", "Rank 3"},
}
function GetSpellCooldown(slot, book) return 0, 0, 1 end
time = os.time
function UnitIsFriend(a, b) return 1 end
function CheckInteractDistance(u, i) return 1 end
function ClearTarget() end
function TargetLastTarget() end
function GetSpellName(i, book)
	local s = spellbook[i]
	if s then return s[1], s[2] end
end
function GetNumTalentTabs() return 3 end
function GetNumTalents(t) return 2 end
function GetTalentInfo(t, i)
	if t == 1 and i == 1 then return "Improved Blessing of Might", "", 0, 0, 5, 5 end
	return "Consecration", "", 0, 0, 1, 5
end
function GetContainerNumSlots(bag) return 4 end
function GetContainerItemLink(bag, slot)
	if bag == 0 and slot == 1 then return "|Hitem:21177|h[Symbol of Kings]|h" end
	return nil
end
function GetContainerItemInfo(bag, slot) return "tex", 20, nil end
function GetCVar(k) return "1" end
function SetCVar(k, v) end
castCount = 0
lastCastSlot = nil
function CastSpell(id, book)
	castCount = castCount + 1
	lastCastSlot = id
end
function SpellIsTargeting() return false end
function SpellCanTargetUnit(u) return false end
function SpellTargetUnit(u) end
function SpellStopTargeting() end
shiftDown = nil
function IsShiftKeyDown() return shiftDown end
function GetCursorPosition() return 0, 0 end
function MouseIsOver(f) return nil end

NONE = "None"
menuItems = {}
lastDropDownFrame = nil
function UIDropDownMenu_AddButton(info, level)
	level = level or UIDROPDOWNMENU_MENU_LEVEL or 1
	menuItems[level] = menuItems[level] or {}
	table.insert(menuItems[level], info)
end
function ToggleDropDownMenu(level, value, frame, anchor, x, y)
	menuItems = {}
	UIDROPDOWNMENU_MENU_LEVEL = level or 1
	UIDROPDOWNMENU_MENU_VALUE = value
	lastDropDownFrame = frame
	assert(frame and frame.initialize, "dropdown host frame has no initialize")
	frame.initialize()
end
function CloseDropDownMenus() end

AURAADDEDOTHERHELPFUL = "%s gains %s."
AURAADDEDSELFHELPFUL = "You gain %s."
AURAREMOVEDOTHER = "%s fades from %s."
AURAREMOVEDSELF = "%s fades from you."

-- ---- helpers to drive the addon ----
local function fire(ev, a1, a2, a3, a4)
	event = ev
	arg1, arg2, arg3, arg4 = a1, a2, a3, a4
	for _, f in ipairs(registered[ev] or {}) do
		if f.__scripts.OnEvent then
			this = f
			f.__scripts.OnEvent()
		end
	end
end

local function tick(n, dt)
	for _ = 1, (n or 1) do
		now = now + (dt or 0.5)
		for _, f in ipairs(frames) do
			if f.__scripts.OnUpdate and f.__shown then
				this = f
				arg1 = dt or 0.5
				f.__scripts.OnUpdate()
			end
		end
	end
end

local function click(name, button)
	local f = _G[name]
	assert(f, "no frame named " .. name)
	if f.__scripts.OnClick then
		this = f
		arg1 = button or "LeftButton"
		f.__scripts.OnClick()
	end
end

local function wheel(name, delta)
	local f = _G[name]
	assert(f, "no frame named " .. name)
	if f.__scripts.OnMouseWheel then
		this = f
		arg1 = delta or 1
		f.__scripts.OnMouseWheel()
	end
end

local function enter(name)
	local f = _G[name]
	assert(f, "no frame named " .. name)
	if f.__scripts.OnEnter then
		this = f
		f.__scripts.OnEnter()
	end
end

-- ---- run ----
local path = arg and arg[1]
assert(path, "usage: lua harness.lua <PallyPower112.lua>")

local step = "loading file"
local function run(desc, fn)
	step = desc
	local ok, err = pcall(fn)
	if not ok then
		print("FAIL at [" .. desc .. "]: " .. tostring(err))
		os.exit(1)
	end
	print("ok: " .. desc)
end

local mode = arg and arg[2] or "login"
run("load file", function() dofile(path) end)
run("VARIABLES_LOADED", function() fire("VARIABLES_LOADED") end)
if mode == "pew" then
	-- /reload path: no PLAYER_LOGIN, only PLAYER_ENTERING_WORLD
	run("PLAYER_ENTERING_WORLD", function() fire("PLAYER_ENTERING_WORLD") end)
else
	run("PLAYER_LOGIN", function() fire("PLAYER_LOGIN") end)
end
run("SPELLS_CHANGED", function() fire("SPELLS_CHANGED") end)
run("PARTY_MEMBERS_CHANGED", function() fire("PARTY_MEMBERS_CHANGED") end)
run("scan ticks", function() tick(30, 0.5) end)
run("open config (/pp)", function() SlashCmdList["PALLYPOWER"]("") end)
run("update ticks with config open", function() tick(5, 1.0) end)
run("incoming SELF (old 1.12 wire format)", function()
	-- old order: Wis Might Salv Light Kings Sanct; 8 old-class assign digits
	fire("CHAT_MSG_ADDON", "PLPWR", "SELF 6275103010nn@n4nnnnnn", "PARTY", "Tanky")
end)
run("incoming NASSIGN on PLPWRX (proxy bypass)", function()
	fire("CHAT_MSG_ADDON", "PLPWRX", "NASSIGN Tanky 1 Tanky 6", "PARTY", "Tanky")
	assert(PallyPowerKronos_NormalAssignments["Tanky"][1]["Tanky"] == 6, "PLPWRX NASSIGN not applied")
end)
run("incoming NASSIGN on legacy PLPWR still accepted", function()
	fire("CHAT_MSG_ADDON", "PLPWR", "NASSIGN Tanky 1 Tanky 3", "PARTY", "Tanky")
	assert(PallyPowerKronos_NormalAssignments["Tanky"][1]["Tanky"] == 3, "PLPWR NASSIGN not applied")
end)
run("incoming ASELF stores aura info", function()
	fire("CHAT_MSG_ADDON", "PLPWRX", "ASELF 5231nnnnnnnnnn@0", "PARTY", "Tanky")
	local ai = AllPallys["Tanky"].AuraInfo
	assert(ai and ai[1] and ai[1].rank == 5 and ai[1].talent == 2, "Devotion rank/talent wrong")
	assert(ai[2] and ai[2].rank == 3 and ai[2].talent == 1, "Retribution rank/talent wrong")
end)
run("incoming COOLDOWNS stores expiry", function()
	fire("CHAT_MSG_ADDON", "PLPWR", "FREEASSIGN YES SYMCOUNT 5 COOLDOWNS:3600:1200:600:0", "PARTY", "Tanky")
	local cd = AllPallys["Tanky"].CooldownInfo
	assert(cd and cd[1] and cd[1].expire > GetTime() + 1000, "LoH cooldown not stored")
	assert(cd[2] and cd[2].expire <= GetTime(), "DI should be ready")
end)
run("REQ answer includes ASELF and real COOLDOWNS", function()
	tick(8, 0.5)
	local before = #sent
	fire("CHAT_MSG_ADDON", "PLPWR", "REQ", "PARTY", "Tanky")
	local sawAself, sawCd
	for i = before + 1, #sent do
		if string.find(sent[i], "^PARTY: ASELF ") then sawAself = sent[i] end
		if string.find(sent[i], "COOLDOWNS:3600:0:3600:0") then sawCd = true end
	end
	assert(sawAself, "no ASELF broadcast")
	assert(sawCd, "cooldowns not included (LoH + DI known and ready)")
end)
run("incoming pet ASSIGN on PLPWRX uses modern ids", function()
	fire("CHAT_MSG_ADDON", "PLPWRX", "ASSIGN Tanky 9 3", "PARTY", "Tanky")
	assert(PallyPowerKronos_Assignments["Tanky"][9] == 3, "tunneled pet assignment not applied")
end)
run("own pet assignment broadcasts on PLPWRX", function()
	tick(8, 0.5) -- clear the send-dedupe window
	local before = #sent
	wheel("PallyPowerBar112Class9", -1)
	local found
	for i = before + 1, #sent do
		if string.find(sent[i], "ASSIGN Testpally 9 %d") then found = sent[i] end
	end
	assert(found, "no tunneled pet ASSIGN sent (got none)")
end)
run("SELF is followed by a pet assignment repair", function()
	PallyPowerKronos_Assignments["Testpally"][9] = 2
	tick(8, 0.5) -- clear the send-dedupe window
	local before = #sent
	fire("CHAT_MSG_ADDON", "PLPWR", "REQ", "PARTY", "Tanky")
	local sawSelf, sawPet
	for i = before + 1, #sent do
		if string.find(sent[i], "SELF ") then sawSelf = true end
		if string.find(sent[i], "ASSIGN Testpally 9 2") then sawPet = true end
	end
	assert(sawSelf, "no SELF sent on REQ")
	assert(sawPet, "pet assignment not re-sent after SELF")
end)
run("incoming REQ", function()
	fire("CHAT_MSG_ADDON", "PLPWR", "REQ", "PARTY", "Tanky")
end)
run("combat log gain", function()
	fire("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "Tanky gains Greater Blessing of Might.")
end)
run("combat log fade", function()
	fire("CHAT_MSG_SPELL_AURA_GONE_PARTY", "Greater Blessing of Might fades from Tanky.")
end)
run("BAG_UPDATE", function() fire("BAG_UPDATE") end)
run("bar: wheel class assignment", function()
	wheel("PallyPowerBar112Class1", -1)
	wheel("PallyPowerBar112Class1", -1)
end)
run("bar: click class button", function() click("PallyPowerBar112Class1") end)
run("bar: click always casts even when everyone is buffed", function()
	-- assign Might to warriors and mark Tanky as already carrying it; the
	-- click must still attempt a cast (override), never report "nobody needs"
	PallyPowerKronos_Assignments["Testpally"][1] = 2
	buffs.party1 = {"Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"}
	tick(25, 0.5) -- let a scan pick up the buff
	castCount = 0
	click("PallyPowerBar112Class1")
	assert(castCount > 0, "click was blocked while everyone was buffed")
	buffs.party1 = nil
end)
run("bar: class click ignores personal assignment (casts greater)", function()
	-- class assignment Might; Tanky has a PERSONAL Light assignment.
	-- Left-clicking the class button must cast GREATER Might (book slot 2),
	-- not the personal 5-min Light - the 1.14 spell1/spell2 split.
	PallyPowerKronos_Assignments["Testpally"][1] = 2
	PallyPowerKronos_NormalAssignments["Testpally"] = PallyPowerKronos_NormalAssignments["Testpally"] or {}
	PallyPowerKronos_NormalAssignments["Testpally"][1] = PallyPowerKronos_NormalAssignments["Testpally"][1] or {}
	PallyPowerKronos_NormalAssignments["Testpally"][1]["Tanky"] = 5
	tick(25, 0.5)
	lastCastSlot = nil
	click("PallyPowerBar112Class1")
	assert(lastCastSlot == 2, "expected Greater Might (book slot 2), got slot " .. tostring(lastCastSlot))
	PallyPowerKronos_NormalAssignments["Testpally"][1]["Tanky"] = nil
end)
run("bar: hover shows popup", function() enter("PallyPowerBar112Class1") end)
run("popup: wheel personal assignment", function() wheel("PallyPowerPopup112Row1", 1) end)
run("popup: left-click casts greater", function() click("PallyPowerPopup112Row1") end)
run("popup: right-click casts lesser", function() click("PallyPowerPopup112Row1", "RightButton") end)
run("config: cell cycle + clear", function()
	click("PallyPowerConfig112P1C1")
	wheel("PallyPowerConfig112P1C1", -1)
	click("PallyPowerConfig112P1C1", "RightButton")
	enter("PallyPowerConfig112P1C1")
end)
run("config: shift-click cycles own row", function()
	-- row 2 is "Testpally" (own row; row 1 "Tanky" is correctly CanControl-blocked)
	shiftDown = 1
	local before = #sent
	click("PallyPowerConfig112P2C1")
	shiftDown = nil
	local found
	for i = before + 1, #sent do
		if string.find(sent[i], "MASSIGN Testpally") then found = sent[i] end
	end
	assert(found, "no MASSIGN sent by shift-click")
	-- old wire: -1 means "none"; any 0-5 digit is a real blessing
	assert(not string.find(found, "MASSIGN %S+ %-1$"), "shift-click did not advance the blessing: " .. found)
end)
run("config: shift-wheel cycles own row", function()
	shiftDown = 1
	wheel("PallyPowerConfig112P2C1", -1)
	shiftDown = nil
end)
run("config: shift-click on uncontrolled row is blocked", function()
	-- an earlier test set Tanky's freeassign (which rightly grants control);
	-- clear it so this test exercises the blocked path
	fire("CHAT_MSG_ADDON", "PLPWR", "FREEASSIGN NO SYMCOUNT 5 COOLDOWNS:n:n:n:n", "PARTY", "Tanky")
	shiftDown = 1
	local before = #sent
	click("PallyPowerConfig112P1C1")
	shiftDown = nil
	for i = before + 1, #sent do
		assert(not string.find(sent[i], "MASSIGN Tanky"), "edited a pally without permission")
	end
end)
run("config: class header cycle", function()
	wheel("PallyPowerConfig112Group1Class", -1)
	click("PallyPowerConfig112Group1Class", "RightButton")
	enter("PallyPowerConfig112Group1Class")
end)
run("config: player button cycle", function()
	wheel("PallyPowerConfig112Group1Player1", 1)
	click("PallyPowerConfig112Group1Player1", "RightButton")
	enter("PallyPowerConfig112Group1Player1")
end)
run("config: player name opens per-paladin blessing menu", function()
	click("PallyPowerConfig112Group1Player1")
	local top = menuItems[1]
	assert(top and table.getn(top) >= 3, "menu did not populate")
	assert(top[1].isTitle, "first entry should be a title")
	local sub
	for _, item in ipairs(top) do
		if item.hasArrow and item.value == "Testpally" then sub = item end
	end
	assert(sub, "no submenu entry for own paladin")
	-- open the submenu like hovering the arrow does
	UIDROPDOWNMENU_MENU_LEVEL = 2
	UIDROPDOWNMENU_MENU_VALUE = sub.value
	lastDropDownFrame.initialize()
	local items2 = menuItems[2]
	assert(items2 and table.getn(items2) >= 2, "submenu did not populate")
	local pick
	for _, item in ipairs(items2) do
		if item.func and item.text ~= "(none)" then pick = item break end
	end
	assert(pick, "no blessing entries in submenu")
	local before = #sent
	pick.func()
	local ok
	for i = before + 1, #sent do
		if string.find(sent[i], "NASSIGN Testpally 1 Tanky %d") then ok = true end
	end
	assert(ok, "menu selection did not send NASSIGN")
	local noneItem
	for _, item in ipairs(items2) do
		if item.text == "(none)" then noneItem = item end
	end
	assert(noneItem, "no (none) entry")
	noneItem.func()
	UIDROPDOWNMENU_MENU_LEVEL = 1
end)
run("options: open", function() PallyPower.ToggleOptions() end)
run("options: toggle checkboxes", function()
	assert(_G["PallyPowerOptions112Smart"] == nil, "Smart checkbox should be gone")
	assert(_G["PallyPowerOptions112Chat"] == nil, "Chat checkbox should be gone")
	for _, n in ipairs({"Lock", "Solo", "FlyoutLeft"}) do
		local cb = _G["PallyPowerOptions112" .. n]
		cb.__checked = 1
		this = cb
		cb.__scripts.OnClick()
		cb.__checked = nil
		cb.__scripts.OnClick()
	end
	-- free assignment now lives only on the assignments window
	assert(_G["PallyPowerOptions112Free"] == nil, "Free checkbox should be gone from options")
	local cb = _G["PallyPowerConfig112Free"]
	cb.__checked = 1
	this = cb
	cb.__scripts.OnClick()
end)
run("options: move sliders", function()
	_G["PallyPowerOptions112Scale"]:SetValue(1.2)
	_G["PallyPowerOptions112Scan"]:SetValue(5)
end)
run("bindings: AutoBuff", function() PallyPower:AutoBuff("PallyPowerAuto", "Hotkey1") end)
run("report", function() SlashCmdList["PALLYPOWER"]("report") end)
run("close and reopen config", function()
	SlashCmdList["PALLYPOWER"]("")
	SlashCmdList["PALLYPOWER"]("")
end)
run("stealth keeps last-known buff state", function()
	-- Tanky is buffed and visible; scan records it
	PallyPowerKronos_Assignments["Testpally"][1] = 2
	buffs.party1 = {"Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"}
	tick(25, 0.5)
	-- Tanky stealths: no auras visible, but the buff must not vanish
	hiddenUnits.party1 = true
	buffs.party1 = nil
	tick(25, 0.5)
	enter("PallyPowerBar112Class1")
	local row = _G["PallyPowerPopup112Row1"]
	assert(row.member and row.member.name == "Tanky", "expected Tanky in flyout")
	-- a stealthed-but-buffed rogue must NOT count as needing the buff
	local count = _G["PallyPowerBar112Class1"].count.__text
	assert(count == "" or count == nil,
		"stealthed buffed rogue counted as needing (count=" .. tostring(count) .. ")")
	hiddenUnits.party1 = nil
	buffs.party1 = nil
end)
run("hostile ids on the bypass prefix are clamped, bar keeps updating", function()
	fire("CHAT_MSG_ADDON", "PLPWRX", "ASSIGN Testpally 9 42", "PARTY", "Tanky")
	fire("CHAT_MSG_ADDON", "PLPWRX", "ASSIGN Testpally 3.5 2", "PARTY", "Tanky")
	fire("CHAT_MSG_ADDON", "PLPWRX", "NASSIGN Testpally 1 Tanky 99", "PARTY", "Tanky")
	fire("CHAT_MSG_ADDON", "PLPWR", "PASSIGN Testpally@99999999", "PARTY", "Tanky")
	assert(PallyPowerKronos_Assignments["Testpally"][9] == 0, "pet id 42 not clamped")
	assert(PallyPowerKronos_Assignments["Testpally"][3.5] == nil, "fractional class stored")
	assert(not (PallyPowerKronos_NormalAssignments["Testpally"][1] and PallyPowerKronos_NormalAssignments["Testpally"][1]["Tanky"]), "normal id 99 not clamped")
	for i = 1, 8 do assert(PallyPowerKronos_Assignments["Testpally"][i] == 0, "PASSIGN digit 9 stored at " .. i) end
	tick(5, 1.0)
	enter("PallyPowerBar112Class1")
	tick(3, 1.0)
end)
run("non-leader clear sends none (-1), never Wisdom (0)", function()
	tick(8, 0.5)
	local before = #sent
	SlashCmdList["PALLYPOWER"]("clear")
	local found
	for i = before + 1, #sent do
		if string.find(sent[i], "MASSIGN Testpally") then found = sent[i] end
	end
	assert(found and string.find(found, " %-1$"), "expected MASSIGN ... -1, got " .. tostring(found))
end)
run("warrior with zero auras reads missing, rogue keeps the blackout", function()
	PallyPowerKronos_Assignments["Testpally"][1] = 2
	buffs.party1 = {"Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"}
	fire("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "Tanky gains Greater Blessing of Might.")
	tick(25, 0.5)
	assert(_G["PallyPowerBar112Class1"].count.__text == "" or _G["PallyPowerBar112Class1"].count.__text == nil, "precondition: buffed")
	buffs.party1 = {}
	fire("CHAT_MSG_SPELL_AURA_GONE_PARTY", "Greater Blessing of Might fades from Tanky.")
	tick(25, 0.5)
	assert(tonumber(_G["PallyPowerBar112Class1"].count.__text) == 1, "warrior with no auras still counted as buffed")
	buffs.party1 = nil
end)
run("SELF keeps the pet slot and normals from the other prefix", function()
	fire("CHAT_MSG_ADDON", "PLPWRX", "ASSIGN Tanky 9 3", "PARTY", "Tanky")
	fire("CHAT_MSG_ADDON", "PLPWRX", "NASSIGN Tanky 1 Tanky 6", "PARTY", "Tanky")
	fire("CHAT_MSG_ADDON", "PLPWR", "SELF 6275103010nn@n4nnnnnn", "PARTY", "Tanky")
	assert(PallyPowerKronos_Assignments["Tanky"][9] == 3, "SELF wiped the pet slot")
	assert(PallyPowerKronos_NormalAssignments["Tanky"][1]["Tanky"] == 6, "SELF wiped the normal assignment")
end)
run("status that arrives before SELF is applied after it", function()
	AllPallys["Newguy"] = nil
	fire("CHAT_MSG_ADDON", "PLPWRX", "FREEASSIGN YES SYMCOUNT 7 COOLDOWNS:3600:100:600:0", "PARTY", "Newguy")
	assert(AllPallys["Newguy"] == nil, "status created a phantom entry")
	fire("CHAT_MSG_ADDON", "PLPWR", "SELF 6275103010nn@nnnnnnnn", "PARTY", "Newguy")
	assert(AllPallys["Newguy"] and AllPallys["Newguy"].symbols == 7 and AllPallys["Newguy"].freeassign == true, "queued status not replayed")
	assert(AllPallys["Newguy"].CooldownInfo and AllPallys["Newguy"].CooldownInfo[1], "queued cooldowns not replayed")
end)
run("buff timers persist across reload", function()
	fire("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "Tanky gains Greater Blessing of Might.")
	fire("PLAYER_LOGOUT")
	assert(PallyPowerKronos112_Options.buffEpoch and PallyPowerKronos112_Options.buffEpoch["Tanky"], "no wall-clock timers saved on logout")
	-- a fresh login restores and consumes the saved table
	fire("PLAYER_LOGIN")
	assert(PallyPowerKronos112_Options.buffEpoch == nil, "saved timers not consumed on login")
end)
run("final ticks", function() tick(10, 1.0) end)
run("anchor audit: no visible unanchored frames", function()
	-- a WoW frame that is shown but has no anchor point renders nowhere;
	-- catch any top-level frame in that state (children inherit position)
	for _, f in ipairs(frames) do
		if f.__shown and not f.__anchored and (f.__parent == UIParent or f.__parent == nil) then
			error((f.__name or "?") .. " is shown but has no anchor point")
		end
	end
end)

print("")
print("ALL STEPS PASSED. Messages sent:")
for _, m in ipairs(sent) do print("  " .. m) end
