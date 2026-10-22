# home_server_setup

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
repos that don't have a hosted home yet. Web UI on port **3000**, Git over SSH on **2222**
(Pi-hole already has 80/443). Data, repos and the SQLite database live in `FORGEJO_DATA_LOCATION`
(default `./forgejo`).

first start - set `FORGEJO_HOST` in `.env` to the server's LAN name or IP first, so clone URLs are right
```
mkdir -p forgejo && docker compose up forgejo -d
```
then open `http://<server>:3000`, keep SQLite, and create the **administrator account** in
"Administrator account settings" at the bottom of the install page (self-registration is off).

add your workstation's SSH key: avatar -> Settings -> SSH / GPG keys -> Add key (`cat ~/.ssh/id_ed25519.pub`)

push an existing repo - create an empty repo in the web UI (no README), then on the workstation
```
git remote add home ssh://git@<server>:2222/<user>/<repo>.git
git push home --all && git push home --tags
```

pull requests from the command line - the `tea` CLI (https://gitea.com/gitea/tea) works with Forgejo
```
tea login add --name home --url http://<server>:3000 --token <token from Settings -> Applications>
tea pr create --login home --base main --head feat/x --title "..."
```

optional: a name instead of the IP - Pi-hole -> Local DNS -> DNS Records, e.g. `git.home` -> server IP,
then use it as `FORGEJO_HOST`.

backup - everything is in the data folder; a consistent dump:
```
docker exec -u git forgejo forgejo dump -c /data/gitea/conf/app.ini -f /data/forgejo-dump.zip
```

upgrade - bump the image tag in `docker-compose.yml` one major LTS at a time, then
```
docker compose pull forgejo && docker compose up forgejo -d
```
