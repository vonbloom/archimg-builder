# AUR repository (`aur/`)

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

## aur-build.sh

- `pacman -Syu` on every run, so an image a few days old never builds against stale libraries
  (the failure mode of the old LXC builder).
- `aur sync --no-view --noconfirm --auto-key-retrieve <list>`: builds new and outdated targets and
  their AUR dependencies, skips up-to-date ones. AUR PKGBUILD changes are not reviewed.
- Then `aur build --syncdeps` in a copy of each `local/<pkgname>/` (mounted at `/local`). aur build
  skips a package whose file for that version is already in the repository: local packages only
  change when their `pkgver`/`pkgrel` does (pinned on purpose, e.g. `bootc`). The directory name
  must be the package name (it counts as wanted in the cleanup below), and its AUR dependencies, if
  any, must be in `packages.list`.
- `aur/check-upstream` (`ExecStartPost=-` of `build-aur.service`) compares each `local/<pkg>`
  `pkgver` with the latest GitHub release of its `url=` and sends a Home Assistant notification
  once per new version (state in `/var/lib/distro-builder/upstream/<pkg>`). Upstream, not the AUR
  package: the AUR `bootc` is bumped by a bot and ignores its comments. `aur/bump-local <pkg>
  [version]` edits the PKGBUILD (pkgver, pkgrel=1, sha256sums from the release asset `digest` of
  the GitHub API, or a download); it needs a single `source=()` and `sha256sums=()` line each.
- Packages no longer listed nor needed as AUR dependencies (`aur depends`) are `repo-remove`d and
  their files deleted; `paccache -rk2` keeps the last two versions of each package.
- `makepkg.conf` (`/etc/makepkg.conf.d/`) disables `-debug` packages.
- A failure in any step stops the run (the unit fails); packages built before it stay published.

## Gotchas

- `aur-repo-filter` reads `/dev/tty` unless `unbuffer` (package `expect`) is installed; without a
  terminal (systemd) the check for official packages providing an AUR target silently fails.
- `aur depends` default output is dependency pairs; use `--jsonl` + `aur format -f '%n\n'` for names.
- "Failed to connect to udev via varlink" / "command failed to execute correctly" while installing
  dependencies is the udev pacman hook inside the container: harmless.
