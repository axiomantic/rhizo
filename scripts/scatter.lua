-- scripts/scatter.lua
-- Fans out a task message to target agents (either by comma-separated names, @tag, or *)
-- and returns the number of inboxes the task was delivered to.
-- ARGV[1]: prefix (e.g. "locutus:")
-- ARGV[2]: targets (e.g. "worker1,worker2" or "@qa" or "*")
-- ARGV[3]: message JSON string
-- ARGV[4]: inbox TTL seconds (default 300)

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local target_str = ARGV[2] or "*"
local msg_json = ARGV[3]
if not msg_json or msg_json == "" then
    return redis.error_reply("ERR: Missing message payload")
end

local inbox_ttl = tonumber(ARGV[4]) or 300

local targets = {}
if target_str == "*" or target_str == "@all" then
    targets = redis.call('SMEMBERS', prefix .. 'active_agents')
elseif string.sub(target_str, 1, 1) == "@" then
    local raw = string.sub(target_str, 2)
    local tag_keys = {}
    for tag in string.gmatch(raw, "([^,]+)") do
        local tr = string.lower(string.match(tag, "^%s*(.-)%s*$"))
        if tr ~= "" then
            table.insert(tag_keys, prefix .. 'tag:' .. tr)
        end
    end

    if #tag_keys == 0 then
        return 0
    elseif #tag_keys == 1 then
        targets = redis.call('SMEMBERS', tag_keys[1])
    else
        targets = redis.call('SINTER', unpack(tag_keys))
    end
else
    -- Comma-separated agent names
    for name in string.gmatch(target_str, "([^,]+)") do
        local tr = string.lower(string.match(name, "^%s*(.-)%s*$"))
        if tr ~= "" then
            table.insert(targets, tr)
        end
    end
end

local delivered = 0
for _, agent in ipairs(targets) do
    local norm_agent = string.lower(agent)
    local should_send = true
    if target_str == "*" or target_str == "@all" or string.sub(target_str, 1, 1) == "@" then
        if redis.call('EXISTS', prefix .. 'heartbeat:' .. norm_agent) ~= 1 then
            should_send = false
            -- Prune dead agent
            redis.call('SREM', prefix .. 'active_agents', norm_agent)
            local agent_tags = redis.call('HGET', prefix .. 'agent:' .. norm_agent, 'tags') or ""
            for t in string.gmatch(agent_tags, "([^,]+)") do
                local tr = string.lower(string.match(t, "^%s*(.-)%s*$"))
                if tr ~= "" then redis.call('SREM', prefix .. 'tag:' .. tr, norm_agent) end
            end
            redis.call('DEL', prefix .. 'agent:' .. norm_agent)
        end
    end

    if should_send then
        redis.call('LPUSH', prefix .. 'inbox:' .. norm_agent, msg_json)
        redis.call('EXPIRE', prefix .. 'inbox:' .. norm_agent, inbox_ttl)
        delivered = delivered + 1
    end
end

return delivered
