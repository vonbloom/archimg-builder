#!/usr/bin/bash
# shellcheck disable=SC2154 # $workdir is set by arkdep-build, which sources this file

systemctl --root="$workdir" preset-all
systemctl --root="$workdir" --global preset-all

# Generate only the locales listed in /etc/locale.gen
arch-chroot "$workdir" locale-gen
