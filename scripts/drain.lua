-- scripts/drain.lua
-- Atomically pops up to N messages from an agent's inbox (oldest first).
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: agent name (e.g. "alice")
-- ARGV[3]: max count to pop (default 50)

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

-- Ownership Guard: Prevent cross-project inbox draining
if caller_project ~= "" then
    local existing_proj = redis.call('HGET', prefix .. 'agent:' .. name, 'project')
    if existing_proj and existing_proj ~= "" and string.lower(existing_proj) ~= string.lower(caller_project) then
        if force_steal ~= 1 then
            return redis.error_reply("ERR_CROSS_PROJECT_DRAIN: Agent '" .. name .. "' belongs to project '" .. existing_proj .. "'. Draining across projects denied. Pass --force-steal to override.")
        end
    end
end
local messages = {}

for i = 1, count do
    local msg = redis.call('RPOP', prefix .. 'inbox:' .. name)
    if not msg then break end
    table.insert(messages, msg)
end
return messages
