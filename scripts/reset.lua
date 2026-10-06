-- scripts/reset.lua
-- Dual-phase clean reset and nuke:
-- Phase 1 (notify): Pushes shutdown payload to agent inboxes so BLPOP listeners wake up and terminate.
-- Phase 2 (purge): Deletes keys for prefix or project.

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local phase = ARGV[2] or "all"
local target_project = string.lower(ARGV[3] or "")
local shutdown_payload = ARGV[4] or ""

local function safe_del(keys_to_del)
    local deleted = 0
    if #keys_to_del > 0 then
        for i = 1, #keys_to_del, 500 do
            local chunk = {}
            for j = i, math.min(i + 499, #keys_to_del) do
                table.insert(chunk, keys_to_del[j])
            end
            if #chunk > 0 then
                deleted = deleted + redis.call('DEL', unpack(chunk))
            end
        end
    end
    return deleted
end

if phase == "notify" then
    local agents = {}
    if target_project == "" or target_project == "*" then
        agents = redis.call('SMEMBERS', prefix .. "active_agents") or {}
    else
        local tag_members = redis.call('SMEMBERS', prefix .. "tag:" .. target_project) or {}
        local agent_set = {}
        for _, a in ipairs(tag_members) do agent_set[a] = true end
        local all_active = redis.call('SMEMBERS', prefix .. "active_agents") or {}
        local pfx_match = target_project .. "-"
        for _, a in ipairs(all_active) do
            if string.sub(a, 1, #pfx_match) == pfx_match then
                agent_set[a] = true
            end
        end
        for a, _ in pairs(agent_set) do table.insert(agents, a) end
    end

    if shutdown_payload ~= "" then
        for _, a in ipairs(agents) do
            redis.call('RPUSH', prefix .. "inbox:" .. a, shutdown_payload)
        end
    end

    local agent_strs = {}
    for i, a in ipairs(agents) do
        table.insert(agent_strs, string.format("%q", a))
    end
    return string.format('{"status":"ok","phase":"notify","closed_agents":[%s]}', table.concat(agent_strs, ","))

elseif phase == "purge" or phase == "all" then
    local deleted_count = 0
    local closed_agents = {}

    if target_project == "" or target_project == "*" then
        -- Wipe all keys for prefix
        local all_active = redis.call('SMEMBERS', prefix .. "active_agents") or {}
        for _, a in ipairs(all_active) do table.insert(closed_agents, a) end

        local all_keys = redis.call('KEYS', prefix .. '*')
        deleted_count = safe_del(all_keys)
    else
        -- Wipe project-specific keys
        local proj_agents = {}
        local tag_members = redis.call('SMEMBERS', prefix .. "tag:" .. target_project) or {}
        for _, a in ipairs(tag_members) do proj_agents[a] = true end
        local all_active = redis.call('SMEMBERS', prefix .. "active_agents") or {}
        local pfx_match = target_project .. "-"
        for _, a in ipairs(all_active) do
            if string.sub(a, 1, #pfx_match) == pfx_match then
                proj_agents[a] = true
            end
        end

        local keys_to_delete = {}
        for agent, _ in pairs(proj_agents) do
            table.insert(closed_agents, agent)
            table.insert(keys_to_delete, prefix .. "heartbeat:" .. agent)
            table.insert(keys_to_delete, prefix .. "listener:" .. agent)
            table.insert(keys_to_delete, prefix .. "agent:" .. agent)
            table.insert(keys_to_delete, prefix .. "inbox:" .. agent)

            redis.call('SREM', prefix .. "active_agents", agent)
            local old_tags = redis.call('HGET', prefix .. "agent:" .. agent, 'tags') or ""
            for tag in string.gmatch(old_tags, "([^,]+)") do
                local tr = string.lower(string.match(tag, "^%s*(.-)%s*$"))
                if tr ~= "" then redis.call('SREM', prefix .. "tag:" .. tr, agent) end
            end
        end

        table.insert(keys_to_delete, prefix .. "tag:" .. target_project)
        local held_keys = redis.call('KEYS', prefix .. "held_name:" .. target_project .. "-*")
        for _, k in ipairs(held_keys) do table.insert(keys_to_delete, k) end

        local q1 = redis.call('KEYS', prefix .. "queue:" .. target_project .. ":*")
        for _, k in ipairs(q1) do table.insert(keys_to_delete, k) end
        local q2 = redis.call('KEYS', prefix .. "queue:dlq:" .. target_project .. ":*")
        for _, k in ipairs(q2) do table.insert(keys_to_delete, k) end
        local q3 = redis.call('KEYS', prefix .. "queue:{" .. target_project .. "}*")
        for _, k in ipairs(q3) do table.insert(keys_to_delete, k) end

        deleted_count = safe_del(keys_to_delete)
    end

    local agent_strs = {}
    for i, a in ipairs(closed_agents) do
        table.insert(agent_strs, string.format("%q", a))
    end
    return string.format('{"status":"ok","phase":"purge","closed_agents":[%s],"deleted_keys":%d}', table.concat(agent_strs, ","), deleted_count)
end
