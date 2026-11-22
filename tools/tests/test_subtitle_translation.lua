-- Real API integration. Credentials come from ignored local.conf, never test arguments.
local utils = require 'mp.utils'
local o = {root = '', timeout = 120, target = 'Chinese', custom = false, resume_budget = false, feedback_delay = false}
require('mp.options').read_options(o, 'translation-test')
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local cache = require 'ai-subtitle-cache'
local original = table.concat({
    '1\n00:00:00,000 --> 00:00:02,000\nPlease close the windwo before the rain starts.\n\n',
    '2\n00:00:02,000 --> 00:00:04,000\nThe train will arrive at half past seven tomorrow morning.\n\n',
    '3\n00:00:04,000 --> 00:00:06,000\nAll generated subtitles must stay in the cache folder.\n\n'})
local source = utils.join_path(o.root, 'original.srt')
local phase, translated, content, expected_text, began = 0, nil, nil, nil, mp.get_time()
local selections = {}
local budget_at, budget_resumed
local resumed_requests
local feedback_verified, feedback_started
local budget_stage = 0
local original_font, original_scale = mp.get_property_number('sub-font-size'), mp.get_property_number('sub-scale')
local function translated_text(text)
    if o.target == 'English' then return text:find('[A-Za-z]') end
    return text:find('[\228-\233][\128-\191][\128-\191]')
end
mp.observe_property('sid', 'string', function(_, value)
    selections[#selections + 1] = {sid = value, position = mp.get_property_number('time-pos')}
end)
local function send() mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-translate', source) end
local function check(value, reason) assert(value, reason) end
mp.register_event('file-loaded', function()
    if phase ~= 0 then return end
    if o.custom then original = assert(cache.read(source))
    else check(cache.write(source, original), 'write fixture') end
    phase = 1
    mp.add_timeout(0.5, send)
end)
mp.add_periodic_timer(0.2, function()
    local ok, err = pcall(function()
        check(mp.get_time() - began < o.timeout, 'translation timed out')
        if phase == 1 then
            local status = mp.get_property_native('user-data/ai-subtitles/status/translation', {})
            local feedback = mp.get_property_native('user-data/ai-subtitles/feedback', {})
            if o.feedback_delay and not feedback_started and feedback.phase == 'calibration' and (feedback.elapsed or 0) >= 10 then
                check(feedback.active and feedback.text:find('全文校准') and not feedback.text:find('0/3'), 'persistent calibrated feedback without false progress')
                feedback_started = true
                mp.commandv('screenshot-to-file', utils.join_path(o.root, 'working.png'), 'window')
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-manager')
                mp.add_timeout(0.4, function()
                    local menu = mp.get_property_native('user-data/ai-subtitles/menu', {})
                    local ok = #menu.items == 4 and menu.items[2].title == '取消任务'
                    if not ok then mp.msg.error('TRANSLATION PLAYBACK FAIL: busy menu'); mp.commandv('quit', '3'); return end
                    mp.commandv('screenshot-to-file', utils.join_path(o.root, 'busy-menu.png'), 'window')
                    feedback_verified = true
                    mp.commandv('script-message-to', 'uosc', 'close-menu', 'ai-subtitle-manager')
                end)
            end
            if status.state == 'budget' and o.resume_budget and not budget_resumed then
                if budget_stage == 0 then
                    budget_at, budget_stage = mp.get_time(), 1
                    mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-manager')
                elseif budget_stage == 1 and mp.get_time() - budget_at > 0.5 then
                    if mp.get_property_native('user-data/uosc/menu/type') ~= 'ai-subtitle-manager' then
                        check(mp.get_time() - budget_at < 5, 'budget menu visible'); return
                    end
                    mp.commandv('screenshot-to-file', utils.join_path(o.root, 'budget-menu.png'), 'window')
                    mp.commandv('keypress', 'HOME'); budget_stage, budget_at = 2, mp.get_time()
                elseif budget_stage == 2 and mp.get_time() - budget_at > 0.3 then
                    budget_stage, budget_at = 3, mp.get_time()
                elseif budget_stage == 3 and mp.get_time() - budget_at > 0.3 then
                    budget_resumed = true
                    resumed_requests = status.requests
                    mp.commandv('keypress', 'ENTER')
                    mp.add_timeout(0.3, function() mp.commandv('script-message-to', 'uosc', 'close-menu', 'ai-subtitle-manager') end)
                end
            elseif status.state == 'budget' and o.resume_budget and budget_resumed and resumed_requests ~= status.requests then
                resumed_requests = status.requests
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-translate-resume')
            end
            for _, track in ipairs(mp.get_property_native('track-list', {})) do
                local path = track['external-filename']
                if path and path:sub(-(#o.target + 5)) == '.' .. o.target .. '.ass' then
                    path = path:sub(1, -(#o.target + 6)) .. '.translate.srt'
                end
                if path and path:find('%.translate%.srt$') and cache.read(path .. '.complete') then translated = path end
            end
            if not translated then return end
            content = cache.read(translated)
            local display = assert(cache.read(translated:gsub('%.translate%.srt$', '.' .. o.target .. '.ass')))
            local first, last, words = display:match('Dialogue: 0,([^,]+),([^,]+),Default,,0,0,0,,([^\n]+)')
            check(first and words, 'derived ASS display cue')
            expected_text = words:gsub('{.-}', ''):match('^(.-)\\N') or words:gsub('{.-}', '')
            expected_text = expected_text:gsub('%s+', ' ')
            check(cache.valid_srt(content), 'valid translated SRT')
            check(cache.read(translated .. '.complete') == cache.digest(content), 'completion checksum')
            check(translated_text(content), 'target-language output')
            check(content ~= original, 'response is not unchanged source text')
            check(cache.read(source) == original, 'original subtitle unchanged')
            local calibrated = cache.read(translated:gsub('subtitles%.translate%.srt$', 'subtitles.calibrated.srt'))
            check(cache.valid_srt(calibrated), 'separate calibrated SRT exists')
            if not o.custom then
                check(calibrated:find('window', 1, true) and not calibrated:find('windwo', 1, true), 'clear recognition typo corrected before translation')
            end
            check(not cache.read(source:gsub('%.srt$', '.translate.srt')), 'no source-adjacent translation')
            phase, began = 2, mp.get_time()
            send() -- Repeated action must not append duplicate cues or issue another request.
            local function seconds(value)
                local h, m, s = value:match('(%d+):(%d+):([%d.]+)')
                return h * 3600 + m * 60 + s
            end
            local start, finish = seconds(first), seconds(last)
            mp.commandv('seek', tostring((start + finish) / 2), 'absolute+exact')
        elseif phase == 2 and mp.get_time() - began > 1 then
            check(cache.read(translated) == content, 'repeated action preserves translated file')
            local visible = mp.get_property('sub-text', '')
            if not visible:gsub('%s+', ' '):find(expected_text, 1, true) then
                check(mp.get_time() - began < 10, 'translated subtitle visible')
                return
            end
            mp.commandv('screenshot-to-file', utils.join_path(o.root, 'translated.png'), 'window')
            check(mp.get_property_number('sub-font-size') == original_font and
                mp.get_property_number('sub-scale') == original_scale, 'global subtitle settings unchanged')
            check(cache.write(utils.join_path(o.root, 'result.json'), utils.format_json({
                passed = true, source = source, translated = translated, visible = visible,
                budget_resumed = budget_resumed,
                feedback_verified = feedback_verified,
                translation = mp.get_property_native('user-data/ai-subtitles/status/translation')}) .. '\n'), 'write result')
            phase = 3
            mp.msg.info('TRANSLATION PLAYBACK PASS: target language, timeline, checksum, repeat and unchanged source')
            mp.commandv('quit', '0')
        end
    end)
    if not ok then
        cache.write(utils.join_path(o.root, 'failure.json'), utils.format_json({error = tostring(err),
            position = mp.get_property_number('time-pos'), sid = mp.get_property('sid'),
            text = mp.get_property('sub-text'), track = mp.get_property_native('current-tracks/sub'),
            tracks = mp.get_property_native('track-list'), selections = selections}) .. '\n')
        mp.msg.error('TRANSLATION PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3')
    end
end)
