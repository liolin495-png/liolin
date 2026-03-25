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
# 先直接检查已知路径（最快）
for direct_path in /opt/homebrew/lib/node_modules/openclaw/dist /usr/local/lib/node_modules/openclaw/dist; do
  if [ -d "$direct_path" ]; then
    OPENCLAW_DIST="$direct_path"
    break
  fi
done

# 再搜索 npx 缓存和全局 node_modules
if [ -z "$OPENCLAW_DIST" ]; then
  for search_dir in "$HOME/.npm/_npx" "$HOME/Library/pnpm" "$HOME/.pnpm" /tmp /usr/local/lib/node_modules /opt/homebrew/lib/node_modules "$HOME/.local/share"; do
    if [ -d "$search_dir" ]; then
      found=$(find "$search_dir" -maxdepth 8 -path "*/openclaw/dist" -type d 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then
        OPENCLAW_DIST="$found"
        break
      fi
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

# 4. 网络连通性诊断
echo ""
echo "=== 网络连通性诊断 ==="
echo "  如果报 'network connection error' 而非 'timed out'，问题在网络层"
echo ""

# 4a. 检查代理/VPN 环境变量
echo "  [4a] 代理/VPN 环境变量..."
PROXY_FOUND=0
for var in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
  val=$(printenv "$var" 2>/dev/null || true)
  if [ -n "$val" ]; then
    echo "    $var=$val"
    PROXY_FOUND=1
  fi
done
if [ "$PROXY_FOUND" -eq 0 ]; then
  echo "    (未设置任何代理环境变量)"
  echo "    如果你使用软路由/透明代理，终端进程一般不需要设置代理变量"
  echo "    但如果 gateway 是通过 launchd 启动的，它可能无法使用软路由的代理"
fi

# 检查 NO_PROXY
NO_PROXY_VAL=$(printenv NO_PROXY 2>/dev/null || printenv no_proxy 2>/dev/null || true)
if [ -n "$NO_PROXY_VAL" ]; then
  echo "    NO_PROXY=$NO_PROXY_VAL"
  echo "    ⚠ 请确认 API 域名没有被 NO_PROXY 排除"
fi
echo ""

# 4b. DNS 解析检查
echo "  [4b] DNS 解析检查..."
DNS_OK=0
DNS_FAIL=0
for domain in api.openai.com api.anthropic.com; do
  # 使用多种方式尝试解析
  resolved=""
  if command -v nslookup &>/dev/null; then
    resolved=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | head -1 || true)
  fi
  if [ -z "$resolved" ] && command -v dig &>/dev/null; then
    resolved=$(dig +short "$domain" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$resolved" ] && command -v host &>/dev/null; then
    resolved=$(host "$domain" 2>/dev/null | grep "has address" | head -1 || true)
  fi
  if [ -z "$resolved" ]; then
    # 最终 fallback: getent (Linux) 或 python
    resolved=$(getent hosts "$domain" 2>/dev/null | head -1 || true)
  fi

  if [ -n "$resolved" ]; then
    echo "    $domain -> $resolved"
    DNS_OK=$((DNS_OK + 1))
  else
    echo "    $domain -> ✗ 解析失败！"
    DNS_FAIL=$((DNS_FAIL + 1))
  fi
done

if [ "$DNS_FAIL" -gt 0 ]; then
  echo ""
  echo "    ⚠ DNS 解析失败！可能原因："
  echo "      1. 软路由 DNS 配置问题（API 域名被污染或拦截）"
  echo "      2. /etc/resolv.conf 中的 DNS 服务器不可用"
  echo "      3. 防火墙/GFW 拦截了这些域名"
  echo ""
  echo "    排查命令："
  echo "      cat /etc/resolv.conf"
  echo "      nslookup api.openai.com 8.8.8.8"
  echo "      nslookup api.openai.com 1.1.1.1"
fi
echo ""

# 4c. TCP 连通性检查 (不发送 HTTP 请求，只检查 TCP 握手)
echo "  [4c] TCP 连通性检查 (API endpoints)..."
TCP_OK=0
TCP_FAIL=0
for endpoint in "api.openai.com:443" "api.anthropic.com:443"; do
  host_part="${endpoint%%:*}"
  port_part="${endpoint##*:}"

  # 尝试多种方式测试 TCP 连通
  connected=0
  if command -v curl &>/dev/null; then
    if curl -s --connect-timeout 10 --max-time 10 -o /dev/null "https://${host_part}" 2>/dev/null; then
      connected=1
    fi
  fi

  if [ "$connected" -eq 0 ] && command -v nc &>/dev/null; then
    if nc -z -w 10 "$host_part" "$port_part" 2>/dev/null; then
      connected=1
    fi
  fi

  if [ "$connected" -eq 0 ]; then
    # 使用 bash /dev/tcp 作为 fallback
    if (echo > "/dev/tcp/${host_part}/${port_part}") 2>/dev/null; then
      connected=1
    fi
  fi

  if [ "$connected" -eq 1 ]; then
    echo "    $endpoint -> ✓ 可达"
    TCP_OK=$((TCP_OK + 1))
  else
    echo "    $endpoint -> ✗ 不可达 (连接失败或超时)"
    TCP_FAIL=$((TCP_FAIL + 1))
  fi
done

if [ "$TCP_FAIL" -gt 0 ]; then
  echo ""
  echo "    ⚠ API 端点 TCP 连接失败！"
  echo "    你的终端可以连接，但 gateway 进程可能不行"
  echo "    常见原因："
  echo "      1. 软路由的代理规则没有覆盖这些域名"
  echo "      2. 代理节点本身故障或负载过高"
  echo "      3. 防火墙规则阻止了 443 端口出站连接"
  echo ""
  echo "    排查："
  echo "      # 测试直连（绕过代理）"
  echo "      curl -v --connect-timeout 10 https://api.openai.com/v1/models 2>&1 | head -30"
  echo "      # 看 TLS 握手是否成功"
  echo "      openssl s_client -connect api.openai.com:443 -servername api.openai.com </dev/null 2>&1 | head -20"
fi
echo ""

# 4d. HTTP API 可达性检查 (发送无认证请求，期望 401 而非连接错误)
echo "  [4d] HTTP API 可达性检查..."
if command -v curl &>/dev/null; then
  for api_url in "https://api.openai.com/v1/models" "https://api.anthropic.com/v1/messages"; do
    domain=$(echo "$api_url" | sed 's|https://\([^/]*\).*|\1|')
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 --max-time 20 "$api_url" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ]; then
      echo "    $domain -> ✗ 连接失败 (网络不通)"
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
      echo "    $domain -> ✓ 可达 (HTTP $http_code, 认证未通过是正常的)"
    elif [ "$http_code" = "200" ]; then
      echo "    $domain -> ✓ 可达 (HTTP 200)"
    else
      echo "    $domain -> △ HTTP $http_code (连接成功但响应异常)"
    fi
  done
else
  echo "    curl 不可用，跳过 HTTP 检查"
fi
echo ""

# 4e. 检查 gateway 进程是否能继承网络环境
echo "  [4e] Gateway 进程网络环境检查..."
GW_PID_NET=$(pgrep -f 'openclaw.*gateway' 2>/dev/null | head -1 || true)
if [ -n "$GW_PID_NET" ]; then
  echo "    Gateway PID: $GW_PID_NET"
  # Linux: 读取 /proc/PID/environ
  if [ -f "/proc/$GW_PID_NET/environ" ]; then
    GW_PROXY=$(tr '\0' '\n' < "/proc/$GW_PID_NET/environ" 2>/dev/null | grep -iE "proxy|all_proxy" || true)
    if [ -n "$GW_PROXY" ]; then
      echo "    Gateway 进程代理变量:"
      echo "$GW_PROXY" | while read -r line; do echo "      $line"; done
    else
      echo "    Gateway 进程没有代理环境变量"
      echo "    如果你依赖代理翻墙，gateway 可能无法访问 API"
    fi
    # 检查 NODE_TLS_REJECT_UNAUTHORIZED
    GW_TLS=$(tr '\0' '\n' < "/proc/$GW_PID_NET/environ" 2>/dev/null | grep "NODE_TLS" || true)
    if [ -n "$GW_TLS" ]; then
      echo "    TLS 设置: $GW_TLS"
    fi
  fi
  # macOS: 无法直接读取进程环境变量，给出提示
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "    macOS 无法直接读取进程环境变量"
    echo "    如果 gateway 通过 launchd 启动，代理变量可能未继承"
    echo "    建议手动启动: pkill -f openclaw && npx openclaw gateway"
  fi
else
  echo "    Gateway 进程未运行，无法检查其网络环境"
fi
echo ""

# 4f. 综合诊断建议
echo "  [4f] 综合诊断建议..."
if [ "$TCP_FAIL" -gt 0 ] || [ "$DNS_FAIL" -gt 0 ]; then
  echo ""
  echo "  ===== 网络问题确认 ====="
  echo ""
  echo "  你的环境存在网络连通性问题。可能的修复方案："
  echo ""
  echo "  方案 1: 确保软路由代理规则覆盖 API 域名"
  echo "    在软路由(OpenWrt/Clash/V2Ray)的代理规则中添加："
  echo "      - api.openai.com"
  echo "      - api.anthropic.com"
  echo "    确保这些域名走代理而非直连"
  echo ""
  echo "  方案 2: 给 gateway 进程设置代理环境变量"
  echo "    export HTTPS_PROXY=http://你的代理地址:端口"
  echo "    export HTTP_PROXY=http://你的代理地址:端口"
  echo "    npx openclaw gateway"
  echo ""
  echo "  方案 3: 如果用 launchd 管理 gateway，在 plist 中添加环境变量"
  echo "    找到 plist: find ~/Library/LaunchAgents -name '*openclaw*'"
  echo "    在 <dict> 中添加:"
  echo "    <key>EnvironmentVariables</key>"
  echo "    <dict>"
  echo "      <key>HTTPS_PROXY</key>"
  echo "      <string>http://你的代理地址:端口</string>"
  echo "    </dict>"
  echo ""
else
  echo "    ✓ 从当前终端可以连通 API 端点"
  echo "    如果 gateway 仍报 'network connection error'，问题可能是："
  echo "      1. Gateway 进程的网络环境与终端不同"
  echo "         -> 手动前台启动: pkill -f openclaw && npx openclaw gateway"
  echo "      2. API Key 未配置或已失效"
  echo "         -> 检查 ~/.openclaw/openclaw.json 中的 apiKey"
  echo "      3. TLS/SSL 证书问题（代理使用了 MITM 证书）"
  echo "         -> export NODE_TLS_REJECT_UNAUTHORIZED=0 （临时测试用）"
  echo "         -> 或将代理 CA 证书添加到系统信任链"
  echo "      4. Node.js 版本过低不支持某些 TLS 特性"
  echo "         -> node --version (建议 >= 18)"
  echo ""
fi

# 5. Gateway 进程诊断
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
