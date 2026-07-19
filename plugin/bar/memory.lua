local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.memory
local M = {}

local last_update = 0
local cached_text = ""
local history = {}

---parse Linux /proc/meminfo content and return used/total in kB plus used_pct
---@param s string
---@return number? used
---@return number? total
---@return number? used_pct
M._parse_linux_memory = function(s)
  if type(s) ~= "string" then
    return nil
  end

  local total = tonumber(s:match "MemTotal:%s+(%d+)")
  local available = tonumber(s:match "MemAvailable:%s+(%d+)")
  if not total or not available then
    return nil
  end

  local used = total - available
  return used, total, used / total * 100
end

---parse macOS vm_stat output and return used/total in kB plus used_pct
---@param s string
---@return number? used
---@return number? total
---@return number? used_pct
M._parse_macos_memory = function(s)
  if type(s) ~= "string" then
    return nil
  end

  local page_size = 4096
  local header_page_size = s:match "page size of (%d+) bytes"
  if header_page_size then
    page_size = tonumber(header_page_size) or page_size
  end

  local function parse_pages(name)
    local raw = s:match(name .. ":%s+([%d,]+)%.?")
    if not raw then
      return 0
    end
    return tonumber((raw:gsub(",", ""))) or 0
  end

  local free = parse_pages "Pages free"
  local active = parse_pages "Pages active"
  local inactive = parse_pages "Pages inactive"
  local wired = parse_pages "Pages wired down"
  local speculative = parse_pages "Pages speculative"
  local compressor = parse_pages "Pages occupied by compressor"
  local purgeable = parse_pages "Pages purgeable"

  local used_pages = active + inactive + wired + compressor
  local free_pages = free + speculative + purgeable
  local total_pages = used_pages + free_pages
  if total_pages <= 0 then
    return nil
  end

  return used_pages * page_size / 1024, total_pages * page_size / 1024, used_pages / total_pages * 100
end

---read current memory usage percentage
---@return number? used
---@return number? total
---@return number? used_pct
local function get_memory_usage()
  if utilities.is_windows then
    return nil
  end

  local is_linux = wez.target_triple:find "linux" ~= nil
  if is_linux then
    local f, err = io.open("/proc/meminfo", "r")
    if not f then
      wez.log_error(err)
      return nil
    end
    local content = f:read "*a"
    f:close()
    if not content then
      return nil
    end
    return M._parse_linux_memory(content)
  end

  local is_darwin = wez.target_triple:find "darwin" ~= nil
  if is_darwin then
    local success, stdout, stderr = wez.run_child_process { "vm_stat" }
    if not success then
      wez.log_error(stderr)
      return nil
    end
    return M._parse_macos_memory(stdout)
  end

  return nil
end

---get memory status string
---@param throttle integer
---@param max_width integer
---@return string
M.get_status = function(throttle, max_width)
  if utilities._wait(throttle, last_update) then
    return cached_text
  end

  local used, total, used_pct = get_memory_usage()
  if not used or not used_pct then
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
