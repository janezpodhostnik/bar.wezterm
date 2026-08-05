local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.cpu
local M = {}

local iostat_cache = utilities._cache_path "bar.wezterm-iostat"

local prev_total = 0
local prev_idle = 0

---parse Linux /proc/stat first line and return total/idle jiffies
---@param s string
---@return number? total
---@return number? idle
M._parse_linux_cpu = function(s)
  if type(s) ~= "string" then
    return nil
  end

  -- only the aggregate cpu line (first line of /proc/stat); the %s guard
  -- keeps per-core lines (cpu0, cpu1, ...) from matching
  local line = s:match "^(cpu%s[^\n]*)"
  if not line then
    return nil
  end

  local total, idle, count = 0, 0, 0
  for n in line:gmatch "%d+" do
    count = count + 1
    local v = tonumber(n)
    total = total + v
    if count == 4 or count == 5 then -- idle + iowait
      idle = idle + v
    end
  end
  if count < 4 then
    return nil
  end

  return total, idle
end

---compute CPU usage from current and previous total/idle samples
---@param total number
---@param idle number
---@param prev_total number
---@param prev_idle number
---@return number used_pct
M._compute_linux_cpu_pct = function(total, idle, prev_total, prev_idle)
  local total_delta = total - prev_total
  local idle_delta = idle - prev_idle
  if total_delta <= 0 then
    return 0
  end
  local used_pct = (1 - idle_delta / total_delta) * 100
  return math.min(100, math.max(0, used_pct))
end

---parse macOS iostat output and return the used CPU percentage.
---the output may contain disk statistics before the cpu columns, so we locate
---the "id" column in the header and use that index for the data lines.
---the first data line is a since-boot average; the second line is the sample.
---@param s string
---@return number?
M._parse_macos_cpu = function(s)
  if type(s) ~= "string" then
    return nil
  end

  local idle_index = nil
  local seen_first = false
  for line in s:gmatch "[^\n]+" do
    local fields = {}
    for token in line:gmatch "%S+" do
      fields[#fields + 1] = token
    end
    if not idle_index then
      for i, token in ipairs(fields) do
        if token == "id" then
          idle_index = i
          break
        end
      end
    else
      local idle = tonumber(fields[idle_index] or "")
      if idle then
        if seen_first then
          return math.min(100, math.max(0, 100 - idle))
        end
        seen_first = true
      end
    end
  end

  return nil
end

---read current CPU usage percentage
---@return number?
local function get_cpu_usage()
  if utilities.is_linux then
    local f, err = io.open("/proc/stat", "r")
    if not f then
      wez.log_error(err)
      return nil
    end
    -- only the first (aggregate) line is needed
    local line = f:read "*l"
    f:close()
    if not line then
      return nil
    end

    local total, idle = M._parse_linux_cpu(line)
    if not total or not idle then
      return nil
    end

    if prev_total == 0 then
      prev_total = total
      prev_idle = idle
      return nil
    end

    local used_pct = M._compute_linux_cpu_pct(total, idle, prev_total, prev_idle)
    prev_total = total
    prev_idle = idle
    return used_pct
  end

  if utilities.is_darwin then
    -- iostat -c 2 samples for ~1 second; run it in the background and parse
    -- the last completed sample, so the status bar never blocks
    utilities._spawn_to_file("iostat -c 2", iostat_cache)
    local content = utilities._read_file(iostat_cache)
    if not content then
      return nil
    end
    return M._parse_macos_cpu(content)
  end

  return nil
end

---get CPU status string
---@param throttle integer
---@param max_width integer
---@return string
M.get_status = utilities._make_histogram_status(get_cpu_usage)

return M
