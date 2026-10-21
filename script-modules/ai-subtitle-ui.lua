-- State-driven uosc pages and an independent, non-modal task indicator.
local M = {}
local function action(id, title, message, enabled, hint, argument)
    local value = {'script-message-to', 'sub_fastwhisper', message}
    if argument then value[#value + 1] = argument end
    return {id = id, title = title, value = value, selectable = enabled ~= false, hint = hint}
end
local function text(title) return {title = title, selectable = false} end
local function elapsed(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60)
end
function M.new(host, refresh)
    local self = {view = {}, message = nil, timer = nil, started = nil, phase = nil}
    local overlay = host.create_osd_overlay('ass-events')
    local function task(view)
        local report = view.translation
        if report and (report.state == 'running' or report.state == 'waiting' or report.state == 'retrying') then
            return report.stage or 'translation'
        end
        if view.recognizing then return 'recognition' end
    end
    function self.summary()
        local view, report = self.view, self.view.translation
        local phase = task(view)
        if phase then
            local title = phase == 'recognition' and '正在本地识别' or
                (phase == 'calibration' and '正在全文校准' or '正在翻译')
            if report and phase ~= 'recognition' then
                if report.state == 'retrying' then title = title .. ' · 接口重试等待中'
                elseif report.state == 'waiting' then title = title .. ' · 等待下一次请求' end
                if phase == 'translation' then title = title .. string.format(' · %d/%d 条', report.done or 0, report.total or 0) end
            end
            return title .. ' · 已用时 ' .. elapsed(host.get_time() - (self.started or host.get_time()))
        end
        if report and report.state == 'budget' then return '已暂停：本次请求额度已用完' end
        if report and report.state == 'failed' then return '校准／翻译未完成，原文已保留' end
        if view.recognition_error then return '本地识别未完成，可重试或查看详情' end
        if self.message then return self.message end
        if report and report.state == 'completed' then return '双语字幕已就绪' end
        if view.has_source then return '已有原文字幕，可加载或翻译' end
        return view.media and '尚未生成字幕' or '请先打开视频'
    end
    function self.notice(message, duration)
        self.message = message
        host.osd_message(message, duration or 5)
    end
    local function draw()
        local active = task(self.view) ~= nil
        local menu = host.get_property_native('user-data/uosc/menu/type')
        local label = active and not menu and ('AI 字幕 · ' .. self.summary()) or ''
        label = label:gsub('\\', '\\e'):gsub('{', '\\{'):gsub('}', '\\}')
        overlay.res_x, overlay.res_y, overlay.z = 1280, 720, 1
        overlay.data = label ~= '' and ('{\\an7\\pos(18,18)\\fs20\\bord1.5\\shad0\\1c&HFFFFFF&\\3c&H000000&}' .. label) or ''
        if overlay.data == '' then overlay:remove() else overlay:update() end
        host.set_property_native('user-data/ai-subtitles/feedback', {active = active, text = self.summary(),
            phase = task(self.view) or 'idle', elapsed = active and math.floor(host.get_time() - self.started) or 0})
    end
    local function tick()
        self.timer = nil
        draw()
        if refresh then refresh() end
        if task(self.view) then self.timer = host.add_timeout(1, tick) end
    end
    self.redraw = draw
    function self.update(view)
        local phase = task(view)
        if self.view.identity ~= nil and view.identity ~= self.view.identity then self.message = nil end
        if phase ~= self.phase then self.started = phase and host.get_time() or nil; self.phase = phase end
        self.view = view
        draw()
        if phase and not self.timer then self.timer = host.add_timeout(1, tick)
        elseif not phase and self.timer then self.timer:kill(); self.timer = nil end
        if refresh then refresh() end
    end
    function self.reset()
        if self.timer then self.timer:kill(); self.timer = nil end
        self.view, self.message, self.started, self.phase = {}, nil, nil, nil
        overlay:remove()
    end
    function self.menu(page)
        page = page or 'main'
        local view, report = self.view, self.view.translation
        local busy = task(view) ~= nil
        local items = {text(self.summary())}
        local function add(...) items[#items + 1] = action(...) end
        local target = view.target == 'Chinese' and '中文' or (view.target == 'English' and '英语' or view.target or '中文')
        if page == 'settings' then
            add('back', '返回 AI 字幕', 'sub-fastwhisper-manager')
            add('backend', '识别方案：' .. (view.backend or 'Whisper') .. '…', 'sub-fastwhisper-backend-menu', not busy,
                busy and '请先取消当前任务' or nil)
            add('auto', '自动翻译：' .. (view.auto_translate == 'foreign' and '日语等语种' or '关闭'),
                'sub-fastwhisper-auto-translate-toggle', true, '中文、英语不自动翻译；仅影响后续任务')
            add('regenerate', '重新生成原文字幕', 'sub-fastwhisper-regenerate', view.media and not busy,
                busy and '请先取消当前任务' or '重新识别，成功前保留旧字幕')
            add('folder', '打开字幕文件夹', 'sub-fastwhisper-open-cache')
            add('details', '任务详情…', 'sub-fastwhisper-details')
        elseif page == 'details' then
            add('back', '返回 AI 字幕', 'sub-fastwhisper-manager')
            items[#items + 1] = text('本地识别：' .. (view.backend or 'Whisper'))
            if report then
                items[#items + 1] = text(report.message or '')
                items[#items + 1] = text(string.format('API 请求：%d 次 · 输入：%d 字符 · %d tokens',
                    report.requests or 0, report.input_chars or 0, report.tokens or 0))
                items[#items + 1] = text('本次请求额度：' .. tostring(report.request_limit or view.max_requests or 20) .. ' 次')
            elseif view.recognition_error then items[#items + 1] = text(view.recognition_error)
            else items[#items + 1] = text('当前没有校准或翻译任务') end
            items[#items + 1] = text('原文保留；tokens 为接口返回用量，不等于账单金额。')
        elseif page == 'export' then
            add('back', '返回 AI 字幕', 'sub-fastwhisper-manager')
            for _, item in ipairs({{'original','原文字幕',view.has_source}, {'calibrated','校准后原文',view.calibrated},
                {'translated',target .. '译文',view.translated}}) do
                add(item[1], '导出' .. item[2] .. '…', 'sub-fastwhisper-export-select', item[3] == true,
                    item[3] and '选择保存位置' or '尚未完成', item[1])
            end
        else
            if report and report.state == 'budget' then
                add('resume', '继续处理', 'sub-fastwhisper-translate-resume', true, '追加 ' .. tostring(view.max_requests or 20) .. ' 次 API 请求额度')
                add('cancel', '取消任务', 'sub-fastwhisper-translation-cancel')
            elseif busy then add('cancel', '取消任务', 'sub-fastwhisper-cancel', true, '已完成字幕会保留')
            else
                if report and report.state == 'failed' then
                    add('retry', '重试校准／翻译', 'sub-fastwhisper-translate-resume', true, '使用 API；已完成部分不会重复请求')
                end
                add('generate', view.has_source and '加载原文字幕' or '生成字幕',
                    view.has_source and 'sub-fastwhisper-load-original' or 'sub-fastwhisper', view.media,
                    view.has_source and '直接加载，不调用 API' or
                        (view.api and view.auto_translate == 'foreign' and '本地识别；其他语种按设置使用 API' or '本地识别'))
                if not (report and report.state == 'failed') then
                    add('translate', view.translated and '加载双语字幕' or ('校准并翻译为' .. target),
                        view.translated and 'sub-fastwhisper-load-bilingual' or 'sub-fastwhisper-translate-resume',
                        view.has_source and (view.translated or view.api), view.translated and '直接加载，不调用 API' or
                        (not view.has_source and '请先生成或选择 SRT 字幕' or (not view.api and '尚未配置翻译服务' or '使用 API')))
                end
                add('export', '导出字幕…', 'sub-fastwhisper-export-menu', view.has_source, not view.has_source and '请先生成字幕' or nil)
            end
            add('details', '任务详情…', 'sub-fastwhisper-details')
            add('settings', '更多设置…', 'sub-fastwhisper-settings')
        end
        return {type = page == 'main' and 'ai-subtitle-manager' or ('ai-subtitle-' .. page),
            title = ({main='AI 字幕',settings='AI 字幕设置',details='AI 字幕任务详情',export='导出字幕'})[page],
            keep_open = true, items = items, footnote = page == 'export' and 'AI 校准稿可能误改，请结合音频核对；原文始终保留。' or
                '校准／翻译会把字幕文本发送到已配置的 API 服务；本地识别不上传音频。'}
    end
    return self
end
return M
