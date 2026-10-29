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
CN_MIRROR=0
CLEAN_BUILD=0     # --clean：无条件清空构建目录
KEEP_BUILD=0      # --keep：保留构建目录（仅清理源码残留）

# ---------------------------------------------------------------------------
# 输出与交互
# ---------------------------------------------------------------------------
step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

# g++ 版本过低（<10）时 node-pty 编译会因 -std=gnu++20 失败，给出固定处置命令
print_gxx_hint() {
    cat >&2 <<'EOF'

[提示] 检测到 C++20 编译失败 / GCC 版本过低
  Node 26 的 include/node/common.gypi 使用 -std=gnu++20，需要 GCC 10 及以上；
  麒麟 V10 / Ubuntu 20.04 默认是 GCC 9，只认 -std=gnu++2a，于是在编译 node-pty 时报：
      g++: error: unrecognized command line option '-std=gnu++20'

  请执行以下命令升级默认编译器，然后重跑本脚本：

      sudo apt install gcc-10 g++-10
      sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
      sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
      g++ --version   # 应显示 10.x

  若发行版源里是更新的版本（如 12），把上面两行里的 10 换成对应版本即可。

EOF
}

# 执行 npm install，失败时给出针对性诊断（C++20 编译器过老 / 头文件下载超时）
npm_install() {
    local log rc
    log="$INSTALL_DIR/.npm-install.log"
    set +e
    npm "$@" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        echo ""
        if grep -qE "std=gnu\+\+20|unrecognized command line option" "$log" 2>/dev/null; then
            print_gxx_hint
        elif grep -qE "headers\.tar\.gz|ETIMEDOUT|ECONNRESET" "$log" 2>/dev/null; then
            warn "node-gyp 下载 Node 头文件失败。脚本已设置 npm_config_nodedir 指向随包头文件，"
            warn "若该目录缺失，可加 --cn-mirror 重跑以走 npmmirror 的头文件镜像。"
        fi
        die "npm $* 失败（退出码 $rc），日志: $log"
    fi
}

# 只在变量为空时设置，尊重用户已有的环境变量
set_default_env() {
    local name="$1" value="$2"
    if [ -z "${!name:-}" ]; then
        export "$name=$value"
        info "  $name=$value"
    else
        info "  $name=${!name}（沿用已有设置）"
    fi
}

# 国内镜像：PyPI / npm / Electron / Playwright 全部换到国内源
apply_cn_mirrors() {
    step "步骤2.5：启用国内镜像"

    # PyPI：UV_DEFAULT_INDEX 是新名字，UV_INDEX_URL 是旧别名，两者给同一个值
    if [ -n "${UV_DEFAULT_INDEX:-}" ] || [ -n "${UV_INDEX_URL:-}" ]; then
        info "  PyPI=${UV_DEFAULT_INDEX:-$UV_INDEX_URL}（沿用已有设置）"
    else
        export UV_DEFAULT_INDEX="https://mirrors.aliyun.com/pypi/simple/"
        export UV_INDEX_URL="$UV_DEFAULT_INDEX"
        info "  PyPI=$UV_DEFAULT_INDEX"
    fi

    set_default_env npm_config_registry "https://registry.npmmirror.com"
    set_default_env ELECTRON_MIRROR "https://npmmirror.com/mirrors/electron/"
    set_default_env PLAYWRIGHT_DOWNLOAD_HOST "https://npmmirror.com/mirrors/playwright"

    info "  （已自行设置的同名环境变量不会被覆盖）"
}

usage() {
    cat <<'EOF'
用法: ./make-offline-package.sh [选项]

选项:
  -f, --redownload   强制重新下载最新源码（忽略已有的 latest 记录）
  -y, --yes          所有交互询问自动回答“是”
      --fetch-only   只检测/下载源码，不继续打包
      --cn-mirror    使用国内镜像（PyPI/npm/Electron/Playwright），国内打包机强烈建议
      --clean        构建目录非空时无条件清空重建（等价于对询问回答“是”）
      --keep         保留构建目录（复用已装好的 venv，仅清理旧源码残留）
  -h, --help         显示本帮助

环境变量:
  HERMES_REPO         上游仓库，默认 NousResearch/hermes-agent
  HERMES_VERSION      强制指定源码版本（tag / 分支 / 提交 sha）
  HERMES_USE_HEAD=1   跳过 Release/tag，直接取默认分支最新提交
  HERMES_BRANCH       默认分支名，默认 main
  HERMES_INSTALL_DIR  打包时的安装目录，默认 /opt/hermes-agent
  OUTPUT_DIR          离线包输出目录，默认 dist（已被 .gitignore 忽略）
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
        --cn-mirror) CN_MIRROR=1 ;;
        --clean) CLEAN_BUILD=1 ;;
        --keep) KEEP_BUILD=1 ;;
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

if [ "$(id -u)" -eq 0 ]; then
    warn "正在以 root 身份运行：npm 缓存会写到 /root/.npm，产物文件也归 root。"
    warn "建议改用普通用户执行（脚本内部已按需调用 sudo）。"
fi

# node-pty 在 arm64 上没有预编译包，必须用本地工具链编译
MISSING_TOOLS=""
for c in make g++ python3; do
    command -v "$c" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $c"
done
if [ -n "$MISSING_TOOLS" ]; then
    warn "缺少编译工具:$MISSING_TOOLS"
    warn "node-pty 等原生模块需要在打包机上现场编译（arm64 没有预编译产物）。"
    [ "${HERMES_SKIP_TOOLCHECK:-0}" = "1" ] || die "请先安装编译工具后再运行:
        sudo apt install -y build-essential python3
      （如确认不需要编译，可用 HERMES_SKIP_TOOLCHECK=1 跳过本检查）"
fi

# node-pty 需要 GCC >= 10（Node 26 的 common.gypi 用 -std=gnu++20）
GXX_MAJOR="$(g++ -dumpversion 2>/dev/null | cut -d. -f1)"
if [ -n "${GXX_MAJOR:-}" ] && [ "$GXX_MAJOR" -lt 10 ] 2>/dev/null; then
    warn "当前 g++ 主版本为 $GXX_MAJOR，低于编译 node-pty 所需的 GCC 10"
    if [ "${HERMES_ALLOW_OLD_GXX:-0}" = "1" ]; then
        warn "已设置 HERMES_ALLOW_OLD_GXX=1，继续（步骤8 可能失败）。"
    else
        print_gxx_hint
        ask_yes_no "仍要继续吗？（大概率在步骤8编译 node-pty 时失败）" || die "已中止。按上面的命令升级编译器后重跑。"
    fi
fi

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
# 构建目录处理：旧源码残留会让 mv 失败（如 website/ 已存在）
# ---------------------------------------------------------------------------
dir_nonempty() {
    [ -d "$1" ] || return 1
    [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

# 保留 venv/node 等构建产物，只删旧源码
clean_stale_source() {
    local keep=" hermes-venv uv node node_modules electron-cache playwright-cache "
    local entry base removed=0
    shopt -s dotglob nullglob
    for entry in "$INSTALL_DIR"/*; do
        base="${entry##*/}"
        case "$keep" in *" $base "*) continue ;; esac
        rm -rf "$entry" 2>/dev/null || sudo rm -rf "$entry"
        removed=$((removed + 1))
    done
    shopt -u dotglob nullglob
    info "已清理 $removed 个旧源码条目，保留 hermes-venv / uv / node / node_modules / 缓存目录"
}

prepare_build_dir() {
    step "步骤1：创建安装目录"
    if dir_nonempty "$INSTALL_DIR"; then
        local count size listing
        count="$(ls -A "$INSTALL_DIR" | wc -l)"
        size="$(du -sh "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')"
        listing="$(ls -A "$INSTALL_DIR" | head -n 8 | tr '\n' ' ')"
        warn "构建目录已存在且非空: $INSTALL_DIR"
        info "  顶层条目 $count 个，占用 ${size:-未知}，例如: $listing"
        info "  上一次构建的源码残留在里面，新源码解压时会与它冲突（如 website/ 已存在导致 mv 失败）。"

        if [ "$CLEAN_BUILD" -eq 1 ]; then
            info "已指定 --clean：清空整个目录后重建。"
        elif [ "$KEEP_BUILD" -eq 1 ]; then
            info "已指定 --keep：保留 venv/node 等构建产物，仅清理旧源码。"
            clean_stale_source
            return 0
        elif ask_yes_no "是否清空 $INSTALL_DIR 整个目录后重新构建？（选 N 则保留 venv，只清理旧源码）"; then
            info "选择清空：venv 与 npm 依赖也会重建（uv 缓存仍在，速度尚可）。"
        else
            info "选择保留：仅清理旧源码，复用已有的 venv / node / node_modules。"
            clean_stale_source
            return 0
        fi

        sudo rm -rf "$INSTALL_DIR"
    fi
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown "$(whoami):$(whoami)" "$INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# 开始打包
# ---------------------------------------------------------------------------
prepare_build_dir

step "步骤2：统一环境变量（内外网一致）"
export HERMES_AGENT_ROOT="$INSTALL_DIR"
export UV_NO_CONFIG=1
export UV_PYTHON_INSTALL_DIR="$INSTALL_DIR/uv/python"
export ELECTRON_CACHE="$INSTALL_DIR/electron-cache"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/playwright-cache"
export NODE_PATH="$INSTALL_DIR/node_modules"
export PATH="$INSTALL_DIR/node/bin:$PATH"

if [ "$CN_MIRROR" -eq 1 ]; then
    set_default_env UV_HTTP_TIMEOUT "120"
    apply_cn_mirrors
fi

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

extract_source() {
    cd "$INSTALL_DIR"

    # 先解压到临时目录，确认无同名冲突后再搬进根目录，
    # 避免中途失败留下半新半旧的源码树。
    SRC_TMP="$INSTALL_DIR/.src-extract"
    rm -rf "$SRC_TMP"
    mkdir -p "$SRC_TMP"
    unzip -q "$SRC_ZIP" -d "$SRC_TMP"
    SRC_TOP="$(find "$SRC_TMP" -maxdepth 1 -mindepth 1 -type d -name 'hermes-agent-*' | head -n 1)"
    [ -n "$SRC_TOP" ] || die "源码包解压后未找到 hermes-agent-* 目录: $SRC_ZIP"

    # 同名冲突检查（build 产物 hermes-venv/uv/node 等不与源码重名，重名即说明是残留）
    CONFLICTS=()
    shopt -s dotglob nullglob
    for entry in "$SRC_TOP"/*; do
        base="${entry##*/}"
        [ -e "$INSTALL_DIR/$base" ] && CONFLICTS+=("$base")
    done
    shopt -u dotglob nullglob
    if [ ${#CONFLICTS[@]} -gt 0 ]; then
        rm -rf "$SRC_TMP"
        die "目标目录中已存在同名条目，直接覆盖会丢文件：${CONFLICTS[*]}
          这些是上一次构建的源码残留。请执行：
            ./make-offline-package.sh --clean        # 清空 $INSTALL_DIR 重建
            ./make-offline-package.sh --keep         # 保留 venv，只清理旧源码"
    fi

    shopt -s dotglob nullglob
    mv "$SRC_TOP"/* "$INSTALL_DIR"/
    shopt -u dotglob nullglob
    rm -rf "$SRC_TMP"
    [ -f "$INSTALL_DIR/pyproject.toml" ] || die "源码解压异常：$INSTALL_DIR 下缺少 pyproject.toml"
}


step "步骤5：解压源码到根目录（无 src/ 层）"
extract_source

step "步骤6：安装 Hermes Python 依赖"
uv pip install -e ".[all,dev]"
uv pip install playwright

step "步骤7：部署 Node.js"
cd "$INSTALL_DIR"
tar xf "$OFFLINE_DIR/$NODE_ARCHIVE" -C .
rm -rf node
mv "$NODE_DIR" node

# node-pty 等原生模块在 arm64 上没有预编译包，需要 node-gyp 现场编译。
# node-gyp 默认去 nodejs.org 下载头文件（国内经常超时），
# 而随包的 Node 压缩包自带 include/node/*.h 与 common.gypi，直接指向它即可离线编译。
# 注意：用 .npmrc 而不是 npm_config_nodedir 环境变量，后者会让 npm 报 "Unknown env config"。
NPMRC_TOUCHED=()
write_nodedir_npmrc() {
    local dir file
    for dir in "$INSTALL_DIR" "$INSTALL_DIR/apps/desktop"; do
        [ -d "$dir" ] || continue
        file="$dir/.npmrc"
        if [ -f "$file" ] && grep -q '^nodedir=' "$file"; then
            info "已有 nodedir 配置，跳过: $file"
            continue
        fi
        printf 'nodedir=%s\n' "$INSTALL_DIR/node" >> "$file"
        NPMRC_TOUCHED+=("$file")
        info "已写入 node-gyp 头文件路径: $file"
    done
}

if [ -f "$INSTALL_DIR/node/include/node/common.gypi" ]; then
    write_nodedir_npmrc
else
    warn "随包 Node 缺少 include/node 头文件，原生模块需联网下载头文件"
    [ "$CN_MIRROR" -eq 1 ] && export npm_config_disturl="https://npmmirror.com/mirrors/node"
fi

npm_install install -g npm@latest

step "步骤8：安装 npm 依赖"
npm_install install
cd apps/desktop
npm_install install

step "步骤9：预下载 Electron"
mkdir -p "$ELECTRON_CACHE"

# root 下 Chromium 拒绝启动（除非加 --no-sandbox），这里容错：
# 只要二进制就位就算预下载成功，版本号打印失败不阻断打包。
ELECTRON_BIN="$INSTALL_DIR/node_modules/electron/dist/electron"
ELECTRON_ARGS=(--version)
[ "$(id -u)" -eq 0 ] && ELECTRON_ARGS=(--no-sandbox --version)

if ! npx electron "${ELECTRON_ARGS[@]}"; then
    warn "Electron 自检失败（root 沙箱限制或缺图形库都可能导致，属常见情况）"
    if [ -x "$ELECTRON_BIN" ]; then
        info "二进制已就位，继续打包: $ELECTRON_BIN"
    else
        die "Electron 未下载成功，请检查网络，或设置 ELECTRON_MIRROR 后重跑"
    fi
fi

step "步骤10：构建桌面应用"
cd "$INSTALL_DIR/apps/desktop"
npm run pack

step "步骤11：预下载 Playwright 浏览器"
cd "$INSTALL_DIR"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
"$INSTALL_DIR/hermes-venv/bin/python" -m playwright install chromium

step "步骤12：打包到输出目录"

# 打包前清掉只为本次构建写入的 nodedir 配置，避免随包发给目标机
for _npmrc in ${NPMRC_TOUCHED[@]+"${NPMRC_TOUCHED[@]}"}; do
    [ -f "$_npmrc" ] || continue
    sed -i '/^nodedir=/d' "$_npmrc"
    [ -s "$_npmrc" ] || rm -f "$_npmrc"
    info "已清理构建期 npm 配置: $_npmrc"
done

OUT_DIR="${OUTPUT_DIR:-$OFFLINE_DIR/dist}"
mkdir -p "$OUT_DIR"

# 安装脚本与产物放在一起，目标机整目录拷走即可
if [ -f "$OFFLINE_DIR/install-offline-package.sh" ]; then
    cp -f "$OFFLINE_DIR/install-offline-package.sh" "$OUT_DIR/"
    info "已复制安装脚本: $OUT_DIR/install-offline-package.sh"
fi

cd /opt
sudo tar czvf "$OUT_DIR/hermes-desktop-arm64-offline.tar.gz" hermes-agent/

echo ""
echo "✓ 打包完成: $OUT_DIR/hermes-desktop-arm64-offline.tar.gz"
du -sh "$OUT_DIR/hermes-desktop-arm64-offline.tar.gz"
echo "  源码版本: ${SRC_REF:-未知}"
echo "  目标机安装: 把 $OUT_DIR 下两个文件拷到同一目录，执行 bash install-offline-package.sh"
