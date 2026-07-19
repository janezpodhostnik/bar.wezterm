-- Unit tests for memory and CPU modules.
-- Run with: nix-shell -p lua5_4 --run "lua test-memory-cpu.lua"

-- mock wezterm
package.loaded.wezterm = {
  target_triple = "x86_64-unknown-linux-gnu",
  run_child_process = function()
    return false, "", "not available"
  end,
  log_error = function(err)
    print("  wezterm error:", err)
  end,
  nerdfonts = {},
  home_dir = "/home/test",
}

-- load real utilities first, then override the functions used by modules
local utilities = require "plugin.bar.utilities"
utilities.is_windows = false
utilities._wait = function(throttle, last_update)
  return os.time() - last_update < throttle
end

-- expose utilities so modules use the real helper functions
package.loaded["bar.utilities"] = utilities

local memory = require "plugin.bar.memory"
local cpu = require "plugin.bar.cpu"

local passed = 0
local failed = 0

local function test(name, condition)
  if condition then
    print("  PASS: " .. name)
    passed = passed + 1
  else
    print("  FAIL: " .. name)
    failed = failed + 1
  end
end

print "\nutilities._block_for_pct"
test("0% maps to lowest block", utilities._block_for_pct(0) == "▁")
test("100% maps to full block", utilities._block_for_pct(100) == "█")
test("50% maps to middle block", utilities._block_for_pct(50) == "▄")

print "\nutilities._render_histogram"
test("short history is padded on the left", utf8.len(utilities._render_histogram({ 50 }, 20)) == 20)
test(
  "full history renders exactly width",
  utf8.len(
    utilities._render_histogram(
      { 0, 25, 50, 75, 100, 0, 25, 50, 75, 100, 0, 25, 50, 75, 100, 0, 25, 50, 75, 100, 50 },
      20
    )
  ) == 20
)

print "\nmemory._parse_linux_memory"
local meminfo = [[
MemTotal:       65750932 kB
MemFree:        37262996 kB
MemAvailable:   57086708 kB
Buffers:         3377056 kB
Cached:         15957548 kB
]]
local used, total, pct = memory._parse_linux_memory(meminfo)
test("used is MemTotal - MemAvailable", math.abs(used - (65750932 - 57086708)) < 1)
test("total matches MemTotal", math.abs(total - 65750932) < 1)
test("percentage is reasonable", pct > 0 and pct < 100)

print "\nmemory._parse_macos_memory"
local vmstat = [[
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free: 100000.
Pages active: 200000.
Pages inactive: 30000.
Pages wired down: 50000.
Pages speculative: 10000.
Pages occupied by compressor: 10000.
Pages purgeable: 5000.
]]
local mused, mtotal, mpct = memory._parse_macos_memory(vmstat)
test("macos used pages are active+inactive+wired+compressor", mused == (200000 + 30000 + 50000 + 10000) * 16384 / 1024)
test("macos total is used + free + speculative + purgeable", mtotal == mused + (100000 + 10000 + 5000) * 16384 / 1024)
test("macos percentage is reasonable", mpct > 0 and mpct < 100)

print "\nmemory._parse_macos_memory with commas"
local vmstat_commas = [[
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free: 100,000.
Pages active: 2,000,000.
Pages inactive: 30,000.
Pages wired down: 50,000.
Pages speculative: 10,000.
Pages occupied by compressor: 10,000.
Pages purgeable: 5,000.
]]
local cused, ctotal, cpct = memory._parse_macos_memory(vmstat_commas)
test("comma separators are stripped", cused == (2000000 + 30000 + 50000 + 10000) * 16384 / 1024)
test("comma total is correct", ctotal == cused + (100000 + 10000 + 5000) * 16384 / 1024)

print "\ncpu._parse_linux_cpu"
local stat = [[
cpu  401727 6097 103616 9205915 10503 17569 4216 0 0 0
cpu0 28084 1078 8364 358683 1088 7117 981 0 0 0
]]
local t, idle = cpu._parse_linux_cpu(stat)
test("total aggregates all fields", t == 401727 + 6097 + 103616 + 9205915 + 10503 + 17569 + 4216 + 0 + 0 + 0)
test("idle includes iowait", idle == 9205915 + 10503)

print "\ncpu._compute_linux_cpu_pct"
local pct1 = cpu._compute_linux_cpu_pct(1000, 800, 0, 0)
test("20% used is correct", math.abs(pct1 - 20) < 0.01)
local pct2 = cpu._compute_linux_cpu_pct(1000, 1000, 0, 0)
test("0% used is correct", math.abs(pct2 - 0) < 0.01)
local pct3 = cpu._compute_linux_cpu_pct(1000, 0, 0, 0)
test("100% used is correct", math.abs(pct3 - 100) < 0.01)

print "\ncpu._parse_macos_cpu"
local iostat = [[
          cpu     load average
      us sy id   1m   5m   15m
       3  2 95  1.23 1.45 1.67
       4  3 93  1.25 1.46 1.68
]]
local cpupct = cpu._parse_macos_cpu(iostat)
test("macos cpu uses second sample idle", math.abs(cpupct - 7) < 0.01)

print "\ncpu._parse_macos_cpu with disk stats"
local iostat_disk = [[
              disk0               cpu    load average
    KB/t  tps  MB/s  us sy id   1m   5m   15m
   21.79   16  0.27   5  3 92  1.44 1.83 2.00
   21.79   16  0.27   4  2 94  1.44  1.83  2.00
]]
local cpupct_disk = cpu._parse_macos_cpu(iostat_disk)
test("macos cpu locates idle column when disk stats are present", math.abs(cpupct_disk - 6) < 0.01)

print "\nmemory.get_status / cpu.get_status"
local m1 = memory.get_status(5, 20)
local m2 = memory.get_status(5, 20)
test("memory returns non-empty string", #m1 > 0)
test("memory returns cached value on second call", m1 == m2)
test("memory output is fixed width (25 chars)", utf8.len(m1) == 25)
test("memory output does not include used/total", not m1:find "G")

local c1 = cpu.get_status(5, 20)
test("cpu first Linux call returns empty (baseline)", c1 == "")
-- sleep briefly so a second sample has elapsed
os.execute "sleep 0.1"
local c2 = cpu.get_status(5, 20)
test("cpu second call returns non-empty", #c2 > 0)
test("cpu output is fixed width (25 chars)", utf8.len(c2) == 25)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
