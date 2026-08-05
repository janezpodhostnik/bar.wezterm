local utilities = require "bar.utilities"

---@private
---@class bar.paths
local M = {}

-- rendered cwd per raw cwd uri; the git-root walk only runs when the cwd
-- actually changes, not on every status tick
local cwd_cache = {}

---Finds the git directory starting from the given directory and moving up the directory tree.
---@param directory string
---@return string|nil
local find_git_dir = function(directory)
  directory = directory:gsub("^~", utilities.home)

  while directory do
    local handle = io.open(directory .. "/.git/HEAD", "r")
    if handle then
      handle:close()
      directory = directory:match "([^/]+)$" or ""
      return directory
    elseif directory == "/" or directory == "" then
      break
    else
      directory = directory:match "(.+)/[^/]*" or ""
    end
  end

  return nil
end

---gets the current working directory of the given pane.
---@param pane table
---@param search_git_root_instead boolean
---@return string
M.get_cwd = function(pane, search_git_root_instead)
  local cwd = ""
  local cwd_uri = pane:get_current_working_dir()
  if not cwd_uri then
    return cwd
  end

  -- cache key: the uri itself (string form on older wezterm) or the
  -- decoded file path (Url object on newer wezterm)
  local cache_key
  if type(cwd_uri) == "userdata" then
    ---@diagnostic disable-next-line: undefined-field
    cache_key = cwd_uri.file_path
  else
    cache_key = cwd_uri
  end
  cache_key = tostring(cache_key) .. "|" .. tostring(search_git_root_instead)

  local cached = cwd_cache[cache_key]
  if cached then
    return cached
  end

  if type(cwd_uri) == "userdata" then
    -- Running on a newer version of wezterm and we have
    -- a URL object here, making this simple!

    ---@diagnostic disable-next-line: undefined-field
    cwd = cwd_uri.file_path
  else
    -- an older version of wezterm, 20230712-072601-f4abf8fd or earlier,
    -- which doesn't have the Url object
    cwd_uri = cwd_uri:sub(8)
    local slash = cwd_uri:find "/"
    if slash then
      -- and extract the cwd from the uri, decoding %-encoding
      cwd = cwd_uri:sub(slash):gsub("%%(%x%x)", function(hex)
        local hex_num = tonumber(hex, 16)
        if not hex_num then
          return "-"
        end
        return string.char(hex_num)
      end)
    end
  end

  if utilities.is_windows then
    cwd = cwd:gsub("/" .. utilities.home .. "(.-)$", "~%1")
  else
    cwd = cwd:gsub(utilities.home .. "(.-)$", "~%1")
  end

  ---search for the git root of the project if specified
  if search_git_root_instead then
    local git_root = find_git_dir(cwd)
    cwd = git_root or cwd ---fallback to cwd
  end

  cwd_cache[cache_key] = cwd
  return cwd
end

return M
