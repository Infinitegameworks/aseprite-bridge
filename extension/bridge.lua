-- Aseprite Bridge -- an Aseprite extension that lets an external process drive a
-- live GUI instance (open files, run Lua) over a simple file queue.
--
-- It is COMPLETELY INERT unless launched in bridge mode: init() returns early
-- unless the env var ASEPRITE_BRIDGE=1 is set (which bridge.ps1 does). So normal
-- Aseprite sessions never touch the filesystem or see a security prompt.
--
-- Protocol (queue dir defaults to %USERPROFILE%/.aseprite-bridge):
--   cmd/<seq>.cmd : line 1 = op ("open" | "run" | "ping"), rest = argument
--   res/<seq>.res : line 1 = "OK" | "ERR",                 rest = output
-- Files are written via a .tmp + rename so the reader never sees a partial file.

local POLL_INTERVAL = 0.15
local timer = nil
local base, cmddir, resdir

local function readFile(path)
  local f = io.open(path, "r"); if not f then return nil end
  local c = f:read("a"); f:close(); return c
end

local function writeFileAtomic(path, body)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w"); if not f then return end
  f:write(body); f:close()
  os.remove(path)
  os.rename(tmp, path)
end

local function execCommand(op, arg)
  if op == "open" then
    local spr = app.open(arg)
    if spr then return true, "opened " .. app.fs.fileName(arg) end
    return false, "could not open " .. tostring(arg)
  elseif op == "run" then
    local chunk, err = load(arg, "bridge-run", "t")
    if not chunk then return false, "compile error: " .. tostring(err) end
    local ok, res = pcall(chunk)
    if ok then return true, (res ~= nil and tostring(res) or "ok") end
    return false, tostring(res)
  elseif op == "ping" then
    local spr = app.activeSprite
    return true, "pong activeSprite=" .. (spr and app.fs.fileName(spr.filename or "(unsaved)") or "none")
  end
  return false, "unknown op: " .. tostring(op)
end

local function poll()
  local files = app.fs.listFiles(cmddir)
  if not files then return end
  table.sort(files)
  for _, fname in ipairs(files) do
    if fname:sub(-4) == ".cmd" then
      local cmdpath = app.fs.joinPath(cmddir, fname)
      local content = readFile(cmdpath)
      -- Remove the command BEFORE executing: a "run" that opens a modal dialog
      -- blocks here until dismissed, and we must not reprocess it on resume.
      os.remove(cmdpath)
      if content then
        local nl = content:find("\n", 1, true)
        local op = (nl and content:sub(1, nl - 1) or content):gsub("%s+$", "")
        local arg = nl and content:sub(nl + 1) or ""
        local ok, out = execCommand(op, arg)
        local seq = fname:sub(1, -5)
        writeFileAtomic(app.fs.joinPath(resdir, seq .. ".res"), (ok and "OK\n" or "ERR\n") .. tostring(out))
      end
    end
  end
end

function init(plugin)
  if os.getenv("ASEPRITE_BRIDGE") ~= "1" then return end  -- inert in normal use
  base = os.getenv("ASEPRITE_BRIDGE_DIR")
  if not base or base == "" then
    base = (os.getenv("USERPROFILE") or os.getenv("HOME") or ".") .. "/.aseprite-bridge"
  end
  cmddir = app.fs.joinPath(base, "cmd")
  resdir = app.fs.joinPath(base, "res")
  app.fs.makeDirectory(base)
  app.fs.makeDirectory(cmddir)
  app.fs.makeDirectory(resdir)
  writeFileAtomic(app.fs.joinPath(base, "ready"), "1")
  timer = Timer{ interval = POLL_INTERVAL, ontick = function() pcall(poll) end }
  timer:start()
end

function exit(plugin)
  if timer then timer:stop() end
end
