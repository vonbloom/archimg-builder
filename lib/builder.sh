# Shared helpers for the build scripts (sourced, not executed).

BUILDER_MAX_AGE_DAYS=${BUILDER_MAX_AGE_DAYS:-7}

# Usage: ensure_builder <image> <context_dir> <rebuild>
# Build the podman image <image> from <context_dir>/Containerfile when it is missing, older than
# BUILDER_MAX_AGE_DAYS or <rebuild> is 1, so the tools and pacman databases inside stay current.
ensure_builder() {
	local image=$1 context=$2 rebuild=$3 created
	created=$(podman image inspect -f '{{.Created.Unix}}' "$image" 2>/dev/null || true)
	if [[ -z $created ]] || ((rebuild)) ||
		(($(date +%s) - created > BUILDER_MAX_AGE_DAYS * 86400)); then
		podman build --pull=always --no-cache --rm -t "$image" "$context" &&
			podman image prune -f
	fi
}
