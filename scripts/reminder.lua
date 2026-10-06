-- scripts/reminder.lua
-- Atomic management and smart piggyback/fallback cadence for Rhizo Reminder System
--
-- KEYS: none needed (all keys derived from prefix in ARGV[1])
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: action: "add", "dismiss", "ack", "list", "get", "evaluate_piggyback", "tick_fallback"
-- ARGV[3..]: action-specific parameters

local prefix = ARGV[1]
local action = ARGV[2]

-- Time resolution helper with virtual mock time support
local function get_now()
  local mock_offset = redis.call("GET", prefix .. "mock_time_offset")
  local offset = 0
  if mock_offset and mock_offset ~= false and mock_offset ~= "" then
    offset = tonumber(mock_offset) or 0
  end
  local time_res = redis.call("TIME")
  return tonumber(time_res[1]) + offset
end

local now = get_now()

local priority_map = {
  CRITICAL = 4,
  HIGH = 3,
  NORMAL = 2,
  LOW = 1
}

local function audit_log(event_type, details)
  pcall(function()
    redis.call("XADD", prefix .. "audit_trail", "*",
      "timestamp", tostring(now),
      "event_type", event_type,
      "details", cjson.encode(details)
    )
  end)
end

--------------------------------------------------------------------------------
-- 1. ADD REMINDER
-- ARGV[3]: text
-- ARGV[4]: priority ("CRITICAL", "HIGH", "NORMAL", "LOW")
-- ARGV[5]: author
-- ARGV[6]: scope ("*", "project:<name>", "tag:<tag>")
-- ARGV[7]: target (optional specific agent, "" for none)
-- ARGV[8]: cadence_sec (e.g. 900 for 15m)
-- ARGV[9]: ttl_sec (e.g. 7200 for 2h, 0 for infinite)
-- ARGV[10]: once_per_agent ("true" or "false")
--------------------------------------------------------------------------------
if action == "add" then
  local text = ARGV[3] or ""
  local priority = (ARGV[4] or "NORMAL"):upper()
  if not priority_map[priority] then priority = "NORMAL" end
  local author = ARGV[5] or "operator"
  local scope = ARGV[6] or "*"
  local target = ARGV[7] or ""
  local cadence_sec = tonumber(ARGV[8]) or 900
  local ttl_sec = tonumber(ARGV[9]) or 0
  local once_per_agent = ARGV[10] or "false"

  local seq = redis.call("INCR", prefix .. "reminder:seq")
  local rem_id = "rem-" .. tostring(seq)

  local expires_at = 0
  if ttl_sec > 0 then
    expires_at = now + ttl_sec
  end

  local rem_key = prefix .. "reminder:" .. rem_id
  redis.call("HSET", rem_key,
    "id", rem_id,
    "text", text,
    "priority", priority,
    "author", author,
    "scope", scope,
    "target", target,
    "cadence_sec", tostring(cadence_sec),
    "expires_at", tostring(expires_at),
    "once_per_agent", once_per_agent,
    "created_at", tostring(now)
  )

  if expires_at > 0 then
    -- Expire hash with buffer
    redis.call("EXPIREAT", rem_key, expires_at + 86400)
  end

  -- Score in active set: priority * 10^10 + created_at
  local p_score = priority_map[priority] or 1
  local score = (p_score * 10000000000) + (now % 10000000000)
  redis.call("ZADD", prefix .. "reminders:active", score, rem_id)

  audit_log("REMINDER_ADDED", {
    id = rem_id,
    author = author,
    priority = priority,
    scope = scope,
    cadence_sec = cadence_sec
  })

  return cjson.encode({
    status = "OK",
    id = rem_id,
    text = text,
    priority = priority,
    author = author,
    scope = scope,
    cadence_sec = cadence_sec,
    expires_at = expires_at
  })

--------------------------------------------------------------------------------
-- 2. DISMISS REMINDER
-- ARGV[3]: rem_id
--------------------------------------------------------------------------------
elseif action == "dismiss" then
  local rem_id = ARGV[3]
  local rem_key = prefix .. "reminder:" .. rem_id
  local exists = redis.call("EXISTS", rem_key)
  if exists == 0 then
    return cjson.encode({ status = "ERROR", message = "Reminder not found: " .. rem_id })
  end

  redis.call("ZREM", prefix .. "reminders:active", rem_id)
  redis.call("DEL", rem_key)
  redis.call("DEL", prefix .. "reminder:" .. rem_id .. ":acks")

  audit_log("REMINDER_DISMISSED", { id = rem_id })

  return cjson.encode({ status = "OK", id = rem_id })

--------------------------------------------------------------------------------
-- 3. ACK REMINDER
-- ARGV[3]: rem_id
-- ARGV[4]: agent_name
--------------------------------------------------------------------------------
elseif action == "ack" then
  local rem_id = ARGV[3]
  local agent_name = ARGV[4]
  local rem_key = prefix .. "reminder:" .. rem_id
  local exists = redis.call("EXISTS", rem_key)
  if exists == 0 then
    return cjson.encode({ status = "ERROR", message = "Reminder not found: " .. rem_id })
  end

  redis.call("SADD", prefix .. "reminder:" .. rem_id .. ":acks", agent_name)
  -- Also mark last seen timestamp so we don't immediately re-piggyback
  redis.call("HSET", prefix .. "agent:" .. agent_name .. ":reminder_seen", rem_id, tostring(now))

  audit_log("REMINDER_ACKED", { id = rem_id, agent = agent_name })

  return cjson.encode({ status = "OK", id = rem_id, agent = agent_name })

--------------------------------------------------------------------------------
-- 4. GET REMINDER
-- ARGV[3]: rem_id
--------------------------------------------------------------------------------
elseif action == "get" then
  local rem_id = ARGV[3]
  local rem_key = prefix .. "reminder:" .. rem_id
  local data = redis.call("HGETALL", rem_key)
  if #data == 0 then
    return cjson.encode({ status = "ERROR", message = "Reminder not found: " .. rem_id })
  end

  local rem = {}
  for i = 1, #data, 2 do
    rem[data[i]] = data[i+1]
  end

  local acks = redis.call("SMEMBERS", prefix .. "reminder:" .. rem_id .. ":acks")
  rem.acks = acks

  return cjson.encode(rem)

--------------------------------------------------------------------------------
-- 5. LIST REMINDERS (Non-destructive inspection)
-- ARGV[3]: for_agent (optional agent name to filter / show delivery state)
-- ARGV[4]: scope_filter (optional scope filter)
--------------------------------------------------------------------------------
elseif action == "list" then
  local for_agent = ARGV[3] or ""
  local scope_filter = ARGV[4] or ""

  -- Get active reminders highest priority first (REV)
  local active_ids = redis.call("ZREVRANGE", prefix .. "reminders:active", 0, -1)
  local results = {}

  for _, rem_id in ipairs(active_ids) do
    local rem_key = prefix .. "reminder:" .. rem_id
    local data = redis.call("HGETALL", rem_key)
    if #data > 0 then
      local rem = {}
      for i = 1, #data, 2 do
        rem[data[i]] = data[i+1]
      end

      local expires_at = tonumber(rem.expires_at) or 0
      local is_expired = (expires_at > 0 and now >= expires_at)

      if is_expired then
        -- Automatically clean up expired reminders
        redis.call("ZREM", prefix .. "reminders:active", rem_id)
        redis.call("DEL", rem_key)
        redis.call("DEL", prefix .. "reminder:" .. rem_id .. ":acks")
      else
        local matches = true

        -- Filter by scope if requested
        if scope_filter ~= "" and scope_filter ~= "all" and scope_filter ~= "*" then
          if rem.scope ~= "*" and rem.scope ~= scope_filter then
            matches = false
          end
        end

        -- Filter by specific target agent if set on reminder
        if rem.target and rem.target ~= "" and for_agent ~= "" then
          if rem.target ~= for_agent then
            matches = false
          end
        end

        if matches then
          local acks = redis.call("SMEMBERS", prefix .. "reminder:" .. rem_id .. ":acks")
          rem.acks = acks
          rem.ack_count = #acks

          if for_agent ~= "" then
            local last_seen_val = redis.call("HGET", prefix .. "agent:" .. for_agent .. ":reminder_seen", rem_id)
            local last_seen = tonumber(last_seen_val) or 0
            rem.last_seen_by_target = last_seen
            local cadence_sec = tonumber(rem.cadence_sec) or 900
            local elapsed = (last_seen > 0) and (now - last_seen) or cadence_sec
            rem.due_for_target = (elapsed >= cadence_sec)
            local has_acked = redis.call("SISMEMBER", prefix .. "reminder:" .. rem_id .. ":acks", for_agent) == 1
            rem.acked_by_target = has_acked
          end

          table.insert(results, rem)
        end
      end
    else
      -- Stray ID in active set
      redis.call("ZREM", prefix .. "reminders:active", rem_id)
    end
  end

  return cjson.encode({
    status = "OK",
    reminders = results,
    total = #results
  })

--------------------------------------------------------------------------------
-- 6. EVALUATE PIGGYBACK
-- Evaluates which reminders should be tacked onto an incoming message for agent.
-- Updates last_seen timestamp atomically for selected reminders.
-- ARGV[3]: agent_name
-- ARGV[4]: max_cap (default 2)
--------------------------------------------------------------------------------
elseif action == "evaluate_piggyback" then
  local agent_name = ARGV[3] or ""
  local max_cap = tonumber(ARGV[4]) or 2
  if agent_name == "" then
    return cjson.encode({ reminders = {}, count = 0 })
  end

  local active_ids = redis.call("ZREVRANGE", prefix .. "reminders:active", 0, -1)
  local eligible = {}

  for _, rem_id in ipairs(active_ids) do
    local rem_key = prefix .. "reminder:" .. rem_id
    local data = redis.call("HGETALL", rem_key)
    if #data > 0 then
      local rem = {}
      for i = 1, #data, 2 do
        rem[data[i]] = data[i+1]
      end

      local expires_at = tonumber(rem.expires_at) or 0
      local is_expired = (expires_at > 0 and now >= expires_at)

      if is_expired then
        redis.call("ZREM", prefix .. "reminders:active", rem_id)
        redis.call("DEL", rem_key)
        redis.call("DEL", prefix .. "reminder:" .. rem_id .. ":acks")
      else
        local eligible_for_agent = true

        -- Target check
        if rem.target and rem.target ~= "" and rem.target ~= agent_name then
          eligible_for_agent = false
        end

        -- Once per agent check
        if eligible_for_agent and rem.once_per_agent == "true" then
          local has_acked = redis.call("SISMEMBER", prefix .. "reminder:" .. rem_id .. ":acks", agent_name) == 1
          if has_acked then
            eligible_for_agent = false
          end
        end

        -- Cadence throttle check
        if eligible_for_agent then
          local last_seen_val = redis.call("HGET", prefix .. "agent:" .. agent_name .. ":reminder_seen", rem_id)
          local last_seen = tonumber(last_seen_val) or 0
          local cadence_sec = tonumber(rem.cadence_sec) or 900
          if last_seen > 0 and (now - last_seen) < cadence_sec then
            eligible_for_agent = false
          end
        end

        if eligible_for_agent then
          table.insert(eligible, rem)
        end
      end
    else
      redis.call("ZREM", prefix .. "reminders:active", rem_id)
    end
  end

  -- Take up to max_cap
  local to_display = {}
  for i = 1, math.min(#eligible, max_cap) do
    local rem = eligible[i]
    table.insert(to_display, rem)
    -- Mark impression timestamp
    redis.call("HSET", prefix .. "agent:" .. agent_name .. ":reminder_seen", rem.id, tostring(now))
  end

  return cjson.encode({
    reminders = to_display,
    count = #to_display,
    total_eligible = #eligible,
    overflow = math.max(0, #eligible - #to_display)
  })

--------------------------------------------------------------------------------
-- 7. TICK CANDIDATES (Standalone Broadcast Candidates when Cadence Trips)
-- Finds registered active agents and returns eligible reminders to dispatch
-- if now - last_seen >= cadence_sec.
--------------------------------------------------------------------------------
elseif action == "tick_candidates" or action == "tick_fallback" then
  local active_ids = redis.call("ZREVRANGE", prefix .. "reminders:active", 0, -1)
  if #active_ids == 0 then
    return cjson.encode({ candidates = {}, dispatched = 0 })
  end

  local registered = redis.call("SMEMBERS", prefix .. "active_agents")
  local candidates = {}

  for _, agent_name in ipairs(registered) do
    -- Only dispatch to live agents with active heartbeats
    local is_alive = redis.call("EXISTS", prefix .. "heartbeat:" .. agent_name) == 1
    if is_alive then
      for _, rem_id in ipairs(active_ids) do
        local rem_key = prefix .. "reminder:" .. rem_id
        local data = redis.call("HGETALL", rem_key)
        if #data > 0 then
          local rem = {}
          for i = 1, #data, 2 do
            rem[data[i]] = data[i+1]
          end

          local expires_at = tonumber(rem.expires_at) or 0
          if expires_at == 0 or now < expires_at then
            local eligible = true
            if rem.target and rem.target ~= "" and rem.target ~= agent_name then
              eligible = false
            end
            if eligible and rem.once_per_agent == "true" then
              local has_acked = redis.call("SISMEMBER", prefix .. "reminder:" .. rem_id .. ":acks", agent_name) == 1
              if has_acked then eligible = false end
            end

            if eligible then
              local last_seen_val = redis.call("HGET", prefix .. "agent:" .. agent_name .. ":reminder_seen", rem_id)
              local last_seen = tonumber(last_seen_val) or 0
              local cadence_sec = tonumber(rem.cadence_sec) or 900
              if last_seen == 0 or (now - last_seen) >= cadence_sec then
                table.insert(candidates, {
                  ["to"] = agent_name,
                  rem_id = rem.id,
                  text = rem.text,
                  priority = rem.priority,
                  cadence_sec = cadence_sec
                })
              end
            end
          end
        end
      end
    end
  end

  return cjson.encode({ candidates = candidates, dispatched = #candidates })

else
  return cjson.encode({ status = "ERROR", message = "Unknown action: " .. action })
end
