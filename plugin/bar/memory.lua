local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.memory
local M = {}

local vm_stat_cache = utilities._cache_path "bar.wezterm-vm_stat"

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

---parse macOS vm_stat output and return used/total in kB plus used_pct.
---matches Activity Monitor "Memory Used" (app memory + wired + compressed),
---which is also what monitoring tools like Stats and btop report: file-backed
---pages are reclaimable cache and count as available, not used. counting
---inactive/cache pages as used makes memory always read near 100% on macOS,
---because macOS keeps very little memory truly free.
---@param s string
---@return number? used
---@return number? total
---@return number? used_pct
M._parse_macos_memory = function(s)
  if type(s) ~= "string" then
    return nil
  end

  local page_size = tonumber(s:match "page size of (%d+) bytes") or 4096

  local function parse_pages(name)
    local raw = s:match(name .. ":%s+([%d,]+)%.?")
    if not raw then
      return 0
    end
    return tonumber((raw:gsub(",", ""))) or 0
  end

  local free = parse_pages "Pages free"
  local wired = parse_pages "Pages wired down"
  local compressor = parse_pages "Pages occupied by compressor"
  local purgeable = parse_pages "Pages purgeable"
  local anonymous = parse_pages "Anonymous pages"
  local file_backed = parse_pages "File%-backed pages"

  local used_pages = math.max(0, anonymous - purgeable) + wired + compressor
  local free_pages = free + file_backed + purgeable
  local total_pages = used_pages + free_pages
  if total_pages <= 0 then
    return nil
  end

  return used_pages * page_size / 1024, total_pages * page_size / 1024, used_pages / total_pages * 100
end

---read current memory usage and return used/total in kB plus used_pct
---@return number? used
---@return number? total
---@return number? used_pct
local function get_memory_usage()
  if utilities.is_linux then
    local f, err = io.open("/proc/meminfo", "r")
    if not f then
      wez.log_error(err)
      return nil
    end
    -- MemTotal is the first line and MemAvailable the third; stop reading
    -- as soon as MemAvailable is seen instead of slurping the whole file
    local lines = {}
    for line in f:lines() do
      lines[#lines + 1] = line
      if line:match "^MemAvailable:" then
        break
      end
    end
    f:close()
    return M._parse_linux_memory(table.concat(lines, "\n"))
  end

  if utilities.is_darwin then
    -- refresh in the background and parse the last completed sample, so
    -- the status bar never blocks on the vm_stat subprocess
    utilities._spawn_to_file("vm_stat", vm_stat_cache)
    local content = utilities._read_file(vm_stat_cache)
    if not content then
      return nil
    end
    return M._parse_macos_memory(content)
  end

  return nil
end

---sample current memory usage percentage
---@return number?
local function sample_memory_pct()
  local _, _, used_pct = get_memory_usage()
  return used_pct
end

---get memory status string
---@param throttle integer
---@param max_width integer
---@return string
M.get_status = utilities._make_histogram_status(sample_memory_pct)

return M
