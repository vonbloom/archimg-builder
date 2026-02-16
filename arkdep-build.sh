#!/usr/bin/env bash

[[ -z $1 ]] && echo "A recipe must be specified" && exit 1
[[ $# -gt 1 ]] && echo "Only one argument allowed" && exit 1

RECIPE="$1"
REPO_PATH="/root/target"
DB_FILENAME=database
DB_PATH="$REPO_PATH/$DB_FILENAME"

# Build recipe
echo "Building $RECIPE..."
/usr/bin/arkdep-build "$RECIPE"

# Delete folders not needed
echo "Deleting folders not needed..."
find "$REPO_PATH" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

# Update database
echo "Updating database..."
> "$DB_PATH"
ls -r "$REPO_PATH"/*.tar.zst 2>/dev/null | while read -r file; do
    [[ -e $file ]] || continue
    FILENAME=$(basename "$file")
    IMG_NAME="${FILENAME%.tar.zst}"
    HASH=$(sha256sum "$file" | awk '{ print $1 }')

    echo "$IMG_NAME:zst:$HASH" >> "$DB_PATH"
done
