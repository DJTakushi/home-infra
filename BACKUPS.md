# Backups

Every night takushiserver backs itself up with [restic](https://restic.net) to each repository
listed in `BACKUP_REPOS`: a local disk and an offsite bucket. Snapshots are encrypted before they
leave the server and deduplicated, so after the first run each night only sends what changed.
The script, its config template and the systemd timers are in
[`devices/takushiserver/backup/`](devices/takushiserver/backup/).

## What's backed up

| Data | How | If it's lost |
|---|---|---|
| Immich photos and videos (`UPLOAD_LOCATION`) | files, minus `thumbs/` and `encoded-video/` (Immich regenerates them) | gone for good; often the only copy |
| Immich database | `pg_dumpall` of `immich_postgres` → `immich-db.sql.gz` | albums, faces, people, shared links |
| Forgejo | `forgejo dump` → `forgejo-dump.zip` (repos, database, config) | the backup remotes for work repos |
| Obsidian sync (`./couchdb`) | CouchDB stopped for a few seconds and its folder copied | every device has the vault; this is the sync server |
| This repo, including `.env`, `tailscale/`, `etc-pihole/` and `backup/backup.env` | files, including `.git` | the setup itself, secrets, the tailnet identity and DNS settings |

Not backed up: the raw `postgres/`, `forgejo/` and `couchdb/` folders (the dumps are their
consistent copies) and the `model-cache` volume (Immich downloads the models again).

Dumps are written to `/var/tmp/takushiserver-backup` and stay there until the next run.

**Schedule:** backups run at 03:30 nightly, and a check at 06:00 on the 1st reads back 5% of
each repository. **Retention:** 7 daily, 4 weekly and 12 monthly snapshots.

## Setup

On the server, from `devices/takushiserver/backup/`:

1. Install restic (`sudo apt install restic`) and pick where the backups go.
   - Local: a USB disk mounted at a fixed path, e.g. `/mnt/backup` through `/etc/fstab` with `nofail`.
   - Offsite: a [Backblaze B2](https://www.backblaze.com/cloud-storage) bucket (private, roughly
     $6/TB per month) with an application key limited to that bucket, or a Hetzner Storage Box over SFTP.
2. Create the encryption password, and **save a copy in your password manager**. Without it the
   backups can't be read.
```
sudo install -d -m 700 /root/.config/restic
sudo sh -c 'openssl rand -base64 32 > /root/.config/restic/password && chmod 600 /root/.config/restic/password'
```
3. `cp backup.example.env backup.env && chmod 600 backup.env`, then fill in `BACKUP_REPOS` and the
   B2 key.
4. Optional: create two checks at [healthchecks.io](https://healthchecks.io), one with a 1 day
   period and one with a 31 day period, and put their URLs in `HEALTHCHECK_URL` and
   `HEALTHCHECK_CHECK_URL`. You then get an email when a run fails *or never happens*. Without
   them, failures only show in `journalctl -u takushiserver-backup`.
5. Create the repositories, run the first backup by hand (the first offsite upload of the photo
   library can take hours or days), then install the timers:
```
sudo ./backup.sh init
sudo ./backup.sh run
sudo ./install.sh
```

Day to day:
```
sudo ./backup.sh restic snapshots                 # list snapshots in the first repository
sudo ./backup.sh restic -r <repo> snapshots       # ... or in another one
journalctl -u takushiserver-backup -n 50          # last run's output
systemctl list-timers 'takushiserver-backup*'     # next runs
```

If the local disk isn't mounted, its backup fails (restic finds no repository there) instead of
filling the system disk. The offsite backup still runs.

## Restore

Restore into a scratch folder first, then put things in place. Paths inside a snapshot are
absolute, so they reappear under the target folder.
```
sudo ./backup.sh restic restore latest --target /var/tmp/restore
```
To get one file back, use `restic ls latest | grep <name>`, then `restic restore latest --target /var/tmp/restore --include <path>`.

**A whole new server:** install Docker and restic, and put the restic password in
`/root/.config/restic/password`. Then point restic at the offsite repository directly, because
`backup.env` is still inside the backup:
```
sudo AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  restic -r s3:https://s3.<region>.backblazeb2.com/<bucket> --password-file /root/.config/restic/password \
  restore latest --target /var/tmp/restore
```
Move the restored repo folder to where it lived, along with the photo library at its
`UPLOAD_LOCATION`. Then restore each service below and run `docker compose up -d`. Keep the
repository address and the B2 key in your password manager next to the restic password: those
three are all a rebuild needs.

**Immich database:** restore into an empty database before Immich starts, following
[Immich's restore steps](https://docs.immich.app/administration/backup-and-restore). In short:
```
docker compose down && sudo rm -rf ./postgres
docker compose create && docker compose start database && sleep 10
gunzip -c /var/tmp/restore/var/tmp/takushiserver-backup/immich-db.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker exec -i immich_postgres psql --dbname=postgres --username=postgres
docker compose up -d
```

**Forgejo:** unzip `forgejo-dump.zip` and copy its parts into an empty `./forgejo`. Repositories
go under `git/repositories/`, the `data` folder becomes `gitea/`, and `app.ini` goes in
`gitea/conf/`. Load the `*-db.sql` file into `gitea/gitea.db` with `sqlite3`, `chown -R 1000:1000 ./forgejo`,
then start Forgejo. Check the file names after unzipping: they follow the Forgejo version.

**CouchDB:** with the container stopped, replace `./couchdb` with the restored copy,
`chown -R 5984:5984 ./couchdb`, and start it. Devices reconnect on their own.

**Everything else** (`.env`, `tailscale/`, `etc-pihole/`) is copied back as plain files. Restore
`tailscale/` and the server rejoins the tailnet as the same machine.

Test a restore at least once: bring up Immich from a restored database and library on a scratch
machine or folder. A backup you haven't restored from is a hope, not a backup.

## This repo

This repo needs to outlive the server, because it holds the restore steps above. It's covered
three ways:

- the workstation clone is a full copy, history included;
- every nightly snapshot includes the server's clone;
- optionally, a private GitHub mirror (below), so the docs can be read in a browser when the
  server is down and before anything has been restored.

### GitHub mirror (optional)

Forgejo can push every change to GitHub on its own, so no extra step is needed when you commit.
The repo holds no secrets: `.env` and `backup.env` are git-ignored. What GitHub would see is the
layout, the server's LAN IP and hostname, and the email addresses on the commits.

1. Create an empty private repo (no README), either at github.com/new or with
   `gh repo create home-infra --private`.
2. GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate. Under Repository
   access, pick **Only select repositories** → `home-infra`. Under Permissions → Repository,
   set **Contents: Read and write**. Note the expiry date: the mirror stops when the token
   expires.
3. Forgejo → `home-infra` → Settings → Repository → **Mirror settings** → Push mirror. Git
   remote URL: `https://github.com/<user>/home-infra.git`, username: your GitHub user,
   password: the token. Tick **Sync when new commits are pushed**, then **Add push mirror**, then
   **Synchronize now**.
4. Check that the branches show up on GitHub. Forgejo shows the last sync time and any error on
   the same settings page.

The mirror is an exact copy: a branch deleted in Forgejo is deleted on GitHub at the next sync.
It copies git only. Pull requests and issues stay in Forgejo.
