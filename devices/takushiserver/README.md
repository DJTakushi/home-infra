# takushiserver

Home server (`ts` on the tailnet, 192.168.130.52). Run Compose from this folder; untracked
data folders (`etc-pihole/`, `forgejo/`, `tailscale/`, and Immich's database `postgres/`) and the
`.env` file live next to the compose file. Copy `example.env` to `.env` and fill it in; it holds the
settings for every service. Relative paths in it (e.g. `DB_DATA_LOCATION=./postgres`) resolve from
this folder, so move those folders with it.

## Services

Everything is in `docker-compose.yml` (Compose project `takushiserver`). Container names are in
parentheses where they differ. Ports are host ports; services with none are only reachable by the
other containers. Mounts show host path → container path, using the `.env` defaults; relative paths
resolve from this folder.

| Service | What it does | Host ports | Mounts |
|---|---|---|---|
| `immich-server` (`immich_server`) | Photo and video library, web UI and API | 2283 (web) | `~/Pictures/immich_library` → `/data` |
| `immich-machine-learning` (`immich_machine_learning`) | Face recognition and smart search for Immich | none | volume `model-cache` → `/cache` |
| `database` (`immich_postgres`) | Immich's Postgres database | none | `./postgres` → `/var/lib/postgresql/data` |
| `redis` (`immich_redis`) | Immich's job queue (Valkey) | none | none |
| `pihole` | DNS ad-blocking for the network | 53 tcp/udp (DNS), 80 and 443 (web UI) | `./etc-pihole` → `/etc/pihole` |
| `forgejo` | Self-hosted Git | 3300 (web), 2222 (Git over SSH) | `./forgejo` → `/data` |
| `tailscale` | Remote access over the tailnet | none of its own; host networking makes every port above reachable as `ts` | `./tailscale` → `/var/lib/tailscale` |
| `homepage` | Front page: a card per service with live status, and links to these docs | 3001 (web) | `./homepage` → `/app/config` (tracked config) |

# immich
The version is pinned with `IMMICH_VERSION` in `.env` (v3.3.5) to avoid breaking upgrades. Raise it
deliberately after reading the release notes, then `docker compose pull && docker compose up -d`.

# pihole
ubuntu consdierations regarding port 53: https://docs.pi-hole.net/docker/tips-and-tricks/

```
sudo sh -c 'mkdir -p /etc/systemd/resolved.conf.d && printf "[Resolve]\nDNSStubListener=no\n" | tee /etc/systemd/resolved.conf.d/no-stub.conf'
sudo sh -c 'rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf'
systemctl restart systemd-resolved
```

check who is using port 53
```
sudo lsof -i :53
```

check ubuntu
```
ping -c3 www.ubuntu.com
```

recreate pihole with recreation
```
docker compose up pihole --force-recreate -d
```

lookup
```
nslookup ubuntu.com
```

check resolving settings,  including current  DSNS server
```
resolvectl status
```
# forgejo
Self-hosted Git server (GitHub-like: pull requests, issues, web UI) - a backup remote for work
repos that don't have a hosted home yet. Web UI on port **3300**, Git over SSH on **2222**
(Pi-hole has 80/443, Grafana 3000). Data, repos and the SQLite database live in `FORGEJO_DATA_LOCATION`
(default `./forgejo`).

first start - set `FORGEJO_HOST` in `.env` to the server's LAN name or IP first, so clone URLs are right
```
mkdir -p forgejo && docker compose up forgejo -d
```
then open `http://<server>:3300`, keep SQLite, and create the **administrator account** in
"Administrator account settings" at the bottom of the install page (self-registration is off).

add your workstation's SSH key: avatar -> Settings -> SSH / GPG keys -> Add key (`cat ~/.ssh/id_ed25519.pub`)

push an existing repo - create an empty repo in the web UI (no README), then on the workstation
```
git remote add home ssh://git@<server>:2222/<user>/<repo>.git
git push home --all && git push home --tags
```

pull requests from the command line - the `tea` CLI (https://gitea.com/gitea/tea) works with Forgejo
```
tea login add --name home --url http://<server>:3300 --token <token from Settings -> Applications>
tea pr create --login home --base main --head feat/x --title "..."
```

optional: a name instead of the IP - Pi-hole -> Local DNS -> DNS Records, e.g. `git.home` -> server IP,
then use it as `FORGEJO_HOST`.

backup - everything is in the data folder; a consistent dump:
```
docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini -f /data/forgejo-dump.zip
```

upgrade - bump the image tag in `devices/takushiserver/docker-compose.yml` one major LTS at a time, then
```
docker compose pull forgejo && docker compose up forgejo -d
```

# tailscale
Reach every service here from outside the home network over a private Tailscale network
(tailnet), with **no router port forwards**. The container uses host networking, so it acts like
Tailscale installed on the server: Immich (2283), Forgejo (3300 web, 2222 SSH) and Pi-hole are
reachable at the same ports from any device signed in to the tailnet.

first start
1. create a Tailscale account at https://login.tailscale.com (use a login with 2FA - it now guards the network)
2. admin console -> Settings -> Keys -> **Generate auth key** (one-off, not reusable) and put it in `.env` as `TS_AUTHKEY`
3. start it
```
mkdir -p tailscale && docker compose up tailscale -d
docker exec tailscale tailscale status
```
4. admin console -> Machines -> `ts` -> **...** -> **Disable key expiry**, or the server drops off the tailnet after 180 days
5. install the Tailscale app on your phone/laptop, sign in to the same account, then test with Wi-Fi off: `http://ts:3300`

The auth key is only used to join - the login is stored in `TAILSCALE_DATA_LOCATION` (default
`./tailscale`). Keep that folder; deleting it makes the server join as a new machine.

`ts` on the tailnet is a MagicDNS name. On a computer that pins `ts` to the LAN IP in
`/etc/hosts`, that entry wins and fails away from home - remove it.

optional: ad-blocking away from home - admin console -> DNS -> add a nameserver with the server's
Tailscale IP (`docker exec tailscale tailscale ip -4`) and turn on **Override local DNS**.
Pi-hole already answers on all interfaces (`FTLCONF_dns_listeningMode: all`).

Remove any router port forwards to this server once the tailnet works - nothing needs to be open.

caveat: remote access now depends on Docker. `restart: always` covers crashes and reboots, but if
the Docker daemon itself is broken you need to be on the LAN to fix it.

upgrade
```
docker compose pull tailscale && docker compose up tailscale -d
```

# homepage
Front page for this server at `http://ts:3001`, built with [Homepage](https://gethomepage.dev). Each service
has a card with a status dot (and, for Immich and Pi-hole, live numbers), and the Docs row links to
the sections of this README. Its config is the YAML in `homepage/` and is tracked in git; Homepage
reloads it on save, so edit, commit, and refresh the page.

- `services.yaml`: the cards. `href` is opened by your browser, so it uses the server's name (`HOMEPAGE_HOST`, default `ts`); widget and `siteMonitor` URLs are fetched by the container, so they use compose service names like `http://immich-server:2283`.
- `bookmarks.yaml`: the Docs links. Add one when a service gets a README section.
- `settings.yaml`, `widgets.yaml`: title, layout, and the CPU, memory and disk bar at the top.
- `docker.yaml`, `kubernetes.yaml`: unused defaults; Homepage recreates them if they're missing.

first start - the Immich key goes in `.env`, then `docker compose up homepage -d`
- `HOMEPAGE_IMMICH_KEY`: Immich -> Account Settings -> API Keys, with the `server.statistics` permission
- Pi-hole needs nothing: the widget reuses `PIHOLE_PASSWORD`. The Immich key is stored in Immich's database, so restoring `postgres/` from backup keeps it valid.

Without the key the Immich card shows "API Error"; the rest of the page still works.

If the page says the host isn't allowed, add the exact `host:port` you opened it at to
`HOMEPAGE_ALLOWED_HOSTS` in `.env` (default `ts:3001,192.168.130.52:3001`). There's no login: anyone on
the LAN or tailnet can see it, which is fine since it only shows counts and links. Homepage can add a
password (`HOMEPAGE_AUTH_ENABLED`) if that changes.

upgrade - bump the image tag in `docker-compose.yml` after reading the release notes, then
```
docker compose pull homepage && docker compose up homepage -d
```
