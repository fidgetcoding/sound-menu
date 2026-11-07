# sound-menu

A Hammerspoon replacement for the macOS Sound menu bar item.

- Apple-style popover: volume slider with speaker icons, then your output devices
- Hides virtual devices (BlackHole, Zoom) from the list; they still work in every app
- AirPods listening modes, Spatial Audio and Conversation Awareness, read from Control Center

## Install

Copy `sound-menu.lua` and `icons/` into `~/.hammerspoon/`, then add `require("sound-menu")` to `init.lua`.

Nate Davidovich / Lorecraft LLC
