# distro-builder

Build and distribution tooling for a personal, immutable CachyOS/Arch-based distro on
[arkdep](https://github.com/arkanelinux/arkdep). The root filesystem of each laptop is a read-only
btrfs image built here; interactive software lives in a distrobox (`userland`) fed by a small
repository of prebuilt AUR packages, also built here. An installer ISO puts the whole thing on a
new machine.

| Tool | What it produces | Where it is published | When |
|---|---|---|---|
| [`image/`](image/README.md) | arkdep images, one per device recipe | `http://192.168.2.50/<recipe>/` | weekly (Sunday 08:00 Europe/Madrid) |
| [`bootc/`](bootc/README.md) | bootc images of the same recipes (trial: the T480 runs them) | registry `192.168.2.50:5000/<recipe>` | weekly (Sunday 13:00 Europe/Madrid) |
| [`aur/`](aur/README.md) | the pacman repository `[aur]` | `http://192.168.2.50/aur/` | daily (04:00 UTC) |
| [`iso/`](iso/README.md) | the installer ISO | `http://192.168.2.50/iso/` | by hand |

Each directory has a `README.md` with its usage and a `CLAUDE.md` with implementation notes and the
pitfalls already hit; [`serve/README.md`](serve/README.md) covers the web server, the status page
and the registry.

```
image/    recipes (arkdep-build.d/), build, prune, notify-image
bootc/    Containerfile and build-recipe.sh (the recipes as bootc images), build, prune, overlay/
aur/      packages.list, local/ (own PKGBUILDs), aur-build.sh, build
iso/      installer ISO: Containerfile, build, test-vm, airootfs/ (install.sh, arkdep.config)
serve/    web server (nginx quadlet): /mnt/repo and the status page (web/, status-gen, build-trigger);
          container registry (quadlet) for the bootc images
systemd/  build units and timers, distro-status (page data), distro-trigger (manual builds)
lib/      builder.sh, sign.sh: shared by the build scripts
ci/       check: static checks, run by GitHub Actions (.github/workflows/check.yml) on every push
install   sets up the build server
```

## Checks

`ci/check` runs the static checks: shellcheck of every shell script (warnings and errors, from the
pinned `koalaman/shellcheck` image through podman or docker), Python syntax, no stray files tracked
(`__pycache__`, editor swap files), commands executable (`bin/`, `sbin/` and the tools'
extensionless scripts) and the structure arkdep-build needs from each device recipe. GitHub Actions
runs it on every push (`.github/workflows/check.yml`; a failure shows on the commit and GitHub
sends an email); run it before pushing.

## Build server

Everything builds on `192.168.2.50` (VM 202 on the Proxmox host zeus, Debian 13, user `admin`,
checkout `/home/admin/distro-builder`), never on the laptops. Requirements:

- rootful podman (builds run with `sudo`; image and ISO builds need `--privileged` for btrfs and
  loop devices) and the `loop` module;
- `/mnt/repo` mounted from the file server (NFS `192.168.2.10:/mnt/pool/repos/arkdep`): images,
  AUR packages and ISOs are written there and served from there;
- `notify-ha` and the `notify-failure@.service` template, installed by the homelab repo (Ansible
  role `notify_ha`), for the Home Assistant notifications;
- port 5000 reachable from the LAN for the container registry (the bootc images).

The VM is defined in the homelab repo and is rebuilt from scratch rather than backed up: Ansible
creates it (`pve_guests`, cloud-init), clones this repository and runs `install` (play "Build
server"). Step by step: `docs/rebuild.md` in the homelab repo. To set up a server by hand:

```sh
git clone https://github.com/vonbloom/distro-builder.git ~/distro-builder
sudo ~/distro-builder/install   # or: sudo ARKDEP_RECIPES="p14s t480" BOOTC_RECIPES= ~/distro-builder/install
```

`install` links the units in `systemd/` into `/etc/systemd/system`, the quadlets
`serve/distro-repo.container` and `serve/distro-registry.container` into `/etc/containers/systemd`,
creates `/mnt/repo/registry` and `/mnt/repo/bootc`, installs the polkit rule of the build trigger,
enables `build-aur.timer`, the weekly `build-image@<recipe>.timer` of the recipes in
`ARKDEP_RECIPES` (default `p14s`) and `build-bootc@<recipe>.timer` of those in `BOOTC_RECIPES`
(default `t480`), `distro-status.timer`, `distro-trigger.socket` and `podman-auto-update.timer`,
and (re)starts the web server and the registry. The defaults are what each laptop runs while arkdep
and bootc are compared (P14s arkdep, T480 bootc); the other recipes' timers are disabled, and their
builds stay available by hand (`systemctl start`, or the status page, which lists the arkdep and
bootc builds of every recipe). It is idempotent: run it again to change the schedules, or after
changing `systemd/` or `serve/`.

Every build unit pulls the checkout (`git pull --ff-only`, as `admin`) before building, so a
push to GitHub is enough for the next build to use it. A failed pull does not stop the build. The
units and timers themselves are only reloaded by systemd: after changing a file in `systemd/`,
run `sudo systemctl daemon-reload` on the server once the pull has brought it in.

Each tool builds inside its own throwaway podman *builder* image (`arkdep-builder`, `aur-builder`,
`iso-builder`). `lib/builder.sh` (`ensure_builder`) rebuilds a builder image from scratch when it
is missing, older than 7 days or `--rebuild-builder` is given, so the tools and package databases
inside never go stale.

### Signatures

Everything published is signed with the build server's key (ed25519,
`CF47 1E66 8597 4BF4 3EA1  1362 3F9E BD77 B1E6 0E55`, public part in `keys/distro-builder.asc`):
images (`<image>.tar.zst.sig`), the `[aur]` packages and database, and the ISO checksums. The
build scripts sign after their container has finished (`lib/sign.sh`), so the containers, which
run unreviewed AUR code, never see the key. It lives only in `/etc/distro-builder/gnupg` (root,
mode 700) on the server, backed up in the homelab vault, from which the "Build server" play
restores it. Without the key (a local test run) nothing is signed and the scripts say so.

Clients get the public key from this repository, not from the server they verify:

- laptops: `/arkdep/keys/trusted-keys`, which arkdep checks every image against with `gpgv`
  (`gpg_signature_check` in `/arkdep/config`: `1` verifies when a signature exists, `2` refuses
  unsigned images). The installer sets it up; on an existing machine:
  `sudo sh -c 'gpg --dearmor < keys/distro-builder.asc > /arkdep/keys/trusted-keys'`;
- the `[aur]` clients: `pacman-key --add` + `--lsign-key` (see [aur/README.md](aur/README.md)).

### Notifications

Every unit has `OnFailure=notify-failure@%n.service`, so a failed build sends a `[FAILED]` push to
Home Assistant with the end of its journal. A successful image build sends "New image ..." (tag
`image-<recipe>`) with its package count, kernel and the changes since the previous image; it is
sent as a warning when the package count drops by more than 20 % (see
[image/README.md](image/README.md#sanity-check)). A bootc image build sends the same as "New bootc image ..." (tag
`bootc-<recipe>`).
