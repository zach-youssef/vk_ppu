-- Mesen 2 dump script for SNES and PC Engine (see README.md in this directory).
--
-- It dumps one frame: the video memory as it was when the frame's first displayed line started,
-- one row of registers per line, and the frame Mesen rendered, as a PNG. The console is detected from the
-- loaded ROM. It is one self-contained file so that it can be opened on its own in Mesen's
-- script window.
--
-- Environment (needs Script -> Settings -> "Allow access to I/O and OS functions", or
-- --debug.scriptWindow.allowIoOsAccess=true on the command line):
--   PPU_DUMP_OUT    output directory. When set, the script runs headless: it stops the emulator
--                   when done, with exit code 0 on success and 1 on failure. When unset (script
--                   window), it writes to Mesen's script data folder and leaves the game running.
--   PPU_DUMP_FRAME  which frame to dump, counted from 1 at the first frame that starts after the
--                   script (or the savestate) loads. Default 1.
--   PPU_DUMP_STATE  a Mesen savestate (.mss) to load before counting frames. Optional.
--
-- Running it from the script window is untested so far (see README.md for its hazards).

-- Empty variables count as unset.
local function env(name)
  local v = os and os.getenv(name)
  if v == "" then
    return nil
  end
  return v
end

local HEADLESS_OUT = env("PPU_DUMP_OUT")

local function fail(message)
  error({ dumpError = message }, 0)
end

local function errorText(err)
  if type(err) == "table" and err.dumpError then
    return err.dumpError
  end
  return tostring(err)
end

local finished = false

local function finish(ok, message)
  if finished then
    return
  end
  finished = true
  local text = (ok and "ppu dump: " or "ppu dump failed: ") .. message
  emu.log(text)
  if io and io.stderr then
    io.stderr:write(text, "\n")
  end
  if HEADLESS_OUT then
    emu.stop(ok and 0 or 1)
  else
    emu.displayMessage("Dump", text)
  end
end

-- Runs a callback body, turning any error into a failed dump.
local function guarded(fn)
  return function(...)
    if finished then
      return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
      finish(false, errorText(err))
    end
  end
end

---------------------------------------------------------------------------------------------
-- PNG writer (8-bit RGB, stored deflate blocks: no compression, but no dependencies either).

local crcTable = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c & 1 == 1 then
      c = 0xEDB88320 ~ (c >> 1)
    else
      c = c >> 1
    end
  end
  crcTable[i] = c
end

local function crc32(s)
  local crc = 0xFFFFFFFF
  for i = 1, #s do
    crc = crcTable[(crc ~ s:byte(i)) & 0xFF] ~ (crc >> 8)
  end
  return crc ~ 0xFFFFFFFF
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return (b << 16) | a
end

local function pngChunk(kind, data)
  return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", crc32(kind .. data))
end

-- pixels: a 0-based array of 0xRRGGBB values, read as rows of `stride` starting at `first`.
local function encodePng(pixels, first, stride, width, height)
  local rows = {}
  local bytes = {}
  for y = 0, height - 1 do
    local base = first + y * stride
    for x = 0, width - 1 do
      local c = pixels[base + x]
      bytes[x * 3 + 1] = (c >> 16) & 0xFF
      bytes[x * 3 + 2] = (c >> 8) & 0xFF
      bytes[x * 3 + 3] = c & 0xFF
    end
    rows[y + 1] = "\0" .. string.char(table.unpack(bytes, 1, width * 3))
  end
  local raw = table.concat(rows)

  local blocks = { "\x78\x01" }
  local pos = 1
  repeat
    local len = math.min(65535, #raw - pos + 1)
    local final = (pos + len > #raw) and 1 or 0
    blocks[#blocks + 1] = string.pack("<BI2I2", final, len, len ~ 0xFFFF) .. raw:sub(pos, pos + len - 1)
    pos = pos + len
  until pos > #raw
  blocks[#blocks + 1] = string.pack(">I4", adler32(raw))

  return "\x89PNG\r\n\x1a\n"
    .. pngChunk("IHDR", string.pack(">I4I4BBBBB", width, height, 8, 2, 0, 0, 0))
    .. pngChunk("IDAT", table.concat(blocks))
    .. pngChunk("IEND", "")
end

---------------------------------------------------------------------------------------------
-- Helpers.

local function readMemory(memType, expectedSize)
  local size = emu.getMemorySize(memType)
  if size ~= expectedSize then
    fail(string.format("memory type %d is %d bytes, expected %d", memType, size, expectedSize))
  end
  local chunks = {}
  local bytes = {}
  for base = 0, size - 1, 4096 do
    local n = math.min(4096, size - base)
    for i = 0, n - 1 do
      bytes[i + 1] = emu.read(base + i, memType)
    end
    chunks[#chunks + 1] = string.char(table.unpack(bytes, 1, n))
  end
  return table.concat(chunks)
end

local function countDifferences(a, b)
  local n = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then
      n = n + 1
    end
  end
  return n
end

local function writeFile(dir, name, data)
  local path = dir .. "/" .. name
  local f, err = io.open(path, "wb")
  if not f then
    fail("can't write " .. path .. ": " .. tostring(err))
  end
  f:write(data)
  f:close()
end

local function bit(v, shift)
  return (v and 1 or 0) << shift
end

-- getState() leaves out arrays over 64 elements and enums, and every value is flat ("a.b[0].c").
local function get(state, key)
  local v = state[key]
  if v == nil then
    fail("emu.getState() has no " .. key)
  end
  return v
end

---------------------------------------------------------------------------------------------
-- SNES.

-- One row per displayed line: these registers in this order, each a little-endian uint16,
-- re-encoded in the register's write format from Mesen's decoded state (see README.md).
local SNES_REGISTERS = {
  "INIDISP", "OBSEL", "OAMADD", "BGMODE", "MOSAIC",
  "BG1SC", "BG2SC", "BG3SC", "BG4SC", "BG12NBA", "BG34NBA",
  "BG1HOFS", "BG1VOFS", "BG2HOFS", "BG2VOFS", "BG3HOFS", "BG3VOFS", "BG4HOFS", "BG4VOFS",
  "M7SEL", "M7A", "M7B", "M7C", "M7D", "M7X", "M7Y", "M7HOFS", "M7VOFS",
  "W12SEL", "W34SEL", "WOBJSEL", "WH0", "WH1", "WH2", "WH3", "WBGLOG", "WOBJLOG",
  "TM", "TS", "TMW", "TSW", "CGWSEL", "CGADSUB", "COLDATA", "SETINI",
}

-- getState() has no window mask logic or colour window modes (they are enums), so the script
-- keeps the last value written to $212A, $212B and $2130.
local snesShadow = { [0x212A] = 0, [0x212B] = 0, [0x2130] = 0 }
local snesShadowSeen = { [0x212A] = false, [0x212B] = false, [0x2130] = false }

local function snesRegisterRow(s)
  local function p(k) return get(s, "ppu." .. k) end
  local function layer(i, k) return get(s, string.format("ppu.layers[%d].%s", i, k)) end
  local function windowSel(first)
    local v = 0
    for j = 0, 1 do
      local l = first + j
      local shift = j * 4
      v = v | bit(get(s, string.format("ppu.window[0].invertedLayers[%d]", l)), shift)
            | bit(get(s, string.format("ppu.window[0].activeLayers[%d]", l)), shift + 1)
            | bit(get(s, string.format("ppu.window[1].invertedLayers[%d]", l)), shift + 2)
            | bit(get(s, string.format("ppu.window[1].activeLayers[%d]", l)), shift + 3)
    end
    return v
  end
  local function maskBits(kind)
    local v = 0
    for i = 0, 4 do
      v = v | bit(get(s, string.format("ppu.%s[%d]", kind, i)), i)
    end
    return v
  end
  local function sc(i)
    return ((layer(i, "tilemapAddress") >> 8) & 0x7C) | bit(layer(i, "doubleHeight"), 1) | bit(layer(i, "doubleWidth"), 0)
  end
  local bgmode = p("bgMode") | bit(p("mode1Bg3Priority"), 3)
  for i = 0, 3 do
    bgmode = bgmode | bit(layer(i, "largeTiles"), 4 + i)
  end
  local mosaicSize = p("mosaicSize")
  local row = {
    bit(p("forcedBlank"), 7) | p("screenBrightness"),
    (p("oamMode") << 5) | (((p("oamAddressOffset") >> 12) - 1) << 3) | (p("oamBaseAddress") >> 13),
    p("oamRamAddress") | bit(p("enableOamPriority"), 15),
    bgmode,
    (((mosaicSize > 0) and (mosaicSize - 1) or 0) << 4) | p("mosaicEnabled"),
    sc(0), sc(1), sc(2), sc(3),
    (layer(0, "chrAddress") >> 12) | ((layer(1, "chrAddress") >> 12) << 4),
    (layer(2, "chrAddress") >> 12) | ((layer(3, "chrAddress") >> 12) << 4),
    layer(0, "hscroll"), layer(0, "vscroll"), layer(1, "hscroll"), layer(1, "vscroll"),
    layer(2, "hscroll"), layer(2, "vscroll"), layer(3, "hscroll"), layer(3, "vscroll"),
    bit(p("mode7.largeMap"), 7) | bit(p("mode7.fillWithTile0"), 6) | bit(p("mode7.verticalMirroring"), 1) | bit(p("mode7.horizontalMirroring"), 0),
    p("mode7.matrix[0]") & 0xFFFF, p("mode7.matrix[1]") & 0xFFFF, p("mode7.matrix[2]") & 0xFFFF, p("mode7.matrix[3]") & 0xFFFF,
    p("mode7.centerX") & 0xFFFF, p("mode7.centerY") & 0xFFFF, p("mode7.hscroll") & 0xFFFF, p("mode7.vscroll") & 0xFFFF,
    windowSel(0), windowSel(2), windowSel(4),
    p("window[0].left"), p("window[0].right"), p("window[1].left"), p("window[1].right"),
    snesShadow[0x212A], snesShadow[0x212B] & 0x0F,
    p("mainScreenLayers"), p("subScreenLayers"), maskBits("windowMaskMain"), maskBits("windowMaskSub"),
    (snesShadow[0x2130] & 0xF0) | bit(p("colorMathAddSubscreen"), 1) | bit(p("directColorMode"), 0),
    bit(p("colorMathSubtractMode"), 7) | bit(p("colorMathHalveResult"), 6) | p("colorMathEnabled"),
    p("fixedColor"),
    bit(p("extBgEnabled"), 6) | bit(p("hiResMode"), 3) | bit(p("overscanMode"), 2) | bit(p("objInterlace"), 1) | bit(p("screenInterlace"), 0),
  }
  assert(#row == #SNES_REGISTERS)
  return string.pack("<" .. string.rep("I2", #row), table.unpack(row))
end

local SNES = {
  name = "SNES",
  memories = {
    { file = "vram.bin", memType = emu.memType.snesVideoRam, size = 65536 },
    { file = "cgram.bin", memType = emu.memType.snesCgRam, size = 512 },
    { file = "oam.bin", memType = emu.memType.snesSpriteRam, size = 544 },
  },
  rowSize = #SNES_REGISTERS * 2,
  -- Rows are scanlines 1..224 (1..239 with SETINI overscan), sampled at H = 23 dots, after
  -- every write that reaches the line's first pixel (Mesen draws pixel x once H > x + 22).
  sampleClock = 23 * 4,
  stepToSample = function() emu.step(23, emu.stepType.ppuStep) end,
  scanline = function(s) return get(s, "ppu.scanline") end,
  hclock = function(s) return get(s, "memoryManager.hClock") end,
  -- Whether the line whose start state this is shows the picture (memory is dumped from the first
  -- one, after any upload the game makes in vertical or forced blank).
  displayed = function(s) return not get(s, "ppu.forcedBlank") end,
  -- Forced blank can return mid-frame (to upload), so the display only ends at Mesen's frame
  -- end, which is the start of vertical blank.
  displayEnded = function() return false end,
  setup = function(state)
    -- The frame's height comes from SETINI's overscan bit at the start of the frame.
    local height = get(state, "ppu.overscanMode") and 239 or 224
    return { firstScanline = 1, rowCount = height }
  end,
  row = snesRegisterRow,
  screenshot = function(pixels, count, frame)
    if count ~= 256 * 239 then
      fail("SNES high-resolution or interlaced output (" .. count .. " pixels) isn't supported")
    end
    -- Mesen's buffer is 256x239: without overscan, scanline 1 is row 7.
    local firstRow = frame.rowCount == 239 and 0 or 7
    return encodePng(pixels, firstRow * 256, 256, 256, frame.rowCount), 256, frame.rowCount
  end,
  warnings = function()
    local missing = {}
    for _, addr in ipairs({ 0x212A, 0x212B, 0x2130 }) do
      if not snesShadowSeen[addr] then
        missing[#missing + 1] = string.format("$%04X", addr)
      end
    end
    if #missing > 0 then
      return { "no write to " .. table.concat(missing, ", ") .. " was seen since the script started; " ..
        "WBGLOG, WOBJLOG and CGWSEL bits 4-7 are 0 there (Mesen's getState() doesn't expose them)" }
    end
    return {}
  end,
}

---------------------------------------------------------------------------------------------
-- PC Engine.

local PCE_REGISTERS = {
  "CR", "RCR", "BXR", "BYR", "MWR", "HSR", "HDR", "VPR", "VDW", "VCR",
  "SCROLL_X", "SCROLL_Y", "FLAGS", "LINE", "MWR_LATCHED", "VCE_CR",
}

local function pceMwr(s, prefix)
  local columns = get(s, prefix .. "columnCount")
  local columnCode = columns == 32 and 0 or (columns == 64 and 1 or 2)
  return get(s, prefix .. "vramAccessMode") | (get(s, prefix .. "spriteAccessMode") << 2)
    | (columnCode << 4) | bit(get(s, prefix .. "rowCount") == 64, 6) | bit(get(s, prefix .. "cgMode"), 7)
end

-- start: the state at H = 0 of the same line. The VDC's line counter steps near the end of the
-- line's display, so the row takes the line's counter (and whether the line is displayed) from there.
local function pceRegisterRow(s, start)
  local function v(k) return get(s, "vdc." .. k) end
  -- Mesen keeps EX (bits 4-5) as two flags, so EX = 3 reads as 2. TE and DR (bits 8-10) aren't kept.
  local outputSelect = v("outputVerticalSync") and 2 or (v("outputHorizontalSync") and 1 or 0)
  local increment = v("vramAddrIncrement")
  local incrementCode = increment == 1 and 0 or (increment == 32 and 1 or (increment == 64 and 2 or 3))
  local cr = bit(v("enableCollisionIrq"), 0) | bit(v("enableOverflowIrq"), 1) | bit(v("enableScanlineIrq"), 2)
    | bit(v("enableVerticalBlankIrq"), 3) | (outputSelect << 4) | bit(v("nextSpritesEnabled"), 6)
    | bit(v("nextBackgroundEnabled"), 7) | (incrementCode << 11)
  local line = get(start, "vdc.rcrCounter")
  local active = line <= get(start, "vdc.hvLatch.vertDisplayWidth")
  local flags = bit(v("backgroundEnabled"), 0) | bit(v("spritesEnabled"), 1) | bit(v("burstModeEnabled"), 2) | bit(active, 3)
  local divider = get(s, "vce.clockDivider")
  local vceCr = (divider == 4 and 0 or (divider == 3 and 1 or 2)) | bit(get(s, "vce.scanlineCount") == 263, 2) | bit(get(s, "vce.grayscale"), 7)
  local row = {
    cr,
    v("rasterCompareRegister"),
    v("hvReg.bgScrollX"),
    v("hvReg.bgScrollY"),
    pceMwr(s, "vdc.hvReg."),
    v("hvReg.horizSyncWidth") | (v("hvReg.horizDisplayStart") << 8),
    v("hvReg.horizDisplayWidth") | (v("hvReg.horizDisplayEnd") << 8),
    v("hvReg.vertSyncWidth") | (v("hvReg.vertDisplayStart") << 8),
    v("hvReg.vertDisplayWidth"),
    v("hvReg.vertEndPosVcr"),
    v("hvLatch.bgScrollX"),
    v("hvLatch.bgScrollY"),
    flags,
    line,
    pceMwr(s, "vdc.hvLatch."),
    vceCr,
  }
  assert(#row == #PCE_REGISTERS)
  return string.pack("<" .. string.rep("I2", #row), table.unpack(row))
end

local PCE_ROWS = 242      -- Mesen's output rows: VDC scanlines 14..255
local PCE_BORDER = 18     -- Mesen's border on each side, in 5.37 MHz pixels

local PCE = {
  name = "PC Engine",
  memories = {
    { file = "vram.bin", memType = emu.memType.pceVideoRam, size = 65536 },
    { file = "palette.bin", memType = emu.memType.pcePaletteRam, size = 1024 },
    { file = "sat.bin", memType = emu.memType.pceSpriteRam, size = 512 },
  },
  rowSize = #PCE_REGISTERS * 2,
  -- Rows are sampled at the end of each line (H = 1362 master clocks), after the line is
  -- drawn, when the VDC's latched scroll still holds the values that line used.
  sampleClock = 1362,
  stepToSample = function() emu.step(1362, emu.stepType.ppuStep) end,
  scanline = function(s) return get(s, "vdc.scanline") end,
  hclock = function(s) return get(s, "vdc.hclock") end,
  displayed = function(s) return get(s, "vdc.rcrCounter") <= get(s, "vdc.hvLatch.vertDisplayWidth") end,
  -- Called only after a displayed line: the first line that isn't displayed is in vertical
  -- blank, which starts before Mesen's frame end (scanline 256) when the display ends earlier.
  displayEnded = function(s) return get(s, "vdc.rcrCounter") > get(s, "vdc.hvLatch.vertDisplayWidth") end,
  -- On a SuperGrafx only the first VDC is dumped.
  setup = function() return { firstScanline = 14, rowCount = PCE_ROWS } end,
  row = pceRegisterRow,
  screenshot = function(pixels, count)
    if count % PCE_ROWS ~= 0 then
      fail("unexpected PC Engine frame size (" .. count .. " pixels)")
    end
    local width = count // PCE_ROWS
    local divider = ({ [292] = 4, [389] = 3, [584] = 2 })[width]
    if not divider then
      fail("PC Engine frame is " .. width .. " pixels wide: a frame that mixes dot clocks isn't supported")
    end
    local border = PCE_BORDER * 4 // divider
    local outWidth = width - 2 * border
    return encodePng(pixels, border, width, outWidth, PCE_ROWS), outWidth, PCE_ROWS
  end,
  warnings = function() return {} end,
}

---------------------------------------------------------------------------------------------
-- Main.

local function start()
  if not (io and os) then
    fail("the script needs I/O access: enable Script -> Settings -> \"Allow access to I/O and OS functions\"")
  end

  local consoleType = emu.getState().consoleType
  local console = ({ Snes = SNES, PcEngine = PCE })[consoleType]
  if not console then
    fail("unsupported console " .. tostring(consoleType) .. " (SNES and PC Engine only)")
  end

  local outDir = HEADLESS_OUT or emu.getScriptDataFolder()
  local targetFrame = tonumber(env("PPU_DUMP_FRAME") or "1")
  if not targetFrame or targetFrame < 1 or targetFrame % 1 ~= 0 then
    fail("PPU_DUMP_FRAME must be a whole number >= 1")
  end
  local statePath = env("PPU_DUMP_STATE")

  if console == SNES then
    emu.addMemoryCallback(guarded(function(address, value)
      local reg = address & 0xFFFF
      if snesShadow[reg] then
        snesShadow[reg] = value
        snesShadowSeen[reg] = true
      end
    end), emu.callbackType.write, 0x212A, 0x2130, emu.cpuType.snes, emu.memType.snesRegister)
  end

  local frames = 0
  local counting = statePath == nil
  local frame = nil        -- the frame being dumped
  local rows = {}
  local memory = nil       -- the memory snapshot, taken at the first displayed line
  local changes = nil      -- warnings about memory that changed during the displayed lines

  if statePath then
    local f, err = io.open(statePath, "rb")
    if not f then
      fail("can't read PPU_DUMP_STATE " .. statePath .. ": " .. tostring(err))
    end
    local data = f:read("a")
    f:close()
    -- Savestates can only be loaded from an exec callback on the main CPU.
    local ref
    ref = emu.addMemoryCallback(guarded(function()
      emu.removeMemoryCallback(ref, emu.callbackType.exec, 0, 0xFFFFFF)
      if not emu.loadSavestate(data) then
        fail("Mesen couldn't load the savestate " .. statePath)
      end
      counting = true
    end), emu.callbackType.exec, 0, 0xFFFFFF)
  end

  local function snapshot()
    memory = {}
    for _, m in ipairs(console.memories) do
      memory[m.file] = readMemory(m.memType, m.size)
    end
  end

  -- Compares memory with the snapshot at the end of the displayed lines, so that the game's
  -- uploads for the next frame, in vertical blank, don't count.
  local function compare()
    changes = {}
    for _, m in ipairs(console.memories) do
      local changed = countDifferences(memory[m.file], readMemory(m.memType, m.size))
      if changed > 0 then
        changes[#changes + 1] = string.format("%s changed in %d bytes after the first displayed line; the dump holds its state from the start of that line", m.file, changed)
      end
    end
  end

  emu.addEventCallback(guarded(function()
    if not counting or frame then
      return
    end
    frames = frames + 1
    if frames < targetFrame then
      return
    end
    local state = emu.getState()
    frame = console.setup(state)
    frame.number = get(state, "frameCount")
    emu.step(frame.firstScanline, emu.stepType.specificScanline)
  end), emu.eventType.startFrame)

  -- Each break is either the start of a line (go to the sample point) or the sample point
  -- (record the row, then go to the next line).
  emu.addEventCallback(guarded(function()
    if not frame or frame.sampled then
      return
    end
    local state = emu.getState()
    local scanline = console.scanline(state)
    local hclock = console.hclock(state)
    local expected = frame.firstScanline + #rows
    if scanline ~= expected then
      fail(string.format("stepping lost its place: at scanline %d, expected %d", scanline, expected))
    end
    if hclock == 0 then
      frame.lineStart = state
      if not memory then
        if console.displayed(state) then
          snapshot()
        end
      elseif not changes and console.displayEnded(state) then
        compare()
      end
      console.stepToSample()
    elseif hclock == console.sampleClock and frame.lineStart then
      rows[#rows + 1] = console.row(state, frame.lineStart)
      frame.lineStart = nil
      if #rows == frame.rowCount then
        frame.sampled = true
        emu.resume()
      else
        emu.step(scanline + 1, emu.stepType.specificScanline)
      end
    else
      fail(string.format("stepping lost its place: at H clock %d on scanline %d", hclock, scanline))
    end
  end), emu.eventType.codeBreak)

  emu.addEventCallback(guarded(function()
    if not frame then
      return
    end
    if not frame.sampled then
      fail("the frame ended before every line was sampled (" .. #rows .. " of " .. frame.rowCount .. ")")
    end
    local warnings = console.warnings()
    local files = {}
    if memory then
      if not changes then
        compare()
      end
      for _, w in ipairs(changes) do
        warnings[#warnings + 1] = w
      end
    else
      snapshot()
      warnings[#warnings + 1] = "no line of the frame was displayed; memory is dumped as of the frame's end"
    end
    for _, m in ipairs(console.memories) do
      files[m.file] = memory[m.file]
    end
    files["registers.bin"] = table.concat(rows)

    local buffer = emu.getScreenBuffer()
    local count = #buffer
    -- emu.getScreenBuffer() is 1-based; encodePng reads it 0-based.
    local pixels = setmetatable({}, { __index = function(_, i) return buffer[i + 1] end })
    local png, width, height = console.screenshot(pixels, count, frame)
    files["screenshot.png"] = png

    local info = {
      "console=" .. console.name,
      "frame=" .. frame.number,
      "width=" .. width,
      "height=" .. height,
      "rows=" .. #rows,
      "rowBytes=" .. console.rowSize,
    }
    for _, w in ipairs(warnings) do
      info[#info + 1] = "warning=" .. w
      emu.log("ppu dump warning: " .. w)
      if io.stderr then
        io.stderr:write("ppu dump warning: ", w, "\n")
      end
    end
    files["info.txt"] = table.concat(info, "\n") .. "\n"

    for name, data in pairs(files) do
      writeFile(outDir, name, data)
    end
    finish(true, string.format("%s frame %d written to %s", console.name, frame.number, outDir))
  end), emu.eventType.endFrame)

  emu.log("ppu dump: waiting for frame " .. targetFrame .. (statePath and " after loading " .. statePath or ""))
end

local ok, err = pcall(start)
if not ok then
  finish(false, errorText(err))
end
