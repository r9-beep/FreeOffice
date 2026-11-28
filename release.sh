#!/bin/zsh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Publish a FreeOffice release that the apps can update to in place.
#
#   ./release.sh [--bump] <update folder> ["release notes"] [base URL]
#
# Builds every app, zips them into <update folder>, and writes appcast.json beside the zip.
# Point the apps at that folder (or serve it over https and give its URL) in Updates → Update source.
#   --bump   increment the build number first (apps only update when the build number is higher)
#   VERSION  is the human-readable version in the VERSION file; edit it for bigger releases
#
# Updating from GitHub Releases: attach BOTH the zip and appcast.json to the same (non-draft, non-pre-release) release, then set
# Updates → Update source to  https://github.com/<owner>/<repo>/releases/latest/download/appcast.json
# The zip is found next to the feed automatically. Use --bump on every new release so the build number goes up.
cd "$(dirname "$0")"; set -e
if [[ "$1" == "--bump" ]]; then echo $(( $(cat BUILD) + 1 )) > BUILD; shift; fi
OUT=${1:?usage: ./release.sh [--bump] <update folder> [notes] [base URL]}
NOTES=${2:-$(cat RELEASE_NOTES.md 2>/dev/null || true)}
BASE=${3:-}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
./build.sh > /dev/null
VERSION=$(cat VERSION); BUILD=$(cat BUILD)
ZIP="FreeOffice-$VERSION-$BUILD.zip"
rm -f "$OUT/$ZIP"
( cd dist && zip -qry "$OUT/$ZIP" *.app )
SHA=$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)
URL="$ZIP"; [[ -n "$BASE" ]] && URL="${BASE%/}/$ZIP"
python3 - "$OUT/appcast.json" "$VERSION" "$BUILD" "$NOTES" "$URL" "$SHA" <<'PY'
import json, sys
out, version, build, notes, url, sha = sys.argv[1:7]
json.dump({"version": version, "build": int(build), "notes": notes, "url": url, "sha256": sha}, open(out, "w"), indent=2)
PY
echo "Published FreeOffice $VERSION (build $BUILD)"
echo "  $OUT/$ZIP"
echo "  $OUT/appcast.json"
