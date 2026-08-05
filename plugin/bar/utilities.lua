local wez = require "wezterm"

---@private
---@class bar.utilities
local H = {}

---@type string
H.home = (os.getenv "USERPROFILE" or os.getenv "HOME" or wez.home_dir or ""):gsub("\\", "/")

---@type boolean
H.is_windows = package.config:sub(1, 1) == "\\"

---@type boolean
H.is_linux = wez.target_triple:find "linux" ~= nil

---@type boolean
H.is_darwin = wez.target_triple:find "darwin" ~= nil

---waits for a specified throttle time before proceeding.
---@param throttle integer
---@param last_update integer
---@return boolean
H._wait = function(throttle, last_update)
  local current_time = os.time()
  return current_time - last_update < throttle
end

---get basename for dir/file, removing ft and path
---@param s string
---@return string?
---@return integer?
H._basename = function(s)
  if type(s) ~= "string" then
    return nil
  end
  local name = s:match "[^/\\]*$" -- match everything after the last / or \
  if name then
    return name:gsub("(.+)%.%w+$", "%1") -- remove extension if present, but preserve leading dots
  end
  return nil
end

---add spaces to each side of a string
---@param s string
---@param space integer
---@param trailing_space integer|nil
---@return string
H._space = function(s, space, trailing_space)
  if type(s) ~= "string" or type(space) ~= "number" then
    return ""
  end
  local spaces = string.rep(" ", space)
  local trailing_spaces = spaces
  if trailing_space ~= nil then
    trailing_spaces = string.rep(" ", trailing_space)
  end
  return spaces .. s .. trailing_spaces
end

---trim string from trailing spaces and newlines
---@param s string
---@return string?
H._trim = function(s)
  return s:match "^%s*(.-)%s*$"
end

---merges two tables
---@param t1 table
---@param t2 table
---@return table
function H._merge(t1, t2)
  for k, v in pairs(t2) do
    if type(v) == "table" then
      if type(t1[k] or false) == "table" then
        H._merge(t1[k] or {}, t2[k] or {})
      else
        t1[k] = v
      end
    else
      t1[k] = v
    end
  end
  return t1
end

---return string with spacing adjusted to prev string
---@param prev string
---@param next string
---@return string
H._constant_width = function(prev, next)
  local spacing = #prev - #next
  local first_half = math.floor(spacing / 2)
  local second_half = math.ceil(spacing / 2)
  return H._space(next, first_half, second_half)
end

---return a writable per-user cache file path for the plugin
---@param name string file name
---@return string
H._cache_path = function(name)
  local dir
  if H.is_windows then
    dir = os.getenv "TEMP" or os.getenv "TMP" or "."
  else
    dir = os.getenv "XDG_RUNTIME_DIR" or "/tmp"
  end
  return dir .. "/" .. name
end

---read an entire file, returning nil if it cannot be opened
---@param path string
---@return string?
H._read_file = function(path)
  if type(path) ~= "string" then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read "*a"
  f:close()
  return content
end

---spawn a shell command in the background, redirecting stdout to a file.
---never blocks the caller; failures are silent (the file simply does not
---update), so callers must tolerate stale or missing data.
---@param command string shell command line (without redirection)
---@param path string output file path
H._spawn_to_file = function(command, path)
  if type(command) ~= "string" or type(path) ~= "string" then
    return
  end
  if H.is_windows then
    wez.background_child_process { "cmd", "/c", command .. ' > "' .. path .. '"' }
  else
    wez.background_child_process { "sh", "-c", command .. " > '" .. path .. "'" }
  end
end

---map a percentage to a vertical Unicode block character
---@param pct number
---@return string
H._block_for_pct = function(pct)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local idx = math.max(1, math.min(#blocks, math.ceil(pct / (100 / #blocks))))
  return blocks[idx]
end

---render a histogram from a history of percentages.
---current is an optional in-progress column appended after the history;
---if the result exceeds width, the oldest columns are dropped.
---@param history number[]
---@param width integer
---@param current number?
---@return string
H._render_histogram = function(history, width, current)
  if type(history) ~= "table" or type(width) ~= "number" then
    return ""
  end

  local values = {}
  for i = math.max(1, #history - width + 1), #history do
    values[#values + 1] = history[i]
  end
  if current then
    values[#values + 1] = current
  end

  local bar = ""
  for i = math.max(1, #values - width + 1), #values do
    bar = bar .. H._block_for_pct(values[i])
  end
  while utf8.len(bar) < width do
    bar = "▁" .. bar
  end
  return bar
end

---create a throttled status getter that renders a histogram of recent samples.
---each column aggregates samples_per_column measurements, keeping the maximum
---so short spikes stay visible. the sampler should return a usage percentage,
---or nil to keep the cached text.
---@param sample fun(): number?
---@return fun(throttle: integer, max_width: integer, samples_per_column: integer?): string
H._make_histogram_status = function(sample)
  local last_update = 0
  local cached_text = ""
  local history = {}
  local pending_max = nil
  local pending_count = 0
  return function(throttle, max_width, samples_per_column)
    if H._wait(throttle, last_update) then
      return cached_text
    end

    local pct = sample()
    if not pct then
      return cached_text
    end

    samples_per_column = samples_per_column or 1
    pending_count = pending_count + 1
    pending_max = math.max(pending_max or pct, pct)
    if pending_count >= samples_per_column then
      table.insert(history, pending_max)
      if #history > max_width then
        table.remove(history, 1)
      end
      pending_max = nil
      pending_count = 0
    end

    cached_text = string.format("%3d%% %s", math.floor(pct + 0.5), H._render_histogram(history, max_width, pending_max))
    last_update = os.time()
    return cached_text
  end
end

return H
