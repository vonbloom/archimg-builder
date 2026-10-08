# distro-builder

Build and distribution tooling for a personal, immutable CachyOS/Arch-based distro on
[arkdep](https://github.com/arkanelinux/arkdep). The root filesystem of each laptop is a read-only
btrfs image built here; interactive software lives in a distrobox (`userland`) fed by a small
repository of prebuilt AUR packages, also built here. An installer ISO puts the whole thing on a
new machine.

| Tool | What it produces | Where it is published | When |
|---|---|---|---|
| [`image/`](#images-image) | arkdep images, one per device recipe | `http://192.168.2.50/<recipe>/` | weekly (Sunday 08:00 Europe/Madrid) |
| [`bootc/`](#bootc-images-bootc) | bootc images of the same recipes (trial, not deployed yet) | registry `192.168.2.50:5000/<recipe>` | weekly (Sunday 13:00 Europe/Madrid) |
| [`aur/`](#aur-repository-aur) | the pacman repository `[aur]` | `http://192.168.2.50/aur/` | daily (04:00 UTC) |
| [`iso/`](#installer-iso-iso) | the installer ISO | `http://192.168.2.50/iso/` | by hand |

```
image/    recipes (arkdep-build.d/), build, prune, notify-image
bootc/    Containerfile and build-recipe.sh (the recipes as bootc images), build, prune, overlay/
aur/      packages.list, local/ (own PKGBUILDs), aur-build.sh, build
iso/      installer ISO: Containerfile, build, test-vm, airootfs/ (install.sh, arkdep.config)
serve/    web server (nginx quadlet): /mnt/repo and the status page (web/, status-gen, build-trigger);
          container registry (quadlet) for the bootc images
systemd/  build units and timers, distro-status (page data), distro-trigger (manual builds)
lib/      builder.sh, shared by the build scripts
install   sets up the build server
```

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

### Web server

`serve/distro-repo.container` runs `nginx:alpine` on port 80 (a podman quadlet, so systemd runs it
as `distro-repo.service`) with `/mnt/repo` as its document root and directory listings on. It is
kept up to date by `podman-auto-update.timer` (daily: pulls a new `nginx:alpine` and restarts the
service, rolling back if it does not start):

```
/mnt/repo/
├── p14s/   database, p14s-YYYY-MM-DD.tar.zst(.sig), p14s-YYYY-MM-DD.pkgs
├── t480/   ...
├── aur/    aur.db(.sig), *.pkg.tar.zst(.sig)
└── iso/    distro-installer-YYYY.MM.DD-x86_64.iso, sha256sums.txt(.sig)
```

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
- the `[aur]` clients: `pacman-key --add` + `--lsign-key` (see below).

### Status page

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

### Notifications

Every unit has `OnFailure=notify-failure@%n.service`, so a failed build sends a `[FAILED]` push to
Home Assistant with the end of its journal. A successful image build sends "New image ..." (tag
`image-<recipe>`) with its package count, kernel and the changes since the previous image; it is
sent as a warning when the package count drops by more than 20 % (see
[Images](#sanity-check)). A bootc image build sends the same as "New bootc image ..." (tag
`bootc-<recipe>`).

## Images (`image/`)

arkdep images of the host OS. An image is a `.tar.zst` with btrfs send streams of the read-only
root filesystem and of `/etc` and `/var`, plus an update script. Laptops pull them with
`arkdep deploy` and boot the new deployment; the previous one stays as a fallback.

### Recipes

```
image/arkdep-build.d/
├── common/           pacman.conf (CachyOS x86_64_v3 + Arch + arkane, NoExtract rules), mirrorlist,
│                     extensions/{pre_build,post_install}.sh
├── depends/generic/  base system: bootstrap.list, package.list, overlay/{post_bootstrap,post_install}
├── depends/sway/     desktop: sway, waybar, foot, rofi, mako, darkman (light/dark), user units
├── p14s/             ThinkPad P14s Gen 1 AMD (Ryzen 7 PRO 4750U)
└── t480/             ThinkPad T480 (i7-8650U)
```

A device recipe holds only what is specific to the hardware (CPU microcode, `linux-firmware-*`
split packages, GPU driver for dracut, TLP and systemd presets) plus:

- `name.sh`: prints the image name, `<recipe>-YYYY-MM-DD` (UTC date of the build);
- `type`: `archlinux`;
- `depends.list`: the shared layers it is built on (`depends/generic`, `depends/sway`);
- `bootstrap.list`, `package.list` (required, even if it only holds a comment);
- `overlay/post_install/`: files copied into the image;
- symlinks `pacman.conf`, `mirrorlist`, `extensions` -> `../common/`.

To add a device, copy a recipe, adjust the hardware parts, add it to `install` (or run
`sudo ./install <recipes...>`) and to the model detection in `iso/airootfs/root/install.sh`.
`CLAUDE.md` documents how `arkdep-build` processes a recipe and the pitfalls already hit.

### Building

```sh
sudo systemctl start build-image@p14s        # same as the timer: build, prune, notify
sudo image/build [--rebuild-builder] p14s    # build only
journalctl -fu build-image@p14s
```

`image/build` runs `arkdep-build` in the `arkdep-builder` image (arkdep and the arkane keyring
built from `arkanelinux/pkgbuild`) and writes to `/mnt/repo/<recipe>`, then rewrites the
`database` file (newest first). Builds started together by both timers run one after the other
(`flock`). A failed build leaves the repository untouched.

### Retention

After each successful build, `image/prune <recipe>` keeps the newest 4 images (a month of weekly
builds) plus the newest image of each of the 3 previous months, and deletes the rest from disk and
from `database`. `KEEP_RECENT` and `KEEP_MONTHLY` override the numbers;
`image/prune --dry-run <recipe>` shows what would be kept and deleted.

### Sanity check

Each image has a `<name>.pkgs` file with its installed packages (about 520 for p14s). An image
with far fewer packages (about 150) means `arkdep-build` skipped the package stage; `notify-image`
flags it.

### On the laptops

`/arkdep/config` points to the server (`repo_url='http://192.168.2.50'`,
`repo_default_image='<recipe>'`), so updating is:

```sh
sudo arkdep deploy        # newest image of the default recipe; reboot into it
arkdep-diff               # after rebooting: package changes against the previous deployment
```

The waybar module `custom/arkdep` (script `arkdep-update-status`, in the sway layer) checks the
repository every hour: it shows 󰏔 and the number of new or updated packages when a newer image
is available (click it to deploy in a terminal), 󰜉 when the newest image is deployed but not
booted yet, and nothing when the system is up to date or the server is unreachable. It refreshes
by itself after any deploy (`arkdep-update-status.path` watches the boot entries); to check right
away after a build, run `arkdep-update-status refresh`.

## AUR repository (`aur/`)

Prebuilt AUR packages for the `userland` distrobox, published as the pacman repository `[aur]`.

- List the packages in `aur/packages.list`, one per line. AUR dependencies are built
  automatically; packages removed from the list (and no longer needed as dependencies) are removed
  from the repository on the next run. The last two versions of each package are kept.
- `aur/build [--rebuild-builder] [repo_path]` runs `aurutils` (`aur sync`) in the `aur-builder`
  image after a full `pacman -Syu`, so packages always build against current libraries. The
  default repository path is `/mnt/repo/aur`; a test run works rootless anywhere:
  `aur/build /tmp/aur-test`.
- Own PKGBUILDs go in `aur/local/<pkgname>/PKGBUILD`, for packages the AUR lacks or builds
  differently (e.g. `bootc`, built without SELinux support). Do not list them in `packages.list`.
  A local package is only built when its version (`pkgver`, `pkgrel`) is not in the repository
  yet: a new upstream version is published by bumping it there, and a version that fails to build
  leaves the previous one in place. After each run `aur/check-upstream` compares them with the
  latest GitHub release of their `url=` and sends a Home Assistant notification, once per version,
  when a newer one is out (`NOTIFY=echo STATE_DIR=/tmp/x aur/check-upstream` to try it).
  `aur/bump-local <pkg> [version]` then moves the PKGBUILD to that release (default: the latest):
  `pkgver`, `pkgrel=1` and `sha256sums` from the digest GitHub publishes for the source file
  (downloaded and hashed when there is none); review the diff, commit, push and start `build-aur`.
- Scheduled daily by `build-aur.timer`; run it now with `sudo systemctl start build-aur` and
  follow it with `journalctl -fu build-aur`.
- PKGBUILD changes are not reviewed: only list packages you trust.

Packages and database are signed ([Signatures](#signatures)). Clients trust the key and add the
repository after Arch's repositories (the dotfiles repo does this for the distroboxes, in
`pre_init_distrobox_assemble.sh`):

```sh
pacman-key --add keys/distro-builder.asc
pacman-key --lsign-key CF471E6685974BF43EA113623F9EBD77B1E60E55
```

```ini
[aur]
SigLevel = Required
Server = http://192.168.2.50/aur
```

## bootc images (`bootc/`)

The same recipes as [bootc](https://github.com/bootc-dev/bootc) container images, a trial of
bootc as a replacement for arkdep: while both are compared, the T480 runs bootc and the P14s stays
on arkdep. `bootc/README.md` has the design and the results of the tests in a VM.

- `bootc/build <recipe>` builds `bootc/Containerfile` (which applies the arkdep recipe with
  `build-recipe.sh` and installs `bootc` from `[aur]`), splits the image into per-package layers
  with [chunkah](https://github.com/coreos/chunkah) and pushes it to the registry as
  `<recipe>:YYYY-MM-DD` and `<recipe>:latest`. The package list goes to `/mnt/repo/bootc/<recipe>/`
  for the notification.
- `bootc/prune <recipe>` keeps the newest 4 dated images (`KEEP`) and garbage-collects the
  registry. Both run under the same lock as the arkdep builds, one at a time.
- Scheduled weekly by `build-bootc@<recipe>.timer` for the recipes in `BOOTC_RECIPES` of
  `install` (default `t480`); run it now, for any recipe, with
  `sudo systemctl start build-bootc@p14s` and follow it with `journalctl -fu build-bootc@p14s`.
- On a bootc system `bootc-update.timer` (after boot and every 4 hours, skipped away from home)
  downloads and stages the newest image of its tag; it starts on the next boot. The waybar
  indicator (`arkdep-update-status`, same module as arkdep's) shows a staged image with its package
  changes; a click (or `sudo bootc-update`) looks for a newer one now.
- The registry (`serve/distro-registry.container`, `registry:2`, storage in `/mnt/repo/registry`)
  serves plain HTTP on port 5000; the images list it as insecure in
  `/etc/containers/registries.conf.d/50-distro-builder.conf`. A bootc system follows a recipe with
  `bootc switch 192.168.2.50:5000/<recipe>:latest` and updates with `bootc upgrade`.
- `bootc/install` installs an image on existing partitions from the installer ISO, keeping a
  `/home` partition: see below.

### Installing a bootc image (keeping /home)

`bootc/install` formats the root partition (btrfs, `zstd:1`, `noatime`), reuses the ESP
(systemd-boot, first in the firmware boot order, a 5 s menu; other loaders stay), keeps the `/home`
partition untouched (mounted at `/var/home`), enables a swap partition for hibernation, and creates
the user (UID 1000, the arkdep installer's groups), the hostname and the Wi-Fi profile. Written for
the T480 (Artix: ESP `p1`, swap `p2`, root `p3`, ext4 home `p4`) and rehearsed in a VM with the same
layout.

Before, on the old system:

1. Back up what cannot be lost: the root partition is formatted (the home partition is not, but a
   wrong partition name would be).
2. The user's directory on the home partition must belong to UID 1000 (`--uid` otherwise).
3. Copy the Wi-Fi profile into it (iwd keeps it in a root-only directory):
   `sudo install -m 600 -o roger -g roger /var/lib/iwd/<SSID>.psk ~/`.
4. Note the partitions: `lsblk -f`.

Install:

1. Download the installer ISO, check its signature and write it to a USB stick (the whole device,
   e.g. `/dev/sda`, not a partition: `TRAN` says `usb`; everything on it is lost):

   ```sh
   curl -O http://192.168.2.50/iso/sha256sums.txt -O http://192.168.2.50/iso/sha256sums.txt.sig
   iso=$(awk '{ print $2 }' sha256sums.txt); curl -O "http://192.168.2.50/iso/$iso"
   gpg --dearmor < ~/distro-builder/keys/distro-builder.asc > distro-builder.gpg
   gpgv --keyring ./distro-builder.gpg sha256sums.txt.sig sha256sums.txt && sha256sum -c sha256sums.txt
   lsblk -d -o NAME,SIZE,TRAN,MODEL
   sudo dd if="$iso" of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
   ```

   Boot it in UEFI mode (ThinkPad: F12). At the boot menu press `e` and add `cow_spacesize=2G` to
   the kernel options: the live system installs podman (the image goes to a tmpfs, ~5 GB of RAM).
2. Network: a cable, or `iwctl station wlan0 connect <SSID>`.
3. Download and run the installer (it lists the disk, asks to type the root partition to confirm,
   and asks the user's password twice):

   ```sh
   curl -O https://raw.githubusercontent.com/vonbloom/distro-builder/main/bootc/install
   bash install --image 192.168.2.50:5000/t480:latest --root /dev/nvme0n1p3 --esp /dev/nvme0n1p1 \
       --home /dev/nvme0n1p4 --swap /dev/nvme0n1p2 --hostname anubis --wifi <SSID>.psk
   ```

   It stops before formatting anything if a partition, the user's directory or the Wi-Fi file is
   wrong, and can be run again after a failure.
4. Reboot and remove the USB stick.

First session:

1. Log in on tty1: sway starts.
2. If the home partition has an older `~/.dotfiles` checkout, update it (`git stash` local changes
   first) and restow: `cd ~/.dotfiles && git pull && ./install`. `deploy-userland` only clones the
   dotfiles when `~/.dotfiles` is missing, and only creates the distroboxes from
   `~/.config/distrobox/default.ini`.
3. `systemctl --user start deploy-userland` creates `playground` and `userland` and exports the
   apps. It runs by itself when the user manager starts (the first session after boot, SSH too),
   which on a home with older dotfiles happened before step 2. It takes minutes: do not log out or reboot until the
   "Sistema a punt" notification (an interrupted box is created again at the next login).
4. Check: `sudo bootc status` (the image and its tag), `systemctl --failed`.
5. A home from another system can hold user configs that win over the image's: move them aside
   (the T480's Artix home had `~/.config/rofi/config.rasi` with its own theme, GTK 3/4
   `settings.ini` and `gtk.css`, a full `~/.config/pipewire/pipewire.conf` and links to old
   dotfiles). Compare `ls ~/.config` with the P14s, which has none of them.

Afterwards, updates are staged by `bootc-update.timer` and shown by the waybar indicator (see
above), and start on the next boot. The boot menu lists each image as `Arch Linux (<recipe> <tag>)`
with the previous one as a fallback; `sudo bootc rollback` makes the previous one the default.

## Installer ISO (`iso/`)

A live Arch ISO (Arch's `releng` profile) with `arkdep` added and an installer that deploys the
newest image straight from the repository. The ISO does not contain an image, so it stays small
(~1.6 GB) and never installs an outdated system; it does need the LAN (cable, or Wi-Fi joined
from the installer). Nothing is downloaded from the Arch mirrors during the installation.

### Building

```sh
sudo systemctl start --no-block build-iso   # on the build server, or Executa on the status page
journalctl -fu build-iso
```

`iso/build [output_dir]` builds `iso-builder` on top of `arkdep-builder` (which already trusts the
arkane signing key) with `archiso`, runs `mkarchiso` and moves the ISO to `/mnt/repo/iso/`
(default), replacing the previous one and writing `sha256sums.txt`. `build-iso.service` runs it
after pulling the checkout, one build at a time with the images. There is no timer: rebuild it
when the installer changes or when the live system is too old for new hardware.

### Installing a machine

1. Download the ISO, `sha256sums.txt` and `sha256sums.txt.sig` from `http://192.168.2.50/iso/`,
   check them and write the ISO to a USB stick (the commands are in step 1 of "Installing a bootc
   image" above; `gpgv` cannot read the keyring from a pipe such as `<(gpg --dearmor ...)`). The installed system verifies
   every image with the same key.
2. Boot it in UEFI mode (Secure Boot off) and run `/root/install.sh`.
3. Answer the questions:
   - **Network**: if the server is not reachable, the Wi-Fi networks are listed; type the SSID and
     the passphrase. Networks joined here are copied to the installed system.
   - **Recipe**: detected from the machine model (`20Y1*` p14s, `20L5*`/`20L6*` t480); otherwise
     pick one from the recipes found in the repository.
   - **Disk**: the whole disk is wiped; type `yes` to confirm.
   - **Password**: the same for `root` and `roger`.
4. Reboot and remove the USB stick.

What the installer does:

| Step | Details |
|---|---|
| Partitions | GPT: 1 GiB ESP (FAT32, label `EFI`) + the rest btrfs (label `ROOT`) |
| Swap | subvolume `/swap` with a swap file the size of the RAM; `resume=` and `resume_offset=` on the kernel command line for hibernation |
| arkdep | `arkdep init` with `ARKDEP_ROOT=/mnt`, `/arkdep/config` from `iso/airootfs/root/arkdep.config` (with the chosen recipe as default), then `arkdep deploy <recipe>` |
| Boot | systemd-boot; entries from the template in `/arkdep/templates/systemd-boot` (kernel options in `install.sh`), only the microcode the image ships |
| User | `roger` (UID 1000, zsh) in `wheel input video render audio kvm libvirt`, with the group IDs read from the image; subuid/subgid `100000:65536` for rootless podman; home in the shared `/home` subvolume |
| Filesystem | btrfs with `compress=zstd:1` and `noatime`: in `rootflags=` of the boot template (btrfs takes compression from the first mount, the root) and in fstab |
| fstab | shared subvolumes `/home`, `/root`, `/arkdep`, `/var/lib/flatpak`, `/swap`, the ESP on `/boot` |

`iso/airootfs/root/arkdep.config` and `iso/airootfs/root/systemd-boot.template` are the reference
`/arkdep/config` and boot entry template (title, kernel options) for new installs; keep them in
line with the laptops (`/arkdep/config`, `/arkdep/templates/systemd-boot`).

### Testing in a VM

`iso/test-vm` boots the published ISO in a throwaway UEFI VM (KVM, OVMF, NVMe disk, NAT network
that reaches the LAN) on any machine with QEMU:

```sh
iso/test-vm iso      # download the newest ISO, check it and boot it with an empty disk
iso/test-vm disk     # boot the installed disk
iso/test-vm clean    # delete the VM files (~/.cache/iso-test)
```

The screen is on VNC `localhost:5901`. Use `remote-viewer vnc://localhost:5901` (package
`virt-viewer`): it is a native Wayland client, so it can take the compositor's shortcuts (Super+...)
while focused; Ctrl+Alt gives them back. Stop the VM with `poweroff` inside it. The VM model is not
a known laptop, so the installer shows the recipe menu.
