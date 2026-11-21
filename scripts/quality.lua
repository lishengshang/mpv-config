local mp = require 'mp'
local msg = require 'mp.msg'

local active = {}

local function apply(profile, mode)
    local ok, err = mp.commandv('apply-profile', profile, mode)
    if not ok then
        msg.error(profile .. ': ' .. (err or 'apply-profile failed'))
        mp.osd_message('画质设置失败：' .. profile)
    end
    return ok
end

local function restore(group)
    local profile = active[group]
    if profile and not apply(profile, 'restore') then return false end
    active[group] = nil
    mp.set_property_native('user-data/quality/selected', active)
    return true
end

local function select(group, profile)
    if not group or not profile then return end
    local selected = active[group] == profile
    if not restore(group) then return end
    if selected then
        mp.osd_message('已关闭：' .. profile)
    elseif apply(profile, 'apply') then
        active[group] = profile
        mp.set_property_native('user-data/quality/selected', active)
        mp.osd_message('画质：' .. profile)
    end
end

mp.register_script_message('select', select)

mp.register_script_message('toggle-deband', function()
    select('deband', active.deband or 'DeBand-low')
end)

mp.register_script_message('restore', function(group)
    if group and restore(group) then
        mp.osd_message('已恢复着色器设置')
    end
end)

mp.register_script_message('restore-all', function()
    local restored = true
    for group in pairs(active) do
        if not restore(group) then restored = false end
    end
    if restored then mp.osd_message('已恢复原画质设置') end
end)
