#!/usr/bin/env bash
# Runs inside the builder container as root. /repo is the published repository and
# /packages.list the list of AUR packages to keep in it.

set -euo pipefail

REPO_NAME=aur
REPO_PATH=/repo
DB_PATH="$REPO_PATH/$REPO_NAME.db.tar.zst"
KEEP_VERSIONS=2

mapfile -t PACKAGES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' /packages.list | grep .)
((${#PACKAGES[@]})) || { echo "packages.list is empty"; exit 1; }

# Keep the toolchain current even if the image is a few days old
pacman -Syu --noconfirm

chown -R builder: "$REPO_PATH"
if [[ ! -f $DB_PATH ]]; then
	echo "Creating empty $REPO_NAME repository..."
	sudo -u builder repo-add "$DB_PATH"
fi

cat >> /etc/pacman.conf <<EOC

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file://$REPO_PATH
EOC
pacman -Sy

# Build new and outdated packages (AUR dependencies included); up to date ones are skipped
echo "Syncing ${PACKAGES[*]}..."
sudo -u builder aur sync --database "$REPO_NAME" --no-view --noconfirm --auto-key-retrieve \
	"${PACKAGES[@]}"

# Drop packages that are no longer listed nor needed as AUR dependencies
# (command substitutions, not process substitutions, so an AUR query failure aborts the run)
depends=$(sudo -u builder aur depends --jsonl "${PACKAGES[@]}")
wanted=$(aur format -f '%n\n' - <<<"$depends" | sort -u)
[[ -n $wanted ]] || { echo "Could not resolve the wanted packages"; exit 1; }
current=$(sudo -u builder aur repo --database "$REPO_NAME" --list | cut -f1 | sort -u)
mapfile -t STALE < <(comm -23 <(printf '%s\n' "$current" | grep .) <(printf '%s\n' "$wanted"))
if ((${#STALE[@]})); then
	echo "Removing ${STALE[*]}..."
	sudo -u builder repo-remove "$DB_PATH" "${STALE[@]}"
	for file in "$REPO_PATH"/*.pkg.tar.*; do
		[[ -e $file ]] || continue
		name=$(basename "$file")
		name=${name%-*-*-*}
		for stale in "${STALE[@]}"; do
			[[ $name == "$stale" ]] && rm -v "$file"
		done
	done
fi

# Old package versions are kept for rollbacks
paccache -r -k "$KEEP_VERSIONS" -c "$REPO_PATH"

echo "Repository contents:"
sudo -u builder aur repo --database "$REPO_NAME" --list
