--[[
  StablePlates 1.06 - made by feralpaw
  WoW 3.3.5a, works on top of TidyPlates or ElvUI nameplates (does not change them).

  Two modes:
  native (default)
  * Uses the Rebuffed client's own nameplate stacking, so plates stay clickable.
  * Plates sit closer together and move slower/calmer than the default stacking.

  visual (/sp mode visual)
  * Turns off the client's own nameplate spreading/stacking (the jumpy vertical stacking).
  * Your target's nameplate always stays exactly over its unit.
  * Every other nameplate stays over its unit too, unless it overlaps one that was
    there before it. Then it is pushed sideways (never up/down), and it keeps that side.
    Older plates keep their spot, new plates go to the side.
  * Plates slide smoothly instead of jumping.
  * Only the visible TidyPlates / ElvUI frame is moved. The click area (hitbox) stays at the unit.
]]

local ADDON = "StablePlates"

local defaults = {
	enabled  = true,
	width    = 0,    -- footprint width of one plate, 0 = auto (measured)
	height   = 20,   -- footprint height (bar + name)
	gapX     = 2,    -- horizontal space between plates
	gapY     = 0,    -- extra vertical space that still counts as "overlapping"
	speed    = 14,   -- slide speed (higher = faster, 0 = instant)
	friendly = true, -- also arrange friendly plates
	-- native mode (Rebuffed stacking)
	mode     = "native",
	ySpace   = 24,   -- vertical distance between stacked plates (Rebuffed default 20)
	xSpace   = 0,    -- how wide a plate counts for stacking, 0 = leave client value
	smooth   = 1,    -- move speed of stacked plates, 0-5 (lower = calmer)
	raise    = 50,   -- max. distance a plate is pushed up (Rebuffed default 200)
}

-- visual mode: the client must stop moving plates on its own
local CVARS_VISUAL = {
	nameplateAllowOverlap = "1", -- client spreading off
	nameplateStacking     = "0", -- Rebuffed stacking off
	spreadnameplates      = "0", -- older name of the client spreading option
}

local db
local cvarsNative = {}
local function GetWantedCVars()
	if db.mode == "visual" then return CVARS_VISUAL end
	wipe(cvarsNative)
	cvarsNative.nameplateAllowOverlap = "1" -- old client spreading off
	cvarsNative.nameplateStacking     = "1" -- Rebuffed stacking on
	cvarsNative.nameplateYSpace       = tostring(db.ySpace)
	if db.xSpace and db.xSpace > 0 then
		cvarsNative.nameplateXSpace = tostring(db.xSpace)
	end
	if db.raise and db.raise > 0 then
		cvarsNative.nameplateMaxRaiseDistance = tostring(db.raise)
	end
	local speed = tostring(db.smooth)
	cvarsNative.nameplateSpeedRaise = speed
	cvarsNative.nameplateSpeedLower = speed
	cvarsNative.nameplateSpeedReset = speed
	return cvarsNative
end

local abs, min, sort, select = math.abs, math.min, table.sort, select
local WorldFrame = WorldFrame

local plates = {}      -- every TidyPlates nameplate we know
local known = {}
local active = {}      -- plates handled this frame
local numActive = 0
local orderCounter = 0
local numChildren = -1
local scanTimer = 0
local currentTarget
local applying = false

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99StablePlates|r: " .. msg)
end

-------------------------------------------------------------------------------
-- CVars
-------------------------------------------------------------------------------
local function GetCVarSafe(name)
	local ok, value = pcall(GetCVar, name)
	if ok then return value end
end

local function ApplyCVars()
	db.savedCVars = db.savedCVars or {}
	for name, value in pairs(GetWantedCVars()) do
		local old = GetCVarSafe(name)
		if old ~= nil then
			if db.savedCVars[name] == nil then
				db.savedCVars[name] = old
			end
			if old ~= value then
				pcall(SetCVar, name, value)
			end
		end
	end
end

local function RestoreCVars()
	if not db.savedCVars then return end
	for name, value in pairs(db.savedCVars) do
		pcall(SetCVar, name, value)
	end
	db.savedCVars = nil
end

-------------------------------------------------------------------------------
-- Nameplate addons: TidyPlates (plate.extended) and ElvUI (plate.UnitFrame)
-------------------------------------------------------------------------------
local function GetVisual(plate)
	return plate.UnitFrame or plate.extended
end

local function IsTarget(plate)
	local elv = plate.UnitFrame
	if elv then return elv.isTarget and true or false end
	local unit = plate.extended.unit
	return unit and unit.isTarget or false
end

local function IsFriendly(plate)
	local elv = plate.UnitFrame
	if elv then
		local t = elv.UnitType
		return t == "FRIENDLY_PLAYER" or t == "FRIENDLY_NPC"
	end
	local unit = plate.extended.unit
	return unit and unit.reaction == "FRIENDLY"
end

-- width of the visible plate, in nameplate units
local function MeasureWidth(plate, visual)
	local elv = plate.UnitFrame
	if elv then
		local health = elv.Health
		if health and health:IsShown() then
			return health:GetWidth() * (health:GetScale() or 1)
		end
		local name = elv.Name
		if name and name:IsShown() then
			return (name:GetStringWidth() or 60) + 4
		end
		return 100
	end
	return 104 * (visual:GetScale() or 1) -- TidyPlates Neon health bar
end

local function ApplyOffset(plate, offset)
	local elv = plate.UnitFrame
	applying = true
	if elv then
		-- ElvUI anchors its frame with SetAllPoints to the nameplate
		elv:ClearAllPoints()
		elv:SetPoint("TOPLEFT", plate, "TOPLEFT", offset, 0)
		elv:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", offset, 0)
	else
		local ext = plate.extended
		local style = ext.style and ext.style.frame
		local anchor = style and style.anchor or "CENTER"
		local x = style and style.x or 0
		local y = style and style.y or 0
		local scale = ext:GetScale()
		if not scale or scale <= 0 then scale = 1 end
		ext:SetPoint(anchor, plate, anchor, x + offset / scale, y)
	end
	applying = false
	plate.spApplied = offset
end

local function ResetPlate(plate)
	plate.spOrder, plate.spSide = nil, nil
	if plate.spApplied and plate.spApplied ~= 0 then
		ApplyOffset(plate, 0)
	end
	plate.spOff = 0
end

local function AddPlate(plate)
	known[plate] = true
	plates[#plates + 1] = plate
	-- if the nameplate addon re-anchors its frame, apply our offset again
	hooksecurefunc(GetVisual(plate), "SetPoint", function()
		if not applying then plate.spApplied = nil end
	end)
end

local function ScanChildren(...)
	for i = 1, select("#", ...) do
		local frame = select(i, ...)
		if not known[frame] and (frame.UnitFrame or frame.extended) then
			AddPlate(frame)
		end
	end
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------
local function SortPlates(a, b)
	if a == b then return false end
	if a == currentTarget then return true end
	if b == currentTarget then return false end
	return a.spOrder < b.spOrder
end

local function OnUpdate(self, elapsed)
	-- find new nameplates
	scanTimer = scanTimer + elapsed
	local count = WorldFrame:GetNumChildren()
	if count ~= numChildren or scanTimer > 1 then
		numChildren = count
		scanTimer = 0
		ScanChildren(WorldFrame:GetChildren())
		ApplyCVars() -- ElvUI sets its own value when its options change
	end

	-- collect visible plates
	numActive = 0
	currentTarget = nil
	local width, height = db.width, db.height
	for i = 1, #plates do
		local plate = plates[i]
		local ext = GetVisual(plate)
		local use = plate:IsShown() and ext:IsShown() and ext:GetAlpha() > 0.01
			and (db.friendly or not IsFriendly(plate))
		local x, y
		if use then
			x, y = plate:GetCenter()
			use = x ~= nil
		end
		if use then
			if not plate.spOrder then
				orderCounter = orderCounter + 1
				plate.spOrder = orderCounter
				plate.spSide = nil
				plate.spNew = true
			end
			local scale = ext:GetScale() or 1
			plate.spX, plate.spY = x, y
			if width and width > 0 then
				plate.spW = width * scale
			else
				plate.spW = MeasureWidth(plate, ext)
			end
			plate.spH = height * scale
			numActive = numActive + 1
			active[numActive] = plate
			if IsTarget(plate) then
				currentTarget = plate
			end
		elseif plate.spOrder then
			ResetPlate(plate)
		end
	end
	for i = numActive + 1, #active do active[i] = nil end
	if numActive == 0 then return end

	sort(active, SortPlates)

	-- place plates: target first, then oldest to newest
	local gapX, gapY = db.gapX, db.gapY
	local k = db.speed > 0 and min(1, elapsed * db.speed) or 1
	for i = 1, numActive do
		local p = active[i]
		local x = p.spX
		if i > 1 then
			local moved, guard = true, 0
			while moved and guard <= numActive do
				moved = false
				guard = guard + 1
				for j = 1, i - 1 do
					local q = active[j]
					local minX = (p.spW + q.spW) * 0.5 + gapX
					local dx = x - q.spPX
					if abs(dx) < minX and abs(p.spY - q.spY) < (p.spH + q.spH) * 0.5 + gapY then
						local side = p.spSide
						if not side then
							if dx ~= 0 then
								side = dx > 0 and 1 or -1
							elseif currentTarget and p.spX ~= currentTarget.spX then
								side = p.spX > currentTarget.spX and 1 or -1
							else
								side = (p.spOrder % 2 == 0) and 1 or -1
							end
							p.spSide = side
						end
						x = q.spPX + side * minX
						moved = true
					end
				end
			end
		end
		p.spPX = x

		local desired = x - p.spX
		if desired == 0 then p.spSide = nil end

		local cur = p.spOff or 0
		if p.spNew then
			cur = desired -- new plates appear directly at their spot
			p.spNew = nil
		else
			cur = cur + (desired - cur) * k
			if abs(desired - cur) < 0.5 then cur = desired end
		end
		p.spOff = cur

		local applied = p.spApplied
		if applied == nil or abs(applied - cur) > 0.2 then
			ApplyOffset(p, cur)
		end
	end
end

-------------------------------------------------------------------------------
-- Enable / disable
-------------------------------------------------------------------------------
local driver = CreateFrame("Frame")

-- native mode: only keep our CVars in place (ElvUI changes them on config changes)
local checkTimer = 0
local function OnUpdateNative(self, elapsed)
	checkTimer = checkTimer + elapsed
	if checkTimer > 1 then
		checkTimer = 0
		ApplyCVars()
	end
end

local function Enable()
	ApplyCVars()
	if db.mode == "visual" then
		driver:SetScript("OnUpdate", OnUpdate)
	else
		for i = 1, #plates do ResetPlate(plates[i]) end
		driver:SetScript("OnUpdate", OnUpdateNative)
	end
end

local function Disable()
	driver:SetScript("OnUpdate", nil)
	for i = 1, #plates do ResetPlate(plates[i]) end
	RestoreCVars()
end

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------
local numberOptions = { width = true, height = true, gap = true, gapy = true, speed = true,
	yspace = "ySpace", xspace = "xSpace", smooth = "smooth", raise = "raise" }

SLASH_STABLEPLATES1 = "/sp"
SLASH_STABLEPLATES2 = "/stableplates"
SlashCmdList.STABLEPLATES = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "on" then
		db.enabled = true
		Enable()
		Print("on")
	elseif cmd == "off" then
		db.enabled = false
		Disable()
		Print("off (client nameplate settings restored)")
	elseif cmd == "mode" then
		if arg ~= "native" and arg ~= "visual" then
			Print("use /sp mode native  or  /sp mode visual")
			return
		end
		RestoreCVars()
		db.mode = arg
		if db.enabled then Enable() end
		Print("mode = " .. arg)
	elseif cmd == "test" then
		local TEST_CVARS = { nameplateShowFriends = "1", nameplateStackFriendly = "1" }
		if db.testSaved then
			for name, value in pairs(db.testSaved) do pcall(SetCVar, name, value) end
			db.testSaved = nil
			Print("test mode off (friendly nameplate settings restored)")
		else
			db.testSaved = {}
			for name, value in pairs(TEST_CVARS) do
				local old = GetCVarSafe(name)
				if old ~= nil then
					db.testSaved[name] = old
					pcall(SetCVar, name, value)
				end
			end
			Print("test mode on: friendly nameplates are shown and stacked like enemy plates.")
			Print("Go to a crowded place (e.g. Dalaran), try /sp smooth and /sp yspace. Type /sp test again to end it.")
			if db.mode ~= "native" then
				Print("note: you are in visual mode, use /sp mode native to test the clickable stacking.")
			end
		end
	elseif cmd == "friendly" then
		db.friendly = (arg ~= "off")
		if not db.friendly then
			for i = 1, #plates do
				if IsFriendly(plates[i]) then ResetPlate(plates[i]) end
			end
		end
		Print("friendly plates " .. (db.friendly and "on" or "off"))
	elseif numberOptions[cmd] then
		local value = tonumber(arg)
		if not value then
			Print("need a number, e.g. /sp " .. cmd .. " 4")
			return
		end
		if cmd == "smooth" then value = math.max(0, math.min(5, value)) end
		if cmd == "gap" then db.gapX = value
		elseif cmd == "gapy" then db.gapY = value
		elseif type(numberOptions[cmd]) == "string" then db[numberOptions[cmd]] = value
		else db[cmd] = value end
		if db.enabled then ApplyCVars() end
		Print(cmd .. " = " .. value)
	elseif cmd == "reset" then
		RestoreCVars()
		for key, value in pairs(defaults) do db[key] = value end
		if db.enabled then Enable() end
		Print("settings reset")
	else
		Print("commands:")
		Print("/sp on | off")
		Print("/sp mode native | visual  (now " .. db.mode .. ")")
		Print("|cffaaaaaanative mode (clickable plates):|r")
		Print(("/sp yspace <n>  vertical distance between plates (now %s, client default 20)"):format(db.ySpace))
		Print(("/sp xspace <n>  plate width used for stacking, 0 = client value (now %s)"):format(db.xSpace))
		Print(("/sp smooth <0-5>  move speed, lower = calmer (now %s)"):format(db.smooth))
		Print(("/sp raise <n>  max. height plates are pushed up (now %s, client default 200)"):format(db.raise))
		Print("|cffaaaaaavisual mode (sideways, bars only, not clickable at the moved spot):|r")
		Print(("/sp gap <n>  space between plates (now %s)"):format(db.gapX))
		Print(("/sp width <n>  plate width, 0 = auto (now %s)"):format(db.width))
		Print(("/sp height <n>  plate height (now %s)"):format(db.height))
		Print(("/sp speed <n>  slide speed, 0 = instant (now %s)"):format(db.speed))
		Print("/sp friendly on | off  also arrange friendly plates (now " .. (db.friendly and "on" or "off") .. ")")
		Print("/sp test  show + stack friendly plates for testing (again = off)" .. (db.testSaved and " |cff00ff00(on)|r" or ""))
		Print("/sp reset")
		Print("|cffffd100made by feralpaw|r")
	end
end

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function()
	StablePlatesDB = StablePlatesDB or {}
	db = StablePlatesDB
	for key, value in pairs(defaults) do
		if db[key] == nil then db[key] = value end
	end
	if (db.version or 1) < 2 then
		db.width = 0 -- v2: width is measured automatically
		db.version = 2
	end
	if db.version < 3 then
		db.mode = "native" -- v3: clickable Rebuffed stacking is the default
		db.version = 3
	end
	if db.version < 4 then
		db.raise = defaults.raise -- v4: limit how high plates are pushed
		db.version = 4
	end
	if db.version < 5 then
		-- v5: tested defaults (yspace 24, raise 50, smooth 1)
		db.ySpace, db.raise, db.smooth = defaults.ySpace, defaults.raise, defaults.smooth
		db.version = 5
	end
	if db.enabled then Enable() end
	Print("v1.06 loaded, type /sp for options. |cffffd100made by feralpaw|r")
end)
