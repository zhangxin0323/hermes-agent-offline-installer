# Hermes Agent 离线安装包打包器

面向**内网无外网环境的 arm64 银河麒麟 V10 桌面**，把 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成可拷贝、可离线安装的一体化安装包。

- **一条命令完成打包**：自动检测并下载 Hermes Agent 最新源码，随后下载全部依赖、预编译桌面端、打包成单个 `tar.gz`。
- **latest 版本记录**：源码版本不再写死。首次运行自动解析上游最新版本并下载；再次运行时读取 `latest` 记录，**询问是否重新下载**，默认复用已有源码包。
- **目标机全离线**：Node.js、Python 3.11 环境、Electron、Playwright Chromium 全部预先下载并随包分发，安装过程不访问外网。
- **开箱即用的桌面端**：包内已包含编译好的 Electron 桌面应用，安装后直接 `hermes desktop` 启动，无需现场构建。
- **两种发行形态**：`python-packages`（Python 依赖齐全，本地执行）与 `docker-backend`（配合 Docker 沙箱，数据隔离），按需选用。

| 组件 | 版本 |
| --- | --- |
| Hermes Agent 源码 | 自动解析上游最新版（示例：`v0.22.5`；本文档验证版本 `v2026.9.14` / 0.21.3） |
| Node.js | v26.2.0（linux-arm64） |
| Python | 3.11（uv 托管，位于 `hermes-venv`） |
| Electron | 40.10.2（linux-arm64，已缓存） |
| Playwright | Chromium 1243 + headless shell + ffmpeg（已缓存） |
| uv | 随包的 aarch64 独立二进制 |

> 背景与实机踩坑过程见作者博文：
> [上篇 · 筹划和准备](https://blog.csdn.net/vegaszx/article/details/163778194)、
> [下篇 · 内网部署和中文社区桌面端配置](https://blog.csdn.net/vegaszx/article/details/163802884)。
> 配套的 Docker 沙箱镜像见 [hermes-sandbox-offline](https://github.com/zhangxin0323/hermes-sandbox-offline)。

---

## 一、包内容

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `make-offline-package.sh` | 13 KB | **打包机**上执行的打包脚本：解析/下载源码 → 装依赖 → 构建 → 出包 |
| `hermes-agent-<版本>.zip` | 75–100 MB | 上游源码包（自动下载并缓存，不随包分发） |
| `node-v26.2.0-linux-arm64.tar.xz` | 31 MB | Node.js 官方预编译运行时，打包时解压进离线包 |
| `uv-aarch64-unknown-linux-gnu.tar.gz` | 18 MB | uv 独立二进制，用于创建 Python 3.11 环境 |
| `python-3.12-slim-bookworm-arm64.tar` | 148 MB | 沙箱基础镜像导出文件（Docker 沙箱方案使用） |
| `latest` | 1 KB | 版本记录文件，记录上次下载的源码版本、来源与校验值 |
| `install-offline-package.sh` | 2 KB | **目标机**上执行的安装脚本，打包时自动复制进产物目录 |
| `dist/` | 1.5–4 GB | 打包产物目录（`tar.gz` + 安装脚本），已被 `.gitignore` 忽略 |
| `README.md` / `README_EN.md` | — | 中文 / 英文说明 |

> **目标机只需要两个文件**：`hermes-desktop-arm64-offline.tar.gz` + `install-offline-package.sh`，它们都在打包后的 `dist/` 里。
> 其余文件都留在打包机上，不需要拷贝进内网。

### latest 文件

`latest` 是打包脚本自己维护的纯文本键值文件，用来判断"这一版是不是已经下过了"：

```ini
ref=v0.22.5
kind=tag
repo=NousResearch/hermes-agent
archive=hermes-agent-0.22.5.zip
url=https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/v0.22.5
sha256=5772d33b…
downloaded=2026-10-29T13:35:51+08:00
```

`kind` 取值 `tag`（Release 标签）或 `sha`（默认分支提交），表示源码的来源类型。

---

## 二、环境要求

### 打包机（联网）

- 架构：`aarch64`（与目标机一致，包内的 Node.js / Electron 都是 arm64 版本）。
- 网络：可访问 GitHub（源码、Electron）、PyPI（Python 依赖）、npm registry。
- 权限：需要 `sudo`（安装方式沿用原方案，运行时安装在 `/opt/hermes-agent`）。
- 工具：`curl` 或 `wget`、`tar`、`unzip`、`sha256sum`。
- 磁盘：建议 ≥ 15 GB 可用空间（`/opt` 构建目录约 4 GB + 输出 `tar.gz` 约 1.7 GB + 源码包）。

### 目标机（内网）

- 操作系统：银河麒麟 V10 SP1 桌面版（`aarch64`），或其它较新的 arm64 桌面发行版。
- 权限：普通用户 + `sudo`。
- 网络：完全不需要外网。若内网有可用 apt 源，安装脚本会自动补齐系统依赖；没有 apt 源时请提前装好这些包：
  `git libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2 ripgrep ffmpeg`。
- 磁盘：安装目录 `/opt/hermes-agent` 约占 4 GB，解压期间建议预留 6 GB。
- 图形环境：仅使用 `hermes --tui` 时可不装桌面；使用 `hermes desktop` 时需要可用的 X11/Wayland 桌面。
- 若使用 `docker-backend` 变体，另需安装 Docker（沙箱容器运行在目标机本地）。

---

## 三、快速开始

### 3.1 在打包机上生成离线包

```bash
git clone https://github.com/zhangxin0323/hermes-agent-offline-installer.git
cd hermes-agent-offline-installer

# 准备好随包工具链（首次需要，之后可复用）
#   uv-aarch64-unknown-linux-gnu.tar.gz
#   node-v26.2.0-linux-arm64.tar.xz

./make-offline-package.sh
```

脚本会依次执行 12 个步骤（详见[第六节](#六脚本做了什么)）。首次运行没有 `latest`，会直接解析上游最新版本并下载源码：

```
=== 步骤0.5：准备 Hermes Agent 源码 ===
未找到 /data/hermes-agent-offline/latest（首次打包），将自动下载最新源码
解析到最新版本: v0.22.5（tag）
下载源码: https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/v0.22.5
已保存: /data/hermes-agent-offline/hermes-agent-0.22.5.zip
版本记录: /data/hermes-agent-offline/latest
```

完成后产物位于 `dist/`，脚本会同时把 `install-offline-package.sh` 复制进去：

```
dist/
├── hermes-desktop-arm64-offline.tar.gz
└── install-offline-package.sh
```

> 步骤 10（`npm run pack`）会编译 Electron 桌面端，是整个流程中最慢、最吃内存的一步，建议机器内存 ≥ 8 GB。

### 3.2 拷贝到内网

把下面两个文件拷到目标机的同一个目录（例如 `~/下载/hermes-offline/`）：

```
hermes-desktop-arm64-offline.tar.gz
install-offline-package.sh
```

### 3.3 在目标机上安装

```bash
cd ~/下载/hermes-offline      # 必须进入该目录：脚本按相对路径查找 tar 包
bash install-offline-package.sh
```

看到 `✓ 安装完成！` 即成功。安装脚本只做四件事：补齐系统依赖、解压到 `/opt/hermes-agent`、生成 `/usr/local/bin/hermes` 启动命令、创建桌面快捷方式。

### 3.4 启动

```bash
hermes --tui                  # 终端 TUI 界面（推荐，交互更完整）
hermes desktop --skip-build   # 桌面端（包内已编译好，跳过现场构建）
hermes --version              # 查看版本
```

首次运行会在 `~/.hermes/` 下生成配置。双击桌面图标「Hermes Agent」等价于 `hermes desktop --skip-build`。

---

## 四、源码版本与 latest 机制

### 4.1 版本解析顺序

脚本不再固定使用某个版本号，解析顺序如下：

1. `HERMES_VERSION` 环境变量（最高优先级，可填 tag / 分支 / 提交 sha）；
2. GitHub 最新 Release 的 `tag_name`；
3. 仓库最新 tag（上游没有 Release 时）；
4. 默认分支最新提交的 `sha`（仍未取到 tag 时，对应"最新的代码"而非某个标签）。

### 4.2 是否重新下载

拿到版本后，脚本检查 `latest` 文件：

| 情况 | 行为 |
| --- | --- |
| `latest` 不存在 | 自动解析最新版本并下载（首次打包） |
| `latest` 存在且源码包也在 | **询问**"是否重新下载最新源码？"，默认 `N`，直接复用现有 zip |
| `latest` 存在但源码包被删 | 打印警告并自动重新下载 |
| 传入 `--redownload` | 跳过询问，强制重新下载最新版本 |
| 传入 `--yes` | 所有询问自动回答"是" |
| 非交互环境（管道、CI） | 视为回答"否"，复用现有源码包，并提示可用参数 |

交互效果：

```
=== 步骤0.5：准备 Hermes Agent 源码 ===
检测到 latest 版本记录: v2026.9.14（来源: tag）
对应源码包: hermes-agent-2026.9.14.zip
是否重新下载 Hermes Agent 最新源码？（选 N 则复用现有 hermes-agent-2026.9.14.zip） [y/N] _
```

### 4.3 常用写法

```bash
./make-offline-package.sh                      # 交互式：有缓存就问，没缓存就下
./make-offline-package.sh --redownload         # 强制拉最新版
./make-offline-package.sh --yes                # 无人值守（全部回答"是"）
./make-offline-package.sh --fetch-only         # 只下载源码，不打包（用来确认版本）
HERMES_VERSION=v2026.9.14 ./make-offline-package.sh   # 锁死某个发行标签
HERMES_USE_HEAD=1 ./make-offline-package.sh    # 直接用 main 分支最新提交
```

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `HERMES_REPO` | `NousResearch/hermes-agent` | 上游仓库（可换成内网镜像或 fork） |
| `HERMES_VERSION` | 空 | 强制指定版本，跳过自动解析 |
| `HERMES_USE_HEAD` | `0` | 设为 `1` 时跳过 Release/tag，直接取分支最新提交 |
| `HERMES_BRANCH` | `main` | 默认分支名 |
| `HERMES_INSTALL_DIR` | `/opt/hermes-agent` | 打包时的构建目录 |
| `HERMES_PYTHON_VERSION` | `3.11` | 创建 venv 时使用的 Python 版本 |
| `OUTPUT_DIR` | `dist` | 离线包输出目录（已忽略，不入库） |

---

## 五、两种发行形态

| | `with-python-packages` | `with-docker-backend` |
| --- | --- | --- |
| 离线包体积 | 1.55 GB | 1.25 GB（另附 3.0 GB 沙箱镜像 tar） |
| `hermes-venv` 内容 | 全量：pandas / numpy / scipy / matplotlib / seaborn / python-docx / docxtpl / python-pptx / openpyxl / xlsxwriter / PyMuPDF / pdfplumber / pytesseract / markitdown / oracledb / dmPython / Pillow … | 精简：只装 Hermes 自身运行所需依赖 |
| 代码执行位置 | 目标机本机 | Docker 沙箱容器 |
| 数据安全性 | 依赖 Hermes 自身权限控制 | 容器隔离，可限制 CPU/内存/网络，目录可只读挂载 |
| 适用场景 | 单机自用、文档/数据脚本都在本机跑 | 多人共用、需要把 Agent 生成的代码关进沙箱 |

> `with-docker-backend` 形态附带的 `hermes-sandbox-python312-*.tar` 是**沙箱镜像**，安装脚本不会自动处理，需要单独导入：
> `docker load -i hermes-sandbox-python312-20260901v1-arm64.tar`。
> 沙箱镜像的构建方法与工具清单见 [hermes-sandbox-offline](https://github.com/zhangxin0323/hermes-sandbox-offline)。
>
> 两种形态产出的 `hermes-desktop-arm64-offline.tar.gz` **同名**，用的也是同一份 `install-offline-package.sh`，
> 区别只在包内的 `hermes-venv` 与是否附带沙箱镜像。切换形态时建议指定不同的 `OUTPUT_DIR`，避免互相覆盖。

---

## 六、脚本做了什么

### 打包机：`make-offline-package.sh`

| 步骤 | 动作 |
| --- | --- |
| 0 | 环境自检（sudo、tar/unzip、随包工具链是否齐全） |
| 0.5 | **准备源码**：读 `latest` → 决定复用还是重新下载 → 解析最新版本 → 下载并校验 zip |
| 1 | 创建 `/opt/hermes-agent` 并改属主为当前用户 |
| 2 | 统一环境变量（`HERMES_AGENT_ROOT`、`UV_NO_CONFIG`、`ELECTRON_CACHE`、`PLAYWRIGHT_BROWSERS_PATH`、`NODE_PATH`），保证内外网路径一致 |
| 3 | 安装 uv 到 `/usr/local/bin` |
| 4 | 用 uv 创建 Python 3.11 venv：`/opt/hermes-agent/hermes-venv` |
| 5 | 解压源码并**去掉顶层目录**，让仓库内容直接位于安装根目录 |
| 6 | `uv pip install -e ".[all,dev]"` + `playwright` |
| 7 | 解压 Node.js 到 `node/`，升级 npm |
| 8 | 安装根目录与 `apps/desktop` 的 npm 依赖 |
| 9 | 预下载 Electron 到 `electron-cache/` |
| 10 | `npm run pack` 构建桌面端（产物在 `apps/desktop/release/`） |
| 11 | 预下载 Playwright Chromium 到 `playwright-cache/` |
| 12 | 复制安装脚本，并 `tar czvf` 打包 `/opt/hermes-agent` 到 `dist/hermes-desktop-arm64-offline.tar.gz` |

### 目标机：`install-offline-package.sh`

| 步骤 | 动作 |
| --- | --- |
| 1 | `apt install` 图形与运行时依赖（`libnss3`、`libgtk-3-0`、`libgbm1`、`libasound2`、`ripgrep`、`ffmpeg` 等） |
| 2 | 解压到 `/opt/hermes-agent` 并把属主改为当前用户 |
| 3 | 生成 `/usr/local/bin/hermes` 包装脚本（注入 `HERMES_AGENT_ROOT`、`PATH`、`NODE_PATH`、Playwright/Electron 缓存路径，并清理冲突的 `PYTHONPATH`/`PYTHONHOME`） |
| 4 | 写 `~/.local/share/applications/hermes.desktop` 桌面启动器 |
| 5 | 执行 `hermes --version` 验证 |

安装后的目录结构：

```
/opt/hermes-agent/
├── hermes-venv/            # Python 3.11 虚拟环境（含 hermes 命令）
├── uv/python/              # uv 托管的 Python 运行时
├── node/                   # Node.js v26.2.0
├── node_modules/           # 工作区 npm 依赖
├── apps/desktop/
│   └── release/            # 已编译的 Electron 桌面端
├── electron-cache/         # Electron 二进制缓存
├── playwright-cache/       # Chromium / headless shell / ffmpeg
├── skills/                 # 内置技能
├── hermes_cli/ agent/ tools/ gateway/ …   # 上游源码（无 src/ 层）
└── pyproject.toml

/usr/local/bin/hermes       # 启动包装脚本
~/.hermes/                  # 用户数据与配置（与安装目录分离）
```

---

## 七、配置要点

配置文件位于 `~/.hermes/config.yaml`。接入内网模型的最小配置：

```yaml
model:
  provider: openai-compatible
  base_url: http://你的内网服务端IP:8001/v1   # 注意结尾要带 /v1
  api_key: sk-internal-key
  name: Qwen3.6-27B-TS
```

内网环境常改的几项（摘自作者博文的实机配置）：

```yaml
# 1. 关闭代理探测，避免反复尝试联网
proxy:
  enabled: false

# 2. 会话标题默认调用外网模型，内网会报 "Auxiliary title generation failed"
auxiliary:
  title_generation:
    provider: custom
    model: custom/Qwen3.6-27B-TS     # "/" 后为模型名

# 3. 让代码在 Docker 沙箱里执行（需 docker-backend 变体）
terminal:
  backend: docker
  docker_image: hermes-sandbox-python312:20260901v1
  network: "none"                    # 禁止沙箱联网
  container_memory: 5120             # MB
  container_persistent: false        # 关闭 /workspace 会话间持久化
  docker_volumes:
    - /home/user/hermes-data/home:/opt/data/home    # 唯一可写目录
    - /home/user/hermes-data:/opt/data:ro           # 其余只读
```

> 提示：在会话里明确告诉 Agent「所有生成的文件都保存到 `/opt/data/home`」，可避免文件散落在容器内部而找不到。

---

## 八、常见问题

**Q：`latest` 提示版本，但我想锁定旧版本怎么办？**
`HERMES_VERSION=v2026.9.14 ./make-offline-package.sh`；或者直接回答 `N` 复用现有源码包。

**Q：步骤 9/10 卡在下载 Electron。**
Electron 走 GitHub Releases，内网打包机若访问不畅，可先设置镜像：`export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"`，再重跑脚本。

**Q：`npm install` 很慢或失败。**
打包机可切换 registry：`npm config set registry https://registry.npmmirror.com`。注意：切换后请在打包机上完整跑通一次，避免产物里混入不可用的依赖源。

**Q：桌面端启动白屏 / 报缺少 `.so`。**
补齐系统库：`sudo apt install -y libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2`。Wayland 下如遇异常，可用 `GDK_BACKEND=x11 hermes desktop --skip-build` 回退到 X11。

**Q：内网没有 apt 源，第 1 步就失败。**
提前在目标机装好依赖，或在脚本里注释掉 `apt update/install` 两行后手动执行。

**Q：启动后一直报 `Auxiliary title generation failed: Request timed out.`**
不影响使用，按[第七节](#七配置要点)配置 `auxiliary.title_generation` 指向内网模型即可。

**Q：升级怎么办？**
在打包机上重新出包（`--redownload`），到目标机重跑 `install-offline-package.sh`。安装脚本会覆盖 `/opt/hermes-agent`，**不会**动 `~/.hermes/` 中的用户数据。

**Q：卸载？**

```bash
sudo rm -rf /opt/hermes-agent /usr/local/bin/hermes
rm -f ~/.local/share/applications/hermes.desktop
# 仅在不再需要会话与配置时：
# rm -rf ~/.hermes
```

---

## 九、目录结构（本仓库）

```
hermes-agent-offline-installer/
├── make-offline-package.sh              # 打包脚本（联网打包机执行）
├── install-offline-package.sh           # 目标机安装脚本（打包时自动复制进 dist/）
├── dist/                                # 打包产物：tar.gz + 安装脚本（gitignored）
├── README.md
├── README_EN.md
└── .gitignore
```

> 仓库只存放脚本与文档。`dist/`、`dists/`、源码包、Node/uv 运行时、离线 `tar.gz` 等大文件均被 `.gitignore` 排除，请在打包机上生成。
> `dist/` 下的两个文件就是发布时的全部内容：`hermes-desktop-arm64-offline.tar.gz` + `install-offline-package.sh`。

---

## 十、致谢与许可

- Hermes Agent 由 [Nous Research](https://nousresearch.com) 开发，遵循 MIT 许可：[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)。
- 部署思路、内网配置与沙箱方案来自作者博文：
  [上篇](https://blog.csdn.net/vegaszx/article/details/163778194) ·
  [下篇](https://blog.csdn.net/vegaszx/article/details/163802884) ·
  [番外篇](https://blog.csdn.net/vegaszx/article/details/163803319)。
- 本仓库的脚本与文档同样以 MIT 许可发布；上游源码与其许可证以打包时下载的版本为准。
