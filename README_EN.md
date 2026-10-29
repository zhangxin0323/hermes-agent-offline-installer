# Hermes Agent Offline Package Builder

Builds a self-contained, fully offline installer for [Hermes Agent](https://github.com/NousResearch/hermes-agent), targeting **air-gapped arm64 Kylin V10 desktops**.

- **One command** — resolves and downloads the newest Hermes Agent source, fetches every dependency, pre-compiles the Electron desktop app, and emits a single `tar.gz`.
- **`latest` version record** — the source version is no longer hard-coded. The first run resolves upstream's newest version and downloads it; later runs read the `latest` record and **ask whether to download again**, defaulting to reusing the cached archive.
- **Fully offline on the target** — Node.js, Python 3.11, Electron, and Playwright Chromium are pre-downloaded and shipped inside the bundle; installation never touches the internet.
- **Desktop app ready to run** — the packaged Electron app is already compiled, so `hermes desktop` starts without a local build.
- **Two flavours** — `python-packages` (full Python toolchain, executes locally) and `docker-backend` (runs generated code in a Docker sandbox).

| Component | Version |
| --- | --- |
| Hermes Agent source | Newest upstream (example: `v0.22.5`; verified here with `v2026.9.14` / 0.21.3) |
| Node.js | v26.2.0 (linux-arm64) |
| Python | 3.11 (uv-managed, inside `hermes-venv`) |
| Electron | 40.10.2 (linux-arm64, cached) |
| Playwright | Chromium 1243 + headless shell + ffmpeg (cached) |
| uv | Bundled aarch64 standalone binary |

> Background and field notes (in Chinese) by the author:
> [Part 1 · planning and prerequisites](https://blog.csdn.net/vegaszx/article/details/163778194),
> [Part 2 · intranet deployment and desktop setup](https://blog.csdn.net/vegaszx/article/details/163802884).
> The companion Docker sandbox lives at [hermes-sandbox-offline](https://github.com/zhangxin0323/hermes-sandbox-offline).

---

## 1. Package Contents

| File | Size | Purpose |
| --- | --- | --- |
| `make-offline-package.sh` | 13 KB | Builder script for the **build machine**: resolve/download source → install deps → build → pack |
| `hermes-agent-<version>.zip` | 75–100 MB | Upstream source archive (downloaded and cached; not shipped) |
| `node-v26.2.0-linux-arm64.tar.xz` | 31 MB | Official Node.js prebuilt runtime, extracted into the bundle |
| `uv-aarch64-unknown-linux-gnu.tar.gz` | 18 MB | Standalone uv binary used to create the Python 3.11 environment |
| `python-3.12-slim-bookworm-arm64.tar` | 148 MB | Exported sandbox base image (Docker flavour) |
| `latest` | 1 KB | Version record: last downloaded ref, source and checksum |
| `install-offline-package.sh` | 2 KB | Installer for the **target machine**; copied into the output directory during packaging |
| `dist/` | 1.5–4 GB | Build output (`tar.gz` + installer), excluded by `.gitignore` |
| `README.md` / `README_EN.md` | — | Chinese / English documentation |

> **The target machine only needs two files**: `hermes-desktop-arm64-offline.tar.gz` and `install-offline-package.sh` — both land in `dist/`. Everything else stays on the build machine.

### The `latest` file

`latest` is a plain `key=value` file maintained by the build script, used to decide whether the current version has already been downloaded:

```ini
ref=v0.22.5
kind=tag
repo=NousResearch/hermes-agent
archive=hermes-agent-0.22.5.zip
url=https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/v0.22.5
sha256=5772d33b…
downloaded=2026-10-29T13:35:51+08:00
```

`kind` is `tag` (release/branch tag) or `sha` (commit on the default branch), recording where the source came from.

---

## 2. Requirements

### Build machine (internet-connected)

- Architecture: `aarch64` — matching the target; bundled Node.js and Electron are arm64 builds.
- Network: access to GitHub (source, Electron), PyPI (Python deps) and the npm registry.
- Privileges: `sudo` (the install layout follows the original scheme: `/opt/hermes-agent`).
- Tools: `curl` or `wget`, `tar`, `unzip`, `sha256sum`, `make`, `python3`.
- Compiler: **GCC / G++ ≥ 10**. `node-pty` has no arm64 prebuild, so it is compiled locally against Node 26's
  `-std=gnu++20`; Kylin V10 ships GCC 9 and fails in step 8 with `unrecognized command line option '-std=gnu++20'`
  (upgrade instructions in [Troubleshooting](#8-troubleshooting)).
- Disk: ≥ 15 GB free (≈4 GB build tree in `/opt`, ≈1.7 GB output tarball, plus the source archive).

### Target machine (air-gapped)

- OS: Kylin V10 SP1 Desktop (`aarch64`), or another recent arm64 desktop distribution.
- Privileges: regular user with `sudo`.
- Network: none required. If an internal apt mirror exists, the installer pulls system libraries automatically; otherwise pre-install:
  `git libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2 ripgrep ffmpeg`.
- Disk: `/opt/hermes-agent` needs ≈4 GB; allow ≈6 GB during extraction.
- Graphics: `hermes --tui` works headless; `hermes desktop` needs a working X11/Wayland desktop.
- For the `docker-backend` flavour, Docker must be installed on the target (the sandbox container runs locally).

---

## 3. Quick Start

### 3.1 Build the bundle

```bash
git clone https://github.com/zhangxin0323/hermes-agent-offline-installer.git
cd hermes-agent-offline-installer

# Provide the bundled toolchain once (reusable afterwards):
#   uv-aarch64-unknown-linux-gnu.tar.gz
#   node-v26.2.0-linux-arm64.tar.xz

./make-offline-package.sh --cn-mirror   # in China: route PyPI/npm/Electron/Playwright to CN mirrors
# ./make-offline-package.sh             # elsewhere: talk to the official registries
```

> **Use `--cn-mirror` on build machines in China.** Measured with the same arm64 wheel: the default `files.pythonhosted.org`
> managed **44 KB/s**, while the Aliyun mirror delivered **1.4 MB/s** (~30×). `.[all,dev]` pulls hundreds of megabytes,
> so without a mirror the run looks like it is "stuck on pydantic".

The script runs 12 steps (see [section 6](#6-what-the-scripts-do)). On the first run there is no `latest`, so it resolves the newest upstream version and downloads it:

```
=== Step 0.5: preparing Hermes Agent source ===
未找到 /data/hermes-agent-offline/latest（首次打包），将自动下载最新源码
解析到最新版本: v0.22.5（tag）
下载源码: https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/v0.22.5
已保存: /data/hermes-agent-offline/hermes-agent-0.22.5.zip
版本记录: /data/hermes-agent-offline/latest
```

Output goes to `dist/`, and the installer is copied there as well:

```
dist/
├── hermes-desktop-arm64-offline.tar.gz
└── install-offline-package.sh
```

> Step 10 (`npm run pack`) compiles the Electron desktop app — the slowest and most memory-hungry step. 8 GB of RAM or more is recommended.

### 3.2 Copy to the intranet

Copy these two files into the same directory on the target (e.g. `~/Downloads/hermes-offline/`):

```
hermes-desktop-arm64-offline.tar.gz
install-offline-package.sh
```

### 3.3 Install

```bash
cd ~/Downloads/hermes-offline     # required: the script looks up the tarball by relative path
bash install-offline-package.sh
```

Seeing `✓ 安装完成！` means success. The installer only does four things: install missing system libraries, extract to `/opt/hermes-agent`, create `/usr/local/bin/hermes`, and add a desktop launcher.

> **Reinstall / upgrade**: when `/opt/hermes-agent` is not empty the installer asks first, then renames the old tree to
> `/opt/hermes-agent.bak.<timestamp>` before extracting — nothing is silently overwritten. For unattended runs use `--force`:
>
> ```bash
> bash install-offline-package.sh --force
> ```

### 3.4 Launch

```bash
hermes --tui                  # terminal TUI (recommended, richest interaction)
hermes desktop --skip-build   # desktop app (already compiled, no local build)
hermes --version              # print version
```

The first run creates configuration under `~/.hermes/`. Double-clicking the "Hermes Agent" desktop icon is equivalent to `hermes desktop --skip-build`.

---

## 4. Version Resolution and the `latest` Mechanism

### 4.1 Resolution order

1. `HERMES_VERSION` environment variable (highest priority: tag, branch or commit sha);
2. `tag_name` of the newest GitHub Release;
3. newest repository tag (when upstream has no releases);
4. `sha` of the newest commit on the default branch (i.e. "newest code", not necessarily a tag).

### 4.2 Whether to download again

After resolution the script inspects `latest`:

| Situation | Behaviour |
| --- | --- |
| `latest` missing | Resolve newest version and download (first build) |
| `latest` present and archive present | **Ask** "download the newest source again?" — defaults to `N`, reusing the cached zip |
| `latest` present but archive deleted | Warn and download again automatically |
| `--redownload` passed | Skip the prompt, force a fresh download |
| `--yes` passed | Answer "yes" to every prompt |
| Non-interactive (pipe, CI) | Treated as "no": reuse the cached archive, with a hint about the flags |

Interactive example:

```
=== 步骤0.5：准备 Hermes Agent 源码 ===
检测到 latest 版本记录: v2026.9.14（来源: tag）
对应源码包: hermes-agent-2026.9.14.zip
是否重新下载 Hermes Agent 最新源码？（选 N 则复用现有 hermes-agent-2026.9.14.zip） [y/N] _
```

### 4.3 Common invocations

```bash
./make-offline-package.sh                      # interactive: ask if cached, download otherwise
./make-offline-package.sh --redownload         # always fetch the newest version
./make-offline-package.sh --yes                # unattended (answer "yes" to everything)
./make-offline-package.sh --fetch-only         # only download the source, no build
./make-offline-package.sh --cn-mirror          # China mirrors (recommended there)
./make-offline-package.sh --clean              # wipe the build directory without asking
./make-offline-package.sh --keep               # reuse the existing venv, drop stale source only
HERMES_VERSION=v2026.9.14 ./make-offline-package.sh   # pin a specific tag
HERMES_USE_HEAD=1 ./make-offline-package.sh    # use the newest commit on main
```

`--cn-mirror` sets the following variables (**values you already exported are never overridden**):

| Variable | Value | Used for |
| --- | --- | --- |
| `UV_DEFAULT_INDEX` / `UV_INDEX_URL` | `https://mirrors.aliyun.com/pypi/simple/` | Python packages |
| `npm_config_registry` | `https://registry.npmmirror.com` | npm packages |
| `ELECTRON_MIRROR` | `https://npmmirror.com/mirrors/electron/` | Electron binaries |
| `PLAYWRIGHT_DOWNLOAD_HOST` | `https://npmmirror.com/mirrors/playwright` | Chromium |
| `UV_HTTP_TIMEOUT` | `120` | relaxes uv timeouts on slow links |

| Variable | Default | Effect |
| --- | --- | --- |
| `HERMES_REPO` | `NousResearch/hermes-agent` | Upstream repository (mirror or fork) |
| `HERMES_VERSION` | empty | Pin a version, skipping resolution |
| `HERMES_USE_HEAD` | `0` | `1` skips releases/tags and takes the branch HEAD |
| `HERMES_BRANCH` | `main` | Default branch name |
| `HERMES_INSTALL_DIR` | `/opt/hermes-agent` | Build tree during packaging |
| `HERMES_PYTHON_VERSION` | `3.11` | Python version used for the venv |
| `OUTPUT_DIR` | `dist` | Where the bundle is written (gitignored) |
| `UV_DEFAULT_INDEX` | empty (Aliyun with `--cn-mirror`) | PyPI index; may also be exported directly |

---

## 5. The Two Flavours

| | `with-python-packages` | `with-docker-backend` |
| --- | --- | --- |
| Bundle size | 1.55 GB | 1.25 GB (+ a 3.0 GB sandbox image tarball) |
| `hermes-venv` contents | Full: pandas / numpy / scipy / matplotlib / seaborn / python-docx / docxtpl / python-pptx / openpyxl / xlsxwriter / PyMuPDF / pdfplumber / pytesseract / markitdown / oracledb / dmPython / Pillow … | Minimal: only what Hermes itself needs |
| Code execution | On the target host | Inside a Docker sandbox container |
| Data safety | Relies on Hermes' own permissions | Container isolation; CPU/memory/network limits, read-only mounts |
| Best for | Single user; document and data scripts run locally | Shared machines; agent-generated code must be contained |

> `hermes-sandbox-python312-*.tar` shipped with the `with-docker-backend` flavour is the **sandbox image**; the installer does not import it automatically, so load it yourself:
> `docker load -i hermes-sandbox-python312-20260901v1-arm64.tar`.
> The image build recipe and tool list are in [hermes-sandbox-offline](https://github.com/zhangxin0323/hermes-sandbox-offline).
>
> Both flavours produce a `hermes-desktop-arm64-offline.tar.gz` with the **same name** and share the same `install-offline-package.sh`;
> only the bundled `hermes-venv` and the presence of the sandbox image differ. Use a different `OUTPUT_DIR` when switching flavours to avoid overwriting.

---

## 6. What the Scripts Do

### Build machine: `make-offline-package.sh`

| Step | Action |
| --- | --- |
| 0 | Pre-flight checks (sudo, tar/unzip, bundled toolchain, build tools, and **g++ major version ≥ 10**) |
| 0.5 | **Prepare source**: read `latest` → decide reuse vs. re-download → resolve newest → download and validate the zip |
| 1 | Create `/opt/hermes-agent`, chown to the current user |
| 2 | Export a unified environment (`HERMES_AGENT_ROOT`, `UV_NO_CONFIG`, `ELECTRON_CACHE`, `PLAYWRIGHT_BROWSERS_PATH`, `NODE_PATH`) so paths match on both sides |
| 2.5 | With `--cn-mirror` only: point PyPI / npm / Electron / Playwright at China mirrors |
| 3 | Install uv into `/usr/local/bin` |
| 4 | Create the Python 3.11 venv with uv: `/opt/hermes-agent/hermes-venv` |
| 5 | Extract the source and **strip the top-level directory** so the repo root is the install root |
| 6 | `uv pip install -e ".[all,dev]"` plus `playwright` |
| 7 | Extract Node.js into `node/`, point `npm_config_nodedir` at the bundled headers (offline native builds), then upgrade npm |
| 8 | Install npm dependencies for the repo root and `apps/desktop` |
| 9 | Pre-download Electron into `electron-cache/`; adds `--no-sandbox` under root, and only warns if the self-check fails while the binary exists |
| 10 | `npm run pack` builds the desktop app (output in `apps/desktop/release/`) |
| 11 | Pre-download Playwright Chromium into `playwright-cache/` |
| 12 | Copy the installer, then pack the tree into `dist/hermes-desktop-arm64-offline.tar.gz` (percentage via `pv` if installed, otherwise a dot every 20 MB, **no file listing**) |

### Target machine: `install-offline-package.sh`

| Step | Action |
| --- | --- |
| 1 | `apt install` graphics/runtime libraries (`libnss3`, `libgtk-3-0`, `libgbm1`, `libasound2`, `ripgrep`, `ffmpeg`, …) |
| 2 | Check `/opt/hermes-agent`: when non-empty, ask first and rename the old tree to `/opt/hermes-agent.bak.<timestamp>` before extracting (no silent overwrite) |
| 3 | Write `/usr/local/bin/hermes` (injects `HERMES_AGENT_ROOT`, `PATH`, `NODE_PATH`, Playwright/Electron cache paths, and clears conflicting `PYTHONPATH`/`PYTHONHOME`) |
| 4 | Write `~/.local/share/applications/hermes.desktop` |
| 5 | Verify with `hermes --version` |

Resulting layout:

```
/opt/hermes-agent/
├── hermes-venv/            # Python 3.11 venv (contains the hermes CLI)
├── uv/python/              # uv-managed Python runtime
├── node/                   # Node.js v26.2.0
├── node_modules/           # workspace npm dependencies
├── apps/desktop/
│   └── release/            # prebuilt Electron desktop app
├── electron-cache/         # Electron binary cache
├── playwright-cache/       # Chromium / headless shell / ffmpeg
├── skills/                 # bundled skills
├── hermes_cli/ agent/ tools/ gateway/ …   # upstream source (no src/ level)
└── pyproject.toml

/usr/local/bin/hermes       # launcher wrapper
~/.hermes/                  # user data and config (separate from the install tree)
```

---

## 7. Configuration Highlights

Configuration lives in `~/.hermes/config.yaml`. Minimal setup for an intranet model:

```yaml
model:
  provider: openai-compatible
  base_url: http://YOUR-INTRANET-SERVER:8001/v1   # note the trailing /v1
  api_key: sk-internal-key
  name: Qwen3.6-27B-TS
```

Settings that usually need adjusting on an isolated network (from the author's write-ups):

```yaml
# 1. Disable proxy probing to stop repeated internet attempts
proxy:
  enabled: false

# 2. Title generation defaults to an external model and fails offline
auxiliary:
  title_generation:
    provider: custom
    model: custom/Qwen3.6-27B-TS     # the model name follows the "/"

# 3. Run generated code inside a Docker sandbox (docker-backend flavour)
terminal:
  backend: docker
  docker_image: hermes-sandbox-python312:20260901v1
  network: "none"                    # sandbox has no network
  container_memory: 5120             # MB
  container_persistent: false        # no /workspace persistence between sessions
  docker_volumes:
    - /home/user/hermes-data/home:/opt/data/home    # the only writable path
    - /home/user/hermes-data:/opt/data:ro           # everything else read-only
```

> Tip: tell the agent explicitly that "all generated files must be saved to `/opt/data/home`", otherwise files can end up inside the container and are hard to find.

---

## 8. Troubleshooting

**Q: `latest` says one version but I want to pin an older one.**
`HERMES_VERSION=v2026.9.14 ./make-offline-package.sh`, or simply answer `N` to reuse the cached archive.

**Q: Packing/extracting scrolls thousands of file names — how do I see only progress?**
The scripts no longer use `tar -v` (that flag was the source of the flood):

- With `pv` on the build machine: percentage, rate, elapsed and ETA, e.g.
  `12.3MiB 0:00:07 [1.7MiB/s] [===>    ] 23%  ETA 0:00:23`;
- without `pv`: one dot per 20 MB (`...`) — install it for a nicer display: `sudo apt install pv`;
- on the target, extraction also uses dots instead of a file list.

To inspect the archive manually:

```bash
tar tzf dist/hermes-desktop-arm64-offline.tar.gz | head -30   # list contents
sudo tar xzvf dist/hermes-desktop-arm64-offline.tar.gz -C /tmp/inspect   # verbose extract
```

**Q: Step 9 fails with `Running as root without --no-sandbox is not supported`.**
The build script is running as root. It now adds `--no-sandbox` automatically and keeps going as long as the Electron binary
exists. Running the build as a **regular user** is still preferable (the script sudo's where needed):

```bash
sudo chown -R "$USER:$USER" /opt/hermes-agent   # fix ownership if it was built as root
```

**Q: npm prints `Unknown env config "nodedir"` / `"disturl"`.**
Newer versions write `nodedir` into the build tree's `.npmrc` (removed before packaging), so the warning is gone.
`disturl` is only set in the fallback path where the bundled Node lacks headers.

**Q: Step 8 fails with `g++: error: unrecognized command line option '-std=gnu++20'` (compiler too old).**
Node 26's `common.gypi` requires C++20, while Kylin V10 ships GCC 9 which only knows `-std=gnu++2a`. The script detects this
at step 0 and prints the fix below; run these four commands and rerun (Kylin's repo has `gcc-10`; newer distros use 12):

```bash
sudo apt install gcc-10 g++-10
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
g++ --version   # expect 10.x
```

> A build already in progress can be interrupted: the venv and npm cache survive, so rerun and choose "keep the venv".

**Q: Step 8 fails building `node-pty` / `gyp http GET https://nodejs.org/...headers.tar.gz` times out.**
`node-pty` ships no arm64 prebuild, so node-gyp compiles it locally — and node-gyp downloads Node headers from nodejs.org,
which is usually unreachable from China. The script now points `npm_config_nodedir` at the headers bundled inside the shipped
Node (`node/include/node/`), so no network is involved:

```
node-gyp 使用随包头文件: /opt/hermes-agent/node/include/node
```

If it still fails, check these two:

```bash
ls /opt/hermes-agent/node/include/node/common.gypi   # headers present?
sudo apt install -y build-essential python3          # toolchain: make / g++ / python3
```

> Also: **do not run the build script with `sudo`** (it calls sudo itself where needed). Running as root puts the npm cache in
> `/root/.npm` and leaves the output owned by root.

**Q: Step 5 fails with `mv: cannot move ... : Directory not empty`.**
`/opt/hermes-agent` still holds the previous build's source tree (e.g. an existing `website/`), so merging the new source fails.
Current versions detect this at step 1 and ask; if you hit it on an older copy, rerun with:

```bash
./make-offline-package.sh --clean   # wipe the build directory and rebuild
./make-offline-package.sh --keep    # or keep the venv and drop stale source only (faster)
```

**Q: Step 6 sits on `Using Python 3.11.x environment` / `pydantic==x.y.z` for ages — is it just slow?**
Almost certainly network. uv defaults to `pypi.org`, and wheels are served from `files.pythonhosted.org`, which measured
40–50 KB/s from China. Rerun with mirrors (uv does not re-download what it already cached):

```bash
./make-offline-package.sh --cn-mirror
# or override just PyPI for this run:
export UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple/
export UV_HTTP_TIMEOUT=120
```

To tell "slow" from "stuck":

```bash
du -sh ~/.cache/uv          # sample twice 30s apart: growing = slow, flat = stuck
ps aux | grep -E 'uv (pip|sync)'   # is uv still running?
curl -s -o /dev/null -w '%{speed_download}\n' \
  https://files.pythonhosted.org/packages/.../pydantic_core-*.whl   # raw speed test
```

**Q: Steps 9/10 hang while downloading Electron.**
Electron comes from GitHub Releases. If the build machine struggles, set a mirror first: `export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"`, then rerun.

**Q: `npm install` is slow or fails.**
Switch the registry on the build machine: `npm config set registry https://registry.npmmirror.com`. Always do a full build afterwards so the bundle never references an unreachable registry.

**Q: The desktop app shows a blank window or complains about missing `.so` files.**
Install the system libraries: `sudo apt install -y libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2`. On Wayland, try `GDK_BACKEND=x11 hermes desktop --skip-build`.

**Q: No apt mirror on the intranet, step 1 fails immediately.**
Pre-install the dependencies, or comment out `apt update` / `apt install` and run them manually.

**Q: `Auxiliary title generation failed: Request timed out.`**
Harmless. Point `auxiliary.title_generation` at the intranet model as shown in [section 7](#7-configuration-highlights).

**Q: How do I upgrade?**
Rebuild on the build machine (`--redownload`), then rerun `install-offline-package.sh` on the target. The installer overwrites `/opt/hermes-agent` and leaves `~/.hermes/` untouched.

**Q: How do I uninstall?**

```bash
sudo rm -rf /opt/hermes-agent /usr/local/bin/hermes
rm -f ~/.local/share/applications/hermes.desktop
# only when sessions and configuration are no longer needed:
# rm -rf ~/.hermes
```

---

## 9. Repository Layout

```
hermes-agent-offline-installer/
├── make-offline-package.sh              # builder (internet-connected machine)
├── install-offline-package.sh           # target-side installer (copied into dist/ during packaging)
├── dist/                                # build output: tar.gz + installer (gitignored)
├── README.md
├── README_EN.md
└── .gitignore
```

> The repository holds scripts and docs only. `dist/`, `dists/`, source archives, Node/uv runtimes and the offline `tar.gz` are excluded by `.gitignore` and are produced on the build machine.
> The two files under `dist/` are exactly what you publish: `hermes-desktop-arm64-offline.tar.gz` and `install-offline-package.sh`.

---

## 10. Credits and License

- Hermes Agent is built by [Nous Research](https://nousresearch.com) under the MIT license: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).
- Deployment approach, intranet configuration and sandbox design come from the author's articles (Chinese):
  [Part 1](https://blog.csdn.net/vegaszx/article/details/163778194) ·
  [Part 2](https://blog.csdn.net/vegaszx/article/details/163802884) ·
  [Side note](https://blog.csdn.net/vegaszx/article/details/163803319).
- The scripts and docs here are released under the MIT license; the upstream source keeps whatever license shipped with the downloaded version.
