-- GiantBoBaseState
	GiantBoBaseState = GiantBoBaseState or class()

	function GiantBoBaseState:init(unit, base)
		self._unit = unit
		self._base = base
	end

	function GiantBoBaseState:enter(t) end
	function GiantBoBaseState:exit(t) end
	function GiantBoBaseState:update(t, dt) end

-- GiantBoBaseIntro
	GiantBoBaseIntro = GiantBoBaseIntro or class(GiantBoBaseState)

	function GiantBoBaseIntro:enter(t)
		local intro_time = self._base:do_action("intro")
		self._intro_exit_t = t + intro_time

		self._unit:set_rotation(Rotation(self._base:state_data().current_angle, 0, 0))
		self._unit:set_position(self._base:state_data().origin + Vector3(
			-math.sin(self._base:state_data().current_angle) * self._base:state_data().radius,
			math.cos(self._base:state_data().current_angle) * self._base:state_data().radius,
			0
		))

		self._unit:network():send("sync_stored_pos", true, self._base:state_data().origin, Vector3(
			self._base:state_data().radius,
			speed_multiplier,
			self._base:state_data().target_angle
		))
	end

	function GiantBoBaseIntro:update(t, dt)
		if t > self._intro_exit_t then
			self._base:set_state("idle")

			self._base:do_action("show_health")
		end
	end

-- GiantBoBaseIdle
	GiantBoBaseIdle = GiantBoBaseIdle or class(GiantBoBaseState)

	function GiantBoBaseIdle:enter(t)
		local idle_time = math.lerp(4, 1, self._base:state_data().aggressiveness)

		self._idle_exit_t = t + idle_time
	end

	function GiantBoBaseIdle:update(t, dt)
		if t > self._idle_exit_t then
			self._base:set_state("search")
		end
	end

-- GiantBoBaseSearch
	GiantBoBaseSearch = GiantBoBaseSearch or class(GiantBoBaseState)
	GiantBoBaseSearch._zones = 8

	function GiantBoBaseSearch:update(t, dt)
		local zone_angle_size = 360 / self._zones
		local zone_ratings = {}

		for i = 1, self._zones do
			zone_ratings[i] = 0
		end

		local criminals = managers.groupai:state():all_player_criminals()
		for _, data in pairs(criminals) do
			local position = data.unit:position()
			local direction = position - self._base:state_data().origin
			mvector3.set_z(direction, 0)
			mvector3.normalize(direction)

			for i = 1, self._zones do
				local forward = Rotation(zone_angle_size * (i - 1), 0, 0):y()
				zone_ratings[i] = zone_ratings[i] + mvector3.dot(forward, direction)
			end
		end

		local best_zone_id = 0
		local best_zone_rating = -10
		for i = 1, self._zones do
			if zone_ratings[i] > best_zone_rating then
				best_zone_id = i
				best_zone_rating = zone_ratings[i]
			end
		end

		local new_angle = zone_angle_size * (best_zone_id - 1)
		local old_angle = self._base:state_data().current_angle

		local delta = new_angle - old_angle

		-- Some crappy wrapping so Bo doesn't do a complete 270 turn to go round a corner.
		if delta > 180 then
			new_angle = new_angle - 360
		elseif delta < -180 then
			new_angle = new_angle + 360
		end

		if new_angle == old_angle then
			self._base:set_state("attack")
		else
			self._base:state_data().target_angle = new_angle
			self._base:set_state("move")
		end
	end

-- GiantBoBaseMove
	GiantBoBaseMove = GiantBoBaseMove or class(GiantBoBaseState)

	function GiantBoBaseMove:enter(t)
		local speed_multiplier = math.lerp(1, 2, self._base:state_data().aggressiveness)

		local delta = self._base:state_data().target_angle - self._base:state_data().current_angle
		if delta > 0 then
			local result = self._unit:play_redirect(Idstring("turn_left"))
			self._unit:anim_state_machine():set_speed(result, speed_multiplier)
		elseif delta < 0 then
			local result = self._unit:play_redirect(Idstring("turn_right"))
			self._unit:anim_state_machine():set_speed(result, speed_multiplier)
		end

		self._transition_start_t = t
		self._transition_t = 1 / speed_multiplier

		self._base:state_data().start_angle = self._base:state_data().current_angle

		self._unit:network():send("sync_stored_pos", true, self._base:state_data().origin, Vector3(
			self._base:state_data().radius,
			speed_multiplier,
			self._base:state_data().target_angle
		))
	end

	function GiantBoBaseMove:update(t)
		if t > self._transition_start_t + self._transition_t then
			self._base:set_state("attack")

			self._base:state_data().current_angle = self._base:state_data().target_angle % 360
		else
			local percentage = (t - self._transition_start_t) / self._transition_t

			self._base:state_data().current_angle = math.lerp(
				self._base:state_data().start_angle,
				self._base:state_data().target_angle,
				percentage
			)
		end

		self._unit:set_rotation(Rotation(self._base:state_data().current_angle, 0, 0))
		self._unit:set_position(self._base:state_data().origin + Vector3(
			-math.sin(self._base:state_data().current_angle) * self._base:state_data().radius,
			math.cos(self._base:state_data().current_angle) * self._base:state_data().radius,
			0
		))
	end

-- GiantBoBaseAttack
	GiantBoBaseAttack = GiantBoBaseAttack or class(GiantBoBaseState)
	GiantBoBaseAttack._attack_cone = 45
	GiantBoBaseAttack._attack_distances = {
		4300, 6000, 10000
	}
	GiantBoBaseAttack._attack_map = {
		{"breath_fire"},
		{"throw_smoke", "throw_molotov"},
		{"shoot_grenades"}
	}

	function GiantBoBaseAttack:enter(t)
		local forward = Rotation(self._base:state_data().current_angle, 0, 0):y()
		local limit = math.cos(self._attack_cone/2)

		local distances = {}

		local criminals = managers.groupai:state():all_player_criminals()
		for _, data in pairs(criminals) do
			local position = data.unit:position()
			local direction = position - self._base:state_data().origin
			mvector3.set_z(direction, 0)
			mvector3.normalize(direction)

			if mvector3.dot(forward, direction) > limit then
				table.insert(distances, mvector3.distance(position, self._base:state_data().origin))
			end
		end

		local distance = 0
		if #distances > 0 then
			distance = table.random(distances)
		end

		local distance_index = #self._attack_distances
		for index, max_distance in pairs(self._attack_distances) do
			if distance < max_distance then
				distance_index = index
				break
			end
		end

		-- Not same attack twice if there's more than one
		if #self._attack_map[distance_index] > 1 then
			while self._current_attack == self._last_attack do
				self._current_attack = table.random(self._attack_map[distance_index])
			end
		else
			self._current_attack = self._attack_map[distance_index][1]
		end

		self._last_attack = self._current_attack

		if self._current_attack then
			self._exit_attack_t = t + self._base:do_action(self._current_attack)
		else
			self._exit_attack_t = t
		end
	end

	function GiantBoBaseAttack:update(t)
		if t > self._exit_attack_t then
			self._base:set_state("idle")
		end
	end

-- GiantBoBaseStun
	GiantBoBaseStun = GiantBoBaseStun or class(GiantBoBaseState)

	function GiantBoBaseStun:enter(t)
		local stun_time = self._base:do_action("stun")

		self._stun_exit_t = t + stun_time
	end

	function GiantBoBaseStun:update(t, dt)
		if t > self._stun_exit_t then
			self._base:set_state("idle")
		end
	end

-- GiantBoBaseDead
	GiantBoBaseDead = GiantBoBaseDead or class(GiantBoBaseState)

	function GiantBoBaseDead:enter(t)
		self._base:do_action("death")
		self._base:do_action("hide_health")
	end

-- GiantBoDamage
	GiantBoDamage = GiantBoDamage or class()
	GiantBoDamage._DAMAGE_GRANULARITY = 512 + 512 + 128 + 300 + 7
	GiantBoDamage._MAX_DAMAGE = 2500
	GiantBoDamage._DAMAGE_GRANULARITY_PERCENT = GiantBoDamage._MAX_DAMAGE / GiantBoDamage._DAMAGE_GRANULARITY

	function GiantBoDamage:init(unit)
		self._unit = unit

		self._max_health = 10000
		self._health = self._max_health

		self._listener_holder = EventListenerHolder:new()
	end

	function GiantBoDamage:add_listener(key, events, clbk)
		self._listener_holder:add(key, events, clbk)
	end

	function GiantBoDamage:remove_listener(key)
		self._listener_holder:remove(key)
	end

	local function split_number(number, ...)
		local output = {}
		local bins = {...}

		for _, bin_size in pairs(bins) do
			local value = math.min(number, bin_size)
			number = number - value

			table.insert(output, value)
		end

		return output
	end

	function GiantBoDamage:add_damage(attacker_unit, type, damage)
		damage = math.clamp(damage, 0, self._MAX_DAMAGE)
		local damage_percent = math.ceil(damage / self._DAMAGE_GRANULARITY_PERCENT)
		damage = damage_percent * self._DAMAGE_GRANULARITY_PERCENT

		-- Abusing other melee network data to sync more detailed damage data.
		local split_damage_percent = split_number(damage_percent, 512, 512, 128, 300, 7)
		self._unit:network():send("damage_melee", attacker_unit, split_damage_percent[1], split_damage_percent[2], split_damage_percent[3], split_damage_percent[4], split_damage_percent[5], false)

		return self:do_damage(attacker_unit, damage)
	end

	function GiantBoDamage:do_damage(attacker_unit, damage)
		self._health = self._health - damage
		self._health = math.clamp(self._health, 0, self._max_health)

		self._listener_holder:call("on_take_damage", self._unit, attacker_unit, damage)

		return false, 0
	end

	-- Using this to sync all damage.
	function GiantBoDamage:sync_damage_melee(attacker_unit, damage_percent_1, damage_percent_2, damage_percent_3, damage_percent_4, damage_percent_5, death)
		local damage_percent = damage_percent_1 + damage_percent_2 + damage_percent_3 + damage_percent_4 + damage_percent_5
		local damage = damage_percent * self._DAMAGE_GRANULARITY_PERCENT

		self:do_damage(attacker_unit, damage)
	end

	function GiantBoDamage:health_percentage()
		return self._health / self._max_health
	end

	function GiantBoDamage:damage_bullet(attack_data)
		return self:add_damage(attack_data.attacker_unit, "bullet", attack_data.damage)
	end

	function GiantBoDamage:damage_fire(attack_data)
		return self:add_damage(attack_data.attacker_unit, "fire", attack_data.damage)
	end

	function GiantBoDamage:damage_dot(attack_data)
		return self:add_damage(attack_data.attacker_unit, "dot", attack_data.damage)
	end

	function GiantBoDamage:damage_explosion(attack_data)
		return self:add_damage(attack_data.attacker_unit, "explosion", attack_data.damage)
	end

	function GiantBoDamage:damage_simple(attack_data)
		return self:add_damage(attack_data.attacker_unit, "simple", attack_data.damage)
	end

	function GiantBoDamage:damage_tase(attack_data)
		return self:add_damage(attack_data.attacker_unit, "tase", attack_data.damage)
	end

	function GiantBoDamage:damage_melee(attack_data)
		return self:add_damage(attack_data.attacker_unit, "melee", attack_data.damage)
	end

	function GiantBoDamage:damage_mission(attack_data)
		return self:add_damage(attack_data.attacker_unit, "mission", attack_data.damage)
	end

	function GiantBoDamage:dead()
		return false
	end

	function GiantBoDamage:save(data)
		local save_health = self._health ~= self._max_health

		if save_health then
			data.health = self._health
			data.max_health = self._max_health
		end
	end

	function GiantBoDamage:load(data)
		if data.health then
			self._health = data.health
			self._max_health = data.max_health
		end
	end

GiantBoBase = GiantBoBase or class(UnitBase)
GiantBoBase._actions = {
	intro = {
		animation = "intro",
		length = 140/30
	},
	breath_fire = {
		animation = "breath_fire",
		length = 120/30,
		use_aggressiveness = true
	},
	throw_smoke = {
		animation = "throw_smoke",
		length = 40/30,
		use_aggressiveness = true
	},
	throw_molotov = {
		animation = "throw_molotov",
		length = 40/30,
		use_aggressiveness = true
	},
	shoot_grenades = {
		animation = "shoot_grenades",
		length = 40/30,
		use_aggressiveness = true
	},
	stun = {
		animation = "stun",
		length = 145/30,
	},
	death = {
		animation = "stun",
		sequence = "died",
		length = 145/30
	},
	show_health = {
		func = "show_health"
	},
	hide_health = {
		func = "hide_health"
	}
}

function GiantBoBase:init(unit)
	GiantBoBase.super.init(self, unit, true)

	self._unit = unit
	self._enabled = false

	self._states = {
		intro = GiantBoBaseIntro:new(unit, self),
		idle = GiantBoBaseIdle:new(unit, self),
		search = GiantBoBaseSearch:new(unit, self),
		move = GiantBoBaseMove:new(unit, self),
		attack = GiantBoBaseAttack:new(unit, self),
		stun = GiantBoBaseStun:new(unit, self),
		dead = GiantBoBaseDead:new(unit, self)
	}

	self._last_state = nil
	self._current_state = "idle"

	local init_angle = self._unit:rotation():yaw()
	self._state_data = {
		origin = self._unit:position(),
		start_angle = init_angle,
		current_angle = init_angle,
		target_angle = init_angle,
		radius = 2400,
		aggressiveness = 0
	}

	self._flame_stats = {
		range = 3500,
		radius = 50,
		damage = 5,
		single_flame_effect_duration = 1,
		flame_rate = 0.01,
		flame_effect = Idstring("effects/payday2/particles/explosions/flamethrower"),

		damage_rate = 0.05,
		slotmask = managers.slot:get_mask("world_geometry", "vehicles"),
		damage_slotmask = managers.slot:get_mask("bullet_impact_targets"),

		offset = Vector3(0, 10, 350)
	}

	self._head = self._unit:get_object(Idstring("Head"))

	self._left_hand = self._unit:get_object(Idstring("LeftHand"))
	self._right_hand = self._unit:get_object(Idstring("RightHand"))

	self._left_finger = self._unit:get_object(Idstring("LeftHandMiddle3"))
	self._right_finger = self._unit:get_object(Idstring("RightHandMiddle3"))

	self._flamethrower_effect_collection = {}

	self._flames = false
	self._next_flame_time = 0
	self._next_flame_damage_time = 0

	self._sound = SoundDevice:create_source("giant_bo")
	self._sound:link(self._head)
	self._sound:set_switch("suppressed", "regular")

	self._unit:character_damage():add_listener("giant_bo_take_damage", { "on_take_damage" }, callback(self, self, "_on_damage"))
end

function GiantBoBase:save(data)
	data.enabled = self._enabled

	data.origin = self:state_data().origin
	data.radius = self:state_data().radius

	data.current_angle = self:state_data().current_angle
	data.target_angle = self:state_data().target_angle
end

function GiantBoBase:do_action(action)
	log(action)

	local action_data = self._actions[action]
	if not action_data then return 0 end

	local speed_multiplier = 1
	if action_data.use_aggressiveness then
		speed_multiplier = math.lerp(1, 1.5, self:state_data().aggressiveness)
	end

	if action_data.animation then
		local result = self._unit:play_redirect(Idstring(action_data.animation))
		self._unit:anim_state_machine():set_speed(result, speed_multiplier)
	end

	if action_data.sequence then
		self._unit:damage():run_sequence(action_data.sequence)
	end

	if action_data.func and self[action_data.func] then
		self[action_data.func]()
	end

	self._unit:network():send("run_mission_door_sequence", action)

	return (action_data.length or 0) / speed_multiplier
end

function GiantBoBase:show_health()
	managers.hud:open_boss_health("GIANT BO")
end

function GiantBoBase:hide_health()
	managers.hud:close_boss_health()
end

function GiantBoBase:_on_damage(unit, attacker, damage)
	if self._current_state == "dead" then return end

	local health_percentage = self._unit:character_damage():health_percentage()
	managers.hud:set_boss_health(health_percentage)

	self:state_data().aggressiveness = 1 - health_percentage

	if health_percentage == 0 then
		self:set_state("dead")
		return
	end

	if damage > 1000 then
		self:set_state("stun")
	end
end

function GiantBoBase:activate()
	self._enabled = true

	self:set_state("intro")
end

function GiantBoBase:state_data()
	return self._state_data
end

function GiantBoBase:set_state(new_state)
	self._current_state = new_state
end

local flame_mvec1 = Vector3()
function GiantBoBase:update(unit, t, dt)
	if not self._enabled then return end

	if self._last_state ~= self._current_state then
		if self._states[self._last_state] then
			self._states[self._last_state]:exit(t)
		end

		if self._states[self._current_state] then
			self._states[self._current_state]:enter(t)
		end

		self._last_state = self._current_state
	end

	if self._states[self._current_state] then
		self._states[self._current_state]:update(t, dt)
	end

	if self._flames then
		if self._next_flame_time <= t then
			self._next_flame_time = t + self._flame_stats.flame_rate

			local nozzle_pos = self:flame_spawn_pos()
			local direction = self._head:rotation():z()

			local rotation = Rotation(direction, math.UP)
			local effect_id = World:effect_manager():spawn({
				effect = self._flame_stats.flame_effect,
				position = nozzle_pos,
				rotation = rotation
			})

			table.insert(self._flamethrower_effect_collection, {
				been_alive = false,
				id = effect_id,
				position = mvector3.copy(nozzle_pos),
				direction = rotation:y()
			})
		end
	end

	if self._flamethrower_effect_collection ~= nil then
		local flame_effect_dt = self._flame_stats.single_flame_effect_duration / dt
		local flame_effect_distance = self._flame_stats.range / flame_effect_dt

		local hit_unit_count = 0
		local hit_units = {}

		for index, effect_entry in pairs(self._flamethrower_effect_collection) do
			local do_continue = true

			if World:effect_manager():alive(effect_entry.id) == false then
				if effect_entry.been_alive == true then
					World:effect_manager():kill(effect_entry.id)
					table.remove(self._flamethrower_effect_collection, index)

					do_continue = false
				end
			elseif effect_entry.been_alive == false then
				effect_entry.been_alive = true
			end

			if do_continue == true then
				mvector3.set(flame_mvec1, effect_entry.position)
				mvector3.add(effect_entry.position, effect_entry.direction * flame_effect_distance)

				local hit_damage_bodies = World:find_bodies("intersect", "sphere", effect_entry.position, self._flame_stats.radius, self._flame_stats.damage_slotmask)
				for idx, body in ipairs(hit_damage_bodies) do
					local unit = body:unit()
					if unit and alive(unit) and unit.character_damage and unit:character_damage() and unit:character_damage().damage_killzone then
						if not hit_units[unit:key()] then
							hit_units[unit:key()] = unit
							hit_unit_count = hit_unit_count + 1
						end
					end
				end

				local hit_bodies = World:find_bodies(self._unit, "intersect", "sphere", effect_entry.position, self._flame_stats.radius, self._flame_stats.slotmask)
				if #hit_bodies > 0 then
					table.remove(self._flamethrower_effect_collection, index)
				else
					World:effect_manager():move(effect_entry.id, effect_entry.position)
				end

				local effect_distance = mvector3.distance(effect_entry.position, self:flame_spawn_pos())

				if self._flame_stats.range < effect_distance then
					World:effect_manager():kill(effect_entry.id)
				end
			end
		end

		if self._next_flame_damage_time <= t then
			for key, unit in pairs(hit_units) do
				unit:character_damage():damage_killzone({
					damage = self._flame_stats.damage,
					col_ray = {
						ray = self._head:rotation():z()
					}
				})
			end

			if hit_unit_count > 0 then
				self._next_flame_damage_time = t + self._flame_stats.damage_rate
			end
		end
	end
end

-- Attack Stuff
	function GiantBoBase:play_sound(unit, event)
		self._sound:post_event(event)
	end

	function GiantBoBase:flame_spawn_pos()
		return self._head:position() + self._flame_stats.offset:rotate_with(self._head:rotation())
	end

	local function do_spread(direction, spread_x, spread_y)
		local right = direction:cross(math.UP):normalized()
		local up = direction:cross(right):normalized()

		local theta = math.random() * 360
		local ax = math.sin(theta) * math.random() * spread_x
		local ay = math.cos(theta) * math.random() * (spread_y or spread_x)

		mvector3.add(direction, right * math.rad(ax))
		mvector3.add(direction, up * math.rad(ay))
		mvector3.normalize(direction)
	end

	function GiantBoBase:shoot_grenade(unit, is_left)
		if Network:is_server() then
			local position = nil
			local direction = nil

			if is_left == "true" then
				position = self._left_finger:position()
				direction = self._left_finger:rotation():x()
			else
				position = self._right_finger:position()
				direction = self._right_finger:rotation():x() * -1
			end

			do_spread(direction, 20.0, 10.0)

			local grenade = ProjectileBase.throw_projectile_npc("frag", position, direction * 1.5)
			grenade:base()._timer = 5
		end
	end

	function GiantBoBase:set_flames(unit, state)
		if state == "true" and self._flames == false then
			self:play_sound(unit, "flamethrower_fire")
		elseif state == "false" and self._flames == true then
			self:play_sound(unit, "flamethrower_stop")
		end

		self._flames = state == "true"
	end

	function GiantBoBase:throw_molotov(unit)
		if Network:is_server() then
			local left_position = self._left_hand:position()
			local left_direction = self._left_hand:rotation():y() * -1
			left_position = left_position + (left_direction * 1000)

			local right_position = self._right_hand:position()
			local right_direction = self._right_hand:rotation():y()
			right_position = right_position + (right_direction * 1000)

			do_spread(left_direction, 5, 20)
			do_spread(right_direction, 5, 20)

			ProjectileBase.throw_projectile_npc("molotov", left_position, left_direction * 3)
			ProjectileBase.throw_projectile_npc("molotov", right_position, right_direction * 3)
		end
	end

	function GiantBoBase:throw_smoke(unit)
		if Network:is_server() then
			local left_position = self._left_hand:position()
			local left_direction = self._left_hand:rotation():x()
			left_position = left_position + (left_direction * 1000)

			local right_position = self._right_hand:position()
			local right_direction = self._right_hand:rotation():x() * -1
			right_position = right_position + (right_direction * 1000)

			do_spread(left_direction, 5, 2)
			do_spread(right_direction, 5, 2)

			ProjectileBase.throw_projectile_npc("molotov", left_position, left_direction * 2.5)
			ProjectileBase.throw_projectile_npc("molotov", right_position, right_direction * 2.5)
		end
	end

if not Network:is_server() then
	GiantBoBaseHusk._actions = GiantBoBase._actions
	GiantBoBase = GiantBoBaseHusk
end