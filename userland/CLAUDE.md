# userland image (`userland/`)

- The boxes' first start must not install anything: `distrobox-init` runs its package setup
  (`pacman -Syy`, `pacman -Su`, its dependency list, locales) only when `/.containersetupdone` is
  missing, so the image creates it and has those packages (the list in `packages.list` is
  `setup_pacman` of distrobox 1.8.2.5; recheck it when distrobox changes it). The box then starts
  in seconds and never upgrades itself: updates are a new image.
- `glibc-locales` instead of `locale-gen`: distrobox-init generated the host's locale
  (`ca_ES.UTF-8`) in its setup, which the image skips; the package has every locale built.
- The Arch image skips man pages, locales and docs (`NoExtract` in `pacman.conf`): the Containerfile
  drops those lines before installing, as distrobox-init does. Packages of the base image keep
  what was skipped.
- What the dotfiles' `pre_init_distrobox_assemble.sh` and init hooks did at every start happens
  here once: the `[cachyos]` and `[aur]` repositories and keys, openssh's systemctl hook disabled
  (a `/dev/null` link in `/etc/pacman.d/hooks`; add new ones there), `fc-cache`, and podman as a
  remote client (`99-remote.conf`: a local podman in a box deletes the host's rootless
  `pause.pid`).
- `podman` in the boxes is `podman-remote` (`/usr/local/bin/podman`, first in PATH). The full
  binary, even with `remote = true`, checks the host's `pause.pid` before connecting, takes the
  host's `catatonit -P` for a stale process and deletes the file ("pause.pid file refers to PID
  ... which is not a pause process"); the host's podman then starts another pause process at each
  call (four after a few tests, 2026-10-09, podman 6.1.3; the old userland box did the same).
  `podman-remote` has no rootless setup and leaves it alone. The package cache is removed with `rm`: `pacman -Scc --noconfirm` answers no to
  removing it (seen in the first test build); the live userland had 3.7 GB of it.
- Files go in with `install -m 644` from a bind mount, not `COPY`: the checkout's modes (664, umask
  0002 on the build server) would end up in the image (the same trap as bootc/build-recipe.sh).
- `distrobox.ini` names `192.168.2.50:5000/userland:latest`; the host command that recreates the
  boxes (not written yet) should replace it with the digest it pulled, so that the manifest and the
  boxes come from the same image. Values without spaces are sourced by `distrobox assemble`
  (`$(id -u)` in `additional_flags` works); `exported_bins_path` is left at its default
  (`$HOME/.local/bin`). Exports only happen when a box is created, which is fine: every update
  recreates it.
- The push is `lib/push-image.sh` (chunkah, signature, skopeo), shared with bootc/build; prune is
  `bootc/prune userland` with `PKGS_DIR=/mnt/repo/userland`. The status page lists the registry's
  `userland` repository apart from the bootc ones (`serve/status-gen`, `USERLAND`).
- Test runs on the build server like the bootc ones: a copy of the checkout in `/var/tmp` (never
  edit `/home/admin/distro-builder`), `REPOSITORY=test/userland PKGS_DIR=/var/tmp/...`, under
  `/run/build-image.lock`, then delete the test manifests through the registry API.
