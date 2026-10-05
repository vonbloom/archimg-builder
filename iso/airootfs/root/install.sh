#!/usr/bin/env bash
# Install the newest arkdep image of a recipe from the build server onto a whole disk.
# Runs on the live ISO: partitions the disk (ESP + btrfs ROOT), initializes arkdep with
# /root/arkdep.config, deploys the image and sets up the user, swap (hibernation) and systemd-boot
# (entries from /root/systemd-boot.template).
# Only the LAN is needed: nothing is installed from the Arch mirrors.

set -euo pipefail

REPO_URL=http://192.168.2.50
USER_NAME=roger
USER_GROUPS=(wheel input video render audio kvm libvirt)
ESP_LABEL=EFI
ROOT_LABEL=ROOT
MNT=/mnt

die() {
	echo "$*" >&2
	exit 1
}

repo_reachable() {
	curl -sf -o /dev/null --max-time 5 "$REPO_URL/"
}

# --- Network ---
if ! repo_reachable; then
	wifi=$(iw dev | awk '$1 == "Interface" { print $2; exit }')
	[[ -n $wifi ]] || die "$REPO_URL is not reachable and there is no Wi-Fi interface"
	iwctl station "$wifi" scan
	sleep 3
	iwctl station "$wifi" get-networks
	read -rp "SSID: " ssid
	iwctl station "$wifi" connect "$ssid" # asks for the passphrase
	for _ in {1..20}; do
		repo_reachable && break
		sleep 1
	done
	repo_reachable || die "$REPO_URL is still not reachable"
fi

# --- Recipe: detected from the machine model, otherwise chosen from the published recipes ---
case $(</sys/class/dmi/id/product_name) in
20Y1*) recipe=p14s ;;
20L5* | 20L6*) recipe=t480 ;;
*) recipe= ;;
esac
if [[ -n $recipe ]]; then
	read -rp "Detected $(</sys/class/dmi/id/product_version), recipe $recipe. Use it? [Y/n] " answer
	[[ $answer =~ ^[nN] ]] && recipe=
fi
if [[ -z $recipe ]]; then
	# Recipes with published images, listed by the server's status page generator
	mapfile -t recipes < <(curl -sf "$REPO_URL/status/recipes.txt")
	((${#recipes[@]})) || die "No images found in $REPO_URL"
	PS3="Recipe: "
	select recipe in "${recipes[@]}"; do [[ -n $recipe ]] && break; done
fi

# --- Disk ---
mapfile -t disks < <(lsblk -dno PATH,SIZE,MODEL -e 7,11)
PS3="Disk to install to (it will be wiped): "
select line in "${disks[@]}"; do [[ -n $line ]] && break; done
disk=${line%% *}
read -rp "All data on $disk will be lost. Type yes to continue: " answer
[[ $answer == yes ]] || die "Aborted"

# --- Passwords (same for root and $USER_NAME) ---
while true; do
	read -rsp "Password for root and $USER_NAME: " pass && echo
	read -rsp "Repeat it: " pass2 && echo
	[[ -n $pass && $pass == "$pass2" ]] && break
	echo "Empty or not matching, try again"
done
hash=$(openssl passwd -6 -stdin <<<"$pass")
unset pass pass2

# --- Partitions and filesystems ---
[[ $disk =~ (nvme|mmcblk) ]] && p=p || p=
esp=$disk${p}1 root=$disk${p}2
sgdisk -Z "$disk"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"$ESP_LABEL" -n 2:0:0 -t 2:8300 -c 2:"$ROOT_LABEL" "$disk"
partprobe "$disk"
udevadm settle
mkfs.fat -F 32 -n "$ESP_LABEL" "$esp"
mkfs.btrfs -f -L "$ROOT_LABEL" "$root"

# arkdep works on the top level subvolume; it expects the ESP at <root>/boot
mount -o compress=zstd "$root" $MNT
mkdir $MNT/boot
mount -o fmask=0077,dmask=0077 "$esp" $MNT/boot

# --- Swap file, sized for hibernation ---
ram_gb=$(awk '/^MemTotal/ { print int($2 / 1048576 + 0.99) }' /proc/meminfo)
btrfs subvolume create $MNT/swap
btrfs filesystem mkswapfile --size "${ram_gb}g" $MNT/swap/swapfile
resume_opts="resume=UUID=$(blkid -s UUID -o value "$root")"
resume_opts+=" resume_offset=$(btrfs inspect-internal map-swapfile -r $MNT/swap/swapfile)"

# --- arkdep and the boot loader ---
export ARKDEP_ROOT=$MNT
arkdep init
cp /root/arkdep.config $MNT/arkdep/config
sed -i "s/^repo_default_image=.*/repo_default_image='$recipe'/" $MNT/arkdep/config
mkdir -p $MNT/arkdep/overlay/swap # mount point for /swap in the read-only rootfs
# Boot entry template: the kernel options live in the file, only the machine-specific values are
# filled in here (arkdep replaces %target% with the deployment name)
sed -e "s|@ROOT_LABEL@|$ROOT_LABEL|" -e "s|@RESUME@|$resume_opts|" /root/systemd-boot.template \
	>$MNT/arkdep/templates/systemd-boot

bootctl --esp-path=$MNT/boot install
cat >$MNT/boot/loader/loader.conf <<EOF
timeout 5
console-mode max
editor no
auto-entries yes
auto-firmware yes
EOF

arkdep deploy "$recipe"

# The template lists both microcode images; keep only the ones the image installed
for ucode in amd-ucode.img intel-ucode.img; do
	[[ -f $MNT/boot/$ucode ]] ||
		sed -i "/$ucode/d" $MNT/boot/loader/entries/*.conf $MNT/arkdep/templates/systemd-boot
done

# --- Configuration of the deployment (later deployments get it through migrate_files) ---
rootfs=$(echo $MNT/arkdep/deployments/*/rootfs)
etc=$rootfs/etc

# Group IDs must match the image: take the lines from its /usr/lib/group (nss-altfiles)
grep -q "^$USER_NAME:" "$etc/passwd" ||
	echo "$USER_NAME:x:1000:1000::/home/$USER_NAME:/usr/bin/zsh" >>"$etc/passwd"
for user in root "$USER_NAME"; do
	grep -q "^$user:" "$etc/shadow" || echo "$user:!:$(($(date +%s) / 86400)):0:99999:7:::" >>"$etc/shadow"
done
awk -F: -v OFS=: -v users="root $USER_NAME" -v hash="$hash" \
	'index(" " users " ", " " $1 " ") { $2 = hash } { print }' "$etc/shadow" >"$etc/shadow.new"
mv "$etc/shadow.new" "$etc/shadow"
chmod 600 "$etc/shadow"
for group in "${USER_GROUPS[@]}"; do
	line=$(grep "^$group:" "$rootfs/usr/lib/group") || {
		echo "Group $group is not in the image, skipped"
		continue
	}
	sed -i "/^$group:/d" "$etc/group"
	[[ $line == *: ]] && echo "$line$USER_NAME" >>"$etc/group" || echo "$line,$USER_NAME" >>"$etc/group"
done
grep -q "^$USER_NAME:" "$etc/group" || echo "$USER_NAME:x:1000:" >>"$etc/group"
echo "$USER_NAME:100000:65536" >"$etc/subuid"
echo "$USER_NAME:100000:65536" >"$etc/subgid"

home=$MNT/arkdep/shared/home/$USER_NAME
mkdir -p "$home"
cp -a "$etc/skel/." "$home/"
chown -R 1000:1000 "$home"
chmod 700 "$home"

# Wi-Fi networks joined from the live system
[[ -d /var/lib/iwd ]] && cp -r /var/lib/iwd "$rootfs/var/lib/"

cat >"$etc/fstab" <<EOF
LABEL=$ROOT_LABEL  /home             btrfs  rw,relatime,subvol=arkdep/shared/home,compress=zstd     0 1
LABEL=$ROOT_LABEL  /root             btrfs  rw,relatime,subvol=arkdep/shared/root,compress=zstd     0 1
LABEL=$ROOT_LABEL  /arkdep           btrfs  rw,relatime,subvol=arkdep,compress=zstd                 0 1
LABEL=$ROOT_LABEL  /var/lib/flatpak  btrfs  rw,relatime,subvol=arkdep/shared/flatpak,compress=zstd  0 1
LABEL=$ROOT_LABEL  /swap             btrfs  subvol=/swap,defaults,noatime                           0 0
LABEL=$ESP_LABEL   /boot             vfat   rw,relatime,fmask=0022,dmask=0022,codepage=437          0 2
/swap/swapfile     none              swap   defaults,pri=10                                         0 0
EOF

umount -R $MNT
echo "Installed $(basename "$(dirname "$rootfs")"). Remove the installation media and reboot."
