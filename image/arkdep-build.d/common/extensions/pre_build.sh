#!/bin/bash
# shellcheck disable=SC2154 # $variantdir is set by arkdep-build, which sources this file

pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
pacman -U --noconfirm 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst'
cp $variantdir/pacman.conf /etc/
cp $variantdir/mirrorlist /etc/pacman.d/mirrorlist
pacman -Syy
