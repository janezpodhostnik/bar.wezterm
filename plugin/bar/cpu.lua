local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.cpu
local M = {}

local last_update = 0
local cached_text = ""
local history = {}
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

  local line = s:match "^(cpu.-)\n"
  if not line then
    return nil
  end

  local fields = {}
  for n in line:gmatch "%d+" do
    table.insert(fields, tonumber(n))
  end
  if #fields < 4 then
    return nil
  end

  local total = 0
  for _, v in ipairs(fields) do
    total = total + v
  end
  local idle = fields[4] + (fields[5] or 0)
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

---parse macOS iostat -c 2 output and return the used CPU percentage
---@param s string
---@return number?
M._parse_macos_cpu = function(s)
  if type(s) ~= "string" then
    return nil
  end

  local seen_first = false
  for line in s:gmatch "[^\n]+" do
    local fields = {}
    for token in line:gmatch "%S+" do
      table.insert(fields, token)
    end
    if #fields >= 3 and tonumber(fields[1]) and tonumber(fields[2]) and tonumber(fields[3]) then
      if seen_first then
        local idle = tonumber(fields[3])
        if idle then
          return math.min(100, math.max(0, 100 - idle))
        end
      end
      seen_first = true
    end
  end

  return nil
end

---read current CPU usage percentage
---@return number?
local function get_cpu_usage()
  if utilities.is_windows then
    return nil
  end

  local is_linux = wez.target_triple:find "linux" ~= nil
  if is_linux then
    local f, err = io.open("/proc/stat", "r")
    if not f then
      wez.log_error(err)
      return nil
    end
    local content = f:read "*a"
    f:close()
    if not content then
      return nil
    end

    local total, idle = M._parse_linux_cpu(content)
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

  local is_darwin = wez.target_triple:find "darwin" ~= nil
  if is_darwin then
    local success, stdout, stderr = wez.run_child_process { "iostat", "-c", "2" }
    if not success then
      wez.log_error(stderr)
      return nil
    end
    return M._parse_macos_cpu(stdout)
  end

  return nil
end

---get CPU status string
---@param throttle integer
---@param max_width integer
---@return string
M.get_status = function(throttle, max_width)
  if utilities._wait(throttle, last_update) then
    return cached_text
  end

  local used_pct = get_cpu_usage()
  if not used_pct then
    return cached_text
  end

  table.insert(history, used_pct)
  if #history > max_width then
    table.remove(history, 1)
  end

  local bar = utilities._render_histogram(history, max_width)
  local text = string.format("%3d%% %s", math.floor(used_pct + 0.5), bar)

  cached_text = text
  last_update = os.time()
  return cached_text
end

return M
