-- scripts/reserve_name.lua
-- Atomically tests candidate availability and reserves a codename hold with TTL.
-- ARGV[1]: prefix (e.g. "locutus:")
-- ARGV[2]: candidate name (e.g. "locutus-sequoia")
-- ARGV[3]: hold TTL seconds (default 600)

local prefix = ARGV[1]
if not prefix then
    prefix = ""
end

local candidate = ARGV[2]
if not candidate or candidate == "" then
    return redis.error_reply("ERR: Missing candidate name")
end
candidate = string.lower(candidate)

local ttl = tonumber(ARGV[3]) or 600

-- 1. Check active heartbeat
if redis.call('EXISTS', prefix .. 'heartbeat:' .. candidate) == 1 then
    return 0
end

-- 2. Check active directory roster
if redis.call('SISMEMBER', prefix .. 'active_agents', candidate) == 1 then
    return 0
end

-- 3. Check active listener registration
if redis.call('EXISTS', prefix .. 'listener:' .. candidate) == 1 then
    return 0
end

-- 3b. Check active inbox
if redis.call('EXISTS', prefix .. 'inbox:' .. candidate) == 1 then
    return 0
end

-- 4. Atomically set reservation hold
local ok = redis.call('SET', prefix .. 'held_name:' .. candidate, '1', 'EX', ttl, 'NX')
if ok then
    return 1
else
    return 0
end
