#!/usr/bin/env bash
# =============================================================================
# 一键部署自用代理：VLESS-Reality-Vision (TCP) x2 + Hysteria2 (UDP)
# 适用：Debian 11/12、Ubuntu 20.04+，需要 root 和 systemd，x86_64 / arm64
#
# 用法（全部参数可选，用环境变量传入）：
#   bash install.sh
#   REALITY_SNI=www.nvidia.com REALITY_PORT2=0 NODE_PREFIX=LA bash install.sh
#
# 运行结束后，客户端配置写在 $OUT_DIR（默认 /root/vpn-client）：
#   clash.yaml  —— Clash Verge Rev / Clash Meta for Android / Stash 直接导入
#   links.txt   —— vless:// 与 hysteria2:// 分享链接（Shadowrocket 等）
# =============================================================================
set -euo pipefail

# ---------------------------- 可调参数 ----------------------------------------
# Xray 版本锁定：实测 Xray >= v26.7.11 时 mihomo(Clash Meta) v1.19.33 的 Reality
# 握手会失败（服务端日志 "REALITY: processed invalid connection"），官方 Xray
# 客户端不受影响。升级前请先用 Clash 客户端实测。
XRAY_VERSION="${XRAY_VERSION:-v26.6.27}"
HY2_VERSION="${HY2_VERSION:-v2.13.0}"

REALITY_PORT="${REALITY_PORT:-443}"          # 主 Reality 入站（TCP）
REALITY_SNI="${REALITY_SNI:-www.nvidia.com}" # 伪装目标站，需支持 TLS1.3 + H2
REALITY_PORT2="${REALITY_PORT2:-8443}"       # 备用 Reality 入站，设为 0 则不创建
REALITY_SNI2="${REALITY_SNI2:-www.oracle.com}"
HY2_PORT="${HY2_PORT:-443}"                  # Hysteria2（UDP），设为 0 则不安装
HY2_SNI="${HY2_SNI:-www.bing.com}"           # 自签证书 CN + 伪装站

NODE_PREFIX="${NODE_PREFIX:-VPS}"            # 客户端里节点名前缀
SERVER_IP="${SERVER_IP:-}"                   # 留空自动探测公网 IPv4
OUT_DIR="${OUT_DIR:-/root/vpn-client}"
FORCE="${FORCE:-0}"                          # 1 = 覆盖已有配置（会先备份）
RENDER_ONLY="${RENDER_ONLY:-0}"              # 1 = 只生成配置到 $OUT_DIR，不安装、不改系统
XRAY_BIN="${XRAY_BIN:-xray}"                 # RENDER_ONLY 时用来生成密钥的 xray
# -----------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
die()   { red "错误：$*"; exit 1; }

if [[ "$RENDER_ONLY" == 1 ]]; then
  XRAY_CONF="$OUT_DIR/server/xray-config.json"
  HY2_DIR="$OUT_DIR/server/hysteria"
else
  XRAY_CONF="/usr/local/etc/xray/config.json"
  HY2_DIR="/etc/hysteria"
fi

# ---------------------------- 前置检查 ----------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行"
  command -v systemctl >/dev/null || die "需要 systemd"
  command -v apt-get >/dev/null || die "本脚本只支持 Debian / Ubuntu（apt）"

  if [[ -f "$XRAY_CONF" && "$FORCE" != 1 ]]; then
    die "$XRAY_CONF 已存在。确认要覆盖请加 FORCE=1（会自动备份旧配置）"
  fi

  local p
  for p in "$REALITY_PORT" "$REALITY_PORT2"; do
    [[ "$p" == 0 ]] && continue
    if ss -Htlnp "sport = :$p" | grep -vqE 'xray|^$'; then
      ss -Htlnp "sport = :$p"
      die "TCP $p 已被其他程序占用（常见是 nginx / 宝塔）。换端口：REALITY_PORT=xxxx"
    fi
  done
  if [[ "$HY2_PORT" != 0 ]] && ss -Hulnp "sport = :$HY2_PORT" | grep -vqE 'hysteria|^$'; then
    ss -Hulnp "sport = :$HY2_PORT"
    die "UDP $HY2_PORT 已被占用。换端口：HY2_PORT=xxxx"
  fi
}

install_deps() {
  info "安装依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl openssl ca-certificates iproute2 >/dev/null
}

install_xray() {
  info "安装 Xray $XRAY_VERSION（锁定版本）"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
    @ install --version "$XRAY_VERSION" >/dev/null
  xray version | head -1
}

install_hy2() {
  info "安装 Hysteria2 $HY2_VERSION"
  bash <(curl -fsSL https://get.hy2.sh/) --version "$HY2_VERSION" >/dev/null
  hysteria version | grep -i '^version' || true
}

detect_ip() {
  [[ -n "$SERVER_IP" ]] && return
  SERVER_IP=$(curl -4 -fsS -m8 https://api.ipify.org || curl -4 -fsS -m8 https://ifconfig.me || true)
  [[ "$SERVER_IP" =~ ^[0-9.]+$ ]] || die "探测公网 IP 失败，请手动指定 SERVER_IP=x.x.x.x"
}

# ---------------------------- 生成密钥 ----------------------------------------
gen_secrets() {
  info "生成 UUID / Reality 密钥 / 密码"
  UUID=$("$XRAY_BIN" uuid)
  local keys
  keys=$("$XRAY_BIN" x25519)
  # 兼容新旧两种输出：
  #   旧："Private key: xxx" / "Public key: yyy"
  #   新："PrivateKey: xxx"  / "Password (PublicKey): yyy"
  PRIV=$(awk -F': *' 'tolower($1) ~ /^private ?key/ {print $2}' <<<"$keys")
  PUB=$(awk -F': *' 'tolower($1) ~ /public ?key/ {print $2}' <<<"$keys")
  [[ -n "$PRIV" && -n "$PUB" ]] || { echo "$keys"; die "无法解析 xray x25519 输出"; }
  # 二次校验：用私钥反推公钥，必须一致
  local derived
  derived=$("$XRAY_BIN" x25519 -i "$PRIV")
  [[ "$derived" == *"$PUB"* ]] || die "Reality 公私钥校验不一致"
  SHORT_ID=$(openssl rand -hex 8)
  HY2_PASS=$(openssl rand -hex 16)
  OBFS_PASS=$(openssl rand -hex 16)
}

backup() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" || true; }

# ---------------------------- 服务端配置 --------------------------------------
reality_inbound() { # $1=port $2=sni
  cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $1,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$2:443",
          "serverNames": ["$2"],
          "privateKey": "$PRIV",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
EOF
}

write_xray_conf() {
  info "写入 Xray 配置 $XRAY_CONF"
  mkdir -p "$(dirname "$XRAY_CONF")"
  backup "$XRAY_CONF"
  {
    echo '{'
    echo '  "log": { "loglevel": "warning", "access": "none" },'
    echo '  "inbounds": ['
    reality_inbound "$REALITY_PORT" "$REALITY_SNI"
    if [[ "$REALITY_PORT2" != 0 ]]; then
      echo '    ,'
      reality_inbound "$REALITY_PORT2" "$REALITY_SNI2"
    fi
    cat <<'EOF'
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }]
  }
}
EOF
  } >"$XRAY_CONF"

  if [[ "$RENDER_ONLY" != 1 ]]; then
    local g
    g=$(systemctl show -p Group --value xray 2>/dev/null || true)
    chmod 640 "$XRAY_CONF"
    [[ -n "$g" ]] && chgrp "$g" "$XRAY_CONF"
    # 如果以后在 log 里加了 access/error 文件，目录必须属于服务用户，否则 xray 起不来
    if [[ -d /var/log/xray ]]; then
      local u; u=$(systemctl show -p User --value xray 2>/dev/null || true)
      [[ -n "$u" ]] && chown -R "$u": /var/log/xray
    fi
    "$XRAY_BIN" run -test -c "$XRAY_CONF" >/dev/null || die "Xray 配置校验失败"
    echo "# DO NOT upgrade blindly: Xray >= v26.7.11 breaks mihomo (Clash Meta) Reality. Pinned $XRAY_VERSION on $(date +%F)" \
      >"$(dirname "$XRAY_CONF")/PINNED-VERSION.txt"
  fi
}

write_hy2_conf() {
  [[ "$HY2_PORT" == 0 ]] && return
  info "写入 Hysteria2 配置 $HY2_DIR/config.yaml（自签证书 CN=$HY2_SNI）"
  mkdir -p "$HY2_DIR"
  backup "$HY2_DIR/config.yaml"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$HY2_DIR/server.key" -out "$HY2_DIR/server.crt" \
    -subj "/CN=$HY2_SNI" -days 3650 2>/dev/null
  cat >"$HY2_DIR/config.yaml" <<EOF
listen: :$HY2_PORT
tls:
  cert: $HY2_DIR/server.crt
  key: $HY2_DIR/server.key
auth:
  type: password
  password: $HY2_PASS
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS
masquerade:
  type: proxy
  proxy:
    url: https://$HY2_SNI
    rewriteHost: true
EOF
  if [[ "$RENDER_ONLY" != 1 ]]; then
    chmod 600 "$HY2_DIR/server.key"
    id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$HY2_DIR/server.key" "$HY2_DIR/server.crt"
  fi
}

# ---------------------------- 系统设置 ----------------------------------------
open_firewall() {
  local ssh_port
  ssh_port=$(ss -Htlnp | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')
  ssh_port=${ssh_port:-22}
  local rules=("$ssh_port/tcp" "$REALITY_PORT/tcp")
  [[ "$REALITY_PORT2" != 0 ]] && rules+=("$REALITY_PORT2/tcp")
  [[ "$HY2_PORT" != 0 ]] && rules+=("$HY2_PORT/udp")

  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    info "ufw 已启用，放行：${rules[*]}"
    local r; for r in "${rules[@]}"; do ufw allow "$r" >/dev/null; done
  elif systemctl is-active -q firewalld 2>/dev/null; then
    info "firewalld 已启用，放行：${rules[*]}"
    local r; for r in "${rules[@]}"; do firewall-cmd -q --permanent --add-port="$r"; done
    firewall-cmd -q --reload
  else
    info "未检测到启用中的 ufw/firewalld，跳过（不会替你开启防火墙，避免锁死 SSH）"
  fi
  red "提醒：云厂商控制台的「安全组 / 防火墙」也要放行：${rules[*]}"
}

enable_bbr() {
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    info "BBR 已开启"; return
  fi
  if modprobe tcp_bbr 2>/dev/null; then
    info "开启 BBR"
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null
  else
    info "内核不支持 BBR，跳过"
  fi
}

start_services() {
  info "启动服务"
  systemctl enable -q xray
  systemctl restart xray
  if [[ "$HY2_PORT" != 0 ]]; then
    systemctl enable -q hysteria-server
    systemctl restart hysteria-server
  fi
  sleep 2
  systemctl is-active -q xray || { journalctl -u xray -n 20 --no-pager; die "xray 未能启动"; }
  if [[ "$HY2_PORT" != 0 ]]; then
    systemctl is-active -q hysteria-server || { journalctl -u hysteria-server -n 20 --no-pager; die "hysteria 未能启动"; }
  fi
  green "xray$([[ "$HY2_PORT" != 0 ]] && echo ' + hysteria-server') 运行中，已设开机自启"
}

# ---------------------------- 客户端配置 --------------------------------------
write_client() {
  info "生成客户端配置 → $OUT_DIR"
  mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
  local n1="$NODE_PREFIX-Reality" n2="$NODE_PREFIX-Reality-$REALITY_PORT2" n3="$NODE_PREFIX-Hy2"
  local names=("$n1")
  [[ "$REALITY_PORT2" != 0 ]] && names+=("$n2")
  [[ "$HY2_PORT" != 0 ]] && names+=("$n3")

  vless_proxy() { # name port sni
    cat <<EOF
  - name: $1
    type: vless
    server: $SERVER_IP
    port: $2
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $3
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUB
      short-id: $SHORT_ID

EOF
  }

  {
    cat <<'EOF'
# Clash Meta / mihomo 配置 —— Clash Verge Rev、Clash Meta for Android、FlClash、Stash 可用
# 原版 ClashX / ClashX Pro 不支持 VLESS-Reality。本文件含节点密钥，请勿公开。
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
geox-url:
  geoip: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat
  geosite: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
  mmdb: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '+.msftconnecttest.com'
    - '+.msftncsi.com'
    - 'time.*.com'
    - 'ntp.*.com'
  respect-rules: true          # DNS 查询也按规则走：国外 DoH 经代理发出，防 DNS 泄露
  default-nameserver:          # 只用于解析下面 DoH 服务器自身的域名
    - 223.5.5.5
    - 119.29.29.29
  proxy-server-nameserver:     # 只用于解析代理服务器域名（本配置是 IP，基本用不到）
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  nameserver:                  # 国外域名
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  nameserver-policy:           # 国内域名用国内 DNS，保证解析到国内 CDN
    'geosite:cn,private':
      - https://223.5.5.5/dns-query
      - https://doh.pub/dns-query

proxies:
EOF
    vless_proxy "$n1" "$REALITY_PORT" "$REALITY_SNI"
    [[ "$REALITY_PORT2" != 0 ]] && vless_proxy "$n2" "$REALITY_PORT2" "$REALITY_SNI2"
    if [[ "$HY2_PORT" != 0 ]]; then
      cat <<EOF
  - name: $n3
    type: hysteria2
    server: $SERVER_IP
    port: $HY2_PORT
    password: $HY2_PASS
    obfs: salamander
    obfs-password: $OBFS_PASS
    sni: $HY2_SNI
    skip-cert-verify: true

EOF
    fi
    echo 'proxy-groups:'
    echo '  - name: PROXY'
    echo '    type: select'
    echo '    proxies:'
    echo '      - AUTO'
    local n; for n in "${names[@]}"; do echo "      - $n"; done
    echo '      - DIRECT'
    echo
    echo '  - name: AUTO'
    echo '    type: fallback'
    echo '    url: https://www.gstatic.com/generate_204'
    echo '    interval: 300'
    echo '    proxies:'
    for n in "${names[@]}"; do echo "      - $n"; done
    cat <<'EOF'

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,PROXY
EOF
  } >"$OUT_DIR/clash.yaml"

  vless_link() { # name port sni
    echo "vless://$UUID@$SERVER_IP:$2?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$3&fp=chrome&pbk=$PUB&sid=$SHORT_ID&type=tcp#$1"
  }
  {
    vless_link "$n1" "$REALITY_PORT" "$REALITY_SNI"
    [[ "$REALITY_PORT2" != 0 ]] && vless_link "$n2" "$REALITY_PORT2" "$REALITY_SNI2"
    [[ "$HY2_PORT" != 0 ]] && echo "hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?sni=$HY2_SNI&insecure=1&obfs=salamander&obfs-password=$OBFS_PASS#$n3"
    true
  } >"$OUT_DIR/links.txt"
  chmod 600 "$OUT_DIR/clash.yaml" "$OUT_DIR/links.txt"
}

# ---------------------------- 主流程 ------------------------------------------
main() {
  if [[ "$RENDER_ONLY" == 1 ]]; then
    command -v "$XRAY_BIN" >/dev/null || die "RENDER_ONLY 需要 xray 可执行文件（XRAY_BIN）"
    SERVER_IP="${SERVER_IP:-127.0.0.1}"
    gen_secrets; write_xray_conf; write_hy2_conf; write_client
    green "已生成（未安装、未改系统）：$OUT_DIR"
    return
  fi

  preflight
  install_deps
  detect_ip
  install_xray
  [[ "$HY2_PORT" != 0 ]] && install_hy2
  gen_secrets
  write_xray_conf
  write_hy2_conf
  open_firewall
  enable_bbr
  start_services
  write_client

  echo
  green "================ 部署完成 ================"
  echo "服务器 IP     : $SERVER_IP"
  echo "Reality       : TCP $REALITY_PORT (SNI $REALITY_SNI)$([[ "$REALITY_PORT2" != 0 ]] && echo ", TCP $REALITY_PORT2 (SNI $REALITY_SNI2)")"
  [[ "$HY2_PORT" != 0 ]] && echo "Hysteria2     : UDP $HY2_PORT (obfs salamander)"
  echo "Clash 配置    : $OUT_DIR/clash.yaml"
  echo "分享链接      : $OUT_DIR/links.txt"
  echo
  echo "下载到本地（在你自己电脑上执行）："
  echo "  scp root@$SERVER_IP:$OUT_DIR/clash.yaml ./vpn.yaml"
  red "clash.yaml / links.txt 里有全部密钥，不要发到群里或传到 GitHub。"
}

main "$@"
