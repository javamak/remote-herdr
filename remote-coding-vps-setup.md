# Remote coding machine on `vps1` — Herdr + pi, web access

## What you're building

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
   herdr server (headless, persistent)   ← stays alive across disconnects/reboots
          ├── pane 1: pi agent
          ├── pane 2: shell
          └── pane 3: tests / logs
```

Important truth: **Herdr is a TUI, not a web app.** The "web application" is a
terminal-to-HTTP gateway (ttyd) that renders `herdr` in a browser. The secure
part is the tunnel in front of it.

Two ways to use the box once set up:

| Method | How | Best for |
|---|---|---|
| Native (best UX) | `herdr --remote vps1` from a local terminal | daily driving from a laptop |
| Web | browser → Tailscale/Cloudflare URL → ttyd → herdr | phones, locked-down machines, no client install |

---

## Phase 0 — Prerequisites

- SSH access to `vps1` (`ssh vps1` works, ideally key-based already).
- A **non-root user** on the VPS to own the work (e.g. `coder`). Do not run agents as root.
- Debian/Ubuntu assumed below; adjust for other distros.

Add/confirm a host alias locally (`~/.ssh/config`):

```sshconfig
Host vps1
    HostName <vps-ip-or-dns>
    User coder
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_ed25519
```

---

## Phase 1 — Harden SSH + firewall (do this first)

On `vps1`:

```bash
# 1. Key-only auth
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh

# 2. Firewall: default deny inbound, allow SSH only
sudo apt-get update
sudo apt-get install -y ufw fail2ban
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo systemctl enable --now fail2ban
```

> If you later use **Tailscale**, you can close SSH to the public internet too
> (`ufw delete allow OpenSSH` + use Tailscale SSH). Keep it open until Tailscale works.

---

## Phase 2 — Install Herdr and pi on the VPS

SSH in as `coder`:

```bash
ssh vps1

# --- Herdr (installs to ~/.local/bin/herdr) ---
curl -fsSL https://herdr.dev/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
herdr --version        # expect 0.9.x

# make PATH permanent
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# --- pi agent (needs Node 18+; use nvm if node is old) ---
node --version
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi --version
```

Authenticate pi (do it once, from a terminal):

```bash
# Option A: subscription login
pi
#   then run:  /login

# Option B: API key (example)
echo 'export DEEPSEEK_API_KEY=...' >> ~/.bashrc   # or your provider
```

Confirm Herdr runs headless:

```bash
herdr server        # start it once in foreground to verify; Ctrl-C to stop
herdr status server
herdr server stop
```

---

## Phase 3 — Run the Herdr server as a service (survives reboot)

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/herdr.service <<'EOF'
[Unit]
Description=Herdr headless server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/herdr server
Restart=on-failure
RestartSec=2
Environment=HERDR_LOG=info

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now herdr

# keep user services running without an SSH login
sudo loginctl enable-linger "$USER"

systemctl --user status herdr --no-pager
herdr status server
```

The server now owns the panes permanently. Closing your laptop / browser does
**not** stop the work.

---

## Phase 4 — Native access (recommended daily path)

Install Herdr on your **local** machine too, then attach as a thin client:

```bash
# local machine
curl -fsSL https://herdr.dev/install.sh | sh

# save the remote machine once
herdr machine add --label vps1 coder@vps1

# attach (or just pick vps1 from the sidebar)
herdr --remote vps1
```

`herdr machine add` prepares the remote server and remembers it. Detach with
`prefix+q` (`ctrl+b`, release, `q`) or by closing the window — panes keep running.

Start your agent inside a Herdr pane:

```bash
cd ~/src/myproject
pi
```

You can also SSH in and run `herdr` directly (works like tmux), which is the
simplest fallback if you don't want a local client.

---

## Phase 5 — Web access (the part you asked about)

Install a terminal-over-web gateway that runs `herdr`. Bind it to **loopback
only**, then put a private tunnel in front.

### 5a. Install ttyd

```bash
sudo apt-get install -y ttyd
ttyd --version
```

Test locally on the VPS (still only loopback):

```bash
ttyd -i 127.0.0.1 -p 7681 -W "$HOME/.local/bin/herdr"
# then from another SSH session:  curl -I http://127.0.0.1:7681
```

Flags: `-i 127.0.0.1` loopback only, `-W` writable, `-t titleFixed=Herdr`,
and optionally `-c user:pass` for HTTP basic auth (defense in depth).

Make it a service:

```bash
sudo tee /etc/systemd/system/ttyd.service >/dev/null <<'EOF'
[Unit]
Description=ttyd web terminal for Herdr
After=network-online.target

[Service]
User=coder
Environment=TERM=xterm-256color
ExecStart=/usr/bin/ttyd -i 127.0.0.1 -p 7681 -W -t titleFixed=Herdr /home/coder/.local/bin/herdr
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ttyd
sudo systemctl status ttyd --no-pager
```

Still not reachable from outside — port 7681 listens on loopback and ufw denies it.

### 5b. Secure exposure — Option A: Tailscale Serve (recommended)

Zero open inbound ports, automatic HTTPS, identity-based access. Nothing is
public; only devices in your tailnet can reach it.

On `vps1`:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh        # log in; --ssh also gives you Tailscale SSH

# Publish ttyd privately over HTTPS (MagicDNS name)
sudo tailscale serve --bg --https=443 http://127.0.0.1:7681
sudo tailscale serve status
```

You get a URL like `https://vps1.<your-tailnet>.ts.net`. Open it from any device
signed into your tailnet, anywhere. Lock it down further with an ACL so only
your user/device can hit that port (Tailscale admin → Access controls), and
optionally `tailscale serve --bg --set-path /herdr`.

You can now delete the public SSH rule:

```bash
sudo ufw delete allow OpenSSH     # only if Tailscale SSH works for you
```

### 5c. Secure exposure — Option B: Cloudflare Tunnel + Access

Use this if you don't want a client on every device (browser-only) or need a
nicer public hostname. Auth is enforced by Cloudflare Access (email/SSO/MFA).

On `vps1`:

```bash
# install cloudflared per Cloudflare docs, then:
cloudflared tunnel login
cloudflared tunnel create vps1

mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml <<'EOF'
tunnel: vps1
credentials-file: /home/coder/.cloudflared/<TUNNEL-UUID>.json
ingress:
  - hostname: herdr.example.com
    service: http://127.0.0.1:7681
  - service: http_status:404
EOF

cloudflared tunnel route dns vps1 herdr.example.com
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Then in the Cloudflare dashboard → **Zero Trust → Access → Applications**:
add a self-hosted app for `herdr.example.com` with a policy that allows only
your email (with MFA/OTP). Without that policy the tunnel URL is public, so
**do not skip Access**.

> Quick-and-dirty test only (NO auth, do not leave running):
> `cloudflared tunnel --url http://127.0.0.1:7681` → random `trycloudflare.com` URL.

### 5d. Option C: Only if you must use plain port 443

Run Caddy/nginx with a real cert, add HTTP basic auth **and** an IP allowlist,
and keep ttyd itself on loopback. This is the weakest option; prefer Tailscale
or Cloudflare Access. If you expose a terminal to the internet with just a
password, assume it will be brute-forced.

---

## Phase 6 — Verify end to end

```bash
# on vps1
herdr status server              # server: running
systemctl --user status herdr    # active
systemctl status ttyd            # active
ss -ltnp | grep 7681             # must be 127.0.0.1:7681, never 0.0.0.0
sudo ufw status                  # no 7681 inbound

# from your laptop
herdr --remote vps1              # native path
# and open the Tailscale/Cloudflare URL in a browser for the web path
```

In a Herdr pane inside the browser: `cd ~/src/proj && pi`, then split panes
(`prefix+v`, `prefix+c`), detach/close, reopen later — the agent is still running.

---

## Security checklist

- [ ] SSH: key-only, no root login, ufw deny-by-default, fail2ban on.
- [ ] Agents run as a non-root user.
- [ ] ttyd binds `127.0.0.1` only; port is not in the firewall allowlist.
- [ ] Access path is Tailscale (tailnet ACL) **or** Cloudflare Access policy — never a bare public URL.
- [ ] TLS everywhere (Tailscale/Cloudflare provide it automatically).
- [ ] Optional defense-in-depth: `ttyd -c user:pass` and/or Basic Auth at the tunnel.
- [ ] Keep `herdr update` / `npm update -g` current; review API/socket exposure.
- [ ] Back up `~/.pi/agent` (credentials, sessions) and `~/.config/herdr`.

## Optional niceties

- Phone: the Tailscale URL works in mobile Safari/Chrome; add to home screen.
- Code on the go with a VS Code UI instead of Herdr: run `code-server` on the
  VPS on loopback and publish it through the same Tailscale/Cloudflare tunnel.
- Tamper-proof jump host: put `command="herdr --remote ..."` or a forced command
  in `authorized_keys` for a dedicated key.
- Install the Herdr skill so agents can drive Herdr themselves:
  `npx skills add herdrdev/herdr --skill herdr -g`
