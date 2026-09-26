#!/usr/bin/env bash
#
# setup.sh — turn a fresh Ubuntu/Debian VPS into a persistent remote coding box:
#   Herdr (persistent TUI server) + pi coding agent + optional ttyd web front-end,
#   with SSH/firewall/fail2ban hardening.
#
# Run this ON the VPS as the user that will own the work (never as root):
#
#   ./setup.sh all          # harden + install + services + ttyd + verify
#   ./setup.sh harden       # SSH, ufw, fail2ban, unattended-upgrades, sysctl
#   ./setup.sh install      # herdr, node, pi, ttyd
#   ./setup.sh services     # herdr user service + linger
#   ./setup.sh ttyd         # loopback-only ttyd service
#   ./setup.sh cloudflared  # install Cloudflare Tunnel connector for ttyd
#   ./setup.sh verify       # checks
#
# Configuration (env vars):
#   TARGET_USER        user that owns everything        (default: current user)
#   TTYD_PORT          loopback port for ttyd           (default: 7681)
#   SSH_ALLOW_USERS    sshd AllowUsers list             (default: TARGET_USER)
#   TTYD_CREDENTIAL    optional HTTP basic auth u:p     (default: none)
#   NODE_MAJOR         Node.js major to install         (default: 22)
#   ALLOW_OPENSSH      1 = keep public SSH open in ufw  (default: 1)
#   TUNNEL_HOSTNAME    public hostname served by tunnel (default: herdr.example.com)
#   TUNNEL_TOKEN       dashboard-managed tunnel token  (optional)
#   TUNNEL_CONFIG      locally-managed config.yml path  (default: ~/.cloudflared/config.yml)
#
# It is safe to re-run: every step is idempotent.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

TARGET_USER="${TARGET_USER:-$(id -un)}"
TTYD_PORT="${TTYD_PORT:-7681}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-$TARGET_USER}"
TTYD_CREDENTIAL="${TTYD_CREDENTIAL:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
ALLOW_OPENSSH="${ALLOW_OPENSSH:-1}"
TUNNEL_HOSTNAME="${TUNNEL_HOSTNAME:-herdr.example.com}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_CONFIG="${TUNNEL_CONFIG:-$HOME/.cloudflared/config.yml}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_non_root() {
  [ "$(id -u)" -ne 0 ] || die "Do not run this as root. Run as '$TARGET_USER' (a normal user with sudo)."
}

require_sudo() {
  sudo -n true 2>/dev/null || die "Passwordless sudo is required (or run interactively and authenticate first)."
}

apt_install() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Phase 1 — hardening
# ---------------------------------------------------------------------------
phase_harden() {
  log "Hardening: packages"
  sudo apt-get update -qq
  apt_install ufw fail2ban unattended-upgrades ca-certificates

  log "Hardening: sshd drop-in (root login off, key-only, AllowUsers=$SSH_ALLOW_USERS)"
  local tmp
  tmp="$(mktemp)"
  sed "s|^AllowUsers .*|AllowUsers ${SSH_ALLOW_USERS}|" \
    "$FILES_DIR/sshd/99-hardening.conf" > "$tmp"
  sudo install -m 0644 -o root -g root "$tmp" /etc/ssh/sshd_config.d/99-hardening.conf
  rm -f "$tmp"
  sudo sshd -t || die "sshd config is invalid; not reloading. Check /etc/ssh/sshd_config.d/99-hardening.conf"
  sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
  log "  effective: $(sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|allowusers|maxauthtries) ' | tr '\n' ' ')"

  log "Hardening: ufw (default deny inbound)"
  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null
  if [ "$ALLOW_OPENSSH" = "1" ]; then
    sudo ufw allow OpenSSH >/dev/null
  else
    warn "ALLOW_OPENSSH=0 — make sure you have another way in (e.g. provider console) before disconnecting!"
  fi
  sudo ufw --force enable >/dev/null

  log "Hardening: fail2ban"
  sudo install -m 0644 "$FILES_DIR/fail2ban/jail.local" /etc/fail2ban/jail.local
  sudo systemctl enable fail2ban >/dev/null 2>&1 || true
  sudo systemctl restart fail2ban

  log "Hardening: unattended security upgrades"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

  log "Hardening: network sysctl"
  sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
# Basic network hardening (safe defaults)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
EOF
  sudo sysctl --system >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Phase 2 — install tools
# ---------------------------------------------------------------------------
node_major_installed() {
  command -v node >/dev/null 2>&1 || return 1
  local v
  v="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$v" -ge "$NODE_MAJOR" ]
}

phase_install() {
  log "Installing base packages (curl, git, jq, ttyd)"
  apt_install curl git jq ttyd

  if command -v herdr >/dev/null 2>&1 || [ -x "$HOME/.local/bin/herdr" ]; then
    log "herdr already installed: $("$HOME/.local/bin/herdr" --version 2>/dev/null || true)"
  else
    log "Installing herdr"
    curl -fsSL https://herdr.dev/install.sh | sh
  fi
  # make PATH permanent
  grep -qs '.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  export PATH="$HOME/.local/bin:$PATH"
  herdr --version || die "herdr did not install correctly"

  if node_major_installed; then
    log "Node $(node -v) already present"
  else
    log "Installing Node.js ${NODE_MAJOR}.x (pi needs >= 22.19)"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    apt_install nodejs
  fi
  node -v

  log "Installing pi coding agent (global)"
  if command -v pi >/dev/null 2>&1 && pi --version >/dev/null 2>&1; then
    log "pi already installed: $(pi --version 2>/dev/null)"
  fi
  # --ignore-scripts: the published bundle needs no lifecycle scripts.
  sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent

  log "Installed:"
  printf '  herdr %s\n  pi    %s\n  ttyd  %s\n' \
    "$(herdr --version 2>/dev/null || echo '?')" \
    "$(pi --version 2>/dev/null || echo '?')" \
    "$(ttyd --version 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# Phase 3 — herdr user service
# ---------------------------------------------------------------------------
phase_services() {
  log "Installing herdr user service"
  mkdir -p "$HOME/.config/systemd/user"
  install -m 0644 "$FILES_DIR/systemd/herdr.service" "$HOME/.config/systemd/user/herdr.service"
  systemctl --user daemon-reload
  systemctl --user enable --now herdr
  sudo loginctl enable-linger "$TARGET_USER"
  sleep 1
  systemctl --user --no-pager --lines=0 status herdr || true
  herdr status server || warn "herdr server not reporting yet; check: systemctl --user status herdr"
}

# ---------------------------------------------------------------------------
# Phase 4 — ttyd (loopback only)
# ---------------------------------------------------------------------------
phase_ttyd() {
  command -v ttyd >/dev/null 2>&1 || die "ttyd is not installed (run: ./setup.sh install)"
  log "Installing ttyd service on 127.0.0.1:${TTYD_PORT}"
  local herdr_bin ttyd_bin cred tmp
  herdr_bin="${HOME}/.local/bin/herdr"
  ttyd_bin="$(command -v ttyd)"
  [ -x "$herdr_bin" ] || die "herdr binary not found at $herdr_bin"
  cred=""
  [ -n "$TTYD_CREDENTIAL" ] && cred=" -c ${TTYD_CREDENTIAL}"

  tmp="$(mktemp)"
  sed -e "s|@@USER@@|${TARGET_USER}|g" \
      -e "s|@@HOME@@|${HOME}|g" \
      -e "s|@@TTYD_BIN@@|${ttyd_bin}|g" \
      -e "s|@@HERDR_BIN@@|${herdr_bin}|g" \
      -e "s|@@PORT@@|${TTYD_PORT}|g" \
      -e "s|@@CRED@@|${cred}|g" \
      "$FILES_DIR/systemd/ttyd.service.tmpl" > "$tmp"
  sudo install -m 0644 "$tmp" /etc/systemd/system/ttyd.service
  rm -f "$tmp"

  sudo systemctl daemon-reload
  sudo systemctl enable --now ttyd
  sudo systemctl restart ttyd
  sudo systemctl --no-pager --lines=0 status ttyd || true
}

# ---------------------------------------------------------------------------
# Phase 5 — Cloudflare Tunnel (public HTTPS front door for ttyd)
# ---------------------------------------------------------------------------
phase_cloudflared() {
  local origin="http://127.0.0.1:${TTYD_PORT}"
  local bin execstart user_line env_line tmp

  if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing cloudflared"
    local deb="/tmp/cloudflared-linux-amd64.deb"
    curl -fsSL -o "$deb" \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo apt-get install -y "$deb"
    rm -f "$deb"
  else
    log "cloudflared already installed: $(cloudflared --version)"
  fi
  bin="$(command -v cloudflared)"

  tmp="$(mktemp)"
  if [ -n "$TUNNEL_TOKEN" ]; then
    log "Configuring dashboard-managed tunnel (token)"
    sudo install -d -m 0755 /etc/cloudflared
    printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" | sudo tee /etc/cloudflared/token.env >/dev/null
    sudo chmod 0600 /etc/cloudflared/token.env
    user_line=""
    env_line="EnvironmentFile=/etc/cloudflared/token.env"
    execstart="${bin} tunnel --no-autoupdate run"
  elif [ -f "$TUNNEL_CONFIG" ]; then
    log "Configuring locally-managed tunnel from ${TUNNEL_CONFIG}"
    user_line="User=${TARGET_USER}"
    env_line=""
    execstart="${bin} tunnel --no-autoupdate --config ${TUNNEL_CONFIG} run"
  else
    warn "cloudflared installed, but no tunnel is configured yet."
    cloudflared_instructions "$origin"
    rm -f "$tmp"
    return 0
  fi

  sed -e "s|@@USER_LINE@@|${user_line}|g" \
      -e "s|@@ENV_LINE@@|${env_line}|g" \
      -e "s|@@EXECSTART@@|${execstart}|g" \
      "$FILES_DIR/systemd/cloudflared.service.tmpl" > "$tmp"
  sudo install -m 0644 "$tmp" /etc/systemd/system/cloudflared.service
  rm -f "$tmp"

  sudo systemctl daemon-reload
  sudo systemctl enable --now cloudflared >/dev/null 2>&1 || true
  sudo systemctl restart cloudflared
  sudo systemctl --no-pager --lines=0 status cloudflared || true

  cloudflared_instructions "$origin"
}

cloudflared_instructions() {
  local origin="$1"
  cat <<EOF

  >>> Point your Cloudflare Tunnel at the ttyd origin (loopback only):

        hostname : ${TUNNEL_HOSTNAME}
        service  : ${origin}

      Dashboard-managed tunnel:
        Zero Trust -> Networks -> Tunnels -> your tunnel -> Public Hostname
        add  ${TUNNEL_HOSTNAME}  ->  Type HTTP  ->  URL  ${origin}
        then copy the connector token and run on this host:
          TUNNEL_TOKEN=<token> ./setup.sh cloudflared

      Locally-managed tunnel:
        cp files/cloudflared/config.yml.example ~/.cloudflared/config.yml
        cloudflared tunnel login
        cloudflared tunnel create vps1
        cloudflared tunnel route dns vps1 ${TUNNEL_HOSTNAME}
        ./setup.sh cloudflared        # installs/refreshes the service

      SECURITY: ${TUNNEL_HOSTNAME} reaches a full shell. Add a
      Zero Trust -> Access -> Applications policy for it (email/SSO + MFA)
      BEFORE sharing the URL, and/or set TTYD_CREDENTIAL=user:pass.
EOF
}

# ---------------------------------------------------------------------------
# Phase 6 — verify
# ---------------------------------------------------------------------------
phase_verify() {
  log "Verification"
  echo "--- herdr ---"
  herdr status server 2>&1 || true
  systemctl --user --no-pager --lines=0 status herdr 2>&1 | head -5 || true
  echo "--- ttyd ---"
  systemctl --no-pager --lines=0 status ttyd 2>&1 | head -5 || true
  echo "--- listeners (${TTYD_PORT} must be 127.0.0.1 only) ---"
  ss -ltnp 2>/dev/null | grep -E ":${TTYD_PORT}\b" || echo "  (nothing on ${TTYD_PORT})"
  echo "--- cloudflared ---"
  if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared\.service'; then
    systemctl --no-pager --lines=0 status cloudflared 2>&1 | head -5 || true
  else
    echo "  cloudflared service not installed (run: ./setup.sh cloudflared)"
  fi
  echo "--- ufw ---"
  sudo ufw status verbose | sed 's/^/  /'
  echo "--- sshd ---"
  sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries) ' | sed 's/^/  /'
  echo
  log "Done. Native: from your laptop run  herdr machine add --label $(hostname -s) ${TARGET_USER}@$(hostname -s)  then  herdr --remote $(hostname -s)"
  log "Web: Cloudflare Tunnel -> ${TUNNEL_HOSTNAME} -> http://127.0.0.1:${TTYD_PORT} (loopback only). Protect it with Cloudflare Access."
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  require_non_root
  case "${1:-all}" in
    harden)    require_sudo; phase_harden ;;
    install)   require_sudo; phase_install ;;
    services)  require_sudo; phase_services ;;
    ttyd)      require_sudo; phase_ttyd ;;
    cloudflared) require_sudo; phase_cloudflared ;;
    verify)    require_sudo; phase_verify ;;
    all)       require_sudo; phase_harden; phase_install; phase_services; phase_ttyd; phase_cloudflared; phase_verify ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $1 (try: harden|install|services|ttyd|cloudflared|verify|all)" ;;
  esac
}

main "$@"
