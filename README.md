# remote-herdr

Turn a cheap VPS into a **persistent remote coding machine** you can drive from
anywhere — from a laptop terminal or from a browser on your phone.

It installs and hardens:

- **[Herdr](https://herdr.dev)** — a persistent terminal workspace (like tmux, but
  built for AI coding agents). Panes keep running across disconnects and reboots.
- **[pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)** — the AI
  coding agent that runs inside a Herdr pane.
- **ttyd** — a terminal-to-HTTP gateway so you can use the same workspace from a
  browser. It binds to **loopback only**; a **Cloudflare Tunnel** provides the
  encrypted public front door.
- **Hardening** — key-only SSH, no root login, default-deny firewall, fail2ban,
  unattended security upgrades, and conservative network sysctls.

```
   your laptop / phone
          │  https://herdr.example.com  (Cloudflare edge + Access)
          ▼
   cloudflared tunnel
          │  http://127.0.0.1:7681  (loopback only)
          ▼
         ttyd  ──spawns──►  herdr client
          │
          ▼
   herdr server (headless, persistent)   ← survives disconnects & reboots
          ├── pane 1: pi agent
          ├── pane 2: shell
          └── pane 3: tests / logs
```

Two ways to use the box:

| Method | How | Best for |
|---|---|---|
| **Native** (best UX) | `herdr --remote vps1` from a local terminal | daily driving from a laptop |
| **Web** | browser → `https://herdr.example.com` → ttyd → herdr | phones, locked-down machines, no client install |

The long-form design notes live in
[`remote-coding-vps-setup.md`](./remote-coding-vps-setup.md).

---

## Repository layout

```
.
├── setup.sh                  # idempotent provisioner — runs ON the VPS
├── bootstrap.sh              # copies repo to the VPS and runs setup.sh (local)
├── files/
│   ├── sshd/99-hardening.conf        # sshd drop-in
│   ├── fail2ban/jail.local           # fail2ban sshd jail
│   ├── systemd/herdr.service         # persistent herdr server (user unit)
│   ├── systemd/ttyd.service.tmpl     # loopback web terminal (system unit)
│   ├── systemd/cloudflared.service.tmpl
│   └── cloudflared/config.yml.example
├── remote-coding-vps-setup.md        # the original step-by-step write-up
├── LICENSE
└── README.md
```

---

## Quick start

### 1. Prerequisites

- A Debian/Ubuntu VPS with a **non-root** user (this guide assumes `ubuntu`) that
  has **passwordless sudo**.
- Key-based SSH already working, e.g. a local `~/.ssh/config` entry:

  ```sshconfig
  Host vps1
      HostName <vps-ip-or-dns>
      User ubuntu
      IdentitiesOnly yes
      IdentityFile ~/.ssh/id_ed25519
  ```

- A domain on Cloudflare (`example.com` in this example).

> **Do not run agents as root.** Create a normal user, or use the cloud image's
> default user. The scripts refuse to run as root.

### 2. Run it

From your laptop, in this repo:

```bash
./bootstrap.sh vps1
```

That copies the repo to `~/remote-herdr` on the host and runs `./setup.sh all`
there: **harden → install → services → ttyd → cloudflared → verify**.

Prefer to run phases one at a time?

```bash
./bootstrap.sh vps1 harden       # SSH, firewall, fail2ban, upgrades, sysctl
./bootstrap.sh vps1 install      # herdr, Node 22, pi, ttyd
./bootstrap.sh vps1 services     # herdr server as a systemd --user service
./bootstrap.sh vps1 ttyd         # loopback-only web terminal
./bootstrap.sh vps1 cloudflared  # install Cloudflare Tunnel connector for ttyd
./bootstrap.sh vps1 verify       # health checks
```

Everything is **idempotent** — re-run any phase safely.

### 3. Finish the two interactive steps

**a) Authenticate pi** (needs a human):

```bash
ssh vps1
pi            # then run:  /login
#   or:  echo 'export DEEPSEEK_API_KEY=...' >> ~/.bashrc
```

**b) Configure the Cloudflare Tunnel.** `setup.sh cloudflared` installs the
`cloudflared` connector but leaves the tunnel to you. The origin it must reach is

```
http://127.0.0.1:7681
```

Two ways to wire it up:

**Dashboard-managed (easiest).** In the Cloudflare dashboard go to
**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**, add a
**Public hostname**:

| Field | Value |
|---|---|
| Subdomain | `herdr` |
| Domain | `example.com` |
| Type | `HTTP` |
| URL | `127.0.0.1:7681` |

Then copy the connector token and install it on the VPS:

```bash
ssh vps1
cd ~/remote-herdr
TUNNEL_TOKEN='<token from dashboard>' ./setup.sh cloudflared
sudo systemctl status cloudflared
```

**Locally-managed (config file).** On the VPS:

```bash
cloudflared tunnel login
cloudflared tunnel create vps1
cloudflared tunnel route dns vps1 herdr.example.com
cp ~/remote-herdr/files/cloudflared/config.yml.example ~/.cloudflared/config.yml
# edit ~/.cloudflared/config.yml: set tunnel + credentials-file
cd ~/remote-herdr && ./setup.sh cloudflared   # installs the service
```

Then browse to **`https://herdr.example.com`**.

> ⚠️ **Before you share the URL, add a Cloudflare Access policy.** A public
> hostname pointing at ttyd = a shell on your server for anyone who finds it.
> Zero Trust → Access → Applications → Self-hosted, hostname
> `herdr.example.com`, policy `Emails = you@example.com` with MFA/OTP. As
> defense in depth you can also set `TTYD_CREDENTIAL=user:pass` when running the
> `ttyd` phase.

---

## Configuration

All configuration is via environment variables, forwardable through
`bootstrap.sh`:

```bash
TTYD_PORT=8080 SSH_ALLOW_USERS=ubuntu ./bootstrap.sh vps1
TTYD_CREDENTIAL='me:s3cret' ./bootstrap.sh vps1 ttyd   # add HTTP basic auth
```

| Variable | Default | Meaning |
|---|---|---|
| `TARGET_USER` | current user | User that owns the workspace and runs the services |
| `TTYD_PORT` | `7681` | Loopback port for ttyd (the tunnel origin) |
| `SSH_ALLOW_USERS` | `TARGET_USER` | Value written to sshd `AllowUsers` |
| `TTYD_CREDENTIAL` | *(none)* | Optional `user:pass` basic auth on ttyd |
| `NODE_MAJOR` | `22` | Node.js major installed from NodeSource (pi needs ≥ 22.19) |
| `ALLOW_OPENSSH` | `1` | Keep port 22 open in ufw |
| `TUNNEL_HOSTNAME` | `herdr.example.com` | Public hostname the tunnel serves |
| `TUNNEL_TOKEN` | *(none)* | Dashboard-managed tunnel token; installs the connector service |
| `TUNNEL_CONFIG` | `~/.cloudflared/config.yml` | Locally-managed tunnel config path |

> `TUNNEL_TOKEN` is intentionally **not** forwarded by `bootstrap.sh` (it would
> leak into the remote process list). Set it on the VPS and run
> `./setup.sh cloudflared` there.

---

## What each phase does

### `harden`

- Writes `/etc/ssh/sshd_config.d/99-hardening.conf`:
  `PermitRootLogin no`, `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`,
  `MaxAuthTries 3`, `AllowUsers <you>`, no X11 / agent forwarding / tunnels.
  Validates with `sshd -t` before reloading.
- `ufw`: default deny inbound, allow outbound, allow OpenSSH.
- `fail2ban`: sshd jail with incremental bans, systemd backend.
- `unattended-upgrades`: enables daily security updates.
- `/etc/sysctl.d/99-hardening.conf`: rp_filter, SYN cookies, no redirects, etc.

> TCP forwarding is deliberately left enabled so `herdr --remote` keeps working.
> Uncomment `AllowTcpForwarding no` in the drop-in if you don't need it.

### `install`

- `curl`, `git`, `jq`, `ttyd` from apt.
- Herdr via `https://herdr.dev/install.sh` → `~/.local/bin/herdr`.
- Node.js 22 from NodeSource (apt's Node 18 is too old for pi).
- `@earendil-works/pi-coding-agent` globally with `--ignore-scripts`.

### `services`

- `herdr.service` as a `systemd --user` unit with `Restart=on-failure`.
- `loginctl enable-linger` so it starts at boot, with no SSH login needed.

### `ttyd`

- `/etc/systemd/system/ttyd.service`, running as your user, executing
  `ttyd -i 127.0.0.1 -p <port> -W ... herdr`.
- Hardened with `NoNewPrivileges=true` and `PrivateTmp=true`.

### `cloudflared`

- Installs the `cloudflared` connector (official `.deb`).
- With `TUNNEL_TOKEN`: writes `/etc/cloudflared/token.env` (mode `0600`) and a
  systemd service running `cloudflared tunnel --no-autoupdate run`.
- With `~/.cloudflared/config.yml`: installs a service running
  `cloudflared tunnel --no-autoupdate --config <path> run` as your user.
- Otherwise just installs the binary and prints the origin
  (`http://127.0.0.1:7681`) and instructions.

### `verify`

- Checks herdr server status, all three services, that port 7681 listens on
  **127.0.0.1 only**, the ufw rules, and the effective sshd settings.

---

## Web access: how the tunnel connects

Cloudflare terminates TLS at the edge and forwards to your connector, which
proxies to **ttyd on loopback**. The only value you need is:

```
Service:  http://127.0.0.1:7681
```

Recommended hardening for the public hostname:

1. **Cloudflare Access policy** (Zero Trust → Access → Applications) —
   email/SSO + MFA. Without it the hostname is public.
2. **Basic auth on ttyd** — `TTYD_CREDENTIAL=user:pass ./setup.sh ttyd`.
3. Keep ttyd bound to `127.0.0.1` — never change `-i 127.0.0.1`.
4. If you ever put Cloudflare in front with "Full" TLS mode, ttyd is still plain
   HTTP on loopback; `noTLSVerify: true` in the example config covers this.

Quick sanity checks from the VPS:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7681   # 200
sudo journalctl -u cloudflared -n 50 --no-pager
```

Quick temporary public URL for testing (no auth — do not leave running):

```bash
cloudflared tunnel --url http://127.0.0.1:7681
```

---

## Verify end to end

```bash
# on the VPS
./setup.sh verify
ss -ltnp | grep 7681          # must be 127.0.0.1:7681, never 0.0.0.0
sudo ufw status               # no 7681 inbound

# from your laptop (native path)
herdr machine add ubuntu@vps1 --label vps1
herdr --remote vps1
```

Inside a Herdr pane: `cd ~/src/proj && pi`, split panes (`prefix+v`, `prefix+c`),
detach/close, reopen later — the agent is still running.

---

## Security checklist

- [x] SSH: key-only, no root login, `AuthenticationMethods publickey`, ufw
      default-deny, fail2ban on.
- [x] Agents run as a non-root user.
- [x] ttyd binds `127.0.0.1` only; the port is not in the firewall allowlist.
- [x] Public access goes through a Cloudflare Tunnel, not an open port.
- [ ] **Cloudflare Access policy on `herdr.example.com`** (email/SSO + MFA).
- [ ] Optional defense-in-depth: `TTYD_CREDENTIAL=user:pass`.
- [ ] Review `cloudflared update` / `herdr update` / `npm update -g` regularly.
- [ ] Back up `~/.pi/agent` (credentials, sessions) and `~/.config/herdr`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `herdr: command not found` over SSH | Add `~/.local/bin` to `PATH` (the installer does this in `~/.bashrc`); non-login shells may need `export PATH="$HOME/.local/bin:$PATH"` |
| ttyd page loads but herdr exits | Herdr client can't find the server socket. Check `systemctl --user status herdr` and that `~/.config/herdr/herdr.sock` exists |
| `systemctl --user` fails over SSH | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` |
| Tunnel shows 502 / bad gateway | ttyd isn't up or is on the wrong port: `ss -ltnp \| grep 7681`, `systemctl status ttyd`, ensure the tunnel origin is `http://127.0.0.1:7681` |
| `cloudflared` service not present | No tunnel configured yet; run `TUNNEL_TOKEN=... ./setup.sh cloudflared` or create `~/.cloudflared/config.yml` then re-run |
| Check connector logs | `sudo journalctl -u cloudflared -n 100 --no-pager` |
| pi won't start | pi needs Node ≥ 22.19: `node -v`, else re-run `./setup.sh install` |
| Reboot didn't restart services | `sudo loginctl enable-linger $USER`; check `systemctl --user is-enabled herdr` |

---

## Uninstall

```bash
# services
sudo systemctl disable --now cloudflared 2>/dev/null
sudo rm -f /etc/systemd/system/cloudflared.service /etc/cloudflared/token.env
sudo systemctl disable --now ttyd
sudo rm -f /etc/systemd/system/ttyd.service
systemctl --user disable --now herdr
rm -f ~/.config/systemd/user/herdr.service
sudo loginctl disable-linger "$USER"

# hardening drop-ins
sudo rm -f /etc/ssh/sshd_config.d/99-hardening.conf /etc/sysctl.d/99-hardening.conf
sudo rm -f /etc/fail2ban/jail.local
sudo systemctl reload ssh && sudo systemctl restart fail2ban

# ufw stays configured; disable with: sudo ufw disable

# binaries
sudo apt-get remove --purge -y cloudflared
rm -f ~/.local/bin/herdr
sudo npm uninstall -g @earendil-works/pi-coding-agent
```

---

## License

MIT — see [LICENSE](./LICENSE).
