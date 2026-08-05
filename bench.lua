-- Performance benchmark harness for bar.wezterm.
-- Run from the repo root with:
--   nix-shell -p lua5_4 --run "lua bench.lua [label] [ticks]"
--
-- Mocks wezterm, loads the real plugin (plugin/init.lua), captures the
-- update-status handler, and invokes it TICKS times, advancing a fake clock
-- by one second per tick (matching wezterm's default status_update_interval).
--
-- Reports per-tick CPU time (mean/p50/p95/p99/max), GC pressure, and counts
-- of expensive operations (file opens, subprocess spawns, wezterm API calls).
-- Ticks in which a blocking run_child_process call happened are reported
-- separately as "blocked ticks" -- these are the user-visible stutters.

local LABEL = arg[1] or "run"
local TICKS = tonumber(arg[2]) or 2000
local SPT_LATENCY_MS = 20 -- simulated spt subprocess latency
local REMOTE = LABEL == "remote" -- simulate a pane in an ssh mux domain

-- simulated remote probe: each spawn advances cpu counters (~10% usage)
local ssh_spawns = 0

-- ---------- counters ----------
local counts = {
  io_open = 0,
  run_child_process = 0,
  background_child_process = 0,
  get_foreground_process_name = 0,
  hostname = 0,
  wez_format = 0,
  set_left_status = 0,
  set_right_status = 0,
}

local function busy_wait(ms)
  local target = os.clock() + ms / 1000
  while os.clock() < target do
  end
end

-- ---------- wezterm mock ----------
local handlers = {}

local ansi = {}
local brights = {}
for i = 1, 16 do
  ansi[i] = "#1111" .. string.format("%02d", i)
  brights[i] = "#9999" .. string.format("%02d", i)
end

package.loaded.wezterm = {
  target_triple = "x86_64-unknown-linux-gnu",
  home_dir = "/home/janezp",
  nerdfonts = setmetatable({}, {
    __index = function()
      return "N"
    end,
  }),
  on = function(event, fn)
    handlers[event] = fn
  end,
  plugin = {
    list = function()
      return { { plugin_dir = "." } }
    end,
  },
  color = {
    get_builtin_schemes = function()
      return { Bench = { ansi = ansi, brights = brights } }
    end,
  },
  time = {
    now = function()
      return {
        format = function(_, fmt)
          return os.date(fmt)
        end,
      }
    end,
  },
  hostname = function()
    counts.hostname = counts.hostname + 1
    return "bench-host"
  end,
  format = function(cells)
    counts.wez_format = counts.wez_format + 1
    local parts = {}
    for _, cell in ipairs(cells) do
      if cell.Text then
        parts[#parts + 1] = cell.Text
      end
    end
    return table.concat(parts)
  end,
  truncate_right = function(s, w)
    return s:sub(1, w)
  end,
  run_child_process = function(_)
    counts.run_child_process = counts.run_child_process + 1
    busy_wait(SPT_LATENCY_MS) -- a real subprocess spawn blocks the handler
    return true, "Bench Artist - Bench Track\n", ""
  end,
  background_child_process = function(argv)
    counts.background_child_process = counts.background_child_process + 1
    -- simulate the background command completing instantly: if the command
    -- line redirects to a file, write fake output there so cache reads work
    local cmdline = argv[#argv]
    if type(cmdline) == "string" then
      local path = cmdline:match "> '([^']+)'" or cmdline:match '> "([^"]+)"'
      if path and cmdline:find "spt" then
        local f = io.open(path, "w")
        if f then
          f:write "Bench Artist - Bench Track\n"
          f:close()
        end
      end
      if path and cmdline:find "ssh" then
        -- simulate the ssh probe answering instantly
        ssh_spawns = ssh_spawns + 1
        local f = io.open(path, "w")
        if f then
          if cmdline:find "hostname" then
            f:write "vesna\n"
          else
            f:write(
              string.format(
                "cpu  %d 0 0 %d 0 0 0 0 0 0\nMemTotal:       1000 kB\nMemAvailable:    500 kB\n",
                10 * ssh_spawns,
                90 * ssh_spawns
              )
            )
          end
          f:close()
        end
      end
    end
  end,
  log_error = function(msg)
    print("  wezterm error:", msg)
  end,
}

-- ---------- load the real plugin ----------
local bar = require "plugin.init"

bar.apply_to_config({ color_scheme = "Bench" }, {
  modules = {
    spotify = { enabled = true },
    memory = { enabled = true },
    cpu = { enabled = true },
    ssh = { enabled = true },
    zoom = { enabled = true },
  },
})

-- ---------- fake window/pane ----------
local palette = {
  ansi = ansi,
  brights = brights,
  tab_bar = {
    background = "#000000",
    active_tab = { fg_color = "#ffffff", bg_color = "#000000" },
    inactive_tab = { fg_color = "#888888", bg_color = "#000000" },
    new_tab = { fg_color = "#888888", bg_color = "#000000" },
  },
}

local fake_window = {
  effective_config = function()
    return {
      resolved_palette = palette,
      tab_max_width = 32,
      color_scheme = "Bench",
      ssh_domains = REMOTE and { { name = "vesna.local", remote_address = "vesna.local", username = "janezp" } } or nil,
    }
  end,
  active_workspace = function()
    return "default"
  end,
  leader_is_active = function()
    return false
  end,
  window_id = function()
    return 1
  end,
  set_left_status = function()
    counts.set_left_status = counts.set_left_status + 1
  end,
  set_right_status = function()
    counts.set_right_status = counts.set_right_status + 1
  end,
}

local fake_pane = {
  get_domain_name = function()
    return REMOTE and "vesna.local" or "local"
  end,
  get_foreground_process_name = function()
    counts.get_foreground_process_name = counts.get_foreground_process_name + 1
    return "/usr/bin/zsh"
  end,
  get_current_working_dir = function()
    -- string (pre-Url-object) form to exercise the decode path; resolves to
    -- this repository so the git-root walk has a real tree to climb
    return "file://bench/home/janezp/Programming/janezpodhostnik/bar.wezterm"
  end,
  tab = function()
    return {
      panes_with_info = function()
        return { { is_active = true, is_zoomed = false } }
      end,
    }
  end,
}

-- ---------- measure ----------
local update = handlers["update-status"]
assert(update, "update-status handler was not registered")

-- fake clock so throttle windows are controllable
local now = 1700000000
local real_os_time = os.time
os.time = function()
  return now
end

-- count io.open calls made by the plugin (git walk, /proc reads, cache reads)
local real_io_open = io.open
io.open = function(...)
  counts.io_open = counts.io_open + 1
  return real_io_open(...)
end

-- warmup: first tick establishes baselines/caches
now = now + 1
update(fake_window, fake_pane)

-- reset counters after warmup
for k in pairs(counts) do
  counts[k] = 0
end
collectgarbage "collect"
local kb_before = collectgarbage "count"

local deltas = {}
local blocked = {}
for i = 1, TICKS do
  now = now + 1
  local spawns_before = counts.run_child_process
  local t0 = os.clock()
  update(fake_window, fake_pane)
  local dt = (os.clock() - t0) * 1000
  deltas[i] = dt
  if counts.run_child_process > spawns_before then
    blocked[#blocked + 1] = dt
  end
end

local kb_after = collectgarbage "count"
io.open = real_io_open
os.time = real_os_time

-- ---------- report ----------
table.sort(deltas)
local function percentile(p)
  return deltas[math.max(1, math.ceil(#deltas * p))]
end
local sum = 0
for _, d in ipairs(deltas) do
  sum = sum + d
end
local blocked_sum = 0
for _, d in ipairs(blocked) do
  blocked_sum = blocked_sum + d
end

local scale = 60 / TICKS -- counts per simulated minute (1 tick = 1s)

print(string.format("# bench results: %s", LABEL))
print(string.format("ticks: %d (simulated seconds, 1 update-status call each)", TICKS))
print ""
print "## per-tick update-status time (ms, CPU)"
print(
  string.format(
    "mean %.4f | p50 %.4f | p95 %.4f | p99 %.4f | max %.4f",
    sum / TICKS,
    percentile(0.50),
    percentile(0.95),
    percentile(0.99),
    deltas[TICKS]
  )
)
print ""
print "## blocked ticks (ticks that spawned a blocking subprocess)"
if #blocked > 0 then
  print(
    string.format(
      "count %d (%.1f%% of ticks) | mean %.2f ms | total %.1f ms",
      #blocked,
      #blocked / TICKS * 100,
      blocked_sum / #blocked,
      blocked_sum
    )
  )
else
  print "none"
end
print ""
print "## GC pressure"
print(
  string.format("lua heap delta: %.1f KB total, %.3f KB/tick", kb_after - kb_before, (kb_after - kb_before) / TICKS)
)
print ""
print "## expensive-op counts (per simulated minute)"
print(string.format("io_open                    %7d  (%6.1f/min)", counts.io_open, counts.io_open * scale))
print(
  string.format(
    "run_child_process          %7d  (%6.1f/min)",
    counts.run_child_process,
    counts.run_child_process * scale
  )
)
print(
  string.format(
    "background_child_process   %7d  (%6.1f/min)",
    counts.background_child_process,
    counts.background_child_process * scale
  )
)
print(
  string.format(
    "get_foreground_process_name %7d  (%6.1f/min)",
    counts.get_foreground_process_name,
    counts.get_foreground_process_name * scale
  )
)
print(string.format("hostname                   %7d  (%6.1f/min)", counts.hostname, counts.hostname * scale))
print(string.format("wez.format                 %7d  (%6.1f/min)", counts.wez_format, counts.wez_format * scale))
print(
  string.format("set_left_status            %7d  (%6.1f/min)", counts.set_left_status, counts.set_left_status * scale)
)
print(
  string.format("set_right_status           %7d  (%6.1f/min)", counts.set_right_status, counts.set_right_status * scale)
)
