#!/usr/bin/env bash
# This deply script syncs current state of the project to GCP box
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
cd "Website"

echo "In $PWD"
SSH="ssh -i ~/.ssh/google_compute_engine"
rsync -rlptvzP --no-p -e "$SSH" ./ xazi.app:~/bookmarksync/
# Can add --delete flag above to clean destination from previous deployments
