#!/usr/bin/bash

# USERNAME="roger"
# USERPASS="r0g3r"
#
# arch-chroot "$workdir" locale-gen
# arch-chroot "$workdir" useradd -m -G wheel,video,render,input -s /usr/bin/zsh ${USERNAME}
# echo "${USERNAME}:${USERPASS}" | arch-chroot "$workdir" chpasswd
# arch-chroot "$workdir" fc-cache -fv
systemctl --root="$workdir" preset-all
systemctl --root="$workdir" --global preset-all
