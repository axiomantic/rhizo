-- scripts/status.lua
-- Updates an agent's operational state (idle, busy, error) and current activity description.
-- Also refreshes the agent's heartbeat.
-- ARGV[1]: prefix (e.g. "locutus:")
-- ARGV[2]: agent name (e.g. "alice")
-- ARGV[3]: state ("idle", "busy", "error", "offline")
-- ARGV[4]: activity text (e.g. "Running unit tests")
-- ARGV[5]: heartbeat TTL seconds (default 150)

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local name = ARGV[2]
if not name or name == "" then
    return redis.error_reply("ERR: Missing agent name")
end

local state = ARGV[3] or ""
local activity = ARGV[4] or ""
local ttl = tonumber(ARGV[5]) or 150

local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

redis.call('SET', prefix .. 'heartbeat:' .. name, '1', 'EX', ttl)
redis.call('HSET', prefix .. 'agent:' .. name, 'state', state, 'activity', activity, 'last_seen', now, 'heartbeat_ttl', ttl)
redis.call('SADD', prefix .. 'active_agents', name)
return "OK"
