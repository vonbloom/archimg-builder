# distro-builder

Everything that builds and distributes a CachyOS/Arch-based personal distro on
[arkdep](https://github.com/arkanelinux/arkdep): the immutable host images, the `[aur]` package
repository used by the `userland` distrobox, and the installer ISO. The user speaks Catalan; code,
comments and commit messages are in English (short, sentence-style subjects).

## Layout

```
image/    arkdep image recipes (arkdep-build.d/) and build, prune, notify-image
aur/      AUR packages (packages.list) built into the [aur] repository
iso/      installer ISO: Arch releng profile + arkdep + airootfs/root/install.sh; test-vm
serve/    nginx quadlet serving /mnt/repo (/<recipe>/, /aur/, /iso/) and the status page at /
          (web/index.html; status-gen writes /run/distro-status, served at /status/;
          build-trigger starts builds: POST /api/build/<unit>, polkit rule distro-trigger.rules)
systemd/  build-image@.{service,timer}, build-aur.{service,timer}, build-iso.service,
          distro-status.{service,timer} (every minute), distro-trigger.{socket,service}
lib/      builder.sh (ensure_builder: rebuild a podman builder image when older than 7 days)
install   links the units and the quadlet, installs the polkit rule, enables the timers (also
          podman-auto-update) and the trigger socket (run as root; rerun after changing systemd/, serve/)
```

All builds run on the server `192.168.2.50` (Debian, rootful podman via `sudo`, checkout
`/home/admin/distro-builder`), never on the laptops. `/mnt/repo` there is NFS from zeus
(`192.168.2.10`). Each build unit runs `git pull --ff-only` (as `admin`, non-fatal) first, so
pushing is enough; changes to `systemd/` also need `systemctl daemon-reload`. A failed build triggers `notify-failure@` (Home Assistant push); both
`notify-ha` and that unit come from the homelab repo (role `notify_ha`).

User-facing documentation (setup, usage of each tool, installer steps) is in `README.md`: keep
it in sync when changing behaviour.

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

## Images (`image/`)

- `image/build [--rebuild-builder] <recipe>` builds the `arkdep-builder` podman image (when missing
  or older than 7 days; arkdep from `arkanelinux/pkgbuild`) and runs `arkdep-build.sh` inside it,
  writing to `/mnt/repo/<recipe>`.
- Scheduled builds: `build-image@<recipe>.timer` for p14s and t480 (Sunday 08:00 Europe/Madrid,
  `Persistent=true`). Builds run one at a time (`flock /run/build-image.lock`). After a successful
  build, `prune <recipe>` thins out old images (keep the newest 4 plus the newest of each of the 3
  previous months; `prune --dry-run <recipe>` shows the plan) and `notify-image` sends "New image
  ..." with the package changes to Home Assistant. Logs: `journalctl -u build-image@<recipe>`.
- `serve/distro-repo.container` (nginx quadlet) serves `/mnt/repo` at
  `http://192.168.2.50/<recipe>/` (`database` file + `<name>.tar.zst`).
- An image `.tar.zst` contains btrfs send streams (`<name>-rootfs.img`, `-etc.img`, `-var.img`) and
  `<name>-update.sh`. Inspect without root:
  `curl -s URL | zstd -dc | tar -xOf - ./<name>-rootfs.img | btrfs receive --dump`
  (paths appear as `rename ... dest=./rootfs/<path>`).

## Recipe layout (`image/arkdep-build.d/`)

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

## AUR repository (`aur/`)

- Builds the AUR packages in `aur/packages.list` in a throwaway podman container and publishes them
  as the pacman repository `[aur]` at `http://192.168.2.50/aur/` (`/mnt/repo/aur`), unsigned
  (`SigLevel = Optional TrustAll` on clients). Client: the `userland` distrobox
  (`~/.dotfiles/distrobox/.config/distrobox/pre_init_distrobox_assemble.sh`).
- `build-aur.timer`: daily 04:00 UTC + up to 30 min random delay, `Persistent=true`. Logs:
  `journalctl -u build-aur`. Manual run: `sudo systemctl start build-aur` or `sudo aur/build`.
- `aur/build [--rebuild-builder] [repo_path]` rebuilds the `aur-builder` image when missing, older
  than 7 days or requested, then runs `aur-build.sh` in it. A local test run works rootless on any
  host: `aur/build /some/tmp/dir`.

### aur-build.sh

- `pacman -Syu` on every run, so an image a few days old never builds against stale libraries
  (the failure mode of the old LXC builder).
- `aur sync --no-view --noconfirm --auto-key-retrieve <list>`: builds new and outdated targets and
  their AUR dependencies, skips up-to-date ones. AUR PKGBUILD changes are not reviewed.
- Packages no longer listed nor needed as AUR dependencies (`aur depends`) are `repo-remove`d and
  their files deleted; `paccache -rk2` keeps the last two versions of each package.
- `makepkg.conf` (`/etc/makepkg.conf.d/`) disables `-debug` packages.
- A failure in any step stops the run (the unit fails); packages built before it stay published.

### Gotchas

- `aur-repo-filter` reads `/dev/tty` unless `unbuffer` (package `expect`) is installed; without a
  terminal (systemd) the check for official packages providing an AUR target silently fails.
- `aur depends` default output is dependency pairs; use `--jsonl` + `aur format -f '%n\n'` for names.
- "Failed to connect to udev via varlink" / "command failed to execute correctly" while installing
  dependencies is the udev pacman hook inside the container: harmless.

## Installer ISO (`iso/`)

- `sudo iso/build [output_dir]` builds `iso-builder` (from `arkdep-builder`, which already trusts
  the arkane key, plus `archiso`) and runs `mkarchiso` on Arch's `releng` profile with `arkdep`
  (from `[arkane]`) added and `iso/airootfs/` copied over. The ISO goes to `/mnt/repo/iso/`
  (`http://192.168.2.50/iso/`, with `sha256sums.txt`); older ISOs are deleted. Run through
  `build-iso.service` (pull + `flock /run/build-image.lock`). No timer: rebuild it when the
  installer changes or the live system gets too old.
- The ISO contains no image: `/root/install.sh` deploys the newest image of a recipe straight from
  the repository, so it needs the LAN (Wi-Fi through `iwctl` if there is no cable), not the
  internet. Steps: recipe (from the DMI model: `20Y1` p14s, `20L5`/`20L6` t480, otherwise a menu of
  the recipes in `/status/recipes.txt`), disk, password, then GPT with a 1G ESP (`EFI`) and btrfs `ROOT`,
  `/swap/swapfile` sized to RAM (hibernation `resume=` options), `ARKDEP_ROOT=/mnt arkdep init` +
  `arkdep deploy <recipe>`, systemd-boot, user `roger` and fstab in the new deployment.
- `iso/airootfs/root/arkdep.config` is the canonical `/arkdep/config` for new installs: keep it in
  sync with the laptops' `/arkdep/config` (`repo_url`, `deploy_keep`, `migrate_files`).
- `iso/airootfs/root/systemd-boot.template` is the canonical boot entry template
  (`/arkdep/templates/systemd-boot`: title, kernel options); `install.sh` only fills in
  `@ROOT_LABEL@` and `@RESUME@` (swap UUID and offset). Installed laptops keep their own copy in
  `/arkdep/templates/`: a change here only reaches new installs.
- `iso/test-vm iso|disk|clean` boots the published ISO or the installed disk in a throwaway
  QEMU/OVMF VM (VNC `localhost:5901`; on sway use `remote-viewer`, which can inhibit the
  compositor shortcuts, not TigerVNC).
- Group lines for the user are taken from the image's `/usr/lib/group`, so the GIDs always match
  the image (copying them from another system breaks dynamic GIDs such as `libvirt`).

## Gotchas learned the hard way (images)

- **Builder image age**: `image/build` rebuilds `arkdep-builder` (`--pull=always --no-cache`) when it is
  older than `BUILDER_MAX_AGE_DAYS` (7) or with `image/build --rebuild-builder <recipe>`, and prints the
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
- **Menus**: every system menu is a rofi script in `depends/sway/.../usr/local/bin` (e.g.
  `power-menu`, bound to `$mod+Shift+e` and the waybar power button), using the system theme
  (`/etc/rofi.rasi`). Do not add GTK menus (waybar `menu-file`) or swaynag dialogs.
- **Waybar icons**: the font is JetBrainsMono Nerd Font, which lacks Font Awesome 5/6 codepoints
  (e.g. `U+F590`, `U+F769`): use Nerd Font glyphs (`md-*`) and check new ones with
  `fc-list ":charset=<hex>"`.

## Verifying changes without building

- Resolve every package of a recipe against fresh repo databases (use bash; zsh does not word-split):
  `fakeroot pacman -Sy --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf`, then
  `pacman -Sp --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf <pkgs>`.
- The host's own sync databases come from the image build and are stale.
- Hardware info of other machines: `ssh roger@192.168.2.98` (T480, currently Artix, not arkdep yet).
