#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_URL="${APP_URL:-http://localhost:8000}"
REDIS_CONTAINER="redis-local"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Run E2E tests for the Student Management System."
  echo ""
  echo "Options:"
  echo "  --deployed       Test against deployed app (http://localhost:32000)"
  echo "  --start-app      Start Redis + FastAPI app before testing"
  echo "  --stop-app       Stop Redis + FastAPI app after testing"
  echo "  --verbose, -v    Verbose pytest output (default)"
  echo "  --quiet, -q      Minimal pytest output"
  echo "  --filter EXPR    Run only tests matching EXPR (pytest -k)"
  echo "  --suite SUITE    Run only a specific test class, e.g. TestAuthentication"
  echo "  --help, -h       Show this help"
  echo ""
  echo "Examples:"
  echo "  $0                              # Run all tests against localhost:8000"
  echo "  $0 --deployed                   # Run all tests against localhost:32000"
  echo "  $0 --start-app                  # Start app + Redis, run tests"
  echo "  $0 --start-app --stop-app       # Start, test, then clean up"
  echo "  $0 --suite TestStudentCRUD      # Run only student CRUD tests"
  echo "  $0 --filter 'admin and login'   # Run tests matching expression"
}

START_APP=false
STOP_APP=false
PYTEST_ARGS="-v"
FILTER=""
SUITE=""

for arg in "$@"; do
  case "$arg" in
    --deployed) APP_URL="http://localhost:32000" ;;
    --start-app) START_APP=true ;;
    --stop-app) STOP_APP=true ;;
    --verbose|-v) PYTEST_ARGS="-v" ;;
    --quiet|-q) PYTEST_ARGS="-q" ;;
    --help|-h) usage; exit 0 ;;
    --filter)
      shift_next=true ;;
    --suite)
      shift_suite=true ;;
    *)
      if [ "${shift_next:-}" = true ]; then
        FILTER="$arg"
        shift_next=false
      elif [ "${shift_suite:-}" = true ]; then
        SUITE="$arg"
        shift_suite=false
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
    docker stop "$REDIS_CONTAINER" 2>/dev/null || true
    docker rm "$REDIS_CONTAINER" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$PROJECT_DIR/fastapi-app"

# Activate venv
if [ -d "venv" ]; then
  source venv/bin/activate
fi

# Start Redis and app if requested
if [ "$START_APP" = true ]; then
  echo "==> Starting Redis..."
  docker run -d --name "$REDIS_CONTAINER" -p 6379:6379 redis:7-alpine 2>/dev/null \
    || docker start "$REDIS_CONTAINER" 2>/dev/null || true

  # Wait for Redis
  for i in $(seq 1 10); do
    if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
      break
    fi
    sleep 1
  done

  echo "==> Starting FastAPI app..."
  python run.py &
  APP_PID=$!

  # Wait for app to be ready
  echo "    Waiting for app at $APP_URL..."
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "$APP_URL/login-page" 2>/dev/null | grep -q 200; then
      echo "    App is ready!"
      break
    fi
    sleep 1
  done
  echo ""
fi

# Build pytest command
PYTEST_CMD="pytest tests/test_e2e.py $PYTEST_ARGS"

if [ -n "$SUITE" ]; then
  PYTEST_CMD="pytest tests/test_e2e.py::${SUITE} $PYTEST_ARGS"
fi

if [ -n "$FILTER" ]; then
  PYTEST_CMD="$PYTEST_CMD -k '$FILTER'"
fi

echo "==> Running tests against $APP_URL"
echo "    Command: APP_URL=$APP_URL $PYTEST_CMD"
echo ""

APP_URL="$APP_URL" eval "$PYTEST_CMD"
