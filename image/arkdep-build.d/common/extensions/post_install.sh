#!/usr/bin/bash
# shellcheck disable=SC2154 # $workdir is set by arkdep-build, which sources this file

systemctl --root="$workdir" preset-all
systemctl --root="$workdir" --global preset-all

# Generate only the locales listed in /etc/locale.gen
arch-chroot "$workdir" locale-gen

# The key podman checks the images of the build server's registry with (the generic overlay's
# /etc/containers/policy.json: the userland image). keys/ is mounted by image/build; the bootc
# images get it from bootc/build-recipe.sh
install -D -m 644 /root/keys/distro-builder-sigstore.pub "$workdir/etc/pki/containers/distro-builder.pub"
