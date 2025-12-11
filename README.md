# LuaLooter

LuaLooter is a Lua project (MacroQuest-related) to manage loot and inventory logic.

## Requirements
- Lua 5.1 (or the interpreter you use for MacroQuest scripts)
- (Recommended) VS Code with the `sumneko.lua` and `actboy168.lua-debug` extensions

## Quick start
- Open this folder in VS Code (or open `LuaLooter.code-workspace`).
- Install recommended extensions when prompted.
- To run: open the Command Palette and choose `Tasks: Run Task` → `Run main.lua`, or run in PowerShell:

```powershell
lua main.lua
```

## Notes
- The workspace `settings.json` exposes `mq` as a global for diagnostics.
- If you use a different Lua runtime path, update your PATH or the task command accordingly.
