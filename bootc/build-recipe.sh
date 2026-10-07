#!/usr/bin/bash
# Apply an arkdep recipe (image/arkdep-build.d/<recipe>) to the container being built, in the
# same order as arkdep-build: bootstrap.list packages, post_bootstrap overlays, package.list
# packages, post_install overlays (device first, then each depends overlay, so depends win),
# then presets and locales. Prototype for a bootc image of the same system (see Containerfile).
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
# /etc/resolv.conf is bind mounted during the build: an overlay's link becomes a tmpfiles.d entry
# (sorts before systemd-resolve.conf, whose L! entry it replaces)
overlays() {
	local src target
	for d in "${dirs[@]}"; do
		src=$root/$d/overlay/$1
		[[ -d $src ]] || continue
		tar -C "$src" --exclude=./etc/resolv.conf -cf - . | tar -C / -xpf -
		if [[ -L $src/etc/resolv.conf ]]; then
			target=$(readlink "$src/etc/resolv.conf")
			echo "L+ /etc/resolv.conf - - - - $target" >/usr/lib/tmpfiles.d/etc-resolv-conf.conf
		fi
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
