#!/bin/bash
# Builds dist/dell_idrac_launcher-<version>.zip from the working tree.
# Usage: scripts/build-release.sh v2.1.0
set -euo pipefail
version="${1:?usage: build-release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

pkg="$stage/dell_idrac_launcher"
mkdir -p "$pkg/fetch"
cp "$root"/{idrac.bat,idrac.ps1,README.txt,hosts.example.txt,jre-7u80-windows-x64.exe,jre-7u80-windows-i586.exe} "$pkg/"
cp "$root"/fetch/*.class "$root"/fetch/IdracFetch.java "$pkg/fetch/"

# Windows tools need CRLF (and the BOM on idrac.ps1 for Danish letters).
for f in idrac.bat idrac.ps1 README.txt hosts.example.txt; do
    sed -i 's/\r$//; s/$/\r/' "$pkg/$f"
done
head -c3 "$pkg/idrac.ps1" | od -An -tx1 | grep -q 'ef bb bf' || { echo "idrac.ps1 is missing its UTF-8 BOM" >&2; exit 1; }

mkdir -p "$root/dist"
out="$root/dist/dell_idrac_launcher-$version.zip"
rm -f "$out"
python3 -I - "$stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _, files in os.walk(stage):
        for name in sorted(files):
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, stage))
PY
echo "$out"
