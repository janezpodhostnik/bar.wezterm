# Spec: Memory + CPU modules for bar.wezterm

## Goal

Add two right-status modules to `bar.wezterm`:

- `memory` — used memory percentage, a 20-column histogram of recent usage, and used/total in GiB.
- `cpu` — CPU usage percentage and a 20-column histogram of recent usage.

Both follow `AGENTS.md` conventions, support Linux and macOS, and throttle sampling so the bar stays cheap.

The histogram is a text-based bar chart: each of the 20 columns represents one sample interval, and the column height (via Unicode block characters) represents the relative usage at that interval.

---

## Files

```
plugin/
├── init.lua              # MODIFY: register memory + cpu callbacks; update plugin loading
└── bar/
    ├── config.lua          # MODIFY: add default options
    ├── memory.lua          # CREATE
    ├── cpu.lua             # CREATE
    ├── utilities.lua       # MODIFY: add histogram helpers
    └── test-memory-cpu.lua # CREATE: optional unit tests
```

---

## Data sources

| Module | Linux | macOS | Notes |
|--------|-------|-------|-------|
| **memory** | Read `/proc/meminfo` | Spawn `vm_stat` | Parse page size from the `vm_stat` header. |
| **cpu** | Read `/proc/stat` | Spawn `iostat -c 2` | `iostat -c 2` blocks ~1 s. Use a conservative macOS throttle. |

On Windows, both modules return `""` (unsupported).

### Linux memory

```
used      = MemTotal - MemAvailable
used_pct  = used / MemTotal * 100
```

`/proc/meminfo` values are in kB; convert to GiB for display.

### Linux CPU

Read the aggregate `cpu` line from `/proc/stat`:

```
cpu user nice system idle iowait irq softirq steal guest guest_nice
```

Store the first sample as a baseline and return `""`. On later calls, compute deltas:

```
total_delta = sum(all fields) - previous_total
idle_delta  = (idle + iowait) - previous_idle
used_pct    = clamp((1 - idle_delta / total_delta) * 100, 0, 100)
```

The aggregate `cpu` line gives average utilization across all cores.

### macOS memory

`vm_stat` lines end with a period. Parse the page size from the header, then:

```
used_pages  = active + inactive + wired + compressor - purgeable
free_pages  = free + speculative
total_pages = used_pages + free_pages
used_pct    = used_pages / total_pages * 100
```

### macOS CPU

`iostat -c 2` prints two data lines. The first is cumulative since boot; the second is the 1-second sample. Use the second line, parse the `id` (idle) column, and compute:

```
used_pct = clamp(100 - idle, 0, 100)
```

If `iostat` is unavailable, return `""`.

---

## Histogram

The histogram is a 20-character wide bar chart. Each character is one column; the column height (via vertical Unicode block characters) represents the sampled percentage. Vertical blocks are used because they encode usage by height, matching the usual bar-chart/histogram visual.

### Block mapping (in `utilities.lua`)

Use vertical Unicode block characters to map a percentage to a column height. Add the helper to `plugin/bar/utilities.lua` so both modules share it:

```lua
---map a percentage to a vertical Unicode block character
---@param pct number
---@return string
H._block_for_pct = function(pct)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local idx = math.max(1, math.min(#blocks, math.ceil(pct / (100 / #blocks))))
  return blocks[idx]
end

---render a histogram from a history of percentages
---@param history number[]
---@param width integer
---@return string
H._render_histogram = function(history, width)
  if type(history) ~= "table" or type(width) ~= "number" then
    return ""
  end

  local bar = ""
  local start = math.max(1, #history - width + 1)
  for i = start, #history do
    bar = bar .. H._block_for_pct(history[i])
  end
  while utf8.len(bar) < width do
    bar = "▁" .. bar
  end
  return bar
end
```

`0%` → `▁`, `100%` → `█`.

### History buffer

Each module keeps a history of the last `max_width` sampled percentages (default 20) and renders it with `utilities._render_histogram`. On every successful sample:

1. Append the new percentage to the history.
2. If the history exceeds `max_width`, drop the oldest value.

Render the history left-to-right (oldest on the left, newest on the right). If the history is shorter than `max_width`, pad the left side with `▁`.

### Update cadence

A new sample is added to the histogram only when the throttle interval has elapsed. Therefore, one histogram column corresponds to one `throttle` period. With the default `throttle = 2`, the histogram covers the last 40 seconds.

---

## Module API

Both modules return a table with one function.

```lua
-- plugin/bar/memory.lua
---@param throttle integer seconds between updates
---@param max_width integer histogram width in columns
---@return string
M.get_status = function(throttle, max_width)
  -- e.g. "42% ▁▂▄▅▇█▇▅▄▂▁▁▂▃▄▅ 6.2/15.7G" or ""
end

-- plugin/bar/cpu.lua
---@param throttle integer seconds between updates
---@param max_width integer histogram width in columns
---@return string
M.get_status = function(throttle, max_width)
  -- e.g. "87% ▇▇▇▅▃▂▁▁▂▃▄▅▆▇█" or ""
end
```

Throttle with `utilities._wait(throttle, last_update)` and render the bar with `utilities._render_histogram(history, max_width)`. On failure, log with `wez.log_error` and return the cached value (or `""` on first failure).

### Display format

- **Memory:** `42% ▁▂▄▅▇█▇▅▄▂▁▁▂▃▄▅ 6.2/15.7G`
  - `%.0f%%`
  - histogram (20 columns)
  - `%.1f/%.1fG` (used/total in GiB)
  - If total is unknown, fall back to `42% ▁▂▄▅▇█▇▅▄▂▁▁▂▃▄▅`.
- **CPU:** `87% ▇▇▇▅▃▂▁▁▂▃▄▅▆▇█`
  - `%.0f%%`
  - histogram (20 columns)

---

## Config additions

In `plugin/bar/config.lua`, add under `modules`:

```lua
memory = {
  enabled = false,
  icon = wez.nerdfonts.md_memory,
  color = 3,
  throttle = 2,
  max_width = 20,
},
cpu = {
  enabled = false,
  icon = wez.nerdfonts.md_cpu_64_bit,
  color = 4,
  throttle = 2,
  max_width = 20,
},
```

Use a suitable CPU Nerd Font icon if `md_cpu_64_bit` is unavailable.

---

## Integration in `plugin/init.lua`

The plugin's `init.lua` originally hardcoded the original GitHub URL when building `package.path`. Update it to find the current plugin directory dynamically so forks and `file://` plugins work correctly:

```lua
local separator = package.config:sub(1, 1) == "\\" and "\\" or "/"

---find the plugin directory that contains this plugin's modules.
---@return string
local function get_plugin_path()
  for _, plugin in ipairs(wez.plugin.list()) do
    local memory_path = plugin.plugin_dir .. separator .. "plugin" .. separator .. "bar" .. separator .. "memory.lua"
    local f = io.open(memory_path, "r")
    if f then
      f:close()
      return plugin.plugin_dir
    end
  end

  local first = wez.plugin.list()[1]
  if first then
    return first.plugin_dir
  end

  return ""
end

package.path = package.path
  .. ";"
  .. get_plugin_path()
  .. separator
  .. "plugin"
  .. separator
  .. "?.lua"
```

Then require the modules:

```lua
local memory = require "bar.memory"
local cpu = require "bar.cpu"
```

Add entries to the `callbacks` table in the `update-status` handler, e.g. before `clock`:

```lua
{
  name = "memory",
  func = function()
    return memory.get_status(options.modules.memory.throttle, options.modules.memory.max_width)
  end,
},
{
  name = "cpu",
  func = function()
    return cpu.get_status(options.modules.cpu.throttle, options.modules.cpu.max_width)
  end,
},
```

The existing right-status loop applies colors, separators, and icons automatically.

---

## Platform detection

```lua
local is_windows = utilities.is_windows
local is_darwin = wez.target_triple:find "darwin" ~= nil
local is_linux = wez.target_triple:find "linux" ~= nil
```

---

## Performance notes

- Default throttle is `2` seconds for both modules.
- Linux reads files directly; no subprocesses.
- macOS CPU spawns a subprocess that blocks for ~1 second. macOS users should set `cpu.throttle` to at least `5` (or disable the module).
- The histogram uses a fixed 20-character width; no sparklines or history graphs beyond this.

---

## Testing plan (NixOS)

This machine runs NixOS, so Linux paths are tested directly. macOS paths are verified against saved sample output.

1. **Format check**
   ```sh
   nix-shell -p stylua --run "stylua --check ."
   ```

2. **Unit tests with Lua 5.4** (WezTerm's Lua version)
   The `test-memory-cpu.lua` file in the repo root tests:
   - `utilities._block_for_pct` mapping for `0%`, `50%`, `100%`
   - `utilities._render_histogram` with short and full history, and left padding
   - Linux memory parsing from `/proc/meminfo`
   - Linux CPU parsing from `/proc/stat` (two samples)
   - macOS memory parsing from a saved `vm_stat` sample
   - macOS CPU parsing from a saved `iostat -c 2` sample
   - `memory.get_status` caching and histogram growth
   - `cpu.get_status` baseline behavior on first Linux sample

   The platform-specific parsers are exposed as module-local helpers (e.g. `M._parse_linux_memory`, `M._parse_macos_cpu`) and tested directly. `test-memory-cpu.lua` mocks only `wezterm` and `utilities._wait`; everything else runs the real implementation code.

   ```sh
   nix-shell -p lua5_4 --run "lua test-memory-cpu.lua"
   ```

3. **Live WezTerm test**
   - Load the plugin with `memory.enabled = true` and `cpu.enabled = true`.
   - Confirm the right status shows a percentage and a 20-character bar, e.g. `42% ▁▂▄▅▇█▇▅▄▂▁▁▂▃▄▅ 6.2/15.7G` for memory and `87% ▇▇▇▅▃▂▁▁▂▃▄▅▆▇█` for CPU.
   - Confirm the bar grows from 1 to 20 columns over the first 20 sample intervals, then stays fixed at 20 columns.
   - Set `enabled = false` and confirm the modules disappear.
   - Lower `throttle` to `1` and confirm updates are still limited to once per second (`os.time()` resolution).

4. **macOS verification**
   - On NixOS, `vm_stat` and `iostat` are not available. Validate macOS parsers with sample output in the test file.
   - If a macOS host is available, run the same WezTerm test there and use `cpu.throttle >= 5` to avoid sluggish redraws.
