#!/bin/sh
# Clone the kernel checkout if it is not already there.
#
# The kernel is the one build input that DIT does not fetch, and leaving it as a
# manual prerequisite made a fresh checkout fail inside the kernel's own build
# with a kconfig error that never said "clone me". This is called by `make linux`,
# which `make kernel` depends on.
#
# Cloned from the kernel's default branch, like every other component. A branch
# has no fixed revision to verify against, so the old tag verification is gone:
# there was an exact revision to compare against, and now there is not. The
# revision that was cloned is printed instead, which is the same replacement the
# rest of DIT uses. Depth 1 because a full Linux history is gigabytes and
# nothing in this project needs it.
set -eu

branch=$1 dest=$2

if [ -d "$dest/.git" ]; then
    exit 0
fi

echo "cloning linux $branch (depth 1)"
git clone --depth 1 --branch "$branch" https://github.com/torvalds/linux.git "$dest"

echo "cloned linux $(git -C "$dest" rev-parse HEAD)"
