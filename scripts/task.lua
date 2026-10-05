-- scripts/task.lua
-- First-Class Task Lifecycle & Distributed Lease Manager
-- Invariants: Single active task per worker; monotonic task states; traceable deliverables.

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local action = ARGV[2] or ""
local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

if action == "create" then
    local task_id = ARGV[3]
    if not task_id or task_id == "" then
        return redis.error_reply("ERR: Missing task_id")
    end
    local title = ARGV[4] or ""
    local deliverable = ARGV[5] or ""
    local spec = ARGV[6] or ""

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 1 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' already exists")
    end

    redis.call('HSET', task_key,
        "id", task_id,
        "title", title,
        "deliverable", deliverable,
        "spec", spec,
        "state", "UNASSIGNED",
        "owner", "",
        "strand_path", "",
        "lease_until", 0,
        "progress", "",
        "created_at", now
    )
    redis.call('SADD', prefix .. "tasks", task_id)
    return "OK"

elseif action == "claim" then
    local task_id = ARGV[3]
    local worker = ARGV[4]
    local lease_sec = tonumber(ARGV[5]) or 300
    local strand_path = ARGV[6] or ""

    if not task_id or task_id == "" or not worker or worker == "" then
        return redis.error_reply("ERR: Missing task_id or worker name")
    end

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' does not exist")
    end

    local current_state = redis.call('HGET', task_key, "state") or "UNASSIGNED"
    local current_owner = redis.call('HGET', task_key, "owner") or ""
    local lease_until = tonumber(redis.call('HGET', task_key, "lease_until") or 0)

    -- If already claimed by another worker whose lease hasn't expired:
    if current_state == "IN_PROGRESS" and current_owner ~= "" and current_owner ~= worker and now < lease_until then
        return redis.error_reply("ERR: Task '" .. task_id .. "' is currently claimed by '" .. current_owner .. "' (lease active for " .. (lease_until - now) .. "s)")
    end

    -- Single-active-lease invariant: Check if worker holds another active task
    local active_task = redis.call('GET', prefix .. "agent_task:" .. worker)
    if active_task and active_task ~= false and active_task ~= "" and active_task ~= task_id then
        return redis.error_reply("ERR: Worker '" .. worker .. "' already holds active lease on task '" .. active_task .. "'. Complete or yield it first.")
    end

    local new_lease = now + lease_sec
    redis.call('HSET', task_key,
        "state", "IN_PROGRESS",
        "owner", worker,
        "lease_until", new_lease,
        "strand_path", strand_path
    )
    redis.call('SET', prefix .. "agent_task:" .. worker, task_id)
    redis.call('HSET', prefix .. "agent:" .. worker, "current_task", task_id)
    return "OK"

elseif action == "progress" then
    local task_id = ARGV[3]
    local worker = ARGV[4]
    local progress_text = ARGV[5] or ""
    local renew_lease = tonumber(ARGV[6]) or 300

    local task_key = prefix .. "task:" .. task_id
    local current_owner = redis.call('HGET', task_key, "owner") or ""
    if current_owner ~= worker then
        return redis.error_reply("ERR: Worker '" .. worker .. "' does not own task '" .. task_id .. "'")
    end

    local new_lease = now + renew_lease
    redis.call('HSET', task_key, "progress", progress_text, "lease_until", new_lease)
    return "OK"

elseif action == "complete" then
    local task_id = ARGV[3]
    local worker = ARGV[4]
    local gate_token = ARGV[5] or ""

    local task_key = prefix .. "task:" .. task_id
    local current_owner = redis.call('HGET', task_key, "owner") or ""
    if current_owner ~= worker then
        return redis.error_reply("ERR: Worker '" .. worker .. "' does not own task '" .. task_id .. "'")
    end

    redis.call('HSET', task_key,
        "state", "COMPLETED",
        "gate_token", gate_token,
        "completed_at", now
    )
    redis.call('DEL', prefix .. "agent_task:" .. worker)
    redis.call('HDEL', prefix .. "agent:" .. worker, "current_task")
    return "OK"

elseif action == "yield" or action == "abandon" then
    local task_id = ARGV[3]
    local worker = ARGV[4]
    local reason = ARGV[5] or ""

    local task_key = prefix .. "task:" .. task_id
    redis.call('HSET', task_key,
        "state", "UNASSIGNED",
        "owner", "",
        "lease_until", 0,
        "yield_reason", reason
    )
    redis.call('DEL', prefix .. "agent_task:" .. worker)
    redis.call('HDEL', prefix .. "agent:" .. worker, "current_task")
    return "OK"

elseif action == "get" then
    local task_id = ARGV[3]
    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return "{}"
    end
    local data = redis.call('HGETALL', task_key)
    local obj = {}
    for i = 1, #data, 2 do
        obj[data[i]] = data[i+1]
    end
    return cjson.encode(obj)

elseif action == "list" then
    local task_ids = redis.call('SMEMBERS', prefix .. "tasks")
    local list = {}
    for _, tid in ipairs(task_ids) do
        local task_key = prefix .. "task:" .. tid
        local data = redis.call('HGETALL', task_key)
        local obj = {}
        for i = 1, #data, 2 do
            obj[data[i]] = data[i+1]
        end
        table.insert(list, obj)
    end
    return cjson.encode(list)

else
    return redis.error_reply("ERR: Unknown task action: " .. action)
end
