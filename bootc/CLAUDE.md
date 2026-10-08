# bootc images (`bootc/`)

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
- Signing (sigstore, since 2026-10-08): `bootc/build` pushes the dated tag with
  `--sign-by-sigstore-private-key /etc/distro-builder/sigstore/distro-builder.private
  --sign-passphrase-file .../passphrase` (root only, restored from the homelab vault) and `latest`
  unsigned (same digest, same signature). The push goes to `192.168.2.50:5000`, not localhost: the
  signature names the reference it was pushed as, and the clients' policy uses `matchRepository`.
  podman only writes sigstore attachments with `use-sigstore-attachments` in registries.d: the server
  gets `overlay/etc/containers/registries.d/50-distro-builder.yaml` from `install`. The clients'
  `policy.json` keeps Arch's default (accept anything) for every other registry, so distrobox and dev
  container images are unaffected. composefs bootc pulls through skopeo's image proxy with the default
  config, which applies `/etc/containers/policy.json` (`bootc_composefs/repo.rs`). `prune` deletes the
  `sha256-<digest>.sig` tag with its image. Check a policy by hand with skopeo in a container:
  `skopeo copy --policy P --registries.d D --src-tls-verify=false docker://192.168.2.50:5000/t480:latest dir:/tmp/x`
  (an unsigned image: "A signature was required, but no signature exists").
- Updates on bootc systems: `bootc-update.timer` (`bootc/overlay`, enabled by `80-bootc.preset` in
  `build-recipe.sh`'s `preset-all`) runs `bootc-update`:
  `bootc upgrade` (stage only) and `/run/bootc-update/staged` (recipe, version, package list URL)
  for the waybar indicator. The version is `org.opencontainers.image.version` (the date tag), set
  by `bootc/build` as a label (bootc's ostree backend) and a manifest annotation (the composefs
  backend reads only that, bootc-dev/bootc#2227). `bootc-fetch-apply-updates.timer` stays disabled: it reboots by
  itself and only runs on ostree boots (`/run/ostree-booted`).
- `arkdep-update-status` (sway layer) serves both: arkdep when `/arkdep/config` exists, bootc
  otherwise.
- `build-recipe.sh` copies the overlays (the recipe's, then `bootc/overlay`) like arkdep-build's
  `cp -r`: `tar --no-same-owner --no-same-permissions` into a staging directory, then `cp -r` to `/`
  (existing files and directories keep owner and mode). Plain `tar -xp` kept the checkout's UID
  1000 and 775 modes, also on existing dirs (`/usr`, `/usr/lib`, `/etc/systemd`): sudo ignored
  `sudoers.d` and iwd failed on D-Bus. `COPY` gave existing dirs the checkout's 775 (server umask
  0002), and tar replaced existing files with the overlay's mode (libvirt's 600 `default.xml` became
  644). The Containerfile fails the build when `pacman -Qkk` reports an owner or mode mismatch
  (expected: `/proc`, `/sys`, `utempter`) or a file belongs to UID 1000; at runtime `/var/...`
  entries also differ (created by tmpfiles). The overlays' `resolv.conf` link becomes
  `/etc/tmpfiles.d/systemd-resolve.conf`, replacing systemd's file of that name.
- bootc mounts the ESP read-only at `/boot` (`systemd.mount-extra=...:/boot:auto:ro`), so
  `systemd-boot-random-seed.service` is masked in `bootc/overlay` (systemd-boot refreshes the seed).
- `bootc/install` (live ISO): podman storage on a tmpfs (overlay cannot sit on the live overlayfs
  root), `wipefs` + `mount -t btrfs` (udev's cached probe still says ext4), the target at
  `/target` in the container (`/mnt` links to `var/mnt` in a bootc image), user/hostname/Wi-Fi
  written to `/state/deploy/<id>/etc` and `/state/os/default/var` (`useradd --prefix`), and an
  `efibootmgr` entry (bootc only installs the `EFI/BOOT` fallback, bootc-dev/bootc#2557). It deletes the ESP's
  `bootc_*.conf` entries (and `EFI/Linux/bootc_composefs-*`) whose root is the reformatted
  partition or gone: they share title and sort key with the new one and the version is a hash, so
  systemd-boot booted a stale one in a rehearsal. It writes `loader.conf` like the arkdep
  installer: bootc only writes `timeout 5` when the file is missing, and `bootctl install` has
  just created it with every line commented out (no menu, bootc-dev/bootc#2558). Rehearsed in a VM booted from the ISO
  with a T480-like layout (2026-10-08).
- Boot entry titles: bootc uses `PRETTY_NAME` and `VERSION_ID` of the image's `/usr/lib/os-release`;
  the Containerfile sets them to `Arch Linux (<recipe> <tag>)` and `<tag>.<HHMM>` (`VERSION` and
  `VERSION_ID` build args from `bootc/build`; systemd-boot appends the version to equal titles, two
  builds of a day), and links `/etc/os-release` to it (the Arch container image ships its own
  copy).
