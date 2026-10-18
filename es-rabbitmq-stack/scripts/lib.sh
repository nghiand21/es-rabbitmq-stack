#!/usr/bin/env bash
# Shared helpers. Source, don't execute.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '{"ts":"%s","level":"%s","script":"%s","msg":"%s"}\n' \
           "$(date -u +%FT%TZ)" "$1" "$(basename "$0")" "${*:2}" >&2; }
info() { log info "$@"; }
warn() { log warn "$@"; }
die()  { log error "$@"; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

load_env() {
  [[ -f .env ]] || die ".env not found — cp .env.example .env && ./scripts/gen-secrets.sh"
  local perm; perm="$(stat -c '%a' .env)"
  [[ "$perm" == "600" || "$perm" == "400" ]] || die ".env permission is $perm, run: chmod 600 .env"
  if grep -qE '^[A-Z_]+=CHANGE_ME' .env; then die ".env still contains CHANGE_ME — run ./scripts/gen-secrets.sh"; fi
  set -a; # shellcheck disable=SC1091
  source .env; set +a
}

dc() { docker compose "$@"; }

require() { for b in "$@"; do command -v "$b" >/dev/null || die "missing binary: $b"; done; }
