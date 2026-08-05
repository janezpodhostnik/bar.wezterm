local utilities = require "bar.utilities"

---@private
---@class bar.spotify
local M = {}

local last_update = 0
local stored_playback = ""
local cache_path = utilities._cache_path "bar.wezterm-spotify"

---format spotify playback, to handle max_width nicely
---@param pb string
---@param max_width integer
---@return string
local format_playback = function(pb, max_width)
  if #pb <= max_width then
    return pb
  end

  -- split on " - "
  local artist, track = pb:match "^(.-) %- (.+)$"
  if not artist then
    -- no artist/track separator (e.g. podcasts); trim to width
    return pb:sub(1, max_width)
  end

  -- get artist before first ","
  local main_artist = artist:match "([^,]+)" or artist
  local pb_main_artist = main_artist .. " - " .. track
  if #pb_main_artist <= max_width then
    return pb_main_artist
  end

  -- fallback, return track name (trimmed to max width)
  return track:sub(1, max_width)
end

---gets the currently playing song from spotify.
---`spt` is spawned in the background (writing to a cache file) so the
---status bar never blocks on the subprocess or spotify's network latency;
---the rendered value lags one throttle interval behind.
---@param max_width integer
---@param throttle integer
---@return string
M.get_currently_playing = function(max_width, throttle)
  if utilities._wait(throttle, last_update) then
    return stored_playback
  end
  last_update = os.time()

  -- refresh the cache in the background, read the last completed sample
  utilities._spawn_to_file("spt pb --format '%a - %t'", cache_path)
  local pb = utilities._read_file(cache_path)
  if not pb then
    return stored_playback
  end

  stored_playback = format_playback(utilities._trim(pb) or "", max_width)
  return stored_playback
end

return M
