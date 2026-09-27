-- SIX-DIRECTION PRC VERSION: Forward, Back, Left, Right, Up, Down.
-- Layout v4: large U/D/L/R letters and a compact Config button with feedback.
-- Touchscreen movement controls for ComputerCraft on Minecraft 1.6.4.
-- Run: rig_control.lua [monitor side or wired peripheral name]
-- This complete program can also be saved as /startup.
-- Designed for a 3 x 3 Advanced Monitor wall; also scales to 4 x 4.
-- One analog output feeds an MFR Programmable RedNet Controller (PRC).
-- Configure the PRC with six Equals circuits; see PRC_SETUP.md.
-- Movement names refer to PRC commands, not the computer's physical faces.

local args = { ... }
local OUTPUT_SIDE = "back" -- The one computer face wired to the PRC.
local PULSE_TIME = 0.5
local CONFIG_WIDTH = 15 -- One standalone monitor at text scale 0.5.
local CONFIG_FLASH_TIME = 0.25
local STATE_VERSION = "rig-control-prc-v1"
local BASE_WIDTH, BASE_HEIGHT = 56, 38
local commands = { front = 1, back = 2, left = 3, right = 4, up = 5, down = 6 }
-- Absolute path so recovery also works when this program is named startup.
local STATE_FILE = "/rig_control.state"
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
local configTimer = nil
local letterShapes = {
    U = { "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
    D = { "#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### " },
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
          letter="U" },
        { side="front", label="Forward", dx=0, dy=-stepY,
          arrow="up" },
        { side="left", label="Left", dx=-stepX, dy=0,
          letter="L" },
        { side="right", label="Right", dx=stepX, dy=0,
          letter="R" },
        { side="back", label="Back", dx=0, dy=stepY,
          arrow="down", labelTop=true },
        { side="down", label="Down", dx=stepX, dy=stepY,
          letter="D" }
    }
    for _, button in ipairs(buttons) do
        button.x, button.y = originX + button.dx, middleY + button.dy
        button.w, button.h = buttonWidth, buttonHeight
        button.delayRow = button.y + buttonHeight + labelGap
    end
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

local function drawArrow(x, y, w, h, direction, color)
    -- Draw mirrored spans instead of rounding polygon edges independently.
    -- Even widths have a two-cell tip; odd widths have a one-cell tip.
    local vertical = direction == "up" or direction == "down"
    local length = vertical and h or w
    local thickness = vertical and w or h
    local tipWidth = thickness % 2 == 0 and 2 or 1
    local pairs = (thickness - tipWidth) / 2
    local shaftPairs = math.floor(pairs / 3)
    local headLength = math.max(2, math.ceil(length * 0.55))
    for row = 0, length - 1 do
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

    local lockColor = locked and C.lime or C.cyan
    fill(lockButton.x, lockButton.y, lockButton.w, lockButton.h, lockColor)
    buttonText(lockButton, lockButton.y + math.floor(lockButton.h / 2),
               locked and "Auto" or "Manual", C.black, lockColor)
    local configColor = configTimer and C.white or C.yellow
    fill(configButton.x, configButton.y, configButton.w, configButton.h, configColor)
    buttonText(configButton, configButton.y + math.floor(configButton.h / 2),
               "Config", C.black, configColor)

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
            drawArrow(button.x + (button.w - iconW) / 2, iconTop,
                      iconW, iconH, button.arrow, edge)
        end
        buttonText(button, button.delayRow, delays[button.side] .. " sec",
                   delayColor, C.black)
    end
end

local function startPulse(side)
    outputsOff()
    pulseSide = side
    redstone.setAnalogOutput(OUTPUT_SIDE, commands[side])
    offTimer = os.startTimer(PULSE_TIME)
end

local function inside(x, y, box)
    return x >= box.x and x < box.x + box.w and
           y >= box.y and y < box.y + box.h
end

local function handleTouch(x, y)
    if not layoutOK then return end
    if inside(x, y, configButton) then
        configTimer = os.startTimer(CONFIG_FLASH_TIME)
        draw()
        return -- Feedback only; timing settings will be added later.
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
        elseif event == "timer" then
            if a == configTimer then
                configTimer = nil
                draw()
            elseif a == offTimer then
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
