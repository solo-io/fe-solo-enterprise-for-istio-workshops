#!/usr/bin/env bash
# Mirror the workshop images to a private registry for air-gapped runs.
#
# The image list is read from the `docker pull` lines in each workshop's
# 000-prerequisites.md, so it always matches the docs.
#
# Each image is copied with all of its architectures to <registry>/<name>:<tag>,
# where <name> is the last path segment of the source. Istio needs this flat
# layout: with `global.hub=<registry>` it pulls <registry>/pilot, /proxyv2,
# /install-cni and /ztunnel.
#
# Usage:
#   lib/mirror-images.sh <registry> [--push] [workshop-dir ...]
#
# Examples:
#   lib/mirror-images.sh docker.io/myorg                                     # dry run, all workshops
#   lib/mirror-images.sh docker.io/myorg --push istio-ambient-single-cluster  # push one workshop
#
# Without --push, the script only reports what it would do. It never overwrites
# a tag in the target registry that has different content, and it checks each
# pushed digest against the source.
#
# Requires: docker with buildx, logged in to the target registry (`docker login`).
# Helm charts are not mirrored. Use the `helm pull` commands in the prerequisites.

set -uo pipefail

usage() { sed -n '/^# Usage:/,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ $# -ge 1 ] || usage
case $1 in -h|--help|-*) usage ;; esac
registry=${1%/}; shift
push=false
dirs=()
for arg in "$@"; do
  case $arg in
    --push) push=true ;;
    -h|--help) usage ;;
    *) dirs+=("${arg%/}") ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

docker buildx version >/dev/null 2>&1 || { echo "docker buildx is required" >&2; exit 1; }

if [ ${#dirs[@]} -eq 0 ]; then
  files=(*/000-prerequisites.md)
else
  files=()
  for d in "${dirs[@]}"; do
    [ -f "$d/000-prerequisites.md" ] || { echo "no $d/000-prerequisites.md" >&2; exit 1; }
    files+=("$d/000-prerequisites.md")
  done
fi

images=$(grep -hoE '^docker pull [^ ]+' "${files[@]}" | awk '{print $3}' | sort -u)
[ -n "$images" ] || { echo "no images found" >&2; exit 1; }

digest() { docker buildx imagetools inspect "$1" 2>/dev/null | awk '/^Digest:/{print $2; exit}'; }

fail=0; pushed=0; same=0; todo=0
for src in $images; do
  dst="$registry/${src##*/}"
  s=$(digest "$src")
  if [ -z "$s" ]; then echo "SRC-MISSING $src"; fail=1; continue; fi
  d=$(digest "$dst")
  if [ "$s" = "$d" ]; then echo "SAME        $dst"; same=$((same + 1)); continue; fi
  if [ -n "$d" ]; then
    echo "CONFLICT    $dst already exists with $d (source is $s); not overwriting"
    fail=1; continue
  fi
  if ! $push; then echo "WOULD-PUSH  $src -> $dst"; todo=$((todo + 1)); continue; fi
  if docker buildx imagetools create -t "$dst" "$src" >/dev/null && [ "$(digest "$dst")" = "$s" ]; then
    echo "PUSHED      $dst  $s"; pushed=$((pushed + 1))
  else
    echo "FAILED      $dst"; fail=1
  fi
done

if $push; then
  echo "pushed $pushed, already present $same"
else
  echo "would push $todo, already present $same (dry run; add --push to copy)"
fi
exit $fail
