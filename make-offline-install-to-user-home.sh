#!/bin/bash
# =============================================================================
# Hermes Agent 离线安装包（用户目录版·随包 venv）—— 打包脚本
#
# 产出 dist/ 两件套:
#   hermes-agent-arm64-offline.tar.gz   # 顶层单层目录 hermes-agent/，--strip-components=1 直装
#   install-to-user-home.sh                  # 由本脚本从同目录拷贝到 dist/
#
# 设计要点:
#   * venv 在打包机完整装好随包走（非 editable，无 .pth 指针问题）
#   * 安装时修复 venv: python/python3 符号链接 + pyvenv.cfg home + bin/* 构建路径替换
#     （构建路径记录在 version.txt 的 build_root）
#   * uv-cache 不进包（构建机留作 --keep 复用），安装无需联网装依赖
#   * 全程普通用户，不需要 root
#
# 用法:
#   ./make-offline-home.sh [--cn-mirror] [--redownload] [--yes] [--clean|--keep] [--fetch-only]
# =============================================================================
set -euo pipefail

OFFLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$OFFLINE_DIR/build}"
PAYLOAD_DIR="$BUILD_ROOT/hermes-agent"               # tar 顶层目录（安装时 strip 掉）
REPO_DIR="$PAYLOAD_DIR/src"                          # 上游源码根
OUT_DIR="${OUTPUT_DIR:-$OFFLINE_DIR/dist}"

HERMES_REPO="${HERMES_REPO:-NousResearch/hermes-agent}"
LATEST_FILE="$OFFLINE_DIR/latest"

UV_ARCHIVE="uv-aarch64-unknown-linux-gnu.tar.gz"
NODE_ARCHIVE="${NODE_ARCHIVE:-node-v26.2.0-linux-arm64.tar.xz}"
NODE_DIR="${NODE_ARCHIVE%.tar.xz}"
PYTHON_VERSION="${HERMES_PYTHON_VERSION:-3.14}"
DESKTOP_DIR="${DESKTOP_DIR:-apps/desktop}"

FORCE_DOWNLOAD=0; ASSUME_YES=0; FETCH_ONLY=0; CN_MIRROR=0; CLEAN_BUILD=0; KEEP_BUILD=0

step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

print_gxx_hint() {
    cat >&2 <<'EOF'

[提示] GCC 版本过低：node-pty 编译需要 GCC 10+（Node 26 使用 -std=gnu++20）
      sudo apt install gcc-10 g++-10
      sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
      sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
EOF
}

npm_install() {
    local log rc; log="$BUILD_ROOT/.npm-install.log"
    set +e; npm "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e
    if [ "$rc" -ne 0 ]; then
        grep -qE "std=gnu\+\+20|unrecognized command line option" "$log" 2>/dev/null && print_gxx_hint
        die "npm $* 失败（退出码 $rc），日志: $log"
    fi
}

pnpm_install() {
    local log rc; log="$BUILD_ROOT/.pnpm-install.log"
    set +e; pnpm "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e
    if [ "$rc" -ne 0 ]; then
        grep -qE "std=gnu\+\+20|unrecognized command line option" "$log" 2>/dev/null && print_gxx_hint
        die "pnpm $* 失败（退出码 $rc），日志: $log"
    fi
}

set_default_env() {
    local name="$1" value="$2"
    if [ -z "${!name:-}" ]; then export "$name=$value"; info "  $name=$value"; else info "  $name=${!name}（沿用）"; fi
}

apply_cn_mirrors() {
    step "步骤2.5：启用国内镜像"
    if [ -n "${UV_DEFAULT_INDEX:-}" ] || [ -n "${UV_INDEX_URL:-}" ]; then
        info "  PyPI=${UV_DEFAULT_INDEX:-$UV_INDEX_URL}（沿用）"
    else
        export UV_DEFAULT_INDEX="https://mirrors.aliyun.com/pypi/simple/"
        export UV_INDEX_URL="$UV_DEFAULT_INDEX"
        info "  PyPI=$UV_DEFAULT_INDEX"
    fi
    set_default_env npm_config_registry "https://registry.npmmirror.com"
    set_default_env ELECTRON_MIRROR "https://npmmirror.com/mirrors/electron/"
    set_default_env ELECTRON_BUILDER_BINARIES_MIRROR "https://npmmirror.com/mirrors/electron-builder-binaries/"
    set_default_env PLAYWRIGHT_DOWNLOAD_HOST "https://npmmirror.com/mirrors/playwright"
    set_default_env UV_PYTHON_INSTALL_MIRROR "https://registry.npmmirror.com/-/binary/python-build-standalone"
    set_default_env UV_HTTP_TIMEOUT "120"
}

usage() {
    cat <<'EOF'
用法: ./make-offline-home.sh [选项]
  -f, --redownload   强制重新下载源码      -y, --yes    询问全答“是”
      --fetch-only   只下载源码            --cn-mirror  国内镜像（强烈建议）
      --clean        无条件清空重建        --keep       保留缓存/运行时只清源码
  -h, --help
环境变量: HERMES_REPO / HERMES_VERSION / HERMES_USE_HEAD=1 / HERMES_BRANCH /
          NODE_ARCHIVE / DESKTOP_DIR / BUILD_ROOT / OUTPUT_DIR
EOF
    exit 0
}

ask_yes_no() {
    local question="$1" answer=""
    if [ "$ASSUME_YES" -eq 1 ]; then info "$question 是（--yes）"; return 0; fi
    if [ ! -t 0 ]; then warn "$question 非交互终端按“否”处理"; return 1; fi
    printf '%s [y/N] ' "$question"
    read -r answer || answer=""
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

HTTP_CLIENT=""
if command -v curl >/dev/null 2>&1; then HTTP_CLIENT="curl";
elif command -v wget >/dev/null 2>&1; then HTTP_CLIENT="wget"; fi

http_get() {
    case "$HTTP_CLIENT" in
        curl) curl -fsSL --connect-timeout 20 --max-time 60 "$1" ;;
        wget) wget -qO- --timeout=60 "$1" ;;
        *) die "需要 curl 或 wget" ;;
    esac
}

http_download() {
    case "$HTTP_CLIENT" in
        curl) curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1" ;;
        wget) wget -q --show-progress -O "$2" "$1" ;;
        *) die "需要 curl 或 wget" ;;
    esac
}

json_field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }

resolve_newest_ref() {
    local ref="" kind=""
    if [ -n "${HERMES_VERSION:-}" ]; then
        printf '%s tag\n' "$HERMES_VERSION"; return 0
    fi
    if [ "${HERMES_USE_HEAD:-0}" != "1" ]; then
        ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/releases/latest" 2>/dev/null | json_field tag_name || true)"
        [ -n "$ref" ] && { printf '%s tag\n' "$ref"; return 0; }
        ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/tags?per_page=1" 2>/dev/null | json_field name || true)"
        [ -n "$ref" ] && { printf '%s tag\n' "$ref"; return 0; }
        warn "无 Release/tag，退回默认分支最新提交"
    fi
    ref="$(http_get "https://api.github.com/repos/$HERMES_REPO/commits/${HERMES_BRANCH:-main}" 2>/dev/null | json_field sha || true)"
    [ -n "$ref" ] || die "无法解析 $HERMES_REPO 最新版本（检查网络）"
    printf '%s sha\n' "$ref"
}

latest_value() { sed -n "s/^$1=//p" "$LATEST_FILE" 2>/dev/null | head -n 1; }

download_source() {
    local ref="$1" kind="$2" url archive tmp
    case "$kind" in
        tag) url="https://codeload.github.com/$HERMES_REPO/zip/refs/tags/$ref" ;;
        sha) url="https://codeload.github.com/$HERMES_REPO/zip/$ref" ;;
        *)   die "未知的引用类型: $kind" ;;
    esac
    archive="$OFFLINE_DIR/hermes-agent-${ref#v}.zip"; tmp="$archive.part"
    info "下载源码: $url"
    rm -f "$tmp"
    http_download "$url" "$tmp" || { rm -f "$tmp"; die "源码下载失败"; }
    [ -s "$tmp" ] || { rm -f "$tmp"; die "下载内容为空: $url"; }
    unzip -tqq "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "下载内容不是有效 zip: $url"; }
    mv -f "$tmp" "$archive"
    {
        printf 'ref=%s\n' "$ref"; printf 'kind=%s\n' "$kind"; printf 'repo=%s\n' "$HERMES_REPO"
        printf 'archive=%s\n' "$(basename "$archive")"; printf 'url=%s\n' "$url"
        printf 'sha256=%s\n' "$(sha256sum "$archive" | awk '{print $1}')"
        printf 'downloaded=%s\n' "$(date -Iseconds)"
    } > "$LATEST_FILE"
    info "已保存: $archive"
}

SRC_ZIP=""; SRC_REF=""
acquire_source() {
    local ref="" kind="" archive=""
    if [ -f "$LATEST_FILE" ]; then
        ref="$(latest_value ref)"; kind="$(latest_value kind)"; archive="$(latest_value archive)"
        info "检测到 latest 记录: ${ref:-未知}（${kind:-未知}）"
        if [ -z "$archive" ] || [ ! -f "$OFFLINE_DIR/$archive" ]; then
            warn "源码包缺失，重新下载"
        elif [ "$FORCE_DOWNLOAD" -eq 1 ]; then
            info "--redownload：重新下载源码"
        elif ask_yes_no "是否重新下载最新源码？（N 则复用 ${archive}）"; then
            :
        else
            info "复用现有源码包: $OFFLINE_DIR/$archive"
            SRC_ZIP="$OFFLINE_DIR/$archive"; SRC_REF="$ref"; return 0
        fi
    else
        info "首次打包，自动下载最新源码"
    fi
    local resolved; resolved="$(resolve_newest_ref)"
    ref="${resolved% *}"; kind="${resolved#* }"
    info "解析到版本: $ref（$kind）"
    download_source "$ref" "$kind"
    SRC_ZIP="$OFFLINE_DIR/hermes-agent-${ref#v}.zip"; SRC_REF="$ref"
}

# ---------------------------------------------------------------------------
step "步骤0：环境自检"
[ "$(id -u)" -eq 0 ] && warn "以 root 运行：各类缓存会写到 /root，产物 root 归属。建议普通用户执行。"

MISSING_TOOLS=""
for c in make g++ tar unzip; do
    command -v "$c" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $c"
done
if [ -n "$MISSING_TOOLS" ]; then
    warn "缺少编译工具:$MISSING_TOOLS（node-pty 需在打包机编译）"
    [ "${HERMES_SKIP_TOOLCHECK:-0}" = "1" ] || die "请先: sudo apt install -y build-essential"
fi

GXX_MAJOR="$(g++ -dumpversion 2>/dev/null | cut -d. -f1)"
if [ -n "${GXX_MAJOR:-}" ] && [ "$GXX_MAJOR" -lt 10 ] 2>/dev/null; then
    warn "g++ $GXX_MAJOR 低于 node-pty 所需的 GCC 10"
    [ "${HERMES_ALLOW_OLD_GXX:-0}" = "1" ] || { print_gxx_hint; ask_yes_no "仍要继续吗？" || die "已中止。"; }
fi

for f in "$UV_ARCHIVE" "$NODE_ARCHIVE"; do
    [ -f "$OFFLINE_DIR/$f" ] || die "缺少 $f，请先放到 $OFFLINE_DIR"
done

step "步骤0.5：准备源码"
acquire_source
info "使用源码包: $SRC_ZIP（${SRC_REF:-未知}）"

if [ "$FETCH_ONLY" -eq 1 ]; then echo "✓ 仅获取源码。"; exit 0; fi

# ---------------------------------------------------------------------------
dir_nonempty() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

clean_stale_source() {
    local keep=" python python-venv node node_modules playwright-cache pm-cache electron-app tools "
    local entry base removed=0
    shopt -s dotglob nullglob
    for entry in "$PAYLOAD_DIR"/*; do
        base="${entry##*/}"
        case "$keep" in *" $base "*) continue ;; esac
        rm -rf "$entry"; removed=$((removed + 1))
    done
    shopt -u dotglob nullglob
    info "已清理 $removed 个旧条目（保留 python/python-venv/node/node_modules/缓存）"
}

prepare_build_dir() {
    step "步骤1：创建构建工作区"
    if dir_nonempty "$PAYLOAD_DIR"; then
        warn "payload 目录非空: $PAYLOAD_DIR（$(du -sh "$PAYLOAD_DIR" 2>/dev/null | awk '{print $1}')）"
        if [ "$CLEAN_BUILD" -eq 1 ]; then
            info "--clean：清空重建。"; rm -rf "$PAYLOAD_DIR"
        elif [ "$KEEP_BUILD" -eq 1 ]; then
            info "--keep：仅清理旧源码。"; clean_stale_source
        elif ask_yes_no "是否清空整个 payload 重建？（N 则保留缓存只清源码）"; then
            rm -rf "$PAYLOAD_DIR"
        else
            clean_stale_source
        fi
    fi
    mkdir -p "$PAYLOAD_DIR" "$BUILD_ROOT"
}
prepare_build_dir

step "步骤2：统一环境变量（构建期）"
export UV_NO_CONFIG=1
export UV_CACHE_DIR="$BUILD_ROOT/uv-cache"                    # 不进包，构建机复用
export ELECTRON_CACHE="$BUILD_ROOT/electron-cache"
export ELECTRON_BUILDER_CACHE="$BUILD_ROOT/electron-builder-cache"
export PLAYWRIGHT_BROWSERS_PATH="$PAYLOAD_DIR/playwright-cache"
export HERMES_NIX_BUILD=1   # 上游 setup.py 禁止构建 wheel，Nix 通道逃生口；离线打包自用等价
[ "$CN_MIRROR" -eq 1 ] && apply_cn_mirrors
export PATH="$PAYLOAD_DIR/node/bin:$PATH"

step "步骤3：部署 uv 到 payload"
rm -rf "$BUILD_ROOT/uv-extract"
mkdir -p "$BUILD_ROOT/uv-extract" "$PAYLOAD_DIR/tools"
tar xzf "$OFFLINE_DIR/$UV_ARCHIVE" -C "$BUILD_ROOT/uv-extract"
UV="$PAYLOAD_DIR/tools/uv"
cp "$BUILD_ROOT/uv-extract"/uv-aarch64-unknown-linux-gnu/uv "$UV"
chmod +x "$UV"; rm -rf "$BUILD_ROOT/uv-extract"
info "uv: $("$UV" --version)"

step "步骤4：部署便携 Python 到 payload/python"
if [ -z "$(find "$PAYLOAD_DIR/python" -maxdepth 3 -type f -name 'python3.*' 2>/dev/null | head -n 1)" ]; then
    "$UV" python install "$PYTHON_VERSION" --install-dir "$PAYLOAD_DIR/python"
fi
PAYLOAD_PY="$(find "$PAYLOAD_DIR/python" -maxdepth 3 -type f -name 'python3.[0-9]*' 2>/dev/null | head -n 1)"
[ -x "$PAYLOAD_PY" ] || die "便携 Python 部署失败: $PAYLOAD_DIR/python"
info "便携 Python: $PAYLOAD_PY ($("$PAYLOAD_PY" -V 2>&1))"

step "步骤5：解压源码到 payload/src"
rm -rf "$BUILD_ROOT/src-extract" "$REPO_DIR"
mkdir -p "$BUILD_ROOT/src-extract"
unzip -q "$SRC_ZIP" -d "$BUILD_ROOT/src-extract"
SRC_TOP="$(find "$BUILD_ROOT/src-extract" -maxdepth 1 -mindepth 1 -type d -name 'hermes-agent-*' | head -n 1)"
[ -n "$SRC_TOP" ] || die "源码包解压后未找到 hermes-agent-* 目录"
mv "$SRC_TOP" "$REPO_DIR"; rm -rf "$BUILD_ROOT/src-extract"
[ -f "$REPO_DIR/pyproject.toml" ] || die "源码解压异常：缺少 pyproject.toml"

LOCK_NODE_VER="$(node -p "try{require('$REPO_DIR/pm/lock.json').packages.node.version}catch(e){''}" 2>/dev/null || true)"
if [ -n "$LOCK_NODE_VER" ] && [ "$NODE_ARCHIVE" != "node-v$LOCK_NODE_VER-linux-arm64.tar.xz" ]; then
    warn "随包 Node 与 pm/lock.json 钉的 v$LOCK_NODE_VER 不一致（engines 只要求 >=26，可运行）"
fi

step "步骤6：创建随包 venv 并完整安装依赖（非 editable）"
BVENV="$PAYLOAD_DIR/python-venv"
rm -rf "$BVENV"
"$UV" venv "$BVENV" --python "$PAYLOAD_PY" --seed
BVENV_PY="$BVENV/bin/python"

OVERRIDES_FILE="$(mktemp)"
"$BVENV_PY" - "$REPO_DIR/pyproject.toml" > "$OVERRIDES_FILE" <<'PYOVR'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
for dep in data.get("tool", {}).get("uv", {}).get("override-dependencies") or []:
    if ";" in dep:
        continue
    print(dep)
PYOVR
info "override: $(tr '\n' ' ' < "$OVERRIDES_FILE")"

"$UV" pip install --python "$BVENV_PY" "$REPO_DIR[all]" --override "$OVERRIDES_FILE"
if ! "$BVENV_PY" -c "import playwright" >/dev/null 2>&1; then
    "$UV" pip install --python "$BVENV_PY" playwright
fi
rm -f "$OVERRIDES_FILE"

step "步骤6.5：验证 Python 依赖"
MISSING_MODS=()
for m in ruamel.yaml openai rich httpx pydantic playwright; do
    "$BVENV_PY" -c "import $m" >/dev/null 2>&1 || MISSING_MODS+=("$m")
done
[ ${#MISSING_MODS[@]} -eq 0 ] || die "缺少核心依赖: ${MISSING_MODS[*]}，已中止（避免打出坏包）。"
"$BVENV/bin/hermes" --version >/dev/null 2>&1 || die "hermes 无法启动，已中止。"
info "✓ hermes 可正常启动"

step "步骤7：部署 Node.js 到 payload"
cd "$PAYLOAD_DIR"
tar xf "$OFFLINE_DIR/$NODE_ARCHIVE" -C .
rm -rf node; mv "$NODE_DIR" node

NPMRC_TOUCHED=()
write_nodedir_npmrc() {
    local dir file
    for dir in "$REPO_DIR" "$REPO_DIR/$DESKTOP_DIR"; do
        [ -d "$dir" ] || continue
        file="$dir/.npmrc"
        [ -f "$file" ] && grep -q '^nodedir=' "$file" && continue
        printf 'nodedir=%s\n' "$PAYLOAD_DIR/node" >> "$file"
        NPMRC_TOUCHED+=("$file")
        info "已写入 node-gyp 头文件路径: $file"
    done
}
if [ -f "$PAYLOAD_DIR/node/include/node/common.gypi" ]; then
    write_nodedir_npmrc
else
    warn "随包 Node 缺少头文件，原生模块需联网下载头文件"
    [ "$CN_MIRROR" -eq 1 ] && export npm_config_disturl="https://npmmirror.com/mirrors/node"
fi

npm_install install -g npm@latest

step "步骤7.5：安装 pnpm（pm/lock.json 钉死版本）"
PNPM_PIN="$(node -p "try{require('$REPO_DIR/pm/lock.json').packages.pnpm.version}catch(e){''}" 2>/dev/null || true)"
[ -n "$PNPM_PIN" ] || PNPM_PIN="12.15.0"
info "上游锁定 pnpm: $PNPM_PIN"
npm_install install -g "pnpm@$PNPM_PIN"

step "步骤8：安装 pnpm 依赖（仓库根在 src/）"
cd "$REPO_DIR"
pnpm_install install --frozen-lockfile
if [ -f "$REPO_DIR/$DESKTOP_DIR/pnpm-lock.yaml" ] && ! grep -q "$DESKTOP_DIR" "$REPO_DIR/pnpm-workspace.yaml" 2>/dev/null; then
    cd "$REPO_DIR/$DESKTOP_DIR"
    pnpm_install install --frozen-lockfile
fi
cd "$PAYLOAD_DIR"

step "步骤9：预下载/自检 Electron"
mkdir -p "$ELECTRON_CACHE"
ELECTRON_BIN=""
for cand in "$REPO_DIR/$DESKTOP_DIR/node_modules/electron/dist/electron" \
            "$REPO_DIR/node_modules/electron/dist/electron"; do
    [ -x "$cand" ] && { ELECTRON_BIN="$cand"; break; }
done
ELECTRON_ARGS=(--version)
[ "$(id -u)" -eq 0 ] && ELECTRON_ARGS=(--no-sandbox --version)
cd "$REPO_DIR/$DESKTOP_DIR"
if ! pnpm exec electron "${ELECTRON_ARGS[@]}"; then
    warn "Electron 自检失败（root 沙箱/缺图形库，常见）"
    if [ -n "$ELECTRON_BIN" ] && [ -x "$ELECTRON_BIN" ]; then
        info "二进制已就位，继续: $ELECTRON_BIN"
    else
        die "Electron 未下载成功，检查网络或设置 ELECTRON_MIRROR 后重跑"
    fi
fi
cd "$PAYLOAD_DIR"

step "步骤9.5：解析提交号（避免 stamp 占位符）"
if [ -z "${GITHUB_SHA:-}" ] && [ -n "${SRC_REF:-}" ]; then
    RESOLVED_SHA="$(http_get "https://api.github.com/repos/$HERMES_REPO/commits/$SRC_REF" 2>/dev/null | json_field sha || true)"
    if [ -n "$RESOLVED_SHA" ]; then
        export GITHUB_SHA="$RESOLVED_SHA"
        info "GITHUB_SHA=${GITHUB_SHA:0:12}..."
    else
        warn "无法解析提交 sha，桌面 stamp 将为占位符"
    fi
fi

step "步骤10：构建桌面应用"
cd "$REPO_DIR/$DESKTOP_DIR"
PACK_LOG="$BUILD_ROOT/.npm-pack.log"
set +e
pnpm run pack 2>&1 | tee "$PACK_LOG"
PACK_RC=${PIPESTATUS[0]}
set -e
if [ "$PACK_RC" -ne 0 ]; then
    grep -qE 'fetch failed|ETIMEDOUT|ERR_PNPM_FETCH' "$PACK_LOG" 2>/dev/null && \
        warn "electron-builder 下载失败：加 --cn-mirror 重跑"
    die "pnpm run pack 失败（退出码 $PACK_RC），日志: $PACK_LOG"
fi

step "步骤10.5：收集桌面产物到 payload/electron-app"
rm -rf "$PAYLOAD_DIR/electron-app"; mkdir -p "$PAYLOAD_DIR/electron-app"
APPIMAGE="$(find "$REPO_DIR/$DESKTOP_DIR" -maxdepth 3 -name '*.AppImage' -type f 2>/dev/null | head -n 1)"
if [ -n "$APPIMAGE" ]; then
    cp "$APPIMAGE" "$PAYLOAD_DIR/electron-app/"; chmod +x "$PAYLOAD_DIR/electron-app/"*.AppImage
    info "已收集 AppImage: $(basename "$APPIMAGE")"
else
    UNPACKED="$(find "$REPO_DIR/$DESKTOP_DIR" -maxdepth 3 -type d -name '*unpacked' 2>/dev/null | head -n 1)"
    if [ -n "$UNPACKED" ]; then
        cp -a "$UNPACKED" "$PAYLOAD_DIR/electron-app/unpacked"
        info "已收集 unpacked 目录"
    else
        warn "未找到桌面产物，快捷方式将退回 gateway+浏览器模式"
    fi
fi
grep -q "hud-modifier unavailable" "$PACK_LOG" 2>/dev/null && \
    warn "hud-modifier 未编译（可选）：sudo apt install -y libx11-dev libxi-dev 后重跑可启用"

step "步骤11：预下载 Playwright 浏览器"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
"$BVENV_PY" -m playwright install chromium

step "步骤12：预热外部工具缓存（尽力而为）"
pm_prefetch() {
    local before after newdirs d
    before="$(mktemp)"; after="$(mktemp)"
    find "${XDG_CACHE_HOME:-$HOME/.cache}" "${XDG_DATA_HOME:-$HOME/.local/share}" \
         -maxdepth 2 -mindepth 1 2>/dev/null | sort > "$before"
    info "尝试 hermes 工具同步命令..."
    local tried=0
    for args in "pm sync" "pm sync --all" "tools sync" "tool sync" "bootstrap"; do
        if timeout 180 "$BVENV/bin/hermes" $args >/dev/null 2>&1; then
            info "  成功: hermes $args"; tried=1; break
        fi
    done
    [ "$tried" -eq 1 ] || warn "  无可用同步命令（pm-cache 可能为空）"
    find "${XDG_CACHE_HOME:-$HOME/.cache}" "${XDG_DATA_HOME:-$HOME/.local/share}" \
         -maxdepth 2 -mindepth 1 2>/dev/null | sort > "$after"
    mkdir -p "$PAYLOAD_DIR/pm-cache"
    newdirs="$(comm -13 "$before" "$after" || true)"
    if [ -n "$newdirs" ]; then
        while IFS= read -r d; do
            [ -d "$d" ] || continue
            cp -a "$d" "$PAYLOAD_DIR/pm-cache/$(basename "$d")"
            info "  已捕获: $(basename "$d")"
        done <<< "$newdirs"
    fi
    { echo "prefetched=$(date -Iseconds)"; ls -1 "$PAYLOAD_DIR/pm-cache" 2>/dev/null || true; } \
        > "$PAYLOAD_DIR/pm-cache/MANIFEST.txt"
    rm -f "$before" "$after"
}
pm_prefetch

step "步骤13：写版本记录并清理构建痕迹"
for _npmrc in ${NPMRC_TOUCHED[@]+"${NPMRC_TOUCHED[@]}"}; do
    [ -f "$_npmrc" ] || continue
    sed -i '/^nodedir=/d' "$_npmrc"
    [ -s "$_npmrc" ] || rm -f "$_npmrc"
done
rm -rf "$BUILD_ROOT/electron-builder-cache" "$BUILD_ROOT"/.*.log
find "$PAYLOAD_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
{
    echo "version=$(basename "$SRC_ZIP" .zip)-$(date +%Y%m%d)"
    echo "ref=${SRC_REF:-unknown}"
    echo "source=$(basename "$SRC_ZIP")"
    echo "python=$PYTHON_VERSION"
    echo "arch=aarch64-linux-gnu"
    echo "built=$(date -Iseconds)"
    echo "builder_host=$(hostname)"
    echo "build_root=$PAYLOAD_DIR"
} > "$PAYLOAD_DIR/version.txt"

step "步骤14：打包并拷贝安装脚本到产出目录"
mkdir -p "$OUT_DIR"
TARBALL_OUT="$OUT_DIR/hermes-agent-arm64-offline.tar.gz"
rm -f "$TARBALL_OUT"
cd "$BUILD_ROOT"
if command -v pv >/dev/null 2>&1; then
    TOTAL_BYTES="$(du -sb hermes-agent | cut -f1)"
    info "正在打包（$(numfmt --to=iec "$TOTAL_BYTES" 2>/dev/null || echo "$TOTAL_BYTES B")）..."
    tar cf - hermes-agent | pv -p -t -e -r -s "$TOTAL_BYTES" | gzip -6 > "$TARBALL_OUT"
else
    tar czf "$TARBALL_OUT" --checkpoint=2000 --checkpoint-action=dot hermes-agent
    echo ""
fi
[ -s "$TARBALL_OUT" ] || die "打包失败：$TARBALL_OUT 为空"

if [ -f "$OFFLINE_DIR/install-to-user-home.sh" ]; then
    cp -f "$OFFLINE_DIR/install-to-user-home.sh" "$OUT_DIR/"
    info "已拷贝安装脚本: $OUT_DIR/install-to-user-home.sh"
else
    warn "未找到 $OFFLINE_DIR/install-to-user-home.sh，产出目录将缺少安装脚本！"
fi

echo ""
echo "✓ 打包完成: $TARBALL_OUT"
du -sh "$TARBALL_OUT"
echo "  源码版本: ${SRC_REF:-未知}"
echo "  内网机安装: tar xzf hermes-agent-arm64-offline.tar.gz && bash install-to-user-home.sh"
