local mp = require 'mp'
local utils = require 'mp.utils'

local options = {base_url = '', mount_path = '~/Videos/OpenList'}
require('mp.options').read_options(options, 'openlist')

local mount = mp.command_native({'expand-path', options.mount_path})
mount = mount and mp.command_native({'normalize-path', mount})
if not mount or not mount:match('^/.') then return end
local mount_prefix = mount:gsub('/+$', '') .. '/'

local function normalize_loopback(url)
    local scheme, rest = url:match('^(https?://)localhost(.*)$')
    if rest and (rest == '' or rest:match('^[:/]')) then
        return scheme .. '127.0.0.1' .. rest
    end
    return url
end

local base_url = normalize_loopback(options.base_url:gsub('/+$', ''))

local function unescape(value)
    return (value:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function is_media_file(path)
    local extension = path:match('%.([^./]+)$')
    if not extension then return false end
    extension = extension:lower()
    for _, kind in ipairs({'video', 'audio'}) do
        for _, supported in ipairs(mp.get_property_native('options/' .. kind .. '-exts', {})) do
            if supported == extension then return true end
        end
    end
    return false
end

local function mounted_file(url)
    if not base_url:match('^https?://[^/?#@]+[^?#]*$') then return end
    local wrapped = url:match('^mpv://(.*)$')
    if wrapped then
        url = wrapped:match('^https?://') and wrapped or unescape(wrapped)
    end
    url = normalize_loopback(url)
    if url:sub(1, #base_url) ~= base_url then return end
    local route, relative = url:sub(#base_url + 1):match('^/(%a+)/([^?#]+)')
    if route ~= 'd' and route ~= 'p' and route ~= 'dav' then return end
    if relative:sub(1, 1) == '/' or relative:sub(-1) == '/' or relative:find('//', 1, true) then return end

    local parts = {}
    for raw_part in relative:gmatch('[^/]+') do
        local part = unescape(raw_part)
        if part == '.' or part == '..' or part:find('[/\\%c]') then return end
        parts[#parts + 1] = part
    end

    local path = mount_prefix .. table.concat(parts, '/')
    if not is_media_file(path) then return end
    local info = utils.file_info(path)
    if info and info.is_file then return path end
end

-- Replace a single browser URL before playback so resume and sidecar files use the mounted path.
mp.add_hook('on_before_start_file', 10, function()
    if mp.get_property_number('playlist-count') ~= 1 then return end
    local url = mp.get_property('playlist/0/filename', '')
    if not url:match('^mpv://') and not url:match('^https?://') then return end
    local path = mounted_file(url)
    if path then mp.commandv('loadfile', path, 'replace') end
end)

mp.add_hook('on_load', 10, function()
    if mp.get_property_number('playlist-count') ~= 1 then return end
    local path = mp.get_property('path')
    if not path or path:find('://', 1, true) then return end
    path = mp.command_native({'normalize-path', path})
    if path and path:sub(1, #mount_prefix) == mount_prefix
        and mp.get_property('options/autocreate-playlist') == 'no' then
        mp.set_property('file-local-options/autocreate-playlist', 'same')
    end
end)
