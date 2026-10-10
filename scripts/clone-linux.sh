#!/bin/sh
# Clone the kernel checkout if it is not already there.
#
# The kernel is the one build input that DIT does not fetch, and leaving it as a
# manual prerequisite made a fresh checkout fail inside the kernel's own build
# with a kconfig error that never said "clone me". This is called by `make linux`,
# which `make kernel` depends on.
#
# Pinned the way the rest of the components are: HTTPS at an exact revision, from
# a tag that is then verified, so a tag that has moved fails loudly here instead
# of quietly building something else. Depth 1 because a full Linux history is
# gigabytes and nothing in this project needs it.
set -eu

tag=$1 ref=$2 dest=$3

if [ -d "$dest/.git" ]; then
	exit 0
fi

echo "cloning linux $tag (depth 1)"
git clone --depth 1 --branch "$tag" \
	https://github.com/torvalds/linux.git "$dest"

got=$(git -C "$dest" rev-parse HEAD)
if [ "$got" != "$ref" ]; then
	echo "clone-linux: $tag is $got, expected $ref" >&2
	# Do not leave a checkout that is the wrong revision behind: the next run
	# would see .git and skip the clone, and the mistake would stick.
	rm -rf "$dest"
	exit 1
fi
