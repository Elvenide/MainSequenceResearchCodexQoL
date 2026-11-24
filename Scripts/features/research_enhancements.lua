-- Eqol Feature: Research Screen Search Bar & Queue Drag-and-Drop Reorder
-- Injects a native-styled search bar into the Research screen (matching Help Menu / Codex)
-- and allows dragging queued research items with the mouse to change queue order.

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "ResearchEnhancements",
    DisplayName = "Research Search & Queue Drag-Reorder",
    Description = "Adds a live search bar to the Research screen and drag-and-drop queue reordering.",
}

local PATHS = {
    ResearchTreeClass           = "/Game/Blueprints/Widgets/Windows/WBP_ResearchTree_2.WBP_ResearchTree_2_C",
    ResearchListClass           = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchList.WBP_ResearchList_C",
    ResearchTechnologyClass     = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchTechnology.WBP_ResearchTechnology_C",
    ResearchTechnologyWideClass = "/Game/Blueprints/Widgets/Display/Research/WBP_ResearchTechnologyWide.WBP_ResearchTechnologyWide_C",
    TextInputClass              = "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C",
    VerticalBoxClass            = Core.PATHS.VerticalBoxClass,
    SizeBoxClass                = Core.PATHS.SizeBoxClass,
    WidgetLayoutLibCDO          = Core.PATHS.WidgetLayoutLibCDO,
    SlateLibCDO                 = "/Script/UMG.Default__SlateBlueprintLibrary",
}

local InjectedTrees = {} -- treeAddr -> state
local InputToTree   = {} -- textInputAddr -> state
local ListToTree    = {} -- researchListAddr -> state
local ActiveDrag    = nil

local EnsureResearchSearchBar -- forward declaration

local function SafeTextToString(val)
    if val == nil then return "" end
    if type(val) == "string" then return val end
    local ok, str = pcall(function()
        if val.ToString then
            return val:ToString()
        end
        return nil
    end)
    if ok and type(str) == "string" then
        return str
    end
    return ""
end

local TechSearchTextCache = {}
local ObjectSearchTextCache = {}
local PendingFilterToken = 0

local function ContainsQuery(text, queryLower)
    if queryLower == "" then return true end
    if type(text) ~= "string" or text == "" then return false end
    return string.find(text, queryLower, 1, true) ~= nil
end

local function GetObjectSearchText(obj)
    obj = Core.UnwrapArrayElem(obj)
    if not Core.IsValidObj(obj) then return "" end

    local addr = obj:GetAddress()
    local cached = ObjectSearchTextCache[addr]
    if cached ~= nil then
        return cached
    end

    local parts = {}
    local hasDisp = false
    local okDisp, dispVal = pcall(function() return obj.DisplayName end)
    if okDisp then
        local dispStr = SafeTextToString(dispVal)
        if dispStr ~= "" then
            parts[#parts + 1] = dispStr
            hasDisp = true
        end
    end

    -- Check CDO DisplayName when obj is a UClass with no direct DisplayName
    if not hasDisp then
        local okFull, full = pcall(function() return obj:GetFullName() end)
        if okFull and type(full) == "string" then
            local objPath = full:match("^%S+ (.+)$") or full
            local pkg, clsName = objPath:match("^(.-)%.([^.]+)$")
            if pkg and clsName and string.sub(clsName, 1, 9) ~= "Default__" then
                local cdo = Core.GetCDO(pkg .. ".Default__" .. clsName)
                if Core.IsValidObj(cdo) then
                    local okCdoDisp, cdoDisp = pcall(function() return cdo.DisplayName end)
                    if okCdoDisp then
                        local cdoStr = SafeTextToString(cdoDisp)
                        if cdoStr ~= "" then
                            parts[#parts + 1] = cdoStr
                            hasDisp = true
                        end
                    end
                end
            end
        end
    end

    -- Fallback to Display Title / Name property only if DisplayName is absent (never raw FName with _C suffix)
    if not hasDisp then
        local okN, nVal = pcall(function() return obj.Name end)
        if okN then
            local nStr = SafeTextToString(nVal)
            if nStr ~= "" then parts[#parts + 1] = nStr end
        end
    end

    local result = string.lower(table.concat(parts, "\n"))
    ObjectSearchTextCache[addr] = result
    return result
end

local function GetTechSearchText(tech)
    if not Core.IsValidObj(tech) then return "" end

    local addr = tech:GetAddress()
    local cached = TechSearchTextCache[addr]
    if cached ~= nil then
        return cached
    end

    local parts = {}
    local okDisp, dispVal = pcall(function() return tech.DisplayName end)
    if okDisp then
        local s = SafeTextToString(dispVal)
        if s ~= "" then parts[#parts + 1] = s end
    end

    local okUnlocks, unlocks = pcall(function() return tech.Unlocks end)
    if okUnlocks and unlocks then
        local unlockFields = { "Block", "Recipe", "Item", "Buildable" }
        StationData.ForEachArray(unlocks, function(_, elem)
            local unlock = Core.UnwrapStruct(elem)
            if not unlock then return end

            local okUDisp, uDisp = pcall(function() return unlock.DisplayName end)
            if okUDisp then
                local s = SafeTextToString(uDisp)
                if s ~= "" then parts[#parts + 1] = s end
            end

            for _, fieldName in ipairs(unlockFields) do
                local okField, ref = pcall(function() return unlock[fieldName] end)
                if okField and ref ~= nil then
                    local s = GetObjectSearchText(ref)
                    if s ~= "" then parts[#parts + 1] = s end
                end
            end
        end)
    end

    if #parts == 0 then
        local objText = GetObjectSearchText(tech)
        if objText ~= "" then
            parts[#parts + 1] = objText
        end
    end

    local result = string.lower(table.concat(parts, "\n"))
    TechSearchTextCache[addr] = result
    return result
end

local function TechMatchesQuery(tech, queryLower, matchCache)
    if queryLower == "" then return true end
    if not Core.IsValidObj(tech) then return false end
    local addr = tech:GetAddress()
    if matchCache and matchCache[addr] ~= nil then
        return matchCache[addr]
    end
    local matched = ContainsQuery(GetTechSearchText(tech), queryLower)
    if matchCache then
        matchCache[addr] = matched
    end
    return matched
end

local function ResolveTechFromWidget(widget)
    if not Core.IsValidObj(widget) then return nil end
    local tech = nil
    pcall(function() tech = Core.UnwrapArrayElem(widget.Technology) end)
    if Core.IsValidObj(tech) then return tech end
    pcall(function()
        if widget.Research ~= nil then
            tech = Core.UnwrapArrayElem(widget.Research.Technology)
        end
    end)
    return Core.IsValidObj(tech) and tech or nil
end

local function ReadSearchQuery(st)
    if not st or not Core.IsValidObj(st.SearchInput) then return "" end
    local raw = nil
    pcall(function()
        if Core.IsValidObj(st.SearchInput.EditableTextBox_80) then
            raw = SafeTextToString(st.SearchInput.EditableTextBox_80:GetText())
        end
    end)
    if raw == nil or raw == "" then
        pcall(function()
            if st.SearchInput.GetText then
                raw = SafeTextToString(st.SearchInput:GetText())
            end
        end)
    end
    return type(raw) == "string" and raw or ""
end

local function ClearSearchInput(st)
    if not st or not Core.IsValidObj(st.SearchInput) then return end
    st.PendingQuery = nil
    pcall(function()
        if Core.IsValidObj(st.SearchInput.EditableTextBox_80) then
            st.SearchInput.EditableTextBox_80:SetText(Core.MakeText(""))
        elseif st.SearchInput.SetText then
            st.SearchInput:SetText(Core.MakeText(""))
        end
    end)
end

local function SetWideWidgetAlpha(st, wideW, targetAlpha)
    if not Core.IsValidObj(wideW) then return end
    st.LastWideAlpha = st.LastWideAlpha or {}
    local wAddr = wideW:GetAddress()
    if st.LastWideAlpha[wAddr] == targetAlpha then return end
    st.LastWideAlpha[wAddr] = targetAlpha
    pcall(function() wideW:SetRenderOpacity(targetAlpha) end)
end

local function SetWideTreeDimming(st, tree, queryLower, matchCache, handledWide)
    if not Core.IsValidObj(tree) then return end

    local updatedAny = handledWide ~= nil and next(handledWide) ~= nil
    local treeView = nil
    pcall(function() treeView = tree.ResearchTreeView end)
    if Core.IsValidObj(treeView) then
        local okLV, lvWidgets = pcall(function() return treeView.ListViewWidgets end)
        if okLV and lvWidgets then
            StationData.ForEachArray(lvWidgets, function(_, elem)
                local w = Core.UnwrapArrayElem(elem)
                if not Core.IsValidObj(w) then return end
                updatedAny = true
                local wAddr = w:GetAddress()
                if handledWide and handledWide[wAddr] then return end
                local tech = ResolveTechFromWidget(w)
                local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower, matchCache)
                SetWideWidgetAlpha(st, w, matched and 1.0 or 0.22)
            end)
        end
    end

    if not updatedAny then
        local okAll, wideWidgets = pcall(FindAllOf, "WBP_ResearchTechnologyWide_C")
        if okAll and wideWidgets then
            for _, w in ipairs(wideWidgets) do
                if Core.IsValidObj(w) then
                    local wAddr = w:GetAddress()
                    if not (handledWide and handledWide[wAddr]) then
                        local tech = ResolveTechFromWidget(w)
                        local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower, matchCache)
                        SetWideWidgetAlpha(st, w, matched and 1.0 or 0.22)
                    end
                end
            end
        end
    end
end

local function ApplyResearchFilter(st, overrideQuery)
    if not st or not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.ResearchList) then
        return
    end

    local rawText = ""
    if Core.IsFeatureEnabled("ResearchEnhancements") then
        rawText = (type(overrideQuery) == "string") and overrideQuery or ReadSearchQuery(st)
    end
    local trimmed = rawText:match("^%s*(.-)%s*$") or ""
    local queryLower = string.lower(trimmed)

    if not st.FilterDirty and st.LastAppliedQuery == queryLower then
        return
    end

    local treeView = nil
    pcall(function() treeView = st.Tree.ResearchTreeView end)

    st.HiddenByEqol = st.HiddenByEqol or {}
    local matchCache = {}
    local handledWide = {}

    local container = nil
    pcall(function() container = st.ResearchList.Container end)
    if Core.IsValidObj(container) then
        pcall(function()
            local count = container:GetChildrenCount()
            for i = 0, count - 1 do
                local child = container:GetChildAt(i)
                if Core.IsValidObj(child) then
                    local cAddr = child:GetAddress()
                    local curVis = 0
                    pcall(function() curVis = tonumber(child:GetVisibility()) or 0 end)

                    local tech = ResolveTechFromWidget(child)
                    local matched = (queryLower == "") or TechMatchesQuery(tech, queryLower, matchCache)

                    if matched then
                        local origVis = st.HiddenByEqol[cAddr]
                        if origVis ~= nil then
                            st.HiddenByEqol[cAddr] = nil
                            if curVis ~= origVis then
                                child:SetVisibility(origVis)
                            end
                        end
                    else
                        if st.HiddenByEqol[cAddr] == nil then
                            if curVis ~= 1 and curVis ~= 2 then
                                st.HiddenByEqol[cAddr] = curVis
                                child:SetVisibility(1) -- 1 = Collapsed
                            end
                        elseif curVis ~= 1 then
                            child:SetVisibility(1)
                        end
                    end

                    if Core.IsValidObj(treeView) and Core.IsValidObj(tech) and treeView.GetWidget then
                        local okW, wideW = pcall(function() return treeView:GetWidget(tech) end)
                        if okW and Core.IsValidObj(wideW) then
                            handledWide[wideW:GetAddress()] = true
                            SetWideWidgetAlpha(st, wideW, matched and 1.0 or 0.22)
                        end
                    end
                end
            end
        end)
    end

    SetWideTreeDimming(st, st.Tree, queryLower, matchCache, handledWide)
    st.FilterDirty = false
    st.LastAppliedQuery = queryLower
end

local function ScheduleResearchFilter(st, overrideQuery)
    if not st then return end
    PendingFilterToken = PendingFilterToken + 1
    local myToken = PendingFilterToken
    st.PendingQuery = overrideQuery
    ExecuteInGameThreadWithDelay(50, function()
        if myToken ~= PendingFilterToken then return end
        ApplyResearchFilter(st, st.PendingQuery)
    end)
end

EnsureResearchSearchBar = function(tree)
    if not Core.IsValidObj(tree) then return nil end

    local treeAddr = tree:GetAddress()
    local existing = InjectedTrees[treeAddr]
    if existing and Core.IsValidObj(existing.SearchInput) and Core.IsValidObj(existing.ResearchList) then
        return existing
    end

    local rList = nil
    pcall(function() rList = tree.WBP_ResearchList end)
    if not Core.IsValidObj(rList) then
        Core.Log("[ResearchEnhancements] EnsureResearchSearchBar: missing WBP_ResearchList on tree")
        return nil
    end

    local container = nil
    pcall(function() container = rList.Container end)
    if not Core.IsValidObj(container) then
        Core.Log("[ResearchEnhancements] EnsureResearchSearchBar: missing rList.Container")
        return nil
    end

    -- ScrollBox_63 and SizeBox_94 are layout-only ancestors of Container (not exposed as UProperties)
    local scrollBox = nil
    pcall(function() scrollBox = container:GetParent() end)
    if not Core.IsValidObj(scrollBox) then
        Core.Log("[ResearchEnhancements] EnsureResearchSearchBar: missing container:GetParent() (ScrollBox)")
        return nil
    end

    local sizeBox = nil
    pcall(function() sizeBox = scrollBox:GetParent() end)
    if not Core.IsValidObj(sizeBox) then
        Core.Log("[ResearchEnhancements] EnsureResearchSearchBar: missing scrollBox:GetParent() (SizeBox)")
        return nil
    end

    -- Avoid double-wrapping if ScrollBox_63 is already inside an injected VerticalBox
    local okCls, parentCls = pcall(function() return sizeBox:GetClass():GetFName():ToString() end)
    if okCls and parentCls == "VerticalBox" then
        local existingInput = nil
        pcall(function()
            local count = sizeBox:GetChildrenCount()
            for i = 0, count - 1 do
                local ch = sizeBox:GetChildAt(i)
                if Core.IsValidObj(ch) and ch.GetChildrenCount and ch:GetChildrenCount() > 0 then
                    local inner = ch:GetChildAt(0)
                    if Core.IsValidObj(inner) and Core.IsValidObj(inner.EditableTextBox_80) then
                        existingInput = inner
                        break
                    end
                end
            end
        end)
        if Core.IsValidObj(existingInput) then
            local st = {
                Tree = tree,
                ResearchList = rList,
                SearchInput = existingInput,
                HiddenByEqol = {},
                FilterDirty = true,
            }
            InjectedTrees[treeAddr] = st
            InputToTree[existingInput:GetAddress()] = st
            ListToTree[rList:GetAddress()] = st
            Core.RegisterTextInput(existingInput, tree)
            return st
        end
        return nil
    end

    local outer = Core.GetWidgetOuter(rList)
    local okPC, owningPC = pcall(function() return tree:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local vBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local searchSizeBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local searchInput = Core.CreateUserWidget(PATHS.TextInputClass, tree, pc)
    if not (Core.IsValidObj(vBox) and Core.IsValidObj(searchSizeBox) and Core.IsValidObj(searchInput)) then
        return nil
    end

    pcall(function()
        if sizeBox.bOverride_HeightOverride == true and tonumber(sizeBox.HeightOverride) and sizeBox.HeightOverride < 340.0 then
            sizeBox:SetHeightOverride(sizeBox.HeightOverride + 44.0)
        end
        searchSizeBox:SetHeightOverride(38.0)
        searchInput.Size = 13.0
        searchInput["Minimum Width"] = 220.0
    end)

    local sInSlot = searchSizeBox:AddChild(searchInput)
    if Core.IsValidObj(sInSlot) then
        pcall(function()
            sInSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sInSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    pcall(function() scrollBox:RemoveFromParent() end)
    pcall(function()
        if sizeBox.GetChildrenCount and sizeBox:GetChildrenCount() > 0 and sizeBox.ClearChildren then
            sizeBox:ClearChildren()
        end
    end)

    local rootSlot = sizeBox:AddChild(vBox)
    if Core.IsValidObj(rootSlot) then
        pcall(function()
            rootSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            rootSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    local sSlot = vBox:AddChildToVerticalBox(searchSizeBox)
    if Core.IsValidObj(sSlot) then
        pcall(function()
            sSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
        end)
    end

    local sbSlot = vBox:AddChildToVerticalBox(scrollBox)
    if Core.IsValidObj(sbSlot) then
        pcall(function()
            sbSlot:SetSize({ Value = 1.0, SizeRule = 1 }) -- Fill
            sbSlot:SetHorizontalAlignment(0)               -- HAlign_Fill
            sbSlot:SetVerticalAlignment(0)                 -- VAlign_Fill
        end)
    end

    pcall(function()
        if Core.IsValidObj(searchInput.EditableTextBox_80) then
            searchInput.EditableTextBox_80:SetHintText(Core.MakeText("Search research..."))
            searchInput.EditableTextBox_80:SetText(Core.MakeText(""))
            searchInput.EditableTextBox_80.MinimumDesiredWidth = 220.0
        elseif searchInput.SetText then
            searchInput:SetText(Core.MakeText(""))
        end
    end)

    local st = {
        Tree = tree,
        ResearchList = rList,
        SearchInput = searchInput,
        SearchBox = searchSizeBox,
        HiddenByEqol = {},
        FilterDirty = true,
    }
    InjectedTrees[treeAddr] = st
    InputToTree[searchInput:GetAddress()] = st
    ListToTree[rList:GetAddress()] = st
    Core.RegisterTextInput(searchInput, tree)
    Core.Log("[ResearchEnhancements] Injected research search bar into WBP_ResearchList")
    return st
end

local function SetResearchSearchVisible(st, visible)
    if not st then return end
    st.SearchVisible = (visible == true)
    local vis = visible and 0 or 1
    if Core.IsValidObj(st.SearchBox) then
        pcall(function() st.SearchBox:SetVisibility(vis) end)
    end
    if Core.IsValidObj(st.SearchInput) then
        pcall(function() st.SearchInput:SetVisibility(vis) end)
    end
end

local function EnsureAndFilterTree(tree, markFilterDirty)
    if not Core.IsValidObj(tree) then return end
    if not Core.IsFeatureEnabled("ResearchEnhancements") then
        local existing = InjectedTrees[tree:GetAddress()]
        if existing and existing.SearchVisible ~= false then
            ClearSearchInput(existing)
            existing.FilterDirty = false
            if existing.LastAppliedQuery ~= "" then
                existing.LastAppliedQuery = nil
                ApplyResearchFilter(existing, "")
            end
            SetResearchSearchVisible(existing, false)
        end
        return
    end
    local st = EnsureResearchSearchBar(tree)
    if st then
        SetResearchSearchVisible(st, true)
        if markFilterDirty then
            -- Native SetFilter / RefreshList owns baseline visibility; clear stale HiddenByEqol
            -- so clearing search later cannot un-hide techs hidden by a native filter tab.
            st.HiddenByEqol = {}
            st.FilterDirty = true
        end
        ApplyResearchFilter(st)
    end
end

local function ResolveTreeForList(rList)
    if not Core.IsValidObj(rList) then return nil end
    local rAddr = rList:GetAddress()
    local cached = ListToTree[rAddr]
    if cached and Core.IsValidObj(cached.Tree) then
        return cached.Tree
    end
    local okTrees, trees = pcall(FindAllOf, "WBP_ResearchTree_2_C")
    if okTrees and trees then
        for _, tree in ipairs(trees) do
            if Core.IsValidObj(tree) and Core.IsValidObj(tree.WBP_ResearchList) then
                if tree.WBP_ResearchList:GetAddress() == rAddr then
                    return tree
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Queue Drag-and-Drop Reordering
--------------------------------------------------------------------------------

local function GetViewportMousePos(pc)
    local layoutLib = Core.GetCDO(PATHS.WidgetLayoutLibCDO)
    if Core.IsValidObj(layoutLib) and Core.IsValidObj(pc) then
        local okVP, pos = pcall(function()
            return layoutLib:GetMousePositionOnViewport(pc)
        end)
        if okVP and pos ~= nil then
            local x, y = nil, nil
            pcall(function()
                x = tonumber(pos.X)
                y = tonumber(pos.Y)
            end)
            if x and y then
                return x, y
            end
        end
    end
    if Core.IsValidObj(layoutLib) then
        local okP, pos = pcall(function()
            return layoutLib:GetMousePositionOnPlatform()
        end)
        if okP and pos ~= nil then
            local x, y = nil, nil
            pcall(function()
                x = tonumber(pos.X)
                y = tonumber(pos.Y)
            end)
            if x and y then
                local scale = 1.0
                pcall(function()
                    if Core.IsValidObj(pc) and layoutLib.GetViewportScale then
                        local s = tonumber(layoutLib:GetViewportScale(pc))
                        if s and s > 0.01 then scale = s end
                    end
                end)
                return x / scale, y / scale
            end
        end
    end
    return nil, nil
end

local function MeasureQueueGridLayout(tree, queueBox, count)
    local stepX, stepY = 64.0, 64.0
    local cols = math.max(1, count or 1)
    if not Core.IsValidObj(queueBox) or (count or 0) < 1 then
        return cols, stepX, stepY
    end

    local slateLib = Core.GetCDO(PATHS.SlateLibCDO)
    local innerSlotPadX, innerSlotPadY = 4.0, 4.0

    pcall(function()
        if queueBox.InnerSlotPadding then
            local px = tonumber(queueBox.InnerSlotPadding.X)
            local py = tonumber(queueBox.InnerSlotPadding.Y)
            if px and px >= 0.0 and px <= 40.0 then innerSlotPadX = math.max(4.0, px) end
            if py and py >= 0.0 and py <= 40.0 then innerSlotPadY = math.max(4.0, py) end
        end
    end)

    pcall(function()
        local ch = queueBox:GetChildAt(0)
        if Core.IsValidObj(ch) then
            local w, h = nil, nil
            if Core.IsValidObj(slateLib) and slateLib.GetLocalSize and ch.GetCachedGeometry then
                local okS, sz = pcall(function() return slateLib:GetLocalSize(ch:GetCachedGeometry()) end)
                if okS and sz ~= nil then
                    w = tonumber(sz.X)
                    h = tonumber(sz.Y)
                end
            end
            if (not w or w < 10.0 or not h or h < 10.0) and ch.GetDesiredSize then
                local okD, dsz = pcall(function() return ch:GetDesiredSize() end)
                if okD and dsz ~= nil then
                    if not w or w < 10.0 then w = tonumber(dsz.X) end
                    if not h or h < 10.0 then h = tonumber(dsz.Y) end
                end
            end
            if w and w >= 20.0 and w <= 300.0 then stepX = w + innerSlotPadX end
            if h and h >= 20.0 and h <= 300.0 then stepY = h + innerSlotPadY end
        end
    end)

    local detectSrc = "fallback_count"
    local boxW = 0.0

    -- 1. Try measuring actual row wrap from child 0 vs subsequent children via LocalToAbsolute
    local detectedCols = nil
    if count > 1 and Core.IsValidObj(slateLib) and slateLib.LocalToAbsolute then
        pcall(function()
            local ch0 = queueBox:GetChildAt(0)
            if not (Core.IsValidObj(ch0) and ch0.GetCachedGeometry) then return end
            local p0 = slateLib:LocalToAbsolute(ch0:GetCachedGeometry(), { X = 0.0, Y = 0.0 })
            local x0 = p0 and tonumber(p0.X) or nil
            local y0 = p0 and tonumber(p0.Y) or nil
            if not (x0 and y0) then return end

            local dx1 = nil
            for i = 1, count - 1 do
                local chi = queueBox:GetChildAt(i)
                if Core.IsValidObj(chi) and chi.GetCachedGeometry then
                    local pi = slateLib:LocalToAbsolute(chi:GetCachedGeometry(), { X = 0.0, Y = 0.0 })
                    local xi = pi and tonumber(pi.X) or nil
                    local yi = pi and tonumber(pi.Y) or nil
                    if xi and yi then
                        if i == 1 and math.abs(yi - y0) < 10.0 and (xi - x0) > 20.0 then
                            dx1 = xi - x0
                        end
                        if (yi - y0) > (stepY * 0.45) then
                            detectedCols = i
                            if dx1 and dx1 > 20.0 then
                                local scale = dx1 / stepX
                                if scale > 0.25 and scale < 4.0 then
                                    stepY = (yi - y0) / scale
                                end
                            end
                            break
                        end
                    end
                end
            end
        end)
    end

    if detectedCols and detectedCols >= 1 then
        cols = detectedCols
        detectSrc = "LocalToAbsolute"
    else
        -- 2. Walk queueBox and up to 4 ancestors (plus WBP_ResearchList) to find the sidebar container width
        local function readWidgetWidth(wgt)
            if not Core.IsValidObj(wgt) then return 0.0 end
            local w = 0.0
            pcall(function()
                if Core.IsValidObj(slateLib) and slateLib.GetLocalSize and wgt.GetCachedGeometry then
                    local sz = slateLib:GetLocalSize(wgt:GetCachedGeometry())
                    if sz and tonumber(sz.X) and tonumber(sz.X) > w then
                        w = tonumber(sz.X)
                    end
                end
                if w < stepX and wgt.bExplicitWrapSize == true and tonumber(wgt.ExplicitWrapSize) then
                    w = tonumber(wgt.ExplicitWrapSize)
                end
                if w < stepX and tonumber(wgt.WrapSize) and tonumber(wgt.WrapSize) >= stepX then
                    w = tonumber(wgt.WrapSize)
                end
                if w < stepX and wgt.GetDesiredSize then
                    local dsz = wgt:GetDesiredSize()
                    if dsz and tonumber(dsz.X) and tonumber(dsz.X) > w then
                        w = tonumber(dsz.X)
                    end
                end
            end)
            return w
        end

        local cur = queueBox
        for depth = 0, 4 do
            if not Core.IsValidObj(cur) then break end
            local w = readWidgetWidth(cur)
            -- Ignore full-screen root panels (> 900px) and tiny unmeasured panels (< stepX)
            if w >= stepX and w <= 900.0 then
                boxW = w
                detectSrc = "ancestor_" .. depth
                break
            end
            local okP, par = pcall(function() return cur:GetParent() end)
            cur = (okP and Core.IsValidObj(par)) and par or nil
        end

        if boxW < stepX and Core.IsValidObj(tree) then
            pcall(function()
                if Core.IsValidObj(tree.WBP_ResearchList) then
                    local w = readWidgetWidth(tree.WBP_ResearchList)
                    if w >= stepX and w <= 900.0 then
                        boxW = w
                        detectSrc = "ResearchList"
                    end
                end
            end)
        end

        if boxW >= stepX then
            cols = math.max(1, math.floor((boxW + innerSlotPadX + 2.0) / stepX))
        else
            -- Vanilla WBP_ResearchTree_2_C ResearchQueueContainer is 4 columns wide
            cols = math.min(count, 4)
            detectSrc = "default_4"
        end
    end

    Core.Log(string.format("[ResearchEnhancements] Drag layout: count=%d cols=%d stepX=%.1f stepY=%.1f boxW=%.1f src=%s",
        count, cols, stepX, stepY, boxW, detectSrc))
    return cols, stepX, stepY
end

local function ResetQueueChildVisuals(queueBox)
    if Core.IsValidObj(queueBox) then
        pcall(function()
            local count = queueBox:GetChildrenCount()
            for i = 0, count - 1 do
                local ch = queueBox:GetChildAt(i)
                if Core.IsValidObj(ch) then
                    ch:SetRenderOpacity(1.0)
                    ch:SetRenderTranslation({ X = 0.0, Y = 0.0 })
                    if ch.SetRenderScale then
                        ch:SetRenderScale({ X = 1.0, Y = 1.0 })
                    end
                end
            end
        end)
    end
end

local function CollectQueuedTechs(tree, queueBox)
    local techs = {}
    pcall(function()
        local count = queueBox:GetChildrenCount()
        for i = 0, count - 1 do
            local ch = queueBox:GetChildAt(i)
            techs[i + 1] = ResolveTechFromWidget(ch)
        end
    end)

    -- Fallback via ResearchState if any slot lacked a direct Technology pointer
    local rState = nil
    pcall(function() rState = tree.ResearchState end)
    if Core.IsValidObj(rState) then
        local okAllRes, allRes = pcall(function() return rState.Research end)
        local okQIdx, qIndices = pcall(function() return rState.ResearchQueueIndices end)
        if okAllRes and allRes and okQIdx and qIndices then
            local queueFromState = {}
            StationData.ForEachArray(qIndices, function(_, elem)
                local unwrapped = Core.UnwrapStruct(elem)
                local idx = tonumber(unwrapped)
                if idx ~= nil then
                    pcall(function()
                        local entry = Core.UnwrapStruct(allRes[idx + 1])
                        local t = entry and Core.UnwrapArrayElem(entry.Technology) or nil
                        table.insert(queueFromState, t)
                    end)
                end
            end)
            for i = 1, #techs do
                if not Core.IsValidObj(techs[i]) and Core.IsValidObj(queueFromState[i]) then
                    techs[i] = queueFromState[i]
                end
            end
        end
    end

    return techs
end

local function GetTechPrerequisites(tech)
    local reqs = {}
    if not Core.IsValidObj(tech) then return reqs end
    local seen = {}

    local function addReq(candidate)
        local obj = Core.UnwrapArrayElem(candidate)
        if Core.IsValidObj(obj) then
            local addr = obj:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                table.insert(reqs, obj)
            end
        end
    end

    pcall(function() addReq(tech.PrimaryPrerequisite) end)
    local okPrereqs, prereqs = pcall(function() return tech.Prerequisites end)
    if okPrereqs and prereqs then
        StationData.ForEachArray(prereqs, function(_, elem)
            addReq(Core.UnwrapStruct(elem))
        end)
    end
    return reqs
end

local function IsQueueOrderValid(techs)
    if type(techs) ~= "table" then return false end
    local count = #techs
    local posByAddr = {}
    for i = 1, count do
        if not Core.IsValidObj(techs[i]) then
            return false
        end
        posByAddr[techs[i]:GetAddress()] = i
    end

    -- No queued research may appear at or before any of its pending prerequisites in the queue
    for i = 1, count do
        local reqs = GetTechPrerequisites(techs[i])
        for _, req in ipairs(reqs) do
            local reqPos = posByAddr[req:GetAddress()]
            if reqPos ~= nil and reqPos >= i then
                return false
            end
        end
    end
    return true
end

local function BuildReorderedTechs(oldTechs, fromIdx, toIdx)
    local newTechs = {}
    for i = 1, #oldTechs do
        newTechs[i] = oldTechs[i]
    end
    local moved = table.remove(newTechs, fromIdx)
    table.insert(newTechs, toIdx, moved)
    return newTechs
end

local function ClampValidDropTarget(oldTechs, fromIdx, desiredIdx)
    if not oldTechs or #oldTechs < 2 then return fromIdx, true end
    desiredIdx = Core.Clamp(desiredIdx, 1, #oldTechs)
    if desiredIdx == fromIdx then return fromIdx, true end

    if IsQueueOrderValid(BuildReorderedTechs(oldTechs, fromIdx, desiredIdx)) then
        return desiredIdx, true
    end

    local step = (desiredIdx > fromIdx) and -1 or 1
    local cand = desiredIdx + step
    while (step < 0 and cand > fromIdx) or (step > 0 and cand < fromIdx) do
        if IsQueueOrderValid(BuildReorderedTechs(oldTechs, fromIdx, cand)) then
            return cand, false
        end
        cand = cand + step
    end
    return fromIdx, false
end

local function ReorderResearchQueue(tree, fromIdx, toIdx, snapshotTechs)
    if not Core.IsValidObj(tree) or fromIdx == toIdx then return end
    local queueBox = nil
    pcall(function() queueBox = tree.ResearchQueueContainer end)
    if not Core.IsValidObj(queueBox) then return end

    local pc = nil
    pcall(function() pc = tree.OwningPlayerController end)
    if not Core.IsValidObj(pc) then
        pc = Core.GetLocalPlayerController()
    end
    if not Core.IsValidObj(pc) then return end

    local oldTechs = CollectQueuedTechs(tree, queueBox)
    local count = #oldTechs
    if count < 2 or fromIdx < 1 or fromIdx > count or toIdx < 1 or toIdx > count then
        return
    end
    for i = 1, count do
        if not Core.IsValidObj(oldTechs[i]) then
            return
        end
    end

    -- Validate the ENTIRE live queue against the drag-start snapshot so a concurrent
    -- multiplayer edit or research completion mid-drag never corrupts or duplicates entries.
    if type(snapshotTechs) == "table" then
        if #snapshotTechs ~= count then
            Core.Log(string.format("[ResearchEnhancements] Aborted queue reorder: queue length changed mid-drag (%d -> %d)", #snapshotTechs, count))
            return
        end
        for i = 1, count do
            if not Core.IsValidObj(snapshotTechs[i]) or oldTechs[i]:GetAddress() ~= snapshotTechs[i]:GetAddress() then
                Core.Log(string.format("[ResearchEnhancements] Aborted queue reorder: queue changed at slot %d mid-drag", i))
                return
            end
        end
    end

    local newTechs = BuildReorderedTechs(oldTechs, fromIdx, toIdx)
    if not IsQueueOrderValid(newTechs) then
        Core.Log(string.format("[ResearchEnhancements] Blocked invalid reorder %d -> %d (prerequisite constraint)", fromIdx, toIdx))
        return
    end

    -- Call AddQueueResearchCommand directly because WBP_ResearchTree_2_C:QueueResearch uses DelayUntilNextFrame
    Core.Log(string.format("[ResearchEnhancements] Reordering research queue: %d -> %d (count=%d)", fromIdx, toIdx, count))
    local firstChanged = math.min(fromIdx, toIdx)
    for i = count, firstChanged, -1 do
        pcall(function()
            pc:AddQueueResearchCommand({ Technology = oldTechs[i], bAdd = false })
        end)
    end
    for i = firstChanged, count do
        pcall(function()
            pc:AddQueueResearchCommand({ Technology = newTechs[i], bAdd = true })
        end)
    end

    local function RefreshUI()
        if Core.IsValidObj(tree) then
            pcall(function()
                if tree.RefreshResearchQueue then tree:RefreshResearchQueue() end
                if tree.RefreshQueueButton then tree:RefreshQueueButton() end
            end)
        end
    end

    RefreshUI()
    ExecuteInGameThreadWithDelay(20, RefreshUI)
    ExecuteInGameThreadWithDelay(80, RefreshUI)
    ExecuteInGameThreadWithDelay(250, RefreshUI)
    ExecuteInGameThreadWithDelay(600, RefreshUI)
end

local function FindOwningTreeForQueueParent(parentWidget)
    if not Core.IsValidObj(parentWidget) then return nil, nil end
    local pAddr = parentWidget:GetAddress()

    local hasCachedTree = false
    for _, st in pairs(InjectedTrees) do
        if Core.IsValidObj(st.Tree) then
            hasCachedTree = true
            if Core.IsValidObj(st.Tree.ResearchQueueContainer)
                and st.Tree.ResearchQueueContainer:GetAddress() == pAddr
            then
                return st.Tree, st.Tree.ResearchQueueContainer
            end
            -- Early-return when clicking a non-queued tech inside a known ResearchList.Container
            -- so we never fall through to FindAllOf("WBP_ResearchTree_2_C") on every tech click.
            if Core.IsValidObj(st.ResearchList) and Core.IsValidObj(st.ResearchList.Container)
                and st.ResearchList.Container:GetAddress() == pAddr
            then
                return nil, nil
            end
        end
    end

    if hasCachedTree then
        return nil, nil
    end

    local okTrees, trees = pcall(FindAllOf, "WBP_ResearchTree_2_C")
    if okTrees and trees then
        for _, tree in ipairs(trees) do
            if Core.IsValidObj(tree) and Core.IsValidObj(tree.ResearchQueueContainer) then
                if tree.ResearchQueueContainer:GetAddress() == pAddr then
                    return tree, tree.ResearchQueueContainer
                end
            end
        end
    end
    return nil, nil
end

local ActiveDragGhost = nil

local function DestroyDragGhost()
    local ghost = ActiveDragGhost
    ActiveDragGhost = nil
    if Core.IsValidObj(ghost) then
        pcall(function() ghost:SetVisibility(1) end)
        pcall(function() ghost:RemoveFromParent() end)
    end
end

local function EnsureDragGhost(tree, pc, srcWidget)
    if Core.IsValidObj(ActiveDragGhost) then
        return ActiveDragGhost
    end
    local ghost = Core.CreateUserWidget(PATHS.ResearchTechnologyClass, tree, pc)
    if not Core.IsValidObj(ghost) then return nil end

    pcall(function()
        local tech = ResolveTechFromWidget(srcWidget)
        local resState = nil
        pcall(function() resState = Core.UnwrapArrayElem(srcWidget.ResearchState) end)
        if not Core.IsValidObj(resState) and Core.IsValidObj(tree) then
            pcall(function() resState = Core.UnwrapArrayElem(tree.ResearchState) end)
        end
        local treeView = nil
        pcall(function() treeView = Core.UnwrapArrayElem(srcWidget.ResearchTreeView) end)

        if Core.IsValidObj(tech) then pcall(function() ghost.Technology = tech end) end
        pcall(function() ghost.Research = srcWidget.Research end)
        if Core.IsValidObj(resState) then pcall(function() ghost.ResearchState = resState end) end
        if Core.IsValidObj(treeView) then pcall(function() ghost.ResearchTreeView = treeView end) end

        -- AddToViewport runs Construct() so internal widget tree (Image_0, Border_1, Button) is initialized
        ghost:SetVisibility(3) -- 3 = HitTestInvisible
        ghost:AddToViewport(200)
        if ghost.SetAnchorsInViewport then
            ghost:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        end
        if ghost.SetAlignmentInViewport then
            ghost:SetAlignmentInViewport({ X = 0.5, Y = 0.5 })
        end

        if Core.IsValidObj(treeView) and ghost.SetView then
            pcall(function() ghost:SetView(treeView) end)
        end
        if ghost.SetTechnology and Core.IsValidObj(tech) and Core.IsValidObj(resState) then
            pcall(function() ghost:SetTechnology(tech, resState) end)
        end
        if ghost.Refresh then pcall(function() ghost:Refresh() end) end
        if ghost.RefreshAvailable then pcall(function() ghost:RefreshAvailable() end) end
        if ghost.RefreshProgress then pcall(function() ghost:RefreshProgress() end) end

        -- Mirror Image_0 brush directly from source tile as a guaranteed icon fallback
        pcall(function()
            if Core.IsValidObj(srcWidget.Image_0) and Core.IsValidObj(ghost.Image_0) then
                if ghost.Image_0.SetBrush then
                    ghost.Image_0:SetBrush(srcWidget.Image_0.Brush)
                end
                local resObj = srcWidget.Image_0.Brush and srcWidget.Image_0.Brush.ResourceObject or nil
                if Core.IsValidObj(resObj) and ghost.Image_0.SetBrushResourceObject then
                    ghost.Image_0:SetBrushResourceObject(resObj)
                end
            end
        end)

        local w, h = nil, nil
        pcall(function()
            if srcWidget.GetDesiredSize then
                local dsz = srcWidget:GetDesiredSize()
                if dsz ~= nil then
                    local dx, dy = tonumber(dsz.X), tonumber(dsz.Y)
                    if dx and dx >= 40.0 and dx <= 600.0 then w = dx end
                    if dy and dy >= 40.0 and dy <= 600.0 then h = dy end
                end
            end
        end)
        if not w or not h then
            local slateLib = Core.GetCDO(PATHS.SlateLibCDO)
            if Core.IsValidObj(slateLib) and slateLib.GetLocalSize and srcWidget.GetCachedGeometry then
                local okS, sz = pcall(function()
                    return slateLib:GetLocalSize(srcWidget:GetCachedGeometry())
                end)
                if okS and sz ~= nil then
                    local sx, sy = tonumber(sz.X), tonumber(sz.Y)
                    if not w and sx and sx >= 40.0 and sx <= 600.0 then w = sx end
                    if not h and sy and sy >= 40.0 and sy <= 600.0 then h = sy end
                end
            end
        end
        if w and h and ghost.SetDesiredSizeInViewport then
            ghost:SetDesiredSizeInViewport({ X = w, Y = h })
        end
    end)

    ActiveDragGhost = ghost
    return ghost
end

local function StartQueueDrag(tree, queueBox, dragWidget, startIdx, count)
    if ActiveDrag then return end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    DestroyDragGhost()
    local startX, startY = GetViewportMousePos(pc)
    local gridCols, slotStepX, slotStepY = MeasureQueueGridLayout(tree, queueBox, count)
    local snapshotTechs = CollectQueuedTechs(tree, queueBox)

    local dragState = {
        Tree = tree,
        QueueBox = queueBox,
        DragWidget = dragWidget,
        SnapshotTechs = snapshotTechs,
        StartIdx = startIdx,
        TargetIdx = startIdx,
        Count = count,
        GridCols = gridCols,
        SlotStep = slotStepX,
        SlotStepY = slotStepY,
        IsDragging = false,
        StartX = startX,
        StartY = startY,
    }
    ActiveDrag = dragState

    local function DragPollStep()
        if ActiveDrag ~= dragState then return false end

        local treeOk = Core.IsValidObj(dragState.Tree)
            and Core.IsValidObj(dragState.QueueBox)
            and Core.IsValidObj(dragState.DragWidget)

        local btnPressed = false
        if treeOk then
            pcall(function()
                btnPressed = Core.IsValidObj(dragState.DragWidget.Button)
                    and dragState.DragWidget.Button:IsPressed() == true
            end)
        end

        local mouseDown = false
        if Core.IsValidObj(pc) then
            local okDown, down = pcall(function()
                return pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") })
            end)
            mouseDown = okDown and down == true
        end

        local treeVisible = false
        if treeOk then
            local okVis, vis = pcall(function() return dragState.Tree:IsVisible() end)
            treeVisible = okVis and vis == true
        end

        if not treeOk or not treeVisible or (not btnPressed and not mouseDown) then
            ActiveDrag = nil
            DestroyDragGhost()
            local wasDragging = dragState.IsDragging
            local fromIdx = dragState.StartIdx
            local toIdx = dragState.TargetIdx
            ResetQueueChildVisuals(dragState.QueueBox)
            if treeOk and wasDragging and toIdx ~= fromIdx then
                ReorderResearchQueue(dragState.Tree, fromIdx, toIdx, dragState.SnapshotTechs)
            end
            return false
        end

        local curX, curY = GetViewportMousePos(pc)
        local dx, dy = 0.0, 0.0
        if curX and curY then
            if not dragState.StartX or not dragState.StartY then
                dragState.StartX = curX
                dragState.StartY = curY
            end
            dx = curX - dragState.StartX
            dy = curY - dragState.StartY
            if not dragState.IsDragging and (dx * dx + dy * dy) > 25.0 then
                dragState.IsDragging = true
            end
        end

        if dragState.IsDragging then
            local stepX = dragState.SlotStep or 64.0
            local stepY = dragState.SlotStepY or stepX
            local cols = math.max(1, dragState.GridCols or dragState.Count)
            local startCol = (dragState.StartIdx - 1) % cols
            local startRow = math.floor((dragState.StartIdx - 1) / cols)
            local maxRow = math.floor((dragState.Count - 1) / cols)

            local deltaCol = (dx >= 0.0)
                and math.floor((dx + stepX * 0.5) / stepX)
                or math.ceil((dx - stepX * 0.5) / stepX)
            local deltaRow = (dy >= 0.0)
                and math.floor((dy + stepY * 0.5) / stepY)
                or math.ceil((dy - stepY * 0.5) / stepY)

            local targetCol = Core.Clamp(startCol + deltaCol, 0, cols - 1)
            local targetRow = Core.Clamp(startRow + deltaRow, 0, maxRow)
            local desiredIdx = Core.Clamp(targetRow * cols + targetCol + 1, 1, dragState.Count)

            local validTargetIdx, isDesiredValid = ClampValidDropTarget(dragState.SnapshotTechs, dragState.StartIdx, desiredIdx)
            dragState.TargetIdx = validTargetIdx

            local ghost = EnsureDragGhost(dragState.Tree, pc, dragState.DragWidget)
            if Core.IsValidObj(ghost) then
                pcall(function()
                    if curX and curY and ghost.SetPositionInViewport then
                        ghost:SetPositionInViewport({ X = curX, Y = curY }, false)
                    end
                    if ghost.SetRenderScale then
                        ghost:SetRenderScale({ X = 1.08, Y = 1.08 })
                    end
                    ghost:SetRenderOpacity(isDesiredValid and 0.95 or 0.65)
                end)
            end

            pcall(function()
                local qCount = dragState.QueueBox:GetChildrenCount()
                for i = 0, qCount - 1 do
                    local slotIdx = i + 1
                    local ch = dragState.QueueBox:GetChildAt(i)
                    if Core.IsValidObj(ch) then
                        if slotIdx == dragState.StartIdx then
                            -- Dim original queue slot in place while the viewport ghost floats on top
                            ch:SetRenderTranslation({ X = 0.0, Y = 0.0 })
                            if ch.SetRenderScale then
                                ch:SetRenderScale({ X = 1.0, Y = 1.0 })
                            end
                            ch:SetRenderOpacity(Core.IsValidObj(ghost) and 0.18 or (isDesiredValid and 0.95 or 0.65))
                        else
                            if ch.SetRenderScale then
                                ch:SetRenderScale({ X = 1.0, Y = 1.0 })
                            end
                            ch:SetRenderOpacity(1.0)
                            local shiftX, shiftY = 0.0, 0.0
                            local destIdx = nil
                            if dragState.StartIdx < validTargetIdx and slotIdx > dragState.StartIdx and slotIdx <= validTargetIdx then
                                destIdx = slotIdx - 1
                            elseif dragState.StartIdx > validTargetIdx and slotIdx >= validTargetIdx and slotIdx < dragState.StartIdx then
                                destIdx = slotIdx + 1
                            end
                            if destIdx then
                                local srcC = (slotIdx - 1) % cols
                                local srcR = math.floor((slotIdx - 1) / cols)
                                local dstC = (destIdx - 1) % cols
                                local dstR = math.floor((destIdx - 1) / cols)
                                shiftX = (dstC - srcC) * stepX
                                shiftY = (dstR - srcR) * stepY
                            end
                            ch:SetRenderTranslation({ X = shiftX, Y = shiftY })
                        end
                    end
                end
            end)
        end

        return true
    end

    local function DragPoll()
        local ok, keepPolling = pcall(DragPollStep)
        if not ok then
            Core.Log("[ResearchEnhancements] DragPoll error: " .. tostring(keepPolling))
            ActiveDrag = nil
            DestroyDragGhost()
            ResetQueueChildVisuals(dragState.QueueBox)
            return
        end
        if keepPolling then
            ExecuteInGameThreadWithDelay(16, DragPoll)
        end
    end

    ExecuteInGameThreadWithDelay(16, DragPoll)
end

local ScanningTrees = false

local function ScanExistingTrees()
    if ScanningTrees or not Core.IsFeatureEnabled("ResearchEnhancements") then return end
    ScanningTrees = true
    local okTrees, trees = pcall(FindAllOf, "WBP_ResearchTree_2_C")
    if okTrees and trees then
        for _, tree in ipairs(trees) do
            if Core.IsValidObj(tree) then
                local alreadyInjected = InjectedTrees[tree:GetAddress()] ~= nil
                EnsureAndFilterTree(tree, not alreadyInjected)
            end
        end
    end
    ScanningTrees = false
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    WBP_ResearchTree_2_C = function(tree)
        Feature.RegisterHooks()
        if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
        ExecuteInGameThreadWithDelay(60, function()
            if Core.IsFeatureEnabled("ResearchEnhancements") then
                EnsureAndFilterTree(tree, true)
            end
        end)
    end,
}

function Feature.RegisterHooks()
    local treeHookFns = {
        { name = "SetupWidget",         captureBase = true },
        { name = "SetFilter",           captureBase = true },
        { name = "Refresh",             captureBase = false },
        { name = "OnResearchCompleted", captureBase = false },
    }
    for _, hookSpec in ipairs(treeHookFns) do
        local fnName = hookSpec.name
        local recapture = hookSpec.captureBase
        Core.TryRegisterHook(
            "ResearchEnhancements_" .. fnName,
            PATHS.ResearchTreeClass .. ":" .. fnName,
            function(Context)
                if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
                local tree = Context:get()
                if Core.IsValidObj(tree) then
                    ExecuteInGameThreadWithDelay(30, function()
                        if Core.IsFeatureEnabled("ResearchEnhancements") then
                            EnsureAndFilterTree(tree, recapture)
                        end
                    end)
                end
            end
        )
    end

    Core.TryRegisterHook(
        "ResearchEnhancements_RefreshList",
        PATHS.ResearchListClass .. ":RefreshList",
        function(Context)
            if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
            local rList = Context:get()
            if Core.IsValidObj(rList) then
                ExecuteInGameThreadWithDelay(20, function()
                    if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
                    local tree = ResolveTreeForList(rList)
                    if Core.IsValidObj(tree) then
                        local st = InjectedTrees[tree:GetAddress()]
                        if st then
                            st.LastWideAlpha = {}
                        end
                        EnsureAndFilterTree(tree, true)
                    end
                end)
            end
        end
    )

    Core.TryRegisterHook(
        "ResearchEnhancements_OnTextChanged",
        PATHS.TextInputClass .. ":BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_0_OnEditableTextBoxChangedEvent__DelegateSignature",
        function(Context, textParam)
            if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
            local inputWidget = Context:get()
            if not Core.IsValidObj(inputWidget) then return end
            local st = InputToTree[inputWidget:GetAddress()]
            if not st then return end

            local override = nil
            pcall(function()
                local raw = (textParam and type(textParam.get) == "function") and textParam:get() or textParam
                if type(raw) == "string" or (raw ~= nil and raw.ToString) then
                    override = SafeTextToString(raw)
                end
            end)
            ScheduleResearchFilter(st, override)
        end
    )

    Core.TryRegisterHook(
        "ResearchEnhancements_OnTechButtonPressed",
        PATHS.ResearchTechnologyClass .. ":BndEvt__WBP_ResearchTechnology_Button_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            if not Core.IsFeatureEnabled("ResearchEnhancements") then return end
            local widget = Context:get()
            if not Core.IsValidObj(widget) then return end

            local parent = nil
            pcall(function() parent = widget:GetParent() end)
            local tree, queueBox = FindOwningTreeForQueueParent(parent)
            if not (Core.IsValidObj(tree) and Core.IsValidObj(queueBox)) then return end

            local count = 0
            local startIdx = nil
            pcall(function()
                count = queueBox:GetChildrenCount()
                local targetAddr = widget:GetAddress()
                for i = 0, count - 1 do
                    local ch = queueBox:GetChildAt(i)
                    if Core.IsValidObj(ch) and ch:GetAddress() == targetAddr then
                        startIdx = i + 1
                        break
                    end
                end
            end)

            if startIdx and count > 1 and Core.IsFeatureEnabled("ResearchEnhancements") then
                StartQueueDrag(tree, queueBox, widget, startIdx, count)
            end
        end
    )
end

local function CancelActiveDrag()
    if ActiveDrag and Core.IsValidObj(ActiveDrag.QueueBox) then
        ResetQueueChildVisuals(ActiveDrag.QueueBox)
    end
    ActiveDrag = nil
    DestroyDragGhost()
end

function Feature.OnToggle(enabled)
    PendingFilterToken = PendingFilterToken + 1
    if not enabled then
        for _, st in pairs(InjectedTrees) do
            if st then
                ClearSearchInput(st)
                st.FilterDirty = false
                st.LastAppliedQuery = nil
                ApplyResearchFilter(st, "")
                SetResearchSearchVisible(st, false)
            end
        end
        CancelActiveDrag()
    else
        for _, st in pairs(InjectedTrees) do
            if st and Core.IsValidObj(st.SearchInput) then
                InputToTree[st.SearchInput:GetAddress()] = st
                SetResearchSearchVisible(st, true)
                st.LastAppliedQuery = nil
                ApplyResearchFilter(st)
            end
        end
        ScanExistingTrees()
    end
end

function Feature.OnClientRestart()
    CancelActiveDrag()
    TechSearchTextCache = {}
    ObjectSearchTextCache = {}
    Feature.RegisterHooks()
    ScanExistingTrees()
end

function Feature.OnMapLoad()
    CancelActiveDrag()
    DestroyDragGhost()
    InjectedTrees = {}
    InputToTree = {}
    ListToTree = {}
    TechSearchTextCache = {}
    ObjectSearchTextCache = {}
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedTrees) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.SearchInput) then
            InjectedTrees[addr] = nil
        end
    end
    for inputAddr, st in pairs(InputToTree) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.SearchInput) then
            InputToTree[inputAddr] = nil
        end
    end
    for listAddr, st in pairs(ListToTree) do
        if not Core.IsValidObj(st.Tree) or not Core.IsValidObj(st.ResearchList) then
            ListToTree[listAddr] = nil
        end
    end
    if not ActiveDrag then
        DestroyDragGhost()
    end
end

function Feature.Init()
    Feature.RegisterHooks()
    ExecuteInGameThreadWithDelay(100, ScanExistingTrees)
end

return Feature
