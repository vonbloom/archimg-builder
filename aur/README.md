# AUR repository (`aur/`)

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

Packages and database are signed ([Signatures](../README.md#signatures)). Clients trust the key and add the
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
