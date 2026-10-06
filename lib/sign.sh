# shellcheck shell=bash
# Detached GPG signatures for everything published: images, the [aur] packages and database and
# the ISO checksums. The private key lives only on the build server (SIGN_GNUPGHOME, root, mode
# 700), never inside the builder containers: the scripts sign after their container has finished.
# Clients trust keys/distro-builder.asc (arkdep: /arkdep/keys/trusted-keys; pacman: pacman-key).

SIGN_GNUPGHOME=${SIGN_GNUPGHOME:-/etc/distro-builder/gnupg}
SIGN_KEY=CF471E6685974BF43EA113623F9EBD77B1E60E55

# can_sign: the signing key is available (it is not on local test runs, e.g. aur/build /tmp/x)
can_sign() {
	gpg --homedir "$SIGN_GNUPGHOME" --batch --list-secret-keys "$SIGN_KEY" &>/dev/null
}

# sign <file>...: write <file>.sig, replacing an existing one
sign() {
	local f
	for f; do
		gpg --homedir "$SIGN_GNUPGHOME" --batch --yes --quiet --local-user "$SIGN_KEY" \
			--detach-sign --output "$f.sig" "$f" || return 1
		echo "Signed $f"
	done
}

# sign_missing <file>...: sign the files that have no signature yet
sign_missing() {
	local f
	for f; do
		[[ -s $f.sig ]] || sign "$f" || return 1
	done
}
