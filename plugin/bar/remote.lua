local utilities = require "bar.utilities"
local cpu = require "bar.cpu"
local memory = require "bar.memory"

---@private
---@class bar.remote
local M = {}

---@class remote.context
---@field domain string mux domain name of the pane
---@field host string? ssh destination for stats probes; nil when unsupported
---@field user string? remote username

-- resolved contexts per domain name
local contexts = {}

-- short hostname resolution per host/domain
local short_hosts = {}

-- per-host sampling state and histogram getters
local hosts = {}

-- seconds before an unanswered probe is presumed dead and may be respawned
local IN_FLIGHT_TIMEOUT = 10

---make a value safe for use in a cache file name
---@param s string
---@return string
local function sanitize(s)
  return (s:gsub("[^%w%-_.]", "-"))
end

---single-quote a value for embedding in a shell command
---@param s string
---@return string
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---one ssh round trip collecting both cpu (/proc/stat) and memory
---(/proc/meminfo) data, in the formats cpu/memory already parse
---@param host string
---@return string
local function stats_command(host)
  return "ssh -o BatchMode=yes -o ConnectTimeout=2 "
    .. shell_quote(host)
    .. " 'head -1 /proc/stat; grep -E \"MemTotal|MemAvailable\" /proc/meminfo'"
end

---resolve the mux domain of a pane to a remote context.
---returns nil for the local domain; for ssh domains the context carries the
---ssh destination and username. results are cached per domain name.
---@param pane table
---@param conf table effective wezterm config
---@return remote.context?
M.get_context = function(pane, conf)
  if not pane then
    return nil
  end
  local ok, domain = pcall(pane.get_domain_name, pane)
  if not ok or not domain or domain == "" or domain == "local" then
    return nil
  end
  if contexts[domain] then
    return contexts[domain]
  end

  local ctx = { domain = domain }
  local ssh_domains = conf and conf.ssh_domains or {}
  for _, d in ipairs(ssh_domains) do
    if d.name == domain then
      ctx.host = d.remote_address
      ctx.user = d.username
      break
    end
  end
  -- ad-hoc `wezterm connect some.host` domains are named SSH:some.host
  if not ctx.host then
    ctx.host = domain:match "^SSH:(.+)$"
  end

  contexts[domain] = ctx
  return ctx
end

---short hostname for display. for ssh domains the remote `hostname -s` is
---resolved asynchronously (spawned once, read on later ticks); until the
---answer arrives, or for non-ssh domains, the first DNS label is used.
---@param ctx remote.context
---@return string
M.short_host = function(ctx)
  local key = ctx.host or ctx.domain
  local entry = short_hosts[key]
  if entry and entry.label then
    return entry.label
  end

  local fallback = key:match "^[^.]+" or key
  if not ctx.host then
    short_hosts[key] = { label = fallback }
    return fallback
  end

  entry = entry or { spawned = false }
  short_hosts[key] = entry
  local path = utilities._cache_path("bar.wezterm-hostname-" .. sanitize(key))
  if not entry.spawned then
    entry.spawned = true
    utilities._spawn_to_file(
      "ssh -o BatchMode=yes -o ConnectTimeout=2 " .. shell_quote(ctx.host) .. " hostname -s",
      path
    )
  end
  local content = utilities._read_file(path)
  local name = content and content:match "^%s*(%S*)"
  if name and #name > 0 then
    entry.label = name
    return name
  end
  return fallback
end

---@class remote.host_state
---@field mem_getter fun(throttle: integer, max_width: integer, samples_per_column: integer?): string
---@field cpu_getter fun(throttle: integer, max_width: integer, samples_per_column: integer?): string
---@field seq integer incremented on every successfully parsed probe
---@field mem_seq integer last seq consumed by the memory getter
---@field cpu_seq integer last seq consumed by the cpu getter
---@field mem_pct number?
---@field cpu_pct number?
---@field prev_total number
---@field prev_idle number
---@field last_content string?
---@field last_spawn number
---@field in_flight_since number?

---get or create the per-host sampling state and histogram getters
---@param host string
---@return remote.host_state
local function get_host_state(host)
  local state = hosts[host]
  if state then
    return state
  end

  state = {
    seq = 0,
    mem_seq = 0,
    cpu_seq = 0,
    prev_total = 0,
    prev_idle = 0,
    last_spawn = 0,
  }
  -- each getter consumes a probe result exactly once, so a probe contributes
  -- one measurement to each histogram even though it feeds both
  state.mem_getter = utilities._make_histogram_status(function()
    if state.mem_seq == state.seq then
      return nil
    end
    state.mem_seq = state.seq
    return state.mem_pct
  end)
  state.cpu_getter = utilities._make_histogram_status(function()
    if state.cpu_seq == state.seq then
      return nil
    end
    state.cpu_seq = state.seq
    return state.cpu_pct
  end)
  hosts[host] = state
  return state
end

---refresh remote stats for a host: parse the last completed probe, then
---spawn the next one. at most one probe is ever in flight; an unanswered
---probe is presumed dead after IN_FLIGHT_TIMEOUT seconds. never blocks.
---@param state remote.host_state
---@param host string
---@param throttle integer seconds between probes
local function refresh(state, host, throttle)
  local path = utilities._cache_path("bar.wezterm-remote-" .. sanitize(host))

  -- ignore cache content from before this session's first probe: it may
  -- be stale data left over by a previous run
  if state.last_spawn > 0 then
    local content = utilities._read_file(path)
    if content and content ~= state.last_content then
      local total, idle = cpu._parse_linux_cpu(content)
      local _, _, mem_pct = memory._parse_linux_memory(content)
      -- only a fully parseable payload marks the probe as answered; an empty
      -- or truncated file (spawn just truncated it, ssh still running) does
      -- not. requiring both metrics also means a probe can never feed a
      -- stale duplicate of one metric into its histogram
      if mem_pct and total and idle then
        state.last_content = content
        state.in_flight_since = nil
        state.seq = state.seq + 1
        state.mem_pct = mem_pct
        if state.prev_total > 0 then
          state.cpu_pct = cpu._compute_linux_cpu_pct(total, idle, state.prev_total, state.prev_idle)
        end
        state.prev_total = total
        state.prev_idle = idle
      end
    end
  end

  local now = os.time()
  if state.in_flight_since then
    if now - state.in_flight_since < IN_FLIGHT_TIMEOUT then
      return
    end
    state.in_flight_since = nil
  end
  if now - state.last_spawn < throttle then
    return
  end
  state.last_spawn = now
  state.in_flight_since = now
  utilities._spawn_to_file(stats_command(host), path)
end

---get a remote status string for one metric ("memory" or "cpu"), keeping
---per-host histograms. returns "" when the domain has no ssh target.
---@param ctx remote.context
---@param kind "memory" | "cpu"
---@param throttle integer seconds between ssh probes
---@param max_width integer
---@param samples_per_column integer?
---@return string
M.get_status = function(ctx, kind, throttle, max_width, samples_per_column)
  if not ctx.host then
    return ""
  end
  local state = get_host_state(ctx.host)
  refresh(state, ctx.host, throttle)
  -- getter throttle is 0: probes drive the cadence, the getter only
  -- consumes results as they arrive (sample returns nil otherwise)
  local getter = kind == "cpu" and state.cpu_getter or state.mem_getter
  return getter(0, max_width, samples_per_column)
end

return M
