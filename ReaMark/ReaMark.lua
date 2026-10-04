-- @description Mix Notes
-- @author Studio OS
-- @version 2.3.0
-- @provides [main] .
-- @link GitHub https://github.com/acklin83/reamark
-- @changelog
--   New: "Sections from markers" takes the named markers and regions inside the selected
--   song (Intro, V1, C1 ...) as its sections in Studio OS, measured from the song's start
--   (the calibration offset, or the region named like the song). Asks before replacing.
--   Rebuilt for Studio OS, replacing the ReaMark login: connect with the server URL and
--   connect token, versions as chips with their open notes, the Studio OS look.
--   New: comments on a range. With a time selection set, Add stores it as the range;
--   ranges show as a band on the waveform, and clicking a range pill sets the time
--   selection to it and the edit cursor to its start.
-- @about
--   # Mix Notes
--
--   REAPER integration for the Studio OS mix-review loop. Connect to your studio
--   with the server URL + connect token, view the waveform with comment markers,
--   and create, reply to, resolve, edit or delete timeline comments from REAPER.
--
--   Requires the ReaImGui extension (install via ReaPack). Server URL + connect
--   token are under Studio OS → Settings → Integrations → Mix client (REAPER / VST3).
--
-- Mix Notes v2 - REAPER integration for Studio OS
-- Requires ReaImGui (install via ReaPack)
-- Styled to match ReaMark website dark theme
--
-- Usage: Run from REAPER Actions list
-- Dependencies: ReaImGui, json (bundled below)

---------------------------------------------------------------------------
-- Minimal JSON encoder/decoder (pure Lua)
---------------------------------------------------------------------------
local json = {}

local function json_encode_value(val)
  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return val and "true" or "false"
  elseif t == "number" then return tostring(val)
  elseif t == "string" then
    local s = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == "table" then
    if #val > 0 or next(val) == nil then
      local parts = {}
      for i = 1, #val do parts[i] = json_encode_value(val[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        parts[#parts + 1] = json_encode_value(tostring(k)) .. ":" .. json_encode_value(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end
json.encode = json_encode_value

local function json_decode(str)
  if not str or str == "" then return nil end
  local pos = 1
  local function skip_ws()
    pos = str:find("[^ \t\r\n]", pos) or (#str + 1)
  end
  local parse_value

  local function parse_string()
    pos = pos + 1
    local result = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(result)
      elseif c == '\\' then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if esc == 'n' then result[#result + 1] = '\n'
        elseif esc == 't' then result[#result + 1] = '\t'
        elseif esc == 'r' then result[#result + 1] = '\r'
        elseif esc == 'u' then
          pos = pos + 4
          result[#result + 1] = '?'
        else result[#result + 1] = esc end
      else
        result[#result + 1] = c
      end
      pos = pos + 1
    end
    return table.concat(result)
  end

  local function parse_number()
    local start = pos
    if str:sub(pos, pos) == '-' then pos = pos + 1 end
    while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    return tonumber(str:sub(start, pos - 1))
  end

  local function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      skip_ws()
      arr[#arr + 1] = parse_value()
      skip_ws()
      if str:sub(pos, pos) == ',' then pos = pos + 1
      elseif str:sub(pos, pos) == ']' then pos = pos + 1; return arr
      else return arr end
    end
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws()
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      if str:sub(pos, pos) == ',' then pos = pos + 1
      elseif str:sub(pos, pos) == '}' then pos = pos + 1; return obj
      else return obj end
    end
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '"' then return parse_string()
    elseif c == '{' then return parse_object()
    elseif c == '[' then return parse_array()
    elseif c == 't' then pos = pos + 4; return true
    elseif c == 'f' then pos = pos + 5; return false
    elseif c == 'n' then pos = pos + 4; return nil
    else return parse_number() end
  end

  return parse_value()
end
json.decode = json_decode

---------------------------------------------------------------------------
-- HTTP helper (uses curl via os.execute)
---------------------------------------------------------------------------
local function http_request(method, url, body, token)
  local tmp_out = os.tmpname()
  local tmp_err = os.tmpname()
  local cmd = 'curl -s -w "\\n%{http_code}" -X ' .. method
  cmd = cmd .. ' -H "Content-Type: application/json"'
  if token and token ~= "" then
    cmd = cmd .. ' -H "Authorization: Bearer ' .. token .. '"'
  end
  if body then
    local tmp_body = os.tmpname()
    local f = io.open(tmp_body, "w")
    f:write(body)
    f:close()
    cmd = cmd .. ' -d @' .. tmp_body
    cmd = cmd .. ' "' .. url .. '" > ' .. tmp_out .. ' 2>' .. tmp_err
    os.execute(cmd)
    os.remove(tmp_body)
  else
    cmd = cmd .. ' "' .. url .. '" > ' .. tmp_out .. ' 2>' .. tmp_err
    os.execute(cmd)
  end

  local f = io.open(tmp_out, "r")
  local raw = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmp_out)
  os.remove(tmp_err)

  local lines = {}
  for line in raw:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local status_code = tonumber(lines[#lines]) or 0
  table.remove(lines)
  local response_body = table.concat(lines, "\n")

  return status_code, response_body
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local ctx = reaper.ImGui_CreateContext('Mix Notes')
local FONT_SIZE = 14

local function hash_string(str)
  local h = 5381
  for i = 1, #str do
    h = ((h * 33) + string.byte(str, i)) % 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

local function get_project_id()
  local _, project_path = reaper.EnumProjects(-1)
  if project_path and project_path ~= "" then
    return hash_string(project_path)
  end
  return nil
end

local reaper_project_id = get_project_id()
local is_linked = false
local linked_uuid = ""

-- No hardcoded server — each studio enters its own Studio OS URL (e.g.
-- https://studio.example.com). The client talks to that host's /rmc API.
local server_url = reaper.GetExtState("ReaMark", "server_url")
local author_name = reaper.GetExtState("ReaMark", "author_name")
-- The per-instance connect token (Studio OS → Einstellungen → Mix Notes). Replaces the old
-- admin login: a static bearer, no username/password, no 24h re-login.
local connect_token = reaper.GetExtState("ReaMark", "connect_token")
local share_link_input = reaper.GetExtState("ReaMark", "last_share_link")

if reaper_project_id then
  linked_uuid = reaper.GetExtState("ReaMark_Link", reaper_project_id)
  if linked_uuid ~= "" then
    is_linked = true
    share_link_input = linked_uuid
  end
end

local auth_token = ""
local logged_in = false
local login_error = ""

local share_link = ""
local project_data = nil
local songs = {}
local selected_song_idx = 0
local selected_version_idx = 0
local comments = {}
local loading = false
local error_msg = ""

local admin_projects = {}
local selected_project_idx = 0

local calibration_offsets = {}
local current_offset_key = ""

local new_comment_text = ""

local reply_comment_id = nil
local reply_text = ""

local edit_comment_id = nil
local edit_text = ""

local filter_mode = 0

-- Waveform state
local waveform_peaks = {}
local waveform_duration = 0
local autoplay_enabled = reaper.GetExtState("ReaMark", "autoplay") ~= "false"

---------------------------------------------------------------------------
-- Theme colors (matching ReaMark website dark theme)
---------------------------------------------------------------------------
local C = {
  -- Studio OS design tokens, Theme „Console+" (studio.css :root, Stand 29.09.2026)
  bg_body     = 0x020304FF,  -- #020304  --bg
  bg_card     = 0x121A27FF,  -- #121a27  --panel
  bg_panel2   = 0x1A2439FF,  -- #1a2439  --panel-2 (Nebenknopf)
  bg_panel3   = 0x243149FF,  -- #243149  --panel-3 (Nebenknopf, Hover)
  bg_input    = 0x020203FF,  -- #020203  --sunken (Eingabefelder)
  line        = 0x1E2836FF,  -- #1e2836  --line
  bg_border   = 0x5F7BA0FF,  -- #5f7ba0  --line-strong
  wave_idle   = 0x5E6777FF,  -- #5e6777  --wave-idle

  -- Akzent: die Farbe des Studios. Steht dort der Standard (#3fd9c8), gilt das Petrol des
  -- Themes (--tide #11ffe5), genau wie im Web (frontend/src/app/brand.js). fetch_branding().
  accent      = 0x11FFE5FF,  -- #11ffe5  --tide
  accent_hover = 0x33FFEAFF, -- etwas heller (.btn:hover)
  accent_dim  = 0x11FFE51A,  -- --tide-bg (10 %)
  accent_line = 0x11FFE54D,  -- --tide-line (30 %)
  on_accent   = 0x020304FF,  -- --on-tide: Text auf Petrol

  -- Text (--text / --dim / --mute)
  text        = 0xF6F8FCFF,
  text_dim    = 0xAEB6C4FF,
  text_muted  = 0x98A0AFFF,

  -- Status (feste Bedeutung): offen = Amber, erledigt = Grün, Fehler = Rot, Stern = Amber
  green       = 0x33F596FF,
  amber       = 0xFFB246FF,
  red         = 0xF28E8EFF,
  yellow      = 0xFFB246FF,

  -- Kommentar-Karten: 15 % Amber bzw. Grün über dem Grund ergibt --amber-bg #281d0e und
  -- --green-bg #09271a. DURCHSICHTIG, weil die Karte nach ihrem Text gezeichnet wird.
  card_open   = 0xFFB24626,
  card_solved = 0x33F59626,
}

---------------------------------------------------------------------------
-- Apply / pop theme
---------------------------------------------------------------------------
local THEME_COLOR_COUNT = 26
local THEME_VAR_COUNT = 11

local function apply_theme()
  -- Window
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),       C.bg_body)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),        C.bg_panel2)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         C.bg_border)
  -- Text
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           C.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),   C.text_muted)
  -- Frame (inputs, combos): --sunken mit Rahmen --line-strong wie .inp
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        C.bg_input)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), C.bg_input)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  C.bg_input)
  -- Buttons: Standard ist der Nebenknopf (.btn.ghost). Die eine Hauptaktion je Fläche
  -- zeichnet prim_button() in Petrol.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),         C.bg_panel2)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.bg_panel3)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   C.bg_panel3)
  -- Headers (accent tint, follows the per-tenant accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),         C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),  C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),   C.accent_dim)
  -- Tabs
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(),            C.bg_card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(),     C.accent_dim)
  -- Scrollbar
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),    C.bg_body)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),  C.bg_border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), C.text_muted)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(),  C.text_dim)
  -- Separator
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),      C.line)
  -- Checkbox
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),      C.accent)
  -- Title bar
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),        C.bg_body)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),  C.bg_card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgCollapsed(), C.bg_body)

  -- Style vars
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),    12, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),     8, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),      8, 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),    8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),    9)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),    10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(),4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),     4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(),  1)   -- Rahmen um Felder und Nebenknöpfe
end

local function pop_theme()
  reaper.ImGui_PopStyleColor(ctx, THEME_COLOR_COUNT)
  reaper.ImGui_PopStyleVar(ctx, THEME_VAR_COUNT)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function format_timecode(seconds)
  local mins = math.floor(seconds / 60)
  local secs = seconds - mins * 60
  return string.format("%02d:%05.2f", mins, secs)
end

-- Die Zeitauswahl als Bereich, relativ zum Kalibrier-Offset; nil ohne Auswahl. Der Server
-- speichert ganze Sekunden: was darin zusammenfällt, wäre dort ein Punkt, also hier auch.
local function time_selection_rel(offset)
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not s or not e then return nil end
  local a, b = math.max(0, s - offset), e - offset
  if math.floor(b) <= math.floor(a) then return nil end
  return a, b
end

-- Farbe mit anderer Deckkraft (0xRRGGBBAA): für die leise Fläche eines Bereichs.
local function with_alpha(col, a)
  return (col & 0xFFFFFF00) | (a & 0xFF)
end

local function get_offset_key()
  if selected_song_idx > 0 then
    local song = songs[selected_song_idx]
    if song then return tostring(song.id) end
  end
  return ""
end

local function get_current_offset()
  local key = get_offset_key()
  return calibration_offsets[key] or 0
end

local function save_state()
  reaper.SetExtState("ReaMark", "server_url", server_url, true)
  reaper.SetExtState("ReaMark", "author_name", author_name, true)
  reaper.SetExtState("ReaMark", "connect_token", connect_token, true)
  reaper.SetExtState("ReaMark", "last_share_link", share_link_input, true)
  -- Clean up credentials from the old login-based client, if present.
  reaper.DeleteExtState("ReaMark", "username", true)
  reaper.DeleteExtState("ReaMark", "password", true)
  reaper.SetExtState("ReaMark", "autoplay", tostring(autoplay_enabled), true)
end

local function link_project()
  if reaper_project_id and share_link_input ~= "" then
    reaper.SetExtState("ReaMark_Link", reaper_project_id, share_link_input, true)
    linked_uuid = share_link_input
    is_linked = true
  end
end

local function unlink_project()
  if reaper_project_id then
    reaper.DeleteExtState("ReaMark_Link", reaper_project_id, true)
    linked_uuid = ""
    is_linked = false
  end
end

-- Knöpfe wie in Studio OS (studio.css .btn):
--   sec_button   Nebenknopf, dunkel mit Rahmen (.btn.ghost), klein
--   prim_button  die eine Hauptaktion, Petrol gefüllt, dunkle Schrift
--   link_button  Aktion unter einem Kommentar, nur Text (.cmt-act)
--   pill_button  Zeitmarke @1:23, Petrol-Pille
local function sec_button(label)
  return reaper.ImGui_SmallButton(ctx, label)
end

local function prim_button(label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          C.on_accent)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  local pressed = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return pressed
end

local function link_button(label, col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          col or C.text_dim)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  local pressed = reaper.ImGui_SmallButton(ctx, label)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return pressed
end

local function pill_button(label, col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_line)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent_line)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        C.accent_line)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          col or C.accent)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12)
  local pressed = reaper.ImGui_SmallButton(ctx, label)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 5)
  return pressed
end

-- Filter wie .ansicht: nur der gewählte trägt Petrol-Fläche und -Kante.
local function ansicht_button(label, on)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        on and C.accent_dim or 0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        on and C.accent_line or 0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          on and C.text or C.text_dim)
  local pressed = reaper.ImGui_SmallButton(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 5)
  return pressed
end

---------------------------------------------------------------------------
-- API functions
---------------------------------------------------------------------------
local function extract_share_code(input)
  local code = input:match("[/]([%w]+)$")
  if code then return code end
  return input
end

local function api_load_comments()
  if share_link == "" then return end
  local song = songs[selected_song_idx]
  local ver = song and song.versions and song.versions[selected_version_idx]
  if not ver then comments = {}; return end

  local url = server_url .. "/rmc/api/projects/" .. share_link .. "/comments?version_id=" .. tostring(ver.id)
  local status, resp = http_request("GET", url)
  if status == 200 then
    comments = json.decode(resp) or {}
  else
    error_msg = "Failed to load comments"
    comments = {}
  end
end

local function load_calibration_offsets()
  calibration_offsets = {}
  for _, song in ipairs(songs) do
    local key = tostring(song.id)
    local rv, saved = reaper.GetProjExtState(0, "ReaMark", "offset_" .. key)
    if rv > 0 and saved ~= "" then calibration_offsets[key] = tonumber(saved) end
  end
end

local function api_load_peaks()
  waveform_peaks = {}
  waveform_duration = 0
  if share_link == "" or selected_song_idx == 0 or selected_version_idx == 0 then return end
  local song = songs[selected_song_idx]
  local ver = song and song.versions and song.versions[selected_version_idx]
  if not ver then return end
  local url = server_url .. "/rmc/api/versions/" .. tostring(ver.id) .. "/peaks"
  local status, resp = http_request("GET", url)
  if status == 200 then
    local data = json.decode(resp)
    if data and data.peaks and data.duration then
      waveform_peaks = data.peaks
      waveform_duration = data.duration
    end
  end
end

local function api_load_project()
  error_msg = ""
  loading = true
  share_link_input = extract_share_code(share_link_input)
  local url = server_url .. "/rmc/api/projects/" .. share_link_input
  local status, resp = http_request("GET", url)
  if status == 200 then
    project_data = json.decode(resp)
    songs = project_data and project_data.songs or {}
    selected_song_idx = #songs > 0 and 1 or 0
    selected_version_idx = 0
    if selected_song_idx > 0 and songs[selected_song_idx].versions then
      local versions = songs[selected_song_idx].versions
      selected_version_idx = #versions > 0 and #versions or 0
      for vi, ver in ipairs(versions) do
        if ver.favourite then selected_version_idx = vi; break end
      end
    end
    share_link = share_link_input
    save_state()
    load_calibration_offsets()
    if selected_version_idx > 0 then
      api_load_comments()
      api_load_peaks()
    else
      comments = {}
    end
  else
    error_msg = "Failed to load project (HTTP " .. tostring(status) .. ")"
    project_data = nil
    songs = {}
  end
  loading = false
end

local function api_load_admin_projects()
  if not logged_in or auth_token == "" then return end
  project_data = nil
  songs = {}
  selected_song_idx = 0
  selected_version_idx = 0
  comments = {}
  selected_project_idx = 0

  local url = server_url .. "/rmc/admin/projects"
  local status, resp = http_request("GET", url, nil, auth_token)
  if status == 200 then
    admin_projects = json.decode(resp) or {}
    if reaper_project_id then
      local rv, saved_id = reaper.GetProjExtState(0, "ReaMark", "selected_project_id")
      if rv > 0 and saved_id ~= "" then
        for i, p in ipairs(admin_projects) do
          if p.share_link == saved_id then
            selected_project_idx = i
            share_link_input = p.share_link
            api_load_project()
            break
          end
        end
      end
    end
  else
    error_msg = "Failed to load projects (HTTP " .. tostring(status) .. ")"
  end
end

-- Per-tenant brand accent from GET {server}/api/studio (native Studio OS endpoint, no /rmc,
-- no auth). Overwrites the accent in C so the next frame paints in the studio's colour.
local function fetch_branding()
  if server_url == "" then return end
  local status, resp = http_request("GET", server_url .. "/api/studio", nil, nil)
  if status ~= 200 then return end
  local ok, data = pcall(json.decode, resp)
  if not ok or type(data) ~= "table" or type(data.accent) ~= "string" then return end
  local hex = data.accent:gsub("#", ""):lower()
  if #hex ~= 6 then return end
  -- Der alte Standard #3fd9c8 ist keine eigene Farbe: dann bleibt das Petrol des Themes.
  if hex == "3fd9c8" then return end
  local n = tonumber(hex, 16)
  if not n then return end
  C.accent      = n * 256 + 0xFF     -- 0xRRGGBBAA
  C.accent_dim  = n * 256 + 0x1A     -- --tide-bg (10 %)
  C.accent_line = n * 256 + 0x4D     -- --tide-line (30 %)
  local r = math.floor(n / 65536) % 256
  local g = math.floor(n / 256) % 256
  local b = n % 256
  local hell = function(x) return math.min(255, math.floor(x * 1.06)) end
  C.accent_hover = hell(r) * 16777216 + hell(g) * 65536 + hell(b) * 256 + 0xFF
end

local function api_login()
  login_error = ""
  if server_url == "" or connect_token == "" then
    login_error = "Server-URL und Connect-Token nötig"
    return
  end
  -- No login round-trip: the connect token IS the bearer. Verify it by listing projects
  -- (the first authenticated admin call); a 200 means the token is accepted by this instance.
  auth_token = connect_token
  local status, resp = http_request("GET", server_url .. "/rmc/admin/projects", nil, auth_token)
  if status == 200 then
    logged_in = true
    save_state()
    fetch_branding()            -- per-tenant accent
    api_load_admin_projects()   -- re-fetches + restores the last-selected project
  elseif status == 401 or status == 403 then
    auth_token = ""
    login_error = "Connect-Token abgelehnt — in Studio OS neu erzeugen"
  else
    auth_token = ""
    login_error = "Verbindung fehlgeschlagen (HTTP " .. tostring(status) .. ")"
  end
end

local function api_create_comment(timecode, text, timecode_end)
  local song = songs[selected_song_idx]
  local ver = song and song.versions and song.versions[selected_version_idx]
  if not ver then return end

  local url = server_url .. "/rmc/api/projects/" .. share_link .. "/comments"
  local body = json.encode({
    version_id = ver.id,
    timecode = timecode,
    timecode_end = timecode_end,   -- nil = Zeitpunkt; ältere Server ignorieren das Feld
    author_name = author_name,
    text = text,
  })
  local status, resp = http_request("POST", url, body)
  if status == 201 then
    api_load_comments()
  else
    error_msg = "Failed to create comment (HTTP " .. tostring(status) .. ")"
  end
end

local function api_reply(comment_id, text)
  local url = server_url .. "/rmc/api/projects/" .. share_link .. "/comments/" .. tostring(comment_id) .. "/reply"
  local body = json.encode({
    author_name = author_name,
    text = text,
  })
  local status, resp = http_request("POST", url, body)
  if status == 201 then
    api_load_comments()
  else
    error_msg = "Failed to reply (HTTP " .. tostring(status) .. ")"
  end
end

local function api_toggle_favourite()
  if not logged_in then return end
  local song = songs[selected_song_idx]
  local ver = song and song.versions and song.versions[selected_version_idx]
  if not ver then return end

  local url = server_url .. "/rmc/admin/versions/" .. tostring(ver.id) .. "/favourite"
  local status, resp = http_request("PATCH", url, nil, auth_token)
  if status == 200 then
    local data = json.decode(resp)
    if data then
      for _, v in ipairs(song.versions) do
        v.favourite = false
      end
      ver.favourite = data.favourite
    end
  else
    error_msg = "Failed to toggle favourite (HTTP " .. tostring(status) .. ")"
  end
end

local function api_refresh_project()
  if share_link == "" then return end
  local cur_song_idx = selected_song_idx
  local cur_ver_idx = selected_version_idx
  local url = server_url .. "/rmc/api/projects/" .. share_link
  local status, resp = http_request("GET", url)
  if status == 200 then
    project_data = json.decode(resp)
    songs = project_data and project_data.songs or {}
    selected_song_idx = cur_song_idx <= #songs and cur_song_idx or (#songs > 0 and 1 or 0)
    selected_version_idx = cur_ver_idx
    load_calibration_offsets()
  end
end

local function api_resolve(comment_id)
  local url = server_url .. "/rmc/api/projects/" .. share_link .. "/comments/" .. tostring(comment_id) .. "/resolve"
  local status, resp = http_request("PATCH", url, nil, auth_token)
  if status == 200 then
    api_load_comments()
  else
    error_msg = "Failed to resolve (HTTP " .. tostring(status) .. ")"
  end
end

local function api_update_comment(comment_id, text)
  if not logged_in then return end
  local url = server_url .. "/rmc/admin/comments/" .. tostring(comment_id)
  local body = json.encode({text = text})
  local status, resp = http_request("PUT", url, body, auth_token)
  if status == 200 then
    api_load_comments()
  else
    error_msg = "Failed to update comment (HTTP " .. tostring(status) .. ")"
  end
end

local function api_delete_comment(comment_id)
  if not logged_in then return end
  local url = server_url .. "/rmc/admin/comments/" .. tostring(comment_id)
  local status, resp = http_request("DELETE", url, nil, auth_token)
  if status == 204 or status == 200 then
    api_load_comments()
  else
    error_msg = "Failed to delete comment (HTTP " .. tostring(status) .. ")"
  end
end

---------------------------------------------------------------------------
-- UI Drawing
---------------------------------------------------------------------------
local function draw_login_section()
  if logged_in then
    reaper.ImGui_TextColored(ctx, C.green, ">> " .. (author_name ~= "" and author_name or "verbunden"))
    reaper.ImGui_SameLine(ctx)
    if sec_button("Logout") then
      logged_in = false
      auth_token = ""
      -- Reset view to initial state
      project_data = nil
      songs = {}
      comments = {}
      share_link = ""
      selected_song_idx = 1
      selected_version_idx = 1
      selected_project_idx = 0
      admin_projects = {}
      edit_comment_id = nil
      reply_comment_id = nil
      new_comment_text = ""
      error_msg = ""
      waveform_peaks = {}
      waveform_duration = 0
    end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, C.text_muted, server_url)
    return
  end

  do
    local label_w = 95

    reaper.ImGui_TextColored(ctx, C.text_dim, "Server")
    reaper.ImGui_SameLine(ctx, label_w)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local changed
    changed, server_url = reaper.ImGui_InputText(ctx, "##server_url", server_url)

    reaper.ImGui_TextColored(ctx, C.text_dim, "Token")
    reaper.ImGui_SameLine(ctx, label_w)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, connect_token = reaper.ImGui_InputText(ctx, "##connect_token", connect_token, reaper.ImGui_InputTextFlags_Password())

    reaper.ImGui_TextColored(ctx, C.text_dim, "Name")
    reaper.ImGui_SameLine(ctx, label_w)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, author_name = reaper.ImGui_InputText(ctx, "##author_name", author_name)

    reaper.ImGui_Spacing(ctx)

    if prim_button("Verbinden##login_btn") then
      api_login()
    end

    if login_error ~= "" then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_TextColored(ctx, C.red, login_error)
    end
  end
end

local function draw_project_section()
  reaper.ImGui_Spacing(ctx)

  if logged_in then
    local current_proj = admin_projects[selected_project_idx]
    local proj_label = current_proj and current_proj.title or "Select project..."

    reaper.ImGui_TextColored(ctx, C.text_dim, "Project")
    reaper.ImGui_SameLine(ctx, 85)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    if reaper.ImGui_BeginCombo(ctx, "##project_select", proj_label) then
      for i, p in ipairs(admin_projects) do
        if reaper.ImGui_Selectable(ctx, p.title, i == selected_project_idx) then
          selected_project_idx = i
          share_link_input = p.share_link
          api_load_project()
          if reaper_project_id then
            reaper.SetProjExtState(0, "ReaMark", "selected_project_id", p.share_link)
          end
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
  end

  if error_msg ~= "" then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextColored(ctx, C.red, error_msg)
  end
end

-- Die Versionen eines Songs als Chips, wie auf der Mix-Notes-Seite von Studio OS (.mx-ver):
-- „v1  v2 1  v3 2 ★". Zahl der offenen Anmerkungen in Amber, Stern an der Lieblingsfassung,
-- die gewählte Version mit Petrol-Fläche und -Kante. Bricht um, statt abzuschneiden.
-- Gibt den Index der angeklickten Version zurück (oder nil).
local STAR = "\xe2\x98\x85"
local function version_chips(versions, selected, right_reserve)
  local chip_h, gap, pad_x, inner = 24, 4, 7, 4
  local x0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local right = x0 + reaper.ImGui_GetContentRegionAvail(ctx) - (right_reserve or 0)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local clicked, last_x2 = nil, nil
  for i, ver in ipairs(versions) do
    local teile = { { "v" .. tostring(ver.version_number), nil } }
    local offen = tonumber(ver.open_count) or 0
    if offen > 0 then teile[#teile + 1] = { tostring(offen), C.amber } end
    if ver.favourite then teile[#teile + 1] = { STAR, C.amber } end
    local w = 2 * pad_x
    for k, t in ipairs(teile) do
      t.w = reaper.ImGui_CalcTextSize(ctx, t[1])
      w = w + t.w + (k > 1 and inner or 0)
    end
    if last_x2 and last_x2 + gap + w <= right then reaper.ImGui_SameLine(ctx, 0, gap) end
    reaper.ImGui_InvisibleButton(ctx, "##ver" .. i, w, chip_h)
    local hover = reaper.ImGui_IsItemHovered(ctx)
    if hover then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand()) end
    if reaper.ImGui_IsItemClicked(ctx, 0) and i ~= selected then clicked = i end
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    last_x2 = x2
    local on = i == selected
    if on then reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, C.accent_dim, 6) end
    reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2,
      on and C.accent_line or (hover and C.bg_border or C.line), 6)
    local tx = x1 + pad_x
    local ty = y1 + (chip_h - reaper.ImGui_GetTextLineHeight(ctx)) / 2
    for _, t in ipairs(teile) do
      reaper.ImGui_DrawList_AddText(dl, tx, ty, t[2] or ((on or hover) and C.text or C.text_dim), t[1])
      tx = tx + t.w + inner
    end
  end
  return clicked
end

---------------------------------------------------------------------------
-- Song sections from REAPER markers and regions (Studio OS, 03.10.2026)
---------------------------------------------------------------------------
-- Optional: nothing changes for a studio without REAPER, sections are set by hand in Mix Notes.
-- One project can hold all songs as regions (region name = song title) with section markers
-- (Intro, V1, C1) inside; or one song per project with markers from the render start. The song's
-- start is the calibration offset ("Set from Cursor"); without one, the region named like the song.
local section_preview = nil   -- { song_id, offset, new_offset, list = {{label, start_sek}}, existing }
local section_msg = ""

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function project_markers()
  local out, i = {}, 0
  while true do
    local rv, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
    if not rv or rv == 0 then break end
    out[#out + 1] = { pos = pos, rgnend = rgnend, name = name or "", isrgn = isrgn }
    i = i + 1
  end
  return out
end

local function sections_prepare(song)
  section_msg = ""
  section_preview = nil
  local all = project_markers()
  local offset = calibration_offsets[tostring(song.id)] or 0
  local title = trim(song.title):lower()
  -- The song's region: named like the song, else the region that starts at the offset.
  local song_rgn = nil
  for _, m in ipairs(all) do
    if m.isrgn and trim(m.name):lower() == title then song_rgn = m; break end
  end
  if not song_rgn and offset > 0 then
    for _, m in ipairs(all) do
      if m.isrgn and math.abs(m.pos - offset) < 0.05 then song_rgn = m; break end
    end
  end
  local new_offset = nil
  if offset == 0 and song_rgn and song_rgn.pos > 0 then offset = song_rgn.pos; new_offset = offset end
  -- End of the song: its region, else the length of the mix, else open.
  local stop = math.huge
  if song_rgn and song_rgn.rgnend > offset then stop = song_rgn.rgnend
  elseif waveform_duration > 0 then stop = offset + waveform_duration end
  local list, seen = {}, {}
  for _, m in ipairs(all) do
    local name = trim(m.name)
    local covers = m.isrgn and m.pos <= offset + 0.05 and m.rgnend >= stop - 0.05
    if name ~= "" and m ~= song_rgn and not covers and m.pos >= offset - 0.001 and m.pos < stop then
      local t = math.floor((m.pos - offset) * 10 + 0.5) / 10
      if t < 0 then t = 0 end
      if not seen[t] then
        seen[t] = true
        list[#list + 1] = { label = name:sub(1, 60), start_sek = t }
      end
    end
  end
  table.sort(list, function(a, b) return a.start_sek < b.start_sek end)
  if #list == 0 then
    section_msg = "No named markers in this song's range."
    return
  end
  if #list > 60 then
    section_msg = "More than 60 markers in this song's range."
    return
  end
  local existing = 0
  local status, resp = http_request("GET", server_url .. "/rmc/admin/songs/" .. tostring(song.id) .. "/abschnitte", nil, auth_token)
  if status == 200 then
    local d = json.decode(resp)
    existing = d and #d or 0
  else
    section_msg = "Could not read the current sections (HTTP " .. tostring(status) .. ")"
    return
  end
  section_preview = { song_id = song.id, offset = offset, new_offset = new_offset, list = list, existing = existing }
end

local function sections_apply()
  local v = section_preview
  if not v then return end
  local status, resp = http_request("PUT", server_url .. "/rmc/admin/songs/" .. tostring(v.song_id) .. "/abschnitte",
    json.encode(v.list), auth_token)
  if status == 200 then
    if v.new_offset then
      calibration_offsets[tostring(v.song_id)] = v.new_offset
      reaper.SetProjExtState(0, "ReaMark", "offset_" .. tostring(v.song_id), tostring(v.new_offset))
    end
    section_msg = tostring(#v.list) .. " sections saved."
  else
    local d = json.decode(resp or "")
    section_msg = "Saving failed (HTTP " .. tostring(status) .. ")" .. ((d and d.detail) and (": " .. tostring(d.detail)) or "")
  end
  section_preview = nil
end

local function draw_sections_row(song)
  if not logged_in or not song or song.id == "_project" then return end
  if sec_button("Sections from markers") then sections_prepare(song) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Named markers and regions inside this song become its sections in Studio OS\n(Intro, V1, C1 ...), measured from the song's start.")
  end
  if section_msg ~= "" then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, C.text_muted, section_msg)
  end
  local v = section_preview
  if v and v.song_id == song.id then
    for _, a in ipairs(v.list) do
      reaper.ImGui_TextColored(ctx, C.text_dim, format_timecode(a.start_sek) .. "   " .. a.label)
    end
    if v.new_offset then
      reaper.ImGui_TextColored(ctx, C.text_muted, "Song start from its region: " .. format_timecode(v.new_offset) .. " (also sets the offset)")
    end
    if v.existing > 0 then
      reaper.ImGui_TextColored(ctx, C.amber, "Replaces " .. tostring(v.existing) .. " existing sections.")
    end
    if prim_button("Apply") then sections_apply() end
    reaper.ImGui_SameLine(ctx)
    if sec_button("Cancel") then section_preview = nil end
  end
end

local function draw_song_version_section()
  if not project_data or #songs == 0 then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local current_song = songs[selected_song_idx]
  local song_label = current_song and current_song.title or "Select..."

  local label_w = 80   -- Spalte „Song" / „Version", wie im Plugin
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, C.text_dim, "Song")
  reaper.ImGui_SameLine(ctx, label_w)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  if reaper.ImGui_BeginCombo(ctx, "##song", song_label) then
    for i, song in ipairs(songs) do
      if reaper.ImGui_Selectable(ctx, song.title, i == selected_song_idx) then
        selected_song_idx = i
        local versions = songs[i].versions or {}
        selected_version_idx = #versions > 0 and #versions or 0
        for vi, ver in ipairs(versions) do
          if ver.favourite then selected_version_idx = vi; break end
        end
        api_load_comments()
        api_load_peaks()
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  local versions = current_song and current_song.versions or {}
  local current_ver = versions[selected_version_idx]
  local star_w = (logged_in and current_ver) and 30 or 0
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, C.text_dim, "Version")
  reaper.ImGui_SameLine(ctx, label_w)
  local row_x = reaper.ImGui_GetCursorPosX(ctx)
  local row_w = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_BeginGroup(ctx)
  local gewaehlt = version_chips(versions, selected_version_idx, star_w > 0 and star_w + 8 or 0)
  reaper.ImGui_EndGroup(ctx)
  if gewaehlt then
    selected_version_idx = gewaehlt
    current_ver = versions[gewaehlt]
    api_load_comments()
    api_load_peaks()
  end

  -- Lieblingsfassung setzen (nur Studio): Nebenknopf rechts in der Versionszeile
  if star_w > 0 then
    reaper.ImGui_SameLine(ctx, row_x + row_w - star_w)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), current_ver.favourite and C.amber or C.text_muted)
    local star = current_ver.favourite and (STAR .. "##fav") or "\xe2\x98\x86##fav"
    if reaper.ImGui_Button(ctx, star, star_w, 24) then
      api_toggle_favourite()
    end
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- Calibration
  local offset = get_current_offset()
  local full_w = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_TextColored(ctx, C.text_muted, "Offset: " .. format_timecode(offset))
  reaper.ImGui_SameLine(ctx)
  if sec_button("Set from Cursor") then
    local key = get_offset_key()
    if key ~= "" then
      calibration_offsets[key] = reaper.GetCursorPosition()
      reaper.SetProjExtState(0, "ReaMark", "offset_" .. key, tostring(calibration_offsets[key]))
    end
  end
  if offset == 0 then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, C.amber, "(!)")
  end

  -- Autoplay toggle (right-aligned on offset line)
  if share_link ~= "" and selected_version_idx > 0 then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 2, 2)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetCursorPosX(ctx, full_w - 58)
    local changed
    changed, autoplay_enabled = reaper.ImGui_Checkbox(ctx, "Autoplay", autoplay_enabled)
    if changed then save_state() end
    reaper.ImGui_PopStyleVar(ctx)
  end

  draw_sections_row(current_song)
end

local function draw_waveform_section()
  if share_link == "" or selected_version_idx == 0 or #waveform_peaks == 0 then return end

  reaper.ImGui_Spacing(ctx)

  -- Waveform dimensions. A dark strip at the top carries the comment-marker heads, so the
  -- (semantic) marker colours never sit on the per-tenant accent waveform.
  local head_strip = 12
  local wf_h = 50 + head_strip
  local wf_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local wx, wy = reaper.ImGui_GetCursorScreenPos(ctx)
  local bar_top = wy + head_strip
  local bar_h = wf_h - head_strip

  -- Invisible button for click detection
  reaper.ImGui_InvisibleButton(ctx, "##waveform", wf_w, wf_h)
  local is_clicked = reaper.ImGui_IsItemClicked(ctx, 0)

  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- Grund --sunken mit Rahmen --line, Radius wie die Felder
  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + wf_w, wy + wf_h, C.bg_input, 9)
  reaper.ImGui_DrawList_AddRect(dl, wx, wy, wx + wf_w, wy + wf_h, C.line, 9)

  -- Abspielposition (REAPER-Cursor, beim Abspielen die Wiedergabe) vorab: die Balken davor im
  -- Akzent, danach --wave-idle, wie der Web-Player. Derselbe Wert zeichnet unten den Kopf.
  local offset = get_current_offset()
  local cursor_pos = reaper.GetPlayState() ~= 0 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local rel_pos = cursor_pos - offset
  local play_x = -1
  if waveform_duration > 0 and rel_pos > 0 then
    play_x = wx + (math.min(rel_pos, waveform_duration) / waveform_duration) * wf_w
  end

  -- Waveform bars — downsample to pixel width for performance
  local peak_count = #waveform_peaks
  local draw_bars = math.floor(math.min(wf_w, peak_count))
  local bar_w = wf_w / draw_bars
  local center_y = bar_top + bar_h / 2
  local samples_per_bar = peak_count / draw_bars

  for i = 0, draw_bars - 1 do
    -- Find max peak in this bar's range
    local s = math.floor(i * samples_per_bar) + 1
    local e = math.floor((i + 1) * samples_per_bar)
    local peak = 0
    for j = s, e do
      if waveform_peaks[j] and waveform_peaks[j] > peak then
        peak = waveform_peaks[j]
      end
    end
    local x = wx + i * bar_w
    local h = peak * (bar_h * 0.45)
    if h > 0.5 then
      reaper.ImGui_DrawList_AddRectFilled(dl,
        x, center_y - h,
        x + math.max(1, bar_w - (bar_w > 3 and 1 or 0)), center_y + h,
        x < play_x and C.accent or C.wave_idle, 0)
    end
  end

  -- Comment markers + tooltip
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local is_hovered = reaper.ImGui_IsItemHovered(ctx)
  local hovered_comment = nil

  -- Bereiche: leise Fläche über den Balken, oben im dunklen Streifen eine Linie vom Kopf bis
  -- zum Ende (wie im Web). Vor den Köpfen gezeichnet, damit die obenauf liegen.
  if waveform_duration > 0 then
    for _, c in ipairs(comments) do
      if c.timecode and c.timecode_end and c.timecode_end > c.timecode and c.timecode <= waveform_duration then
        local bx1 = wx + (c.timecode / waveform_duration) * wf_w
        local bx2 = wx + (math.min(c.timecode_end, waveform_duration) / waveform_duration) * wf_w
        local bcol = c.solved and C.green or C.amber
        reaper.ImGui_DrawList_AddRectFilled(dl, bx1, bar_top, bx2, wy + wf_h, with_alpha(bcol, 0x1A), 0)
        local ly = wy + head_strip / 2 - 1
        reaper.ImGui_DrawList_AddLine(dl, bx1, ly, bx2, ly, bcol, 2)
      end
    end
    -- Die gesetzte Zeitauswahl: das wird der Bereich der nächsten Anmerkung.
    local sa, se = time_selection_rel(offset)
    if sa and sa < waveform_duration then
      local sx1 = wx + (sa / waveform_duration) * wf_w
      local sx2 = wx + (math.min(se, waveform_duration) / waveform_duration) * wf_w
      reaper.ImGui_DrawList_AddRectFilled(dl, sx1, bar_top, sx2, wy + wf_h, C.accent_dim, 0)
      reaper.ImGui_DrawList_AddLine(dl, sx1, bar_top, sx1, wy + wf_h, C.accent, 1)
      reaper.ImGui_DrawList_AddLine(dl, sx2, bar_top, sx2, wy + wf_h, C.accent, 1)
    end
  end

  for _, c in ipairs(comments) do
    if c.timecode and c.timecode >= 0 and waveform_duration > 0 and c.timecode <= waveform_duration then
      local mx = wx + (c.timecode / waveform_duration) * wf_w
      local mcol = c.solved and C.green or C.amber
      -- A pin in the dark strip pointing down at the exact spot — no line through the
      -- waveform (that read as a break), colour never touches the accent.
      local pcy = wy + head_strip / 2 - 1
      reaper.ImGui_DrawList_AddTriangleFilled(dl, mx - 3, pcy, mx + 3, pcy, mx, bar_top, mcol)
      reaper.ImGui_DrawList_AddCircleFilled(dl, mx, pcy, 4, mcol)

      -- Check hover (±6px)
      if is_hovered and math.abs(mouse_x - mx) < 6 then
        hovered_comment = c
      end
    end
  end

  if hovered_comment then
    reaper.ImGui_BeginTooltip(ctx)
    reaper.ImGui_TextColored(ctx, C.accent, "@" .. format_timecode(hovered_comment.timecode)
      .. (hovered_comment.timecode_end and (" to " .. format_timecode(hovered_comment.timecode_end)) or ""))
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, C.text_dim, hovered_comment.author_name or "")
    reaper.ImGui_TextWrapped(ctx, hovered_comment.text or "")
    reaper.ImGui_EndTooltip(ctx)
  end

  -- Playhead
  if waveform_duration > 0 and rel_pos >= 0 and rel_pos <= waveform_duration then
    local px = wx + (rel_pos / waveform_duration) * wf_w
    reaper.ImGui_DrawList_AddLine(dl, px, bar_top, px, wy + wf_h, 0xFFFFFFFF, 2)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      px, bar_top,
      px - 5, bar_top - 6,
      px + 5, bar_top - 6,
      0xFFFFFFFF)
  end

  -- Click to seek
  if is_clicked and waveform_duration > 0 then
    local mx = reaper.ImGui_GetMousePos(ctx)
    local ratio = (mx - wx) / wf_w
    ratio = math.max(0, math.min(1, ratio))
    local target_tc = ratio * waveform_duration
    reaper.SetEditCurPos(offset + target_tc, true, true)
    if autoplay_enabled then
      local state = reaper.GetPlayState()
      if state == 0 then reaper.OnPlayButton() end
    end
  end
end

local function draw_new_comment_section()
  if share_link == "" or selected_version_idx == 0 then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Author + timecode
  reaper.ImGui_SetNextItemWidth(ctx, 120)
  local changed
  changed, author_name = reaper.ImGui_InputText(ctx, "##author", author_name)
  reaper.ImGui_SameLine(ctx)

  local cursor_pos = reaper.GetCursorPosition()
  local offset = get_current_offset()
  local relative_tc = math.max(0, cursor_pos - offset)
  -- Mit Zeitauswahl gilt sie als Bereich, sonst der Edit-Cursor (Frank 30.09.2026).
  local sel_a, sel_e = time_selection_rel(offset)
  if sel_a then
    pill_button("@" .. format_timecode(sel_a) .. " to " .. format_timecode(sel_e) .. "##now")
  else
    pill_button("@" .. format_timecode(relative_tc) .. "##now")   -- nur Anzeige, wie die Pille im Web
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, sel_a and "Time selection: the note covers this range"
      or "Set a time selection to comment on a range")
  end

  -- Comment input (2 lines) + button
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  changed, new_comment_text = reaper.ImGui_InputTextMultiline(ctx, "##new_comment", new_comment_text, -80, line_h * 2 + 10)
  reaper.ImGui_SameLine(ctx)
  if prim_button("Add##add_btn", 70, line_h * 2 + 10) and new_comment_text ~= "" then
    api_create_comment(sel_a or relative_tc, new_comment_text, sel_e)
    new_comment_text = ""
  end
end

local function draw_comments_section()
  if share_link == "" then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Count open/resolved
  local open_count, resolved_count = 0, 0
  for _, c in ipairs(comments) do
    if c.solved then resolved_count = resolved_count + 1 else open_count = open_count + 1 end
  end

  -- Filter buttons
  if ansicht_button("All (" .. #comments .. ")", filter_mode == 0) then filter_mode = 0 end
  reaper.ImGui_SameLine(ctx)
  if ansicht_button("Open (" .. open_count .. ")", filter_mode == 1) then filter_mode = 1 end
  reaper.ImGui_SameLine(ctx)
  if ansicht_button("Done (" .. resolved_count .. ")", filter_mode == 2) then filter_mode = 2 end
  reaper.ImGui_SameLine(ctx)
  if sec_button("Refresh") then
    api_refresh_project()
    api_load_comments()
  end

  reaper.ImGui_Spacing(ctx)

  -- Scrollable comment list
  if reaper.ImGui_BeginChild(ctx, "##comments_scroll", 0, 0, 0) then

    reaper.ImGui_Spacing(ctx)
    local offset = get_current_offset()
    for _, c in ipairs(comments) do
      local show = (filter_mode == 0)
        or (filter_mode == 1 and not c.solved)
        or (filter_mode == 2 and c.solved)

      if show then
        reaper.ImGui_PushID(ctx, c.id)

        -- Card background via draw list
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local card_pad = 8
        -- Reserve left padding for card content
        reaper.ImGui_Indent(ctx, card_pad)

        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local card_w = reaper.ImGui_GetContentRegionAvail(ctx)

        reaper.ImGui_BeginGroup(ctx)

        -- Header row: @timecode  Author          [Done] [Edit] [Delete]
        local tc_col = c.solved and C.text_muted or C.accent
        local tc_label = "@" .. format_timecode(c.timecode)
          .. (c.timecode_end and (" to " .. format_timecode(c.timecode_end)) or "")
        if pill_button(tc_label .. "##tc" .. tostring(c.id), tc_col) then
          local target = offset + c.timecode
          -- Bereich: als Zeitauswahl setzen, Schleife macht REAPER selbst (Repeat).
          if c.timecode_end then
            reaper.GetSet_LoopTimeRange(true, false, target, offset + c.timecode_end, false)
          end
          reaper.SetEditCurPos(target, true, true)
          if autoplay_enabled then
            local state = reaper.GetPlayState()
            if state == 0 then reaper.OnPlayButton() end
          end
        end

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextColored(ctx, c.solved and C.text_muted or C.text, (c.author_name or ""))

        -- Right-aligned admin actions: Done, Edit, Delete
        if logged_in then
          -- Calculate positions for right-alignment (8px margin from card edge)
          local btn_delete_w = 50
          local btn_edit_w = 40
          local btn_done_w = 45
          local spacing = 4
          local right_edge = card_w - 8
          local delete_x = right_edge - btn_delete_w
          local edit_x = delete_x - btn_edit_w - spacing
          local done_x = edit_x - btn_done_w - spacing

          reaper.ImGui_SameLine(ctx, done_x)
          local done_col = c.solved and C.green or C.text_dim
          if link_button("Done##done", done_col) then
            api_resolve(c.id)
          end

          reaper.ImGui_SameLine(ctx, edit_x)
          if link_button("Edit##edit", C.text_dim) then
            if edit_comment_id == c.id then
              edit_comment_id = nil
            else
              edit_comment_id = c.id
              edit_text = c.text or ""
            end
          end

          reaper.ImGui_SameLine(ctx, delete_x)
          if link_button("Delete##del", C.red) then
            api_delete_comment(c.id)
          end
        else
          -- Non-admin: just show status (right-aligned)
          local status_w = 40
          reaper.ImGui_SameLine(ctx, card_w - status_w)
          if c.solved then
            reaper.ImGui_TextColored(ctx, C.green, "Done")
          else
            reaper.ImGui_TextColored(ctx, C.amber, "Open")
          end
        end

        -- Edit mode: show input instead of text
        if edit_comment_id == c.id then
          reaper.ImGui_Spacing(ctx)
          local line_h = reaper.ImGui_GetTextLineHeight(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local echanged
          local num_lines = 1
          for _ in edit_text:gmatch("\n") do num_lines = num_lines + 1 end
          if num_lines < 2 then num_lines = 2 end
          echanged, edit_text = reaper.ImGui_InputTextMultiline(ctx, "##edit_input", edit_text, -1, line_h * num_lines + 10)
          if prim_button("Save##save_edit") and edit_text ~= "" then
            api_update_comment(c.id, edit_text)
            edit_comment_id = nil
          end
          reaper.ImGui_SameLine(ctx)
          if sec_button("Cancel##cancel_edit") then
            edit_comment_id = nil
          end
        else
          -- Comment text (always use TextWrapped for line breaks)
          if c.solved then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_muted)
            reaper.ImGui_TextWrapped(ctx, c.text or "")
            reaper.ImGui_PopStyleColor(ctx)
          else
            reaper.ImGui_TextWrapped(ctx, c.text or "")
          end
        end

        -- Existing replies
        if c.replies and #c.replies > 0 then
          reaper.ImGui_Indent(ctx, 12)
          reaper.ImGui_Spacing(ctx)
          for _, r in ipairs(c.replies) do
            -- Reply with left accent bar effect via indented text
            reaper.ImGui_TextColored(ctx, C.text, r.text or "")
            reaper.ImGui_TextColored(ctx, C.text_muted, "  -- " .. (r.author_name or ""))
          end
          reaper.ImGui_Unindent(ctx, 12)
        end

        -- Reply button (right-aligned with Delete)
        reaper.ImGui_Spacing(ctx)
        local reply_w = 48
        reaper.ImGui_Dummy(ctx, 1, 0)
        reaper.ImGui_SameLine(ctx, card_w - 8 - reply_w)
        if link_button("Reply", C.accent) then
          if reply_comment_id == c.id then
            reply_comment_id = nil
          else
            reply_comment_id = c.id
            reply_text = ""
          end
        end

        -- Reply input
        if reply_comment_id == c.id then
          reaper.ImGui_Indent(ctx, 12)
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -60)
          local rchanged
          rchanged, reply_text = reaper.ImGui_InputText(ctx, "##reply_input", reply_text)
          reaper.ImGui_SameLine(ctx)
          if prim_button("Send") and reply_text ~= "" then
            api_reply(c.id, reply_text)
            reply_comment_id = nil
            reply_text = ""
          end
          reaper.ImGui_Unindent(ctx, 12)
        end

        reaper.ImGui_EndGroup(ctx)

        -- Draw card background behind the group
        local _, group_h = reaper.ImGui_GetItemRectSize(ctx)
        local card_bg = c.solved and C.card_solved or C.card_open
        reaper.ImGui_DrawList_AddRectFilled(dl,
          cx - card_pad, cy - card_pad,
          cx + card_w + card_pad, cy + group_h + card_pad,
          card_bg, 9)

        reaper.ImGui_Unindent(ctx, card_pad)
        reaper.ImGui_PopID(ctx)
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)
      end
    end

    reaper.ImGui_EndChild(ctx)
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function loop()
  apply_theme()
  reaper.ImGui_SetNextWindowSize(ctx, 420, 700, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 420, 300, 9999, 9999)
  local visible, open = reaper.ImGui_Begin(ctx, 'Mix Notes', true)

  if visible then
    draw_login_section()
    draw_project_section()
    draw_song_version_section()
    draw_waveform_section()
    draw_new_comment_section()
    draw_comments_section()
    reaper.ImGui_End(ctx)
  end

  pop_theme()

  if open then
    reaper.defer(loop)
  end
end

-- Auto-load linked project on script start
if is_linked and share_link_input ~= "" then
  api_load_project()
  if selected_version_idx > 0 then
    api_load_comments()
    api_load_peaks()
  end
end

load_calibration_offsets()

reaper.defer(loop)
