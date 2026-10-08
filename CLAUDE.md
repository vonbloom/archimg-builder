# distro-builder

Everything that builds and distributes a CachyOS/Arch-based personal distro on
[arkdep](https://github.com/arkanelinux/arkdep): the immutable host images, the `[aur]` package
repository used by the `userland` distrobox, and the installer ISO. The user speaks Catalan; code,
comments and commit messages are in English (short, sentence-style subjects).

## Layout

```
image/    arkdep image recipes (arkdep-build.d/) and build, prune, notify-image
aur/      AUR packages (packages.list) and own PKGBUILDs (local/) built into the [aur] repository
iso/      installer ISO: Arch releng profile + arkdep + airootfs/root/install.sh; test-vm
serve/    nginx quadlet serving /mnt/repo (/<recipe>/, /aur/, /iso/) and the status page at /
          (web/index.html; status-gen writes /run/distro-status, served at /status/;
          build-trigger starts builds: POST /api/build/<unit>, polkit rule distro-trigger.rules);
          distro-registry.container: registry:2 on port 5000 (plain HTTP), storage /mnt/repo/registry
systemd/  build-image@.{service,timer}, build-bootc@.{service,timer}, build-aur.{service,timer}, build-iso.service,
          distro-status.{service,timer} (every minute), distro-trigger.{socket,service}
lib/      builder.sh (ensure_builder: rebuild a podman builder image when older than 7 days),
          sign.sh (detached GPG signatures with the server key, /etc/distro-builder/gnupg)
docs/     todo.md: pending improvements (boot time, storage, memory)
bootc/    the recipes as bootc images (trial, the T480): Containerfile, build-recipe.sh,
          build (chunkah + push to the registry), prune, install (from the ISO), overlay/; design
          and VM results in bootc/README.md
keys/     distro-builder.asc: public signing key, trusted by arkdep, pacman and the installer
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
- Scheduled builds: `build-image@<recipe>.timer` for the recipes in `ARKDEP_RECIPES` of `install`
  (default p14s; the T480 runs bootc while both are compared) (Sunday 08:00 Europe/Madrid,
  `Persistent=true`). The other recipes build by hand (`systemctl start`, status page). Builds run one at a time (`flock /run/build-image.lock`). After a successful
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
GPU driver in `dracut.conf.d/10-gpu.conf`, `tlp.d/50-<device>.conf`, presets, `/etc/hostname`) plus `name.sh`,
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
  as the pacman repository `[aur]` at `http://192.168.2.50/aur/` (`/mnt/repo/aur`), signed by
  `aur/build` after the container (packages and `aur.db`). Client: the `userland` distrobox
  (`~/.dotfiles/distrobox/.config/distrobox/pre_init_distrobox_assemble.sh`).
- `build-aur.timer`: daily 04:00 UTC + up to 30 min random delay, `Persistent=true`. Logs:
  `journalctl -u build-aur`. It takes `/run/build-image.lock` like the image builds: the bootc
  builds install bootc from `[aur]`, and the 8 GB VM cannot hold chunkah and a Rust compile at once
  (both started by hand on 2026-10-08: ~2 GB rustc next to `podman load`). Manual run: `sudo systemctl start build-aur` or `sudo aur/build`.
- `aur/build [--rebuild-builder] [repo_path]` rebuilds the `aur-builder` image when missing, older
  than 7 days or requested, then runs `aur-build.sh` in it. `aur-build.sh` and `makepkg.conf` are
  mounted from the checkout (the copies baked into the image are only a fallback), so changes to
  them apply on the next run. A local test run works rootless on any host: `aur/build /some/tmp/dir`.

### aur-build.sh

- `pacman -Syu` on every run, so an image a few days old never builds against stale libraries
  (the failure mode of the old LXC builder).
- `aur sync --no-view --noconfirm --auto-key-retrieve <list>`: builds new and outdated targets and
  their AUR dependencies, skips up-to-date ones. AUR PKGBUILD changes are not reviewed.
- Then `aur build --syncdeps` in a copy of each `local/<pkgname>/` (mounted at `/local`). aur build
  skips a package whose file for that version is already in the repository: local packages only
  change when their `pkgver`/`pkgrel` does (pinned on purpose, e.g. `bootc`). The directory name
  must be the package name (it counts as wanted in the cleanup below), and its AUR dependencies, if
  any, must be in `packages.list`.
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

## bootc images (`bootc/`)

- `build-bootc@<recipe>`: `bootc/build` (podman build `--pull=always --no-cache --no-hostname`,
  package list to `/mnt/repo/bootc/<recipe>/<recipe>-<date>.pkgs`, chunkah rechunk piped into
  `podman load`, push `<recipe>:<date>` and `:latest` to `localhost:5000`, then remove the local
  images: the server has little disk), then `bootc/prune` and `image/notify-image` with
  `REPO_PATH=/mnt/repo/bootc/<recipe> KIND=bootc`. Weekly, Sunday 13:00 Europe/Madrid.
- Build and prune run under `/run/build-image.lock` with the other builds: memory, and the
  registry's `garbage-collect` must never run during a push (it deletes blobs of unfinished
  uploads). prune deletes manifests through the API (`REGISTRY_STORAGE_DELETE_ENABLED`), runs
  `registry garbage-collect --delete-untagged` in the `distro-registry` container and then restarts
  it: registry:2 caches blob descriptors in memory, and without the restart a later push skipped
  uploading a blob the collection had deleted (a broken image, seen in a test). That restart is why
  `build-bootc@` has `Wants=distro-registry.service`, not `Requires=` (a restart of a required unit
  stops the requiring one, prune included).
- `bootc` comes from `[aur]` (`aur/local/bootc`, without the `selinux` feature, which links
  libselinux), signed: the build trusts `keys/distro-builder.asc` and adds `[aur]` only for that
  `pacman -S`. Local test runs: `REGISTRY=127.0.0.1:5000 PKGS_DIR=... AUR_SERVER=... AUR_SIGLEVEL=Never`.
- `bootc/overlay/` holds files only bootc images need: the registry as insecure in
  `registries.conf.d`, and `@{HOMEDIRS}+=/var/home/` for AppArmor (`/home` links to `/var/home`).
- No image signing yet (cosign + `policy.json` on the clients), see `bootc/README.md`.
- Updates on bootc systems: `bootc-update.timer` (`bootc/overlay`, enabled by `80-bootc.preset` in
  `build-recipe.sh`'s `preset-all`) runs `bootc-update`:
  `bootc upgrade` (stage only) and `/run/bootc-update/staged` (recipe, version, package list URL)
  for the waybar indicator. The version is the `org.opencontainers.image.version` label set by
  `bootc/build` (the date tag). `bootc-fetch-apply-updates.timer` stays disabled: it reboots by
  itself and only runs on ostree boots (`/run/ostree-booted`).
- `arkdep-update-status` (sway layer) serves both: arkdep when `/arkdep/config` exists, bootc
  otherwise.
- `build-recipe.sh` copies the overlays (the recipe's, then `bootc/overlay`) like arkdep-build's
  `cp -r`: `tar --no-same-owner --no-same-permissions` into a staging directory, then `cp -r` to `/`
  (existing files and directories keep owner and mode). Plain `tar -xp` kept the checkout's UID
  1000 and 775 modes, also on existing dirs (`/usr`, `/usr/lib`, `/etc/systemd`): sudo ignored
  `sudoers.d` and iwd failed on D-Bus. `COPY` gave existing dirs the checkout's 775 (server umask
  0002), and tar replaced existing files with the overlay's mode (libvirt's 600 `default.xml` became
  644). Check new images with `find / -xdev -uid 1000` and `pacman -Qkk | grep mismatch` (normal:
  `utempter`, `/var/...`).
- bootc mounts the ESP read-only at `/boot` (`systemd.mount-extra=...:/boot:auto:ro`), so
  `systemd-boot-random-seed.service` is masked in `bootc/overlay` (systemd-boot refreshes the seed).
- `bootc/install` (live ISO): podman storage on a tmpfs (overlay cannot sit on the live overlayfs
  root), `wipefs` + `mount -t btrfs` (udev's cached probe still says ext4), the target at
  `/target` in the container (`/mnt` links to `var/mnt` in a bootc image), user/hostname/Wi-Fi
  written to `/state/deploy/<id>/etc` and `/state/os/default/var` (`useradd --prefix`), and an
  `efibootmgr` entry (bootc only installs the `EFI/BOOT` fallback). It deletes the ESP's
  `bootc_*.conf` entries (and `EFI/Linux/bootc_composefs-*`) whose root is the reformatted
  partition or gone: they share title and sort key with the new one and the version is a hash, so
  systemd-boot booted a stale one in a rehearsal. It writes `loader.conf` like the arkdep
  installer: bootc only writes `timeout 5` when the file is missing, and `bootctl install` has
  just created it with every line commented out (no menu). Rehearsed in a VM booted from the ISO
  with a T480-like layout (2026-10-08).
- Boot entry titles: bootc uses `PRETTY_NAME` and `VERSION_ID` of the image's `/usr/lib/os-release`;
  the Containerfile sets them to `Arch Linux (<recipe> <tag>)` and `<tag>.<HHMM>` (`VERSION` and
  `VERSION_ID` build args from `bootc/build`; systemd-boot appends the version to equal titles, two
  builds of a day), and links `/etc/os-release` to it (the Arch container image ships its own
  copy).

## Installer ISO (`iso/`)

- `sudo iso/build [output_dir]` builds `iso-builder` (from `arkdep-builder`, which already trusts
  the arkane key, plus `archiso`) and runs `mkarchiso` on Arch's `releng` profile with `arkdep`
  (from `[arkane]`) added and `iso/airootfs/` copied over. The ISO goes to `/mnt/repo/iso/`
  (`http://192.168.2.50/iso/`, with `sha256sums.txt` and its signature); older ISOs are deleted. Run through
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
- **btrfs scrub**: `btrfs-scrub@-.timer` (monthly, from `btrfs-progs`, enabled in `81-custom.preset`)
  scrubs the whole filesystem; on a single device it detects corruption but can only repair
  metadata (DUP).
- **Journal**: `/var/log/journal` is per deployment; capped with `SystemMaxUse=1G` in
  `depends/generic/.../journald.conf.d/50-size.conf` (default would be 4 GiB each).
- **Menus**: every system menu is a rofi script in `depends/sway/.../usr/local/bin` (e.g.
  `power-menu`, bound to `$mod+Shift+e` and the waybar power button), using the system theme
  (`/etc/rofi.rasi`). Do not add GTK menus (waybar `menu-file`) or swaynag dialogs.
  `keys-menu` (`$mod+F1`) lists the `bindsym` lines of the running sway config: when adding a
  binding with a new kind of command, add its Catalan description to `describe()` there
  (otherwise the raw command is shown).
- **Light/dark mode**: `darkman` (started by `sway-session.target`, location in
  `/etc/xdg/darkman/config.yaml`) runs `/usr/share/darkman/desktop-theme light|dark` at sunrise
  and sunset (`darkman toggle`: `$mod+Shift+t`, power menu). It sets gsettings `color-scheme`
  (apps through xdg-desktop-portal-gtk), `gtk-theme` (`adw-gtk3[-dark]`; icons stay Adwaita),
  the rofi theme (`~/.local/share/rofi/themes/current.rasi`), the mako mode
  `light` and the wallpaper folder (`pickwall`: `~/.local/share/wallpapers/{dia,nit}`). Waybar,
  foot and VS Code (no `window.autoDetectColorScheme` in the dotfiles) stay dark on purpose. New
  themed components belong in that hook.
- **Memory tuning** (`depends/generic`) is a hand-picked subset of `cachyos-settings` (the package
  itself is not installed: it pulls `ananicy-cpp` and gaming/NVIDIA tweaks): `sysctl.d/99-optimizations.conf`,
  zram as big as RAM, `udev/rules.d/30-zram.rules` (zswap off once zram is up) and
  `tmpfiles.d/thp.conf`. Compare with the current package (`pacman -Sp cachyos-settings`) when
  revisiting it. Its `systemd-oomd` slice defaults are left out on purpose: oomd kills whole leaf
  cgroups, and the `userland` distrobox is a single podman scope holding Brave, VS Code and the
  terminals, so it would be the likely victim when dev containers exhaust memory.
- **btrfs mount options**: compression (and other filesystem-wide options) is taken from the
  first mount only, the root from `rootflags=` in the boot template. `compress=` in fstab is
  ignored: until 2026-10-07 the laptop had `compress=zstd` in fstab and no compression at all.
  Both `iso/airootfs/root/systemd-boot.template` and fstab use `compress=zstd:1,noatime`;
  `noatime` is per mount point, so it does belong in fstab.
- **Podman storage** (`podman-cleanup.timer`, user, monthly, sway layer): removes images unused
  by any container for 30 days and old VS Code server versions in the dev containers' shared
  `vscode` volume (VS Code adds one per update and never removes them: 10 versions, 6 GB in
  2026-10), and all but the highest version of each extension download in its `extensionsCache`
  (`sort -V`, `.sigzip` signatures go with their package; an age limit kept nearly everything:
  some extensions publish daily, 8 GB in a month). It never removes containers or volumes. After a VS Code update, windows of several
  dev containers restored at once race to install the new server into that shared volume: the
  losers fail (`mv -n ...` then `rmdir: ... Directory not empty`), "Reload Window" fixes them (the
  server is installed by then). Accepted (2026-10-08): `dev.containers.cacheVolume: false` (a
  server per container) or `window.restoreWindows: one` would avoid it at a permanent cost.
- **First userland setup** (`deploy-userland`, at any login, SSH too): it takes minutes, and ending
  the session or rebooting meanwhile stops the box mid-setup. `distrobox assemble create` skips
  existing boxes, so such a box never got its exports (bootc T480 rehearsal, 2026-10-08):
  `deploy-userland` removes boxes without `/.containersetupdone` (checked with `podman unshare` +
  `podman mount`) before assembling, and the dotfiles' pre-init hook removes a leftover pacman lock.
- **Slow shutdown with containers**: rootless containers started outside systemd (VS Code
  devcontainers, distrobox) kept their conmon scopes alive until the 90 s stop timeout.
  `podman-stop-all.service` (user, sway layer) runs `podman stop --all` when the session ends, and
  `user.conf.d/50-stop-timeout.conf` caps any user unit or scope at 15 s.
- **Signatures**: images, `[aur]` and ISO checksums are signed outside the builder containers
  (`lib/sign.sh`; the key never enters a container, which runs unreviewed AUR code). Anything
  that deletes published files must delete their `.sig` too (`prune`, `aur/build` cleans orphan
  package signatures). `sign_stale` also re-signs a file newer than its signature: a second build
  of an image on the same day replaces `<recipe>-<date>.tar.zst` under the same name, and the
  kept signature made arkdep reject it ("BAD signature", p14s-2026-10-07). The installer copies `keys/distro-builder.asc` (built into the ISO through
  `--build-context keys=../keys`) to `/arkdep/keys/trusted-keys`.
- **Waybar icons**: the font is JetBrainsMono Nerd Font, which lacks Font Awesome 5/6 codepoints
  (e.g. `U+F590`, `U+F769`): use Nerd Font glyphs (`md-*`) and check new ones with
  `fc-list ":charset=<hex>"`.
- **Waybar config**: module settings and the layout live in `/etc/xdg/waybar/bar.jsonc`;
  `config.jsonc` only lists the bars per output and includes it. The external monitors' bar
  overrides `modules-right` without `backlight` (keys in the including bar win), so add or remove
  right-side modules in both lists. Test a change with `waybar -c <copy>/config.jsonc` (rewrite the
  absolute include path to the copy).

## Verifying changes without building

- Resolve every package of a recipe against fresh repo databases (use bash; zsh does not word-split):
  `fakeroot pacman -Sy --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf`, then
  `pacman -Sp --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf <pkgs>`.
- The host's own sync databases come from the image build and are stale.
- Hardware info of other machines: `ssh roger@192.168.2.98` (T480, currently Artix, not arkdep yet).
