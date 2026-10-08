#!/usr/bin/bash
# Apply an arkdep recipe (image/arkdep-build.d/<recipe>) to the container being built, in the
# same order as arkdep-build: bootstrap.list packages, post_bootstrap overlays, package.list
# packages, post_install overlays (device first, then each depends overlay, so depends win),
# then bootc/overlay, presets and locales. Prototype for a bootc image of the same system (see
# Containerfile).
set -euo pipefail

recipe=$1
root=/ctx/image/arkdep-build.d
mapfile -t dirs < <(echo "$recipe"; grep -vE '^\s*(#|$)' "$root/$recipe/depends.list")

lists() {
	for d in "${dirs[@]}"; do
		# A list may hold only comments (p14s/package.list): grep finds nothing
		[[ -f $root/$d/$1 ]] && { grep -vE '^\s*(#|$)' "$root/$d/$1" || true; }
	done
	return 0
}
# Copy an overlay directory to / like arkdep-build's cp -r: root owns the new files, their modes
# follow root's umask, and existing files and directories keep their owner and mode (only the
# contents of a file change). The checkout belongs to UID 1000 with umask 0002: extracting it as is
# made /usr, /etc/systemd, /etc/sudoers.d... UID 1000 and 775 (sudo ignored sudoers.d, iwd could not
# register on D-Bus), and COPY applied its 775 directory modes to existing directories. The copy
# goes through a root-owned staging directory first. /etc/resolv.conf is bind mounted during the
# build: an overlay's link becomes a tmpfiles.d entry (sorts before systemd-resolve.conf, whose L!
# entry it replaces)
copy_overlay() {
	local src=$1 stage target
	stage=$(mktemp -d)
	tar -C "$src" --exclude=./etc/resolv.conf -cf - . |
		tar -C "$stage" -xf - --no-same-owner --no-same-permissions
	cp -r "$stage"/. /
	rm -r "$stage"
	if [[ -L $src/etc/resolv.conf ]]; then
		target=$(readlink "$src/etc/resolv.conf")
		echo "L+ /etc/resolv.conf - - - - $target" >/usr/lib/tmpfiles.d/etc-resolv-conf.conf
	fi
}
overlays() {
	for d in "${dirs[@]}"; do
		[[ -d $root/$d/overlay/$1 ]] && copy_overlay "$root/$d/overlay/$1"
	done
	return 0
}

# arkdep and its [arkane] repository have no use under bootc. nss-altfiles reads the accounts
# arkdep-build moves to /usr/lib/{passwd,group}; bootc keeps them in /etc (3-way merge).
skip='^(arkdep|arkane-keyring|nss-altfiles)$'

mapfile -t pkgs < <(lists bootstrap.list | grep -vE "$skip")
pacman -S --noconfirm --needed "${pkgs[@]}"
overlays post_bootstrap
mapfile -t pkgs < <(lists package.list | grep -vE "$skip")
pacman -S --noconfirm --needed "${pkgs[@]}"
overlays post_install
# Files only bootc systems need, before the presets (80-bootc.preset enables bootc-update.timer)
copy_overlay /ctx/bootc/overlay
sed -i 's/ altfiles//' /etc/nsswitch.conf

# /usr/local becomes a link to /var/usrlocal, and bootc never updates /var after the install:
# the scripts must live in /usr/bin to be updated with the image
if [[ -d /usr/local/bin ]] && compgen -G '/usr/local/bin/*' >/dev/null; then
	mv /usr/local/bin/* /usr/bin/
	grep -rl /usr/local/bin/ /usr/lib/systemd /etc | xargs -r sed -i 's|/usr/local/bin/|/usr/bin/|g'
fi

# common/extensions/post_install.sh
systemctl preset-all
systemctl --global preset-all
locale-gen

pacman -Scc --noconfirm
