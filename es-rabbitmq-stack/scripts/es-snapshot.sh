#!/usr/bin/env bash
# Snapshot toàn bộ index pitel* vào repo local_fs (volume es-snapshots).
# Cron gợi ý (host): 15 2 * * *  cd /opt/es-rabbitmq-stack && ./scripts/es-snapshot.sh
# Giữ lại KEEP bản mới nhất. Nên rsync/restic volume snapshot ra off-site (S3/CMC Object Storage).
source "$(dirname "$0")/lib.sh"
require docker jq
load_env
KEEP="${KEEP:-7}"
AUTH="$(printf 'elastic:%s' "$ELASTIC_PASSWORD" | base64 -w0)"; export AUTH

es() { # METHOD PATH [BODY]
  # shellcheck disable=SC2016  # biến được expand bên trong container, có chủ đích
  dc exec -T -e AUTH es sh -c '
    m="$1"; p="$2"; shift 2
    if [ -n "${1:-}" ]; then set -- --data-binary "$1"; fi
    curl -fsS -X "$m" "http://localhost:9200$p" -H "Content-Type: application/json" \
      "$@" -K /dev/fd/3 3<<EOC
header = "Authorization: Basic $AUTH"
EOC' _ "$@"
}

name="snap-$(date -u +%Y%m%d-%H%M%S)"
body="$(jq -nc --arg i "$ES_INDEX_PATTERNS" '{indices:$i, include_global_state:false}')"
es PUT "/_snapshot/local_fs/$name?wait_for_completion=true" "$body" \
  | jq -e '.snapshot.state == "SUCCESS"' >/dev/null || die "snapshot $name failed"
info "snapshot $name SUCCESS"

mapfile -t old < <(es GET "/_snapshot/local_fs/_all" | jq -r '.snapshots | sort_by(.start_time_in_millis) | .[:-'"$KEEP"'][] .snapshot')
for s in "${old[@]}"; do
  [[ -n "$s" ]] || continue
  es DELETE "/_snapshot/local_fs/$s" >/dev/null && info "deleted old snapshot $s"
done
