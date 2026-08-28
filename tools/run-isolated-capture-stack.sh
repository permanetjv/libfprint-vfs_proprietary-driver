#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

: "${VFS495_CAPTURE_HELPER:?set VFS495_CAPTURE_HELPER to the built helper}"
export VFS495_STACK_SUPERVISOR=$repo_root/tools/legacy-stack-supervisor.sh

exec "$repo_root/tools/run-legacy-component-isolated.sh" stack
