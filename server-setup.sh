#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Terminal UI helpers. Pure bash + ANSI — no deps. Color/glyphs are enabled
# only on a real terminal and honour NO_COLOR; everything degrades to plain
# ASCII text otherwise so logs and the DO web Console stay readable.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
    C_ACCENT=$'\e[38;5;39m'   # calm cyan-blue
    C_OK=$'\e[38;5;42m'       # green
    C_WARN=$'\e[38;5;214m'    # amber
    C_ERR=$'\e[38;5;203m'     # red
    G_OK="✓"; G_ARROW="›"; G_WARN="!"; G_DOT="•"
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_ACCENT=""; C_OK=""; C_WARN=""; C_ERR=""
    G_OK="[ok]"; G_ARROW=">"; G_WARN="[!]"; G_DOT="-"
fi

# A titled rule introducing a phase.
section() { printf '\n%s%s── %s%s %s\n' "$C_ACCENT" "$C_BOLD" "$1" "$C_RESET" \
    "${C_ACCENT}$(printf '─%.0s' $(seq 1 $((48 - ${#1}))))${C_RESET}"; }
step()  { printf '  %s%s%s %s\n' "$C_ACCENT" "$G_ARROW" "$C_RESET" "$1"; }
ok()    { printf '  %s%s%s %s\n' "$C_OK" "$G_OK" "$C_RESET" "$1"; }
warn()  { printf '  %s%s %s%s\n' "$C_WARN" "$G_WARN" "$1" "$C_RESET"; }
die()   { printf '\n%s%s %s%s\n' "$C_ERR" "$G_WARN" "$1" "$C_RESET" >&2; exit 1; }

# ask "Prompt" [default] -> echoes the answer (default if blank).
ask() {
    local prompt="$1" default="${2:-}" reply hint=""
    [ -n "$default" ] && hint=" ${C_DIM}[$default]${C_RESET}"
    printf '  %s%s%s %s%s ' "$C_ACCENT" "$G_DOT" "$C_RESET" "$prompt" "$hint" >&2
    read -r reply
    printf '%s' "${reply:-$default}"
}

# ask_yn "Prompt" "y"|"n" (default) -> returns 0 for yes, 1 for no.
ask_yn() {
    local prompt="$1" default="${2:-n}" reply hint
    case "$default" in y|Y) hint="[Y/n]";; *) hint="[y/N]";; esac
    printf '  %s%s%s %s %s%s%s ' "$C_ACCENT" "$G_DOT" "$C_RESET" "$prompt" "$C_DIM" "$hint" "$C_RESET" >&2
    read -r reply; reply="${reply:-$default}"
    case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# menu "Prompt" opt1 opt2 ... -> echoes the chosen option string.
menu() {
    local prompt="$1"; shift
    local opts=("$@") i choice
    printf '  %s%s%s %s\n' "$C_ACCENT" "$G_DOT" "$C_RESET" "$prompt" >&2
    for i in "${!opts[@]}"; do
        printf '      %s%2d%s  %s\n' "$C_ACCENT" "$((i+1))" "$C_RESET" "${opts[$i]}" >&2
    done
    while true; do
        printf '    %sselect 1-%d:%s ' "$C_DIM" "${#opts[@]}" "$C_RESET" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#opts[@]}" ]; then
            printf '%s' "${opts[$((choice-1))]}"; return 0
        fi
        printf '    %senter a number 1-%d%s\n' "$C_WARN" "${#opts[@]}" "$C_RESET" >&2
    done
}

# db-admin is a locked service identity for file ownership under /home/sites
# (see usermod -s nologin below) — never a login.
SERVICE_USER='db-admin'
# Working groups for the human login account.
GROUPS=('sudo' 'www-data' 'db-admin' 'docker')

# This script is interactive (asks who the login user is and how they
# authenticate). Bail early if there's no terminal rather than misbehaving
# under `curl | bash`.
if [ ! -t 0 ]; then
    die "This script must be run interactively (needs a terminal — not 'curl | bash')."
fi

# Refuse to run as the cloud-init 'ubuntu' account: this script deletes that
# account (and pkills its processes) partway through, which would kill its own
# session mid-run. Run as root or another sudo-capable user instead.
if [ "$(id -un)" = "ubuntu" ]; then
    die "Don't run this as the 'ubuntu' user — the script removes that account mid-run and would kill its own session. Log in as root and re-run."
fi

# --- Welcome banner --------------------------------------------------------
printf '\n%s%s' "$C_ACCENT" "$C_BOLD"
cat <<'BANNER'
  ╶──────────────────────────────────────────────╴
     Digital Brands · Dev Server Setup
  ╶──────────────────────────────────────────────╴
BANNER
printf '%s' "$C_RESET"
printf '  %sProvisions Docker, accounts, and a hardened SSH/firewall baseline.%s\n' "$C_DIM" "$C_RESET"
printf '  %sA few questions first, then it runs unattended.%s\n' "$C_DIM" "$C_RESET"

# --- Collected up front; the rest runs unattended -------------------------
section "Account"
LOGIN_USER="$(ask 'Username for your login account:')"
if ! [[ "$LOGIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "Invalid username '$LOGIN_USER'."
fi

AUTH_METHOD="$(menu "How should $LOGIN_USER authenticate over SSH?" "ssh-key" "password")"

PUBKEY=""
if [ "$AUTH_METHOD" = "ssh-key" ]; then
    # Key-only: password auth gets disabled in sshd below. Capture the public
    # key now so we don't harden ourselves out of the box.
    PASSWORD_AUTH="no"
    step "Paste $LOGIN_USER's PUBLIC key (one line, e.g. 'ssh-ed25519 AAAA... comment'):"
    read -r PUBKEY
    [ -n "$PUBKEY" ] || die "No key provided — refusing to enable key-only auth (would lock you out)."
else
    PASSWORD_AUTH="yes"
fi

section "Options"
# mosh is optional: it's a roaming/latency-tolerant SSH alternative but needs a
# UDP port range opened in the firewall, so we only install it (and add the UFW
# rule below) if asked for.
if ask_yn "Install mosh (roaming SSH over UDP 60000-61000)?" n; then
    INSTALL_MOSH="yes"; else INSTALL_MOSH="no"; fi

# nvm is per-user node version management (installs into the login user's
# ~/.nvm and hooks their shell). We deliberately do NOT install the apt `npm`
# package — node is nvm-managed for the user to avoid version confusion. Decline
# only if you don't need node on this box at all.
if ask_yn "Install nvm (per-user node) for $LOGIN_USER?" y; then
    INSTALL_NVM="yes"; else INSTALL_NVM="no"; fi

section "GitHub access"
# GitHub authentication for the login user. Three supported paths:
#   gh    - install the gh CLI; you run `gh auth login` yourself after first
#           login (interactive browser/device flow, no token to paste here).
#   token - paste a Personal Access Token now; we store it via git's credential
#           helper (~/.git-credentials, chmod 600). No gh needed.
#   skip  - set nothing up; configure git auth later by hand.
# This is also what decides whether gh gets installed (see TOOLS below).
GIT_PAT=""
GIT_PAT_USER=""
GH_AUTH="$(menu "How should $LOGIN_USER authenticate to GitHub?" "gh" "token" "skip")"

if [ "$GH_AUTH" = "token" ]; then
    GIT_PAT_USER="$(ask 'GitHub username:')"
    # -s: don't echo the token to the terminal.
    printf '  %s%s%s GitHub Personal Access Token %s(hidden)%s: ' \
        "$C_ACCENT" "$G_DOT" "$C_RESET" "$C_DIM" "$C_RESET"
    read -rs GIT_PAT; echo
    if [ -z "$GIT_PAT_USER" ] || [ -z "$GIT_PAT" ]; then
        die "Username and token are both required for the token method."
    fi
fi

# --- Review before the unattended phase ------------------------------------
section "Review"
printf '  %s%-14s%s %s\n' "$C_DIM" "Login user" "$C_RESET" "$LOGIN_USER"
printf '  %s%-14s%s %s\n' "$C_DIM" "SSH auth" "$C_RESET" "$AUTH_METHOD"
printf '  %s%-14s%s %s\n' "$C_DIM" "mosh" "$C_RESET" "$INSTALL_MOSH"
printf '  %s%-14s%s %s\n' "$C_DIM" "nvm" "$C_RESET" "$INSTALL_NVM"
printf '  %s%-14s%s %s\n' "$C_DIM" "GitHub auth" "$C_RESET" "$GH_AUTH"
echo
ask_yn "Proceed with these settings?" y || die "Aborted — re-run to start over."

TOOLS=(
    'git' 'htop' 'curl' 'vim' 'zsh' 'tmux' 'build-essential' 'certbot' 'direnv'
    'python3-certbot-dns-cloudflare'
    'ca-certificates' 'gnupg' 'ufw' 'fail2ban'
)
[ "$INSTALL_MOSH" = "yes" ] && TOOLS+=('mosh')
# gh is only needed for the interactive `gh auth login` path.
[ "$GH_AUTH" = "gh" ] && TOOLS+=('gh')

# Detect Ubuntu codename
UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
UBUNTU_VERSION=$(. /etc/os-release && echo "$VERSION_ID")

section "Packages"
ok "Detected Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"

# Patch the base system, then install our tools. DEBIAN_FRONTEND=noninteractive
# keeps the upgrade from prompting (service restarts, conf-file diffs) and
# stalling the otherwise-unattended part of this run.
step "Updating and patching the base system…"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
step "Installing ${#TOOLS[@]} packages…"
sudo apt-get install -y "${TOOLS[@]}"

# Remove host packages that conflict with / are unwanted on a Docker host:
# apache2 & mysql-server would fight for ports 80/443/3306 (no-ops on a clean
# droplet); snapd is auto-updating bloat we don't need. Guarded with || true so
# "not installed" doesn't trip set -e.
for pkg in snapd apache2 mysql-server; do
    sudo systemctl disable --now "$pkg" 2>/dev/null || true
    sudo apt-get remove --purge -y "$pkg" 2>/dev/null || true
done
sudo apt-get autoremove --purge -y 2>/dev/null || true

section "Docker"
# Remove any conflicting Docker packages (safe no-op if not installed)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

# Set up Docker's official apt repository
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Determine which codename Docker's repo has packages for.
REPO_CODENAME="$UBUNTU_CODENAME"
DOCKER_REPO_CHECK="https://download.docker.com/linux/ubuntu/dists/$UBUNTU_CODENAME/stable/"
if ! curl -fsSL --head "$DOCKER_REPO_CHECK" >/dev/null 2>&1; then
    echo "Docker repo has no packages for '$UBUNTU_CODENAME' yet; falling back to 'noble'."
    REPO_CODENAME="noble"
fi

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $REPO_CODENAME stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Install compose-switch so legacy `docker-compose` calls forward to
# `docker compose` (v2). The project's task scripts still invoke the
# hyphenated form.
sudo curl -fL \
    https://github.com/docker/compose-switch/releases/latest/download/docker-compose-linux-amd64 \
    -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

section "Accounts"
# Create groups (skip if they exist)
for group in "${GROUPS[@]}"; do
    getent group "$group" >/dev/null || sudo groupadd "$group"
done

# Create the db-admin service account (file ownership under /home/sites; shell
# locked below). Only needs its own group plus www-data — no sudo/docker.
if ! id "$SERVICE_USER" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$SERVICE_USER"
fi
sudo usermod -aG www-data,db-admin "$SERVICE_USER"

# Create the login user and add it to the working groups.
if ! id "$LOGIN_USER" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$LOGIN_USER"
fi
for group in "${GROUPS[@]}"; do
    sudo usermod -aG "$group" "$LOGIN_USER"
done

# Remove the cloud-init-provisioned `ubuntu` account. It ships with a
# NOPASSWD:ALL sudoers rule via /etc/sudoers.d/90-cloud-init-users, and
# droplet-agent will drop DO Console SSH keys into any user's
# authorized_keys — leaving it enabled is a latent passwordless-root
# escalation. Cloud-init runs once per-instance on DO so this won't be
# re-provisioned. Idempotent: skipped on re-runs once the account is gone.
if id ubuntu &>/dev/null; then
    sudo pkill -KILL -u ubuntu 2>/dev/null || true
    sudo deluser --remove-home ubuntu
fi
sudo rm -f /etc/sudoers.d/90-cloud-init-users

# Default the login user to zsh.
sudo chsh -s "$(command -v zsh)" "$LOGIN_USER"

# Hook direnv into the login user's shells so each site's .envrc loads on `cd`
# (the per-site secrets/config live there). Idempotent — only appends if absent.
# Covers zsh (the default above) and bash (fallback / non-login shells).
for rc in .zshrc .bashrc; do
    rc_path="/home/$LOGIN_USER/$rc"
    shell="${rc#.}"; shell="${shell%rc}"   # .zshrc -> zsh, .bashrc -> bash
    hook="eval \"\$(direnv hook $shell)\""
    sudo touch "$rc_path"
    if ! sudo grep -qF "direnv hook $shell" "$rc_path"; then
        printf '\n# direnv: load per-directory .envrc files\n%s\n' "$hook" \
            | sudo tee -a "$rc_path" >/dev/null
    fi
    sudo chown "$LOGIN_USER:$LOGIN_USER" "$rc_path"
done

# Install nvm for the login user, if requested. nvm is per-user: its installer
# drops ~/.nvm and appends its shell hook to the user's rc files. Run the whole
# thing AS the login user (sudo -iu) so paths/ownership land in their home, not
# root's. Idempotent: the installer is a no-op re-run, and we only set a default
# node if none is active yet.
if [ "$INSTALL_NVM" = "yes" ]; then
    # Bump periodically: https://github.com/nvm-sh/nvm/releases
    NVM_VERSION="v0.40.5"
    # Run as the login user. The body is single-quoted so the OUTER shell leaves
    # it untouched; NVM_VERSION is passed in as an env var the inner shell reads.
    # PROFILE points the installer at .bashrc so it appends its hook there.
    sudo -iu "$LOGIN_USER" NVM_VERSION="$NVM_VERSION" bash -c '
        export PROFILE="$HOME/.bashrc"
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
        export NVM_DIR="$HOME/.nvm"
        . "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm alias default "lts/*"
    '
    # nvm's installer only hooks .bashrc by default; make sure zsh (our default
    # shell) loads it too. Idempotent.
    zrc="/home/$LOGIN_USER/.zshrc"
    if ! sudo grep -qF 'NVM_DIR' "$zrc" 2>/dev/null; then
        sudo tee -a "$zrc" >/dev/null <<'EOF'

# nvm: per-user node version management
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
EOF
        sudo chown "$LOGIN_USER:$LOGIN_USER" "$zrc"
    fi
fi

# Store the GitHub token for the login user, if the token method was chosen.
# Mirrors the old git-set-credentials.sh but fixed: writes to the LOGIN user's
# home, 0600, owned by them, and points git's `store` helper at the file. The
# token is written via a heredoc into a root-run tee so it never lands in the
# process list. Idempotent: the helper config and credentials file are rewritten
# cleanly each run.
if [ "$GH_AUTH" = "token" ]; then
    cred_file="/home/$LOGIN_USER/.git-credentials"
    # URL-form credential line consumed by git's store helper.
    printf 'https://%s:%s@github.com\n' "$GIT_PAT_USER" "$GIT_PAT" \
        | sudo tee "$cred_file" >/dev/null
    sudo chmod 600 "$cred_file"
    sudo chown "$LOGIN_USER:$LOGIN_USER" "$cred_file"
    # Configure git (as the login user) to use the on-disk credential store.
    sudo -u "$LOGIN_USER" git config --global credential.helper store
fi

# Lock the db-admin shell so the service account can't be used for an
# interactive session (even if a password ever gets set).
sudo usermod -s /usr/sbin/nologin "$SERVICE_USER"

# Set up /home/sites: writable by the db-admin group, with setgid so new
# subdirectories inherit db-admin group ownership.
sudo install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 2775 /home/sites

# Provision the login user's ~/.ssh. For the key method, install the pasted
# public key (idempotent — won't duplicate on re-run). 700/600 perms either way
# (sshd tolerates looser, but this is the convention).
sudo install -d -o "$LOGIN_USER" -g "$LOGIN_USER" -m 700 "/home/$LOGIN_USER/.ssh"
if [ "$AUTH_METHOD" = "ssh-key" ]; then
    if ! sudo grep -qsF "$PUBKEY" "/home/$LOGIN_USER/.ssh/authorized_keys"; then
        printf '%s\n' "$PUBKEY" | sudo tee -a "/home/$LOGIN_USER/.ssh/authorized_keys" >/dev/null
    fi
fi
if [ -f "/home/$LOGIN_USER/.ssh/authorized_keys" ]; then
    sudo chmod 600 "/home/$LOGIN_USER/.ssh/authorized_keys"
    sudo chown "$LOGIN_USER:$LOGIN_USER" "/home/$LOGIN_USER/.ssh/authorized_keys"
fi

# For the password method, set the login user's password now. Retry loop so a
# mistyped confirmation doesn't abort the whole run under `set -e`.
if [ "$AUTH_METHOD" = "password" ]; then
    echo "Set a password for $LOGIN_USER:"
    until sudo passwd "$LOGIN_USER"; do
        echo "Let's try that again."
    done
fi

section "Hardening"
# SSH hardening drop-in. Named 01- so it loads before any other drop-in
# (50-cloud-init, etc.) — sshd takes the FIRST value it sees per directive,
# so loading hardening first means later files can't relax it.
# PasswordAuthentication is interpolated from the auth method chosen at the
# start of this run (yes = password login, no = key-only). Pubkey auth stays
# on via sshd's default regardless.
sudo tee /etc/ssh/sshd_config.d/01-hardening.conf > /dev/null <<EOF
# Managed by dev-server-setup-2026.sh — edit the script, re-run, don't hand-edit.

# Authentication
PermitRootLogin no
# Set explicitly (not omitted): cloud-init's 50- drop-in ships
# PasswordAuthentication no, and since this 01- file loads first and sshd
# honours the first value seen, the value here wins.
PasswordAuthentication $PASSWORD_AUTH
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Connection behaviour
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 24   # 300s * 24 = 2h idle before disconnect
LoginGraceTime 30

# Modern crypto only
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
# ETM variants preferred; non-ETM SHA-2 kept as fallback because the
# DigitalOcean web Console's SSH client doesn't negotiate ETM MACs.
# (Moot with AEAD ciphers above, but required for KEX to succeed.)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
EOF
sudo sshd -t
sudo systemctl reload ssh

# fail2ban: ban brute-force SSH attempts. backend=systemd reads journald
# (no /var/log/auth.log on 24.04). banaction=ufw drops via UFW so bans
# stack with our existing firewall policy instead of iptables-direct.
#
# Escalating ban times balance "don't lock ourselves out over a fat-fingered
# password" against "punish a persistent attacker". Multipliers are relative to
# bantime (the base, 1m here):
#   ban#1 = 1m*1   = 1 minute   (a quick fumble barely costs anything)
#   ban#2 = 1m*5   = 5 minutes
#   ban#3 = 1m*60  = 1 hour
#   ban#4+ = 1m*1440 = 24 hours (capped by maxtime)
# maxretry=5 gives human fingers some headroom before the first ban. Recovery if
# we ever do lock ourselves out: the DigitalOcean web Console is out-of-band
# (not over SSH), or `fail2ban-client set sshd unbanip <ip>` from there.
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
backend             = systemd
banaction           = ufw
maxretry            = 5
findtime            = 10m
bantime             = 1m
bantime.increment   = true
bantime.multipliers = 1 5 60 1440
bantime.maxtime     = 24h

[sshd]
enabled = true
EOF
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

# Firewall: UFW only governs *host* services. There is deliberately no rule for
# 443 — haproxy runs in Docker, which publishes ports by inserting rules into the
# iptables DOCKER/FORWARD chains that are evaluated before UFW's input chain. A
# `ufw allow 443` would therefore be cosmetic (it gates nothing), and a `deny`
# wouldn't actually block container traffic either. Real source-IP filtering for
# 443 (e.g. Cloudflare-only) belongs in the DOCKER-USER chain or upstream at
# Cloudflare — not here. So UFW protects exactly the host listeners: SSH (and
# mosh if installed).
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 22/tcp comment 'ssh: rate-limited + fail2ban-guarded'
# mosh uses a UDP port range for its session; only opened if mosh was installed.
[ "$INSTALL_MOSH" = "yes" ] && sudo ufw allow 60000:61000/udp comment 'mosh'
sudo ufw --force enable

section "Done"
ok "Provisioned on Ubuntu $UBUNTU_VERSION."
printf '  %sVerify with:%s\n' "$C_DIM" "$C_RESET"
printf '    docker --version\n'
printf '    docker compose version\n'
printf '    docker-compose version   %s# compose-switch shim%s\n' "$C_DIM" "$C_RESET"
printf '    sudo ufw status\n'

# Point the user at the next step for their chosen GitHub auth method.
case "$GH_AUTH" in
    gh)    step "GitHub: run 'gh auth login' (then 'gh auth setup-git') after you log in as $LOGIN_USER." ;;
    token) ok   "GitHub: token stored for $LOGIN_USER — HTTPS clones will just work." ;;
    skip)  warn "GitHub: no auth configured — set it up later with gh or a token." ;;
esac

# Reminder: don't burn the bridge until the new login is verified.
warn "Before you disconnect root: confirm '$LOGIN_USER' can log in (new terminal). Root login is now disabled."
