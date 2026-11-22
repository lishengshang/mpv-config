-- Derived display only: never rewrite recognition text or translation timestamps.
local M = {}
local function trim(text) return text:match('^%s*(.-)%s*$') end
local function chars(text)
    local result = {}
    for c in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do result[#result + 1] = c end
    return result
end
local function width(text)
    local n = 0
    for _, c in ipairs(chars(text)) do n = n + (#c > 1 and 2 or 1) end
    return n
end
local function boundary(c)
    return c:match('[%s%.,!?:;]') or c == '。' or c == '，' or c == '！' or c == '？' or c == '；'
end
local function split(text, maximum)
    local units, parts, first = chars(trim(text:gsub('[\r\n]+', ' '))), {}, 1
    while first <= #units do
        local finish, used, preferred = first - 1, 0, nil
        while finish < #units do
            local c = units[finish + 1]
            local size = #c > 1 and 2 or 1
            if used + size > maximum then break end
            finish, used = finish + 1, used + size
            if boundary(c) and used >= maximum / 2 then preferred = finish end
        end
        finish = math.max(first, finish)
        if finish < #units and preferred then finish = preferred end
        parts[#parts + 1] = trim(table.concat(units, '', first, finish))
        first = finish + 1
        while units[first] and units[first]:match('%s') do first = first + 1 end
    end
    return #parts > 0 and parts or {''}
end
local function expand(parts, count)
    while #parts < count do
        local longest, length = nil, 1
        for i, text in ipairs(parts) do
            if width(text) > length then longest, length = i, width(text) end
        end
        if not longest then parts[#parts + 1] = ''
        else
            local text = parts[longest]
            local units, total, pivot = chars(text), 0, 1
            for i, c in ipairs(units) do
                total = total + (#c > 1 and 2 or 1)
                if total >= length / 2 then pivot = i; break end
            end
            -- Prefer punctuation/word boundaries, preserving all source characters.
            for i = pivot, math.max(1, pivot - 10), -1 do
                if boundary(units[i]) then pivot = i; break end
            end
            pivot = math.min(#units - 1, math.max(1, pivot))
            parts[longest] = trim(table.concat(units, '', 1, pivot))
            table.insert(parts, longest + 1, trim(table.concat(units, '', pivot + 1)))
        end
    end
    return parts
end
local function seconds(text)
    local h, m, s, ms = text:match('(%d+):(%d+):(%d+),(%d+)')
    return h * 3600 + m * 60 + s + ms / 1000
end
function M.parse(data)
    if type(data) ~= 'string' then return nil end
    local cues = {}
    for block in (data:gsub('\r\n', '\n'):gsub('^\239\187\191', '') .. '\n\n'):gmatch('(.-)\n%s*\n') do
        if block:match('%S') then
            local start, finish, text = block:match('^%s*%d+\n([^\n]+)%s+%-%->%s+([^\n]+)\n(.+)$')
            if not start or not start:match('^%d%d:%d%d:%d%d,%d%d%d$') or
                not finish:match('^%d%d:%d%d:%d%d,%d%d%d$') or seconds(start) >= seconds(finish) then return nil end
            cues[#cues + 1] = {key = start .. ' --> ' .. finish, start = seconds(start), finish = seconds(finish), text = trim(text)}
        end
    end
    return #cues > 0 and cues or nil
end
local function ass_time(n)
    local ticks = math.floor(n * 100 + 0.00001)
    return string.format('%d:%02d:%02d.%02d', math.floor(ticks / 360000), math.floor(ticks / 6000) % 60,
        math.floor(ticks / 100) % 60, ticks % 100)
end
local function escape(text)
    return text:gsub('\\', '＼'):gsub('{', '｛'):gsub('}', '｝')
end
function M.render(original, translated, options)
    options = options or {}
    local source, translation = M.parse(original), translated and M.parse(translated)
    if not source or (translated and not translation) then return nil, 'Invalid subtitle data' end
    local lookup = {}
    for _, cue in ipairs(translation or {}) do lookup[cue.key] = cue.text end
    local scale = math.max(0.2, math.min(2, tonumber(options.scale) or 0.8))
    local maximum = math.max(16, math.min(100, tonumber(options.line_width) or 56))
    local rows = math.max(2, math.min(4, math.floor(tonumber(options.max_lines) or 2)))
    local duration = math.max(1, math.min(12, tonumber(options.max_seconds) or 6))
    local primary = (translated and 70 or (tonumber(options.plain_font_size) or 50) * 1.5) * scale
    local secondary = 50 * scale
    local font = (options.font or 'sans-serif'):gsub('[,\r\n]', '')
    local lines = {'[Script Info]', 'ScriptType: v4.00+', 'PlayResX: 1920', 'PlayResY: 1080',
        'WrapStyle: 2', 'ScaledBorderAndShadow: yes', '', '[V4+ Styles]',
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
        string.format('Style: Default,%s,%.2f,&H00FFFFFF,&H00FFFFFF,&H00000000,&H50000000,0,0,0,0,100,100,0,0,1,2,1,2,80,80,30,1', font, primary),
        '', '[Events]', 'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text'}
    local events = {}
    for _, cue in ipairs(source) do
        local target = lookup[cue.key]
        local source_parts = split(cue.text, maximum)
        local target_parts = target and split(target, maximum) or {}
        local count = math.max(#source_parts, #target_parts, math.ceil((cue.finish - cue.start) / duration))
        -- Timing is a proportional display estimate, not word-level forced alignment.
        source_parts, target_parts = expand(source_parts, count), expand(target_parts, count)
        for i = 1, count do
            local text, line_count = {}, 0
            local function add(part, style)
                if part == '' then return end
                for _, row in ipairs(split(part, maximum)) do
                    text[#text + 1] = style .. escape(row)
                    line_count = line_count + 1
                end
            end
            if target then
                add(target_parts[i], string.format('{\\fs%.2f\\c&HFFFFFF&}', primary))
                add(source_parts[i], string.format('{\\fs%.2f\\c&H62A8EB&}', secondary))
            else add(source_parts[i], '') end
            if #text > 0 then
                local start = cue.start + (cue.finish - cue.start) * (i - 1) / count
                local finish = cue.start + (cue.finish - cue.start) * i / count
                lines[#lines + 1] = string.format('Dialogue: 0,%s,%s,Default,,0,0,0,,%s', ass_time(start), ass_time(finish), table.concat(text, '\\N'))
                events[#events + 1] = {start = start, finish = finish, lines = line_count, source = source_parts[i], translated = target_parts[i]}
            end
        end
    end
    return table.concat(lines, '\n') .. '\n', {events = events, primary_size = primary, secondary_size = secondary, max_lines = rows}
end
M.width = width
return M
