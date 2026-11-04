# takushiserver

Home server (`ts` on the tailnet, 192.168.130.52). Run Compose from this folder; untracked
data folders (`etc-pihole/`, `forgejo/`, `tailscale/`) and `.env` files live next to the compose file.

# immich
- set host environmetn varaible to v2.3.1 to avoid breaking
```
export IMMICH_VERSION=v2.3.1
```

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
