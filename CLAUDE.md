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
          (bootc and userland images)
systemd/  build-image@.{service,timer}, build-bootc@.{service,timer}, build-aur.{service,timer},
          build-userland.{service,timer}, build-iso.service,
          distro-status.{service,timer} (every minute), distro-trigger.{socket,service}
lib/      builder.sh (ensure_builder: rebuild a podman builder image when older than 7 days),
          sign.sh (detached GPG signatures with the server key, /etc/distro-builder/gnupg),
          push-image.sh (chunkah + signed skopeo push to the registry: bootc and userland images)
docs/     todo.md: pending improvements (boot time, storage, memory)
ci/       check: static checks (shellcheck, Python syntax, stray files, exec bits, recipe structure),
          run by GitHub Actions on every push (.github/workflows/check.yml)
bootc/    the recipes as bootc images (trial, the T480): Containerfile, build-recipe.sh,
          build (chunkah + push to the registry), prune, install (from the ISO), overlay/; design
          and VM results in bootc/README.md
userland/ the userland distrobox image: Containerfile, packages.list, distrobox.ini (the box
          manifest, carried by the image), dbus-1/, build; prune is bootc/prune
keys/     distro-builder.asc: public signing key, trusted by arkdep, pacman and the installer;
          distro-builder-sigstore.pub: public key of the bootc image signatures
install   links the units and the quadlet, installs the polkit rule, enables the timers (also
          podman-auto-update) and the trigger socket (run as root; rerun after changing systemd/, serve/)
```

All builds run on the server `192.168.2.50` (Debian, rootful podman via `sudo`, checkout
`/home/admin/distro-builder`), never on the laptops. `/mnt/repo` there is NFS from zeus
(`192.168.2.10`). Each build unit runs `git pull --ff-only` (as `admin`, non-fatal) first, so
pushing is enough; changes to `systemd/` also need `systemctl daemon-reload`. A failed build triggers `notify-failure@` (Home Assistant push); both
`notify-ha` and that unit come from the homelab repo (role `notify_ha`).

Run `ci/check` before giving the user a commit: it must pass (GitHub Actions runs it on every push).
A shellcheck warning that is intended gets a `# shellcheck disable=SCxxxx # reason` directive.

Documentation is split per component: user-facing usage in `README.md` (this directory: overview,
build server, signatures, notifications) and in each component's `README.md`; implementation notes
and pitfalls in each component's `CLAUDE.md` (`image/`, `aur/`, `bootc/`, `iso/`), read when
working there. Keep them in sync when changing behaviour, in the file of the component concerned.

## System overview

- **Host OS**: arkdep deployments. Root is a read-only btrfs subvolume
  (`/arkdep/deployments/<image>/rootfs`), `/etc` and `/var` are separate subvolumes per deployment.
  `deploy_keep=2`. Packages are not installed on the host at runtime: change a recipe and rebuild.
- **Userland**: everything interactive (VS Code, Brave, neovim, compilers) lives in the `userland`
  distrobox (Arch), created from the userland image built here (`userland/`, with the box
  manifest inside) by `userland-update` (host image, generic overlay), which `deploy-userland`
  (user unit `deploy-userland.service`) runs at the first login when the box is missing. The user
  configuration is the dotfiles repo `vonbloom/dotfiles` (stow, `~/.dotfiles`), which defined the
  boxes until 2026-10-09 (`default.ini`).
- **Host config persistence**: `/arkdep/config` `migrate_files` copies listed paths from the running
  system into each new deployment (`cp -rp`, merged over the image). It includes
  `etc/passwd|shadow|group`, `etc/ssh`, `etc/systemd/network` (WireGuard `wg0`), `var/lib/iwd`, etc.
  Local copies win over the image versions of the same files.
- **Users**: `arkdep-build` moves non-root accounts to `/usr/lib/{passwd,group,shadow}`, read through
  `nss-altfiles` (`altfiles` in `nsswitch.conf`). Do not remove either or system users disappear.

## Signatures

Images, `[aur]` and ISO checksums are signed outside the builder containers
(`lib/sign.sh`; the key never enters a container, which runs unreviewed AUR code). Anything
that deletes published files must delete their `.sig` too (`prune`, `aur/build` cleans orphan
package signatures). `sign_stale` also re-signs a file newer than its signature: a second build
of an image on the same day replaces `<recipe>-<date>.tar.zst` under the same name, and the
kept signature made arkdep reject it ("BAD signature", p14s-2026-10-07). The installer copies `keys/distro-builder.asc` (built into the ISO through
`--build-context keys=../keys`) to `/arkdep/keys/trusted-keys`.

## Other machines

- ThinkPad T480 (hardware info, tests of the `t480` recipe): `ssh roger@192.168.2.182`, bootc
  `t480` image since 2026-10-08.
