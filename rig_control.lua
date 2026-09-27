-- SIX-DIRECTION PRC VERSION: Forward, Back, Left, Right, Up, Down.
-- Version 7: persistent timing editor and inset Up/Down arrowheads.
-- Touchscreen movement controls for ComputerCraft on Minecraft 1.6.4.
-- Run: rig_control.lua [monitor side or wired peripheral name]
-- This complete program can also be saved as /startup.
-- Designed for a 3 x 3 Advanced Monitor wall; also scales to 4 x 4.
-- One analog output feeds an MFR Programmable RedNet Controller (PRC).
-- Configure the PRC with six Equals circuits; see PRC_SETUP.md.
-- Movement names refer to PRC commands, not the computer's physical faces.

local args = { ... }
local OUTPUT_SIDE = "back" -- The one computer face wired to the PRC.
local pulseLength = 0.5
local CONFIG_WIDTH = 15 -- One standalone monitor at text scale 0.5.
local STATE_VERSION = "rig-control-prc-v1"
local SETTINGS_VERSION = "rig-control-settings-v1"
local BASE_WIDTH, BASE_HEIGHT = 56, 38
local commands = { front = 1, back = 2, left = 3, right = 4, up = 5, down = 6 }
-- Absolute path so recovery also works when this program is named startup.
local STATE_FILE = "/rig_control.state"
-- Timing preferences survive Ctrl+T as well as movement reboots.
local SETTINGS_FILE = "/rig_control.settings"
local delays = { front = 6, back = 6, left = 2, right = 2, up = 3, down = 3 }
-- These delays are OFF time after each pulse in Auto mode.
local sides = { "front", "back", "left", "right", "top", "bottom" }
local C = colors

local monitor, monitorName
local width, height, originX, originY
local guiScale = 1
local buttons, lockButton, configButton = {}, nil, nil
local layoutOK = false
local locked, active, pulseSide = false, nil, nil
local offTimer, repeatTimer = nil, nil
local screen = "main"
local draft, focusedField, replaceValue = nil, 1, true
local configMessage, invalidField = nil, nil
local inputBoxes, keypadButtons = {}, {}
local cancelButton, saveButton
local timingFields = {
    { key="pulse", label="Pulse Length", minimum=0.05 },
    { key="up", label="Up Delay", minimum=0 },
    { key="down", label="Down Delay", minimum=0 },
    { key="left", label="Left Delay", minimum=0 },
    { key="right", label="Right Delay", minimum=0 },
    { key="front", label="Forward Delay", minimum=0 },
    { key="back", label="Back Delay", minimum=0 }
}
local letterShapes = {
    L = { "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####" },
    R = { "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #" }
}

local function outputsOff()
    for _, side in ipairs(sides) do
        redstone.setAnalogOutput(side, 0)
    end
end

local function stopMotion()
    -- Old timer events are ignored after their IDs are cleared.
    offTimer, repeatTimer = nil, nil
    active, pulseSide = nil, nil
    outputsOff()
end

local function secondsText(value)
    local text = string.format("%.2f", value)
    return (text:gsub("0+$", ""):gsub("%.$", ""))
end

local function parseSeconds(text, field)
    if type(text) ~= "string" or not text:match("^%d*%.?%d*$") then
        return nil, "Enter a number for " .. field.label .. "."
    end
    local value = tonumber(text)
    if not value or value ~= value or value < field.minimum or value > 9999.99 then
        return nil, field.label .. ": " .. secondsText(field.minimum) ..
                    " to 9999.99 sec."
    end
    local decimals = text:match("%.(%d*)$")
    if decimals and #decimals > 2 then
        return nil, "Use up to 2 decimal places."
    end
    return value
end

local function applySettings(values)
    pulseLength = values.pulse
    for direction in pairs(delays) do delays[direction] = values[direction] end
end

local function loadSettings()
    local path = SETTINGS_FILE
    if not fs.exists(path) then
        -- An interrupted replacement may leave the previous file here.
        path = SETTINGS_FILE .. ".bak"
        if not fs.exists(path) then return end
    end
    local file = fs.open(path, "r")
    if not file then error("Cannot read timing settings: " .. path, 0) end
    local values = {}
    local valid = file.readLine() == SETTINGS_VERSION
    for _, field in ipairs(timingFields) do
        local line = file.readLine() or ""
        local prefix = field.key .. "="
        if line:sub(1, #prefix) ~= prefix then
            valid = false
        else
            values[field.key] = parseSeconds(line:sub(#prefix + 1), field)
            if values[field.key] == nil then valid = false end
        end
    end
    if file.readLine() ~= nil then valid = false end
    file.close()
    if not valid then error("Invalid timing settings: " .. path, 0) end
    if path ~= SETTINGS_FILE then fs.move(path, SETTINGS_FILE) end
    applySettings(values)
end

local function saveSettings(values)
    local temporary, backup = SETTINGS_FILE .. ".tmp", SETTINGS_FILE .. ".bak"
    local file
    local ok, message = pcall(function()
        file = fs.open(temporary, "w")
        if not file then error("Cannot write timing settings.", 0) end
        file.writeLine(SETTINGS_VERSION)
        for _, field in ipairs(timingFields) do
            file.writeLine(field.key .. "=" .. secondsText(values[field.key]))
        end
        file.close()
        file = nil
        -- Keep the old settings until the complete replacement is in place.
        if not fs.exists(SETTINGS_FILE) and fs.exists(backup) then
            fs.move(backup, SETTINGS_FILE)
        end
        if fs.exists(backup) then fs.delete(backup) end
        if fs.exists(SETTINGS_FILE) then fs.move(SETTINGS_FILE, backup) end
        fs.move(temporary, SETTINGS_FILE)
    end)
    if file then pcall(file.close) end
    if not ok then
        pcall(function()
            if not fs.exists(SETTINGS_FILE) and fs.exists(backup) then
                fs.move(backup, SETTINGS_FILE)
            end
        end)
        return false, message
    end
    -- Cleanup failure does not invalidate an already committed settings file.
    pcall(function() if fs.exists(backup) then fs.delete(backup) end end)
    return true
end

local function saveState()
    local temporary = STATE_FILE .. ".tmp"
    if not locked then
        if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
        if fs.exists(temporary) then fs.delete(temporary) end
        return
    end

    -- Close the new file before replacing the previous state. This must finish
    -- before powering an output, since that output can reboot the computer.
    local file = fs.open(temporary, "w")
    if not file then error("Cannot save Auto state. Movement stopped.", 0) end
    file.writeLine(STATE_VERSION)
    file.writeLine(OUTPUT_SIDE)
    file.writeLine(active or "idle")
    file.close()
    if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
    fs.move(temporary, STATE_FILE)
end

local function loadState()
    if not fs.exists(STATE_FILE) then return end
    local file = fs.open(STATE_FILE, "r")
    if not file then error("Cannot read saved Auto state.", 0) end
    local version, savedSide = file.readLine(), file.readLine()
    local direction, extra = file.readLine(), file.readLine()
    file.close()
    -- A first install or a changed output connection starts in Manual.
    if version == "rig-control-v1" or
       (version == STATE_VERSION and savedSide ~= OUTPUT_SIDE) then
        saveState()
        print("PRC connection changed. Starting in Manual.")
        return
    end
    if version ~= STATE_VERSION or extra ~= nil or
       (direction ~= "idle" and delays[direction] == nil) then
        error("Invalid saved Auto state. Restart to use Manual.", 0)
    end
    locked = true
    if direction ~= "idle" then active = direction end
end

local function findMonitor()
    if args[1] then
        if peripheral.getType(args[1]) ~= "monitor" then
            error("No monitor named " .. args[1], 0)
        end
        monitorName = args[1]
        monitor = peripheral.wrap(monitorName)
    else
        local names = redstone.getSides()
        if peripheral.getNames then names = peripheral.getNames() end
        local found = {}
        for _, name in ipairs(names) do
            if peripheral.getType(name) == "monitor" then
                local candidate = peripheral.wrap(name)
                if candidate.isColor and candidate.isColor() then
                    found[#found + 1] = name
                end
            end
        end
        if #found == 0 then
            error("Connect an Advanced Monitor wall first.", 0)
        elseif #found > 1 then
            error("Choose a monitor: rig_control.lua <name>\n" ..
                  table.concat(found, ", "), 0)
        end
        monitorName = found[1]
        monitor = peripheral.wrap(monitorName)
    end
    if not monitor.isColor or not monitor.isColor() then
        error("Touch controls need Advanced Monitors.", 0)
    end
end

local function updateLayout()
    width, height = monitor.getSize()
    layoutOK = width >= BASE_WIDTH and height >= BASE_HEIGHT
    buttons, lockButton, configButton = {}, nil, nil
    if not layoutOK then return end
    guiScale = math.min(width / BASE_WIDTH, height / BASE_HEIGHT)
    -- Round each shared measurement once so all six boxes stay identical.
    local buttonWidth = math.floor(14 * guiScale)
    -- Match the screen's odd/even width so centring never rounds left.
    buttonWidth = buttonWidth + (width - buttonWidth) % 2
    local buttonHeight = math.floor(9 * guiScale)
    -- Columns are narrower than rows. This pitch keeps the cross balanced.
    local spacingUnit = math.floor(6 * guiScale)
    local stepX, stepY = 3 * spacingUnit, 2 * spacingUnit
    local labelGap = 0
    local modeWidth = math.floor(20 * guiScale)
    modeWidth = modeWidth + (width - modeWidth) % 2
    local modeHeight = math.max(3, math.floor(3 * guiScale))
    local modeGap = math.max(1, math.floor(guiScale))
    local totalHeight = modeHeight + modeGap + 2 * stepY +
                        buttonHeight + labelGap + 1
    local centerX = (width + 1) / 2
    originX = centerX - (buttonWidth - 1) / 2
    originY = math.floor((height - totalHeight) / 2) + 1
    lockButton = {
        x = centerX - (modeWidth - 1) / 2, y = originY,
        w = modeWidth, h = modeHeight
    }
    local middleY = originY + modeHeight + modeGap + stepY
    configButton = {
        x = 1, y = height - modeHeight + 1,
        w = math.min(CONFIG_WIDTH, width), h = modeHeight
    }
    -- Shared columns: Up/Left, Forward/Back, and Right/Down.
    -- Shared rows: Up/Forward, Left/Right, and Back/Down.
    buttons = {
        { side="up", label="Up", dx=-stepX, dy=-stepY,
          arrow="up", headOnly=true, arrowOffsetY=1 },
        { side="front", label="Forward", dx=0, dy=-stepY,
          arrow="up" },
        { side="left", label="Left", dx=-stepX, dy=0,
          letter="L" },
        { side="right", label="Right", dx=stepX, dy=0,
          letter="R" },
        { side="back", label="Back", dx=0, dy=stepY,
          arrow="down", labelTop=true },
        { side="down", label="Down", dx=stepX, dy=stepY,
          arrow="down", labelTop=true, headOnly=true, arrowOffsetY=-1 }
    }
    for _, button in ipairs(buttons) do
        button.x, button.y = originX + button.dx, middleY + button.dy
        button.w, button.h = buttonWidth, buttonHeight
        button.delayRow = button.y + buttonHeight + labelGap
    end

    local fieldWidth = math.floor(12 * guiScale)
    local keyWidth = math.floor(5 * guiScale)
    local keyGap = math.max(1, math.floor(guiScale))
    local padWidth = 3 * keyWidth + 2 * keyGap
    local formWidth = 15 + fieldWidth + 4
    local columnGap = math.max(3, math.floor(4 * guiScale))
    local leftX = math.floor((width - formWidth - columnGap - padWidth) / 2) + 1
    local firstY = lockButton.y + modeHeight + 2
    local rowStep = modeHeight + 1
    inputBoxes, keypadButtons = {}, {}
    for i, field in ipairs(timingFields) do
        inputBoxes[i] = {
            x=leftX + 15, y=firstY + (i - 1) * rowStep,
            w=fieldWidth, h=modeHeight, labelX=leftX
        }
    end
    local padX = leftX + formWidth + columnGap
    local keyLabels = { "7", "8", "9", "4", "5", "6", "1", "2", "3", ".", "0", "<-" }
    for i, label in ipairs(keyLabels) do
        keypadButtons[i] = {
            x=padX + ((i - 1) % 3) * (keyWidth + keyGap),
            y=firstY + math.floor((i - 1) / 3) * rowStep,
            w=keyWidth, h=modeHeight, label=label
        }
    end
    keypadButtons[#keypadButtons + 1] = {
        x=padX, y=firstY + 4 * rowStep, w=padWidth, h=modeHeight, label="Clear"
    }
    cancelButton = { x=1, y=height-modeHeight+1, w=CONFIG_WIDTH, h=modeHeight }
    saveButton = { x=width-CONFIG_WIDTH+1, y=cancelButton.y, w=CONFIG_WIDTH, h=modeHeight }
end

local function fitMonitor()
    -- Keep the smallest legacy text scale for the most drawing detail.
    monitor.setTextScale(0.5)
    updateLayout()
end

local function writeAt(x, y, text, foreground, background)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(foreground)
    monitor.setBackgroundColor(background)
    monitor.write(text)
end

local function fill(x, y, w, h, background)
    for row = y, y + h - 1 do
        writeAt(x, row, string.rep(" ", w), C.white, background)
    end
end

local function centered(y, text, foreground)
    text = string.sub(text, 1, width)
    writeAt(math.floor((width - #text) / 2) + 1, y,
            text, foreground, C.black)
end

local function drawArrow(x, y, w, h, direction, color, headOnly)
    -- Draw mirrored spans instead of rounding polygon edges independently.
    -- Even widths have a two-cell tip; odd widths have a one-cell tip.
    local vertical = direction == "up" or direction == "down"
    local length = vertical and h or w
    local thickness = vertical and w or h
    local tipWidth = thickness % 2 == 0 and 2 or 1
    local pairs = (thickness - tipWidth) / 2
    local shaftPairs = math.floor(pairs / 3)
    local headLength = math.max(2, math.ceil(length * 0.55))
    -- Keep the shared head geometry, omitting the shaft for Up and Down.
    local lastRow = headOnly and headLength - 1 or length - 1
    for row = 0, lastRow do
        local halfSpan = shaftPairs
        if row < headLength then
            halfSpan = math.floor(pairs * row / (headLength - 1) + 0.5)
        end
        local span = tipWidth + 2 * halfSpan
        local inset = (thickness - span) / 2
        local along = row
        if direction == "down" or direction == "right" then
            along = length - row - 1
        end
        if vertical then
            fill(x + inset, y + along, span, 1, color)
        else
            fill(x + along, y + inset, 1, span, color)
        end
    end
end

local function buttonText(button, y, text, foreground, background)
    writeAt(button.x + math.floor((button.w - #text) / 2), y,
            text, foreground, background)
end

local function drawBigLetter(button, color)
    local shape = letterShapes[button.letter]
    local h = button.h - 2
    local w = math.min(button.w - 4, math.max(5, math.floor(h * 1.2)))
    -- Keep matching margins around the large character.
    if (button.w - w) % 2 ~= 0 then w = w - 1 end
    local x, y = button.x + (button.w - w) / 2, button.y + 1
    for row = 0, h - 1 do
        local pattern = shape[math.floor((row + 0.5) * #shape / h) + 1]
        local run = nil
        for column = 0, w do
            local ink = false
            if column < w then
                local sourceColumn = math.floor((column + 0.5) * #pattern / w) + 1
                ink = string.sub(pattern, sourceColumn, sourceColumn) == "#"
            end
            if ink and not run then
                run = column
            elseif not ink and run then
                fill(x + run, y + row, column - run, 1, color)
                run = nil
            end
        end
    end
end

local function drawFlatButton(button, label, foreground, background)
    fill(button.x, button.y, button.w, button.h, background)
    buttonText(button, button.y + math.floor(button.h / 2), label, foreground, background)
end

local function drawConfig()
    drawFlatButton(lockButton, "Config", C.black, C.yellow)
    for i, field in ipairs(timingFields) do
        local box = inputBoxes[i]
        local y = box.y + math.floor(box.h / 2)
        local focused = i == focusedField
        local border = focused and C.cyan or C.gray
        if invalidField == i then border = C.red end
        writeAt(box.labelX, y, field.label .. ":", C.white, C.black)
        fill(box.x, box.y, box.w, box.h, border)
        fill(box.x + 1, box.y + 1, box.w - 2, box.h - 2, C.white)
        local text = draft[field.key]
        writeAt(box.x + 1, y, text, C.black,
                focused and replaceValue and C.lightBlue or C.white)
        if focused and not replaceValue and #text < box.w - 2 then
            writeAt(box.x + 1 + #text, y, "_", C.gray, C.white)
        end
        writeAt(box.x + box.w + 1, y, "sec", C.lightGray, C.black)
    end
    for _, button in ipairs(keypadButtons) do
        drawFlatButton(button, button.label, C.black, C.lightBlue)
    end
    if configMessage then centered(cancelButton.y - 3, configMessage, C.red) end
    centered(cancelButton.y - 2, "Tap a field; use the number pad to edit.", C.lightGray)
    drawFlatButton(cancelButton, "Cancel", C.white, C.gray)
    drawFlatButton(saveButton, "Save", C.black, C.lime)
end

local function draw()
    monitor.setBackgroundColor(C.black)
    monitor.setTextColor(C.white)
    monitor.clear()
    if not layoutOK then
        centered(1, "MONITOR TOO SMALL", C.red)
        if height >= 3 then centered(3, "Use a 3 x 3 wall", C.white) end
        if height >= 5 then centered(5, "Outputs are off", C.lightGray) end
        return
    end
    if screen == "config" then
        drawConfig()
        return
    end

    local lockColor = locked and C.lime or C.cyan
    fill(lockButton.x, lockButton.y, lockButton.w, lockButton.h, lockColor)
    buttonText(lockButton, lockButton.y + math.floor(lockButton.h / 2),
               locked and "Auto" or "Manual", C.black, lockColor)
    local configDisabled = locked or pulseSide ~= nil
    local configColor = configDisabled and C.gray or C.yellow
    fill(configButton.x, configButton.y, configButton.w, configButton.h, configColor)
    buttonText(configButton, configButton.y + math.floor(configButton.h / 2),
               "Config", configDisabled and C.lightGray or C.black, configColor)

    for _, button in ipairs(buttons) do
        local selected = active == button.side
        local disabled = locked and active and not selected
        local background, edge, labelColor = C.lightBlue, C.cyan, C.black
        local delayColor = C.white
        if selected then
            background, edge, labelColor = C.green, C.lime, C.white
        elseif disabled then
            background, edge, labelColor = C.gray, C.lightGray, C.lightGray
            delayColor = C.gray
        elseif pulseSide == button.side then
            background, edge = C.white, C.cyan
        end
        fill(button.x, button.y, button.w, button.h, edge)
        fill(button.x + 1, button.y + 1, button.w - 2, button.h - 2, background)
        if button.letter then
            drawBigLetter(button, labelColor)
        else
            local labelY = button.labelTop and button.y + 1 or button.y + button.h - 2
            buttonText(button, labelY, button.label, labelColor, background)
            local iconTop = button.labelTop and labelY + 1 or button.y + 1
            local iconBottom = button.labelTop and button.y + button.h - 2 or labelY - 1
            local iconH = iconBottom - iconTop + 1
            local iconW = math.min(button.w - 4, math.max(5, math.floor(iconH * 1.4)))
            if (button.w - iconW) % 2 ~= 0 then iconW = iconW - 1 end
            drawArrow(button.x + (button.w - iconW) / 2,
                      iconTop + (button.arrowOffsetY or 0),
                      iconW, iconH, button.arrow, edge, button.headOnly)
        end
        buttonText(button, button.delayRow, secondsText(delays[button.side]) .. " sec",
                   delayColor, C.black)
    end
end

local function startPulse(side)
    outputsOff()
    pulseSide = side
    redstone.setAnalogOutput(OUTPUT_SIDE, commands[side])
    offTimer = os.startTimer(pulseLength)
end

local function inside(x, y, box)
    return x >= box.x and x < box.x + box.w and
           y >= box.y and y < box.y + box.h
end

local function focusField(index)
    focusedField = (index - 1) % #timingFields + 1
    replaceValue = true
    configMessage, invalidField = nil, nil
end

local function openConfig()
    -- Do not shorten an in-progress Manual pulse to open the editor.
    if locked or pulseSide then return end
    stopMotion()
    draft = { pulse=secondsText(pulseLength) }
    for direction, value in pairs(delays) do draft[direction] = secondsText(value) end
    focusField(1)
    screen = "config"
    draw()
end

local function closeConfig()
    screen, draft = "main", nil
    configMessage, invalidField = nil, nil
    draw()
end

local function editValue(input)
    local field = timingFields[focusedField]
    local text = draft[field.key]
    configMessage, invalidField = nil, nil
    if input == "Clear" then
        text = ""
    elseif input == "<-" then
        text = replaceValue and "" or text:sub(1, -2)
    elseif input:match("^%d$") or input == "." then
        if replaceValue then text = "" end
        if input == "." and text:find(".", 1, true) then return end
        if input == "." and text == "" then text = "0" end
        local newText = text .. input
        local decimals = newText:match("%.(%d*)$")
        if #newText > 7 or (decimals and #decimals > 2) then
            configMessage = "Max 9999.99 seconds; up to 2 decimal places."
            draw()
            return
        end
        text = newText
    else
        return
    end
    draft[field.key], replaceValue = text, false
    draw()
end

local function saveDraft()
    local values = {}
    for i, field in ipairs(timingFields) do
        local value, message = parseSeconds(draft[field.key], field)
        if value == nil then
            focusField(i)
            configMessage, invalidField = message, i
            draw()
            return
        end
        values[field.key] = value
    end
    local ok, message = saveSettings(values)
    if not ok then
        configMessage = "Save failed. Changes have not been applied."
        print("Cannot save timing settings: " .. tostring(message))
        draw()
        return
    end
    applySettings(values)
    closeConfig()
end

local function handleConfigTouch(x, y)
    if inside(x, y, cancelButton) then closeConfig(); return end
    if inside(x, y, saveButton) then saveDraft(); return end
    for i, box in ipairs(inputBoxes) do
        if inside(x, y, box) then focusField(i); draw(); return end
    end
    for _, button in ipairs(keypadButtons) do
        if inside(x, y, button) then editValue(button.label); return end
    end
end

local function handleConfigKey(key)
    if key == keys.backspace then
        editValue("<-")
    elseif key == keys.delete then
        editValue("Clear")
    elseif key == keys.tab or key == keys.enter or key == keys.down then
        focusField(focusedField + 1)
        draw()
    elseif key == keys.up then
        focusField(focusedField - 1)
        draw()
    end
end

local function handleTouch(x, y)
    if not layoutOK then return end
    if screen == "config" then handleConfigTouch(x, y); return end
    if inside(x, y, configButton) then
        openConfig()
        return
    end
    if inside(x, y, lockButton) then
        stopMotion()
        locked = not locked
        saveState()
        draw()
        return
    end
    for _, button in ipairs(buttons) do
        if inside(x, y, button) then
            if locked then
                if active == button.side then
                    stopMotion()
                    saveState()
                elseif active then
                    return -- The other five arrows are disabled.
                else
                    active = button.side
                    saveState()
                    startPulse(active)
                end
            else
                if pulseSide then return end -- Let the short pulse finish.
                startPulse(button.side)
            end
            draw()
            return
        end
    end
end

local function main()
    local validOutput = false
    for _, side in ipairs(sides) do
        if side == OUTPUT_SIDE then validOutput = true end
    end
    if not validOutput then error("Invalid OUTPUT_SIDE setting.", 0) end
    loadSettings()
    loadState()
    findMonitor()
    fitMonitor()
    if not layoutOK and active then
        stopMotion()
        saveState()
    end
    if locked and active then
        -- Movement reboots us. Keep outputs off and wait a full directional
        -- delay after startup, rather than moving immediately at every boot.
        repeatTimer = os.startTimer(delays[active])
        print("Resuming Auto " .. active .. " in " .. delays[active] .. " seconds.")
    end
    draw()
    print("Movement controls: " .. monitorName)
    print("PRC output: " .. OUTPUT_SIDE .. " (strengths 1-6, 0 = off)")
    print("Right-click the monitor buttons.")
    print("Hold Ctrl+T here to stop and exit.")

    while true do
        local event, a, b, c = os.pullEventRaw()
        if event == "terminate" then
            return
        elseif event == "monitor_touch" and a == monitorName then
            handleTouch(b, c)
        elseif event == "char" and screen == "config" and layoutOK then
            editValue(a)
        elseif event == "key" and screen == "config" and layoutOK then
            handleConfigKey(a)
        elseif event == "timer" then
            if a == offTimer then
                offTimer = nil
                outputsOff()
                pulseSide = nil
                if locked and active then
                    repeatTimer = os.startTimer(delays[active])
                end
                draw()
            elseif a == repeatTimer then
                repeatTimer = nil
                if locked and active then
                    startPulse(active)
                    draw()
                end
            end
        elseif event == "monitor_resize" and a == monitorName then
            local newWidth, newHeight = monitor.getSize()
            -- Applying text scale can queue a resize event.
            -- Ignore those if we already drew the monitor's final size.
            if newWidth ~= width or newHeight ~= height then
                stopMotion()
                fitMonitor()
                saveState()
                draw()
            end
        elseif event == "peripheral_detach" then
            if a == monitorName or peripheral.getType(monitorName) ~= "monitor" then
                error("Monitor disconnected. Movement stopped.", 0)
            end
        end
    end
end

outputsOff()
local ok, message = pcall(main)
stopMotion()
-- A reboot never reaches this cleanup. Ctrl+T and errors do, and must clear
-- the saved direction so a later startup cannot resume a stopped rig.
locked = false
local cleared, clearError = pcall(saveState)
if monitor then
    pcall(function()
        monitor.setBackgroundColor(C.black)
        monitor.setTextColor(C.white)
        monitor.clear()
        width, height = monitor.getSize()
        centered(math.max(1, math.floor(height / 2)), "STOPPED", C.white)
    end)
end
if ok then
    print("Stopped. All outputs are off.")
else
    print("Stopped: " .. tostring(message))
end
if not cleared then
    print("Could not clear saved Auto state: " .. tostring(clearError))
    print("Delete " .. STATE_FILE .. " before restarting.")
end
