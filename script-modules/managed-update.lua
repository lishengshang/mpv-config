-- Exact-byte upstream baselines; unknown local changes are never overwritten.
local M = {}
function M.read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a'); f:close(); return data
end
function M.write(path, data)
    local f = io.open(path, 'wb')
    if not f then return nil end
    local ok = f:write(data); local closed = f:close(); return ok and closed
end
function M.key(value)
    local a, b = 5381, 2166136261
    for i = 1, #value do a = (a * 33 + value:byte(i)) % 4294967296; b = (b * 131 + value:byte(i)) % 4294967296 end
    return string.format('%08x%08x', a, b)
end
function M.classify(current, upstream, baseline)
    if current == upstream then return 'unchanged' end
    if current == nil then return 'create' end
    if baseline ~= nil and current == baseline then return 'update' end
    return 'conflict'
end
function M.apply(plan, backup, save_baseline)
    local ready, seen = {}, {}
    for _, item in ipairs(plan) do
        if item.state ~= 'conflict' then
            local key = item.target:gsub('\\', '/'):lower()
            if seen[key] then return nil, 'Duplicate target: ' .. item.target end
            seen[key] = true
            if M.read(item.target) ~= item.before then return nil, 'Preview is stale: ' .. item.target end
            ready[#ready + 1] = item
        end
    end
    -- Back up and stage every eligible file before mutating any target.
    for i, item in ipairs(ready) do
        item.stage = backup .. '/' .. i .. '.new'
        if not M.write(item.stage, item.data) then return nil, 'Cannot stage update' end
        if item.before ~= nil and not M.write(backup .. '/' .. i .. '.old', item.before) then return nil, 'Cannot back up original' end
    end
    local changed = {}
    local function rollback()
        local errors = {}
        for i = #changed, 1, -1 do
            local item, ok = changed[i]
            if item.before == nil then ok = os.remove(item.target) else ok = M.write(item.target, item.before) end
            if not ok then errors[#errors + 1] = item.target end
        end
        return #errors == 0 and '' or ('; rollback failed: ' .. table.concat(errors, ', '))
    end
    for _, item in ipairs(ready) do
        if M.read(item.target) ~= item.before then return nil, 'Target changed during update: ' .. item.target .. rollback() end
        if item.state ~= 'unchanged' then
            changed[#changed + 1] = item
            if item.before ~= nil and not os.remove(item.target) then return nil, 'Cannot replace: ' .. item.target .. rollback() end
            if not os.rename(item.stage, item.target) then return nil, 'Cannot install: ' .. item.target .. rollback() end
        end
    end
    for _, item in ipairs(ready) do
        if not save_baseline(item) then return nil, 'Files installed; baseline save failed (backup retained)' end
    end
    return #changed
end
return M
