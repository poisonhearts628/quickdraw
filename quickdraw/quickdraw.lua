--[[
* Quick Draw Charge Tracker
* Staggered cards + settings + bottom-to-top fill
* Ashita v4
*
* /qd  - Open settings
--]]

addon.name    = 'quickdraw';
addon.author  = 'Zilas';
addon.version = '2.7';
addon.desc    = 'Corsair Quick Draw tracker with staggered cards';

require('common');
local chat       = require('chat');
local imgui      = require('imgui');
local primitives = require('primitives');
local fonts      = require('fonts');
local settings   = require('settings');
local ffi        = require('ffi');

------------------------------------------------
-- Game config access (SE mute)
------------------------------------------------
ffi.cdef[[
    typedef int32_t (__cdecl* get_config_value_t)(int32_t);
]];

local game_config = { get = nil, ready = false };
local CONFIG_SOUND = 9;

local function init_game_config()
    pcall(function()
        local ptr = ashita.memory.find('FFXiMain.dll', 0, '8B0D????????85C974??8B44240450E8????????C383C8FFC3', 0, 0);
        if ptr ~= 0 then
            game_config.get = ffi.cast('get_config_value_t', ptr);
            game_config.ready = true;
        end
    end);
end

local function get_game_se_volume()
    if not game_config.ready or not game_config.get then return 100; end
    local ok, val = pcall(function() return game_config.get(CONFIG_SOUND); end);
    if ok and type(val) == 'number' then return val; end
    return 100;
end

------------------------------------------------
-- Settings
------------------------------------------------
local default_settings = T{
    position = T{ x = 100, y = 200 },
    scale    = 0.42,
    text_size = 12,
    text_offset = -80,
    text_font = 'Arial',
    text_color = T{ 1.0, 1.0, 1.0, 1.0 }, -- RGBA 0-1 for ImGui
    offset_x = 70,
    offset_y = -55,
    sound = T{
        enabled = true,
        file = 'reload.wav',
    },
};

local FONT_OPTIONS = {
    'Arial',
    'Arial Black',
    'Verdana',
    'Tahoma',
    'Segoe UI',
    'Georgia',
    'Times New Roman',
    'Courier New',
    'Comic Sans MS',
    'Impact',
};

local qd_settings = settings.load(default_settings);

local function rgba_to_color(c)
    local r = math.floor((c[1] or 1) * 255);
    local g = math.floor((c[2] or 1) * 255);
    local b = math.floor((c[3] or 1) * 255);
    local a = math.floor((c[4] or 1) * 255);
    return (a * 0x1000000) + (r * 0x10000) + (g * 0x100) + b;
end

local card1_bg, card1_fill = nil, nil;
local card2_bg, card2_fill = nil, nil;
local text_font = nil;

local last_charges = -1;
local pulse = {
    active = false,
    card = nil,
    start_time = 0,
    duration = 0.40,
};

local show_config = false;
local config_scale = { qd_settings.scale };
local config_text_size = { qd_settings.text_size };

local QUICK_DRAW_TIMER_ID = 195;
local IMAGE_NAME = 'burning_card.png';

------------------------------------------------
-- Size helpers
------------------------------------------------
-- Source texture is 360x360
local TEX_SIZE = 360;

local function card_w()
    return TEX_SIZE * qd_settings.scale;
end

local function card_h()
    return TEX_SIZE * qd_settings.scale;
end

------------------------------------------------
-- Quick Draw data
------------------------------------------------
local function get_quick_draw_info()
    local mmRecast = AshitaCore:GetMemoryManager():GetRecast();
    local player   = AshitaCore:GetMemoryManager():GetPlayer();

    if player:GetMainJob() ~= 17 and player:GetSubJob() ~= 17 then
        return nil;
    end

    for i = 0, 31 do
        local timerId = mmRecast:GetAbilityTimerId(i);
        if timerId == QUICK_DRAW_TIMER_ID then
            local timer = mmRecast:GetAbilityTimer(i);
            local duration = timer / 60.0;

            local ptr = ashita.memory.find('FFXiMain.dll', 0, '894124E9????????8B46??6A006A00508BCEE8', 0x19, 0);
            if ptr == 0 then return nil; end
            ptr = ashita.memory.read_uint32(ptr);
            local modifier = ashita.memory.read_int16(ptr + (i * 8) + 4);

            local baseRecast  = 120 + modifier;
            local chargeValue = baseRecast / 2;
            local charges = math.floor((baseRecast - duration) / chargeValue);
            charges = math.max(0, math.min(2, charges));

            local nextCharge = 0;
            local progress = 1.0;

            if charges < 2 then
                nextCharge = math.fmod(duration, chargeValue);
                if nextCharge == 0 and duration > 0 then
                    nextCharge = chargeValue;
                end
                progress = 1.0 - (nextCharge / chargeValue);
                if progress < 0 then progress = 0; end
                if progress > 1 then progress = 1; end
            end

            return {
                charges = charges,
                nextCharge = nextCharge,
                progress = progress,
            };
        end
    end

    return { charges = 2, nextCharge = 0, progress = 1.0 };
end

------------------------------------------------
-- Sound
------------------------------------------------
local function play_charge_sound()
    if not qd_settings.sound.enabled then return; end
    if get_game_se_volume() <= 0 then return; end
    ashita.misc.play_sound(addon.path .. '\\' .. qd_settings.sound.file);
end

------------------------------------------------
-- Create / Destroy
------------------------------------------------
local function create_cards()
    local scale = qd_settings.scale;
    local image_path = addon.path .. '\\' .. IMAGE_NAME;

    card1_bg = primitives.new();
    card1_bg.scale_x = scale;
    card1_bg.scale_y = scale;
    card1_bg.color = 0x66AAAAAA;
    card1_bg.visible = true;
    card1_bg.texture = image_path;

    card1_fill = primitives.new();
    card1_fill.scale_x = scale;
    card1_fill.scale_y = scale;
    card1_fill.color = 0xFFFFFFFF;
    card1_fill.visible = true;
    card1_fill.texture = image_path;

    card2_bg = primitives.new();
    card2_bg.scale_x = scale;
    card2_bg.scale_y = scale;
    card2_bg.color = 0x66AAAAAA;
    card2_bg.visible = true;
    card2_bg.texture = image_path;

    card2_fill = primitives.new();
    card2_fill.scale_x = scale;
    card2_fill.scale_y = scale;
    card2_fill.color = 0xFFFFFFFF;
    card2_fill.visible = true;
    card2_fill.texture = image_path;

    text_font = fonts.new({
        font_family = qd_settings.text_font or 'Arial',
        font_height = qd_settings.text_size,
        color = rgba_to_color(qd_settings.text_color or {1,1,1,1}),
        color_outline = 0xFF000000,
        visible = true,
    });
end

local function destroy_cards()
    if card1_bg then card1_bg:destroy(); card1_bg = nil; end
    if card1_fill then card1_fill:destroy(); card1_fill = nil; end
    if card2_bg then card2_bg:destroy(); card2_bg = nil; end
    if card2_fill then card2_fill:destroy(); card2_fill = nil; end
    if text_font then text_font:destroy(); text_font = nil; end
end

local function recreate_cards()
    destroy_cards();
    create_cards();
end

local function apply_text_style()
    if not text_font then return; end
    text_font.font_height = qd_settings.text_size;
    text_font.font_family = qd_settings.text_font or 'Arial';
    text_font.color = rgba_to_color(qd_settings.text_color or {1,1,1,1});
end

------------------------------------------------
-- Pulse
------------------------------------------------
local function start_pulse(card_number)
    pulse.active = true;
    pulse.card = card_number;
    pulse.start_time = os.clock();
end

local function update_pulse()
    if not pulse.active then return; end

    local elapsed = os.clock() - pulse.start_time;
    local progress = elapsed / pulse.duration;
    local base = qd_settings.scale;

    if progress >= 1.0 then
        if pulse.card == 1 then
            if card1_bg then card1_bg.scale_x = base; card1_bg.scale_y = base; end
            if card1_fill then card1_fill.scale_x = base; end
        else
            if card2_bg then card2_bg.scale_x = base; card2_bg.scale_y = base; end
            if card2_fill then card2_fill.scale_x = base; end
        end
        pulse.active = false;
        return;
    end

    local amount = math.sin(progress * math.pi) * 0.22;
    local current = base * (1.0 + amount);

    if pulse.card == 1 then
        if card1_bg then card1_bg.scale_x = current; card1_bg.scale_y = current; end
        if card1_fill then card1_fill.scale_x = current; end
    else
        if card2_bg then card2_bg.scale_x = current; card2_bg.scale_y = current; end
        if card2_fill then card2_fill.scale_x = current; end
    end
end

------------------------------------------------
-- Display (staggered + bottom-to-top fill)
------------------------------------------------
local function update_display(info)
    if not card1_bg then return; end

    if not info then
        card1_bg.visible = false;
        card1_fill.visible = false;
        card2_bg.visible = false;
        card2_fill.visible = false;
        if text_font then text_font.visible = false; end
        return;
    end

    card1_bg.visible = true;
    card2_bg.visible = true;
    card1_fill.visible = true;
    card2_fill.visible = true;
    if text_font then text_font.visible = true; end

    local scale = qd_settings.scale;
    local h = card_h();

    local x1 = qd_settings.position.x;
    local y1 = qd_settings.position.y;
    local x2 = x1 + (qd_settings.offset_x * scale);
    local y2 = y1 + (qd_settings.offset_y * scale);

    -- Gray backgrounds always full size
    card1_bg.position_x = x1;
    card1_bg.position_y = y1;
    card1_bg.scale_x = scale;
    card1_bg.scale_y = scale;

    card2_bg.position_x = x2;
    card2_bg.position_y = y2;
    card2_bg.scale_x = scale;
    card2_bg.scale_y = scale;

    -- Colored fills: fully on when charge available, hidden when not.
    -- No progressive fill — snaps on with the pulse when a charge is ready.
    local function set_fill(prim, bx, by, available)
        prim.position_x = bx;
        prim.position_y = by;
        prim.scale_x = scale;
        prim.scale_y = scale;
        prim.color = 0xFFFFFFFF;
        prim.visible = available;
    end

    set_fill(card1_fill, x1, y1, info.charges >= 1);
    set_fill(card2_fill, x2, y2, info.charges >= 2);

    if text_font then
        text_font.position_x = x1;
        text_font.position_y = y1 + h + (qd_settings.text_offset or 0);
        if info.charges >= 2 then
            text_font.text = 'Quick Draw Ready';
        else
            local t = info.nextCharge;
            local tstr = t < 60 and string.format('%.1fs', t) or string.format('%d:%02d', math.floor(t/60), math.floor(t%60));
            text_font.text = string.format('Next: %s', tstr);
        end
    end
end

------------------------------------------------
-- Settings window
------------------------------------------------
local function draw_config()
    if not show_config then return; end

    imgui.SetNextWindowSize({ 300, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Quick Draw Settings', true, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.Text('Position');
        imgui.Separator();
        imgui.Text(string.format('X: %d   Y: %d', qd_settings.position.x, qd_settings.position.y));

        if imgui.Button('< Left') then
            qd_settings.position.x = qd_settings.position.x - 20;
            settings.save();
        end
        imgui.SameLine();
        if imgui.Button('Right >') then
            qd_settings.position.x = qd_settings.position.x + 20;
            settings.save();
        end

        if imgui.Button('^ Up') then
            qd_settings.position.y = qd_settings.position.y - 20;
            settings.save();
        end
        imgui.SameLine();
        if imgui.Button('v Down') then
            qd_settings.position.y = qd_settings.position.y + 20;
            settings.save();
        end

        imgui.Spacing();
        imgui.Text('Fine (10px)');
        if imgui.Button('< 10') then
            qd_settings.position.x = qd_settings.position.x - 10;
            settings.save();
        end
        imgui.SameLine();
        if imgui.Button('10 >') then
            qd_settings.position.x = qd_settings.position.x + 10;
            settings.save();
        end
        imgui.SameLine();
        if imgui.Button('^ 10') then
            qd_settings.position.y = qd_settings.position.y - 10;
            settings.save();
        end
        imgui.SameLine();
        if imgui.Button('v 10') then
            qd_settings.position.y = qd_settings.position.y + 10;
            settings.save();
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Text('Card Scale');
        local scale_changed = imgui.SliderFloat('##scale', config_scale, 0.20, 1.00, '%.2f');
        if scale_changed then
            qd_settings.scale = config_scale[1];
            recreate_cards();
            settings.save();
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Text('Text');
        imgui.Spacing();

        imgui.Text('Size');
        local text_changed = imgui.SliderInt('##textsize', config_text_size, 8, 24);
        if text_changed then
            qd_settings.text_size = config_text_size[1];
            apply_text_style();
            settings.save();
        end

        imgui.Text('Offset (up/down)');
        local to = { qd_settings.text_offset or 0 };
        if imgui.SliderInt('##textoffset', to, -200, 50) then
            qd_settings.text_offset = to[1];
            settings.save();
        end

        imgui.Text('Font');
        local current_font = qd_settings.text_font or 'Arial';
        if imgui.BeginCombo('##font', current_font) then
            for _, name in ipairs(FONT_OPTIONS) do
                local selected = (name == current_font);
                if imgui.Selectable(name, selected) then
                    qd_settings.text_font = name;
                    apply_text_style();
                    settings.save();
                end
                if selected then
                    imgui.SetItemDefaultFocus();
                end
            end
            imgui.EndCombo();
        end

        imgui.Text('Color');
        local col = {
            (qd_settings.text_color and qd_settings.text_color[1]) or 1.0,
            (qd_settings.text_color and qd_settings.text_color[2]) or 1.0,
            (qd_settings.text_color and qd_settings.text_color[3]) or 1.0,
            (qd_settings.text_color and qd_settings.text_color[4]) or 1.0,
        };
        if imgui.ColorEdit4('##textcolor', col) then
            qd_settings.text_color = T{ col[1], col[2], col[3], col[4] };
            apply_text_style();
            settings.save();
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Text('Sound');
        if imgui.Checkbox('Enable sound on charge', { qd_settings.sound.enabled }) then
            qd_settings.sound.enabled = not qd_settings.sound.enabled;
            settings.save();
        end

        local se = get_game_se_volume();
        imgui.Text(string.format('Game SE Volume: %d%s', se, se <= 0 and ' (muted)' or ''));

        if imgui.Button('Test Sound + Pulse') then
            play_charge_sound();
            start_pulse(1);
        end

        imgui.Spacing();
        imgui.Separator();
        if imgui.Button('Close') then
            show_config = false;
        end
    end
    imgui.End();
end

------------------------------------------------
-- Main update
------------------------------------------------
local function update()
    local info = get_quick_draw_info();

    if info and last_charges ~= -1 and info.charges > last_charges then
        play_charge_sound();
        if info.charges == 1 then
            start_pulse(1);
        elseif info.charges == 2 then
            start_pulse(2);
        end
    end
    last_charges = info and info.charges or -1;

    update_display(info);
    update_pulse();
    draw_config();
end

------------------------------------------------
-- Events
------------------------------------------------
ashita.events.register('load', 'load_cb', function()
    init_game_config();
    create_cards();
    config_scale = { qd_settings.scale };
    config_text_size = { qd_settings.text_size };
    print(chat.header('QuickDraw') .. chat.message('Loaded. Type /qd to open settings.'));
end);

ashita.events.register('unload', 'unload_cb', function()
    destroy_cards();
end);

ashita.events.register('d3d_present', 'present_cb', function()
    update();
end);

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if #args == 0 or args[1]:lower() ~= '/qd' then return; end
    e.blocked = true;

    local cmd = args[2] and args[2]:lower() or '';

    if cmd == '' then
        show_config = not show_config;
        if show_config then
            config_scale = { qd_settings.scale };
            config_text_size = { qd_settings.text_size };
        end

    elseif cmd == 'pos' and args[3] and args[4] then
        local x = tonumber(args[3]);
        local y = tonumber(args[4]);
        if x and y then
            qd_settings.position.x = x;
            qd_settings.position.y = y;
            settings.save();
            print(chat.header('QuickDraw') .. chat.message(string.format('Moved to %d, %d', x, y)));
        end

    elseif cmd == 'left' or cmd == 'right' or cmd == 'up' or cmd == 'down' then
        local dist = tonumber(args[3]) or 20;
        if cmd == 'left'  then qd_settings.position.x = qd_settings.position.x - dist; end
        if cmd == 'right' then qd_settings.position.x = qd_settings.position.x + dist; end
        if cmd == 'up'    then qd_settings.position.y = qd_settings.position.y - dist; end
        if cmd == 'down'  then qd_settings.position.y = qd_settings.position.y + dist; end
        settings.save();
        print(chat.header('QuickDraw') .. chat.message(string.format('Position: %d, %d', qd_settings.position.x, qd_settings.position.y)));

    elseif cmd == 'scale' and args[3] then
        local s = tonumber(args[3]);
        if s and s > 0.15 and s < 1.5 then
            qd_settings.scale = s;
            config_scale = { s };
            settings.save();
            recreate_cards();
            print(chat.header('QuickDraw') .. chat.message('Scale set to ' .. s));
        end

    elseif cmd == 'sound' then
        qd_settings.sound.enabled = not qd_settings.sound.enabled;
        settings.save();
        print(chat.header('QuickDraw') .. chat.message('Sound ' .. (qd_settings.sound.enabled and 'ON' or 'OFF')));

    elseif cmd == 'test' then
        play_charge_sound();
        start_pulse(1);

    else
        print(chat.header('QuickDraw') .. chat.message('Commands:'));
        print(chat.message('  /qd                 Open settings'));
        print(chat.message('  /qd pos <x> <y>'));
        print(chat.message('  /qd left/right/up/down [px]'));
        print(chat.message('  /qd scale <number>'));
        print(chat.message('  /qd sound'));
        print(chat.message('  /qd test'));
    end
end);
