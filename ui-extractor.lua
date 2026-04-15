-- Source code originally written by mspaint-cc, redesigned to work with our UI library.

local cloneref = cloneref or clonereference or function(instance)
	return instance
end

local Players = cloneref(game:GetService("Players"))
local HttpService = cloneref(game:GetService("HttpService"))

local Library = (getgenv and (getgenv().library or getgenv().lib)) or nil
local ScreenGui = Library and Library.items or nil

local UIExtractor = {}
UIExtractor.__index = UIExtractor

local function stripRichText(text)
	text = tostring(text or "")
	return (text:gsub("<.->", ""))
end

local function serializeValue(value, seen)
	local valueType = typeof(value)
	if valueType == "Vector2" then
		return { x = value.X, y = value.Y }
	elseif valueType == "Color3" then
		return { r = value.R, g = value.G, b = value.B }
	elseif valueType == "UDim2" then
		return {
			X = { Scale = value.X.Scale, Offset = value.X.Offset },
			Y = { Scale = value.Y.Scale, Offset = value.Y.Offset },
		}
	elseif valueType == "Rect" then
		return {
			Min = { X = value.Min.X, Y = value.Min.Y },
			Max = { X = value.Max.X, Y = value.Max.Y },
		}
	elseif valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "Instance" then
		return value:GetFullName()
	elseif type(value) == "table" then
		seen = seen or {}
		if seen[value] then
			return "<cycle>"
		end
		seen[value] = true

		local result = {}
		for key, nestedValue in next, value do
			result[tostring(key)] = serializeValue(nestedValue, seen)
		end

		seen[value] = nil
		return result
	end

	return value
end

local function sortGuiObjects(objects)
	table.sort(objects, function(left, right)
		local leftOrder = left.LayoutOrder or 0
		local rightOrder = right.LayoutOrder or 0
		if leftOrder ~= rightOrder then
			return leftOrder < rightOrder
		end

		local leftY = left.AbsolutePosition.Y or 0
		local rightY = right.AbsolutePosition.Y or 0
		if leftY ~= rightY then
			return leftY < rightY
		end

		return (left.AbsolutePosition.X or 0) < (right.AbsolutePosition.X or 0)
	end)
	return objects
end

local function getGuiChildren(parent, predicate)
	local children = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("GuiObject") and (not predicate or predicate(child)) then
			children[#children + 1] = child
		end
	end
	return sortGuiObjects(children)
end

local function getDirectChildrenOfClass(parent, className)
	local children = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.ClassName == className then
			children[#children + 1] = child
		end
	end
	return sortGuiObjects(children)
end

local function findDirectChild(parent, predicate)
	for _, child in ipairs(parent:GetChildren()) do
		if predicate(child) then
			return child
		end
	end
	return nil
end

local function findDescendant(parent, predicate)
	for _, descendant in ipairs(parent:GetDescendants()) do
		if predicate(descendant) then
			return descendant
		end
	end
	return nil
end

local function getDirectTextLabels(parent)
	local labels = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("TextLabel") then
			labels[#labels + 1] = child
		end
	end
	return sortGuiObjects(labels)
end

local function getPrimaryTextLabel(parent)
	local labels = getDirectTextLabels(parent)
	table.sort(labels, function(left, right)
		local leftBrightness = left.TextColor3.R + left.TextColor3.G + left.TextColor3.B
		local rightBrightness = right.TextColor3.R + right.TextColor3.G + right.TextColor3.B
		if leftBrightness ~= rightBrightness then
			return leftBrightness > rightBrightness
		end
		return (left.AbsolutePosition.X or 0) < (right.AbsolutePosition.X or 0)
	end)
	return labels[1]
end

local function getSecondaryTextLabel(parent)
	local primary = getPrimaryTextLabel(parent)
	for _, label in ipairs(getDirectTextLabels(parent)) do
		if label ~= primary then
			return label
		end
	end
	return nil
end

local function getButtonText(button)
	local label = findDirectChild(button, function(child)
		return child:IsA("TextLabel")
	end) or findDescendant(button, function(child)
		return child:IsA("TextLabel")
	end)

	return label and stripRichText(label.Text) or ""
end

local function getButtonIcon(button)
	local image = findDirectChild(button, function(child)
		return child:IsA("ImageLabel") or child:IsA("ImageButton")
	end) or findDescendant(button, function(child)
		return child:IsA("ImageLabel") or child:IsA("ImageButton")
	end)

	if not image then
		return nil
	end

	return {
		image = image.Image,
		imageRectOffset = serializeValue(image.ImageRectOffset),
		imageRectSize = serializeValue(image.ImageRectSize),
		imageColor = serializeValue(image.ImageColor3),
	}
end

local function isBright(color)
	return color and (color.R + color.G + color.B) >= 2.2
end

local function tryFireSignal(signal)
	if not signal then
		return false
	end

	if type(firesignal) == "function" then
		local ok = pcall(firesignal, signal)
		if ok then
			return true
		end
	end

	if type(getconnections) == "function" then
		local ok, connections = pcall(getconnections, signal)
		if ok and type(connections) == "table" then
			for _, connection in ipairs(connections) do
				if connection.Fire then
					local fired = pcall(connection.Fire, connection)
					if fired then
						return true
					end
				elseif connection.Function then
					local fired = pcall(connection.Function)
					if fired then
						return true
					end
				end
			end
		end
	end

	return false
end

local function activateButton(button, preferMouseDown)
	if not button then
		return false
	end

	local signals = preferMouseDown and {
		button.MouseButton1Down,
		button.MouseButton1Click,
		button.Activated,
	} or {
		button.MouseButton1Click,
		button.MouseButton1Down,
		button.Activated,
	}

	for _, signal in ipairs(signals) do
		if tryFireSignal(signal) then
			task.wait(0.12)
			return true
		end
	end

	return false
end

function UIExtractor:new()
	return setmetatable({
		extractedData = {
			metadata = {},
			flags = {},
			structure = {},
			tabs = {},
		},
		warnings = {},
	}, UIExtractor)
end

function UIExtractor:addWarning(message)
	self.warnings[#self.warnings + 1] = tostring(message)
end

function UIExtractor:findMainWindow()
	if not ScreenGui then
		return nil
	end

	local bestCandidate
	local bestScore = -math.huge

	for _, child in ipairs(ScreenGui:GetChildren()) do
		if child:IsA("Frame") then
			local score = 0
			if child.AbsoluteSize.X >= 600 then
				score = score + 15
			end
			if child.AbsoluteSize.Y >= 400 then
				score = score + 10
			end

			for _, descendant in ipairs(child:GetDescendants()) do
				if descendant:IsA("TextLabel") then
					local text = tostring(descendant.Text or "")
					if text:find("%.rest") then
						score = score + 25
					end
					if text:find(tostring(game.PlaceId), 1, true) then
						score = score + 10
					end
				end
			end

			if score > bestScore then
				bestScore = score
				bestCandidate = child
			end
		end
	end

	return bestCandidate
end

function UIExtractor:findSidebarHolder(mainWindow)
	local bestCandidate
	local bestScore = -1

	for _, frame in ipairs(mainWindow:GetDescendants()) do
		if frame:IsA("Frame") and frame.AbsoluteSize.X <= 240 then
			local score = 0
			for _, child in ipairs(frame:GetChildren()) do
				if child:IsA("TextButton") and child:FindFirstChildWhichIsA("TextLabel") and child:FindFirstChildWhichIsA("ImageLabel") then
					score = score + 10
				elseif child:IsA("TextLabel") then
					score = score + 1
				end
			end

			if frame:FindFirstChildOfClass("UIListLayout") then
				score = score + 5
			end

			if score > bestScore then
				bestScore = score
				bestCandidate = frame
			end
		end
	end

	return bestCandidate
end

function UIExtractor:findPageButtonHolder(mainWindow)
	local bestCandidate
	local bestScore = -1

	for _, frame in ipairs(mainWindow:GetDescendants()) do
		if frame:IsA("Frame") and frame.AbsoluteSize.Y <= 80 and frame.AbsoluteSize.X >= 180 then
			local buttonCount = 0
			for _, child in ipairs(frame:GetChildren()) do
				if child:IsA("TextButton") and child:FindFirstChildWhichIsA("TextLabel") then
					buttonCount = buttonCount + 1
				end
			end

			if buttonCount > 0 and frame:FindFirstChildOfClass("UIListLayout") then
				local score = (buttonCount * 10) + math.floor(frame.AbsoluteSize.X / 100)
				if score > bestScore then
					bestScore = score
					bestCandidate = frame
				end
			end
		end
	end

	return bestCandidate
end

function UIExtractor:findActiveTabHolder(mainWindow)
	for _, child in ipairs(mainWindow:GetChildren()) do
		if child:IsA("Frame") and child.Visible and child.AbsoluteSize.X > 260 and child.AbsoluteSize.Y > 180 then
			local pageRoot = findDirectChild(child, function(grandChild)
				return grandChild:IsA("Frame") and grandChild.Visible and grandChild:FindFirstChildOfClass("UIListLayout") ~= nil
			end)
			if pageRoot then
				return child, pageRoot
			end
		end
	end

	return nil, nil
end

function UIExtractor:getTabButtons(sidebarHolder)
	local tabs = {}
	local separators = {}

	for _, child in ipairs(getGuiChildren(sidebarHolder)) do
		if child:IsA("TextButton") and child:FindFirstChildWhichIsA("ImageLabel") and child:FindFirstChildWhichIsA("TextLabel") then
			tabs[#tabs + 1] = {
				button = child,
				name = getButtonText(child),
				icon = getButtonIcon(child),
				order = child.LayoutOrder or (#tabs + 1),
			}
		elseif child:IsA("TextLabel") then
			separators[#separators + 1] = {
				name = stripRichText(child.Text),
				order = child.LayoutOrder or (#separators + 1),
			}
		end
	end

	return tabs, separators
end

function UIExtractor:getPageButtons(pageButtonHolder)
	local pages = {}
	if not pageButtonHolder then
		return pages
	end

	for _, child in ipairs(getGuiChildren(pageButtonHolder)) do
		if child:IsA("TextButton") and child:FindFirstChildWhichIsA("TextLabel") then
			pages[#pages + 1] = {
				button = child,
				name = getButtonText(child),
				order = child.LayoutOrder or (#pages + 1),
			}
		end
	end

	return pages
end

function UIExtractor:getActiveTabName(sidebarHolder)
	for _, child in ipairs(getGuiChildren(sidebarHolder)) do
		if child:IsA("TextButton") then
			local label = findDirectChild(child, function(descendant)
				return descendant:IsA("TextLabel")
			end)
			if label and isBright(label.TextColor3) then
				return stripRichText(label.Text)
			end
		end
	end
	return nil
end

function UIExtractor:getActivePageName(pageButtonHolder)
	for _, child in ipairs(getGuiChildren(pageButtonHolder)) do
		if child:IsA("TextButton") then
			local label = findDirectChild(child, function(descendant)
				return descendant:IsA("TextLabel")
			end)
			if label and isBright(label.TextColor3) then
				return stripRichText(label.Text)
			end
		end
	end
	return nil
end

function UIExtractor:activateTab(tabButton)
	if not tabButton then
		return false
	end
	return activateButton(tabButton, true)
end

function UIExtractor:activatePage(pageButton)
	if not pageButton then
		return false
	end
	return activateButton(pageButton, true)
end

function UIExtractor:getSectionElementsContainer(sectionOutline)
	local inlineFrame = findDirectChild(sectionOutline, function(child)
		return child:IsA("Frame") and child.AbsoluteSize.Y > 20
	end)
	if not inlineFrame then
		return nil
	end

	local scrolling = findDescendant(inlineFrame, function(child)
		return child:IsA("ScrollingFrame")
	end)
	if not scrolling then
		return nil
	end

	return findDirectChild(scrolling, function(child)
		return child:IsA("Frame") and child:FindFirstChildOfClass("UIListLayout") ~= nil
	end)
end

function UIExtractor:detectElementType(element)
	if element:IsA("Frame") then
		-- Milenium buttons: Frame wrapper containing a TextButton (Y ~30)
		local directButton = findDirectChild(element, function(child)
			return child:IsA("TextButton")
		end)
		if directButton and directButton.AbsoluteSize.Y >= 26 then
			return "Button"
		end

		-- Milenium dividers: Frame with a thin line Frame child
		local hasLine = findDirectChild(element, function(child)
			return child:IsA("Frame") and child.AbsoluteSize.Y <= 2
		end)
		if hasLine then
			return "Divider"
		end

		return "Unknown"
	end

	if not element:IsA("TextButton") then
		return "Unknown"
	end

	-- Check for slider first (TextBox + thin TextButton bar)
	local textBox = findDescendant(element, function(child)
		return child:IsA("TextBox")
	end)
	local sliderBar = findDescendant(element, function(child)
		return child:IsA("TextButton") and child ~= element and child.AbsoluteSize.Y <= 6 and child.AbsoluteSize.X > 30
	end)
	if textBox and sliderBar then
		return "Slider"
	end

	-- Check for dropdown (TextButton descendant with ImageLabel indicator + TextLabel)
	local dropdownButton = findDescendant(element, function(child)
		return child:IsA("TextButton")
			and child ~= element
			and child:FindFirstChildWhichIsA("ImageLabel") ~= nil
			and child:FindFirstChildWhichIsA("TextLabel") ~= nil
			and child.AbsoluteSize.Y >= 12
			and child.AbsoluteSize.Y <= 22
	end)
	if dropdownButton then
		return "Dropdown"
	end

	-- Textbox (has TextBox but no slider bar)
	if textBox then
		return "Textbox"
	end

	-- Checkbox (ImageLabel tick with non-empty image)
	local checkboxTick = findDescendant(element, function(child)
		return child:IsA("ImageLabel") and child.Image ~= ""
			and child.AbsoluteSize.X <= 18 and child.AbsoluteSize.Y <= 18
	end)
	if checkboxTick then
		return "Checkbox"
	end

	-- Toggle (12x12 circle Frame)
	local toggleCircle = findDescendant(element, function(child)
		return child:IsA("Frame") and child.AbsoluteSize.X >= 10 and child.AbsoluteSize.X <= 14
			and child.AbsoluteSize.Y >= 10 and child.AbsoluteSize.Y <= 14
			and child:FindFirstChildOfClass("UICorner") ~= nil
	end)
	if toggleCircle then
		return "Toggle"
	end

	return "Label"
end

function UIExtractor:extractElementAddons(element, elementType)
	local addons = {}
	if elementType ~= "Label" then
		return addons
	end

	local rightComponents = findDirectChild(element, function(child)
		return child:IsA("Frame") and child:FindFirstChildOfClass("UIListLayout") ~= nil
	end)
	if not rightComponents then
		return addons
	end

	for _, child in ipairs(getGuiChildren(rightComponents)) do
		if child:IsA("TextButton") then
			local label = child:FindFirstChildWhichIsA("TextLabel")
			if label and stripRichText(label.Text) ~= "" then
				addons[#addons + 1] = {
					type = "Keybind",
					text = stripRichText(label.Text),
				}
			end
		end
	end

	return addons
end

function UIExtractor:extractElementInfo(element)
	local elementType = self:detectElementType(element)
	local primaryLabel = getPrimaryTextLabel(element)
	local secondaryLabel = getSecondaryTextLabel(element)
	local info = {
		type = elementType,
		className = element.ClassName,
		order = element.LayoutOrder or 0,
		visible = element.Visible,
		text = primaryLabel and stripRichText(primaryLabel.Text) or nil,
		info = secondaryLabel and stripRichText(secondaryLabel.Text) or nil,
		value = nil,
		properties = {
			size = serializeValue(element.Size),
			position = serializeValue(element.Position),
			addons = {},
		},
	}

	if elementType == "Button" then
		local button = findDirectChild(element, function(child)
			return child:IsA("TextButton")
		end)
		info.text = button and getButtonText(button) or info.text
	elseif elementType == "Divider" then
		info.text = primaryLabel and stripRichText(primaryLabel.Text) or ""
	elseif elementType == "Dropdown" then
		local subText = findDescendant(element, function(child)
			return child:IsA("TextLabel") and child.TextTruncate == Enum.TextTruncate.AtEnd
		end)
		info.value = subText and stripRichText(subText.Text) or nil
	elseif elementType == "Slider" then
		local valueBox = findDescendant(element, function(child)
			return child:IsA("TextBox")
		end)
		info.value = valueBox and stripRichText(valueBox.Text) or nil
		info.properties.sliderFill = (findDescendant(element, function(child)
			return child:IsA("Frame") and child.AbsoluteSize.Y == 4 and child.BackgroundColor3 ~= Color3.fromRGB(33, 33, 35)
		end) and true) or false
	elseif elementType == "Textbox" then
		local input = findDescendant(element, function(child)
			return child:IsA("TextBox")
		end)
		if input then
			info.value = input.Text
			info.properties.placeholder = input.PlaceholderText
		end
	elseif elementType == "Checkbox" then
		local tick = findDescendant(element, function(child)
			return child:IsA("ImageLabel") and child.Image ~= ""
		end)
		info.value = tick and tick.ImageTransparency < 0.5 or false
	elseif elementType == "Toggle" then
		local circle = findDescendant(element, function(child)
			return child:IsA("Frame") and child.AbsoluteSize.X == 12 and child.AbsoluteSize.Y == 12
		end)
		info.value = circle and circle.Position.X.Scale > 0.5 or false
	elseif elementType == "Label" then
		info.properties.addons = self:extractElementAddons(element, elementType)
	end

	return info
end

function UIExtractor:extractSection(sectionOutline, side, orderIndex)
	local header = findDirectChild(sectionOutline, function(child)
		return child:IsA("TextButton") and child.AbsoluteSize.Y >= 30 and child.AbsoluteSize.Y <= 40
	end)
	local title = header and getPrimaryTextLabel(header) or nil
	local icon = header and getButtonIcon(header) or nil
	local elementsFrame = self:getSectionElementsContainer(sectionOutline)

	local sectionInfo = {
		name = title and stripRichText(title.Text) or "Section",
		type = "Section",
		side = side,
		order = sectionOutline.LayoutOrder or orderIndex or 0,
		visible = sectionOutline.Visible,
		icon = icon,
		anchor = sectionOutline:GetAttribute("SectionAnchor"),
		autoSize = sectionOutline:GetAttribute("SectionAutoSize"),
		size = sectionOutline:GetAttribute("SectionSize"),
		elements = {},
	}

	if not elementsFrame then
		return sectionInfo
	end

	for _, child in ipairs(getGuiChildren(elementsFrame)) do
		if child:IsA("Frame") and child.AbsoluteSize.Y <= 2 and #child:GetChildren() == 0 then
			continue
		end

		if child:GetAttribute("SectionManaged") then
			continue
		end

		sectionInfo.elements[#sectionInfo.elements + 1] = self:extractElementInfo(child)
	end

	return sectionInfo
end

function UIExtractor:findColumnsInPage(pageRoot)
	-- Milenium nests: .page -> tab_parent -> column Frames -> sections
	-- tab_parent has a horizontal UIListLayout; columns contain SectionManaged children
	local columns = {}

	local function hasSectionChildren(frame)
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("Frame") and child:GetAttribute("SectionManaged") then
				return true
			end
		end
		return false
	end

	for _, child in ipairs(getGuiChildren(pageRoot)) do
		if child:IsA("Frame") then
			if hasSectionChildren(child) then
				-- This frame is directly a column (has sections)
				columns[#columns + 1] = child
			else
				-- This is likely tab_parent; look inside for actual columns
				for _, subChild in ipairs(getGuiChildren(child)) do
					if subChild:IsA("Frame") and hasSectionChildren(subChild) then
						columns[#columns + 1] = subChild
					end
				end
			end
		end
	end

	return columns
end

function UIExtractor:extractCurrentPage(mainWindow, pageName, pageOrder)
	local _, pageRoot = self:findActiveTabHolder(mainWindow)
	local pageInfo = {
		name = pageName or "Main",
		type = "Page",
		order = pageOrder or 0,
		visible = true,
		sections = {},
	}

	if not pageRoot then
		pageInfo.error = "Active page root not found"
		return pageInfo
	end

	local columns = self:findColumnsInPage(pageRoot)
	for columnIndex, column in ipairs(columns) do
		local side = columnIndex == 1 and "Left" or columnIndex == 2 and "Right" or ("Column" .. tostring(columnIndex))
		local sectionOrder = 0
		for _, child in ipairs(getGuiChildren(column)) do
			if child:IsA("Frame") and child:GetAttribute("SectionManaged") then
				sectionOrder = sectionOrder + 1
				pageInfo.sections[#pageInfo.sections + 1] = self:extractSection(child, side, sectionOrder)
			end
		end
	end

	return pageInfo
end

function UIExtractor:extractLibraryMetadata(mainWindow, sidebarHolder, pageButtonHolder)
	local title = findDescendant(mainWindow, function(child)
		return child:IsA("TextLabel") and tostring(child.Text):find("%.rest") ~= nil
	end)
	-- Milenium footer: game name label + "PlaceId  lumin.rest" label with rich text
	local footerGame = findDescendant(mainWindow, function(child)
		if not child:IsA("TextLabel") then return false end
		local raw = stripRichText(child.Text)
		return raw == tostring(game.PlaceId)
			or raw:find(tostring(game.PlaceId), 1, true) ~= nil
	end)
	-- Also try to find the game name label in the footer bar
	local footerBar = findDescendant(mainWindow, function(child)
		return child:IsA("Frame") and child.AbsoluteSize.Y <= 30 and child.AbsoluteSize.Y >= 20
			and child.AnchorPoint == Vector2.new(0, 1)
	end)
	local gameName = nil
	if footerBar then
		local nameLabel = findDirectChild(footerBar, function(child)
			return child:IsA("TextLabel") and child.TextXAlignment == Enum.TextXAlignment.Left
		end)
		if nameLabel then
			gameName = stripRichText(nameLabel.Text)
		end
	end

	return {
		libraryDirectory = Library.directory,
		menuEnabled = ScreenGui.Enabled,
		activeTab = self:getActiveTabName(sidebarHolder),
		activePage = self:getActivePageName(pageButtonHolder),
		windowTitle = title and title.Text or nil,
		gameFooter = footerGame and footerGame.Text or nil,
		gameName = gameName,
		placeId = game.PlaceId,
		playerCount = #Players:GetPlayers(),
		totalFlags = (function()
			local count = 0
			for _ in next, Library.flags or {} do
				count = count + 1
			end
			return count
		end)(),
	}
end

function UIExtractor:extractAll()
	if not Library then
		warn("Milenium library not found. Load the UI before running the extractor.")
		return nil
	end

	ScreenGui = Library.items
	if not ScreenGui then
		warn("Milenium ScreenGui not found. The UI may not be loaded yet.")
		return nil
	end

	local mainWindow = self:findMainWindow()
	if not mainWindow then
		warn("Failed to find the Milenium main window.")
		return nil
	end

	local sidebarHolder = self:findSidebarHolder(mainWindow)
	if not sidebarHolder then
		warn("Failed to find the Milenium tab sidebar.")
		return nil
	end

	local pageButtonHolder = self:findPageButtonHolder(mainWindow)
	local originalTabName = self:getActiveTabName(sidebarHolder)
	local originalPageName = pageButtonHolder and self:getActivePageName(pageButtonHolder) or nil
	local tabs, separators = self:getTabButtons(sidebarHolder)

	self.extractedData.metadata = self:extractLibraryMetadata(mainWindow, sidebarHolder, pageButtonHolder)
	local serializedFlags = {}
	for flagName, flagValue in next, Library.flags or {} do
		local ok, serialized = pcall(serializeValue, flagValue)
		if ok then
			serializedFlags[tostring(flagName)] = serialized
		else
			serializedFlags[tostring(flagName)] = tostring(flagValue)
		end
	end
	self.extractedData.flags = serializedFlags
	self.extractedData.structure = {
		separators = separators,
		warnings = self.warnings,
	}

	local canNavigate = type(firesignal) == "function" or type(getconnections) == "function"
	if not canNavigate then
		self:addWarning("firesignal/getconnections not available; only the currently visible tab/page can be fully inspected")
		self.extractedData.structure.warnings = self.warnings
	end

	-- Brief wait for UI to settle after any prior navigation
	task.wait(0.15)

	for _, tab in ipairs(tabs) do
		local tabInfo = {
			name = tab.name,
			type = "MainTab",
			icon = tab.icon,
			order = tab.order,
			active = tab.name == originalTabName,
			pages = {},
		}

		local activated = tabInfo.active or self:activateTab(tab.button)
		if not activated and not tabInfo.active then
			tabInfo.error = "Unable to activate tab in this executor"
			self.extractedData.tabs[#self.extractedData.tabs + 1] = tabInfo
			continue
		end

		-- Wait for tab content to settle after activation
		if not tabInfo.active then
			task.wait(0.2)
		end

		pageButtonHolder = self:findPageButtonHolder(mainWindow)
		local pages = self:getPageButtons(pageButtonHolder)
		if #pages == 0 then
			tabInfo.pages[#tabInfo.pages + 1] = self:extractCurrentPage(mainWindow, "Main", 1)
		else
			for _, page in ipairs(pages) do
				local pageActive = pageButtonHolder and self:getActivePageName(pageButtonHolder) == page.name
				local pageActivated = pageActive or self:activatePage(page.button)
				if not pageActive and pageActivated then
					task.wait(0.15)
				end
				if pageActivated then
					tabInfo.pages[#tabInfo.pages + 1] = self:extractCurrentPage(mainWindow, page.name, page.order)
				else
					tabInfo.pages[#tabInfo.pages + 1] = {
						name = page.name,
						type = "Page",
						order = page.order,
						error = "Unable to activate page in this executor",
						sections = {},
					}
				end
			end
		end

		self.extractedData.tabs[#self.extractedData.tabs + 1] = tabInfo
	end

	if originalTabName then
		for _, tab in ipairs(tabs) do
			if tab.name == originalTabName then
				self:activateTab(tab.button)
				break
			end
		end
	end

	if originalPageName then
		pageButtonHolder = self:findPageButtonHolder(mainWindow)
		for _, page in ipairs(self:getPageButtons(pageButtonHolder)) do
			if page.name == originalPageName then
				self:activatePage(page.button)
				break
			end
		end
	end

	self.extractedData.structure.warnings = self.warnings
	return self.extractedData
end

function UIExtractor:exportToString()
	local data = self:extractAll()
	if not data then
		return "nil"
	end

	local function toLuaString(value, indent)
		indent = indent or 0
		local spacing = string.rep("  ", indent)
		if type(value) ~= "table" then
			if type(value) == "string" then
				return string.format("%q", value)
			end
			return tostring(value)
		end

		local lines = {"{"}
		for key, nestedValue in next, value do
			local serializedKey = type(key) == "string" and string.format("[\"%s\"]", key) or string.format("[%s]", tostring(key))
			lines[#lines + 1] = string.format("%s  %s = %s,", spacing, serializedKey, toLuaString(nestedValue, indent + 1))
		end
		lines[#lines + 1] = spacing .. "}"
		return table.concat(lines, "\n")
	end

	return toLuaString(data)
end

function UIExtractor:printStructure()
	local data = self.extractedData.tabs[1] and self.extractedData or self:extractAll()
	if not data then
		return
	end

	print("=== MILENIUM UI STRUCTURE ===")
	print(string.format("Active Tab: %s", data.metadata.activeTab or "None"))
	print(string.format("Active Page: %s", data.metadata.activePage or "None"))
	print(string.format("Flag Count: %s", tostring(data.metadata.totalFlags or 0)))
	print("")

	for _, tab in ipairs(data.tabs) do
		print(string.format("TAB: %s%s", tab.name, tab.active and " [active]" or ""))
		for _, page in ipairs(tab.pages) do
			print(string.format("  PAGE: %s", page.name or "Main"))
			for _, section in ipairs(page.sections or {}) do
				print(string.format("    SECTION: %s (%s)", section.name or "Section", section.side or "Unknown"))
				for _, element in ipairs(section.elements or {}) do
					local text = element.text or element.value or ""
					print(string.format("      - %s: %s", element.type or "Unknown", tostring(text)))
				end
			end
			if page.error then
				print(string.format("    ERROR: %s", page.error))
			end
		end
		if tab.error then
			print(string.format("  ERROR: %s", tab.error))
		end
		print("")
	end

	if data.structure and data.structure.warnings and #data.structure.warnings > 0 then
		print("Warnings:")
		for _, warningText in ipairs(data.structure.warnings) do
			print("  - " .. warningText)
		end
	end
end

local extractor = UIExtractor:new()
local uiData = extractor:extractAll()

if uiData then
	local encodedData = HttpService:JSONEncode(uiData)
	extractor:printStructure()

	if type(writefile) == "function" then
		writefile(
			"MileniumExtracted.json",
			encodedData
				:gsub(Players.LocalPlayer.Name, "Roblox")
				:gsub(Players.LocalPlayer.DisplayName, "Roblox")
		)
	end

	print("Done.", tick())
end
