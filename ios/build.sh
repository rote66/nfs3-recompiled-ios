#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
exec "$repo_root/build.sh" "$@"
