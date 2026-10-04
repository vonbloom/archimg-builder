# aur-builder

Builds the AUR packages listed in `packages.list` in a throwaway podman container and publishes
them as the pacman repository `[aur]`. Sibling of `~/archimg-builder` and run on the same server.
The user speaks Catalan; code, comments and commit messages are in English (short, sentence-style
subjects).

## How it runs

- Server `192.168.2.50` (Debian, rootful podman via `sudo`), checkout `/home/admin/aur-builder`.
- `install` links `systemd/aur-builder.{service,timer}` into `/etc/systemd/system` and enables the
  timer (daily 04:00 UTC + up to 30 min random delay, `Persistent=true`). A failed run triggers
  `notify-failure@` (Home Assistant push; from the homelab repo, role `notify_ha`). Logs:
  `journalctl -u aur-builder`. Manual run: `sudo systemctl start aur-builder` or `sudo ./build`.
- `build [--rebuild-builder] [repo_path]` rebuilds the `aur-builder` image when missing, older than 7
  days or requested, then runs `aur-build.sh` in it with `packages.list` and the repo
  (`/mnt/repo/aur`, NFS from `192.168.2.10`) mounted. A local test run works rootless on any host:
  `./build /some/tmp/dir`.
- The repo is served by archimg-builder's nginx quadlet (`arkdep-repo.container`, `/mnt/repo`) at
  `http://192.168.2.50/aur/`, unsigned (`SigLevel = Optional TrustAll` on clients).
- Client: the `userland` distrobox (`~/.dotfiles/distrobox/.config/distrobox/pre_init_distrobox_assemble.sh`).
  The old LXC builder at `192.168.2.38` is obsolete.

## aur-build.sh

- `pacman -Syu` on every run, so an image a few days old never builds against stale libraries
  (the failure mode of the old LXC builder).
- `aur sync --no-view --noconfirm --auto-key-retrieve <list>`: builds new and outdated targets and
  their AUR dependencies, skips up-to-date ones. AUR PKGBUILD changes are not reviewed.
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
