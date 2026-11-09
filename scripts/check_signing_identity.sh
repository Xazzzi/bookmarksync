#!/bin/bash
# Simulate an update: the resource seal changes while the designated requirement stays identical.
set -euo pipefail
APP_PATH="${1:?Usage: check_signing_identity.sh path/to/signed/BookmarkSync.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bookmarksync-update-check.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
UPDATED_APP="$WORK_DIR/BookmarkSync.app"
ditto "$APP_PATH" "$UPDATED_APP"
printf 'Signature update regression check\n' > "$UPDATED_APP/Contents/Resources/signature-update-check.txt"
bash "$SCRIPT_DIR/sign_app.sh" "$UPDATED_APP"
original_requirement="$(codesign --display --requirements - "$APP_PATH" 2>&1 | sed -n 's/^designated => //p')"
updated_requirement="$(codesign --display --requirements - "$UPDATED_APP" 2>&1 | sed -n 's/^designated => //p')"
original_hash="$(codesign --display --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^CDHash=//p')"
updated_hash="$(codesign --display --verbose=4 "$UPDATED_APP" 2>&1 | sed -n 's/^CDHash=//p')"
[[ -n "$original_requirement" && "$original_requirement" == "$updated_requirement" ]]
[[ -n "$original_hash" && -n "$updated_hash" && "$original_hash" != "$updated_hash" ]]
codesign --verify --strict -R "=$original_requirement" "$UPDATED_APP"
printf 'PASS: changed app content retains the original designated requirement.\n'
