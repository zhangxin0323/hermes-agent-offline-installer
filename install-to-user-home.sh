#!/bin/bash
# =============================================================================
# Hermes Agent 离线安装脚本（用户目录版·随包 venv 修复式）
#
# 用法:
#   tar xzf hermes-agent-arm64-offline.tar.gz        # 任意目录解压
#   bash install-to-home.sh                          # 安装到 ~/.local/opt/hermes-agent
#   INSTALL_DIR=/data/hermes bash install-to-home.sh # 自定义位置
#   bash install-to-home.sh --uninstall              # 卸载
#
# 流程（对齐 deepseek-harness 的 dsh 脚本）:
#   tar --strip-components=1 直装 → ~/.local/bin 符号链接/包装脚本
#   → 修复 venv（python 符号链接 + pyvenv.cfg home + bin/* 构建路径替换）
#   → 校验 → env.sh/启动器/快捷方式
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/opt/hermes-agent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAR="${TARBALL:-$SCRIPT_DIR/hermes-agent-arm64-offline.tar.gz}"

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
    echo "卸载 Hermes Agent ..."
    rm -rf "$INSTALL_DIR"
    rm -f "$HOME/.local/bin/hermes" "$HOME/.local/bin/hermes-desktop" \
          "$HOME/.local/bin/node" "$HOME/.local/bin/pnpm"
    rm -f "$HOME/.local/share/applications/hermes-agent.desktop"
    for d in "$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")" "$HOME/桌面"; do
        rm -f "$d/hermes-agent.desktop"
    done
    echo "✓ 已卸载（用户数据 ~/.hermes 如需清理请手动删除）"
    exit 0
fi

[ -f "$TAR" ] || { echo "未找到离线包: $TAR" >&2; exit 1; }
[ "$(uname -m)" = "aarch64" ] || echo "警告: 当前架构 $(uname -m) 不是 aarch64" >&2

echo "解压到 $INSTALL_DIR ..."
if [ -e "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$INSTALL_DIR.bak-$(date +%Y%m%d-%H%M%S)"
    echo "旧版本已备份（确认新版正常后可手动删除）"
fi
mkdir -p "$INSTALL_DIR"
tar xzf "$TAR" -C "$INSTALL_DIR" --strip-components=1

mkdir -p "$HOME/.local/bin"

# 命令行入口：包装脚本（source 环境变量，保证 playwright/桌面端变量生效）
cat > "$HOME/.local/bin/hermes" <<EOF
#!/bin/sh
[ -f "$INSTALL_DIR/env.sh" ] && . "$INSTALL_DIR/env.sh"
exec "$INSTALL_DIR/python-venv/bin/hermes" "\$@"
EOF
cat > "$HOME/.local/bin/hermes-desktop" <<EOF
#!/bin/sh
exec "$INSTALL_DIR/bin/hermes-desktop.sh" "\$@"
EOF
chmod +x "$HOME/.local/bin/hermes" "$HOME/.local/bin/hermes-desktop"
# node/pnpm 链到 PATH（与 dsh 相同做法；会遮蔽系统 node，如有冲突自行取舍）
ln -sf "$INSTALL_DIR/node/bin/node"  "$HOME/.local/bin/node"
ln -sf "$INSTALL_DIR/node/bin/pnpm"  "$HOME/.local/bin/pnpm"
export PATH="$INSTALL_DIR/node/bin:$HOME/.local/bin:$PATH"

# ---- 修复随包 venv（构建机路径 → 本机路径）----
PYROOT="$INSTALL_DIR/python"
VENV="$INSTALL_DIR/python-venv"
BASE_PY="$(ls -1 "$PYROOT"/cpython-*/bin/python3.* 2>/dev/null | head -1)"
if [ -n "$BASE_PY" ] && [ -f "$BASE_PY" ] && [ -f "$VENV/pyvenv.cfg" ]; then
    BASE_BIN="$(dirname "$BASE_PY")"
    ln -sfn "$BASE_PY" "$VENV/bin/python"
    ln -sfn "$BASE_PY" "$VENV/bin/python3"
    awk -v h="$BASE_BIN" '
      /^home[[:space:]]*=/ && !done { print "home = " h; done=1; next }
      { print }
    ' "$VENV/pyvenv.cfg" > "$VENV/pyvenv.cfg.tmp"
    mv -f "$VENV/pyvenv.cfg.tmp" "$VENV/pyvenv.cfg"

# 先清 .pyc：跨机搬运时字节码缓存本就是隐患，且避免下面的 sed 误伤二进制
find "$VENV" "$INSTALL_DIR/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

BUILD_ROOT="$(sed -n 's/^build_root=//p' "$INSTALL_DIR/version.txt" 2>/dev/null | head -n 1)"
if [ -n "$BUILD_ROOT" ] && [ "$BUILD_ROOT" != "$VENV" ]; then
    # grep -I：跳过二进制文件，只处理文本（.pyc 里嵌的路径随缓存删除一起消失，无需替换）
    grep -rlI "$BUILD_ROOT" "$VENV/bin" 2>/dev/null \
        | xargs -r sed -i "s|$BUILD_ROOT|$INSTALL_DIR|g"
    SP="$(echo "$VENV"/lib/python*/site-packages)"
    grep -rlI "$BUILD_ROOT" "$SP" 2>/dev/null \
        | xargs -r sed -i "s|$BUILD_ROOT|$INSTALL_DIR|g"
fi

    echo "✓ Python 环境: $VENV"
    "$VENV/bin/python" -V 2>&1 | sed 's/^/  /'
else
    echo "！未找到随包的 Python 运行时，Python 环境不可用" >&2
    exit 1
fi

# ---- 校验 ----
echo "校验依赖 ..."
"$VENV/bin/python" - <<'PYCHK' || { echo "依赖校验失败，venv 修复可能不完整" >&2; exit 1; }
import importlib
mods = ["ruamel.yaml", "openai", "rich", "httpx", "pydantic", "playwright"]
missing = [m for m in mods if not importlib.import_module(m)]
assert not missing, f"missing: {missing}"
PYCHK
"$VENV/bin/hermes" --version || { echo "hermes 无法启动" >&2; exit 1; }

# ---- env.sh（桌面端探测指路 + playwright 缓存）----
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/bin"
cat > "$INSTALL_DIR/env.sh" <<EOF
# Hermes 运行时环境（install-to-home.sh 生成）
export PATH="$INSTALL_DIR/node/bin:$INSTALL_DIR/python-venv/bin:\$PATH"
export HERMES_DESKTOP_HERMES_ROOT="$INSTALL_DIR/src"
export HERMES_DESKTOP_HERMES="$INSTALL_DIR/python-venv/bin/hermes"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/playwright-cache"
export HERMES_HOME="$INSTALL_DIR/data"
EOF

# ---- 启动器 ----
cat > "$INSTALL_DIR/bin/hermes-desktop.sh" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/env.sh"
APPIMAGE="$(ls "$HERE/electron-app"/*.AppImage 2>/dev/null | head -n 1)"
[ -n "$APPIMAGE" ] && { exec "$APPIMAGE" "$@" 2>/dev/null || exec "$APPIMAGE" --no-sandbox "$@"; }
BIN="$(find "$HERE/electron-app" -maxdepth 2 -type f -executable \
        ! -name 'chrome*' ! -name 'crashpad*' ! -name '*.so*' 2>/dev/null | head -n 1)"
[ -n "$BIN" ] && { exec "$BIN" "$@" 2>/dev/null || exec "$BIN" --no-sandbox "$@"; }
echo "[提示] 未找到桌面产物，退回 gateway + 浏览器模式" >&2
hermes gateway run &
for _ in $(seq 1 60); do (echo >/dev/tcp/127.0.0.1/8642) 2>/dev/null && break; sleep 1; done
xdg-open "http://127.0.0.1:8642" >/dev/null 2>&1
wait
EOF
chmod +x "$INSTALL_DIR/bin/hermes-desktop.sh"

# ---- pm 工具缓存合并进 ~/.cache ----
if [ -d "$INSTALL_DIR/pm-cache" ]; then
    USER_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
    for d in "$INSTALL_DIR/pm-cache"/*; do
        name="$(basename "$d")"
        [ "$name" = "MANIFEST.txt" ] && continue
        [ -d "$d" ] && [ ! -e "$USER_CACHE/$name" ] && cp -a "$d" "$USER_CACHE/$name"
    done
fi

# ---- 快捷方式 ----
APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$APPS_DIR"
cat > "$APPS_DIR/hermes-agent.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hermes Agent
Comment=Hermes Agent 桌面端
Exec=$INSTALL_DIR/bin/hermes-desktop.sh
Icon=$INSTALL_DIR/src/apps/desktop/assets/icon.png
Terminal=false
Categories=Development;Utility;
StartupNotify=true
EOF
chmod +x "$APPS_DIR/hermes-agent.desktop"
update-desktop-database "$APPS_DIR" 2>/dev/null || true
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
[ -d "$DESKTOP_DIR" ] || DESKTOP_DIR="$HOME/桌面"
if [ -d "$DESKTOP_DIR" ]; then
    cp "$APPS_DIR/hermes-agent.desktop" "$DESKTOP_DIR/hermes-agent.desktop"
    chmod +x "$DESKTOP_DIR/hermes-agent.desktop"
    gio set "$DESKTOP_DIR/hermes-agent.desktop" metadata::trusted true 2>/dev/null || true
fi

# ---- 完成 ----
echo ""
echo "✓ 安装完成: $INSTALL_DIR"
[ -f "$INSTALL_DIR/version.txt" ] && { echo "  包版本:"; sed 's/^/    /' "$INSTALL_DIR/version.txt"; }
cat <<EOF

  桌面启动: 开始菜单/桌面双击 "Hermes Agent"，或 hermes-desktop
  命令行:   hermes --help
  数据目录: $INSTALL_DIR/data (HERMES_HOME)
  卸载:     bash $SCRIPT_DIR/install-to-home.sh --uninstall

EOF
echo "提示: 建议断网验证一次离线功能（浏览器/转录等）。"
