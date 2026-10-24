# 架构与维护

## 组件

| 文件 | 职责 |
| --- | --- |
| `Sources/main.swift` | AppKit 窗口与菜单栏、媒体键事件、后台队列、状态轮询、CLI |
| `Sources/Audio.swift` | CoreAudio 音箱发现、主音量和静音读写 |
| `Sources/ManagerCore.swift` | SDK 协议、灯光配置、音频路由、模式事务、重连 |
| `Sources/DeviceConfiguration.swift` | 本机设备身份和可隔离的配置路径 |
| `scripts/configure.py` | 本机预配置、设备适配检查、音乐区域生成、备份 |

管理器连接 `127.0.0.1:6742`，使用 OpenRGB SDK 协议 6。以 vendor/description/serial 匹配控制器，每次从服务端查询实际控制器 ID；不会假定 ID 恒为 0。Effects Plugin 命令目前假定插件索引 0。

普通灯光按亮度比例缩放每个 RGB 通道，再发送 Direct 模式和 LED 颜色更新命令。音乐效果由独立的 OpenRGB Effects Plugin 执行；管理器只保存和加载它的配置。

## 模式切换

1. 校验设置、本机设备和配置。
2. 获取控制锁，建立 SDK 连接。
3. 保存音频路由快照和 OpenRGB 临时灯光配置。
4. 写入目标灯光配置，切换灯光和音频输出。
5. 检查效果状态与音频路由，再保存用户选择。
6. 失败时恢复文件、音频路由和先前灯光。若恢复不完整，保留临时灯光配置并报告原因。

失败恢复是尽力执行；设备突然拔出或 SDK 断开时可能无法完整恢复硬件状态。双输出设备创建后保留，恢复原路由不会删除它。

## 本机数据

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/OpenRGB-Volume/device-config.json` | 设备 UID 和控制器身份，不应提交 |
| 同目录 `manager-settings.json` | 颜色、亮度、灵敏度、FPS、启动/上次模式 |
| 同目录 `config-backups/`、`install-backups/` | 配置及应用备份 |
| `~/.config/OpenRGB/profiles/default.json` | 用户通过 OpenRGB 保存的基础配置 |
| 同目录 `音乐同步.json` | 选定控制器的音乐效果 |
| 同目录 `管家-普通灯光.json`、`管家-关灯.json` | 自动生成的模式配置 |
| `~/Library/LaunchAgents/local.openrgb.volume-control.plist` | 可选的登录启动项 |

测试和维护可用 `OPENRGB_MANAGER_DATA_DIR`、`OPENRGB_MANAGER_PROFILE_DIR` 隔离文件目录。这两个变量**不会隔离音频硬件或 SDK**，测试时不要执行修改状态的 CLI。`scripts/check.sh` 仅运行配置生成测试。

应用路径 `~/Applications/OpenRGB Volume.app`、可执行文件 `OpenRGBVolume`、bundle ID `local.openrgb.volume-control` 保持稳定，以兼容已有登录项。稳定路径不能保证更新后的临时签名沿用辅助功能授权。

## 命令行

下面命令中的变量只在当前终端会话有效：

```sh
APP_BIN="$HOME/Applications/OpenRGB Volume.app/Contents/MacOS/OpenRGBVolume"
"$APP_BIN" --list-audio
"$APP_BIN" --control status
"$APP_BIN" --status
```

以上为只读查询。下面命令会改变真实灯光或音频路由：

```sh
"$APP_BIN" --control daily --brightness 40
"$APP_BIN" --control music --sensitivity 65 --fps 30
"$APP_BIN" --control off
"$APP_BIN" --control startup
```

`--self-test` 会暂时降低音箱音量再恢复，属于硬件写入测试，不用于 CI。`--background` 启动菜单栏应用并应用登录模式。普通打开会显示窗口；检测断开时仍可能触发自动恢复。

## 边界

- 没有遥测或云端同步；运行时只通过本机 TCP 访问 OpenRGB。
- 不安装或重写驱动，不修改 TCC 权限数据库。
- 当前界面和路由围绕双声道音箱设计，未实现设备选择 GUI、多控制器编排或多声道音量兼容层。
- 构建不自动更新已安装程序，避免打断灯效或使当前辅助功能授权失效。
