# distro-builder

Build and distribution tooling for a personal, immutable CachyOS/Arch-based distro on
[arkdep](https://github.com/arkanelinux/arkdep). The root filesystem of each laptop is a read-only
btrfs image built here; interactive software lives in a distrobox (`userland`) fed by a small
repository of prebuilt AUR packages, also built here. An installer ISO puts the whole thing on a
new machine.

| Tool | What it produces | Where it is published | When |
|---|---|---|---|
| [`image/`](#images-image) | arkdep images, one per device recipe | `http://192.168.2.50/<recipe>/` | weekly (Sunday 08:00 Europe/Madrid) |
| [`aur/`](#aur-repository-aur) | the pacman repository `[aur]` | `http://192.168.2.50/aur/` | daily (04:00 UTC) |
| [`iso/`](#installer-iso-iso) | the installer ISO | `http://192.168.2.50/iso/` | by hand |

```
image/    recipes (arkdep-build.d/), build, prune, notify-image
aur/      packages.list, aur-build.sh, build
iso/      installer ISO: Containerfile, build, test-vm, airootfs/ (install.sh, arkdep.config)
serve/    nginx quadlet that publishes /mnt/repo over HTTP
systemd/  build-image@.{service,timer}, build-aur.{service,timer}
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
  role `notify_ha`), for the Home Assistant notifications.

The VM is created by the homelab repo (`pve_guests`), whose cloud-init clones this repository.
Then, once:

```sh
sudo ~/distro-builder/install            # or: sudo ~/distro-builder/install p14s t480 ...
```

`install` links the units in `systemd/` into `/etc/systemd/system`, the quadlet
`serve/distro-repo.container` into `/etc/containers/systemd`, enables `build-aur.timer` and one
`build-image@<recipe>.timer` per recipe (default `p14s t480`), and (re)starts the web server. It is
idempotent: run it again to schedule other recipes.

Every build unit pulls the checkout (`git pull --ff-only`, as `admin`) before building, so a
push to GitHub is enough for the next build to use it. A failed pull does not stop the build. The
units and timers themselves are only reloaded by systemd: after changing a file in `systemd/`,
run `sudo systemctl daemon-reload` on the server once the pull has brought it in.

Each tool builds inside its own throwaway podman *builder* image (`arkdep-builder`, `aur-builder`,
`iso-builder`). `lib/builder.sh` (`ensure_builder`) rebuilds a builder image from scratch when it
is missing, older than 7 days or `--rebuild-builder` is given, so the tools and package databases
inside never go stale.

### Web server

`serve/distro-repo.container` runs `nginx:alpine` on port 80 with `/mnt/repo` as its document root
and directory listings on (the installer reads the recipe list from the index):

```
/mnt/repo/
├── p14s/   database, p14s-YYYY-MM-DD.tar.zst, p14s-YYYY-MM-DD.pkgs
├── t480/   ...
├── aur/    aur.db, *.pkg.tar.zst
└── iso/    distro-installer-YYYY.MM.DD-x86_64.iso, sha256sums.txt
```

### Notifications

Every unit has `OnFailure=notify-failure@%n.service`, so a failed build sends a `[FAILED]` push to
Home Assistant with the end of its journal. A successful image build sends "New image ..." (tag
`image-<recipe>`) with its package count, kernel and the changes since the previous image; it is
sent as a warning when the package count drops by more than 20 % (see
[Images](#sanity-check)).

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
├── depends/sway/     desktop: sway, waybar, foot, rofi, user units
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
booted yet, and nothing when the system is up to date or the server is unreachable.

## AUR repository (`aur/`)

Prebuilt AUR packages for the `userland` distrobox, published as the pacman repository `[aur]`.

- List the packages in `aur/packages.list`, one per line. AUR dependencies are built
  automatically; packages removed from the list (and no longer needed as dependencies) are removed
  from the repository on the next run. The last two versions of each package are kept.
- `aur/build [--rebuild-builder] [repo_path]` runs `aurutils` (`aur sync`) in the `aur-builder`
  image after a full `pacman -Syu`, so packages always build against current libraries. The
  default repository path is `/mnt/repo/aur`; a test run works rootless anywhere:
  `aur/build /tmp/aur-test`.
- Scheduled daily by `build-aur.timer`; run it now with `sudo systemctl start build-aur` and
  follow it with `journalctl -fu build-aur`.
- PKGBUILD changes are not reviewed: only list packages you trust.

The repository is unsigned. Clients add it after Arch's repositories (the dotfiles repo does this
for the distroboxes, in `pre_init_distrobox_assemble.sh`):

```ini
[aur]
SigLevel = Optional TrustAll
Server = http://192.168.2.50/aur
```

## Installer ISO (`iso/`)

A live Arch ISO (Arch's `releng` profile) with `arkdep` added and an installer that deploys the
newest image straight from the repository. The ISO does not contain an image, so it stays small
(~1.6 GB) and never installs an outdated system; it does need the LAN (cable, or Wi-Fi joined
from the installer). Nothing is downloaded from the Arch mirrors during the installation.

### Building

```sh
sudo systemd-run --unit=build-iso --collect ~/distro-builder/iso/build   # on the build server
journalctl -fu build-iso
```

`iso/build [output_dir]` builds `iso-builder` on top of `arkdep-builder` (which already trusts the
arkane signing key) with `archiso`, runs `mkarchiso` and moves the ISO to `/mnt/repo/iso/`
(default), replacing the previous one and writing `sha256sums.txt`. There is no timer: rebuild it
when the installer changes or when the live system is too old for new hardware.

### Installing a machine

1. Download the ISO from `http://192.168.2.50/iso/`, check it against `sha256sums.txt` and write
   it to a USB stick (`dd if=distro-installer-*.iso of=/dev/sdX bs=4M oflag=sync`).
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
| fstab | shared subvolumes `/home`, `/root`, `/arkdep`, `/var/lib/flatpak`, `/swap`, the ESP on `/boot` |

`iso/airootfs/root/arkdep.config` is the reference `/arkdep/config` for new installs; keep it in
line with the laptops (`repo_url`, `deploy_keep`, `migrate_files`).

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
