# Legacy / special case: the original lighttpd host

> **This is not the supported way to deploy ipinfo.** Use `deploy.sh` (systemd + Caddy) or
> `docker compose` (Traefik) — see the main [README](../../README.md). Nothing here applies to
> those installs, and running these files against them is likely to break them.

This directory exists so the deployment tooling for **one hand-built host** is not lost:
`britta.asdfghjkl.ca`, the machine ipinfo was first written on, before Docker and before
`deploy.sh`. It fronts gunicorn with **lighttpd** (`mod_proxy` over a Unix socket) instead of
Caddy or Traefik, so `deploy.sh` cannot manage it: it would install Caddy and Go, refuse to run
while lighttpd holds ports 80/443, regenerate the systemd unit with the wrong `Group=` (lighttpd,
running as `www-data`, could no longer open the socket), and its `git pull` fails on a checkout
pinned to a release tag.

| File | What it is |
| --- | --- |
| [`ipinfo-update.sh`](ipinfo-update.sh) | Update the host to a GitHub release, with automatic rollback |
| [`ipinfo.service.example`](ipinfo.service.example) | Reference copy of the systemd unit the script expects |

## Layout the script assumes

It checks for this and refuses to run otherwise.

- App at `/srv/ipinfo`, a git checkout of a **release tag** (detached HEAD), owned by `ipinfo`,
  with its own `venv/` and a `logs/` directory (both git-ignored).
- systemd unit `ipinfo.service` whose `ExecStart` is `/srv/ipinfo/venv/bin/python -m gunicorn ...`,
  binding `unix:/run/ipinfo/ipinfo.sock` with `Group=www-data`, and
  `EnvironmentFile=/etc/ipinfo/ipinfo.env` (same variable names as the Docker `.env`, e.g.
  `BASE_DOMAIN`, `TRUSTED_PROXY_COUNT`; see `example.env`).
- lighttpd proxies each vhost to that socket. lighttpd overwrites `X-Forwarded-For`, so
  `TRUSTED_PROXY_COUNT=1` is correct there.
- Needs `git`, `curl`, `flock`, `python3-venv`, GNU coreutils, and root or passwordless `sudo`.

## Install

```bash
sudo install -m 0755 ipinfo-update.sh /usr/local/sbin/ipinfo-update
```

## Use

```bash
ipinfo-update --check          # installed vs. latest release; changes nothing
ipinfo-update                  # update to the newest non-pre-release v* tag
ipinfo-update v0.2.4-4.10.222A # a specific tag
ipinfo-update --build-only     # build + smoke-test the latest tag, discard it, service untouched
ipinfo-update --rollback       # swap back to the newest kept previous tree
ipinfo-update --force TAG      # rebuild and swap even if already on TAG
```

An update builds the release in `/srv/ipinfo.new` (venv, requirements minus pytest, in-process
smoke test as the service user) **before** touching the running service. Only then does it stop
the service, rename directories, carry `logs/` across, start it, and check `/`, `/98`, `/json` and
`/iponly` through the gunicorn socket (sending `X-Forwarded-For` the way lighttpd does; over a
Unix socket the app otherwise has no client IP and `/iponly` returns 500). If any check fails it puts the previous tree back
automatically. Downtime is a stop, two renames and a start.

Kept alongside `/srv/ipinfo` (newest two of each are retained, older ones pruned after a
successful update):

- `/srv/ipinfo.old-<timestamp>` — the tree before an update; what `--rollback` restores
- `/srv/ipinfo.failed-<timestamp>` — a release that failed verification, for post-mortem
- `/srv/ipinfo.replaced-<timestamp>` — the tree a `--rollback` replaced

Each tree carries its own venv (about 30–60 MB), so budget for a handful of them. The script
refuses to start with under 300 MB free (`IPINFO_MIN_FREE_MB`).

## Notes

- A new setting from a release goes in `/etc/ipinfo/ipinfo.env`, then `sudo systemctl restart ipinfo`.
- `--rollback` only works to a tree that has its own `venv/`. Trees from before this layout
  (system-Python gunicorn) must be restored by hand.
- Tag names look like `v0.2.3-4.10.222A`; the `-4.10.222A` suffix is a joke build number and is
  ignored by everything except `git`. `--check`/auto-update skip `-rc`/`-beta`/`-alpha` tags.
- Some git versions print `warning: refs/tags/... is not a commit!` when shallow-cloning an
  annotated tag. It is harmless; the correct commit is still checked out.
- Every path, user and service name can be overridden (`IPINFO_APP_DIR`, `IPINFO_SERVICE`, ...);
  see the header of the script.
