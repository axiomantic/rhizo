-- scripts/peek.lua
-- Non-destructively inspects up to N messages from an agent's inbox (oldest first, matching drain order).
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: agent name (e.g. "alice")
-- ARGV[3]: max count to peek (default 50)
-- ARGV[4]: caller project (e.g. "myproj")
-- ARGV[5]: force_steal flag (0 or 1)

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local name = ARGV[2]
if not name or name == "" then
    return redis.error_reply("ERR: Missing agent name")
end
name = string.lower(name)

-- Resolve alias if configured
local alias_target = redis.call('HGET', prefix .. 'aliases', name)
if alias_target and alias_target ~= false and alias_target ~= '' then
    name = string.lower(alias_target)
end

local count = tonumber(ARGV[3]) or 50
local caller_project = ARGV[4] or ""
local force_steal = tonumber(ARGV[5] or 0)

-- Ownership Guard: Prevent cross-project inbox peeking
if caller_project ~= "" then
    local existing_proj = redis.call('HGET', prefix .. 'agent:' .. name, 'project')
    if existing_proj and existing_proj ~= "" and string.lower(existing_proj) ~= string.lower(caller_project) then
        if force_steal ~= 1 then
            return redis.error_reply("ERR_CROSS_PROJECT_DRAIN: Agent '" .. name .. "' belongs to project '" .. existing_proj .. "'. Peeking across projects denied. Pass --force-steal to override.")
        end
    end
end

local len = redis.call('LLEN', prefix .. 'inbox:' .. name)
if len == 0 then return {} end

-- Messages are LPUSHed into inbox, so tail is oldest (index len - 1).
-- RPOP pops oldest first.
-- To peek up to `count` oldest messages in FIFO order:
local start_idx = math.max(0, len - count)
local raw_messages = redis.call('LRANGE', prefix .. 'inbox:' .. name, start_idx, len - 1)
local messages = {}
for i = #raw_messages, 1, -1 do
    table.insert(messages, raw_messages[i])
end
return messages
