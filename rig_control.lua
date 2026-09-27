-- Touchscreen movement controls for ComputerCraft on Minecraft 1.6.4.
-- Run: rig_control.lua [monitor side or wired peripheral name]
-- Use a joined wall of Advanced Monitors, at least 2 blocks by 2 blocks.
-- Directions refer to the computer's own faces. RedNet colour channels
-- are configured on the cables, not in this program.

local args = { ... }
local PULSE_TIME = 0.1
local delays = { front = 6, back = 6, left = 2, right = 2 }
-- These delays are OFF time after each pulse in Lock mode.
local sides = { "front", "back", "left", "right" }
local C = colors

local monitor, monitorName
local width, height, originX, originY
local buttons, lockButton = {}, nil
local layoutOK = false
local locked, active, pulseSide = false, nil, nil
local offTimer, repeatTimer = nil, nil

local shapes = {
    front = { "  #  ", " ### ", "#####", "  #  ", "  #  " },
    back  = { "  #  ", "  #  ", "#####", " ### ", "  #  " },
    left  = { "  #  ", " ##  ", "#####", " ##  ", "  #  " },
    right = { "  #  ", "  ## ", "#####", "  ## ", "  #  " }
}

local function outputsOff()
    for _, side in ipairs(sides) do
        redstone.setOutput(side, false)
    end
end

local function stopMotion()
    -- Old timer events are ignored after their IDs are cleared.
    offTimer, repeatTimer = nil, nil
    active, pulseSide = nil, nil
    outputsOff()
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
    layoutOK = width >= 29 and height >= 24
    buttons, lockButton = {}, nil
    if not layoutOK then return end
    originX = math.floor((width - 29) / 2) + 1
    originY = math.floor((height - 24) / 2) + 1
    lockButton = {
        x = math.floor((width - 15) / 2) + 1,
        y = originY, w = 15, h = 3
    }
    buttons = {
        { side = "front", x = originX + 10, y = originY + 4 },
        { side = "left",  x = originX,      y = originY + 10 },
        { side = "right", x = originX + 20, y = originY + 10 },
        { side = "back",  x = originX + 10, y = originY + 16 }
    }
end

local function fitMonitor()
    -- Use only legacy monitor functions, with no modern drawing API.
    for step = 10, 1, -1 do
        monitor.setTextScale(step / 2)
        updateLayout()
        if layoutOK then return end
    end
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

local function draw()
    monitor.setBackgroundColor(C.black)
    monitor.setTextColor(C.white)
    monitor.clear()
    if not layoutOK then
        centered(1, "MONITOR TOO SMALL", C.red)
        if height >= 3 then centered(3, "Use a 2 x 2 wall", C.white) end
        if height >= 5 then centered(5, "Outputs are off", C.lightGray) end
        return
    end

    local lockColor = locked and C.lime or C.gray
    fill(lockButton.x, lockButton.y, 15, 3, lockColor)
    local label = locked and "Auto" or "Manual"
    writeAt(lockButton.x + math.floor((15 - #label) / 2),
            lockButton.y + 1, label,
            locked and C.black or C.white, lockColor)

    for _, button in ipairs(buttons) do
        local selected = active == button.side
        local disabled = locked and active and not selected
        local background, arrow, labelColor = C.blue, C.white, C.white
        if selected then
            background, arrow = C.green, C.lime
        elseif disabled then
            background, arrow, labelColor = C.gray, C.lightGray, C.gray
        elseif pulseSide == button.side then
            background = C.cyan
        end
        fill(button.x, button.y, 9, 5, background)
        for row, pattern in ipairs(shapes[button.side]) do
            for col = 1, #pattern do
                if string.sub(pattern, col, col) == "#" then
                    writeAt(button.x + 1 + col, button.y + row - 1,
                            " ", arrow, arrow)
                end
            end
        end
        local name = string.upper(button.side) .. " " .. delays[button.side] .. "s"
        writeAt(button.x + math.floor((9 - #name) / 2), button.y + 5,
                name, labelColor, C.black)
    end

    centered(originY + 11, locked and "LOCKED" or "MANUAL", C.lightGray)
    local state = pulseSide and "PULSE" or (active and "WAIT" or "READY")
    centered(originY + 13, state, active and C.lime or C.white)
    local hint = "Click an arrow for one pulse"
    if locked then
        hint = active and "Tap active arrow to stop" or "Choose a direction"
    end
    centered(originY + 23, hint, C.lightGray)
end

local function startPulse(side)
    outputsOff()
    pulseSide = side
    redstone.setOutput(side, true)
    offTimer = os.startTimer(PULSE_TIME)
end

local function inside(x, y, box, w, h)
    return x >= box.x and x < box.x + w and
           y >= box.y and y < box.y + h
end

local function handleTouch(x, y)
    if not layoutOK then return end
    if inside(x, y, lockButton, 15, 3) then
        stopMotion()
        locked = not locked
        draw()
        return
    end
    for _, button in ipairs(buttons) do
        if inside(x, y, button, 9, 6) then
            if locked then
                if active == button.side then
                    stopMotion()
                elseif active then
                    return -- The other three arrows are disabled.
                else
                    active = button.side
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
    findMonitor()
    fitMonitor()
    draw()
    print("Movement controls: " .. monitorName)
    print("Right-click the monitor buttons.")
    print("Hold Ctrl+T here to stop and exit.")

    while true do
        local event, a, b, c = os.pullEventRaw()
        if event == "terminate" then
            return
        elseif event == "monitor_touch" and a == monitorName then
            handleTouch(b, c)
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
            stopMotion()
            updateLayout()
            draw()
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
    print("Stopped. All four outputs are off.")
else
    print("Stopped: " .. tostring(message))
end
