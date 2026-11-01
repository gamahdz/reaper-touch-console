local section = "REAPER_FX_UI"
local request_key = "request"
local response_key = "response"
local last_request = ""
local last_metronome_state = nil
local run_undo

local function encode(value)
  return (tostring(value):gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function split(value, separator)
  local fields = {}
  for field in (value .. separator):gmatch("(.-)" .. separator) do
    fields[#fields + 1] = field
  end
  return fields
end

local function decode(value)
  return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function get_track(index)
  if index == 0 then return reaper.GetMasterTrack(0) end
  return reaper.GetTrack(0, index - 1)
end

local function list_fx(request_id, track_index)
  local track = get_track(track_index)
  if not track then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end

  local records = {}
  for fx_index = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, fx_index, "")
    local enabled = reaper.TrackFX_GetEnabled(track, fx_index) and "1" or "0"
    local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
    records[#records + 1] = table.concat({ fx_index, enabled, encode(name), param_count }, ",")
  end

  reaper.SetExtState(section, response_key, request_id .. "|LIST|" .. table.concat(records, ";"), false)
end

local function list_params(request_id, track_index, fx_index)
  local track = get_track(track_index)
  if not track or fx_index < 0 or fx_index >= reaper.TrackFX_GetCount(track) then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Efecto no encontrado", false)
    return
  end

  local records = {}
  for param_index = 0, reaper.TrackFX_GetNumParams(track, fx_index) - 1 do
    local _, name = reaper.TrackFX_GetParamName(track, fx_index, param_index, "")
    local normalized = reaper.TrackFX_GetParamNormalized(track, fx_index, param_index)
    records[#records + 1] = table.concat({ param_index, string.format("%.6f", normalized), encode(name) }, ",")
  end

  reaper.SetExtState(section, response_key, request_id .. "|PARAMS|" .. table.concat(records, ";"), false)
end

local function set_param(request_id, track_index, fx_index, param_index, value)
  local track = get_track(track_index)
  if track and fx_index >= 0 and fx_index < reaper.TrackFX_GetCount(track)
    and param_index >= 0 and param_index < reaper.TrackFX_GetNumParams(track, fx_index) then
    reaper.TrackFX_SetParamNormalized(track, fx_index, param_index, math.max(0, math.min(1, value)))
  end
end

local function list_track_fx(request_id, track_index)
  local track = get_track(track_index)
  if not track then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local records = {}
  for fx_index = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, fx_index, "")
    records[#records + 1] = table.concat({
      fx_index, reaper.TrackFX_GetEnabled(track, fx_index) and "1" or "0", encode(name),
      reaper.TrackFX_GetOpen(track, fx_index) and "1" or "0"
    }, ",")
  end
  reaper.SetExtState(section, response_key, request_id .. "|TRACKFX|" .. track_index .. "|" .. table.concat(records, ";"), false)
end

local function search_installed_fx(request_id, query)
  local normalized_query = string.lower(query or "")
  local records = {}
  local index = 0
  while #records < 100 do
    local found, name, ident = reaper.EnumInstalledFX(index)
    if not found then break end
    if normalized_query == "" or string.find(string.lower(name), normalized_query, 1, true) then
      records[#records + 1] = table.concat({ encode(ident), encode(name) }, ",")
    end
    index = index + 1
  end
  reaper.SetExtState(section, response_key, request_id .. "|FXOPTIONS|" .. encode(query or "") .. "|" .. table.concat(records, ";"), false)
end

local function mutate_track_fx(request_id, track_index, action, fx_index, fx_ident)
  local track = get_track(track_index)
  if not track then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local ok, err = run_undo("Update track FX", function()
    if action == "TOGGLE_TRACK_FX" then
      assert(fx_index >= 0 and fx_index < reaper.TrackFX_GetCount(track), "Effect not found")
      reaper.TrackFX_SetEnabled(track, fx_index, not reaper.TrackFX_GetEnabled(track, fx_index))
    elseif action == "DELETE_TRACK_FX" then
      assert(fx_index >= 0 and fx_index < reaper.TrackFX_GetCount(track), "Effect not found")
      assert(reaper.TrackFX_Delete(track, fx_index), "Could not delete effect")
    elseif action == "ADD_TRACK_FX" then
      assert(fx_ident and fx_ident ~= "", "Select an effect to add")
      local position = -1000 - reaper.TrackFX_GetCount(track)
      local added_index = reaper.TrackFX_AddByName(track, fx_ident, false, position)
      assert(added_index >= 0, "Could not add effect")
    end
  end)
  if not ok then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false)
    return
  end
  list_track_fx(request_id, track_index)
end

local function track_number(track)
  if not track then return -1 end
  local number = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
  return number < 0 and 0 or number
end

local function track_name(track)
  if not track then return "" end
  local _, name = reaper.GetTrackName(track, "")
  return name
end

run_undo = function(description, callback)
  reaper.Undo_BeginBlock2(0)
  local ok, result = pcall(callback)
  reaper.Undo_EndBlock2(0, description, -1)
  if ok then
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end
  return ok, result
end

local function rename_track(request_id, track_index, name)
  local track = get_track(track_index)
  if not track or track_index == 0 then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local ok, err = run_undo("Rename track", function()
    assert(reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true), "Could not rename track")
  end)
  if not ok then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false)
    return
  end
  reaper.SetExtState(section, response_key, request_id .. "|TRACKNAME|" .. track_index .. "|" .. encode(name), false)
end

local function delete_track(request_id, track_index)
  local track = get_track(track_index)
  if not track or track_index <= 0 then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local ok, err = run_undo("Delete track", function()
    reaper.DeleteTrack(track)
  end)
  if not ok then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false)
    return
  end
  reaper.SetExtState(section, response_key, request_id .. "|TRACKDELETED|" .. track_index, false)
end

local function move_track(request_id, source_index, destination_index)
  local track_count = reaper.CountTracks(0)
  local source_track = get_track(source_index)
  local destination_track = nil
  if destination_index ~= 0 then destination_track = get_track(destination_index) end
  if not source_track or (destination_index ~= 0 and not destination_track)
    or source_index <= 0 or destination_index < 0 then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  if source_index == destination_index then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Choose a different destination", false)
    return
  end

  local selection = {}
  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
    selection[#selection + 1] = { track = track, selected = reaper.IsTrackSelected(track) }
  end

  local ok, err = run_undo("Move track", function()
    for _, entry in ipairs(selection) do
      reaper.SetTrackSelected(entry.track, false)
    end
    reaper.SetTrackSelected(source_track, true)
    local before_track_index = destination_index == 0 and track_count or destination_index - 1
    local moved = reaper.ReorderSelectedTracks(before_track_index, 0)
    for _, entry in ipairs(selection) do
      if reaper.ValidatePtr2(0, entry.track, "MediaTrack*") then
        reaper.SetTrackSelected(entry.track, entry.selected)
      end
    end
    assert(moved, "Could not move track")
  end)
  if not ok then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false)
    return
  end
  reaper.SetExtState(section, response_key, request_id .. "|TRACKMOVED|" .. source_index .. "|" .. destination_index, false)
end

local function get_input_options()
  local options = { "-1,No%20input" }
  local input_count = reaper.GetNumAudioInputs()
  for index = 0, input_count - 1 do
    local name = reaper.GetInputChannelName(index) or ("Input " .. (index + 1))
    options[#options + 1] = table.concat({ index, encode(name .. " mono") }, ",")
    if index % 2 == 0 and index + 1 < input_count then
      local right_name = reaper.GetInputChannelName(index + 1) or ("Input " .. (index + 2))
      options[#options + 1] = table.concat({ index + 1024, encode(name .. " / " .. right_name) }, ",")
    end
  end

  options[#options + 1] = table.concat({ 4096 + 63 * 32, encode("MIDI: all inputs") }, ",")
  for index = 0, reaper.GetNumMIDIInputs() - 1 do
    local _, name = reaper.GetMIDIInputName(index, "")
    if not name or name == "" then name = "Input " .. (index + 1) end
    options[#options + 1] = table.concat({ 4096 + index * 32, encode("MIDI: " .. (name or ("Input " .. (index + 1)))) }, ",")
  end
  return table.concat(options, ";")
end

local function get_output_options()
  local options = {}
  local output_count = reaper.GetNumAudioOutputs()
  for index = 0, output_count - 1 do
    local name = reaper.GetOutputChannelName(index) or ("Output " .. (index + 1))
    options[#options + 1] = table.concat({ index + 1024, encode(name .. " mono") }, ",")
    if index % 2 == 0 and index + 1 < output_count then
      local right_name = reaper.GetOutputChannelName(index + 1) or ("Output " .. (index + 2))
      options[#options + 1] = table.concat({ index, encode(name .. " / " .. right_name) }, ",")
    end
  end
  return table.concat(options, ";")
end

local function get_midi_output_options()
  local options = { "-1,No%20MIDI%20output" }
  for index = 0, reaper.GetNumMIDIOutputs() - 1 do
    local _, name = reaper.GetMIDIOutputName(index, "")
    if not name or name == "" then name = "Output " .. (index + 1) end
    options[#options + 1] = table.concat({ index * 32, encode(name .. " - all channels") }, ",")
    for channel = 1, 16 do
      options[#options + 1] = table.concat({ index * 32 + channel, encode((name or ("MIDI " .. (index + 1))) .. " - channel " .. channel) }, ",")
    end
  end
  return table.concat(options, ";")
end

local function get_hardware_outputs(track)
  local records = {}
  for index = 0, reaper.GetTrackNumSends(track, 1) - 1 do
    local destination = math.floor(reaper.GetTrackSendInfo_Value(track, 1, index, "I_DSTCHAN"))
    local output_index = destination % 1024
    local mono = math.floor(destination / 1024) % 2 == 1
    local name = reaper.GetOutputChannelName(output_index) or ("Output " .. (output_index + 1))
    if not mono then
      local second_name = reaper.GetOutputChannelName(output_index + 1) or ("Output " .. (output_index + 2))
      name = name .. " / " .. second_name
    else
      name = name .. " mono"
    end
    records[#records + 1] = table.concat({
      index, encode(name),
      string.format("%.4f", reaper.GetTrackSendInfo_Value(track, 1, index, "D_VOL")),
      string.format("%.4f", reaper.GetTrackSendInfo_Value(track, 1, index, "D_PAN")),
      reaper.GetTrackSendInfo_Value(track, 1, index, "B_MUTE") > 0 and "1" or "0",
      math.floor(reaper.GetTrackSendInfo_Value(track, 1, index, "I_SRCCHAN")), destination
    }, ",")
  end
  return table.concat(records, ";")
end

local function list_io(request_id, track_index)
  local track = get_track(track_index)
  if not track then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local response = table.concat({
    request_id, "IO", track_index,
    math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT")),
    reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND") > 0 and "1" or "0",
    math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")),
    get_input_options(), get_output_options(), get_hardware_outputs(track),
    math.floor(reaper.GetMediaTrackInfo_Value(track, "I_MIDIHWOUT")), get_midi_output_options()
  }, "|")
  reaper.SetExtState(section, response_key, response, false)
end

local function get_send_records(track, category)
  local records = {}
  for index = 0, reaper.GetTrackNumSends(track, category) - 1 do
    local peer = reaper.GetTrackSendInfo_Value(track, category, index, category < 0 and "P_SRCTRACK" or "P_DESTTRACK")
    records[#records + 1] = table.concat({
      index, track_number(peer), encode(track_name(peer)),
      string.format("%.4f", reaper.GetTrackSendInfo_Value(track, category, index, "D_VOL")),
      string.format("%.4f", reaper.GetTrackSendInfo_Value(track, category, index, "D_PAN")),
      reaper.GetTrackSendInfo_Value(track, category, index, "B_MUTE") > 0 and "1" or "0",
      math.floor(reaper.GetTrackSendInfo_Value(track, category, index, "I_SENDMODE")),
      math.floor(reaper.GetTrackSendInfo_Value(track, category, index, "I_SRCCHAN")),
      math.floor(reaper.GetTrackSendInfo_Value(track, category, index, "I_DSTCHAN")),
      peer and math.floor(reaper.GetMediaTrackInfo_Value(peer, "I_NCHAN")) or 2
    }, ",")
  end
  return table.concat(records, ";")
end

local function list_routes(request_id, track_index)
  local track = get_track(track_index)
  if not track then
    reaper.SetExtState(section, response_key, request_id .. "|ERROR|Track not found", false)
    return
  end
  local tracks = {}
  for index = 0, reaper.CountTracks(0) - 1 do
    local destination = reaper.GetTrack(0, index)
    tracks[#tracks + 1] = table.concat({ index + 1, encode(track_name(destination)), math.floor(reaper.GetMediaTrackInfo_Value(destination, "I_NCHAN")) }, ",")
  end
  local response = table.concat({
    request_id, "ROUTES", track_index,
    math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")),
    table.concat(tracks, ";"), get_send_records(track, 0), get_send_records(track, -1)
  }, "|")
  reaper.SetExtState(section, response_key, response, false)
end

local function set_track_value(request_id, track_index, attribute, value, undo_label)
  local track = get_track(track_index)
  local allowed = { I_RECINPUT = true, I_MIDIHWOUT = true, B_MAINSEND = true, I_NCHAN = true }
  if not track or not allowed[attribute] then return end
  local ok, err = run_undo(undo_label, function()
    assert(reaper.SetMediaTrackInfo_Value(track, attribute, value), "Could not update track")
  end)
  if not ok then reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false) end
  return ok
end

local function add_hardware_output(request_id, track_index, destination, source)
  local track = get_track(track_index)
  if not track then return end
  local ok, err = run_undo("Add hardware output", function()
    local send_index = reaper.CreateTrackSend(track, nil)
    assert(send_index >= 0, "Could not create hardware output")
    reaper.SetTrackSendInfo_Value(track, 1, send_index, "I_DSTCHAN", destination)
    reaper.SetTrackSendInfo_Value(track, 1, send_index, "I_SRCCHAN", source)
  end)
  if not ok then reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false) end
  return ok
end

local function mutate_send(request_id, track_index, category, send_index, attribute, value)
  local track = get_track(track_index)
  local allowed = { B_MUTE = true, D_VOL = true, D_PAN = true, I_SENDMODE = true, I_SRCCHAN = true, I_DSTCHAN = true }
  if not track or not allowed[attribute] then return end
  local ok, err = run_undo("Update routing", function()
    assert(reaper.SetTrackSendInfo_Value(track, category, send_index, attribute, value), "Could not update routing")
  end)
  if not ok then reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false) end
  return ok
end

local function update_routing(request_id, track_index, action, send_index, value)
  local track = get_track(track_index)
  if not track then return end
  local ok, err = run_undo("Update routing", function()
    if action == "ADD_SEND" then
      local destination = get_track(tonumber(value) or -1)
      assert(destination and destination ~= track, "Select a different track")
      assert(reaper.CreateTrackSend(track, destination) >= 0, "Could not create send")
    elseif action == "REMOVE_SEND" then
      assert(reaper.RemoveTrackSend(track, 0, send_index), "Could not remove send")
    elseif action == "REMOVE_RECV" then
      assert(reaper.RemoveTrackSend(track, -1, send_index), "Could not remove receive")
    elseif action == "REMOVE_HW" then
      assert(reaper.RemoveTrackSend(track, 1, send_index), "Could not remove hardware output")
    end
  end)
  if not ok then reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false) end
  return ok
end

local function get_transport_progress(request_id)
  local pos = reaper.GetPlayPosition()
  local length = reaper.GetProjectLength(0)
  reaper.SetExtState(section, response_key, request_id .. "|PROGRESS|" .. string.format("%.6f", pos) .. "," .. string.format("%.6f", length), false)
end

local function seek_transport(position)
  local length = reaper.GetProjectLength(0)
  local target = math.max(0, math.min(length, position))
  reaper.SetEditCurPos(target, false, true)
end

local function process_request(request)
  local fields = split(request, "|")
  local command = fields[1]
  local request_id = fields[2]
  if not request_id then return end

  if command == "LIST" then
    list_fx(request_id, tonumber(fields[3]) or 0)
  elseif command == "SETTRACKNAME" then
    rename_track(request_id, tonumber(fields[3]) or -1, decode(fields[4]))
  elseif command == "DELETETRACK" then
    delete_track(request_id, tonumber(fields[3]) or -1)
  elseif command == "MOVETRACK" then
    move_track(request_id, tonumber(fields[3]) or -1, tonumber(fields[4]) or -1)
  elseif command == "GETTRACKFX" then
    list_track_fx(request_id, tonumber(fields[3]) or 0)
  elseif command == "SEARCHFX" then
    search_installed_fx(request_id, decode(fields[3]))
  elseif command == "TRACKFXACTION" then
    mutate_track_fx(request_id, tonumber(fields[3]) or 0, fields[4], tonumber(fields[5]) or -1, decode(fields[6]))
  elseif command == "PARAMS" then
    list_params(request_id, tonumber(fields[3]) or 0, tonumber(fields[4]) or -1)
  elseif command == "SET" then
    set_param(request_id, tonumber(fields[3]) or 0, tonumber(fields[4]) or -1,
      tonumber(fields[5]) or -1, tonumber(fields[6]) or 0)
  elseif command == "PROGRESS" then
    get_transport_progress(request_id)
  elseif command == "SEEK" then
    seek_transport(tonumber(fields[3]) or 0)
  elseif command == "GETIO" then
    list_io(request_id, tonumber(fields[3]) or 0)
  elseif command == "GETROUTES" then
    list_routes(request_id, tonumber(fields[3]) or 0)
  elseif command == "SETINPUT" then
    if set_track_value(request_id, tonumber(fields[3]) or -1, "I_RECINPUT", tonumber(fields[4]) or -1, "Set recording input") then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETMIDIOUT" then
    if set_track_value(request_id, tonumber(fields[3]) or -1, "I_MIDIHWOUT", tonumber(fields[4]) or -1, "Set MIDI hardware output") then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETMAIN" then
    if set_track_value(request_id, tonumber(fields[3]) or -1, "B_MAINSEND", tonumber(fields[4]) or 0, "Set master send") then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETNCHAN" then
    if set_track_value(request_id, tonumber(fields[3]) or -1, "I_NCHAN", tonumber(fields[4]) or 2, "Set track channels") then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "ADDHW" then
    if add_hardware_output(request_id, tonumber(fields[3]) or -1, tonumber(fields[4]) or 0, tonumber(fields[5]) or 0) then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETHW" then
    if mutate_send(request_id, tonumber(fields[3]) or -1, 1, tonumber(fields[4]) or -1, fields[5], tonumber(fields[6]) or 0) then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "REMOVEHW" then
    if update_routing(request_id, tonumber(fields[3]) or -1, "REMOVE_HW", tonumber(fields[4]) or -1) then
      list_io(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "ADDSEND" then
    if update_routing(request_id, tonumber(fields[3]) or -1, "ADD_SEND", -1, tonumber(fields[4]) or -1) then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETSEND" then
    if mutate_send(request_id, tonumber(fields[3]) or -1, 0, tonumber(fields[4]) or -1, fields[5], tonumber(fields[6]) or 0) then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "REMOVESEND" then
    if update_routing(request_id, tonumber(fields[3]) or -1, "REMOVE_SEND", tonumber(fields[4]) or -1) then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "SETRECV" then
    if mutate_send(request_id, tonumber(fields[3]) or -1, -1, tonumber(fields[4]) or -1, fields[5], tonumber(fields[6]) or 0) then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "REMOVERECV" then
    if update_routing(request_id, tonumber(fields[3]) or -1, "REMOVE_RECV", tonumber(fields[4]) or -1) then
      list_routes(request_id, tonumber(fields[3]) or 0)
    end
  elseif command == "TOGGLEPHASE" then
    local track = get_track(tonumber(fields[3]) or -1)
    if track then
      run_undo("Toggle track phase", function()
        local inverted = reaper.GetMediaTrackInfo_Value(track, "B_PHASE") > 0
        reaper.SetMediaTrackInfo_Value(track, "B_PHASE", inverted and 0 or 1)
      end)
    end
  end
end

local last_phase_state = nil
local last_phase_check = 0
local function publish_phase_state()
  local now = reaper.time_precise()
  if now - last_phase_check < 0.25 then return end
  last_phase_check = now

  local inverted = {}
  for i = 0, reaper.CountTracks(0) do
    local track = get_track(i)
    if track and reaper.GetMediaTrackInfo_Value(track, "B_PHASE") > 0 then inverted[#inverted + 1] = i end
  end
  local state = table.concat(inverted, ",")
  if state ~= last_phase_state then
    last_phase_state = state
    reaper.SetExtState(section, "phase", state, false)
  end
end

local function loop()
  local metronome_state = reaper.GetToggleCommandState(40364) == 1 and "1" or "0"
  if metronome_state ~= last_metronome_state then
    last_metronome_state = metronome_state
    reaper.SetExtState(section, "metronome", metronome_state, false)
  end

  local request = reaper.GetExtState(section, request_key)
  if request ~= "" and request ~= last_request then
    last_request = request
    local ok, err = pcall(process_request, request)
    if not ok then
      local request_id = split(request, "|")[2] or "0"
      reaper.SetExtState(section, response_key, request_id .. "|ERROR|" .. encode(err), false)
    end
  end

  pcall(publish_phase_state)
  reaper.defer(loop)
end

reaper.SetExtState(section, response_key, "READY", false)
loop()
