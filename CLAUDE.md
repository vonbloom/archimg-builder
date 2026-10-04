# archimg-builder

Recipes and tooling to build immutable [arkdep](https://github.com/arkanelinux/arkdep) images of a
CachyOS/Arch-based personal distro. The user speaks Catalan; code, comments and commit messages are
in English (short, sentence-style subjects).

## System overview

- **Host OS**: arkdep deployments. Root is a read-only btrfs subvolume
  (`/arkdep/deployments/<image>/rootfs`), `/etc` and `/var` are separate subvolumes per deployment.
  `deploy_keep=2`. Packages are not installed on the host at runtime: change a recipe and rebuild.
- **Userland**: everything interactive (VS Code, Brave, neovim, compilers) lives in the `userland`
  distrobox (Arch). Defined in `~/.config/distrobox/default.ini`, from the dotfiles repo
  `vonbloom/dotfiles` (stow, `~/.dotfiles`). Provisioned at first login by
  `/usr/local/bin/deploy-userland` (user unit `deploy-userland.service`).
- **Host config persistence**: `/arkdep/config` `migrate_files` copies listed paths from the running
  system into each new deployment (`cp -rp`, merged over the image). It includes
  `etc/passwd|shadow|group`, `etc/ssh`, `etc/systemd/network` (WireGuard `wg0`), `var/lib/iwd`, etc.
  Local copies win over the image versions of the same files.
- **Users**: `arkdep-build` moves non-root accounts to `/usr/lib/{passwd,group,shadow}`, read through
  `nss-altfiles` (`altfiles` in `nsswitch.conf`). Do not remove either or system users disappear.

## Build and publish

- Builds run on the server `192.168.2.50` (checkout at `/home/admin/archimg-builder`), not on the
  laptops: `./build <recipe>` builds the `arkdep-builder` podman image (when missing or older than 7 days, arkdep from
  `arkanelinux/pkgbuild`) and runs `arkdep-build.sh` inside it, writing to `/mnt/repo/<recipe>`.
- Scheduled builds: `install` (as root) links `systemd/archimg-build@.{service,timer}` into
  `/etc/systemd/system` and enables `archimg-build@<recipe>.timer` for p14s and t480 (Sunday 08:00
  Europe/Madrid, `Persistent=true`). Builds run one at a time (`flock /run/archimg-build.lock`).
  After a successful build, `prune <recipe>` thins out old images (keep the newest 4 plus the newest
  of each of the 3 previous months; `prune --dry-run <recipe>` shows the plan) and `notify-image`
  sends "New image ..." with the package changes to Home Assistant. A failed build triggers
  `notify-failure@` (both `notify-ha` and that unit come from the homelab repo, role `notify_ha`).
  Logs: `journalctl -u archimg-build@<recipe>`.
- `serve` installs the `arkdep-repo.container` quadlet: nginx serves `/mnt/repo` at
  `http://192.168.2.50/<recipe>/` (`database` file + `<name>.tar.zst`).
- An image `.tar.zst` contains btrfs send streams (`<name>-rootfs.img`, `-etc.img`, `-var.img`) and
  `<name>-update.sh`. Inspect without root:
  `curl -s URL | zstd -dc | tar -xOf - ./<name>-rootfs.img | btrfs receive --dump`
  (paths appear as `rename ... dest=./rootfs/<path>`).

## Recipe layout (`arkdep-build.d/`)

```
common/           pacman.conf, mirrorlist, extensions/{pre_build,post_install}.sh
depends/generic/  base system: bootstrap.list, package.list, overlay/{post_bootstrap,post_install}
depends/sway/     desktop: package.list, overlay/post_install (sway, waybar, foot, rofi, user units)
p14s/             ThinkPad P14s Gen 1 AMD (Ryzen 7 PRO 4750U, Renoir) + update.sh
t480/             ThinkPad T480 (i7-8650U Kaby Lake-R, UHD 620, Intel 8265, 2 batteries, TB3)
```

Device recipes contain only hardware specific things (ucode, `linux-firmware-*` split packages,
GPU driver in `dracut.conf.d/10-gpu.conf`, `tlp.d/50-<device>.conf`, presets) plus `name.sh`,
`type`, `depends.list` and symlinks `pacman.conf`, `mirrorlist`, `extensions` -> `../common/`.

How `arkdep-build` processes a recipe (relevant constraints):
- `pacman.conf` and `extensions/*` are only read from the device dir, never from `depends/*`,
  hence the symlinks to `common/`. `pacman.conf` is also copied into the image (`/etc/pacman.conf`).
- `pre_build.sh` installs the recipe `pacman.conf` and `mirrorlist` in the builder container;
  `pacstrap` copies that mirrorlist into the image.
- Bootstrap: device + depends `bootstrap.list` via `pacstrap`, then `post_bootstrap` overlays, then
  `pacman -S` of all `package.list` files in an `arch-chroot`.
- `post_install` overlays: the device overlay is copied first, then each `depends` overlay, so a
  depends overlay overwrites a device file with the same path. Use drop-in files instead.
- `post_install.sh` runs `systemctl preset-all` and `locale-gen`, before subvolumes become read-only.

## Gotchas learned the hard way

- **Builder image age**: `build` rebuilds `arkdep-builder` (`--pull=always --no-cache`) when it is
  older than `BUILDER_MAX_AGE_DAYS` (7) or with `./build --rebuild-builder <recipe>`, and prints the
  arkdep version used (`Builder: arkdep <version>`). When debugging, read the code of that version,
  not upstream HEAD: a builder from 2026-02 had arkdep without the package.list fix below.
- **Every device recipe needs a `package.list`** (a comment is enough): arkdep-build releases before
  2026.06.10 silently skip the whole secondary stage, depends package lists included, without it.
  Always sanity check a new image: its `<name>.pkgs` file in the repo lists the installed packages
  (~520 for p14s; ~150 means only the bootstrap stage ran).

- **NoExtract and hardlinks**: pacman cannot create a hardlink whose target was excluded. This broke
  `glibc-locales` (shared `LC_*` files). Locales are now generated with `locale-gen` from
  `depends/generic/overlay/post_bootstrap/etc/locale.gen`; do not reintroduce `glibc-locales`.
  When adding a NoExtract rule, check the package for hardlinks (`bsdtar -tvf` shows `link to`).
- **NoExtract rules** live in `common/pacman.conf` (last matching pattern wins). They drop docs,
  non ca/es/en translations, headers (no compiler on host), unused JetBrains Mono Nerd variants and
  Intel platform firmware not used by any device. `i915` firmware must stay (T480).
- **TLP precedence**: `/etc/tlp.conf` is read after `/etc/tlp.d/*.conf` and overrides it, so the
  generic `tlp.conf` must not set device specific options. `CPU_SCALING_*_FREQ` values are in kHz.
- **systemd presets**: first match wins and `81-custom.preset` ends with `disable *`; device presets
  must sort before it (e.g. `80-t480.preset`).
- **Firmware**: never use the `linux-firmware` meta package; pick split packages per device. To find
  what a machine needs: `modinfo -F firmware` over `lsmod` and map files to packages with
  `pacman -Ql linux-firmware-*`.
- **Mirrors**: a single stalled mirror fails the whole transaction ("Operation too slow"); keep
  several servers in `common/mirrorlist`.
- **Migrated files keep numeric GIDs** (`cp -p`): e.g. `wg0.key` is `root:systemd-network` (977, a
  dynamic sysusers GID). If an image changes that GID, networkd cannot read the key.
- **Journal**: `/var/log/journal` is per deployment; capped with `SystemMaxUse=1G` in
  `depends/generic/.../journald.conf.d/50-size.conf` (default would be 4 GiB each).

## Verifying changes without building

- Resolve every package of a recipe against fresh repo databases (use bash; zsh does not word-split):
  `fakeroot pacman -Sy --dbpath <tmp> --config common/pacman.conf`, then
  `pacman -Sp --dbpath <tmp> --config common/pacman.conf <pkgs>`.
- The host's own sync databases come from the image build and are stale.
- Hardware info of other machines: `ssh roger@192.168.2.98` (T480, currently Artix, not arkdep yet).
