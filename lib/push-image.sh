# shellcheck shell=bash
# Push an image built on the build server to the registry (bootc/build, userland/build): chunkah
# splits it into per-package layers, so an update downloads only the packages that changed, and
# skopeo pushes them as they are, signed with the server's sigstore key, as <repository>:<tag> and
# <repository>:latest. Sourced; the caller sets -euo pipefail.

# The name clients pull from: the signature names the image it signs (matchRepository in the
# clients' policy.json), so the push goes to the LAN address, not localhost
REGISTRY=${REGISTRY:-192.168.2.50:5000}
SIGSTORE_DIR=${SIGSTORE_DIR:-/etc/distro-builder/sigstore}  # private key and its passphrase, root only
# Pinned: an update of chunkah's gzip could change the bytes of unchanged layers, and every client
# would download the whole image again
CHUNKAH=${CHUNKAH:-quay.io/coreos/chunkah:v0.7.0}
SKOPEO=${SKOPEO:-quay.io/skopeo/stable:v1.22.3}

# push_image <local image> <repository> <tag> [chunkah build option...]
# The tag also goes to the org.opencontainers.image.version label and manifest annotation. Removes
# the local image afterwards: the registry holds it (a copy of several GB on the build server's disk
# otherwise)
push_image() {
	local image=$1 repository=$2 tag=$3
	shift 3

	# chunkah's output, an OCI directory layout (~1 GiB): /var/tmp, not the tmpfs /tmp. Global for
	# the EXIT trap
	PUSH_IMAGE_WORK=$(mktemp -d /var/tmp/push-image.XXXXXX)
	trap 'rm -rf -- "$PUSH_IMAGE_WORK"' EXIT
	local work=$PUSH_IMAGE_WORK

	# One layer per group of packages instead of one per Containerfile step. chunkah reads the
	# pacman database (DBPath in the image's pacman.conf). The layers are gzip-compressed once, here,
	# and pushed as they are: no import into containers-storage and no recompression by podman push
	CHUNKAH_CONFIG_STR=$(podman inspect "$image")
	export CHUNKAH_CONFIG_STR
	podman run --rm --mount=type=image,src="$image",target=/chunkah -v "$work:/out" \
		-e CHUNKAH_CONFIG_STR "$CHUNKAH" build "$@" \
		--label org.opencontainers.image.version="$tag" --annotation org.opencontainers.image.version="$tag" \
		--compressed --max-layers 128 -o oci:/out/image

	# Signed with the build server's sigstore key: the signature goes to the registry next to the
	# image (sha256-<digest>.sig, /etc/containers/registries.d/50-distro-builder.yaml, mounted into
	# the skopeo container). One signature covers both tags: they name the same manifest digest
	local mounts=(-v "$work:/work" -v /etc/containers/registries.d:/etc/containers/registries.d:ro)
	local sign=()
	if [[ -r $SIGSTORE_DIR/distro-builder.private ]]; then
		mounts+=(-v "$SIGSTORE_DIR:$SIGSTORE_DIR:ro")
		sign=(--sign-by-sigstore-private-key "$SIGSTORE_DIR/distro-builder.private"
			--sign-passphrase-file "$SIGSTORE_DIR/passphrase")
	else
		echo "No signing key ($SIGSTORE_DIR): the image is not signed, clients that require a signature will refuse it" >&2
	fi
	# --preserve-digests: the manifest goes up byte for byte (chunkah's annotations, OCI format: the
	# composefs backend fails on Docker v2s2 manifests, bootc-dev/bootc#1703); skopeo fails instead
	# of rewriting it. Blobs already in the registry are skipped
	local copy=(copy --preserve-digests --dest-tls-verify=false --digestfile /work/digest)
	skopeo() { podman run --rm --network host "${mounts[@]}" "$SKOPEO" "$@"; }
	skopeo "${copy[@]}" "${sign[@]}" oci:/work/image "docker://$REGISTRY/$repository:$tag"
	skopeo "${copy[@]}" --quiet oci:/work/image "docker://$REGISTRY/$repository:latest"
	echo "Pushed $REGISTRY/$repository:$tag ($(<"$work/digest"))${sign:+, signed}"

	podman rmi "$image" >/dev/null
	podman image prune -f >/dev/null
}
