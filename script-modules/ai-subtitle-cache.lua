-- Local persistent cache for sub-fastwhisper. Never writes into media directories.
local utils = require 'mp.utils'
local M = {}
local windows = package.config:sub(1, 1) == '\\'

-- Two independent modular hashes; identities and payload hashes are verified on reuse.
function M.digest(value)
    local a, b = 5381, 2166136261
    for i = 1, #value do
        local byte = value:byte(i)
        a = (a * 33 + byte) % 4294967296
        b = (b * 131 + byte) % 4294967296
    end
    return string.format('%08x%08x', a, b)
end

function M.read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local data = file:read('*all')
    file:close()
    return data
end

function M.valid_srt(data)
    if type(data) ~= 'string' then return false end
    data = data:gsub('\r\n', '\n'):gsub('^\239\187\191', '')
    local count = 0
    for block in (data .. '\n\n'):gmatch('(.-)\n%s*\n') do
        if block:match('%S') then
            local start, finish, words = block:match(
                '^%s*%d+\n(%d%d:%d%d:%d%d,%d%d%d)%s+%-%->%s+(%d%d:%d%d:%d%d,%d%d%d)[^\n]*\n(.+)$')
            if not start or not words:match('%S') or start >= finish then return false end
            count = count + 1
        end
    end
    return count > 0
end

function M.mkdir(path)
    local info = utils.file_info(path)
    if info then return info.is_dir == true end
    local args
    if windows then
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            "[System.IO.Directory]::CreateDirectory('" .. path:gsub("'", "''") .. "') | Out-Null"}
    else
        args = {'mkdir', '-p', '--', path}
    end
    local res = mp.command_native({name = 'subprocess', args = args,
        playback_only = false, capture_stdout = true, capture_stderr = true})
    info = utils.file_info(path)
    if res and res.status == 0 and info and info.is_dir == true then return true end
    return false, tostring(res and (res.stderr ~= '' and res.stderr or res.error_string) or 'subprocess unavailable')
end

function M.write(path, data)
    local file = io.open(path, 'wb')
    if not file then return false end
    local ok = file:write(data)
    local closed = file:close()
    return ok ~= nil and closed ~= nil
end

function M.entry(root, identity)
    local key = M.digest(identity)
    local dir = utils.join_path(root, key)
    return {key = key, identity = identity, dir = dir,
        srt = utils.join_path(dir, 'subtitles.srt'),
        manifest = utils.join_path(dir, 'complete.json')}
end

function M.lookup(entry)
    local meta = utils.parse_json(M.read(entry.manifest) or '')
    local data = M.read(entry.srt)
    if meta and meta.schema == 1 and meta.identity == entry.identity and
        meta.complete == true and M.valid_srt(data) and meta.payload == M.digest(data) then
        return entry.srt
    end
end

function M.prepare(entry, pid, sequence)
    local work = utils.join_path(entry.dir, 'work-' .. tostring(pid) .. '-' .. tostring(sequence))
    local ok, err = M.mkdir(work)
    if not ok then return nil, 'Cannot create AI subtitle cache directory: ' .. tostring(err) end
    -- A different identity is never allowed to overwrite a hash collision.
    local meta = utils.parse_json(M.read(entry.manifest) or '')
    if meta and meta.identity ~= entry.identity then return nil, 'AI subtitle cache identity collision' end
    return work
end

function M.commit(entry, source)
    local data = M.read(source)
    if not M.valid_srt(data) then return false, 'No valid SRT output' end
    local pending = entry.srt .. '.pending'
    if not M.write(pending, data) then return false, 'Cannot write AI subtitle cache' end
    local meta = utils.format_json({schema = 1, complete = true,
        identity = entry.identity, payload = M.digest(data)})
    if not M.write(entry.manifest .. '.pending', meta .. '\n') then return false, 'Cannot stage cache marker' end
    local old_srt, old_manifest = M.read(entry.srt), M.read(entry.manifest)
    -- Regeneration must preserve the last completed result even if installation fails.
    if old_srt and not M.write(entry.srt .. '.previous', old_srt) then return false, 'Cannot back up completed SRT' end
    if old_manifest and not M.write(entry.manifest .. '.previous', old_manifest) then return false, 'Cannot back up cache marker' end
    local function restore(reason)
        local restored = true
        if old_srt then restored = M.write(entry.srt, old_srt) and restored else os.remove(entry.srt) end
        if old_manifest then restored = M.write(entry.manifest, old_manifest) and restored else os.remove(entry.manifest) end
        return false, reason .. (restored and '' or '; restore failed, .previous backups retained')
    end
    -- The marker is installed last; incomplete/cancelled jobs cannot be reused.
    if old_manifest and not os.remove(entry.manifest) then return false, 'Cannot replace cache marker' end
    if old_srt and not os.remove(entry.srt) then return restore('Cannot replace cached SRT') end
    if not os.rename(pending, entry.srt) then return restore('Cannot finalize cached SRT') end
    if not os.rename(entry.manifest .. '.pending', entry.manifest) then return restore('Cannot finalize cache marker') end
    os.remove(entry.srt .. '.previous'); os.remove(entry.manifest .. '.previous')
    return true
end

return M
