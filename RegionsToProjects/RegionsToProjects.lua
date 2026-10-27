-- @description Regions to Projects
-- @author Frank Acklin
-- @version 1.0
-- @provides [main] .
-- @link GitHub https://github.com/acklin83/reaper-scripts
-- @changelog
--   First version: every region of the current project becomes its own project.
-- @about
--   # Regions to Projects
--
--   Saves each region of the current project as its own REAPER project, named like the region.
--
--   Each new project has every track (FX, sends, routing, folders), the items of the region
--   (cut at the region edges), all envelopes over that range, the tempo map with the tempo and
--   time signature at the region start and every change inside it, the markers and regions
--   inside it and the region itself. The song starts at the beginning of the new project.
--   Audio files are referenced, not copied.
--
--   Asks for: all regions or only those touching the time selection, and the output folder
--   (default: "<project name> Songs" next to the project). One folder per song:
--   `<output>/<region>/<region>.RPP`. Existing projects are never overwritten; a name that is
--   already taken gets " (2)", " (3)" ...
--
--   The original project stays as it is: the script saves a temporary copy next to it, opens it
--   in a new tab per region, edits and saves that, closes the tab and deletes the copy.

local r = reaper
local SCRIPT = "Regions to Projects"

---------------------------------------------------------------------------------------------
-- helpers

local function action_by_name(name)
  local sec = r.SectionFromUniqueID(0)
  local i = 0
  while true do
    local id, n = r.kbd_enumerateActions(sec, i)
    if not id or id == 0 then return nil end
    if n == name then return id end
    i = i + 1
  end
end

local function sanitize(name)
  name = name:gsub('[/\\:%*%?"<>|%c]', "_")
  name = name:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
  return name
end

local function dir_exists(path)
  return r.EnumerateFiles(path, 0) ~= nil or r.EnumerateSubdirectories(path, 0) ~= nil
end

local function split_path(fn)
  local dir, file = fn:match("^(.*)[/\\]([^/\\]+)$")
  local base = file:gsub("%.[Rr][Pp][Pp]$", "")
  return dir, base
end

local sep = package.config:sub(1, 1)

---------------------------------------------------------------------------------------------
-- one region: turn the open copy (current tab) into the song project

local function all_envelopes(proj)
  local list = {}
  local function add_track(tr)
    for i = 0, r.CountTrackEnvelopes(tr) - 1 do
      local env = r.GetTrackEnvelope(tr, i)
      local _, nm = r.GetEnvelopeName(env)
      if nm ~= "Tempo map" then list[#list + 1] = env end
    end
  end
  add_track(r.GetMasterTrack(proj))
  for i = 0, r.CountTracks(proj) - 1 do add_track(r.GetTrack(proj, i)) end
  return list
end

local function crop_to_region(proj, s, e, delete_ai_cmd)
  local len = e - s

  -- 1. read envelopes in the old timing. Points inside the region are kept, plus the two points
  --    on each side of it: they keep the curve across both edges exactly (points before the
  --    project start or after its end are allowed). No value has to be computed, so automation
  --    items over an edge do not leak into the underlying envelope.
  local envs = {}
  for _, env in ipairs(all_envelopes(proj)) do
    local d = { env = env, pts = {}, ais = {} }
    local n = r.CountEnvelopePointsEx(env, -1)
    if n > 0 then
      local all = {}
      for i = 0, n - 1 do
        local _, t, v, shape, tens, sel = r.GetEnvelopePointEx(env, -1, i)
        all[#all + 1] = { t, v, shape, tens, sel }
      end
      local first, last = 1, n
      for i = 1, n do if all[i][1] <= s then first = i end end
      for i = n, 1, -1 do if all[i][1] >= e then last = i end end
      first, last = math.max(1, first - 1), math.min(n, last + 1)
      for i = first, last do
        local p = all[i]
        d.pts[#d.pts + 1] = { p[1] - s, p[2], p[3], p[4], p[5] }
      end
      d.has_points = true
    end
    for i = 0, r.CountAutomationItems(env) - 1 do
      local pos = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
      local l = r.GetSetAutomationItemInfo(env, i, "D_LENGTH", 0, false)
      local ai = { idx = i }
      if pos + l <= s or pos >= e then
        ai.delete = true
      else
        local offs = r.GetSetAutomationItemInfo(env, i, "D_STARTOFFS", 0, false)
        local rate = r.GetSetAutomationItemInfo(env, i, "D_PLAYRATE", 0, false)
        if pos < s then
          offs = offs + (s - pos) * rate
          l = l - (s - pos)
          pos = s
        end
        if pos + l > e then l = e - pos end
        ai.pos, ai.len, ai.offs = pos - s, l, offs
      end
      d.ais[#d.ais + 1] = ai
    end
    envs[#envs + 1] = d
  end

  -- 2. markers and regions: keep those inside, remember them by GUID
  local keep = {}
  for i = r.GetNumRegionsOrMarkers(proj) - 1, 0, -1 do
    local m = r.GetRegionOrMarker(proj, i, "")
    local pos = r.GetRegionOrMarkerInfo_Value(proj, m, "D_STARTPOS")
    local mend = r.GetRegionOrMarkerInfo_Value(proj, m, "D_ENDPOS")
    if pos >= s - 1e-9 and mend <= e + 1e-9 then
      local _, guid = r.GetSetRegionOrMarkerInfo_String(proj, m, "GUID", "", false)
      keep[#keep + 1] = { guid = guid, pos = pos - s, mend = mend - s }
    else
      r.DeleteProjectMarkerByIndex(proj, i)
    end
  end

  -- 3. items: cut at the edges, drop what is outside, remember where the rest goes
  local items = {}
  for ti = 0, r.CountTracks(proj) - 1 do
    local tr = r.GetTrack(proj, ti)
    local list = {}
    for ii = 0, r.GetTrackNumMediaItems(tr) - 1 do list[#list + 1] = r.GetTrackMediaItem(tr, ii) end
    for _, it in ipairs(list) do
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      local l = r.GetMediaItemInfo_Value(it, "D_LENGTH")
      if pos + l <= s or pos >= e then
        r.DeleteTrackMediaItem(tr, it)
      else
        if pos < s then
          local right = r.SplitMediaItem(it, s)
          if right then r.DeleteTrackMediaItem(tr, it); it = right end
        end
        pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
        l = r.GetMediaItemInfo_Value(it, "D_LENGTH")
        if pos + l > e then
          local right = r.SplitMediaItem(it, e)
          if right then r.DeleteTrackMediaItem(tr, right) end
        end
        local rec = { it = it,
                      pos = r.GetMediaItemInfo_Value(it, "D_POSITION") - s,
                      len = r.GetMediaItemInfo_Value(it, "D_LENGTH"), rates = {} }
        for k = 0, r.CountTakes(it) - 1 do
          local tk = r.GetTake(it, k)
          if tk then rec.rates[#rec.rates + 1] = { tk, r.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE") } end
        end
        items[#items + 1] = rec
      end
    end
  end

  -- 4. tempo map: tempo + signature at the region start become the start values,
  --    every change inside the region follows at its new time
  local num0, den0, bpm0 = r.TimeMap_GetTimeSigAtTime(proj, s)
  local _, _, bpm_end = r.TimeMap_GetTimeSigAtTime(proj, e)
  local old, lin0 = {}, false
  for i = 0, r.CountTempoTimeSigMarkers(proj) - 1 do
    local _, t, _, _, bpm, num, den, lin = r.GetTempoTimeSigMarker(proj, i)
    old[#old + 1] = { t = t, bpm = bpm, num = num, den = den, lin = lin }
    if t <= s then lin0 = lin end
  end
  for i = #old - 1, 0, -1 do r.DeleteTempoTimeSigMarker(proj, i) end
  r.SetTempoTimeSigMarker(proj, -1, 0, -1, -1, bpm0, num0, den0, lin0)
  local lin_open = lin0
  for _, m in ipairs(old) do
    if m.t > s + 1e-9 and m.t < e - 1e-9 then
      r.SetTempoTimeSigMarker(proj, -1, m.t - s, -1, -1, m.bpm, m.num, m.den, m.lin)
      lin_open = m.lin
    end
  end
  -- a tempo ramp that runs past the region end gets its end point at the region end
  if lin_open and bpm_end then
    r.SetTempoTimeSigMarker(proj, -1, len, -1, -1, bpm_end, 0, 0, false)
  end
  r.UpdateTimeline()

  -- 5. everything else is set in seconds AFTER the new tempo map, so items, envelopes and
  --    markers in a beats timebase land at the right time too
  for _, rec in ipairs(items) do
    r.SetMediaItemInfo_Value(rec.it, "D_POSITION", rec.pos)
    r.SetMediaItemInfo_Value(rec.it, "D_LENGTH", rec.len)
    for _, tr in ipairs(rec.rates) do r.SetMediaItemTakeInfo_Value(tr[1], "D_PLAYRATE", tr[2]) end
  end

  local any_ai_deleted = false
  for _, d in ipairs(envs) do
    if d.has_points then
      r.DeleteEnvelopePointRangeEx(d.env, -1, -1e12, 1e12)
      -- an emptied envelope gets a default point back at 0: overwrite it, never keep it
      local left = r.CountEnvelopePointsEx(d.env, -1)
      for i, p in ipairs(d.pts) do
        if i <= left then
          r.SetEnvelopePointEx(d.env, -1, i - 1, p[1], p[2], p[3], p[4], p[5], true)
        else
          r.InsertEnvelopePointEx(d.env, -1, p[1], p[2], p[3], p[4], p[5], true)
        end
      end
      for i = left - 1, #d.pts, -1 do r.DeleteEnvelopePointEx(d.env, -1, i) end
      r.Envelope_SortPointsEx(d.env, -1)
    end
    for _, ai in ipairs(d.ais) do
      r.GetSetAutomationItemInfo(d.env, ai.idx, "D_UISEL", ai.delete and 1 or 0, true)
      if ai.delete then
        any_ai_deleted = true
      else
        r.GetSetAutomationItemInfo(d.env, ai.idx, "D_POSITION", ai.pos, true)
        r.GetSetAutomationItemInfo(d.env, ai.idx, "D_LENGTH", ai.len, true)
        r.GetSetAutomationItemInfo(d.env, ai.idx, "D_STARTOFFS", ai.offs, true)
      end
    end
  end
  if any_ai_deleted and delete_ai_cmd then r.Main_OnCommandEx(delete_ai_cmd, 0, proj) end

  for _, k in ipairs(keep) do
    local m = r.GetRegionOrMarker(proj, -1, k.guid)
    if m then
      r.SetRegionOrMarkerInfo_Value(proj, m, "D_STARTPOS", k.pos)
      r.SetRegionOrMarkerInfo_Value(proj, m, "D_ENDPOS", k.mend)
    end
  end

  r.GetSet_LoopTimeRange2(proj, true, false, 0, len, false)
  r.GetSet_LoopTimeRange2(proj, true, true, 0, len, false)
  r.SetEditCurPos2(proj, 0, true, false)
end

---------------------------------------------------------------------------------------------
-- main

local function run(opts)
  local proj, projfn = r.EnumProjects(-1)
  if not projfn or projfn == "" then
    return false, "Please save the project first (the new projects reference its audio files)."
  end
  local dir, base = split_path(projfn)

  -- regions
  local tsS, tsE = r.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  local regions = {}
  local i = 0
  while true do
    local ok, isrgn, pos, rend, name, num = r.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    if isrgn and rend > pos then
      if opts.mode ~= "sel" or (pos < tsE and rend > tsS) then
        regions[#regions + 1] = { pos = pos, rend = rend, name = name, num = num }
      end
    end
    i = i + 1
  end
  if #regions == 0 then
    return false, opts.mode == "sel" and "No region touches the time selection." or "The project has no regions."
  end

  local new_tab = action_by_name("New project tab, ignore default template") or action_by_name("New project tab")
  local close_tab = action_by_name("Close current project tab")
  local delete_ai = action_by_name("Envelope: Delete automation items")
  if not new_tab or not close_tab then
    return false, "Could not find the actions \"New project tab\" / \"Close current project tab\"."
  end

  -- splitting must not overlap/crossfade, or the cut item would start before the region
  local xf_toggle = action_by_name("Options: Toggle crossfade on split (disregard toolbar auto-crossfade button)")
  local xf_on = action_by_name("Options: Enable crossfade on split (disregard toolbar auto-crossfade button)")
  local xf_off = action_by_name("Options: Disable crossfade on split (disregard toolbar auto-crossfade button)")
  if not (xf_toggle and xf_on and xf_off) then
    return false, "Could not find the \"crossfade on split\" options."
  end

  local outdir = opts.outdir
  if r.RecursiveCreateDirectory(outdir, 0) == 0 and not dir_exists(outdir) then
    return false, "Cannot create the folder:\n" .. outdir
  end

  -- temporary copy of the current state, next to the project so relative media paths resolve
  local tmp = dir .. sep .. base .. "__regions_to_projects_tmp.RPP"
  r.Main_SaveProjectEx(proj, tmp, 0)
  if not r.file_exists(tmp) then return false, "Could not write the temporary copy:\n" .. tmp end

  local done, used = {}, {}
  local xf_was_on = r.GetToggleCommandStateEx(0, xf_toggle) == 1
  r.Main_OnCommandEx(xf_off, 0, proj)
  r.PreventUIRefresh(1)
  local ok, err = pcall(function()
  for _, rg in ipairs(regions) do
    local name = sanitize(rg.name)
    if name == "" then name = "Region " .. rg.num end
    local final, n = name, 1
    while used[final:lower()] or dir_exists(outdir .. sep .. final) do
      n = n + 1
      final = name .. " (" .. n .. ")"
    end
    used[final:lower()] = true
    local songdir = outdir .. sep .. final
    r.RecursiveCreateDirectory(songdir, 0)
    local out = songdir .. sep .. final .. ".RPP"

    r.Main_OnCommandEx(new_tab, 0, proj)
    r.Main_openProject("noprompt:" .. tmp)
    local p = r.EnumProjects(-1)
    crop_to_region(p, rg.pos, rg.rend, delete_ai)
    r.Main_SaveProjectEx(p, out, 8)
    r.Main_OnCommandEx(close_tab, 0, p)
    r.SelectProjectInstance(proj)
    done[#done + 1] = out
  end
  end)
  r.PreventUIRefresh(-1)
  if xf_was_on then r.Main_OnCommandEx(xf_on, 0, proj) end
  os.remove(tmp)
  r.SelectProjectInstance(proj)
  if not ok then return false, "Stopped with an error:\n" .. tostring(err) end
  return true, done
end

-- tests set _REGIONS_TO_PROJECTS_OPTS = { mode = "all"|"sel", outdir = "..." } before dofile()
local opts = _REGIONS_TO_PROJECTS_OPTS
if not opts then
  local proj, projfn = r.EnumProjects(-1)
  if not projfn or projfn == "" then
    r.ShowMessageBox("Please save the project first.", SCRIPT, 0)
    return
  end
  local dir, base = split_path(projfn)
  local tsS, tsE = r.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  local def_mode = (tsE > tsS) and "sel" or "all"
  local ok, csv = r.GetUserInputs(SCRIPT, 2,
    "Regions (all / sel = time selection):,Output folder:,extrawidth=320,separator=|",
    def_mode .. "|" .. dir .. sep .. base .. " Songs")
  if not ok then return end
  local mode, outdir = csv:match("^([^|]*)|(.*)$")
  mode = (mode or ""):lower():gsub("%s", "")
  if mode ~= "all" and mode ~= "sel" then
    r.ShowMessageBox("Regions: type \"all\" or \"sel\".", SCRIPT, 0)
    return
  end
  outdir = (outdir or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]+$", "")
  if outdir == "" then return end
  opts = { mode = mode, outdir = outdir }
end

local ok, res = run(opts)
if _REGIONS_TO_PROJECTS_OPTS then
  _REGIONS_TO_PROJECTS_RESULT = { ok = ok, res = res }
elseif not ok then
  r.ShowMessageBox(res, SCRIPT, 0)
else
  r.ShowMessageBox(#res .. " project(s) saved in:\n" .. opts.outdir, SCRIPT, 0)
end
