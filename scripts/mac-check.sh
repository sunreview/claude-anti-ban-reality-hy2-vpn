#!/bin/bash
# macOS 客户端自检：端口连通性 + Clash Verge 里每个节点的真实延迟
# 用法：SERVER=1.2.3.4 bash scripts/mac-check.sh
#      可选：PORTS="22 443 8443"  CLASH_SECRET=set-your-secret（Clash Verge 默认值）
# 测之前请彻底退出其他 VPN（它们的 TUN 会劫持 Clash 的出站，导致假的 Reality 握手失败）
S="${SERVER:?请用 SERVER=你的服务器IP 运行}"
PORTS="${PORTS:-22 443 8443}"
SECRET="${CLASH_SECRET:-set-your-secret}"

echo "== $(date) =="
echo "-- 其他 VPN / 虚拟网卡（应该只有 Clash 自己的 utun）"
scutil --nc list 2>/dev/null | grep -i connected || echo "系统 VPN：无已连接"
ifconfig -l | tr ' ' '\n' | grep utun | tr '\n' ' '; echo
echo "去往服务器的路由: $(route -n get "$S" 2>/dev/null | awk '/interface/ {print $2}')"
echo "本机直连出口 IP : $(curl -s -m8 --noproxy '*' https://myip.ipip.net || echo '获取失败')"

echo "-- TCP 端口（直连）"
for p in $PORTS; do
  if nc -z -G5 -w5 "$S" "$p" 2>/dev/null; then echo "TCP $p: OK"; else echo "TCP $p: FAILED"; fi
done

echo "-- Clash 节点延迟（mihomo 控制接口）"
SOCK=$(ps -axo args= | grep -o -E "ext-ctl-unix [^ ]+" | head -1 | awk '{print $2}')
if [ ! -S "$SOCK" ]; then
  echo "没找到 Clash Verge 的控制 socket（Clash Verge 没运行？），跳过"
  exit 0
fi
api() { curl -s -m12 --unix-socket "$SOCK" -H "Authorization: Bearer $SECRET" "http://localhost$1"; }
NODES=$(api /proxies | python3 -c '
import json,sys
d=json.load(sys.stdin)["proxies"]
print("\n".join(n for n,p in d.items() if p.get("type","").lower() in ("vless","hysteria2","vmess","trojan","shadowsocks","tuic")))')
[ -z "$NODES" ] && { echo "读不到节点（CLASH_SECRET 不对？）"; exit 1; }
while IFS= read -r n; do
  enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$n")
  echo "$n: $(api "/proxies/$enc/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=10000")"
done <<<"$NODES"
# Clash Verge 会用自己的端口设置覆盖配置里的 mixed-port（默认 7897），以实际运行值为准
PORT=$(api /configs | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mixed-port") or 7890)')
echo "经代理(:$PORT)出口 IP : $(curl -s -m10 -x "http://127.0.0.1:$PORT" https://api.ipify.org || echo '失败')"
