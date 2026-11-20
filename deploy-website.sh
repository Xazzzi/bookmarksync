#!/usr/bin/env bash
# Deploys the website to Cloudflare.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

npx wrangler deploy
