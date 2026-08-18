#!/usr/bin/env bash

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

portable_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

require_protected_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || die "$label must be a regular non-symlink file: $path"
  [[ "$(portable_mode "$path")" == 600 ]] || die "$label must have mode 0600: $path"
}

validate_env_file() {
  local path="$1"
  local line line_number=0 duplicate_key
  [[ -f "$path" && ! -L "$path" ]] || die "Configuration file is unavailable or unsafe: $path"
  if LC_ALL=C grep -q '[[:cntrl:]]' "$path"; then
    die "Control byte in configuration file: $path"
  fi
  duplicate_key="$(awk -F= '
    /^[A-Z][A-Z0-9_]*=/ && ++seen[$1] == 2 { print $1; exit }
  ' "$path")"
  [[ -z "$duplicate_key" ]] || die "Duplicate configuration key $duplicate_key in $path"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
      || die "Invalid dotenv record at $path:$line_number"
  done <"$path"
}

env_value() {
  local path="$1"
  local key="$2"
  local default_value="${3-}"
  local value
  value="$(awk -v wanted="$key" '
    index($0, wanted "=") == 1 { print substr($0, length(wanted) + 2); found = 1 }
    END { if (!found) exit 1 }
  ' "$path" 2>/dev/null)" || value="$default_value"
  printf '%s' "$value"
}

first_env_value() {
  local key="$1"
  local default_value="$2"
  shift 2
  local path value
  for path in "$@"; do
    [[ -f "$path" ]] || continue
    value="$(env_value "$path" "$key" '__APOLLO_MISSING__')"
    if [[ "$value" != __APOLLO_MISSING__ && -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf '%s' "$default_value"
}

write_protected_file() {
  local target="$1"
  local parent temporary
  parent="$(dirname "$target")"
  mkdir -p "$parent"
  [[ ! -L "$parent" ]] || die "Protected-file parent cannot be a symlink: $parent"
  if [[ -e "$target" && (! -f "$target" || -L "$target") ]]; then
    die "Refusing to replace unsafe path: $target"
  fi
  temporary="$(mktemp "$parent/.apollo.XXXXXX")"
  chmod 600 "$temporary"
  if ! tee "$temporary" >/dev/null; then
    rm -f -- "$temporary"
    die "Could not write protected file: $target"
  fi
  mv -f -- "$temporary" "$target"
  chmod 600 "$target"
}

replace_env_value() {
  local target="$1"
  local key="$2"
  local value="$3"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Invalid configuration key: $key"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "Invalid multiline value for $key"
  awk -v wanted="$key" -v replacement="$value" '
    index($0, wanted "=") == 1 { print wanted "=" replacement; found = 1; next }
    { print }
    END { if (!found) print wanted "=" replacement }
  ' "$target" | write_protected_file "$target"
}

random_secret() {
  openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n'
}

random_base64_key() {
  openssl rand -base64 32 | tr -d '\r\n'
}

random_client_id() {
  local candidate=''
  while [[ ${#candidate} -lt 32 ]]; do
    candidate+="$(openssl rand -base64 48 | tr -cd 'A-Za-z')"
  done
  printf '%s' "${candidate:0:32}"
}

random_uuid() {
  local hex
  hex="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-8%s-%s' \
    "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
}

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

confirm_target() {
  local prompt="$1"
  local response
  if [[ "${APOLLO_ASSUME_YES:-false}" == true ]]; then
    return 0
  fi
  [[ -t 0 && -t 1 ]] || die "$prompt Re-run interactively or use --yes after reviewing the target."
  read -r -p "$prompt [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || die 'Cancelled.'
}
