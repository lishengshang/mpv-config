-- Run with the real config but other user scripts disabled; see gpu-verification.md.
local phase = 0
local function check(ok, reason)
    if not ok then
        mp.msg.error('REGRESSION FAIL: ' .. reason)
        mp.commandv('quit', '3')
        error(reason)
    end
end
local function vf_count() return #(mp.get_property_native('vf') or {}) end
local steps = {
    {'!', function() check(vf_count() == 1, 'Bilateral enable') end},
    {'!', function() check(vf_count() == 0, 'Bilateral disable') end},
    {'+', function() check(vf_count() == 1, 'DFTTest enable') end},
    {'+', function() check(vf_count() == 0, 'DFTTest disable') end},
    {'CTRL+ALT+1', function()
        check((mp.get_property('glsl-shaders') or ''):find('ArtCNN_C4F16', 1, true), 'light shader')
    end},
    {'CTRL+ALT+2', function()
        check((mp.get_property('glsl-shaders') or ''):find('ArtCNN_C4F32', 1, true), 'balanced shader')
        check(#mp.get_property_native('glsl-shaders') == 1, 'no stacking')
    end},
    {'CTRL+0', function() check(#mp.get_property_native('glsl-shaders') == 0, 'shader clear') end},
    {'!', function() check(vf_count() == 1, 'before next file') end}
}
local function step(i)
    if i > #steps then
        mp.commandv('loadfile', 'av://lavfi:testsrc2=size=640x360:rate=24,format=yuv420p', 'replace')
        return
    end
    mp.commandv('keypress', steps[i][1])
    -- Keypress queues the bound command; checking immediately can race it.
    mp.add_timeout(0.5, function() steps[i][2](); step(i + 1) end)
end
mp.register_event('file-loaded', function()
    phase = phase + 1
    mp.add_timeout(0.3, function()
        if phase == 1 then step(1) else
            check(vf_count() == 0, 'next-file reset')
            mp.commandv('keypress', '+')
            mp.add_timeout(0.6, function()
                check(vf_count() == 1, 'second-file enable')
                mp.commandv('keypress', 'ALT+~')
                mp.add_timeout(0.5, function()
                    check(vf_count() == 0, 'clear VS')
                    mp.msg.info('REGRESSION PASS: keys, toggles, shader replacement, clear, next-file reset')
                    mp.commandv('quit', '0')
                end)
            end)
        end
    end)
end)
mp.add_timeout(30, function() mp.commandv('quit', '4') end)
