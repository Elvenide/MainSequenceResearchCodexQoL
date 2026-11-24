-- Eqol Feature: Codex / Help Menu Search Bar
-- Injects a native-styled search box into each tab of the Help Menu (K) and filters entries live.

local Core = require("core")

local Feature = {
    Name        = "CodexSearch",
    DisplayName = "Help / Codex Search Bar",
    Description = "Adds a live search box to filter entries in the Help / Codex menu (K).",
}

local PATHS = {
    CodexContentClass = "/Game/Blueprints/Widgets/Display/Codex/WBP_CodexContent.WBP_CodexContent_C",
    TextInputClass    = "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C",
    VerticalBoxClass  = "/Script/UMG.VerticalBox",
    SizeBoxClass      = "/Script/UMG.SizeBox",
}

local InjectedCodex = {} -- codexContentAddr -> state
local InputToCodex = {}  -- textInputAddr -> state

local EnsureCodexSearchBar -- forward declaration

local function ReadCodexQuery(st)
    if not st or not Core.IsValidObj(st.SearchInput) then return "" end
    local raw = nil
    pcall(function()
        if Core.IsValidObj(st.SearchInput.EditableTextBox_80) then
            raw = st.SearchInput.EditableTextBox_80:GetText():ToString()
        end
    end)
    if raw == nil then
        pcall(function()
            if st.SearchInput.GetText then
                local txt = st.SearchInput:GetText()
                if txt then raw = txt:ToString() end
            end
        end)
    end
    return type(raw) == "string" and raw or ""
end

local function SetCodexSearchText(st, textStr)
    if not st or not Core.IsValidObj(st.SearchInput) then return end
    st.SuppressTextEvent = true
    pcall(function()
        local txt = Core.MakeText(textStr or "")
        if st.SearchInput.SetText then
            st.SearchInput:SetText(txt)
        elseif Core.IsValidObj(st.SearchInput.EditableTextBox_80) then
            st.SearchInput.EditableTextBox_80:SetText(txt)
        end
    end)
    st.SuppressTextEvent = false
end

local function GetEntryButtonLabel(btn)
    if not Core.IsValidObj(btn) then return "" end
    local label = nil
    pcall(function()
        if btn.DisplayName ~= nil then
            label = btn.DisplayName:ToString()
        end
    end)
    if type(label) == "string" and label ~= "" then
        return label
    end
    pcall(function()
        if Core.IsValidObj(btn.WBP_Text) and Core.IsValidObj(btn.WBP_Text.TextBlock) then
            label = btn.WBP_Text.TextBlock:GetText():ToString()
        end
    end)
    return type(label) == "string" and label or ""
end

local function ApplyCodexFilter(st, overrideQuery)
    if not st or not Core.IsValidObj(st.CodexContent) or not Core.IsValidObj(st.EntryList) then
        return
    end

    local rawText = (type(overrideQuery) == "string") and overrideQuery or ReadCodexQuery(st)
    local curTab = 0
    pcall(function() curTab = tonumber(st.CodexContent.SelectedTab) or 0 end)
    st.TabQueries[curTab] = rawText

    local trimmed = rawText:match("^%s*(.-)%s*$") or ""
    local q = string.lower(trimmed)

    pcall(function()
        local count = st.EntryList:GetChildrenCount()
        for i = 0, count - 1 do
            local child = st.EntryList:GetChildAt(i)
            if Core.IsValidObj(child) then
                local nameStr = GetEntryButtonLabel(child)
                local matched = (q == "") or (string.find(string.lower(nameStr), q, 1, true) ~= nil)
                child:SetVisibility(matched and 0 or 1)
            end
        end
        st.EntryList:ScrollToStart()
    end)
end

local function SyncTabAndFilter(codexContent)
    if not Core.IsFeatureEnabled("CodexSearch") then return end
    if not Core.IsValidObj(codexContent) then return end
    local st = EnsureCodexSearchBar(codexContent)
    if not st then return end

    local curTab = 0
    pcall(function() curTab = tonumber(codexContent.SelectedTab) or 0 end)
    if curTab ~= st.LastTab then
        st.LastTab = curTab
        SetCodexSearchText(st, st.TabQueries[curTab] or "")
    end

    ApplyCodexFilter(st)
end

EnsureCodexSearchBar = function(codexContent)
    Feature.RegisterHooks()
    if not Core.IsValidObj(codexContent) then return nil end

    local addr = codexContent:GetAddress()
    local existing = InjectedCodex[addr]
    if existing and Core.IsValidObj(existing.SearchInput) and Core.IsValidObj(existing.EntryList) then
        return existing
    end

    local entryList = codexContent.EntryListContainer
    if not Core.IsValidObj(entryList) then return nil end

    local parentContainer = nil
    pcall(function() parentContainer = entryList:GetParent() end)
    if not Core.IsValidObj(parentContainer) then return nil end

    local outer = Core.GetWidgetOuter(codexContent)
    local okPC, owningPC = pcall(function() return codexContent:GetOwningPlayer() end)
    local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()

    local leftColVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local searchSizeBox = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local searchInput = Core.CreateUserWidget(PATHS.TextInputClass, codexContent, pc)

    if not (Core.IsValidObj(leftColVBox) and Core.IsValidObj(searchSizeBox) and Core.IsValidObj(searchInput)) then
        return nil
    end

    pcall(function()
        searchSizeBox:SetHeightOverride(34.0)
        searchInput.Size = 13
        searchInput["Minimum Width"] = 280.0
    end)

    local sInSlot = searchSizeBox:AddChild(searchInput)
    if Core.IsValidObj(sInSlot) then
        pcall(function()
            sInSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sInSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    -- Targeted removal only: never ClearChildren() on parentContainer in case future updates add siblings
    pcall(function() entryList:RemoveFromParent() end)

    local sbSlot = parentContainer:AddChild(leftColVBox)
    if Core.IsValidObj(sbSlot) then
        pcall(function()
            sbSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sbSlot:SetVerticalAlignment(0)   -- VAlign_Fill
        end)
    end

    local sSlot = leftColVBox:AddChildToVerticalBox(searchSizeBox)
    if Core.IsValidObj(sSlot) then
        pcall(function()
            sSlot:SetHorizontalAlignment(0) -- HAlign_Fill
            sSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 8.0 })
        end)
    end

    local eSlot = leftColVBox:AddChildToVerticalBox(entryList)
    if Core.IsValidObj(eSlot) then
        pcall(function()
            eSlot:SetSize({ Value = 1.0, SizeRule = 1 }) -- Fill
            eSlot:SetHorizontalAlignment(0)               -- HAlign_Fill
            eSlot:SetVerticalAlignment(0)                 -- VAlign_Fill
        end)
    end

    pcall(function()
        if Core.IsValidObj(searchInput.EditableTextBox_80) then
            searchInput.EditableTextBox_80:SetHintText(Core.MakeText("Search..."))
            searchInput.EditableTextBox_80:SetText(Core.MakeText(""))
            searchInput.EditableTextBox_80.MinimumDesiredWidth = 280.0
        elseif searchInput.SetText then
            searchInput:SetText(Core.MakeText(""))
        end
    end)

    local initTab = 0
    pcall(function() initTab = tonumber(codexContent.SelectedTab) or 0 end)

    -- Opportunistically prune stale entries before inserting
    for k, old in pairs(InjectedCodex) do
        if not old or not Core.IsValidObj(old.CodexContent) or not Core.IsValidObj(old.SearchInput) then
            InjectedCodex[k] = nil
        end
    end
    for k, old in pairs(InputToCodex) do
        if not old or not Core.IsValidObj(old.CodexContent) or not Core.IsValidObj(old.SearchInput) then
            InputToCodex[k] = nil
        end
    end

    local st = {
        CodexContent = codexContent,
        SearchInput = searchInput,
        SearchBox = searchSizeBox,
        EntryList = entryList,
        TabQueries = {},
        LastTab = initTab,
        SuppressTextEvent = false,
    }
    InjectedCodex[addr] = st
    InputToCodex[searchInput:GetAddress()] = st
    Core.RegisterTextInput(searchInput, codexContent)
    return st
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

Feature.WatchWidgets = {
    -- Watch only WBP_CodexContent_C (always constructed inside WBP_Codex_C) to avoid double-trigger on open
    WBP_CodexContent_C = function(codexContent)
        if not Core.IsFeatureEnabled("CodexSearch") then return end
        Feature.RegisterHooks()
        ExecuteInGameThreadWithDelay(60, function()
            if Core.IsFeatureEnabled("CodexSearch") and Core.IsValidObj(codexContent) then
                SyncTabAndFilter(codexContent)
            end
        end)
    end,
}

function Feature.OnToggle(enabled)
    local vis = enabled and 0 or 1
    for _, st in pairs(InjectedCodex) do
        if st then
            if Core.IsValidObj(st.SearchBox) then
                pcall(function() st.SearchBox:SetVisibility(vis) end)
            end
            if Core.IsValidObj(st.SearchInput) then
                pcall(function() st.SearchInput:SetVisibility(vis) end)
                if not enabled then
                    local curTab = 0
                    pcall(function() curTab = tonumber(st.CodexContent.SelectedTab) or 0 end)
                    local savedQuery = st.TabQueries[curTab]
                    ApplyCodexFilter(st, "")
                    st.TabQueries[curTab] = savedQuery
                else
                    ApplyCodexFilter(st)
                end
            end
        end
    end
end

function Feature.RegisterHooks()
    local codexHookFns = {
        "SetSelectedTab",
        "CreateTutorialList",
        "CreateItemList",
        "CreateMachineList",
        "CreateShipModuleList",
        "CreateStationModuleList",
    }

    for _, fnName in ipairs(codexHookFns) do
        Core.TryRegisterHook(
            "CodexSearch_" .. fnName,
            PATHS.CodexContentClass .. ":" .. fnName,
            function(Context)
                if not Core.IsFeatureEnabled("CodexSearch") then return end
                local codexContent = Context:get()
                if Core.IsValidObj(codexContent) then
                    ExecuteInGameThreadWithDelay(30, function()
                        if Core.IsValidObj(codexContent) and Core.IsFeatureEnabled("CodexSearch") then
                            SyncTabAndFilter(codexContent)
                        end
                    end)
                end
            end
        )
    end

    Core.TryRegisterHook(
        "CodexSearch_OnTextChanged",
        PATHS.TextInputClass .. ":BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_0_OnEditableTextBoxChangedEvent__DelegateSignature",
        function(Context, textParam)
            local inputWidget = Context:get()
            if not Core.IsValidObj(inputWidget) then return end
            local st = InputToCodex[inputWidget:GetAddress()]
            if not st or st.SuppressTextEvent then return end

            local override = nil
            pcall(function()
                local raw = (textParam and type(textParam.get) == "function") and textParam:get() or textParam
                if type(raw) == "string" then
                    override = raw
                elseif raw and raw.ToString then
                    override = raw:ToString()
                end
            end)
            ApplyCodexFilter(st, override)
        end
    )
end

function Feature.PruneCaches()
    for addr, st in pairs(InjectedCodex) do
        if not Core.IsValidObj(st.SearchInput) or not Core.IsValidObj(st.CodexContent) then
            InjectedCodex[addr] = nil
        end
    end
    for inputAddr, st in pairs(InputToCodex) do
        if not Core.IsValidObj(st.SearchInput) or not Core.IsValidObj(st.CodexContent) then
            InputToCodex[inputAddr] = nil
        end
    end
end

return Feature
