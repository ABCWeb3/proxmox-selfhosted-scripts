local world_path = minetest.get_worldpath()
local data_dir = world_path .. "/dashboard"
local state_path = data_dir .. "/state.json"
local chat_path = data_dir .. "/chat.json"
local command_path = data_dir .. "/command.json"
local result_path = data_dir .. "/command-result.json"
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

local function process_command()
  local file = io.open(command_path, "r")
  if file then
    local raw = file:read("*a"); file:close(); os.remove(command_path)
    local cmd = minetest.parse_json(raw)
    local ok, message = false, "Invalid command"
    if type(cmd) == "table" then
      if cmd.action == "announce" and type(cmd.message) == "string" then
        minetest.chat_send_all("[Admin] " .. cmd.message); ok, message = true, "Announcement sent"
      elseif cmd.action == "kick" and type(cmd.player) == "string" then
        ok = minetest.kick_player(cmd.player, cmd.reason or "Removed by server administrator") or false; message = ok and "Player kicked" or "Player is not online"
      elseif cmd.action == "ban" and type(cmd.player) == "string" then
        minetest.ban_player(cmd.player); minetest.kick_player(cmd.player, "Banned by server administrator"); ok, message = true, "Player banned"
      elseif cmd.action == "unban" and type(cmd.player) == "string" then
        ok = minetest.unban_player_or_ip(cmd.player) or false; message = ok and "Ban removed" or "Player was not banned"
      end
    end
    write_json(result_path, { ok = ok, message = message, time = utc_now() })
  end
  minetest.after(1, process_command)
end

minetest.after(1, publish_state)
minetest.after(2, process_command)
