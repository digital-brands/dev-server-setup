# Digital Brands Dev Server Setup

Provisioning script for Digital Brands dev/prod servers (Ubuntu, tested on 24.04).
It installs the base toolchain + Docker, creates the login and service accounts,
and applies a hardened SSH/firewall baseline.

## Running it

On a fresh DigitalOcean droplet, log in **as root** (DO's default) — *not* as
the `ubuntu` account; the script removes `ubuntu` mid-run and refuses to run as
it. git ships on the droplet and the repo is public, so just clone and run:

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
- **nvm** — optional (default yes); installs per-user node for your login account.
- **GitHub auth** — `gh` (installs the CLI; you run `gh auth login` yourself
  after first login), `token` (paste a Personal Access Token now — it's stored
  to `~/.git-credentials` at `chmod 600` and wired into git's credential helper),
  or `skip`. `gh` is only installed if you pick the `gh` path.

Everything after the prompts runs unattended.

> **Before you disconnect the root session**, open a second terminal and confirm
> you can log in as your new user (by key, or password). The script sets
> `PermitRootLogin no`, so once you log out of root that door is closed — don't
> close it until the new account is verified working.

## What it does

### Packages

- **Patches** the base system (`apt-get upgrade`, non-interactive).
- **Installs:** git, htop, curl, vim, zsh, tmux, build-essential, certbot
  (+ Cloudflare DNS plugin), direnv, ca-certificates, gnupg, ufw, fail2ban —
  plus mosh if selected, and `gh` if you chose the gh GitHub-auth path.
- **Removes** host packages that conflict with a Docker host: snapd, apache2,
  mysql-server.
- **Node** comes from nvm (per-user), if you opt in — not the apt `npm` package.

### Docker

- Installs Docker CE + the Compose v2 plugin from Docker's official apt repo.
- Adds a `compose-switch` shim so legacy `docker-compose` calls forward to
  `docker compose`.

### Accounts

- **Login user** — added to `sudo`, `www-data`, `db-admin`, `docker`; default
  shell set to zsh; SSH key installed (key method) or password set.
- **`db-admin`** — a *locked* (`nologin`) service identity used only for file
  ownership under `/home/sites`. Not a login account.
- **`ubuntu`** — the cloud-init account and its passwordless-sudo rule are
  removed.
- **`/home/sites`** — created group-writable (`2775`, setgid) and owned by
  `db-admin` so new site dirs inherit the right group.

### Security hardening

- **SSH** (`/etc/ssh/sshd_config.d/01-hardening.conf`) — no root login, password
  auth set per your choice, modern ciphers/MACs only, idle timeouts.
- **fail2ban** — bans brute-force SSH after 5 failed attempts, with escalating
  ban times (1m → 5m → 1h → 24h): a fat-fingered password costs a minute, a
  persistent attacker climbs to a day. Recover from a self-lockout via the
  DigitalOcean web Console (out-of-band):
  `fail2ban-client set sshd unbanip <ip>`.
- **Firewall (UFW)** — deny incoming by default; rate-limited 22/tcp (and mosh's
  UDP range if installed). No 443 rule: haproxy runs in Docker and publishes
  ports via iptables, bypassing UFW, so HTTPS filtering belongs in the
  `DOCKER-USER` chain or at Cloudflare, not UFW.

> Edit the script and re-run rather than hand-editing the files it manages. The
> script is idempotent — safe to re-run.

## Log in as your new user

Once you've confirmed the new account works (see the note above), **exit the root
session and log back in as your login user** — everything from here runs as that
user:

```
exit                              # leave root
ssh <your-user>@<server-ip>       # (or `mosh` if you enabled it)
```

This fresh login is also when the user's group memberships (`docker`, `db-admin`,
…) and the direnv shell hook take effect. Don't run the steps below as root.

## After setup

### Verify

```
docker --version
docker compose version
docker-compose version   # compose-switch shim
sudo ufw status
node --version           # if you installed nvm (open a fresh shell first)
gh --version             # if you chose the gh GitHub-auth path
```

### Git authentication

Depends on the GitHub-auth choice you made during setup:

- **gh** — `gh` is installed; finish the interactive login yourself:
  ```
  gh auth login           # choose HTTPS; follow the prompts
  gh auth setup-git       # configures git to use gh's credentials
  ```
- **token** — already done. Your token is stored in `~/.git-credentials`
  (`chmod 600`) and git's credential helper is set, so HTTPS clones/pushes work
  with no further steps. To rotate it, re-run the script or rewrite that file.
- **skip** — nothing was configured; set up either method above when you need it.

## Setting up a site

Each site is its own repository cloned under `/home/sites`. Because that
directory is group-writable and setgid for the `db-admin` group, clone as your
login user and ownership lands correctly. The general flow per site:

1. **Clone** the site repo into `/home/sites/<site>`.
2. **Environment** — set the site's required variables (its home directory,
   domain, production flag, and any service credentials it needs). Host-wide
   values go in `/etc/environment`; per-site values live in the repo's own env
   file, which `direnv` loads on `cd` (run `direnv allow` once per site).
3. **Node dependencies** — some tooling needs a host-side `npm install`. Run it
   in the cache-warmer dir (`warmer/`) and in the build toolchain dir under
   `volumes/phpfpm/` — note that dir is `gulp/` on most sites but `build/` on at
   least one, so check the repo for the actual `package.json` locations rather
   than assuming. (Node comes from nvm; open a fresh shell so it's on `PATH`.)
   The build toolchain also installs its own deps inside the container when the
   site starts — the host-side install covers tools that run on the host.
4. **Aliases** *(optional)* — if the site ships a shell-aliases file, symlink it
   into `/etc/profile.d/` so its shortcuts load globally. Re-login to pick it up.
   Skip if you don't want the shortcuts.
5. **Permissions** — run the site's permissions task to normalize ownership.
6. **TLS** — obtain certificates via the DNS challenge (the Cloudflare DNS plugin
   is installed), then run the site's cert-assembly task to produce the
   proxy-format certificate.
7. **Start** — bring the containers up and build assets with the site's own task
   scripts.

Steps 5–7 are driven by scripts inside each site repo (under its `tasks/`
directory); see that repo for the exact commands and the specific variables it
expects. Paths and per-site details vary — treat the steps above as the shape of
the process, not exact commands.

