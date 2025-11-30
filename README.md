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