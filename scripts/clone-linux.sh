#!/bin/sh
# Clone the kernel checkout if it is not already there.
#
# The kernel is the one build input that DIT does not fetch, and leaving it as a
# manual prerequisite made a fresh checkout fail inside the kernel's own build
# with a kconfig error that never said "clone me". This is called by `make linux`,
# which `make kernel` depends on.
#
# Cloned from a **stable** branch, not master: master is a moving feature branch,
# and a Kconfig change that landed on it between one clone and another silently
# dropped CONFIG_PROC_SYSCTL from the generated config -- so the kernel one
# machine built was not the kernel CI built. A stable branch carries backported
# fixes only, which is the same "track upstream, no surprises" rule the rest of
# DIT follows. It still has no fixed revision to verify against, so the revision
# cloned is printed. Depth 1 because a full Linux history is gigabytes and
# nothing here needs it.
set -eu

branch=$1 dest=$2 remote=$3

if [ -d "$dest/.git" ]; then
    # Not clobbered: a checkout may be on any branch on purpose. Said plainly
    # instead, because a checkout left on master is how the two kernels diverged.
    have=$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    if [ "$have" != "$branch" ]; then
        echo "warning: $dest is on '$have', not the pinned '$branch'." >&2
        # -B, not a bare checkout: FETCH_HEAD leaves a detached HEAD, after which
        # rev-parse --abbrev-ref prints "HEAD" and this warning returns every run.
        echo "  To move it: git -C $dest fetch --depth 1 $remote $branch && git -C $dest checkout -B $branch FETCH_HEAD" >&2
    fi
    exit 0
fi

echo "cloning linux $branch from $remote (depth 1)"
git clone --depth 1 --branch "$branch" "$remote" "$dest"

echo "cloned linux $(git -C "$dest" rev-parse HEAD)"
