#!/usr/bin/env bash
# =============================================================================
# deploy_local.sh — ObSync local replica deployment
# Deploys the router and user_vault canisters to a local dfx replica,
# then runs a smoke test to verify the full registration flow works.
#
# Usage:
#   chmod +x deploy_local.sh
#   ./deploy_local.sh              # full deploy + smoke test
#   ./deploy_local.sh --no-test    # deploy only, skip smoke test
#   ./deploy_local.sh --reset      # wipe replica state and redeploy
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[info]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[ok]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
log_error()   { echo -e "${RED}[error]${RESET} $*"; }
log_section() { echo -e "\n${BOLD}──── $* ────${RESET}"; }

# ── Flags ─────────────────────────────────────────────────────────────────────
RUN_TESTS=true
RESET_STATE=false

for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS=false ;;
    --reset)   RESET_STATE=true ;;
    *) log_error "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Prerequisites check ───────────────────────────────────────────────────────
log_section "Checking prerequisites"

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    log_error "'$1' not found. $2"
    exit 1
  fi
  log_ok "$1 found"
}

check_cmd dfx   "Install from: https://internetcomputer.org/docs/current/developer-docs/setup/install"
check_cmd cargo "Install from: https://rustup.rs"
check_cmd jq    "Install with: brew install jq  or  apt install jq"

DFX_VERSION=$(dfx --version | awk '{print $2}')
log_info "dfx version: $DFX_VERSION"

# Warn if dfx.json is missing — script must run from project root
if [[ ! -f "dfx.json" ]]; then
  log_error "dfx.json not found. Run this script from the project root."
  exit 1
fi

# ── Replica lifecycle ─────────────────────────────────────────────────────────
log_section "Starting local replica"

if $RESET_STATE; then
  log_warn "--reset flag set: wiping all local canister state"
  dfx stop 2>/dev/null || true
  dfx start --clean --background
  log_ok "Replica started fresh (state cleared)"
else
  # Start replica if not already running, otherwise leave it alone
  if ! dfx ping &>/dev/null; then
    dfx start --background
    log_ok "Replica started"
  else
    log_info "Replica already running — skipping start"
  fi
fi

# Give the replica a moment to be ready
sleep 2

# ── Build ─────────────────────────────────────────────────────────────────────
log_section "Building canisters"

log_info "Building router canister (Rust → Wasm)..."
cargo build \
  --target wasm32-unknown-unknown \
  --release \
  --package router \
  -q
log_ok "Router built"

log_info "Building user_vault canister (Rust → Wasm)..."
cargo build \
  --target wasm32-unknown-unknown \
  --release \
  --package user_vault \
  -q
log_ok "user_vault built"

# ── Deploy ────────────────────────────────────────────────────────────────────
log_section "Deploying canisters"

# Deploy router first — user_vault registration references it
log_info "Deploying router..."
dfx deploy router --yes 2>&1 | grep -E "^(Deploying|Deployed|Creating|Installing|Upgrading)" || true
ROUTER_ID=$(dfx canister id router)
log_ok "Router deployed: ${BOLD}${ROUTER_ID}${RESET}"

# Deploy user_vault canister
log_info "Deploying user_vault..."
dfx deploy user_vault --yes 2>&1 | grep -E "^(Deploying|Deployed|Creating|Installing|Upgrading)" || true
VAULT_ID=$(dfx canister id user_vault)
log_ok "user_vault deployed: ${BOLD}${VAULT_ID}${RESET}"

# ── Register vault in router ──────────────────────────────────────────────────
log_section "Registering vault in router"

log_info "Calling register_vault on router with vault canister ID..."
REGISTER_RESULT=$(dfx canister call router register_vault "(principal \"${VAULT_ID}\")")
log_info "Result: $REGISTER_RESULT"

if echo "$REGISTER_RESULT" | grep -q "Ok"; then
  log_ok "Vault registered successfully"
else
  log_error "register_vault returned an unexpected result"
  exit 1
fi

# ── Smoke tests ───────────────────────────────────────────────────────────────
if $RUN_TESTS; then
  log_section "Running smoke tests"

  PASS=0
  FAIL=0

  run_test() {
    local name="$1"
    local result="$2"
    local expected="$3"

    if echo "$result" | grep -q "$expected"; then
      log_ok "PASS — $name"
      ((PASS++))
    else
      log_error "FAIL — $name"
      log_error "  expected to contain: $expected"
      log_error "  got:                 $result"
      ((FAIL++))
    fi
  }

  # 1. Router: is_registered should return true
  IS_REG=$(dfx canister call router is_registered)
  run_test "router.is_registered returns true" "$IS_REG" "true"

  # 2. Router: get_vault_id should return the vault canister ID
  VAULT_LOOKUP=$(dfx canister call router get_vault_id)
  run_test "router.get_vault_id returns Ok" "$VAULT_LOOKUP" "Ok"

  # 3. user_vault: list_files on fresh vault should return empty
  LIST=$(dfx canister call user_vault list_files)
  run_test "user_vault.list_files returns empty list" "$LIST" "(vec {})"

  # 4. user_vault: list_conflicts on fresh vault should return empty
  CONFLICTS=$(dfx canister call user_vault list_conflicts)
  run_test "user_vault.list_conflicts returns empty list" "$CONFLICTS" "(vec {})"

  # 5. user_vault: push a test file and verify it appears in list_files
  log_info "Pushing a test file to user_vault..."
  PUSH_RESULT=$(dfx canister call user_vault push_file \
    "(
      \"notes/hello.md\",
      \"abc123hash\",
      blob \"68656c6c6f\",
      \"test-device\",
      vec {}
    )"
  )
  run_test "user_vault.push_file returns Ok" "$PUSH_RESULT" "Ok"

  LIST_AFTER=$(dfx canister call user_vault list_files)
  run_test "user_vault.list_files shows pushed file" "$LIST_AFTER" "hello.md"

  # 6. user_vault: pull_changes with empty clock should return the file
  PULL=$(dfx canister call user_vault pull_changes "(vec {})")
  run_test "user_vault.pull_changes returns the file" "$PULL" "hello.md"

  # 7. user_vault: clear_vault should wipe everything
  dfx canister call user_vault clear_vault > /dev/null
  LIST_CLEARED=$(dfx canister call user_vault list_files)
  run_test "user_vault.list_files empty after clear_vault" "$LIST_CLEARED" "(vec {})"

  # ── Summary ──────────────────────────────────────────────────────────────
  echo ""
  if [[ $FAIL -eq 0 ]]; then
    log_ok "${BOLD}All $PASS tests passed${RESET}"
  else
    log_error "${BOLD}$FAIL test(s) failed, $PASS passed${RESET}"
    exit 1
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log_section "Deployment complete"

echo -e "
  ${BOLD}Router canister ID :${RESET}  ${ROUTER_ID}
  ${BOLD}Vault canister ID  :${RESET}  ${VAULT_ID}
  ${BOLD}Replica dashboard  :${RESET}  http://localhost:4943

  ${BOLD}Useful commands:${RESET}
    dfx canister call router  is_registered
    dfx canister call router  get_vault_id
    dfx canister call user_vault list_files
    dfx canister call user_vault list_conflicts
    dfx stop
"