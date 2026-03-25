#!/usr/bin/env bash
# OpenClaw 配置修复脚本
# 问题：截图失败 / 无法控制电脑 / 权限不足 / LLM 请求超时
# 根因：
#   1. Linux 环境缺少图形显示服务器 (DISPLAY 未设置)
#   2. GatewayClient.requestTimeoutMs 硬编码为 30s (3e4)，导致 LLM 请求超时
#   3. 配置文件的 timeoutSeconds 无法覆盖 Gateway WebSocket 请求超时

set -euo pipefail

echo "=== OpenClaw 环境修复脚本 ==="

# 1. 启动 Xvfb 虚拟显示 (如果未运行)
if [ -z "${DISPLAY:-}" ] || ! ls /tmp/.X11-unix/X${DISPLAY#:} 2>/dev/null; then
  echo "[1/5] 启动 Xvfb 虚拟显示..."
  Xvfb :99 -screen 0 1920x1080x24 &>/dev/null &
  export DISPLAY=:99
  sleep 1
  echo "  ✓ 虚拟显示已启动 (DISPLAY=$DISPLAY)"
else
  echo "[1/5] 显示服务器已运行 (DISPLAY=$DISPLAY)"
fi

# 2. 检查依赖工具
echo "[2/5] 检查依赖工具..."
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
echo "[3/5] 测试截图功能..."
if scrot /tmp/openclaw_test.png 2>/dev/null; then
  echo "  ✓ 截图功能正常"
  rm -f /tmp/openclaw_test.png
else
  echo "  ✗ 截图失败 - 请检查 Xvfb 是否正常运行"
  exit 1
fi

# 4. Patch 所有硬编码超时 (根因修复)
echo "[4/6] Patch 硬编码超时值..."
# OpenClaw 有 3 处硬编码的 30s 超时导致 LLM 请求超时：
#   a) method-scopes-*.js: GatewayClient.requestTimeoutMs = 3e4 (WebSocket 请求超时)
#   b) pi-embedded-*.js: resolveGatewayOptions 中 callGatewayTool 的默认 timeoutMs = 3e4
#   c) call-*.js: resolveGatewayCallTimeout 连接超时 = 1e4 (10秒)
# 配置文件无法覆盖这些值，必须直接 patch 源码
OPENCLAW_DIST=$(find "$HOME/.npm/_npx" /tmp -maxdepth 6 -path "*/openclaw/dist" -type d 2>/dev/null | head -1)
PATCH_COUNT=0
if [ -n "$OPENCLAW_DIST" ]; then
  # Patch a) GatewayClient.requestTimeoutMs: 30s -> 300s
  METHOD_SCOPES=$(ls "$OPENCLAW_DIST"/method-scopes-*.js 2>/dev/null | head -1)
  if [ -n "$METHOD_SCOPES" ]; then
    if grep -q 'requestTimeoutMs.*: 3e4' "$METHOD_SCOPES"; then
      sed -i 's/\(requestTimeoutMs.*\): 3e4/\1: 3e5/g' "$METHOD_SCOPES"
      echo "  ✓ [a] GatewayClient.requestTimeoutMs: 30s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    elif grep -q 'requestTimeoutMs.*: 3e5' "$METHOD_SCOPES"; then
      echo "  ✓ [a] 已 patch (300s)"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
  fi

  # Patch b) callGatewayTool 默认 timeoutMs: 30s -> 300s
  PI_EMBEDDED=$(ls "$OPENCLAW_DIST"/pi-embedded-*.js 2>/dev/null | head -1)
  if [ -n "$PI_EMBEDDED" ]; then
    if grep -q 'opts\.timeoutMs)) : 3e4' "$PI_EMBEDDED"; then
      sed -i 's/opts\.timeoutMs)) : 3e4/opts.timeoutMs)) : 3e5/g' "$PI_EMBEDDED"
      echo "  ✓ [b] callGatewayTool timeoutMs: 30s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    elif grep -q 'opts\.timeoutMs)) : 3e5' "$PI_EMBEDDED"; then
      echo "  ✓ [b] 已 patch (300s)"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
  fi

  # Patch c) resolveGatewayCallTimeout 连接超时: 10s -> 300s
  CALL_FILE=$(ls "$OPENCLAW_DIST"/call-*.js 2>/dev/null | head -1)
  if [ -n "$CALL_FILE" ]; then
    if grep -q 'timeoutValue) : 1e4' "$CALL_FILE"; then
      sed -i 's/timeoutValue) : 1e4/timeoutValue) : 3e5/g' "$CALL_FILE"
      echo "  ✓ [c] resolveGatewayCallTimeout: 10s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    elif grep -q 'timeoutValue) : 3e5' "$CALL_FILE"; then
      echo "  ✓ [c] 已 patch (300s)"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
  fi

  echo "  Patch 完成: $PATCH_COUNT/3 处已修复"
else
  echo "  ⚠ 未找到 openclaw 安装路径，跳过 patch"
  echo "    请先运行: npx openclaw --version 确认已安装"
fi

# 5. 写入超时配置文件 (补充保护)
echo "[5/6] 写入超时配置..."
OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
mkdir -p "$OPENCLAW_DIR"

if [ -f "$OPENCLAW_CONFIG" ]; then
  cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.bak.$(date +%s)"
  echo "  已备份现有配置"

  if command -v node &>/dev/null; then
    node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('$OPENCLAW_CONFIG', 'utf8'));
      cfg.agents = cfg.agents || {};
      cfg.agents.defaults = cfg.agents.defaults || {};
      cfg.agents.defaults.timeoutSeconds = Math.max(cfg.agents.defaults.timeoutSeconds || 0, 300);
      cfg.models = cfg.models || {};
      cfg.models.providers = cfg.models.providers || {};
      for (const [name, provider] of Object.entries(cfg.models.providers)) {
        provider.requestTimeout = Math.max(provider.requestTimeout || 0, 300000);
        provider.retry = Object.assign({
          attempts: 5,
          minDelayMs: 1000,
          maxDelayMs: 60000,
          jitter: 0.2
        }, provider.retry || {});
        provider.retry.attempts = Math.max(provider.retry.attempts, 5);
      }
      fs.writeFileSync('$OPENCLAW_CONFIG', JSON.stringify(cfg, null, 2) + '\n');
    "
    echo "  ✓ 已合并超时配置到现有设置"
  else
    cat > "$OPENCLAW_CONFIG" << 'CFGEOF'
{
  "agents": {
    "defaults": {
      "timeoutSeconds": 300
    }
  },
  "models": {
    "providers": {
      "openai": {
        "requestTimeout": 300000,
        "retry": {
          "attempts": 5,
          "minDelayMs": 1000,
          "maxDelayMs": 60000,
          "jitter": 0.2
        }
      }
    }
  }
}
CFGEOF
    echo "  ✓ 已写入新的超时配置"
  fi
else
  cat > "$OPENCLAW_CONFIG" << 'CFGEOF'
{
  "agents": {
    "defaults": {
      "timeoutSeconds": 300
    }
  },
  "models": {
    "providers": {
      "openai": {
        "requestTimeout": 300000,
        "retry": {
          "attempts": 5,
          "minDelayMs": 1000,
          "maxDelayMs": 60000,
          "jitter": 0.2
        }
      }
    }
  }
}
CFGEOF
  echo "  ✓ 已创建超时配置: $OPENCLAW_CONFIG"
fi

echo "  配置详情:"
echo "    - Agent 超时: 300s"
echo "    - Provider requestTimeout: 300s"
echo "    - 失败重试: 最多 5 次，指数退避 1s-60s"
echo "  Patch 详情:"
echo "    - GatewayClient.requestTimeoutMs: 30s -> 300s"
echo "    - callGatewayTool timeoutMs: 30s -> 300s"
echo "    - resolveGatewayCallTimeout: 10s -> 300s"

# 6. 检查 OpenClaw Gateway
echo "[6/6] 检查 OpenClaw Gateway..."
if npx openclaw browser status &>/dev/null; then
  echo "  ✓ Gateway 正在运行"
  echo ""
  echo "  注意: 配置已更新，请重启 Gateway 使超时配置生效:"
  echo "    pkill -f 'openclaw gateway' && DISPLAY=:99 npx openclaw gateway &"
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
echo "提示:"
echo "  1. 将 'export DISPLAY=:99' 加入 ~/.bashrc 以永久生效"
echo "  2. 超时配置文件: ~/.openclaw/openclaw.json"
echo "  3. patch 在 npx openclaw 更新后需重新运行本脚本"
echo "  4. 修复后必须重启 Gateway 才能生效"
