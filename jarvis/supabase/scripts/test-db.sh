#!/usr/bin/env bash
# Applies the Jarvis migrations to a throwaway PostgreSQL container and runs the
# database tests in supabase/tests.
#
# Requires Docker only: no local psql, no database credentials, no Supabase
# project. The container is deleted when the script exits.
#
#   ./supabase/scripts/test-db.sh
#   JARVIS_TEST_POSTGRES_IMAGE=postgres:17 ./supabase/scripts/test-db.sh
#   JARVIS_TEST_SUPABASE_LIKE=1 ./supabase/scripts/test-db.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${JARVIS_TEST_POSTGRES_IMAGE:-postgres:16}"
NAME="jarvis-db-test-$$"
DB="jarvis_test"

# Container paths are written relative to the container's working directory,
# which is / for the postgres image. Absolute arguments such as /migrations are
# rewritten by Git Bash into C:/Program Files/Git/migrations (even --workdir=/),
# so relative paths are what make this script work unchanged in Linux, WSL and
# Git Bash.

cleanup() {
    docker rm --force "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting $IMAGE as $NAME"
docker run --detach --name "$NAME" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --env POSTGRES_DB=postgres \
    "$IMAGE" >/dev/null

for _ in $(seq 1 120); do
    if docker exec "$NAME" pg_isready --quiet --username postgres --dbname postgres; then
        break
    fi
    sleep 1
done
docker exec "$NAME" pg_isready --quiet --username postgres --dbname postgres

docker exec "$NAME" createdb --username postgres "$DB"
docker cp "$ROOT/supabase/migrations" "$NAME:/migrations" >/dev/null
docker cp "$ROOT/supabase/tests" "$NAME:/tests" >/dev/null
docker cp "$ROOT/supabase/scripts/bootstrap-test-roles.sql" \
    "$NAME:/bootstrap-test-roles.sql" >/dev/null

# The client roles must exist before the access-control migration so that its
# revokes are exercised against real roles, not skipped.
echo "bootstrap test roles"
docker exec "$NAME" psql --quiet --set ON_ERROR_STOP=1 \
    --username postgres --dbname "$DB" --file bootstrap-test-roles.sql >/dev/null

# Optional: start from the state a fresh Supabase project is in (extensions
# schema already present, pgcrypto and pg_trgm already installed) instead of an
# empty database.
if [ "${JARVIS_TEST_SUPABASE_LIKE:-0}" = "1" ]; then
    docker cp "$ROOT/supabase/scripts/bootstrap-supabase-like.sql" \
        "$NAME:/bootstrap-supabase-like.sql" >/dev/null
    echo "bootstrap supabase-like state"
    docker exec "$NAME" psql --quiet --set ON_ERROR_STOP=1 \
        --username postgres --dbname "$DB" --file bootstrap-supabase-like.sql >/dev/null
fi

for file in $(docker exec "$NAME" ls migrations | sort); do
    echo "migration $file"
    docker exec "$NAME" psql --quiet --set ON_ERROR_STOP=1 \
        --username postgres --dbname "$DB" --file "migrations/$file" >/dev/null
done

failures=0
total=0
for file in $(docker exec "$NAME" ls tests | sort); do
    total=$((total + 1))
    if docker exec "$NAME" psql --quiet --set ON_ERROR_STOP=1 \
        --username postgres --dbname "$DB" --file "tests/$file" >/dev/null; then
        echo "ok   $file"
    else
        echo "FAIL $file"
        docker exec "$NAME" psql --set ON_ERROR_STOP=1 \
            --username postgres --dbname "$DB" --file "tests/$file" 2>&1 | tail -n 20 || true
        failures=$((failures + 1))
    fi
done

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures of $total test files failed"
    exit 1
fi
echo "all $total test files passed"
