#!/usr/bin/bash

systemctl --root="$workdir" preset-all
systemctl --root="$workdir" --global preset-all

# Generate only the locales listed in /etc/locale.gen
arch-chroot "$workdir" locale-gen
