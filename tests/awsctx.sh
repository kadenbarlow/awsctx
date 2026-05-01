#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWSCTX="$ROOT_DIR/awsctx"

TEST_TMP=""
HOME_DIR=""
BIN_DIR=""
LAST_STDOUT=""
LAST_STDERR=""
LAST_STATUS=0
TEST_FAIL_JQ_ENCRYPTED=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-expected '$expected', got '$actual'}"
  [[ "$expected" == "$actual" ]] || fail "$msg"
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-expected to find '$needle'}"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg"
}

assert_jq() {
  local file="$1"
  local filter="$2"
  local expected="$3"
  local actual
  actual="$(jq -r "$filter" "$file")"
  assert_eq "$expected" "$actual" "jq assertion failed for $file with filter $filter"
}

setup_env() {
  local real_jq

  TEST_TMP="$(mktemp -d)"
  HOME_DIR="$TEST_TMP/home"
  BIN_DIR="$TEST_TMP/bin"
  mkdir -p "$HOME_DIR" "$BIN_DIR"
  real_jq="$(command -v jq)"

  cat > "$BIN_DIR/aescrypt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=""
file=""
password=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -e|-d) mode="$1" ;;
    -p) shift; password="$1" ;;
    *) file="$1" ;;
  esac
  shift
done

[[ -n "$file" ]] || exit 1
[[ "$password" == "pw" ]] || {
  echo "Error: Bad file header (not aescrypt file or is corrupted? [7b, a, 20])" >&2
  exit 1
}
if [[ "$mode" == "-e" ]]; then
  cp "$file" "$file.aes"
elif [[ "$mode" == "-d" ]]; then
  cp "$file" "${file%.aes}"
else
  exit 1
fi
EOF
  chmod +x "$BIN_DIR/aescrypt"

  cat > "$BIN_DIR/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_FAIL_JQ_ENCRYPTED:-0}" == "1" && "$#" -gt 0 ]]; then
  last_arg="${!#}"
  if [[ "$last_arg" == *"awsctx-encrypted.json" ]]; then
    exit 1
  fi
fi
exec "__REAL_JQ__" "$@"
EOF
  perl -0pi -e 's#__REAL_JQ__#'"$real_jq"'#g' "$BIN_DIR/jq"
  chmod +x "$BIN_DIR/jq"
}

teardown_env() {
  [[ -n "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

run_awsctx() {
  local input="${1-}"
  shift || true

  LAST_STDOUT="$TEST_TMP/stdout"
  LAST_STDERR="$TEST_TMP/stderr"

  set +e
  HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" TEST_FAIL_JQ_ENCRYPTED="$TEST_FAIL_JQ_ENCRYPTED" bash "$AWSCTX" "$@" >"$LAST_STDOUT" 2>"$LAST_STDERR" <<< "$input"
  LAST_STATUS=$?
  set -e
}

stdout() {
  cat "$LAST_STDOUT"
}

stderr() {
  cat "$LAST_STDERR"
}

decrypt_store() {
  HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" "$BIN_DIR/aescrypt" -d -p pw "$HOME_DIR/.aws/awsctx-encrypted.json.aes"
}

init_store() {
  run_awsctx $'pw\n' -h
  assert_eq 0 "$LAST_STATUS" "init_store failed: $(stderr)"
}

create_context() {
  local name="$1"
  local access="$2"
  local secret="$3"
  run_awsctx "${name}
${access}
${secret}
pw
" -n
  assert_eq 0 "$LAST_STATUS" "create_context failed for $name: $(stderr)"
}

test_help_initializes_store() {
  setup_env
  trap teardown_env RETURN

  init_store

  assert_file_exists "$HOME_DIR/.aws/awsctx.json"
  assert_file_exists "$HOME_DIR/.aws/awsctx-encrypted.json.aes"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.contexts | length' '0'
  pass "help initializes store"
}

test_create_context_with_hyphen() {
  setup_env
  trap teardown_env RETURN

  init_store
  create_context "awesome-ctx" "abc" "def"

  assert_jq "$HOME_DIR/.aws/awsctx.json" '.contexts[0]' 'awesome-ctx'
  decrypt_store
  assert_jq "$HOME_DIR/.aws/awsctx-encrypted.json" '."awesome-ctx".access_key_id' 'abc'
  assert_jq "$HOME_DIR/.aws/awsctx-encrypted.json" '."awesome-ctx".secret_access_key' 'def'
  pass "create context with hyphen"
}

test_set_export_rename_delete() {
  setup_env
  trap teardown_env RETURN

  init_store
  create_context "dev-1" "AKIADEV" "DEVSECRET"
  create_context "prod-2" "AKIAPROD" "PRODSECRET"

  run_awsctx $'pw\n' -s dev-1
  assert_eq 0 "$LAST_STATUS" "set context failed: $(stderr)"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.current_context' 'dev-1'
  assert_file_exists "$HOME_DIR/.aws/credentials"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.previous_context' 'null'
  grep -q 'aws_access_key_id = AKIADEV' "$HOME_DIR/.aws/credentials" || fail "credentials not written"

  local exported
  exported="$(HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" bash -c 'source "$1" -e "$2" >/dev/null; printf "%s:%s" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"' _ "$AWSCTX" 'prod-2' <<< $'pw\n')"
  assert_eq 'AKIAPROD:PRODSECRET' "$exported" "export failed"

  run_awsctx $'pw\n' 'renamed-prod=prod-2'
  assert_eq 0 "$LAST_STATUS" "rename failed: $(stderr)"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.contexts | sort | join(",")' 'dev-1,renamed-prod'

  run_awsctx $'pw\n' -d renamed-prod
  assert_eq 0 "$LAST_STATUS" "delete failed: $(stderr)"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.contexts | join(",")' 'dev-1'
  pass "set/export/rename/delete"
}

test_previous_context_swap() {
  setup_env
  trap teardown_env RETURN

  init_store
  create_context "one-ctx" "ONE" "SECRET1"
  create_context "two-ctx" "TWO" "SECRET2"

  run_awsctx $'pw\n' -s one-ctx
  assert_eq 0 "$LAST_STATUS" "set one-ctx failed"

  run_awsctx $'pw\n' -s two-ctx
  assert_eq 0 "$LAST_STATUS" "set two-ctx failed"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.current_context' 'two-ctx'
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.previous_context' 'one-ctx'

  run_awsctx $'pw\n' -
  assert_eq 0 "$LAST_STATUS" "swap failed"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.current_context' 'one-ctx'
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.previous_context' 'two-ctx'
  pass "previous context swap"
}

test_password_retry() {
  setup_env
  trap teardown_env RETURN

  init_store
  create_context "retry-ctx" "RETRY" "SECRET"

  run_awsctx $'wrong\npw\n' -s retry-ctx
  assert_eq 0 "$LAST_STATUS" "password retry failed: $(stderr)"
  assert_contains 'error: invalid password, please try again' "$(stderr)" "expected retry error message"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.current_context' 'retry-ctx'
  grep -q 'aws_access_key_id = RETRY' "$HOME_DIR/.aws/credentials" || fail "credentials not written after retry"
  pass "password retry"
}

test_failed_create_does_not_add_context() {
  setup_env
  trap teardown_env RETURN

  init_store
  TEST_FAIL_JQ_ENCRYPTED=1
  run_awsctx $'broken-ctx\nBROKEN\nSECRET\npw\n' -n
  TEST_FAIL_JQ_ENCRYPTED=0

  assert_eq 1 "$LAST_STATUS" "expected create to fail"
  assert_contains 'error creating context "broken-ctx"' "$(stderr)" "expected create error message"
  assert_jq "$HOME_DIR/.aws/awsctx.json" '.contexts | length' '0'
  decrypt_store
  assert_jq "$HOME_DIR/.aws/awsctx-encrypted.json" 'keys | length' '0'
  pass "failed create does not add context"
}

main() {
  test_help_initializes_store
  test_create_context_with_hyphen
  test_set_export_rename_delete
  test_previous_context_swap
  test_password_retry
  test_failed_create_does_not_add_context
  echo "All tests passed"
}

main "$@"
