# home-infra

Setup and documentation for the machines on the home network. One folder per machine, named
after its hostname; each machine's Compose project uses the same name (`name:` in its compose file).

```
devices/
  takushiserver/   # home server: Immich, Pi-hole, Forgejo, Tailscale
```

Backups, what's in them and how to restore: [BACKUPS.md](BACKUPS.md).

Add new machines (NAS, desktop) as `devices/<hostname>/` with their own README. Notes that span
machines (network layout, what data lives where, backups) go at the top level.

Secrets stay out of git: each machine has an `example.env` to copy to an untracked `.env`.
