-- Independent Monster Hunter Wilds skeleton, animation and collision viewer.

local game_name = reframework.get_game_name()
if game_name ~= "mhwilds" then return end

local ok_emv, EMV = pcall(require, "EMV Engine")
if not ok_emv or not EMV then
	log.warn("[Wilds Motion Viewer] EMV Engine helpers are required")
	return
end

log.info("[Wilds Motion Viewer] Loaded")

local is_valid_obj = EMV.is_valid_obj
local get_gameobj_path = EMV.get_gameobj_path
local get_children = EMV.get_children
local lua_get_system_array = EMV.lua_get_system_array

local scene_manager = sdk.get_native_singleton("via.SceneManager")
local scene_td = sdk.find_type_definition("via.SceneManager")
local object_key

local component_types = {
	"via.motion.Motion",
	"via.motion.MotionFsm2",
	"via.motion.ActorMotion",
	"via.motion.DummySkeleton",
	"via.motion.CustomSkeleton",
	"via.motion.Chain",
	"via.render.Mesh",
	"via.physics.CharacterController",
	"via.physics.Colliders",
	"via.physics.RequestSetCollider",
	"via.character.CollisionShapePreset",
	"via.dynamics.RigidBodySet",
}

local scan_modes = {"Player", "Monsters/Boss", "NPC/Life", "Scene collision", "All"}
local position_modes = {"WorldMatrix", "Position", "Transform+BaseLocal"}

local state = {
	objects = {},
	selected_idx = 1,
	scan_mode = 1,
	filter = "",
	radius = 80.0,
	near_player = false,
	max_results = 250,
	joint_limit = 220,
	joint_limit_text = "220",
	draw_skeleton = true,
	show_joint_names = false,
	position_mode = 2,
	draw_collision = false,
	collision_labels = false,
	collision_debug = true,
	collision_limit = 180,
	anim_bank_idx = 0,
	use_current_node_bank = true,
	anim_selected_idx = 1,
	anim_loop_a = nil,
	anim_loop_b = nil,
	anim_seek_all = false,
	anim_enabled_layers = {},
	motion_owner_idx = 1,
	anim_probe_limit = 220,
	anim_debug = true,
	anim_loop = false,
	status = "",
}

local function safe_call(obj, method, ...)
	if not obj or not obj.call then return nil end
	local ok, value = pcall(obj.call, obj, method, ...)
	if ok then return value end
end

local function get_scene()
	if not scene_manager or not scene_td then return nil end
	local ok, value = pcall(sdk.call_native_func, scene_manager, scene_td, "get_CurrentScene")
	if ok then return value end
end

local function get_elements(arr)
	if not arr then return {} end
	return (arr.get_elements and arr:get_elements()) or lua_get_system_array(arr, true) or {}
end

local function get_gameobject(xform)
	return safe_call(xform, "get_GameObject")
end

local function get_name(gameobj)
	return safe_call(gameobj, "get_Name") or tostring(gameobj)
end

local function get_position(xform)
	return safe_call(xform, "get_Position")
end

local function distance(a, b)
	if not a or not b then return nil end
	local dx = (a.x or 0) - (b.x or 0)
	local dy = (a.y or 0) - (b.y or 0)
	local dz = (a.z or 0) - (b.z or 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function type_name(obj)
	local td = obj and obj.get_type_definition and obj:get_type_definition()
	return td and (td:get_full_name() or td:get_name()) or tostring(obj)
end

local function resource_text(obj)
	if not obj then return nil end
	return safe_call(obj, "get_ResourcePath") or safe_call(obj, "get_Path") or safe_call(obj, "get_Name") or safe_call(obj, "ToString()") or tostring(obj)
end

local function safe_field_data(obj, field)
	if not obj or not field then return nil end
	local ok, value = pcall(field.get_data, field, obj)
	if ok then return value end
end

local function get_fields(obj)
	local td = obj and obj.get_type_definition and obj:get_type_definition()
	if not td then return {} end
	local ok, fields = pcall(td.get_fields, td)
	if ok and fields then return fields end
	return {}
end

local function field_type_name(field)
	local ok, ftype = pcall(field.get_type, field)
	if ok and ftype then
		return ftype:get_full_name() or ftype:get_name() or ""
	end
	return ""
end

local function field_name(field)
	local ok, name = pcall(field.get_name, field)
	return ok and name or "?"
end

local function get_methods(obj_or_td, pattern)
	local td = obj_or_td
	if obj_or_td and obj_or_td.get_type_definition then
		td = obj_or_td:get_type_definition()
	end
	if not td then return {} end
	local ok, methods = pcall(td.get_methods, td)
	if not ok or not methods then return {} end
	local out = {}
	for _, method in ipairs(methods) do
		local name = method:get_name()
		if not pattern or name:find(pattern, 1, true) then table.insert(out, method) end
	end
	return out
end

local function method_signature(method)
	local params = method:get_param_types()
	local parts = {}
	for i, param in ipairs(params or {}) do
		table.insert(parts, param:get_full_name() or param:get_name() or "?")
	end
	return method:get_name() .. "(" .. table.concat(parts, ", ") .. ")"
end

local function vt_field(v, name)
	if not v or not v.get_field then return nil end
	local ok, value = pcall(v.get_field, v, name)
	if ok then return value end
end

local function vt_vec3(v)
	if not v then return nil end
	local x = vt_field(v, "x") or vt_field(v, "X")
	local y = vt_field(v, "y") or vt_field(v, "Y")
	local z = vt_field(v, "z") or vt_field(v, "Z")
	if x and y and z then return Vector3f.new(x, y, z) end
end

local function vt_radius(v)
	return vt_field(v, "r") or vt_field(v, "R") or vt_field(v, "w") or vt_field(v, "W") or vt_field(v, "radius") or vt_field(v, "Radius")
end

local function vt_point(v, names)
	for _, name in ipairs(names) do
		local value = vt_field(v, name)
		local vec = vt_vec3(value) or value
		if vec and vec.x and vec.y and vec.z then return vec end
	end
end

local function has_component(gameobj, type_name)
	if not sdk.find_type_definition(type_name) then return nil end
	return safe_call(gameobj, "getComponent(System.Type)", sdk.typeof(type_name))
end

local function get_components(gameobj)
	local out = {}
	for _, type_name in ipairs(component_types) do
		local comp = has_component(gameobj, type_name)
		if comp then out[type_name] = comp end
	end
	return out
end

local function component_summary(item)
	local parts = {}
	for _, type_name in ipairs(component_types) do
		if item.components[type_name] then
			table.insert(parts, type_name:match("[^%.]+$") or type_name)
		end
	end
	return table.concat(parts, ",")
end

local function get_joints(xform)
	return get_elements(safe_call(xform, "get_Joints"))
end

local function get_child_items(root_item, depth, out)
	out = out or {}
	if not root_item or not root_item.xform or depth <= 0 then return out end
	for _, child_xform in ipairs(get_children(root_item.xform) or {}) do
		local gameobj = get_gameobject(child_xform)
		if gameobj then
			local item = {
				xform = child_xform,
				gameobj = gameobj,
				name = get_name(gameobj),
				components = get_components(gameobj),
				position = get_position(child_xform),
			}
			item.joint_count = #get_joints(child_xform)
			table.insert(out, item)
			get_child_items(item, depth - 1, out)
		end
	end
	return out
end

local function has_any_component(item, names)
	for _, name in ipairs(names) do
		if item.components[name] then return true end
	end
	return false
end

local function item_matches_mode(item, mode_name)
	local lname = (item.name or ""):lower()
	if mode_name == "Player" then
		return lname:find("masterplayer", 1, true) or lname:find("player", 1, true)
	end
	if mode_name == "Monsters/Boss" then
		return lname:find("em", 1, true) or lname:find("boss", 1, true) or lname:find("enemy", 1, true)
	end
	if mode_name == "NPC/Life" then
		return lname:find("npc", 1, true) or lname:find("otomo", 1, true) or lname:find("animal", 1, true) or lname:find("life", 1, true)
	end
	if mode_name == "Scene collision" then
		return has_any_component(item, {"via.physics.Colliders", "via.physics.RequestSetCollider", "via.character.CollisionShapePreset"})
	end
	return true
end

local function item_matches_filter(item)
	local filter = tostring(state.filter or ""):lower()
	if filter == "" then return true end
	local lname = tostring(item.name or ""):lower()
	local path = tostring(get_gameobj_path and get_gameobj_path(item.gameobj) or ""):lower()
	for term in filter:gmatch("%S+") do
		if lname:find(term, 1, true) or path:find(term, 1, true) then return true end
	end
	return false
end

local function find_player_pos()
	for _, item in ipairs(state.objects) do
		if item.name:lower():find("masterplayer", 1, true) then return item.position end
	end
end

local function score_item(item)
	local score = item.joint_count or 0
	if item.components["via.motion.Motion"] then score = score + 60 end
	if item.components["via.motion.MotionFsm2"] then score = score + 30 end
	if item.components["via.render.Mesh"] then score = score + 40 end
	if item.components["via.physics.Colliders"] then score = score + 15 end
	if item.name:lower():find("face", 1, true) then score = score - 120 end
	return score
end

local function scan_scene()
	state.objects = {}
	state.selected_idx = 1
	state.motion_owner_idx = 1
	state.anim_bank_idx = 0
	local scene = get_scene()
	if not scene then
		state.status = "No current scene"
		return
	end

	local mode_name = scan_modes[state.scan_mode] or "Player"
	local transforms = safe_call(scene, "findComponents(System.Type)", sdk.typeof("via.Transform"))
	local tmp = {}
	local scanned_player_pos
	for _, xform in ipairs(get_elements(transforms)) do
		if is_valid_obj(xform) then
			local gameobj = get_gameobject(xform)
			if gameobj then
				local item = {
					xform = xform,
					gameobj = gameobj,
					name = get_name(gameobj),
					components = get_components(gameobj),
					position = get_position(xform),
				}
				item.joint_count = #get_joints(xform)
				if item.name:lower():find("masterplayer", 1, true) then
					scanned_player_pos = item.position
				end
				if next(item.components) and item_matches_mode(item, mode_name) and item_matches_filter(item) then
					table.insert(tmp, item)
				end
			end
		end
	end

	local player_pos = scanned_player_pos or find_player_pos()
	for _, item in ipairs(tmp) do
		item.distance = player_pos and distance(item.position, player_pos) or nil
		if not state.near_player or not item.distance or item.distance <= state.radius then
			table.insert(state.objects, item)
		end
	end

	table.sort(state.objects, function(a, b)
		local sa, sb = score_item(a), score_item(b)
		if sa == sb then return tostring(a.name) < tostring(b.name) end
		return sa > sb
	end)

	while #state.objects > state.max_results do table.remove(state.objects) end
	state.status = "Found " .. tostring(#state.objects) .. " " .. mode_name .. " object(s)"
end

local function selected()
	return state.objects[state.selected_idx]
end

local function pick_owner(root_item, component_name, require_joints)
	if not root_item then return nil end
	local candidates = {root_item}
	for _, item in ipairs(get_child_items(root_item, 5)) do table.insert(candidates, item) end
	local best, best_score
	for _, item in ipairs(candidates) do
		if item.components[component_name] and (not require_joints or (item.joint_count or 0) > 0) then
			local score = score_item(item)
			if not best_score or score > best_score then
				best, best_score = item, score
			end
		end
	end
	return best
end

local function score_motion_owner(item)
	local score = score_item(item)
	local lname = tostring(item.name or ""):lower()
	local motion = item.components["via.motion.Motion"]
	local active_count = motion and (safe_call(motion, "getActiveMotionBankCount") or 0) or 0
	local dynamic_count = motion and (safe_call(motion, "getDynamicMotionBankCount") or 0) or 0
	score = score + active_count * 20 + dynamic_count * 5
	if lname:find("face", 1, true) then score = score - 10000 end
	if lname:find("masterplayer", 1, true) then score = score + 500 end
	if lname:find("body", 1, true) then score = score + 250 end
	if lname:find("player", 1, true) then score = score + 100 end
	return score
end

local function get_motion_candidates(root_item)
	local out = {}
	if not root_item then return out end
	local candidates = {root_item}
	for _, item in ipairs(get_child_items(root_item, 5)) do table.insert(candidates, item) end
	for _, item in ipairs(candidates) do
		if item.components["via.motion.Motion"] then
			item.motion_score = score_motion_owner(item)
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		if a.motion_score == b.motion_score then return tostring(a.name) < tostring(b.name) end
		return a.motion_score > b.motion_score
	end)
	return out
end

local function get_skeleton_owner(root_item)
	if root_item and (root_item.joint_count or 0) > 0 then return root_item end
	return pick_owner(root_item, "via.motion.CustomSkeleton", true)
		or pick_owner(root_item, "via.motion.DummySkeleton", true)
		or pick_owner(root_item, "via.render.Mesh", true)
end

local function get_motion_owner(root_item)
	local candidates = get_motion_candidates(root_item)
	if #candidates == 0 then return nil end
	state.motion_owner_idx = math.max(1, math.min(state.motion_owner_idx or 1, #candidates))
	return candidates[state.motion_owner_idx]
end

local function get_collision_owners(root_item)
	local out = {}
	if not root_item then return out end
	local candidates = {root_item}
	for _, item in ipairs(get_child_items(root_item, 9)) do table.insert(candidates, item) end
	for _, item in ipairs(candidates) do
		if has_any_component(item, {"via.physics.Colliders", "via.physics.RequestSetCollider", "via.character.CollisionShapePreset", "via.motion.Chain"}) then
			table.insert(out, item)
		end
	end
	return out
end

local function get_joint_position(item, joint)
	if state.position_mode == 1 then
		local mat = safe_call(joint, "get_WorldMatrix")
		return mat and mat[3]
	elseif state.position_mode == 3 then
		local base = safe_call(joint, "get_BaseLocalPosition")
		return (item.position and base) and (item.position + base) or safe_call(joint, "get_Position")
	end
	return safe_call(joint, "get_Position")
end

local function draw_world_line(a, b, color)
	local a2 = a and draw.world_to_screen(a)
	local b2 = b and draw.world_to_screen(b)
	if a2 and b2 then draw.line(a2.x, a2.y, b2.x, b2.y, color) end
end

local function draw_world_circle(center, radius, color)
	if not center or not radius or radius <= 0 then return end
	local last
	for i = 0, 32 do
		local a = (math.pi * 2.0) * (i / 32.0)
		local p = center + Vector3f.new(math.cos(a) * radius, 0.0, math.sin(a) * radius)
		local p2 = draw.world_to_screen(p)
		if last and p2 then draw.line(last.x, last.y, p2.x, p2.y, color) end
		last = p2
	end
end

local function draw_skeleton_overlay(root_item)
	if not state.draw_skeleton then return end
	local owner = get_skeleton_owner(root_item)
	if not owner then return end
	local joints = get_joints(owner.xform)
	local joint_set = {}
	for _, joint in ipairs(joints) do joint_set[joint] = true end
	local limit = math.min(#joints, state.joint_limit)
	for i = 1, limit do
		local joint = joints[i]
		local parent = safe_call(joint, "get_Parent")
		if parent and joint_set[parent] then
			local a = get_joint_position(owner, parent)
			local b = get_joint_position(owner, joint)
			draw_world_line(a, b, 0xFF00FFFF)
		end
		if state.show_joint_names then
			local pos = get_joint_position(owner, joint)
			if pos then draw.world_text(safe_call(joint, "get_Name") or tostring(i), pos, 0xFFFFFF00) end
		end
	end
end

local function get_shape_center(shape, fallback)
	return safe_call(shape, "get_Position")
		or safe_call(shape, "get_Center")
		or safe_call(shape, "getCenter")
		or fallback
end

local function get_shape_radius(shape)
	return safe_call(shape, "get_Radius")
		or safe_call(shape, "getRadius")
		or safe_call(shape, "get_R")
end

local function get_shape_point(shape, names)
	for _, name in ipairs(names) do
		local value = safe_call(shape, name)
		if value then return value end
	end
end

local function draw_shape(shape, fallback_pos, color)
	if not shape then return end
	local tn = type_name(shape):lower()
	local center = get_shape_center(shape, fallback_pos)
	local radius = get_shape_radius(shape)
	local shape_value
	for _, field in ipairs(get_fields(shape)) do
		local ftype = field_type_name(field):lower()
		local fname = field_name(field):lower()
		if ftype:find("sphere", 1, true) or ftype:find("capsule", 1, true) or ftype:find("obb", 1, true) or ftype:find("aabb", 1, true)
			or fname:find("sphere", 1, true) or fname:find("capsule", 1, true) or fname:find("box", 1, true) then
			shape_value = safe_field_data(shape, field)
			break
		end
	end
	if tn:find("capsule", 1, true) then
		local a = get_shape_point(shape, {"get_PointA", "get_Start", "get_P0", "get_BeginPosition"})
			or vt_point(shape_value, {"p0", "P0", "point0", "Point0", "start", "Start", "v0", "V0", "p0_", "P0_"})
			or center
		local b = get_shape_point(shape, {"get_PointB", "get_End", "get_P1", "get_EndPosition"})
			or vt_point(shape_value, {"p1", "P1", "point1", "Point1", "end", "End", "v1", "V1", "p1_", "P1_"})
			or center
		radius = radius or vt_radius(shape_value)
		if radius and radius > 0 and radius < 20.0 then
			draw_world_line(a, b, color)
			draw_world_circle(a, radius, color)
			draw_world_circle(b, radius, color)
		end
	elseif tn:find("sphere", 1, true) then
		center = center or vt_vec3(shape_value)
		radius = radius or vt_radius(shape_value)
		if radius and radius > 0 and radius < 20.0 then draw_world_circle(center, radius, color) end
	elseif tn:find("box", 1, true) or tn:find("aabb", 1, true) then
		center = center or vt_vec3(shape_value)
		if center then draw_world_circle(center, radius or 0.35, color) end
	end
end

local function get_collider_list(colliders)
	if not colliders then return {} end
	local count = safe_call(colliders, "get_NumColliders")
	if count and count > 0 then
		local out = {}
		for i = 0, count - 1 do
			local collider = safe_call(colliders, "getColliders", i)
			if collider then table.insert(out, collider) end
		end
		if #out > 0 then return out end
	end
	for _, field in ipairs(get_fields(colliders)) do
		local value = safe_field_data(colliders, field)
		local elements = get_elements(value)
		if #elements > 0 then
			local out = {}
			for _, element in ipairs(elements) do
				if type_name(element):find("via.physics.Collider", 1, true) then table.insert(out, element) end
			end
			if #out > 0 then return out end
		end
	end
	return {}
end

local function get_collider_shape(collider)
	if not collider then return nil end
	local shape = safe_call(collider, "get_TransformedShape") or safe_call(collider, "get_Shape")
	if shape then return shape end
	for _, field in ipairs(get_fields(collider)) do
		local value = safe_field_data(collider, field)
		local tn = type_name(value)
		if tn:find("via.physics.", 1, true) and tn:find("Shape", 1, true) then
			return value
		end
	end
end

object_key = function(obj)
	if not obj then return nil end
	if obj.get_address then
		local ok, addr = pcall(obj.get_address, obj)
		if ok and addr then return tostring(addr) end
	end
	return tostring(obj)
end

local function is_shape_object(obj)
	local tn = type_name(obj):lower()
	return tn:find("via.physics.", 1, true) and tn:find("shape", 1, true)
end

local function add_unique(out, value)
	if not value then return end
	out._seen = out._seen or {}
	local key = object_key(value)
	if key and not out._seen[key] then
		out._seen[key] = true
		table.insert(out, value)
	end
end

local function collect_field_shapes(obj, out, seen, depth)
	out = out or {}
	seen = seen or {}
	if not obj or depth <= 0 or #out >= state.collision_limit then return out end
	local key = object_key(obj)
	if key and seen[key] then return out end
	if key then seen[key] = true end
	if is_shape_object(obj) then add_unique(out, obj) end
	if type_name(obj):find("via.physics.Collider", 1, true) then
		add_unique(out, get_collider_shape(obj))
	end
	for _, field in ipairs(get_fields(obj)) do
		local value = safe_field_data(obj, field)
		if value then
			if is_shape_object(value) or type_name(value):find("via.physics.Collider", 1, true) then
				collect_field_shapes(value, out, seen, depth - 1)
			else
				for _, element in ipairs(get_elements(value)) do
					local tn = type_name(element)
					if tn:find("via.physics.", 1, true) or tn:find("Collider", 1, true) or tn:find("Collision", 1, true) then
						collect_field_shapes(element, out, seen, depth - 1)
					end
				end
			end
		end
	end
	return out
end

local function looks_like_collision_resource(text)
	text = tostring(text or ""):lower()
	return text:find(".rcol", 1, true)
		or text:find(".clsp", 1, true)
		or text:find(".rbs", 1, true)
		or text:find(".mcol", 1, true)
		or text:find(".cdef", 1, true)
		or text:find(".chain", 1, true)
end

local function collect_resource_refs(obj, out, seen, depth)
	out = out or {}
	seen = seen or {}
	if not obj or depth <= 0 or #out >= 80 then return out end
	local key = object_key(obj)
	if key and seen[key] then return out end
	if key then seen[key] = true end
	local direct = resource_text(obj)
	if looks_like_collision_resource(direct) then add_unique(out, direct) end
	for _, field in ipairs(get_fields(obj)) do
		local value = safe_field_data(obj, field)
		local text = resource_text(value)
		if looks_like_collision_resource(text) then add_unique(out, field_name(field) .. " = " .. tostring(text)) end
		for _, element in ipairs(get_elements(value)) do
			local etext = resource_text(element)
			if looks_like_collision_resource(etext) then add_unique(out, field_name(field) .. "[] = " .. tostring(etext)) end
			local tn = type_name(element)
			if tn:find("RequestSet", 1, true) or tn:find("Collision", 1, true) or tn:find("RigidBody", 1, true) then
				collect_resource_refs(element, out, seen, depth - 1)
			end
		end
	end
	return out
end

local function collect_owner_field_shapes(owner)
	local out = {}
	if not owner then return out end
	for _, cname in ipairs({"via.physics.RequestSetCollider", "via.character.CollisionShapePreset", "via.dynamics.RigidBodySet", "via.motion.Chain"}) do
		collect_field_shapes(owner.components[cname], out, {}, 5)
	end
	out._seen = nil
	return out
end

local function draw_collision_overlay(root_item)
	if not state.draw_collision then return end
	local owners = get_collision_owners(root_item)
	local drawn = 0
	for _, owner in ipairs(owners) do
		if drawn >= state.collision_limit then break end
		local colliders = owner.components["via.physics.Colliders"]
		local collider_list = get_collider_list(colliders)
		for _, collider in ipairs(collider_list) do
			if drawn >= state.collision_limit then break end
			local shape = get_collider_shape(collider)
			draw_shape(shape, owner.position, 0xFF40FF40)
			drawn = drawn + 1
		end
		for _, shape in ipairs(collect_owner_field_shapes(owner)) do
			if drawn >= state.collision_limit then break end
			draw_shape(shape, owner.position, 0xFF29B3FF)
			drawn = drawn + 1
		end
		if state.collision_labels and owner.position then
			draw.world_text("COL " .. owner.name, owner.position, 0xFF40FF40)
		end
	end
end

local function get_layers(motion)
	return get_elements(safe_call(motion, "get_Layer"))
end

local function get_first_layer_and_node(motion)
	for _, layer in ipairs(get_layers(motion)) do
		local node = safe_call(layer, "getMotionNode", 0)
		if node then return layer, node end
	end
end

local function motion_info_by_index(motion, bank_id, bank_type, idx, info)
	local signatures = {
		{"getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank_id, idx, info},
		{"getMotionInfo(System.UInt32, System.Int32, System.UInt32, via.motion.MotionInfo)", bank_id, bank_type or 0, idx, info},
		{"getMotionInfo(System.UInt32, System.UInt32, System.UInt32, via.motion.MotionInfo)", bank_id, bank_type or 0, idx, info},
		{"getMotionInfoByIndex(System.UInt32, System.Int32, System.UInt32, via.motion.MotionInfo)", bank_id, bank_type or 0, idx, info},
		{"getMotionInfoByIndex(System.UInt32, System.UInt32, System.UInt32, via.motion.MotionInfo)", bank_id, bank_type or 0, idx, info},
		{"getMotionInfoByIndex(System.Int32, System.Int32, System.UInt32, via.motion.MotionInfo)", bank_id, bank_type or 0, idx, info},
		{"getMotionInfoByIndex(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank_id, idx, info},
		{"getMotionInfoByIndex(System.UInt32, System.Int32, via.motion.MotionInfo)", bank_id, idx, info},
	}
	for _, sig in ipairs(signatures) do
		local ok, has_info = pcall(motion.call, motion, table.unpack(sig))
		if ok and has_info then return true end
	end
	for _, method in ipairs(get_methods(motion, "getMotionInfo")) do
		local params = method:get_param_types()
		local args = {}
		for i, param in ipairs(params) do
			local tn = param:get_full_name() or ""
			if tn == "via.motion.MotionInfo" then
				table.insert(args, info)
			elseif i == 1 then
				table.insert(args, bank_id)
			elseif i == 2 and #params >= 4 then
				table.insert(args, bank_type or 0)
			elseif tn:find("Int", 1, true) or tn:find("UInt", 1, true) then
				table.insert(args, idx)
			else
				table.insert(args, 0)
			end
		end
		local ok, has_info = pcall(method.call, method, motion, table.unpack(args))
		if ok and has_info then return true end
	end
	return false
end

local function find_motion_bank(motion, bank_id, bank_type)
	if not motion or bank_id == nil then return nil, nil end
	local bank = safe_call(motion, "findMotionBank(System.UInt32, System.UInt32)", bank_id, bank_type or 0)
		or safe_call(motion, "findMotionBank(System.UInt32)", bank_id)
		or safe_call(motion, "findMotionBankAtMainBankTable(System.UInt32)", bank_id)
	if bank then return bank, "findMotionBank" end
	local active_count = safe_call(motion, "getActiveMotionBankCount") or 0
	for i = 0, math.max(active_count - 1, 0) do
		local active_bank = safe_call(motion, "getActiveMotionBank(System.UInt32)", i)
		if active_bank and safe_call(active_bank, "get_BankID") == bank_id then
			return active_bank, "active[" .. tostring(i) .. "]"
		end
	end
	return nil, nil
end

local function call_count_method(obj, idx)
	if not obj then return nil end
	for _, name in ipairs({"getMotionCount", "getMotionCount()", "get_MotionCount", "get_NumMotions", "get_NumMotion", "get_Count", "getCount"}) do
		local value = safe_call(obj, name)
		if value ~= nil then return value end
		value = idx ~= nil and safe_call(obj, name, idx) or nil
		if value ~= nil then return value end
	end
end

local function get_bank_motion_list(bank)
	if not bank then return nil, "none" end
	local mlist = safe_call(bank, "get_MotionList")
	if mlist then return mlist, "get_MotionList" end
	mlist = safe_call(bank, "get_TargetMotionList")
	if mlist then return mlist, "get_TargetMotionList" end
	local extern_bank = safe_call(bank, "get_ExternMotionBank")
	if extern_bank then
		mlist = safe_call(extern_bank, "get_MotionList")
		if mlist then return mlist, "get_ExternMotionBank:get_MotionList" end
		mlist = safe_call(extern_bank, "get_TargetMotionList")
		if mlist then return mlist, "get_ExternMotionBank:get_TargetMotionList" end
	end
	return nil, "none"
end

local function get_motion_count(motion, bank_id, bank_type, mlist)
	local value = safe_call(motion, "getMotionCount(System.UInt32)", bank_id)
	if value ~= nil then return value, "Motion:getMotionCount(UInt32)" end
	value = safe_call(motion, "getMotionCount(System.UInt32, System.Int32)", bank_id, bank_type or 0)
	if value ~= nil then return value, "Motion:getMotionCount(UInt32, Int32)" end
	value = call_count_method(mlist, bank_id)
	if value ~= nil then return value, "MotionList count" end
	return nil, "unavailable"
end

local function motion_info_from_object(obj, idx, info)
	if not obj then return false end
	for _, method in ipairs(get_methods(obj, "Info")) do
		local name = method:get_name()
		if name:find("Info", 1, true) then
			local params = method:get_param_types()
			local args = {}
			local has_info_param = false
			for _, param in ipairs(params or {}) do
				local tn = param:get_full_name() or ""
				if tn == "via.motion.MotionInfo" then
					table.insert(args, info)
					has_info_param = true
				elseif tn:find("Int", 1, true) or tn:find("UInt", 1, true) then
					table.insert(args, idx)
				else
					table.insert(args, 0)
				end
			end
			local ok, ret = pcall(method.call, method, obj, table.unpack(args))
			if ok then
				if has_info_param and ret then return true, info end
				if ret and sdk.is_managed_object(ret) and type_name(ret):find("MotionInfo", 1, true) then
					return true, ret
				end
			end
		end
	end
	return false
end

local function motion_entry_label(entry)
	if not entry then return "<none>" end
	return tostring(entry.id) .. " " .. tostring(entry.name or ("motion_" .. tostring(entry.id))) .. " [" .. tostring(entry.frames or "?") .. "]"
end

local function build_motion_entries(motion, bank, mlist, bank_id, bank_type, motion_count, current_motion_id, current_motion_name)
	local entries, seen = {}, {}
	local info = sdk.create_instance("via.motion.MotionInfo")
	if info then safe_call(info, ".ctor") end
	local probe_limit = math.min(motion_count or state.anim_probe_limit, state.anim_probe_limit)
	for i = 0, probe_limit - 1 do
		local found_info, resolved_info = false, info
		found_info = info and motion_info_by_index(motion, bank_id, bank_type, i, info)
		if not found_info then found_info, resolved_info = motion_info_from_object(bank, i, info) end
		if not found_info then found_info, resolved_info = motion_info_from_object(mlist, i, info) end
		resolved_info = resolved_info or info
		if found_info then
			local mot_id = safe_call(resolved_info, "get_MotionID")
			local mot_name = safe_call(resolved_info, "get_MotionName")
			local end_frame = safe_call(resolved_info, "get_MotionEndFrame")
			if current_motion_id ~= nil and (mot_id == current_motion_id or i == current_motion_id) then
				mot_id = mot_id or current_motion_id
				mot_name = mot_name or current_motion_name
			end
			local usable = mot_id ~= nil and (mot_name ~= nil or end_frame ~= nil or mot_id == current_motion_id)
			if usable and not seen[tostring(mot_id)] then
				seen[tostring(mot_id)] = true
				table.insert(entries, {
					bank = bank_id,
					bank_type = bank_type or 0,
					id = mot_id,
					name = mot_name or ("motion_" .. tostring(mot_id)),
					frames = end_frame,
				})
			end
		end
	end
	if current_motion_id ~= nil and not seen[tostring(current_motion_id)] then
		table.insert(entries, {
			bank = bank_id,
			bank_type = bank_type or 0,
			id = current_motion_id,
			name = current_motion_name or ("motion_" .. tostring(current_motion_id)),
			frames = nil,
		})
	end
	table.sort(entries, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
	return entries
end

local function get_enabled_layers(motion)
	local layers = get_layers(motion)
	local selected = {}
	for i, layer in ipairs(layers) do
		local key = object_key(layer) or tostring(i)
		if state.anim_enabled_layers and state.anim_enabled_layers[key] == false then
			-- disabled
		else
			table.insert(selected, layer)
		end
	end
	return (#selected > 0 and selected) or layers
end

local function call_layers(layers, method, ...)
	for _, layer in ipairs(layers or {}) do
		safe_call(layer, method, ...)
	end
end

local function change_motion_on_layers(layers, bank_id, motion_id, start_frame, interp_frames)
	for _, layer in ipairs(layers or {}) do
		safe_call(layer, "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)", bank_id, motion_id, start_frame or 0.0, interp_frames or 10.0, 2, 0)
	end
end

local function draw_animation_ui(root_item)
	if not imgui.tree_node("Animation") then return end
	local motion_candidates = get_motion_candidates(root_item)
	if #motion_candidates > 0 and imgui.tree_node("Motion owners (" .. tostring(#motion_candidates) .. ")") then
		for i, candidate in ipairs(motion_candidates) do
			local motion = candidate.components["via.motion.Motion"]
			local active_count = motion and (safe_call(motion, "getActiveMotionBankCount") or 0) or 0
			local dynamic_count = motion and (safe_call(motion, "getDynamicMotionBankCount") or 0) or 0
			local label = tostring(i) .. ": " .. tostring(candidate.name)
				.. " active=" .. tostring(active_count)
				.. " dynamic=" .. tostring(dynamic_count)
				.. " joints=" .. tostring(candidate.joint_count or 0)
			if imgui.button((state.motion_owner_idx == i and "> " or "") .. label) then
				state.motion_owner_idx = i
				state.anim_bank_idx = 0
			end
		end
		imgui.tree_pop()
	end
	local owner = get_motion_owner(root_item)
	if not owner then
		imgui.text("No motion owner found under selected object")
		imgui.tree_pop()
		return
	end
	local motion = owner.components["via.motion.Motion"]
	local layer, node = get_first_layer_and_node(motion)
	imgui.text("Motion owner: " .. tostring(owner.name))
	imgui.text("Layers: " .. tostring(#get_layers(motion)) .. "  PlayState: " .. tostring(safe_call(motion, "get_PlayState")))
	local changed
	changed, state.anim_debug = imgui.checkbox("Method debug", state.anim_debug)
	if state.anim_debug and imgui.tree_node("Motion method signatures") then
		for _, method in ipairs(get_methods(motion, "Motion")) do
			local name = method:get_name()
			if name:find("MotionInfo", 1, true) or name:find("MotionCount", 1, true) or name:find("MotionBank", 1, true) then
				imgui.text(method_signature(method))
			end
		end
		imgui.tree_pop()
	end
	local current_bank_id = node and safe_call(node, "get_MotionBankID")
	local current_motion_id = node and safe_call(node, "get_MotionID")
	local current_motion_name = node and safe_call(node, "get_MotionName")
	if node then
		imgui.text("Current: bank=" .. tostring(current_bank_id) .. " motion=" .. tostring(current_motion_id))
		imgui.text("Name: " .. tostring(current_motion_name))
	else
		imgui.text("No active motion node")
	end

	if layer then
		local frame = safe_call(layer, "get_Frame") or 0.0
		local end_frame = safe_call(layer, "get_EndFrame") or 1.0
		local speed = safe_call(layer, "get_Speed") or safe_call(motion, "get_PlaySpeed") or 1.0
		if imgui.button((speed == 0.0) and "Play" or "Pause") then
			local next_speed = (speed == 0.0) and 1.0 or 0.0
			call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", next_speed)
			safe_call(motion, "set_PlaySpeed", next_speed)
		end
		imgui.same_line()
		if imgui.button("Reverse") then
			local next_speed = (speed == 0.0) and -1.0 or -speed
			call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", next_speed)
			safe_call(motion, "set_PlaySpeed", next_speed)
		end
		imgui.same_line()
		if imgui.button("0.05x") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", 0.05) end
		imgui.same_line()
		if imgui.button("0.25x") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", 0.25) end
		imgui.same_line()
		if imgui.button("0.5x") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", 0.5) end
		imgui.same_line()
		if imgui.button("1.0x") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", 1.0) end
		imgui.same_line()
		if imgui.button("+0.25x") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", speed + 0.25) end
		if imgui.button("Restart") then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Frame", 0.0) end
		changed, frame = imgui.slider_float("Frame", frame, 0.0, math.max(end_frame, 1.0))
		if changed then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Frame", frame) end
		changed, speed = imgui.slider_float("Speed", speed, -5.0, 5.0)
		if changed then
			call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Speed", speed)
			safe_call(motion, "set_PlaySpeed", speed)
		end
		changed, state.anim_seek_all = imgui.checkbox("Seek All", state.anim_seek_all)
		changed, state.anim_loop = imgui.checkbox("Loop", state.anim_loop)
		if changed then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_WrapMode", state.anim_loop and 2 or 0) end
		if imgui.button((state.anim_loop_b and "Clear A/B Loop") or (state.anim_loop_a and "Set Loop B") or "Set Loop A") then
			if state.anim_loop_b then
				state.anim_loop_a, state.anim_loop_b = nil, nil
			elseif state.anim_loop_a then
				state.anim_loop_b = frame
			else
				state.anim_loop_a = frame
			end
		end
		if state.anim_loop_a then
			imgui.same_line()
			imgui.text("A=" .. tostring(math.floor(state.anim_loop_a)) .. " B=" .. tostring(state.anim_loop_b and math.floor(state.anim_loop_b) or "?"))
			if state.anim_loop_b and frame >= state.anim_loop_b then
				call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_Frame", state.anim_loop_a)
			end
		end
		local mirrored = safe_call(layer, "get_MirrorSymmetry") or false
		changed, mirrored = imgui.checkbox("Mirror", mirrored)
		if changed then call_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), "set_MirrorSymmetry", mirrored) end
		if imgui.tree_node("Affected Layers") then
			for i, item_layer in ipairs(get_layers(motion)) do
				local key = object_key(item_layer) or tostring(i)
				local enabled = state.anim_enabled_layers[key] ~= false
				local layer_node = safe_call(item_layer, "getMotionNode", 0)
				changed, enabled = imgui.checkbox("Layer " .. tostring(i) .. " " .. tostring(layer_node and safe_call(layer_node, "get_MotionName") or ""), enabled)
				if changed then state.anim_enabled_layers[key] = enabled or false end
			end
			imgui.tree_pop()
		end
	end

	local active_count = safe_call(motion, "getActiveMotionBankCount") or 0
	local dynamic_count = safe_call(motion, "getDynamicMotionBankCount") or 0
	imgui.text("Active banks: " .. tostring(active_count) .. "  Dynamic banks: " .. tostring(dynamic_count))
	changed, state.use_current_node_bank = imgui.checkbox("Use current node bank", state.use_current_node_bank)
	state.anim_bank_idx = math.max(0, math.min(state.anim_bank_idx or 0, math.max(active_count - 1, 0)))
	changed, state.anim_bank_idx = imgui.slider_int("Bank index", state.anim_bank_idx, 0, math.max(active_count - 1, 0))

	local bank, bank_source
	if state.use_current_node_bank and current_bank_id ~= nil then
		bank, bank_source = find_motion_bank(motion, current_bank_id, 0)
	end
	if not bank then
		bank = safe_call(motion, "getActiveMotionBank(System.UInt32)", state.anim_bank_idx)
		bank_source = "active[" .. tostring(state.anim_bank_idx) .. "]"
	end
	if bank then
		local bank_id = (state.use_current_node_bank and current_bank_id ~= nil) and current_bank_id or safe_call(bank, "get_BankID")
		local bank_type = safe_call(bank, "get_BankType")
		local mlist, mlist_source = get_bank_motion_list(bank)
		local motion_count, count_source = get_motion_count(motion, bank_id, bank_type, mlist)
		imgui.text("Bank source: " .. tostring(bank_source))
		imgui.text("Motlist: " .. tostring(mlist and resource_text(mlist) or safe_call(bank, "get_Name")))
		imgui.text("Motlist source: " .. tostring(mlist_source))
		imgui.text("Bank id/type: " .. tostring(bank_id) .. " / " .. tostring(bank_type))
		if current_motion_id ~= nil then
			local current_info = sdk.create_instance("via.motion.MotionInfo")
			if current_info then safe_call(current_info, ".ctor") end
			local current_ok = current_info and motion_info_by_index(motion, bank_id, bank_type, current_motion_id, current_info)
			imgui.text("Current info: " .. tostring(current_ok)
				.. " id=" .. tostring(current_ok and safe_call(current_info, "get_MotionID"))
				.. " name=" .. tostring(current_ok and safe_call(current_info, "get_MotionName")))
		end
		if motion_count then
			imgui.text("Motion count: " .. tostring(motion_count) .. " (" .. tostring(count_source) .. ")")
		else
			imgui.text("Motion count: unavailable (" .. tostring(count_source) .. ")")
			imgui.text("Probe range: 0.." .. tostring(math.max((state.anim_probe_limit or 1) - 1, 0)))
		end
		local motion_entries = build_motion_entries(motion, bank, mlist, bank_id, bank_type, motion_count, current_motion_id, current_motion_name)
		local motion_labels = {}
		for i, entry in ipairs(motion_entries) do
			table.insert(motion_labels, motion_entry_label(entry))
			if current_motion_id ~= nil and entry.id == current_motion_id and state.anim_last_current ~= tostring(bank_id) .. ":" .. tostring(current_motion_id) then
				state.anim_selected_idx = i
				state.anim_last_current = tostring(bank_id) .. ":" .. tostring(current_motion_id)
			end
		end
		state.anim_selected_idx = math.max(1, math.min(state.anim_selected_idx or 1, math.max(#motion_entries, 1)))
		if #motion_entries > 0 then
			changed, state.anim_selected_idx = imgui.combo("Mot", state.anim_selected_idx, motion_labels)
			if changed and motion_entries[state.anim_selected_idx] and layer then
				local entry = motion_entries[state.anim_selected_idx]
				change_motion_on_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), entry.bank, entry.id, 0.0, 10.0)
			end
			if imgui.button("Prev") and #motion_entries > 0 then
				state.anim_selected_idx = state.anim_selected_idx - 1
				if state.anim_selected_idx < 1 then state.anim_selected_idx = #motion_entries end
				local entry = motion_entries[state.anim_selected_idx]
				change_motion_on_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), entry.bank, entry.id, 0.0, 10.0)
			end
			imgui.same_line()
			if imgui.button("Next") and #motion_entries > 0 then
				state.anim_selected_idx = state.anim_selected_idx + 1
				if state.anim_selected_idx > #motion_entries then state.anim_selected_idx = 1 end
				local entry = motion_entries[state.anim_selected_idx]
				change_motion_on_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), entry.bank, entry.id, 0.0, 10.0)
			end
			imgui.same_line()
			if imgui.button("Shuffle") and #motion_entries > 0 then
				state.anim_selected_idx = math.random(1, #motion_entries)
				local entry = motion_entries[state.anim_selected_idx]
				change_motion_on_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), entry.bank, entry.id, 0.0, 10.0)
			end
		else
			imgui.text("Mot: no entries resolved")
		end
		if imgui.tree_node("Active bank list") then
			for i = 0, math.max(active_count - 1, 0) do
				local active_bank = safe_call(motion, "getActiveMotionBank(System.UInt32)", i)
				if active_bank then
					local active_bank_id = safe_call(active_bank, "get_BankID")
					local active_bank_type = safe_call(active_bank, "get_BankType")
					local active_mlist, active_source = get_bank_motion_list(active_bank)
					imgui.text((i == state.anim_bank_idx and "> " or "  ")
						.. tostring(i)
						.. " bank=" .. tostring(active_bank_id)
						.. " type=" .. tostring(active_bank_type)
						.. " list=" .. tostring(active_mlist and resource_text(active_mlist) or safe_call(active_bank, "get_Name"))
						.. " [" .. tostring(active_source) .. "]")
				end
			end
			imgui.tree_pop()
		end
		if state.anim_debug and imgui.tree_node("Bank/Motlist method signatures") then
			imgui.text("Bank: " .. type_name(bank))
			for _, method in ipairs(get_methods(bank)) do
				local name = method:get_name()
				if name:find("Motion", 1, true) or name:find("Count", 1, true) or name:find("List", 1, true) then
					imgui.text(method_signature(method))
				end
			end
			if mlist then
				imgui.text("Motlist: " .. type_name(mlist))
				for _, method in ipairs(get_methods(mlist)) do
					local name = method:get_name()
					if name:find("Motion", 1, true) or name:find("Count", 1, true) or name:find("List", 1, true) or name:find("get_", 1, true) then
						imgui.text(method_signature(method))
					end
				end
			end
			imgui.tree_pop()
		end
		if imgui.tree_node("Motions") then
			for i, entry in ipairs(motion_entries) do
				if i > state.anim_probe_limit then break end
				if imgui.button(motion_entry_label(entry)) and layer then
					state.anim_selected_idx = i
					change_motion_on_layers(state.anim_seek_all and get_layers(motion) or get_enabled_layers(motion), entry.bank, entry.id, 0.0, 10.0)
				end
			end
			if #motion_entries == 0 then imgui.text("No motion entries resolved with known overloads") end
			imgui.tree_pop()
		end
	end
	imgui.tree_pop()
end

local function draw_skeleton_ui(root_item)
	if not imgui.tree_node("Skeleton") then return end
	local owner = get_skeleton_owner(root_item)
	if not owner then
		imgui.text("No skeleton owner found under selected object")
		imgui.tree_pop()
		return
	end
	local joints = get_joints(owner.xform)
	imgui.text("Skeleton owner: " .. tostring(owner.name))
	imgui.text("Joints: " .. tostring(#joints))
	local changed
	changed, state.draw_skeleton = imgui.checkbox("Draw skeleton", state.draw_skeleton)
	imgui.same_line()
	changed, state.show_joint_names = imgui.checkbox("Names", state.show_joint_names)
	changed, state.position_mode = imgui.combo("Position source", state.position_mode, position_modes)
	changed, state.joint_limit_text = imgui.input_text("Joint draw/list limit", state.joint_limit_text)
	if changed then
		state.joint_limit = math.max(20, math.min(512, tonumber(state.joint_limit_text) or state.joint_limit))
		state.joint_limit_text = tostring(state.joint_limit)
	end
	if imgui.tree_node("Joint list") then
		for i = 1, math.min(#joints, state.joint_limit) do
			imgui.text(tostring(i) .. ": " .. tostring(safe_call(joints[i], "get_Name") or "joint"))
		end
		imgui.tree_pop()
	end
	imgui.tree_pop()
end

local function draw_collision_ui(root_item)
	if not imgui.tree_node("Collision") then return end
	local changed
	changed, state.draw_collision = imgui.checkbox("Draw collision", state.draw_collision)
	imgui.same_line()
	changed, state.collision_labels = imgui.checkbox("Labels", state.collision_labels)
	changed, state.collision_debug = imgui.checkbox("Field debug", state.collision_debug)
	local owners = get_collision_owners(root_item)
	imgui.text("Collision owners: " .. tostring(#owners))
	imgui.text("Known capsule/sphere/box shapes are drawn. Unknown shapes are listed only.")
	for i, owner in ipairs(owners) do
		if i > 24 then
			imgui.text("... more")
			break
		end
		if imgui.tree_node(tostring(owner.name) .. "##col" .. tostring(i)) then
			local colliders = owner.components["via.physics.Colliders"]
			local collider_list = get_collider_list(colliders)
			local field_shapes = collect_owner_field_shapes(owner)
			imgui.text("Colliders: " .. tostring(#collider_list))
			imgui.text("Field shapes: " .. tostring(#field_shapes))
			if colliders then imgui.text("Raw NumColliders: " .. tostring(safe_call(colliders, "get_NumColliders"))) end
			if state.collision_debug and colliders and imgui.tree_node("Colliders fields") then
				for _, field in ipairs(get_fields(colliders)) do
					local value = safe_field_data(colliders, field)
					imgui.text(field_name(field) .. " : " .. field_type_name(field) .. " -> " .. type_name(value) .. " [" .. tostring(#get_elements(value)) .. "]")
				end
				imgui.tree_pop()
			end
			for c, collider in ipairs(collider_list) do
				if c > 16 then break end
				local shape = get_collider_shape(collider)
				if imgui.tree_node("[" .. tostring(c) .. "] " .. type_name(shape)) then
					imgui.text("Shape: " .. type_name(safe_call(collider, "get_Shape")))
					imgui.text("Transformed: " .. type_name(safe_call(collider, "get_TransformedShape")))
					if state.collision_debug then
						imgui.text("Collider fields:")
						for _, field in ipairs(get_fields(collider)) do
							local value = safe_field_data(collider, field)
							imgui.text("  " .. field_name(field) .. " : " .. field_type_name(field) .. " -> " .. type_name(value))
						end
						if shape then
							imgui.text("Shape fields:")
							for _, field in ipairs(get_fields(shape)) do
								local value = safe_field_data(shape, field)
								imgui.text("  " .. field_name(field) .. " : " .. field_type_name(field) .. " -> " .. type_name(value))
							end
						end
					end
					imgui.tree_pop()
				end
			end
			if #field_shapes > 0 and imgui.tree_node("Field shape objects") then
				for s, shape in ipairs(field_shapes) do
					if s > 32 then
						imgui.text("... more")
						break
					end
					if imgui.tree_node("[" .. tostring(s) .. "] " .. type_name(shape)) then
						for _, field in ipairs(get_fields(shape)) do
							local value = safe_field_data(shape, field)
							imgui.text("  " .. field_name(field) .. " : " .. field_type_name(field) .. " -> " .. type_name(value))
						end
						imgui.tree_pop()
					end
				end
				imgui.tree_pop()
			end
			local refs = collect_resource_refs(owner.components["via.physics.RequestSetCollider"], {}, {}, 5)
			collect_resource_refs(owner.components["via.character.CollisionShapePreset"], refs, {}, 5)
			collect_resource_refs(owner.components["via.dynamics.RigidBodySet"], refs, {}, 5)
			refs._seen = nil
			imgui.text("Collision resources: " .. tostring(#refs))
			if #refs > 0 and imgui.tree_node("Collision resources") then
				for r, ref in ipairs(refs) do
					if r > 64 then
						imgui.text("... more")
						break
					end
					imgui.text(tostring(ref))
				end
				imgui.tree_pop()
			end
			if owner.components["via.physics.RequestSetCollider"] then imgui.text("RequestSetCollider: present") end
			if owner.components["via.character.CollisionShapePreset"] then imgui.text("CollisionShapePreset: present") end
			if owner.components["via.motion.Chain"] then
				local asset = safe_call(owner.components["via.motion.Chain"], "get_ChainAsset")
				imgui.text("Chain: " .. tostring(asset and resource_text(asset) or "present"))
			end
			imgui.tree_pop()
		end
	end
	imgui.tree_pop()
end

local function draw_object_browser()
	local changed
	if imgui.button("Scan") then scan_scene() end
	imgui.same_line()
	if imgui.button("Player") then
		state.scan_mode = 1
		state.filter = "masterplayer"
		state.motion_owner_idx = 1
		state.anim_bank_idx = 0
		scan_scene()
	end
	changed, state.scan_mode = imgui.combo("Mode", state.scan_mode, scan_modes)
	changed, state.filter = imgui.input_text("Filter", state.filter)
	changed, state.near_player = imgui.checkbox("Near player", state.near_player)
	if state.near_player then
		changed, state.radius = imgui.slider_float("Radius", state.radius, 5.0, 250.0)
	end
	imgui.text(state.status)
	if imgui.tree_node("Objects (" .. tostring(#state.objects) .. ")") then
		for i, item in ipairs(state.objects) do
			local label = tostring(i) .. ": " .. tostring(item.name) .. " joints=" .. tostring(item.joint_count or 0)
			if item.distance then label = label .. string.format(" [%.1f]", item.distance) end
			if imgui.button((state.selected_idx == i and "> " or "") .. label) then
				state.selected_idx = i
				state.motion_owner_idx = 1
				state.anim_bank_idx = 0
			end
		end
		imgui.tree_pop()
	end
end

local function draw_selected_ui()
	local item = selected()
	if not item then
		imgui.text("No object selected")
		return
	end
	imgui.separator()
	imgui.text("Selected: " .. tostring(item.name))
	imgui.text("Path: " .. tostring(get_gameobj_path and get_gameobj_path(item.gameobj) or item.name))
	imgui.text("Components: " .. component_summary(item))
	draw_skeleton_ui(item)
	draw_animation_ui(item)
	draw_collision_ui(item)
end

re.on_frame(function()
	local item = selected()
	if not item then return end
	draw_skeleton_overlay(item)
	draw_collision_overlay(item)
end)

re.on_draw_ui(function()
	if imgui.tree_node("Wilds Motion Viewer") then
		draw_object_browser()
		draw_selected_ui()
		imgui.tree_pop()
	end
end)
