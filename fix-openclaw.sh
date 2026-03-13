#!/usr/bin/env bash
# OpenClaw 配置修复脚本
# 问题：截图失败 / 无法控制电脑 / 权限不足
# 根因：Linux 环境缺少图形显示服务器 (DISPLAY 未设置)

set -euo pipefail

echo "=== OpenClaw 环境修复脚本 ==="

# 1. 启动 Xvfb 虚拟显示 (如果未运行)
if [ -z "${DISPLAY:-}" ] || ! ls /tmp/.X11-unix/X${DISPLAY#:} 2>/dev/null; then
  echo "[1/4] 启动 Xvfb 虚拟显示..."
  Xvfb :99 -screen 0 1920x1080x24 &>/dev/null &
  export DISPLAY=:99
  sleep 1
  echo "  ✓ 虚拟显示已启动 (DISPLAY=$DISPLAY)"
else
  echo "[1/4] 显示服务器已运行 (DISPLAY=$DISPLAY)"
fi

# 2. 检查依赖工具
echo "[2/4] 检查依赖工具..."
MISSING=""
for cmd in xdotool scrot xclip; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done
if [ -n "$MISSING" ]; then
  echo "  安装缺少的工具:$MISSING"
  sudo apt-get install -y -qq $MISSING
fi
echo "  ✓ 所有依赖工具已就绪"

# 3. 测试截图
echo "[3/4] 测试截图功能..."
if scrot /tmp/openclaw_test.png 2>/dev/null; then
  echo "  ✓ 截图功能正常"
  rm -f /tmp/openclaw_test.png
else
  echo "  ✗ 截图失败 - 请检查 Xvfb 是否正常运行"
  exit 1
fi

# 4. 检查 OpenClaw Gateway
echo "[4/4] 检查 OpenClaw Gateway..."
if npx openclaw browser status &>/dev/null; then
  echo "  ✓ Gateway 正在运行"
else
  echo "  ✗ Gateway 未运行"
  echo ""
  echo "  请运行以下命令初始化 (替换 YOUR_API_KEY):"
  echo ""
  echo "    DISPLAY=:99 npx openclaw onboard \\"
  echo "      --mode local \\"
  echo "      --non-interactive \\"
  echo "      --accept-risk \\"
  echo "      --auth-choice openai-api-key \\"
  echo "      --openai-api-key \"YOUR_API_KEY\" \\"
  echo "      --skip-channels --skip-daemon --skip-ui"
  echo ""
  echo "  然后启动 Gateway:"
  echo "    DISPLAY=:99 npx openclaw gateway &"
fi

echo ""
echo "=== 完成 ==="
echo "提示: 将 'export DISPLAY=:99' 加入 ~/.bashrc 以永久生效"
