# remote-herdr

Turn a cheap VPS into a **persistent remote coding machine** you can drive from
anywhere — from a laptop terminal or from a browser on your phone.

It installs and hardens:

- **[Herdr](https://herdr.dev)** — a persistent terminal workspace (like tmux, but
  built for AI coding agents). Panes keep running across disconnects and reboots.
- **[pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)** — the AI
  coding agent that runs inside a Herdr pane.
- **ttyd** — a terminal-to-HTTP gateway so you can use the same workspace from a
  browser. It binds to **loopback only**; a private tunnel (Tailscale or
  Cloudflare Access) provides the encrypted front door.
- **Hardening** — key-only SSH, no root login, default-deny firewall, fail2ban,
  unattended security upgrades, and conservative network sysctls.

```
   your laptop / phone
          │  HTTPS (private)
          ▼
   Tailscale Serve  ──or──  Cloudflare Tunnel + Access
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
| **Web** | browser → Tailscale/Cloudflare URL → ttyd → herdr | phones, locked-down machines, no client install |

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

> **Do not run agents as root.** Create a normal user, or use the cloud image's
> default user. The scripts refuse to run as root.

### 2. Run it

From your laptop, in this repo:

```bash
./bootstrap.sh vps1
```

That copies the repo to `~/remote-herdr` on the host and runs `./setup.sh all`
there: **harden → install → services → ttyd → verify**.

Prefer to run phases one at a time?

```bash
./bootstrap.sh vps1 harden      # SSH, firewall, fail2ban, upgrades, sysctl
./bootstrap.sh vps1 install     # herdr, Node 22, pi, ttyd
./bootstrap.sh vps1 services    # herdr server as a systemd --user service
./bootstrap.sh vps1 ttyd        # loopback-only web terminal
./bootstrap.sh vps1 tailscale   # install Tailscale (login instructions printed)
./bootstrap.sh vps1 verify      # health checks
```

Everything is **idempotent** — re-run any phase safely.

### 3. Finish the two interactive steps

These need a human, so they are not automated:

```bash
ssh vps1

# a) Authenticate pi (subscription login or API key)
pi            # then run:  /login
#   or:  echo 'export DEEPSEEK_API_KEY=...' >> ~/.bashrc

# b) Log the box into your tailnet (recommended for web access)
sudo tailscale up --ssh --hostname=vps1
sudo tailscale serve --bg --https=443 http://127.0.0.1:7681
sudo ufw delete allow OpenSSH     # only after Tailscale SSH works
```

You now have a private HTTPS URL like
`https://vps1.<your-tailnet>.ts.net` that opens the Herdr workspace in any
browser on any device in your tailnet.

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
| `TTYD_PORT` | `7681` | Loopback port for ttyd |
| `SSH_ALLOW_USERS` | `TARGET_USER` | Value written to sshd `AllowUsers` |
| `TTYD_CREDENTIAL` | *(none)* | Optional `user:pass` basic auth on ttyd |
| `NODE_MAJOR` | `22` | Node.js major installed from NodeSource (pi needs ≥ 22.19) |
| `ALLOW_OPENSSH` | `1` | Keep port 22 open in ufw (set `0` once Tailscale SSH works) |
| `INSTALL_TAILSCALE_UP` | `0` | Run `tailscale up` during the tailscale phase |
| `TS_HOSTNAME` | short hostname | Tailscale node name |
| `TS_AUTHKEY` | *(none)* | Tailscale auth key; enables unattended `up` |

> `TS_AUTHKEY` is intentionally **not** forwarded by `bootstrap.sh` (it would
> leak into the remote process list). Set it on the VPS and run
> `./setup.sh tailscale` there.

---

## What each phase does

### `harden`

- Writes `/etc/ssh/sshd_config.d/99-hardening.conf`:
  `PermitRootLogin no`, `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`,
  `MaxAuthTries 3`, `AllowUsers <you>`, no X11 / agent forwarding / tunnels.
  Validates with `sshd -t` before reloading.
- `ufw`: default deny inbound, allow outbound, allow OpenSSH (until Tailscale).
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

### `tailscale`

- Installs the Tailscale package.
- If `TS_AUTHKEY`/`INSTALL_TAILSCALE_UP` is set, logs in with `--ssh` and
  publishes ttyd over `tailscale serve --https=443`. Otherwise prints the two
  commands to finish manually.

### `verify`

- Checks herdr server status, both services, that port 7681 listens on
  **127.0.0.1 only**, the ufw rules, and the effective sshd settings.

---

## Web access: choose one front door

Herdr is a TUI, not a web app. ttyd is what renders it in a browser. **Never
expose port 7681 to the internet.** Pick a private tunnel:

### Option A — Tailscale Serve (recommended)

Zero open inbound ports, automatic HTTPS, identity-based access. Only devices in
your tailnet can reach it.

```bash
sudo tailscale up --ssh --hostname=vps1
sudo tailscale serve --bg --https=443 http://127.0.0.1:7681
sudo tailscale serve status
sudo ufw delete allow OpenSSH        # Tailscale SSH replaces public SSH
```

Tighten access with a tailnet ACL so only your user/device can reach the port.

### Option B — Cloudflare Tunnel + Access

Use this if you want a browser-only path on devices that can't install Tailscale.
Auth is enforced by Cloudflare Access (email/SSO/MFA).

```bash
cloudflared tunnel login
cloudflared tunnel create vps1
cp files/cloudflared/config.yml.example ~/.cloudflared/config.yml   # edit it
cloudflared tunnel route dns vps1 herdr.example.com
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Then in **Zero Trust → Access → Applications**, add a self-hosted app for
`herdr.example.com` with a policy that allows only your email **with MFA**.
Without that policy the tunnel URL is public — **do not skip Access**.

### Option C — plain 443 (not recommended)

A real cert plus HTTP basic auth and an IP allowlist is the weakest option. A
terminal on the public internet with only a password *will* be brute-forced.
Prefer A or B.

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
- [x] Access path is Tailscale (tailnet ACL) **or** Cloudflare Access — never a
      bare public URL.
- [x] TLS everywhere (Tailscale/Cloudflare provide it automatically).
- [ ] Optional defense-in-depth: `TTYD_CREDENTIAL=user:pass`.
- [ ] Review `herdr update` / `npm update -g` regularly.
- [ ] Back up `~/.pi/agent` (credentials, sessions) and `~/.config/herdr`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `herdr: command not found` over SSH | Add `~/.local/bin` to `PATH` (the installer does this in `~/.bashrc`); non-login shells may need `export PATH="$HOME/.local/bin:$PATH"` |
| ttyd page loads but herdr exits | Herdr client can't find the server socket. Check `systemctl --user status herdr` and that `~/.config/herdr/herdr.sock` exists |
| `systemctl --user` fails over SSH | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` |
| Locked out after `ALLOW_OPENSSH=0` | Use the provider's console / Tailscale SSH to re-enable: `sudo ufw allow OpenSSH` |
| pi won't start | pi needs Node ≥ 22.19: `node -v`, else re-run `./setup.sh install` |
| Reboot didn't restart services | `sudo loginctl enable-linger $USER`; check `systemctl --user is-enabled herdr` |

---

## Uninstall

```bash
# services
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
rm -f ~/.local/bin/herdr
sudo npm uninstall -g @earendil-works/pi-coding-agent
```

---

## License

MIT — see [LICENSE](./LICENSE).
