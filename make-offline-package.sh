#!/bin/bash
# =============================================================================
# Hermes Agent 离线安装包打包脚本
#
# 在“联网的 arm64 打包机”上运行，产出可以在内网（无外网）麒麟 V10 上
# 直接安装的 hermes-desktop-arm64-offline.tar.gz。
#
# 源码版本解析规则：
#   1. 若存在 $OFFLINE_DIR/latest 且其中的源码包也在，则询问用户是否重新下载；
#      用户选择“否”时直接复用现有源码包。
#   2. latest 不存在（或源码包丢失、或用户选择重新下载）时，自动从
#      GitHub 解析并下载最新版源码：
#        a) 最新 Release 的 tag（默认）
#        b) 没有 Release 时退回最新 tag
#        c) 仍然没有则退回默认分支最新提交（sha）
#   3. 环境变量 HERMES_VERSION 可以强制指定版本（tag / 分支 / 提交 sha）。
#
# 用法：
#   ./make-offline-package.sh                # 交互式
#   ./make-offline-package.sh --redownload   # 强制重新下载源码
#   ./make-offline-package.sh --yes          # 所有询问自动回答“是”
#   ./make-offline-package.sh --fetch-only   # 只下载源码，不打包
#   ./make-offline-package.sh --help
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 基本路径
# ---------------------------------------------------------------------------
OFFLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/opt/hermes-agent}"

# 上游仓库与本地状态文件
HERMES_REPO="${HERMES_REPO:-NousResearch/hermes-agent}"
LATEST_FILE="$OFFLINE_DIR/latest"

# 随包工具链（保持与仓库内文件名一致）
UV_ARCHIVE="uv-aarch64-unknown-linux-gnu.tar.gz"
NODE_ARCHIVE="node-v26.2.0-linux-arm64.tar.xz"
NODE_DIR="node-v26.2.0-linux-arm64"
PYTHON_VERSION="${HERMES_PYTHON_VERSION:-3.11}"

# 运行开关
FORCE_DOWNLOAD=0
ASSUME_YES=0
FETCH_ONLY=0

# ---------------------------------------------------------------------------
# 输出与交互
# ---------------------------------------------------------------------------
step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: ./make-offline-package.sh [选项]

选项:
  -f, --redownload   强制重新下载最新源码（忽略已有的 latest 记录）
  -y, --yes          所有交互询问自动回答“是”
      --fetch-only   只检测/下载源码，不继续打包
  -h, --help         显示本帮助

环境变量:
  HERMES_REPO         上游仓库，默认 NousResearch/hermes-agent
  HERMES_VERSION      强制指定源码版本（tag / 分支 / 提交 sha）
  HERMES_USE_HEAD=1   跳过 Release/tag，直接取默认分支最新提交
  HERMES_BRANCH       默认分支名，默认 main
  HERMES_INSTALL_DIR  打包时的安装目录，默认 /opt/hermes-agent
  OUTPUT_DIR          离线包输出目录，默认 dists/hermes-desktop-arm64-with-python-packages
EOF
    exit 0
}

# ask_yes_no "问题" —— 默认回答“否”；--yes 时直接返回“是”
ask_yes_no() {
    local question="$1" answer=""
    if [ "$ASSUME_YES" -eq 1 ]; then
        info "$question 是（--yes）"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "$question 当前不是交互终端，按“否”处理（可使用 --yes / --redownload）"
        return 1
    fi
    printf '%s [y/N] ' "$question"
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--redownload|--force-download) FORCE_DOWNLOAD=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --fetch-only) FETCH_ONLY=1 ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 联网工具
# ---------------------------------------------------------------------------
HTTP_CLIENT=""
if command -v curl >/dev/null 2>&1; then
    HTTP_CLIENT="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP_CLIENT="wget"
fi

http_get() {
    case "$HTTP_CLIENT" in
        curl) curl -fsSL --connect-timeout 20 --max-time 60 "$1" ;;
        wget) wget -qO- --timeout=60 "$1" ;;
        *) die "需要 curl 或 wget 才能访问 GitHub" ;;
    esac
}

http_download() {  # $1=url  $2=输出文件
    case "$HTTP_CLIENT" in
        curl) curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1" ;;
        wget) wget -q --show-progress -O "$2" "$1" ;;
        *) die "需要 curl 或 wget 才能下载源码" ;;
    esac
}

# 从 GitHub JSON 里取第一个字符串字段，例如 tag_name / sha
json_field() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# 解析“最新版本”，输出 "<ref> <kind>"，kind ∈ tag | sha
resolve_newest_ref() {
    local ref="" kind=""

    if [ -n "${HERMES_VERSION:-}" ]; then
        printf '使用环境变量指定的版本: %s\n' "$HERMES_VERSION" >&2
        printf '%s tag\n' "$HERMES_VERSION"
        return 0
    fi

    if [ "${HERMES_USE_HEAD:-0}" != "1" ]; then
        # 1) 最新 Release
        ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/releases/latest" 2>/dev/null | json_field tag_name || true)"
        if [ -n "$ref" ]; then
            printf '%s tag\n' "$ref"
            return 0
        fi
        # 2) 最新 tag
        ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/tags?per_page=1" 2>/dev/null | json_field name || true)"
        if [ -n "$ref" ]; then
            printf '%s tag\n' "$ref"
            return 0
        fi
        warn "GitHub 上没有可用 Release / tag，退回默认分支最新提交"
    fi

    # 3) 默认分支最新提交
    ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/commits/${HERMES_BRANCH:-main}" 2>/dev/null | json_field sha || true)"
    [ -n "$ref" ] || die "无法从 GitHub 解析 $HERMES_REPO 的最新版本（检查网络/代理）"
    printf '%s sha\n' "$ref"
}

# 读取 latest 文件中的某个键
latest_value() {
    sed -n "s/^$1=//p" "$LATEST_FILE" 2>/dev/null | head -n 1
}

# 下载指定 ref 的源码包，并写入 latest
download_source() {
    local ref="$1" kind="$2" url archive tmp

    case "$kind" in
        tag)  url="https://codeload.github.com/$HERMES_REPO/zip/refs/tags/$ref" ;;
        sha)  url="https://codeload.github.com/$HERMES_REPO/zip/$ref" ;;
        *)    die "未知的引用类型: $kind" ;;
    esac

    archive="$OFFLINE_DIR/hermes-agent-${ref#v}.zip"
    tmp="$archive.part"

    info "下载源码: $url"
    rm -f "$tmp"
    http_download "$url" "$tmp" || { rm -f "$tmp"; die "源码下载失败，请检查网络或使用 HERMES_VERSION 手动指定版本后重试"; }
    [ -s "$tmp" ] || { rm -f "$tmp"; die "下载得到的文件为空: $url"; }

    # GitHub 出错时可能返回一个很小的页面而不是 zip
    if ! unzip -tqq "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "下载内容不是有效的 zip 包: $url"
    fi

    mv -f "$tmp" "$archive"

    {
        printf 'ref=%s\n' "$ref"
        printf 'kind=%s\n' "$kind"
        printf 'repo=%s\n' "$HERMES_REPO"
        printf 'archive=%s\n' "$(basename "$archive")"
        printf 'url=%s\n' "$url"
        printf 'sha256=%s\n' "$(sha256sum "$archive" | awk '{print $1}')"
        printf 'downloaded=%s\n' "$(date -Iseconds)"
    } > "$LATEST_FILE"

    info "已保存: $archive"
    info "版本记录: $LATEST_FILE"
}

# 决定使用哪个源码包，结果写入 SRC_ZIP
acquire_source() {
    local need_download=1 ref="" kind="" archive=""

    if [ -f "$LATEST_FILE" ]; then
        ref="$(latest_value ref)"
        kind="$(latest_value kind)"
        archive="$(latest_value archive)"
        info "检测到 latest 版本记录: ${ref:-未知}（来源: ${kind:-未知}）"
        [ -n "$archive" ] && info "对应源码包: $archive"

        if [ -z "$archive" ] || [ ! -f "$OFFLINE_DIR/$archive" ]; then
            warn "latest 记录的源码包不存在，需要重新下载"
            need_download=1
        elif [ "$FORCE_DOWNLOAD" -eq 1 ]; then
            info "已指定 --redownload，重新下载源码"
            need_download=1
        elif ask_yes_no "是否重新下载 Hermes Agent 最新源码？（选 N 则复用现有 ${archive}）"; then
            need_download=1
        else
            info "复用现有源码包: $OFFLINE_DIR/$archive"
            SRC_ZIP="$OFFLINE_DIR/$archive"
            SRC_REF="$ref"
            return 0
        fi
    else
        info "未找到 $LATEST_FILE（首次打包），将自动下载最新源码"
    fi

    if [ "$need_download" -eq 1 ]; then
        local resolved
        resolved="$(resolve_newest_ref)"
        ref="${resolved% *}"
        kind="${resolved#* }"
        info "解析到最新版本: $ref（$kind）"
        download_source "$ref" "$kind"
        SRC_ZIP="$OFFLINE_DIR/hermes-agent-${ref#v}.zip"
        SRC_REF="$ref"
    fi
}

# ---------------------------------------------------------------------------
# 打包前自检
# ---------------------------------------------------------------------------
step "步骤0：环境自检"
command -v sudo >/dev/null 2>&1 || die "需要 sudo 权限写入 $INSTALL_DIR"
for f in "$UV_ARCHIVE" "$NODE_ARCHIVE"; do
    [ -f "$OFFLINE_DIR/$f" ] || die "缺少 $f，请先把它放到 $OFFLINE_DIR"
done
for c in tar unzip; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done

step "步骤0.5：准备 Hermes Agent 源码"
acquire_source
info "使用源码包: $SRC_ZIP"
info "源码版本:   ${SRC_REF:-未知}（$(du -h "$SRC_ZIP" | awk '{print $1}')）"

if [ "$FETCH_ONLY" -eq 1 ]; then
    echo ""
    echo "✓ 仅获取源码（--fetch-only），未执行后续打包步骤。"
    exit 0
fi

# ---------------------------------------------------------------------------
# 开始打包
# ---------------------------------------------------------------------------
step "步骤1：创建安装目录"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(whoami):$(whoami)" "$INSTALL_DIR"

step "步骤2：统一环境变量（内外网一致）"
export HERMES_AGENT_ROOT="$INSTALL_DIR"
export UV_NO_CONFIG=1
export UV_PYTHON_INSTALL_DIR="$INSTALL_DIR/uv/python"
export ELECTRON_CACHE="$INSTALL_DIR/electron-cache"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/playwright-cache"
export NODE_PATH="$INSTALL_DIR/node_modules"
export PATH="$INSTALL_DIR/node/bin:$PATH"

step "步骤3：安装 uv"
cd "$OFFLINE_DIR"
rm -rf uv-aarch64-unknown-linux-gnu
tar xzf "$UV_ARCHIVE"
sudo cp uv-aarch64-unknown-linux-gnu/uv /usr/local/bin/
rm -rf uv-aarch64-unknown-linux-gnu

step "步骤4：创建 Python venv"
uv venv "$INSTALL_DIR/hermes-venv" --python "$PYTHON_VERSION"
# shellcheck disable=SC1091
source "$INSTALL_DIR/hermes-venv/bin/activate"

step "步骤5：解压源码到根目录（无 src/ 层）"
cd "$INSTALL_DIR"
rm -rf ./hermes-agent-*/
unzip -q "$SRC_ZIP" -d "$INSTALL_DIR"
SRC_TOP="$(find "$INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d -name 'hermes-agent-*' | head -n 1)"
[ -n "$SRC_TOP" ] || die "源码包解压后未找到 hermes-agent-* 目录: $SRC_ZIP"
shopt -s dotglob
mv "$SRC_TOP"/* "$INSTALL_DIR"/
shopt -u dotglob
rmdir "$SRC_TOP"
[ -f "$INSTALL_DIR/pyproject.toml" ] || die "源码解压异常：$INSTALL_DIR 下缺少 pyproject.toml"

step "步骤6：安装 Hermes Python 依赖"
uv pip install -e ".[all,dev]"
uv pip install playwright

step "步骤7：部署 Node.js"
cd "$INSTALL_DIR"
tar xf "$OFFLINE_DIR/$NODE_ARCHIVE" -C .
rm -rf node
mv "$NODE_DIR" node
npm install -g npm@latest

step "步骤8：安装 npm 依赖"
npm install
cd apps/desktop
npm install

step "步骤9：预下载 Electron"
mkdir -p "$ELECTRON_CACHE"
npx electron --version

step "步骤10：构建桌面应用"
cd "$INSTALL_DIR/apps/desktop"
npm run pack

step "步骤11：预下载 Playwright 浏览器"
cd "$INSTALL_DIR"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
"$INSTALL_DIR/hermes-venv/bin/python" -m playwright install chromium

step "步骤12：打包到输出目录"
OUT_DIR="${OUTPUT_DIR:-$OFFLINE_DIR/dists/hermes-desktop-arm64-with-python-packages}"
mkdir -p "$OUT_DIR"
cd /opt
sudo tar czvf "$OUT_DIR/hermes-desktop-arm64-offline.tar.gz" hermes-agent/

echo ""
echo "✓ 打包完成: $OUT_DIR/hermes-desktop-arm64-offline.tar.gz"
du -sh "$OUT_DIR/hermes-desktop-arm64-offline.tar.gz"
echo "  源码版本: ${SRC_REF:-未知}"
