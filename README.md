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
chmod +x server-setup.sh
./server-setup.sh
```

The script is **interactive** and must be run from a real terminal (it refuses
to run under `curl | bash`). It prompts for:

- **Login username** — the human account you'll log in as.
- **Auth method** — `ssh-key` (paste a public key; password login is then
  disabled for a key-only box) or `password` (you'll set one).
- **mosh** — optional; if yes, it's installed and the firewall opens UDP
  60000–61000 for it.
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
- **Node** is not installed by this script. Install it per-user with nvm (or
  your tool of choice) after first login — the cache warmer needs it on the
  host (see "Setting up a site").

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
login user and ownership lands correctly. The sections below cover the granular,
not-obvious parts — DNS, TLS, the database load, and the cache warmer.

> Examples use a placeholder site `<site>` and a placeholder dev hostname
> `<dev-host>`. The per-site environment file (`.envrc`) holds real credentials
> (API keys, basic-auth) — **never commit a populated `.envrc`**; the repo
> tracks only a template. Substitute your own values; nothing secret belongs in
> this README.

### Environment

Set the site's variables before running any task. Host-wide values
(`IS_PRODUCTION`, the site's home dir, `DOMAIN_DEV`, …) live in `/etc/environment`; 

Example `/etc/environment`:
```
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
BC_HOME_DIR="/home/sites/badcredit"
CR_HOME_DIR="/home/sites/cardrates"
DA_HOME_DIR="/home/sites/datingadvice"
DN_HOME_DIR="/home/sites/datingnews"
DB_HOME_DIR="/home/sites/digitalbrands"
HA_HOME_DIR="/home/sites/hostingadvice"

DOMAIN_DEV="dev.passprotect.me"
DOMAIN_PRODUCTION="dev.passprotect.me"
IS_PRODUCTION=false
```

per-site values live in the repo's own `.envrc`, which `direnv` loads on `cd`:

```
cd /home/sites/<site>
direnv allow          # once per site; reloads .envrc on every cd thereafter
```

Key variables the tasks below read: `HA_HOME_DIR` (the site's checkout path),
`IS_PRODUCTION` (false on a dev box — this gates the dev vs prod code paths),
and `DOMAIN_DEV` (the dev hostname the cert is issued for).

### 1. DNS

Each dev site answers on a dev hostname, and its TLS cert is issued via a
**DNS-01 challenge through Cloudflare**, so the domain must be a Cloudflare zone.

1. In Cloudflare, create an **A record** for the dev hostname pointing at the
   droplet's public IP.
2. Proxy status:
   - **DNS-only (grey cloud)** is simplest for a dev box — haproxy terminates TLS
     directly with the Let's Encrypt cert.
   - If you proxy through Cloudflare (orange cloud), set SSL/TLS mode to **Full
     (strict)** so the edge trusts the origin's Let's Encrypt cert.

DNS-01 doesn't need the A record to resolve before issuing (the challenge is a
TXT record certbot writes via the API), but you want it in place to reach the
site afterward.

### 2. Cloudflare credentials for certbot

The DNS-01 challenge proves you control the domain by writing a TXT record into
the Cloudflare zone, so certbot's `dns-cloudflare` plugin needs API credentials.
It reads them from **`/root/cloudflare.ini`**.

You don't normally hand-create that file — `tasks/cert-issue.sh` (step 3)
generates it (mode `600`, root-owned) on first run from two variables in the
site's `.envrc`:

```ini
# .envrc (already present for an existing site; set these if provisioning fresh)
export CLOUDFLARE_AUTH_EMAIL='...'    # Cloudflare account email
export CLOUDFLARE_AUTH_KEY='...'      # Cloudflare API key
```

So the only prep here is making sure those are set and `direnv allow`'d. Because
certbot runs as root and reads the env to build the file, **issue/renew with
`sudo -E`** so direnv's vars survive into sudo (the task scripts assume this).

> `/root/cloudflare.ini` is **not** in the repo and isn't provisioned by
> `server-setup.sh` — it's derived from `.envrc`. On a rebuilt box it's
> regenerated the next time `cert-issue.sh` runs.
>
> The variables above are the Cloudflare **global API key**, which the plugin
> accepts but which has broad account access. To tighten it, replace the `.ini`
> with a single `dns_cloudflare_api_token = ...` line scoped to **Zone:DNS:Edit**
> on just this zone.

### 3. TLS certificate

The cert is issued **once** with `tasks/cert-issue.sh`; renewals are automatic
thereafter (cron, below). Issuance uses DNS-01, so it works whether or not the
hostname is proxied and without port 80 — the A record doesn't even have to
resolve yet.

```
cd /home/sites/<site>
sudo -E ./tasks/cert-issue.sh                       # issues for $DOMAIN_DEV
```

The script obtains the cert via `certbot certonly --dns-cloudflare`, then calls
`tasks/cert-combine.sh`, which concatenates the Let's Encrypt `fullchain.pem` +
`privkey.pem` into the `volumes/haproxy/certs/development.pem` that haproxy
serves in step 6 (on dev it also writes the BrowserSync certs).

**Issuing before DNS is switched.** If the real dev hostname still points
elsewhere and you want to test on this box first, pass extra hostnames — they're
added to the cert as SANs while the primary name stays `$DOMAIN_DEV` (so the
Let's Encrypt lineage dir matches what `cert-combine.sh` expects):

```
sudo -E ./tasks/cert-issue.sh <temp-host-pointing-here>
```

The one cert then covers both names: test on the temp host now, flip the real
A record when ready — no re-issue needed.

**Renewal is hands-off.** `tasks/cert-renew.sh` runs `certbot renew` (a no-op
until within 30 days of expiry) and is cron'd monthly. A certbot `--deploy-hook`
re-runs `cert-combine.sh` and restarts haproxy **only when a cert actually
renews**, so there's no downtime on the months nothing is due. To validate the
whole pipeline against Let's Encrypt staging without touching rate limits:

```
sudo certbot renew --dry-run
```

> First issuance writes `development.pem` as `root` (certbot runs as root).
> That's expected — `cert-combine.sh` writes it via `sudo cp` so later renewals
> overwrite it regardless of owner, and haproxy reads it through the bind mount.

### 4. Database load (monsoon)

"monsoon" pulls the **latest DB dump from S3** and loads it into the dockerized
MySQL. The wrapper is `tasks/database-monsoon.sh`; the work is in
`volumes/database/scripts/monsoon/monsoon.sh`. It **refuses to run when
`IS_PRODUCTION=true`** (won't clobber a live DB) unless you pass `--force`; on a
dev box it just runs.

monsoon caches its answers in
`volumes/database/scripts/monsoon/monsoon.cfg`. If absent, it offers to create
one and prompts for each value, writing them back so later runs are
non-interactive:

```ini
# monsoon.cfg
username='root'                 # MySQL user inside the db container
siteurl='https://<dev-host>'    # written to wp_options home + siteurl
database='<db-name>'            # target schema
bucketname='<s3-bucket>'        # bucket holding the .sql.gz dumps
```

The **MySQL password is never stored** — monsoon always prompts for it.

The DB container must be up first (monsoon execs into it), so start the stack
(step 6) then:

```
cd /home/sites/<site>
./tasks/database-monsoon.sh
```

It finds the newest object in the bucket, `aws s3 cp`s it into the container,
`zcat | mysql` restores it, rewrites `wp_options.home`/`siteurl` to the dev URL
so WordPress doesn't bounce you to production, and creates a read-only MySQL
user for the Claude Code MCP. The AWS CLI runs **inside the database container**,
so its credentials come from the container's env — not your host `~/.aws`.

### 5. Cache warmer

The warmer is a standalone Node app (its own git repo) checked out at the site's
`warmer/` directory; it crawls the site's sitemaps to prime Varnish/Cloudflare
caches. `tasks/warmer-run.sh` builds sitemaps, purges Varnish, runs it, then
purges Cloudflare's HTML cache.

First-time setup — populate its `node_modules` on the host:

```
cd /home/sites/<site>/warmer
npm install
```

If `warmer/` is empty (a checkout that didn't pull it), clone the warmer repo
into it first, then `npm install`. Node isn't installed by the setup script —
install it (nvm is the convention) and open a fresh shell so `npm` is on `PATH`.
(The vendored `warmer/node` binary is what `warmer-run.sh` invokes at runtime;
`npm install` just populates `node_modules`.)

Run it:

```
cd /home/sites/<site>
./tasks/warmer-run.sh        # add -c to crawl, per the site's flag convention
```

On dev it authenticates through basic-auth (`AUTH_USER`/`AUTH_PASS` from
`.envrc`) and purges via `https://${DOMAIN_DEV}/`.

### 6. Bring the site up

```
cd /home/sites/<site>
direnv allow                 # if you haven't already this session
./tasks/permissions-set.sh   # normalize ownership/permissions
./tasks/site-start.sh        # docker-compose up -d (+ gulp asset build on dev)
```

Once containers are up, haproxy is serving 443 with the `development.pem` you
assembled in step 3. Sanity checks:

```
docker compose ps
curl -kI https://<dev-host>/    # expect a response from haproxy
```

> The optional **aliases** file some sites ship can be symlinked into
> `/etc/profile.d/` to load its shortcuts globally (re-login to pick them up).

### Order of operations (quick reference)

```
server-setup.sh (done) → log in as your user
1. <command>
2. <command>
3. <command>
4. <command>
5. <command>
6. <command>
7. <command>
8. <command>
9. <command>
```

Tasks live in each site repo's `tasks/` directory; per-site paths and flags
vary, so check the repo when something differs from the above.

