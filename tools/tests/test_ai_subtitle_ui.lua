package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local module = require 'ai-subtitle-ui'
local checks, clock, notices, refreshes, timers, feedback, data = 0, 0, 0, 0, {}, nil, ''
local properties = {}
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local fake = {
    get_time = function() return clock end,
    get_property_native = function(name) return properties[name] end,
    set_property_native = function(_, value) feedback = value end,
    osd_message = function() notices = notices + 1 end,
    create_osd_overlay = function()
        return {update = function(self) data = self.data end, remove = function() data = '' end}
    end,
    add_timeout = function(delay, callback)
        local timer = {callback = callback, at = clock + delay}
        function timer:kill() self.killed = true end
        timers[#timers + 1] = timer
        return timer
    end}
local ui = module.new(fake, function() refreshes = refreshes + 1 end)
local function row(menu, id)
    for _, item in ipairs(menu.items) do if item.id == id then return item end end
end
local function view(overrides)
    local result = {media=true,has_source=false,api=true,backend='Whisper',target='Chinese',auto_translate='foreign',max_requests=20}
    for k, v in pairs(overrides or {}) do result[k] = v end
    ui.update(result)
    return ui.menu('main')
end
local function suite()
    local menu = view({media=false})
    check(#menu.items <= 6 and not row(menu,'generate').selectable, 'compact no-media page explains unavailable action')
    check(not row(menu,'translate').selectable and not row(menu,'export').selectable, 'unavailable translation/export disabled')
    check(not row(menu,'regenerate') and not row(menu,'backend'), 'settings do not crowd main page')
    menu = view({has_source=true,api=false})
    check(row(menu,'generate').title == '加载原文字幕' and row(menu,'generate').hint:find('不调用 API'), 'cached action explicitly free of API')
    check(not row(menu,'translate').selectable, 'missing API configuration explained before activation')
    check(row(menu,'export').selectable and not row(menu,'export').hint, 'ready export never says generation is required')
    menu = view({recognizing=true})
    check(#menu.items == 4 and row(menu,'cancel') and not row(menu,'generate'), 'busy view has one cancel and no duplicate generation')
    check(data:find('本地识别') and feedback.active, 'immediate dedicated overlay and public feedback')
    check(data:find('\\an9', 1, true) and data:find('\\pos(1262.00,85.20)', 1, true),
        'task indicator reserves two native notice lines instead of drawing over the toast')
    properties['osd-dimensions'] = {w=800,h=600}
    properties['user-data/osc/margins'] = {t=0.1}
    ui.redraw()
    check(data:find('\\pos(942.00,139.20)', 1, true), 'task follows aspect ratio and visible title margin')
    properties['osd-margin-y'], properties['osd-font-size'] = 100, 40
    ui.redraw()
    check(data:find('\\pos(942.00,212.00)', 1, true), 'task also reserves enlarged native OSD margins and font')
    properties['user-data/uosc/menu/type'] = 'ai-subtitle-manager'
    ui.redraw()
    check(data == '' and feedback.active, 'menu hides duplicate indicator without hiding task state')
    properties = {}
    ui.redraw()
    clock = 12
    timers[#timers].callback()
    check(data:find('00:12') and not data:find('%%'), 'visible beyond old nine-second toast without invented percentage')
    check(notices == 0 and refreshes >= 4, 'periodic status does not overwrite unrelated OSD notifications')
    local settings = ui.menu('settings')
    check(not row(settings,'backend').selectable and not row(settings,'regenerate').selectable, 'busy settings prevent task replacement')
    menu = view({has_source=true,translation={state='running',stage='calibration',done=0,total=100}})
    check(data:find('全文校准') and not data:find('0/100'), 'whole calibration has stage feedback without false cue progress')
    check(feedback.elapsed == 0, 'elapsed clock restarts at stage transition')
    clock = 17
    menu = view({has_source=true,translation={state='waiting',stage='translation',done=20,total=45}})
    check(data:find('20/45') and data:find('等待'), 'translation exposes actual cue progress and wait state')
    menu = view({has_source=true,translation={state='budget',stage='translation',done=20,total=45}})
    check(data == '' and not feedback.active, 'paused task removes active overlay')
    check(row(menu,'resume') and row(menu,'resume').hint:find('20') and row(menu,'cancel'), 'budget pause offers meaningful continue and one cancel')
    check(not row(menu,'generate'), 'budget pause cannot restart or erase task by accident')
    menu = view({has_source=true,translation={state='failed',stage='calibration',message='HTTP 401'}})
    check(row(menu,'retry') and row(menu,'details'), 'failure has retry and visible details entry')
    check(ui.menu('details').items[4].title == 'HTTP 401', 'failure reason remains accessible after toast')
    menu = view({has_source=true,calibrated=true,translated=true,translation={state='completed',done=45,total=45}})
    check(row(menu,'translate').title == '加载双语字幕' and row(menu,'translate').hint:find('不调用 API'), 'completed view offers safe reload')
    local export = ui.menu('export')
    check(row(export,'original').selectable and row(export,'calibrated').selectable and row(export,'translated').selectable,
        'export distinguishes all three complete artifacts')
    view({has_source=true})
    export = ui.menu('export')
    check(not row(export,'calibrated').selectable and not row(export,'translated').selectable, 'missing artifacts cannot be exported')
    ui.notice('已取消任务，原文保留')
    check(ui.summary():find('已取消') and notices == 1, 'terminal explanation persists in menu after toast')
    view({recognizing=true}); local old_timer = timers[#timers]
    ui.reset()
    check(old_timer.killed and data == '', 'file-switch/reset stops own timer and removes own overlay')
    view({identity='old',has_source=true})
    ui.notice('旧字幕处理完成')
    view({identity='new',has_source=true})
    check(not ui.summary():find('旧字幕'), 'source switch clears stale success message')
    view({recognition_error='识别后端退出码 7'})
    check(ui.summary():find('识别未完成') and ui.menu('details').items[4].title:find('退出码 7'), 'recognition failure has actionable persistent details')
    menu = view()
    check(row(menu,'generate').hint:find('API'), 'generation discloses configured automatic API follow-up')
end
mp.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    mp.msg.info(ok and ('AI SUBTITLE UI PASS: ' .. checks .. ' assertions') or ('AI SUBTITLE UI FAIL: ' .. tostring(err)))
    mp.commandv('quit', ok and 0 or 3)
end)
