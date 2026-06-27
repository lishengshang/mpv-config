-- Install [Torrserver](https://github.com/YouROK/TorrServer)
-- then add "script-opts-append=mpv_torrserver-server=http://[TorrServer ip]:[port]" to mpv.conf
local utils = require 'mp.utils'

local opts = {
    server = "http://localhost:8090",
    torrserver_init = false,
    torrserver_path = "TorrServer",
    search_for_external_tracks = true
}

(require 'mp.options').read_options(opts)
local luacurl_available, cURL = pcall(require, 'cURL')

local is_windows = package.config:sub(1, 1) == "\\" -- detect path separator, windows uses backslashes

local function find_executable(name)
    -- If name is already a valid file path, use it directly
    local meta = utils.file_info(name)
    if meta and meta.is_file then
        return name
    end
    local os_path = os.getenv("PATH") or ""
    local sep = is_windows and ";" or ":"
    local fallback_path = utils.join_path("/usr/bin", name)
    local exec_path
    for path in os_path:gmatch("[^" .. sep .. "]+") do
        exec_path = utils.join_path(path, name)
        local meta = utils.file_info(exec_path)
        if meta and meta.is_file then
            return exec_path
        end
    end
    if not is_windows then return fallback_path end
    return name -- fallback to just the name, hoping it's in PATH
end

local function torrserver_running()
    local cmd = mp.command_native {
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {"curl", "-s", "--noproxy", "*", "--max-time", "2", "http://127.0.0.1:8090/"}
    }
    return cmd.status == 0
end

-- Keep a reference to the launched process so Lua GC doesn't abort it.
local _torrserver_proc

local function init()
    -- Skip if TorrServer is already up
    if torrserver_running() then
        mp.msg.info("TorrServer already running")
        return true
    end

    local exec_path = find_executable(opts.torrserver_path)
    mp.msg.info("Starting TorrServer: " .. exec_path)

    if is_windows then
        -- Use synchronous command: powershell runs Start-Process (which
        -- launches TorrServer and returns immediately), then powershell exits.
        -- Synchronous = no GC-abortable async handle, so TorrServer survives.
        local dir = exec_path:match("^(.*)[/\\][^/\\]+$") or ""
        local ps_cmd = "Start-Process -FilePath '" .. exec_path
                       .. "' -WorkingDirectory '" .. dir
                       .. "' -WindowStyle Hidden"
        local res = mp.command_native {
            name = "subprocess",
            capture_stdout = true,
            capture_stderr = true,
            playback_only = false,
            args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps_cmd}
        }
        if res.status ~= 0 then
            mp.msg.error("Failed to launch TorrServer (powershell exit " .. res.status .. "): " .. (res.stderr or ""))
            return false
        end
    else
        _torrserver_proc = mp.command_native_async({
            name = "subprocess",
            capture_stdout = false,
            playback_only = false,
            args = {"/bin/bash", "-c", "nohup '" .. exec_path .. "' >/dev/null 2>&1 &"}
        })
    end

    -- Poll until TorrServer is ready. With --noproxy, connection-refused is
    -- instant, so each failed probe costs only the ~1s ping sleep.
    local max_attempts = 30
    for i = 1, max_attempts do
        if torrserver_running() then
            mp.msg.info("TorrServer is ready (attempt " .. i .. ")")
            return true
        end
        mp.command_native {
            name = "subprocess",
            capture_stdout = true,
            playback_only = false,
            args = is_windows and {"ping", "-n", "2", "127.0.0.1"} or {"sleep", "1"}
        }
    end

    mp.msg.error("TorrServer failed to start within " .. max_attempts .. " attempts")
    return false
end

local char_to_hex = function(c)
  return string.format("%%%02X", string.byte(c))
end

local function urlencode(url)
  if url == nil then
    return
  end
  url = url:gsub("\n", "\r\n")
  url = url:gsub("([^%w ])", char_to_hex)
  url = url:gsub(" ", "+")
  return url
end

local function get_magnet_info(url)
    local info_url = opts.server .. "/stream?stat&link=" .. urlencode(url)
    local res
    if not (luacurl_available) then
        -- if Lua-cURL is not available on this system
        local curl_cmd = {
            "curl",
            "-L",
            "--silent",
            "--max-time", "10",
            info_url
        }
        local cmd = mp.command_native {
            name = "subprocess",
            capture_stdout = true,
            playback_only = false,
            args = curl_cmd
        }
        res = cmd.stdout
    else
        -- otherwise use Lua-cURL (binding to libcurl)
        local buf = {}
        local c = cURL.easy_init()
        c:setopt_followlocation(1)
        c:setopt_url(info_url)
        c:setopt_writefunction(function(chunk)
            table.insert(buf, chunk);
            return true;
        end)
        c:perform()
        res = table.concat(buf)
    end
    if res and res ~= "" then
        return (require 'mp.utils').parse_json(res)
    else
        return nil, "no info response (timeout?)"
    end
end

local function edlencode(url)
    return "%" .. string.len(url) .. "%" .. url
end

local function normalize_torrent_url(url)
    if url == nil then
        return nil
    end

    -- Clipboard/command-based loadfile on Windows can turn magnet URIs into a
    -- pseudo local path like "D:\path\magnet:?xt=...". Extract the real URI so
    -- the hook still recognizes it.
    local magnet_pos = url:find("magnet:%?")
    if magnet_pos ~= nil then
        return url:sub(magnet_pos)
    end

    return url
end

local function guess_type_by_extension(ext)
    if ext == "mkv" or ext == "mp4" or ext == "avi" or ext == "wmv" or ext == "vob" or ext == "m2ts" or ext == "ogm" then
        return "video"
    end
    if ext == "mka" or ext == "mp3" or ext == "aac" or ext == "flac" or ext == "ogg" or ext == "wma" or ext == "mpg"
            or ext == "wav" or ext == "wv" or ext == "opus" or ext == "ac3" then
        return "audio"
    end
    if ext == "ass" or ext == "srt" or ext == "vtt" then
        return "sub"
    end
    return "other";
end

local function string_replace(str, match, replace)
    local s, e = string.find(str, match, 1, true)
    if s == nil or e == nil then
        return str
    end
    return string.sub(str, 1, s - 1) .. replace .. string.sub(str, e + 1)
end

-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst
local function generate_m3u(magnet_uri, files)
    for _, fileinfo in ipairs(files) do
        -- strip top directory
        if fileinfo.path:find("/", 1, true) then
            fileinfo.fullpath = string.sub(fileinfo.path, fileinfo.path:find("/", 1, true) + 1)
        else
            fileinfo.fullpath = fileinfo.path
        end
        fileinfo.path = {}
        for w in fileinfo.fullpath:gmatch("([^/]+)") do table.insert(fileinfo.path, w) end
        local ext = string.match(fileinfo.path[#fileinfo.path], "%.(%w+)$")
        fileinfo.type = guess_type_by_extension(ext)
    end
    table.sort(files, function(a, b)
        -- make top-level files appear first in the playlist
        if (#a.path == 1 or #b.path == 1) and #a.path ~= #b.path then
            return #a.path < #b.path
        end
        -- make videos first
        if (a.type == "video" or b.type == "video") and a.type ~= b.type then
            return a.type == "video"
        end
        -- otherwise sort by path
        return a.fullpath < b.fullpath
    end);

    local infohash = magnet_uri:match("^magnet:%?xt=urn:bt[im]h:(%w+)") or urlencode(magnet_uri)

    local playlist = { '#EXTM3U' }

    for _, fileinfo in ipairs(files) do
        if fileinfo.processed ~= true then
            table.insert(playlist, '#EXTINF:0,' .. fileinfo.fullpath)
            local basename = string.match(fileinfo.path[#fileinfo.path], '^(.+)%.%w+$')

            local url = opts.server .. "/stream/" .. urlencode(fileinfo.fullpath) .."?play&index=" .. fileinfo.id .. "&link=" .. infohash
            local hdr = { "!new_stream", "!no_clip",
                          --"!track_meta,title=" .. edlencode(basename),
                          edlencode(url)
            }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"
            local external_tracks = 0

            fileinfo.processed = true
            if opts.search_for_external_tracks and basename ~= nil and fileinfo.type == "video" then
                mp.msg.info("!" .. basename)

                for _, fileinfo2 in ipairs(files) do
                    if #fileinfo2.path > 0 and
                            fileinfo2.type ~= "other" and
                            fileinfo2.processed ~= true and
                            string.find(fileinfo2.path[#fileinfo2.path], basename, 1, true) ~= nil
                    then
                        mp.msg.info("->" .. fileinfo2.fullpath)
                        local title = string_replace(fileinfo2.fullpath, basename, "%")
                        local url = opts.server .. "/stream/" .. urlencode(fileinfo2.fullpath).."?play&index=" .. fileinfo2.id .. "&link=" .. infohash
                        local hdr = { "!new_stream", "!no_clip", "!no_chapters",
                                      "!delay_open,media_type=" .. fileinfo2.type,
                                      "!track_meta,title=" .. edlencode(title),
                                      edlencode(url)
                        }
                        edl = edl .. table.concat(hdr, ";") .. ";"
                        fileinfo2.processed = true
                        external_tracks = external_tracks + 1
                    end
                end
            end
            if external_tracks == 0 then -- dont use edl
                table.insert(playlist, url)
            else
                table.insert(playlist, edl)
            end
        end
    end
    return table.concat(playlist, '\n')
end

mp.add_hook("on_load", 5, function()
    local url = normalize_torrent_url(mp.get_property("stream-open-filename"))
    if url:find("^magnet:") == 1 or (url:find("^https?://") == 1 and url:find("%.torrent$") ~= nil) then
        mp.set_property_bool("file-local-options/ytdl", false)
        if opts.torrserver_init then
            if not init() then
                return
            end
        end
        local magnet_info, err = get_magnet_info(url)
        if type(magnet_info) == "table" then
            if magnet_info.file_stats then
                -- torrent has multiple files. open as playlist
                mp.set_property("stream-open-filename", "memory://" .. generate_m3u(url, magnet_info.file_stats))
                return
            end
            -- if not a playlist and has a name
            if magnet_info.name then
                mp.set_property("stream-open-filename", "memory://#EXTM3U\n" ..
                        "#EXTINF:0," .. magnet_info.name .. "\n" ..
                        opts.server .. "/stream?play&index=1&link=" .. urlencode(url))
                return
            end
        else
            mp.msg.warn("error: " .. err)
        end
        mp.set_property("stream-open-filename", opts.server .. "/stream?m3u&link=" .. urlencode(url))
    end
end)
