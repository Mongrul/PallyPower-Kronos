if PALLYPOWER_KRONOS_BLOCKED then return end
-- ============================================================================
-- PallyPower Classic -- vanilla 1.12 client build (Kronos)
--
-- A rewrite of Aznamir's original PallyPower that speaks the same "PLPWR"
-- addon-message protocol as PallyPower v1.4.4-classic (the 1.14 build that
-- ships in this same folder), so paladins on 1.12 and 1.14 clients share one
-- set of assignments:
--   * blessing IDs 1..7  (1 Wisdom, 2 Might, 3 Kings, 4 Salvation, 5 Light,
--                         6 Sanctuary, 7 Sacrifice/normal-only)
--   * class IDs    1..9  (1 Warrior .. 8 Warlock, 9 Pet)
--   * SELF / ASSIGN / PASSIGN / NASSIGN / MASSIGN / SYMCOUNT / CLEAR / REQ /
--     FREEASSIGN messages in the v1.4.4 wire format (broadcast only; the
--     1.12 network protocol has no addon whispers)
--
-- Features ported from the 1.14 build: per-player normal blessings (NASSIGN)
-- and pet scanning/buffing. Buff timers come from combat-log gain/fade lines
-- since 1.12's UnitBuff() exposes no durations.
--
-- This file is Lua 5.0: no '#', no '%' operator, no select(), string.gfind
-- instead of gmatch, event handlers read the this/event/arg1 globals.
-- ============================================================================

PallyPower = PallyPower or {}
AllPallys = {}

BINDING_HEADER_PALLYPOWER_KEYCAT = "PallyPower"
PALLYPOWER_KEYCAT = "PallyPower"
BINDING_NAME_AUTOKEY1 = "Automatic Blessing 1"
BINDING_NAME_AUTOKEY2 = "Automatic Blessing 2"

SLASH_PALLYPOWER1 = "/pp"
SLASH_PALLYPOWER2 = "/pallypower"

-- All shared constants, state, and functions live on this ONE table. WoW 1.12
-- runs Lua 5.0, which limits a function to 32 upvalues; referencing dozens of
-- file-scope locals from closures exceeds that and the whole file fails to
-- compile ("too many upvalues"). With everything on P, each closure needs a
-- single upvalue.
local P = {}

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------
P.PP_PREFIX = "PLPWR"
P.MAXCLASSES = 9
P.MAXPERCLASS = 15
P.MAXPALLYS = 12
P.NORMAL_DURATION = 5 * 60
P.GREATER_DURATION = 15 * 60
P.SYMBOL_NAME = "Symbol of Kings"
P.BIG = 99999

P.ClassID = {
	[1] = "WARRIOR", [2] = "ROGUE", [3] = "PRIEST", [4] = "DRUID",
	[5] = "PALADIN", [6] = "HUNTER", [7] = "MAGE", [8] = "WARLOCK", [9] = "PET",
}
P.ClassToID = {}
for id, token in pairs(P.ClassID) do P.ClassToID[token] = id end

P.ClassLabel = {
	[1] = "Warriors", [2] = "Rogues", [3] = "Priests", [4] = "Druids",
	[5] = "Paladins", [6] = "Hunters", [7] = "Mages", [8] = "Warlocks", [9] = "Pets",
}

P.ICONDIR = "Interface\\AddOns\\PallyPower\\Classic112\\Icons\\"
P.ClassIcons = {
	[1] = P.ICONDIR .. "Warrior", [2] = P.ICONDIR .. "Rogue", [3] = P.ICONDIR .. "Priest",
	[4] = P.ICONDIR .. "Druid", [5] = P.ICONDIR .. "Paladin", [6] = P.ICONDIR .. "Hunter",
	[7] = P.ICONDIR .. "Mage", [8] = P.ICONDIR .. "Warlock",
	[9] = "Interface\\Icons\\Ability_Mount_JungleTiger",
}

-- Blessing table: IDs identical to the 1.14 build. Icon paths are what 1.12's
-- UnitBuff() returns, used to detect who already has which blessing.
P.Blessings = {
	[1] = {key = "Wisdom", normal = "Blessing of Wisdom", greater = "Greater Blessing of Wisdom",
		talent = "Wisdom",
		nicon = "Interface\\Icons\\Spell_Holy_SealOfWisdom",
		gicon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofWisdom"},
	[2] = {key = "Might", normal = "Blessing of Might", greater = "Greater Blessing of Might",
		talent = "Might",
		nicon = "Interface\\Icons\\Spell_Holy_FistOfJustice",
		gicon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings"},
	[3] = {key = "Kings", normal = "Blessing of Kings", greater = "Greater Blessing of Kings",
		nicon = "Interface\\Icons\\Spell_Magic_MageArmor",
		gicon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings"},
	[4] = {key = "Salvation", normal = "Blessing of Salvation", greater = "Greater Blessing of Salvation",
		nicon = "Interface\\Icons\\Spell_Holy_SealOfSalvation",
		gicon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSalvation"},
	[5] = {key = "Light", normal = "Blessing of Light", greater = "Greater Blessing of Light",
		nicon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
		gicon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofLight"},
	[6] = {key = "Sanctuary", normal = "Blessing of Sanctuary", greater = "Greater Blessing of Sanctuary",
		nicon = "Interface\\Icons\\Spell_Nature_LightningShield",
		gicon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSanctuary"},
	[7] = {key = "Sacrifice", normal = "Blessing of Sacrifice", greater = nil,
		nicon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
		gicon = nil},
}

P.TexToBless = {}
for id, b in pairs(P.Blessings) do
	if b.nicon then P.TexToBless[b.nicon] = id end
	if b.gicon then P.TexToBless[b.gicon] = id end
end

-- blessing ids from other players' messages: integer 0..7 or nothing
function P.SaneBless(v)
	local n = tonumber(v)
	if not n or n ~= math.floor(n) or n < 0 or n > 7 then return 0 end
	return n
end

P.NormalNameToID, P.GreaterNameToID = {}, {}
for id, b in pairs(P.Blessings) do
	P.NormalNameToID[b.normal] = id
	if b.greater then P.GreaterNameToID[b.greater] = id end
end

-- Auras (same indices as the 1.14 build's ASELF message) and the two tracked
-- cooldowns (1 = Lay on Hands, 2 = Divine Intervention, like COOLDOWNS)
P.AuraNames = {
	[1] = "Devotion Aura",
	[2] = "Retribution Aura",
	[3] = "Concentration Aura",
	[4] = "Shadow Resistance Aura",
	[5] = "Frost Resistance Aura",
	[6] = "Fire Resistance Aura",
	[7] = "Sanctity Aura",
}
P.AuraNameToID = {}
for id, n in pairs(P.AuraNames) do P.AuraNameToID[n] = id end
P.AuraTalentMap = {Devotion = 1, Retribution = 2, Concentration = 3}
P.AuraIcons = {
	[1] = "Interface\\Icons\\Spell_Holy_DevotionAura",
	[2] = "Interface\\Icons\\Spell_Holy_AuraOfLight",
	[3] = "Interface\\Icons\\Spell_Holy_MindSooth",
}
P.CooldownIcons = {
	[1] = "Interface\\Icons\\Spell_Holy_LayOnHands",
	[2] = "Interface\\Icons\\Spell_Nature_TimeStop",
}
P.auraInfo = {}
P.cdSlots = {}
P.lastCd1 = false
P.lastCd2 = false
P.buffGreater = {}   -- [name][blessID] = false when the tracked buff is a normal

-- ----------------------------------------------------------------------------
-- State
-- ----------------------------------------------------------------------------
P.playerName = nil
P.isPally = false
P.initialized = false
P.spellSlots = {}     -- [blessID] = {normal=slot, greater=slot, rank=n, talent=n}
P.PP_Symbols = 0
P.roster = {}         -- [classID] = array of {unit, name}
P.unitInfo = {}       -- [name] = {visible, dead, online, buffs = {texture=true}}
P.buffExpire = {}     -- [name][blessID] = GetTime()-based expiry
P.scanQueue = {}
P.scanRoster = nil    -- P.roster being built while the queue drains
P.nextScan = 2
P.timerAcc = 0
P.pendingSync = nil   -- GetTime() at which to send REQ + SELF
P.lastSent = {}       -- [msg] = GetTime() (anti-spam)
P.pendingStatus = {}  -- [sender] = status messages that arrived before their SELF
P.lastGroupSize = 0

P.Bar, P.Popup, P.Config, P.Options = nil, nil, nil, nil  -- frames, built below

function P.Print(msg, r, g, b)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffff78PallyPower:|r " .. (msg or "nil"), r or 1, g or 1, b or 0.6)
end

function P.Feedback(msg)
	UIErrorsFrame:AddMessage(msg, 0, 1, 0, 1)
end

-- The 1.12 client hides Lua errors unless scriptErrors is enabled, so every
-- entry point runs through this and prints the real error to chat instead of
-- failing silently. Each label reports only once to avoid spam.
P.errorReported = {}
function P.SafeCall(label, fn)
	local ok, err = pcall(fn)
	if not ok and not P.errorReported[label] then
		P.errorReported[label] = true
		P.Print("Error in " .. label .. ": " .. tostring(err), 1, 0.2, 0.2)
	end
	return ok
end

-- ----------------------------------------------------------------------------
-- Small utilities (Lua 5.0 replacements)
-- ----------------------------------------------------------------------------
function P.StripRealm(name)
	if not name then return name end
	local _, _, short = string.find(name, "^([^%-]+)%-")
	-- pet keys like "Owner-pet" must survive; only strip when the suffix is not "pet"
	if short and not string.find(name, "%-pet$") then
		return short
	end
	return name
end

function P.FormatTime(time)
	if not time or time < 0 or time >= P.BIG then return "" end
	local mins = math.floor(time / 60)
	local secs = math.floor(time - (mins * 60))
	return string.format("%d:%02d", mins, secs)
end

function P.GroupChannel()
	if GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers() > 0 then return "PARTY" end
	return nil
end

function P.IsMouseOver(frame)
	-- MouseIsOver is not guaranteed in 1.12 FrameXML, so fall back to cursor math
	if MouseIsOver then return MouseIsOver(frame) end
	local x, y = GetCursorPosition()
	local scale = frame:GetEffectiveScale()
	x = x / scale
	y = y / scale
	local left, right = frame:GetLeft(), frame:GetRight()
	local top, bottom = frame:GetTop(), frame:GetBottom()
	return left and x >= left and x <= right and y >= bottom and y <= top
end

function P.PatternFromFormat(fmt)
	fmt = string.gsub(fmt, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	fmt = string.gsub(fmt, "%%%%s", "(.+)")
	return "^" .. fmt .. "$"
end

P.PAT_GAIN_OTHER = P.PatternFromFormat(AURAADDEDOTHERHELPFUL or "%s gains %s.")
P.PAT_GAIN_SELF = P.PatternFromFormat(AURAADDEDSELFHELPFUL or "You gain %s.")
P.PAT_FADE_OTHER = P.PatternFromFormat(AURAREMOVEDOTHER or "%s fades from %s.")
P.PAT_FADE_SELF = P.PatternFromFormat(AURAREMOVEDSELF or "%s fades from you.")

-- ----------------------------------------------------------------------------
-- Saved variables
-- ----------------------------------------------------------------------------
function P.InitSavedVars()
	if not PallyPowerKronos112_Options then PallyPowerKronos112_Options = {} end
	local d = {
		scale = 0.9, scanfreq = 10, freeassign = true,
		locked = false, barx = nil, bary = nil,
		cfgx = nil, cfgy = nil, showsolo = true, flyoutleft = false,
	}
	for k, v in pairs(d) do
		if PallyPowerKronos112_Options[k] == nil then PallyPowerKronos112_Options[k] = v end
	end
	if not PallyPowerKronos_Assignments then PallyPowerKronos_Assignments = {} end
	if not PallyPowerKronos_NormalAssignments then PallyPowerKronos_NormalAssignments = {} end
	-- One-time migrations. dataver history:
	--   nil = original 1.12 addon (0-based IDs; those numbers mean something
	--         else in the 1.14 scheme, so wipe them)
	--   2   = first build of this rewrite (showsolo wrongly defaulted to off)
	if PallyPowerKronos112_Options.dataver == nil then
		PallyPowerKronos_Assignments = {}
		PallyPowerKronos_NormalAssignments = {}
	end
	if (PallyPowerKronos112_Options.dataver or 0) < 3 then
		PallyPowerKronos112_Options.showsolo = true
		PallyPowerKronos112_Options.dataver = 3
	end
	if (PallyPowerKronos112_Options.dataver or 0) < 4 then
		-- free assignment defaults to ON for the Kronos build
		PallyPowerKronos112_Options.freeassign = true
		PallyPowerKronos112_Options.dataver = 4
	end
end

function P.MyAssignments()
	if not PallyPowerKronos_Assignments[P.playerName] then
		PallyPowerKronos_Assignments[P.playerName] = {}
		for i = 1, P.MAXCLASSES do PallyPowerKronos_Assignments[P.playerName][i] = 0 end
	end
	return PallyPowerKronos_Assignments[P.playerName]
end

function P.MyNormalAssignments()
	if not PallyPowerKronos_NormalAssignments[P.playerName] then
		PallyPowerKronos_NormalAssignments[P.playerName] = {}
	end
	return PallyPowerKronos_NormalAssignments[P.playerName]
end

-- ----------------------------------------------------------------------------
-- Permissions
-- ----------------------------------------------------------------------------
function P.IAmPromoted()
	if GetNumRaidMembers() > 0 then
		return IsRaidLeader() or IsRaidOfficer()
	end
	return IsPartyLeader()
end

function P.CheckLeader(nick)
	if not nick then return false end
	if nick == P.playerName then return P.IAmPromoted() end
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local name, rank = GetRaidRosterInfo(i)
			if name == nick then return (rank or 0) >= 1 end
		end
		return false
	end
	for i = 1, GetNumPartyMembers() do
		if UnitName("party" .. i) == nick and UnitIsPartyLeader("party" .. i) then
			return true
		end
	end
	return false
end

function P.CanControl(name)
	if name == P.playerName then return true end
	if P.IAmPromoted() then return true end
	if AllPallys[name] and AllPallys[name].freeassign then return true end
	return false
end

-- ----------------------------------------------------------------------------
-- Spellbook / talent / inventory scanning
-- ----------------------------------------------------------------------------
function P.ScanSpells()
	local _, class = UnitClass("player")
	if class ~= "PALADIN" then
		P.isPally = false
		P.initialized = true
		return
	end
	P.isPally = true
	P.spellSlots = {}
	P.auraInfo = {}
	P.cdSlots = {}
	local i = 1
	while true do
		local name, rankStr = GetSpellName(i, BOOKTYPE_SPELL)
		if not name then break end
		local blessID = P.NormalNameToID[name]
		local greater = false
		if not blessID then
			blessID = P.GreaterNameToID[name]
			greater = greater or (blessID ~= nil)
		end
		if blessID then
			if not P.spellSlots[blessID] then P.spellSlots[blessID] = {rank = 0, talent = 0} end
			local slot = P.spellSlots[blessID]
			local _, _, rank = string.find(rankStr or "", "(%d+)")
			rank = tonumber(rank) or 1
			if greater then
				if not slot.grank or rank >= slot.grank then
					slot.greater = i
					slot.grank = rank
				end
			else
				if rank >= (slot.rank or 0) then
					slot.normal = i
					slot.rank = rank
				end
			end
		end
		local auraID = P.AuraNameToID[name]
		if auraID then
			local _, _, arank = string.find(rankStr or "", "(%d+)")
			arank = tonumber(arank) or 1
			local cur = P.auraInfo[auraID]
			if not cur or arank >= cur.rank then
				P.auraInfo[auraID] = {rank = arank, talent = cur and cur.talent or 0}
			end
		end
		if name == "Lay on Hands" then
			P.cdSlots.loh = i
		elseif name == "Divine Intervention" then
			P.cdSlots.di = i
		end
		i = i + 1
	end
	-- talent points that improve a blessing (Imp. Wisdom / Imp. Might)
	for t = 1, GetNumTalentTabs() do
		for j = 1, GetNumTalents(t) do
			local tname, _, _, _, curRank = GetTalentInfo(t, j)
			if tname then
				local _, _, which = string.find(tname, "^Improved Blessing of (%a+)$")
				if which then
					for id, b in pairs(P.Blessings) do
						if b.talent == which and P.spellSlots[id] then
							P.spellSlots[id].talent = curRank or 0
						end
					end
				end
				local _, _, awhich = string.find(tname, "^Improved (%a+) Aura$")
				if awhich and P.AuraTalentMap[awhich] and P.auraInfo[P.AuraTalentMap[awhich]] then
					P.auraInfo[P.AuraTalentMap[awhich]].talent = curRank or 0
				end
			end
		end
	end
	-- publish own skills in the AllPallys format every client shares
	local mine = AllPallys[P.playerName] or {}
	AllPallys[P.playerName] = mine
	for id = 1, 6 do
		if P.spellSlots[id] and P.spellSlots[id].normal then
			mine[id] = {rank = P.spellSlots[id].rank, talent = P.spellSlots[id].talent or 0}
		else
			mine[id] = nil
		end
	end
	P.initialized = true
end

function P.ScanInventory()
	if not P.isPally then return end
	local count = 0
	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag)
		if slots then
			for slot = 1, slots do
				local link = GetContainerItemLink(bag, slot)
				if link and string.find(link, P.SYMBOL_NAME) then
					local _, n = GetContainerItemInfo(bag, slot)
					count = count + (n or 0)
				end
			end
		end
	end
	P.PP_Symbols = count
	if AllPallys[P.playerName] then AllPallys[P.playerName].symbols = count end
end

-- ----------------------------------------------------------------------------
-- Comm: send
-- ----------------------------------------------------------------------------
function P.SendMessage(msg, force)
	local chan = P.GroupChannel()
	if not chan then return end
	-- 1.12 SendAddonMessage rejects a bare "|" (invalid escape code)
	msg = string.gsub(msg, "|", "/")
	local now = GetTime()
	if not force and P.lastSent[msg] and (now - P.lastSent[msg]) < 3 then return end
	P.lastSent[msg] = now
	-- NASSIGN, pet-class ASSIGNs, ASELF, and the FREEASSIGN/SYMCOUNT/COOLDOWNS
	-- status combo have no old-protocol equivalent, so they travel (in MODERN
	-- formats) on the second prefix that the Kronos proxy's PLPWR translator
	-- does not touch (the proxy was observed clipping the combo's tail)
	local prefix = P.PP_PREFIX
	if string.find(msg, "^NASSIGN") or string.find(msg, "^ASSIGN %S+ 9 ")
		or string.find(msg, "^ASELF") or string.find(msg, "^FREEASSIGN") then
		prefix = "PLPWRX"
	end
	SendAddonMessage(prefix, msg, chan)
end

-- ---------------------------------------------------------------------------
-- WIRE ID TRANSLATION: the Kronos proxy already translates PallyPower traffic
-- between the ORIGINAL 1.12 addon protocol and the 1.14 client, so this build
-- must speak the original wire format:
--   old blessings: 0 Wisdom, 1 Might, 2 Salvation, 3 Light, 4 Kings,
--                  5 Sanctuary (-1/n = none; Sacrifice has no old ID)
--   old classes:   0 Warrior .. 7 Warlock (pets do not exist on the wire)
-- Internally everything stays on the 1.14 scheme; SELF/ASSIGN/MASSIGN are
-- translated here at the comm boundary. NASSIGN/PASSIGN/FREEASSIGN only exist
-- in the modern protocol (the proxy passes them through untouched), so those
-- keep modern IDs.
-- ---------------------------------------------------------------------------
P.BlessNewToOld = {[1] = 0, [2] = 1, [3] = 4, [4] = 2, [5] = 3, [6] = 5}
P.BlessOldToNew = {[0] = 1, [1] = 2, [2] = 4, [3] = 5, [4] = 3, [5] = 6}

function P.SendSelf()
	if not P.initialized or not P.isPally or not P.GroupChannel() then return end
	local isLeader = false
	if GetNumRaidMembers() > 0 then isLeader = IsRaidLeader() and true or false else isLeader = IsPartyLeader() and true or false end
	if isLeader then P.SendMessage("PPLEADER " .. P.playerName) end
	local s = ""
	-- skills in OLD blessing order (old ids 0..5)
	for oldid = 0, 5 do
		local slot = P.spellSlots[P.BlessOldToNew[oldid]]
		if slot and slot.normal then
			s = s .. slot.rank .. (slot.talent or 0)
		else
			s = s .. "nn"
		end
	end
	s = s .. "@"
	-- assignments for OLD classes 0..7 as OLD blessing digits
	local mine = P.MyAssignments()
	for oldc = 0, 7 do
		local a = mine[oldc + 1]
		local old = a and P.BlessNewToOld[a]
		if old then s = s .. old else s = s .. "n" end
	end
	P.SendMessage("SELF " .. s)
	-- the old-format SELF has no pet slot and receivers wipe the table on
	-- SELF, so follow up with a modern-id pet assignment on the bypass prefix
	if mine[9] and mine[9] > 0 then
		-- forced past the dedupe: a SELF within 3 s of setting the pet slot must still carry it
		P.SendMessage("ASSIGN " .. P.playerName .. " 9 " .. mine[9], true)
	end

	-- normal (per-player) assignments, batched 5 per message like the 1.14 build
	local list = {}
	for classid, tnames in pairs(P.MyNormalAssignments()) do
		for tname, blessID in pairs(tnames) do
			if blessID and blessID > 0 then
				tinsert(list, P.playerName .. " " .. classid .. " " .. tname .. " " .. blessID)
			end
		end
	end
	local count = table.getn(list)
	local offset = 1
	while offset <= count do
		local last = math.min(offset + 4, count)
		P.SendMessage("NASSIGN " .. table.concat(list, "@", offset, last), true)
		offset = offset + 5
	end

	-- aura ranks/talents, hex-encoded like the 1.14 build's ASELF
	local a = ""
	for id = 1, 7 do
		local aura = P.auraInfo[id]
		if aura then
			a = a .. string.format("%x%x", aura.rank, aura.talent or 0)
		else
			a = a .. "nn"
		end
	end
	P.SendMessage("ASELF " .. a .. "@0")

	P.SendStatus()
end

-- one COOLDOWNS field: ":duration:remaining", ":dur:0" = ready, ":n:n" = unknown
function P.CooldownPart(i)
	local slot = (i == 1) and P.cdSlots.loh or P.cdSlots.di
	if not slot then return ":n:n" end
	local start, duration = GetSpellCooldown(slot, BOOKTYPE_SPELL)
	if start and start > 0 and duration and duration > 1.5 then
		local left = start + duration - GetTime()
		if left < 0 then left = 0 end
		return ":" .. math.floor(duration) .. ":" .. math.floor(left)
	end
	return ":3600:0"
end

-- NO pipe separators here, unlike the stock 1.14 build: 1.12's
-- SendAddonMessage rejects a bare "|" ("Invalid escape code in chat message").
-- The 1.14 parser only pattern-matches the keywords, so pipes are not needed.
function P.SendStatus()
	local fa = "NO"
	if PallyPowerKronos112_Options.freeassign then fa = "YES" end
	P.SendMessage("FREEASSIGN " .. fa .. " SYMCOUNT " .. P.PP_Symbols .. " COOLDOWNS" .. P.CooldownPart(1) .. P.CooldownPart(2))
end

-- remaining cooldown for LoH (1) / DI (2): nil = spell unknown, 0 = ready
function P.GetOwnCooldown(i)
	local slot = (i == 1) and P.cdSlots.loh or P.cdSlots.di
	if not slot then return nil end
	local start, duration = GetSpellCooldown(slot, BOOKTYPE_SPELL)
	if not start or start == 0 or not duration or duration <= 1.5 then
		return 0 -- ready (<=1.5s is just the global cooldown)
	end
	local left = start + duration - GetTime()
	if left < 0 then left = 0 end
	return left
end

function P.RequestSync()
	P.SendMessage("REQ")
end

-- ----------------------------------------------------------------------------
-- Comm: receive
-- ----------------------------------------------------------------------------
P.UpdateAll = nil -- forward declaration

function P.ParseMessage(sender, msg, prefix)
	sender = P.StripRealm(sender)
	if not P.playerName or not sender or sender == P.playerName or not P.initialized then return end
	local leader = P.CheckLeader(sender)

	if msg == "REQ" then
		P.SendSelf()
		return
	end

	-- the two prefixes are separate queues, so status can land before the SELF that creates the entry
	if not AllPallys[sender] and (string.find(msg, "^FREEASSIGN") or string.find(msg, "^ASELF") or string.find(msg, "^SYMCOUNT")) then
		P.pendingStatus[sender] = P.pendingStatus[sender] or {}
		tinsert(P.pendingStatus[sender], msg)
		return
	end

	if string.find(msg, "^SELF") then
		PallyPowerKronos_NormalAssignments[sender] = PallyPowerKronos_NormalAssignments[sender] or {}
		local keepPet = PallyPowerKronos_Assignments[sender] and PallyPowerKronos_Assignments[sender][9]
		PallyPowerKronos_Assignments[sender] = {}
		PallyPowerKronos_Assignments[sender][9] = keepPet
		AllPallys[sender] = AllPallys[sender] or {}
		local skills = AllPallys[sender]
		-- original 1.12 wire format: skills in OLD blessing order, then
		-- 8 assignment digits (OLD classes 0..7, OLD blessing ids)
		local _, _, numbers, assign = string.find(msg, "SELF ([0-9n]*)@?([0-9n]*)")
		if numbers then
			for oldid = 0, 5 do
				local id = P.BlessOldToNew[oldid]
				local rank = string.sub(numbers, oldid * 2 + 1, oldid * 2 + 1)
				local talent = string.sub(numbers, oldid * 2 + 2, oldid * 2 + 2)
				if rank ~= "n" and rank ~= "" then
					skills[id] = {rank = tonumber(rank) or 0, talent = tonumber(talent) or 0}
				else
					skills[id] = nil
				end
			end
		end
		if assign then
			for oldc = 0, 7 do
				local tmp = string.sub(assign, oldc + 1, oldc + 1)
				local blessID = 0
				if tmp ~= "n" and tmp ~= "" then
					blessID = P.BlessOldToNew[tonumber(tmp) or -1] or 0
				end
				PallyPowerKronos_Assignments[sender][oldc + 1] = blessID
			end
		end
		local pend = P.pendingStatus[sender]
		if pend then
			P.pendingStatus[sender] = nil
			for _, m in ipairs(pend) do P.ParseMessage(sender, m, "PLPWRX") end
		end
	end

	if string.find(msg, "^ASSIGN") then
		local _, _, name, class, skill = string.find(msg, "^ASSIGN (.*) (.*) (.*)")
		if name then
			name = P.StripRealm(name)
			if name == sender or leader or PallyPowerKronos112_Options.freeassign then
				if not PallyPowerKronos_Assignments[name] then PallyPowerKronos_Assignments[name] = {} end
				if prefix == "PLPWRX" then
					-- the proxy-bypass prefix carries MODERN ids (pet class)
					local classid = tonumber(class) or 0
					if classid >= 1 and classid <= P.MAXCLASSES and classid == math.floor(classid) then
						PallyPowerKronos_Assignments[name][classid] = P.SaneBless(skill)
					end
				else
					-- old wire: class 0..7, skill = old blessing id or -1
					local classid = (tonumber(class) or -1) + 1
					if classid >= 1 and classid <= 8 then
						PallyPowerKronos_Assignments[name][classid] = P.BlessOldToNew[tonumber(skill) or -1] or 0
					end
				end
			end
		end
	end

	if string.find(msg, "^PASSIGN") then
		local _, _, name, assign = string.find(msg, "^PASSIGN (.*)@([0-9n]*)")
		if name then
			name = P.StripRealm(name)
			if name == sender or leader or PallyPowerKronos112_Options.freeassign then
				if not PallyPowerKronos_Assignments[name] then PallyPowerKronos_Assignments[name] = {} end
				for i = 1, P.MAXCLASSES do
					local tmp = string.sub(assign, i, i)
					if tmp == "n" or tmp == "" then tmp = "0" end
					PallyPowerKronos_Assignments[name][i] = P.SaneBless(tmp)
				end
			end
		end
	end

	if string.find(msg, "^NASSIGN") then
		for pname, class, tname, skill in string.gfind(string.sub(msg, 9), "([^@]*) ([^@]*) ([^@]*) ([^@]*)") do
			local name = P.StripRealm(pname)
			if name == sender or leader or PallyPowerKronos112_Options.freeassign then
				if not PallyPowerKronos_NormalAssignments[name] then PallyPowerKronos_NormalAssignments[name] = {} end
				class = tonumber(class) or 0
				if class >= 1 and class <= P.MAXCLASSES and class == math.floor(class) then
					if not PallyPowerKronos_NormalAssignments[name][class] then
						PallyPowerKronos_NormalAssignments[name][class] = {}
					end
					skill = P.SaneBless(skill)
					if skill == 0 then skill = nil end
					PallyPowerKronos_NormalAssignments[name][class][tname] = skill
				end
			end
		end
	end

	if string.find(msg, "^MASSIGN") then
		local _, _, name, skill = string.find(msg, "^MASSIGN (.*) (.*)")
		if name then
			name = P.StripRealm(name)
			if name == sender or leader or PallyPowerKronos112_Options.freeassign then
				if not PallyPowerKronos_Assignments[name] then PallyPowerKronos_Assignments[name] = {} end
				-- old wire: skill = old blessing id or -1
				local blessID = P.BlessOldToNew[tonumber(skill) or -1] or 0
				for i = 1, P.MAXCLASSES do
					PallyPowerKronos_Assignments[name][i] = blessID
				end
			end
		end
	end

	if string.find(msg, "SYMCOUNT") then
		local _, _, count = string.find(msg, "SYMCOUNT ([0-9]*)")
		if AllPallys[sender] then
			AllPallys[sender].symbols = tonumber(count) or 0
		end
	end

	if string.find(msg, "FREEASSIGN YES") and AllPallys[sender] then
		AllPallys[sender].freeassign = true
	end
	if string.find(msg, "FREEASSIGN NO") and AllPallys[sender] then
		AllPallys[sender].freeassign = false
	end

	if string.find(msg, "^CLEAR") then
		if leader then
			for name in pairs(PallyPowerKronos_Assignments) do
				PallyPowerKronos_Assignments[name] = {}
			end
			for name in pairs(PallyPowerKronos_NormalAssignments) do
				PallyPowerKronos_NormalAssignments[name] = {}
			end
		end
	end

	if string.find(msg, "^ASELF") and AllPallys[sender] then
		local _, _, numbers = string.find(msg, "ASELF ([0-9a-fn]*)@")
		if numbers then
			AllPallys[sender].AuraInfo = {}
			for i = 1, 7 do
				local rank = string.sub(numbers, (i - 1) * 2 + 1, (i - 1) * 2 + 1)
				local talent = string.sub(numbers, (i - 1) * 2 + 2, (i - 1) * 2 + 2)
				if rank ~= "n" and rank ~= "" then
					AllPallys[sender].AuraInfo[i] = {
						rank = tonumber(rank, 16) or 0,
						talent = tonumber(talent, 16) or 0,
					}
				end
			end
		end
	end

	if string.find(msg, "COOLDOWNS") and AllPallys[sender] then
		local _, _, cd = string.find(msg, "COOLDOWNS:(.*)")
		if cd then
			local vals = {}
			for v in string.gfind(cd, "([^:]+)") do
				tinsert(vals, v)
			end
			AllPallys[sender].CooldownInfo = {}
			for i = 1, 2 do
				local dur = vals[i * 2 - 1]
				local rem = vals[i * 2]
				if rem and rem ~= "n" then
					AllPallys[sender].CooldownInfo[i] = {
						duration = tonumber(dur) or 0,
						expire = GetTime() + (tonumber(rem) or 0),
					}
				end
			end
		end
	end

	-- AASSIGN / PPLEADER: aura assignment and leader traffic from 1.14
	-- clients; nothing in this build consumes it.

	P.UpdateAll()
end

-- ----------------------------------------------------------------------------
-- Assignment logic
-- ----------------------------------------------------------------------------
function P.GetEffectiveAssignment(pally, classid, tname)
	local na = PallyPowerKronos_NormalAssignments[pally]
	na = na and na[classid] and na[classid][tname]
	if na and na > 0 then return na, true end
	local ga = PallyPowerKronos_Assignments[pally] and PallyPowerKronos_Assignments[pally][classid]
	if ga and ga > 0 then return ga, false end
	return 0, false
end

function P.PallyKnows(name, blessID)
	if name == P.playerName then
		return P.spellSlots[blessID] and P.spellSlots[blessID].normal
	end
	if blessID == 7 then return true end -- SELF only carries 1..6; assume Sacrifice
	return AllPallys[name] and AllPallys[name][blessID]
end

function P.AssignedElsewhere(name, classid, blessID)
	for pally, skills in pairs(PallyPowerKronos_Assignments) do
		if pally ~= name and AllPallys[pally] and skills[classid] == blessID then
			return true
		end
	end
	return false
end

function P.BroadcastAssignment(name, classid)
	if classid == 9 then
		-- pets have no slot on the old wire; tunnel a MODERN-id message
		-- over the proxy-bypass prefix, like NASSIGN
		local a = PallyPowerKronos_Assignments[name][classid] or 0
		P.SendMessage("ASSIGN " .. name .. " 9 " .. a)
		return
	end
	local a = PallyPowerKronos_Assignments[name][classid] or 0
	local old = P.BlessNewToOld[a] or -1
	P.SendMessage("ASSIGN " .. name .. " " .. (classid - 1) .. " " .. old)
end

function P.CycleAssignment(name, classid, backwards)
	if not P.CanControl(name) then return end
	if not PallyPowerKronos_Assignments[name] then PallyPowerKronos_Assignments[name] = {} end
	local cur = PallyPowerKronos_Assignments[name][classid] or 0
	local step = 1
	if backwards then step = -1 end
	local test = cur
	for _ = 1, 7 do
		test = test + step
		if test > 6 then test = 0 end
		if test < 0 then test = 6 end
		if test == 0 then break end
		if P.PallyKnows(name, test) and not P.AssignedElsewhere(name, classid, test) then
			break
		end
	end
	PallyPowerKronos_Assignments[name][classid] = test
	P.BroadcastAssignment(name, classid)
	P.UpdateAll()
end

function P.MassAssign(name, blessID)
	if not P.CanControl(name) then return end
	if not PallyPowerKronos_Assignments[name] then PallyPowerKronos_Assignments[name] = {} end
	for c = 1, P.MAXCLASSES do
		PallyPowerKronos_Assignments[name][c] = blessID
	end
	P.SendMessage("MASSIGN " .. name .. " " .. (P.BlessNewToOld[blessID] or -1))
	P.UpdateAll()
end

-- shift-click/wheel in 1.14: advance to the pally's next known blessing and
-- assign it to every class in the row. Starts from the clicked cell's value.
function P.MassCycle(name, classid, backwards)
	if not P.CanControl(name) then return end
	local cur = (PallyPowerKronos_Assignments[name] and PallyPowerKronos_Assignments[name][classid]) or 0
	local step = 1
	if backwards then step = -1 end
	local test = cur
	for _ = 1, 7 do
		test = test + step
		if test > 6 then test = 0 end
		if test < 0 then test = 6 end
		if test == 0 then break end
		if P.PallyKnows(name, test) then break end
	end
	P.MassAssign(name, test)
	P.UpdateAll()
end

-- set (or clear, with 0) a paladin's personal 5-minute blessing for one target
function P.SetNormalAssignmentFor(pally, classid, tname, blessID)
	if not P.CanControl(pally) then return end
	if not PallyPowerKronos_NormalAssignments[pally] then PallyPowerKronos_NormalAssignments[pally] = {} end
	if not PallyPowerKronos_NormalAssignments[pally][classid] then PallyPowerKronos_NormalAssignments[pally][classid] = {} end
	if blessID == 0 then
		PallyPowerKronos_NormalAssignments[pally][classid][tname] = nil
	else
		PallyPowerKronos_NormalAssignments[pally][classid][tname] = blessID
	end
	P.SendMessage("NASSIGN " .. pally .. " " .. classid .. " " .. tname .. " " .. blessID)
	P.UpdateAll()
end

function P.SetNormalAssignment(classid, tname, blessID)
	P.SetNormalAssignmentFor(P.playerName, classid, tname, blessID)
end

local function PallyKnowsNormal(pally, id)
	if pally == P.playerName then
		return P.spellSlots[id] and P.spellSlots[id].normal
	end
	-- SELF messages only carry blessings 1-6 for other paladins
	return id <= 6 and AllPallys[pally] and AllPallys[pally][id]
end

-- The 1.14 dropdown on the little player names, replicated from
-- PallyPowerGrid_NormalBlessingMenu: one submenu per paladin in the group
-- (greyed when you cannot control them), each listing (none) + their
-- known normal blessings.
function P.OpenNormalMenu(classid, member)
	if not P.NormalMenu then
		P.NormalMenu = CreateFrame("Frame", "PallyPowerNormalMenu112", UIParent)
		P.NormalMenu.displayMode = "MENU"
		P.NormalMenu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		P.NormalMenu:Hide()
	end
	local tname = member.name
	P.NormalMenu.initialize = function()
		local level = UIDROPDOWNMENU_MENU_LEVEL or 1
		local info
		if level == 1 then
			info = {}
			info.text = "|cffffffff" .. tname .. "|r can be assigned"
			info.isTitle = 1
			UIDropDownMenu_AddButton(info, 1)
			info = {}
			info.text = "a Normal Blessing from:"
			info.isTitle = 1
			UIDropDownMenu_AddButton(info, 1)
			for pally in pairs(AllPallys) do
				local control = P.CanControl(pally)
				local pre, suf = "", ""
				if not control then
					pre = "|cff999999"
					suf = "|r"
				end
				info = {}
				info.text = pre .. pally .. suf
				info.hasArrow = 1
				info.value = pally
				info.checked = (PallyPowerKronos_NormalAssignments[pally]
					and PallyPowerKronos_NormalAssignments[pally][classid]
					and PallyPowerKronos_NormalAssignments[pally][classid][tname]) and 1 or nil
				UIDropDownMenu_AddButton(info, 1)
			end
			info = {}
			info.text = "Cancel"
			info.func = function() end
			UIDropDownMenu_AddButton(info, 1)
		else
			local pally = UIDROPDOWNMENU_MENU_VALUE
			if not pally then return end
			local control = P.CanControl(pally)
			local pre, suf = "", ""
			if not control then
				pre = "|cff999999"
				suf = "|r"
			end
			local current = (PallyPowerKronos_NormalAssignments[pally]
				and PallyPowerKronos_NormalAssignments[pally][classid]
				and PallyPowerKronos_NormalAssignments[pally][classid][tname]) or 0
			info = {}
			info.text = pre .. "(none)" .. suf
			info.checked = (current == 0) and 1 or nil
			info.func = function()
				CloseDropDownMenus()
				if control then P.SetNormalAssignmentFor(pally, classid, tname, 0) end
			end
			UIDropDownMenu_AddButton(info, 2)
			for id = 1, 7 do
				if PallyKnowsNormal(pally, id) then
					local blessID = id
					info = {}
					info.text = pre .. P.Blessings[id].normal .. suf
					info.checked = (current == id) and 1 or nil
					info.func = function()
						CloseDropDownMenus()
						if control then P.SetNormalAssignmentFor(pally, classid, tname, blessID) end
					end
					UIDropDownMenu_AddButton(info, 2)
				end
			end
		end
	end
	ToggleDropDownMenu(1, nil, P.NormalMenu, "cursor", 0, 0)
end

function P.CycleNormalAssignment(classid, tname, backwards)
	-- own normal (per-player) assignment for one target; syncs via NASSIGN
	local mine = P.MyNormalAssignments()
	if not mine[classid] then mine[classid] = {} end
	local cur = mine[classid][tname] or 0
	local step = 1
	if backwards then step = -1 end
	local test = cur
	for _ = 1, 8 do
		test = test + step
		if test > 7 then test = 0 end
		if test < 0 then test = 7 end
		if test == 0 then break end
		if P.spellSlots[test] and P.spellSlots[test].normal then break end
	end
	if test == 0 then
		mine[classid][tname] = nil
	else
		mine[classid][tname] = test
	end
	P.SendMessage("NASSIGN " .. P.playerName .. " " .. classid .. " " .. tname .. " " .. test)
	P.UpdateAll()
end

function P.ClearAssignments()
	P.SendMessage("CLEAR")
	if P.IAmPromoted() then
		for name in pairs(PallyPowerKronos_Assignments) do PallyPowerKronos_Assignments[name] = {} end
		for name in pairs(PallyPowerKronos_NormalAssignments) do PallyPowerKronos_NormalAssignments[name] = {} end
	else
		PallyPowerKronos_Assignments[P.playerName] = {}
		PallyPowerKronos_NormalAssignments[P.playerName] = {}
		P.SendMessage("MASSIGN " .. P.playerName .. " -1")
	end
	P.UpdateAll()
end

-- ----------------------------------------------------------------------------
-- Roster / buff scanning
-- ----------------------------------------------------------------------------
function P.BuildScanQueue()
	P.scanQueue = {}
	P.scanRoster = {}
	for c = 1, P.MAXCLASSES do P.scanRoster[c] = {} end
	if GetNumRaidMembers() > 0 then
		for i = 1, 40 do
			tinsert(P.scanQueue, "raid" .. i)
			tinsert(P.scanQueue, "raidpet" .. i)
		end
	else
		tinsert(P.scanQueue, "player")
		tinsert(P.scanQueue, "pet")
		for i = 1, 4 do
			tinsert(P.scanQueue, "party" .. i)
			tinsert(P.scanQueue, "partypet" .. i)
		end
	end
end

function P.ScanUnit(unit)
	if not UnitExists(unit) then return end
	local name = UnitName(unit)
	if not name or name == UNKNOWNOBJECT then return end
	local cid
	if string.find(unit, "pet") then
		cid = 9
	else
		local _, class = UnitClass(unit)
		cid = class and P.ClassToID[class]
	end
	if not cid then return end
	tinsert(P.scanRoster[cid], {unit = unit, name = name})
	local old = P.unitInfo[name]
	local info = {
		visible = UnitIsVisible(unit) and UnitIsConnected(unit),
		online = UnitIsConnected(unit),
		dead = UnitIsDeadOrGhost(unit),
		buffs = {},
	}
	local count = 0
	if info.visible then
		local j = 1
		while j <= 32 do
			local tex = UnitBuff(unit, j)
			if not tex then break end
			info.buffs[tex] = true
			count = count + 1
			j = j + 1
		end
	end
	if count > 0 then
		info.hadBuffs = true
	elseif old and old.hadBuffs and not info.dead and (cid == 2 or cid == 4 or cid == 9) then
		-- aura blackout: stealth/prowl (rogues, druids, pets) hides ALL of
		-- a unit's auras, sometimes while the unit itself is still visible.
		-- Keep the last-seen blessings whose combat-log timer is still running;
		-- a warrior with zero auras has simply lost his buff.
		local now = GetTime()
		for tex, v in pairs(old.buffs) do
			local id = P.TexToBless[tex]
			local t = id and P.buffExpire[name] and P.buffExpire[name][id]
			if not id or (t and t > now) then info.buffs[tex] = v end
		end
		info.hadBuffs = true
	end
	P.unitInfo[name] = info
end

function P.ProcessScanQueue()
	if not P.scanRoster then return end
	local budget = 8
	while budget > 0 do
		local unit = P.scanQueue[1]
		if not unit then
			P.roster = P.scanRoster
			P.scanRoster = nil
			P.nextScan = PallyPowerKronos112_Options.scanfreq or 10
			P.UpdateAll()
			return
		end
		tremove(P.scanQueue, 1)
		P.ScanUnit(unit)
		budget = budget - 1
	end
end

function P.UnitHasBlessing(name, blessID)
	local info = P.unitInfo[name]
	if not info or not blessID or blessID == 0 then return false end
	local b = P.Blessings[blessID]
	if b.gicon and info.buffs[b.gicon] then return true end
	if b.nicon and info.buffs[b.nicon] then return true end
	return false
end

function P.TimeLeft(name, blessID)
	local t = P.buffExpire[name] and P.buffExpire[name][blessID]
	if not t then return nil end
	local left = t - GetTime()
	if left <= 0 then
		P.buffExpire[name][blessID] = nil
		return nil
	end
	return left
end

-- ----------------------------------------------------------------------------
-- Buff timers from combat-log gain/fade lines
-- ----------------------------------------------------------------------------
function P.RecordGain(name, buffName)
	local id = P.GreaterNameToID[buffName]
	local dur = P.GREATER_DURATION
	local isGreater = true
	if not id then
		id = P.NormalNameToID[buffName]
		dur = P.NORMAL_DURATION
		isGreater = false
	end
	if not id then return end
	if not P.buffExpire[name] then P.buffExpire[name] = {} end
	P.buffExpire[name][id] = GetTime() + dur
	P.SetTrackedGreater(name, id, isGreater)
end

-- track whether a running timer belongs to a GREATER or a normal blessing,
-- so the class button can route it to the right of its two clocks
function P.SetTrackedGreater(name, id, isGreater)
	if not P.buffGreater[name] then P.buffGreater[name] = {} end
	P.buffGreater[name][id] = isGreater
end

function P.IsTrackedGreater(name, id)
	-- unknown (e.g. restored old data) counts as greater: the top clock
	local t = P.buffGreater[name]
	return not (t and t[id] == false)
end

function P.RecordFade(name, buffName)
	local id = P.GreaterNameToID[buffName] or P.NormalNameToID[buffName]
	if not id or not P.buffExpire[name] then return end
	-- Stealth/prowl makes the client emit "fades from X" for EVERY aura as
	-- the server hides them. If the unit now shows zero auras and is alive,
	-- this is a blackout, not a real expiry - keep the timer running.
	for c = 1, P.MAXCLASSES do
		local members = P.roster[c]
		if members then
			for _, m in ipairs(members) do
				if m.name == name then
					if (c == 2 or c == 4 or c == 9) and UnitExists(m.unit) and UnitBuff(m.unit, 1) == nil
						and not UnitIsDeadOrGhost(m.unit) and UnitIsConnected(m.unit) then
						return -- blackout: ignore the fade
					end
					P.buffExpire[name][id] = nil
					return
				end
			end
		end
	end
	P.buffExpire[name][id] = nil
end

function P.HandleCombatLog(ev, msg)
	if not msg then return end
	if ev == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
		local _, _, buff = string.find(msg, P.PAT_GAIN_SELF)
		if buff then P.RecordGain(P.playerName, buff) return end
	end
	if ev == "CHAT_MSG_SPELL_AURA_GONE_SELF" then
		local _, _, buff = string.find(msg, P.PAT_FADE_SELF)
		if buff then P.RecordFade(P.playerName, buff) return end
	end
	local _, _, who, buff = string.find(msg, P.PAT_GAIN_OTHER)
	if who and buff and (P.GreaterNameToID[buff] or P.NormalNameToID[buff]) then
		P.RecordGain(who, buff)
		return
	end
	local _, _, buff2, who2 = string.find(msg, P.PAT_FADE_OTHER)
	if buff2 and who2 then P.RecordFade(who2, buff2) end
end

-- ----------------------------------------------------------------------------
-- Casting
-- ----------------------------------------------------------------------------
function P.TryCastOnUnits(bookSlot, units, blessID, isGreater)
	if not bookSlot then return false end
	local sc = GetCVar("autoSelfCast")
	SetCVar("autoSelfCast", 0)
	-- 1.12: CastSpell lands INSTANTLY on a valid friendly target instead of
	-- showing the targeting cursor, hijacking the cast (e.g. buffing the
	-- hunter when the pet was clicked). Clear the target first and restore
	-- it after, like the original addon did.
	local restoreTarget = false
	if UnitExists("target") and UnitIsFriend("player", "target") then
		restoreTarget = true
		ClearTarget()
	end
	CastSpell(bookSlot, BOOKTYPE_SPELL)
	if SpellIsTargeting() then
		for _, u in ipairs(units) do
			if SpellCanTargetUnit(u.unit) then
				SpellTargetUnit(u.unit)
				SetCVar("autoSelfCast", sc)
				if restoreTarget then TargetLastTarget() end
				local dur = P.NORMAL_DURATION
				if isGreater then dur = P.GREATER_DURATION end
				-- optimistic timer, but never SHORTEN an existing one for the
				-- same blessing: the game rejects lesser-over-greater casts,
				-- and a shorter timer here would be recording that failure.
				-- The combat-log "gains" line corrects the timer either way.
				local newExpire = GetTime() + dur
				local cur = P.buffExpire[u.name] and P.buffExpire[u.name][blessID]
				local rejected = cur and (not isGreater) and cur > GetTime() and P.IsTrackedGreater(u.name, blessID)
				if not rejected and (not cur or newExpire > cur) then
					if not P.buffExpire[u.name] then P.buffExpire[u.name] = {} end
					P.buffExpire[u.name][blessID] = newExpire
					P.SetTrackedGreater(u.name, blessID, isGreater)
				end
				P.nextScan = 1
				return true
			end
		end
		SpellStopTargeting()
	end
	SetCVar("autoSelfCast", sc)
	if restoreTarget then TargetLastTarget() end
	return false
end

-- a greater blessing hits EVERY class member, not just the click target:
-- stamp them all with the fresh duration (never shortening a longer timer)
function P.StampGreater(classid, blessID)
	local newExpire = GetTime() + P.GREATER_DURATION
	local members = P.roster[classid] or {}
	for _, m in ipairs(members) do
		local info = P.unitInfo[m.name]
		-- the greater's application radius on Kronos is huge (~100yd), so
		-- "client can see them" (render range) is the best 1.12 proxy for
		-- "the refresh reached them"; dead members are skipped
		if info and not info.dead and info.visible then
			if not P.buffExpire[m.name] then P.buffExpire[m.name] = {} end
			local cur = P.buffExpire[m.name][blessID]
			if not cur or newExpire > cur then
				P.buffExpire[m.name][blessID] = newExpire
				P.SetTrackedGreater(m.name, blessID, true)
			end
		end
	end
end

function P.NeedingUnits(classid)
	local needs = {}
	local members = P.roster[classid] or {}
	for _, m in ipairs(members) do
		local blessID = P.GetEffectiveAssignment(P.playerName, classid, m.name)
		local info = P.unitInfo[m.name]
		if blessID > 0 and info and info.visible and not info.dead
			and not P.UnitHasBlessing(m.name, blessID) then
			tinsert(needs, m)
		end
	end
	return needs
end

function P.CastForClass(classid, forceNormal)
	if not P.isPally then return end
	if forceNormal then
		-- right-click: cast the target's effective LESSER blessing (their
		-- personal assignment first), like 1.14's right-click. A personal
		-- blessing differs from the class one, so it can override an active
		-- greater; the game itself forbids same-blessing downgrades.
		local members = P.roster[classid] or {}
		local target
		for _, m in ipairs(members) do
			local info = P.unitInfo[m.name]
			local b = P.GetEffectiveAssignment(P.playerName, classid, m.name)
			if b > 0 and info and info.visible and not info.dead and not P.UnitHasBlessing(m.name, b) then
				target = m
				break
			end
		end
		if not target then
			for _, m in ipairs(members) do
				local info = P.unitInfo[m.name]
				local b = P.GetEffectiveAssignment(P.playerName, classid, m.name)
				if b > 0 and info and info.visible and not info.dead then
					target = m
					break
				end
			end
		end
		if not target then
			P.Feedback("No valid target in " .. P.ClassLabel[classid])
			return
		end
		local b = P.GetEffectiveAssignment(P.playerName, classid, target.name)
		local slot = P.spellSlots[b]
		if slot and slot.normal then
			P.TryCastOnUnits(slot.normal, {target}, b, false)
		end
		return
	end
	-- Left-click: the class button always uses the CLASS assignment's greater
	-- blessing, mirroring 1.14's spell1 (greater) / spell2 (normal) split.
	local blessID = (PallyPowerKronos_Assignments[P.playerName] and PallyPowerKronos_Assignments[P.playerName][classid]) or 0
	if blessID == 0 then
		P.Feedback("No blessing assigned for " .. P.ClassLabel[classid])
		return
	end
	local slot = P.spellSlots[blessID]
	if not slot then return end
	-- pets CAN take greater blessings on Kronos (one pet per cast)
	local useGreater = slot.greater and not forceNormal
	if useGreater and P.PP_Symbols <= 0 then
		P.Feedback("Out of " .. P.SYMBOL_NAME .. "! Casting normal blessing instead.")
		useGreater = false
	end
	-- prefer members missing this blessing, but never BLOCK a cast: clicking
	-- must always be able to overwrite an existing blessing
	local members = P.roster[classid] or {}
	local candidates = {}
	for _, m in ipairs(members) do
		local info = P.unitInfo[m.name]
		if info and info.visible and not info.dead and not P.UnitHasBlessing(m.name, blessID) then
			tinsert(candidates, m)
		end
	end
	if table.getn(candidates) == 0 then
		for _, m in ipairs(members) do
			local info = P.unitInfo[m.name]
			if info and info.visible and not info.dead then
				tinsert(candidates, m)
			end
		end
	end
	if table.getn(candidates) == 0 then
		P.Feedback("No valid target in " .. P.ClassLabel[classid])
		return
	end
	if useGreater then
		-- pets (class 9): a greater hits only the one pet, which the cast
		-- routine already stamps; players get the class-wide stamp
		if P.TryCastOnUnits(slot.greater, candidates, blessID, true) and classid ~= 9 then
			P.StampGreater(classid, blessID)
		end
	elseif slot.normal then
		P.TryCastOnUnits(slot.normal, candidates, blessID, false)
	end
end

-- wantGreater: 1.14 flyout semantics - left-click casts the class's greater
-- (major) blessing on this target, right-click casts the normal (lesser) one
-- from their personal-else-class assignment.
function P.CastOnPlayer(classid, member, wantGreater)
	if not P.isPally or not member then return end
	local blessID
	if wantGreater then
		blessID = (PallyPowerKronos_Assignments[P.playerName] and PallyPowerKronos_Assignments[P.playerName][classid]) or 0
	else
		blessID = P.GetEffectiveAssignment(P.playerName, classid, member.name)
	end
	if blessID == 0 then
		P.Feedback("No blessing assigned for " .. member.name)
		return
	end
	local slot = P.spellSlots[blessID]
	if not slot then return end
	-- pets CAN take greater blessings on Kronos (one pet per cast)
	local useGreater = wantGreater and slot.greater
	if useGreater and P.PP_Symbols <= 0 then
		P.Feedback("Out of " .. P.SYMBOL_NAME .. "! Casting normal blessing instead.")
		useGreater = false
	end
	if useGreater then
		-- pets (class 9): a greater hits only the one pet, which the cast
		-- routine already stamps; players get the class-wide stamp
		if P.TryCastOnUnits(slot.greater, {member}, blessID, true) and classid ~= 9 then
			P.StampGreater(classid, blessID)
		end
	elseif slot.normal then
		P.TryCastOnUnits(slot.normal, {member}, blessID, false)
	end
end

-- Auto-buff feature removed by request. The stub stays because the shared
-- Bindings.xml (used by both client builds) still references this method.
function PallyPower:AutoBuff()
end

-- ----------------------------------------------------------------------------
-- P.Report
-- ----------------------------------------------------------------------------
function P.Report()
	local chan = P.GroupChannel()
	if not chan then
		P.Print("Not in a party or raid.")
		return
	end
	SendChatMessage("--- Paladin assignments ---", chan)
	for name in pairs(AllPallys) do
		local parts = {}
		local assigns = PallyPowerKronos_Assignments[name]
		if assigns then
			for c = 1, P.MAXCLASSES do
				local a = assigns[c]
				if a and a > 0 then
					tinsert(parts, P.ClassLabel[c] .. ": " .. P.Blessings[a].key)
				end
			end
		end
		local line = "Nothing"
		if table.getn(parts) > 0 then line = table.concat(parts, ", ") end
		SendChatMessage(name .. " - " .. line, chan)
	end
	SendChatMessage("--- end of assignments ---", chan)
end

-- ----------------------------------------------------------------------------
-- UI helpers
-- ----------------------------------------------------------------------------
-- Styling copied from the 1.14 build: "Smooth" skin fill (shared Skins folder),
-- tooltip border, and the same red/yellow/green state colors.
P.BUTTON_BACKDROP = {
	bgFile = "Interface\\AddOns\\PallyPower\\Skins\\Smooth",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = false, edgeSize = 8,
	insets = {left = 2, right = 2, top = 2, bottom = 2},
}
P.WINDOW_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 8, edgeSize = 8,
	insets = {left = 2, right = 2, top = 2, bottom = 2},
}
P.COLOR_NEEDALL = {1.0, 0.0, 0.0, 0.5}
P.COLOR_NEEDSOME = {1.0, 1.0, 0.5, 0.5}
P.COLOR_NEEDSPECIAL = {0.0, 0.0, 1.0, 0.5}
P.COLOR_GOOD = {0.0, 0.7, 0.0, 0.5}
P.COLOR_IDLE = {0.0, 0.0, 0.0, 0.5}

function P.SetButtonColor(frame, c)
	frame:SetBackdropColor(c[1], c[2], c[3], c[4])
end

function P.ApplyBackdrop(frame, color, backdrop)
	frame:SetBackdrop(backdrop or P.BUTTON_BACKDROP)
	P.SetButtonColor(frame, color)
	frame:SetBackdropBorderColor(1, 1, 1, 1)
end

function P.MakeLabel(parent, fontObject, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(fontObject or GameFontHighlightSmall)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

function P.SavePosition(frame, xkey, ykey)
	PallyPowerKronos112_Options[xkey] = frame:GetLeft()
	PallyPowerKronos112_Options[ykey] = frame:GetTop()
end

function P.RestorePosition(frame, xkey, ykey, defx, defy)
	frame:ClearAllPoints()
	if PallyPowerKronos112_Options[xkey] and PallyPowerKronos112_Options[ykey] then
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", PallyPowerKronos112_Options[xkey], PallyPowerKronos112_Options[ykey])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", defx or 0, defy or 0)
	end
end

-- ----------------------------------------------------------------------------
-- UI: buff bar (one row per class, popup with per-player rows)
-- ----------------------------------------------------------------------------
P.BTN_W, P.BTN_H = 100, 34

function P.BuildPopup()
	P.Popup = CreateFrame("Frame", "PallyPowerPopup112", UIParent)
	P.Popup:SetScale(PallyPowerKronos112_Options.scale or 0.9)
	P.Popup:SetWidth(P.BTN_W)
	P.Popup:SetFrameStrata("DIALOG")
	P.Popup:Hide()
	P.Popup.rows = {}
	P.Popup.classid = nil
	for i = 1, P.MAXPERCLASS do
		-- anatomy copied from the 1.14 PallyPowerPopupTemplate (100x34 buttons)
		local row = CreateFrame("Button", "PallyPowerPopup112Row" .. i, P.Popup)
		row:SetWidth(P.BTN_W)
		row:SetHeight(P.BTN_H)
		row:SetPoint("TOPLEFT", P.Popup, "TOPLEFT", 0, -(i - 1) * P.BTN_H)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:EnableMouseWheel(1)
		P.ApplyBackdrop(row, P.COLOR_IDLE)
		row.icon = row:CreateTexture(nil, "OVERLAY")
		row.icon:SetWidth(16)
		row.icon:SetHeight(16)
		row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
		row.timer = P.MakeLabel(row, GameFontHighlightSmall, "LEFT")
		row.timer:SetWidth(40)
		row.timer:SetHeight(16)
		row.timer:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 1, 0)
		row.name = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.name:SetWidth(92)
		row.name:SetHeight(16)
		row.name:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -5, 3)
		row.rng = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.rng:SetWidth(10)
		row.rng:SetHeight(10)
		row.rng:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
		row.rng:SetText("R")
		row.dead = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.dead:SetWidth(10)
		row.dead:SetHeight(10)
		row.dead:SetPoint("RIGHT", row.rng, "LEFT", -3, 0)
		row.dead:SetText("D")
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		row.index = i
		row:SetScript("OnClick", function()
			local member = this.member
			if not member then return end
			if arg1 == "RightButton" then
				-- lesser (normal 5-min) blessing, like the 1.14 flyout
				P.CastOnPlayer(P.Popup.classid, member, false)
			else
				-- major (greater) blessing
				P.CastOnPlayer(P.Popup.classid, member, true)
			end
		end)
		row:SetScript("OnMouseWheel", function()
			local member = this.member
			if not member then return end
			P.CycleNormalAssignment(P.Popup.classid, member.name, arg1 > 0)
		end)
		row:SetScript("OnEnter", function()
			local member = this.member
			if not member then return end
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(member.name, 1, 1, 1)
			local blessID, isNormal = P.GetEffectiveAssignment(P.playerName, P.Popup.classid, member.name)
			if blessID > 0 then
				local kind = "class assignment"
				if isNormal then kind = "personal assignment" end
				GameTooltip:AddLine(P.Blessings[blessID].key .. " (" .. kind .. ")", 0.8, 0.8, 1)
			else
				GameTooltip:AddLine("No blessing assigned", 0.8, 0.8, 0.8)
			end
			GameTooltip:AddLine("Left-click: cast greater blessing", 0.6, 1, 0.6)
			GameTooltip:AddLine("Right-click: cast normal (5-min) blessing", 0.6, 1, 0.6)
			GameTooltip:AddLine("Wheel: set personal blessing", 0.6, 1, 0.6)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		P.Popup.rows[i] = row
	end
end

function P.UpdatePopup()
	if not P.Popup or not P.Popup:IsVisible() or not P.Popup.classid then return end
	local classid = P.Popup.classid
	local members = P.roster[classid] or {}
	local shown = 0
	for i = 1, P.MAXPERCLASS do
		local row = P.Popup.rows[i]
		local member = members[i]
		if member then
			shown = shown + 1
			row.member = member
			local blessID, isNormal = P.GetEffectiveAssignment(P.playerName, classid, member.name)
			if blessID > 0 then
				local b = P.Blessings[blessID]
				local icon = b.gicon
				if isNormal or not icon then icon = b.nicon end
				row.icon:SetTexture(icon)
				row.icon:Show()
			else
				row.icon:Hide()
			end
			row.name:SetText(member.name)
			local info = P.unitInfo[member.name]
			if info and info.visible then
				row.rng:SetTextColor(0, 1, 0)
			else
				row.rng:SetTextColor(1, 0, 0)
			end
			if info and info.dead then
				row.dead:SetTextColor(1, 0, 0)
				row.dead:Show()
			else
				row.dead:Hide()
			end
			if not info or info.dead then
				P.SetButtonColor(row, P.COLOR_IDLE)
				row.name:SetTextColor(0.6, 0.6, 0.6)
				row.timer:SetText("")
			elseif blessID > 0 and P.UnitHasBlessing(member.name, blessID) then
				-- stays green with its timer even while stealthed (cached)
				P.SetButtonColor(row, P.COLOR_GOOD)
				row.name:SetTextColor(1, 1, 1)
				row.timer:SetText(P.FormatTime(P.TimeLeft(member.name, blessID)))
			elseif blessID > 0 and info.visible then
				-- missing a LESSER (personal) blessing shows dark blue,
				-- missing the class blessing shows red - like 1.14
				if isNormal then
					P.SetButtonColor(row, P.COLOR_NEEDSPECIAL)
				else
					P.SetButtonColor(row, P.COLOR_NEEDALL)
				end
				row.name:SetTextColor(1, 1, 1)
				row.timer:SetText("")
			else
				P.SetButtonColor(row, P.COLOR_IDLE)
				row.name:SetTextColor(0.8, 0.8, 0.8)
				row.timer:SetText("")
			end
			row:Show()
		else
			row.member = nil
			row:Hide()
		end
	end
	P.Popup:SetHeight(math.max(1, shown * P.BTN_H))
end

function P.ShowPopup(classRow)
	P.Popup.classid = classRow.classid
	P.Popup:ClearAllPoints()
	if PallyPowerKronos112_Options.flyoutleft then
		P.Popup:SetPoint("TOPRIGHT", classRow, "TOPLEFT", 0, 0)
	else
		P.Popup:SetPoint("TOPLEFT", classRow, "TOPRIGHT", 0, 0)
	end
	P.Popup:Show()
	P.UpdatePopup()
end

function P.BuildBar()
	P.Bar = CreateFrame("Frame", "PallyPowerBar112", UIParent)
	P.Bar:SetWidth(P.BTN_W)
	P.Bar:SetHeight(20 + P.BTN_H)
	P.Bar:SetScale(PallyPowerKronos112_Options.scale or 0.9)
	P.Bar:SetMovable(true)
	P.Bar:SetClampedToScreen(true)

	-- title strip: drag handle, symbols counter, right-click opens assignments
	local title = CreateFrame("Button", "PallyPowerBar112Title", P.Bar)
	title:SetWidth(P.BTN_W)
	title:SetHeight(20)
	title:SetPoint("TOPLEFT", P.Bar, "TOPLEFT", 0, 0)
	title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	title:RegisterForDrag("LeftButton")
	P.ApplyBackdrop(title, P.COLOR_IDLE)
	title.text = P.MakeLabel(title, GameFontNormalSmall, "CENTER")
	title.text:SetPoint("CENTER", title, "CENTER", 0, 0)
	title.text:SetText("Pally Buffs")
	title:SetScript("OnDragStart", function()
		if not PallyPowerKronos112_Options.locked then P.Bar:StartMoving() end
	end)
	title:SetScript("OnDragStop", function()
		P.Bar:StopMovingOrSizing()
		P.SavePosition(P.Bar, "barx", "bary")
	end)
	title:SetScript("OnClick", function()
		if arg1 == "RightButton" then PallyPower.ToggleConfig() end
	end)
	title:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:SetText("Pally Power", 1, 1, 1)
		GameTooltip:AddLine("(n) = your Symbol of Kings count", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Drag: move - Right-click: assignments", 0.6, 1, 0.6)
		GameTooltip:Show()
	end)
	title:SetScript("OnLeave", function() GameTooltip:Hide() end)
	P.Bar.title = title.text
	P.Bar.titleFrame = title

	P.Bar.rows = {}
	for c = 1, P.MAXCLASSES do
		-- anatomy copied from the 1.14 PallyPowerButtonTemplate (100x34)
		local row = CreateFrame("Button", "PallyPowerBar112Class" .. c, P.Bar)
		row:SetWidth(P.BTN_W)
		row:SetHeight(P.BTN_H)
		row.classid = c
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:EnableMouseWheel(1)
		P.ApplyBackdrop(row, P.COLOR_IDLE)
		row.classIcon = row:CreateTexture(nil, "OVERLAY")
		row.classIcon:SetWidth(26)
		row.classIcon:SetHeight(26)
		row.classIcon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
		row.classIcon:SetTexture(P.ClassIcons[c])
		row.buffIcon = row:CreateTexture(nil, "OVERLAY")
		row.buffIcon:SetWidth(26)
		row.buffIcon:SetHeight(26)
		row.buffIcon:SetPoint("TOPLEFT", row.classIcon, "TOPRIGHT", 2, 0)
		row.timer = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.timer:SetWidth(35)
		row.timer:SetHeight(16)
		row.timer:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -3)
		row.timer2 = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.timer2:SetWidth(35)
		row.timer2:SetHeight(16)
		row.timer2:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -5, 3)
		row.count = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.count:SetWidth(14)
		row.count:SetHeight(16)
		row.count:SetPoint("TOPRIGHT", row.timer2, "TOPLEFT", -2, 0)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		row:SetScript("OnClick", function()
			if arg1 == "RightButton" then
				P.CastForClass(this.classid, true) -- force a normal (single-target) blessing
			else
				P.CastForClass(this.classid)
			end
		end)
		row:SetScript("OnMouseWheel", function()
			if IsShiftKeyDown() then
				P.MassCycle(P.playerName, this.classid, arg1 > 0)
			else
				P.CycleAssignment(P.playerName, this.classid, arg1 > 0)
			end
		end)
		row:SetScript("OnEnter", function()
			P.ShowPopup(this)
		end)
		P.Bar.rows[c] = row
	end
	P.RestorePosition(P.Bar, "barx", "bary", -200, 0)
end

function P.UpdateBar()
	if not P.Bar then return end
	if not P.isPally or (not P.GroupChannel() and not PallyPowerKronos112_Options.showsolo) then
		P.Bar:Hide()
		return
	end
	P.Bar:Show()
	-- same as the 1.14 build's title: the number is your Symbol of Kings count
	P.Bar.title:SetText("Pally Buffs (" .. P.PP_Symbols .. ")")
	local shown = 0
	local totalNeed = 0
	local minAny = P.BIG
	local mine = P.MyAssignments()
	for c = 1, P.MAXCLASSES do
		local row = P.Bar.rows[c]
		local members = P.roster[c] or {}
		local total = table.getn(members)
		if total > 0 then
			shown = shown + 1
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", P.Bar, "TOPLEFT", 0, -20 - (shown - 1) * P.BTN_H)
			local assign = mine[c] or 0
			if assign > 0 then
				local b = P.Blessings[assign]
				local icon = b.gicon or b.nicon
				row.buffIcon:SetTexture(icon)
				row.buffIcon:Show()
			else
				row.buffIcon:Hide()
			end
			local need, special, have = 0, 0, 0
			-- timer = class-wide (greater) blessing, timer2 = personal blessings,
			-- mirroring the Time/Time2 pair on the 1.14 class button
			local minClass, minSpec = P.BIG, P.BIG
			for _, m in ipairs(members) do
				local blessID, isNormal = P.GetEffectiveAssignment(P.playerName, c, m.name)
				local info = P.unitInfo[m.name]
				if not info or info.dead then
					-- unbuffable right now; doesn't count against the class
				elseif blessID > 0 and P.UnitHasBlessing(m.name, blessID) then
					have = have + 1
					local left = P.TimeLeft(m.name, blessID)
					if left then
						-- route by what buff is actually tracked: the bottom
						-- clock is ONLY for minor (5-min) blessings
						if P.IsTrackedGreater(m.name, blessID) then
							if left < minClass then minClass = left end
						else
							if left < minSpec then minSpec = left end
						end
					end
				elseif blessID > 0 and info.visible then
					if isNormal then
						special = special + 1
					else
						need = need + 1
					end
				elseif blessID > 0 then
					-- hidden with no known buff: not buffable, so not "need"
					have = have + 1
				end
			end
			totalNeed = totalNeed + need + special
			if minClass < minAny then minAny = minClass end
			if minSpec < minAny then minAny = minSpec end
			if need + special > 0 then
				row.count:SetText(need + special)
			else
				row.count:SetText("")
			end
			row.timer:SetText(P.FormatTime(minClass))
			row.timer2:SetText(P.FormatTime(minSpec))
			-- 1.14 color priority: red = nobody buffed, yellow = class blessing
			-- missing, dark blue = only lesser (personal) blessings missing
			if (need + special) > 0 and have == 0 then
				P.SetButtonColor(row, P.COLOR_NEEDALL)
			elseif need > 0 then
				P.SetButtonColor(row, P.COLOR_NEEDSOME)
			elseif special > 0 then
				P.SetButtonColor(row, P.COLOR_NEEDSPECIAL)
			elseif have == 0 then
				-- nothing assigned, or nobody in range to check: not "all buffed"
				P.SetButtonColor(row, P.COLOR_IDLE)
			else
				P.SetButtonColor(row, P.COLOR_GOOD)
			end
			row:Show()
		else
			row:Hide()
		end
	end
	P.Bar:SetHeight(20 + shown * P.BTN_H)
end

-- ----------------------------------------------------------------------------
-- UI: assignments window, modeled on the 1.14 PallyPowerBlessingsFrame:
-- class columns with per-player lists up top, one row per paladin below
-- (name, symbols, blessing ranks + talents), grid cells under the columns.
-- ----------------------------------------------------------------------------
P.COL_W = 86      -- class column width (84 + 2 gap, like ClassGroupTemplate)
P.NAME_W = 140    -- left column with paladin name/skills
P.UROW_H = 92     -- one paladin row (blessings, auras, cooldowns)
P.GRID_LEFT = 8 + P.NAME_W

P.CONFIG_BACKDROP = {
	bgFile = "Interface\\CharacterFrame\\UI-Party-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = {left = 5, right = 5, top = 5, bottom = 5},
}
P.SLIDER_BACKDROP = {
	bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
	edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
	tile = true, tileSize = 8, edgeSize = 8,
	insets = {left = 3, right = 3, top = 6, bottom = 6},
}

function P.MakeCheck(parent, name, label, x, y, get, set)
	local cb = CreateFrame("CheckButton", name, parent)
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
	cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	cb.label = P.MakeLabel(cb, GameFontHighlightSmall)
	cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	cb.label:SetText(label)
	cb.get = get
	cb.set = set
	cb:SetScript("OnClick", function()
		this.set(this:GetChecked() and true or false)
	end)
	cb:SetScript("OnShow", function()
		this:SetChecked(this.get())
	end)
	return cb
end

function P.MakeSlider(parent, name, label, x, y, minv, maxv, step, fmt, get, set)
	local s = CreateFrame("Slider", name, parent)
	s:SetOrientation("HORIZONTAL")
	s:SetWidth(220)
	s:SetHeight(17)
	s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	s:SetBackdrop(P.SLIDER_BACKDROP)
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	s:SetMinMaxValues(minv, maxv)
	s:SetValueStep(step)
	s.label = P.MakeLabel(s, GameFontHighlightSmall)
	s.label:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
	s.text = label
	s.fmt = fmt
	s.get = get
	s.set = set
	s:SetScript("OnValueChanged", function()
		local v = this:GetValue()
		this.label:SetText(this.text .. ": " .. string.format(this.fmt, v))
		if not this.loading then this.set(v) end
	end)
	s:SetScript("OnShow", function()
		this.loading = true
		this:SetValue(this.get())
		this.loading = false
		this.label:SetText(this.text .. ": " .. string.format(this.fmt, this:GetValue()))
	end)
	return s
end

P.BuildOptions = nil -- defined below

function P.BuildConfig()
	P.Config = CreateFrame("Frame", "PallyPowerConfig112", UIParent)
	P.Config:SetWidth(P.GRID_LEFT + P.MAXCLASSES * P.COL_W + 8)
	P.Config:SetHeight(400)
	P.Config:SetScale(PallyPowerKronos112_Options.scale or 0.9)
	P.Config:SetFrameStrata("HIGH")
	P.Config:SetMovable(true)
	P.Config:EnableMouse(true)
	P.Config:SetClampedToScreen(true)
	P.ApplyBackdrop(P.Config, {1, 1, 1, 1}, P.CONFIG_BACKDROP)
	P.Config:Hide()

	-- title strip doubles as the drag handle, like the 1.14 window
	local title = CreateFrame("Button", "PallyPowerConfig112Title", P.Config)
	title:SetHeight(20)
	title:SetPoint("TOPLEFT", P.Config, "TOPLEFT", 30, -7)
	title:SetPoint("TOPRIGHT", P.Config, "TOPRIGHT", -30, -7)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function() P.Config:StartMoving() end)
	title:SetScript("OnDragStop", function()
		P.Config:StopMovingOrSizing()
		P.SavePosition(P.Config, "cfgx", "cfgy")
	end)
	P.Config.title = P.MakeLabel(title, GameFontNormal, "CENTER")
	P.Config.title:SetPoint("CENTER", title, "CENTER", 0, 0)
	P.Config.title:SetText("PallyPower Kronos by Mirasu")

	-- 1.12 CreateFrame has no template argument, so the close button is manual
	local close = CreateFrame("Button", "PallyPowerConfig112Close", P.Config)
	close:SetWidth(24)
	close:SetHeight(24)
	close:SetPoint("TOPRIGHT", P.Config, "TOPRIGHT", -4, -4)
	close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
	close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
	close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
	close:SetScript("OnClick", function() P.Config:Hide() end)

	-- class columns (ClassGroupTemplate): 32px class icon on top, up to 15
	-- per-player rows below for personal (normal) blessing assignments
	P.Config.groups = {}
	for c = 1, P.MAXCLASSES do
		local grp = CreateFrame("Frame", "PallyPowerConfig112Group" .. c, P.Config)
		grp:SetWidth(84)
		grp:SetHeight(80)
		grp:SetPoint("TOPLEFT", P.Config, "TOPLEFT", P.GRID_LEFT + (c - 1) * P.COL_W, -25)
		grp.line = grp:CreateTexture(nil, "ARTWORK")
		grp.line:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		grp.line:SetVertexColor(1, 1, 1, 0.25)
		grp.line:SetWidth(2)
		grp.line:SetHeight(212)
		grp.line:SetPoint("TOPLEFT", grp, "TOPLEFT", 0, 0)

		local hdr = CreateFrame("Button", "PallyPowerConfig112Group" .. c .. "Class", grp)
		hdr:SetWidth(32)
		hdr:SetHeight(32)
		hdr:SetPoint("TOPLEFT", grp, "TOPLEFT", 26, -12)
		hdr.classid = c
		hdr:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		hdr:EnableMouseWheel(1)
		hdr.icon = hdr:CreateTexture(nil, "ARTWORK")
		hdr.icon:SetAllPoints(hdr)
		hdr.icon:SetTexture(P.ClassIcons[c])
		local hhl = hdr:CreateTexture(nil, "HIGHLIGHT")
		hhl:SetWidth(38)
		hhl:SetHeight(38)
		hhl:SetPoint("CENTER", hdr, "CENTER", 0, 0)
		hhl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
		hhl:SetBlendMode("ADD")
		hdr:SetScript("OnClick", function()
			if arg1 == "RightButton" then
				local mine = P.MyAssignments()
				mine[this.classid] = 0
				P.BroadcastAssignment(P.playerName, this.classid)
				P.UpdateAll()
			else
				P.CycleAssignment(P.playerName, this.classid, false)
			end
		end)
		hdr:SetScript("OnMouseWheel", function()
			P.CycleAssignment(P.playerName, this.classid, arg1 > 0)
		end)
		hdr:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(P.ClassLabel[this.classid], 1, 1, 1)
			local a = P.MyAssignments()[this.classid]
			if a and a > 0 then
				GameTooltip:AddLine("Your assignment: " .. P.Blessings[a].key, 0.8, 0.8, 1)
			else
				GameTooltip:AddLine("Nothing assigned to you", 0.8, 0.8, 0.8)
			end
			GameTooltip:AddLine("Click/wheel: cycle your assignment", 0.6, 1, 0.6)
			GameTooltip:AddLine("Right-click: clear", 0.6, 1, 0.6)
			GameTooltip:Show()
		end)
		hdr:SetScript("OnLeave", function() GameTooltip:Hide() end)
		grp.header = hdr

		grp.players = {}
		for i = 1, P.MAXPERCLASS do
			-- PlayerButtonTemplate: 84x13, name left, 12px blessing icon right
			local pb = CreateFrame("Button", "PallyPowerConfig112Group" .. c .. "Player" .. i, grp)
			pb:SetWidth(84)
			pb:SetHeight(13)
			pb:SetPoint("TOPLEFT", grp, "TOPLEFT", 3, -54 - (i - 1) * 13)
			pb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			pb:EnableMouseWheel(1)
			pb.classid = c
			pb.text = P.MakeLabel(pb, GameFontHighlightSmall)
			pb.text:SetWidth(68)
			pb.text:SetHeight(13)
			pb.text:SetPoint("LEFT", pb, "LEFT", 0, 0)
			pb.icon = pb:CreateTexture(nil, "OVERLAY")
			pb.icon:SetWidth(12)
			pb.icon:SetHeight(12)
			pb.icon:SetPoint("RIGHT", pb, "RIGHT", 0, 0)
			local phl = pb:CreateTexture(nil, "HIGHLIGHT")
			phl:SetAllPoints(pb)
			phl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			phl:SetBlendMode("ADD")
			pb:SetScript("OnClick", function()
				if not this.member then return end
				if arg1 == "RightButton" then
					-- 1.14: right-click clears every paladin's 5-min assignment
					-- on this player (that we have permission to edit)
					for pally in pairs(AllPallys) do
						local has = PallyPowerKronos_NormalAssignments[pally]
							and PallyPowerKronos_NormalAssignments[pally][this.classid]
							and PallyPowerKronos_NormalAssignments[pally][this.classid][this.member.name]
						if has and P.CanControl(pally) then
							P.SetNormalAssignmentFor(pally, this.classid, this.member.name, 0)
						end
					end
				else
					-- 1.14 behavior: the name opens the per-paladin blessing menu
					P.OpenNormalMenu(this.classid, this.member)
				end
			end)
			pb:SetScript("OnMouseWheel", function()
				if not this.member then return end
				P.CycleNormalAssignment(this.classid, this.member.name, arg1 > 0)
			end)
			pb:SetScript("OnEnter", function()
				if not this.member then return end
				GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
				GameTooltip:SetText(this.member.name, 1, 1, 1)
				local blessID, isNormal = P.GetEffectiveAssignment(P.playerName, this.classid, this.member.name)
				if blessID > 0 then
					local kind = "class assignment"
					if isNormal then kind = "personal assignment" end
					GameTooltip:AddLine(P.Blessings[blessID].key .. " (" .. kind .. ")", 0.8, 0.8, 1)
				else
					GameTooltip:AddLine("No blessing assigned", 0.8, 0.8, 0.8)
				end
				GameTooltip:AddLine("Click: choose a 5-min blessing (menu)", 0.6, 1, 0.6)
				GameTooltip:AddLine("Wheel: cycle - Right-click: clear", 0.6, 1, 0.6)
				GameTooltip:Show()
			end)
			pb:SetScript("OnLeave", function() GameTooltip:Hide() end)
			grp.players[i] = pb
		end
		P.Config.groups[c] = grp
	end

	-- paladin rows (UserTemplate): name, symbols, 6 skill icons with rank+talent,
	-- and 32px assignment cells aligned under the class columns
	P.Config.rows = {}
	for p = 1, P.MAXPALLYS do
		local row = CreateFrame("Frame", "PallyPowerConfig112Row" .. p, P.Config)
		row:SetWidth(P.NAME_W + P.MAXCLASSES * P.COL_W)
		row:SetHeight(P.UROW_H)
		row:Hide()
		-- horizontal grid line above each paladin row, like the 1.14 window
		row.line = row:CreateTexture(nil, "BORDER")
		row.line:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		row.line:SetVertexColor(1, 1, 1, 0.25)
		row.line:SetHeight(2)
		row.line:SetPoint("TOPLEFT", row, "TOPLEFT", -2, 4)
		row.line:SetPoint("TOPRIGHT", row, "TOPRIGHT", 2, 4)
		row.name = P.MakeLabel(row, GameFontHighlightSmall)
		row.name:SetWidth(96)
		row.name:SetHeight(16)
		row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
		row.symbols = P.MakeLabel(row, GameFontHighlightSmall, "RIGHT")
		row.symbols:SetWidth(40)
		row.symbols:SetHeight(16)
		row.symbols:SetPoint("TOPLEFT", row, "TOPLEFT", 94, 0)
		row.skillIcons = {}
		row.skillTexts = {}
		for id = 1, 6 do
			local col = math.mod(id - 1, 3)
			local line = math.floor((id - 1) / 3)
			local icon = row:CreateTexture(nil, "OVERLAY")
			icon:SetWidth(16)
			icon:SetHeight(16)
			icon:SetPoint("TOPLEFT", row, "TOPLEFT", col * 48, -18 - line * 18)
			icon:SetTexture(P.Blessings[id].nicon)
			local txt = P.MakeLabel(row, GameFontHighlightSmall)
			txt:SetWidth(28)
			txt:SetHeight(16)
			txt:SetPoint("TOPLEFT", row, "TOPLEFT", col * 48 + 18, -18 - line * 18)
			row.skillIcons[id] = icon
			row.skillTexts[id] = txt
		end
		-- aura ranks (Devotion / Retribution / Concentration) like 1.14
		row.auraIcons = {}
		row.auraTexts = {}
		for id = 1, 3 do
			local icon = row:CreateTexture(nil, "OVERLAY")
			icon:SetWidth(16)
			icon:SetHeight(16)
			icon:SetPoint("TOPLEFT", row, "TOPLEFT", (id - 1) * 48, -54)
			icon:SetTexture(P.AuraIcons[id])
			local txt = P.MakeLabel(row, GameFontHighlightSmall)
			txt:SetWidth(28)
			txt:SetHeight(16)
			txt:SetPoint("TOPLEFT", row, "TOPLEFT", (id - 1) * 48 + 18, -54)
			row.auraIcons[id] = icon
			row.auraTexts[id] = txt
		end
		-- Lay on Hands / Divine Intervention cooldown status like 1.14
		row.cdTexts = {}
		for id = 1, 2 do
			local icon = row:CreateTexture(nil, "OVERLAY")
			icon:SetWidth(16)
			icon:SetHeight(16)
			icon:SetPoint("TOPLEFT", row, "TOPLEFT", (id - 1) * 72, -72)
			icon:SetTexture(P.CooldownIcons[id])
			local txt = P.MakeLabel(row, GameFontHighlightSmall)
			txt:SetWidth(52)
			txt:SetHeight(16)
			txt:SetPoint("TOPLEFT", row, "TOPLEFT", (id - 1) * 72 + 18, -72)
			row.cdTexts[id] = txt
		end
		row.cells = {}
		for c = 1, P.MAXCLASSES do
			local cell = CreateFrame("Button", "PallyPowerConfig112P" .. p .. "C" .. c, row)
			cell:SetWidth(32)
			cell:SetHeight(32)
			cell:SetPoint("TOPLEFT", row, "TOPLEFT", P.NAME_W + (c - 1) * P.COL_W + 26, -10)
			cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			cell:EnableMouseWheel(1)
			cell.pallyIndex = p
			cell.classid = c
			cell.icon = cell:CreateTexture(nil, "ARTWORK")
			cell.icon:SetAllPoints(cell)
			local hl = cell:CreateTexture(nil, "HIGHLIGHT")
			hl:SetWidth(38)
			hl:SetHeight(38)
			hl:SetPoint("CENTER", cell, "CENTER", 0, 0)
			hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
			hl:SetBlendMode("ADD")
			cell:SetScript("OnClick", function()
				local pname = P.Config.pallys and P.Config.pallys[this.pallyIndex]
				if not pname then return end
				if arg1 == "RightButton" then
					if not P.CanControl(pname) then return end
					if not PallyPowerKronos_Assignments[pname] then PallyPowerKronos_Assignments[pname] = {} end
					if IsShiftKeyDown() then
						P.MassAssign(pname, 0)
					else
						PallyPowerKronos_Assignments[pname][this.classid] = 0
						P.BroadcastAssignment(pname, this.classid)
						P.UpdateAll()
					end
				else
					if IsShiftKeyDown() then
						P.MassCycle(pname, this.classid, false)
					else
						P.CycleAssignment(pname, this.classid, false)
					end
				end
			end)
			cell:SetScript("OnMouseWheel", function()
				local pname = P.Config.pallys and P.Config.pallys[this.pallyIndex]
				if not pname then return end
				if IsShiftKeyDown() then
					P.MassCycle(pname, this.classid, arg1 > 0)
				else
					P.CycleAssignment(pname, this.classid, arg1 > 0)
				end
			end)
			cell:SetScript("OnEnter", function()
				local pname = P.Config.pallys and P.Config.pallys[this.pallyIndex]
				if not pname then return end
				GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
				GameTooltip:SetText(pname .. " -> " .. P.ClassLabel[this.classid], 1, 1, 1)
				local a = PallyPowerKronos_Assignments[pname] and PallyPowerKronos_Assignments[pname][this.classid]
				if a and a > 0 then
					GameTooltip:AddLine(P.Blessings[a].key, 0.8, 0.8, 1)
				else
					GameTooltip:AddLine("Nothing assigned", 0.8, 0.8, 0.8)
				end
				GameTooltip:AddLine("Click/wheel: cycle - Right-click: clear - Shift: all classes", 0.6, 1, 0.6)
				GameTooltip:Show()
			end)
			cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
			row.cells[c] = cell
		end
		P.Config.rows[p] = row
	end

	-- bottom row: GameMenu-style buttons + free-assign checkbox, like 1.14
	-- red GameMenu-style buttons, like the 1.14 window's bottom row
	local function MakeButton(name, label, x, onclick)
		local b = CreateFrame("Button", name, P.Config)
		b:SetWidth(100)
		b:SetHeight(24)
		b:SetPoint("BOTTOMLEFT", P.Config, "BOTTOMLEFT", x, 8)
		b:SetNormalTexture("Interface\\Buttons\\UI-DialogBox-Button-Up")
		b:SetPushedTexture("Interface\\Buttons\\UI-DialogBox-Button-Down")
		b:SetHighlightTexture("Interface\\Buttons\\UI-DialogBox-Button-Highlight")
		-- the dialog button texture's bottom 28% is empty padding
		local nt = b:GetNormalTexture()
		if nt then nt:SetTexCoord(0, 1, 0, 0.71875) end
		local pt = b:GetPushedTexture()
		if pt then pt:SetTexCoord(0, 1, 0, 0.71875) end
		local ht = b:GetHighlightTexture()
		if ht then
			ht:SetTexCoord(0, 1, 0, 0.71875)
			ht:SetBlendMode("ADD")
		end
		local fs = P.MakeLabel(b, GameFontNormal, "CENTER")
		fs:SetPoint("CENTER", b, "CENTER", 0, 1)
		fs:SetText(label)
		b:SetScript("OnClick", onclick)
		return b
	end
	MakeButton("PallyPowerConfig112Refresh", "Refresh", 140, function()
		AllPallys = {}
		P.ScanSpells()
		if AllPallys[P.playerName] then AllPallys[P.playerName].symbols = P.PP_Symbols end
		P.RequestSync()
		P.SendSelf()
		P.UpdateAll()
	end)
	MakeButton("PallyPowerConfig112Clear", "Clear", 246, function() P.ClearAssignments() end)
	MakeButton("PallyPowerConfig112Options", "Options", 352, function() PallyPower.ToggleOptions() end)
	P.Config.freeCheck = P.MakeCheck(P.Config, "PallyPowerConfig112Free", "Free Assignment", 0, 0,
		function() return PallyPowerKronos112_Options.freeassign end,
		function(v)
			PallyPowerKronos112_Options.freeassign = v
			P.SendSelf()
		end)
	P.Config.freeCheck:ClearAllPoints()
	P.Config.freeCheck:SetPoint("BOTTOMLEFT", P.Config, "BOTTOMLEFT", 10, 8)

	P.RestorePosition(P.Config, "cfgx", "cfgy", 0, 100)
	P.SafeCall("options window build", P.BuildOptions)
end

P.BuildOptions = function()
	P.Options = CreateFrame("Frame", "PallyPowerOptions112", UIParent)
	P.Options:SetWidth(300)
	P.Options:SetHeight(240)
	P.Options:SetFrameStrata("DIALOG")
	P.Options:SetMovable(true)
	P.Options:EnableMouse(true)
	P.Options:SetClampedToScreen(true)
	P.Options:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	P.ApplyBackdrop(P.Options, {0, 0, 0, 0.9}, P.WINDOW_BACKDROP)
	P.Options:Hide()

	local title = CreateFrame("Button", "PallyPowerOptions112Title", P.Options)
	title:SetHeight(20)
	title:SetPoint("TOPLEFT", P.Options, "TOPLEFT", 8, -6)
	title:SetPoint("TOPRIGHT", P.Options, "TOPRIGHT", -28, -6)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function() P.Options:StartMoving() end)
	title:SetScript("OnDragStop", function() P.Options:StopMovingOrSizing() end)
	local tfs = P.MakeLabel(title, GameFontNormal, "CENTER")
	tfs:SetPoint("CENTER", title, "CENTER", 0, 0)
	tfs:SetText("Pally Power - Options")

	local close = CreateFrame("Button", "PallyPowerOptions112Close", P.Options)
	close:SetWidth(24)
	close:SetHeight(24)
	close:SetPoint("TOPRIGHT", P.Options, "TOPRIGHT", -2, -2)
	close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
	close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
	close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
	close:SetScript("OnClick", function() P.Options:Hide() end)

	P.MakeCheck(P.Options, "PallyPowerOptions112Lock", "Lock the buff bar", 14, -34,
		function() return PallyPowerKronos112_Options.locked end,
		function(v) PallyPowerKronos112_Options.locked = v end)
	P.MakeCheck(P.Options, "PallyPowerOptions112Solo", "Show the buff bar when solo", 14, -60,
		function() return PallyPowerKronos112_Options.showsolo end,
		function(v)
			PallyPowerKronos112_Options.showsolo = v
			P.UpdateBar()
		end)
	P.MakeCheck(P.Options, "PallyPowerOptions112FlyoutLeft", "Flyout opens to the left", 14, -86,
		function() return PallyPowerKronos112_Options.flyoutleft end,
		function(v)
			PallyPowerKronos112_Options.flyoutleft = v
			if P.Popup then P.Popup:Hide() end
		end)

	P.MakeSlider(P.Options, "PallyPowerOptions112Scale", "Window scale", 20, -134, 0.5, 1.5, 0.05, "%.2f",
		function() return PallyPowerKronos112_Options.scale or 0.9 end,
		function(v)
			PallyPowerKronos112_Options.scale = v
			if P.Bar then P.Bar:SetScale(v) end
			if P.Popup then P.Popup:SetScale(v) end
			if P.Config then P.Config:SetScale(v) end
		end)
	P.MakeSlider(P.Options, "PallyPowerOptions112Scan", "Buff scan frequency (seconds)", 20, -188, 2, 30, 1, "%d",
		function() return PallyPowerKronos112_Options.scanfreq or 10 end,
		function(v) PallyPowerKronos112_Options.scanfreq = v end)
end

function PallyPower.ToggleOptions()
	if not P.Options then
		P.Print("The options window was never built - look for a red startup error above.", 1, 0.2, 0.2)
		return
	end
	if P.Options:IsVisible() then
		P.Options:Hide()
	else
		P.Options:Show()
	end
end

function P.UpdateConfig()
	if not P.Config or not P.Config:IsVisible() then return end
	local names = {}
	for name in pairs(AllPallys) do tinsert(names, name) end
	table.sort(names)
	P.Config.pallys = names

	-- class columns: member lists showing personal (normal) assignments
	local maxShown = 0
	for c = 1, P.MAXCLASSES do
		local grp = P.Config.groups[c]
		local members = P.roster[c] or {}
		local n = math.min(table.getn(members), P.MAXPERCLASS)
		if n > maxShown then maxShown = n end
		for i = 1, P.MAXPERCLASS do
			local pb = grp.players[i]
			local m = members[i]
			if m then
				pb.member = m
				pb.text:SetText(m.name)
				pb.text:SetTextColor(1, 1, 1)
				-- lesser (personal) blessing icon: OWN assignment bright,
				-- another paladin's dimmed - same rule as the 1.14 build
				local lesser, ownAssign = nil, false
				local own = PallyPowerKronos_NormalAssignments[P.playerName]
				own = own and own[c] and own[c][m.name]
				if own and own > 0 then
					lesser = own
					ownAssign = true
				elseif P.IAmPromoted() then
					-- full coverage view is for the raid lead/assist only;
					-- a regular paladin's list stays "my casts only"
					for pally in pairs(AllPallys) do
						local na = PallyPowerKronos_NormalAssignments[pally]
						na = na and na[c] and na[c][m.name]
						if na and na > 0 then
							lesser = na
							break
						end
					end
				end
				if lesser then
					pb.icon:SetTexture(P.Blessings[lesser].nicon)
					if ownAssign then
						pb.icon:SetVertexColor(1, 1, 1, 1)
					else
						pb.icon:SetVertexColor(0.45, 0.45, 0.45, 0.9)
					end
					pb.icon:Show()
				else
					pb.icon:Hide()
				end
				pb:Show()
			else
				pb.member = nil
				pb:Hide()
			end
		end
	end

	local headerH = 54 + maxShown * 13 + 6
	if headerH < 80 then headerH = 80 end
	local rowsTop = 25 + headerH

	local count = 0
	for p = 1, P.MAXPALLYS do
		local row = P.Config.rows[p]
		local name = names[p]
		if name then
			count = count + 1
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", P.Config, "TOPLEFT", 8, -(rowsTop + (count - 1) * P.UROW_H))
			local sk = AllPallys[name]
			row.name:SetText(name)
			if P.CanControl(name) then
				row.name:SetTextColor(1, 1, 1)
			else
				row.name:SetTextColor(1, 0.4, 0.4)
			end
			if sk and sk.symbols then
				row.symbols:SetText("|cffffd200" .. sk.symbols .. "|r")
			else
				row.symbols:SetText("")
			end
			-- 6 skill entries: icon + "rank+talent" (dimmed if not known)
			for id = 1, 6 do
				local info = sk and sk[id]
				if info then
					row.skillIcons[id]:SetVertexColor(1, 1, 1, 1)
					local t = tostring(info.rank)
					if (tonumber(info.talent) or 0) > 0 then
						t = t .. "+" .. info.talent
					end
					row.skillTexts[id]:SetText(t)
				else
					row.skillIcons[id]:SetVertexColor(0.4, 0.4, 0.4, 0.4)
					row.skillTexts[id]:SetText("")
				end
			end
			-- aura ranks (own = live scan, others = their ASELF broadcast)
			local ai
			if name == P.playerName then
				ai = P.auraInfo
			else
				ai = sk and sk.AuraInfo
			end
			for id = 1, 3 do
				local info = ai and ai[id]
				if info then
					row.auraIcons[id]:SetVertexColor(1, 1, 1, 1)
					local t = tostring(info.rank)
					if (tonumber(info.talent) or 0) > 0 then
						t = t .. "+" .. info.talent
					end
					row.auraTexts[id]:SetText(t)
				else
					row.auraIcons[id]:SetVertexColor(0.4, 0.4, 0.4, 0.4)
					row.auraTexts[id]:SetText("")
				end
			end
			-- LoH / DI cooldowns (own = live, others = their COOLDOWNS msg)
			for id = 1, 2 do
				local left
				if name == P.playerName then
					left = P.GetOwnCooldown(id)
				else
					local cds = sk and sk.CooldownInfo and sk.CooldownInfo[id]
					if cds then
						left = cds.expire - GetTime()
						if left < 0 then left = 0 end
					end
				end
				local fs = row.cdTexts[id]
				if left == nil then
					fs:SetText("")
				elseif left > 0 then
					fs:SetText(P.FormatTime(left))
					fs:SetTextColor(1, 0.3, 0.3)
				else
					fs:SetText("Ready")
					fs:SetTextColor(0, 1, 0)
				end
			end
			for c = 1, P.MAXCLASSES do
				local cell = row.cells[c]
				local a = PallyPowerKronos_Assignments[name] and PallyPowerKronos_Assignments[name][c]
				if a and a > 0 then
					local b = P.Blessings[a]
					cell.icon:SetTexture(b.gicon or b.nicon)
					cell.icon:Show()
				else
					-- unassigned shows nothing, like 1.14 (cell stays clickable)
					cell.icon:Hide()
				end
			end
			row:Show()
		else
			row:Hide()
		end
	end

	for c = 1, P.MAXCLASSES do
		P.Config.groups[c].line:SetHeight(headerH + count * P.UROW_H)
	end
	P.Config:SetHeight(rowsTop + count * P.UROW_H + 44)
end

function PallyPower.ToggleConfig()
	if not P.Config then
		P.Print("The assignments window was never built - look for a red startup error above.", 1, 0.2, 0.2)
		return
	end
	if P.Config:IsVisible() then
		P.Config:Hide()
	else
		P.Config:Show()
		P.SafeCall("assignments window update", P.UpdateConfig)
	end
end

-- ----------------------------------------------------------------------------
-- Update dispatcher
-- ----------------------------------------------------------------------------
P.UpdateAll = function()
	P.SafeCall("buff bar update", P.UpdateBar)
	P.SafeCall("popup update", P.UpdatePopup)
	P.SafeCall("assignments window update", P.UpdateConfig)
end

-- ----------------------------------------------------------------------------
-- Events and driver
-- ----------------------------------------------------------------------------
function P.PrunePallys()
	-- drop paladins that left the group
	local present = {}
	local unresolved = false
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local name = GetRaidRosterInfo(i)
			if name and name ~= UNKNOWNOBJECT then present[name] = true else unresolved = true end
		end
	else
		present[P.playerName] = true
		for i = 1, GetNumPartyMembers() do
			local n = UnitName("party" .. i)
			if n and n ~= UNKNOWNOBJECT then present[n] = true else unresolved = true end
		end
	end
	-- names read "Unknown" right after zoning; pruning on such a pass would drop real paladins
	if unresolved then return end
	for name in pairs(AllPallys) do
		if name ~= P.playerName and not present[name] then
			AllPallys[name] = nil
		end
	end
end

local driver = CreateFrame("Frame", "PallyPowerDriver112", UIParent)
driver:RegisterEvent("VARIABLES_LOADED")
driver:RegisterEvent("PLAYER_LOGOUT")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("SPELLS_CHANGED")
driver:RegisterEvent("CHAT_MSG_ADDON")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
driver:RegisterEvent("BAG_UPDATE")
driver:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
driver:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS")
driver:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
driver:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
driver:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_PARTY")
driver:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")

driver:SetScript("OnEvent", function()
	if event == "VARIABLES_LOADED" then
		P.InitSavedVars()
		return
	end

	if event == "PLAYER_LOGOUT" then
		-- persist buff timers as wall-clock expiries so they survive
		-- reloads and relogs (the 1.14 build gets this from LCD_Data)
		local saveTbl = {}
		local saveNormal = {}
		local now = GetTime()
		local epoch = time()
		for name, byBless in pairs(P.buffExpire) do
			for id, exp in pairs(byBless) do
				local left = exp - now
				if left > 0 then
					if not saveTbl[name] then saveTbl[name] = {} end
					saveTbl[name][id] = epoch + left
					if not P.IsTrackedGreater(name, id) then
						if not saveNormal[name] then saveNormal[name] = {} end
						saveNormal[name][id] = 1
					end
				end
			end
		end
		PallyPowerKronos112_Options.buffEpoch = saveTbl
		PallyPowerKronos112_Options.buffEpochNormal = saveNormal
		return
	end

	if event == "PLAYER_LOGIN" or (event == "PLAYER_ENTERING_WORLD" and not P.playerName) then
		P.playerName = UnitName("player")
		P.InitSavedVars()
		-- restore buff timers saved at the last reload/logout
		if PallyPowerKronos112_Options.buffEpoch then
			local now = GetTime()
			local epoch = time()
			for name, byBless in pairs(PallyPowerKronos112_Options.buffEpoch) do
				for id, exp in pairs(byBless) do
					local left = exp - epoch
					if left > 0 then
						if not P.buffExpire[name] then P.buffExpire[name] = {} end
						P.buffExpire[name][id] = now + left
						local n = PallyPowerKronos112_Options.buffEpochNormal
						if n and n[name] and n[name][id] then
							P.SetTrackedGreater(name, id, false)
						end
					end
				end
			end
			PallyPowerKronos112_Options.buffEpoch = nil
			PallyPowerKronos112_Options.buffEpochNormal = nil
		end
		P.SafeCall("startup (spell/inventory scan)", function()
			P.ScanSpells()
			P.ScanInventory()
		end)
		if not P.Bar then
			P.SafeCall("buff bar build", P.BuildBar)
			P.SafeCall("popup build", P.BuildPopup)
			P.SafeCall("assignments window build", P.BuildConfig)
		end
		P.pendingSync = GetTime() + 5
		P.nextScan = 2
		P.UpdateAll()
		return
	end

	if not P.playerName then return end

	if event == "SPELLS_CHANGED" then
		P.ScanSpells()
		if P.initialized and P.GroupChannel() then P.pendingSelf = GetTime() + 2 end
		return
	end

	if event == "CHAT_MSG_ADDON" then
		if (arg1 == P.PP_PREFIX or arg1 == "PLPWRX") and (arg3 == "PARTY" or arg3 == "RAID") then
			P.ParseMessage(arg4, arg2, arg1)
		end
		return
	end

	if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		local size = GetNumRaidMembers() + GetNumPartyMembers()
		if size > 0 and P.lastGroupSize == 0 then
			P.pendingSync = GetTime() + 3
		end
		P.lastGroupSize = size
		P.PrunePallys()
		P.nextScan = 1
		return
	end

	if event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" then
		if P.nextScan > 2 then P.nextScan = 2 end
		return
	end

	if event == "BAG_UPDATE" then
		local old = P.PP_Symbols
		P.ScanInventory()
		if old ~= P.PP_Symbols then
			P.SendMessage("SYMCOUNT " .. P.PP_Symbols)
			P.UpdateBar()
		end
		return
	end

	if string.find(event, "^CHAT_MSG_SPELL") then
		P.HandleCombatLog(event, arg1)
		return
	end
end)

driver:SetScript("OnUpdate", function()
	if not P.playerName or not P.initialized then return end
	local e = arg1 or 0

	if P.scanRoster then
		P.SafeCall("buff scan", P.ProcessScanQueue)
	else
		P.nextScan = P.nextScan - e
		if P.nextScan <= 0 and P.isPally then
			P.SafeCall("scan setup", P.BuildScanQueue)
		end
	end

	if P.pendingSync and GetTime() >= P.pendingSync then
		P.pendingSync = nil
		P.pendingSelf = nil
		P.RequestSync()
		P.SendSelf()
	end
	if P.pendingSelf and GetTime() >= P.pendingSelf then
		P.pendingSelf = nil
		P.SendSelf()
	end

	P.timerAcc = P.timerAcc + e
	if P.timerAcc >= 1 then
		P.timerAcc = 0
		if P.Bar and P.Bar:IsVisible() then P.SafeCall("buff bar update", P.UpdateBar) end
		if P.Config and P.Config:IsVisible() then
			P.SafeCall("assignments window update", P.UpdateConfig)
		end
		-- push LoH/DI cooldown transitions to the group (1.12 has no
		-- SPELL_UPDATE_COOLDOWN event, so poll once a second)
		if P.isPally then
			local s1 = (P.GetOwnCooldown(1) or 0) > 1
			local s2 = (P.GetOwnCooldown(2) or 0) > 1
			if s1 ~= P.lastCd1 or s2 ~= P.lastCd2 then
				P.lastCd1, P.lastCd2 = s1, s2
				P.SendStatus()
			end
		end
		if P.Popup and P.Popup:IsVisible() then
			-- hide the popup once the mouse leaves both the bar and the popup
			if not P.IsMouseOver(P.Popup) and not (P.Bar and P.IsMouseOver(P.Bar)) then
				P.Popup:Hide()
			else
				P.UpdatePopup()
			end
		end
	end
end)

-- ----------------------------------------------------------------------------
-- Slash commands
-- ----------------------------------------------------------------------------
SlashCmdList["PALLYPOWER"] = function(msg)
	msg = string.lower(msg or "")
	if msg == "report" then
		P.Report()
	elseif msg == "clear" then
		P.ClearAssignments()
	elseif msg == "free" then
		PallyPowerKronos112_Options.freeassign = not PallyPowerKronos112_Options.freeassign
		local state = "OFF"
		if PallyPowerKronos112_Options.freeassign then state = "ON" end
		P.Print("Free assignment is now " .. state)
		P.SendSelf()
	elseif msg == "lock" then
		PallyPowerKronos112_Options.locked = not PallyPowerKronos112_Options.locked
		local state = "unlocked"
		if PallyPowerKronos112_Options.locked then state = "locked" end
		P.Print("Buff bar " .. state)
	elseif msg == "solo" then
		PallyPowerKronos112_Options.showsolo = not PallyPowerKronos112_Options.showsolo
		P.UpdateBar()
	elseif msg == "bar" then
		if P.Bar then
			if P.Bar:IsVisible() then P.Bar:Hide() else P.UpdateBar() end
		end
	elseif string.find(msg, "^scale") then
		local _, _, v = string.find(msg, "scale (%d+%.?%d*)")
		v = tonumber(v)
		if v and v >= 0.5 and v <= 2 then
			PallyPowerKronos112_Options.scale = v
			if P.Bar then P.Bar:SetScale(v) end
			if P.Config then P.Config:SetScale(v) end
		else
			P.Print("Usage: /pp scale 0.5-2.0")
		end
	elseif msg == "sync" then
		P.RequestSync()
		P.SendSelf()
	elseif msg == "" then
		PallyPower.ToggleConfig()
	else
		P.Print("PallyPower (1.12 build) commands:")
		P.Print("/pp - toggle the assignment grid")
		P.Print("/pp bar - toggle the buff bar")
		P.Print("/pp report - report assignments to the group")
		P.Print("/pp clear - clear assignments")
		P.Print("/pp free - allow others to edit your assignments")
		P.Print("/pp lock | solo | sync | scale <n>")
	end
end
