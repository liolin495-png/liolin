#!/usr/bin/env bash
# OpenClaw LLM 超时修复脚本 (macOS / Linux 通用)
# 问题：所有 provider (OpenAI / Anthropic / VibeCoding) 都报 "LLM request timed out"
# 根因：OpenClaw 源码中有 4 处硬编码超时值太短，配置文件无法覆盖
#
# 用法：bash fix-openclaw.sh
# 修复后必须重启 Gateway：pkill -f 'openclaw' && npx openclaw gateway

set -euo pipefail

echo "=== OpenClaw LLM 超时修复脚本 ==="
echo "平台: $(uname -s) $(uname -m)"

# macOS sed 兼容：使用 perl 替代 sed -i（macOS sed -i 需要备份后缀）
safe_replace() {
  local file="$1" old="$2" new="$3"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    perl -pi -e "s/\Q${old}\E/${new}/g" "$file"
  else
    sed -i "s/${old}/${new}/g" "$file"
  fi
}

# 1. 查找 OpenClaw 安装路径
echo ""
echo "[1/3] 查找 OpenClaw 安装路径..."
OPENCLAW_DIST=""
for search_dir in "$HOME/.npm/_npx" "$HOME/Library/pnpm" "$HOME/.pnpm" /tmp; do
  found=$(find "$search_dir" -maxdepth 8 -path "*/openclaw/dist" -type d 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    OPENCLAW_DIST="$found"
    break
  fi
done

# 也搜索全局 node_modules
if [ -z "$OPENCLAW_DIST" ]; then
  for search_dir in /usr/local/lib/node_modules /opt/homebrew/lib/node_modules "$HOME/.local/share"; do
    found=$(find "$search_dir" -maxdepth 6 -path "*/openclaw/dist" -type d 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      OPENCLAW_DIST="$found"
      break
    fi
  done
fi

if [ -z "$OPENCLAW_DIST" ]; then
  echo "  ✗ 未找到 openclaw 安装路径"
  echo "    请先确认 openclaw 已安装: npx openclaw --version"
  echo "    然后重新运行本脚本"
  exit 1
fi
echo "  ✓ 找到: $OPENCLAW_DIST"

# 2. Patch 所有硬编码超时
echo ""
echo "[2/3] Patch 硬编码超时值..."
echo "  OpenClaw 有 4 处硬编码超时导致 LLM 请求超时："
echo "    a) GatewayClient.requestTimeoutMs = 30s (WebSocket 请求)"
echo "    b) callGatewayTool timeoutMs = 30s (工具调用)"
echo "    c) resolveGatewayCallTimeout = 10s (连接超时)"
echo "    d) gateway-rpc CLI default + fallback = 30s/10s (RPC 调用)"
echo ""

PATCH_COUNT=0
PATCH_TOTAL=4

# Patch a) GatewayClient.requestTimeoutMs: 30s -> 300s
METHOD_SCOPES=$(ls "$OPENCLAW_DIST"/method-scopes-*.js 2>/dev/null | head -1)
if [ -n "$METHOD_SCOPES" ]; then
  if grep -q 'requestTimeoutMs.*: 3e4' "$METHOD_SCOPES" 2>/dev/null; then
    safe_replace "$METHOD_SCOPES" ': 3e4' ': 3e5'
    # 验证
    if grep -q '3e5' "$METHOD_SCOPES"; then
      echo "  ✓ [a] GatewayClient.requestTimeoutMs: 30s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    else
      echo "  ✗ [a] patch 失败"
    fi
  elif grep -q 'requestTimeoutMs.*: 3e5' "$METHOD_SCOPES" 2>/dev/null; then
    echo "  ✓ [a] 已是 300s (无需修改)"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  else
    echo "  ⚠ [a] 未找到预期的超时值，版本可能不同"
  fi
else
  echo "  ⚠ [a] 未找到 method-scopes-*.js"
fi

# Patch b) callGatewayTool 默认 timeoutMs: 30s -> 300s
PI_EMBEDDED=$(ls "$OPENCLAW_DIST"/pi-embedded-*.js 2>/dev/null | head -1)
if [ -n "$PI_EMBEDDED" ]; then
  # 精确匹配 callGatewayTool 的默认超时
  if grep -q 'opts\.timeoutMs)) : 3e4' "$PI_EMBEDDED" 2>/dev/null; then
    safe_replace "$PI_EMBEDDED" 'opts.timeoutMs)) : 3e4' 'opts.timeoutMs)) : 3e5'
    if grep -q 'opts\.timeoutMs)) : 3e5' "$PI_EMBEDDED"; then
      echo "  ✓ [b] callGatewayTool timeoutMs: 30s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    else
      echo "  ✗ [b] patch 失败"
    fi
  elif grep -q 'opts\.timeoutMs)) : 3e5' "$PI_EMBEDDED" 2>/dev/null; then
    echo "  ✓ [b] 已是 300s (无需修改)"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  else
    echo "  ⚠ [b] 未找到预期的超时值"
  fi
else
  echo "  ⚠ [b] 未找到 pi-embedded-*.js"
fi

# Patch c) resolveGatewayCallTimeout: 10s -> 300s
CALL_FILE=$(ls "$OPENCLAW_DIST"/call-*.js 2>/dev/null | head -1)
if [ -n "$CALL_FILE" ]; then
  if grep -q 'timeoutValue) : 1e4' "$CALL_FILE" 2>/dev/null; then
    safe_replace "$CALL_FILE" 'timeoutValue) : 1e4' 'timeoutValue) : 3e5'
    if grep -q 'timeoutValue) : 3e5' "$CALL_FILE"; then
      echo "  ✓ [c] resolveGatewayCallTimeout: 10s -> 300s"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    else
      echo "  ✗ [c] patch 失败"
    fi
  elif grep -q 'timeoutValue) : 3e5' "$CALL_FILE" 2>/dev/null; then
    echo "  ✓ [c] 已是 300s (无需修改)"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  else
    echo "  ⚠ [c] 未找到预期的超时值"
  fi
else
  echo "  ⚠ [c] 未找到 call-*.js"
fi

# Patch d) gateway-rpc CLI default 30s -> 300s 和 fallback 10s -> 300s
GW_RPC=$(ls "$OPENCLAW_DIST"/gateway-rpc-*.js 2>/dev/null | head -1)
if [ -n "$GW_RPC" ]; then
  D_PATCHED=0
  # CLI 默认值 "30000" -> "300000"
  if grep -q '"30000"' "$GW_RPC" 2>/dev/null; then
    safe_replace "$GW_RPC" '"30000"' '"300000"'
    D_PATCHED=1
  elif grep -q '"300000"' "$GW_RPC" 2>/dev/null; then
    D_PATCHED=1
  fi
  # fallback 1e4 -> 3e5
  if grep -q '?? 1e4' "$GW_RPC" 2>/dev/null; then
    safe_replace "$GW_RPC" '?? 1e4' '?? 3e5'
    D_PATCHED=$((D_PATCHED + 1))
  elif grep -q '?? 3e5' "$GW_RPC" 2>/dev/null; then
    D_PATCHED=$((D_PATCHED + 1))
  fi
  if [ "$D_PATCHED" -ge 2 ]; then
    echo "  ✓ [d] gateway-rpc: CLI 30s + fallback 10s -> 300s"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  elif [ "$D_PATCHED" -ge 1 ]; then
    echo "  △ [d] gateway-rpc: 部分 patch 成功"
    PATCH_COUNT=$((PATCH_COUNT + 1))
  else
    echo "  ⚠ [d] 未找到预期的超时值"
  fi
else
  echo "  ⚠ [d] 未找到 gateway-rpc-*.js"
fi

echo ""
echo "  Patch 结果: $PATCH_COUNT/$PATCH_TOTAL 处已修复"

if [ "$PATCH_COUNT" -eq 0 ]; then
  echo ""
  echo "  ⚠ 没有成功 patch 任何文件！"
  echo "    可能原因："
  echo "    1. OpenClaw 版本不同，文件名/代码结构变化"
  echo "    2. 文件权限不足（尝试 sudo bash fix-openclaw.sh）"
  echo ""
  echo "  手动排查："
  echo "    grep -r 'requestTimeoutMs.*3e4' $OPENCLAW_DIST/"
  echo "    grep -r 'timeoutValue.*1e4' $OPENCLAW_DIST/"
fi

# 3. 写入配置文件 (补充保护)
echo ""
echo "[3/3] 写入超时配置..."
OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
mkdir -p "$OPENCLAW_DIR"

if [ -f "$OPENCLAW_CONFIG" ]; then
  cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.bak.$(date +%s)"
  echo "  已备份: $OPENCLAW_CONFIG.bak.*"

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
    echo "  ✓ 已合并超时配置"
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
      },
      "anthropic": {
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
  echo "  ✓ 已创建配置: $OPENCLAW_CONFIG"
fi

echo ""
echo "=== 完成 ==="
echo ""
echo "⚠ 重要：必须重启 Gateway 才能生效！"
echo ""
echo "  pkill -f openclaw"
echo "  npx openclaw gateway"
echo ""
echo "如果重启后仍然超时，请运行以下命令并把输出发给我："
echo ""
echo "  # 验证 patch 是否生效"
echo "  grep -o 'requestTimeoutMs.*: [0-9e]*' $OPENCLAW_DIST/method-scopes-*.js"
echo "  grep -o 'timeoutMs)) : [0-9e]*' $OPENCLAW_DIST/pi-embedded-*.js | head -1"
echo "  grep -o 'timeoutValue) : [0-9e]*' $OPENCLAW_DIST/call-*.js"
echo "  grep -n 'timeout\|1e4\|3e4\|3e5\|30000\|300000' $OPENCLAW_DIST/gateway-rpc-*.js"
echo ""
echo "  # 查看 gateway 日志"
echo "  npx openclaw gateway logs"
echo ""
echo "提示："
echo "  - patch 在 npx openclaw 更新后会被覆盖，需重新运行本脚本"
echo "  - 配置文件: $OPENCLAW_CONFIG"

# 4. Gateway 进程诊断
echo ""
echo "=== Gateway 进程诊断 ==="

# 检查 launchctl
if command -v launchctl &>/dev/null; then
  GW_STATUS=$(launchctl list 2>/dev/null | grep -i gateway || true)
  if [ -n "$GW_STATUS" ]; then
    EXIT_CODE=$(echo "$GW_STATUS" | awk '{print $2}')
    echo "  launchctl 状态: $GW_STATUS"
    if [ "$EXIT_CODE" = "-9" ]; then
      echo ""
      echo "  ⚠⚠⚠ Gateway 退出码 -9 (SIGKILL) ⚠⚠⚠"
      echo "  这意味着 Gateway 进程被系统强制杀掉了！"
      echo "  常见原因："
      echo "    1. 内存不足 (OOM) — macOS 杀掉了高内存进程"
      echo "    2. launchd 启动超时 — 进程启动太慢被 launchd 杀掉"
      echo "    3. 沙盒/权限问题"
      echo ""
      echo "  建议排查步骤："
      echo "    # 查看系统日志中的 kill 原因"
      echo "    log show --predicate 'process == \"openclaw\" OR eventMessage CONTAINS \"openclaw\"' --last 5m"
      echo ""
      echo "    # 查看是否 OOM"
      echo "    log show --predicate 'eventMessage CONTAINS \"Jetsam\"' --last 10m | head -20"
      echo ""
      echo "    # 手动前台启动 gateway 观察报错"
      echo "    launchctl stop ai.openclaw.gateway 2>/dev/null"
      echo "    npx openclaw gateway"
      echo ""
      echo "    # 如果是 launchd 超时，可增加 plist 中的 TimeoutStartInterval"
      echo "    # 找到 plist 文件："
      echo "    find ~/Library/LaunchAgents /Library/LaunchAgents -name '*openclaw*' 2>/dev/null"
    elif [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "-" ]; then
      echo "  ⚠ Gateway 退出码: $EXIT_CODE (非正常)"
      echo "  建议手动前台启动查看报错: npx openclaw gateway"
    else
      echo "  ✓ Gateway 状态正常"
    fi
  else
    echo "  Gateway 未在 launchctl 中注册"
  fi
fi

# 检查进程
GW_PID=$(pgrep -f 'openclaw.*gateway' 2>/dev/null || true)
if [ -n "$GW_PID" ]; then
  echo "  ✓ Gateway 进程运行中: PID $GW_PID"
else
  echo "  ✗ Gateway 进程未运行"
  echo "    尝试手动启动: npx openclaw gateway"
fi
