#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Patch a temporary module copy so builds never write to the Go module cache.
module=github.com/ganeshrvel/go-mtpfs
upstream=$(go list -m -f '{{.Dir}}' "$module")
if [[ -z "$upstream" ]]; then
    go mod download "$module"
    upstream=$(go list -m -f '{{.Dir}}' "$module")
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$upstream" "$work/go-mtpfs"
chmod -R u+w "$work/go-mtpfs"
patch -s "$work/go-mtpfs/mtp/mtp.go" < no-usb-reset.patch
cp go.mod go.sum "$work/"
go mod edit -modfile="$work/go.mod" "-replace=$module=$work/go-mtpfs"
command=$1
shift
go "$command" -modfile="$work/go.mod" "$@"
