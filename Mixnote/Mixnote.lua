-- @description Mixnote - REAPER Integration for Audio Review Platform
-- @author Frank Acklin
-- @version 2.0
-- @changelog
--   Initial ReaPack release
--   Waveform display with comment markers
--   Timeline-based comment management
--   Project/song/version navigation
--   Calibration system for timeline sync
-- @about
--   # Mixnote REAPER Integration
--
--   Connect REAPER to your self-hosted Mixnote audio review platform.
--   View client comments directly in your DAW with timeline synchronization.
--
--   ## Features
--
--   - Waveform display with clickable comment markers
--   - Timeline-based comments with timecode sync
--   - Project/song/version navigation
--   - Add, reply, and resolve comments from REAPER
--   - Calibration system for timeline alignment
--   - Dark theme matching Mixnote web interface
--
--   ## Requirements
--
--   - REAPER 6.0+
--   - ReaImGui (required)
--   - Running Mixnote server instance
-- @link GitHub https://github.com/acklin83/mixnote
-- @provides
--   [main] Mixnote.lua


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
local ctx = reaper.ImGui_CreateContext('Mixnote Comments')
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

local server_url = reaper.GetExtState("Mixnote", "server_url")
local author_name = reaper.GetExtState("Mixnote", "author_name")
local username = reaper.GetExtState("Mixnote", "username")
local share_link_input = reaper.GetExtState("Mixnote", "last_share_link")

if reaper_project_id then
  linked_uuid = reaper.GetExtState("Mixnote_Link", reaper_project_id)
  if linked_uuid ~= "" then
    is_linked = true
    share_link_input = linked_uuid
  end
end

-- No hardcoded defaults - user must configure on first run
if author_name == "" and username ~= "" then author_name = username end

local password = reaper.GetExtState("Mixnote", "password")
if password == nil then password = "" end
local remember_password = (password ~= "")
local jwt_token = ""
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
local autoplay_enabled = reaper.GetExtState("Mixnote", "autoplay") ~= "false"

---------------------------------------------------------------------------
-- Theme colors (matching Mixnote website dark theme)
---------------------------------------------------------------------------
local C = {
  -- Backgrounds (4-level hierarchy like website)
  bg_body     = 0x0F0F0FFF,  -- #0f0f0f
  bg_card     = 0x1A1A1AFF,  -- #1a1a1a
  bg_input    = 0x2A2A2AFF,  -- #2a2a2a
  bg_border   = 0x3A3A3AFF,  -- #3a3a3a

  -- Accent (Indigo)
  accent      = 0x6366F1FF,  -- #6366f1
  accent_hover = 0x5558E8FF,
  accent_dim  = 0x6366F140,  -- 25% opacity

  -- Text
  text        = 0xE5E7EBFF,  -- #e5e7eb
  text_dim    = 0x9CA3AFFF,  -- #9ca3af
  text_muted  = 0x6B7280FF,  -- #6b7280

  -- Status
  green       = 0x4ADE80FF,  -- #4ade80
  amber       = 0xF59E0BFF,  -- #f59e0b
  red         = 0xEF4444FF,  -- #ef4444
  yellow      = 0xFBBF24FF,  -- #fbbf24

  -- Comment card backgrounds
  card_open   = 0x1E233380,  -- subtle blue tint
  card_solved = 0x1A2A1A60,  -- subtle green tint
}

---------------------------------------------------------------------------
-- Apply / pop theme
---------------------------------------------------------------------------
local THEME_COLOR_COUNT = 26
local THEME_VAR_COUNT = 10

local function apply_theme()
  -- Window
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),       C.bg_body)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),        C.bg_card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         C.bg_border)
  -- Text
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           C.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),   C.text_muted)
  -- Frame (inputs, combos)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        C.bg_input)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), C.bg_border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  C.bg_border)
  -- Buttons
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),         C.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.accent_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   0x4F46E5FF)
  -- Headers
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),         C.accent_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),  0x6366F160)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),   0x6366F180)
  -- Tabs
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(),            C.bg_card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(),     C.accent)
  -- Scrollbar
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),    C.bg_body)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),  C.bg_border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), C.text_muted)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(),  C.text_dim)
  -- Separator
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),      C.bg_border)
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
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),    4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),    4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),    4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(),4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),     4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
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
  reaper.SetExtState("Mixnote", "server_url", server_url, true)
  reaper.SetExtState("Mixnote", "author_name", author_name, true)
  reaper.SetExtState("Mixnote", "username", username, true)
  reaper.SetExtState("Mixnote", "last_share_link", share_link_input, true)
  if remember_password then
    reaper.SetExtState("Mixnote", "password", password, true)
  else
    reaper.DeleteExtState("Mixnote", "password", true)
  end
  reaper.SetExtState("Mixnote", "autoplay", tostring(autoplay_enabled), true)
end

local function link_project()
  if reaper_project_id and share_link_input ~= "" then
    reaper.SetExtState("Mixnote_Link", reaper_project_id, share_link_input, true)
    linked_uuid = share_link_input
    is_linked = true
  end
end

local function unlink_project()
  if reaper_project_id then
    reaper.DeleteExtState("Mixnote_Link", reaper_project_id, true)
    linked_uuid = ""
    is_linked = false
  end
end

-- Secondary button (muted colors for non-primary actions)
local function sec_button(label)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.bg_input)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.bg_border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  C.text_muted)
  local pressed = reaper.ImGui_SmallButton(ctx, label)
  reaper.ImGui_PopStyleColor(ctx, 3)
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

  local url = server_url .. "/api/projects/" .. share_link .. "/comments?version_id=" .. tostring(ver.id)
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
    local rv, saved = reaper.GetProjExtState(0, "Mixnote", "offset_" .. key)
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
  local url = server_url .. "/api/versions/" .. tostring(ver.id) .. "/peaks"
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
  local url = server_url .. "/api/projects/" .. share_link_input
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
  if not logged_in or jwt_token == "" then return end
  project_data = nil
  songs = {}
  selected_song_idx = 0
  selected_version_idx = 0
  comments = {}
  selected_project_idx = 0

  local url = server_url .. "/admin/projects"
  local status, resp = http_request("GET", url, nil, jwt_token)
  if status == 200 then
    admin_projects = json.decode(resp) or {}
    if reaper_project_id then
      local rv, saved_id = reaper.GetProjExtState(0, "Mixnote", "selected_project_id")
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

local function api_login()
  login_error = ""
  local url = server_url .. "/admin/auth/login"
  local body = json.encode({username = username, password = password})
  local status, resp = http_request("POST", url, body)
  if status == 200 then
    local data = json.decode(resp)
    if data and data.access_token then
      jwt_token = data.access_token
      logged_in = true
      author_name = username
      save_state()
      api_load_admin_projects()
    else
      login_error = "Invalid response"
    end
  else
    login_error = "Login failed (HTTP " .. tostring(status) .. ")"
  end
end

local function api_create_comment(timecode, text)
  local song = songs[selected_song_idx]
  local ver = song and song.versions and song.versions[selected_version_idx]
  if not ver then return end

  local url = server_url .. "/api/projects/" .. share_link .. "/comments"
  local body = json.encode({
    version_id = ver.id,
    timecode = timecode,
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
  local url = server_url .. "/api/projects/" .. share_link .. "/comments/" .. tostring(comment_id) .. "/reply"
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

  local url = server_url .. "/admin/versions/" .. tostring(ver.id) .. "/favourite"
  local status, resp = http_request("PATCH", url, nil, jwt_token)
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
  local url = server_url .. "/api/projects/" .. share_link
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
  local url = server_url .. "/api/projects/" .. share_link .. "/comments/" .. tostring(comment_id) .. "/resolve"
  local status, resp = http_request("PATCH", url, nil, jwt_token)
  if status == 200 then
    api_load_comments()
  else
    error_msg = "Failed to resolve (HTTP " .. tostring(status) .. ")"
  end
end

local function api_update_comment(comment_id, text)
  if not logged_in then return end
  local url = server_url .. "/admin/comments/" .. tostring(comment_id)
  local body = json.encode({text = text})
  local status, resp = http_request("PUT", url, body, jwt_token)
  if status == 200 then
    api_load_comments()
  else
    error_msg = "Failed to update comment (HTTP " .. tostring(status) .. ")"
  end
end

local function api_delete_comment(comment_id)
  if not logged_in then return end
  local url = server_url .. "/admin/comments/" .. tostring(comment_id)
  local status, resp = http_request("DELETE", url, nil, jwt_token)
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
    reaper.ImGui_TextColored(ctx, C.green, ">> " .. username)
    reaper.ImGui_SameLine(ctx)
    if sec_button("Logout") then
      logged_in = false
      jwt_token = ""
      if not remember_password then password = "" end
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

    reaper.ImGui_TextColored(ctx, C.text_dim, "User")
    reaper.ImGui_SameLine(ctx, label_w)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, username = reaper.ImGui_InputText(ctx, "##username", username)

    reaper.ImGui_TextColored(ctx, C.text_dim, "Password")
    reaper.ImGui_SameLine(ctx, label_w)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, password = reaper.ImGui_InputText(ctx, "##password", password, reaper.ImGui_InputTextFlags_Password())

    reaper.ImGui_Spacing(ctx)

    local rem_changed
    rem_changed, remember_password = reaper.ImGui_Checkbox(ctx, "Remember me", remember_password)
    if rem_changed then save_state() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Login##login_btn") then
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
            reaper.SetProjExtState(0, "Mixnote", "selected_project_id", p.share_link)
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

local function draw_song_version_section()
  if not project_data or #songs == 0 then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local current_song = songs[selected_song_idx]
  local song_label = current_song and current_song.title or "Select..."

  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, avail_w * 0.55)
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

  reaper.ImGui_SameLine(ctx)

  local versions = current_song and current_song.versions or {}
  local current_ver = versions[selected_version_idx]
  local ver_label = current_ver and ("v" .. tostring(current_ver.version_number)) or "v?"
  reaper.ImGui_SetNextItemWidth(ctx, logged_in and -35 or -1)
  if reaper.ImGui_BeginCombo(ctx, "##version", ver_label) then
    for i, ver in ipairs(versions) do
      local label = "v" .. tostring(ver.version_number)
      if ver.label and ver.label ~= "" then label = label .. " - " .. ver.label end
      if ver.favourite then label = label .. " \xe2\x98\x85" end
      if reaper.ImGui_Selectable(ctx, label, i == selected_version_idx) then
        selected_version_idx = i
        api_load_comments()
        api_load_peaks()
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Favourite toggle (admin only) - filled/outline star, same height as combo
  if logged_in and current_ver then
    reaper.ImGui_SameLine(ctx)
    local fav_col = current_ver.favourite and C.yellow or C.text_muted
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.bg_input)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.bg_border)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.text_muted)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), fav_col)
    local star = current_ver.favourite and "\xe2\x98\x85##fav" or "\xe2\x98\x86##fav"
    if reaper.ImGui_Button(ctx, star) then
      api_toggle_favourite()
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
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
      reaper.SetProjExtState(0, "Mixnote", "offset_" .. key, tostring(calibration_offsets[key]))
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
end

local function draw_waveform_section()
  if share_link == "" or selected_version_idx == 0 or #waveform_peaks == 0 then return end

  reaper.ImGui_Spacing(ctx)

  -- Waveform dimensions
  local wf_h = 50
  local wf_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local wx, wy = reaper.ImGui_GetCursorScreenPos(ctx)

  -- Invisible button for click detection
  reaper.ImGui_InvisibleButton(ctx, "##waveform", wf_w, wf_h)
  local is_clicked = reaper.ImGui_IsItemClicked(ctx, 0)

  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- Background
  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + wf_w, wy + wf_h, C.bg_input, 4)

  -- Waveform bars — downsample to pixel width for performance
  local peak_count = #waveform_peaks
  local draw_bars = math.floor(math.min(wf_w, peak_count))
  local bar_w = wf_w / draw_bars
  local center_y = wy + wf_h / 2
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
    local h = peak * (wf_h * 0.45)
    if h > 0.5 then
      reaper.ImGui_DrawList_AddRectFilled(dl,
        x, center_y - h,
        x + bar_w, center_y + h,
        C.accent, 0)
    end
  end

  -- Comment markers + tooltip
  local offset = get_current_offset()
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local is_hovered = reaper.ImGui_IsItemHovered(ctx)
  local hovered_comment = nil

  for _, c in ipairs(comments) do
    if c.timecode and c.timecode >= 0 and waveform_duration > 0 and c.timecode <= waveform_duration then
      local mx = wx + (c.timecode / waveform_duration) * wf_w
      local mcol = c.solved and C.green or C.amber
      reaper.ImGui_DrawList_AddLine(dl, mx, wy, mx, wy + wf_h, mcol, 2)
      reaper.ImGui_DrawList_AddCircleFilled(dl, mx, wy + 5, 4, mcol)

      -- Check hover (±6px)
      if is_hovered and math.abs(mouse_x - mx) < 6 then
        hovered_comment = c
      end
    end
  end

  if hovered_comment then
    reaper.ImGui_BeginTooltip(ctx)
    reaper.ImGui_TextColored(ctx, C.accent, "@" .. format_timecode(hovered_comment.timecode))
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, C.text_dim, hovered_comment.author_name or "")
    reaper.ImGui_TextWrapped(ctx, hovered_comment.text or "")
    reaper.ImGui_EndTooltip(ctx)
  end

  -- Playhead (real-time REAPER cursor position)
  local cursor_pos = reaper.GetCursorPosition()
  -- If playing, use play position instead
  local play_state = reaper.GetPlayState()
  if play_state ~= 0 then
    cursor_pos = reaper.GetPlayPosition()
  end
  local rel_pos = cursor_pos - offset

  if waveform_duration > 0 and rel_pos >= 0 and rel_pos <= waveform_duration then
    local px = wx + (rel_pos / waveform_duration) * wf_w
    reaper.ImGui_DrawList_AddLine(dl, px, wy, px, wy + wf_h, 0xFFFFFFFF, 2)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      px, wy,
      px - 5, wy - 6,
      px + 5, wy - 6,
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
  reaper.ImGui_TextColored(ctx, C.accent, "@" .. format_timecode(relative_tc))

  -- Comment input (2 lines) + button
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  changed, new_comment_text = reaper.ImGui_InputTextMultiline(ctx, "##new_comment", new_comment_text, -80, line_h * 2 + 10)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Add##add_btn", 70, line_h * 2 + 10) and new_comment_text ~= "" then
    api_create_comment(relative_tc, new_comment_text)
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
  if reaper.ImGui_RadioButton(ctx, "All (" .. #comments .. ")", filter_mode == 0) then filter_mode = 0 end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_RadioButton(ctx, "Open (" .. open_count .. ")", filter_mode == 1) then filter_mode = 1 end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_RadioButton(ctx, "Done (" .. resolved_count .. ")", filter_mode == 2) then filter_mode = 2 end
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
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.bg_border)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_dim)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), tc_col)
        if reaper.ImGui_SmallButton(ctx, "@" .. format_timecode(c.timecode)) then
          local target = offset + c.timecode
          reaper.SetEditCurPos(target, true, true)
          if autoplay_enabled then
            local state = reaper.GetPlayState()
            if state == 0 then reaper.OnPlayButton() end
          end
        end
        reaper.ImGui_PopStyleColor(ctx, 4)

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
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), done_col)
          if sec_button(c.solved and "Done##done" or "Done##done") then
            api_resolve(c.id)
          end
          reaper.ImGui_PopStyleColor(ctx)

          reaper.ImGui_SameLine(ctx, edit_x)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text_dim)
          if sec_button("Edit##edit") then
            if edit_comment_id == c.id then
              edit_comment_id = nil
            else
              edit_comment_id = c.id
              edit_text = c.text or ""
            end
          end
          reaper.ImGui_PopStyleColor(ctx)

          reaper.ImGui_SameLine(ctx, delete_x)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.red)
          if sec_button("Delete##del") then
            api_delete_comment(c.id)
          end
          reaper.ImGui_PopStyleColor(ctx)
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
          if sec_button("Save##save_edit") and edit_text ~= "" then
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
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.accent)
        if sec_button("Reply") then
          if reply_comment_id == c.id then
            reply_comment_id = nil
          else
            reply_comment_id = c.id
            reply_text = ""
          end
        end
        reaper.ImGui_PopStyleColor(ctx)

        -- Reply input
        if reply_comment_id == c.id then
          reaper.ImGui_Indent(ctx, 12)
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -60)
          local rchanged
          rchanged, reply_text = reaper.ImGui_InputText(ctx, "##reply_input", reply_text)
          reaper.ImGui_SameLine(ctx)
          if sec_button("Send") and reply_text ~= "" then
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
          card_bg, 4)

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
  local visible, open = reaper.ImGui_Begin(ctx, 'Mixnote', true)

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
