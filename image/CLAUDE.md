# arkdep images and recipes (`image/`)

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
- **Split boot entries** (arkdep 2026.08.17, arkanelinux/arkdep#53): a deploy can write the
  entry's title and the rest into two files a second apart. The menu then shows the deployment
  by its file name plus a title-only entry; the deployment boots fine. Fix by hand on the ESP
  (`sudo sed -i '1i title ...' <entry>` and remove the title-only file) if it bothers.
- **dracut modules left out** (`depends/generic/.../dracut.conf.d/20-omit-unused.conf`, both the
  arkdep and the bootc images): no LUKS (`crypt`, `systemd-cryptsetup`, `dm`, `fido2`, `pkcs11`),
  RAID, LVM, TPM measurements, `hwdb` or fsck in the initramfs. Encrypting a disk or using RAID,
  LVM or TPM-bound secrets needs their modules back there first, or the system will not find
  its root.
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
- **First userland setup** (`deploy-userland`, when the user manager starts: the first session
  after boot, SSH too, not every login): it takes minutes, and ending
  the session or rebooting meanwhile stops the box mid-setup. `distrobox assemble create` skips
  existing boxes, so such a box never got its exports (bootc T480 rehearsal, 2026-10-08):
  `deploy-userland` removes boxes without `/.containersetupdone` (checked with `podman unshare` +
  `podman mount`; written once the packages are installed, before the init hooks) before
  assembling, and the dotfiles' pre-init hook removes a leftover pacman lock. A failing init hook
  also left the T480's userland without exports: the dotfiles' hooks must not fail.
- **Lid and suspend** (`depends/generic/.../etc/systemd/logind.conf`): the lid suspends only on
  battery (`HandleLidSwitchExternalPower=ignore`): logind counts as docked only while an external
  display is connected, so turning off the P14s' monitors on the dock (lid closed) suspended it.
  `IdleAction=ignore`: logind's idle suspend (it was `suspend` after 15 min) never saw a sway
  session as idle (no idle hint) but did act with no session at all, at the login prompt or over
  SSH (the T480 on its charger, reached by SSH, suspended). swayidle locks after 10 min and, on
  battery only (`systemd-ac-power || systemctl suspend`), suspends after 15 min.
- **Secret Service** (sway layer, since 2026-10-08): `gnome-keyring` (11 MB with gcr and gcr-4;
  `oo7` has fewer dependencies but takes 25 MB and is 0.6), started by
  `gnome-keyring-daemon.socket` (user preset) and unlocked at the tty login by `pam_gnome_keyring`
  in `etc/pam.d/login` (overrides util-linux's file: keep it in line with it) and kept in sync on a
  password change by `etc/pam.d/passwd` (shadow's). Brave and VS Code run in the userland box and
  reach it on the host's session bus, but on sway they do not detect it: the dotfiles set
  `--password-store=gnome-libsecret` (`brave-flags.conf`, `~/.vscode/argv.json`) once the images
  have the keyring. Check with `secret-tool store --label=t a b` and `secret-tool lookup a b`.
  gcr-4 also brings `gcr-ssh-agent`, which sets `SSH_AUTH_SOCK` for the systemd user manager: the
  user preset disables it (and openssh's `ssh-agent.socket`), SSH keys are gpg-agent's. The user
  preset has no `disable *`, so every packaged user unit with an `[Install]` section is enabled.
- **Slow shutdown with containers**: rootless containers started outside systemd (VS Code
  devcontainers, distrobox) kept their conmon scopes alive until the 90 s stop timeout.
  `podman-stop-all.service` (user, sway layer) runs `podman stop --all` when the session ends, and
  `user.conf.d/50-stop-timeout.conf` caps any user unit or scope at 15 s.
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
  `unshare -r pacman -Sy --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf` (root in a
  user namespace, which `pacman -Sy` requires; the host's mirrorlists are the image's), then
  `pacman -Sp --dbpath <tmp> --config image/arkdep-build.d/common/pacman.conf <pkgs>`.
- The host's own sync databases come from the image build and are stale.
