# userland image

The image of the `userland` distrobox, where everything interactive runs (VS Code, Brave, neovim,
Ansible...), and of `playground`, the box for trying packages. The boxes are created from the image
and replaced by the next one instead of being upgraded in place: the same contents on every
machine, no first setup that installs hundreds of packages on each of them, and a previous tag to
go back to.

| File | What it is |
|---|---|
| `Containerfile` | Arch (`archlinux/archlinux:latest`) with `[cachyos]` and `[aur]`, the packages, the boxes' setup |
| `packages.list` | the packages, with what each group is for |
| `distrobox.ini` | the boxes for `distrobox assemble`: `[playground]` (image, volume, flags) and `[userland]` (plus the apps and commands exported to the host) |
| `dbus-1/services/` | D-Bus services the host's session bus starts in the box (gvfs, xfconf) |
| `build` | builds the image and pushes it to the registry |

The image carries `distrobox.ini` and the D-Bus services in `/usr/share/userland/`: the host reads
them from the image it creates the boxes from, so the exports always match the packages, and going
back to an older image brings back its exports too.

## Builds

`build-userland.service` runs `build` every Sunday at 15:00 Europe/Madrid (after the arkdep and
bootc images, under the same lock), or by hand: the status page, or
`sudo systemctl start build-userland.service`. It pushes `192.168.2.50:5000/userland:YYYY-MM-DD` and
`:latest`, signed with the server's sigstore key, in per-package layers: a new image downloads only
the packages that changed. `bootc/prune` keeps the newest 4 dated tags. The package list of each
image is at `http://192.168.2.50/userland/userland-<date>.pkgs`, and the build sends a "New userland
image" notification with the changes since the previous one.

## Changing the packages

1. Try the package in `playground` (`playground`, then `sudo pacman -S <package>`): the same image,
   with the same repositories.
2. Add it to `packages.list`, and to `exported_apps` or `exported_bins` in `distrobox.ini` if the
   host must see it. An AUR package must be in `aur/packages.list` too (built into `[aur]`).
3. Push, and start a build by hand if it cannot wait until Sunday.

## On the laptops

`userland-update` (in the host images) pulls `userland:latest`, reads its `distrobox.ini`, pins it
to the digest it pulled and recreates `userland` with it (`distrobox assemble create --replace`),
then installs the D-Bus services and removes the previous image. It does nothing when userland
already runs that image, asks before replacing a running box (the apps opened from it close;
`--yes` skips the question), and `--dry-run` only shows what it would do.
`userland-update 192.168.2.50:5000/userland:<date>` goes back to an older image (the registry keeps
four). On a new machine `deploy-userland` runs it at the first login. The host images trust the
registry and require its signature (the generic overlay of `image/arkdep-build.d/depends`).

`playground` is left alone by an update, so the experiments in it stay (it says when it runs an
older image than userland). `userland-update --playground` moves it to the image userland runs and
installs again the packages added in it (explicitly installed, not in the image), with `pacman
-Syu`; files changed in it by hand go. `--playground --dry-run` lists those packages: the
candidates for `packages.list`.

Both laptops' boxes come from the image since 2026-10-09; pending (`docs/todo.md`): the dotfiles'
`distrobox` package goes, then the waybar notice.
