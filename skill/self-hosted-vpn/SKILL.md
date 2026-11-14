---
name: self-hosted-vpn
description: Deploy a personal proxy on the user's own Debian/Ubuntu VPS (Xray VLESS-Reality on TCP 443 + 8443, Hysteria2 on UDP 443) and connect Clash Verge Rev on macOS, Clash Meta for Android and iPhone, including the DNS-leak fix. Use when the user asks to set up, rebuild, debug or rotate keys for a self-hosted VPN/proxy/"梯子"/节点 on their server, or when Reality/Hysteria2 nodes stop working in Clash.
---

# Self-hosted VPN (Reality + Hysteria2 + Clash Verge)

Bundled files (relative to this skill's directory):
- `scripts/install.sh`: the server installer. It is idempotent with `FORCE=1`, writes the client config to `/root/vpn-client/{clash.yaml,links.txt}`, and has a `RENDER_ONLY=1` mode for tests.
- `scripts/mac-check.sh`: the macOS client check (ports, per-node delay through the mihomo socket, exit IP).

Reply in the user's language. Treat node secrets (UUID, private and public keys, shortId, Hy2 passwords) as credentials. Never paste them into public places, commits, artifacts or external services.

## 0. Access: key-based SSH only

- Never type, store or use a root password, even if the user pastes one. Ask the user to run the following themselves in the terminal:
  `ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<IP>` (run `ssh-keygen -t ed25519` first if no key exists).
- After that, run commands with `ssh -o ConnectTimeout=15 -i ~/.ssh/id_ed25519 root@<IP> '...'`. A transient "banner exchange" timeout usually works on retry.
- If the password was shared in chat, recommend that the user run `passwd`. Offer to disable `PasswordAuthentication`, but only after key login is confirmed.

## 1. Preflight (read-only)

```bash
ssh ... 'cat /etc/os-release | head -3; uname -m; free -h | sed -n 2p; systemd-detect-virt;
  ss -tlnp | grep -E ":(443|8443) "; ss -ulnp | grep ":443 ";
  ufw status 2>/dev/null | head -3; systemctl is-active firewalld 2>/dev/null;
  sysctl -n net.ipv4.tcp_congestion_control; ls /usr/local/etc/xray/config.json 2>/dev/null'
```

- If TCP 443 is held by nginx or BT Panel, don't kill it. Ask the user, or pick other ports (`REALITY_PORT=...`).
- If an Xray config already exists, ask before running with `FORCE=1`. Rotating keys breaks every client that is already imported.
- Remind the user that the cloud provider's security group must allow TCP 443, TCP 8443 and UDP 443. You can't see it from inside the VM.

## 2. Install

```bash
scp -i ~/.ssh/id_ed25519 <skill>/scripts/install.sh root@<IP>:/root/install.sh
ssh ... 'NODE_PREFIX=<short-name> bash /root/install.sh'
```

Optional env: `REALITY_SNI`, `REALITY_PORT2=0` (skip the 8443 node), `HY2_PORT=0` (skip Hy2), `SERVER_IP`, `FORCE=1`.
The script pins **Xray v26.6.27** (see gotcha 1) and Hysteria v2.13.0. It opens ports only in a firewall that is already active, enables BBR, and enables both services on boot.

Copy the client config into the local scratchpad, not into the project:
`scp ... root@<IP>:/root/vpn-client/clash.yaml <scratchpad>/vpn.yaml` (and `links.txt` for iOS).

## 3. Clients

**macOS (Clash Verge Rev)**
- Install it with `brew install --cask clash-verge-rev` if it's missing. Original ClashX / ClashX Pro can't do Reality.
- To import, serve the file on loopback only and use the deep link, then stop the server:
  ```bash
  cd <dir-with-vpn.yaml> && python3 -m http.server 18765 --bind 127.0.0.1 &   # background
  open "clash://install-config?url=http%3A%2F%2F127.0.0.1%3A18765%2Fvpn.yaml&name=<name>"
  ```
  Then confirm that `profiles.yaml` lists the new profile, and kill the server.
- TUN ("all traffic") needs the service installed first (Settings → install service, admin password). That's a user action, so don't automate the password.
- The controller socket path is in the mihomo process args (`ext-ctl-unix ...`). The default secret is `set-your-secret`. Real latency per node: `GET /proxies/<name>/delay?url=https://www.gstatic.com/generate_204&timeout=10000`.
- Clash Verge overrides `mixed-port` with its own setting (default 7897).

**Android (Clash Meta for Android)**
- Serve on the Mac's LAN IP (`ipconfig getifaddr en0`) with `python3 -m http.server 8899 --bind <LAN-IP>` in the background.
- The user adds it in Clash Meta → 配置 → 新配置 → URL `http://<LAN-IP>:8899/vpn.yaml`.
- **Stop the server as soon as the user confirms the import, and delete the served copy.** The file contains every secret.

**iPhone**
- Shadowrocket imports the `links.txt` lines. The links carry no DNS settings, so tell the user to use global route 代理, or to set the config's DNS to `https://1.1.1.1/dns-query, https://8.8.8.8/dns-query`.
- Stash can import the yaml over the same LAN URL.
- Say clearly that the iPhone steps are untested unless you verified them.

## 4. Verify

- Run `SERVER=<IP> bash <skill>/scripts/mac-check.sh`. Expect all TCP ports OK, a numeric delay for every node, and the exit IP equal to the server IP.
- Leak test: have the user open https://ip.net.coffee/claude/ (or ipleak.net). The expected result is "未检测到泄露" with a foreign DNS exit. A domestic resolver on `whoami.akamai.net` is expected, because `akamai.net` is in `geosite:cn`.

## 5. Gotchas (check these before deeper debugging)

1. **Xray ≥ v26.7.11 breaks Reality for mihomo v1.19.33.** The server log shows `REALITY: processed invalid connection ... authentication failed`, while the official Xray client still works. Keep v26.6.27 and don't run the upgrade script blindly. If you need to retest a version, bisect on the server: install `--version vX`, run a mihomo binary on the server against `127.0.0.1`, and curl through it.
2. **Another VPN on the client** (TUN utun*, some commercial apps restart themselves) hijacks Clash's outbound by SNI. That produces fake auth failures or timeouts. Check `ifconfig -l`, `scutil --nc list` and `pgrep -fl <app>`, and have the user fully quit it before you blame the server.
3. Xray won't start after log files are added: the log dir must be owned by the service user (`chown -R $(systemctl show -p User --value xray): /var/log/xray`).
4. Reality target: it must support TLS 1.3 + H2 (`curl -sI --tlsv1.3 --http2 https://<site>`). `www.apple.com` drew an Xray warning, `www.nvidia.com` and `www.oracle.com` work.
5. DNS leak: the bundled yaml already has `respect-rules: true`, foreign DoH in `nameserver`, `geosite:cn` routed to domestic DoH via `nameserver-policy`, and `no-resolve` on GEOIP rules. Don't remove these.
6. In a hand-written YAML, a flow list like `rules: [MATCH,R]` is wrong because the comma splits it into two items. Use block lists for rules.
7. Hy2 fails while Reality works: UDP 443 is blocked (security group, ufw, or the local network blocking UDP).
8. Google Play "add payment method → no network" is usually payments-profile, region or datacenter-IP risk control, not the tunnel. Don't spend long switching nodes.

## 6. Wrap up

- Tell the user which nodes work and their delays, and where the client files are.
- Confirm that any LAN or loopback config server is stopped.
- Remind the user that the VPS renewal date ends the service, and that `/usr/local/etc/xray/PINNED-VERSION.txt` explains the version pin.
