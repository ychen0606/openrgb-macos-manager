# 安装与配置

## 1. 准备依赖

1. 将 OpenRGB 1.1 安装到 `/Applications/OpenRGB.app`，确认它能识别并控制你的机箱灯。
2. 从 [OpenRGB 插件页面](https://openrgb.org/plugins.html) 安装与 OpenRGB 版本和 CPU 架构匹配的 Effects Plugin 1.1，并启用它。当前实现要求它的插件索引为 0；插件顺序不匹配时会报错。
3. 音乐同步需要 [BlackHole 2ch](https://existential.audio/blackhole/)；使用官方安装程序，按系统要求完成管理员验证或重启。
4. 在 OpenRGB 保存名为 `default` 的配置，文件应位于 `~/.config/OpenRGB/profiles/default.json`。确认选中的机箱控制器提供 `Direct` 模式。
5. 在 OpenRGB 设置中开启“关闭窗口时最小化”。SDK 应只在本机 `127.0.0.1:6742` 提供服务，并允许本机客户端所需的控制权限。控制台连接时会协商权限；未获允许会显示错误。
6. 安装 Xcode Command Line Tools 和 Python 3。构建脚本通过 `xcrun` 找到 Swift 编译器，不依赖固定的开发工具安装路径。

控制台会按需启动 SDK。如果已运行的 OpenRGB 没有服务，它会尝试正常退出该实例，再带 `--server` 参数启动，随后恢复控制台保存的模式。请先保存 OpenRGB 中希望保留的手动设置。

## 2. 构建和选择本机设备

```sh
./scripts/build.sh
python3 scripts/configure.py --list
```

输出包含音频设备的名称、UID、输出声道数、主音量/静音可写状态，以及 `default.json` 中的灯光控制器索引。

```sh
python3 scripts/configure.py \
  --speaker-uid '从列表复制实际音箱 UID' \
  --controller-index 0 \
  --dry-run
```

核对后去掉 `--dry-run` 执行。只有一个名为 `USB AUDIO` 的音箱和一个合适的控制器时，可以省略两个选择参数。不要选 BlackHole 或双输出设备作为音箱。

配置工具会：

- 在 `~/Library/Application Support/OpenRGB-Volume/device-config.json` 保存所选本机设备标识。
- 从本机 `default.json` 的选定控制器及区域生成 `音乐同步.json`。
- 仅在不存在时创建 `manager-settings.json`，初始采用普通灯光模式。
- 保留原始 `default.json`。

首次模板使用 Effects Plugin 音频输入索引 `0`。**插件的输入索引随机器变化，不能假设 0 始终是 BlackHole。** 可以传入 `--audio-device-index N`，或在首次进入音乐模式后到 Effects Plugin 中选择 BlackHole 2ch，再保存为“音乐同步”。只修改当前效果但不保存，下一次模式切换会重新加载旧配置。

配置默认拒绝覆盖已有文件。需要重建时使用 `--replace`，旧文件保存到支持目录下的 `config-backups/`，现有用户参数保持不变。重新生成音乐配置会替换手动调整的插件效果，因此先检查备份和自己的设置。

## 3. 安装和权限

```sh
./scripts/install.sh
open "$HOME/Applications/OpenRGB Volume.app"
```

脚本不会自动启动新应用或更改登录项。首次打开后：

1. 选择“普通灯光”，验证选色和同色亮度调整。
2. 在“系统设置 → 隐私与安全性 → 辅助功能”允许 `OpenRGB Volume`，以处理音乐双输出下的音量键。音量滑块不依赖此权限。
3. 选择“音乐同步”，确认 Effects Plugin 输入是 BlackHole；macOS 如提示 OpenRGB 使用音频输入，选择允许。
4. 播放音乐、暂停约 3 秒，确认机箱跟随并变暗。
5. 按音量减、加，确认音箱音量改变且灯效继续运行。

音乐模式会创建/修复名为“OpenRGB 音乐同步”的双输出：音箱作为主设备，BlackHole 开启漂移校正，两个设备接收相同双声道信号。默认输入切为 BlackHole、默认输出切为双输出，系统提示音输出设为音箱。

普通/关灯模式将默认输出和系统输出恢复为音箱，默认输入仍保留 BlackHole。若随后使用会议或录音软件，请在对应软件中选择需要的实体麦克风。

## 4. 日常使用与更新

- 选颜色后立即应用；普通模式的亮度滑块松开后应用。
- 音乐的亮度、灵敏度、30/60 FPS 调整后，点击“应用灯光设置”。
- 开启“登录启动”后，可选择普通、音乐或上次模式；下次登录生效。
- 关闭管理窗口仍保留菜单栏；“退出并恢复普通模式”先恢复普通灯光和直接音频输出。
- 更新前先退出控制台，再运行安装脚本；旧应用备份在 `install-backups/`。
- 默认临时签名在重编译后会改变。旧辅助功能条目可能失效，需要移除并重新添加当前应用。仅重新打开旧开关不一定有效。

## 5. 停用或移除

先取消登录启动，再从菜单选择“退出并恢复普通模式”。随后可移除 `~/Applications/OpenRGB Volume.app`。如果还不需要灯光服务，可退出 OpenRGB。

保留支持目录和 OpenRGB 配置可以方便恢复。BlackHole 是独立驱动，是否卸载请按官方说明处理。清理前确认其他音频工作流是否仍在使用它。
