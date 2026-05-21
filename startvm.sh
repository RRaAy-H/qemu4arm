#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
exec ./install-arm64-vm.sh run
