<div align="center">

# 🤖 Fully developed by Claude

**This entire project (code, build scripts, icon, tests and documentation) was designed, written and tested by Claude (Anthropic's AI, Claude Opus 5.5) in Claude Code.**
**human note here: yes i know ai code is bad i just want to screw around and if it works it works, leave me alone ok, im not denying it nor am i saying that you should use it, its your choice and its made for me.**

</div>

---

# Vintner

A Whisky-style app for **Intel Macs and Hackintoshes** that runs Windows programs and games with Wine.

| Layer | Component |
|---|---|
| Wine | Wine Staging 11.18 x86_64 (Gcenx/WineHQ build): WoW64, so 32-bit and 64-bit apps work on macOS 12+ |
| D3D10/11 | DXVK-macOS 1.10.3 (async) → MoltenVK → Metal |
| D3D8/9 | WineD3D (OpenGL) |
| D3D12 | vkd3d (built into Wine) → MoltenVK |
| .NET / web views | Wine Mono 11.3, Wine Gecko 2.47.4 (bundled with Wine) |
| Extras | winetricks 20260125, cabextract 1.11, SDL2 (controllers) |

Every download is pinned and checked against its SHA-256 before install.

## Install

1. Copy `Vintner.app` to `/Applications` on the Intel Mac (it requires macOS 12 Monterey or later).
2. The app is ad-hoc signed, not notarized. If the zip came over the internet or AirDrop, clear the quarantine flag first:
   `xattr -cr /Applications/Vintner.app`
3. Open it and click **Install**. `Vintner-1.0.0-offline.zip` contains the whole runtime. The lean zip downloads about 200 MB.
4. Optional health check: `/Applications/Vintner.app/Contents/MacOS/Vintner --selftest`
   It creates a temporary bottle, runs 32-bit and 64-bit Windows code, and renders Direct3D 11 through DXVK and WineD3D. A small window flashes briefly during the test.

## Use

- **New Bottle** (⌘N) creates an isolated Windows environment.
- **Run…** (⌘O), drag-and-drop, or double-clicking an `.exe` runs a program. Installers, `.msi`, `.bat` and `.lnk` files all work.
- **Programs** lists installed `.exe` files. Right-click a program to pin it, set launch arguments, or create a Dock/Launchpad shortcut in `~/Applications/Vintner`.
- **Settings**: Windows version, graphics backend, DXVK async/HUD, Metal HUD, preferred GPU (for iGPU+dGPU Hackintoshes), FPS limit, Retina, DPI, exclusive fullscreen, ⌘/⌥ key mapping, logging, and custom environment variables.
- **Winetricks**: one-click Visual C++ runtimes, DirectX extras, .NET, fonts, PhysX, XNA and more, plus any other verb.
- **Tools**: winecfg, regedit, Task Manager, Control Panel, cmd, a Terminal pre-configured for the bottle, Install Steam, prefix update, force quit.

Data lives in `~/Library/Application Support/Vintner`. Logs go to `~/Library/Logs/Vintner` and are deleted after 7 days.

## Performance defaults

- Wine debug channels are off (`WINEDEBUG=-all`). DXVK and MoltenVK logging is off unless you enable logging.
- DXVK async shader compilation is on, with a persistent per-bottle shader cache.
- The file-descriptor limit is raised to 10240 for Wine.
- Programs run at interactive QoS.
- 32-bit games get large-address-aware mode (4 GB).
- `winemenubuilder` is disabled.
- Registry changes are applied in one `regedit` batch.
- The program scanner skips redistributable and shader-cache folders.

## Known limitations

- **32-bit Direct3D 10/11 games use WineD3D, not DXVK.** In Wine's WoW64 mode, 32-bit Vulkan memory mapping needs a host-memory import that MoltenVK rejects. Vintner therefore installs DXVK only for 64-bit programs. A 32-bit launcher plus a 64-bit game in the same bottle both work. There's an experimental per-bottle toggle, and `--selftest` reports whether 32-bit DXVK works on your Mac.
- WineD3D on macOS OpenGL (capped at GL 4.1) exposes only Direct3D feature level 9_3. Games that require D3D10/11 must be 64-bit to use DXVK.
- Apple's D3DMetal (Game Porting Toolkit) needs Apple Silicon, so it isn't available here.
- Anti-cheat games (EAC/BattlEye kernel mode, Vanguard, etc.) don't work under Wine.
- GPUs without Metal 2 support can't use DXVK or MoltenVK. This includes very old NVIDIA cards on Hackintoshes. Use WineD3D (OpenGL) instead. AMD Radeon GPUs work best.
- There's no GStreamer, so some in-game video cutscenes may not play.

## Build from source

```
./build.sh                 # lean app → dist/Vintner.app + dist/Vintner-1.0.0.zip
./build.sh --embed-runtime # bundle Wine/DXVK/winetricks for offline install (~190 MB)
```

Building needs Xcode 15 or later (Swift 5.9+). It can be built on Apple Silicon: the output is x86_64.
`Vendor/d3dprobe/d3dprobe.c` is the source of the self-test's Direct3D probes. It's built with `zig cc -target x86_64-windows-gnu` and `x86-windows-gnu`.
