#!/bin/bash
# =============================================================================
# Hermes Agent 离线安装脚本（/opt 系统级版）
#
# 与 make-offline-package.sh（/opt 版）产出的 tar 包配套：
#   包内容: hermes-agent/ 目录（已含 venv/node_modules/桌面产物，绝对路径耦合 /opt）
#
# 本脚本职责（旧版缺失的部分）:
#   1. 解压到 /opt/hermes-agent（路径必须与打包机一致，editable venv 硬链该路径）
#   2. 生成 /opt/hermes-agent/env.sh —— 桌面端后端探测指路（治首启弹向导）
#   3. 生成 /opt/hermes-agent/bin/hermes-desktop.sh —— 统一启动器
#   4. 创建系统级开始菜单（/usr/share/applications）与桌面快捷方式
#
# 用法:
#   sudo bash install-offline-package.sh                  # 交互式安装
#   sudo bash install-offline-package.sh -y               # 默认全部“是”
#   sudo bash install-offline-package.sh --no-desktop --no-menu
#   sudo bash install-offline-package.sh --uninstall      # 卸载
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hermes-agent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ASSUME_YES=0
NO_DESKTOP=0
NO_MENU=0
UNINSTALL=0

step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash install-offline-package.sh [选项]

选项:
  -y, --yes          所有询问自动回答“是”
      --no-desktop   不创建桌面快捷方式
      --no-menu      不创建开始菜单项
      --uninstall    卸载
  -h, --help         显示本帮助

环境变量:
  INSTALL_DIR        安装位置，默认 /opt/hermes-agent（必须与打包路径一致！）
  TARBALL            离线包路径，默认与脚本同目录的 hermes-desktop-arm64-offline.tar.gz
EOF
    exit 0
}

ask_yes_no() {  # $1=问题 $2=默认(y|n)，--yes 直接返回 0
    local question="$1" default="${2:-n}" answer=""
    if [ "$ASSUME_YES" -eq 1 ]; then
        info "$question 是（--yes）"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "$question 当前不是交互终端，按默认“$default”处理（可使用 --yes）"
        [ "$default" = "y" ]; return
    fi
    if [ "$default" = "y" ]; then printf '%s [Y/n] ' "$question"; else printf '%s [y/N] ' "$question"; fi
    read -r answer || answer=""
    case "$answer" in
        "") [ "$default" = "y" ] ;;
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-desktop) NO_DESKTOP=1 ;;
        --no-menu) NO_MENU=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
    shift
done

TARBALL="${TARBALL:-$SCRIPT_DIR/hermes-desktop-arm64-offline.tar.gz}"

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    step "卸载 Hermes Agent"
    [ "$(id -u)" -eq 0 ] || die "卸载需要 root：sudo bash $0 --uninstall"
    if [ -d "$INSTALL_DIR" ]; then
        if ask_yes_no "确认删除 $INSTALL_DIR ？" "n"; then
            rm -rf "$INSTALL_DIR"
            info "已删除 $INSTALL_DIR"
        fi
    fi
    for f in /usr/share/applications/hermes-agent.desktop; do
        [ -f "$f" ] && rm -f "$f" && info "已删除开始菜单项: $f"
    done
    for d in "$(sudo -u "${SUDO_USER:-$USER}" xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")" \
             "/home/${SUDO_USER:-}/桌面" "/home/${SUDO_USER:-}/Desktop"; do
        [ -f "$d/hermes-agent.desktop" ] && rm -f "$d/hermes-agent.desktop" && info "已删除桌面快捷方式: $d/hermes-agent.desktop"
    done
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database /usr/share/applications 2>/dev/null || true
    info "卸载完成。"
    exit 0
fi

# ---------------------------------------------------------------------------
# 步骤0：自检
# ---------------------------------------------------------------------------
step "步骤0：环境自检"
[ "$(id -u)" -eq 0 ] || die "本脚本需要 root 写入 /opt：sudo bash $0"
[ -f "$TARBALL" ] || die "未找到离线包: $TARBALL
  请把 make-offline-package.sh 生成的 hermes-desktop-arm64-offline.tar.gz
  与本脚本放在同一目录，或用 TARBALL=路径 指定。"
[ "$(uname -m)" = "aarch64" ] || warn "当前架构 $(uname -m) 不是 aarch64，本包为 arm64 构建。"
command -v tar >/dev/null 2>&1 || die "缺少命令: tar"
info "离线包: $TARBALL ($(du -h "$TARBALL" | awk '{print $1}'))"

# ---------------------------------------------------------------------------
# 步骤1：解压（路径必须与打包机一致）
# ---------------------------------------------------------------------------
step "步骤1：解压到 $INSTALL_DIR"
if [ "$INSTALL_DIR" != "/opt/hermes-agent" ]; then
    warn "安装位置被改为 $INSTALL_DIR"
    warn "包内 venv 以 editable 方式安装、shebang 指向 /opt/hermes-agent，"
    warn "换路径会导致 hermes 无法启动！非必要请勿修改 INSTALL_DIR。"
    ask_yes_no "仍要继续吗？" "n" || die "已中止。"
fi

if [ -e "$INSTALL_DIR" ]; then
    warn "$INSTALL_DIR 已存在。"
    if ask_yes_no "是否备份旧版本（重命名为 .bak-<时间戳>）后继续安装？" "y"; then
        mv "$INSTALL_DIR" "$INSTALL_DIR.bak-$(date +%Y%m%d-%H%M%S)"
        info "旧版本已备份（确认新版正常后可手动删除）"
    else
        die "已中止。请手动处理 $INSTALL_DIR 后重试。"
    fi
fi
mkdir -p /opt

info "正在解压（约需几分钟）..."
tar xzf "$TARBALL" -C /opt
[ -d "$INSTALL_DIR" ] || die "解压后未找到 $INSTALL_DIR，tar 包内容结构异常。"
[ -x "$INSTALL_DIR/hermes-venv/bin/hermes" ] || die "$INSTALL_DIR/hermes-venv/bin/hermes 不存在或不可执行，包不完整。"

# ---------------------------------------------------------------------------
# 步骤2：验证
# ---------------------------------------------------------------------------
step "步骤2：验证安装"
VER_OUT="$("$INSTALL_DIR/hermes-venv/bin/hermes" --version 2>&1 | head -n 1)" \
    || die "hermes 命令无法启动，包可能损坏。"
info "✓ hermes 可运行: $VER_OUT"

# 输出打包时记录的版本（version.txt 由 make-offline-package.sh 生成）
if [ -f "$INSTALL_DIR/version.txt" ]; then
    PKG_VER="$(sed -n 's/^version=//p' "$INSTALL_DIR/version.txt" | head -n 1)"
    info "✓ 包版本: ${PKG_VER:-未知}"
    sed 's/^/    /' "$INSTALL_DIR/version.txt"
else
    warn "未找到 version.txt（旧包未包含版本记录）"
fi

# ---------------------------------------------------------------------------
# 步骤3：生成环境文件（核心修复：桌面端后端探测指路）
# ---------------------------------------------------------------------------
step "步骤3：生成 $INSTALL_DIR/env.sh"
cat > "$INSTALL_DIR/env.sh" <<EOF
# Hermes 运行时环境（由 install-offline-package.sh 生成）
# 注意：HERMES_HOME 保持默认 ~/.hermes（/opt 归 root，普通用户写不进，
# hermes 首次运行会自动落到当前用户目录）。
export PATH="$INSTALL_DIR/node/bin:$INSTALL_DIR/hermes-venv/bin:\$PATH"
# 桌面端后端探测顺序：HERMES_DESKTOP_HERMES_ROOT → HERMES_DESKTOP_HERMES → 托管安装。
# 不设置会弹 "Set up Hermes Desktop" 向导并尝试联网自装（离线机必失败）。
export HERMES_DESKTOP_HERMES_ROOT="$INSTALL_DIR"
export HERMES_DESKTOP_HERMES="$INSTALL_DIR/hermes-venv/bin/hermes"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/playwright-cache"
EOF
chmod +x "$INSTALL_DIR/env.sh"
info "已生成 env.sh（含 HERMES_DESKTOP_HERMES_ROOT 指路变量）"

# ---------------------------------------------------------------------------
# 步骤4：启动器
# ---------------------------------------------------------------------------
step "步骤4：生成启动器 $INSTALL_DIR/bin/hermes-desktop.sh"
mkdir -p "$INSTALL_DIR/bin"
cat > "$INSTALL_DIR/bin/hermes-desktop.sh" <<'EOF'
#!/bin/bash
# Hermes Agent 桌面启动器（source 环境后拉起桌面端，探测顺序：AppImage → unpacked → gateway+浏览器）
source /opt/hermes-agent/env.sh

# 1) AppImage（若打包时收集了）
APPIMAGE="$(find /opt/hermes-agent/electron-app /opt/hermes-agent/apps/desktop/release /opt/hermes-agent/apps/desktop/dist \
            -maxdepth 1 -name '*.AppImage' -type f 2>/dev/null | head -n 1)"
if [ -n "$APPIMAGE" ]; then
    exec "$APPIMAGE" "$@" 2>/dev/null || exec "$APPIMAGE" --no-sandbox "$@"
fi

# 2) unpacked 目录：主二进制在 linux-*-unpacked/ 顶层，名字由 productName 决定（如 Hermes），
#    用排除法去掉 chrome-sandbox / crashpad_handler / 动态库
APPDIR="$(find /opt/hermes-agent/electron-app /opt/hermes-agent/apps/desktop/release /opt/hermes-agent/apps/desktop/dist \
          -maxdepth 2 -type d -name '*-unpacked' 2>/dev/null | head -n 1)"
if [ -n "$APPDIR" ]; then
    BIN="$(find "$APPDIR" -maxdepth 1 -type f -executable \
            ! -name 'chrome*' ! -name 'crashpad*' ! -name '*.so*' 2>/dev/null | head -n 1)"
    if [ -n "$BIN" ]; then
        exec "$BIN" "$@" 2>/dev/null || exec "$BIN" --no-sandbox "$@"
    fi
fi

# 3) 兜底：gateway + 系统浏览器
echo "[提示] 未找到桌面产物，退回 gateway + 浏览器模式" >&2
hermes gateway run &
GW_PID=$!
for _ in $(seq 1 60); do
    (echo >/dev/tcp/127.0.0.1/8642) 2>/dev/null && break
    sleep 1
done
xdg-open "http://127.0.0.1:8642" >/dev/null 2>&1 || echo "请手动打开: http://127.0.0.1:8642"
wait $GW_PID
EOF
chmod +x "$INSTALL_DIR/bin/hermes-desktop.sh"
info "已生成 hermes-desktop.sh；命令行入口: $INSTALL_DIR/bin/hermes（venv 自带）"

# ---------------------------------------------------------------------------
# 步骤5：快捷方式
# ---------------------------------------------------------------------------
step "步骤5：创建快捷方式"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || { warn "无法确定目标用户主目录，跳过桌面快捷方式。"; NO_DESKTOP=1; }

MENU_MADE=0
if [ "$NO_MENU" -eq 0 ]; then
    if ask_yes_no "是否在开始菜单创建 Hermes Agent 入口（所有用户可见）？" "y"; then
        cat > /usr/share/applications/hermes-agent.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Hermes Agent
Comment=Hermes Agent 桌面端
Exec=/opt/hermes-agent/bin/hermes-desktop.sh
Icon=/opt/hermes-agent/apps/desktop/assets/icon.png
Terminal=false
Categories=Development;Utility;
StartupNotify=true
EOF
        chmod +x /usr/share/applications/hermes-agent.desktop
        MENU_MADE=1
        command -v update-desktop-database >/dev/null 2>&1 && \
            update-desktop-database /usr/share/applications 2>/dev/null || true
        info "✓ 开始菜单入口: /usr/share/applications/hermes-agent.desktop"
    fi
fi

DESKTOP_MADE=0
if [ "$NO_DESKTOP" -eq 0 ]; then
    DESKTOP_DIR=""
    for d in "$TARGET_HOME/桌面" "$TARGET_HOME/Desktop"; do
        [ -d "$d" ] && { DESKTOP_DIR="$d"; break; }
    done
    if [ -n "$DESKTOP_DIR" ]; then
        if ask_yes_no "是否在 $TARGET_USER 的桌面创建快捷方式？" "y"; then
            cat > "$DESKTOP_DIR/hermes-agent.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hermes Agent
Comment=Hermes Agent 桌面端
Exec=/opt/hermes-agent/bin/hermes-desktop.sh
Icon=/opt/hermes-agent/apps/desktop/assets/icon.png
Terminal=false
Categories=Development;Utility;
StartupNotify=true
EOF
            chmod +x "$DESKTOP_DIR/hermes-agent.desktop"
            chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
                "$DESKTOP_DIR/hermes-agent.desktop" 2>/dev/null || true
            sudo -u "$TARGET_USER" gio set "$DESKTOP_DIR/hermes-agent.desktop" metadata::trusted true 2>/dev/null || true
            DESKTOP_MADE=1
            info "✓ 桌面快捷方式: $DESKTOP_DIR/hermes-agent.desktop"
        fi
    else
        warn "未找到 $TARGET_USER 的桌面目录，跳过。"
    fi
fi

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
step "安装完成"
cat <<EOF

  安装位置:   $INSTALL_DIR
  桌面启动:   $INSTALL_DIR/bin/hermes-desktop.sh
              （或开始菜单/桌面双击 "Hermes Agent"）
  命令行:     $INSTALL_DIR/hermes-venv/bin/hermes --help
  卸载:       sudo bash "$SCRIPT_DIR/$(basename "$0")" --uninstall

  注意:
    - 数据目录为各用户 ~/.hermes（首启自动创建）；
    - 若桌面图标双击无反应，右键 → 允许启动（UKUI 安全机制）；
    - 建议首次启动前断网验证离线功能完整。

EOF
