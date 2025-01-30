obs = obslua

filters = {}
filter_info = {}
filter_info.id = "link-source-visible"
filter_info.type = obs.OBS_SOURCE_TYPE_FILTER
filter_info.output_flags = obs.OBS_SOURCE_VIDEO
filter_info.get_name = function()
    return "Hide when game not active"
end
filter_info.get_width = function(filter)
  local target = obs.obs_filter_get_target(filter.source)
  if target == nil then
    return 0
  end
  return obs.obs_source_get_base_width(target)
end
filter_info.get_height = function(filter)
  local target = obs.obs_filter_get_target(filter.source)
  if target == nil then
    return 0
  end
  return obs.obs_source_get_base_height(target)
end
filter_info.video_render = function(filter)
  if obs.obs_source_process_filter_begin(filter.source, obs.GS_RGBA, obs.OBS_ALLOW_DIRECT_RENDERING) then
      obs.obs_source_process_filter_end(filter.source, filter.effect, filter_info.get_width(filter), filter_info.get_height(filter))
  end
end
filter_info.create = function(settings, source)
  local filter = {}
  filter.source = source
  filter.target = nil
  filter.on_hooked = function()
    print(obs.obs_source_get_name(filter.target).." active")
    set_source_visible(obs.obs_filter_get_parent(filter.source), true)
  end
  filter.on_unhooked = function()
    print(obs.obs_source_get_name(filter.target).." inactive")
    set_source_visible(obs.obs_filter_get_parent(filter.source), false)
  end
  obs.obs_enter_graphics()
  filter.effect = obs.gs_effect_create(shader, nil, nil)
  obs.obs_leave_graphics()
  filter_info.update(filter, settings)
  print("Filter created")
  table.insert(filters, filter)
  return filter
end
filter_info.destroy = function(filter)
  if filter.target ~= nil then
    filter:on_unhooked()
  end
  filter_unhook(filter)
  if filter.effect ~= nil then
    obs.obs_enter_graphics()
    obs.gs_effect_destroy(filter.effect)
    obs.obs_leave_graphics()
  end
  for i, v in ipairs(filters) do
    if v == filter then
      table.remove(filters, i)
      break
    end
  end
  filter = nil
end
filter_info.get_properties = function(settings)
  local props = obs.obs_properties_create()
  local prop = obs.obs_properties_add_list(
    props,
    "source",
    "Source",
    obs.OBS_COMBO_TYPE_RADIO,
    obs.OBS_COMBO_FORMAT_STRING
  )
  obs.obs_property_list_add_string(prop, "(None)", "")
  local sources = obs.obs_enum_sources()
  if sources then
    for _, source in ipairs(sources) do
      local id = obs.obs_source_get_id(source)
      local type = obs.obs_source_get_display_name(id)
      if type == "Game Capture" or type == "Window Capture" then
        local name = obs.obs_source_get_name(source)
        local uuid = obs.obs_source_get_uuid(source)
        obs.obs_property_list_add_string(prop, name, uuid)
      end
    end
  end
  obs.source_list_release(sources)
  return props
end
filter_info.get_defaults = function(settings)
  obs.obs_data_set_default_string(settings, "source", "")
end
filter_info.update = function(filter, settings)
  filter_unhook(filter)
  local uuid = obs.obs_data_get_string(settings, "source")
  filter.target = obs.obs_get_source_by_uuid(uuid)
  if filter.target == nil then
    print("Unable to find: "..uuid)
    return
  end
  if is_hooked(filter.target) then
    filter:on_hooked()
  else
    filter:on_unhooked()
  end
  print("Connecting events")
  local handler = obs.obs_source_get_signal_handler(filter.target)
  obs.signal_handler_connect(handler, "hooked", on_hooked)
  obs.signal_handler_connect(handler, "unhooked", on_unhooked)
end

function filter_unhook(filter)
  if filter.target == nil then
    return
  end
  -- print("Disconnecting events")
  -- local handler = obs.obs_source_get_signal_handler(filter.target)
  -- obs.signal_handler_disconnect(handler, "hooked", on_hooked)
  -- obs.signal_handler_disconnect(handler, "unhooked", on_unhooked)
  print("Releasing target source")
  obs.obs_source_release(filter.target)
  filter.target = nil
end

function on_hooked(data)
  local source = obs.calldata_source(data, "source")
  local uuid = obs.obs_source_get_uuid(source)
  for _, filter in ipairs(filters) do
    local filterUuid = obs.obs_source_get_uuid(filter.target)
    if uuid == filterUuid then
      filter:on_hooked()
    end
  end
end
function on_unhooked(data)
  local source = obs.calldata_source(data, "source")
  local uuid = obs.obs_source_get_uuid(source)
  for _, filter in ipairs(filters) do
    local filterUuid = obs.obs_source_get_uuid(filter.target)
    if uuid == filterUuid then
      filter:on_unhooked()
    end
  end
end

function is_hooked(source)
  local calldata = obs.calldata_create()
  local handler = obs.obs_source_get_proc_handler(source)
  obs.proc_handler_call(handler, "get_hooked", calldata)
  local hooked = obs.calldata_bool(calldata, "hooked")
  obs.calldata_destroy(calldata)
  return hooked
end

function set_source_visible(source, visible)
  if source == nil then
    return
  end
  local scenes = obs.obs_frontend_get_scenes()
  if scenes == nil then
    return
  end
  local uuid = obs.obs_source_get_uuid(source)
  for _, sceneSource in ipairs(scenes) do
    local scene = obs.obs_scene_from_source(sceneSource)
    local sceneItems = obs.obs_scene_enum_items(scene)
    for i, sceneItem in ipairs(sceneItems) do
      local itemSource = obs.obs_sceneitem_get_source(sceneItem)
      local itemUuid = obs.obs_source_get_uuid(itemSource)
      if itemUuid == uuid then
        obs.obs_sceneitem_set_visible(sceneItem, visible)
      end
    end
    obs.sceneitem_list_release(sceneItems)
  end
  obs.source_list_release(scenes)
end

function script_load(settings)
  obs.obs_register_source(filter_info)
  print("Loaded script")
end

shader = [[
uniform float4x4 ViewProj;
uniform texture2d image;

sampler_state textureSampler {
    Filter    = Linear;
    AddressU  = Clamp;
    AddressV  = Clamp;
};

struct VertData {
    float4 pos : POSITION;
    float2 uv  : TEXCOORD0;
};

VertData VSDefault(VertData v_in)
{
    VertData vert_out;
    vert_out.pos = mul(float4(v_in.pos.xyz, 1.0), ViewProj);
    vert_out.uv  = v_in.uv;
    return vert_out;
}

float4 PassThrough(VertData v_in) : TARGET
{
  float4 orig = image.Sample(textureSampler, v_in.uv);
  return float4(orig.rgb, orig.a);
}

technique Draw
{
    pass
    {
        vertex_shader = VSDefault(v_in);
        pixel_shader  = PassThrough(v_in);
    }
}
]]
