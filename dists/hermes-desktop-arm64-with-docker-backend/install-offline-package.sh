#!/bin/bash
set -e

OFFLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/hermes-agent"

echo "=== 步骤1：安装系统运行时依赖 ==="
sudo apt update
sudo apt install -y git libnss3 libxkbcommon0 libgtk-3-0 libgbm1 libasound2 \
    ripgrep ffmpeg

echo "=== 步骤2：解压离线包到 /opt ==="
cd /opt
sudo tar xzvf "$OFFLINE_DIR/hermes-desktop-arm64-offline.tar.gz"
sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR"

echo "=== 步骤3：创建 hermes 启动命令 ==="
sudo tee /usr/local/bin/hermes << 'EOF'
#!/bin/bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_AGENT_ROOT="/opt/hermes-agent"

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
sudo chmod +x /usr/local/bin/hermes

echo "=== 步骤4：创建桌面启动器（可选）==="
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

echo "=== 步骤5：验证安装 ==="
hermes --version

echo ""
echo "✓ 安装完成！"
echo "  启动终端界面: hermes --tui"
echo "  启动桌面应用: hermes desktop --skip-build"
echo ""
echo "如需连接 Docker 服务端，请编辑 ~/.hermes/config.yaml:"
echo "  model:"
echo "    provider: openai-compatible"
echo "    base_url: http://你的docker服务端IP:8642/v1"
echo "    api_key: sk-internal-key"
