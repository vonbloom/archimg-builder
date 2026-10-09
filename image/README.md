# arkdep images (`image/`)

arkdep images of the host OS. An image is a `.tar.zst` with btrfs send streams of the read-only
root filesystem and of `/etc` and `/var`, plus an update script. Laptops pull them with
`arkdep deploy` and boot the new deployment; the previous one stays as a fallback.

## Recipes

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

To add a device, copy a recipe, adjust the hardware parts, schedule it in `ARKDEP_RECIPES` or
`BOOTC_RECIPES` of `../install` if it should build weekly, and add its model to the detection in
`iso/airootfs/root/install.sh`. `CLAUDE.md` in this directory documents how `arkdep-build`
processes a recipe and the pitfalls already hit.

## Building

```sh
sudo systemctl start build-image@p14s        # same as the timer: build, prune, notify
sudo image/build [--rebuild-builder] p14s    # build only
journalctl -fu build-image@p14s
```

`image/build` runs `arkdep-build` in the `arkdep-builder` image (arkdep and the arkane keyring
built from `arkanelinux/pkgbuild`) and writes to `/mnt/repo/<recipe>`, then rewrites the
`database` file (newest first). Builds started together by both timers run one after the other
(`flock`). A failed build leaves the repository untouched.

## Retention

After each successful build, `image/prune <recipe>` keeps the newest 4 images (a month of weekly
builds) plus the newest image of each of the 3 previous months, and deletes the rest from disk and
from `database`. `KEEP_RECENT` and `KEEP_MONTHLY` override the numbers;
`image/prune --dry-run <recipe>` shows what would be kept and deleted.

## Sanity check

Each image has a `<name>.pkgs` file with its installed packages (about 520 for p14s). An image
with far fewer packages (about 150) means `arkdep-build` skipped the package stage; `notify-image`
flags it.

## On the laptops

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

Next to it, `custom/userland` (script `userland-update-status`) does the same for the userland
distrobox: every hour it compares the digest of `userland:latest` in the registry with the image
the box runs (no pull), shows 󰆧 and the number of new or updated packages when they differ, and
nothing otherwise or away from home. A click runs `userland-update` in a terminal, which asks
before replacing the running box; `userland-update-status refresh` checks again now.
