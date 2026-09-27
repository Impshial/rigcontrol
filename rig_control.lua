-- Touchscreen movement controls for ComputerCraft on Minecraft 1.6.4.
-- Run: rig_control.lua [monitor side or wired peripheral name]
-- This complete program can also be saved as /startup.
-- Use a joined wall of Advanced Monitors, at least 2 blocks by 2 blocks.
-- Buttons and arrows expand to fit larger walls, including 3 by 3.
-- Directions refer to the computer's own faces. RedNet colour channels
-- are configured on the cables, not in this program.

local args = { ... }
local PULSE_TIME = 0.5
-- Absolute path so recovery also works when this program is named startup.
local STATE_FILE = "/rig_control.state"
local delays = { front = 6, back = 6, left = 2, right = 2 }
-- These delays are OFF time after each pulse in Lock mode.
local sides = { "front", "back", "left", "right" }
local C = colors

local monitor, monitorName
local width, height, originX, originY
local guiScale = 1
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
    file.writeLine("rig-control-v1")
    file.writeLine(active or "idle")
    file.close()
    if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
    fs.move(temporary, STATE_FILE)
end

local function loadState()
    if not fs.exists(STATE_FILE) then return end
    local file = fs.open(STATE_FILE, "r")
    if not file then error("Cannot read saved Auto state.", 0) end
    local version, direction = file.readLine(), file.readLine()
    local extra = file.readLine()
    file.close()
    if version ~= "rig-control-v1" or extra ~= nil or
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

local function guiX(x)
    return originX + math.floor(x * guiScale)
end

local function guiY(y)
    return originY + math.floor(y * guiScale)
end

local function updateLayout()
    width, height = monitor.getSize()
    layoutOK = width >= 29 and height >= 24
    buttons, lockButton = {}, nil
    if not layoutOK then return end
    -- Scale the whole arrangement uniformly, with matching click areas.
    guiScale = math.min(width / 29, height / 24)
    originX = math.floor((width - math.floor(29 * guiScale)) / 2) + 1
    originY = math.floor((height - math.floor(24 * guiScale)) / 2) + 1
    lockButton = {
        x = guiX(7), y = guiY(0),
        w = guiX(22) - guiX(7), h = guiY(3) - guiY(0)
    }
    buttons = {
        { side = "front", gx = 10, gy = 4 },
        { side = "left",  gx = 0,  gy = 10 },
        { side = "right", gx = 20, gy = 10 },
        { side = "back",  gx = 10, gy = 16 }
    }
    for _, button in ipairs(buttons) do
        button.x, button.y = guiX(button.gx), guiY(button.gy)
        button.w = guiX(button.gx + 9) - button.x
        button.h = guiY(button.gy + 6) - button.y
        button.bodyH = guiY(button.gy + 5) - button.y
        local labelTop = guiY(button.gy + 5)
        button.labelY = labelTop +
            math.floor((guiY(button.gy + 6) - labelTop - 1) / 2)
    end
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
    fill(lockButton.x, lockButton.y, lockButton.w, lockButton.h, lockColor)
    local label = locked and "Auto" or "Manual"
    writeAt(lockButton.x + math.floor((lockButton.w - #label) / 2),
            lockButton.y + math.floor(lockButton.h / 2), label,
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
        fill(button.x, button.y, button.w, button.bodyH, background)
        for row, pattern in ipairs(shapes[button.side]) do
            for col = 1, #pattern do
                if string.sub(pattern, col, col) == "#" then
                    local x = guiX(button.gx + 1 + col)
                    local y = guiY(button.gy + row - 1)
                    fill(x, y, guiX(button.gx + 2 + col) - x,
                         guiY(button.gy + row) - y, arrow)
                end
            end
        end
        local name = string.upper(button.side) .. " " .. delays[button.side] .. "s"
        writeAt(button.x + math.floor((button.w - #name) / 2), button.labelY,
                name, labelColor, C.black)
    end

    centered(guiY(11), locked and "AUTO" or "MANUAL", C.lightGray)
    local state = pulseSide and "PULSE" or (active and "WAIT" or "READY")
    centered(guiY(13), state, active and C.lime or C.white)
    local hint = ""
    if locked then
        hint = active and "" or ""
    end
    centered(guiY(23), hint, C.lightGray)
end

local function startPulse(side)
    outputsOff()
    pulseSide = side
    redstone.setOutput(side, true)
    offTimer = os.startTimer(PULSE_TIME)
end

local function inside(x, y, box)
    return x >= box.x and x < box.x + box.w and
           y >= box.y and y < box.y + box.h
end

local function handleTouch(x, y)
    if not layoutOK then return end
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
                    return -- The other three arrows are disabled.
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
            local newWidth, newHeight = monitor.getSize()
            -- fitMonitor queues resize events while selecting its scale.
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
    print("Stopped. All four outputs are off.")
else
    print("Stopped: " .. tostring(message))
end
if not cleared then
    print("Could not clear saved Auto state: " .. tostring(clearError))
    print("Delete " .. STATE_FILE .. " before restarting.")
end
