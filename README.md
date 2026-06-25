# Digital Brands Dev Server Setup

Provisioning script for Digital Brands dev/prod servers (Ubuntu, tested on 24.04).
It installs the base toolchain + Docker, creates the login and service accounts,
and applies a hardened SSH/firewall baseline.

## Running it

SSH into a fresh server as a sudo-capable user (e.g. the cloud image's default
account), then:

```
git clone https://github.com/digital-brands/dev-server-setup.git
cd dev-server-setup
./server-setup.sh
```

The script is **interactive** and must be run from a real terminal (it refuses
to run under `curl | bash`). It prompts for:

- **Login username** — the human account you'll log in as.
- **Auth method** — `ssh-key` (paste a public key; password login is then
  disabled for a key-only box) or `password` (you'll set one).
- **mosh** — optional; if yes, it's installed and the firewall opens UDP
  60000–61000 for it.

Everything after the prompts runs unattended.

## What it does

- **Patches** the base system (`apt-get upgrade`, non-interactive).
- **Tools:** git, gh, htop, curl, vim, zsh, tmux, build-essential, npm, certbot
  (+ Cloudflare DNS plugin), direnv, ca-certificates, gnupg, ufw, fail2ban
  (and mosh if selected).
- **Removes** host packages that conflict with a Docker host: snapd, apache2,
  mysql-server.
- **Docker:** installs Docker CE + Compose v2 plugin from Docker's official apt
  repo, plus a `compose-switch` shim so legacy `docker-compose` calls forward to
  `docker compose`.
- **Accounts:**
  - Your **login user** — added to `sudo`, `www-data`, `db-admin`, `docker`;
    default shell set to zsh; SSH key installed (key method) or password set.
  - **`db-admin`** — a *locked* (`nologin`) service identity used only for file
    ownership under `/home/sites`. Not a login account.
  - Removes the cloud-init `ubuntu` account and its passwordless-sudo rule.
- **`/home/sites`** — created group-writable (`2775`, setgid) and owned by
  `db-admin` so new site dirs inherit the right group.
- **SSH hardening** (`/etc/ssh/sshd_config.d/01-hardening.conf`): no root login,
  password auth set per your choice, modern ciphers/MACs only, idle timeouts.
- **fail2ban** — bans brute-force SSH after 5 failed attempts, with escalating
  ban times (1m → 5m → 1h → 24h) so a fat-fingered password costs a minute while
  a persistent attacker climbs to a day. Recover from a self-lockout via the
  DigitalOcean web Console (out-of-band): `fail2ban-client set sshd unbanip <ip>`.
- **Firewall (UFW):** deny incoming by default; rate-limited 22/tcp (and mosh's
  UDP range if installed). No 443 rule — haproxy runs in Docker and publishes
  ports via iptables, bypassing UFW, so HTTPS filtering belongs in the
  `DOCKER-USER` chain or at Cloudflare, not UFW.

> Edit the script and re-run rather than hand-editing the files it manages. The
> script is idempotent — safe to re-run.

## After setup

### Verify

```
docker --version
docker compose version
docker-compose version   # compose-switch shim
gh --version
sudo ufw status
```

### Git authentication

`gh` is installed. Authenticate and let it configure git credentials:

```
gh auth login           # choose HTTPS; follow the prompts
gh auth setup-git       # configures git to use gh's credentials
```

This replaces the old `git-set-credentials.sh` / plaintext-PAT flow.
