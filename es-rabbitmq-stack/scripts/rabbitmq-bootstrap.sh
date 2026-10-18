#!/usr/bin/env bash
# Idempotent RabbitMQ bootstrap: vhost, users, permissions; removes `guest`.
source "$(dirname "$0")/lib.sh"
require docker
load_env

# Credentials are passed as container env (-e NAME, value read from host env),
# never on the host command line.
# shellcheck disable=SC2016  # expanded inside the container on purpose
rmq_userctl() {   # add_user|change_password
  dc exec -T -e RMQ_U -e RMQ_P rabbitmq sh -c 'rabbitmqctl -q "$0" "$RMQ_U" "$RMQ_P"' "$1"
}
ctl() { dc exec -T rabbitmq rabbitmqctl -q "$@"; }

info "waiting for RabbitMQ"
for _ in $(seq 1 60); do ctl await_startup >/dev/null 2>&1 && break; sleep 5; done
ctl status >/dev/null || die "RabbitMQ not ready"

ctl list_vhosts name | grep -qx "$RMQ_VHOST" || { ctl add_vhost "$RMQ_VHOST"; info "vhost $RMQ_VHOST created"; }

ensure_user() {   # user pass tags
  local u="$1" p="$2" tags="$3"
  export RMQ_U="$u" RMQ_P="$p"
  if ctl list_users | awk '{print $1}' | grep -qx "$u"; then
    rmq_userctl change_password >/dev/null; info "user $u password synced"
  else
    rmq_userctl add_user >/dev/null; info "user $u created"
  fi
  unset RMQ_U RMQ_P
  # shellcheck disable=SC2086
  ctl set_user_tags "$u" $tags
}

set_perms() {     # user "configure write read" vhost
  local u="$1" c w r; read -r c w r <<<"$2"
  ctl set_permissions -p "$3" "$u" "$c" "$w" "$r"
  info "perms $u@$3 configure='$c' write='$w' read='$r'"
}

ensure_user "$RMQ_ADMIN_USER"     "$RMQ_ADMIN_PASS"     administrator
ensure_user "$RMQ_ESWRITER_USER"  "$RMQ_ESWRITER_PASS"  ""
ensure_user "$RMQ_PUBLISHER_USER" "$RMQ_PUBLISHER_PASS" ""

set_perms "$RMQ_ADMIN_USER"     ".* .* .*"              "$RMQ_VHOST"
set_perms "$RMQ_ADMIN_USER"     ".* .* .*"              "/"
set_perms "$RMQ_ESWRITER_USER"  "$RMQ_ESWRITER_PERMS"   "$RMQ_VHOST"
set_perms "$RMQ_PUBLISHER_USER" "$RMQ_PUBLISHER_PERMS"  "$RMQ_VHOST"

if ctl list_users | awk '{print $1}' | grep -qx guest; then
  ctl delete_user guest; info "default user guest deleted"
fi
info "RabbitMQ bootstrap done"
