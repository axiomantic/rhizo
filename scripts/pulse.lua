-- scripts/pulse.lua
-- Atomic Redis script for distributed cron & pulse scheduler over sorted sets.
-- Invariants:
-- 1. Pulse metadata stored in HASH prefix .. "pulse:" .. pulse_id
-- 2. Pulse schedule indexed in ZSET prefix .. "pulses" scored by Unix timestamp next_run
-- 3. Monotonic fencing tokens ensure linearizable tick execution
-- 4. High-availability zero-duplicate ticks via atomic ZRANGEBYSCORE + score advancement
--
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: action: "add", "list", "get", "remove", "tick"
-- ARGV[3..]: action-specific arguments

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local action = ARGV[2] or ""

-- Mock time resolution for reproducible testing and deterministic simulation
local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

--------------------------------------------------------------------------------
-- Calendar and Epoch Arithmetic (UTC)
--------------------------------------------------------------------------------

local function epoch_to_dt(t)
    local sec = t % 60
    local total_m = math.floor(t / 60)
    local min = total_m % 60
    local total_h = math.floor(total_m / 60)
    local hour = total_h % 24
    local total_days = math.floor(total_h / 24)
    local dow = (total_days + 4) % 7 -- 1970-01-01 was Thursday (dow=4; 0=Sun..6=Sat)

    local a = total_days + 32044 + 2440588
    local b = math.floor((4 * a + 3) / 146097)
    local c = a - math.floor((146097 * b) / 4)
    local d = math.floor((4 * c + 3) / 1461)
    local e = c - math.floor((1461 * d) / 4)
    local m = math.floor((5 * e + 2) / 153)
    local day = e - math.floor((153 * m + 2) / 5) + 1
    local month = m + 3 - 12 * math.floor(m / 10)
    local year = 100 * b + d - 4800 + math.floor(m / 10)

    return {
        sec = sec,
        min = min,
        hour = hour,
        day = day,
        month = month,
        year = year,
        dow = dow
    }
end

local function dt_to_epoch(dt)
    local y = dt.year
    local m = dt.month
    if m <= 2 then
        y = y - 1
        m = m + 12
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m - 3) + 2) / 5) + dt.day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + dt.hour * 3600 + dt.min * 60 + dt.sec
end

--------------------------------------------------------------------------------
-- Cron Expression Matching & Calculation
--------------------------------------------------------------------------------

local function match_field(val, field_str, min_val, max_val)
    if field_str == "*" then return true end
    for part in string.gmatch(field_str, "([^,]+)") do
        local expr, step = string.match(part, "^(.-)/(%d+)$")
        step = tonumber(step) or 1
        if not expr then expr = part end

        local start_v, end_v
        if expr == "*" then
            start_v = min_val
            end_v = max_val
        else
            local r1, r2 = string.match(expr, "^(%d+)%-(%d+)$")
            if r1 and r2 then
                start_v = tonumber(r1)
                end_v = tonumber(r2)
            else
                local single = tonumber(expr)
                if single then
                    start_v = single
                    end_v = single
                end
            end
        end

        if start_v and end_v then
            if val >= start_v and val <= end_v and ((val - start_v) % step == 0) then
                return true
            end
        end
    end
    return false
end

local function compute_next_cron(cron_str, from_time)
    if not cron_str or cron_str == "" then
        return from_time + 60
    end

    local low_cron = string.lower(cron_str)

    -- Shorthand aliases
    if low_cron == "@yearly" or low_cron == "@annually" then low_cron = "0 0 1 1 *"
    elseif low_cron == "@monthly" then low_cron = "0 0 1 * *"
    elseif low_cron == "@weekly" then low_cron = "0 0 * * 0"
    elseif low_cron == "@daily" or low_cron == "@midnight" then low_cron = "0 0 * * *"
    elseif low_cron == "@hourly" then low_cron = "0 * * * *"
    elseif low_cron == "@minutely" then low_cron = "* * * * *"
    end

    -- Interval shorthand: @every <duration> (e.g. @every 15s, @every 5m, @every 1h)
    local every_val, every_unit = string.match(low_cron, "^@every%s+(%d+)([smhd]?)$")
    if every_val then
        local sec = tonumber(every_val)
        if every_unit == "m" then sec = sec * 60
        elseif every_unit == "h" then sec = sec * 3600
        elseif every_unit == "d" then sec = sec * 86400
        end
        return from_time + math.max(sec, 1)
    end

    -- Pure numeric interval (e.g. "30s", "10m", "60")
    local num_val, num_unit = string.match(low_cron, "^(%d+)([smhd]?)$")
    if num_val and num_unit ~= "" then
        local sec = tonumber(num_val)
        if num_unit == "s" then sec = sec
        elseif num_unit == "m" then sec = sec * 60
        elseif num_unit == "h" then sec = sec * 3600
        elseif num_unit == "d" then sec = sec * 86400
        end
        return from_time + math.max(sec, 1)
    end

    -- 5-field cron parsing: min hour dom mon dow
    local fields = {}
    for f in string.gmatch(low_cron, "%S+") do
        table.insert(fields, f)
    end

    if #fields ~= 5 then
        return from_time + 60
    end

    local f_min, f_hour, f_dom, f_mon, f_dow = fields[1], fields[2], fields[3], fields[4], fields[5]

    -- Start looking from next whole minute
    local cur_t = math.floor(from_time / 60) * 60 + 60
    local dt = epoch_to_dt(cur_t)

    for i = 1, 10000 do
        if not match_field(dt.month, f_mon, 1, 12) then
            dt.day = 1
            dt.hour = 0
            dt.min = 0
            dt.month = dt.month + 1
            if dt.month > 12 then
                dt.month = 1
                dt.year = dt.year + 1
            end
            cur_t = dt_to_epoch(dt)
            dt = epoch_to_dt(cur_t)
        elseif (f_dom ~= "*" and not match_field(dt.day, f_dom, 1, 31)) or
               (f_dow ~= "*" and not (match_field(dt.dow, f_dow, 0, 6) or (dt.dow == 0 and match_field(7, f_dow, 0, 7)))) then
            dt.hour = 0
            dt.min = 0
            cur_t = dt_to_epoch(dt) + 86400
            dt = epoch_to_dt(cur_t)
        elseif not match_field(dt.hour, f_hour, 0, 23) then
            dt.min = 0
            cur_t = dt_to_epoch(dt) + 3600
            dt = epoch_to_dt(cur_t)
        elseif not match_field(dt.min, f_min, 0, 59) then
            cur_t = cur_t + 60
            dt = epoch_to_dt(cur_t)
        else
            return cur_t
        end
    end

    return from_time + 60
end

--------------------------------------------------------------------------------
-- ACTION: add
-- ARGV[3]: pulse_id
-- ARGV[4]: cron expression
-- ARGV[5]: target queue
-- ARGV[6]: body
-- ARGV[7]: title (optional)
-- ARGV[8]: initial_next_run (optional, e.g. "0" for compute, or timestamp)
-- ARGV[9]: author (optional)
--------------------------------------------------------------------------------
if action == "add" then
    local pulse_id = string.lower(ARGV[3] or "")
    if pulse_id == "" then
        return redis.error_reply("ERR: Missing pulse id")
    end

    local cron = ARGV[4] or ""
    if cron == "" then
        return redis.error_reply("ERR: Missing cron expression")
    end

    local queue = ARGV[5] or ""
    if queue == "" then
        return redis.error_reply("ERR: Missing queue name")
    end
    queue = string.lower(queue)
    if string.sub(queue, 1, 6) == "queue:" then
        queue = string.sub(queue, 7)
    end

    local body = ARGV[6] or ""
    if body == "" then
        return redis.error_reply("ERR: Missing body")
    end

    local title = ARGV[7] or ""
    if title == "" then
        title = "Pulse: " .. pulse_id
    end

    local pulse_key = prefix .. "pulse:" .. pulse_id
    if redis.call("EXISTS", pulse_key) == 1 then
        return redis.error_reply("ERR: Pulse '" .. pulse_id .. "' already exists")
    end

    local init_run = tonumber(ARGV[8] or 0) or 0
    local next_run
    if init_run > 0 then
        next_run = init_run
    else
        next_run = compute_next_cron(cron, now)
    end

    redis.call("HSET", pulse_key,
        "id", pulse_id,
        "cron", cron,
        "queue", queue,
        "body", body,
        "title", title,
        "created_at", tostring(now),
        "next_run", tostring(next_run),
        "last_run", "0",
        "total_ticks", "0",
        "status", "ACTIVE",
        "lease_owner", "",
        "lease_until", "0",
        "fencing_token", "0"
    )

    redis.call("ZADD", prefix .. "pulses", next_run, pulse_id)

    return cjson.encode({
        status = "OK",
        id = pulse_id,
        cron = cron,
        queue = queue,
        body = body,
        title = title,
        next_run = next_run,
        created_at = now
    })

--------------------------------------------------------------------------------
-- ACTION: list
--------------------------------------------------------------------------------
elseif action == "list" then
    local items = redis.call("ZRANGE", prefix .. "pulses", 0, -1, "WITHSCORES")
    local pulses = {}

    for i = 1, #items, 2 do
        local pulse_id = items[i]
        local score = tonumber(items[i + 1]) or 0
        local pulse_key = prefix .. "pulse:" .. pulse_id
        local meta = redis.call("HGETALL", pulse_key)

        local p = {
            id = pulse_id,
            next_run = score
        }
        for j = 1, #meta, 2 do
            local k = meta[j]
            local v = meta[j + 1]
            if k == "total_ticks" or k == "last_run" or k == "created_at" or k == "fencing_token" or k == "lease_until" then
                p[k] = tonumber(v) or 0
            elseif k == "next_run" then
                p[k] = tonumber(v) or score
            else
                p[k] = v
            end
        end
        table.insert(pulses, p)
    end

    return cjson.encode({
        status = "OK",
        pulses = pulses
    })

--------------------------------------------------------------------------------
-- ACTION: get
-- ARGV[3]: pulse_id
--------------------------------------------------------------------------------
elseif action == "get" then
    local pulse_id = string.lower(ARGV[3] or "")
    if pulse_id == "" then
        return redis.error_reply("ERR: Missing pulse id")
    end

    local pulse_key = prefix .. "pulse:" .. pulse_id
    if redis.call("EXISTS", pulse_key) == 0 then
        return redis.error_reply("ERR: Pulse '" .. pulse_id .. "' not found")
    end

    local score = tonumber(redis.call("ZSCORE", prefix .. "pulses", pulse_id) or 0)
    local meta = redis.call("HGETALL", pulse_key)
    local p = {
        id = pulse_id,
        next_run = score
    }
    for j = 1, #meta, 2 do
        local k = meta[j]
        local v = meta[j + 1]
        if k == "total_ticks" or k == "last_run" or k == "created_at" or k == "fencing_token" or k == "lease_until" then
            p[k] = tonumber(v) or 0
        elseif k == "next_run" then
            p[k] = tonumber(v) or score
        else
            p[k] = v
        end
    end

    return cjson.encode({
        status = "OK",
        pulse = p
    })

--------------------------------------------------------------------------------
-- ACTION: remove
-- ARGV[3]: pulse_id
--------------------------------------------------------------------------------
elseif action == "remove" then
    local pulse_id = string.lower(ARGV[3] or "")
    if pulse_id == "" then
        return redis.error_reply("ERR: Missing pulse id")
    end

    local pulse_key = prefix .. "pulse:" .. pulse_id
    local zrem = redis.call("ZREM", prefix .. "pulses", pulse_id)
    local del = redis.call("DEL", pulse_key)

    if zrem == 0 and del == 0 then
        return redis.error_reply("ERR: Pulse '" .. pulse_id .. "' not found")
    end

    return cjson.encode({
        status = "OK",
        id = pulse_id,
        message = "Pulse removed"
    })

--------------------------------------------------------------------------------
-- ACTION: tick
-- ARGV[3]: max_count (default 50)
-- ARGV[4]: sweeper_id (optional)
-- ARGV[5]: lease_sec (optional, default 60)
-- ARGV[6]: direct_enqueue ("1" or "true" to have Lua enqueue directly)
--------------------------------------------------------------------------------
elseif action == "tick" then
    local max_n = tonumber(ARGV[3] or 50) or 50
    local sweeper = ARGV[4] or "sweeper"
    local lease_sec = tonumber(ARGV[5] or 60) or 60
    local do_enqueue = (ARGV[6] == "1" or ARGV[6] == "true" or ARGV[6] == "enqueue")

    -- Atomically fetch all pulses due at or before 'now'
    local due = redis.call("ZRANGEBYSCORE", prefix .. "pulses", "-inf", now, "LIMIT", 0, max_n)
    if #due == 0 then
        return cjson.encode({
            status = "OK",
            ticked = 0,
            pulses = {},
            now = now
        })
    end

    local ticked_pulses = {}

    for _, pulse_id in ipairs(due) do
        local pulse_key = prefix .. "pulse:" .. pulse_id
        if redis.call("EXISTS", pulse_key) == 0 then
            -- Orphaned entry in ZSET, prune it
            redis.call("ZREM", prefix .. "pulses", pulse_id)
        else
            local meta_raw = redis.call("HMGET", pulse_key, "cron", "queue", "body", "title", "total_ticks", "status", "lease_until")
            local p_cron = meta_raw[1] or "* * * * *"
            local p_queue = meta_raw[2] or "tasks"
            local p_body = meta_raw[3] or ""
            local p_title = meta_raw[4] or ("Pulse: " .. pulse_id)
            local p_ticks = tonumber(meta_raw[5] or 0) or 0
            local p_status = meta_raw[6] or "ACTIVE"

            if p_status == "ACTIVE" then
                -- 1. Monotonic fencing token
                local fencing_token = redis.call("INCR", prefix .. "pulse:fencing")

                -- 2. Advance schedule to next interval strictly in future
                local next_t = compute_next_cron(p_cron, now)
                if next_t <= now then
                    next_t = now + 60
                end

                -- 3. Atomically advance ZSET score so no concurrent worker can re-claim
                redis.call("ZADD", prefix .. "pulses", next_t, pulse_id)

                -- 4. Update pulse metadata
                redis.call("HSET", pulse_key,
                    "last_run", tostring(now),
                    "next_run", tostring(next_t),
                    "total_ticks", tostring(p_ticks + 1),
                    "fencing_token", tostring(fencing_token),
                    "lease_owner", sweeper,
                    "lease_until", tostring(now + lease_sec)
                )

                local p_info = {
                    id = pulse_id,
                    cron = p_cron,
                    queue = p_queue,
                    body = p_body,
                    title = p_title,
                    ticked_at = now,
                    next_run = next_t,
                    total_ticks = p_ticks + 1,
                    fencing_token = fencing_token
                }

                -- 5. Optional direct Lua enqueue for zero-roundtrip scripts/tests
                if do_enqueue then
                    local norm_q = string.lower(p_queue)
                    if string.sub(norm_q, 1, 6) == "queue:" then
                        norm_q = string.sub(norm_q, 7)
                    end
                    local q_key
                    if string.sub(norm_q, 1, 4) == "dlq:" then
                        q_key = prefix .. "queue:dlq:{" .. string.sub(norm_q, 5) .. "}"
                    else
                        q_key = prefix .. "queue:{" .. norm_q .. "}"
                    end
                    local msg_id = "msg_pulse_" .. tostring(fencing_token) .. "_" .. pulse_id
                    local msg_node = {
                        id = msg_id,
                        ["from"] = "system:pulse",
                        to = "queue:" .. norm_q,
                        ["type"] = "pulse",
                        subject = p_title,
                        body = p_body,
                        timestamp = tostring(now),
                        tags = {"pulse", pulse_id},
                        fencing_token = fencing_token,
                        encrypted = false
                    }
                    redis.call("LPUSH", q_key, cjson.encode(msg_node))
                    redis.call("EXPIRE", q_key, 604800)
                end

                table.insert(ticked_pulses, p_info)
            end
        end
    end

    return cjson.encode({
        status = "OK",
        ticked = #ticked_pulses,
        pulses = ticked_pulses,
        now = now
    })

else
    return redis.error_reply("ERR: Unknown pulse action '" .. action .. "'")
end
