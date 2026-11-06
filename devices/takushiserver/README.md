# takushiserver

Home server (`ts` on the tailnet, 192.168.130.52). Run Compose from this folder; untracked
data folders (`etc-pihole/`, `forgejo/`, `tailscale/`, `couchdb/`, and Immich's database `postgres/`) and the
`.env` file live next to the compose file. Copy `example.env` to `.env` and fill it in; it holds the
settings for every service. Relative paths in it (e.g. `DB_DATA_LOCATION=./postgres`) resolve from
this folder, so move those folders with it.

Backups run nightly from `backup/` (restic, systemd timers): see [BACKUPS.md](../../BACKUPS.md).

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
| `tailscale` | Remote access over the tailnet, and HTTPS for Homepage, Immich, Forgejo and CouchDB | none of its own; host networking makes every port above reachable as `ts`. HTTPS on the tailnet: 443 (Homepage), 2443 (Immich), 3443 (Forgejo), 6984 (CouchDB) | `./tailscale` → `/var/lib/tailscale`, `./tailscale-serve` → `/config` (tracked config) |
| `homepage` | Front page: a card per service with live status, and links to these docs | 3001 (web) | `./homepage` → `/app/config` (tracked config) |
| `couchdb` | Sync server for Obsidian (Self-hosted LiveSync plugin) | 5984 on localhost only; devices use HTTPS 6984 on the tailnet | `./couchdb` → `/opt/couchdb/data`, `./couchdb-config` → `/config` (tracked config) |

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

HTTPS - Tailscale Serve gives Homepage, Immich, Forgejo and CouchDB real certificates at
`https://ts.<tailnet>.ts.net`, trusted by phones and browsers with no setup. It's tailnet only: the
Tailscale app must be on, even at home. The plain `http://` ports keep working on the LAN.

| Service | HTTPS address | Proxies to |
|---|---|---|
| Homepage | `https://ts.<tailnet>.ts.net` | `http://127.0.0.1:3001` |
| Immich | `https://ts.<tailnet>.ts.net:2443` | `http://127.0.0.1:2283` |
| Forgejo | `https://ts.<tailnet>.ts.net:3443` | `http://127.0.0.1:3300` |
| CouchDB (Obsidian sync) | `https://ts.<tailnet>.ts.net:6984` | `http://127.0.0.1:5984` |

The mapping is `tailscale-serve/serve.json` (`TS_SERVE_CONFIG`); the container fills in
`${TS_CERT_DOMAIN}` and reapplies the file whenever it changes, so edit, commit, pull - no restart.
Tailscale answers these ports itself before traffic reaches Docker, so 443 here doesn't clash with
Pi-hole's 443; over the tailnet, Pi-hole's own HTTPS page is hidden behind Homepage (use `http://ts/admin`).

first time
1. admin console -> DNS: **MagicDNS** on, then **HTTPS Certificates** -> Enable. Your tailnet name
   (the `<tailnet>.ts.net` part) is shown on the same page.
2. add `ts.<tailnet>.ts.net` to `HOMEPAGE_ALLOWED_HOSTS` in `.env`, then
```
docker compose up tailscale homepage -d
docker exec tailscale tailscale serve status
```
3. open `https://ts.<tailnet>.ts.net` on a device with Tailscale on. The first request takes a few
   seconds while the certificate is issued.

caveats
- certificates are published in public Certificate Transparency logs, so the names `ts` and your
  tailnet become public. Nothing becomes reachable because of that.
- Forgejo's own links and clone URLs still use `FORGEJO_HOST` over plain http; the HTTPS address is
  for browsing.

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

Over HTTPS it's at `https://ts.<tailnet>.ts.net` (see tailscale "HTTPS"). If the page says the host
isn't allowed, add the exact host (and port, if the address has one) you opened it at to
`HOMEPAGE_ALLOWED_HOSTS` in `.env` (default `ts:3001,192.168.130.52:3001`). There's no login: anyone on
the LAN or tailnet can see it, which is fine since it only shows counts and links. Homepage can add a
password (`HOMEPAGE_AUTH_ENABLED`) if that changes.

upgrade - bump the image tag in `docker-compose.yml` after reading the release notes, then
```
docker compose pull homepage && docker compose up homepage -d
```

# obsidian sync
Syncs Obsidian vaults between phone, laptop and desktop through CouchDB, using the community plugin
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync). Each device keeps a full local
copy of the vault and works offline; changes sync within seconds when it's online. CouchDB only
listens on the server itself (127.0.0.1:5984). Devices reach it at `https://ts.<tailnet>.ts.net:6984`
through Tailscale Serve, which supplies the HTTPS that Obsidian on phones requires, so the Tailscale
app must be on, even at home.

Settings from the plugin's setup guide (single node, CORS for the Obsidian apps, large documents,
login required) are in `couchdb-config/livesync.ini`. They're copied in at every start, so after
editing it, `docker compose restart couchdb`.

first start
1. set a long random `COUCHDB_PASSWORD` in `.env` (`openssl rand -base64 24`); `COUCHDB_USER`
   defaults to `obsidian`. Without a password CouchDB stays in a restart loop and says why in
   `docker logs couchdb`.
2. start it, then check it from the server
```
mkdir -p couchdb && docker compose up couchdb -d
curl -u obsidian:<password> http://127.0.0.1:5984/_up
```
3. the HTTPS address needs Tailscale Serve set up (see tailscale "HTTPS"); `tailscale serve status`
   should list port 6984.

first device (desktop)
1. Obsidian -> Settings -> Community plugins -> Browse -> **Self-hosted LiveSync** -> Install, Enable
2. its setup wizard -> manual setup with CouchDB: URI `https://ts.<tailnet>.ts.net:6984`, the user
   and password from `.env`, any database name (e.g. `vault`). Run its check, which fixes
   anything the server is missing.
3. turn on **end-to-end encryption** and pick a passphrase. CouchDB then only stores encrypted data,
   and the passphrase is needed on every device: keep it in your password manager.
4. sync mode **LiveSync**, then let it upload the vault.
5. plugin settings -> copy the **setup URI** (it asks for a separate passphrase to protect it).

other devices (phone): install Tailscale and Obsidian, create an empty vault, install the plugin, and
choose "Use setup URI": paste the URI from step 5 and its passphrase. Let it download the vault
before editing anything.

notes
- anything in the vault syncs, including folders linked into it (a 27 MB mirror of someone else's
  notes would land on the phone too). The plugin's selective-sync settings can skip a folder.
- every device holds the whole vault, but back up `./couchdb` too; restoring it brings back a sync
  server every device can reconnect to. Stop the container for a consistent copy.
- the CouchDB web admin (Fauxton) is at `https://ts.<tailnet>.ts.net:6984/_utils`.

upgrade - `couchdb:3.5` follows 3.5.x patch releases; move to a new minor version deliberately
```
docker compose pull couchdb && docker compose up couchdb -d
```
