#!/usr/bin/env bash
# Terraform interpolation markers below are intentionally matched as literals.
# shellcheck disable=SC2016

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$test_dir/../../.." && pwd)
platform_module="$repo_root/infra/terraform/modules/profiles/platform-api/modules/service/main.tf"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/apollo-certbot-health-tests.XXXXXX")

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'test         = ["CMD-SHELL", local.certbot_healthcheck_script]' "$platform_module" \
  || fail 'Certbot does not expose its renewal status through a Docker healthcheck.'
grep -Fq 'interval     = "5m0s"' "$platform_module" \
  || fail 'Certbot health does not use the expected five-minute monitoring contract.'
grep -Fq 'start_period = "1m0s"' "$platform_module" \
  || fail 'Certbot health does not preserve the greenfield start period.'
grep -Fq 'test         = ["CMD-SHELL", local.nginx_healthcheck_script]' "$platform_module" \
  || fail 'nginx does not expose reload and loaded-certificate state through its healthcheck.'
grep -Fq 'write_reload_status failure unknown "$reload_epoch"' "$platform_module" \
  || fail 'nginx reload failures are not persisted for health evaluation.'

extract_local_script() {
  local name="$1" destination="$2"
  awk -v name="$name" '
    $0 == "  " name " = <<-SCRIPT" { capture = 1; next }
    capture && $0 == "  SCRIPT" { exit }
    capture {
      sub(/^    /, "")
      print
    }
  ' "$platform_module" >"$destination"
  [ -s "$destination" ] || fail "Could not extract local.$name from the platform module."
}

renewal_script="$test_root/renewal.sh"
health_script="$test_root/health.sh"
extract_local_script certbot_renewal_script "$renewal_script.original"
extract_local_script certbot_healthcheck_script "$health_script.original"

letsencrypt_root="$test_root/letsencrypt"
mkdir -p "$letsencrypt_root"
sed "s#/etc/letsencrypt#$letsencrypt_root#g" \
  "$renewal_script.original" >"$renewal_script"
sed \
  -e "s#/etc/letsencrypt#$letsencrypt_root#g" \
  -e 's/${local.platform_domain}/api.platform.example.com/g' \
  "$health_script.original" >"$health_script"
chmod 0700 "$renewal_script" "$health_script"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/certbot" <<'FAKE_CERTBOT'
#!/usr/bin/env sh
[ "${APOLLO_CERTBOT_TEST_RESULT:-success}" = success ]
FAKE_CERTBOT
cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env sh
exit 99
FAKE_SLEEP
cat >"$fake_bin/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env sh
payload=$(cat)
printf '%s  -\n' "$payload"
FAKE_SHA256SUM
cat >"$fake_bin/timeout" <<'FAKE_TIMEOUT'
#!/usr/bin/env sh
shift
exec "$@"
FAKE_TIMEOUT
cat >"$fake_bin/openssl" <<'FAKE_OPENSSL'
#!/usr/bin/env sh
command_name=$1
shift
if [ "$command_name" = s_client ]; then
  printf '%s\n' "${APOLLO_CERTBOT_TEST_SERVED_CERTIFICATE:-fixture-certificate}"
  exit 0
fi
[ "$command_name" = x509 ] || exit 2
check_expiry=false
from_file=false
for argument in "$@"; do
  case "$argument" in
    -checkend) check_expiry=true ;;
    -in) from_file=true ;;
  esac
done
if $check_expiry; then
  [ "${APOLLO_CERTBOT_TEST_EXPIRY:-valid}" = valid ]
elif $from_file; then
  printf '%s\n' "${APOLLO_CERTBOT_TEST_RENEWED_CERTIFICATE:-fixture-certificate}"
else
  cat
fi
FAKE_OPENSSL
chmod 0700 "$fake_bin/certbot" "$fake_bin/sleep" "$fake_bin/sha256sum" "$fake_bin/timeout" "$fake_bin/openssl"

run_renewal_attempt() {
  local result="$1" status
  set +e
  PATH="$fake_bin:$PATH" APOLLO_CERTBOT_TEST_RESULT="$result" \
    sh "$renewal_script" >"$test_root/renewal-$result.out" 2>&1
  status=$?
  set -e
  [ "$status" -eq 99 ] || fail "Renewal loop test expected sleep status 99, got $status."
}

run_health() {
  local expiry="${1:-valid}"
  local served_certificate="${2:-fixture-certificate}"
  PATH="$fake_bin:$PATH" APOLLO_CERTBOT_TEST_EXPIRY="$expiry" \
    APOLLO_CERTBOT_TEST_SERVED_CERTIFICATE="$served_certificate" \
    sh "$health_script"
}

# A brand-new deployment has no certificate yet. Terraform must stay healthy
# long enough for setup-vps-tls.sh to complete initial issuance.
greenfield_output=$(run_health)
[ "$greenfield_output" = certbot-health:greenfield-no-certificate ] \
  || fail "Greenfield health returned an unexpected status: $greenfield_output"

mkdir -p "$letsencrypt_root/renewal"
printf '%s\n' fixture >"$letsencrypt_root/renewal/api.platform.example.com.conf"
if missing_output=$(run_health 2>&1); then
  fail 'A previously issued but now-missing certificate passed health.'
fi
case "$missing_output" in
  *certbot-health:certificate-missing*) ;;
  *) fail "Missing-certificate health reason was not stable: $missing_output" ;;
esac

mkdir -p "$letsencrypt_root/live/api.platform.example.com"
printf '%s\n' fixture >"$letsencrypt_root/live/api.platform.example.com/fullchain.pem"

run_renewal_attempt success
state_file="$letsencrypt_root/.apollo-renewal-health/status"
certificate_observed_file="$letsencrypt_root/.apollo-renewal-health/certificate-observed"
[ -f "$state_file" ] || fail 'Successful renewal did not persist health state.'
grep -qx 'consecutive_failures=0' "$state_file" \
  || fail 'Successful renewal did not reset the failure counter.'
run_health >/dev/null || fail 'Fresh successful renewal with a valid certificate was unhealthy.'
[ -f "$certificate_observed_file" ] \
  || fail 'Health did not persist that a certificate has previously existed.'

# Losing both the live certificate and its renewal configuration must not make
# an established deployment look like a greenfield deployment.
rm -f -- \
  "$letsencrypt_root/live/api.platform.example.com/fullchain.pem" \
  "$letsencrypt_root/renewal/api.platform.example.com.conf"
if erased_output=$(run_health 2>&1); then
  fail 'Erasing an established certificate and renewal configuration passed health.'
fi
case "$erased_output" in
  *certbot-health:certificate-missing*) ;;
  *) fail "Erased-certificate health reason was not stable: $erased_output" ;;
esac
printf '%s\n' fixture >"$letsencrypt_root/renewal/api.platform.example.com.conf"
printf '%s\n' fixture >"$letsencrypt_root/live/api.platform.example.com/fullchain.pem"

# A live certificate is not enough if the renewal loop has stopped reporting
# successful attempts for longer than the health contract allows.
{
  printf 'last_success_epoch=1\n'
  printf 'consecutive_failures=0\n'
  printf 'last_attempt_epoch=1\n'
  printf 'last_result=success\n'
} >"$state_file"
if stale_output=$(run_health 2>&1); then
  fail 'Stale renewal success state passed health.'
fi
case "$stale_output" in
  *certbot-health:renewal-success-stale*) ;;
  *) fail "Stale-renewal health reason was not stable: $stale_output" ;;
esac
run_renewal_attempt success

# Renewal is not complete until the nginx endpoint serves the renewed file.
if served_stale_output=$(run_health valid old-certificate 2>&1); then
  fail 'A renewed certificate file with an old certificate still served by nginx passed health.'
fi
case "$served_stale_output" in
  *certbot-health:served-certificate-stale*) ;;
  *) fail "Served-certificate mismatch reason was not stable: $served_stale_output" ;;
esac

# Three failed attempts are persisted across process generations and fail the
# Docker healthcheck even while the old certificate still parses correctly.
run_renewal_attempt failure
run_renewal_attempt failure
run_renewal_attempt failure
grep -qx 'consecutive_failures=3' "$state_file" \
  || fail 'Repeated renewal failures were not persisted.'
if repeated_output=$(run_health 2>&1); then
  fail 'Three consecutive renewal failures passed health.'
fi
case "$repeated_output" in
  *certbot-health:repeated-renewal-failures*) ;;
  *) fail "Repeated-failure health reason was not stable: $repeated_output" ;;
esac

# A later success repairs the persisted failure state, but a certificate inside
# the fourteen-day safety window remains unhealthy.
run_renewal_attempt success
if expiry_output=$(run_health near 2>&1); then
  fail 'A near-expiry certificate passed health.'
fi
case "$expiry_output" in
  *certbot-health:certificate-near-expiry*) ;;
  *) fail "Near-expiry health reason was not stable: $expiry_output" ;;
esac

echo 'Certbot renewal persistence and expiry health tests passed.'

nginx_health_script="$test_root/nginx-health.sh"
extract_local_script nginx_healthcheck_script "$nginx_health_script.original"
nginx_status_file="$test_root/nginx-reload-status"
sed \
  -e "s#/etc/letsencrypt#$letsencrypt_root#g" \
  -e "s#/tmp/apollo-nginx-reload-status#$nginx_status_file#g" \
  -e 's/${local.platform_domain}/api.platform.example.com/g' \
  "$nginx_health_script.original" >"$nginx_health_script"
chmod 0700 "$nginx_health_script"

nginx_fake_bin="$test_root/nginx-bin"
mkdir -p "$nginx_fake_bin"
cat >"$nginx_fake_bin/wget" <<'FAKE_WGET'
#!/usr/bin/env sh
exit 0
FAKE_WGET
cat >"$nginx_fake_bin/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env sh
printf '%s  %s\n' "${APOLLO_NGINX_TEST_DISK_DIGEST:-aaaa}" "$1"
FAKE_SHA256SUM
cat >"$nginx_fake_bin/date" <<'FAKE_DATE'
#!/usr/bin/env sh
printf '%s\n' "${APOLLO_NGINX_TEST_NOW:-20000}"
FAKE_DATE
chmod 0700 "$nginx_fake_bin/wget" "$nginx_fake_bin/sha256sum" "$nginx_fake_bin/date"

# Certbot's live certificate is normally a symlink into its archive directory;
# nginx health must follow that standard layout.
mkdir -p "$letsencrypt_root/archive/api.platform.example.com"
mv "$letsencrypt_root/live/api.platform.example.com/fullchain.pem" \
  "$letsencrypt_root/archive/api.platform.example.com/fullchain1.pem"
ln -s ../../archive/api.platform.example.com/fullchain1.pem \
  "$letsencrypt_root/live/api.platform.example.com/fullchain.pem"

write_nginx_status() {
  local result="$1" digest="$2" epoch="$3"
  {
    printf 'last_reload_result=%s\n' "$result"
    printf 'loaded_certificate_sha256=%s\n' "$digest"
    printf 'last_reload_epoch=%s\n' "$epoch"
  } >"$nginx_status_file"
  chmod 600 "$nginx_status_file"
}

run_nginx_health() {
  PATH="$nginx_fake_bin:$PATH" \
    APOLLO_NGINX_TEST_DISK_DIGEST="${1:-aaaa}" \
    APOLLO_NGINX_TEST_NOW="${2:-20000}" \
    sh "$nginx_health_script"
}

write_nginx_status success aaaa 19999
nginx_healthy_output="$(run_nginx_health)"
[ "$nginx_healthy_output" = nginx-health:healthy ] \
  || fail "Matching loaded and renewed nginx certificate state was unhealthy: $nginx_healthy_output"

write_nginx_status success aaaa 19999
if nginx_stale_certificate_output="$(run_nginx_health bbbb 2>&1)"; then
  fail 'A renewed certificate file that nginx had not loaded passed health.'
fi
case "$nginx_stale_certificate_output" in
  *nginx-health:served-certificate-stale*) ;;
  *) fail "Stale served-certificate health reason was not stable: $nginx_stale_certificate_output" ;;
esac

write_nginx_status failure unknown 19999
if nginx_reload_failure_output="$(run_nginx_health aaaa 2>&1)"; then
  fail 'A failed nginx certificate reload passed health.'
fi
case "$nginx_reload_failure_output" in
  *nginx-health:reload-failed*) ;;
  *) fail "Reload-failure health reason was not stable: $nginx_reload_failure_output" ;;
esac

write_nginx_status success aaaa 1
if nginx_stale_loop_output="$(run_nginx_health aaaa 50000 2>&1)"; then
  fail 'A stopped nginx reload loop passed health.'
fi
case "$nginx_stale_loop_output" in
  *nginx-health:reload-loop-stale*) ;;
  *) fail "Reload-loop liveness reason was not stable: $nginx_stale_loop_output" ;;
esac

echo 'nginx loaded-certificate and reload-liveness health tests passed.'
