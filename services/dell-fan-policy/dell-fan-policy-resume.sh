#!/usr/bin/env bash
set -euo pipefail

# Reassert fan-policy ownership after suspend/hibernate transitions.

case "${1:-}" in
    post)
        systemctl restart dell-fan-policy.service
        ;;
esac
