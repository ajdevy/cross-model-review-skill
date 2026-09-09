#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
function_file=$(mktemp)
trap 'rm -f "$function_file"' EXIT
sed -n '/^secret_scan_redact()/,/^}/p' "$script_dir/cross-model-review.sh" >"$function_file"
# shellcheck disable=SC1090
source "$function_file"

assert_redacted() {
  local input=$1
  local marker=$2
  local output
  output=$(printf '%s' "$input" | secret_scan_redact)
  if grep -Fq "$marker" <<<"$output"; then
    printf 'raw secret marker remained: %s\n' "$marker" >&2
    exit 1
  fi
  grep -Fq '[REDACTED' <<<"$output"
}

for label in RSA OPENSSH EC DSA ENCRYPTED; do
  input=$(printf '%s\n%s\n%s' "-----BEGIN $label PRIVATE KEY-----" 'private-material' "-----END $label PRIVATE KEY-----")
  assert_redacted "$input" private-material
done
input=$(printf '%s\n%s\n%s' '-----BEGIN PRIVATE KEY-----' 'private-material' '-----END PRIVATE KEY-----')
assert_redacted "$input" private-material
input=$(printf '%s\n%s\n%s' '-----BEGIN PGP PRIVATE KEY BLOCK-----' 'private-material' '-----END PGP PRIVATE KEY BLOCK-----')
assert_redacted "$input" private-material
assert_redacted 'SECRET_KEY = "long-secret-value"' long-secret-value
assert_redacted 'AWS_SECRET_ACCESS_KEY=long-secret-value' long-secret-value
assert_redacted 'ghp_123456789012345678901234567890123456' ghp_

printf '%s\n' 'secret redaction tests passed'
