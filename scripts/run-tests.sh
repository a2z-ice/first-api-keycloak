#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_URL="${APP_URL:-http://localhost:30000}"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Run Playwright E2E tests for the Student Management System."
  echo ""
  echo "Options:"
  echo "  --deployed       Test against deployed app (http://localhost:30000)"
  echo "  --local          Test against local dev (http://localhost:5173)"
  echo "  --start-app      Start Redis + FastAPI backend before testing"
  echo "  --stop-app       Stop Redis + FastAPI backend after testing"
  echo "  --verbose, -v    Verbose output (default)"
  echo "  --quiet, -q      Minimal output"
  echo "  --filter EXPR    Run only tests matching EXPR"
  echo "  --help, -h       Show this help"
  echo ""
  echo "Examples:"
  echo "  $0                              # Run all tests against localhost:30000"
  echo "  $0 --deployed                   # Run all tests against deployed app"
  echo "  $0 --local --start-app          # Start backend, test via Vite proxy"
  echo "  $0 --filter 'auth'              # Run only auth tests"
}

START_APP=false
STOP_APP=false
PW_ARGS=""
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --deployed) APP_URL="http://localhost:30000" ;;
    --local) APP_URL="http://localhost:5173" ;;
    --start-app) START_APP=true ;;
    --stop-app) STOP_APP=true ;;
    --verbose|-v) PW_ARGS="" ;;
    --quiet|-q) PW_ARGS="--quiet" ;;
    --help|-h) usage; exit 0 ;;
    --filter)
      shift_next=true ;;
    *)
      if [ "${shift_next:-}" = true ]; then
        FILTER="$arg"
        shift_next=false
      else
        echo "Unknown option: $arg"
        usage
        exit 1
      fi
      ;;
  esac
done

cleanup() {
  if [ "$STOP_APP" = true ]; then
    echo ""
    echo "==> Stopping FastAPI app..."
    pkill -f "uvicorn app.main:app" 2>/dev/null || true
    echo "==> Stopping Redis container..."
    docker stop redis-local 2>/dev/null || true
    docker rm redis-local 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start Redis and backend if requested
if [ "$START_APP" = true ]; then
  echo "==> Starting Redis..."
  docker run -d --name redis-local -p 6379:6379 redis:7-alpine 2>/dev/null \
    || docker start redis-local 2>/dev/null || true

  for i in $(seq 1 10); do
    if docker exec redis-local redis-cli ping 2>/dev/null | grep -q PONG; then
      break
    fi
    sleep 1
  done

  echo "==> Starting FastAPI backend..."
  cd "$PROJECT_DIR/backend"
  if [ -d "venv" ]; then
    source venv/bin/activate
  fi
  python run.py &
  APP_PID=$!

  echo "    Waiting for backend at http://localhost:8000..."
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:8000/api/health" 2>/dev/null | grep -q 200; then
      echo "    Backend is ready!"
      break
    fi
    sleep 1
  done
  echo ""
fi

# Build test command
cd "$PROJECT_DIR/frontend"
npm ci --silent 2>/dev/null || true

GREP_ARG=""
if [ -n "$FILTER" ]; then
  GREP_ARG="--grep '$FILTER'"
fi

echo "==> Running tests against $APP_URL"
echo "    Command: APP_URL=$APP_URL npx playwright test $PW_ARGS $GREP_ARG --reporter=html"
echo ""

APP_URL="$APP_URL" eval "npx playwright test $PW_ARGS $GREP_ARG --reporter=html"

echo ""
echo "==> Test report: $PROJECT_DIR/frontend/playwright-report/index.html"
