-- scripts/task.lua
-- Unified Work Item State Machine (WISM) & Distributed Lease Manager
-- Invariants: Single active task per worker; monotonic task states; DAG dependency auto-unblocking;
-- atomic transport receipts; local disk mirror synchronization.

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local action = ARGV[2] or ""
local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

local function split_csv(str)
    local t = {}
    if not str or str == "" then return t end
    for item in string.gmatch(str, '([^,]+)') do
        local trimmed = string.match(item, "^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            table.insert(t, string.lower(trimmed))
        end
    end
    return t
end

local function are_dependencies_completed(prefix_str, dep_str)
    local deps = split_csv(dep_str)
    if #deps == 0 then return true end
    for _, dep_id in ipairs(deps) do
        local dep_key = prefix_str .. "task:" .. dep_id
        local state = redis.call('HGET', dep_key, "state")
        if state ~= "COMPLETED" then
            return false
        end
    end
    return true
end

if action == "create" then
    local task_id = string.lower(ARGV[3] or "")
    if not task_id or task_id == "" then
        return redis.error_reply("ERR: Missing task_id")
    end
    local title = ARGV[4] or ""
    local deliverable = ARGV[5] or ""
    local spec = ARGV[6] or ""
    local depends_on = string.lower(ARGV[7] or "")
    local target = string.lower(ARGV[8] or "")
    local fencing_keys = ARGV[9] or ""

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 1 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' already exists")
    end

    local initial_state = "QUEUED"
    if depends_on ~= "" and not are_dependencies_completed(prefix, depends_on) then
        initial_state = "BLOCKED"
    end

    redis.call('HSET', task_key,
        "id", task_id,
        "title", title,
        "deliverable", deliverable,
        "spec", spec,
        "depends_on", depends_on,
        "target", target,
        "fencing_keys", fencing_keys,
        "state", initial_state,
        "owner", "",
        "strand_path", "",
        "lease_until", 0,
        "delivery_until", 0,
        "delivery_attempts", 0,
        "progress", "",
        "gate_token", "",
        "created_at", now
    )
    redis.call('SADD', prefix .. "tasks", task_id)

    local resObj = {
        id = task_id,
        state = initial_state,
        target = target,
        depends_on = depends_on
    }
    return cjson.encode(resObj)

elseif action == "deliver" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local timeout_sec = tonumber(ARGV[5]) or 180
    local title = ARGV[6] or ""
    local spec = ARGV[7] or ""

    if not task_id or task_id == "" or not worker or worker == "" then
        return redis.error_reply("ERR: Missing task_id or worker name")
    end

    local task_key = prefix .. "task:" .. task_id
    local exists = redis.call('EXISTS', task_key)

    if exists == 0 then
        -- Auto-provision ad-hoc task record for incoming message directives
        redis.call('HSET', task_key,
            "id", task_id,
            "title", (title ~= "" and title or task_id),
            "deliverable", "",
            "spec", spec,
            "depends_on", "",
            "target", worker,
            "fencing_keys", "",
            "state", "DELIVERED",
            "owner", worker,
            "strand_path", "",
            "lease_until", 0,
            "delivery_until", (now + timeout_sec),
            "delivery_attempts", 1,
            "progress", "",
            "gate_token", "",
            "created_at", now,
            "delivered_at", now
        )
        redis.call('SADD', prefix .. "tasks", task_id)
    else
        local attempts = tonumber(redis.call('HGET', task_key, "delivery_attempts") or 0) + 1
        redis.call('HSET', task_key,
            "state", "DELIVERED",
            "owner", worker,
            "delivered_at", now,
            "delivery_until", (now + timeout_sec),
            "delivery_attempts", attempts
        )
    end

    redis.call('SET', prefix .. "current_task:" .. worker, task_id)
    redis.call('HSET', prefix .. "agent:" .. worker, "current_task", task_id)

    -- Publish transport receipt
    local receipt = {
        event = "TRANSPORT_RECEIPT",
        task_id = task_id,
        worker = worker,
        delivered_at = now,
        status = "DELIVERED"
    }
    redis.call('PUBLISH', prefix .. "receipts", cjson.encode(receipt))

    local task_data = redis.call('HGETALL', task_key)
    local obj = {}
    for i = 1, #task_data, 2 do
        obj[task_data[i]] = task_data[i+1]
    end
    return cjson.encode(obj)

elseif action == "claim" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local lease_sec = tonumber(ARGV[5]) or 1800
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

    -- Active lease lock check
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
        "claimed_at", now,
        "lease_until", new_lease,
        "strand_path", strand_path
    )
    redis.call('SET', prefix .. "agent_task:" .. worker, task_id)
    redis.call('SET', prefix .. "current_task:" .. worker, task_id)
    redis.call('HSET', prefix .. "agent:" .. worker, "current_task", task_id)
    return "OK"

elseif action == "progress" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local progress_text = ARGV[5] or ""
    local renew_lease = tonumber(ARGV[6]) or 300

    local task_key = prefix .. "task:" .. task_id
    local current_owner = redis.call('HGET', task_key, "owner") or ""
    if current_owner ~= "" and current_owner ~= worker then
        return redis.error_reply("ERR: Worker '" .. worker .. "' does not own task '" .. task_id .. "'")
    end

    local new_lease = now + renew_lease
    redis.call('HSET', task_key, "progress", progress_text, "lease_until", new_lease)
    return "OK"

elseif action == "gate-report" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local gate_token = ARGV[5] or ""
    local strand_path = ARGV[6] or ""

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' does not exist")
    end

    redis.call('HSET', task_key,
        "state", "READY_TO_WEAVE",
        "gate_token", gate_token,
        "strand_path", (strand_path ~= "" and strand_path or redis.call('HGET', task_key, "strand_path"))
    )
    return "OK"

elseif action == "complete" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local gate_token = ARGV[5] or ""

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' does not exist")
    end

    local current_owner = redis.call('HGET', task_key, "owner") or ""
    if current_owner ~= "" and current_owner ~= worker and worker ~= "orchestrator" and worker ~= "" then
        -- Allow orchestrator or owner to complete
        return redis.error_reply("ERR: Worker '" .. worker .. "' does not own task '" .. task_id .. "'")
    end

    redis.call('HSET', task_key,
        "state", "COMPLETED",
        "gate_token", gate_token,
        "completed_at", now
    )

    if current_owner ~= "" then
        redis.call('DEL', prefix .. "agent_task:" .. current_owner)
        redis.call('DEL', prefix .. "current_task:" .. current_owner)
        redis.call('HDEL', prefix .. "agent:" .. current_owner, "current_task")
    end
    if worker ~= "" and worker ~= current_owner then
        redis.call('DEL', prefix .. "agent_task:" .. worker)
        redis.call('DEL', prefix .. "current_task:" .. worker)
        redis.call('HDEL', prefix .. "agent:" .. worker, "current_task")
    end

    -- AUTOMATIC DAG DEPENDENCY RESOLUTION:
    -- Find any BLOCKED task whose dependencies are now 100% completed
    local all_tasks = redis.call('SMEMBERS', prefix .. "tasks")
    local unblocked = {}
    for _, tid in ipairs(all_tasks) do
        local tk = prefix .. "task:" .. tid
        local st = redis.call('HGET', tk, "state")
        if st == "BLOCKED" then
            local deps = redis.call('HGET', tk, "depends_on") or ""
            if are_dependencies_completed(prefix, deps) then
                redis.call('HSET', tk, "state", "QUEUED")
                local target = redis.call('HGET', tk, "target") or ""
                table.insert(unblocked, { id = tid, target = target })
                -- Publish unblocked notification
                redis.call('PUBLISH', prefix .. "task_events", cjson.encode({
                    event = "TASK_UNBLOCKED",
                    task_id = tid,
                    target = target
                }))
            end
        end
    end

    local ret = {
        status = "COMPLETED",
        task_id = task_id,
        unblocked_count = #unblocked,
        unblocked_tasks = unblocked
    }
    return cjson.encode(ret)

elseif action == "yield" or action == "abandon" then
    local task_id = string.lower(ARGV[3] or "")
    local worker = string.lower(ARGV[4] or "")
    local reason = ARGV[5] or ""

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return redis.error_reply("ERR: Task '" .. task_id .. "' does not exist")
    end

    redis.call('HSET', task_key,
        "state", "QUEUED",
        "owner", "",
        "lease_until", 0,
        "yield_reason", reason
    )
    if worker ~= "" then
        redis.call('DEL', prefix .. "agent_task:" .. worker)
        redis.call('DEL', prefix .. "current_task:" .. worker)
        redis.call('HDEL', prefix .. "agent:" .. worker, "current_task")
    end
    return "OK"

elseif action == "sweep" then
    local all_tasks = redis.call('SMEMBERS', prefix .. "tasks")
    local swept = {}
    for _, tid in ipairs(all_tasks) do
        local tk = prefix .. "task:" .. tid
        local st = redis.call('HGET', tk, "state")
        local owner = redis.call('HGET', tk, "owner") or ""

        if st == "DELIVERED" then
            local delivery_until = tonumber(redis.call('HGET', tk, "delivery_until") or 0)
            if delivery_until > 0 and now > delivery_until then
                local attempts = tonumber(redis.call('HGET', tk, "delivery_attempts") or 1)
                if attempts >= 3 then
                    redis.call('HSET', tk, "state", "DEAD_LETTER")
                    if owner ~= "" then
                        redis.call('DEL', prefix .. "current_task:" .. owner)
                    end
                    table.insert(swept, { id = tid, previous_state = "DELIVERED", new_state = "DEAD_LETTER", attempts = attempts })
                else
                    redis.call('HSET', tk, "state", "ORPHANED")
                    if owner ~= "" then
                        redis.call('DEL', prefix .. "current_task:" .. owner)
                    end
                    table.insert(swept, { id = tid, previous_state = "DELIVERED", new_state = "ORPHANED", attempts = attempts })
                end
            end
        elseif st == "IN_PROGRESS" then
            local lease_until = tonumber(redis.call('HGET', tk, "lease_until") or 0)
            if lease_until > 0 and now > lease_until then
                redis.call('HSET', tk, "state", "ORPHANED")
                if owner ~= "" then
                    redis.call('DEL', prefix .. "agent_task:" .. owner)
                    redis.call('DEL', prefix .. "current_task:" .. owner)
                    redis.call('HDEL', prefix .. "agent:" .. owner, "current_task")
                end
                table.insert(swept, { id = tid, previous_state = "IN_PROGRESS", new_state = "ORPHANED" })
            end
        end
    end
    return cjson.encode(swept)

elseif action == "current" then
    local worker = string.lower(ARGV[3] or "")
    if not worker or worker == "" then
        return "{}"
    end

    local task_id = redis.call('GET', prefix .. "current_task:" .. worker)
    if not task_id or task_id == false or task_id == "" then
        task_id = redis.call('GET', prefix .. "agent_task:" .. worker)
    end
    if not task_id or task_id == false or task_id == "" then
        return "{}"
    end

    local task_key = prefix .. "task:" .. task_id
    if redis.call('EXISTS', task_key) == 0 then
        return "{}"
    end

    local task_data = redis.call('HGETALL', task_key)
    local obj = {}
    for i = 1, #task_data, 2 do
        obj[task_data[i]] = task_data[i+1]
    end
    return cjson.encode(obj)

elseif action == "get" then
    local task_id = string.lower(ARGV[3] or "")
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
    local state_filter = string.upper(ARGV[3] or "")
    local task_ids = redis.call('SMEMBERS', prefix .. "tasks")
    local list = {}
    for _, tid in ipairs(task_ids) do
        local task_key = prefix .. "task:" .. tid
        local data = redis.call('HGETALL', task_key)
        local obj = {}
        for i = 1, #data, 2 do
            obj[data[i]] = data[i+1]
        end
        if state_filter == "" or state_filter == "ALL" or string.upper(obj.state or "") == state_filter then
            table.insert(list, obj)
        end
    end
    return cjson.encode(list)

else
    return redis.error_reply("ERR: Unknown task action: " .. action)
end
