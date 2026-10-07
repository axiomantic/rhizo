-- scripts/watchdog_inflight.lua
-- Counts in-flight tasks across queues and leases for the namespace prefix.
-- ARGV[1]: prefix (e.g. "locutus:")

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return 0
end

local active_count = 0

-- 1. Scan active leases (tasks currently claimed by workers)
local cursor = "0"
repeat
    local scan_res = redis.call("SCAN", cursor, "MATCH", prefix .. "leases:*", "COUNT", 50)
    cursor = scan_res[1]
    local keys = scan_res[2]
    for _, lk in ipairs(keys) do
        active_count = active_count + redis.call("ZCARD", lk)
    end
until cursor == "0"

-- 2. Scan pending queues (tasks queued waiting for workers to claim)
cursor = "0"
repeat
    local scan_res = redis.call("SCAN", cursor, "MATCH", prefix .. "queue:*", "COUNT", 50)
    cursor = scan_res[1]
    local keys = scan_res[2]
    for _, qk in ipairs(keys) do
        -- Skip dead letter queues (DLQ)
        if not string.find(qk, ":dlq:") then
            active_count = active_count + redis.call("LLEN", qk)
        end
    end
until cursor == "0"

return active_count
