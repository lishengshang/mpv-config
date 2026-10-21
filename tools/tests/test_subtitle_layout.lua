local utils = require 'mp.utils'
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local layout = require 'ai-subtitle-layout'
local passed = 0
local function check(ok, why) assert(ok, why); passed = passed + 1 end
local function plain(s) return s:gsub('%s', '') end
local function suite()
    local source = ('线性方程组的系数与平面的法向量需要分别检查，两个平面的关系可能是平行、相交或重合。'):rep(5)
    local target = ('The normal vector follows the coefficients. Two planes may be parallel, intersecting, or coincident. '):rep(5)
    local a = '1\n00:00:01,000 --> 00:00:31,000\n' .. source .. '\n\n'
    local b = '1\n00:00:01,000 --> 00:00:31,000\n' .. target .. '\n\n'
    local ass, meta = layout.render(a, b)
    check(ass and meta.primary_size == 56 and meta.secondary_size == 40, 'bilingual fonts are 80 percent')
    local originals, translations, previous = {}, {}, 1
    for _, event in ipairs(meta.events) do
        check(event.lines <= 2, 'at most two display rows')
        check(event.start >= previous - 0.001 and event.finish <= 31 and event.finish > event.start, 'ordered bounded display times')
        check(event.finish - event.start <= 6.001, 'long cues split into short displays')
        check(layout.width(event.source) <= 56 and layout.width(event.translated) <= 56, 'bounded Unicode display width')
        originals[#originals + 1], translations[#translations + 1] = event.source, event.translated
        previous = event.finish
    end
    check(plain(table.concat(originals)) == plain(source), 'Chinese text is never dropped or repeated')
    check(plain(table.concat(translations)) == plain(target), 'English text is never dropped or repeated')
    check(math.abs(previous - 31) < 0.001, 'end of original cue preserved')
    local mono, mono_meta = layout.render(a, nil, {plain_font_size = 50})
    check(mono and mono_meta.primary_size == 60, 'plain size 50 at 720p becomes equivalent 40 at 80 percent')
    check(not layout.render('broken', nil), 'malformed subtitle rejected')
    local literal = layout.render('1\n00:00:00,000 --> 00:00:01,000\n{\\pos(0,0)} 字幕\n\n')
    check(not literal:find('{\\pos', 1, true), 'source text cannot inject ASS position tags')
    local unicode = layout.render('1\n00:00:00,000 --> 00:00:02,000\n中文 English 123 😀\n\n')
    check(unicode:find('😀', 1, true), 'UTF-8 character preserved')
end
mp.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    mp.msg.info(ok and ('SUBTITLE LAYOUT PASS: ' .. passed .. ' assertions') or ('SUBTITLE LAYOUT FAIL: ' .. tostring(err)))
    mp.commandv('quit', ok and 0 or 3)
end)
