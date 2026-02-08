-- @description RAPID - Recording Auto-Placement & Intelligent Dynamics
-- @author Frank Acklin
-- @version 2.5
-- @changelog
--   Multi-RPP Import: import multiple RPP files into one template
--   Merged tempo/time-signatures with full API fidelity (no project reload)
--   Time-based offset system (seconds) for all positioning
--   Track consolidation with lane alignment and group flag copying
--   Column-based mapping UI with per-RPP dropdowns and drag-drop reordering
--   Editable template track names in both single and multi-RPP mode
-- @about
--   # RAPID
--
--   Professional workflow automation for REAPER that automates track mapping,
--   media import, and LUFS normalization.
--
--   ## Four Workflows
--
--   - **Full Workflow**: Import + mapping + normalization in one pass
--   - **Import Mode (Single RPP)**: Map recording tracks to mix template (preserves FX, sends, routing)
--   - **Import Mode (Multi-RPP)**: Import multiple RPP files into one template with merged tempo
--   - **Normalize Mode**: Standalone LUFS normalization on existing tracks
--
--   ## Features
--
--   - Multi-RPP import with merged tempo, regions, and markers
--   - Fuzzy matching with aliases for automatic track suggestions
--   - Multi-slot mapping with auto-duplicate for multiple sources
--   - LUFS calibration system for creating custom normalization profiles
--   - Per-profile LUFS settings (segment size, percentile, threshold)
--   - Offline media auto-relinking via progressive path suffix matching
--   - MixnoteStyle dark theme
--
--   ## Requirements
--
--   - REAPER 6.0+
--   - ReaImGui (required)
--   - SWS Extension (required)
--   - JS_ReaScriptAPI (optional, for multi-file dialogs)
-- @link GitHub https://github.com/acklin83/RAPID
-- @provides
--   [main] .
--
-- RAPID - Recording Auto-Placement & Intelligent Dynamics v2.5
--
-- Unified version combining RAPID (Import & Mapping) with Little Joe (Normalize-Only)
--
-- Modes:
-- ------
-- [x] Import  [x] Normalize = Full RAPID workflow (import + map + normalize)
-- [x] Import  [ ] Normalize = Import & map only (no normalization)
-- [ ] Import  [x] Normalize = Little Joe mode (normalize existing tracks)
--
-- See Project Notes for full documentation
--
-- NEW in v2.5:
-- - Multi-RPP Import: Import multiple RPP files into the same template
-- - Drag-and-drop reordering of RPP queue
-- - Per-RPP regions created automatically
-- - Tempo/time-signature changes merged from all RPPs (time-based)
-- - Markers imported with correct measure offsets
-- - Configurable gap between RPPs (in measures, default: 2)
-- - JS_ReaScriptAPI multi-file dialog support
--
-- NEW in v2.4:
-- - LUFS Calibration System: Create/update profiles from perfectly leveled reference tracks
-- - Per-profile LUFS measurement settings (segment size, percentile, threshold)
-- - Removed global LUFS settings (now profile-specific or use defaults)
-- - "Calibrate from Selection" button in Settings → Normalization tab
--
-- NEW in v2.3:
-- - Editable track names, duplicate slot improvements, delete unused toggle
-- - Offline media fix (progressive path suffix matching)
-- - DrawList lock icon, help text rewrite
--
-- NEW in v2.2:
-- - MixnoteStyle dark theme (Indigo accent, 4-level background hierarchy)
-- - Compact toolbar layout, sec_button for secondary actions
--

local r = reaper

-- ===== VERSION =====
local VERSION = "2.5"
local WINDOW_TITLE = "RAPID v" .. VERSION

-- ===== Capability checks =====
local HAVE_SWS = (r.BR_GetMediaTrackSendInfo_Track ~= nil)
local HAVE_JS  = (r.JS_Dialog_BrowseForOpenFiles ~= nil)
local HAVE_IMGUI = (r.ImGui_CreateContext ~= nil)

if not HAVE_IMGUI then
    r.ShowMessageBox("ReaImGui is required. Please install via ReaPack.", "Missing Dependency", 0)
    return
end

-- ===== Constants =====
local ONLY_WITH_MEDIA    = true
local AUTOSUGGEST_THRESH = 0.60

-- LUFS type for CalculateNormalization: 4 = LUFS-M max (Momentary max)
local LUFS_TYPE_M_MAX = 4

-- Default LUFS measurement settings (used when profile doesn't have custom settings)
local DEFAULT_LUFS_SEGMENT_SIZE = 10.0      -- seconds (5-30)
local DEFAULT_LUFS_PERCENTILE = 90          -- percent (80-99)
local DEFAULT_LUFS_THRESHOLD = -40.0        -- LUFS (segments below this are ignored)

-- ===== ExtState Keys =====
local EXT_SECTION  = "RAPID_Unified"
local EXT_LASTMAP  = "last_map"
local EXT_WINGEOM  = "win_geom"
local EXT_SESSION  = "session_data"

-- ===== .ini File Path =====
local function getConfigIniPath()
    local script_path = ({r.get_action_context()})[2]
    local script_dir = script_path:match("^(.+[/\\])")
    return (script_dir or "") .. "RAPID_Config.ini"
end

-- Legacy (kept for reference during migration)
local function getIniPath()
    local script_path = ({r.get_action_context()})[2]
    local script_dir = script_path:match("^(.+[/\\])")
    return (script_dir or "") .. "RAPID.ini"
end

-- ===== DEFAULT PROFILES =====
local DEFAULT_PROFILES = {
    {name = "Peak", offset = 0, defaultPeak = -6},
    {name = "RMS", offset = 0, defaultPeak = -12},
    {name = "Kick", offset = 18, defaultPeak = -6},
    {name = "Snare", offset = 18, defaultPeak = -6},
    {name = "Tom", offset = 14, defaultPeak = -6},
    {name = "OH", offset = 12, defaultPeak = -12},
    {name = "Bass", offset = 6, defaultPeak = -10},
    {name = "Guitar", offset = 8, defaultPeak = -12},
    {name = "Vocal", offset = 10, defaultPeak = -10},
    {name = "Room", offset = 6, defaultPeak = -12}
}

local DEFAULT_BUS_KEYWORDS = {"MIXES", "FX", "Sidechains", "BUS", "Ref", "ANALOGUE"}

local DEFAULT_ALIASES = {
    {src = "voc", dst = "Voc 1"},
    {src = "git", dst = "Gtr"},
    {src = "kik", dst = "Kik In"},
    {src = "Sn Top", dst = "Snare"},
    {src = "Valvet", dst = "Room"},
    {src = "Coles", dst = "Room 2"},
    {src = "Workshop", dst = "Room Mono"},
    {src = "Sn Bott", dst = "Sn Bottom"},
    {src = "Flo", dst = "Voc 1"}
}

local DEFAULT_PROFILE_ALIASES = {
    {src = "kik, kick, kick out, bd", dst = "Kick"},
    {src = "snare, sd, sn bottom", dst = "Snare"},
    {src = "t1, t2, t3, t4, tom", dst = "Tom"},
    {src = "oh, hi hat, hat, ride", dst = "OH"},
    {src = "room", dst = "Room"},
    {src = "bass", dst = "Bass"},
    {src = "gtr, guit, git", dst = "Guitar"},
    {src = "voc, bvoc", dst = "Vocal"}
}


-- ===== ImGui Context (forward declaration for theme functions) =====
local ctx

-- ===== MIXNOTE THEME =====
-- Theme colors consolidated into table to reduce local variable count
local theme = {
    COLOR_COUNT = 26,
    VAR_COUNT = 10,
    -- Backgrounds (4-level hierarchy)
    bg_body   = 0x0F0F0FFF,
    bg_card   = 0x1A1A1AFF,
    bg_input  = 0x2A2A2AFF,
    bg_border = 0x3A3A3AFF,
    -- Accent (Indigo)
    accent        = 0x6366F1FF,
    accent_hover  = 0x5558E8FF,
    accent_active = 0x4F46E5FF,
    accent_dim    = 0x6366F140,
    -- Text
    text       = 0xE5E7EBFF,
    text_dim   = 0x9CA3AFFF,
    text_muted = 0x6B7280FF,
    -- Status
    green  = 0x4ADE80FF,
    amber  = 0xF59E0BFF,
    red    = 0xEF4444FF,
}

local function apply_theme()
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(),       theme.bg_body)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(),        0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(),        theme.bg_card)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(),         theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),           theme.text)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(),   theme.text_muted)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),        theme.bg_input)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(),  theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),         theme.accent)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(),  theme.accent_hover)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),   theme.accent_active)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(),         theme.accent_dim)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(),  0x6366F160)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(),   0x6366F180)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Tab(),            theme.bg_card)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabHovered(),     theme.accent)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarBg(),    theme.bg_body)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrab(),  theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabHovered(), theme.text_muted)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ScrollbarGrabActive(),  theme.text_dim)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(),      theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(),      theme.accent)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBg(),        theme.bg_body)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgActive(),  theme.bg_card)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TitleBgCollapsed(), theme.bg_body)

    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(),     8, 8)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(),      6, 3)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(),       8, 4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(),     4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(),    6)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ChildRounding(),     4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupRounding(),     4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ScrollbarRounding(), 4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(),      4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowBorderSize(),  0)
end

local function pop_theme()
    r.ImGui_PopStyleColor(ctx, theme.COLOR_COUNT)
    r.ImGui_PopStyleVar(ctx, theme.VAR_COUNT)
end

local function sec_button(label)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        theme.bg_input)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), theme.bg_border)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  theme.text_muted)
    local pressed = r.ImGui_SmallButton(ctx, label)
    r.ImGui_PopStyleColor(ctx, 3)
    return pressed
end

-- ===== MODE STATE =====
local importMode = true      -- Import & mapping functionality (RAPID)
local normalizeMode = true   -- Normalization functionality (Little Joe)

-- ===== GLOBAL STATE =====
local normProfiles = {}
local busKeywords = {}
local aliases = {}
local profileAliases = {}  -- Track name contains -> Profile name mappings
local protectedSet = {}
local keepSet = {}
local settings = {
    -- Mode settings
    importMode = true,
    normalizeMode = true,

    -- Import mode settings
    autoMatchTracksOnImport = true,
    autoMatchProfilesOnImport = true,
    copyMedia = false,  -- Copy media into project on commit (was copyMediaOnCommit)

    -- Normalize mode settings
    processPerRegion = true,
    createNewLane = true,
    deleteBetweenRegions = true,

    -- Note: LUFS settings are now per-profile (see DEFAULT_LUFS_* constants for defaults)

    -- UI settings
    swatch_size = 12,
    enableConsoleLogging = false,
    deleteUnused = false,  -- was standalone deleteUnusedMode (0/1), now boolean in settings
}

-- Mapping data (Import Mode)
local recPath = {
    rpp = nil,          -- Path to source .rpp file (was recPathRPP)
    dir = nil,          -- Directory of source .rpp (was recPathRPPDir)
    regionCount = 0,    -- Count of regions in source RPP (was recSourceRegionCount)
}
local recSources = {}
local mixTargets = {}
local map = {}
local normMap = {}  -- Maps trackIndex -> slotIndex -> {profile, targetPeak}
local keepMap = {}  -- Maps trackIndex -> slotIndex -> boolean (keep source name)
local fxMap = {}    -- Maps trackIndex -> slotIndex -> boolean (keep source FX)
-- deleteUnusedMode consolidated into settings.deleteUnused (boolean) to save local slot

-- Normalize-Only Mode data
local tracks = {}          -- Array of {track, name} for normalize-only mode
local normMapDirect = {}   -- Maps track index -> {profile, targetPeak} for normalize-only mode

-- UI state (grouped to stay under Lua's 200 local variable limit)
local uiFlags = {
    settings = false,
    help = false,
    close = false,
    winInit = false,
}

-- Multi-select & drag state
local selectedRows = {}      -- Set of selected row IDs (format: "mixIdx_slotIdx")
local dragState = {
    lastClicked = nil,   -- Last clicked row ID for Shift-range selection
    sel = nil,       -- Drag selection state for Sel column
    lock = nil,      -- Drag state for Lock checkbox
    keepName = nil,  -- Drag state for Keep Name checkbox
    keepFX = nil,    -- Drag state for Keep FX checkbox
}

-- Inline editing state
local editState = {
    track = nil,         -- Edit key "i_s" currently being renamed (double-click)
    buf = "",            -- Buffer for the InputText
    slotNames = {},      -- slotNames[i][s] = custom name for duplicate slots (s >= 2)
}

-- Calibration window state
local calibrationWindow = {
    open = false,
    itemName = "",
    measuredPeak = 0,
    measuredLUFS = 0,
    calculatedOffset = 0,
    editablePeak = 0,
    -- Measurement settings (editable in dialog)
    segmentSize = DEFAULT_LUFS_SEGMENT_SIZE,
    percentile = DEFAULT_LUFS_PERCENTILE,
    threshold = DEFAULT_LUFS_THRESHOLD,
    -- Profile selection
    selectedProfileIdx = 0,  -- 0 = "Create new"
    newProfileName = "",
    errorMsg = "",
}

-- ===== MULTI-RPP IMPORT STATE (v2.5) =====
local rppQueue = {}              -- Array of RPP entries for multi-import
--[[
rppQueue[i] = {
    path = "/path/to/recording.rpp",
    dir = "/path/to/",
    name = "Song Name",           -- From filename, editable
    rppText = "",                 -- Raw RPP text (cached for tempo extraction)
    tracks = {},                  -- Extracted track data (like recSources entries)
    lengthInMeasures = 0,         -- Length in measures (rounded up to complete measure)
    measureOffset = 0,            -- Start measure on timeline (calculated)
    qnOffset = 0,                 -- Start position in quarter notes (accumulated correctly)
    tempoMap = {},                -- Extracted tempo/time-sig points
    markers = {},                 -- Extracted markers
    baseTempo = {bpm=120, num=4, denom=4},  -- Initial tempo
}
]]
local multiMap = {}              -- multiMap[mixIdx][rppIdx] = trackIdxInRpp (or 0 = unmapped)
local multiNormMap = {}          -- multiNormMap[mixIdx] = {profile, targetPeak}
local multiRppSettings = {
    enabled = false,              -- Toggle between single/multi RPP mode (was multiRppMode)
    gapInMeasures = 2,            -- Gap between RPPs in measures (default: 2)
    createRegions = true,         -- Create region per RPP
    importMarkers = true,         -- Import markers from all RPPs
    alignLanes = true,            -- Move items to highest lane for visibility across RPPs
}

-- Caches (grouped to reduce local count)
local nameCache = setmetatable({}, {__mode="k"})
local trackCache = {
    kids = setmetatable({}, {__mode="k"}),   -- was hasKids
    color = setmetatable({}, {__mode="k"}),  -- was effColorCache
}

_G.__mr_offset = 0.0
_G.__mixTargets = mixTargets
_G.__map = map
_G.__recSources = recSources
_G.__protectedSet = protectedSet
_G.__keepSet = keepSet
_G.__keepMap = keepMap
_G.__tracks = tracks
_G.__normMapDirect = normMapDirect
_G.__protectedSet = protectedSet
_G.__keepSet = keepSet

-- ===== EARLY UTILITY FUNCTIONS (needed before saveLastMap) =====
local function validTrack(t) return t and r.ValidatePtr(t, "MediaTrack*") end

local function trackHasItems(tr)
    return validTrack(tr) and r.CountTrackMediaItems(tr) > 0
end

local function trName(tr)
    if not validTrack(tr) then return "" end
    local _, n = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    return n or ""
end

local function calculateLUFS(targetPeak, offset)
    return targetPeak - offset
end

_G.__keepMap = keepMap

-- Forward declarations for functions used before definition
local normalizeTrack
local normalizeTrackDirect
local scanRegions
local getProfileByName

-- ===== HELPER FUNCTIONS =====
local function showError(msg)
    r.ShowMessageBox(msg, "RAPID Error", 0)
end

local function log(msg)
    if settings.enableConsoleLogging then
        r.ShowConsoleMsg(msg)
    end
end

local function trim(str)
    return (str or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Generic helpers for ExtState string sets
local function saveStringSet(key, set)
    local names = {}
    for k, v in pairs(set or {}) do
        if v then names[#names + 1] = k end
    end
    table.sort(names)
    r.SetExtState(EXT_SECTION, key, table.concat(names, ","), true)
end

local function loadStringSet(key)
    local raw = r.GetExtState(EXT_SECTION, key) or ""
    local set = {}
    for name in raw:gmatch("[^,]+") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if #name > 0 then set[name] = true end
    end
    return set
end

-- ===== IMPORT MARKERS/REGIONS/TEMPO =====
-- ===== SESSION DATA (ExtState) =====
local function saveProtected()
    saveStringSet("protected", protectedSet)
end

local function loadProtected()
    return loadStringSet("protected")
end

local function saveKeep()
    saveStringSet("keep_names", keepSet)
end

local function loadKeep()
    return loadStringSet("keep_names")
end

local function saveLastMap()
    local out = {}
    local function recNameByIndex(idx)
        return (idx > 0 and recSources[idx] and recSources[idx].name) or nil
    end
    
    for i, tr in ipairs(mixTargets or {}) do
        if validTrack(tr) then
            local _, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            name = trim(name)
            if name ~= "" then
                local names = {}
                for _, ri in ipairs(map[i] or {}) do
                    local nm = recNameByIndex(ri or 0)
                    if nm and nm ~= "" then names[#names + 1] = nm end
                end
                if #names > 0 then
                    out[#out + 1] = name .. "=>" .. table.concat(names, "||")
                end
            end
        end
    end
    
    r.SetExtState(EXT_SECTION, EXT_LASTMAP, table.concat(out, "\n"), true)
end

local function loadLastMapData()
    local raw = r.GetExtState(EXT_SECTION, EXT_LASTMAP) or ""
    local t = {}
    for ln in (raw .. "\n"):gmatch("([^\n]*)\n") do
        local mix, list = ln:match("^%s*(.-)%s*=>%s*(.-)%s*$")
        if mix and mix ~= "" and list and list ~= "" then
            local arr = {}
            for part in (list .. "||"):gmatch("(.-)%|%|") do
                part = trim(part)
                if part ~= "" then arr[#arr + 1] = part end
            end
            if #arr > 0 then t[mix] = arr end
        end
    end
    return t
end

-- ===== IMPORT MARKERS/REGIONS/TEMPO (POST-COMMIT) =====
-- Single-RPP: Import tempo, markers and regions from source RPP via API (no file-write or reload)
local function importMarkersTempoPostCommit()
    if not recPath.rpp or recPath.rpp == "" then
        log("No recording RPP loaded, skipping marker import\n")
        return
    end

    log("\n=== Importing Markers/Regions/Tempo ===\n")
    r.Undo_BeginBlock()

    -- Read source RPP
    local f = io.open(recPath.rpp, "rb")
    if not f then
        log("Cannot read source RPP\n")
        return
    end
    local src_txt = f:read("*a"):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    f:close()

    -- 1. Extract & apply tempo
    local tempoMap, baseTempo = extractTempoMap(src_txt)

    -- Set base tempo
    r.SetCurrentBPM(0, baseTempo.bpm, true)

    -- Delete existing tempo markers
    for i = r.CountTempoTimeSigMarkers(0) - 1, 0, -1 do
        r.DeleteTempoTimeSigMarker(0, i)
    end

    -- Set tempo markers via API (for correct positioning)
    for _, pt in ipairs(tempoMap) do
        r.SetTempoTimeSigMarker(0, -1, -1, -1, pt.pos,
            pt.bpm, pt.num or 0, pt.denom or 0, pt.shape == 0)  -- shape 0 = gradual (linear=true), shape 1 = square (linear=false)
    end

    -- Apply source RPP's envelope chunk directly (copies TEMPOENVEX verbatim for single-RPP)
    if #tempoMap > 1 then
        local envexStart = src_txt:find("<TEMPOENVEX\n")
        if envexStart then
            local envexEnd = src_txt:find("\n>", envexStart)
            if envexEnd then
                local envexChunk = src_txt:sub(envexStart, envexEnd + 1)
                local masterTrack = r.GetMasterTrack(0)
                local tempoEnv = masterTrack and r.GetTrackEnvelopeByName(masterTrack, "Tempo map")
                if tempoEnv then
                    local ok = r.SetEnvelopeStateChunk(tempoEnv, envexChunk, true)
                    if ok then
                        log("  Tempo envelope applied via chunk\n")
                    else
                        log("  WARNING: SetEnvelopeStateChunk failed, using API tempo only\n")
                    end
                end
            end
        end
    end

    -- 2. Import markers/regions via API
    local markers = extractMarkersFromRpp(src_txt)
    local markerCount, regionCount = 0, 0
    for _, m in ipairs(markers) do
        if m.isRegion then
            r.AddProjectMarker2(0, true, m.pos, m.rgnend, m.name, -1, m.color)
            regionCount = regionCount + 1
        else
            r.AddProjectMarker2(0, false, m.pos, 0, m.name, -1, m.color)
            markerCount = markerCount + 1
        end
    end

    r.UpdateTimeline()
    r.Undo_EndBlock("RAPID: Import Markers/Tempomap", -1)
    log(string.format("Markers/Regions/Tempo imported! (%d markers, %d regions, %d tempo points)\n",
        markerCount, regionCount, #tempoMap))
end

-- ===== AUTO-RESUME NORMALIZATION AFTER RELOAD =====
-- ===== .INI FILE HANDLING =====
-- ===== .ini Migration & Saving/Loading =====
local function saveSharedNormalizationSettings()
    local iniPath = getConfigIniPath()
    local f = io.open(iniPath, "w")
    if not f then
        showError("Cannot write shared .ini file: " .. iniPath)
        return
    end
    
    -- [Profiles]
    -- Format: Name,Offset,DefaultPeak[,SegmentSize,Percentile,Threshold]
    -- Last 3 fields are optional (only written if profile has custom LUFS settings)
    f:write("[Profiles]\n")
    f:write("Count=" .. #normProfiles .. "\n")
    for i, p in ipairs(normProfiles) do
        if p.lufsSegmentSize then
            -- Profile has custom LUFS settings
            f:write(string.format("Profile%d=%s,%d,%d,%.1f,%d,%.1f\n",
                i, p.name, p.offset, p.defaultPeak,
                p.lufsSegmentSize, p.lufsPercentile, p.lufsThreshold))
        else
            -- Profile uses defaults
            f:write(string.format("Profile%d=%s,%d,%d\n", i, p.name, p.offset, p.defaultPeak))
        end
    end
    f:write("\n")

    -- [ProfileAliases]
    f:write("[ProfileAliases]\n")
    f:write("Count=" .. #profileAliases .. "\n")
    for i, a in ipairs(profileAliases) do
        f:write(string.format("ProfileAlias%d=%s,%s\n", i, a.src, a.dst))
    end
    f:write("\n")

    -- Note: [LufsSettings] section is no longer written (settings are now per-profile)

    f:close()
end

local function saveIni()
    -- Save shared normalization settings
    saveSharedNormalizationSettings()
    
    -- Save RAPID-specific settings
    local iniPath = getIniPath()
    local f = io.open(iniPath, "w")
    if not f then
        showError("Cannot write .ini file: " .. iniPath)
        return
    end
    
    -- [BusKeywords]
    f:write("[BusKeywords]\n")
    f:write("Keywords=" .. table.concat(busKeywords, ",") .. "\n")
    f:write("\n")
    
    -- [Aliases]
    f:write("[Aliases]\n")
    f:write("Count=" .. #aliases .. "\n")
    for i, a in ipairs(aliases) do
        f:write(string.format("Alias%d=%s,%s\n", i, a.src, a.dst))
    end
    f:write("\n")
    
    -- [Defaults]
    f:write("[Defaults]\n")
    f:write("ImportMode=" .. tostring(settings.importMode) .. "\n")
    f:write("NormalizeMode=" .. tostring(settings.normalizeMode) .. "\n")
    f:write("ProcessPerRegion=" .. tostring(settings.processPerRegion) .. "\n")
    f:write("CreateNewLane=" .. tostring(settings.createNewLane) .. "\n")
    f:write("DeleteBetweenRegions=" .. tostring(settings.deleteBetweenRegions) .. "\n")
    f:write("EnableConsoleLogging=" .. tostring(settings.enableConsoleLogging) .. "\n")
    f:write("AutoMatchTracksOnImport=" .. tostring(settings.autoMatchTracksOnImport) .. "\n")
    f:write("AutoMatchProfilesOnImport=" .. tostring(settings.autoMatchProfilesOnImport) .. "\n")
    f:write("DeleteUnused=" .. tostring(settings.deleteUnused) .. "\n")
    f:write("\n")

    -- [MultiRpp]
    f:write("[MultiRpp]\n")
    f:write("GapInMeasures=" .. tostring(multiRppSettings.gapInMeasures) .. "\n")
    f:write("CreateRegions=" .. tostring(multiRppSettings.createRegions) .. "\n")
    f:write("ImportMarkers=" .. tostring(multiRppSettings.importMarkers) .. "\n")
    f:write("AlignLanes=" .. tostring(multiRppSettings.alignLanes) .. "\n")

    f:close()
end

local function loadSharedNormalizationSettings()
    local iniPath = getConfigIniPath()
    local f = io.open(iniPath, "r")
    if not f then
        return false
    end
    
    local content = f:read("*a")
    f:close()
    
    -- Parse [Profiles]
    -- Format: Name,Offset,DefaultPeak[,SegmentSize,Percentile,Threshold]
    normProfiles = {}
    local profileCount = tonumber(content:match("%[Profiles%].-Count=(%d+)")) or 0
    for i = 1, profileCount do
        local line = content:match("Profile" .. i .. "=([^\n]+)")
        if line then
            -- Try extended format first: Name,Offset,Peak,SegSize,Pct,Threshold
            local name, offset, peak, segSize, pct, thresh = line:match("^(.-),(-?%d+),(-?%d+),([%d%.]+),(%d+),([-%d%.]+)$")
            if name and offset and peak and segSize then
                normProfiles[#normProfiles + 1] = {
                    name = name,
                    offset = tonumber(offset),
                    defaultPeak = tonumber(peak),
                    lufsSegmentSize = tonumber(segSize),
                    lufsPercentile = tonumber(pct),
                    lufsThreshold = tonumber(thresh)
                }
            else
                -- Fall back to basic format: Name,Offset,Peak
                name, offset, peak = line:match("^(.-),(-?%d+),(-?%d+)$")
                if name and offset and peak then
                    normProfiles[#normProfiles + 1] = {
                        name = name,
                        offset = tonumber(offset),
                        defaultPeak = tonumber(peak)
                    }
                end
            end
        end
    end
    
    -- Ensure Peak and RMS profiles exist
    local hasPeak = false
    local hasRMS = false
    for _, p in ipairs(normProfiles) do
        if p.name == "Peak" then hasPeak = true end
        if p.name == "RMS" then hasRMS = true end
    end
    
    if not hasPeak then
        table.insert(normProfiles, 1, {name = "Peak", offset = 0, defaultPeak = -6})
    end
    if not hasRMS then
        local insertPos = hasPeak and 2 or 1
        table.insert(normProfiles, insertPos, {name = "RMS", offset = 0, defaultPeak = -12})
    end
    
    -- Parse [ProfileAliases]
    profileAliases = {}
    local profileAliasCount = tonumber(content:match("%[ProfileAliases%].-Count=(%d+)")) or 0
    for i = 1, profileAliasCount do
        local line = content:match("ProfileAlias" .. i .. "=([^\n]+)")
        if line then
            local lastCommaPos = nil
            for pos = 1, #line do
                if line:sub(pos, pos) == "," then
                    lastCommaPos = pos
                end
            end
            
            if lastCommaPos then
                local src = line:sub(1, lastCommaPos - 1)
                local dst = line:sub(lastCommaPos + 1)
                profileAliases[#profileAliases + 1] = {src = src, dst = dst}
            end
        end
    end
    
    -- Note: [LufsSettings] section is ignored (backwards compatibility)
    -- LUFS settings are now stored per-profile

    return true
end

local function loadIni()
    -- Load shared normalization settings
    if not loadSharedNormalizationSettings() then
        -- Use defaults if not found
        normProfiles = {}
        for _, p in ipairs(DEFAULT_PROFILES) do
            normProfiles[#normProfiles + 1] = {
                name = p.name,
                offset = p.offset,
                defaultPeak = p.defaultPeak
            }
        end
        profileAliases = {}
        for _, a in ipairs(DEFAULT_PROFILE_ALIASES) do
            profileAliases[#profileAliases + 1] = {src = a.src, dst = a.dst}
        end
    else
        log("[RAPID] Loaded shared normalization settings from RAPIDJoe_Normalization.ini\n")
    end
    
    -- Load RAPID-specific settings
    local iniPath = getIniPath()
    local f = io.open(iniPath, "r")
    if not f then
        -- Use defaults
        busKeywords = {}
        for _, k in ipairs(DEFAULT_BUS_KEYWORDS) do
            busKeywords[#busKeywords + 1] = k
        end
        aliases = {}
        for _, a in ipairs(DEFAULT_ALIASES) do
            aliases[#aliases + 1] = {src = a.src, dst = a.dst}
        end
        -- Sync global mode variables from settings defaults
        importMode = settings.importMode
        normalizeMode = settings.normalizeMode
        return
    end
    
    local content = f:read("*a")
    f:close()
    
    -- Parse [BusKeywords]
    busKeywords = {}
    local kwLine = content:match("%[BusKeywords%].-Keywords=([^\n]+)")
    if kwLine then
        for kw in kwLine:gmatch("[^,]+") do
            local trimmed = kw:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                busKeywords[#busKeywords + 1] = trimmed
            end
        end
    end
    
    -- Parse [Aliases]
    aliases = {}
    local aliasCount = tonumber(content:match("%[Aliases%].-Count=(%d+)")) or 0
    for i = 1, aliasCount do
        local line = content:match("Alias" .. i .. "=([^\n]+)")
        if line then
            local lastCommaPos = nil
            for pos = 1, #line do
                if line:sub(pos, pos) == "," then
                    lastCommaPos = pos
                end
            end
            
            if lastCommaPos then
                local src = line:sub(1, lastCommaPos - 1)
                local dst = line:sub(lastCommaPos + 1)
                aliases[#aliases + 1] = {src = src, dst = dst}
            end
        end
    end
    
    -- Parse [Defaults]
    local function parseBool(key, default)
        local val = content:match("%[Defaults%].-" .. key .. "=(%w+)")
        if val then return val == "true" end
        return default
    end
    
    local function parseInt(key, default)
        local val = content:match("%[Defaults%].-" .. key .. "=(%d+)")
        if val then return tonumber(val) end
        return default
    end
    
    settings.importMode = parseBool("ImportMode", true)
    settings.normalizeMode = parseBool("NormalizeMode", true)
    settings.processPerRegion = parseBool("ProcessPerRegion", true)
    settings.createNewLane = parseBool("CreateNewLane", true)
    settings.deleteBetweenRegions = parseBool("DeleteBetweenRegions", true)
    settings.enableConsoleLogging = parseBool("EnableConsoleLogging", false)
    settings.autoMatchTracksOnImport = parseBool("AutoMatchTracksOnImport", true)
    settings.autoMatchProfilesOnImport = parseBool("AutoMatchProfilesOnImport", true)
    settings.deleteUnused = parseBool("DeleteUnused", false)

    -- Parse [MultiRpp]
    local function parseMultiRppBool(key, default)
        local val = content:match("%[MultiRpp%].-" .. key .. "=(%w+)")
        if val then return val == "true" end
        return default
    end

    local function parseMultiRppInt(key, default)
        local val = content:match("%[MultiRpp%].-" .. key .. "=(%d+)")
        if val then return tonumber(val) end
        return default
    end

    multiRppSettings.gapInMeasures = parseMultiRppInt("GapInMeasures", 2)
    multiRppSettings.createRegions = parseMultiRppBool("CreateRegions", true)
    multiRppSettings.importMarkers = parseMultiRppBool("ImportMarkers", true)
    multiRppSettings.alignLanes = parseMultiRppBool("AlignLanes", true)

    -- Sync global mode variables
    importMode = settings.importMode
    normalizeMode = settings.normalizeMode
end

local function exportIni()
    if not HAVE_JS then
        showError("JS_ReaScriptAPI required for file export. Install via ReaPack.")
        return
    end
    
    local retval, path = r.JS_Dialog_BrowseForSaveFile(
        "Export Settings", 
        "", 
        "MixRecMapper_Settings.ini", 
        "INI files (*.ini)\0*.ini\0All files (*.*)\0*.*\0"
    )
    
    if retval == 0 then return end  -- User cancelled
    
    -- Stelle sicher, dass .ini Extension vorhanden ist
    if not path:match("%.ini$") then
        path = path .. ".ini"
    end
    
    saveIni()  -- Save current settings first
    
    local srcPath = getIniPath()
    local srcFile = io.open(srcPath, "rb")
    if not srcFile then
        showError("Cannot read source .ini")
        return
    end
    
    local content = srcFile:read("*a")
    srcFile:close()
    
    local dstFile = io.open(path, "wb")
    if not dstFile then
        showError("Cannot write to " .. path)
        return
    end
    
    dstFile:write(content)
    dstFile:close()
    
    r.ShowMessageBox("Settings exported to:\n" .. path, "Export Success", 0)
end

local function importIni()
    if not HAVE_JS then
        showError("JS_ReaScriptAPI required for file import. Install via ReaPack.")
        return
    end
    
    local retval, payload = r.JS_Dialog_BrowseForOpenFiles(
        "Import Settings", 
        "", 
        "", 
        "INI files (*.ini)\0*.ini\0All files (*.*)\0*.*\0",
        false  -- Single file only
    )
    
    if retval == 0 then return end  -- User cancelled
    
    -- Parse the returned path inline (JS_Dialog returns special format)
    local path = nil
    
    if payload:find("%z") then
        -- Null-separated format
        path = payload:match("([^%z]+)")
    elseif payload:match('^"%s*.-"%s*,') then
        -- Quoted format with base path
        local base = payload:match('^"%s*(.-)%s*"%s*,')
        local file = payload:match(',"(.-)"')
        if base and file then
            path = base .. "/" .. file
        end
    else
        -- Simple path
        path = payload:gsub('^"', ""):gsub('"$', ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    if not path or path == "" then
        showError("Invalid file path")
        return
    end
    
    local srcFile = io.open(path, "rb")
    if not srcFile then
        showError("Cannot read " .. path)
        return
    end
    
    local content = srcFile:read("*a")
    srcFile:close()
    
    local dstPath = getIniPath()
    local dstFile = io.open(dstPath, "wb")
    if not dstFile then
        showError("Cannot write to " .. dstPath)
        return
    end
    
    dstFile:write(content)
    dstFile:close()
    
    loadIni()  -- Reload from new file
    
    r.ShowMessageBox("Settings imported from:\n" .. path, "Import Success", 0)
end

-- ===== PATH HANDLING =====
local function isWindows()
    return package.config:sub(1,1) == "\\"
end

local function normalizePath(p)
    if not p or p == "" then return "" end
    p = p:gsub("\\", "/"):gsub("//+", "/")
    p = p:gsub("/$", "")
    return p
end

local function isAbsolutePath(p)
    if not p or p == "" then return false end
    p = normalizePath(p)
    if isWindows() then
        if p:match("^%a:/") then return true end
        if p:match("^//") then return true end
        return false
    end
    return p:sub(1,1) == "/"
end

local function joinPath(a, b)
    if not a or a == "" then return normalizePath(b or "") end
    if not b or b == "" then return normalizePath(a) end
    a = normalizePath(a)
    b = normalizePath(b)
    return a .. "/" .. b
end

local function getBasename(p)
    p = normalizePath(p)
    return p:match("([^/]+)$") or p
end

local function getDirname(p)
    p = normalizePath(p)
    return p:match("^(.*)/") or ""
end

local function fileExists(p)
    if not p or p == "" then return false end
    local f = io.open(p, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function ensureDir(d)
    if not d or d == "" then return end
    r.RecursiveCreateDirectory(d, 0)
end

-- ===== PROJECT PATHS =====
local function getProjectDir()
    local path = r.GetProjectPath("")
    return normalizePath(path or "")
end

local function getProjectMediaDir()
    local proj_dir = getProjectDir()
    if proj_dir == "" then return "" end
    
    local ok, sub = r.GetSetProjectInfo_String(0, "RECORD_PATH", "", false)
    sub = (ok and sub) or ""
    sub = normalizePath(sub)
    
    local media_dir = proj_dir
    
    if sub ~= "" then
        if isAbsolutePath(sub) then
            media_dir = sub
        else
            local proj_lower = proj_dir:lower()
            local sub_lower = sub:lower()
            
            if not proj_lower:match("/" .. sub_lower .. "$") then
                media_dir = joinPath(proj_dir, sub)
            end
        end
    end
    
    ensureDir(media_dir)
    return media_dir
end

-- ===== FILE OPERATIONS =====
local function copyFile(src, dst)
    if not src or not dst then return false end
    if normalizePath(src) == normalizePath(dst) then return true end
    
    local f = io.open(src, "rb")
    if not f then return false end
    
    local data = f:read("*all")
    f:close()
    
    local dst_dir = getDirname(dst)
    if dst_dir ~= "" then
        ensureDir(dst_dir)
    end
    
    local o = io.open(dst, "wb")
    if not o then return false end
    
    o:write(data)
    o:close()
    
    return true
end

-- ===== RESOLVE MEDIA PATHS =====
local function resolveMediaPath(mediaPath, rppDir)
    if not mediaPath or mediaPath == "" then return nil end
    
    mediaPath = normalizePath(mediaPath)
    
    if isAbsolutePath(mediaPath) then
        if fileExists(mediaPath) then
            return mediaPath
        end
        return nil
    end
    
    if rppDir and rppDir ~= "" then
        local candidate = joinPath(rppDir, mediaPath)
        if fileExists(candidate) then
            return candidate
        end
    end
    
    local proj_dir = getProjectDir()
    if proj_dir ~= "" then
        local candidate = joinPath(proj_dir, mediaPath)
        if fileExists(candidate) then
            return candidate
        end
    end
    
    return nil
end

local function copyMediaToProject(sourcePath)
    if not sourcePath or sourcePath == "" then return sourcePath end
    if not fileExists(sourcePath) then return sourcePath end
    
    local media_dir = getProjectMediaDir()
    local basename = getBasename(sourcePath)
    local destPath = joinPath(media_dir, basename)
    
    if normalizePath(sourcePath) == normalizePath(destPath) then
        return destPath
    end
    
    if copyFile(sourcePath, destPath) then
        return destPath
    end
    
    return sourcePath
end

-- ===== TRACK HELPERS =====
-- validTrack and trName are defined earlier (before saveLastMap)

local function setTrName(tr, n)
    if validTrack(tr) then
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", n or "", true)
    end
end

local function idxOf(tr)
    return validTrack(tr) and (r.CSurf_TrackToID(tr, false) - 1) or -1
end

local function folderDepth(tr)
    return validTrack(tr) and (r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") or 0) or 0
end

local function isFolderHeader(tr)
    return folderDepth(tr) == 1
end

local function isHidden(tr)
    if not validTrack(tr) then return false end
    local a = r.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") or 1
    local b = r.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER") or 1
    return (a == 0) and (b == 0)
end

local function trimLower(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function nameContainsAny(name, words)
    local s = (name or ""):lower()
    for _, w in ipairs(words or {}) do
        local k = (w or ""):lower()
        if k ~= "" and s:find(k, 1, true) then
            return true
        end
    end
    return false
end

-- ===== COLOR HANDLING =====
local function u32_from_rgb24(rgb)
    if not rgb or rgb == 0 then return 0xFF808080 end
    -- REAPER gives us: 0xRRGGBB
    -- ImGui wants: 0xRRGGBBAA (RGBA format)
    return (rgb << 8) | 0xFF
end

local function icc_raw(tr)
    return validTrack(tr) and math.floor((r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") or 0) + 0.5) or 0
end

local function effective_rgb24(tr)
    if not validTrack(tr) then return 0 end
    
    -- First: Check track's own color
    local raw = math.floor((r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") or 0) + 0.5)
    
    -- REAPER stores colors as 0x01RRGGBB (bit 24 = custom color flag)
    if (raw & 0x01000000) ~= 0 then
        local rgb = raw & 0xFFFFFF
        if rgb ~= 0 then return rgb end
    end
    
    -- Second: Walk up parent chain
    local safety = 0
    local cur = r.GetParentTrack and r.GetParentTrack(tr) or nil
    while validTrack(cur) and safety < 128 do
        raw = math.floor((r.GetMediaTrackInfo_Value(cur, "I_CUSTOMCOLOR") or 0) + 0.5)
        if (raw & 0x01000000) ~= 0 then
            local rgb = raw & 0xFFFFFF
            if rgb ~= 0 then return rgb end
        end
        cur = r.GetParentTrack and r.GetParentTrack(cur) or nil
        safety = safety + 1
    end
    
    -- Third: Check chunk as fallback
    local ok, chunk = r.GetTrackStateChunk(tr, "", false)
    if ok and chunk then
        local color = chunk:match("\nI_CUSTOMCOLOR%s+(%d+)")
        if color then
            raw = tonumber(color) or 0
            if (raw & 0x01000000) ~= 0 then
                local rgb = raw & 0xFFFFFF
                if rgb ~= 0 then return rgb end
            end
        end
    end
    
    return 0
end

-- ===== WINDOW GEOMETRY =====
local function loadWinGeom()
    local raw = r.GetExtState(EXT_SECTION, EXT_WINGEOM)
    if not raw or raw == "" then return nil end
    local x, y, w, h = raw:match("^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
    if x and y and w and h then
        return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    end
end

local function saveWinGeom(x, y, w, h)
    if x and y and w and h then
        r.SetExtState(EXT_SECTION, EXT_WINGEOM, string.format("%d,%d,%d,%d", x, y, w, h), true)
    end
end

-- ===== NAME NORMALIZATION & SIMILARITY =====
local function normalizeName(s)
    s = (s or ""):lower()
    s = s:gsub("ambience", "room"):gsub("ambi", "room"):gsub("amb", "room")
         :gsub("kik", "kick"):gsub("vox", "voc"):gsub("git", "gtr"):gsub("guit", "gtr")
         :gsub("[_%-%./]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- Remove leading numbers and separators (e.g. "02 kick" -> "kick", "03 snare" -> "snare")
    s = s:gsub("^%d+%s+", "")
    return s
end

local function baseSimilarity(a, b)
    a, b = normalizeName(a), normalizeName(b)
    if a == "" or b == "" then return 0 end
    if a == b then return 1 end
    if (a:find("bass") and b:find("brass")) or (a:find("brass") and b:find("bass")) then
        return 0.05
    end
    if math.abs(#a - #b) > 10 then return 0.1 end
    
    local la, lb = #a, #b
    local dp = {}
    for i = 0, la do
        dp[i] = {}
        for j = 0, lb do dp[i][j] = 0 end
    end
    
    for i = 1, la do
        for j = 1, lb do
            if a:sub(i, i) == b:sub(j, j) then
                dp[i][j] = dp[i - 1][j - 1] + 1
            else
                dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
            end
        end
    end
    
    local lcs = dp[la][lb]
    return (2 * lcs) / (la + lb)
end


local function findAliasTarget(recName)
    local rn = trimLower(recName or "")
    if rn:find("%.") then
        rn = rn:gsub("%.(%w+)$", " %1"):gsub("^%s+", "")
    end
    
    for _, it in ipairs(aliases or {}) do
        -- Split src by comma to support multiple keywords per alias
        local srcList = it.src or ""
        for srcPart in (srcList .. ","):gmatch("([^,]+),") do
            local key = trimLower(srcPart)
            if key ~= "" and (rn == key or rn:find(" " .. key .. " ") or rn:find("^" .. key) or rn:find(key .. "$")) then
                return trimLower(it.dst or "")
            end
        end
    end
    
    return nil
end

-- ===== RPP HANDLING =====
local chunkCache = setmetatable({}, {__mode = "kv"})

local function readAll(p)
    if chunkCache[p] then return chunkCache[p] end
    local f = io.open(p, "rb")
    if not f then
        showError("Cannot open file: " .. p)
        return nil
    end
    local s = f:read("*a")
    f:close()
    local txt = (s:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
    chunkCache[p] = txt
    return txt
end

local function lines(txt)
    local t = {}
    for L in (txt .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = L end
    return t
end

local function extractTrackChunks(txt)
    local out, L = {}, lines(txt)
    local i = 1
    while i <= #L do
        if L[i]:match("^%s*<%s*TRACK") then
            local s = i
            local depth = 0
            while i <= #L do
                local l = L[i]
                if l:match("^%s*<") then depth = depth + 1 end
                if l:match("^%s*>%s*$") then
                    depth = depth - 1
                    if depth == 0 then
                        local buf = {}
                        for k = s, i do buf[#buf + 1] = L[k] end
                        out[#out + 1] = table.concat(buf, "\n") .. "\n"
                        break
                    end
                end
                i = i + 1
            end
        end
        i = i + 1
    end
    return out
end

-- ===== EXTRACT POOLEDENV SECTIONS =====
local function extractPooledEnvs(txt)
    local out = {}
    local L = lines(txt)
    local i = 1
    
    while i <= #L do
        if L[i]:match("^%s*<%s*POOLEDENV") then
            local s = i
            local depth = 0
            while i <= #L do
                local l = L[i]
                if l:match("^%s*<") then depth = depth + 1 end
                if l:match("^%s*>%s*$") then
                    depth = depth - 1
                    if depth == 0 then
                        local buf = {}
                        for k = s, i do buf[#buf + 1] = L[k] end
                        local pooledEnvChunk = table.concat(buf, "\n") .. "\n"
                        
                        -- Extract pool ID
                        local poolID = pooledEnvChunk:match("\n%s*ID%s+(%d+)")
                        if poolID then
                            out[tonumber(poolID)] = pooledEnvChunk
                        end
                        break
                    end
                end
                i = i + 1
            end
        end
        i = i + 1
    end
    
    return out
end

-- ===== GET POOL IDS USED IN CHUNK =====
local function getPoolIDsFromChunk(chunk)
    local poolIDs = {}
    
    -- Find all POOLEDENVINST lines (format: POOLEDENVINST <poolID> ...)
    for poolID in chunk:gmatch("POOLEDENVINST%s+(%d+)") do
        poolIDs[tonumber(poolID)] = true
    end
    
    return poolIDs
end

-- ===== INJECT POOLEDENV INTO PROJECT =====
local function injectPooledEnvsIntoProject(pooledEnvChunks)
    if not pooledEnvChunks or #pooledEnvChunks == 0 then return end
    
    -- Get current project path WITHOUT forcing save
    local _, projPath = r.EnumProjects(-1, "")
    if not projPath or projPath == "" then
        log("WARNING: Project not saved - automation items may not work correctly!\n")
        log("Please save your project and try again.\n")
        return
    end
    
    -- Read current project WITHOUT saving first
    local f = io.open(projPath, "rb")
    if not f then
        log("Cannot read project file\n")
        return
    end
    local projTxt = f:read("*a"):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    f:close()
    
    -- Find highest existing pool ID in project
    local maxPoolID = 0
    for poolID in projTxt:gmatch("<POOLEDENV\n%s*ID%s+(%d+)") do
        local id = tonumber(poolID)
        if id and id > maxPoolID then
            maxPoolID = id
        end
    end
    
    log(string.format("Max existing pool ID: %d\n", maxPoolID))
    
    -- Renumber all pool IDs to avoid conflicts
    local poolIDMap = {}  -- old ID -> new ID
    local newPooledEnvChunks = {}
    
    for _, poolChunk in ipairs(pooledEnvChunks) do
        local oldID = poolChunk:match("\n%s*ID%s+(%d+)")
        if oldID then
            oldID = tonumber(oldID)
            if not poolIDMap[oldID] then
                maxPoolID = maxPoolID + 1
                poolIDMap[oldID] = maxPoolID
            end
            
            -- Replace ID in pool chunk
            local newID = poolIDMap[oldID]
            local newPoolChunk = poolChunk:gsub("(\n%s*ID%s+)%d+", "%1" .. newID)
            newPooledEnvChunks[#newPooledEnvChunks + 1] = newPoolChunk
            
            log(string.format("  Renumbered pool: %d -> %d\n", oldID, newID))
        end
    end
    
    -- Find insertion point: right before <MASTERPLAYSPEEDENV or <TEMPOENVEX or <PROJBAY
    local insertPos = projTxt:find("\n%s*<MASTERPLAYSPEEDENV") or 
                      projTxt:find("\n%s*<TEMPOENVEX") or 
                      projTxt:find("\n%s*<PROJBAY")
    
    if not insertPos then
        log("Cannot find insertion point for POOLEDENV\n")
        return
    end
    
    -- Build pooled env text
    local pooledEnvText = ""
    for _, poolChunk in ipairs(newPooledEnvChunks) do
        pooledEnvText = pooledEnvText .. "  " .. poolChunk
    end
    
    -- Insert POOLEDENV sections
    local newProjTxt = projTxt:sub(1, insertPos - 1) .. "\n" .. pooledEnvText .. projTxt:sub(insertPos)
    
    -- Write modified project
    f = io.open(projPath, "wb")
    if not f then
        log("Cannot write project file\n")
        return
    end
    f:write(newProjTxt)
    f:close()
    
    log("Injected " .. #newPooledEnvChunks .. " POOLEDENV section(s)\n")
    
    -- Return the ID mapping so we can update POOLEDENVINST references in tracks
    return poolIDMap
end

local function parseTopLevelName(chunk)
    local L = lines(chunk)
    local s = 1
    while s <= #L and not L[s]:match("^%s*<%s*TRACK") do s = s + 1 end
    if s > #L then return "(unnamed)" end
    for i = s + 1, #L do
        local ln = L[i]
        if ln:match("^%s*<") then break end
        local q = ln:match('^%s*NAME%s+"(.-)"%s*$')
        if q then return q end
        local u = ln:match('^%s*NAME%s+(.+)%s*$')
        if u then return (u:gsub("^%s+", ""):gsub("%s+$", "")) end
    end
    return "(unnamed)"
end

local function chunkHasMedia(chunk)
    return chunk:find("\n%s*<ITEM", 1) ~= nil
end

-- ===== PARSE SELECTED FILES =====
local function parseSelectedFiles(s)
    local out = {}
    if not s or s == "" then return out end
    
    if s:find("%z") then
        for p in s:gmatch("([^%z]+)") do
            if #p > 0 then out[#out + 1] = p end
        end
        return out
    end
    
    if s:match('^"%s*.-"%s*,') then
        local base = s:match('^"%s*(.-)%s*"%s*,')
        for p in s:gmatch(',"(.-)"') do
            out[#out + 1] = ((base and #base > 0) and (base .. "/" .. p) or p)
        end
        return out
    end
    
    local separator = s:find("\n") and "\n" or ","
    for part in (s .. separator):gmatch("([^" .. separator .. "]+)") do
        part = part:gsub("^%s+", "")
        part = part:gsub("%s+$", "")
        part = part:gsub('^"', "")
        part = part:gsub('"$', "")
        if #part > 0 then
            out[#out + 1] = part
        end
    end
    
    return out
end

-- ===== REBUILD MIX TARGETS =====
local function rebuildMixTargets()
    mixTargets = {}
    protectedSet = protectedSet or {}
    trackCache.kids = setmetatable({}, {__mode = "k"})
    nameCache = setmetatable({}, {__mode = "k"})
    trackCache.color = setmetatable({}, {__mode = "k"})
    
    local N = r.CountTracks(0)
    local busStack, activeBus = {}, false
    local visStack = {}
    
    for i = 0, N - 1 do
        local tr = r.GetTrack(0, i)
        if validTrack(tr) then
            local d = folderDepth(tr)
            if d == 1 then
                local thisIsBus = nameContainsAny(trName(tr), busKeywords)
                busStack[#busStack + 1] = (activeBus or thisIsBus)
                activeBus = busStack[#busStack]
            end
            
            local hidden = isHidden(tr)
            local selfIsBus = nameContainsAny(trName(tr), busKeywords)
            local excluded = activeBus or selfIsBus
            local visible = (not hidden) and (not excluded)
            
            if visible then
                local nm = trName(tr)
                nameCache[tr] = nm
                mixTargets[#mixTargets + 1] = tr
                for _, par in ipairs(visStack) do trackCache.kids[par] = true end
                if d == 1 then visStack[#visStack + 1] = tr end
                trackCache.color[tr] = effective_rgb24(tr)
            end
            
            if d < 0 then
                for _ = 1, math.min(#busStack, -d) do busStack[#busStack] = nil end
                activeBus = (#busStack > 0) and busStack[#busStack] or false
                for _ = 1, math.min(#visStack, -d) do visStack[#visStack] = nil end
            end
        end
    end
    
    for _, tr in ipairs(mixTargets) do
        if validTrack(tr) and (r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") or 0) == 1 then
            local nm = nameCache[tr] or trName(tr)
            if nm and nm ~= "" then protectedSet[nm] = true end
        end
    end
    
    _G.__mixTargets = mixTargets
end

local function isLeafCached(tr)
    if not validTrack(tr) then return true end
    if isFolderHeader(tr) then return false end
    return not (trackCache.kids and trackCache.kids[tr])
end

-- ===== LOCK PARENT FOLDERS =====
local function lockParentFolders(trackIndex)
    if not trackIndex or trackIndex < 1 or trackIndex > #mixTargets then return end
    
    local track = mixTargets[trackIndex]
    if not validTrack(track) then return end
    
    -- Find all parent folders by walking backwards through the track list
    local parents = {}
    local depth = 0
    
    for i = trackIndex - 1, 1, -1 do
        local tr = mixTargets[i]
        if validTrack(tr) then
            local fd = folderDepth(tr)
            
            if fd == 1 then
                -- This is a folder start
                depth = depth - 1
                parents[#parents + 1] = tr
                
                if depth <= 0 then
                    break  -- We've found all parents
                end
            elseif fd < 0 then
                -- This is a folder end
                depth = depth + math.abs(fd)
            end
        end
    end
    
    -- Lock all parent folders
    for _, parent in ipairs(parents) do
        local parentName = nameCache[parent] or trName(parent)
        if parentName and parentName ~= "" then
            protectedSet[parentName] = true
        end
    end
    
    _G.__protectedSet = protectedSet
end

-- ===== LOAD RECORDING RPP =====
local function countRegionsInRPP(rppText)
    local count = 0
    -- MARKER format: MARKER index position "name" isrgn rgnend [color]
    -- isrgn: 0 = marker, 1 = region
    -- Example: MARKER 2 4.0 "Region 1" 1 8.0 0
    for line in rppText:gmatch("[^\r\n]+") do
        if line:match("^%s*MARKER%s+") then
            -- Parse: MARKER idx pos "name" isrgn ...
            -- We need to check if the 4th parameter (after name) is 1
            local idx, pos, rest = line:match("^%s*MARKER%s+(%S+)%s+(%S+)%s+(.+)")
            if rest then
                -- Extract name (quoted string) and following parameters
                local name, after_name = rest:match('^"([^"]*)"(.*)')
                if not name then
                    -- Try unquoted name
                    name, after_name = rest:match("^(%S+)(.*)")
                end
                
                if after_name then
                    -- First parameter after name is isrgn
                    local isrgn = after_name:match("^%s*(%d+)")
                    if isrgn == "1" then
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

local function loadRecRPP(path)
    if not path or path == "" then
        showError("Invalid RPP path")
        return
    end
    
    recPath.rpp = path
    recPath.dir = getDirname(path)
    
    local txt = readAll(path)
    if not txt then return end
    
    -- Count regions in source RPP
    recPath.regionCount = countRegionsInRPP(txt)
    log(string.format("Source RPP has %d regions\n", recPath.regionCount))
    
    -- Extract all POOLEDENV sections from RPP
    local pooledEnvs = extractPooledEnvs(txt)
    
    local chunks = extractTrackChunks(txt)
    
    for _, ch in ipairs(chunks) do
        local nm = parseTopLevelName(ch)
        if nm == "" then nm = "(unnamed)" end
        local has = chunkHasMedia(ch)
        
        if (ONLY_WITH_MEDIA and has) or (not ONLY_WITH_MEDIA) then
            -- Find which pool IDs this track uses
            local usedPoolIDs = getPoolIDsFromChunk(ch)
            
            -- Collect the POOLEDENV chunks this track needs
            local neededPools = {}
            for poolID, _ in pairs(usedPoolIDs) do
                if pooledEnvs[poolID] then
                    neededPools[#neededPools + 1] = pooledEnvs[poolID]
                end
            end
            
            recSources[#recSources + 1] = {
                src = "rpp",
                name = nm,
                chunk = ch,
                hasMedia = has,
                pooledEnvs = neededPools  -- Store the needed POOLEDENV chunks
            }
        end
    end
    
    _G.__recSources = recSources
end

local function loadRecFiles()
    if not HAVE_JS then
        showError("JS_ReaScriptAPI required for multi-file selection. Select files one-by-one.")
        while true do
            local ok, p = r.GetUserFileNameForRead("", "Select audio file (Cancel to stop)", "")
            if not ok or not p or p == "" then break end
            recSources[#recSources + 1] = {
                src = "file",
                name = (p:match("([^/\\]+)$") or p):gsub("%.[%w%d_-]+$", ""),
                file = p
            }
            local cont = r.ShowMessageBox("Add another file?", "Add files", 6)
            if cont ~= 6 then break end
        end
    else
        local ok, payload = r.JS_Dialog_BrowseForOpenFiles("Select audio files", "", "", "Audio files (*.*)\0*.*\0", true)
        if ok then
            local files = parseSelectedFiles(payload)
            for _, full in ipairs(files) do
                recSources[#recSources + 1] = {
                    src = "file",
                    name = (full:match("([^/\\]+)$") or full):gsub("%.[%w%d_-]+$", ""),
                    file = full
                }
            end
        end
    end
    _G.__recSources = recSources
end

local function clearRecList()
    recSources = {}
    recPath.rpp = nil
    recPath.dir = nil
    _G.__recSources = recSources
end

-- ===== MULTI-RPP IMPORT FUNCTIONS (v2.5) =====

-- Extract base tempo from RPP text
local function extractBaseTempo(rppText)
    local bpm, num, denom = rppText:match("TEMPO%s+([%d%.]+)%s+(%d+)%s+(%d+)")
    return {
        bpm = tonumber(bpm) or 120,
        num = tonumber(num) or 4,
        denom = tonumber(denom) or 4
    }
end

-- Extract complete tempo map from RPP (TEMPO line + TEMPOENVEX points)
local function extractTempoMap(rppText)
    local points = {}
    local baseTempo = extractBaseTempo(rppText)

    -- Extract TEMPOENVEX points if present (authoritative source for shape + timesig)
    -- Note: Lua's .- does not match newlines, so we use find/sub for multi-line blocks
    local envexStart = rppText:find("<TEMPOENVEX\n")
    local envex = nil
    if envexStart then
        -- Match closing ">" with optional leading whitespace (RPP indents with 2 spaces per level)
        local envexEnd = rppText:find("\n%s*>", envexStart)
        if envexEnd then
            -- Include the ">" itself: find the actual ">" position after the whitespace
            local closePos = rppText:find(">", envexEnd + 1)
            envex = rppText:sub(envexStart, closePos)
        end
    end
    if envex then
        for line in envex:gmatch("PT%s+([^\n]+)") do
            -- Real format: PT <pos> <bpm> <shape> [<timesig> <selected> <flags> ...]
            -- Without timesig: PT <pos> <bpm> <shape>  (3 fields only)
            local pos, bpm, shape, rest = line:match(
                "([%d%.%-]+)%s+([%d%.]+)%s+(%d+)%s*(.*)"
            )
            if pos and bpm then
                local pt = {
                    pos = tonumber(pos),
                    bpm = tonumber(bpm),
                    shape = tonumber(shape) or 0,
                    num = nil,
                    denom = nil,
                }

                -- Field 4 = optional timesig (encoded as 65536*denom + num)
                if rest and rest ~= "" then
                    local timesig = rest:match("^(%d+)")
                    if timesig then
                        local ts = tonumber(timesig)
                        if ts and ts > 0 then
                            pt.denom = math.floor(ts / 65536)
                            pt.num = ts % 65536
                        end
                    end
                end

                points[#points + 1] = pt
            end
        end
    end

    -- Fallback: if no TEMPOENVEX or no point at pos 0, add baseTempo as first point
    -- (TEMPOENVEX PT 0 is authoritative when present — has correct shape value)
    if #points == 0 or points[1].pos > 0 then
        table.insert(points, 1, {
            pos = 0,
            bpm = baseTempo.bpm,
            num = baseTempo.num,
            denom = baseTempo.denom,
            shape = 1,  -- shape 1 = square/instant (safe default)
        })
    end

    -- Force shape=1 (SQUARE/instant) on the last tempo point of every RPP.
    -- In standalone context, the last point's shape is irrelevant (REAPER ignores it).
    -- But in multi-RPP merge, the last point is no longer last — shape=0 (gradual)
    -- would cause an unwanted ramp to the next RPP's first tempo.
    if #points > 0 then
        points[#points].shape = 1  -- 1 = square/instant (no transition across RPP boundary)
    end

    return points, baseTempo
end

-- Extract markers from RPP text
-- RPP MARKER format: MARKER <idx> <pos> "<name>" <flags> [0 <colortype> <colorflag> {GUID} 0]
-- Regions use TWO MARKER lines: start (with name, flags bit0=1) + end (empty name "", same idx)
-- Region-end lines have shortened format: MARKER <idx> <pos> "" <flags>
local function extractMarkersFromRpp(rppText)
    local allEntries = {}

    for line in rppText:gmatch("[^\r\n]+") do
        if line:match("^%s*MARKER%s+") then
            local idx, pos, rest = line:match("^%s*MARKER%s+(%S+)%s+([%d%.%-]+)%s+(.+)")
            if idx and pos and rest then
                local name, afterName = rest:match('^"([^"]*)"(.*)')
                if not name then
                    name, afterName = rest:match("^(%S+)(.*)")
                end

                local flags, color = 0, 0
                if afterName then
                    local parts = {}
                    for p in afterName:gmatch("%S+") do parts[#parts + 1] = p end
                    flags = tonumber(parts[1]) or 0
                    -- Color info is at parts[3] (after "0 <colortype>") if present
                    -- Full format: flags 0 colortype colorflag {GUID} 0
                    -- For API import we only need the color value from REAPER's native format
                    color = tonumber(parts[3]) or 0
                end

                local isRegion = (flags % 2 == 1)  -- bit 0 = isRegion

                allEntries[#allEntries + 1] = {
                    idx = tonumber(idx),
                    pos = tonumber(pos),
                    name = name or "",
                    isRegion = isRegion,
                    flags = flags,
                    rgnend = 0,
                    color = color
                }
            end
        end
    end

    -- Second pass: pair region-end markers with their start markers
    -- Region-end markers have empty name "" and same idx as their start
    local regionStarts = {}  -- idx -> entry (last seen start for this idx)
    for _, m in ipairs(allEntries) do
        if m.isRegion and m.name ~= "" then
            regionStarts[m.idx] = m
        end
    end

    -- Filter: remove end-markers and set rgnend on matching starts
    local markers = {}
    for _, m in ipairs(allEntries) do
        if m.isRegion and m.name == "" then
            -- This is a region-end marker — set rgnend on matching start
            local startEntry = regionStarts[m.idx]
            if startEntry then
                startEntry.rgnend = m.pos
            end
            -- Don't add to output (skip region-end markers)
        else
            markers[#markers + 1] = m
        end
    end

    return markers
end

-- Calculate RPP length in measures (finds last item end, rounds up to complete measure)
-- Returns: measures (integer, rounded up), totalQN (float, exact beat count)
local function calculateRppLengthInMeasures(rppText, baseTempo, tempoMap)
    local maxEndTime = 0

    -- Scan line-by-line for POSITION/LENGTH pairs inside ITEM blocks
    -- (indented RPP format makes <ITEM.-\n> pattern unreliable)
    local curPos = nil
    for line in rppText:gmatch("[^\n]+") do
        local p = line:match("^%s*POSITION%s+([%d%.]+)")
        if p then curPos = tonumber(p) or 0 end
        local l = line:match("^%s*LENGTH%s+([%d%.]+)")
        if l and curPos then
            local itemEnd = curPos + (tonumber(l) or 0)
            if itemEnd > maxEndTime then maxEndTime = itemEnd end
            curPos = nil
        end
    end

    -- Simple fallback if no tempo map with multiple points
    if not tempoMap or #tempoMap < 2 then
        local qnPerMeasure = (baseTempo.num or 4) * (4 / (baseTempo.denom or 4))
        local bpm = baseTempo.bpm or 120
        local totalBeats = maxEndTime * (bpm / 60)
        return math.ceil(totalBeats / qnPerMeasure), totalBeats, maxEndTime
    end

    -- Build segments from tempo map
    -- PT positions in TEMPOENVEX are in SECONDS (not quarter notes!)
    -- Shape: 0 = gradual/linear ramp, 1 = square/instant (inverted from API's lineartempo)
    local segs = {}
    local curNum, curDenom = baseTempo.num or 4, baseTempo.denom or 4
    for i, pt in ipairs(tempoMap) do
        if pt.num and pt.num > 0 then curNum = pt.num end
        if pt.denom and pt.denom > 0 then curDenom = pt.denom end
        segs[i] = { time = pt.pos, bpm = pt.bpm, shape = pt.shape, num = curNum, denom = curDenom }
    end

    -- Integrate BPM over time to get total QN at maxEndTime
    -- Also track QN breakpoints for measure calculation
    local totalQN = 0
    local qnBreaks = {}  -- {qnStart, num, denom} for each segment
    for i = 1, #segs do
        local s = segs[i]
        qnBreaks[i] = { qnStart = totalQN, num = s.num, denom = s.denom }
        local nextTime = (i < #segs) and segs[i + 1].time or maxEndTime
        if nextTime > maxEndTime then nextTime = maxEndTime end
        local deltaTime = nextTime - s.time
        if deltaTime > 0 then
            -- shape=0 means GRADUAL (linear ramp), shape=1 means SQUARE (constant)
            if s.shape == 0 and i < #segs and s.bpm ~= segs[i + 1].bpm then
                -- Linear ramp: QN = deltaTime * (bpm2 - bpm1) / (60 * ln(bpm2/bpm1))
                local bpm2 = segs[i + 1].bpm
                totalQN = totalQN + deltaTime * (bpm2 - s.bpm) / (60 * math.log(bpm2 / s.bpm))
            else
                -- Constant tempo: QN = deltaTime * bpm / 60
                totalQN = totalQN + deltaTime * s.bpm / 60
            end
        end
        if nextTime >= maxEndTime then break end
    end

    -- Convert totalQN to measures using time signature changes at QN breakpoints
    local totalMeasures = 0
    for i = 1, #qnBreaks do
        local qnStart = qnBreaks[i].qnStart
        local qnEnd = (i < #qnBreaks) and qnBreaks[i + 1].qnStart or totalQN
        local qnInSeg = qnEnd - qnStart
        if qnInSeg > 0 then
            local qnPerMeasure = qnBreaks[i].num * (4 / qnBreaks[i].denom)
            totalMeasures = totalMeasures + qnInSeg / qnPerMeasure
        end
    end

    -- Round up to complete measure; also return totalQN for direct use (avoids lossy measures*qnPerMeasure)
    return math.ceil(totalMeasures), totalQN, maxEndTime
end

-- Load RPP into the multi-RPP queue
local function loadRppToQueue(path)
    if not path or path == "" then return false end

    local txt = readAll(path)
    if not txt then return false end

    local dir = getDirname(path)
    local filename = path:match("([^/\\]+)%.[rR][pP][pP]$") or path:match("([^/\\]+)$") or "Unnamed"

    -- Extract tempo map and base tempo
    local tempoMap, baseTempo = extractTempoMap(txt)

    -- Extract markers
    local markers = extractMarkersFromRpp(txt)

    -- Calculate length in measures, quarter notes, and absolute time
    local lengthInMeasures, lengthInQN, maxEndTime = calculateRppLengthInMeasures(txt, baseTempo, tempoMap)
    if lengthInMeasures < 1 then lengthInMeasures = 1 end

    -- PT positions in TEMPOENVEX are already in seconds — assign directly
    for _, pt in ipairs(tempoMap) do
        pt.time = pt.pos
    end

    log(string.format("  loadRppToQueue '%s': measures=%d, lengthInQN=%.4f, maxEndTime=%.4fs, baseTempo=%.1f bpm %d/%d\n",
        filename, lengthInMeasures, lengthInQN or -1, maxEndTime or 0, baseTempo.bpm, baseTempo.num or 4, baseTempo.denom or 4))

    -- Extract tracks (same as loadRecRPP)
    local regionCount = countRegionsInRPP(txt)
    local pooledEnvs = extractPooledEnvs(txt)
    local chunks = extractTrackChunks(txt)

    local tracks = {}
    for _, ch in ipairs(chunks) do
        local nm = parseTopLevelName(ch)
        if nm == "" then nm = "(unnamed)" end
        local has = chunkHasMedia(ch)

        if (ONLY_WITH_MEDIA and has) or (not ONLY_WITH_MEDIA) then
            local usedPoolIDs = getPoolIDsFromChunk(ch)
            local neededPools = {}
            for poolID, _ in pairs(usedPoolIDs) do
                if pooledEnvs[poolID] then
                    neededPools[#neededPools + 1] = pooledEnvs[poolID]
                end
            end

            tracks[#tracks + 1] = {
                src = "rpp",
                name = nm,
                chunk = ch,
                hasMedia = has,
                pooledEnvs = neededPools
            }
        end
    end

    -- Add to queue
    rppQueue[#rppQueue + 1] = {
        path = path,
        dir = dir,
        name = filename,
        rppText = txt,
        tracks = tracks,
        lengthInMeasures = lengthInMeasures,
        lengthInQN = lengthInQN or (lengthInMeasures * (baseTempo.num or 4) * (4 / (baseTempo.denom or 4))),  -- fallback
        maxEndTime = maxEndTime or 0,  -- RPP duration in seconds (max item end)
        measureOffset = 0,  -- Will be calculated
        qnOffset = 0,       -- Will be calculated (for tempo envelope only)
        timeOffset = 0,     -- Will be calculated (for item/region/marker positioning)
        tempoMap = tempoMap,
        markers = markers,
        baseTempo = baseTempo,
        regionCount = regionCount
    }

    recalculateQueueOffsets()
    return true
end

-- Remove RPP from queue
local function removeRppFromQueue(idx)
    if idx < 1 or idx > #rppQueue then return end
    local oldCount = #rppQueue
    table.remove(rppQueue, idx)
    -- Shift multiMap entries: remove column idx, shift higher indices down
    for i, _ in pairs(multiMap) do
        local row = multiMap[i]
        if row then
            -- Remove the entry for the deleted RPP, shift rest down
            for r = idx, oldCount - 1 do
                row[r] = row[r + 1]
            end
            row[oldCount] = nil
        end
    end
    recalculateQueueOffsets()
end

-- Move RPP in queue (for reordering)
local function moveRppInQueue(fromIdx, toIdx)
    if fromIdx < 1 or fromIdx > #rppQueue then return end
    if toIdx < 1 or toIdx > #rppQueue then return end
    if fromIdx == toIdx then return end

    local n = #rppQueue
    local item = table.remove(rppQueue, fromIdx)
    table.insert(rppQueue, toIdx, item)

    -- Reorder multiMap columns to match the new queue order
    -- Same logic: remove column fromIdx, insert at toIdx
    for i, _ in pairs(multiMap) do
        local row = multiMap[i]
        if row then
            local saved = row[fromIdx]
            if fromIdx < toIdx then
                for r = fromIdx, toIdx - 1 do row[r] = row[r + 1] end
            else
                for r = fromIdx, toIdx + 1, -1 do row[r] = row[r - 1] end
            end
            row[toIdx] = saved
        end
    end

    recalculateQueueOffsets()
end

-- Calculate measure/time/beat offsets for all RPPs in queue
-- Time-based: timeOffset (seconds) is primary for item/region/marker positioning
-- Beat-based: qnOffset is kept for tempo envelope PT positions only
function recalculateQueueOffsets()
    local currentMeasure = 0
    local currentTime = 0
    local currentQN = 0

    for i, rpp in ipairs(rppQueue) do
        rpp.measureOffset = currentMeasure
        rpp.timeOffset = currentTime
        rpp.qnOffset = currentQN

        -- Calculate measure/time constants from base tempo
        local num = rpp.baseTempo.num or 4
        local denom = rpp.baseTempo.denom or 4
        local qnPerMeasure = num * (4 / denom)
        local baseBPM = rpp.baseTempo.bpm or 120
        local secPerMeasure = qnPerMeasure * 60 / baseBPM

        -- Round RPP duration up to next measure boundary (at base tempo)
        local rppMeasuresCeil = math.ceil((rpp.maxEndTime or 0) / secPerMeasure)
        if rppMeasuresCeil < 1 then rppMeasuresCeil = 1 end
        local rppTimeRounded = rppMeasuresCeil * secPerMeasure
        local gapTime = multiRppSettings.gapInMeasures * secPerMeasure

        -- QN offset synchronized with time (both use rounded-up measure count)
        local rppQNRounded = rppMeasuresCeil * qnPerMeasure
        local gapQN = multiRppSettings.gapInMeasures * qnPerMeasure

        log(string.format("  recalcQueueOff RPP %d '%s': measOff=%d timeOff=%.4fs qnOff=%.4f maxEnd=%.4fs lenMeas=%d rounded=%d meas\n",
            i, rpp.name, rpp.measureOffset, rpp.timeOffset, rpp.qnOffset, rpp.maxEndTime or 0, rpp.lengthInMeasures or 0, rppMeasuresCeil))

        -- Use actual lengthInMeasures (accounts for tempo/timesig changes) for measure display
        currentMeasure = currentMeasure + (rpp.lengthInMeasures or rppMeasuresCeil) + multiRppSettings.gapInMeasures
        currentTime = currentTime + rppTimeRounded + gapTime
        currentQN = currentQN + rppQNRounded + gapQN
    end

    -- Rebuild recSources from all queued RPPs with rppIndex metadata
    rebuildRecSourcesFromQueue()
end

-- Rebuild recSources array from queue (for track mapping compatibility)
function rebuildRecSourcesFromQueue()
    if #rppQueue == 0 then return end

    recSources = {}

    for rppIdx, rpp in ipairs(rppQueue) do
        for _, track in ipairs(rpp.tracks) do
            recSources[#recSources + 1] = {
                src = "rpp",
                name = track.name,
                chunk = track.chunk,
                hasMedia = track.hasMedia,
                pooledEnvs = track.pooledEnvs,
                -- Multi-RPP metadata
                rppIndex = rppIdx,
                rppMeasureOffset = rpp.measureOffset,
                rppName = rpp.name
            }
        end
    end

    -- Also set recPath.rpp to first RPP for marker import compatibility
    if rppQueue[1] then
        recPath.rpp = rppQueue[1].path
        recPath.dir = rppQueue[1].dir
    end

    _G.__recSources = recSources
end

-- Build merged tempo section text for project
local function buildMergedTempoSection()
    if #rppQueue == 0 then return nil end

    local lines = {}

    -- First RPP's base tempo becomes project tempo
    local firstTempo = rppQueue[1].baseTempo
    lines[#lines + 1] = string.format("TEMPO %.14g %d %d",
        firstTempo.bpm, firstTempo.num, firstTempo.denom)

    -- NOTE: MARKER lines are NOT written here. They are created via API
    -- (createMultiRppRegions + importMultiRppMarkers) and REAPER writes them
    -- to the .rpp on save. writeMultiRppTempoSection() preserves existing
    -- MARKER lines from the saved .rpp when replacing TEMPO+TEMPOENVEX.

    -- Build TEMPOENVEX with all tempo points from all RPPs
    local allPoints = {}

    for _, rpp in ipairs(rppQueue) do
        local offsetSeconds = rpp.timeOffset  -- PT positions in TEMPOENVEX are in seconds

        for _, pt in ipairs(rpp.tempoMap) do
            local adjPos = pt.pos + offsetSeconds  -- pt.pos is seconds within RPP

            allPoints[#allPoints + 1] = {
                pos = adjPos,
                bpm = pt.bpm,
                shape = pt.shape,
                num = pt.num,
                denom = pt.denom
            }
        end
    end

    -- Sort by position
    table.sort(allPoints, function(a, b) return a.pos < b.pos end)

    -- Build TEMPOENVEX block
    if #allPoints > 1 then  -- Only if there are tempo changes
        lines[#lines + 1] = "<TEMPOENVEX"
        lines[#lines + 1] = "ACT 1 -1"
        lines[#lines + 1] = "VIS 1 0 1"
        lines[#lines + 1] = "LANEHEIGHT 0 0"
        lines[#lines + 1] = "ARM 0"
        lines[#lines + 1] = "DEFSHAPE 0 -1 -1"

        for _, pt in ipairs(allPoints) do
            local ptLine
            if pt.num and pt.denom and pt.num > 0 and pt.denom > 0 then
                local timesig = pt.denom * 65536 + pt.num
                ptLine = string.format("PT %.14g %.14g %d %d",
                    pt.pos, pt.bpm, pt.shape, timesig)
            else
                ptLine = string.format("PT %.14g %.14g %d",
                    pt.pos, pt.bpm, pt.shape)
            end
            lines[#lines + 1] = ptLine
        end

        lines[#lines + 1] = ">"
    end

    return table.concat(lines, "\n")
end

-- Apply full-fidelity tempo via SetEnvelopeStateChunk (no file I/O or reload needed)
-- Reads beat positions from REAPER's API markers (set by setTempoViaAPI using time positions),
-- then builds TEMPOENVEX chunk with correct shape/tension values from rppQueue data.
-- NOTE: This function is retained but NOT called in commitMultiRpp().
-- setTempoViaAPI() now maps shapes correctly (linear = pt.shape == 0), so API markers
-- have full fidelity. Calling this function corrupted REAPER's internal beat positions
-- because deleting API markers before SetEnvelopeStateChunk caused TIMELOCKMODE 2
-- items to recalculate, and the rebuilt markers had different internal beat positions.
local function applyTempoViaEnvelopeChunk()
    if #rppQueue == 0 then return false end
    log("\n=== Applying Full-Fidelity Tempo via Envelope Chunk ===\n")

    -- Build a lookup of shape values from rppQueue (keyed by approximate time position)
    local shapeByTime = {}  -- { {time=, shape=, num=, denom=}, ... }
    for _, rpp in ipairs(rppQueue) do
        for _, pt in ipairs(rpp.tempoMap) do
            shapeByTime[#shapeByTime + 1] = {
                time = rpp.timeOffset + (pt.time or 0),
                shape = pt.shape,
                num = pt.num,
                denom = pt.denom
            }
        end
    end
    table.sort(shapeByTime, function(a, b) return a.time < b.time end)

    -- Read back API markers — PT positions in TEMPOENVEX are in SECONDS (not QN)
    local existingCount = r.CountTempoTimeSigMarkers(0)
    log(string.format("  Reading %d existing API tempo markers\n", existingCount))

    if existingCount < 2 then
        log("  No tempo changes to apply (single tempo throughout)\n")
        return true
    end

    -- Build allPoints by matching API markers with our shape data (both sorted by time)
    local allPoints = {}
    local shapeIdx = 1
    for i = 0, existingCount - 1 do
        local ok, timepos, measurepos, beatpos, bpm, tsnum, tsdenom, lineartempo =
            r.GetTempoTimeSigMarker(0, i)
        if ok then
            -- Find matching shape from our rppQueue data (sequential match by closest time)
            -- Shape mapping: lineartempo=true → gradual → shape=0; lineartempo=false → square → shape=1
            local bestShape = lineartempo and 0 or 1  -- fallback from API linear flag
            local bestNum, bestDenom = nil, nil
            local bestDist = math.huge
            -- Search forward from last match position for efficiency
            for si = shapeIdx, #shapeByTime do
                local dist = math.abs(shapeByTime[si].time - timepos)
                if dist < bestDist then
                    bestDist = dist
                    bestShape = shapeByTime[si].shape
                    bestNum = shapeByTime[si].num
                    bestDenom = shapeByTime[si].denom
                    shapeIdx = si  -- advance for next iteration
                elseif dist > bestDist then
                    break  -- past the closest match, stop searching
                end
            end

            -- Use time sig from our data if API doesn't have it
            local useNum = (tsnum > 0) and tsnum or bestNum
            local useDenom = (tsdenom > 0) and tsdenom or bestDenom

            allPoints[#allPoints + 1] = {
                pos = timepos,  -- SECONDS — TEMPOENVEX PT positions are in seconds
                bpm = bpm,
                shape = bestShape,
                num = useNum,
                denom = useDenom
            }

            log(string.format("  API marker %d: time=%.4f bpm=%.4f shape=%d ts=%s\n",
                i, timepos, bpm, bestShape,
                useNum and string.format("%d/%d", useNum, useDenom or 4) or "-"))
        end
    end

    -- Build TEMPOENVEX chunk
    local lines = {}
    lines[#lines + 1] = "<TEMPOENVEX"
    lines[#lines + 1] = "ACT 1 -1"
    lines[#lines + 1] = "VIS 1 0 1"
    lines[#lines + 1] = "LANEHEIGHT 0 0"
    lines[#lines + 1] = "ARM 0"
    lines[#lines + 1] = "DEFSHAPE 0 -1 -1"
    for _, pt in ipairs(allPoints) do
        if pt.num and pt.denom and pt.num > 0 and pt.denom > 0 then
            local ts = pt.denom * 65536 + pt.num
            lines[#lines + 1] = string.format("PT %.14g %.14g %d %d",
                pt.pos, pt.bpm, pt.shape, ts)
        else
            lines[#lines + 1] = string.format("PT %.14g %.14g %d",
                pt.pos, pt.bpm, pt.shape)
        end
    end
    lines[#lines + 1] = ">"
    local chunk = table.concat(lines, "\n")

    -- Delete all existing API tempo markers first to prevent duplicates
    -- (REAPER's tempo envelope has a dual-source system: internal markers + envelope chunk.
    --  If we don't clear the markers, SetEnvelopeStateChunk merges rather than replaces.)
    for i = existingCount - 1, 0, -1 do
        r.DeleteTempoTimeSigMarker(0, i)
    end

    -- Apply to master tempo envelope
    local masterTrack = r.GetMasterTrack(0)
    local tempoEnv = masterTrack and r.GetTrackEnvelopeByName(masterTrack, "Tempo map")
    if not tempoEnv then
        log("  ERROR: Cannot get tempo envelope\n")
        return false
    end

    log("  Chunk to apply (" .. #allPoints .. " points):\n")
    for cline in chunk:gmatch("[^\n]+") do
        log("    " .. cline .. "\n")
    end

    local ok = r.SetEnvelopeStateChunk(tempoEnv, chunk, true)
    if not ok then
        log("  ERROR: SetEnvelopeStateChunk failed\n")
        return false
    end

    r.UpdateTimeline()
    r.UpdateArrange()

    -- Verify
    local resultCount = r.CountTempoTimeSigMarkers(0)
    log(string.format("  Result: %d tempo markers after chunk apply (expected %d)\n",
        resultCount, #allPoints))

    log("  Tempo envelope applied successfully\n")
    return true
end

-- Write merged tempo/marker section to current project (FALLBACK — only used if SetEnvelopeStateChunk fails)
local function writeMultiRppTempoSection()
    if #rppQueue == 0 then
        log("No RPPs in queue, skipping tempo merge\n")
        return
    end

    log("\n=== Writing Multi-RPP Tempo/Markers ===\n")

    -- Build merged section
    local mergedSection = buildMergedTempoSection()
    if not mergedSection then
        log("Failed to build merged tempo section\n")
        return
    end

    -- Save current project
    r.Main_SaveProject(0, false)

    -- Read current project
    local _, cur_path = r.EnumProjects(-1, "")
    if not cur_path or cur_path == "" then
        log("Current project not saved\n")
        return
    end

    local f = io.open(cur_path, "rb")
    if not f then
        log("Cannot read current project\n")
        return
    end
    local cur_txt = f:read("*a"):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    f:close()

    -- Find TEMPO and PROJBAY in current project
    local cur_tempo_start = cur_txt:find("\n%s*TEMPO%s+") or cur_txt:find("^%s*TEMPO%s+")
    if not cur_tempo_start then
        log("No TEMPO in current project\n")
        return
    end
    cur_tempo_start = (cur_txt:sub(cur_tempo_start, cur_tempo_start) == "\n") and (cur_tempo_start + 1) or cur_tempo_start

    local cur_projbay_start = cur_txt:find("\n%s*<PROJBAY", cur_tempo_start) or cur_txt:find("^%s*<PROJBAY", cur_tempo_start)
    if not cur_projbay_start then
        log("No <PROJBAY> in current project\n")
        return
    end

    -- Extract existing MARKER lines from the TEMPO-to-PROJBAY section
    -- (REAPER writes API-created markers/regions here on save)
    local tempoToProjbay = cur_txt:sub(cur_tempo_start, cur_projbay_start - 1)
    local existingMarkers = {}
    for line in tempoToProjbay:gmatch("[^\n]+") do
        if line:match("^%s*MARKER%s+") then
            existingMarkers[#existingMarkers + 1] = line
        end
    end
    local markerBlock = (#existingMarkers > 0) and (table.concat(existingMarkers, "\n") .. "\n") or ""
    log(string.format("  Preserved %d MARKER lines from saved .rpp\n", #existingMarkers))

    -- Build new project text: TEMPO+TEMPOENVEX (from mergedSection) + preserved MARKERs + rest
    local new_txt = cur_txt:sub(1, cur_tempo_start - 1) .. mergedSection .. "\n" .. markerBlock .. cur_txt:sub(cur_projbay_start)

    -- Backup
    local backup = cur_path .. ".backup_before_multirpp.rpp"
    f = io.open(backup, "wb")
    if f then f:write(cur_txt); f:close() end

    -- Write
    f = io.open(cur_path, "wb")
    if not f then
        log("Cannot write modified project\n")
        return
    end
    f:write(new_txt)
    f:close()

    log("Multi-RPP Tempo/Markers written!\n")
    log(string.format("  %d RPPs, %d total tempo points\n", #rppQueue,
        (function() local c=0; for _,rpp in ipairs(rppQueue) do c=c+#rpp.tempoMap end return c end)()))
end

-- Clear multi-RPP queue
local function clearRppQueue()
    rppQueue = {}
    multiMap = {}
    multiNormMap = {}
    recSources = {}
    recPath.rpp = nil
    recPath.dir = nil
    _G.__recSources = recSources
end

-- Shift all envelope points on a track by delta seconds
local function shiftTrackEnvelopesBy(tr, delta)
    if not (validTrack(tr) and delta and math.abs(delta) >= 1e-9) then return end

    local envCount = r.CountTrackEnvelopes(tr)
    for e = 0, envCount - 1 do
        local env = r.GetTrackEnvelope(tr, e)
        if env then
            local ptCount = r.CountEnvelopePoints(env)
            -- Iterate backwards to avoid index shifting issues
            for p = ptCount - 1, 0, -1 do
                local retval, time, value, shape, tension, selected = r.GetEnvelopePoint(env, p)
                if retval then
                    r.SetEnvelopePoint(env, p, time + delta, value, shape, tension, selected, true)
                end
            end
            r.Envelope_SortPoints(env)
        end
    end
end

-- Move all items from srcTrack to destTrack (preserving positions)
local function moveItemsToTrack(srcTrack, destTrack)
    if not (validTrack(srcTrack) and validTrack(destTrack)) then return end

    -- Move items from last to first to avoid index issues
    local cnt = r.CountTrackMediaItems(srcTrack)
    for i = cnt - 1, 0, -1 do
        local item = r.GetTrackMediaItem(srcTrack, i)
        if item then
            r.MoveMediaItemToTrack(item, destTrack)
        end
    end
end

-- Copy envelope points from srcTrack to destTrack (additive, no clearing)
local function copyEnvelopePointsToTrack(srcTrack, destTrack)
    if not (validTrack(srcTrack) and validTrack(destTrack)) then return end

    local srcEnvCount = r.CountTrackEnvelopes(srcTrack)
    for e = 0, srcEnvCount - 1 do
        local srcEnv = r.GetTrackEnvelope(srcTrack, e)
        if srcEnv then
            -- Get envelope name to find matching dest envelope
            local _, srcEnvName = r.GetEnvelopeName(srcEnv)

            -- Find or create matching envelope on dest track
            local destEnv = nil
            local destEnvCount = r.CountTrackEnvelopes(destTrack)
            for d = 0, destEnvCount - 1 do
                local env = r.GetTrackEnvelope(destTrack, d)
                if env then
                    local _, dName = r.GetEnvelopeName(env)
                    if dName == srcEnvName then
                        destEnv = env
                        break
                    end
                end
            end

            if not destEnv then
                -- Try to make the envelope visible on dest track (creates it)
                -- Use chunk-based approach to copy envelope structure
                local _, srcEnvChunk = r.GetEnvelopeStateChunk(srcEnv, "", false)
                if srcEnvChunk and srcEnvChunk ~= "" then
                    -- Find the envelope on dest by enabling it via chunk manipulation
                    -- For now, skip envelopes that don't exist on dest
                    goto nextEnv
                end
            end

            if destEnv then
                local ptCount = r.CountEnvelopePoints(srcEnv)
                for p = 0, ptCount - 1 do
                    local retval, time, value, shape, tension, selected = r.GetEnvelopePoint(srcEnv, p)
                    if retval then
                        r.InsertEnvelopePoint(destEnv, time, value, shape, tension, selected, true)
                    end
                end
                r.Envelope_SortPoints(destEnv)
            end

            ::nextEnv::
        end
    end
end

-- Set tempo markers via API (for correct item positioning before track import)
local function setTempoViaAPI()
    if #rppQueue == 0 then return end

    log("\n=== Setting tempo via API for Multi-RPP ===\n")

    -- Delete existing tempo markers (except the first/default)
    local existingCount = r.CountTempoTimeSigMarkers(0)
    for i = existingCount - 1, 0, -1 do
        r.DeleteTempoTimeSigMarker(0, i)
    end

    -- Collect all tempo points with time-based offsets
    local allPoints = {}

    for _, rpp in ipairs(rppQueue) do
        for _, pt in ipairs(rpp.tempoMap) do
            allPoints[#allPoints + 1] = {
                timepos = rpp.timeOffset + (pt.time or 0),  -- Absolute project time in seconds
                bpm = pt.bpm,
                num = pt.num or 0,
                denom = pt.denom or 0,
                linear = pt.shape == 0  -- shape 0 = gradual (linear=true), shape 1 = square (linear=false)
            }
        end
    end

    -- Sort by time position
    table.sort(allPoints, function(a, b) return a.timepos < b.timepos end)

    -- Set first point as project tempo
    if allPoints[1] then
        r.SetCurrentBPM(0, allPoints[1].bpm, true)
    end

    -- Add all tempo markers via API using time positions
    for _, pt in ipairs(allPoints) do
        r.SetTempoTimeSigMarker(0, -1, pt.timepos, -1, -1,
            pt.bpm, pt.num, pt.denom, pt.linear)
    end

    r.UpdateTimeline()
    log(string.format("  Set %d tempo markers via API\n", #allPoints))
    for _, pt in ipairs(allPoints) do
        log(string.format("  API tempo set: time=%.4fs bpm=%.4f linear=%s num=%d denom=%d\n",
            pt.timepos, pt.bpm, tostring(pt.linear), pt.num, pt.denom))
    end
end

-- Create regions for each RPP in the queue
local function createMultiRppRegions()
    if not multiRppSettings.createRegions then return end

    log("\n=== Creating Multi-RPP Regions ===\n")

    for i, rpp in ipairs(rppQueue) do
        -- Use time-based offsets directly (no beat→time conversion needed)
        local startTime = rpp.timeOffset
        local endTime = rpp.timeOffset + (rpp.maxEndTime or 0)

        r.AddProjectMarker2(0, true, startTime, endTime, rpp.name, -1, 0)
        log(string.format("  Region '%s': %.2fs - %.2fs\n", rpp.name, startTime, endTime))
    end
end

-- Import markers from all RPPs with correct time offsets
local function importMultiRppMarkers()
    if not multiRppSettings.importMarkers then return end

    log("\n=== Importing Multi-RPP Markers ===\n")

    for _, rpp in ipairs(rppQueue) do
        -- Use time-based offset directly
        local offsetTime = rpp.timeOffset

        for _, m in ipairs(rpp.markers) do
            local adjPos = m.pos + offsetTime
            if m.isRegion then
                local adjEnd = m.rgnend + offsetTime
                r.AddProjectMarker2(0, true, adjPos, adjEnd, m.name, -1, m.color)
            else
                r.AddProjectMarker2(0, false, adjPos, 0, m.name, -1, m.color)
            end
        end
    end
end

-- Auto-match one RPP column against template tracks (same logic as autosuggest)
local function multiRppAutoMatchColumn(rppIdx)
    if rppIdx < 1 or rppIdx > #rppQueue then return end
    local rpp = rppQueue[rppIdx]
    if not rpp or not rpp.tracks then return end

    local R = #rpp.tracks
    local M = #mixTargets
    if M == 0 or R == 0 then return end

    -- Track which RPP tracks and template tracks are already assigned in this column
    local usedR = {}
    local usedM = {}
    for mi, row in pairs(multiMap) do
        if row[rppIdx] and row[rppIdx] > 0 then
            usedR[row[rppIdx]] = true
            usedM[mi] = true
        end
    end

    local function eligible(i)
        local tr = mixTargets[i]
        if not validTrack(tr) then return false end
        local nm = nameCache[tr] or trName(tr)
        if protectedSet[nm] then return false end
        if isFolderHeader(tr) then return false end
        return true
    end

    -- Match scoring (same priority as autosuggest's calculateMatchScore)
    local function getFirstWord(name)
        local normalized = normalizeName(name)
        return normalized:match("^(%w+)") or normalized
    end

    local function calcScore(mixName, recName)
        local mnorm = normalizeName(mixName)
        local rnorm = normalizeName(recName)
        if mnorm == "" or rnorm == "" then return 0 end
        -- PRIORITY 1: Exact match (100%)
        if mnorm == rnorm then return 1.0 end
        -- PRIORITY 2: Prefix match with space/digit boundary (95%)
        local mnorm_escaped = mnorm:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
        local rnorm_escaped = rnorm:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
        if rnorm:match("^" .. mnorm_escaped .. "[%s%d]") then return 0.95 end
        if mnorm:match("^" .. rnorm_escaped .. "[%s%d]") then return 0.95 end
        -- PRIORITY 3: First word exact match (85%)
        local mixFirstWord = getFirstWord(mixName)
        local recFirstWord = getFirstWord(recName)
        if mixFirstWord ~= "" and recFirstWord ~= "" and
           mixFirstWord == recFirstWord and #mixFirstWord > 1 then
            return 0.85
        end
        -- PRIORITY 4: Contains match with word boundaries (75%)
        local shorterLen = math.min(#mnorm, #rnorm)
        local longerLen = math.max(#mnorm, #rnorm)
        if shorterLen >= 3 and longerLen > shorterLen + 2 then
            local shorter = (#mnorm < #rnorm) and mnorm or rnorm
            local longer = (#mnorm < #rnorm) and rnorm or mnorm
            local sh_esc = shorter:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
            if longer:find("^" .. sh_esc .. "%s") or
               longer:find("%s" .. sh_esc .. "%s") or
               longer:find("%s" .. sh_esc .. "$") then
                return 0.75
            end
        end
        -- PRIORITY 5: Fuzzy similarity
        return baseSimilarity(mixName, recName)
    end

    -- First pass: Alias matching
    for i = 1, M do
        if eligible(i) and not usedM[i] then
            local mixL = trimLower(nameCache[mixTargets[i]] or trName(mixTargets[i]))
            for j = 1, R do
                if not usedR[j] then
                    local recName = rpp.tracks[j].name or ""
                    if recName:find("%.") then
                        recName = recName:gsub("%.(%w+)$", " %1"):gsub("^%s+", "")
                    end
                    local dstL = findAliasTarget(recName)
                    if dstL and dstL == mixL then
                        multiMap[i] = multiMap[i] or {}
                        multiMap[i][rppIdx] = j
                        usedR[j] = true
                        usedM[i] = true
                        break
                    end
                end
            end
        end
    end

    -- Second pass: Score-based matching with global optimization
    local allMatches = {}
    for j = 1, R do
        if not usedR[j] then
            local recName = rpp.tracks[j].name or ""
            if recName:find("%.") then
                recName = recName:gsub("%.(%w+)$", " %1"):gsub("^%s+", "")
            end
            for i = 1, M do
                if eligible(i) and not usedM[i] then
                    local mixName = nameCache[mixTargets[i]] or trName(mixTargets[i])
                    local score = calcScore(mixName, recName)
                    if score >= AUTOSUGGEST_THRESH then
                        allMatches[#allMatches + 1] = {
                            recIdx = j,
                            mixIdx = i,
                            score = score,
                            recName = recName,
                            mixName = mixName
                        }
                    end
                end
            end
        end
    end

    -- Sort by score (highest first), then by name length
    table.sort(allMatches, function(a, b)
        if math.abs(a.score - b.score) > 0.001 then
            return a.score > b.score
        end
        return #a.mixName < #b.mixName
    end)

    -- Group by recording track and assign best available match
    local matchesByRec = {}
    for _, match in ipairs(allMatches) do
        if not matchesByRec[match.recIdx] then
            matchesByRec[match.recIdx] = {}
        end
        table.insert(matchesByRec[match.recIdx], match)
    end

    for recIdx, matches in pairs(matchesByRec) do
        if not usedR[recIdx] then
            for _, match in ipairs(matches) do
                if not usedM[match.mixIdx] then
                    multiMap[match.mixIdx] = multiMap[match.mixIdx] or {}
                    multiMap[match.mixIdx][rppIdx] = recIdx
                    usedR[recIdx] = true
                    usedM[match.mixIdx] = true
                    lockParentFolders(match.mixIdx)
                    break
                end
            end
        end
    end
end

-- Auto-match all RPP columns
local function multiRppAutoMatchAll()
    for rppIdx = 1, #rppQueue do
        multiRppAutoMatchColumn(rppIdx)
    end
end

-- Forward declarations for functions defined later but used in commitMultiRpp
local sanitizeChunk
local fixChunkMediaPaths
local postprocessTrackCopyRelink
local copyFX
local cloneSends
local rewireReceives
local copyTrackControls
local shiftTrackItemsBy
local replaceGroupFlagsInChunk

-- ===== MULTI-RPP COMMIT FLOW =====
local function commitMultiRpp()
    if #rppQueue == 0 then return end

    log("\n========================================\n")
    log("=== MULTI-RPP COMMIT START ===\n")
    log(string.format("=== %d RPPs in queue ===\n", #rppQueue))
    log("========================================\n")

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)

    -- STEP 1: Set tempo via API (for correct positioning during track import)
    setTempoViaAPI()

    -- Tempo map is now fully set via API with correct shapes (linear = pt.shape == 0).
    -- applyTempoViaEnvelopeChunk() is no longer called here — API markers have full fidelity
    -- (shapes 0/1 map perfectly to linear true/false). Calling SetEnvelopeStateChunk after
    -- deleting API markers corrupted REAPER's internal beat positions (TIMELOCKMODE 2 issue).
    -- REAPER will generate the correct TEMPOENVEX from internal markers on save.

    -- Use time-based offsets directly (no beat→time conversion)
    local regionOffsets = {}  -- rppIdx -> startTime (seconds)
    for rppIdx, rpp in ipairs(rppQueue) do
        regionOffsets[rppIdx] = rpp.timeOffset
        log(string.format("  RPP %d '%s': timeOffset=%.4fs\n",
            rppIdx, rpp.name, rpp.timeOffset))
    end

    -- STEP 2: Import tracks, shift, consolidate
    local matchedSet = {}

    for i, mixTr in ipairs(mixTargets) do
        if not validTrack(mixTr) then goto nextTemplate end
        if not multiMap[i] then goto nextTemplate end

        -- Collect which RPPs have a mapping for this template track
        local mappedRpps = {}
        for rppIdx = 1, #rppQueue do
            local trackIdx = multiMap[i] and multiMap[i][rppIdx]
            if trackIdx and trackIdx > 0 then
                local rpp = rppQueue[rppIdx]
                local entry = rpp and rpp.tracks[trackIdx]
                if entry then
                    mappedRpps[#mappedRpps + 1] = {
                        rppIdx = rppIdx,
                        entry = entry,
                        offset = regionOffsets[rppIdx] or 0,
                        rppDir = rpp.dir
                    }
                end
            end
        end

        if #mappedRpps == 0 then goto nextTemplate end

        local mixName = nameCache[mixTr] or trName(mixTr)
        local mixColor = effective_rgb24(mixTr)
        local mixIdx = idxOf(mixTr)
        local mixDepth = folderDepth(mixTr)

        -- Extract template GROUP_FLAGS for later application (same as single-RPP)
        local _, templateChunk = r.GetTrackStateChunk(mixTr, "", false)
        local templateGroupFlags = templateChunk:match("(GROUP_FLAGS[^\r\n]*)")

        log(string.format("\n--- Template: '%s' (%d RPP mappings) ---\n", mixName, #mappedRpps))

        -- 4a: Import all mapped tracks (insert after template)
        local importedTracks = {}
        for _, mp in ipairs(mappedRpps) do
            local insertIdx = mixIdx + #importedTracks + 1
            r.InsertTrackAtIndex(insertIdx, true)
            local newTr = r.GetTrack(0, insertIdx)

            if validTrack(newTr) and mp.entry.src == "rpp" then
                local chunk = sanitizeChunk(mp.entry.chunk)

                -- Fix media paths relative to source RPP dir
                local savedDir = recPath.dir
                recPath.dir = mp.rppDir
                chunk = fixChunkMediaPaths(chunk, settings.copyMedia)
                recPath.dir = savedDir

                -- 4b: Shift item positions and envelope points in chunk before applying
                -- (shifting via API after SetTrackStateChunk can fail inside PreventUIRefresh)
                -- Must be done BEFORE adding POOLEDENV (pooled envs use beat-based positions)
                if mp.offset > 0 then
                    local posCount, ptCount
                    chunk, posCount = chunk:gsub("(\n%s*POSITION%s+)([%d%.%-]+)", function(prefix, pos)
                        return prefix .. string.format("%.10f", tonumber(pos) + mp.offset)
                    end)
                    -- Shift envelope points (PT <time> ...) in track envelopes
                    chunk, ptCount = chunk:gsub("(\n%s*PT%s+)([%d%.%-]+)", function(prefix, t)
                        return prefix .. string.format("%.10f", tonumber(t) + mp.offset)
                    end)
                    log(string.format("  Shifted RPP %d: %d POSITIONs, %d PTs by %.2fs\n",
                        mp.rppIdx, posCount, ptCount, mp.offset))
                end

                -- Add POOLEDENV if needed (after shifting — pooled envs are beat-based, not shifted)
                if mp.entry.pooledEnvs and #mp.entry.pooledEnvs > 0 then
                    local closingPos = chunk:find(">%s*$")
                    if closingPos then
                        local pooledEnvText = ""
                        for _, poolChunk in ipairs(mp.entry.pooledEnvs) do
                            pooledEnvText = pooledEnvText .. poolChunk
                        end
                        chunk = chunk:sub(1, closingPos - 1) .. pooledEnvText .. chunk:sub(closingPos)
                    end
                end

                local chunkOk = r.SetTrackStateChunk(newTr, chunk, false)
                if not chunkOk then
                    log(string.format("  WARNING: SetTrackStateChunk FAILED for RPP %d track '%s'\n",
                        mp.rppIdx, mp.entry.name or "?"))
                end
                postprocessTrackCopyRelink(newTr, settings.copyMedia)

                r.SetMediaTrackInfo_Value(newTr, "I_FOLDERDEPTH", 0)
                r.SetMediaTrackInfo_Value(newTr, "I_RECARM", 0)
                r.SetMediaTrackInfo_Value(newTr, "B_SHOWINMIXER", 1)
                r.SetMediaTrackInfo_Value(newTr, "B_SHOWINTCP", 1)

                importedTracks[#importedTracks + 1] = newTr
            end
        end

        if #importedTracks == 0 then goto nextTemplate end

        -- 4c.pre: Align lanes for visibility across imported tracks (BEFORE consolidation)
        -- When RPPs have different numbers of fixed lanes (e.g. Kulti=2 lanes, Mels=3 lanes),
        -- items on the active lane of each RPP need to be copied to the highest active lane
        -- so all are visible after consolidation. Original lanes are preserved.
        if multiRppSettings.alignLanes and #importedTracks > 1 then
            local maxActiveLane = 0
            local trackActiveLanes = {}

            for t, tr in ipairs(importedTracks) do
                if validTrack(tr) then
                    -- Find the highest lane with items on this track
                    local highestLane = 0
                    local cnt = r.CountTrackMediaItems(tr)
                    for idx = 0, cnt - 1 do
                        local item = r.GetTrackMediaItem(tr, idx)
                        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                        if lane > highestLane then highestLane = lane end
                    end

                    -- Find which lane is active (check from highest down)
                    local activeLane = 0
                    for lane = highestLane, 0, -1 do
                        local plays = r.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane)
                        if plays == 1 then
                            activeLane = lane
                            break
                        end
                    end

                    trackActiveLanes[t] = activeLane
                    if activeLane > maxActiveLane then maxActiveLane = activeLane end
                end
            end

            -- For tracks whose active lane < maxActiveLane: copy active-lane items to maxActiveLane
            if maxActiveLane > 0 then
                for t, tr in ipairs(importedTracks) do
                    local activeLane = trackActiveLanes[t] or 0
                    if activeLane < maxActiveLane and validTrack(tr) then
                        local cnt = r.CountTrackMediaItems(tr)
                        local itemsToCopy = {}
                        for idx = 0, cnt - 1 do
                            local item = r.GetTrackMediaItem(tr, idx)
                            local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                            if lane == activeLane then
                                itemsToCopy[#itemsToCopy + 1] = item
                            end
                        end
                        -- Duplicate items to maxActiveLane via chunk copy
                        for _, item in ipairs(itemsToCopy) do
                            local newItem = r.AddMediaItemToTrack(tr)
                            local _, itemChunk = r.GetItemStateChunk(item, "", false)
                            r.SetItemStateChunk(newItem, itemChunk, false)
                            r.SetMediaItemInfo_Value(newItem, "I_FIXEDLANE", maxActiveLane)
                        end
                        -- Activate maxActiveLane on this track
                        r.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. activeLane, 0)
                        r.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. maxActiveLane, 1)
                        log(string.format("  Track %d: copied %d items from lane %d to lane %d\n",
                            t, #itemsToCopy, activeLane, maxActiveLane))
                    end
                end
            end
        end

        -- 4c: Consolidate all imported tracks onto the first one
        local masterTrack = importedTracks[1]
        for t = 2, #importedTracks do
            local srcTrack = importedTracks[t]
            if validTrack(srcTrack) then
                moveItemsToTrack(srcTrack, masterTrack)
                copyEnvelopePointsToTrack(srcTrack, masterTrack)
                log(string.format("  Consolidated track %d onto master\n", t))
            end
        end

        -- 4d: Copy FX/Sends/Groups from template
        copyFX(mixTr, masterTrack)
        cloneSends(mixTr, masterTrack)
        copyTrackControls(mixTr, masterTrack)
        rewireReceives(mixTr, masterTrack)

        -- Copy group flags from template (same approach as single-RPP)
        if templateGroupFlags then
            local _, masterChunk = r.GetTrackStateChunk(masterTrack, "", false)
            masterChunk = replaceGroupFlagsInChunk(masterChunk, templateGroupFlags)
            r.SetTrackStateChunk(masterTrack, masterChunk, false)
        end

        -- Set name and color
        setTrName(masterTrack, mixName)
        if mixColor ~= 0 then r.SetTrackColor(masterTrack, mixColor) end

        -- 4e: Delete extra imported tracks (now empty)
        for t = #importedTracks, 2, -1 do
            local srcTrack = importedTracks[t]
            if validTrack(srcTrack) then
                r.DeleteTrack(srcTrack)
            end
        end

        -- 4f: Delete template track
        if validTrack(mixTr) then
            r.DeleteTrack(mixTr)
            matchedSet[mixTr] = true
        end

        ::nextTemplate::
    end

    -- STEP 3: Delete unused template tracks (if enabled)
    if settings.deleteUnused then
        r.Main_OnCommand(40297, 0)  -- Unselect all tracks

        for _, tr in ipairs(mixTargets) do
            if validTrack(tr) then
                local name = nameCache[tr] or trName(tr)
                if not matchedSet[tr] and not protectedSet[name] then
                    r.SetTrackSelected(tr, true)
                end
            end
        end

        r.Main_OnCommand(40005, 0)  -- Remove selected tracks
        r.Main_OnCommand(40297, 0)  -- Unselect all
    end

    r.PreventUIRefresh(-1)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()

    -- STEP 4: Create regions and import markers
    -- Tempo map is already final (set via API in STEP 1)
    createMultiRppRegions()
    importMultiRppMarkers()

    -- STEP 5: Normalization (per region)
    if normalizeMode then
        log("\n=== Multi-RPP Normalization (per region) ===\n")
        local regions = scanRegions()

        for i = 0, r.CountTracks(0) - 1 do
            local tr = r.GetTrack(0, i)
            if validTrack(tr) then
                local tName = trName(tr)

                -- Find normalization profile for this track
                local normInfo = nil
                for mi, mixTr in ipairs(mixTargets) do
                    local mName = nameCache[mixTr] or trName(mixTr)
                    if mName == tName and multiNormMap[mi] then
                        normInfo = multiNormMap[mi]
                        break
                    end
                end

                if normInfo and normInfo.profile ~= "-" then
                    local profile = getProfileByName(normInfo.profile)
                    if profile then
                        local normType, targetValue, usedProfile
                        if normInfo.profile == "Peak" then
                            normType = "Peak"
                            targetValue = normInfo.targetPeak
                        elseif normInfo.profile == "RMS" then
                            normType = "RMS"
                            targetValue = normInfo.targetPeak
                        else
                            normType = "LUFS"
                            targetValue = calculateLUFS(normInfo.targetPeak, profile.offset)
                            usedProfile = profile
                        end
                        normalizeTrack(tr, normType, targetValue, regions, nil, usedProfile)
                    end
                end
            end
        end
    end

    -- STEP 6: Build peaks for new tracks
    r.Main_OnCommand(40047, 0)  -- Build missing peaks

    -- STEP 7: Minimize all tracks
    r.PreventUIRefresh(1)
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        r.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", 26)
    end
    r.PreventUIRefresh(-1)
    r.TrackList_AdjustWindows(false)

    r.Undo_EndBlock("RAPID v" .. VERSION .. ": Multi-RPP Import", -1)
    uiFlags.close = true
end

-- ===== APPLY LAST MAP =====
local function applyLastMap()
    local lm = loadLastMapData()
    if not lm or #mixTargets == 0 or #recSources == 0 then return end
    
    local recIndexByName = {}
    for j, rc in ipairs(recSources) do
        local key = (rc.name or ""):lower()
        if key ~= "" and not recIndexByName[key] then
            recIndexByName[key] = j
        end
    end
    
    for i, tr in ipairs(mixTargets) do
        local mname = nameCache[tr] or trName(tr)
        local arr = lm[mname]
        
        if not arr then
            local ml = (mname or ""):lower()
            for k, v in pairs(lm) do
                if (k or ""):lower() == ml then
                    arr = v
                    break
                end
            end
        end
        
        if arr and #arr > 0 then
            map[i] = {}
            for s = 1, #arr do
                map[i][s] = recIndexByName[(arr[s] or ""):lower()] or 0
            end
            
            -- Auto-lock parent folders when restoring from last map
            if map[i][1] and map[i][1] > 0 then
                lockParentFolders(i)
            end
        end
    end
    
    _G.__map = map
end

-- ===== AUTO-SUGGEST (TRACKS) =====
local function hasAssignment(mi)
    local slots = map[mi] or {}
    for _, ri in ipairs(slots) do
        if ri and ri > 0 then return true end
    end
    return false
end

local function unlockEmptyFolders()
    for i = 1, #mixTargets do
        local tr = mixTargets[i]
        if isFolderHeader(tr) then
            local level = 1
            local anyAssigned = false
            local j = i + 1
            
            while j <= #mixTargets and level > 0 do
                local d = folderDepth(mixTargets[j])
                if hasAssignment(j) then anyAssigned = true end
                if d == 1 then
                    level = level + 1
                elseif d < 0 then
                    level = level + d
                end
                j = j + 1
            end
            
            local name = nameCache[tr] or trName(tr)
            if not anyAssigned then protectedSet[name] = nil end
        end
    end
    _G.__protectedSet = protectedSet
end

local function autosuggest()
    local M, R = #mixTargets, #recSources
    if M == 0 or R == 0 then return end
    
    for i = 1, M do map[i] = {0} end
    local usedR = {}
    local usedM = {}
    
    local function eligible(i)
        local tr = mixTargets[i]
        if not validTrack(tr) then return false end
        local nm = nameCache[tr] or trName(tr)
        if protectedSet[nm] then return false end
        -- NEVER match folder tracks
        if isFolderHeader(tr) then return false end
        return true
    end
    
    -- Helper: Extract first word from track name
    local function getFirstWord(name)
        local normalized = normalizeName(name)
        return normalized:match("^(%w+)") or normalized
    end
    
    -- Helper: Calculate match score with PROPER priority order
    local function calculateMatchScore(mixName, recName)
        local mnorm = normalizeName(mixName)
        local rnorm = normalizeName(recName)
        
        if mnorm == "" or rnorm == "" then return 0 end
        
        -- PRIORITY 1: Exact match (100%)
        if mnorm == rnorm then
            return 1.0
        end
        
        -- PRIORITY 2: Prefix match with space/digit boundary (95%)
        local mnorm_escaped = mnorm:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
        local rnorm_escaped = rnorm:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
        
        -- Recording starts with mix name + space/digit
        if rnorm:match("^" .. mnorm_escaped .. "[%s%d]") then
            return 0.95
        end
        
        -- Mix starts with recording name + space/digit
        if mnorm:match("^" .. rnorm_escaped .. "[%s%d]") then
            return 0.95
        end
        
        -- PRIORITY 3: First word exact match (85%)
        local mixFirstWord = getFirstWord(mixName)
        local recFirstWord = getFirstWord(recName)
        if mixFirstWord ~= "" and recFirstWord ~= "" and 
           mixFirstWord == recFirstWord and #mixFirstWord > 1 then
            return 0.85
        end
        
        -- PRIORITY 4: Contains match with word boundaries (minimum 3 chars) (75%)
        local shorterLen = math.min(#mnorm, #rnorm)
        local longerLen = math.max(#mnorm, #rnorm)
        
        -- Only match if shorter string is at least 3 chars and significantly shorter than longer
        if shorterLen >= 3 and longerLen > shorterLen + 2 then
            local shorter = (#mnorm < #rnorm) and mnorm or rnorm
            local longer = (#mnorm < #rnorm) and rnorm or mnorm
            
            -- Check if shorter is contained in longer as a complete word
            if longer:find("^" .. shorter:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1") .. "%s") or
               longer:find("%s" .. shorter:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1") .. "%s") or
               longer:find("%s" .. shorter:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1") .. "$") then
                return 0.75
            end
        end
        
        -- PRIORITY 5: Fuzzy similarity
        return baseSimilarity(mixName, recName)
    end
    
    
    -- First pass: Aliases (Manual)
    for i = 1, M do
        if eligible(i) then
            local mixL = trimLower(nameCache[mixTargets[i]] or trName(mixTargets[i]))
            for j = 1, R do
                if not usedR[j] then
                    local recName = recSources[j].name
                    if recName:find("%.") then
                        recName = recName:gsub("%.(%w+)$", " %1"):gsub("^%s+", "")
                    end
                    local dstL = findAliasTarget(recName)
                    if dstL and dstL == mixL then
                        map[i][1] = j
                        usedR[j] = true
                        usedM[i] = true
                        break
                    end
                end
            end
        end
    end
    
    -- NEW STRATEGY: Recording-first matching with global optimization
    log("\n========== RECORDING-FIRST MATCHING ==========\n")
    
    -- Step 1: For each recording, find ALL possible mix tracks and their scores
    local allMatches = {}  -- Array of {recIdx, mixIdx, score, recName, mixName}
    
    for j = 1, R do
        if not usedR[j] then
            local recName = recSources[j].name
            if recName:find("%.") then
                recName = recName:gsub("%.(%w+)$", " %1"):gsub("^%s+", "")
            end
            
            log(string.format("\nRecording '%s' - finding all matches:\n", recName))
            
            for i = 1, M do
                if eligible(i) and not usedM[i] then
                    local mixName = nameCache[mixTargets[i]] or trName(mixTargets[i])
                    local score = calculateMatchScore(mixName, recName)
                    
                    if score >= AUTOSUGGEST_THRESH then
                        allMatches[#allMatches + 1] = {
                            recIdx = j,
                            mixIdx = i,
                            score = score,
                            recName = recName,
                            mixName = mixName
                        }
                    end
                end
            end
        end
    end
    
    -- Step 2: Sort by score (highest first), then by track number
    table.sort(allMatches, function(a, b)
        -- First: Sort by score (highest first)
        if math.abs(a.score - b.score) > 0.001 then
            return a.score > b.score
        end
        
        -- Scores are equal - now sort intelligently
        
        -- Extract base name and number from mix track names
        local function extractBaseAndNumber(name)
            -- Match patterns like "BVoc 1", "Gtr 2", "T1", etc.
            local base, num = name:match("^(.-)%s*(%d+)%s*$")
            if base and num then
                return base:lower(), tonumber(num)
            end
            return name:lower(), nil
        end
        
        local aBase, aNum = extractBaseAndNumber(a.mixName)
        local bBase, bNum = extractBaseAndNumber(b.mixName)
        
        -- If both have same base name (e.g., "BVoc"), sort by number
        if aBase == bBase and aNum and bNum then
            return aNum < bNum  -- Lower numbers first (BVoc 1 before BVoc 2)
        end
        
        -- If only one has a number, prefer the numbered one
        if aBase == bBase then
            if aNum and not bNum then return true end
            if bNum and not aNum then return false end
        end
        
        -- Otherwise, prefer shorter names (more specific)
        return #a.mixName < #b.mixName
    end)
    
    -- Step 3: Assign ONLY best match per recording (not all over threshold)
    log("\n========== ASSIGNING BEST MATCHES ONLY ==========\n")
    
    -- Group matches by recording
    local matchesByRec = {}
    for _, match in ipairs(allMatches) do
        local recIdx = match.recIdx
        if not matchesByRec[recIdx] then
            matchesByRec[recIdx] = {}
        end
        table.insert(matchesByRec[recIdx], match)
    end
    
    -- For each recording, assign ONLY the best match
    for recIdx, matches in pairs(matchesByRec) do
        if not usedR[recIdx] then
            -- Find best match that's still available
            local bestMatch = nil
            for _, match in ipairs(matches) do
                if not usedM[match.mixIdx] then
                    bestMatch = match
                    break  -- First one is best (already sorted)
                end
            end
            
            if bestMatch then
                map[bestMatch.mixIdx][1] = recIdx
                usedR[recIdx] = true
                usedM[bestMatch.mixIdx] = true
                
                log(string.format("[Auto-match] %s <- %s (%.0f%% match)\n", bestMatch.mixName, bestMatch.recName, bestMatch.score * 100))
                
                -- Auto-lock parent folders when mapping via auto-suggest
                lockParentFolders(bestMatch.mixIdx)
            end
        end
    end
    
    _G.__map = map
    unlockEmptyFolders()
end

-- ===== HELPER FOR PROFILES =====
getProfileByName = function(name)
    if not name or name == "" or name == "-" then return nil end
    for _, p in ipairs(normProfiles) do
        if p.name == name then
            return p
        end
    end
    return nil
end

-- ===== AUTO-MATCH PROFILES =====
local function autoMatchProfiles()
    if #mixTargets == 0 or #normProfiles == 0 then return end
    
    local thresh = 0.40  -- 40% similarity threshold
    
    for i, tr in ipairs(mixTargets) do
        local trackName = nameCache[tr] or trName(tr)
        local nm = nameCache[tr] or trName(tr)
        
        -- Skip protected tracks
        if protectedSet[nm] then
            goto continue
        end
        
        -- CRITICAL: Only match profiles for tracks that have a recording assignment!
        local hasRecording = false
        local slots = map[i] or {0}
        for _, ri in ipairs(slots) do
            if ri and ri > 0 then
                hasRecording = true
                break
            end
        end
        
        if not hasRecording then
            log(string.format("Skipping profile match for '%s' (no recording assigned)\n", trackName))
            goto continue
        end
        
        
        -- FIRST: Check profileAliases for contains matches (case-insensitive)
        local foundAlias = false
        local trackNameLower = trackName:lower()
        
        log(string.format("Checking profile for '%s':\n", trackName))
        
        -- Sort aliases by length (longest first) to prioritize more specific matches
        local sortedAliases = {}
        for _, alias in ipairs(profileAliases) do
            sortedAliases[#sortedAliases + 1] = alias
        end
        table.sort(sortedAliases, function(a, b)
            return #(a.src or "") > #(b.src or "")
        end)
        
        for _, alias in ipairs(sortedAliases) do
            local srcList = alias.src or ""
            -- Split by comma to support multiple keywords per alias
            for srcPart in (srcList .. ","):gmatch("([^,]+),") do
                local srcLower = srcPart:gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if srcLower ~= "" then
                    -- Check if track name contains the alias source
                    if trackNameLower:find(srcLower, 1, true) then
                        log(string.format("  Found alias match: '%s' contains '%s'\n", trackName, srcLower))
                        
                        -- Found a profile alias match!
                        local targetProfileName = alias.dst or ""
                        
                        for _, profile in ipairs(normProfiles) do
                            if profile.name:lower() == targetProfileName:lower() then
                                -- Assign to ALL slots for this track
                                normMap[i] = normMap[i] or {}
                                for s = 1, #slots do
                                    normMap[i][s] = {
                                        profile = profile.name,
                                        targetPeak = profile.defaultPeak
                                    }
                                end
                                log(string.format("  Assigned profile '%s' via alias to all %d slots\n", profile.name, #slots))
                                foundAlias = true
                                break
                            end
                        end
                        
                        if not foundAlias then
                            log(string.format("  Profile '%s' not found!\n", targetProfileName))
                        end
                        
                        if foundAlias then break end
                    end
                end
            end
            if foundAlias then break end
        end

        
        if foundAlias then
            goto continue
        end
        
        -- SECOND: Try fuzzy matching with all profiles (but only if no alias found)
        local bestProfile = nil
        local bestScore = thresh
        
        for _, profile in ipairs(normProfiles) do
            local score = baseSimilarity(trackName, profile.name)
            if score > bestScore then
                bestProfile = profile
                bestScore = score
            end
        end
        
        if bestProfile then
            -- Assign to ALL slots for this track
            normMap[i] = normMap[i] or {}
            for s = 1, #slots do
                normMap[i][s] = {
                    profile = bestProfile.name,
                    targetPeak = bestProfile.defaultPeak
                }
            end
            log(string.format("Auto-matched (fuzzy): %s -> Profile: %s (%.0f%% match) to all %d slots\n", 
                trackName, bestProfile.name, bestScore * 100, #slots))
        else
            -- No good match found, keep current or set to None for all slots
            normMap[i] = normMap[i] or {}
            for s = 1, #slots do
                if not normMap[i][s] then
                    normMap[i][s] = {profile = "-", targetPeak = -6}
                end
            end
        end
        
        ::continue::
    end
end

-- ===== AUTO-MATCH PROFILES FOR MULTI-RPP =====
local function autoMatchProfilesMulti()
    if #mixTargets == 0 or #normProfiles == 0 then return end

    local thresh = 0.40

    for i, tr in ipairs(mixTargets) do
        local trackName = nameCache[tr] or trName(tr)

        if protectedSet[trackName] then goto continue end

        -- Only match tracks that have a recording assignment in multiMap
        local hasRecording = false
        if multiMap[i] then
            for _, v in pairs(multiMap[i]) do
                if v and v > 0 then hasRecording = true; break end
            end
        end
        if not hasRecording then goto continue end

        -- FIRST: Check profileAliases (contains match, longest first)
        local foundAlias = false
        local trackNameLower = trackName:lower()

        local sortedAliases = {}
        for _, alias in ipairs(profileAliases) do
            sortedAliases[#sortedAliases + 1] = alias
        end
        table.sort(sortedAliases, function(a, b)
            return #(a.src or "") > #(b.src or "")
        end)

        for _, alias in ipairs(sortedAliases) do
            local srcList = alias.src or ""
            for srcPart in (srcList .. ","):gmatch("([^,]+),") do
                local srcLower = srcPart:gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if srcLower ~= "" and trackNameLower:find(srcLower, 1, true) then
                    local targetProfileName = alias.dst or ""
                    for _, profile in ipairs(normProfiles) do
                        if profile.name:lower() == targetProfileName:lower() then
                            multiNormMap[i] = {
                                profile = profile.name,
                                targetPeak = profile.defaultPeak or -6
                            }
                            foundAlias = true
                            break
                        end
                    end
                    if foundAlias then break end
                end
            end
            if foundAlias then break end
        end

        if foundAlias then goto continue end

        -- SECOND: Fuzzy matching
        local bestProfile = nil
        local bestScore = thresh

        for _, profile in ipairs(normProfiles) do
            local score = baseSimilarity(trackName, profile.name)
            if score > bestScore then
                bestProfile = profile
                bestScore = score
            end
        end

        if bestProfile then
            multiNormMap[i] = {
                profile = bestProfile.name,
                targetPeak = bestProfile.defaultPeak or -6
            }
        else
            multiNormMap[i] = multiNormMap[i] or {profile = "-", targetPeak = -6}
        end

        ::continue::
    end
end

-- ===== NORMALIZE-ONLY MODE FUNCTIONS (from Little Joe) =====

local function loadTracksWithItems()
    tracks = {}
    normMapDirect = {}
    
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        if validTrack(tr) and trackHasItems(tr) then
            local name = trName(tr)
            tracks[#tracks + 1] = {
                track = tr,
                name = name
            }
            normMapDirect[#tracks] = {profile = "-", targetPeak = -6}
        end
    end
    
    log(string.format("Loaded %d tracks with media items\n", #tracks))
end

local function autoMatchProfilesDirect()
    if #tracks == 0 or #normProfiles == 0 then return end
    
    local thresh = 0.40
    
    for i, trackData in ipairs(tracks) do
        local trackName = trackData.name
        local trackNameLower = trackName:lower()
        local foundAlias = false
        
        log(string.format("Checking profile for '%s':\n", trackName))
        
        -- Sort aliases by length (longest first)
        local sortedAliases = {}
        for _, alias in ipairs(profileAliases) do
            sortedAliases[#sortedAliases + 1] = alias
        end
        table.sort(sortedAliases, function(a, b)
            return #(a.src or "") > #(b.src or "")
        end)
        
        -- Check profile aliases first
        for _, alias in ipairs(sortedAliases) do
            local srcList = alias.src or ""
            for srcPart in (srcList .. ","):gmatch("([^,]+),") do
                local srcLower = srcPart:gsub("^%s+", ""):gsub("%s+$", ""):lower()
                if srcLower ~= "" then
                    if trackNameLower:find(srcLower, 1, true) then
                        log(string.format("  Found alias match: '%s' contains '%s'\n", trackName, srcLower))
                        
                        local targetProfileName = alias.dst or ""
                        
                        for _, profile in ipairs(normProfiles) do
                            if profile.name:lower() == targetProfileName:lower() then
                                normMapDirect[i] = {
                                    profile = profile.name,
                                    targetPeak = profile.defaultPeak
                                }
                                log(string.format("  Assigned profile '%s' via alias\n", profile.name))
                                foundAlias = true
                                break
                            end
                        end
                        
                        if not foundAlias then
                            log(string.format("  Profile '%s' not found!\n", targetProfileName))
                        end
                        
                        if foundAlias then break end
                    end
                end
            end
            if foundAlias then break end
        end
        
        if foundAlias then
            goto continue
        end
        
        -- Fuzzy matching fallback
        local bestProfile = nil
        local bestScore = thresh
        
        for _, profile in ipairs(normProfiles) do
            local score = baseSimilarity(trackName, profile.name)
            if score > bestScore then
                bestProfile = profile
                bestScore = score
            end
        end
        
        if bestProfile then
            normMapDirect[i] = {
                profile = bestProfile.name,
                targetPeak = bestProfile.defaultPeak
            }
            log(string.format("Auto-matched (fuzzy): %s -> Profile: %s (%.0f%% match)\n", 
                trackName, bestProfile.name, bestScore * 100))
        else
            if not normMapDirect[i] then
                normMapDirect[i] = {profile = "-", targetPeak = -6}
            end
        end
        
        ::continue::
    end
end

-- ===== NORMALIZE-ONLY: COMMIT FUNCTION =====
local function doNormalizeDirectly()
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    
    log("\n=== Starting Normalization (Normalize-Only Mode) ===\n")
    
    local regions = settings.processPerRegion and scanRegions() or {}
    log(string.format("Regions found: %d\n", #regions))
    
    -- Build list of tracks to normalize
    local toProcess = {}
    for i, trackData in ipairs(tracks) do
        if normMapDirect[i] and normMapDirect[i].profile ~= "-" then
            toProcess[#toProcess + 1] = {
                index = i,
                track = trackData.track,
                name = trackData.name,
                profile = normMapDirect[i].profile,
                targetPeak = normMapDirect[i].targetPeak
            }
        end
    end
    
    if #toProcess == 0 then
        r.PreventUIRefresh(-1)
        r.ShowMessageBox("No tracks with profiles assigned.", "RAPID", 0)
        r.Undo_EndBlock("RAPID: Nothing to normalize", -1)
        return
    end
    
    -- Table to store target lane per track (for createNewLane mode)
    local trackLanes = {}
    
    -- If createNewLane is enabled, duplicate lanes for tracks to be normalized
    if settings.createNewLane then
        log("\n=== Duplicating lanes for normalized tracks ===\n")
        
        -- Set tracks to Fixed Item Lane mode (only tracks in toProcess with items)
        r.Main_OnCommand(40297, 0)  -- Unselect all tracks
        for _, proc in ipairs(toProcess) do
            if validTrack(proc.track) then
                local itemCount = r.CountTrackMediaItems(proc.track)
                if itemCount > 0 then
                    r.SetTrackSelected(proc.track, true)
                end
            end
        end
        
        r.Main_OnCommand(42431, 0)  -- Set selected tracks to fixed lane mode
        r.UpdateArrange()
        log("  Set selected tracks to Fixed Item Lane mode\n")
        
        -- Duplicate lanes (works on selected tracks)
        r.Main_OnCommand(42505, 0)
        r.UpdateArrange()
        log("  Duplicated active lanes to new lanes\n")
        
        -- Switch to next lane (the new duplicated one) - works on selected tracks
        r.Main_OnCommand(42482, 0)
        r.UpdateArrange()
        log("  Switched to play only next lane (new duplicated lane)\n")
        
        -- Store the highest lane for each track in toProcess
        for _, proc in ipairs(toProcess) do
            if validTrack(proc.track) then
                local maxLane = 0
                local itemCount = r.CountTrackMediaItems(proc.track)
                if itemCount > 0 then
                    for i = 0, itemCount - 1 do
                        local item = r.GetTrackMediaItem(proc.track, i)
                        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                        maxLane = math.max(maxLane, lane)
                    end
                    trackLanes[proc.track] = maxLane
                    log(string.format("  Track '%s': Target lane %d\n", proc.name, maxLane))
                end
            end
        end
        
        r.Main_OnCommand(40297, 0)  -- Unselect all tracks
        r.Main_OnCommand(40289, 0)  -- Unselect all items
        r.UpdateArrange()
        log("  Lane duplication complete\n")
    end
    
    -- Normalize each track
    local normalizedCount = 0
    for _, proc in ipairs(toProcess) do
        local normType, targetValue, usedProfile

        if proc.profile == "Peak" then
            normType = "Peak"
            targetValue = proc.targetPeak
            log(string.format("\nNormalizing: %s\n", proc.name))
            log(string.format("  Type: Peak @ %.1f dB\n", targetValue))
        elseif proc.profile == "RMS" then
            normType = "RMS"
            targetValue = proc.targetPeak
            log(string.format("\nNormalizing: %s\n", proc.name))
            log(string.format("  Type: RMS @ %.1f dB\n", targetValue))
        else
            local profile = getProfileByName(proc.profile)
            if profile then
                normType = "LUFS"
                targetValue = calculateLUFS(proc.targetPeak, profile.offset)
                usedProfile = profile  -- Store for passing to normalizeTrack
                log(string.format("\nNormalizing: %s\n", proc.name))
                log(string.format("  Profile: %s, Peak: %.1f dB, LUFS: %.1f\n",
                    proc.profile, proc.targetPeak, targetValue))
            end
        end

        if normType and targetValue then
            local success
            if settings.createNewLane then
                -- Use stored target lane from duplication
                local targetLane = trackLanes[proc.track]
                success = normalizeTrack(proc.track, normType, targetValue, regions, targetLane, usedProfile)
            else
                success = normalizeTrackDirect(proc.track, normType, targetValue, regions, usedProfile)
            end
            
            if success then
                normalizedCount = normalizedCount + 1
                log("  - Success\n")
            else
                log("  Failed\n")
            end
        end
    end
    
    log(string.format("\n=== Normalization Complete: %d tracks ===\n", normalizedCount))
    
    r.PreventUIRefresh(-1)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    r.UpdateTimeline()
    
    -- Generate peaks
    for i = 0, r.CountMediaItems(0) - 1 do
        local item = r.GetMediaItem(0, i)
        local take = r.GetActiveTake(item)
        if take then
            local src = r.GetMediaItemTake_Source(take)
            if src then
                r.PCM_Source_BuildPeaks(src, 0)
            end
        end
    end
    
    -- Hide fixed item lanes if they were created
    if settings.createNewLane then
        local lanesVisible = r.GetToggleCommandState(42432) == 1
        if lanesVisible then
            r.Main_OnCommand(42432, 0)  -- Toggle off = hide lanes
            log("\n=== Hidden fixed item lanes ===\n")
        end
    end
    
    r.Undo_EndBlock("RAPID v" .. VERSION .. ": Normalize " .. normalizedCount .. " tracks", -1)
    
    r.ShowMessageBox(
        string.format("Normalized %d tracks successfully!", normalizedCount),
        "RAPID",
        0
    )
end

-- ===== CHUNK SANITIZATION =====
sanitizeChunk = function(chunk)
    -- Patterns use %s* after \n to handle indented RPP chunks (2 spaces per nesting level)
    return (chunk
        :gsub("\n%s*I_FOLDERDEPTH%s+%-?%d+", "\nI_FOLDERDEPTH 0")
        :gsub("\n%s*AUXRECV.-\n", "\n")
        :gsub("\n%s*HWOUT.-\n", "\n")
        :gsub("\n%s*RECARM %d+", "\nRECARM 0")
        :gsub("\n%s*ISBUS%s+%d+%s+%d+", "\nISBUS 0 0")
        :gsub("\n%s*SHOWINMIX %-?%d+", "\nSHOWINMIX 1")
        :gsub("\n%s*SHOWINTCP %-?%d+", "\nSHOWINTCP 1"))
end

local function extractMediaPathsFromChunk(chunk)
    local paths = {}
    for line in chunk:gmatch("[^\n]+") do
        local file = line:match('^%s*FILE%s+"(.-)"')
        if not file then
            file = line:match("^%s*FILE%s+(.+)%s*$")
        end
        if file then
            file = file:gsub("^%s+", ""):gsub("%s+$", "")
            if file ~= "" then
                paths[#paths + 1] = file
            end
        end
    end
    return paths
end

local function tryResolveMedia(oldPath, rppDir)
    -- 1. Direct resolve (absolute exists, or relative from rppDir/projDir)
    local resolved = resolveMediaPath(oldPath, rppDir)
    if resolved then return resolved end

    -- 2. Try separator variants
    if oldPath:find("\\") then
        resolved = resolveMediaPath(oldPath:gsub("\\", "/"), rppDir)
        if resolved then return resolved end
    end

    -- 3. Absolute path that doesn't exist — try each suffix segment relative to rppDir
    --    e.g. "/Old/Location/Audio/file.wav" → try rppDir/Audio/file.wav, rppDir/file.wav
    local normOld = normalizePath(oldPath)
    if rppDir and rppDir ~= "" and isAbsolutePath(normOld) then
        local parts = {}
        for seg in normOld:gmatch("[^/]+") do
            parts[#parts + 1] = seg
        end
        -- Try progressively shorter suffixes (skip drive/root)
        for start = 2, #parts do
            local tail = table.concat(parts, "/", start)
            local candidate = joinPath(rppDir, tail)
            if fileExists(candidate) then return candidate end
        end
    end

    return nil
end

fixChunkMediaPaths = function(chunk, doCopy)
    if not chunk then return chunk end

    local mediaPaths = extractMediaPathsFromChunk(chunk)
    if #mediaPaths == 0 then return chunk end

    local newChunk = chunk

    for _, oldPath in ipairs(mediaPaths) do
        local resolvedPath = tryResolveMedia(oldPath, recPath.dir)

        if resolvedPath then
            local finalPath = resolvedPath
            if doCopy then
                finalPath = copyMediaToProject(resolvedPath)
            end

            log(string.format("  fixChunk: '%s' -> '%s'\n", oldPath, finalPath))

            if finalPath ~= oldPath then
                local escapedOld = oldPath:gsub("([%.%-%+%*%?%[%]%(%)%^%$%%])", "%%%1")
                local safeNew = finalPath:gsub("%%", "%%%%")

                local quotedOld = '"' .. escapedOld .. '"'
                local quotedNew = '"' .. safeNew .. '"'
                local replaced = newChunk:gsub(quotedOld, quotedNew)

                if replaced ~= newChunk then
                    newChunk = replaced
                else
                    local pattern = "FILE%s+" .. escapedOld
                    newChunk = newChunk:gsub(pattern, "FILE " .. safeNew)
                end
            end
        else
            log(string.format("  fixChunk UNRESOLVED: '%s'\n", oldPath))
        end
    end

    return newChunk
end

-- ===== POST-PROCESS TRACK =====
postprocessTrackCopyRelink = function(track, doCopy)
    if not track or not r.ValidatePtr(track, "MediaTrack*") then return end

    local item_cnt = r.CountTrackMediaItems(track)
    log(string.format("postprocessRelink: %d items, doCopy=%s\n", item_cnt, tostring(doCopy)))

    for i = 0, item_cnt - 1 do
        local item = r.GetTrackMediaItem(track, i)
        if item then
            local take_cnt = r.CountTakes(item)
            for t = 0, take_cnt - 1 do
                local take = r.GetTake(item, t)
                if take then
                    local src = r.GetMediaItemTake_Source(take)
                    if src then
                        local _, cur = r.GetMediaSourceFileName(src, "")
                        log(string.format("  take %d: src='%s' exists=%s\n", t, cur or "nil", tostring(fileExists(cur or ""))))
                        if cur and #cur > 0 then
                            if doCopy then
                                local newPath = copyMediaToProject(cur)
                                if newPath and newPath ~= cur then
                                    local newSrc = r.PCM_Source_CreateFromFile(newPath)
                                    if newSrc then
                                        r.SetMediaItemTake_Source(take, newSrc)
                                    end
                                end
                            elseif not fileExists(cur) then
                                -- No-copy mode: resolve and relink offline sources
                                local resolved = tryResolveMedia(cur, recPath.dir)
                                if resolved and fileExists(resolved) then
                                    log(string.format("    relink: '%s' -> '%s'\n", cur, resolved))
                                    local newSrc = r.PCM_Source_CreateFromFile(resolved)
                                    if newSrc then
                                        r.SetMediaItemTake_Source(take, newSrc)
                                    end
                                else
                                    log(string.format("    STILL OFFLINE: '%s' (rppDir='%s')\n", cur, recPath.dir or "nil"))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function sweepProjectCopyRelink(doCopy)
    if not doCopy then return end
    
    local media_dir = getProjectMediaDir()
    local item_cnt = r.CountMediaItems(0)
    
    for i = 0, item_cnt - 1 do
        local item = r.GetMediaItem(0, i)
        local take_cnt = r.CountTakes(item)
        
        for t = 0, take_cnt - 1 do
            local take = r.GetTake(item, t)
            if take then
                local src = r.GetMediaItemTake_Source(take)
                if src then
                    local _, cur = r.GetMediaSourceFileName(src, "")
                    if cur and #cur > 0 then
                        local basename = getBasename(cur)
                        local destPath = joinPath(media_dir, basename)
                        
                        if normalizePath(cur) ~= normalizePath(destPath) then
                            if fileExists(cur) then
                                if copyFile(cur, destPath) then
                                    local newSrc = r.PCM_Source_CreateFromFile(destPath)
                                    if newSrc then
                                        r.SetMediaItemTake_Source(take, newSrc)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ===== CREATE TRACK WITH AUDIO FILE =====
local function createTrackWithAudioFileAtIndex(insertIdx, mixDepth, filePath, trackName)
    if not filePath or filePath == "" then
        showError("Invalid file path")
        return nil
    end
    
    local finalPath = filePath
    if not fileExists(finalPath) then
        showError("Audio file not found: " .. filePath)
        return nil
    end
    
    if settings.copyMedia then
        finalPath = copyMediaToProject(filePath)
    end
    
    r.InsertTrackAtIndex(insertIdx, true)
    local tr = r.GetTrack(0, insertIdx)
    if not validTrack(tr) then
        showError("Failed to create track at index " .. insertIdx)
        return nil
    end
    
    local src = r.PCM_Source_CreateFromFile(finalPath)
    if not src then
        showError("Cannot load audio file: " .. finalPath)
        return nil
    end
    
    local length = (r.GetMediaSourceLength(src) or 1.0)
    local item = r.AddMediaItemToTrack(tr)
    r.SetMediaItemInfo_Value(item, "D_POSITION", _G.__mr_offset or 0.0)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", length)
    
    local take = r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take, src)
    
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", mixDepth)
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 1)
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
    
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", trackName or getBasename(finalPath), true)
    
    local color = effective_rgb24(tr)
    if color ~= 0 then r.SetTrackColor(tr, color) end
    
    return tr
end

-- ===== COPY FX/SENDS/CONTROLS (v1.1 API-based - WORKS!) =====
copyFX = function(src, dst)
    if not (validTrack(src) and validTrack(dst)) then return end
    -- Delete all FX on destination
    for i = r.TrackFX_GetCount(dst) - 1, 0, -1 do
        r.TrackFX_Delete(dst, i)
    end
    -- Copy FX from source to destination via API
    local n = r.TrackFX_GetCount(src)
    for i = 0, n - 1 do
        r.TrackFX_CopyToTrack(src, i, dst, r.TrackFX_GetCount(dst), false)
    end
end

-- NEW: Copy FX from a cached chunk to a destination track
local function copyFXFromChunk(sourceChunk, dst)
    if not (sourceChunk and validTrack(dst)) then return end
    
    -- Extract FX sections from source chunk
    local fxSections = {}
    for fx in sourceChunk:gmatch("(<[^>]+FX[^<>]*>.-\n>)") do
        table.insert(fxSections, fx)
    end
    
    if #fxSections == 0 then
        log("  No FX found in template chunk\n")
        return
    end
    
    -- Get destination track chunk
    local _, dstChunk = r.GetTrackStateChunk(dst, "", false)
    
    -- CRITICAL: Remove ALL existing FX sections from destination chunk first
    dstChunk = dstChunk:gsub("  <[^>]+FX[^<>]*>.-\n  >\n", "")
    
    -- Find insertion point (after VOLPAN line or at end of track properties, before <ITEM)
    local insertPos = dstChunk:find("\n  <ITEM") or dstChunk:find("\n>")
    if not insertPos then
        log("  Cannot find FX insertion point in destination chunk\n")
        return
    end
    
    -- Build FX text to insert
    local fxText = ""
    for _, fx in ipairs(fxSections) do
        fxText = fxText .. "  " .. fx .. "\n"
    end
    
    -- Insert FX into destination chunk
    local newChunk = dstChunk:sub(1, insertPos - 1) .. "\n" .. fxText .. dstChunk:sub(insertPos)
    
    -- Apply modified chunk
    r.SetTrackStateChunk(dst, newChunk, false)
    
    log(string.format("  Copied %d FX from template chunk (replaced existing)\n", #fxSections))
end

local function clearSendsHW(tr)
    if not validTrack(tr) then return end
    for i = r.GetTrackNumSends(tr, 0) - 1, 0, -1 do
        r.RemoveTrackSend(tr, 0, i)
    end
    for i = r.GetTrackNumSends(tr, 1) - 1, 0, -1 do
        r.RemoveTrackSend(tr, 1, i)
    end
end

cloneSends = function(src, dst)
    if not (validTrack(src) and validTrack(dst)) then return end
    if not HAVE_SWS then return end
    
    clearSendsHW(dst)
    
    local n = r.GetTrackNumSends(src, 0)
    for i = 0, n - 1 do
        local destTr = r.BR_GetMediaTrackSendInfo_Track(src, 0, i, 1)
        if validTrack(destTr) then
            local si = r.CreateTrackSend(dst, destTr)
            r.SetTrackSendInfo_Value(dst, 0, si, "D_VOL", r.GetTrackSendInfo_Value(src, 0, i, "D_VOL"))
            r.SetTrackSendInfo_Value(dst, 0, si, "D_PAN", r.GetTrackSendInfo_Value(src, 0, i, "D_PAN"))
            r.SetTrackSendInfo_Value(dst, 0, si, "I_SENDMODE", r.GetTrackSendInfo_Value(src, 0, i, "I_SENDMODE"))
            r.SetTrackSendInfo_Value(dst, 0, si, "B_MONO", r.GetTrackSendInfo_Value(src, 0, i, "B_MONO"))
            r.SetTrackSendInfo_Value(dst, 0, si, "B_MUTE", r.GetTrackSendInfo_Value(src, 0, i, "B_MUTE"))
        end
    end
    
    local h = r.GetTrackNumSends(src, 1)
    for i = 0, h - 1 do
        local si = r.CreateTrackSend(dst, nil)
        r.SetTrackSendInfo_Value(dst, 1, si, "I_HWCHAN", r.GetTrackSendInfo_Value(src, 1, i, "I_HWCHAN"))
        r.SetTrackSendInfo_Value(dst, 1, si, "D_VOL", r.GetTrackSendInfo_Value(src, 1, i, "D_VOL"))
        r.SetTrackSendInfo_Value(dst, 1, si, "D_PAN", r.GetTrackSendInfo_Value(src, 1, i, "D_PAN"))
        r.SetTrackSendInfo_Value(dst, 1, si, "B_MUTE", r.GetTrackSendInfo_Value(src, 1, i, "B_MUTE"))
    end
    
    r.SetMediaTrackInfo_Value(dst, "B_MAINSEND", r.GetMediaTrackInfo_Value(src, "B_MAINSEND"))
    r.SetTrackColor(dst, effective_rgb24(src))
end

rewireReceives = function(src, dst)
    if not (validTrack(src) and validTrack(dst) and HAVE_SWS) then return end
    
    local N = r.CountTracks(0)
    for i = 0, N - 1 do
        local tr = r.GetTrack(0, i)
        if validTrack(tr) and tr ~= dst then
            for s = r.GetTrackNumSends(tr, 0) - 1, 0, -1 do
                local to = r.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
                if to == src then
                    local vol = r.GetTrackSendInfo_Value(tr, 0, s, "D_VOL")
                    local pan = r.GetTrackSendInfo_Value(tr, 0, s, "D_PAN")
                    local mode = r.GetTrackSendInfo_Value(tr, 0, s, "I_SENDMODE")
                    local mono = r.GetTrackSendInfo_Value(tr, 0, s, "B_MONO")
                    r.RemoveTrackSend(tr, 0, s)
                    local si = r.CreateTrackSend(tr, dst)
                    r.SetTrackSendInfo_Value(tr, 0, si, "D_VOL", vol)
                    r.SetTrackSendInfo_Value(tr, 0, si, "D_PAN", pan)
                    r.SetTrackSendInfo_Value(tr, 0, si, "I_SENDMODE", mode)
                    r.SetTrackSendInfo_Value(tr, 0, si, "B_MONO", mono)
                end
            end
        end
    end
end

copyTrackControls = function(src, dst)
    if not (validTrack(src) and validTrack(dst)) then return end
    local function c(k)
        r.SetMediaTrackInfo_Value(dst, k, r.GetMediaTrackInfo_Value(src, k))
    end
    c("D_VOL")
    c("D_PAN")
    c("I_PANMODE")
    c("D_WIDTH")
    c("B_PHASE")
    c("B_MUTE")
    c("I_SOLO")
    c("B_MAINSEND")
end

local function copyTrackGroups(src, dst)
    if not (validTrack(src) and validTrack(dst)) then return end
    
    -- Copy group membership flags
    local groupFlags = r.GetMediaTrackInfo_Value(src, "I_GROUPFLAGS")
    r.SetMediaTrackInfo_Value(dst, "I_GROUPFLAGS", groupFlags)
    
    log(string.format("  Copied groups: 0x%X\n", groupFlags))
end

replaceGroupFlagsInChunk = function(chunk, templateChunkGroupFlags)
    log(string.format(">>> replaceGroupFlagsInChunk: templateChunkGroupFlags = '%s'\n", templateChunkGroupFlags or "NIL"))
    
    if not templateChunkGroupFlags or templateChunkGroupFlags == "" then
        log(">>> No template group flags to replace\n")
        return chunk
    end
    
    -- Replace entire GROUP_FLAGS line in chunk with template's GROUP_FLAGS line
    local pattern = "GROUP_FLAGS[^\r\n]*"
    
    -- Check if GROUP_FLAGS exists in chunk
    if chunk:match(pattern) then
        log(">>> Found GROUP_FLAGS in chunk, replacing entire line...\n")
        chunk = chunk:gsub(pattern, templateChunkGroupFlags)
    else
        log(">>> GROUP_FLAGS not found in chunk, adding after VU line...\n")
        -- If GROUP_FLAGS doesn't exist, add it after VU line
        local vuPos = chunk:find("VU %d+")
        if vuPos then
            local lineEnd = chunk:find("\n", vuPos)
            if lineEnd then
                chunk = chunk:sub(1, lineEnd) .. "    " .. templateChunkGroupFlags .. "\n" .. chunk:sub(lineEnd + 1)
                log(">>> Added GROUP_FLAGS after VU\n")
            end
        else
            log(">>> ERROR: No VU found in chunk!\n")
        end
    end
    
    return chunk
end

shiftTrackItemsBy = function(tr, delta)
    if not (validTrack(tr) and delta and math.abs(delta) >= 1e-9) then return end
    local cnt = r.CountTrackMediaItems(tr)
    for i = 0, cnt - 1 do
        local it = r.GetTrackMediaItem(tr, i)
        local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
        r.SetMediaItemInfo_Value(it, "D_POSITION", p + delta)
    end
end

-- ===== REPLACE MIX WITH SOURCE =====
local function replaceMixWithSourceAtSamePosition(entry, mixTr)
    local mixIdx = idxOf(mixTr)
    if mixIdx < 0 then
        showError("Invalid mix track index")
        return nil
    end
    
    local mixDepth = folderDepth(mixTr)
    
    -- Get template GROUP_FLAGS from chunk
    local _, templateChunk = r.GetTrackStateChunk(mixTr, "", false)
    local templateGroupFlags = templateChunk:match("(GROUP_FLAGS[^\r\n]*)")
    
    log(string.format(">>> replaceMixWithSourceAtSamePosition: mixTr=%s\n", trName(mixTr)))
    log(string.format(">>> Template GROUP_FLAGS line: '%s'\n", templateGroupFlags or "NOT FOUND"))
    
    if entry.src == "file" then
        log(">>> FILE IMPORT path\n")
        local newTr = createTrackWithAudioFileAtIndex(mixIdx, mixDepth, entry.file, entry.name)
        -- For file import: set groups from template using chunk manipulation
        if validTrack(newTr) and templateGroupFlags then
            local _, newChunk = r.GetTrackStateChunk(newTr, "", false)
            newChunk = replaceGroupFlagsInChunk(newChunk, templateGroupFlags)
            r.SetTrackStateChunk(newTr, newChunk, false)
            
            local checkAfter = r.GetMediaTrackInfo_Value(newTr, "I_GROUPFLAGS")
            log(string.format(">>> File import - After setting groups: I_GROUPFLAGS = 0x%X (%d)\n", checkAfter, checkAfter))
        end
        return newTr
    else
        log(">>> RPP IMPORT path\n")
        r.InsertTrackAtIndex(mixIdx, true)
        local t = r.GetTrack(0, mixIdx)
        if not validTrack(t) then
            showError("Failed to create track at index " .. mixIdx)
            return nil
        end
        
        local chunk = sanitizeChunk(entry.chunk)
        chunk = fixChunkMediaPaths(chunk, settings.copyMedia)

        -- CRITICAL: Add POOLEDENV data to track chunk if this track has automation items
        if entry.pooledEnvs and #entry.pooledEnvs > 0 then
            log("  Adding POOLEDENV data to track chunk...\n")
            
            -- Insert POOLEDENV sections at the END of track chunk (before closing >)
            local closingPos = chunk:find(">%s*$")
            if closingPos then
                local pooledEnvText = ""
                for _, poolChunk in ipairs(entry.pooledEnvs) do
                    -- CRITICAL FIX: Don't add extra spaces - poolChunk already has correct indentation
                    pooledEnvText = pooledEnvText .. poolChunk
                end
                chunk = chunk:sub(1, closingPos - 1) .. pooledEnvText .. chunk:sub(closingPos)
                log(string.format("  Added %d POOLEDENV section(s) to track\n", #entry.pooledEnvs))
            end
        end
        
        log(">>> Chunk BEFORE replaceGroupFlagsInChunk (first 500 chars):\n" .. chunk:sub(1, 500) .. "\n")
        
        -- Replace GROUP_FLAGS in chunk with template groups
        if templateGroupFlags then
            chunk = replaceGroupFlagsInChunk(chunk, templateGroupFlags)
        end
        
        log(">>> Chunk AFTER replaceGroupFlagsInChunk (first 500 chars):\n" .. chunk:sub(1, 500) .. "\n")
        
        r.SetTrackStateChunk(t, chunk, false)
        
        local checkAfter = r.GetMediaTrackInfo_Value(t, "I_GROUPFLAGS")
        log(string.format(">>> After SetTrackStateChunk: I_GROUPFLAGS = 0x%X (%d)\n", checkAfter, checkAfter))
        
        postprocessTrackCopyRelink(t, settings.copyMedia)
        
        r.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", mixDepth)
        r.SetMediaTrackInfo_Value(t, "I_RECARM", 0)
        r.SetMediaTrackInfo_Value(t, "B_SHOWINMIXER", 1)
        r.SetMediaTrackInfo_Value(t, "B_SHOWINTCP", 1)
        
        if (_G.__mr_offset or 0) ~= 0 then
            shiftTrackItemsBy(t, _G.__mr_offset)
        end
        
        local color = effective_rgb24(t)
        if color ~= 0 then r.SetTrackColor(t, color) end
        
        return t
    end
end

-- ===== NORMALIZATION FUNCTIONS =====

scanRegions = function()
    local regions = {}
    local _, numMarkers, numRegions = r.CountProjectMarkers(0)
    
    for i = 0, numMarkers + numRegions - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = r.EnumProjectMarkers(i)
        if isrgn then
            regions[#regions + 1] = {
                pos = pos,
                fin = rgnend,
                name = name or ("Region " .. (markrgnindexnumber + 1))
            }
        end
    end
    
    return regions
end

local function getItemsInTimeRange(track, startTime, endTime, lane)
    local items = {}
    local itemCount = r.CountTrackMediaItems(track)
    
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local itemLane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        
        if lane == nil or itemLane == lane then
            local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local itemEnd = pos + len
            
            if pos < endTime and itemEnd > startTime then
                items[#items + 1] = item
            end
        end
    end
    
    return items
end

-- ===== GROUP-BASED NORMALIZATION (v1.2) =====
-- Helper: Measures the loudest item in a list and returns its level
-- lufsSettings is optional: {segmentSize, percentile, threshold}
local function measureLoudestItem(items, measureType, lufsSettings)
    if #items == 0 then return nil end

    -- Get LUFS settings (use profile settings or defaults)
    local segmentSize, percentile, threshold
    if lufsSettings then
        segmentSize = lufsSettings.segmentSize or DEFAULT_LUFS_SEGMENT_SIZE
        percentile = lufsSettings.percentile or DEFAULT_LUFS_PERCENTILE
        threshold = lufsSettings.threshold or DEFAULT_LUFS_THRESHOLD
    else
        segmentSize = DEFAULT_LUFS_SEGMENT_SIZE
        percentile = DEFAULT_LUFS_PERCENTILE
        threshold = DEFAULT_LUFS_THRESHOLD
    end
    
    local loudestValue = nil
    local loudestItem = nil
    
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            if source then
                local currentValue = nil
                
                if measureType == "Peak" or measureType == "RMS" then
                    -- Peak/RMS measurement using AudioAccessor (measures actual item content)
                    local accessor = r.CreateTakeAudioAccessor(take)
                    if accessor then
                        local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
                        local samplerate = r.GetMediaSourceSampleRate(source)
                        local n_ch = r.GetMediaSourceNumChannels(source)
                        local totalSamples = math.floor(itemLen * samplerate)

                        local maxPeak = 0
                        local sumSquared = 0
                        local numSamples = 0
                        -- Use larger buffer for better performance (64k samples)
                        local bufferSize = 65536
                        local buffer = r.new_array(n_ch * bufferSize)
                        local pos = 0

                        while pos < totalSamples do
                            local toRead = math.min(bufferSize, totalSamples - pos)
                            r.GetAudioAccessorSamples(accessor, samplerate, n_ch, pos / samplerate, toRead, buffer)

                            for i = 1, toRead * n_ch do
                                local val = math.abs(buffer[i])
                                if val > maxPeak then maxPeak = val end
                                if measureType == "RMS" then
                                    sumSquared = sumSquared + (val * val)
                                    numSamples = numSamples + 1
                                end
                            end

                            pos = pos + toRead
                        end

                        r.DestroyAudioAccessor(accessor)

                        if measureType == "Peak" then
                            currentValue = maxPeak
                        else -- RMS
                            if numSamples > 0 then
                                currentValue = math.sqrt(sumSquared / numSamples)
                            end
                        end

                        log(string.format("      %s measure: %.4f (%.2f dB), len=%.2fs\n",
                            measureType, currentValue or 0,
                            currentValue and currentValue > 0 and (20 * math.log(currentValue, 10)) or -999,
                            itemLen))
                    end
                else -- LUFS
                    -- LUFS-M max measurement with configurable percentile
                    local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local takeOffset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
                    local measurements = {}

                    local pos = 0
                    while pos < itemLen do
                        local segEnd = math.min(pos + segmentSize, itemLen)

                        local volumeMultiplier = r.CalculateNormalization(
                            source,
                            LUFS_TYPE_M_MAX,
                            -23.0,  -- Temporary reference
                            takeOffset + pos,
                            takeOffset + segEnd
                        )

                        if volumeMultiplier and volumeMultiplier > 0 then
                            local gainDB = 20 * math.log(volumeMultiplier, 10)
                            local currentLUFS = -23.0 - gainDB

                            -- Only add segments ABOVE threshold (ignore silent/quiet segments)
                            if currentLUFS > threshold then
                                measurements[#measurements + 1] = currentLUFS
                            end
                        end

                        pos = pos + segmentSize
                    end

                    if #measurements > 0 then
                        table.sort(measurements)
                        local pctFrac = percentile / 100.0
                        local percentileIndex = math.floor(#measurements * pctFrac)
                        if percentileIndex < 1 then percentileIndex = 1 end
                        currentValue = measurements[percentileIndex]
                    end
                end
                
                -- Compare with loudest so far
                if currentValue then
                    if not loudestValue or currentValue > loudestValue then
                        loudestValue = currentValue
                        loudestItem = item
                    end
                end
            end
        end
    end
    
    return loudestValue, loudestItem
end

-- Helper: Applies gain to all items in a group
local function applyGainToItems(items, gainDB)
    if #items == 0 then return end
    
    local gainLinear = 10 ^ (gainDB / 20.0)
    
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local currentVol = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
            local newVol = currentVol * gainLinear
            r.SetMediaItemTakeInfo_Value(take, "D_VOL", newVol)
            r.UpdateItemInProject(item)
        end
    end
end

-- Group-based LUFS normalization: Find loudest item, apply same gain to all
-- lufsSettings is optional: {segmentSize, percentile, threshold}
local function normalizeLUFSGroup(items, targetLUFS, lufsSettings)
    if #items == 0 then return false end

    log(string.format("    Measuring loudest of %d items...\n", #items))

    local loudestLUFS, loudestItem = measureLoudestItem(items, "LUFS", lufsSettings)

    if not loudestLUFS then
        log("    No valid LUFS measurements\n")
        return false
    end

    local pct = (lufsSettings and lufsSettings.percentile) or DEFAULT_LUFS_PERCENTILE
    log(string.format("    Loudest item: %.1f LUFS (%dth percentile)\n", loudestLUFS, pct))

    -- Calculate required gain
    local gainDB = targetLUFS - loudestLUFS
    log(string.format("    Applying %.2f dB gain to all %d items\n", gainDB, #items))

    -- Apply gain to ALL items
    applyGainToItems(items, gainDB)

    return true
end

-- Group-based Peak/RMS normalization: Find loudest item, apply same gain to all
local function normalizePeakOrRMSGroup(items, targetDB, useRMS)
    if #items == 0 then return false end
    
    local measureType = useRMS and "RMS" or "Peak"
    log(string.format("    Measuring loudest %s of %d items...\n", measureType, #items))
    
    local loudestValue, loudestItem = measureLoudestItem(items, measureType)
    
    if not loudestValue or loudestValue <= 0 then
        log("    No valid measurements\n")
        return false
    end
    
    local currentDB = 20 * math.log(loudestValue, 10)
    log(string.format("    Loudest item: %.2f dB\n", currentDB))
    
    -- Calculate required gain
    local gainDB = targetDB - currentDB
    log(string.format("    Applying %.2f dB gain to all %d items\n", gainDB, #items))
    
    -- Apply gain to ALL items
    applyGainToItems(items, gainDB)
    
    return true
end

-- ===== OLD PER-ITEM NORMALIZATION (DEPRECATED - kept for reference) =====
local function normalizeLUFS(items, targetLUFS)
    if #items == 0 then return false end

    local successCount = 0
    local failCount = 0

    -- Use default LUFS settings (this function is deprecated)
    local segmentSize = DEFAULT_LUFS_SEGMENT_SIZE
    local pctValue = DEFAULT_LUFS_PERCENTILE

    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            if source then
                -- Get item length
                local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")

                -- Measure LUFS-M max in segments
                local measurements = {}

                local pos = 0
                while pos < itemLen do
                    local segmentEnd = math.min(pos + segmentSize, itemLen)

                    -- Measure LUFS-M max for this segment
                    local volumeMultiplier = r.CalculateNormalization(
                        source,
                        LUFS_TYPE_M_MAX,  -- Type 4 = LUFS-M max
                        targetLUFS,
                        pos,
                        segmentEnd
                    )

                    if volumeMultiplier and volumeMultiplier > 0 then
                        -- Convert multiplier to current LUFS
                        local gainDB = 20 * math.log(volumeMultiplier, 10)
                        local currentLUFS = targetLUFS - gainDB
                        measurements[#measurements + 1] = currentLUFS
                    end

                    pos = pos + segmentSize
                end

                if #measurements > 0 then
                    -- Sort measurements
                    table.sort(measurements)

                    -- Get percentile
                    local percentile = pctValue / 100.0
                    local percentileIndex = math.floor(#measurements * percentile)
                    if percentileIndex < 1 then percentileIndex = 1 end
                    local percentileValue = measurements[percentileIndex]

                    log(string.format("    LUFS-M segments: %d, %dth percentile: %.1f LUFS\n",
                        #measurements, pctValue, percentileValue))
                    
                    -- Calculate gain needed from percentile to target
                    local gainDB = targetLUFS - percentileValue
                    local volumeMultiplier = 10 ^ (gainDB / 20)
                    
                    r.SetMediaItemTakeInfo_Value(take, "D_VOL", volumeMultiplier)
                    r.UpdateItemInProject(item)
                    successCount = successCount + 1
                else
                    log("    No valid LUFS measurements\n")
                    failCount = failCount + 1
                end
            else
                failCount = failCount + 1
            end
        else
            failCount = failCount + 1
        end
    end
    
    return successCount > 0
end

local function normalizePeakOrRMS(items, targetDB, useRMS)
    if #items == 0 then return false end
    
    local successCount = 0
    local failCount = 0
    
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local source = r.GetMediaItemTake_Source(take)
            if source then
                -- Scan audio to find peak/RMS
                local accessor = r.CreateTakeAudioAccessor(take)
                if accessor then
                    local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local samplerate = r.GetMediaSourceSampleRate(source)
                    local n_ch = r.GetMediaSourceNumChannels(source)
                    local totalSamples = math.floor(itemLen * samplerate)
                    
                    local maxPeak = 0
                    local sumSquared = 0
                    local numSamples = 0
                    local buffer = r.new_array(n_ch * 4096)
                    local pos = 0
                    
                    while pos < totalSamples do
                        local toRead = math.min(4096, totalSamples - pos)
                        r.GetAudioAccessorSamples(accessor, samplerate, n_ch, pos / samplerate, toRead, buffer)
                        
                        for i = 0, toRead - 1 do
                            for c = 0, n_ch - 1 do
                                local val = math.abs(buffer[i * n_ch + c + 1])
                                maxPeak = math.max(maxPeak, val)
                                if useRMS then
                                    sumSquared = sumSquared + (val * val)
                                    numSamples = numSamples + 1
                                end
                            end
                        end
                        
                        pos = pos + toRead
                    end
                    
                    r.DestroyAudioAccessor(accessor)
                    
                    local currentLevel = maxPeak
                    if useRMS and numSamples > 0 then
                        currentLevel = math.sqrt(sumSquared / numSamples)
                    end
                    
                    if currentLevel and currentLevel > 0 then
                        -- Calculate needed gain
                        local currentDB = 20 * math.log(currentLevel, 10)
                        local gainDB = targetDB - currentDB
                        local gainLinear = 10 ^ (gainDB / 20.0)
                        
                        -- Get current item volume and multiply
                        local currentVol = r.GetMediaItemInfo_Value(item, "D_VOL")
                        local newVol = currentVol * gainLinear
                        
                        log(string.format("    Item: current=%.2f dB, target=%.2f dB, gain=%.2f dB, newVol=%.4f\n", 
                            currentDB, targetDB, gainDB, newVol))
                        
                        -- IMPORTANT: D_VOL is an ITEM parameter, not a TAKE parameter!
                        r.SetMediaItemInfo_Value(item, "D_VOL", newVol)
                        r.UpdateItemInProject(item)
                        successCount = successCount + 1
                    else
                        log(string.format("    Item: silent or no audio (level=%.6f)\n", currentLevel or 0))
                        failCount = failCount + 1
                    end
                else
                    failCount = failCount + 1
                end
            else
                failCount = failCount + 1
            end
        else
            failCount = failCount + 1
        end
    end
    
    return successCount > 0
end

-- ===== CALIBRATION FUNCTIONS =====

-- Gets LUFS settings from a profile, falling back to defaults
local function getProfileLufsSettings(profile)
    if profile and profile.lufsSegmentSize then
        return profile.lufsSegmentSize, profile.lufsPercentile, profile.lufsThreshold
    end
    return DEFAULT_LUFS_SEGMENT_SIZE, DEFAULT_LUFS_PERCENTILE, DEFAULT_LUFS_THRESHOLD
end

-- Measures Peak and LUFS of the currently selected item in REAPER
local function measureSelectedItemLoudness(segmentSize, percentile, threshold)
    -- 1. Get selected item
    local item = r.GetSelectedMediaItem(0, 0)
    if not item then
        return nil, "No item selected"
    end

    -- 2. Get take and source
    local take = r.GetActiveTake(item)
    if not take then
        return nil, "Item has no active take"
    end

    local source = r.GetMediaItemTake_Source(take)
    if not source then
        return nil, "Could not get audio source"
    end

    -- 3. Item boundaries
    local itemLen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    local takeOffset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

    -- 4. Measure Peak using AudioAccessor (accounts for item boundaries correctly)
    local accessor = r.CreateTakeAudioAccessor(take)
    if not accessor then
        return nil, "Could not create audio accessor"
    end

    local samplerate = r.GetMediaSourceSampleRate(source)
    local numChannels = r.GetMediaSourceNumChannels(source)
    local totalSamples = math.floor(itemLen * samplerate)

    local maxPeak = 0
    local bufferSize = 4096
    local buffer = r.new_array(numChannels * bufferSize)
    local pos = 0

    while pos < totalSamples do
        local samplesToRead = math.min(bufferSize, totalSamples - pos)
        r.GetAudioAccessorSamples(accessor, samplerate, numChannels, pos / samplerate, samplesToRead, buffer)

        for i = 1, samplesToRead * numChannels do
            local val = math.abs(buffer[i])
            if val > maxPeak then
                maxPeak = val
            end
        end

        pos = pos + samplesToRead
    end

    r.DestroyAudioAccessor(accessor)

    local peakDB = -math.huge
    if maxPeak > 0 then
        peakDB = 20 * math.log(maxPeak, 10)
    end

    -- 5. Measure LUFS using segment-based approach
    local measurements = {}
    local pos = 0
    while pos < itemLen do
        local segmentEnd = math.min(pos + segmentSize, itemLen)

        local volumeMultiplier = r.CalculateNormalization(
            source,
            LUFS_TYPE_M_MAX,
            -23.0,  -- Temporary reference
            takeOffset + pos,
            takeOffset + segmentEnd
        )

        if volumeMultiplier and volumeMultiplier > 0 then
            local gainDB = 20 * math.log(volumeMultiplier, 10)
            local currentLUFS = -23.0 - gainDB

            -- Only add segments ABOVE threshold (ignore silent/quiet segments)
            if currentLUFS > threshold then
                measurements[#measurements + 1] = currentLUFS
            end
        end

        pos = pos + segmentSize
    end

    local lufsDB = -math.huge
    if #measurements > 0 then
        table.sort(measurements)
        local percentileIdx = math.floor(#measurements * (percentile / 100.0))
        if percentileIdx < 1 then percentileIdx = 1 end
        lufsDB = measurements[percentileIdx]
    else
        return nil, "No valid LUFS measurements (item too quiet?)"
    end

    -- 6. Account for item gain AND take gain (AudioAccessor returns raw audio, ignores both)
    local itemGain = r.GetMediaItemInfo_Value(item, "D_VOL")
    local takeGain = r.GetMediaItemTakeInfo_Value(take, "D_VOL")

    if itemGain and itemGain > 0 then
        local itemGainDB = 20 * math.log(itemGain, 10)
        peakDB = peakDB + itemGainDB
        lufsDB = lufsDB + itemGainDB
    end

    if takeGain and takeGain > 0 then
        local takeGainDB = 20 * math.log(takeGain, 10)
        peakDB = peakDB + takeGainDB
        lufsDB = lufsDB + takeGainDB
    end

    -- 8. Get item name
    local _, itemName = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if itemName == "" then
        itemName = "Unnamed Item"
    end

    return {
        name = itemName,
        peak = peakDB,
        lufs = lufsDB,
        offset = math.floor(peakDB - lufsDB + 0.5)
    }, nil
end

-- Opens the calibration dialog and performs initial measurement
local function openCalibrationWindow()
    -- Initialize with defaults
    calibrationWindow.segmentSize = DEFAULT_LUFS_SEGMENT_SIZE
    calibrationWindow.percentile = DEFAULT_LUFS_PERCENTILE
    calibrationWindow.threshold = DEFAULT_LUFS_THRESHOLD
    calibrationWindow.selectedProfileIdx = 0
    calibrationWindow.newProfileName = ""
    calibrationWindow.errorMsg = ""

    -- Measure
    local result, err = measureSelectedItemLoudness(
        calibrationWindow.segmentSize,
        calibrationWindow.percentile,
        calibrationWindow.threshold
    )

    if not result then
        calibrationWindow.open = true
        calibrationWindow.errorMsg = err
        calibrationWindow.itemName = ""
        return
    end

    calibrationWindow.open = true
    calibrationWindow.itemName = result.name
    calibrationWindow.measuredPeak = result.peak
    calibrationWindow.measuredLUFS = result.lufs
    calibrationWindow.calculatedOffset = result.offset
end

-- Re-measures with updated settings
local function remeasureCalibration()
    local result, err = measureSelectedItemLoudness(
        calibrationWindow.segmentSize,
        calibrationWindow.percentile,
        calibrationWindow.threshold
    )

    if not result then
        calibrationWindow.errorMsg = err
        return
    end

    calibrationWindow.errorMsg = ""
    calibrationWindow.itemName = result.name
    calibrationWindow.measuredPeak = result.peak
    calibrationWindow.measuredLUFS = result.lufs
    calibrationWindow.calculatedOffset = result.offset
end

-- Saves or updates the profile with calibration data
local function saveCalibrationToProfile()
    local offset = calibrationWindow.calculatedOffset
    local peak = math.floor(calibrationWindow.measuredPeak + 0.5)  -- Use measured peak, rounded

    if calibrationWindow.selectedProfileIdx > 0 then
        -- Update existing profile
        local profile = normProfiles[calibrationWindow.selectedProfileIdx]
        profile.offset = offset
        profile.defaultPeak = peak
        profile.lufsSegmentSize = calibrationWindow.segmentSize
        profile.lufsPercentile = calibrationWindow.percentile
        profile.lufsThreshold = calibrationWindow.threshold
    else
        -- Create new profile
        local newName = calibrationWindow.newProfileName:match("^%s*(.-)%s*$")  -- trim
        table.insert(normProfiles, {
            name = newName,
            offset = offset,
            defaultPeak = peak,
            lufsSegmentSize = calibrationWindow.segmentSize,
            lufsPercentile = calibrationWindow.percentile,
            lufsThreshold = calibrationWindow.threshold,
        })
    end

    -- Save to INI
    saveSharedNormalizationSettings()
end

local function getNextAvailableLane(track)
    local maxLane = -1
    local itemCount = r.CountTrackMediaItems(track)
    
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        maxLane = math.max(maxLane, lane)
    end
    
    return maxLane + 1
end

local function setOnlyLaneActive(track, targetLane)
    r.SetMediaTrackInfo_Value(track, "I_PLAY_LANES", 2)
    
    local itemCount = r.CountTrackMediaItems(track)
    local existingLanes = {}
    
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        existingLanes[lane] = true
    end
    
    for lane, _ in pairs(existingLanes) do
        r.SetMediaTrackInfo_Value(track, "C_LANEPLAYS:" .. lane, 0)
    end
    
    r.SetMediaTrackInfo_Value(track, "C_LANEPLAYS:" .. targetLane, 1)
end

local function setLaneName(track, lane, name)
    if not validTrack(track) then return end
    
    -- Lane names are stored in track chunk, not via direct API
    local ok, chunk = r.GetTrackStateChunk(track, "", false)
    if not ok then return end
    
    -- Find or create LANENAME line for this lane
    local lanePattern = "\nLANENAME " .. lane .. " "
    local existingLine = chunk:match(lanePattern .. "([^\n]*)")
    
    if existingLine then
        -- Replace existing lane name
        chunk = chunk:gsub(lanePattern .. "[^\n]*", lanePattern .. name)
    else
        -- Add new lane name after PLAY_LANES or at end of track properties
        local insertPos = chunk:find("\n%s*<ITEM") or chunk:find("\n%s*>")
        if insertPos then
            local before = chunk:sub(1, insertPos - 1)
            local after = chunk:sub(insertPos)
            chunk = before .. "\nLANENAME " .. lane .. " " .. name .. after
        end
    end
    
    r.SetTrackStateChunk(track, chunk, false)
end

local function splitAllItemsAtRegions(regions, targetLanes, singleTrack)
    if #regions == 0 then return end
    
    local lanesToSplit = {}
    if type(targetLanes) == "table" then
        for lane, _ in pairs(targetLanes) do
            lanesToSplit[#lanesToSplit + 1] = lane
        end
    else
        lanesToSplit = {targetLanes}
    end
    
    r.Main_OnCommand(40042, 0)
    
    for i = 1, #regions do
        r.Main_OnCommand(40289, 0)
        
        local selectedCount = 0
        
        -- If singleTrack is provided, only work on that track
        if singleTrack and validTrack(singleTrack) then
            local itemCount = r.CountTrackMediaItems(singleTrack)
            for itemIdx = 0, itemCount - 1 do
                local item = r.GetTrackMediaItem(singleTrack, itemIdx)
                local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                
                for _, targetLane in ipairs(lanesToSplit) do
                    if lane == targetLane then
                        r.SetMediaItemSelected(item, true)
                        selectedCount = selectedCount + 1
                        break
                    end
                end
            end
        else
            -- Original behavior: work on all tracks
            for trackIdx = 0, r.CountTracks(0) - 1 do
                local track = r.GetTrack(0, trackIdx)
                local itemCount = r.CountTrackMediaItems(track)
                for itemIdx = 0, itemCount - 1 do
                    local item = r.GetTrackMediaItem(track, itemIdx)
                    local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                    
                    for _, targetLane in ipairs(lanesToSplit) do
                        if lane == targetLane then
                            r.SetMediaItemSelected(item, true)
                            selectedCount = selectedCount + 1
                            break
                        end
                    end
                end
            end
        end
        
        r.Main_OnCommand(r.NamedCommandLookup("_SWS_SELNEXTREG"), 0)
        r.Main_OnCommand(40061, 0)
    end
    
    r.Main_OnCommand(40289, 0)
    r.GetSet_LoopTimeRange2(0, true, false, 0, 0, false)
    r.UpdateArrange()
end

normalizeTrack = function(track, normalizationType, targetValue, regions, targetLane, profile)
    if not validTrack(track) then return false end

    -- normalizationType: "LUFS", "Peak", or "RMS"
    -- targetValue: LUFS value for LUFS, dB for Peak/RMS
    -- targetLane: optional - if provided, use this lane instead of finding highest
    -- profile: optional - normalization profile for LUFS settings

    -- Build LUFS settings from profile (or use defaults)
    local lufsSettings = nil
    if profile and profile.lufsSegmentSize then
        lufsSettings = {
            segmentSize = profile.lufsSegmentSize,
            percentile = profile.lufsPercentile,
            threshold = profile.lufsThreshold
        }
    end

    -- Get item count at start (needed for take reset even when targetLane is provided)
    local itemCount = r.CountTrackMediaItems(track)

    -- Find highest lane on this track if not provided
    if not targetLane then
        targetLane = 0
        for i = 0, itemCount - 1 do
            local item = r.GetTrackMediaItem(track, i)
            local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
            targetLane = math.max(targetLane, lane)
        end
    end

    log(string.format("  Working on lane %d\n", targetLane))

    -- Activate the new lane
    log(string.format("  Activating lane %d\n", targetLane))
    setOnlyLaneActive(track, targetLane)

    -- Verify lane is active
    local laneActive = r.GetMediaTrackInfo_Value(track, "C_LANEPLAYS:" .. targetLane)
    log(string.format("  Lane %d active status: %d\n", targetLane, laneActive))

    -- Reset all item gains AND take volumes to 0dB BEFORE measuring/normalizing
    log("  Resetting all item gains and take volumes to 0dB...\n")
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        -- Reset Item Gain (D_VOL on item)
        r.SetMediaItemInfo_Value(item, "D_VOL", 1.0)  -- 1.0 = 0dB
        -- Reset Take Volume (D_VOL on take)
        local take = r.GetActiveTake(item)
        if take then
            r.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)  -- 1.0 = 0dB
        end
    end

    -- Step 6: Normalize per region (WITHOUT splitting!)
    if settings.processPerRegion and #regions > 0 then
        log(string.format("  Processing %d regions\n", #regions))

        -- Normalize per region (GROUP-BASED: all items in region get same gain)
        for ridx, region in ipairs(regions) do
            local items = getItemsInTimeRange(track, region.pos, region.fin, targetLane)
            log(string.format("    Region %d: found %d items to normalize\n", ridx, #items))
            if #items > 0 then
                if normalizationType == "Peak" then
                    normalizePeakOrRMSGroup(items, targetValue, false)
                elseif normalizationType == "RMS" then
                    normalizePeakOrRMSGroup(items, targetValue, true)
                else  -- LUFS
                    normalizeLUFSGroup(items, targetValue, lufsSettings)
                end
            end
        end
    else
        -- Normalize full track (GROUP-BASED: all items get same gain)
        local allItems = getItemsInTimeRange(track, 0, math.huge, targetLane)
        log(string.format("  Normalizing %d items on full track\n", #allItems))
        if normalizationType == "Peak" then
            normalizePeakOrRMSGroup(allItems, targetValue, false)
        elseif normalizationType == "RMS" then
            normalizePeakOrRMSGroup(allItems, targetValue, true)
        else  -- LUFS
            normalizeLUFSGroup(allItems, targetValue, lufsSettings)
        end
    end
    
    -- Step 7: Delete items between regions (using time selection + Xenakios)
    if settings.processPerRegion and #regions > 0 and settings.deleteBetweenRegions then
        log("  Deleting items between regions (lane " .. targetLane .. " only)...\n")
        
        -- Build list of gaps between regions
        local gaps = {}
        for i = 1, #regions - 1 do
            local gapStart = regions[i].fin
            local gapEnd = regions[i + 1].pos
            if gapEnd > gapStart then
                gaps[#gaps + 1] = {start = gapStart, finish = gapEnd}
            end
        end
        
        -- Also consider before first region and after last region
        if #regions > 0 then
            local projectLength = r.GetProjectLength(0)
            if regions[1].pos > 0 then
                table.insert(gaps, 1, {start = 0, finish = regions[1].pos})
            end
            if regions[#regions].fin < projectLength then
                gaps[#gaps + 1] = {start = regions[#regions].fin, finish = projectLength}
            end
        end
        
        -- Get Xenakios command
        local cmd = r.NamedCommandLookup("_XENAKIOS_TSADEL")
        if cmd == 0 then
            log("  WARNING: _XENAKIOS_TSADEL command not found (SWS required)\n")
        else
            -- Unselect all items ONCE before processing gaps
            r.Main_OnCommand(40289, 0) -- Unselect all items first
            
            -- For each gap, create time selection and delete items
            for _, gap in ipairs(gaps) do
                -- Set time selection to gap
                r.GetSet_LoopTimeRange2(0, true, false, gap.start, gap.finish, false)
                
                -- Select only items on targetLane
                local itemCount = r.CountTrackMediaItems(track)
                for i = 0, itemCount - 1 do
                    local item = r.GetTrackMediaItem(track, i)
                    local itemLane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                    if itemLane == targetLane then
                        r.SetMediaItemSelected(item, true)
                    end
                end
                
                -- Delete selected items in time selection
                r.Main_OnCommand(cmd, 0)
                log(string.format("    Deleted in gap %.2f-%.2f\n", gap.start, gap.finish))
            end
            
            -- Clear time selection and item selection
            r.GetSet_LoopTimeRange2(0, true, false, 0, 0, false)
            r.Main_OnCommand(40289, 0)
            log(string.format("  Processed %d gaps between regions\n", #gaps))
        end
        
    end

    -- Make sure new lane is STILL active at the very end
    log("  Final lane activation\n")
    setOnlyLaneActive(track, targetLane)

    return true
end

normalizeTrackDirect = function(track, normalizationType, targetValue, regions, profile)
    if not validTrack(track) then return false end

    -- normalizationType: "LUFS", "Peak", or "RMS"
    -- targetValue: LUFS value for LUFS, dB for Peak/RMS
    -- profile: optional - normalization profile for LUFS settings

    -- Build LUFS settings from profile (or use defaults)
    local lufsSettings = nil
    if profile and profile.lufsSegmentSize then
        lufsSettings = {
            segmentSize = profile.lufsSegmentSize,
            percentile = profile.lufsPercentile,
            threshold = profile.lufsThreshold
        }
    end

    log("  Direct normalization (no new lane)\n")
    
    -- Find active lane
    local activeLane = 0
    local itemCount = r.CountTrackMediaItems(track)
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
        local lanePlay = r.GetMediaTrackInfo_Value(track, "C_LANEPLAYS:" .. lane)
        if lanePlay == 1 then
            activeLane = lane
            break
        end
    end
    
    log(string.format("  Active lane: %d\n", activeLane))
    
    -- Get all items on the active lane only
    local allItems = getItemsInTimeRange(track, 0, math.huge, activeLane)
    if #allItems == 0 then
        log("  No items found on active lane\n")
        return false
    end
    
    log(string.format("  Found %d items on active lane\n", #allItems))

    -- Reset all item gains AND take volumes to 0dB BEFORE measuring/normalizing
    log("  Resetting all item gains and take volumes to 0dB...\n")
    for i = 0, itemCount - 1 do
        local item = r.GetTrackMediaItem(track, i)
        -- Reset Item Gain (D_VOL on item)
        r.SetMediaItemInfo_Value(item, "D_VOL", 1.0)  -- 1.0 = 0dB
        -- Reset Take Volume (D_VOL on take)
        local take = r.GetActiveTake(item)
        if take then
            r.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)  -- 1.0 = 0dB
        end
    end

    if settings.processPerRegion and #regions > 0 then
        log(string.format("  Processing %d regions\n", #regions))
        
        -- Normalize per region (only active lane) (GROUP-BASED: all items in region get same gain)
        for ridx, region in ipairs(regions) do
            local items = getItemsInTimeRange(track, region.pos, region.fin, activeLane)
            log(string.format("    Region %d (%s): %d items\n", ridx, region.name, #items))
            if #items > 0 then
                if normalizationType == "Peak" then
                    normalizePeakOrRMSGroup(items, targetValue, false)
                elseif normalizationType == "RMS" then
                    normalizePeakOrRMSGroup(items, targetValue, true)
                else  -- LUFS
                    normalizeLUFSGroup(items, targetValue, lufsSettings)
                end
            end
        end
        
        -- Delete items between regions using time selections
        if settings.deleteBetweenRegions then
            log(string.format("  Deleting items between regions on active lane %d...\n", activeLane))
            
            -- Build list of gaps between regions
            local gaps = {}
            for i = 1, #regions - 1 do
                local gapStart = regions[i].fin
                local gapEnd = regions[i + 1].pos
                if gapEnd > gapStart then
                    gaps[#gaps + 1] = {start = gapStart, finish = gapEnd}
                end
            end
            
            -- Also consider before first region and after last region
            if #regions > 0 then
                local projectLength = r.GetProjectLength(0)
                if regions[1].pos > 0 then
                    table.insert(gaps, 1, {start = 0, finish = regions[1].pos})
                end
                if regions[#regions].fin < projectLength then
                    gaps[#gaps + 1] = {start = regions[#regions].fin, finish = projectLength}
                end
            end
            
            -- Get Xenakios command
            local cmd = r.NamedCommandLookup("_XENAKIOS_TSADEL")
            if cmd == 0 then
                log("  WARNING: _XENAKIOS_TSADEL command not found (SWS required)\n")
                return
            end
            
            -- For each gap, create time selection and delete items
            for _, gap in ipairs(gaps) do
                -- Set time selection to gap
                r.GetSet_LoopTimeRange2(0, true, false, gap.start, gap.finish, false)
                
                -- Select only items on active lane
                r.Main_OnCommand(40289, 0) -- Unselect all items first
                local itemCount = r.CountTrackMediaItems(track)
                for i = 0, itemCount - 1 do
                    local item = r.GetTrackMediaItem(track, i)
                    local itemLane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                    if itemLane == activeLane then
                        r.SetMediaItemSelected(item, true)
                    end
                end
                
                -- Delete selected items in time selection
                -- _XENAKIOS_TSADEL only deletes items that are within the time selection
                r.Main_OnCommand(cmd, 0)
                log(string.format("    Processed gap %.2f-%.2f\n", gap.start, gap.finish))
            end
            
            -- Clear time selection and item selection
            r.GetSet_LoopTimeRange2(0, true, false, 0, 0, false)
            r.Main_OnCommand(40289, 0) -- Unselect all items
            log(string.format("  Processed %d gaps between regions\n", #gaps))
        end
    else
        -- Normalize entire track (GROUP-BASED: all items get same gain)
        log("  Normalizing entire track\n")
        if normalizationType == "Peak" then
            normalizePeakOrRMSGroup(allItems, targetValue, false)
        elseif normalizationType == "RMS" then
            normalizePeakOrRMSGroup(allItems, targetValue, true)
        else  -- LUFS
            normalizeLUFSGroup(allItems, targetValue, lufsSettings)
        end
    end

    r.UpdateArrange()
    return true
end

-- ===== COMMIT MAPPINGS =====
-- Performance notes (v2.3.1):
--   - firstNew chunk cached once before duplicate loop (avoids repeated GetTrackStateChunk)
--   - UpdateArrange() removed from normalization inner loops (already inside PreventUIRefresh)
--   - Peak building and media sweep scoped to allCreatedTracks only
--   - Normalization lookup pre-computed once via trackNormLookup table
local function commitMappings()
    _G.__mr_offset = 0.0
    
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    
    local ops, matchedSet = {}, {}
    local allCreatedTracks = {}  -- collect all new tracks for targeted peak building
    
    for i, mixTr in ipairs(mixTargets) do
        if validTrack(mixTr) then
            local slots = map[i] or {0}
            local chosen = {}
            local chosenSlots = {}  -- original slot indices
            for si, ri in ipairs(slots) do
                if ri and ri > 0 and recSources[ri] then
                    chosen[#chosen + 1] = ri
                    chosenSlots[#chosenSlots + 1] = si
                end
            end
            if #chosen > 0 then
                ops[#ops + 1] = {mixIndex = i, mixTr = mixTr, recIdxs = chosen, slotIdxs = chosenSlots}
            end
        end
    end
    
    -- Phase 1: Map tracks
    for _, op in ipairs(ops) do
        local mixTr = op.mixTr
        if not validTrack(mixTr) then goto continue end
        
        local mixName = nameCache[mixTr] or trName(mixTr)
        local mixColor = effective_rgb24(mixTr)
        local mixIdx = op.mixIndex
        
        -- Get keep name settings for each slot
        keepMap[mixIdx] = keepMap[mixIdx] or {}
        fxMap[mixIdx] = fxMap[mixIdx] or {}  -- NEW: Initialize fxMap
        
        local firstEntry = recSources[op.recIdxs[1]]

        -- Multi-RPP: Use time-based offset directly
        if multiRppSettings.enabled and firstEntry.rppMeasureOffset and firstEntry.rppMeasureOffset > 0 then
            local rppIdx = firstEntry.rppIndex or 1
            local rpp = rppQueue[rppIdx]
            if rpp then
                _G.__mr_offset = rpp.timeOffset or 0
            end
        else
            _G.__mr_offset = 0.0
        end

        local firstNew = replaceMixWithSourceAtSamePosition(firstEntry, mixTr)
        
        -- First track: use settings from original slot index
        local firstOrigSlot = op.slotIdxs and op.slotIdxs[1] or 1
        local firstKeepName = (keepMap[mixIdx][firstOrigSlot] == true)
        local firstKeepFX = (fxMap[mixIdx][firstOrigSlot] == true)
        local firstName
        if editState.slotNames[mixIdx] and editState.slotNames[mixIdx][firstOrigSlot] then
            firstName = editState.slotNames[mixIdx][firstOrigSlot]
        elseif firstKeepName then
            firstName = firstEntry.name or mixName
        else
            firstName = mixName
        end
        local created = {}
        
        if validTrack(firstNew) then
            setTrName(firstNew, firstName)
            if mixColor ~= 0 then r.SetTrackColor(firstNew, mixColor) end
            
            -- Only copy template FX if Keep FX is NOT checked
            if not firstKeepFX then
                copyFX(mixTr, firstNew)
            end
            
            cloneSends(mixTr, firstNew)
            copyTrackControls(mixTr, firstNew)
            rewireReceives(mixTr, firstNew)
            created[#created + 1] = firstNew
        end
        
        r.DeleteTrack(mixTr)
        matchedSet[mixTr] = true
        
        -- Cache firstNew chunk once for all duplicates (avoid repeated expensive serialization)
        local firstNewChunk = nil
        if validTrack(firstNew) then
            _, firstNewChunk = r.GetTrackStateChunk(firstNew, "", false)
        end

        for s = 2, #op.recIdxs do
            local prev = created[#created]
            local insertIdx = prev and (idxOf(prev) + 1) or r.CountTracks(0)
            
            r.InsertTrackAtIndex(insertIdx, true)
            local newTr = r.GetTrack(0, insertIdx)
            local entry = recSources[op.recIdxs[s]]

            -- Multi-RPP: Use time-based offset directly
            if multiRppSettings.enabled and entry.rppMeasureOffset and entry.rppMeasureOffset > 0 then
                local rppIdx = entry.rppIndex or 1
                local rpp = rppQueue[rppIdx]
                if rpp then
                    _G.__mr_offset = rpp.timeOffset or 0
                end
            else
                _G.__mr_offset = 0.0
            end

            -- Each duplicate gets its own keep name setting
            local origSlot = op.slotIdxs and op.slotIdxs[s] or s
            local slotKeepName = (keepMap[mixIdx][origSlot] == true)
            local slotName

            -- Check for user-defined name override first
            if editState.slotNames[mixIdx] and editState.slotNames[mixIdx][origSlot] then
                slotName = editState.slotNames[mixIdx][origSlot]
            elseif slotKeepName then
                slotName = entry.name or (mixName .. " " .. s)
            else
                slotName = mixName .. " " .. s
            end
            
            if entry and entry.src == "file" then
                newTr = createTrackWithAudioFileAtIndex(insertIdx, 0, entry.file, slotName)
                -- Set groups from firstNew on file import duplicates
                if validTrack(newTr) and firstNewChunk then
                    local firstGroupFlags = firstNewChunk:match("(GROUP_FLAGS[^\r\n]*)")
                    if firstGroupFlags then
                        local _, newChunk = r.GetTrackStateChunk(newTr, "", false)
                        newChunk = replaceGroupFlagsInChunk(newChunk, firstGroupFlags)
                        r.SetTrackStateChunk(newTr, newChunk, false)
                        log(">>> Duplicate file import: set groups from firstNew\n")
                    end
                end
            elseif entry then
                local chunk = sanitizeChunk(entry.chunk)
                chunk = fixChunkMediaPaths(chunk, settings.copyMedia)
                
                -- Replace GROUP_FLAGS in chunk with groups from firstNew (using cached chunk)
                if firstNewChunk then
                    local firstGroupFlags = firstNewChunk:match("(GROUP_FLAGS[^\r\n]*)")
                    if firstGroupFlags then
                        chunk = replaceGroupFlagsInChunk(chunk, firstGroupFlags)
                        log(">>> Duplicate rpp import: replaced groups from firstNew\n")
                    end
                end
                
                r.SetTrackStateChunk(newTr, chunk, false)
                postprocessTrackCopyRelink(newTr, settings.copyMedia)
                
                r.SetMediaTrackInfo_Value(newTr, "I_FOLDERDEPTH", 0)
                setTrName(newTr, slotName)
            end
            
            if validTrack(newTr) then
                if mixColor ~= 0 then r.SetTrackColor(newTr, mixColor) end
                if validTrack(firstNew) then
                    -- Check Keep FX setting for this slot
                    local slotKeepFX = (fxMap[mixIdx][s] == true)
                    
                    -- Only copy FX from first track if Keep FX is NOT checked
                    if not slotKeepFX then
                        copyFX(firstNew, newTr)
                    end
                    
                    cloneSends(firstNew, newTr)
                    copyTrackControls(firstNew, newTr)
                end
                r.SetMediaTrackInfo_Value(newTr, "I_RECARM", 0)
                r.SetMediaTrackInfo_Value(newTr, "B_SHOWINMIXER", 1)
                r.SetMediaTrackInfo_Value(newTr, "B_SHOWINTCP", 1)
                created[#created + 1] = newTr
            end
        end
        
        -- Collect created tracks for targeted peak building
        for _, tr in ipairs(created) do
            allCreatedTracks[#allCreatedTracks + 1] = tr
        end

        ::continue::
    end

    -- Delete unused tracks
    if settings.deleteUnused then
        local sel = {}
        for i = 0, r.CountTracks(0) - 1 do
            local t = r.GetTrack(0, i)
            if validTrack(t) then
                sel[t] = r.IsTrackSelected(t) or false
            end
        end
        
        r.Main_OnCommand(40297, 0)
        
        for _, tr in ipairs(mixTargets) do
            if validTrack(tr) then
                local name = nameCache[tr] or trName(tr)
                if not matchedSet[tr] and not protectedSet[name] then
                    r.SetTrackSelected(tr, true)
                end
            end
        end
        
        r.Main_OnCommand(40005, 0)
        r.Main_OnCommand(40297, 0)
        
        for t, was in pairs(sel) do
            if was and validTrack(t) then
                r.SetTrackSelected(t, true)
            end
        end
    end
    
    r.PreventUIRefresh(-1)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    
    if settings.copyMedia then
        -- Sweep only newly created tracks instead of entire project
        local media_dir = getProjectMediaDir()
        for _, tr in ipairs(allCreatedTracks) do
            if validTrack(tr) then
                local itemCount = r.CountTrackMediaItems(tr)
                for ii = 0, itemCount - 1 do
                    local item = r.GetTrackMediaItem(tr, ii)
                    local take_cnt = r.CountTakes(item)
                    for t = 0, take_cnt - 1 do
                        local take = r.GetTake(item, t)
                        if take then
                            local src = r.GetMediaItemTake_Source(take)
                            if src then
                                local _, cur = r.GetMediaSourceFileName(src, "")
                                if cur and #cur > 0 then
                                    local basename = getBasename(cur)
                                    local destPath = joinPath(media_dir, basename)
                                    if normalizePath(cur) ~= normalizePath(destPath) then
                                        if fileExists(cur) then
                                            if copyFile(cur, destPath) then
                                                local newSrc = r.PCM_Source_CreateFromFile(destPath)
                                                if newSrc then
                                                    r.SetMediaItemTake_Source(take, newSrc)
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Phase 2: Normalize (if enabled)
    if normalizeMode then
        r.PreventUIRefresh(1)
        
        log("\n=== Starting Normalization Phase ===\n")
        
        local regions = settings.processPerRegion and scanRegions() or {}
        log(string.format("Regions found: %d\n", #regions))
        
        -- Build a list of tracks that were actually mapped
        local mappedTrackNames = {}
        for _, op in ipairs(ops) do
            local mixName = nameCache[op.mixTr] or trName(op.mixTr)
            mappedTrackNames[mixName] = true
        end
        
        -- Rebuild track list (tracks have changed)
        local currentTracks = {}
        for i = 0, r.CountTracks(0) - 1 do
            local tr = r.GetTrack(0, i)
            if validTrack(tr) then
                currentTracks[#currentTracks + 1] = tr
            end
        end
        
        log(string.format("Current tracks: %d\n", #currentTracks))

        -- Table to store target lane per track (for createNewLane mode)
        local trackLanes = {}

        -- Pre-compute normalization lookup: track -> normData (avoids duplicate O(N*M) matching)
        local trackNormLookup = {}  -- tr -> normData
        for idx, tr in ipairs(currentTracks) do
            local trackName = trName(tr)
            for i, mixTr in ipairs(mixTargets) do
                local mixName = nameCache[mixTr] or trName(mixTr)
                local isMatch = false
                if trackName == mixName then
                    isMatch = true
                else
                    local baseName = trackName:match("^(.-)%s*%(%d+%)$")
                    if baseName and baseName == mixName then
                        isMatch = true
                    end
                end
                if isMatch and normMap[i] and normMap[i][1] then
                    local hasMapping = false
                    local slots = map[i] or {0}
                    for _, ri in ipairs(slots) do
                        if ri and ri > 0 then
                            hasMapping = true
                            break
                        end
                    end
                    if hasMapping then
                        trackNormLookup[tr] = normMap[i][1]
                        break
                    end
                end
            end
        end

        -- NEW: If createNewLane is enabled, duplicate lanes for tracks that will be normalized
        if settings.createNewLane then
            log("\n=== Duplicating lanes for normalized tracks ===\n")

            -- Build list of tracks that will actually be normalized
            local tracksToNormalize = {}
            for idx, tr in ipairs(currentTracks) do
                local normData = trackNormLookup[tr]
                if normData and normData.profile ~= "-" then
                    local itemCount = r.CountTrackMediaItems(tr)
                    if itemCount > 0 then
                        tracksToNormalize[#tracksToNormalize + 1] = tr
                    end
                end
            end
            
            log(string.format("  Found %d tracks to normalize\n", #tracksToNormalize))
            
            -- Only proceed if there are tracks to normalize
            if #tracksToNormalize > 0 then
                -- Select only tracks that will be normalized
                r.Main_OnCommand(40297, 0) -- Unselect all tracks
                for _, tr in ipairs(tracksToNormalize) do
                    r.SetTrackSelected(tr, true)
                end
                
                -- Set selected tracks to Fixed Item Lane mode
                r.Main_OnCommand(42431, 0)
                log("  Set selected tracks to Fixed Item Lane mode\n")

                -- Duplicate active lanes to new lanes (works on selected tracks)
                r.Main_OnCommand(42505, 0)
                log("  Duplicated active lanes to new lanes\n")

                -- Switch to next lane (the new duplicated one) - works on selected tracks
                r.Main_OnCommand(42482, 0)
                log("  Switched to play only next lane (new duplicated lane)\n")
                
                -- Store the highest lane for each track
                for _, tr in ipairs(tracksToNormalize) do
                    local maxLane = 0
                    local itemCount = r.CountTrackMediaItems(tr)
                    for i = 0, itemCount - 1 do
                        local item = r.GetTrackMediaItem(tr, i)
                        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                        maxLane = math.max(maxLane, lane)
                    end
                    if maxLane > 0 then
                        trackLanes[tr] = maxLane
                        log(string.format("  Track '%s': Target lane %d\n", trName(tr), maxLane))
                    end
                end
                
                r.Main_OnCommand(40297, 0) -- Unselect all tracks
                r.Main_OnCommand(40289, 0) -- Unselect all items
                log("  Lane duplication complete\n")
            end
        end
        
        -- Normalize tracks that have a profile assigned AND were mapped
        local normalizedCount = 0
        for idx, tr in ipairs(currentTracks) do
            local trackName = trName(tr)
            local normData = trackNormLookup[tr]

            if normData and normData.profile ~= "-" then
                -- Check if it's a special Peak/RMS profile or a regular LUFS profile
                local normType, targetValue, usedProfile

                if normData.profile == "Peak" then
                    normType = "Peak"
                    targetValue = normData.targetPeak
                    log(string.format("\nNormalizing: %s\n", trackName))
                    log(string.format("  Type: Peak @ %.1f dB\n", targetValue))
                elseif normData.profile == "RMS" then
                    normType = "RMS"
                    targetValue = normData.targetPeak
                    log(string.format("\nNormalizing: %s\n", trackName))
                    log(string.format("  Type: RMS @ %.1f dB\n", targetValue))
                else
                    -- Regular LUFS profile
                    local profile = getProfileByName(normData.profile)
                    if profile then
                        normType = "LUFS"
                        targetValue = calculateLUFS(normData.targetPeak, profile.offset)
                        usedProfile = profile  -- Store for passing to normalizeTrack
                        log(string.format("\nNormalizing: %s\n", trackName))
                        log(string.format("  Profile: %s, Peak: %.1f dB, LUFS: %.1f\n",
                            normData.profile, normData.targetPeak, targetValue))
                    end
                end

                if normType and targetValue then
                    if settings.createNewLane then
                        -- Create new lane and normalize - use stored target lane
                        local targetLane = trackLanes[tr]  -- Get stored lane from duplication
                        local success = normalizeTrack(tr, normType, targetValue, regions, targetLane, usedProfile)
                        if success then
                            normalizedCount = normalizedCount + 1
                            log("  - Success (new lane)\n")
                        else
                            log("  Failed\n")
                        end
                    else
                        -- Direct normalization on existing items
                        local success = normalizeTrackDirect(tr, normType, targetValue, regions, usedProfile)
                        if success then
                            normalizedCount = normalizedCount + 1
                            log("  - Success (direct)\n")
                        else
                            log("  Failed\n")
                        end
                    end
                end
            end

        end
        
        log(string.format("\n=== Normalization Complete: %d tracks ===\n", normalizedCount))
        
        -- Name normalized lanes ONCE at the end (safer than during normalization)
        if settings.createNewLane then
            log("\n=== Naming normalized lanes ===\n")
            for _, tr in ipairs(currentTracks) do
                if validTrack(tr) then
                    local maxLane = 0
                    local itemCount = r.CountTrackMediaItems(tr)
                    for i = 0, itemCount - 1 do
                        local item = r.GetTrackMediaItem(tr, i)
                        local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
                        maxLane = math.max(maxLane, lane)
                    end
                    if maxLane > 0 then
                        setLaneName(tr, maxLane, "Normalized")
                    end
                end
            end
            log("  Lanes named successfully\n")
        end
        
        r.PreventUIRefresh(-1)
        r.TrackList_AdjustWindows(false)
    end

    r.UpdateArrange()
    r.UpdateTimeline()

    -- Generate peaks (only for newly created tracks, not entire project)
    for _, tr in ipairs(allCreatedTracks) do
        if validTrack(tr) then
            local itemCount = r.CountTrackMediaItems(tr)
            for i = 0, itemCount - 1 do
                local item = r.GetTrackMediaItem(tr, i)
                local take = r.GetActiveTake(item)
                if take then
                    local src = r.GetMediaItemTake_Source(take)
                    if src then
                        r.PCM_Source_BuildPeaks(src, 0)
                    end
                end
            end
        end
    end

    -- Hide fixed item lanes (Command 42432: Toggle fixed item lanes)
    if normalizeMode and settings.createNewLane then
        local lanesVisible = r.GetToggleCommandState(42432) == 1
        if lanesVisible then
            r.Main_OnCommand(42432, 0)  -- Toggle off = hide lanes
            log("\n=== Hidden fixed item lanes ===\n")
        end
    end
    
    -- Minimize all tracks
    r.PreventUIRefresh(1)
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        r.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", 26)
    end
    r.PreventUIRefresh(-1)
    r.TrackList_AdjustWindows(false)

    r.Undo_EndBlock("RAPID v" .. VERSION .. ": Commit", -1)

    uiFlags.close = true
end

-- ===== UI: MAIN WINDOW =====
local function drawUI_body()
    -- ===== HEADER: Title + Mode + Settings/Help =====
    r.ImGui_Text(ctx, "RAPID v" .. VERSION)
    r.ImGui_SameLine(ctx)
    r.ImGui_Dummy(ctx, 12, 0)
    r.ImGui_SameLine(ctx)

    r.ImGui_Text(ctx, "Mode:")
    r.ImGui_SameLine(ctx)

    local importChanged, importVal = r.ImGui_Checkbox(ctx, "Import", settings.importMode)
    if importChanged then
        settings.importMode = importVal
        importMode = importVal
        saveIni()

        -- When switching from Import to Normalize-only, load tracks for normalize mode
        if not importVal and normalizeMode and #tracks == 0 then
            loadTracksWithItems()
            if settings.autoMatchProfilesOnImport then
                autoMatchProfilesDirect()
            end
        end

        -- When enabling Import mode, rebuild mix targets
        if importVal and #mixTargets == 0 then
            rebuildMixTargets()
            map = {}
            normMap = {}
        end
    end

    r.ImGui_SameLine(ctx)
    local normalizeChanged, normalizeVal = r.ImGui_Checkbox(ctx, "Normalize", settings.normalizeMode)
    if normalizeChanged then
        settings.normalizeMode = normalizeVal
        normalizeMode = normalizeVal
        saveIni()

        -- When enabling Normalize-only mode (Import already off), load tracks
        if normalizeVal and not importMode and #tracks == 0 then
            loadTracksWithItems()
            if settings.autoMatchProfilesOnImport then
                autoMatchProfilesDirect()
            end
        end
    end

    if not importMode and not normalizeMode then
        r.ImGui_TextColored(ctx, 0xFF0000FF, " ERROR: At least one mode required!")
        settings.importMode = true
        importMode = true
        return
    end

    -- Settings/Help right-aligned in header
    r.ImGui_SameLine(ctx, r.ImGui_GetWindowWidth(ctx) - 120)
    if sec_button("Settings##header") then
        uiFlags.settings = true
    end
    r.ImGui_SameLine(ctx)
    if sec_button("Help##header") then
        uiFlags.help = true
    end

    r.ImGui_Separator(ctx)

    -- ===== IMPORT MODE UI =====
    if importMode then

    -- Toolbar row 1: Load sources + Auto-match + Multi-RPP toggle
    if not multiRppSettings.enabled then
        -- Single RPP mode
        if r.ImGui_Button(ctx, "Load .RPP") then
            local ok, p = r.GetUserFileNameForRead("", "Select Recording .RPP", ".rpp")
            if ok then
                recSources = {}
                loadRecRPP(p)
                applyLastMap()

                if settings.autoMatchTracksOnImport then
                    autosuggest()
                end
                if settings.autoMatchProfilesOnImport and normalizeMode then
                    autoMatchProfiles()
                end
            end
        end
    else
        -- Multi-RPP mode: Load multiple RPPs
        if r.ImGui_Button(ctx, "Add .RPP##multi") then
            if HAVE_JS then
                -- JS_ReaScriptAPI multi-file dialog
                local ok, payload = r.JS_Dialog_BrowseForOpenFiles("Select Recording .RPP files", "", "", "RPP files (*.rpp)\0*.rpp\0", true)
                if ok and payload and payload ~= "" then
                    local files = parseSelectedFiles(payload)
                    for _, p in ipairs(files) do
                        loadRppToQueue(p)
                    end
                    applyLastMap()
                    if settings.autoMatchTracksOnImport then autosuggest() end
                    if settings.autoMatchProfilesOnImport and normalizeMode then autoMatchProfiles() end
                end
            else
                -- Fallback: single file dialog
                local ok, p = r.GetUserFileNameForRead("", "Select Recording .RPP", ".rpp")
                if ok then
                    loadRppToQueue(p)
                    applyLastMap()
                    if settings.autoMatchTracksOnImport then autosuggest() end
                    if settings.autoMatchProfilesOnImport and normalizeMode then autoMatchProfiles() end
                end
            end
        end

        r.ImGui_SameLine(ctx)
        if sec_button("Clear Queue##multi") then
            clearRppQueue()
            multiMap = {}
            multiNormMap = {}
        end
    end

    r.ImGui_SameLine(ctx)

    -- Multi-RPP toggle
    local multiChanged, multiVal = r.ImGui_Checkbox(ctx, "Multi-RPP", multiRppSettings.enabled)
    if multiChanged then
        multiRppSettings.enabled = multiVal
        if not multiVal then
            -- Switching back to single mode: use first queued RPP or clear
            if #rppQueue > 0 then
                recPath.rpp = rppQueue[1].path
                recPath.dir = rppQueue[1].dir
                recSources = {}
                loadRecRPP(rppQueue[1].path)
            end
            rppQueue = {}
            multiMap = {}
            multiNormMap = {}
        else
            -- Switching to multi mode: convert current single RPP to queue
            if recPath.rpp and recPath.rpp ~= "" then
                rppQueue = {}
                multiMap = {}
                multiNormMap = {}
                loadRppToQueue(recPath.rpp)
            end
        end
    end

    if not multiRppSettings.enabled then
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Load audio files") then
            local before = #recSources
            loadRecFiles()
            if #recSources > before then
                applyLastMap()

                if settings.autoMatchTracksOnImport then
                    autosuggest()
                end
                if settings.autoMatchProfilesOnImport and normalizeMode then
                    autoMatchProfiles()
                end
            end
        end
    end

    r.ImGui_SameLine(ctx)
    r.ImGui_Dummy(ctx, 8, 0)
    r.ImGui_SameLine(ctx)

    if sec_button("Auto-match Tracks##import") then
        autosuggest()
    end

    if normalizeMode then
        r.ImGui_SameLine(ctx)
        if sec_button("Auto-match Profiles##import") then
            autoMatchProfiles()
        end
    end

    if not multiRppSettings.enabled and recPath.rpp then
        r.ImGui_SameLine(ctx)
        if sec_button("Import Markers/Tempomap") then
            importMarkersTempoPostCommit()
        end
    end

    -- RPP path info (single mode) or queue info (multi mode)
    if not multiRppSettings.enabled then
        if recPath.rpp then
            r.ImGui_SameLine(ctx)
            r.ImGui_TextColored(ctx, theme.text_dim, "  RPP: " .. recPath.rpp)
        end
    else
        r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, theme.text_dim, string.format("  %d RPPs queued", #rppQueue))
    end

    r.ImGui_Separator(ctx)

    -- ===== MULTI-RPP QUEUE PANEL =====
    if multiRppSettings.enabled and #rppQueue > 0 then
        -- Collapsible queue panel
        if r.ImGui_CollapsingHeader(ctx, "RPP Queue##multirpp", r.ImGui_TreeNodeFlags_DefaultOpen()) then
            -- Settings row
            r.ImGui_Text(ctx, "Gap:")
            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, 100)
            local gapChanged, gapVal = r.ImGui_InputInt(ctx, "measures##gap", multiRppSettings.gapInMeasures)
            if gapChanged then
                multiRppSettings.gapInMeasures = math.max(0, gapVal)
                recalculateQueueOffsets()
            end

            r.ImGui_SameLine(ctx)
            r.ImGui_Dummy(ctx, 8, 0)
            r.ImGui_SameLine(ctx)

            local regChanged, regVal = r.ImGui_Checkbox(ctx, "Create regions", multiRppSettings.createRegions)
            if regChanged then multiRppSettings.createRegions = regVal end

            r.ImGui_SameLine(ctx)
            local markChanged, markVal = r.ImGui_Checkbox(ctx, "Import Markers + Tempo Map", multiRppSettings.importMarkers)
            if markChanged then multiRppSettings.importMarkers = markVal end

            r.ImGui_SameLine(ctx)
            local laneChanged, laneVal = r.ImGui_Checkbox(ctx, "Align lanes", multiRppSettings.alignLanes)
            if laneChanged then multiRppSettings.alignLanes = laneVal end

            -- Queue table
            local queueFlags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()
            if r.ImGui_BeginTable(ctx, "rppqueue", 6, queueFlags) then
                local COLFIX = r.ImGui_TableColumnFlags_WidthFixed()
                r.ImGui_TableSetupColumn(ctx, "##drag", COLFIX, 25)
                r.ImGui_TableSetupColumn(ctx, "##", COLFIX, 30)
                r.ImGui_TableSetupColumn(ctx, "Name")
                r.ImGui_TableSetupColumn(ctx, "Measures", COLFIX, 70)
                r.ImGui_TableSetupColumn(ctx, "Offset", COLFIX, 70)
                r.ImGui_TableSetupColumn(ctx, "##remove", COLFIX, 25)
                r.ImGui_TableHeadersRow(ctx)

                local toRemove = nil
                local dragSource = nil
                local dragTarget = nil

                for i, rpp in ipairs(rppQueue) do
                    r.ImGui_TableNextRow(ctx)

                    -- Drag handle column
                    r.ImGui_TableSetColumnIndex(ctx, 0)
                    r.ImGui_PushID(ctx, "drag" .. i)

                    -- Drag source
                    r.ImGui_Button(ctx, "=##draghandle")
                    if r.ImGui_BeginDragDropSource(ctx, r.ImGui_DragDropFlags_None()) then
                        r.ImGui_SetDragDropPayload(ctx, "RPP_QUEUE_ITEM", tostring(i))
                        r.ImGui_Text(ctx, rpp.name)
                        r.ImGui_EndDragDropSource(ctx)
                        dragSource = i
                    end

                    -- Drag target (on the row)
                    if r.ImGui_BeginDragDropTarget(ctx) then
                        local rv, payload = r.ImGui_AcceptDragDropPayload(ctx, "RPP_QUEUE_ITEM")
                        if rv then
                            dragTarget = i
                            local srcIdx = tonumber(payload)
                            if srcIdx and srcIdx ~= i then
                                moveRppInQueue(srcIdx, i)
                            end
                        end
                        r.ImGui_EndDragDropTarget(ctx)
                    end

                    r.ImGui_PopID(ctx)

                    -- Index column
                    r.ImGui_TableSetColumnIndex(ctx, 1)
                    r.ImGui_Text(ctx, tostring(i))

                    -- Name column (editable)
                    r.ImGui_TableSetColumnIndex(ctx, 2)
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    local nameChanged, newName = r.ImGui_InputText(ctx, "##name" .. i, rpp.name)
                    if nameChanged then rpp.name = newName end

                    -- Measures column
                    r.ImGui_TableSetColumnIndex(ctx, 3)
                    r.ImGui_Text(ctx, tostring(rpp.lengthInMeasures))

                    -- Offset column
                    r.ImGui_TableSetColumnIndex(ctx, 4)
                    r.ImGui_TextColored(ctx, theme.text_dim, "M" .. rpp.measureOffset)

                    -- Remove button
                    r.ImGui_TableSetColumnIndex(ctx, 5)
                    if sec_button("x##remove" .. i) then
                        toRemove = i
                    end
                end

                r.ImGui_EndTable(ctx)

                -- Handle removal after table iteration
                if toRemove then
                    removeRppFromQueue(toRemove)
                end
            end

            -- Total info
            if #rppQueue > 0 then
                local totalMeasures = rppQueue[#rppQueue].measureOffset + rppQueue[#rppQueue].lengthInMeasures
                r.ImGui_TextColored(ctx, theme.text_dim,
                    string.format("Total: %d measures | %d tracks",
                        totalMeasures, #recSources))
            end
        end

        r.ImGui_Separator(ctx)
    end

    -- Calculate available height for scrollable table
    local window_h = r.ImGui_GetWindowHeight(ctx)
    local cursor_y = r.ImGui_GetCursorPosY(ctx)
    local footer_height = 90  -- v2.2: compact footer (options + action row)
    local table_height = window_h - cursor_y - footer_height

    local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg() |
                  r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_ScrollY()

    -- ===== MULTI-RPP COLUMN MAPPING TABLE =====
    if multiRppSettings.enabled and #rppQueue > 0 then

    -- Columns: [Lock] [Template] [RPP1] [RPP2] ... [RPPn] [Normalize?] [Peak?]
    local numRpps = #rppQueue
    local numColumns = 3 + numRpps  -- Lock + Color + Template + RPP columns
    if normalizeMode then numColumns = numColumns + 2 end  -- + Normalize + Peak

    local scrollFlags = flags | r.ImGui_TableFlags_ScrollX()

    if r.ImGui_BeginTable(ctx, "multimaptable", numColumns, scrollFlags, 0, table_height) then
        local COLFIX = r.ImGui_TableColumnFlags_WidthFixed()

        r.ImGui_TableSetupColumn(ctx, "##lock", COLFIX, 25.0)
        r.ImGui_TableSetupColumn(ctx, "##color", COLFIX, 18.0)
        r.ImGui_TableSetupColumn(ctx, "Template", COLFIX, 150.0)

        for rppIdx, rpp in ipairs(rppQueue) do
            r.ImGui_TableSetupColumn(ctx, rpp.name .. "##rpp" .. rppIdx, COLFIX, 130.0)
        end

        if normalizeMode then
            r.ImGui_TableSetupColumn(ctx, "Normalize", COLFIX, 120.0)
            r.ImGui_TableSetupColumn(ctx, "Peak dB", COLFIX, 80.0)
        end

        r.ImGui_TableSetupScrollFreeze(ctx, 3, 1)  -- Freeze Lock + Color + Template columns
        r.ImGui_TableHeadersRow(ctx)

        -- Auto-match button row
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        r.ImGui_TableSetColumnIndex(ctx, 2)
        if sec_button("Match All##multi") then
            multiRppAutoMatchAll()
            if normalizeMode then autoMatchProfilesMulti() end
        end

        for rppIdx = 1, numRpps do
            r.ImGui_TableSetColumnIndex(ctx, 2 + rppIdx)
            if sec_button("Match##rpp" .. rppIdx) then
                multiRppAutoMatchColumn(rppIdx)
            end
        end

        if normalizeMode then
            r.ImGui_TableSetColumnIndex(ctx, 2 + numRpps + 1)
            if sec_button("Match##multinorm") then
                autoMatchProfilesMulti()
            end
        end

        -- Track mapping rows
        for i, tr in ipairs(mixTargets) do
            if not validTrack(tr) then goto nextMixRow end

            local trackName = nameCache[tr] or trName(tr)
            local isLocked = protectedSet[trackName] and true or false
            local isFolder = not isLeafCached(tr)

            -- Delete unused: hide unmapped unlocked tracks
            if settings.deleteUnused then
                local hasAnyMapping = false
                if multiMap[i] then
                    for _, v in pairs(multiMap[i]) do
                        if v and v > 0 then hasAnyMapping = true; break end
                    end
                end
                if not hasAnyMapping and not isLocked and not isFolder then
                    goto nextMixRow
                end
            end

            r.ImGui_TableNextRow(ctx)

            -- Lock column
            r.ImGui_TableSetColumnIndex(ctx, 0)
            local lockChanged, lockVal = r.ImGui_Checkbox(ctx, "##lock_" .. i, isLocked)
            if lockChanged then
                protectedSet[trackName] = lockVal or nil
                saveProtected()
            end

            -- Color swatch column
            r.ImGui_TableSetColumnIndex(ctx, 1)
            do
                local rgb = trackCache.color[tr] or 0
                local u32 = u32_from_rgb24(rgb)
                local dl = r.ImGui_GetWindowDrawList(ctx)
                local x, y = r.ImGui_GetCursorScreenPos(ctx)
                local swh = (settings.swatch_size or 12)
                r.ImGui_DrawList_AddRectFilled(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, u32, 3.0)
                r.ImGui_DrawList_AddRect(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, 0xFF000000, 3.0, 0, 1.0)
                r.ImGui_Dummy(ctx, swh + 4, swh + 2)
            end

            -- Template name column (editable via double-click, same as single-RPP)
            r.ImGui_TableSetColumnIndex(ctx, 2)
            local displayName = trackName .. (isFolder and " (Folder)" or "")
            local editKey = "multi_" .. i

            if editState.track == editKey then
                -- Edit mode: inline InputText
                r.ImGui_SetNextItemWidth(ctx, -1)
                local changed, newBuf = r.ImGui_InputText(ctx, "##multiDestName_" .. i,
                    editState.buf, r.ImGui_InputTextFlags_AutoSelectAll())
                editState.buf = newBuf
                if not r.ImGui_IsItemActive(ctx) and not r.ImGui_IsItemDeactivated(ctx) then
                    r.ImGui_SetKeyboardFocusHere(ctx, -1)
                end
                if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
                    editState.track = nil
                    editState.buf = ""
                elseif r.ImGui_IsItemDeactivated(ctx) then
                    local trimmed = (editState.buf or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        r.GetSetMediaTrackInfo_String(tr, "P_NAME", trimmed, true)
                        nameCache[tr] = trimmed
                    end
                    editState.track = nil
                    editState.buf = ""
                end
            else
                -- Display mode: Selectable with double-click to edit
                r.ImGui_SetNextItemWidth(ctx, -1)
                if r.ImGui_Selectable(ctx, displayName .. "##multiDest_" .. i, false,
                        r.ImGui_SelectableFlags_AllowDoubleClick()) then
                    if r.ImGui_IsMouseDoubleClicked(ctx, r.ImGui_MouseButton_Left()) then
                        editState.track = editKey
                        editState.buf = trackName
                    end
                end
            end

            -- RPP columns (dropdown per RPP)
            for rppIdx, rpp in ipairs(rppQueue) do
                r.ImGui_TableSetColumnIndex(ctx, 2 + rppIdx)

                multiMap[i] = multiMap[i] or {}
                local currentIdx = multiMap[i][rppIdx] or 0
                local currentName = "-"
                if currentIdx > 0 and rpp.tracks[currentIdx] then
                    currentName = rpp.tracks[currentIdx].name
                end

                -- Build assignment lookup for this RPP column
                local assignedInCol = {}
                for mi, row in pairs(multiMap) do
                    if row[rppIdx] and row[rppIdx] > 0 then
                        assignedInCol[row[rppIdx]] = mi
                    end
                end

                r.ImGui_SetNextItemWidth(ctx, -1)
                if r.ImGui_BeginCombo(ctx, "##map_" .. i .. "_" .. rppIdx, currentName) then
                    -- "-" option (unmapped)
                    if r.ImGui_Selectable(ctx, "-##unmap_" .. i .. "_" .. rppIdx, currentIdx == 0) then
                        multiMap[i][rppIdx] = 0
                    end

                    -- Track options from this RPP (with dimming for assigned tracks)
                    for j, track in ipairs(rpp.tracks) do
                        local ownerMix = assignedInCol[j]
                        local isMine = (ownerMix == i)
                        local dim = ownerMix and not isMine
                        local pushed = false

                        if dim then
                            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), 0.5)
                            pushed = true
                        end

                        local label = track.name
                        if ownerMix and not isMine then
                            local ownerName = (validTrack(mixTargets[ownerMix]) and (nameCache[mixTargets[ownerMix]] or trName(mixTargets[ownerMix]))) or "?"
                            label = label .. " [-> " .. ownerName .. "]"
                        end

                        local uniqueLabel = label .. "##" .. i .. "_" .. rppIdx .. "_" .. j
                        if r.ImGui_Selectable(ctx, uniqueLabel, currentIdx == j) then
                            -- If stealing from another template track, clear that assignment
                            if ownerMix and not isMine then
                                multiMap[ownerMix][rppIdx] = 0
                            end
                            multiMap[i][rppIdx] = j
                        end

                        if pushed then
                            r.ImGui_PopStyleVar(ctx)
                        end
                    end

                    r.ImGui_EndCombo(ctx)
                end
            end

            -- Normalize columns
            if normalizeMode then
                multiNormMap[i] = multiNormMap[i] or {profile = "-", targetPeak = -6}

                -- Profile dropdown
                r.ImGui_TableSetColumnIndex(ctx, 2 + numRpps + 1)
                r.ImGui_SetNextItemWidth(ctx, -1)
                local currentProfile = multiNormMap[i].profile

                if r.ImGui_BeginCombo(ctx, "##norm_" .. i, currentProfile) then
                    if r.ImGui_Selectable(ctx, "-##normoff_" .. i, currentProfile == "-") then
                        multiNormMap[i].profile = "-"
                    end
                    for _, p in ipairs(normProfiles) do
                        if r.ImGui_Selectable(ctx, p.name .. "##norm_" .. i, currentProfile == p.name) then
                            multiNormMap[i].profile = p.name
                            if p.defaultPeak then
                                multiNormMap[i].targetPeak = p.defaultPeak
                            end
                        end
                    end
                    r.ImGui_EndCombo(ctx)
                end

                -- Peak dB input
                r.ImGui_TableSetColumnIndex(ctx, 2 + numRpps + 2)
                r.ImGui_SetNextItemWidth(ctx, -1)
                local peakChanged, peakVal = r.ImGui_InputInt(ctx, "##peak_" .. i, multiNormMap[i].targetPeak)
                if peakChanged then
                    multiNormMap[i].targetPeak = peakVal
                end
            end

            ::nextMixRow::
        end

        r.ImGui_EndTable(ctx)
    end

    -- ===== SINGLE-RPP MAPPING TABLE =====
    else

    -- Dynamic column count based on auto-normalize setting
    -- Columns: [Sel] [Color] [Lock] [Template Destinations] [Rec Sources] [Keep name] [Keep FX] [Normalize?] [Peak?] [x]
    local numColumns = normalizeMode and 10 or 8

    if r.ImGui_BeginTable(ctx, "maptable", numColumns, flags, 0, table_height) then
        local COLFIX = r.ImGui_TableColumnFlags_WidthFixed()
        r.ImGui_TableSetupColumn(ctx, "Sel", COLFIX, 25.0)
        r.ImGui_TableSetupColumn(ctx, "##color", COLFIX, 18.0)  -- Color swatch (no title)
        r.ImGui_TableSetupColumn(ctx, "##lock", COLFIX, 25.0)  -- Lock column (drawn icon)
        r.ImGui_TableSetupColumn(ctx, "Template Destinations")  -- Mix tracks
        r.ImGui_TableSetupColumn(ctx, "Recording Sources")
        r.ImGui_TableSetupColumn(ctx, "Keep name", COLFIX, 80.0)
        r.ImGui_TableSetupColumn(ctx, "Keep FX", COLFIX, 80.0)
        
        -- Only show normalize columns if auto-normalize is enabled
        if normalizeMode then
            r.ImGui_TableSetupColumn(ctx, "Normalize", COLFIX, 120.0)
            r.ImGui_TableSetupColumn(ctx, "Peak dB", COLFIX, 80.0)
        end
        
        r.ImGui_TableSetupColumn(ctx, "x", COLFIX, 60.0)
        r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
        
        -- Custom clickable headers with toggle-all functionality
        r.ImGui_TableNextRow(ctx, r.ImGui_TableRowFlags_Headers())
        
        -- Column 0: Sel (clickable to toggle all)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        if r.ImGui_Selectable(ctx, "Sel##header", false) then
            -- Check if any rows are selected
            local anySelected = false
            for i, tr in ipairs(mixTargets) do
                local slots = map[i] or {0}
                for s = 1, math.max(1, #slots) do
                    local rowID = string.format("%d_%d", i, s)
                    if selectedRows[rowID] then
                        anySelected = true
                        break
                    end
                end
                if anySelected then break end
            end
            
            -- Toggle: If any selected, clear all. Otherwise, select all.
            if anySelected then
                selectedRows = {}
            else
                for i, tr in ipairs(mixTargets) do
                    local slots = map[i] or {0}
                    for s = 1, math.max(1, #slots) do
                        local rowID = string.format("%d_%d", i, s)
                        selectedRows[rowID] = true
                    end
                end
            end
        end
        
        -- Column 1: Color swatch (no header)
        r.ImGui_TableSetColumnIndex(ctx, 1)

        -- Column 2: Lock (clickable to toggle all protected) - draw lock icon
        r.ImGui_TableSetColumnIndex(ctx, 2)
        do
            local cx, cy = r.ImGui_GetCursorScreenPos(ctx)
            local colW = 25.0  -- fixed column width
            local lineH = r.ImGui_GetTextLineHeight(ctx)
            local dl = r.ImGui_GetWindowDrawList(ctx)
            local sz = 10  -- icon size
            local ix = cx + (colW - sz) * 0.5  -- center horizontally
            local iy = cy + (lineH - sz) * 0.5 + 1  -- center vertically
            local col = 0xAAAAAAFF  -- light gray
            -- Lock body (filled rect)
            r.ImGui_DrawList_AddRectFilled(dl, ix + 1, iy + 4, ix + sz - 1, iy + sz, col, 1.5)
            -- Lock shackle (arc on top)
            r.ImGui_DrawList_AddRect(dl, ix + 2.5, iy, ix + sz - 2.5, iy + 5.5, col, 2.0, 0, 1.5)
        end
        if r.ImGui_Selectable(ctx, "##lockheader", false) then
            -- Check if any tracks are protected
            local anyProtected = false
            for i, tr in ipairs(mixTargets) do
                local name = nameCache[tr] or trName(tr)
                if protectedSet[name] then
                    anyProtected = true
                    break
                end
            end
            
            -- Toggle all
            local newState = not anyProtected
            for i, tr in ipairs(mixTargets) do
                local name = nameCache[tr] or trName(tr)
                protectedSet[name] = newState or nil
            end
            saveProtected()
        end
        
        -- Column 3: Template Destinations
        r.ImGui_TableSetColumnIndex(ctx, 3)
        r.ImGui_Text(ctx, "Template Destinations")

        -- Column 4: Recording Sources
        r.ImGui_TableSetColumnIndex(ctx, 4)
        r.ImGui_Text(ctx, "Recording Sources")

        -- Column 5: Keep Name (clickable to toggle all)
        r.ImGui_TableSetColumnIndex(ctx, 5)
        if r.ImGui_Selectable(ctx, "Keep name##header", false) then
            -- Check if any Keep Name are checked (check keepMap per slot)
            local anyChecked = false
            for i, tr in ipairs(mixTargets) do
                local slots = map[i] or {0}
                for s = 1, math.max(1, #slots) do
                    if keepMap[i] and keepMap[i][s] then
                        anyChecked = true
                        break
                    end
                end
                if anyChecked then break end
            end
            
            -- Toggle all
            local newState = not anyChecked
            for i, tr in ipairs(mixTargets) do
                local slots = map[i] or {0}
                for s = 1, math.max(1, #slots) do
                    keepMap[i] = keepMap[i] or {}
                    keepMap[i][s] = newState or nil
                end
            end
        end
        
        -- Column 6: Keep FX (clickable to toggle all)
        r.ImGui_TableSetColumnIndex(ctx, 6)
        if r.ImGui_Selectable(ctx, "Keep FX##header", false) then
            local anyChecked = false
            for i, tr in ipairs(mixTargets) do
                local slots = map[i] or {0}
                for s = 1, math.max(1, #slots) do
                    if fxMap[i] and fxMap[i][s] then
                        anyChecked = true
                        break
                    end
                end
                if anyChecked then break end
            end
            
            local newState = not anyChecked
            for i, tr in ipairs(mixTargets) do
                local slots = map[i] or {0}
                for s = 1, math.max(1, #slots) do
                    fxMap[i] = fxMap[i] or {}
                    fxMap[i][s] = newState or nil
                end
            end
        end
        
        -- Remaining columns (normalize columns if enabled)
        if normalizeMode then
            r.ImGui_TableSetColumnIndex(ctx, 7)
            r.ImGui_Text(ctx, "Normalize")
            r.ImGui_TableSetColumnIndex(ctx, 8)
            r.ImGui_Text(ctx, "Peak dB")
            r.ImGui_TableSetColumnIndex(ctx, 9)
        else
            r.ImGui_TableSetColumnIndex(ctx, 7)
        end
        r.ImGui_Text(ctx, "x")
        
        local assignedTo = {}
        for mi = 1, #mixTargets do
            for s, ri in ipairs(map[mi] or {}) do
                if ri and ri > 0 then assignedTo[ri] = {mix = mi, slot = s} end
            end
        end
        
        local globalRowID = 0  -- Global counter for unique ImGui IDs
        
        -- Pre-compute which folders have at least one child with a source or locked child
        local folderHasContent = {}
        if settings.deleteUnused and #recSources > 0 then
            -- Walk backwards: if a track has source/is locked, mark all parent folders
            local parentStack = {}  -- stack of folder indices
            for i, tr in ipairs(mixTargets) do
                local fd = folderDepth(tr)
                if fd == 1 then
                    -- Folder start: push onto stack
                    parentStack[#parentStack + 1] = i
                end
                -- Check if this track contributes content
                local hasSource = false
                if map[i] then
                    for si = 1, #map[i] do
                        if map[i][si] and map[i][si] > 0 then hasSource = true; break end
                    end
                end
                local tn = nameCache[tr] or trName(tr)
                if hasSource or (protectedSet[tn] and true or false) then
                    -- Mark all parent folders as having content
                    for _, pi in ipairs(parentStack) do
                        folderHasContent[pi] = true
                    end
                end
                if fd < 0 then
                    -- Folder end: pop from stack (may pop multiple levels)
                    for _ = 1, math.abs(fd) do
                        if #parentStack > 0 then parentStack[#parentStack] = nil end
                    end
                end
            end
        end

        for i, tr in ipairs(mixTargets) do
            local slots = map[i] or {0}

            -- Check if this track (or any of its slots) has a source mapped
            local trackHasSource = false
            if map[i] then
                for si = 1, #map[i] do
                    if map[i][si] and map[i][si] > 0 then trackHasSource = true; break end
                end
            end
            local trackName = nameCache[tr] or trName(tr)
            local isLocked = protectedSet[trackName] and true or false
            local isFolder = not isLeafCached(tr)
            local hideRow
            if settings.deleteUnused and #recSources > 0 then
                if isFolder then
                    hideRow = not isLocked and not folderHasContent[i]
                else
                    hideRow = not trackHasSource and not isLocked
                end
            else
                hideRow = false
            end

            for s = 1, math.max(1, #slots) do
                globalRowID = globalRowID + 1  -- Increment for each row
                if hideRow then goto nextrow end
                r.ImGui_TableNextRow(ctx)
                
                -- Create unique row ID for selection tracking
                local rowID = string.format("%d_%d", i, s)
                local isSelected = selectedRows[rowID] or false
                
                -- Column 0: Select checkbox (NEW)
                r.ImGui_TableSetColumnIndex(ctx, 0)
                local selectChanged, selectValue = r.ImGui_Checkbox(ctx, "##sel_" .. globalRowID, isSelected)
                
                -- Drag-state selection (like in Stem Manager) - only when hovering
                if r.ImGui_IsItemHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
                    if dragState.sel == nil and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Left()) then
                        -- Start drag: toggle state
                        dragState.sel = not isSelected
                        selectedRows[rowID] = dragState.sel or nil
                        dragState.lastClicked = rowID
                    elseif dragState.sel ~= nil and dragState.sel ~= isSelected then
                        -- Dragging and this row has different state - apply drag state
                        selectedRows[rowID] = dragState.sel or nil
                    end
                end
                
                -- Handle Shift+Click for range selection (when checkbox clicked normally)
                if selectChanged then
                    local shiftDown = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())
                    
                    if shiftDown and dragState.lastClicked and dragState.lastClicked ~= rowID then
                        -- Range select
                        local allRowIDs = {}
                        for ti = 1, #mixTargets do
                            local tslots = map[ti] or {0}
                            for ts = 1, math.max(1, #tslots) do
                                allRowIDs[#allRowIDs + 1] = string.format("%d_%d", ti, ts)
                            end
                        end
                        
                        local startIdx, endIdx = nil, nil
                        for idx, id in ipairs(allRowIDs) do
                            if id == dragState.lastClicked then startIdx = idx end
                            if id == rowID then endIdx = idx end
                        end
                        
                        if startIdx and endIdx then
                            local from = math.min(startIdx, endIdx)
                            local to = math.max(startIdx, endIdx)
                            for idx = from, to do
                                selectedRows[allRowIDs[idx]] = true
                            end
                        end
                    else
                        -- Single toggle was already handled by dragState.sel
                        if dragState.sel == nil then
                            selectedRows[rowID] = selectValue or nil
                        end
                    end
                    
                    dragState.lastClicked = rowID
                end
                
                -- Column 1: Color swatch
                r.ImGui_TableSetColumnIndex(ctx, 1)
                local name = nameCache[tr] or trName(tr)
                do
                    local rgb = trackCache.color[tr] or 0
                    local u32 = u32_from_rgb24(rgb)
                    local dl = r.ImGui_GetWindowDrawList(ctx)
                    local x, y = r.ImGui_GetCursorScreenPos(ctx)
                    local swh = (settings.swatch_size or 12)
                    r.ImGui_DrawList_AddRectFilled(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, u32, 3.0)
                    r.ImGui_DrawList_AddRect(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, 0xFF000000, 3.0, 0, 1.0)
                    r.ImGui_Dummy(ctx, swh + 4, swh + 2)
                end

                -- Column 2: Lock checkbox
                r.ImGui_TableSetColumnIndex(ctx, 2)
                local checked = protectedSet[name] and true or false
                if s == 1 then
                    local ch, nv = r.ImGui_Checkbox(ctx, "##prot_" .. globalRowID, checked)

                    -- Drag-state for Lock checkbox
                    if r.ImGui_IsItemHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
                        if dragState.lock == nil and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Left()) then
                            dragState.lock = not checked
                            protectedSet[name] = dragState.lock or nil
                        elseif dragState.lock ~= nil and dragState.lock ~= checked then
                            protectedSet[name] = dragState.lock or nil
                        end
                    end

                    if ch and dragState.lock == nil then
                        protectedSet[name] = nv or nil
                        saveProtected()
                    end
                end

                -- Column 3: Template Destination (Track Name)
                r.ImGui_TableSetColumnIndex(ctx, 3)
                local editKey = tostring(i) .. "_" .. tostring(s)
                -- For slot 1: use actual track name. For slot 2+: use override or original name
                local slotDisplayName
                if s == 1 then
                    slotDisplayName = name
                else
                    slotDisplayName = (editState.slotNames[i] and editState.slotNames[i][s]) or name
                end
                if editState.track == editKey then
                    -- Editing mode: InputText (full width)
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    local changed, newBuf = r.ImGui_InputText(ctx, "##destName_" .. globalRowID, editState.buf, r.ImGui_InputTextFlags_AutoSelectAll())
                    editState.buf = newBuf
                    -- Auto-focus on first frame
                    if not r.ImGui_IsItemActive(ctx) and not r.ImGui_IsItemDeactivated(ctx) then
                        r.ImGui_SetKeyboardFocusHere(ctx, -1)
                    end
                    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
                        -- Escape: cancel without saving
                        editState.track = nil
                        editState.buf = ""
                    elseif r.ImGui_IsItemDeactivated(ctx) then
                        -- Enter, Tab, or click away: apply
                        local trimmed = (editState.buf or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if trimmed ~= "" then
                            if s == 1 then
                                -- Slot 1: rename the actual REAPER track
                                r.GetSetMediaTrackInfo_String(tr, "P_NAME", trimmed, true)
                                nameCache[tr] = trimmed
                            else
                                -- Slot 2+: store as override (track created at commit)
                                editState.slotNames[i] = editState.slotNames[i] or {}
                                editState.slotNames[i][s] = trimmed
                            end
                        end
                        editState.track = nil
                        editState.buf = ""
                    end
                else
                    -- Display mode: Selectable (full cell width), double-click to edit
                    local displayLabel
                    if s == 1 then
                        displayLabel = slotDisplayName .. (isLeafCached(tr) and "" or " (Folder)")
                    else
                        displayLabel = "|_ " .. slotDisplayName
                    end
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    if r.ImGui_Selectable(ctx, displayLabel .. "##dest_" .. globalRowID, false, r.ImGui_SelectableFlags_AllowDoubleClick()) then
                        if r.ImGui_IsMouseDoubleClicked(ctx, r.ImGui_MouseButton_Left()) then
                            editState.track = editKey
                            editState.buf = slotDisplayName
                        end
                    end
                    if r.ImGui_IsItemHovered(ctx) then
                        r.ImGui_SetTooltip(ctx, slotDisplayName)
                    end
                end
                
                -- Column 4: Recording Sources
                r.ImGui_TableSetColumnIndex(ctx, 4)
                if #recSources == 0 then
                    r.ImGui_Text(ctx, "(load .RPP or files)")
                else
                    local current = slots[s] or 0
                    local preview = (current > 0 and recSources[current] and recSources[current].name) or "<none>"
                    
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    if r.ImGui_BeginCombo(ctx, "##recSel_" .. globalRowID, preview) then
                        if r.ImGui_Selectable(ctx, "<none>", current == 0) then
                            map[i][s] = 0
                        end
                        
                        for j, rc in ipairs(recSources) do
                            local owner = assignedTo[j]
                            local isMine = owner and (owner.mix == i and owner.slot == s)
                            local dim = owner and not isMine
                            local pushed = false
                            
                            if dim then
                                r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_Alpha(), 0.5)
                                pushed = true
                            end
                            
                            local label = rc.name
                            if owner and not isMine then
                                label = label .. " [-> " .. (nameCache[mixTargets[owner.mix]] or trName(mixTargets[owner.mix])) .. "]"
                            end
                            
                            -- Add unique ID to prevent conflicts with duplicate names
                            local uniqueLabel = label .. "##rec_" .. j
                            
                            local selected = (current == j)
                            if r.ImGui_Selectable(ctx, uniqueLabel, selected) then
                                -- Store old mapping for learning detection
                                local oldMapping = current
                                
                                if owner and not isMine then
                                    map[owner.mix][owner.slot] = 0
                                end
                                map[i][s] = j
                                assignedTo[j] = {mix = i, slot = s}
                                
                                -- Auto-lock parent folders when mapping a recording source
                                if j > 0 then  -- Only if actually mapping (not clearing)
                                    lockParentFolders(i)
                                end
                            end
                            
                            if pushed then r.ImGui_PopStyleVar(ctx) end
                        end
                        r.ImGui_EndCombo(ctx)
                    end
                    
                    local should_skip = false
                    if r.ImGui_BeginPopupContextItem(ctx, "ctx_" .. globalRowID) then
                        if s == 1 then
                            if r.ImGui_MenuItem(ctx, "Clear selection") then
                                map[i][s] = 0
                            end
                        else
                            if r.ImGui_MenuItem(ctx, "Remove slot") then
                                table.remove(map[i], s)
                                should_skip = true
                            end
                        end
                        r.ImGui_EndPopup(ctx)
                    end
                    
                    if should_skip then goto nextrow end
                end
                
                -- Column 5: Keep Name
                r.ImGui_TableSetColumnIndex(ctx, 5)
                -- Keep Name is now per slot, not per track name
                keepMap[i] = keepMap[i] or {}
                local kn = keepMap[i][s] and true or false
                local chkn, nvkn = r.ImGui_Checkbox(ctx, "##keep_" .. globalRowID, kn)
                
                -- Drag-state for Keep Name checkbox
                if r.ImGui_IsItemHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
                    if dragState.keepName == nil and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Left()) then
                        dragState.keepName = not kn
                        keepMap[i][s] = dragState.keepName or nil
                    elseif dragState.keepName ~= nil and dragState.keepName ~= kn then
                        keepMap[i][s] = dragState.keepName or nil
                    end
                end
                
                if chkn then 
                    if dragState.keepName == nil then
                        -- Apply to all selected rows if multi-select active
                        local hasMultipleSelected = false
                        for _ in pairs(selectedRows) do hasMultipleSelected = true; break end
                        
                        if hasMultipleSelected and isSelected then
                            -- Apply to all selected rows
                            for selectedID in pairs(selectedRows) do
                                local mi, ms = selectedID:match("(%d+)_(%d+)")
                                mi, ms = tonumber(mi), tonumber(ms)
                                if mi and ms then
                                    keepMap[mi] = keepMap[mi] or {}
                                    keepMap[mi][ms] = nvkn or nil
                                end
                            end
                        else
                            -- Single row
                            keepMap[i][s] = nvkn or nil
                        end
                    end
                end
                
                -- Keep FX (column 6)
                r.ImGui_TableSetColumnIndex(ctx, 6)
                fxMap[i] = fxMap[i] or {}
                local kfx = fxMap[i][s] and true or false
                local chkfx, nvkfx = r.ImGui_Checkbox(ctx, "##keepfx_" .. globalRowID, kfx)
                
                -- Drag-state for Keep FX checkbox
                if r.ImGui_IsItemHovered(ctx, r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
                    if dragState.keepFX == nil and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Left()) then
                        dragState.keepFX = not kfx
                        fxMap[i][s] = dragState.keepFX or nil
                    elseif dragState.keepFX ~= nil and dragState.keepFX ~= kfx then
                        fxMap[i][s] = dragState.keepFX or nil
                    end
                end
                
                if chkfx then 
                    if dragState.keepFX == nil then
                        -- Apply to all selected rows if multi-select active
                        local hasMultipleSelected = false
                        for _ in pairs(selectedRows) do hasMultipleSelected = true; break end
                        
                        if hasMultipleSelected and isSelected then
                            -- Apply to all selected rows
                            for selectedID in pairs(selectedRows) do
                                local mi, ms = selectedID:match("(%d+)_(%d+)")
                                mi, ms = tonumber(mi), tonumber(ms)
                                if mi and ms then
                                    fxMap[mi] = fxMap[mi] or {}
                                    fxMap[mi][ms] = nvkfx or nil
                                end
                            end
                        else
                            -- Single row
                            fxMap[i][s] = nvkfx or nil
                        end
                    end
                end
                
                -- Normalization profile (only if auto-normalize is enabled)
                if normalizeMode then
                    r.ImGui_TableSetColumnIndex(ctx, 7)
                    
                    -- Each slot gets its own normalization settings
                    normMap[i] = normMap[i] or {}
                    normMap[i][s] = normMap[i][s] or {profile = "-", targetPeak = -6}
                    
                    local allProfiles = {"-"}
                    for _, p in ipairs(normProfiles) do
                        allProfiles[#allProfiles + 1] = p.name
                    end
                    
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    if r.ImGui_BeginCombo(ctx, "##norm_" .. globalRowID, normMap[i][s].profile) then
                        for _, profileName in ipairs(allProfiles) do
                            if r.ImGui_Selectable(ctx, profileName, normMap[i][s].profile == profileName) then
                                -- Apply to all selected rows if multi-select active (NEW)
                                local hasMultipleSelected = false
                                for _ in pairs(selectedRows) do hasMultipleSelected = true; break end
                                
                                if hasMultipleSelected and isSelected then
                                    -- Apply to all selected rows
                                    for selectedID in pairs(selectedRows) do
                                        local mi, ms = selectedID:match("(%d+)_(%d+)")
                                        mi, ms = tonumber(mi), tonumber(ms)
                                        if mi and ms then
                                            normMap[mi] = normMap[mi] or {}
                                            normMap[mi][ms] = normMap[mi][ms] or {profile = "-", targetPeak = -6}
                                            normMap[mi][ms].profile = profileName
                                            
                                            if profileName ~= "-" then
                                                local profile = getProfileByName(profileName)
                                                if profile and profile.defaultPeak then
                                                    normMap[mi][ms].targetPeak = profile.defaultPeak
                                                end
                                            end
                                        end
                                    end
                                else
                                    -- Single row
                                    local oldProfile = normMap[i][s].profile
                                    normMap[i][s].profile = profileName
                                    
                                    if profileName ~= "-" then
                                        local profile = getProfileByName(profileName)
                                        if profile and profile.defaultPeak then
                                            normMap[i][s].targetPeak = profile.defaultPeak
                                        end
                                        
                                    end
                                end
                            end
                        end
                        r.ImGui_EndCombo(ctx)
                    end
                    
                    -- Target peak
                    r.ImGui_TableSetColumnIndex(ctx, 8)
                    r.ImGui_SetNextItemWidth(ctx, -1)
                    local changed, val = r.ImGui_InputInt(ctx, "##peak_" .. globalRowID, normMap[i][s].targetPeak)
                    if changed then
                        -- Apply to all selected rows if multi-select active (NEW)
                        local hasMultipleSelected = false
                        for _ in pairs(selectedRows) do hasMultipleSelected = true; break end
                        
                        if hasMultipleSelected and isSelected then
                            -- Apply to all selected rows
                            for selectedID in pairs(selectedRows) do
                                local mi, ms = selectedID:match("(%d+)_(%d+)")
                                mi, ms = tonumber(mi), tonumber(ms)
                                if mi and ms then
                                    normMap[mi] = normMap[mi] or {}
                                    normMap[mi][ms] = normMap[mi][ms] or {profile = "-", targetPeak = -6}
                                    normMap[mi][ms].targetPeak = val
                                end
                            end
                        else
                            -- Single row
                            normMap[i][s].targetPeak = val
                        end
                    end
                end
                
                -- Plus button column (last column)
                r.ImGui_TableSetColumnIndex(ctx, normalizeMode and 9 or 7)
                -- "+" on the last slot row, "-" on duplicate slots (s > 1)
                if s == #slots then
                    if r.ImGui_Button(ctx, "+##add_" .. globalRowID) then
                        local newSlot = #slots + 1
                        map[i] = slots
                        map[i][newSlot] = 0
                        -- Copy normalize params from slot 1
                        if normMap[i] and normMap[i][1] then
                            normMap[i][newSlot] = {
                                profile = normMap[i][1].profile,
                                targetPeak = normMap[i][1].targetPeak
                            }
                        end
                    end
                end
                if s > 1 then
                    r.ImGui_SameLine(ctx)
                    if r.ImGui_Button(ctx, "-##del_" .. globalRowID) then
                        table.remove(map[i], s)
                        -- Clean up editState.slotNames
                        if editState.slotNames[i] then
                            editState.slotNames[i][s] = nil
                        end
                        -- Clean up normMap
                        if normMap[i] then
                            table.remove(normMap[i], s)
                        end
                    end
                end
                
                ::nextrow::
            end
        end
        
        r.ImGui_EndTable(ctx)
    end
    
    -- Clear drag states when mouse is released (drag complete)
    if r.ImGui_IsMouseReleased(ctx, r.ImGui_MouseButton_Left()) then
        if dragState.sel ~= nil then dragState.sel = nil end
        if dragState.lock ~= nil then 
            dragState.lock = nil 
            saveProtected()  -- Save when drag ends
        end
        if dragState.keepName ~= nil then dragState.keepName = nil end
        if dragState.keepFX ~= nil then dragState.keepFX = nil end
    end

    end  -- end of if multiRppSettings.enabled ... else (single-RPP table)

    r.ImGui_Separator(ctx)

    -- Options row 1: Delete unused + Copy media
    local delChanged, delVal = r.ImGui_Checkbox(ctx, "Delete unused", settings.deleteUnused)
    if delChanged then
        settings.deleteUnused = delVal
        saveIni()
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Dummy(ctx, 12, 0)
    r.ImGui_SameLine(ctx)
    local _, cmc = r.ImGui_Checkbox(ctx, "Copy media", settings.copyMedia)
    settings.copyMedia = cmc

    -- Options row 2: Normalization options (horizontal)
    if normalizeMode then
        changed, val = r.ImGui_Checkbox(ctx, "Import to new lane", settings.createNewLane)
        if changed then
            settings.createNewLane = val
            saveIni()
        end
        r.ImGui_SameLine(ctx)
        changed, val = r.ImGui_Checkbox(ctx, "Normalize per region", settings.processPerRegion)
        if changed then
            settings.processPerRegion = val
            saveIni()
        end
        if settings.processPerRegion then
            local regions = scanRegions()
            r.ImGui_SameLine(ctx)
            r.ImGui_TextColored(ctx, theme.text_dim, string.format("(%d regions)", #regions))
            if #regions > 0 then
                r.ImGui_SameLine(ctx)
                changed, val = r.ImGui_Checkbox(ctx, "Delete gaps", settings.deleteBetweenRegions)
                if changed then
                    settings.deleteBetweenRegions = val
                    saveIni()
                end
            end
        end
    end

    -- Info + Action buttons: Commit+Close right-aligned
    local processCount = 0
    for i, tr in ipairs(mixTargets) do
        local slots = map[i] or {0}
        for _, ri in ipairs(slots) do
            if ri and ri > 0 then
                processCount = processCount + 1
                break
            end
        end
    end
    r.ImGui_TextColored(ctx, theme.text_dim, string.format("%d tracks", processCount))

    local win_w = r.ImGui_GetContentRegionAvail(ctx)
    local commitW = r.ImGui_CalcTextSize(ctx, "Commit") + 16
    local closeW = r.ImGui_CalcTextSize(ctx, "Close") + 16
    local padding = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing())
    r.ImGui_SameLine(ctx, r.ImGui_GetWindowWidth(ctx) - commitW - closeW - padding - r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_WindowPadding()))
    if r.ImGui_Button(ctx, "Commit##import") then
        if multiRppSettings.enabled and #rppQueue > 0 then
            commitMultiRpp()
        else
            commitMappings()
        end
    end
    r.ImGui_SameLine(ctx)
    if sec_button("Close##import") then
        uiFlags.close = true
    end

    -- ===== END IMPORT MODE =====
    
    -- ===== NORMALIZE-ONLY MODE UI =====
    elseif normalizeMode then
        r.ImGui_Text(ctx, "Normalize Mode")
        r.ImGui_SameLine(ctx)
        
        if r.ImGui_Button(ctx, "Reload Tracks") then
            loadTracksWithItems()
            if settings.autoMatchProfilesOnImport then
                autoMatchProfilesDirect()
            end
        end
        
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Auto-match Profiles##norm") then
            autoMatchProfilesDirect()
        end

        r.ImGui_Separator(ctx)
        
        -- Bulk action section (Normalize-Only Mode)
        if r.ImGui_BeginChild(ctx, "norm_bulk", 0, 40, r.ImGui_WindowFlags_None()) then
            r.ImGui_Text(ctx, "Set all to:")
            r.ImGui_SameLine(ctx)
            
            local allProfiles = {"-"}
            for _, p in ipairs(normProfiles) do
                allProfiles[#allProfiles + 1] = p.name
            end
            
            r.ImGui_SetNextItemWidth(ctx, 150)
            local bulkProfile = settings.lastBulkProfile or "-"
            
            if r.ImGui_BeginCombo(ctx, "##norm_bulk_profile", bulkProfile) then
                for _, profileName in ipairs(allProfiles) do
                    if r.ImGui_Selectable(ctx, profileName, bulkProfile == profileName) then
                        bulkProfile = profileName
                        settings.lastBulkProfile = bulkProfile
                        
                        if profileName ~= "-" then
                            local profile = getProfileByName(profileName)
                            if profile and profile.defaultPeak then
                                settings.lastBulkPeak = profile.defaultPeak
                            end
                        end
                    end
                end
                r.ImGui_EndCombo(ctx)
            end
            
            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, 80)
            local bulkPeak = settings.lastBulkPeak or -6
            local changed, val = r.ImGui_InputInt(ctx, "##norm_bulk_peak", bulkPeak)
            if changed then
                bulkPeak = val
                settings.lastBulkPeak = bulkPeak
            end
            
            r.ImGui_SameLine(ctx)
            r.ImGui_Text(ctx, "dB")
            
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Apply to all##norm_bulk") then
                for i = 1, #tracks do
                    normMapDirect[i] = {profile = bulkProfile, targetPeak = bulkPeak}
                end
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        -- Calculate available height for scrollable table
        local window_h = r.ImGui_GetWindowHeight(ctx)
        local cursor_y = r.ImGui_GetCursorPosY(ctx)
        local footer_height = 90  -- v2.2: compact footer
        local table_height = window_h - cursor_y - footer_height
        
        local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg() | 
                      r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_ScrollY()
        
        if r.ImGui_BeginTable(ctx, "tracktable", 4, flags, 0, table_height) then
            r.ImGui_TableSetupColumn(ctx, "Track Name")
            local COLFIX = r.ImGui_TableColumnFlags_WidthFixed()
            r.ImGui_TableSetupColumn(ctx, "Profile", COLFIX, 120.0)
            r.ImGui_TableSetupColumn(ctx, "Peak dB", COLFIX, 80.0)
            r.ImGui_TableSetupColumn(ctx, "x", COLFIX, 40.0)
            r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
            r.ImGui_TableHeadersRow(ctx)
            
            local toRemove = nil
            
            for i, trackData in ipairs(tracks) do
                r.ImGui_TableNextRow(ctx)
                
                r.ImGui_TableSetColumnIndex(ctx, 0)
                
                -- Color swatch
                do
                    local rgb = effective_rgb24(trackData.track)
                    local u32 = u32_from_rgb24(rgb)
                    local dl = r.ImGui_GetWindowDrawList(ctx)
                    local x, y = r.ImGui_GetCursorScreenPos(ctx)
                    local swh = (settings.swatch_size or 12)
                    r.ImGui_DrawList_AddRectFilled(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, u32, 3.0)
                    r.ImGui_DrawList_AddRect(dl, x + 2, y + 3, x + 2 + swh, y + 3 + swh, 0xFF000000, 3.0, 0, 1.0)
                    r.ImGui_Dummy(ctx, swh + 8, swh + 2)
                    r.ImGui_SameLine(ctx, 0)
                end
                
                r.ImGui_Text(ctx, trackData.name)
                if r.ImGui_IsItemHovered(ctx) then 
                    r.ImGui_SetTooltip(ctx, trackData.name) 
                end
                
                r.ImGui_TableSetColumnIndex(ctx, 1)
                normMapDirect[i] = normMapDirect[i] or {profile = "-", targetPeak = -6}
                
                local allProfilesTable = {"-"}
                for _, p in ipairs(normProfiles) do
                    allProfilesTable[#allProfilesTable + 1] = p.name
                end
                
                r.ImGui_SetNextItemWidth(ctx, -1)
                if r.ImGui_BeginCombo(ctx, "##norm_profile_" .. i, normMapDirect[i].profile) then
                    for _, profileName in ipairs(allProfilesTable) do
                        if r.ImGui_Selectable(ctx, profileName, normMapDirect[i].profile == profileName) then
                            normMapDirect[i].profile = profileName
                            if profileName ~= "-" then
                                local profile = getProfileByName(profileName)
                                if profile and profile.defaultPeak then
                                    normMapDirect[i].targetPeak = profile.defaultPeak
                                end
                            end
                        end
                    end
                    r.ImGui_EndCombo(ctx)
                end
                
                r.ImGui_TableSetColumnIndex(ctx, 2)
                r.ImGui_SetNextItemWidth(ctx, -1)
                local peakChanged, peakVal = r.ImGui_InputInt(ctx, "##norm_peak_" .. i, normMapDirect[i].targetPeak)
                if peakChanged then
                    normMapDirect[i].targetPeak = peakVal
                end
                
                r.ImGui_TableSetColumnIndex(ctx, 3)
                if r.ImGui_Button(ctx, "X##norm_" .. i) then
                    toRemove = i
                end
            end
            
            r.ImGui_EndTable(ctx)
            
            if toRemove then
                table.remove(tracks, toRemove)
                table.remove(normMapDirect, toRemove)
            end
        end
        
        r.ImGui_Separator(ctx)

        -- Normalization options (horizontal)
        local changed, val = r.ImGui_Checkbox(ctx, "New lane", settings.createNewLane)
        if changed then
            settings.createNewLane = val
            saveIni()
        end
        r.ImGui_SameLine(ctx)
        changed, val = r.ImGui_Checkbox(ctx, "Per region", settings.processPerRegion)
        if changed then
            settings.processPerRegion = val
            saveIni()
        end
        if settings.processPerRegion then
            local regions = scanRegions()
            r.ImGui_SameLine(ctx)
            r.ImGui_TextColored(ctx, theme.text_dim, string.format("(%d regions)", #regions))
            if #regions > 0 then
                r.ImGui_SameLine(ctx)
                changed, val = r.ImGui_Checkbox(ctx, "Delete gaps", settings.deleteBetweenRegions)
                if changed then
                    settings.deleteBetweenRegions = val
                    saveIni()
                end
            end
        end

        -- Info + Action buttons
        local normCount = 0
        for i = 1, #tracks do
            if normMapDirect[i] and normMapDirect[i].profile ~= "-" then
                normCount = normCount + 1
            end
        end
        r.ImGui_TextColored(ctx, theme.text_dim, string.format("%d tracks | %d to normalize", #tracks, normCount))

        local win_w = r.ImGui_GetWindowWidth(ctx)
        r.ImGui_SameLine(ctx, win_w - 170)
        if r.ImGui_Button(ctx, "Normalize##norm") then
            doNormalizeDirectly()
        end
        r.ImGui_SameLine(ctx)
        if sec_button("Close##norm") then
            uiFlags.close = true
        end

    -- ===== END NORMALIZE-ONLY MODE =====
    end
end

-- ===== UI: CALIBRATION WINDOW =====
local function drawCalibrationWindow()
    if not calibrationWindow.open then return end

    local windowFlags = r.ImGui_WindowFlags_AlwaysAutoResize()
    r.ImGui_SetNextWindowPos(ctx, 400, 300, r.ImGui_Cond_FirstUseEver())

    local visible, open = r.ImGui_Begin(ctx, "Calibrate Profile", true, windowFlags)

    if visible then
        -- Error State
        if calibrationWindow.errorMsg ~= "" then
            r.ImGui_TextColored(ctx, 0xFF6666FF, calibrationWindow.errorMsg)
            r.ImGui_Spacing(ctx)
            if r.ImGui_Button(ctx, "Close") then
                calibrationWindow.open = false
            end
            r.ImGui_End(ctx)
            return
        end

        -- Item Info
        r.ImGui_Text(ctx, "Selected Item:")
        r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, 0x66FF66FF, calibrationWindow.itemName)

        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)

        -- Measured Values (read-only display)
        r.ImGui_Text(ctx, "Measured Values:")
        r.ImGui_Text(ctx, string.format("  Peak:  %.1f dB", calibrationWindow.measuredPeak))
        r.ImGui_Text(ctx, string.format("  LUFS:  %.1f dB", calibrationWindow.measuredLUFS))
        r.ImGui_Text(ctx, string.format("  Offset: %d dB", calibrationWindow.calculatedOffset))

        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)

        -- Measurement Settings Section
        r.ImGui_Text(ctx, "Measurement Settings:")
        r.ImGui_Spacing(ctx)

        -- Segment Size
        r.ImGui_SetNextItemWidth(ctx, 150)
        local changed1, newSeg = r.ImGui_SliderDouble(ctx, "Segment Size (s)", calibrationWindow.segmentSize, 5.0, 30.0, "%.1f")
        if changed1 then calibrationWindow.segmentSize = newSeg end

        -- Percentile
        r.ImGui_SetNextItemWidth(ctx, 150)
        local changed2, newPct = r.ImGui_SliderInt(ctx, "Percentile (%)", calibrationWindow.percentile, 80, 99)
        if changed2 then calibrationWindow.percentile = newPct end

        -- Threshold
        r.ImGui_SetNextItemWidth(ctx, 150)
        local changed3, newThr = r.ImGui_SliderDouble(ctx, "Threshold (dB)", calibrationWindow.threshold, -60.0, -20.0, "%.0f")
        if changed3 then calibrationWindow.threshold = newThr end

        -- Re-measure button
        r.ImGui_Spacing(ctx)
        if r.ImGui_Button(ctx, "Re-measure") then
            remeasureCalibration()
        end

        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)

        -- Profile Selection
        r.ImGui_Text(ctx, "Save to Profile:")

        -- Build dropdown items: "Create new..." + existing profiles (excluding Peak/RMS)
        r.ImGui_SetNextItemWidth(ctx, 200)
        local items = "Create new...\0"
        local profileIndices = {0}  -- Maps combo index to normProfiles index
        for i, p in ipairs(normProfiles) do
            if p.name ~= "Peak" and p.name ~= "RMS" then
                items = items .. p.name .. "\0"
                table.insert(profileIndices, i)
            end
        end

        local comboChanged, newIdx = r.ImGui_Combo(ctx, "##profileselect", calibrationWindow.selectedProfileIdx, items)
        if comboChanged then
            calibrationWindow.selectedProfileIdx = newIdx
            if newIdx > 0 and profileIndices[newIdx + 1] then
                local profile = normProfiles[profileIndices[newIdx + 1]]
                calibrationWindow.newProfileName = profile.name
                -- Load profile's measurement settings if available
                if profile.lufsSegmentSize then
                    calibrationWindow.segmentSize = profile.lufsSegmentSize
                    calibrationWindow.percentile = profile.lufsPercentile
                    calibrationWindow.threshold = profile.lufsThreshold
                end
            else
                calibrationWindow.newProfileName = ""
            end
        end

        -- Store the actual profile index for saving
        if calibrationWindow.selectedProfileIdx > 0 then
            calibrationWindow.actualProfileIdx = profileIndices[calibrationWindow.selectedProfileIdx + 1]
        else
            calibrationWindow.actualProfileIdx = 0
        end

        -- New profile name input (only if "Create new" selected)
        if calibrationWindow.selectedProfileIdx == 0 then
            r.ImGui_SetNextItemWidth(ctx, 200)
            local nameChanged, newName = r.ImGui_InputText(ctx, "##newprofilename", calibrationWindow.newProfileName)
            if nameChanged then
                calibrationWindow.newProfileName = newName
            end
        end

        r.ImGui_Spacing(ctx)
        r.ImGui_Spacing(ctx)

        -- Buttons
        local canSave = calibrationWindow.selectedProfileIdx > 0 or
                        (calibrationWindow.newProfileName ~= "" and calibrationWindow.newProfileName:match("%S"))

        if not canSave then
            r.ImGui_BeginDisabled(ctx)
        end

        if r.ImGui_Button(ctx, "Save Profile") then
            -- Use actualProfileIdx for saving to correct profile
            local origIdx = calibrationWindow.selectedProfileIdx
            calibrationWindow.selectedProfileIdx = calibrationWindow.actualProfileIdx or 0
            saveCalibrationToProfile()
            calibrationWindow.selectedProfileIdx = origIdx
            calibrationWindow.open = false
        end

        if not canSave then
            r.ImGui_EndDisabled(ctx)
        end

        r.ImGui_SameLine(ctx)

        if sec_button("Cancel") then
            calibrationWindow.open = false
        end
    end

    if not open then
        calibrationWindow.open = false
    end

    r.ImGui_End(ctx)
end

-- ===== UI: SETTINGS WINDOW =====
local function drawSettingsWindow()
    if not uiFlags.settings then return end
    
    r.ImGui_SetNextWindowSize(ctx, 700, 600, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, "Settings", true)
    
    if visible then
        if r.ImGui_BeginTabBar(ctx, "settabs") then
            
            -- TAB: Bus Tracks
            if r.ImGui_BeginTabItem(ctx, "Bus Tracks") then
                r.ImGui_TextWrapped(ctx, "Tracks whose name contains any of these keywords are hidden.")
                r.ImGui_Separator(ctx)
                
                if r.ImGui_BeginTable(ctx, "buskeys", 2, r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()) then
                    r.ImGui_TableSetupColumn(ctx, "Keyword")
                    r.ImGui_TableSetupColumn(ctx, " ")
                    r.ImGui_TableHeadersRow(ctx)
                    
                    local removeIdx = nil
                    for i, word in ipairs(busKeywords) do
                        r.ImGui_TableNextRow(ctx)
                        r.ImGui_TableSetColumnIndex(ctx, 0)
                        local ch, v = r.ImGui_InputText(ctx, "##bus" .. i, word or "")
                        if ch then busKeywords[i] = v end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 1)
                        if r.ImGui_SmallButton(ctx, "-##rm" .. i) then removeIdx = i end
                    end
                    r.ImGui_EndTable(ctx)
                    
                    if removeIdx then table.remove(busKeywords, removeIdx) end
                end
                
                if r.ImGui_Button(ctx, "+ Add keyword") then
                    busKeywords[#busKeywords + 1] = ""
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save keywords") then
                    saveIni()
                    rebuildMixTargets()
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- TAB: Aliases
            if r.ImGui_BeginTabItem(ctx, "Aliases") then
                r.ImGui_TextWrapped(ctx, "Define contains->equals mappings for smarter Auto-match.")
                r.ImGui_Spacing(ctx)
                r.ImGui_TextWrapped(ctx, "TIP: Use commas to group multiple keywords: 'voc, vocal, vox' -> 'Vocals'")
                r.ImGui_Separator(ctx)
                
                local toRemove = nil
                if r.ImGui_BeginTable(ctx, "aliastable", 3, r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()) then
                    r.ImGui_TableSetupColumn(ctx, "Recording contains")
                    r.ImGui_TableSetupColumn(ctx, "-> Prefer mix target")
                    r.ImGui_TableSetupColumn(ctx, " ")
                    r.ImGui_TableHeadersRow(ctx)
                    
                    for i, it in ipairs(aliases) do
                        r.ImGui_TableNextRow(ctx)
                        r.ImGui_TableSetColumnIndex(ctx, 0)
                        local ca, a = r.ImGui_InputText(ctx, "##src" .. i, it.src or "")
                        if ca then it.src = a end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 1)
                        local cb, b = r.ImGui_InputText(ctx, "##dst" .. i, it.dst or "")
                        if cb then it.dst = b end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 2)
                        if r.ImGui_SmallButton(ctx, "x##del" .. i) then toRemove = i end
                    end
                    r.ImGui_EndTable(ctx)
                end
                
                if toRemove then table.remove(aliases, toRemove) end
                
                if r.ImGui_Button(ctx, "+ Add alias") then
                    aliases[#aliases + 1] = {src = "", dst = ""}
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save aliases") then
                    saveIni()
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                local ch, val = r.ImGui_Checkbox(ctx, "Auto-match tracks on import", settings.autoMatchTracksOnImport)
                if ch then
                    settings.autoMatchTracksOnImport = val
                    saveIni()
                end
                
                if settings.autoMatchTracksOnImport then
                    r.ImGui_SameLine(ctx)
                    r.ImGui_TextDisabled(ctx, "(Runs Auto-match Tracks after importing)")
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- TAB: Profile Aliases
            if r.ImGui_BeginTabItem(ctx, "Profile Aliases") then
                r.ImGui_TextWrapped(ctx, "Define track name contains->profile mappings for Auto-match Profiles.")
                r.ImGui_Spacing(ctx)
                r.ImGui_TextWrapped(ctx, "Example: 'sn bottom, snare top, sn' -> 'Snare' means any track containing these keywords will match the 'Snare' profile.")
                r.ImGui_Spacing(ctx)
                r.ImGui_TextWrapped(ctx, "TIP: Use commas to group multiple keywords: 'kik, kick, bd' -> 'Kick'")
                r.ImGui_Separator(ctx)
                
                local toRemove = nil
                if r.ImGui_BeginTable(ctx, "profilealiastable", 3, r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()) then
                    r.ImGui_TableSetupColumn(ctx, "Track name contains")
                    r.ImGui_TableSetupColumn(ctx, "-> Profile name")
                    r.ImGui_TableSetupColumn(ctx, " ")
                    r.ImGui_TableHeadersRow(ctx)
                    
                    for i, it in ipairs(profileAliases) do
                        r.ImGui_TableNextRow(ctx)
                        r.ImGui_TableSetColumnIndex(ctx, 0)
                        local ca, a = r.ImGui_InputText(ctx, "##profsrc" .. i, it.src or "")
                        if ca then it.src = a end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 1)
                        
                        -- Dropdown for profile selection
                        local allProfiles = {}
                        for _, p in ipairs(normProfiles) do
                            allProfiles[#allProfiles + 1] = p.name
                        end
                        
                        local currentProfile = it.dst or ""
                        r.ImGui_SetNextItemWidth(ctx, -1)
                        if r.ImGui_BeginCombo(ctx, "##profdst" .. i, currentProfile) then
                            for _, profileName in ipairs(allProfiles) do
                                if r.ImGui_Selectable(ctx, profileName, currentProfile == profileName) then
                                    it.dst = profileName
                                end
                            end
                            r.ImGui_EndCombo(ctx)
                        end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 2)
                        if r.ImGui_SmallButton(ctx, "x##pdel" .. i) then toRemove = i end
                    end
                    r.ImGui_EndTable(ctx)
                end
                
                if toRemove then table.remove(profileAliases, toRemove) end
                
                if r.ImGui_Button(ctx, "+ Add profile alias") then
                    profileAliases[#profileAliases + 1] = {src = "", dst = ""}
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save profile aliases") then
                    saveIni()
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                local ch, val = r.ImGui_Checkbox(ctx, "Auto-match profiles on import", settings.autoMatchProfilesOnImport)
                if ch then
                    settings.autoMatchProfilesOnImport = val
                    saveIni()
                end
                
                if settings.autoMatchProfilesOnImport then
                    r.ImGui_SameLine(ctx)
                    r.ImGui_TextDisabled(ctx, "(Runs Auto-match Profiles after importing)")
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- TAB: Normalization (NEW!)
            if r.ImGui_BeginTabItem(ctx, "Normalization") then
                r.ImGui_TextWrapped(ctx, "Define LUFS-to-Peak offset for each instrument type.")
                r.ImGui_Spacing(ctx)
                r.ImGui_Text(ctx, "Example: Kick at -24 LUFS-M -> Peak at -6 dB (Offset = 18 dB)")
                r.ImGui_Separator(ctx)
                r.ImGui_Spacing(ctx)
                
                if r.ImGui_BeginTable(ctx, "profiletable", 4, r.ImGui_TableFlags_Borders()) then
                    r.ImGui_TableSetupColumn(ctx, "Type Name")
                    r.ImGui_TableSetupColumn(ctx, "Offset (dB)")
                    r.ImGui_TableSetupColumn(ctx, "Default Peak (dB)")
                    r.ImGui_TableSetupColumn(ctx, "")
                    r.ImGui_TableHeadersRow(ctx)
                    
                    local toRemove = nil
                    for i, profile in ipairs(normProfiles) do
                        r.ImGui_TableNextRow(ctx)
                        
                        r.ImGui_TableSetColumnIndex(ctx, 0)
                        r.ImGui_SetNextItemWidth(ctx, -1)
                        local changed, val = r.ImGui_InputText(ctx, "##name" .. i, profile.name)
                        if changed then profile.name = val end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 1)
                        r.ImGui_SetNextItemWidth(ctx, -1)
                        changed, val = r.ImGui_InputInt(ctx, "##offset" .. i, profile.offset)
                        if changed then profile.offset = val end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 2)
                        r.ImGui_SetNextItemWidth(ctx, -1)
                        changed, val = r.ImGui_InputInt(ctx, "##defaultpeak" .. i, profile.defaultPeak)
                        if changed then profile.defaultPeak = val end
                        
                        r.ImGui_TableSetColumnIndex(ctx, 3)
                        if r.ImGui_SmallButton(ctx, "x##" .. i) then
                            toRemove = i
                        end
                    end
                    r.ImGui_EndTable(ctx)
                    
                    if toRemove then
                        table.remove(normProfiles, toRemove)
                    end
                end
                
                r.ImGui_Spacing(ctx)
                
                if r.ImGui_Button(ctx, "+ Add Profile") then
                    normProfiles[#normProfiles + 1] = {name = "New Type", offset = 10, defaultPeak = -6}
                end
                
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Reset to Defaults") then
                    normProfiles = {}
                    for _, p in ipairs(DEFAULT_PROFILES) do
                        normProfiles[#normProfiles + 1] = {
                            name = p.name,
                            offset = p.offset,
                            defaultPeak = p.defaultPeak
                        }
                    end
                end
                
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save") then
                    saveIni()
                end

                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Calibrate from Selection") then
                    openCalibrationWindow()
                end
                if r.ImGui_IsItemHovered(ctx) then
                    r.ImGui_SetTooltip(ctx, "Select a perfectly leveled item in REAPER,\nthen click to create/update a profile from it.")
                end

                r.ImGui_EndTabItem(ctx)
            end
            
            -- TAB: UI Settings
            if r.ImGui_BeginTabItem(ctx, "UI") then
                r.ImGui_TextWrapped(ctx, "Customize UI appearance.")
                r.ImGui_Separator(ctx)
                
                local changed, newSize = r.ImGui_SliderInt(ctx, "Swatch Size", settings.swatch_size, 8, 24)
                if changed then
                    settings.swatch_size = newSize
                    saveIni()
                end
                
                r.ImGui_Spacing(ctx)
                r.ImGui_Separator(ctx)
                r.ImGui_Text(ctx, "Debugging:")
                
                local ch, val = r.ImGui_Checkbox(ctx, "Enable console logging", settings.enableConsoleLogging)
                if ch then
                    settings.enableConsoleLogging = val
                    saveIni()
                end
                
                if settings.enableConsoleLogging then
                    r.ImGui_SameLine(ctx)
                    r.ImGui_TextDisabled(ctx, "(Shows detailed output in REAPER console)")
                end
                
                r.ImGui_EndTabItem(ctx)
            end
            
            -- TAB: Save/Load
            if r.ImGui_BeginTabItem(ctx, "Save/Load") then
                r.ImGui_TextWrapped(ctx, "Manage presets and session data.")
                r.ImGui_Separator(ctx)
                
                r.ImGui_Text(ctx, "Profile Sync:")
                if r.ImGui_Button(ctx, "Copy Profiles from Little Joe") then
                    copyProfilesFromLittleJoe()
                end
                if r.ImGui_IsItemHovered(ctx) then
                    r.ImGui_SetTooltip(ctx, 
                        "Imports Profiles + Profile Aliases from\n" ..
                        "Little_Joe.ini"
                    )
                end
                
                r.ImGui_Separator(ctx)
                r.ImGui_Text(ctx, "Preset Management (.ini file):")
                if r.ImGui_Button(ctx, "Export Settings.ini") then
                    exportIni()
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Import Settings.ini") then
                    importIni()
                end
                
                r.ImGui_Separator(ctx)
                r.ImGui_Text(ctx, "Session Data (ExtState):")
                
                if r.ImGui_Button(ctx, "Save protected locks") then
                    saveProtected()
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save current selection") then
                    saveLastMap()
                end
                r.ImGui_SameLine(ctx)
                if r.ImGui_Button(ctx, "Save Keep-name set") then
                    saveKeep()
                end
                
                r.ImGui_Separator(ctx)
                r.ImGui_Text(ctx, "Current .ini: " .. getIniPath())
                
                r.ImGui_EndTabItem(ctx)
            end
            
            
            r.ImGui_EndTabBar(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    if not open then uiFlags.settings = false end
end

-- ===== UI: HELP WINDOW =====
local function drawHelpWindow()
    if not uiFlags.help then return end
    
    r.ImGui_SetNextWindowSize(ctx, 950, 750, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, "Help - RAPID v" .. VERSION, true)
    
    if visible then
        if r.ImGui_BeginTabBar(ctx, "helptabs") then
            
            -- ===== TAB: OVERVIEW =====
            if r.ImGui_BeginTabItem(ctx, "Overview") then
                r.ImGui_TextWrapped(ctx, [[
RAPID v2.5 - Recording Auto-Placement & Intelligent Dynamics

A professional workflow tool for REAPER that combines automated track
mapping with intelligent LUFS-based normalization.

--------------------------------------------------------------------

FOUR WORKFLOWS IN ONE:

1. IMPORT MODE (Single RPP)
   -> Map recording tracks to your mix template
   -> Preserves all FX, sends, routing, automation
   -> Perfect for recurring workflows (podcasts, live recordings, etc.)

2. MULTI-RPP IMPORT (NEW in v2.5)
   -> Import multiple RPP session files into the same template
   -> Automatic regions, merged tempo/markers, configurable gap
   -> Drag-and-drop reorder, column-based mapping UI

3. NORMALIZE MODE
   -> Standalone LUFS normalization for existing tracks
   -> No import needed - works on current project
   -> Quick loudness standardization

4. IMPORT + NORMALIZE (Full Workflow)
   -> Complete automation: import, map, and normalize
   -> One-click solution for production workflows
   -> Professional gain staging in seconds

--------------------------------------------------------------------

MODE SELECTION:

At the top of the window, you'll find two checkboxes:

[x] Import    [x] Normalize  ->  Full RAPID workflow
[x] Import    [ ] Normalize  ->  Import & mapping only
[ ] Import    [x] Normalize  ->  Normalize-only mode

(At least one mode must be active)

Your mode selection is saved and restored automatically.

--------------------------------------------------------------------

KEY FEATURES:

 Intelligent Track Matching
  - Fuzzy matching handles typos and variations
  - Custom aliases for your workflow
  - Exact, contains, and similarity-based matching

 Multi-RPP Import (NEW in v2.5)
  - Import multiple RPP files into one template project
  - Automatic regions per RPP (named from filename)
  - Full tempo/time-signature merging (time-based)
  - Configurable gap between RPPs (in measures)
  - Drag-and-drop queue reordering
  - Column-based mapping with per-RPP dropdowns

 LUFS-Based Normalization
  - Instrument-specific profiles (Kick, Snare, Bass, etc.)
  - Segment-based measurement with percentile filtering
  - Threshold to ignore silent sections

 Workflow Efficiency
  - Multi-select rows for batch editing
  - Drag-to-toggle checkboxes (paint mode)
  - Click column headers to toggle all
  - Protected tracks (lock feature)
  - Double-click to rename template tracks
  - Hide unused tracks with one click

 Professional Tools
  - Process per region (multi-song sessions)
  - Import to new Fixed Item Lane (A/B comparison)
  - Delete gaps between regions
  - Copy or keep source FX
  - Duplicate template slots (+/- buttons)

--------------------------------------------------------------------

GETTING STARTED:

See the "Import Mode" and "Normalize Mode" tabs for detailed workflows.
Check "Normalization" tab for profile system details.
Review "Tips & Tricks" for advanced features.

Version: ]] .. VERSION .. [[

Last Updated: February 2026
]])
                r.ImGui_EndTabItem(ctx)
            end
            
            -- ===== TAB: IMPORT MODE =====
            if r.ImGui_BeginTabItem(ctx, "Import Mode") then
                r.ImGui_TextWrapped(ctx, [[
IMPORT MODE - Automated Track Mapping & Template Workflow

--------------------------------------------------------------------

CONCEPT:

You have a mix template with prepared tracks (drums, bass, vocals, etc.)
with all your FX chains, routing, sends, and automation ready to go.

RAPID imports recordings from a session and automatically maps them to
your template tracks, preserving all your template setup while bringing
in the new audio.

--------------------------------------------------------------------

STEP-BY-STEP WORKFLOW:

1. PREPARE YOUR TEMPLATE
   - Open your mix template in REAPER
   - Ensure all tracks are named clearly (Kick, Snare, Bass, etc.)
   - Your FX, sends, routing, and automation stay intact

2. LAUNCH RAPID
   - Enable Import Mode at the top ([x] Import)
   - Enable Normalize Mode too if you want automatic gain staging

3. IMPORT RECORDINGS
   - Click "Load .RPP" to import from a recording session project
   - OR click "Load audio files" to import individual audio files
   - Recording track list appears in the table

4. AUTO-MATCH TRACKS
   - Click "Auto-match Tracks" button
   - RAPID suggests the best template match for each recording
   - Review and adjust matches in the dropdown menus

5. (OPTIONAL) AUTO-MATCH PROFILES
   - If Normalize Mode is enabled, click "Auto-match Profiles"
   - RAPID assigns appropriate normalization profiles (Kick, Snare, etc.)
   - Adjust profiles and target peaks as needed

6. REVIEW MAPPING TABLE
   - Check all recording -> template assignments
   - Use multi-select to batch-edit Keep Name/FX settings
   - Lock any tracks you want to protect from deletion
   - Double-click template names to rename them

7. COMMIT
   - Click "Commit" to execute the mapping
   - RAPID replaces template tracks with recordings
   - FX, sends, and routing are copied to new tracks
   - If Normalize Mode is enabled, tracks are normalized
   - Done!

--------------------------------------------------------------------

MAPPING TABLE FEATURES:

 Color Column
  - Shows track color from REAPER

 Lock Column (lock icon)
  - Protect tracks from being deleted after commit
  - Click header to toggle all
  - Drag to paint lock status

 Sel Column
  - Multi-select rows for batch editing
  - Click header to select/deselect all
  - Drag over checkboxes to paint selection

 Template Destinations
  - Your mix template tracks (target)
  - Double-click to rename a track
  - Duplicated slots can be renamed independently

 Recording Sources
  - Dropdown to select which recording maps to this template track
  - "+" button to add duplicate slots
  - "-" button to remove duplicate slots
  - Multiple recordings can map to same template (creates lanes)

 Keep Name
  - Use recording track name instead of template name
  - Click header to toggle all
  - Drag to paint

 Keep FX
  - Keep FX from recording instead of template FX
  - Useful when recordings have processing you want to preserve
  - Click header to toggle all
  - Drag to paint

 Normalize (if enabled)
  - Select normalization profile for this track
  - Only visible when Normalize Mode is enabled

 Peak dB (if enabled)
  - Target peak level for normalization
  - Default values from profile, adjustable per track

--------------------------------------------------------------------

MULTI-SLOT MAPPING:

One template track can receive multiple recordings:

Example: "Kick" template track receives:
- Slot 1: "Kick In" recording
- Slot 2: "Kick Out" recording
- Slot 3: "Kick Sub" recording

Result: Three tracks in your template, all with template FX/routing,
named "Kick", "Kick (2)", "Kick (3)".

Use the "+" button to add slots, "-" button to remove them.
Duplicate slots inherit normalization settings from the original.
You can rename duplicate slots independently by double-clicking.

--------------------------------------------------------------------

AFTER COMMIT OPTIONS:

 Copy media into project
  - Copies audio files into project directory
  - Recommended for archival and portability

 Delete unused template tracks
  - Toggle checkbox to hide/show unused tracks
  - On commit: unmapped tracks are removed
  - Locked tracks and folders with content are always kept

--------------------------------------------------------------------

MARKERS, REGIONS & TEMPO (Single RPP):

Use "Import Markers/Tempomap" button to transfer:
- Markers from recording session
- Regions with names
- Tempo map

Note: This closes the script to prevent conflicts.
Reopen RAPID after import completes.

--------------------------------------------------------------------

MULTI-RPP IMPORT (NEW in v2.5):

Import multiple RPP recording sessions into the same template.
Each RPP gets its own region, with tempo and markers merged correctly.

 When To Use
  - Album/EP sessions (one RPP per song)
  - Multi-day recordings into one mix project
  - Compiling takes from different sessions

 Step-by-Step Workflow
  1. Enable "Multi-RPP" checkbox in toolbar
  2. Click "Add .RPP" to load multiple session files
     (or use multi-file dialog with JS_ReaScriptAPI)
  3. Reorder RPPs via drag-and-drop in the queue
  4. Set gap between RPPs (default: 2 measures)
  5. Map tracks: one dropdown column per RPP
  6. Use "Auto-match All" for automatic mapping
  7. Assign normalization profiles if needed
  8. Click "Commit" to execute

 What Happens On Commit
  - Tempo/time-signatures from all RPPs merged
  - One region per RPP created (named from filename)
  - Markers imported with correct measure offsets
  - For each template track: all mapped RPP tracks imported,
    shifted to correct position, consolidated onto one track
  - FX/Sends/routing copied from template
  - Normalization per region (if enabled)
  - Tempo/time-signatures set via API with full shape fidelity

 Settings
  - Gap (measures): silence between RPPs (default: 2)
  - Create regions: auto-create region per RPP
  - Import markers: import markers from RPPs

 Column-Based Mapping Table
  - One column per loaded RPP
  - Dropdown to select which RPP track maps to each template slot
  - Horizontal scrolling when many RPPs are loaded
  - Auto-match per column or all columns at once

--------------------------------------------------------------------

TIPS:

 Use protected tracks for master/bus tracks you never want deleted
 Keep Name is useful when recording track names are descriptive
 Multi-select + batch edit = fast workflow for many tracks
 Process per region is perfect for multi-song live recordings
 Multi-RPP mode: gap completes the last measure before adding silence
]])
                r.ImGui_EndTabItem(ctx)
            end
            
            -- ===== TAB: NORMALIZE MODE =====
            if r.ImGui_BeginTabItem(ctx, "Normalize Mode") then
                r.ImGui_TextWrapped(ctx, [[
NORMALIZE MODE - Standalone LUFS Normalization

--------------------------------------------------------------------

CONCEPT:

Normalize existing tracks in your current project using intelligent
LUFS-based loudness standardization with instrument-specific profiles.

No importing needed - works directly on your current project tracks.

--------------------------------------------------------------------

STEP-BY-STEP WORKFLOW:

1. OPEN YOUR PROJECT
   - Load the project with tracks you want to normalize
   - Tracks must contain media items

2. ENABLE NORMALIZE MODE
   - Disable Import Mode ([ ] Import)
   - Enable Normalize Mode ([x] Normalize)
   - UI switches to Normalize-Only interface

3. LOAD TRACKS
   - Click "Reload Tracks" to scan project
   - All tracks with media items appear in the table
   - Remove unwanted tracks with "X" button

4. ASSIGN PROFILES
   - Click "Auto-match Profiles" for automatic assignment
   - OR manually select profiles from dropdowns

5. ADJUST SETTINGS
   - Review target peak levels (default from profile)
   - Adjust individual tracks as needed
   - Check normalization options (see below)

6. NORMALIZE
   - Click "Commit" button
   - Progress shown in REAPER console
   - Done!

--------------------------------------------------------------------

NORMALIZATION OPTIONS:

 Import to new lane
  - Creates duplicate lane with normalized audio
  - Original stays on first lane (muted)
  - Perfect for A/B comparison
  - Can revert anytime by switching lanes

 Normalize per region
  - Normalizes each region independently
  - Essential for multi-song sessions
  - Each song gets its own loudness target

 Delete media between regions
  - Removes audio between regions (gaps)
  - Only available when "Normalize per region" is enabled
  - Cleans up long recordings with songs separated by regions

--------------------------------------------------------------------

TRACK TABLE FEATURES:

 Track Name
  - Shows track name with color swatch
  - Matches color from REAPER project

 Profile Dropdown
  - Select normalization profile (Kick, Snare, Bass, Vocal, etc.)
  - "-" means no normalization for this track
  - Profiles have different LUFS offsets for different instruments

 Peak dB
  - Target peak level in dB
  - Default value comes from selected profile
  - Adjust per track as needed
  - More negative = quieter (e.g., -12 dB quieter than -6 dB)

 X Button
  - Remove track from normalization list
  - Track stays in project, just not normalized
  - Use "Reload Tracks" to add it back

--------------------------------------------------------------------

USE CASES:

 Podcast Production
  - Load all dialog tracks
  - Auto-match to Vocal profile
  - Quick loudness standardization

 Multi-track Recording
  - Normalize drum tracks with proper offsets
  - Bass gets different treatment than guitars
  - Professional gain staging in seconds

 Mix Preparation
  - Rough level balance before mixing
  - Each instrument at appropriate loudness
  - No more huge level differences

--------------------------------------------------------------------

TIPS:

 Use Auto-match Profiles to save time
 Import to new lane for non-destructive normalization
 Normalize per region essential for live recordings
 Combine with Import Mode for complete workflow
]])
                r.ImGui_EndTabItem(ctx)
            end
            
            -- ===== TAB: NORMALIZATION SYSTEM =====
            if r.ImGui_BeginTabItem(ctx, "Normalization") then
                r.ImGui_TextWrapped(ctx, [[
LUFS NORMALIZATION SYSTEM

--------------------------------------------------------------------

WHAT IS LUFS?

LUFS = Loudness Units relative to Full Scale

A measurement standard that reflects perceived loudness better than
peak levels. Used in broadcast, streaming, and professional audio.

RAPID uses LUFS-M max (Momentary Maximum) for normalization.

--------------------------------------------------------------------

WHY INSTRUMENT-SPECIFIC PROFILES?

Different instruments have different dynamic ranges:

 Transient instruments (kick, snare) have HIGH peaks but LOW LUFS
  - Short, loud hits
  - Lots of headroom between hits
  - Need higher LUFS targets

 Sustained instruments (vocals, bass) have LOWER peaks but HIGH LUFS
  - Continuous energy
  - Less dynamic range
  - Need lower LUFS targets

If you normalize everything to -23 LUFS, your kick will be way too
quiet compared to vocals. Profiles solve this.

--------------------------------------------------------------------

PROFILE SYSTEM:

Each profile has:
1. NAME (e.g., "Kick", "Vocal")
2. LUFS OFFSET (how much to adjust LUFS target)
3. DEFAULT PEAK (starting target peak level)

Formula: Target LUFS = Target Peak - LUFS Offset

Example: Kick profile
- Default Peak: -6 dB
- LUFS Offset: 18 LUFS
- Target LUFS: -6 - 18 = -24 LUFS

This makes kick loud enough despite high dynamic range.

--------------------------------------------------------------------

DEFAULT PROFILES:

Peak (offset: 0, default: -6 dB)
- Simple peak normalization
- No LUFS processing
- Target: -6 dB peak

RMS (offset: 0, default: -12 dB)
- RMS-based normalization
- No LUFS processing
- Target: -12 dB RMS

Kick (offset: 18, default: -6 dB)
- Very transient
- High peaks, low LUFS
- Target: -24 LUFS

Snare (offset: 18, default: -6 dB)
- Very transient
- Similar to kick
- Target: -24 LUFS

Tom (offset: 14, default: -6 dB)
- Transient but more sustain than kick
- Target: -20 LUFS

OH (Overheads) (offset: 12, default: -12 dB)
- Room/cymbal mics
- Some transients, some sustain
- Target: -24 LUFS

Bass (offset: 6, default: -10 dB)
- Low frequency, sustained
- Moderate dynamics
- Target: -16 LUFS

Guitar (offset: 8, default: -12 dB)
- Can be dynamic or sustained
- Middle ground
- Target: -20 LUFS

Vocal (offset: 10, default: -10 dB)
- Sustained with some dynamics
- Most important for mix
- Target: -20 LUFS

Room (offset: 6, default: -12 dB)
- Ambient mics
- Less direct than vocals
- Target: -18 LUFS

--------------------------------------------------------------------

MEASUREMENT DETAILS:

RAPID uses segment-based LUFS measurement:

1. Segment Size (5-30 seconds, default: 10s)
   - Audio is split into segments
   - Each segment measured separately
   - Captures loudness variation

2. Percentile (80-99%, default: 90%)
   - Takes 90th percentile of measurements
   - Ignores loudest 10% (prevents over-normalization from peaks)
   - More consistent results

3. Segment Threshold (-60 to -20 LUFS, default: -40 LUFS)
   - Ignores segments quieter than threshold
   - Prevents silence from affecting measurement
   - Critical for tracks with long quiet sections

Example: A 60-second track with 10-second segments
- 6 segments measured
- Segments quieter than -40 LUFS ignored (silence)
- Remaining segments sorted
- 90th percentile value used

--------------------------------------------------------------------

ADJUSTING SETTINGS:

Settings > Normalization tab:

 Segment Size
  - Smaller = more detail, more measurements
  - Larger = smoother averaging
  - Default (10s) works for most content

 Percentile
  - Lower = ignores more peaks
  - Higher = includes more peaks
  - Default (90%) good balance

 Segment Threshold
  - Higher = more aggressive silence filtering
  - Lower = includes more quiet sections
  - Default (-40 LUFS) catches most silence

--------------------------------------------------------------------

PRACTICAL WORKFLOW:

1. Use Auto-match Profiles first
   - Gets you 90% there
   - Based on track names

2. Review auto-matched profiles
   - Check if assignments make sense
   - Adjust any wrong matches

3. Fine-tune target peaks if needed
   - Most tracks: keep defaults
   - Exceptions: adjust individual tracks

4. Normalize and listen
   - Check relative balance
   - Re-normalize individual tracks if needed

--------------------------------------------------------------------

CUSTOM PROFILES:

Settings > Profiles tab:

Create profiles for your specific needs:
- Different vocal types (lead, BGV, shout)
- Instrument variations (acoustic vs electric)
- Special cases (sound effects, ambience)

Each profile needs:
- Unique name
- LUFS offset (0-20 typical range)
- Default peak dB (-20 to 0 typical range)
]])
                r.ImGui_EndTabItem(ctx)
            end
            
            -- ===== TAB: TIPS & TRICKS =====
            if r.ImGui_BeginTabItem(ctx, "Tips & Tricks") then
                r.ImGui_TextWrapped(ctx, [[
TIPS & TRICKS - Advanced Features

--------------------------------------------------------------------

MULTI-SELECT & BATCH EDITING:

 Select Multiple Rows
  - Click checkboxes in "Sel" column
  - Drag over checkboxes to paint selection
  - Shift+Click for range selection
  - Click "Sel" header to select/deselect all

 Batch Edit Selected Rows
  - Change any setting (Keep Name, Keep FX, Profile, Peak)
  - Applies to ALL selected rows
  - Fast workflow for many tracks

 Example Workflow
  1. Select all drum tracks (drag over checkboxes)
  2. Set one to "Keep name" = ON
  3. All selected rows updated instantly

--------------------------------------------------------------------

DRAG-TO-TOGGLE (Paint Mode):

ALL checkboxes support drag-to-toggle:

 Sel Column
  - Drag to paint selection

 Lock Column
  - Drag to paint protected status
  - Useful for locking multiple bus tracks

 Keep Name Column
  - Drag to paint keep name status
  - Fast for multiple similar tracks

 Keep FX Column
  - Drag to paint keep FX status

How it works:
1. Hold mouse button on checkbox
2. Drag over other checkboxes
3. All touched checkboxes get same state
4. Release mouse button

--------------------------------------------------------------------

CLICKABLE COLUMN HEADERS:

Click column headers to toggle ALL:

 "Sel" Header -> Select/deselect all rows
 Lock Header -> Lock/unlock all tracks
 "Keep name" Header -> Toggle all Keep Name
 "Keep FX" Header -> Toggle all Keep FX

Behavior:
- If ANY are ON -> ALL turn OFF
- If ALL are OFF -> ALL turn ON

Super fast for:
- "Lock all my bus tracks"
- "Keep all recording names"
- "Reset all to template FX"

--------------------------------------------------------------------

EDITABLE TEMPLATE NAMES:

Double-click any template track name to rename it:

 Original tracks
  - Rename changes the actual REAPER track name
  - Press Enter or click away to confirm

 Duplicate slots (created with "+")
  - Rename only affects the imported track name
  - Original REAPER track stays unchanged
  - Each duplicate can have its own name

--------------------------------------------------------------------

PROTECTED TRACKS (Lock Feature):

Use Lock to protect tracks from deletion:

 Why Use It
  - Master track should never be deleted
  - Bus tracks stay in template
  - Reference tracks remain untouched

 How It Works
  - Locked tracks skip the commit process
  - Won't be replaced by recordings
  - Stay exactly as they are
  - Always visible even when "Delete unused" is on

 Workflow
  1. Lock your master track
  2. Lock all bus tracks (click lock header!)
  3. Lock any reference/guide tracks
  4. Now you can safely commit

--------------------------------------------------------------------

MULTI-SLOT MAPPING:

One template track can receive multiple recordings:

 Example: Kick Track
  Slot 1: Kick In (close mic)
  Slot 2: Kick Out (front mic)
  Slot 3: Kick Sub (subkick)

 Result
  Three tracks created:
  - "Kick" (first slot, uses template name)
  - "Kick (2)" (second slot)
  - "Kick (3)" (third slot)
  All have same FX, routing from template

 Duplicate slots inherit normalization settings
  - Profile and peak dB copied from original
  - Can be adjusted independently per slot

 When To Use
  - Multi-mic instruments (drums)
  - Multiple takes of same part
  - Parallel processing chains

 How To Add Slots
  - Click "+" button in Recording Sources cell
  - Select recording for each slot
  - Use "-" to remove duplicate slots

--------------------------------------------------------------------

PROCESS PER REGION:

Essential for multi-song sessions:

 The Problem
  Live recording with 10 songs, each as a region
  Without per-region: All songs normalized to same loudness
  Song 1 (ballad) and Song 10 (rock anthem) forced to same level

 The Solution
  Enable "Normalize per region"
  Each region normalized independently
  Each song can have its own dynamic

 Gap Deletion
  Enable "Delete media between regions"
  Removes audio in gaps (talking, tuning, etc.)
  Clean session without manual editing

 Workflow
  1. Mark each song as region in recording project
  2. Import into RAPID with "Normalize per region" ON
  3. Each song gets appropriate loudness
  4. Gaps automatically cleaned

--------------------------------------------------------------------

IMPORT TO NEW LANE (A/B Comparison):

Non-destructive normalization:

 What It Does
  - Duplicates original items to Lane 1
  - Normalized items on Lane 2
  - Can switch between them anytime

 Why Use It
  - Compare before/after
  - Safe experimentation
  - Easy to revert
  - No destructive edits

 How To Use
  1. Enable "Import to new lane"
  2. Normalize
  3. In REAPER: Right-click track > Show all lanes
  4. Toggle lanes on/off to A/B

 Clean Up Later
  - Keep lane you prefer
  - Delete the other
  - Or keep both for future reference

--------------------------------------------------------------------

ALIASES:

Speed up track matching:

 Track Aliases
  "voc, vocal, vox" -> "Vocals 1"
  Any recording track named voc/vocal/vox maps to "Vocals 1"

 Profile Aliases
  "vocal, vox, lead" -> "Vocal" profile
  Tracks with these names get Vocal profile automatically

 Configure
  Settings > Track Aliases
  Settings > Profile Aliases

 Format
  Source keywords: comma-separated
  Destination: exact match required

--------------------------------------------------------------------

KEYBOARD SHORTCUTS:

While in mapping table:
 Shift+Click -> Range selection
 Click+Drag -> Paint selection/toggle
 Click header -> Toggle all
 Double-click template name -> Rename track

--------------------------------------------------------------------

CONSOLE LOGGING:

Enable for debugging:

Settings > UI > "Enable console logging"

Shows detailed info:
- Which tracks are being processed
- LUFS measurements
- Lane operations
- FX copying status
- Error messages

Check REAPER Console (View > Monitoring) for output.

--------------------------------------------------------------------

WORKFLOW OPTIMIZATION:

 Template Setup
  - Name tracks clearly (auto-matching works better)
  - Color-code track types
  - Lock bus tracks by default
  - Save template for reuse

 Recording Session Setup
  - Name tracks clearly before recording
  - Use consistent naming (Kick In, Snare Top, etc.)
  - Add regions for multi-song sessions
  - Export as .RPP or individual files

 RAPID Workflow
  1. Import -> Auto-match -> Review -> Commit
  2. For repeating work: Save your settings
  3. Use mode checkboxes to skip steps you don't need

--------------------------------------------------------------------

COMBINING MODES:

Mix and match for your workflow:

 Import only (no normalize)
  - Fast import when levels are already good
  - Manual gain staging preferred
  - Quick template population

 Normalize only (no import)
  - Quick loudness standardization
  - Re-normalize after editing
  - Existing project cleanup

 Both modes (full automation)
  - Complete workflow
  - Recording to mix-ready in seconds
  - Professional results with one click
]])
                r.ImGui_EndTabItem(ctx)
            end
            
            -- ===== TAB: CHANGELOG =====
            if r.ImGui_BeginTabItem(ctx, "Changelog") then
                r.ImGui_TextWrapped(ctx, [[
VERSION HISTORY

--------------------------------------------------------------------

v2.5 (February 2026)

Multi-RPP Import:
 Import multiple RPP files into the same mix template
 Drag-and-drop reordering of RPP queue
 Per-RPP regions created automatically (named from filename)
 Tempo/time-signature changes merged from all RPPs (full fidelity)
 Markers imported with correct measure offsets
 Configurable gap between RPPs (in measures, default: 2)
 Column-based UI with per-RPP dropdowns
 Per-column and all-columns auto-matching
 Track consolidation (import, shift, merge onto master track)
 JS_ReaScriptAPI multi-file dialog support

--------------------------------------------------------------------

v2.4 (February 2026)

LUFS Calibration System:
 "Calibrate from Selection" button in Settings
 Create/update profiles from reference tracks
 Per-profile LUFS measurement settings
 Calibration window with editable target peak

Normalization:
 Gain reset (Item Gain + Take Volume) before processing
 All normalization via Take Volume only
 AudioAccessor for accurate measurement

--------------------------------------------------------------------

v2.3 (February 2026)

New Features:
 Editable template track names (double-click to rename)
 Duplicate slot renaming (independent from original)
 Duplicate slots inherit normalization settings
 Delete unused toggle (checkbox replaces radio buttons)
 Unused tracks hidden when "Delete unused" is active
 Improved media path resolution for imported RPP files
 Offline media auto-relinking via progressive path matching

UI Improvements:
 MixnoteStyle dark theme refinements
 Separate color swatch and lock columns
 Lock column header shows lock icon
 Consistent button styling (sec_button for secondary actions)
 Right-aligned Commit/Close buttons
 Renamed options: "Import to new lane", "Normalize per region"
 Removed obsolete buttons (Reload Mix Targets, Clear list, Show all RPP tracks)
 Removed bulk action row (use multi-select instead)

Bug Fixes:
 Fixed duplicate slot deletion losing original assignment
 Fixed folder visibility in delete unused mode
 Fixed slot name override on commit for duplicated tracks

--------------------------------------------------------------------

v2.2 (February 2026)

 MixnoteStyle dark theme (26 color + 10 style pushes)
 Compact UI layout
 sec_button() helper for secondary actions
 Visual refinements throughout

--------------------------------------------------------------------

v2.1 (November 2025)

 Auto-duplicate feature for multi-slot mapping
 "+" and "-" buttons for slot management
 Per-slot FX settings

--------------------------------------------------------------------

v2.0 (November 2025)

MAJOR UPDATE - Unified Workflow:
 Merged RAPID and standalone normalization into one script
 Mode Selection system (Import + Normalize checkboxes)
 Three workflows in one tool
 Conditional UI based on active modes

New Features:
 Normalize-Only Mode (full standalone normalization)
 Mode persistence (saves/restores your preference)
 Clickable column headers (toggle all)
 Drag-to-toggle for all checkboxes (paint mode)
 Lock column (protected tracks)
 Multi-select batch editing

Code Quality:
 Removed 668 lines of obsolete code
 Streamlined from 8076 to 5900 lines (29% reduction)
 Unified configuration system

--------------------------------------------------------------------

v1.5 (November 2025)

MAJOR REFACTOR:
 60% code reduction (~5,096 to ~2,000 lines)
 10x performance improvement (20s -> 2s for 20 tracks)
 Complete code reorganization
 Fixed FX copying using native API (TrackFX_CopyToTrack)
 LUFS Segment Threshold feature
 Shared normalization configuration system
 Settings window with tabs

--------------------------------------------------------------------

v1.3 (October 2025)

 Profile system introduced
 Auto-match profiles feature
 Instrument-specific LUFS offsets
 Profile aliases

--------------------------------------------------------------------

v1.2 (October 2025)

 LUFS normalization added
 Segment-based measurement
 Percentile filtering
 Integration with track mapping

--------------------------------------------------------------------

v1.1 (September 2025)

 Initial public release
 Basic track mapping
 Fuzzy matching
 Track aliases
 Template workflow

--------------------------------------------------------------------

CREDITS:

Developed by Frank
REAPER Lua scripting
ReaImGui interface
SWS Extension integration

Special thanks to the REAPER community for feedback and testing.

--------------------------------------------------------------------

Current Version: ]] .. VERSION .. [[

Last Updated: February 2026

For support or feature requests, check the REAPER forums.
]])
                r.ImGui_EndTabItem(ctx)
            end

            
            r.ImGui_EndTabBar(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    if not open then uiFlags.help = false end
end


-- ===== MAIN LOOP =====
local function loop()
    apply_theme()

    if not uiFlags.winInit then
        local x, y, w, h = loadWinGeom()
        if x and y and w and h then
            r.ImGui_SetNextWindowPos(ctx, x, y, r.ImGui_Cond_Once())
            r.ImGui_SetNextWindowSize(ctx, w, h, r.ImGui_Cond_Once())
        else
            r.ImGui_SetNextWindowSize(ctx, 1200, 800, r.ImGui_Cond_FirstUseEver())
        end
        uiFlags.winInit = true
    end

    local visible, open = r.ImGui_Begin(ctx, WINDOW_TITLE, true, r.ImGui_WindowFlags_NoSavedSettings())

    if visible then
        local ok, err = xpcall(function()
            drawUI_body()
            local wx, wy = r.ImGui_GetWindowPos(ctx)
            local ww, wh = r.ImGui_GetWindowSize(ctx)
            if wx and wy and ww and wh then
                saveWinGeom(math.floor(wx + 0.5), math.floor(wy + 0.5), math.floor(ww + 0.5), math.floor(wh + 0.5))
            end
        end, debug.traceback)

        if not ok then
            showError("ERROR in UI:\n" .. tostring(err))
        end

        r.ImGui_End(ctx)
    end

    drawSettingsWindow()
    drawCalibrationWindow()
    drawHelpWindow()

    pop_theme()

    if uiFlags.close or (not open) then return end

    r.defer(loop)
end

-- ===== ENTRY POINT =====
do
    r.ClearConsole()
    
    if not HAVE_SWS then
        showError("SWS extension required. Download from sws-extension.org")
    end
    
    if not r.ImGui_CreateContext then
        showError("ReaImGui required. Install via ReaPack")
        return
    end
    
    -- Load .ini file (or create with defaults)
    loadIni()
    
    ctx = r.ImGui_CreateContext(WINDOW_TITLE, r.ImGui_ConfigFlags_DockingEnable())
    
    -- Initialize based on active modes
    if importMode then
        -- Initialize Import Mode structures
        rebuildMixTargets()
        map = {}
        normMap = {}
        keepMap = {}
        fxMap = {}
        for i = 1, #mixTargets do
            map[i] = {0}
            normMap[i] = {}
            normMap[i][1] = {profile = "-", targetPeak = -6}
            keepMap[i] = {}
            fxMap[i] = {}
        end
        
        -- Load session data for Import Mode
        protectedSet = loadProtected()
        keepSet = loadKeep()
        applyLastMap()
    end
    
    if normalizeMode and not importMode then
        -- Initialize Normalize-Only Mode
        loadTracksWithItems()
        if settings.autoMatchProfilesOnImport then
            autoMatchProfilesDirect()
        end
    end

    log("RAPID v" .. VERSION .. " loaded\n")
    log("Settings file: " .. getIniPath() .. "\n")
    log("Mode: " .. (importMode and "Import" or "") .. (importMode and normalizeMode and " + " or "") .. (normalizeMode and "Normalize" or "") .. "\n")
    
    loop()
end
