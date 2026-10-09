# NFS3

[English](README-en.md)

**Pure Vibe Coding Project**

- 大部分readme也为AI完成

《极品飞车 III：热力追踪》（Need for Speed III: Hot Pursuit）的 iOS 静态重编译版本。保留原版游戏逻辑，用 UIKit、Metal、AVAudioEngine 和 Core Haptics 实现界面、画面、声音、触控与震动。

当前仓库只构建 NFS3 的 iOS 版本，最低系统为 **iOS / iPadOS 14.0**，支持 ARM64 iPhone 和 iPad。仓库已包含生成好的 C++ 源码，日常构建不需要重新反汇编。

## 构建

### 环境

- macOS 和完整 Xcode，包含 iOS SDK。
- CMake 3.15 或以上版本。
- Metal 编译工具链。若 Xcode 尚未安装该组件，按下面的命令安装。
- 模拟器包为 ARM64，运行它需要 Apple Silicon Mac。

```sh
brew install cmake
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain
```

首次安装 Xcode 后，先打开一次并完成组件安装及许可确认。

### 编译

在仓库根目录执行：

```sh
./build.sh
```

默认构建真机 Release，生成：

```text
ios/output/NFS3-ios14.ipa
ios/output/SHA256.txt
ios/output/build-device.log
```

每次真机构建覆盖同一个 IPA，只保留一个安装包。脚本会检查 App 签名及 IPA 压缩包完整性。生成的 IPA 使用临时签名，安装到设备前需用自己的签名工具和证书重新签名。

其他入口：

```sh
./build.sh device
./build.sh simulator
BUILD_JOBS=4 ./build.sh
./build.sh --help
```

默认并行数量为 4，可用 `BUILD_JOBS` 调整。模拟器构建输出 `ios/build-simulator/ios/nfs3.app`，日志为 `ios/output/build-simulator.log`。

原来的 `bash ios/build.sh device` 和 `bash ios/build.sh simulator` 入口仍可使用，它们转发到根目录脚本。

### 清理和重新构建

```sh
./build.sh clean
./build.sh
```

清理命令删除 `build/`、`ios/build-device/`、`ios/build-simulator/` 和整个 `ios/output/`，包括 IPA、构建日志及保存在其中的测试产物。源码、内置资源和设备上的游戏数据不受影响。Metal 模块缓存也放在构建目录内，会一并清理。

## 使用

1. 重新签名并安装 IPA，打开 **NFS3**。
2. 准备原版游戏的完整 `FEDATA` 和 `GAMEDATA` 文件夹。
3. 在“文件”App 中打开“我的 iPhone / iPad → NFS3 → data”，把这两个文件夹直接放进去；或在启动器点“导入游戏数据”，选择同时包含两个文件夹的目录（启动器导入未测试）。
4. 返回 NFS3，等待数据检查完成，再点“启动游戏”。

设备上的目录结构如下：

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

EXE、三个 DLL 和 `install.win` 已内置，App 会准备到 `data/` 中。只需提供 `FEDATA` 和 `GAMEDATA`，不要额外嵌套一层游戏目录。资源查找兼容文件名大小写。存档、配置和游戏临时文件都在 `data/`；游戏可能生成 `temp.mus`，无需自行提供它。

`install.win` 是生成的原版游戏路径配置文本，用于定位资源，扩展名为 `.win`。资源来源和生成方法见 [资源说明](ios/Resources/SOURCES.md)。

开启“保存日志”后，日志写到独立的 `log/log.log`。报告问题时可提供这个文件；若发生闪退，也可附上系统生成的 `.ips` 报告。

## 特性和功能

### 显示与声音

- 用 Metal 实现原版 DirectDraw / Glide 的显示路径，包括车辆、赛道、车内视角和后视镜。
- 保持游戏画面比例，支持原版的 640×480、800×600 和 1024×768 显示模式。
- 用 AVAudioEngine 播放原版音频；后台时暂停，回到前台后尝试恢复。音频服务或输出失效时会重新创建音频引擎。
- 可显示 FPS、CPU、GPU 和内存信息。

### 触控与输入

- 白色半透明虚拟按键，图标独立绘制，默认布局参考 Android 版本。
- 支持方向、油门、刹车、换挡、视角、喇叭等操作；手动挡和警车专用按键按游戏状态显示。
- 游戏内可切换虚拟按键显示 / 隐藏；隐藏时释放已按下的按键。
- 触摸游戏画面模拟鼠标，可操作主菜单和暂停菜单。
- 输入名字等游戏文本时自动弹出系统键盘，也可用游戏内键盘按钮手动切换。
- 布局编辑器支持拖动、吸附 / 自由移动、按键大小调整、保存和恢复默认。

### 重力转向与震动

重力转向在游戏内切换，只把左右转向改为摇杆轴，其他虚拟动作按键保留键盘映射。切换模式时同步修改游戏控制配置，第二位玩家及其他游戏设置保持不变。

启动器的“手动油门 / 刹车”开关选择两种重力玩法：

| 开关 | 模式 | 操作 |
| --- | --- | --- |
| 关闭 | 模式 1 | 自动加速，触摸游戏画面刹车，隐藏方向和油门 / 刹车按钮 |
| 开启 | 模式 2 | 手动油门 / 刹车，只隐藏方向按钮 |

启动器提供震动开关。游戏的 Force Feedback 已接入 Core Haptics，实际震动取决于设备支持、输入模式和游戏设置。

### 返回与后台

- 左上角返回按钮向游戏发送返回 / 退出操作；游戏退出后自动回到启动器。
- 开启 OSD 时，返回按钮下移以避开信息显示。
- 切到后台会释放触控输入并暂停游戏时钟、画面和声音；回到前台后恢复。

## 参考项目

- [motor-dev/nfs-recompiled](https://github.com/motor-dev/nfs-recompiled)：原版游戏的静态重编译项目，提供 EXE / DLL 的 C++ 生成工具、生成源码、虚拟 CPU 和 Win32 / DirectX 兼容层。本项目以它为基础实现 NFS3 的 iOS 版本。
- [ZloiKILLER/nfs3recompiled-android](https://github.com/ZloiKILLER/nfs3recompiled-android)：NFS3 的 Android 版本，为移动端启动器、触控布局、输入映射等功能提供参考。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `build.sh` | 构建、打包和清理入口 |
| `ios/` | iOS 界面、输入、Metal、音频、震动与运行时实现 |
| `ios/Resources/` | App 图标、多语言字符串和生成的 `install.win` |
| `include/`、`src/lib/` | 虚拟 CPU、内存和原版游戏所需的 Win32 / DirectX 兼容层 |
| `src/nfs3hp/disassembly/` | NFS3 EXE 和三个 DLL 的重编译 C++ 代码 |
| `nfs3hp/` | 内置的原版 EXE 和 DLL |
| `disasm/`、`disassemble_nfs3hp.py` | NFS3 反汇编生成工具，普通构建无需运行 |
| `ios/tools/` | 路径配置和图标生成工具 |

普通构建直接使用现有源码。重新运行反汇编生成器会覆盖生成代码及其中的兼容性修复，修改生成逻辑时需要保留并重新验证这些修复。

## 当前限制与验证

最低部署版本为 iOS / iPadOS 14.0。仅在SE3 15.5上测试通过。

原版的网络联机和在线车辆下载当前不可用。
