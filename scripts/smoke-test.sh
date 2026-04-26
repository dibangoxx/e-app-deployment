#!/usr/bin/env bash
###############################################################################
# FlashInfo — Local Smoke Test
# Runs a rapid end-to-end check against the running local stack.
# Usage: ./scripts/smoke-test.sh
###############################################################################

set -e

BASE="http://localhost:3001"
PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }

check() {
  local label="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local extra_args="${@:4}"

  actual=$(curl -s -o /tmp/smoke_body -w "%{http_code}" $extra_args "$url")
  if [[ "$actual" == "$expected_status" ]]; then
    ok "$label (HTTP $actual)"
  else
    fail "$label — expected $expected_status, got $actual"
    cat /tmp/smoke_body 2>/dev/null | head -3
  fi
}

echo ""
echo "=============================="
echo " FlashInfo Local Smoke Test"
echo "=============================="
echo ""

# ── Health ────────────────────────────────────────────────────────────────────
echo "[ Health ]"
check "API health endpoint" "$BASE/health"

# ── Products ──────────────────────────────────────────────────────────────────
echo ""
echo "[ Products ]"
check "List products"           "$BASE/api/v1/products"
check "Filter by category"     "$BASE/api/v1/products?category=living_room"
check "Filter by price range"  "$BASE/api/v1/products?min_price=50&max_price=300"
check "Pagination"             "$BASE/api/v1/products?limit=3&page=1"
check "Unknown product 404"    "$BASE/api/v1/products/00000000-0000-0000-0000-000000000000" 404

# ── Search ────────────────────────────────────────────────────────────────────
echo ""
echo "[ Search ]"
check "Search for 'chair'"     "$BASE/api/v1/search?q=chair"
check "Search missing q=400"   "$BASE/api/v1/search" 400

# ── Auth ──────────────────────────────────────────────────────────────────────
echo ""
echo "[ Auth ]"
TIMESTAMP=$(date +%s)
REGISTER_BODY="{\"email\":\"smoke-${TIMESTAMP}@test.com\",\"password\":\"TestPass123!\",\"given_name\":\"Smoke\",\"family_name\":\"Test\"}"

# Register
REGISTER_STATUS=$(curl -s -o /tmp/register_resp -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "$REGISTER_BODY" "$BASE/api/v1/auth/register")

if [[ "$REGISTER_STATUS" == "201" ]]; then
  ok "Register new customer (HTTP 201)"
  TOKEN=$(cat /tmp/register_resp | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null)
else
  fail "Register new customer — expected 201, got $REGISTER_STATUS"
fi

# Login
if [[ -n "$TOKEN" ]]; then
  LOGIN_STATUS=$(curl -s -o /tmp/login_resp -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"email\":\"smoke-${TIMESTAMP}@test.com\",\"password\":\"TestPass123!\"}" \
    "$BASE/api/v1/auth/login")
  [[ "$LOGIN_STATUS" == "200" ]] && ok "Login (HTTP 200)" || fail "Login — got $LOGIN_STATUS"

  # Me endpoint
  ME_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE/api/v1/auth/me")
  [[ "$ME_STATUS" == "200" ]] && ok "GET /me with token (HTTP 200)" || fail "GET /me — got $ME_STATUS"
fi

# ── Cart ─────────────────────────────────────────────────────────────────────
echo ""
echo "[ Cart ]"
SESSION="smoke-session-${TIMESTAMP}"
check "Get empty cart"  "$BASE/api/v1/cart?session_id=${SESSION}"

# Get a real product ID first
PRODUCT_ID=$(curl -s "$BASE/api/v1/products?limit=1" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d['data'] else '')" 2>/dev/null)

if [[ -n "$PRODUCT_ID" ]]; then
  ADD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"session_id\":\"$SESSION\",\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}" \
    "$BASE/api/v1/cart/add")
  [[ "$ADD_STATUS" == "200" ]] && ok "Add item to cart" || fail "Add item — got $ADD_STATUS"
fi

# ── Unknown route ─────────────────────────────────────────────────────────────
echo ""
echo "[ Errors ]"
check "Unknown route returns 404"  "$BASE/api/v1/doesnotexist" 404
check "Me without auth returns 401" "$BASE/api/v1/auth/me" 401

# ── Frontend ──────────────────────────────────────────────────────────────────
echo ""
echo "[ Frontend ]"
FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000/")
if [[ "$FRONTEND_STATUS" == "200" ]]; then
  ok "Frontend serving (HTTP 200)"
else
  fail "Frontend — expected 200, got $FRONTEND_STATUS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
TOTAL=$((PASS + FAIL))
echo " Results: ${PASS}/${TOTAL} passed"
if [[ $FAIL -gt 0 ]]; then
  echo -e " ${RED}${FAIL} test(s) failed${NC}"
  echo "=============================="
  exit 1
else
  echo -e " ${GREEN}All tests passed!${NC}"
  echo "=============================="
fi
