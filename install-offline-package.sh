#!/bin/bash
# =============================================================================
# Hermes Agent 离线包安装脚本（目标机 / 内网执行）
#
# 用法:
#   bash install-offline-package.sh              # 交互式
#   bash install-offline-package.sh --force      # 已安装时直接备份并覆盖
#   bash install-offline-package.sh --help
#
# 目标目录: /opt/hermes-agent
# 若该目录已存在且非空，脚本会先询问；确认后把旧目录重命名为
# /opt/hermes-agent.bak.<时间戳> 再安装，不会直接覆盖丢文件。
# =============================================================================
set -euo pipefail

OFFLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/opt/hermes-agent}"
TARBALL="$OFFLINE_DIR/hermes-desktop-arm64-offline.tar.gz"
FORCE_INSTALL=0

info() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: bash install-offline-package.sh [选项]

选项:
  -f, --force   目标目录已存在时不再询问，自动备份为 .bak.<时间戳> 后覆盖安装
  -h, --help    显示本帮助

环境变量:
  HERMES_INSTALL_DIR  安装目录，默认 /opt/hermes-agent
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE_INSTALL=1 ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
    shift
done

dir_nonempty() {
    [ -d "$1" ] || return 1
    [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

ask_yes_no() {
    local question="$1" answer=""
    if [ ! -t 0 ]; then
        return 1
    fi
    printf '%s [y/N] ' "$question"
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

[ -f "$TARBALL" ] || die "找不到离线包: $TARBALL
      请把 hermes-desktop-arm64-offline.tar.gz 与本脚本放在同一目录。"

step "步骤1：安装系统运行时依赖"
sudo apt update
sudo apt install -y git libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2 \
    ripgrep ffmpeg

step "步骤2：检查目标目录并解压"
if dir_nonempty "$INSTALL_DIR"; then
    BACKUP_DIR="$INSTALL_DIR.bak.$(date +%Y%m%d-%H%M%S)"
    warn "目标目录已存在且非空: $INSTALL_DIR"
    info "  顶层条目 $(ls -A "$INSTALL_DIR" | wc -l) 个，占用 $(du -sh "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')"
    info "  继续安装会把它整体重命名为: $BACKUP_DIR（保留旧版本，可回滚）"

    if [ "$FORCE_INSTALL" -eq 1 ]; then
        info "已指定 --force，直接备份并覆盖。"
    elif ask_yes_no "是否备份旧目录后覆盖安装？"; then
        info "确认覆盖安装。"
    else
        die "已取消安装。
      如需覆盖: bash install-offline-package.sh --force
      如需先清理旧版本:
        sudo rm -rf $INSTALL_DIR
        bash install-offline-package.sh"
    fi

    sudo mv "$INSTALL_DIR" "$BACKUP_DIR"
    info "旧版本已备份到: $BACKUP_DIR"
fi

cd /opt
sudo tar xzvf "$TARBALL"
sudo chown -R "$(whoami):$(whoami)" "$INSTALL_DIR"

step "步骤3：创建 hermes 启动命令"
sudo tee /usr/local/bin/hermes > /dev/null << 'EOF'
#!/bin/bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_AGENT_ROOT="__INSTALL_DIR__"

# UV 环境（与外网编译时一致）
export UV_NO_CONFIG=1
export UV_PYTHON_INSTALL_DIR="$HERMES_AGENT_ROOT/uv/python"

# PATH
export PATH="$HERMES_AGENT_ROOT/hermes-venv/bin:$HERMES_AGENT_ROOT/node/bin:$PATH"

# Node/Electron/Playwright（与外网编译时一致）
export NODE_PATH="$HERMES_AGENT_ROOT/node_modules"
export ELECTRON_CACHE="$HERMES_AGENT_ROOT/electron-cache"
export PLAYWRIGHT_BROWSERS_PATH="$HERMES_AGENT_ROOT/playwright-cache"

# 清理冲突
unset PYTHONPATH
unset PYTHONHOME

exec "$HERMES_AGENT_ROOT/hermes-venv/bin/hermes" "$@"
EOF
sudo sed -i "s#__INSTALL_DIR__#${INSTALL_DIR}#g" /usr/local/bin/hermes
sudo chmod +x /usr/local/bin/hermes

step "步骤4：创建桌面启动器（可选）"
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/hermes.desktop << DESKTOP
[Desktop Entry]
Name=Hermes Agent
Exec=/usr/local/bin/hermes desktop --skip-build
Icon=$INSTALL_DIR/apps/desktop/assets/icon.png
Type=Application
Terminal=false
Categories=Development;
DESKTOP

step "步骤5：验证安装"
hermes --version

echo ""
echo "✓ 安装完成！"
echo "  安装目录: $INSTALL_DIR"
if [ -n "${BACKUP_DIR:-}" ]; then
    echo "  旧版本备份: $BACKUP_DIR"
    echo "    （确认新版可用后可删除: sudo rm -rf $BACKUP_DIR）"
fi
echo "  启动终端界面: hermes --tui"
echo "  启动桌面应用: hermes desktop --skip-build"
echo ""
echo "如需连接 Docker 服务端，请编辑 ~/.hermes/config.yaml:"
echo "  model:"
echo "    provider: openai-compatible"
echo "    base_url: http://你的docker服务端IP:8642/v1"
echo "    api_key: sk-internal-key"
