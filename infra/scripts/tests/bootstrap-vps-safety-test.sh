#!/usr/bin/env bash

# The production scripts intentionally contain remote heredocs. This test
# extracts those reviewed payloads and runs them against file-backed fakes.
# shellcheck disable=SC2016

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$test_dir/../../.." && pwd)
bootstrap="$repo_root/infra/scripts/bootstrap-vps.sh"
tls_setup="$repo_root/infra/scripts/setup-vps-tls.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/apollo-bootstrap-tests.XXXXXX")

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local expected="$1" file="$2"
  grep -Fq -- "$expected" "$file" \
    || fail "Expected '$expected' in $file"
}

assert_file_absent() {
  local unexpected="$1" file="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "Did not expect '$unexpected' in $file"
  fi
}

assert_equal() {
  local expected="$1" actual="$2" context="$3"
  [ "$expected" = "$actual" ] \
    || fail "$context: expected '$expected', got '$actual'"
}

fake_bin="$test_root/bin"
firewall_state="$test_root/firewall-state"
policy_state="$test_root/policy-state"
mkdir -p "$fake_bin" "$firewall_state" "$policy_state"

# Extract the exact root-owned helper installed by bootstrap-vps.sh.
firewall_helper="$test_root/apollo-docker-firewall"
awk '
  /^cat >"\$docker_firewall_tmp" <<'\''DOCKER_FIREWALL'\''$/ { capture = 1; next }
  capture && $0 == "DOCKER_FIREWALL" { exit }
  capture { print }
' "$bootstrap" >"$firewall_helper"
assert_file_contains 'bridge_outputs=(docker0 '\''br+'\'')' "$firewall_helper"
sed "s#^state_dir=/etc/apollo\$#state_dir=$policy_state#" \
  "$firewall_helper" >"$firewall_helper.rewritten"
mv -- "$firewall_helper.rewritten" "$firewall_helper"
chmod 0700 "$firewall_helper"

cat >"$fake_bin/iptables" <<'FAKE_IPTABLES'
#!/usr/bin/env bash
set -euo pipefail

family=4
[ "${0##*/}" = ip6tables ] && family=6
root=${APOLLO_FIREWALL_TEST_STATE:?}
chains="$root/chains-$family"
rules="$root/rules-$family"
log="$root/commands.log"
touch "$chains" "$rules" "$log"
printf '%s %s\n' "$family" "$*" >>"$log"

if [ "${1:-}" = -w ]; then
  shift 2
fi

chain_exists() {
  grep -Fxq -- "$1" "$chains"
}

case "${1:-}" in
  -n)
    [ "${2:-}" = -L ] || exit 64
    chain_exists "$3"
    ;;
  -S)
    if [ "$#" -eq 1 ]; then
      while IFS= read -r chain; do
        [ -n "$chain" ] && printf '%s\n' "-N $chain"
      done <"$chains"
      while IFS='|' read -r chain arguments; do
        [ -n "$chain" ] && printf '%s\n' "-A $chain $arguments"
      done <"$rules"
    else
      chain=$2
      chain_exists "$chain" || exit 1
      while IFS='|' read -r rule_chain arguments; do
        [ "$rule_chain" = "$chain" ] \
          && printf '%s\n' "-A $rule_chain $arguments"
      done <"$rules"
    fi
    ;;
  -N)
    chain_exists "$2" && exit 1
    printf '%s\n' "$2" >>"$chains"
    ;;
  -A)
    chain=$2
    shift 2
    chain_exists "$chain" || exit 1
    printf '%s|%s\n' "$chain" "$*" >>"$rules"
    ;;
  -I)
    chain=$2
    shift 2
    [ "${1:-}" = 1 ] && shift
    chain_exists "$chain" || exit 1
    row="$chain|$*"
    temporary="$rules.tmp.$$"
    inserted=false
    while IFS= read -r existing; do
      if [ "$inserted" = false ] && [[ "$existing" == "$chain|"* ]]; then
        printf '%s\n' "$row"
        inserted=true
      fi
      printf '%s\n' "$existing"
    done <"$rules" >"$temporary"
    [ "$inserted" = true ] || printf '%s\n' "$row" >>"$temporary"
    mv -- "$temporary" "$rules"
    ;;
  -C)
    chain=$2
    shift 2
    grep -Fxq -- "$chain|$*" "$rules"
    ;;
  -D)
    chain=$2
    shift 2
    wanted="$chain|$*"
    temporary="$rules.tmp.$$"
    removed=false
    while IFS= read -r existing; do
      if [ "$removed" = false ] && [ "$existing" = "$wanted" ]; then
        removed=true
        continue
      fi
      printf '%s\n' "$existing"
    done <"$rules" >"$temporary"
    [ "$removed" = true ] || { rm -f -- "$temporary"; exit 1; }
    mv -- "$temporary" "$rules"
    ;;
  -F)
    chain=$2
    temporary="$rules.tmp.$$"
    awk -F '|' -v chain="$chain" '$1 != chain' "$rules" >"$temporary"
    mv -- "$temporary" "$rules"
    ;;
  -X)
    chain=$2
    if grep -F -- "-j $chain" "$rules" >/dev/null 2>&1; then
      exit 1
    fi
    temporary="$chains.tmp.$$"
    grep -Fvx -- "$chain" "$chains" >"$temporary" || true
    mv -- "$temporary" "$chains"
    ;;
  *)
    exit 64
    ;;
esac
FAKE_IPTABLES
chmod 0700 "$fake_bin/iptables"
ln -s iptables "$fake_bin/ip6tables"

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

root=${APOLLO_DOCKER_TEST_STATE:-}
[ -n "$root" ] && printf '%s\n' "$*" >>"$root/commands.log"
case "${APOLLO_DOCKER_TEST_MODE:-none}:$*" in
  live-restore:'--version')
    printf '%s\n' 'Docker version test'
    ;;
  live-restore:'info')
    exit 0
    ;;
  live-restore:'info --format {{.LiveRestoreEnabled}}')
    printf '%s\n' true
    ;;
  helper-stopped:'container inspect apollo-platform-nginx'|helper-wrong-policy:'container inspect apollo-platform-nginx'|helper-flaky:'container inspect apollo-platform-nginx'|helper-short-lived:'container inspect apollo-platform-nginx'|helper-running-short-lived:'container inspect apollo-platform-nginx')
    exit 0
    ;;
  helper-absent:'container inspect apollo-platform-nginx')
    exit 1
    ;;
  helper-stopped:'inspect --format={{.HostConfig.RestartPolicy.Name}} apollo-platform-nginx'|helper-flaky:'inspect --format={{.HostConfig.RestartPolicy.Name}} apollo-platform-nginx'|helper-short-lived:'inspect --format={{.HostConfig.RestartPolicy.Name}} apollo-platform-nginx'|helper-running-short-lived:'inspect --format={{.HostConfig.RestartPolicy.Name}} apollo-platform-nginx')
    printf '%s\n' on-failure
    ;;
  helper-wrong-policy:'inspect --format={{.HostConfig.RestartPolicy.Name}} apollo-platform-nginx')
    printf '%s\n' unless-stopped
    ;;
  helper-stopped:'inspect --format={{.State.Running}} apollo-platform-nginx'|helper-flaky:'inspect --format={{.State.Running}} apollo-platform-nginx')
    if [ -f "$root/helper-started-nginx" ]; then
      printf '%s\n' true
    else
      printf '%s\n' false
    fi
    ;;
  helper-stopped:'start apollo-platform-nginx')
    : >"$root/helper-started-nginx"
    ;;
  helper-flaky:'start apollo-platform-nginx')
    count_file="$root/helper-start-count"
    count=0
    [ -f "$count_file" ] && count=$(<"$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      exit 47
    fi
    : >"$root/helper-started-nginx"
    ;;
  helper-short-lived:'inspect --format={{.State.Running}} apollo-platform-nginx')
    start_count=0
    [ -f "$root/helper-start-count" ] && start_count=$(<"$root/helper-start-count")
    if [ "$start_count" -eq 0 ]; then
      printf '%s\n' false
    elif [ "$start_count" -eq 1 ]; then
      check_count=0
      [ -f "$root/helper-running-check-count" ] \
        && check_count=$(<"$root/helper-running-check-count")
      check_count=$((check_count + 1))
      printf '%s\n' "$check_count" >"$root/helper-running-check-count"
      if [ "$check_count" -le 3 ]; then
        printf '%s\n' true
      else
        printf '%s\n' false
      fi
    else
      printf '%s\n' true
    fi
    ;;
  helper-short-lived:'start apollo-platform-nginx')
    start_count=0
    [ -f "$root/helper-start-count" ] && start_count=$(<"$root/helper-start-count")
    start_count=$((start_count + 1))
    printf '%s\n' "$start_count" >"$root/helper-start-count"
    : >"$root/helper-started-nginx"
    ;;
  helper-running-short-lived:'inspect --format={{.State.Running}} apollo-platform-nginx')
    check_count=0
    [ -f "$root/helper-running-check-count" ] \
      && check_count=$(<"$root/helper-running-check-count")
    check_count=$((check_count + 1))
    printf '%s\n' "$check_count" >"$root/helper-running-check-count"
    if [ "$check_count" -le 3 ]; then
      printf '%s\n' true
    else
      printf '%s\n' false
    fi
    ;;
  nginx-fail:'container inspect apollo-platform-nginx'|nginx-success:'container inspect apollo-platform-nginx')
    exit 0
    ;;
  nginx-fail:'inspect --format={{.State.Running}} apollo-platform-nginx'|nginx-success:'inspect --format={{.State.Running}} apollo-platform-nginx')
    printf '%s\n' true
    ;;
  nginx-fail:'exec apollo-platform-nginx nginx -t')
    count_file="$root/nginx-test-count"
    count=0
    [ -f "$count_file" ] && count=$(<"$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    [ "$count" -gt 1 ]
    ;;
  nginx-success:'exec apollo-platform-nginx nginx -t')
    exit 0
    ;;
  nginx-fail:'exec apollo-platform-nginx nginx -s reload'|nginx-success:'exec apollo-platform-nginx nginx -s reload'|nginx-fail:'start apollo-platform-nginx'|nginx-success:'start apollo-platform-nginx'|nginx-fail:'stop apollo-platform-nginx'|nginx-success:'stop apollo-platform-nginx')
    exit 0
    ;;
  rollback-safe:'restart apollo-platform-nginx'|rollback-safe:'start apollo-platform-nginx'|rollback-safe:'exec apollo-platform-nginx nginx -t')
    exit 0
    ;;
  none:'container inspect apollo-platform-nginx')
    exit 1
    ;;
  *)
    exit 64
    ;;
esac
FAKE_DOCKER
chmod 0700 "$fake_bin/docker"

cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod 0700 "$fake_bin/sleep"

cat >"$fake_bin/base64" <<'FAKE_BASE64'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --decode ]; then
  python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))'
else
  exec /usr/bin/base64 "$@"
fi
FAKE_BASE64
chmod 0700 "$fake_bin/base64"

# Cloudflare mode depends on Docker's iptables/DOCKER-USER contract. Exercise
# the exact installed validator against safe, nftables, disabled-iptables, and
# deferred-command-line configurations before any daemon-start test.
backend_state="$test_root/backend-state"
backend_config="$test_root/daemon.json"
mkdir -p "$backend_state"
printf '%s\n' cloudflare >"$backend_state/https-access-mode"
backend_validator="$test_root/apollo-validate-docker-firewall-backend"
awk '
  /^cat >"\$docker_backend_validator_tmp" <<'\''DOCKER_BACKEND_VALIDATOR'\''$/ { capture = 1; next }
  capture && $0 == "DOCKER_BACKEND_VALIDATOR" { exit }
  capture { print }
' "$bootstrap" >"$backend_validator.original"
sed \
  -e "s#^state_dir=/etc/apollo\$#state_dir=$backend_state#" \
  -e "s#^daemon_config=/etc/docker/daemon.json\$#daemon_config=$backend_config#" \
  "$backend_validator.original" >"$backend_validator"
chmod 0700 "$backend_validator"

cat >"$fake_bin/systemctl" <<'FAKE_BACKEND_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'show --property=ExecStart --value docker.service' ]; then
  printf '%s\n' "${APOLLO_TEST_DOCKER_EXEC:-{ path=/usr/bin/dockerd ; argv[]=/usr/bin/dockerd -H fd:// ; }}"
  exit 0
fi
exit 1
FAKE_BACKEND_SYSTEMCTL
chmod 0700 "$fake_bin/systemctl"

rm -f -- "$backend_config"
PATH="$fake_bin:$PATH" bash "$backend_validator"
printf '%s\n' '{"firewall-backend":"nftables"}' >"$backend_config"
if PATH="$fake_bin:$PATH" bash "$backend_validator" >"$test_root/nftables-backend.out" 2>&1; then
  fail "Cloudflare mode accepted Docker's nftables firewall backend."
fi
assert_file_contains "requires Docker's iptables firewall backend" "$test_root/nftables-backend.out"
printf '%s\n' '{"iptables":false}' >"$backend_config"
if PATH="$fake_bin:$PATH" bash "$backend_validator" >"$test_root/iptables-disabled.out" 2>&1; then
  fail 'Cloudflare mode accepted Docker with iptables disabled.'
fi
printf '%s\n' '{"firewall-backend":"iptables","iptables":true}' >"$backend_config"
if APOLLO_TEST_DOCKER_EXEC='dockerd --firewall-backend=nftables' \
  PATH="$fake_bin:$PATH" bash "$backend_validator" >"$test_root/backend-override.out" 2>&1; then
  fail 'Cloudflare mode accepted a command-line Docker firewall override.'
fi
assert_file_contains 'unsupported deferred or firewall override' "$test_root/backend-override.out"
if APOLLO_TEST_DOCKER_EXEC='{ path=/usr/local/sbin/dockerd-wrapper ; argv[]=/usr/local/sbin/dockerd-wrapper ; }' \
  PATH="$fake_bin:$PATH" bash "$backend_validator" >"$test_root/backend-wrapper.out" 2>&1; then
  fail 'Cloudflare mode accepted an opaque Docker ExecStart wrapper.'
fi
assert_file_contains 'not the allowlisted packaged dockerd binary' "$test_root/backend-wrapper.out"
if APOLLO_TEST_DOCKER_EXEC='$DOCKER_OPTS' \
  PATH="$fake_bin:$PATH" bash "$backend_validator" >"$test_root/backend-deferred.out" 2>&1; then
  fail 'Cloudflare mode accepted deferred Docker daemon arguments.'
fi
printf '%s\n' direct >"$backend_state/https-access-mode"
printf '%s\n' '{"firewall-backend":"nftables"}' >"$backend_config"
PATH="$fake_bin:$PATH" bash "$backend_validator"
printf '%s\n' cloudflare >"$backend_state/https-access-mode"
printf '%s\n' '{"firewall-backend":"iptables","iptables":true}' >"$backend_config"

printf '%s\n' FORWARD >"$firewall_state/chains-4"
: >"$firewall_state/rules-4"
printf '%s\n' FORWARD >"$firewall_state/chains-6"
: >"$firewall_state/rules-6"
: >"$firewall_state/commands.log"
printf '%s\n' cloudflare >"$policy_state/https-access-mode"
printf '%s\n' '173.245.48.0/20' >"$policy_state/cloudflare-ips-v4"
printf '%s\n' '2400:cb00::/32' >"$policy_state/cloudflare-ips-v6"

run_firewall() {
  PATH="$fake_bin:$PATH" \
    APOLLO_FIREWALL_TEST_STATE="$firewall_state" \
    APOLLO_DOCKER_TEST_STATE="$firewall_state" \
    APOLLO_DOCKER_TEST_MODE=none \
    bash "$firewall_helper" "$@"
}

iptables_test() {
  PATH="$fake_bin:$PATH" \
    APOLLO_FIREWALL_TEST_STATE="$firewall_state" \
    "$fake_bin/iptables" "$@"
}

ipv4_to_integer() {
  local address="$1" a b c d
  IFS=. read -r a b c d <<<"$address"
  IPV4_INTEGER=$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

ipv4_in_cidr() {
  local address="$1" cidr="$2" network prefix mask address_integer network_integer
  IFS=/ read -r network prefix <<<"$cidr"
  ipv4_to_integer "$address"
  address_integer=$IPV4_INTEGER
  ipv4_to_integer "$network"
  network_integer=$IPV4_INTEGER
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  (( (address_integer & mask) == (network_integer & mask) ))
}

chain_verdict() {
  local chain="$1" source="$2" output="$3" connection_state="$4"
  local rule_chain arguments target rule_output rule_source states token index matches
  local -a tokens

  while IFS='|' read -r rule_chain arguments; do
    [ "$rule_chain" = "$chain" ] || continue
    read -r -a tokens <<<"$arguments"
    target=''
    rule_output=''
    rule_source=''
    states=''
    index=0
    while [ "$index" -lt "${#tokens[@]}" ]; do
      token=${tokens[$index]}
      case "$token" in
        -j) index=$((index + 1)); target=${tokens[$index]} ;;
        -o) index=$((index + 1)); rule_output=${tokens[$index]} ;;
        -s) index=$((index + 1)); rule_source=${tokens[$index]} ;;
        --ctstate) index=$((index + 1)); states=${tokens[$index]} ;;
      esac
      index=$((index + 1))
    done

    matches=true
    if [ -n "$rule_output" ]; then
      case "$rule_output" in
        *+) [[ "$output" == "${rule_output%+}"* ]] || matches=false ;;
        *) [ "$output" = "$rule_output" ] || matches=false ;;
      esac
    fi
    if [ "$matches" = true ] && [ -n "$rule_source" ]; then
      ipv4_in_cidr "$source" "$rule_source" || matches=false
    fi
    if [ "$matches" = true ] && [ -n "$states" ]; then
      case ",$states," in
        *",$connection_state,"*) ;;
        *) matches=false ;;
      esac
    fi
    [ "$matches" = true ] || continue

    case "$target" in
      DROP|RETURN) printf '%s\n' "$target"; return 0 ;;
      APOLLO-H4-*) chain_verdict "$target" "$source" "$output" "$connection_state"; return 0 ;;
    esac
  done <"$firewall_state/rules-4"
  printf '%s\n' RETURN
}

packet_verdict() {
  local source="$1" output="$2" connection_state="${3:-NEW}"
  if ! grep -Fxq -- 'FORWARD|-j DOCKER-USER' "$firewall_state/rules-4"; then
    printf '%s\n' NO-FORWARD-JUMP
    return
  fi
  chain_verdict DOCKER-USER "$source" "$output" "$connection_state"
}

# Cold start: the pre-hook creates only inbound bridge guards. Docker then adds
# its FORWARD jump before it can restore a published container.
run_firewall --guard >/dev/null
assert_file_contains 'DOCKER-USER|-o docker0 -p tcp --dport 443 -m comment --comment Apollo HTTPS fail-closed guard -j DROP' "$firewall_state/rules-4"
assert_file_contains 'DOCKER-USER|-o br+ -p tcp --dport 443 -m comment --comment Apollo HTTPS fail-closed guard -j DROP' "$firewall_state/rules-4"
assert_file_absent 'DOCKER-USER|-p tcp --dport 443 -m comment --comment Apollo HTTPS fail-closed guard -j DROP' "$firewall_state/rules-4"
iptables_test -A FORWARD -j DOCKER-USER
iptables_test -A DOCKER-USER -j RETURN
assert_equal DROP "$(packet_verdict 203.0.113.9 br-apollo)" 'Direct inbound HTTPS during Docker auto-restore'
assert_equal RETURN "$(packet_verdict 172.18.0.5 eth0)" 'Container-originated HTTPS during Docker auto-restore'

run_firewall >/dev/null
assert_equal RETURN "$(packet_verdict 173.245.48.5 br-apollo)" 'Cloudflare inbound HTTPS'
assert_equal DROP "$(packet_verdict 203.0.113.9 br-apollo)" 'Direct inbound HTTPS'
assert_equal RETURN "$(packet_verdict 172.18.0.5 eth0)" 'Container-originated HTTPS'

# A second run must converge without duplicate generations or jumps.
run_firewall >/dev/null
[ "$(grep -Ec '^APOLLO-H4-' "$firewall_state/chains-4")" -eq 1 ] \
  || fail 'Idempotent firewall re-run retained duplicate IPv4 generations.'
[ "$(grep -Ec '^DOCKER-USER\|-o (docker0|br\+) -p tcp --dport 443 -j APOLLO-H4-' "$firewall_state/rules-4")" -eq 2 ] \
  || fail 'Idempotent firewall re-run did not retain exactly two scoped jumps.'

# A daemon restart executes guard before auto-restore and post-apply afterwards.
printf '%s\n' pre-hook >"$firewall_state/restart-events"
run_firewall --guard >/dev/null
printf '%s\n' docker-auto-restore >>"$firewall_state/restart-events"
assert_equal DROP "$(packet_verdict 203.0.113.9 br-apollo)" 'Direct inbound HTTPS at restart auto-restore'
assert_equal RETURN "$(packet_verdict 172.18.0.5 eth0)" 'Outbound HTTPS at restart auto-restore'
printf '%s\n' post-hook >>"$firewall_state/restart-events"
run_firewall >/dev/null
assert_equal $'pre-hook\ndocker-auto-restore\npost-hook' "$(cat "$firewall_state/restart-events")" 'Docker restart hook order'

# Upgrade cleanup recognizes directionless legacy jumps/guards. A bad refresh
# leaves the scoped emergency guard in place without blocking container egress.
iptables_test -N APOLLO-H4-999
iptables_test -A APOLLO-H4-999 -j RETURN
iptables_test -I DOCKER-USER 1 -p tcp --dport 443 -j APOLLO-H4-999
iptables_test -I DOCKER-USER 1 -p tcp --dport 443 -m comment --comment 'Apollo HTTPS fail-closed guard' -j DROP
printf '%s\n' invalid >"$policy_state/cloudflare-ips-v4"
if run_firewall >"$test_root/invalid-refresh.out" 2>&1; then
  fail 'An invalid Cloudflare refresh unexpectedly succeeded.'
fi
assert_file_absent 'DOCKER-USER|-p tcp --dport 443 -j APOLLO-H4-999' "$firewall_state/rules-4"
assert_file_absent 'DOCKER-USER|-p tcp --dport 443 -m comment --comment Apollo HTTPS fail-closed guard -j DROP' "$firewall_state/rules-4"
assert_equal DROP "$(packet_verdict 173.245.48.5 br-apollo)" 'Inbound HTTPS after failed refresh'
assert_equal RETURN "$(packet_verdict 172.18.0.5 eth0)" 'Outbound HTTPS after failed refresh'

printf '%s\n' '198.41.128.0/17' >"$policy_state/cloudflare-ips-v4"
run_firewall >/dev/null
assert_equal DROP "$(packet_verdict 173.245.48.5 br-apollo)" 'Removed Cloudflare range'
assert_equal RETURN "$(packet_verdict 198.41.128.5 br-apollo)" 'Refreshed Cloudflare range'

printf '%s\n' direct >"$policy_state/https-access-mode"
run_firewall --guard >/dev/null
run_firewall >/dev/null
if grep -Eq 'APOLLO-H4-|Apollo HTTPS fail-closed guard' "$firewall_state/rules-4"; then
  fail 'Direct mode retained a managed Cloudflare jump or guard.'
fi
if grep -Eq '^APOLLO-H4-' "$firewall_state/chains-4"; then
  fail 'Direct mode retained a managed Cloudflare chain.'
fi
assert_equal RETURN "$(packet_verdict 203.0.113.9 br-apollo)" 'Explicit direct-mode inbound HTTPS'
assert_equal RETURN "$(packet_verdict 172.18.0.5 eth0)" 'Direct-mode container HTTPS'

# Cloudflare mode refuses Docker live-restore because it lets the published
# container survive outside the ordered daemon policy/start lifecycle.
docker_install_payload="$test_root/docker-install-remote.sh"
awk '
  $0 == "remote_root_bash <<'\''DOCKER_INSTALL_REMOTE'\''" { capture = 1; next }
  capture && $0 == "DOCKER_INSTALL_REMOTE" { exit }
  capture { print }
' "$bootstrap" >"$docker_install_payload.original"
sed "s#/usr/local/sbin/apollo-validate-docker-firewall-backend#$backend_validator#g" \
  "$docker_install_payload.original" >"$docker_install_payload"
assert_file_contains "Live-restored containers can outlive the daemon policy/start gate." "$docker_install_payload"
cat >"$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
if [ "$*" = 'show --property=ExecStart --value docker.service' ]; then
  printf '%s\n' '{ path=/usr/bin/dockerd ; argv[]=/usr/bin/dockerd -H fd:// ; }'
fi
exit 0
FAKE_SYSTEMCTL
chmod 0700 "$fake_bin/systemctl"
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$firewall_state" \
  APOLLO_DOCKER_TEST_MODE=live-restore \
  APOLLO_SSH_USER=root \
  APOLLO_HTTPS_ACCESS_MODE=cloudflare \
  bash "$docker_install_payload" >"$test_root/live-restore.out" 2>&1; then
  fail 'Cloudflare mode accepted Docker live-restore.'
fi
assert_file_contains 'Cloudflare-only HTTPS requires Docker live-restore to be disabled.' "$test_root/live-restore.out"

# First convergence installs the complete gate before any intentional Docker
# start. Fresh package installation is runtime-masked so maintainer scripts
# cannot auto-start the daemon; brownfield stopped daemons use the same later
# enable/start and therefore the same pre/post hooks.
state_line=$(grep -nF 'mv -f -- "$https_mode_tmp" "$https_mode_file"' "$bootstrap" | cut -d: -f1)
validator_install_line=$(grep -nF 'install -o root -g root -m 0755 "$docker_backend_validator_tmp"' "$bootstrap" | cut -d: -f1)
helper_install_line=$(grep -nF 'install -o root -g root -m 0755 "$docker_firewall_tmp"' "$bootstrap" | cut -d: -f1)
dropin_install_line=$(grep -nF 'install -o root -g root -m 0644 "$docker_firewall_dropin_tmp"' "$bootstrap" | cut -d: -f1)
docker_mask_line=$(grep -nF 'systemctl mask --runtime docker.service docker.socket' "$bootstrap" | cut -d: -f1)
docker_start_line=$(grep -nF 'systemctl enable --now docker.service' "$bootstrap" | cut -d: -f1)
[ -n "$state_line" ] && [ -n "$validator_install_line" ] && [ -n "$helper_install_line" ] \
  && [ -n "$dropin_install_line" ] && [ -n "$docker_mask_line" ] \
  && [ -n "$docker_start_line" ] \
  || fail 'Could not resolve the first-convergence Docker gate sequence.'
[ "$state_line" -lt "$validator_install_line" ] \
  && [ "$validator_install_line" -lt "$helper_install_line" ] \
  && [ "$helper_install_line" -lt "$dropin_install_line" ] \
  && [ "$dropin_install_line" -lt "$docker_mask_line" ] \
  && [ "$dropin_install_line" -lt "$docker_start_line" ] \
  || fail 'Docker can start before its persisted state, helper, and drop-in are installed.'
[ "$(grep -Fc 'systemctl enable --now docker.service' "$bootstrap")" -eq 1 ] \
  || fail 'Docker has more than one intentional activation path.'

mask_line=$(grep -nF 'systemctl mask --runtime docker.service docker.socket' "$docker_install_payload" | cut -d: -f1)
package_line=$(grep -nF 'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "$docker_install_payload" | head -1 | cut -d: -f1)
unmask_line=$(grep -nF '  remove_docker_runtime_mask' "$docker_install_payload" | head -1 | cut -d: -f1)
payload_start_line=$(grep -nF 'systemctl enable --now docker.service' "$docker_install_payload" | cut -d: -f1)
payload_validate_line=$(grep -nF "$backend_validator" "$docker_install_payload" | tail -1 | cut -d: -f1)
[ "$mask_line" -lt "$package_line" ] \
  && [ "$package_line" -lt "$unmask_line" ] \
  && [ "$payload_validate_line" -lt "$payload_start_line" ] \
  && [ "$unmask_line" -lt "$payload_start_line" ] \
  || fail 'Fresh Docker package installation is not masked through the post-install auto-start window.'

# The firewall hooks are intentionally unprefixed: any guard/policy failure
# fails Docker activation. ExecStartPre is ordered before daemon/container start.
dropin="$test_root/docker-dropin"
awk '
  /^cat >"\$docker_firewall_dropin_tmp" <<'\''DOCKER_FIREWALL_DROPIN'\''$/ { capture = 1; next }
  capture && $0 == "DOCKER_FIREWALL_DROPIN" { exit }
  capture { print }
' "$bootstrap" >"$dropin"
assert_file_contains 'ExecStartPre=/usr/local/sbin/apollo-docker-firewall --guard' "$dropin"
assert_file_contains 'ExecStartPre=/usr/local/sbin/apollo-validate-docker-firewall-backend' "$dropin"
assert_file_contains 'ExecStartPost=/usr/local/sbin/apollo-docker-firewall' "$dropin"
assert_file_contains 'After=ufw.service firewalld.service' "$dropin"
assert_file_absent 'Requires=ufw.service' "$dropin"
assert_file_absent 'Requires=firewalld.service' "$dropin"
assert_file_absent 'Wants=ufw.service' "$dropin"
assert_file_absent 'Wants=firewalld.service' "$dropin"
assert_file_absent 'ExecStartPre=-' "$dropin"
assert_file_absent 'apollo-start-platform-nginx' "$dropin"
backend_pre_line=$(grep -n '^ExecStartPre=/usr/local/sbin/apollo-validate-docker-firewall-backend$' "$dropin" | cut -d: -f1)
guard_pre_line=$(grep -n '^ExecStartPre=/usr/local/sbin/apollo-docker-firewall --guard$' "$dropin" | cut -d: -f1)
policy_post_line=$(grep -n '^ExecStartPost=/usr/local/sbin/apollo-docker-firewall$' "$dropin" | cut -d: -f1)
[ "$backend_pre_line" -lt "$guard_pre_line" ] \
  && [ "$guard_pre_line" -lt "$policy_post_line" ] \
  || fail 'Docker firewall hooks do not validate the backend before the guard and post-policy.'

# nginx start is a durable retrying unit, not an ignored Docker post-hook. It is
# stopped/restarted with Docker and cannot run until both Docker and the policy
# service are active.
nginx_unit="$test_root/apollo-start-platform-nginx.service"
awk '
  /^cat >"\$docker_nginx_unit_tmp" <<'\''DOCKER_NGINX_UNIT'\''$/ { capture = 1; next }
  capture && $0 == "DOCKER_NGINX_UNIT" { exit }
  capture { print }
' "$bootstrap" >"$nginx_unit"
assert_file_contains 'Requires=docker.service apollo-docker-firewall.service' "$nginx_unit"
assert_file_contains 'After=docker.service apollo-docker-firewall.service' "$nginx_unit"
assert_file_contains 'PartOf=docker.service' "$nginx_unit"
assert_file_contains 'StartLimitIntervalSec=0' "$nginx_unit"
assert_file_contains 'Restart=on-failure' "$nginx_unit"
assert_file_contains 'RestartSec=5s' "$nginx_unit"
assert_file_contains 'WantedBy=docker.service' "$nginx_unit"
assert_file_contains 'until systemctl is-active --quiet apollo-start-platform-nginx.service; do' "$docker_install_payload"
assert_file_contains 'nginx did not recover through its protected systemd start gate.' "$docker_install_payload"
assert_file_contains 'nginx is not deployed yet; its persistent protected start retry is armed.' "$docker_install_payload"

# Exercise the installed root-owned start helper. It starts a stopped container
# only under the protected on-failure lifecycle and rejects drifted policy.
nginx_start_helper="$test_root/apollo-start-platform-nginx"
awk '
  /^cat >"\$docker_nginx_start_tmp" <<'\''DOCKER_NGINX_START'\''$/ { capture = 1; next }
  capture && $0 == "DOCKER_NGINX_START" { exit }
  capture { print }
' "$bootstrap" >"$nginx_start_helper"
chmod 0700 "$nginx_start_helper"
helper_state="$test_root/helper-state"
mkdir -p "$helper_state"
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-absent \
  bash "$nginx_start_helper" >"$helper_state/absent.out" 2>&1; then
  fail 'The protected nginx start unit became successful before nginx existed.'
fi
assert_file_contains 'not deployed yet; keeping its protected start gate retrying.' \
  "$helper_state/absent.out"
PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-stopped \
  bash "$nginx_start_helper"
[ -f "$helper_state/helper-started-nginx" ] \
  || fail 'The post-policy helper did not start stopped nginx.'
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-wrong-policy \
  bash "$nginx_start_helper" >"$helper_state/wrong-policy.out" 2>&1; then
  fail 'The post-policy helper accepted an auto-restore restart policy.'
fi
assert_file_contains "restart policy 'unless-stopped'" "$helper_state/wrong-policy.out"

# The first start can fail transiently. The helper remains retry-safe and the
# unit contract above schedules an unbounded on-failure retry; the next attempt
# starts nginx without any Docker daemon restart.
rm -f -- "$helper_state/helper-started-nginx" "$helper_state/helper-start-count"
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-flaky \
  bash "$nginx_start_helper" >"$helper_state/flaky-first.out" 2>&1; then
  fail 'Injected first nginx helper failure unexpectedly succeeded.'
fi
PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-flaky \
  bash "$nginx_start_helper"
assert_equal 2 "$(cat "$helper_state/helper-start-count")" 'Persistent nginx start retry count'
[ -f "$helper_state/helper-started-nginx" ] \
  || fail 'The retrying nginx helper did not recover after its first failure.'

# A successful `docker start` is not sufficient: Docker only activates the
# restart policy after ten seconds. A short-lived first generation must keep
# the systemd unit failed so its persistent retry starts a healthy generation.
rm -f -- \
  "$helper_state/helper-started-nginx" \
  "$helper_state/helper-start-count" \
  "$helper_state/helper-running-check-count"
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-short-lived \
  bash "$nginx_start_helper" >"$helper_state/short-lived-first.out" 2>&1; then
  fail 'The nginx start gate accepted a container that exited inside ten seconds.'
fi
assert_file_contains 'exited before its Docker restart policy became active.' \
  "$helper_state/short-lived-first.out"
PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-short-lived \
  bash "$nginx_start_helper"
assert_equal 2 "$(cat "$helper_state/helper-start-count")" \
  'Short-lived nginx generation retry count'

# The same stability window applies when the helper finds nginx already
# running: it must not record permanent success just before that process exits.
running_helper_state="$test_root/running-helper-state"
mkdir -p "$running_helper_state"
if PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$running_helper_state" \
  APOLLO_DOCKER_TEST_MODE=helper-running-short-lived \
  bash "$nginx_start_helper" >"$running_helper_state/output" 2>&1; then
  fail 'The nginx start gate accepted an initially running short-lived container.'
fi
assert_file_contains 'exited before its Docker restart policy became active.' \
  "$running_helper_state/output"
assert_file_absent 'start apollo-platform-nginx' "$running_helper_state/commands.log"

policy_active_line=$(grep -n 'systemctl is-active --quiet apollo-docker-firewall.service' "$docker_install_payload" | cut -d: -f1)
policy_update_line=$(grep -n 'docker update --restart on-failure apollo-platform-nginx' "$docker_install_payload" | cut -d: -f1)
[ "$policy_active_line" -lt "$policy_update_line" ] \
  || fail 'Bootstrap changes nginx restart behavior before origin policy is active.'

platform_service="$repo_root/infra/terraform/modules/profiles/platform-api/modules/service/main.tf"
nginx_resource="$test_root/nginx-resource.tf"
platform_resource="$test_root/platform-resource.tf"
certbot_resource="$test_root/certbot-resource.tf"
extract_container_resource() {
  local resource_name="$1" destination="$2"
  awk -v resource_name="$resource_name" '
    $0 == "resource \"docker_container\" \"" resource_name "\" {" { capture = 1 }
    capture && /^resource / && $0 != "resource \"docker_container\" \"" resource_name "\" {" { exit }
    capture { print }
  ' "$platform_service" >"$destination"
  [ -s "$destination" ] || fail "Could not extract docker_container.$resource_name."
}
extract_container_resource nginx "$nginx_resource"
extract_container_resource platform "$platform_resource"
extract_container_resource certbot "$certbot_resource"
assert_file_contains 'restart = "on-failure"' "$nginx_resource"
assert_file_absent 'restart = "unless-stopped"' "$nginx_resource"
assert_file_contains 'restart = "unless-stopped"' "$platform_resource"
assert_file_absent 'restart = "on-failure"' "$platform_resource"
assert_file_contains 'restart = "unless-stopped"' "$certbot_resource"
assert_file_absent 'restart = "on-failure"' "$certbot_resource"
[ "$(grep -Fc 'restart = "on-failure"' "$platform_service")" -eq 1 ] \
  || fail 'on-failure was not limited to the externally published nginx container.'

# Exercise the embedded nginx transaction with a failed candidate validation.
nginx_payload="$test_root/nginx-sync-remote.sh"
awk '
  $0 == "remote_root_bash <<'\''NGINX_SYNC_REMOTE'\''" { capture = 1; next }
  capture && $0 == "NGINX_SYNC_REMOTE" { exit }
  capture { print }
' "$bootstrap" >"$nginx_payload.original"
assert_file_contains 'rollback_nginx_sync()' "$nginx_payload.original"

prepare_nginx_payload() {
  local live="$1" backup_parent="$2"
  awk -v live="$live" -v backup_parent="$backup_parent" '
    $0 == "nginx_root=/opt/apollo/platform/nginx" {
      printf "nginx_root=\"%s\"\n", live
      next
    }
    $0 == "backup_parent=/var/lib/apollo" {
      printf "backup_parent=\"%s\"\n", backup_parent
      next
    }
    /^if \[\[ ! "\$stage_root" =~/ {
      print "if [ ! -d \"$stage_root\" ] || [ -L \"$stage_root\" ]; then"
      getline
      next
    }
    /^if \[\[ ! "\$backup_dir" =~/ {
      print "if [ ! -d \"$backup_dir\" ]; then"
      next
    }
    /install -d -o root -g root -m 0700/ {
      sub(/ -o root -g root/, "")
      print
      next
    }
    { print }
  ' "$nginx_payload.original" >"$nginx_payload"
}

create_nginx_source() {
  local source="$1" required
  local -a required_files=(
    nginx.conf
    conf.d/00-default.conf
    conf.d/api-redirect.conf
    snippets/acme-challenge.conf
    snippets/locations-billing.conf
    snippets/locations-platform.conf
    snippets/locations-signal.conf
    snippets/proxy.conf
    snippets/security-headers.conf
    snippets/ssl-params.conf
  )
  for required in "${required_files[@]}"; do
    mkdir -p -- "$source/$(dirname -- "$required")"
    printf '# staged %s\n' "$required" >"$source/$required"
  done
}

run_nginx_sync_case() {
  local mode="$1" scenario live stage backup expected
  local encoded_stage encoded_ipv4 encoded_ipv6
  scenario="$test_root/nginx-$mode"
  live="$scenario/live"
  stage="$scenario/stage"
  backup="$scenario/backups"
  expected="$scenario/expected"
  mkdir -p "$live/conf.d" "$live/snippets" "$stage/source" "$scenario/docker"
  printf '%s\n' old-live-config >"$live/conf.d/old.conf"
  printf '%s\n' old-real-ip >"$live/snippets/cloudflare-real-ip.conf"
  cp -a -- "$live" "$expected"
  create_nginx_source "$stage/source"
  prepare_nginx_payload "$live" "$backup"
  encoded_stage=$(printf '%s' "$stage" | /usr/bin/base64 | tr -d '\n')
  encoded_ipv4=$(printf '%s\n' '173.245.48.0/20' | /usr/bin/base64 | tr -d '\n')
  encoded_ipv6=$(printf '%s\n' '2400:cb00::/32' | /usr/bin/base64 | tr -d '\n')

  if [ "$mode" = fail ]; then
    if PATH="$fake_bin:$PATH" \
      APOLLO_DOCKER_TEST_STATE="$scenario/docker" \
      APOLLO_DOCKER_TEST_MODE=nginx-fail \
      APOLLO_NGINX_REMOTE_STAGE_B64="$encoded_stage" \
      APOLLO_HTTPS_ACCESS_MODE=cloudflare \
      APOLLO_CLOUDFLARE_IPV4_B64="$encoded_ipv4" \
      APOLLO_CLOUDFLARE_IPV6_B64="$encoded_ipv6" \
      bash "$nginx_payload" >"$scenario/output" 2>&1; then
      fail 'Injected nginx candidate validation failure unexpectedly succeeded.'
    fi
    diff -r -- "$expected" "$live" >/dev/null \
      || fail 'Failed nginx candidate did not restore the exact previous live tree.'
    assert_file_contains 'exec apollo-platform-nginx nginx -s reload' "$scenario/docker/commands.log"
  else
    PATH="$fake_bin:$PATH" \
      APOLLO_DOCKER_TEST_STATE="$scenario/docker" \
      APOLLO_DOCKER_TEST_MODE=nginx-success \
      APOLLO_NGINX_REMOTE_STAGE_B64="$encoded_stage" \
      APOLLO_HTTPS_ACCESS_MODE=cloudflare \
      APOLLO_CLOUDFLARE_IPV4_B64="$encoded_ipv4" \
      APOLLO_CLOUDFLARE_IPV6_B64="$encoded_ipv6" \
      bash "$nginx_payload" >"$scenario/output" 2>&1
    assert_file_contains 'set_real_ip_from 173.245.48.0/20;' "$live/snippets/cloudflare-real-ip.conf"
    assert_file_contains 'set_real_ip_from 2400:cb00::/32;' "$live/snippets/cloudflare-real-ip.conf"
    assert_file_contains 'real_ip_header CF-Connecting-IP;' "$live/snippets/cloudflare-real-ip.conf"
  fi
}

run_nginx_sync_case fail
run_nginx_sync_case success

# Run TLS orchestration through a fake SSH transport. Candidate-start failure
# must invoke rollback; the rendered config must include the trusted-proxy
# snippet, and certbot must reuse the Terraform-resolved image without pulling.
tls_test="$test_root/tls"
mkdir -p "$tls_test"
cat >"$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail

root=${APOLLO_TLS_TEST_STATE:?}
printf '%s\n' "$*" >>"$root/ssh-argv.log"
case " $* " in
  *' StrictHostKeyChecking=yes '*) ;;
  *) exit 91 ;;
esac
case "$*" in
  *StrictHostKeyChecking=accept-new*) exit 92 ;;
  *'test -f /opt/apollo/platform/nginx/snippets/cloudflare-real-ip.conf'*) exit 0 ;;
  *"docker stop 'apollo-platform-nginx'"*) exit 0 ;;
  *'docker run --rm --pull=never'*)
    : >"$root/certbot-pull-never"
    exit 0
    ;;
  *'bash -s -- example-com')
    cat >/dev/null
    printf '%s\n' /opt/apollo/platform/nginx/.tls-rollback.FAKE123
    ;;
  *'bash -s -- /opt/apollo/platform/nginx/.tls-rollback.FAKE123 example-com')
    cat >/dev/null
    : >"$root/stale-removal-ran"
    ;;
  *"umask 077; cat > '/opt/apollo/platform/nginx/.tls-rollback.FAKE123/20-production.conf.candidate'"*)
    cat >"$root/production.conf"
    ;;
  *"docker start 'apollo-platform-nginx' >/dev/null")
    exit 47
    ;;
  *'bash -s -- /opt/apollo/platform/nginx/.tls-rollback.FAKE123 apollo-platform-nginx')
    cat >/dev/null
    : >"$root/rollback-ran"
    ;;
  *)
    exit 93
    ;;
esac
FAKE_SSH
chmod 0700 "$fake_bin/ssh"

set +e
PATH="$fake_bin:$PATH" APOLLO_TLS_TEST_STATE="$tls_test" \
  bash "$tls_setup" deploy@203.0.113.10 example.com ops@example.com \
  >"$tls_test/output" 2>&1
tls_status=$?
set -e
assert_equal 47 "$tls_status" 'TLS candidate-start failure status'
[ -f "$tls_test/rollback-ran" ] || fail 'TLS failure did not run nginx rollback.'
[ -f "$tls_test/stale-removal-ran" ] || fail 'TLS did not defer stale removal until after rollback identity validation.'
[ -f "$tls_test/certbot-pull-never" ] || fail 'TLS bootstrap omitted docker --pull=never.'
[ "$(grep -Fc '    include /etc/nginx/snippets/cloudflare-real-ip.conf;' "$tls_test/production.conf")" -eq 4 ] \
  || fail 'TLS production vhosts do not all include the trusted-proxy snippet.'
assert_file_contains 'server_name api.platform.example.com;' "$tls_test/production.conf"
assert_file_contains 'server_name api.signal.example.com;' "$tls_test/production.conf"
assert_file_contains 'server_name api.billing.example.com;' "$tls_test/production.conf"

# Execute the exact remote snapshot payload with failures at rollback-directory
# creation, live-config copy, and final ready-marker creation. Snapshot creation
# is copy-only, so none may alter the production vhost or any stale live file.
tls_snapshot_payload="$test_root/tls-snapshot-remote.sh"
awk '
  /<<'\''TLS_SNAPSHOT_REMOTE'\''$/ { capture = 1; next }
  capture && $0 == "TLS_SNAPSHOT_REMOTE" { exit }
  capture { print }
' "$tls_setup" >"$tls_snapshot_payload.original"

tls_snapshot_root="$test_root/tls-snapshot-root"
awk -v nginx_root="$tls_snapshot_root" '
  $0 == "nginx_root=/opt/apollo/platform/nginx" {
    printf "nginx_root=\"%s\"\n", nginx_root
    next
  }
  { print }
' "$tls_snapshot_payload.original" >"$tls_snapshot_payload"
chmod 0700 "$tls_snapshot_payload"

snapshot_fault_bin="$test_root/snapshot-fault-bin"
mkdir -p "$snapshot_fault_bin"
real_mktemp=$(command -v mktemp)
real_cp=$(command -v cp)
real_touch=$(command -v touch)
cat >"$snapshot_fault_bin/mktemp" <<'FAKE_SNAPSHOT_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
if [ "${APOLLO_TLS_SNAPSHOT_FAULT:-}" = rollback-dir ]; then
  exit 71
fi
exec "${APOLLO_REAL_MKTEMP:?}" "$@"
FAKE_SNAPSHOT_MKTEMP
cat >"$snapshot_fault_bin/cp" <<'FAKE_SNAPSHOT_CP'
#!/usr/bin/env bash
set -euo pipefail
if [ "${APOLLO_TLS_SNAPSHOT_FAULT:-}" = copy ]; then
  exit 72
fi
exec "${APOLLO_REAL_CP:?}" "$@"
FAKE_SNAPSHOT_CP
cat >"$snapshot_fault_bin/touch" <<'FAKE_SNAPSHOT_TOUCH'
#!/usr/bin/env bash
set -euo pipefail
last_argument=''
for last_argument in "$@"; do :; done
if [ "${APOLLO_TLS_SNAPSHOT_FAULT:-}" = marker ] \
  && [[ "$last_argument" == */snapshot-ready ]]; then
  exit 73
fi
exec "${APOLLO_REAL_TOUCH:?}" "$@"
FAKE_SNAPSHOT_TOUCH
chmod 0700 \
  "$snapshot_fault_bin/mktemp" \
  "$snapshot_fault_bin/cp" \
  "$snapshot_fault_bin/touch"

run_tls_snapshot_fault() {
  local fault="$1"
  local output="$test_root/tls-snapshot-$fault.out" status
  rm -rf -- "$tls_snapshot_root"
  mkdir -p "$tls_snapshot_root/conf.d"
  printf '%s\n' valid-live-vhost >"$tls_snapshot_root/conf.d/20-production.conf"
  printf '%s\n' valid-stale-vhost >"$tls_snapshot_root/conf.d/10-dev.conf"

  set +e
  PATH="$snapshot_fault_bin:$PATH" \
    APOLLO_TLS_SNAPSHOT_FAULT="$fault" \
    APOLLO_REAL_MKTEMP="$real_mktemp" \
    APOLLO_REAL_CP="$real_cp" \
    APOLLO_REAL_TOUCH="$real_touch" \
    bash "$tls_snapshot_payload" example-com >"$output" 2>&1
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "Injected TLS snapshot $fault failure unexpectedly succeeded."
  assert_equal valid-live-vhost "$(cat "$tls_snapshot_root/conf.d/20-production.conf")" \
    "Live vhost after TLS snapshot $fault failure"
  assert_equal valid-stale-vhost "$(cat "$tls_snapshot_root/conf.d/10-dev.conf")" \
    "Stale vhost after TLS snapshot $fault failure"
  if find "$tls_snapshot_root" -maxdepth 1 -name '.tls-rollback.*' -print -quit | grep -q .; then
    fail "TLS snapshot $fault failure retained an incomplete rollback directory."
  fi
}

run_tls_snapshot_fault rollback-dir
run_tls_snapshot_fault copy
run_tls_snapshot_fault marker

# A complete snapshot also leaves the live tree unchanged until its path has
# been returned and validated. Thus a transport disconnect that loses stdout
# cannot strand an unknown rollback directory after destructive mutation.
rm -rf -- "$tls_snapshot_root"
mkdir -p "$tls_snapshot_root/conf.d" "$tls_snapshot_root/local"
printf '%s\n' valid-live-vhost >"$tls_snapshot_root/conf.d/20-production.conf"
printf '%s\n' valid-stale-vhost >"$tls_snapshot_root/conf.d/10-dev.conf"
printf '%s\n' valid-local-stale >"$tls_snapshot_root/local/legacy.conf"
snapshot_path="$({
  PATH="$snapshot_fault_bin:$PATH" \
    APOLLO_TLS_SNAPSHOT_FAULT='' \
    APOLLO_REAL_MKTEMP="$real_mktemp" \
    APOLLO_REAL_CP="$real_cp" \
    APOLLO_REAL_TOUCH="$real_touch" \
    bash "$tls_snapshot_payload" example-com
})"
[ -f "$snapshot_path/snapshot-ready" ] \
  || fail 'Successful TLS snapshot did not create its ready marker.'
assert_equal valid-live-vhost "$(cat "$tls_snapshot_root/conf.d/20-production.conf")" \
  'Live vhost before rollback identity consumption'
assert_equal valid-stale-vhost "$(cat "$tls_snapshot_root/conf.d/10-dev.conf")" \
  'Stale vhost before rollback identity consumption'
assert_equal valid-stale-vhost "$(cat "$snapshot_path/stale/conf.d/10-dev.conf")" \
  'Copied stale vhost in complete TLS snapshot'

tls_remove_payload="$test_root/tls-remove-stale-remote.sh"
awk '
  /<<'\''TLS_REMOVE_STALE_REMOTE'\''$/ { capture = 1; next }
  capture && $0 == "TLS_REMOVE_STALE_REMOTE" { exit }
  capture { print }
' "$tls_setup" >"$tls_remove_payload.original"
awk -v nginx_root="$tls_snapshot_root" '
  $0 == "nginx_root=/opt/apollo/platform/nginx" {
    printf "nginx_root=\"%s\"\n", nginx_root
    next
  }
  { print }
' "$tls_remove_payload.original" >"$tls_remove_payload"
chmod 0700 "$tls_remove_payload"
bash "$tls_remove_payload" "$snapshot_path" example-com
[ ! -e "$tls_snapshot_root/conf.d/10-dev.conf" ] \
  || fail 'Rollback-covered activation retained the stale development vhost.'
[ ! -e "$tls_snapshot_root/local/legacy.conf" ] \
  || fail 'Rollback-covered activation retained a stale local vhost.'
assert_equal valid-live-vhost "$(cat "$tls_snapshot_root/conf.d/20-production.conf")" \
  'Production vhost after stale activation'

# Even if an incomplete rollback directory is supplied defensively, it has no
# authority to replace or remove the live production vhost.
tls_rollback_payload="$test_root/tls-rollback-remote.sh"
awk '
  /<<'\''TLS_ROLLBACK_REMOTE'\''$/ { capture = 1; next }
  capture && $0 == "TLS_ROLLBACK_REMOTE" { exit }
  capture { print }
' "$tls_setup" >"$tls_rollback_payload.original"
awk -v nginx_root="$tls_snapshot_root" '
  $0 == "nginx_root=/opt/apollo/platform/nginx" {
    printf "nginx_root=\"%s\"\n", nginx_root
    next
  }
  { print }
' "$tls_rollback_payload.original" >"$tls_rollback_payload"
chmod 0700 "$tls_rollback_payload"

# Once the rollback identity is known, an interrupted destructive phase can
# restore every copied stale path and the previous production vhost.
PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$tls_test" \
  APOLLO_DOCKER_TEST_MODE=rollback-safe \
  bash "$tls_rollback_payload" "$snapshot_path" apollo-platform-nginx
assert_equal valid-stale-vhost "$(cat "$tls_snapshot_root/conf.d/10-dev.conf")" \
  'Stale vhost after complete TLS rollback'
assert_equal valid-local-stale "$(cat "$tls_snapshot_root/local/legacy.conf")" \
  'Local stale vhost after complete TLS rollback'
[ ! -e "$snapshot_path" ] || fail 'Complete TLS rollback retained its snapshot directory.'

rm -rf -- "$tls_snapshot_root"
mkdir -p \
  "$tls_snapshot_root/conf.d" \
  "$tls_snapshot_root/.tls-rollback.INCOMPLETE/stale"
printf '%s\n' valid-live-vhost >"$tls_snapshot_root/conf.d/20-production.conf"
printf '%s\n' stale-snapshot \
  >"$tls_snapshot_root/.tls-rollback.INCOMPLETE/20-production.conf.previous"
touch "$tls_snapshot_root/.tls-rollback.INCOMPLETE/original-present"
PATH="$fake_bin:$PATH" \
  APOLLO_DOCKER_TEST_STATE="$tls_test" \
  APOLLO_DOCKER_TEST_MODE=rollback-safe \
  bash "$tls_rollback_payload" \
    "$tls_snapshot_root/.tls-rollback.INCOMPLETE" \
    apollo-platform-nginx
assert_equal valid-live-vhost "$(cat "$tls_snapshot_root/conf.d/20-production.conf")" \
  'Live vhost after incomplete TLS rollback'

assert_file_absent 'StrictHostKeyChecking=accept-new' "$bootstrap"
assert_file_absent 'StrictHostKeyChecking=accept-new' "$tls_setup"
[ "$(grep -Fc 'StrictHostKeyChecking=yes' "$bootstrap")" -eq 2 ] \
  || fail 'Bootstrap SSH and rsync are not both strict-host-key verified.'
assert_file_contains 'StrictHostKeyChecking=yes' "$tls_setup"
assert_file_contains 'docker run --rm --pull=never' "$tls_setup"
assert_file_contains 'certbot/certbot:v2.11.0@sha256:ddf9e5d226a56e886986838fa0ebedc0237511c78664352e8d0f4346ee022cd8 certonly' "$tls_setup"

echo 'Bootstrap, Docker firewall, nginx rollback, and TLS safety tests passed.'
