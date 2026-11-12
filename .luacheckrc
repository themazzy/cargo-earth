-- luacheck settings for the mod (BeamNG runs LuaJIT; these are the game's globals the mod uses).
std = 'luajit'
max_line_length = false
unused = false
globals = { 'log', 'FS', 'jsonReadFile', 'jsonWriteFile', 'jsonDecode', 'jsonEncode', 'extensions', 'be', 'map', 'vec3', 'quat',
  'getObjectByID', 'getPlayerVehicle', 'core_vehicles', 'core_vehicle_manager', 'core_vehicle_partmgmt', 'serialize',
  'deepcopy', 'dumps', 'Engine', 'ui_message', 'castRayStatic', 'debugDrawer', 'ColorF', 'ColorI', 'Point2F', 'Point3F',
  'setExtensionUnloadMode', 'obj', 'sensors', 'energyStorage', 'beamng_versiond', 'getVersion', 'scenetree', 'createObject',
  'guihooks', 'ui_imgui', 'core_camera', 'getCameraPosition', 'core_groundMarkers', 'spawn', 'commands', 'worldEditorCppApi',
  'Sim', 'electrics', 'String', 'TorqueScriptLua', 'socket', 'im', 'ffi', 'tableSize', 'shallowcopy', 'float3', 'core_trailerRespawn',
  'core_vehicleBridge', 'gameplay_traffic', 'core_environment', 'MPCoreNetwork', 'career_career', 'simTimeAuthority', 'bullettime', 'render_openxr' }
