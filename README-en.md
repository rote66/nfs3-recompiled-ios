# NFS3

[简体中文](README.md)

**Pure Vibe Coding Project**

- Most of this README was also written with AI.

An iOS static recompilation of **Need for Speed III: Hot Pursuit**. It preserves the original game logic and uses UIKit, Metal, AVAudioEngine, and Core Haptics for the interface, graphics, audio, touch controls, and vibration.

This repository builds only the iOS version of NFS3. The minimum system version is **iOS / iPadOS 14.0**, with support for ARM64 iPhones and iPads. Generated C++ sources are already included, so normal builds do not require regenerating the disassembly.

## Building

### Requirements

- macOS and a full Xcode installation with the iOS SDK.
- CMake 3.15 or later.
- The Metal compiler toolchain. If Xcode has not installed this component, install it with the command below.
- The simulator build is ARM64 and requires an Apple Silicon Mac to run.

```sh
brew install cmake
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain
```

After installing Xcode for the first time, open it to finish installing components and accepting the license.

### Build and package

Run this command from the repository root:

```sh
./build.sh
```

By default, it builds a device Release package and generates:

```text
ios/output/NFS3-ios14.ipa
ios/output/SHA256.txt
ios/output/build-device.log
```

Each device build replaces the same IPA, keeping only one package. The script verifies the App signature and IPA archive integrity. The generated IPA is ad-hoc signed; re-sign it with your own signing tool and certificate before installing it on a device.

Other commands:

```sh
./build.sh device
./build.sh simulator
BUILD_JOBS=4 ./build.sh
./build.sh --help
```

The default parallel job count is 4 and can be changed with `BUILD_JOBS`. The simulator App is generated at `ios/build-simulator/ios/nfs3.app`, with its build log at `ios/output/build-simulator.log`.

The existing `bash ios/build.sh device` and `bash ios/build.sh simulator` commands still work and forward to the script in the repository root.

### Clean and rebuild

```sh
./build.sh clean
./build.sh
```

The clean command removes `build/`, `ios/build-device/`, `ios/build-simulator/`, and the entire `ios/output/` directory, including the IPA, build logs, and any test artifacts stored there. Source files, bundled resources, and game data on your device are unaffected. The Metal module cache is stored inside the build directory and is removed as well.

## Usage

1. Re-sign and install the IPA, then open **NFS3**.
2. Prepare the complete `FEDATA` and `GAMEDATA` folders from the original game.
3. In the Files App, open **On My iPhone / iPad → NFS3 → data** and place both folders directly inside it. Alternatively, tap **导入游戏数据** (Import Game Data) in the launcher and select a folder containing both folders. Importing through the launcher has not been tested.
4. Return to NFS3, wait for the data check to finish, and tap **启动游戏** (Start Game).

The directory layout on your device is:

```text
NFS3/
├── data/
│   ├── nfs3.exe
│   ├── eacsnd.dll
│   ├── softtria.dll
│   ├── voodoo2a.dll
│   ├── install.win
│   ├── FEDATA/
│   └── GAMEDATA/
└── log/
    └── log.log
```

The EXE, three DLLs, and `install.win` are bundled, and the App prepares them in `data/`. You only need to provide `FEDATA` and `GAMEDATA`; do not nest them inside an extra game directory. Resource lookup handles differences in filename capitalization. Saves, configuration, and game temporary files are stored in `data/`. The game may generate `temp.mus`; you do not need to provide it yourself.

`install.win` is a generated text configuration that tells the original game where to find resources. Its extension is `.win`. See [resource sources](ios/Resources/SOURCES.md) for the sources and generation process.

Enable **保存日志** (Save Logs) to write logs separately to `log/log.log`. Include this file when reporting a problem. If the App crashes, you can also include the system-generated `.ips` report.

## Features

### Graphics and audio

- Metal implements the original DirectDraw / Glide display paths, including cars, tracks, cockpit views, and rearview mirrors.
- Preserves the game's aspect ratio and supports the original 640×480, 800×600, and 1024×768 display modes.
- AVAudioEngine plays the original audio, pauses in the background, and attempts to resume when returning to the foreground. The audio engine is recreated if the audio service or output fails.
- Optional FPS, CPU, GPU, and memory display.

### Touch controls and input

- White, translucent virtual buttons with independently drawn icons. The default layout follows the Android version.
- Steering, throttle, brake, shifting, camera, horn, and other actions. Manual transmission and police-specific buttons appear according to the game state.
- Show or hide virtual buttons in-game. Hiding them releases held inputs.
- Touching the game screen simulates a mouse for the main menu and pause menu.
- The system keyboard opens automatically for names and other game text. An in-game keyboard button can also toggle it manually.
- The layout editor supports dragging, snapping or free movement, button resizing, saving, and restoring defaults.

### Tilt steering and vibration

Tilt steering is toggled in-game. Only left and right steering are mapped to a joystick axis; the other virtual action buttons retain keyboard bindings. Switching modes updates the game's control configuration while preserving the second player's bindings and other game settings.

The launcher's **Manual Throttle / Brake** switch selects between two tilt modes:

| Switch | Mode | Controls |
| --- | --- | --- |
| Off | Mode 1 | Automatic acceleration; touch the game screen to brake; steering and throttle / brake buttons are hidden |
| On | Mode 2 | Manual throttle / brake; only steering buttons are hidden |

The launcher includes a vibration switch. The game's Force Feedback is connected to Core Haptics. Actual vibration depends on device support, input mode, and game settings.

### LAN multiplayer

1. Install this LAN-enabled version on every device, connect to the same Wi-Fi, and use matching original game data, cars and tracks.
2. Launch the game, open the original **Connect Players** menu and select **IPX**.
3. One player creates a game and the others find and join it. The host then starts the race. Player limits and race modes follow the original game.
4. Allow **Local Network** access when first opening the multiplayer menu. If access was denied, enable it in **Settings → NFS3 → Local Network**, then re-enter the multiplayer menu. The Local Network setting appears after an actual access request.

Bonjour discovers devices automatically and UDP carries the original IPX packets. No IP address or external server is required. Wi-Fi must permit devices to communicate; guest networks with client isolation cannot be used. Keep the game in the foreground during multiplayer: backgrounding pauses the local game and other players may consider it disconnected.

This transport connects iOS / iPadOS devices running this version.

### Back button and background behavior

- The back button in the upper-left corner sends a back / exit action to the game. When the game exits, the App returns to the launcher automatically.
- With OSD enabled, the back button moves down to avoid the information display.
- Moving to the background releases touch input and pauses the game clock, graphics, and audio. Returning to the foreground resumes them.

## Reference projects

- [motor-dev/nfs-recompiled](https://github.com/motor-dev/nfs-recompiled): The original static recompilation project, providing the EXE / DLL-to-C++ generation tools, generated sources, virtual CPU, and Win32 / DirectX compatibility layer. This project builds the iOS version of NFS3 on that foundation.
- [ZloiKILLER/nfs3recompiled-android](https://github.com/ZloiKILLER/nfs3recompiled-android): The Android version of NFS3, used as a reference for the mobile launcher, touch layout, input mappings, and related features.

## Project structure

| Path | Contents |
| --- | --- |
| `build.sh` | Build, package, and clean entry point |
| `ios/` | iOS interface, input, Metal, audio, vibration, and runtime implementations |
| `ios/Resources/` | App icons, localized strings, and generated `install.win` |
| `include/`, `src/lib/` | Virtual CPU, memory, and the Win32 / DirectX compatibility layer required by the original game |
| `src/nfs3hp/disassembly/` | Recompiled C++ code for the NFS3 EXE and three DLLs |
| `nfs3hp/` | Bundled original EXE and DLLs |
| `disasm/`, `disassemble_nfs3hp.py` | NFS3 disassembly generation tools; not needed for normal builds |
| `ios/tools/` | Path configuration and icon generation tools |

Normal builds use the existing sources directly. Running the disassembly generator again overwrites generated code and its compatibility fixes. Preserve and revalidate those fixes when changing the generation logic.

## Current limitations and testing

The minimum deployment version is iOS / iPadOS 14.0. Previous single-player device testing passed on an iPhone SE (3rd generation) running iOS 15.5.
