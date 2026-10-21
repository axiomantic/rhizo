-- scripts/directory.lua
-- Lists registered agents, their liveness heartbeat (1 or 0), tags, state, activity, listener attachment, and elapsed seconds since last seen.
-- Pure query: NEVER prunes or mutates state on read.
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: optional filter tag (e.g. "rhizo", or "*" / nil for all)

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local filter = ARGV[2]
local agents = {}

if filter and filter ~= "" and filter ~= "*" and filter ~= "@all" then
    local filter_tag = string.lower(filter)
    local from_tag = redis.call('SMEMBERS', prefix .. 'tag:' .. filter_tag)
    local seen = {}
    for _, a in ipairs(from_tag) do
        seen[a] = true
        table.insert(agents, a)
    end
    -- Check if filter_tag is an exact agent name in active_agents
    if redis.call('SISMEMBER', prefix .. 'active_agents', filter_tag) == 1 then
        if not seen[filter_tag] then
            seen[filter_tag] = true
            table.insert(agents, filter_tag)
        end
    end
    -- Also scan active_agents for matching project field or agent name
    local all_active = redis.call('SMEMBERS', prefix .. 'active_agents')
    for _, a in ipairs(all_active) do
        if not seen[a] then
            local a_low = string.lower(a)
            local a_proj = redis.call('HGET', prefix .. 'agent:' .. a, 'project')
            if a_low == filter_tag or (a_proj and string.lower(a_proj) == filter_tag) then
                seen[a] = true
                table.insert(agents, a)
            end
        end
    end
    -- Also check if agent:<filter_tag> or listener:<filter_tag> exists directly
    if not seen[filter_tag] then
        if redis.call('EXISTS', prefix .. 'agent:' .. filter_tag) == 1 or redis.call('EXISTS', prefix .. 'listener:' .. filter_tag) == 1 then
            seen[filter_tag] = true
            table.insert(agents, filter_tag)
        end
    end
else
    agents = redis.call('SMEMBERS', prefix .. 'active_agents')
end

local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

local result = {}
for _, agent in ipairs(agents) do
    local meta = redis.call('HMGET', prefix .. 'agent:' .. agent, 'tags', 'state', 'activity', 'last_seen', 'heartbeat_ttl', 'current_task', 'project')
    local tags = meta[1] or ""
    local state = meta[2]
    if not state or state == "" then state = "idle" end
    local activity = meta[3] or ""
    local last_seen = tonumber(meta[4]) or now
    local hb_ttl = tonumber(meta[5]) or 150
    local cur_task = meta[6] or ""
    local proj = meta[7] or ""
    if cur_task == "" then
        local at = redis.call('GET', prefix .. 'agent_task:' .. agent)
        if at and at ~= false and at ~= "" then
            cur_task = at
        end
    end
    if cur_task ~= "" and (state == "idle" or state == "busy") then
        state = "busy (" .. cur_task .. ")"
    end

    local hb_exists = redis.call('EXISTS', prefix .. 'heartbeat:' .. agent)
    local elapsed = math.max(0, now - last_seen)
    local alive = 0
    if hb_exists == 1 and elapsed <= hb_ttl then
        alive = 1
    end

    -- In-Flight Task Lease Liveness:
    -- If agent holds an active task lease (state IN_PROGRESS, CLAIMED, or DELIVERED within active window),
    -- treat agent as alive and state as busy (<cur_task>), preventing STALE during long work.
    if cur_task ~= "" then
        local t_meta = redis.call('HMGET', prefix .. 'task:' .. string.lower(cur_task), 'state', 'lease_until', 'delivery_until', 'progress')
        local t_state = t_meta[1]
        local t_lease = tonumber(t_meta[2]) or 0
        local t_delivery = tonumber(t_meta[3]) or 0
        local t_progress = t_meta[4] or ""
        if ((t_state == "IN_PROGRESS" or t_state == "CLAIMED") and now < t_lease) or (t_state == "DELIVERED" and (now < t_delivery or now < t_lease)) then
            alive = 1
            state = "busy (" .. cur_task .. ")"
            if activity == "" and t_progress ~= "" then
                activity = t_progress
            end
        end
    end

    local listener_raw = redis.call('GET', prefix .. 'listener:' .. agent)
    local has_listener = 0
    if listener_raw and listener_raw ~= false and listener_raw ~= "" then
        has_listener = 1
    end

    -- Active Listener Liveness:
    -- If an agent maintains an active listener process in Redis (listener:<name> exists with valid TTL),
    -- it is actively listening on the bus and ready to receive messages. Never mark as STALE while actively listening.
    if has_listener == 1 then
        alive = 1
    end

    -- Format: agent|alive|tags|state|activity|has_listener|elapsed|project
    table.insert(result, agent .. "|" .. alive .. "|" .. tags .. "|" .. state .. "|" .. activity .. "|" .. has_listener .. "|" .. elapsed .. "|" .. proj)
end
return result
