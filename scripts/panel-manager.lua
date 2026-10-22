-- Local coordination of interactive panels. Keep upstream renderers and key maps.
local mp = require 'mp'
local utils = require 'mp.utils'
local o = {stats_duration = 4}
require('mp.options').read_options(o, 'panel-manager')

local panels = {
    files = {prop = 'user-data/file_browser/open', stamp = 'user-data/file_browser/opened-at',
        close = {'script-message-to', 'file_browser', 'close-browser'},
        open = {'script-message-to', 'file_browser', 'browse-files'}},
    history = {prop = 'user-data/simplehistory/menu-open', stamp = 'user-data/simplehistory/opened-at',
        close = {'script-message-to', 'simplehistory', 'close-list'},
        open = {'script-message-to', 'simplehistory', 'open-list'}},
    bookmarks = {prop = 'user-data/simplebookmark/menu-open', stamp = 'user-data/simplebookmark/opened-at',
        close = {'script-message-to', 'simplebookmark', 'close-list'},
        open = {'script-message-to', 'simplebookmark', 'open-list'}},
    menu = {prop = 'user-data/uosc/menu/type', stamp = 'user-data/uosc/menu/opened-at',
        close = {'script-message-to', 'uosc', 'close-menu'}},
    console = {prop = 'user-data/mpv/console/open',
        close = {'script-message-to', 'console', 'disable'},
        open = {'script-binding', 'commands/open'}},
}
local pending, stats_mode, closing_stats, last_stats = nil, nil, false, false
local opening_stats, hide_requested = false, false
local closed = {}
local settle, transient
local published

local function is_open(panel)
    local value = mp.get_property_native(panel.prop)
    return value ~= nil and value ~= false and value ~= '' and value ~= 'no'
end
local function any_panel()
    for _, panel in pairs(panels) do if is_open(panel) then return true end end
    return false
end
local function stats_visible()
    for _, binding in ipairs(mp.get_property_native('input-bindings', {})) do
        if binding.owner == 'stats' and binding.cmd and binding.cmd:find('stats/__forced_', 1, true) then
            return true
        end
    end
    return false
end
local function stats_search()
    -- Stats page 4 uses console as its own search box, not a separate panel.
    -- Its opened callback removes page/exit keys and keeps only scroll keys.
    local scroll, exit = false, false
    for _, binding in ipairs(mp.get_property_native('input-bindings', {})) do
        if binding.owner == 'stats' then
            local key = (binding.key or ''):upper()
            if key == 'ESC' then exit = true end
            if key == 'UP' then scroll = true end
        end
    end
    return scroll and not exit
end
local function publish()
    local open = {}
    for id, panel in pairs(panels) do if is_open(panel) then open[#open + 1] = id end end
    table.sort(open)
    local state = {
        panels = open, stats = stats_visible(), stats_mode = stats_mode or 'off',
        pending = pending and pending.kind or '',
    }
    local json = utils.format_json(state)
    if json ~= published then
        published = json
        mp.set_property_native('user-data/panel-manager/state', state)
    end
end
local function hide_stats()
    hide_requested = true
    if stats_visible() and not closing_stats then
        closing_stats = true
        mp.commandv('script-binding', 'stats/display-stats-toggle')
    end
end
local function suspend_stats()
    transient:kill()
    if stats_mode == 'oneshot' then stats_mode = nil end
    hide_stats()
end
local function close_others(keep)
    for id, panel in pairs(panels) do
        if id ~= keep and is_open(panel) and not closed[id] then
            closed[id] = panel.stamp and mp.get_property_native(panel.stamp) or true
            mp.command_native(panel.close)
        end
    end
end
local function focused_panel(fallback)
    local owners = {file_browser = 'files', simplehistory = 'history',
        simplebookmark = 'bookmarks', uosc = 'menu', console = 'console'}
    local winner, priority = fallback, -math.huge
    local all_stamped, latest = true, -math.huge
    for id, panel in pairs(panels) do
        if closed[id] and panel.stamp and closed[id] ~= mp.get_property_native(panel.stamp) then closed[id] = nil end
        if not closed[id] and is_open(panel) then
            if not panel.stamp then all_stamped = false
            else
                local stamp = mp.get_property_number(panel.stamp, -math.huge)
                if stamp > latest then winner, latest = id, stamp end
            end
        end
    end
    if all_stamped then return winner end
    -- State notifications can be delivered together after several panels open.
    -- Native input priority identifies the panel that actually owns Enter now.
    for _, binding in ipairs(mp.get_property_native('input-bindings', {})) do
        local id = owners[binding.owner]
        if id and not closed[id] and is_open(panels[id]) and (binding.key or ''):upper() == 'ENTER'
            and binding.priority > priority then
            winner, priority = id, binding.priority
        end
    end
    return winner
end
local function show_stats(mode)
    stats_mode = mode
    hide_requested = false
    if not stats_visible() and not opening_stats then
        opening_stats = true
        mp.commandv('script-binding', 'stats/display-stats-toggle')
    end
    transient:kill()
    if mode == 'oneshot' then transient:resume() end
    settle:resume()
end
transient = mp.add_timeout(o.stats_duration, function()
    stats_mode = nil
    hide_stats()
    publish()
end)
transient:kill()

-- Wait for close acknowledgements (including uosc's fadeout) before opening.
settle = mp.add_periodic_timer(0.05, function()
    -- input-bindings is queryable but does not notify observers on this mpv.
    local visible = stats_visible()
    if visible then opening_stats = false end
    if last_stats and not visible and not closing_stats then stats_mode = nil; transient:kill() end
    if not visible then closing_stats = false end
    last_stats = visible
    if hide_requested and visible then hide_stats() end
    if not visible and not opening_stats then hide_requested = false end
    if pending then
        if pending.opening then
            if (pending.kind == 'stats' and visible) or
                (panels[pending.kind] and is_open(panels[pending.kind])) then pending = nil end
        elseif not any_panel() and not visible and not opening_stats then
            local request = pending
            request.opening = true
            if request.kind == 'stats' then
                show_stats(request.mode)
            elseif request.kind == 'menu' then
                mp.commandv('script-message-to', 'menu_ui', 'open-coordinated', request.mode or 'main', request.submenu or '')
            else
                mp.command_native(panels[request.kind].open)
                if request.kind == 'files' then mp.commandv('script-message-to', 'file_browser', 'dynamic/reload') end
            end
        end
        if pending and mp.get_time() > pending.deadline then
            mp.msg.warn('Panel switch cancelled: missing open/close acknowledgement')
            pending = nil
        end
    elseif any_panel() and not opening_stats and not closing_stats then settle:kill()
    elseif not closing_stats then
        if stats_mode == 'persistent' and not visible then show_stats('persistent')
        elseif not visible and not opening_stats then settle:kill() end
    end
    publish()
end)
settle:kill()

mp.register_script_message('open', function(kind, mode, submenu)
    local panel = panels[kind]
    if not panel then return end
    if is_open(panel) and not pending then
        -- Keep the renderer's own repeat-key/toggle behavior.
        if kind == 'menu' then
            mp.commandv('script-message-to', 'menu_ui', 'open-coordinated', mode or 'main', submenu or '')
        else mp.command_native(panel.open) end
        return
    end
    pending = {kind = kind, mode = mode, submenu = submenu, deadline = mp.get_time() + 2}
    suspend_stats()
    close_others()
    settle:resume()
    publish()
end)
mp.register_script_message('stats', function(mode)
    if mode == 'toggle' and stats_mode == 'persistent' then
        stats_mode = nil
        if pending and pending.kind == 'stats' then pending = nil end
        hide_stats()
    else
        local wanted = mode == 'toggle' and 'persistent' or 'oneshot'
        if stats_mode == 'persistent' and mode ~= 'toggle' then return end
        stats_mode = wanted
        transient:kill()
        if stats_visible() and not any_panel() and not pending then show_stats(wanted)
        else
            pending = {kind = 'stats', mode = wanted, deadline = mp.get_time() + 2}
            close_others()
            settle:resume()
        end
    end
    publish()
end)

for id, panel in pairs(panels) do
    mp.observe_property(panel.prop, 'native', function()
        local function changed()
            if closed[id] and panel.stamp and closed[id] ~= mp.get_property_native(panel.stamp) then closed[id] = nil end
            if is_open(panel) then
                -- Also cover menus opened by mouse buttons or other scripts.
                if not closed[id] then
                    local winner = focused_panel(id)
                    if winner ~= 'console' or not stats_search() then suspend_stats() end
                    close_others(winner)
                end
            else closed[id] = nil end
            settle:resume()
            publish()
        end
        -- mp.input acknowledges opening before stats installs its search keys.
        if id == 'console' and is_open(panel) then mp.add_timeout(0.05, changed)
        else changed() end
    end)
end
