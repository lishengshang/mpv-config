local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local files = {}
local options = {state_dir = '~~state/', export_dir = '~/Videos/mpv-exports'}
require('mp.options').read_options(options, 'local-files')

local function subprocess_args(args)
    return {name = 'subprocess', playback_only = false, args = args,
        capture_stdout = true, capture_stderr = true}
end

function files.run(args, stdin)
    local command = subprocess_args(args)
    command.stdin_data = stdin
    return mp.command_native(command)
end

function files.run_async(args, done)
    return mp.command_native_async(subprocess_args(args), function(success, result, error)
        if not success or not result or result.status ~= 0 then
            msg.warn(result and result.stderr or error or 'subprocess failed')
            done(nil)
        else
            done(result)
        end
    end)
end

function files.path(path)
    if not path or path == '' or path == '-' or path:match('^%a[%w.+-]*://') then return end
    local normalized = mp.command_native({'normalize-path', path})
    if normalized and normalized:sub(1, 1) == '/' then return normalized end
end

function files.context()
    local path = files.path(mp.get_property('path'))
    local pos = mp.get_property_number('playlist-playing-pos', -1)
    local id = mp.get_property_number(('playlist/%d/id'):format(pos))
    if path and id then return {path = path, id = id} end
end

function files.is_current(context)
    local current = files.context()
    return current and current.id == context.id and current.path == context.path
end

function files.track(kind)
    local track = mp.get_property_native('current-tracks/' .. kind)
    if track and track.selected then return track end
end

function files.track_path(context, track)
    if not track.external then return context.path end
    return files.path(track['external-filename'])
end

function files.hash(value)
    local result = files.run({'sha256sum'}, value)
    if result and result.status == 0 then return result.stdout:match('^%x+') end
end

function files.state_path(category)
    return utils.join_path(mp.command_native({'expand-path', options.state_dir}), category)
end

local function make_dir(path)
    local result = files.run({'mkdir', '-p', '-m', '700', '--', path})
    if result and result.status == 0 then return path end
    mp.osd_message('无法创建目录\n' .. path, 4)
end

local function temp_path(parent, directory)
    local args = {'mktemp'}
    if directory then args[#args + 1] = '-d' end
    args[#args + 1] = '--'
    args[#args + 1] = utils.join_path(parent, '.mpv-XXXXXXXX')
    local result = files.run(args)
    if result and result.status == 0 then return (result.stdout:gsub('\n$', '')) end
    mp.osd_message('无法创建临时文件\n' .. parent, 4)
end

function files.write(path, contents)
    local file = io.open(path, 'wb')
    if not file then return false end
    local written = file:write(contents)
    local closed = file:close()
    return written ~= nil and closed ~= nil
end

function files.save_state(path, contents)
    local parent = make_dir(utils.split_path(path))
    if not parent then return false end
    local temp = temp_path(parent, false)
    if not temp then return false end
    if files.write(temp, contents) and os.rename(temp, path) then return true end
    os.remove(temp)
    mp.osd_message('无法保存本机数据\n' .. path, 4)
    return false
end

function files.export_job(category)
    local root = mp.command_native({'expand-path', options.export_dir})
    local output = make_dir(utils.join_path(root, category))
    if not output then return end
    local temp = temp_path(output, true)
    if temp then return {temp = temp, output = output} end
end

function files.publish(job, name, title, extension)
    local stem = (title or 'mpv'):gsub('[/%c\\]', '_')
    if stem == '' or #stem > 160 then stem = 'mpv' end
    stem = stem .. os.date(' - %Y%m%d-%H%M%S')
    local source = utils.join_path(job.temp, name)
    for index = 0, 99 do
        local suffix = index == 0 and '' or ('-%02d'):format(index)
        local target = utils.join_path(job.output, stem .. suffix .. extension)
        -- The job and destination are on the same filesystem. Link only a
        -- complete file, and let the kernel reject duplicate names.
        local result = files.run({'ln', '-T', '--', source, target})
        if result and result.status == 0 then return target end
        if not utils.file_info(target) then break end
    end
    mp.osd_message('无法保存导出文件\n' .. job.output, 4)
end

function files.clean(job)
    for _, name in ipairs(utils.readdir(job.temp, 'files') or {}) do
        os.remove(utils.join_path(job.temp, name))
    end
    files.run({'rmdir', '--', job.temp})
end

function files.menu(kind, title, items)
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json({
        type = kind, title = title, items = items, search_style = 'on_demand',
    }))
end

return files
