local world_path = minetest.get_worldpath()
local data_dir = world_path .. "/dashboard"
local state_path = data_dir .. "/state.json"
local chat_path = data_dir .. "/chat.json"
local sessions = {}
local chat = {}

minetest.mkdir(data_dir)

local function utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function write_json(path, value)
  local encoded = minetest.write_json(value, true)
  if encoded then minetest.safe_file_write(path, encoded) end
end

local function add_chat(player, message, kind)
  table.insert(chat, 1, { player = player, message = message, kind = kind or "chat", time = utc_now() })
  while #chat > 100 do table.remove(chat) end
  write_json(chat_path, chat)
end

minetest.register_on_joinplayer(function(player)
  local name = player:get_player_name()
  sessions[name] = os.time()
  add_chat("System", name .. " joined the game.", "system")
end)

minetest.register_on_leaveplayer(function(player)
  local name = player:get_player_name()
  sessions[name] = nil
  add_chat("System", name .. " left the game.", "system")
end)

minetest.register_on_chat_message(function(name, message)
  if message:sub(1, 1) ~= "/" then add_chat(name, message, "chat") end
  return false
end)

local function publish_state()
  local players = {}
  for _, player in ipairs(minetest.get_connected_players()) do
    local name = player:get_player_name()
    local pos = player:get_pos()
    table.insert(players, { name = name, x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5), joined_at = sessions[name] or os.time(), hp = player:get_hp() })
  end
  write_json(state_path, { generated_at = utc_now(), players = players, player_count = #players, game_time = minetest.get_timeofday(), day_count = minetest.get_day_count() })
  minetest.after(3, publish_state)
end

minetest.after(1, publish_state)
