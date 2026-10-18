#!/usr/bin/env bash
# Host checks before `make up`. Non-zero exit on blocking issues.
source "$(dirname "$0")/lib.sh"
require docker curl jq getent
load_env

docker compose version >/dev/null || die "docker compose v2 plugin required"

mmc="$(sysctl -n vm.max_map_count)"
(( mmc >= 262144 )) || die "vm.max_map_count=$mmc (<262144). Run: sysctl -w vm.max_map_count=262144 (Ansible sets it persistently)"

for p in 80 443 5671; do
  if ss -ltnH "sport = :$p" | grep -q .; then
    dc ps --format '{{.Publishers}}' 2>/dev/null | grep -q ":$p->" || die "port $p already in use by another process"
  fi
done

pub_ip="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
for d in "$ES_DOMAIN" "$RMQ_DOMAIN"; do
  ip="$(getent ahostsv4 "$d" | awk 'NR==1{print $1}')"
  [[ -n "$ip" ]] || die "DNS: $d does not resolve — create the A record first"
  if [[ -n "$pub_ip" && "$ip" != "$pub_ip" ]]; then
    warn "DNS: $d -> $ip but host egress IP is $pub_ip (OK if behind NAT/LB, else ACME HTTP-01 will fail)"
  else
    info "DNS: $d -> $ip"
  fi
done

[[ "${ES_ALLOWED_CIDRS},${AMQP_ALLOWED_CIDRS},${RMQ_MGMT_ALLOWED_CIDRS}" == *"0.0.0.0/0"* ]] \
  && warn "an allowlist contains 0.0.0.0/0 — service exposed to the whole Internet"

dc config -q || die "compose config invalid"
info "preflight OK"
