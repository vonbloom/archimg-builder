# Web server, status page and registry (`serve/`)

Run on the build server by podman quadlets and systemd units that `../install` sets up.

## Web server

`serve/distro-repo.container` runs `nginx:alpine` on port 80 (a podman quadlet, so systemd runs it
as `distro-repo.service`) with `/mnt/repo` as its document root and directory listings on. It is
kept up to date by `podman-auto-update.timer` (daily: pulls a new `nginx:alpine` and restarts the
service, rolling back if it does not start):

```
/mnt/repo/
├── p14s/   database, p14s-YYYY-MM-DD.tar.zst(.sig), p14s-YYYY-MM-DD.pkgs
├── t480/   ...
├── aur/    aur.db(.sig), *.pkg.tar.zst(.sig)
├── bootc/  <recipe>/<recipe>-YYYY-MM-DD.pkgs: package lists of the bootc images
├── registry/  storage of the container registry
└── iso/    distro-installer-YYYY.MM.DD-x86_64.iso, sha256sums.txt(.sig)
```

## Status page

`http://192.168.2.50/` is a status page (`serve/web/index.html`, a single static file) instead of
the directory listing (still available under each directory):

- **Builds**: state, last run, duration and next run of each build unit, with its log (follows the
  end while the build runs) and an **Executa** button to start it now;
- **Images** per recipe: size, packages, kernel and the package changes since the previous image;
- **Installer**: the ISO with its SHA-256; **`[aur]`**: packages and versions.

Three pieces, all run by systemd:

| Piece | Unit | Does |
|---|---|---|
| `serve/status-gen` | `distro-status.timer` (every minute) | reads systemd, the journal and `/mnt/repo`; writes `status.json`, `recipes.txt` and `logs/<unit>.txt` to `/run/distro-status`, served at `/status/` |
| `serve/build-trigger` | `distro-trigger.socket` (socket activated) | `POST /api/build/<unit>`, proxied by nginx through `/run/distro-trigger/trigger.sock`: starts a build unit |
| `serve/web/index.html` | `distro-repo.service` (nginx) | the page; reads `/status/` every 30 s |

`build-trigger` runs as `admin`; the polkit rule `serve/distro-trigger.rules` (copied to
`/etc/polkit-1/rules.d`) only lets it start `build-*.service` and `distro-status.service`. Only
units shown on the page can be started, and requests need an `X-Distro-Builder` header, so other
web sites cannot start builds from a visitor's browser. There is no login: anyone on the LAN can
see the page and start builds.

`/status/recipes.txt` lists the recipes with images; the installer reads it for its recipe menu.

## Registry

`distro-registry.container` runs `registry:2` on port 5000 (plain HTTP, storage
`/mnt/repo/registry`, deletes enabled for `bootc/prune`) for the bootc images and their sigstore
signatures (tags `sha256-<digest>.sig`): see [`../bootc/README.md`](../bootc/README.md).
