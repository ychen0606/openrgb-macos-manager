#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/dist/OpenRGB Volume.app"
DEST="$HOME/Applications/OpenRGB Volume.app"
if [[ ! -x "$APP/Contents/MacOS/OpenRGBVolume" ]]; then
  echo 'Run ./scripts/build.sh first.' >&2; exit 1
fi
if pgrep -x OpenRGBVolume >/dev/null; then
  echo '请先从控制台菜单选择「退出并恢复普通模式」，再安装。' >&2; exit 1
fi
codesign --verify --strict "$APP"
mkdir -p "$HOME/Applications"
if [[ -e "$DEST" ]]; then
  BACKUP_DIR="$HOME/Library/Application Support/OpenRGB-Volume/install-backups/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$BACKUP_DIR"
  ditto "$DEST" "$BACKUP_DIR/OpenRGB Volume.app"
  echo "Existing app backed up: $BACKUP_DIR"
fi
ditto "$APP" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed: $DEST"
echo '运行 python3 scripts/configure.py 完成本机设备配置，然后打开应用。'
echo '更新后，macOS 可能要求在「辅助功能」中重新添加此应用。'
