-- sound-menu.lua — replacement for Apple's Sound menu bar item that leaves out virtual devices
-- (BlackHole, Zoom). They stay installed and usable in every app; they just aren't in this list. (Nate 2026-11-07)
-- AirPods controls (Listening Mode, Spatial Audio, Conversation Awareness) have no public API, so they are
-- read and set by driving Control Center's Sound module through accessibility. Their checkmarks are
-- refreshed when AirPods become the output and after each click here; a stem squeeze shows up on the next refresh.
local M = {}
local ax = require("hs.axuielement")
local item = hs.menubar.new(true, "soundMenu")
local dir = os.getenv("HOME") .. "/.hammerspoon/icons/"
local function icon(f, px) local i = hs.image.imageFromPath(dir .. f .. "@2x.png"); i:size({w = px, h = px}); i:template(true); return i end
local I = {}
for _, n in ipairs({"sound-0","sound-1","sound-2","sound-3","sound-mute","sound-airpods",
  "mode-transparency","mode-adaptive","mode-nc","mode-spatial","mode-conversation"}) do
  I[n] = icon(n, n:find("^mode") and 22 or 20)   -- menu bar 20pt, menu rows 22pt
end

-- icon per output device: brand logo when we have one, else a symbol for the kind of device
local D = {}
for _, n in ipairs({"dev-builtin","dev-airpods","dev-headphones","dev-speaker","dev-airplay","dev-display","dev-ua"}) do D[n] = icon(n, 20) end
local function deviceIcon(d)
  local n, t = d:name():lower(), d:transportType()
  if n:find("apollo") or n:find("universal audio") then return D["dev-ua"] end
  if t == "Built-in" then return D["dev-builtin"] end
  if n:find("pods") then return D["dev-airpods"] end
  if n:find("huawei") or n:find("freebuds") or t == "Bluetooth" then return D["dev-headphones"] end
  if t == "AirPlay" then return D["dev-airplay"] end
  if t == "HDMI" or t == "DisplayPort" then return D["dev-display"] end
  return D["dev-speaker"]
end

-- icon per AirPods option, matched on section + title the way Apple's menu shows them
local optionIcon = {
  ["Listening Mode"] = {Transparency = I["mode-transparency"], Adaptive = I["mode-adaptive"],
    ["Noise Cancellation"] = I["mode-nc"], Off = I["mode-nc"]},
  ["Spatial Audio"] = I["mode-spatial"],
  ["Conversation Awareness"] = I["mode-conversation"],
}

local airpods = {}   -- [device name] = { {section=, title=, on=} ... } as last read from Control Center

local function hidden(d) return d:transportType() == "Virtual" end
local function isAirPods(d)
  return d and d:transportType() == "Bluetooth" and (airpods[d:name()] ~= nil or d:name():lower():find("pods") ~= nil)
end

local function render()
  local d = hs.audiodevice.defaultOutputDevice()
  if isAirPods(d) then item:setIcon(I["sound-airpods"], true)
  else
    local v, muted = d and d:outputVolume() or 0, d and d:outputMuted()
    local n = (muted or v == 0) and "sound-mute" or v < 34 and "sound-1" or v < 67 and "sound-2" or "sound-3"
    item:setIcon(I[n], true)
  end
  item:setTooltip(d and ("Sound: " .. d:name()) or "Sound")
end

-- Control Center plumbing -----------------------------------------------------------------------------
local function ccApp() return ax.applicationElement(hs.application.find("com.apple.controlcenter")) end
local function extra(e, id)
  local bar = e:attributeValue("AXExtrasMenuBar")
  for _, c in ipairs(bar and bar:attributeValue("AXChildren") or {}) do
    if c:attributeValue("AXIdentifier") == id then return c end
  end
end
local function find(root, test, depth)
  depth = depth or 0
  if depth > 8 then return end
  for _, c in ipairs(root:attributeValue("AXChildren") or {}) do
    if test(c) then return c end
    local r = find(c, test, depth + 1); if r then return r end
  end
end

-- Opens the Sound device list (Apple's Sound item if it's in the menu bar, else Control Center → Sound),
-- runs fn(rows) on the AirPods rows, then closes it again.
local function withSoundPanel(devName, fn)
  local e = ccApp(); if not e then return end
  local opener = extra(e, "com.apple.menuextra.sound")
  if opener then opener:performAction("AXPress")
  else
    opener = extra(e, "com.apple.menuextra.controlcenter"); if not opener then return end
    opener:performAction("AXPress"); hs.timer.usleep(450000)
    local btn
    for _, w in ipairs(e:attributeValue("AXWindows") or {}) do
      btn = btn or find(w, function(c) return c:attributeValue("AXIdentifier") == "controlcenter-volume" end)
    end
    if not btn then opener:performAction("AXPress"); return end
    for _, a in ipairs(btn:actionNames() or {}) do
      if a:find("show details") then btn:performAction(a) end
    end
  end
  hs.timer.usleep(450000)
  local id = "sound-device-" .. devName
  local function rows()
    local list = {}
    for _, w in ipairs(e:attributeValue("AXWindows") or {}) do
      local area = find(w, function(c) return c:attributeValue("AXRole") == "AXScrollArea" end) or w
      for _, c in ipairs(area:attributeValue("AXChildren") or {}) do
        if c:attributeValue("AXIdentifier") == id then table.insert(list, c) end
      end
    end
    return list
  end
  local r = rows()
  for _, c in ipairs(r) do   -- AirPods options are collapsed under a disclosure triangle until expanded
    if c:attributeValue("AXRole") == "AXDisclosureTriangle" and c:attributeValue("AXValue") == 0 then
      c:performAction("AXPress"); hs.timer.usleep(300000); r = rows()
    end
  end
  local ok, err = pcall(fn, r, rows)
  if not ok then print("sound-menu: " .. tostring(err)) end
  opener:performAction("AXPress")   -- same item again closes the panel
end

local function readOptions(rowList)
  local opts, section = {}, nil
  for _, c in ipairs(rowList) do
    local role, title = c:attributeValue("AXRole"), c:attributeValue("AXDescription") or c:attributeValue("AXTitle")
    if role == "AXHeading" then section = title
    elseif role == "AXCheckBox" and section then
      table.insert(opts, {section = section, title = title, on = c:attributeValue("AXValue") == 1,
        enabled = c:attributeValue("AXEnabled") ~= false})
    end
  end
  return opts
end

local function refreshAirPods(name)
  withSoundPanel(name, function(r) airpods[name] = readOptions(r) end)
  render()
end

local function choose(name, section, title)
  withSoundPanel(name, function(r, rows)
    local cur = nil
    for _, c in ipairs(r) do
      local role, t = c:attributeValue("AXRole"), c:attributeValue("AXDescription") or c:attributeValue("AXTitle")
      if role == "AXHeading" then cur = t
      elseif role == "AXCheckBox" and cur == section and t == title then c:performAction("AXPress") end
    end
    hs.timer.usleep(350000)
    airpods[name] = readOptions(rows())
  end)
  render()
end

-- Menu ------------------------------------------------------------------------------------------------
local function menu()
  local d, out = hs.audiodevice.defaultOutputDevice(), {{title = "Output", disabled = true}}
  local devs = hs.audiodevice.allOutputDevices()
  table.sort(devs, function(a, b)   -- built-in speakers first, then the rest by name
    local ab, bb = a:transportType() == "Built-in", b:transportType() == "Built-in"
    if ab ~= bb then return ab end
    return a:name() < b:name()
  end)
  for _, dev in ipairs(devs) do
    if not hidden(dev) then
      table.insert(out, {title = dev:name(), image = deviceIcon(dev), checked = d and dev:uid() == d:uid(),
        fn = function() dev:setDefaultOutputDevice(); render() end})
    end
  end
  local opts = isAirPods(d) and airpods[d:name()]
  if opts then
    local section
    for _, o in ipairs(opts) do
      if o.section ~= section then
        section = o.section
        table.insert(out, {title = "-"}); table.insert(out, {title = section, disabled = true})
      end
      local ic = optionIcon[o.section]; if type(ic) == "table" then ic = ic[o.title] end
      local name, sec, t = d:name(), o.section, o.title
      table.insert(out, {title = o.title, image = ic, checked = o.on, disabled = not o.enabled or o.title == "Not Available",
        fn = function() choose(name, sec, t) end})
    end
  end
  table.insert(out, {title = "-"})
  table.insert(out, {title = "Sound Settings…", fn = function()
    hs.execute("open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'") end})
  return out
end

-- Popover --------------------------------------------------------------------------------------------
-- hs.menubar menus can't hold a live slider, so the click opens a small webview styled like Apple's
-- Sound menu: "Sound" + volume slider on top, then the same rows menu() builds (Nate 2026-11-07).
local uc = hs.webview.usercontent.new("sm")
local pop, rows, outside
local function hidePop()
  if outside then outside:stop(); outside = nil end
  if pop then pop:hide() end
end
local function esc(t) return (tostring(t):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function html()
  rows = menu()
  local d = hs.audiodevice.defaultOutputDevice()
  local vol = d and d:outputVolume() and math.floor(d:outputVolume() + 0.5) or 0
  if d and d:outputMuted() then vol = 0 end
  local body = {}
  for i, r in ipairs(rows) do
    if r.title == "-" then body[#body + 1] = '<div class="sep"></div>'
    elseif r.disabled and not r.fn then body[#body + 1] = '<div class="hdr">' .. esc(r.title) .. '</div>'
    else
      local img = r.image and ('<span class="ic' .. (r.checked and ' on' or '') .. '"><img src="' ..
        r.image:encodeAsURLString() .. '"></span>') or ''
      body[#body + 1] = string.format('<div class="row%s%s" onclick="go(%d)">%s<span class="t">%s</span>%s</div>',
        r.image and ' dev' or '', r.disabled and ' off' or '', i, img, esc(r.title),
        (r.checked and not r.image) and '<span class="ck">✓</span>' or '')
    end
  end
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;background:transparent;font:13px -apple-system,BlinkMacSystemFont;color:#fff;-webkit-user-select:none;cursor:default}
  .p{background:rgba(38,38,40,.94);border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:6px;box-sizing:border-box;height:100vh;overflow:hidden}
  .ttl{font-weight:600;padding:6px 10px 8px}
  .sl{display:flex;align-items:center;gap:8px;padding:0 10px 10px}
  input[type=range]{-webkit-appearance:none;flex:1;height:18px;margin:0;background:transparent;outline:none}
  input[type=range]::-webkit-slider-runnable-track{height:6px;border-radius:3px;
    background:linear-gradient(to right,#fff 0,#fff var(--v),rgba(255,255,255,.16) var(--v))}
  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:30px;height:18px;margin-top:-6px;border-radius:9px;
    background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.4)}
  .sl svg{width:16px;height:16px;fill:#fff;flex:none}
  .sep{height:1px;background:rgba(255,255,255,.12);margin:5px 10px}
  .hdr{color:rgba(255,255,255,.5);font-weight:600;font-size:12px;padding:4px 10px}
  .row{display:flex;align-items:center;gap:8px;padding:4px 10px;border-radius:6px;min-height:20px}
  .row:hover{background:rgba(255,255,255,.1)} .row.off{opacity:.4;pointer-events:none}
  .ic{width:26px;height:26px;border-radius:50%;background:rgba(255,255,255,.14);display:flex;align-items:center;justify-content:center}
  .ic.on{background:#0a84ff} .ic img{width:16px;height:16px;filter:invert(1)}
  .t{flex:1} .ck{font-size:12px}
  </style></head><body><div class="p"><div class="ttl">Sound</div>
  <div class="sl"><svg viewBox="0 0 16 16"><path d="M2 6h2.5L8 3v10L4.5 10H2z"/></svg>
  <input id="v" type="range" min="0" max="100" value="]] .. vol .. [[" style="--v:]] .. vol .. [[%">
  <svg viewBox="0 0 16 16" style="width:20px"><path d="M1 6h2.5L7 3v10L3.5 10H1z"/><path d="M9 5.5a3.5 3.5 0 0 1 0 5" stroke="#fff" stroke-width="1.3" fill="none" stroke-linecap="round"/><path d="M11 3.8a6 6 0 0 1 0 8.4" stroke="#fff" stroke-width="1.3" fill="none" stroke-linecap="round"/><path d="M13 2.2a8.5 8.5 0 0 1 0 11.6" stroke="#fff" stroke-width="1.3" fill="none" stroke-linecap="round"/></svg></div>
  ]] .. table.concat(body) .. [[</div><script>
  const v=document.getElementById('v'),post=m=>webkit.messageHandlers.sm.postMessage(m);
  v.addEventListener('input',()=>{v.style.setProperty('--v',v.value+'%');post({vol:+v.value})});
  let dragging=false;v.addEventListener('pointerdown',()=>dragging=true);addEventListener('pointerup',()=>dragging=false);
  function setV(n){if(dragging)return;v.value=n;v.style.setProperty('--v',n+'%')}
  function go(i){post({row:i})}
  document.addEventListener('keydown',e=>{if(e.key==='Escape')post({close:1})});
  </script></body></html>]]
end
local function rowsHeight()
  local h = 6 * 2 + 30 + 34
  for _, r in ipairs(rows) do
    h = h + (r.title == "-" and 11 or (r.disabled and not r.fn) and 23 or r.image and 34 or 28)
  end
  return h
end
uc:setCallback(function(m)
  local b = m.body
  if b.vol then
    local d = hs.audiodevice.defaultOutputDevice()
    if d then d:setOutputMuted(b.vol == 0); if b.vol > 0 then d:setOutputVolume(b.vol) end end
    render()
  elseif b.row then
    local r = rows and rows[math.floor(b.row)]
    hidePop()
    if r and r.fn then r.fn() end
  elseif b.close then hidePop() end
end)
local function showPop()
  if pop and pop:isVisible() then return hidePop() end
  local page = html()
  local f, w = item:frame(), 300
  local h = rowsHeight()
  local scr = hs.screen.mainScreen():frame()
  local x = math.max(scr.x + 6, math.min(f.x, scr.x + scr.w - w - 6))
  local rect = {x = x, y = f.y + f.h + 4, w = w, h = h}
  if not pop then
    pop = hs.webview.new(rect, {developerExtrasEnabled = false}, uc)
      :transparent(true):allowTextEntry(true):level(hs.drawing.windowLevels.popUpMenu)
      :windowStyle({"borderless", "nonactivating"}):shadow(true)
  end
  pop:frame(rect):html(page):show()
  outside = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown}, function(e)
    local p = e:location()
    local r = pop:frame()
    if not (p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h) then hidePop() end
    return false
  end):start()
end
item:setClickCallback(showPop)
-- keep the open slider on the system volume (volume keys, other apps)
function M.syncPop()
  if not (pop and pop:isVisible()) then return end
  local d = hs.audiodevice.defaultOutputDevice()
  local v = d and d:outputVolume() and math.floor(d:outputVolume() + 0.5) or 0
  if d and d:outputMuted() then v = 0 end
  pop:evaluateJavaScript("setV(" .. v .. ")")
end
M.syncTimer = hs.timer.doEvery(0.25, M.syncPop)
M.showPop, M.hidePop = showPop, hidePop

-- Watchers: icon follows output device, volume and mute; AirPods options are re-read when AirPods take over
local watched
local function watchVolume()
  if watched then watched:watcherStop() end
  watched = hs.audiodevice.defaultOutputDevice()
  if watched then
    watched:watcherCallback(function(_, ev) if ev == "vmvc" or ev == "mute" then render() end end)
    watched:watcherStart()
  end
end
hs.audiodevice.watcher.setCallback(function(ev)
  if ev == "dOut" then
    watchVolume(); render()
    local d = hs.audiodevice.defaultOutputDevice()
    if isAirPods(d) then hs.timer.doAfter(2, function() refreshAirPods(d:name()) end) end
  end
end)
hs.audiodevice.watcher.start()
watchVolume(); render()
do
  local d = hs.audiodevice.defaultOutputDevice()
  if isAirPods(d) then hs.timer.doAfter(3, function() refreshAirPods(d:name()) end) end
end

M.item, M.refresh, M.state, M.menu = item, refreshAirPods, airpods, menu
return M
