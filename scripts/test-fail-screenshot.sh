#!/usr/bin/env bash
# ============================================================================
# test-fail-screenshot.sh
#
# Runs a single deliberately-failing Playwright test to verify that
# screenshots are captured on failure and appear in the HTML report.
#
# This script is completely isolated — it uses its own Playwright config,
# its own test directory, and its own report folder. It does NOT touch
# the main test suite or any other scripts.
#
# Usage:
#   ./scripts/test-fail-screenshot.sh
#   APP_URL=http://localhost:30000 ./scripts/test-fail-screenshot.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_DIR="$PROJECT_ROOT/frontend"

APP_URL="${APP_URL:-http://localhost:30000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   Fail-Screenshot Demo                           ║${NC}"
echo -e "${CYAN}${BOLD}║   Verifying Playwright captures screenshots      ║${NC}"
echo -e "${CYAN}${BOLD}║   on test failure                                ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# --- Step 1: Verify the app is reachable ---
echo -e "${YELLOW}[1/4]${NC} Checking app is reachable at ${APP_URL} ..."
if ! curl -sf --max-time 5 "$APP_URL/api/health" > /dev/null 2>&1; then
    echo -e "${RED}ERROR:${NC} Cannot reach $APP_URL/api/health"
    echo "       Make sure the app is deployed and running."
    echo "       You can deploy with: ./scripts/build-test-deploy.sh --deploy-only"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} App is healthy"

# --- Step 2: Clean previous demo artifacts ---
echo -e "${YELLOW}[2/4]${NC} Cleaning previous fail-demo artifacts ..."
rm -rf "$FRONTEND_DIR/playwright-fail-demo-report"
rm -rf "$FRONTEND_DIR/test-results"
echo -e "  ${GREEN}✓${NC} Clean"

# --- Step 3: Run the deliberately-failing test ---
echo -e "${YELLOW}[3/4]${NC} Running fail-demo test (expect 1 failure) ..."
echo ""

cd "$FRONTEND_DIR"
TEST_EXIT_CODE=0
APP_URL="$APP_URL" npx playwright test --config playwright-fail-demo.config.ts || TEST_EXIT_CODE=$?

echo ""

if [ "$TEST_EXIT_CODE" -eq 0 ]; then
    echo -e "${RED}ERROR:${NC} The test was supposed to FAIL but it passed!"
    echo "       Something is wrong with the fail-demo test."
    exit 1
fi

echo -e "  ${GREEN}✓${NC} Test failed as expected (exit code: $TEST_EXIT_CODE)"

# --- Step 4: Verify screenshot was captured ---
echo -e "${YELLOW}[4/4]${NC} Verifying screenshot was captured ..."

# Playwright stores failure screenshots in test-results/ directory
SCREENSHOT=$(find "$FRONTEND_DIR/test-results" -name "*.png" -type f 2>/dev/null | head -1)

if [ -z "$SCREENSHOT" ]; then
    echo -e "${RED}ERROR:${NC} No screenshot found in test-results/"
    echo "       Screenshot capture may not be configured correctly."
    exit 1
fi

SCREENSHOT_COUNT=$(find "$FRONTEND_DIR/test-results" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}✓${NC} Found ${SCREENSHOT_COUNT} screenshot(s)"
echo ""

# List all screenshots
echo -e "${BOLD}Screenshots captured:${NC}"
find "$FRONTEND_DIR/test-results" -name "*.png" -type f | while read -r f; do
    SIZE=$(ls -lh "$f" | awk '{print $5}')
    echo -e "  📸 $(basename "$f") (${SIZE})"
    echo -e "     ${f}"
done

echo ""
echo -e "${BOLD}HTML Report:${NC}"
echo -e "  ${FRONTEND_DIR}/playwright-fail-demo-report/index.html"
echo ""
echo -e "  Open it with: ${CYAN}cd frontend && npx playwright show-report playwright-fail-demo-report${NC}"
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   ✓ Screenshot-on-failure verified successfully  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
