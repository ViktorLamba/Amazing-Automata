#!/usr/bin/env bash
set -euo pipefail

LOGFILE="ci/logs/detect.log"
OUT="manifest.json"
mkdir -p ci/logs

log() { echo "$(date -Iseconds) $*" | tee -a "$LOGFILE" >&2; }

# --- Инициализация ---
language="unknown"
build_tool="unknown"
entry=""
start_cmd=""
build_cmd=""
test_cmd=""
deps_file=""
has_dockerfile=false
is_mobile=false
artifacts='[]'
targets='["linux/amd64"]'
database="unknown-database"

log "Start detect-entry..."

PROJECT_DIR="project"

find_file_recursive() {
  local pattern="$1"
  find "$PROJECT_DIR" -type f -name "$pattern" | head -n1
}

# --- 1) Manual override .deployrc ---
if [ -f .deployrc ]; then
  log "Found .deployrc — reading overrides"
  entry=$(jq -r '.entry // empty' .deployrc 2>/dev/null || echo "")
  start_cmd=$(jq -r '.start_cmd // empty' .deployrc 2>/dev/null || echo "")
  build_cmd=$(jq -r '.build_cmd // empty' .deployrc 2>/dev/null || echo "")
  test_cmd=$(jq -r '.test_cmd // empty' .deployrc 2>/dev/null || echo "")
  targets=$(jq -c '.targets // ["linux/amd64"]' .deployrc 2>/dev/null || echo '["linux/amd64"]')
  database=$(jq -r '.database // empty' .deployrc 2>/dev/null || echo "")
fi

# --- 2) Procfile ---
if [ -f Procfile ] && [ -z "$start_cmd" ]; then
  line=$(grep -E '^web:' Procfile | head -n1 || true)
  if [ -n "$line" ]; then
    start_cmd=$(echo "$line" | sed 's/^web:\s*//')
    log "Procfile -> start_cmd='$start_cmd'"
  fi
fi

# --- 3) Dockerfile ---
if [ -f "$PROJECT_DIR/Dockerfile" ]; then
  has_dockerfile=true
fi

# --- 4) Detect Python ---
pyproject_file=$(find_file_recursive "pyproject.toml")
requirements_file=$(find_file_recursive "requirements.txt")
any_py_file=$(find "$PROJECT_DIR" -type f -name "*.py" | head -n1 || true)

if [ -f "$pyproject_file" ] || [ -f "$requirements_file" ] || [ -n "$any_py_file" ]; then
  language="python"
  build_tool="pip"
  project_dir=$(dirname "${pyproject_file:-${requirements_file:-$any_py_file}}")

  entry=$(find "$project_dir" -maxdepth 1 -type f -name "manage.py" -o -name "main.py" | head -n1 || true)
  if [ -z "$entry" ]; then
    entry=$(find "$project_dir" -type f -name "*.py" | head -n1 || true)
  fi

  if [ -f "$requirements_file" ]; then
      deps_file="$requirements_file"
      build_cmd="cd $project_dir && pip install -r requirements.txt || true"
  else
      build_cmd="cd $project_dir && pip install . || true"
  fi
  test_cmd="cd $project_dir && pytest . || true"
  start_cmd="cd $project_dir && python $(basename "$entry")"
  artifacts='["project/**/.venv/","project/**/dist/"]'
  log "Detected Python project in $project_dir/, entry='$entry'"
fi

# --- 5) Detect Go ---
go_mod_file=$(find "$PROJECT_DIR" -type f -name "go.mod" | head -n1 || true)
main_go_file=$(find "$PROJECT_DIR" -type f -name "main.go" | head -n1 || true)
any_go_file=$(find "$PROJECT_DIR" -type f -name "*.go" | head -n1 || true)

if [ -f "$go_mod_file" ] || [ -f "$main_go_file" ] || [ -n "$any_go_file" ]; then
  language="go"
  build_tool="go"
  project_dir=$(dirname "${go_mod_file:-${main_go_file:-$any_go_file}}")
  entry=$(find "$project_dir" -type f -name "*.go" -exec grep -l "func main" {} + | head -n1 || true)
  entry="${entry:-$project_dir/main.go}"
  build_cmd="cd $project_dir && go build ./..."
  test_cmd="cd $project_dir && go test ./..."
  start_cmd="cd $project_dir && go run $(basename "$entry")"
  artifacts='["project/**/bin/"]'
  log "Detected Go project in $project_dir/"
fi

# --- 6) Detect Rust ---
cargo_file=$(find_file_recursive "Cargo.toml")
if [ -f "$cargo_file" ]; then
  language="rust"
  build_tool="cargo"
  project_dir=$(dirname "$cargo_file")
  deps_file="$cargo_file"
  main_rs_candidate=$(find "$project_dir" -name "main.rs" | head -n1 || true)
  any_rs_candidate=$(find "$project_dir" -name "*.rs" | head -n1 || true)
  entry="${main_rs_candidate:-${any_rs_candidate:-$project_dir/src/main.rs}}"
  build_cmd="cd $project_dir && cargo build --release"
  test_cmd="cd $project_dir && cargo test"
  start_cmd="cd $project_dir && cargo run"
  artifacts='["project/**/target/release/"]'
  log "Detected Rust project in $project_dir/"
fi

# --- 7) Detect C++ ---
cmake_file=$(find_file_recursive "CMakeLists.txt")
makefile_file=$(find_file_recursive "Makefile")

if [ -f "$cmake_file" ] || [ -f "$makefile_file" ]; then
  language="cpp"
  build_tool="cmake"
  project_dir=$(dirname "${cmake_file:-$makefile_file}")
  deps_file="${cmake_file:-$makefile_file}"
  main_cpp_candidate=$(find "$project_dir" -name "main.cpp" | head -n1 || true)
  any_cpp_candidate=$(find "$project_dir" -name "*.cpp" | head -n1 || true)
  entry="${main_cpp_candidate:-${any_cpp_candidate:-$project_dir/main.cpp}}"

  if [ -f "$cmake_file" ]; then
    build_cmd="cd $project_dir && mkdir -p build && cd build && cmake .. && make -j4"
    test_cmd="cd $project_dir/build && ctest . || true"
    start_cmd="cd $project_dir/build && ./$(basename $project_dir)"
  else
    build_cmd="cd $project_dir && make -j4"
    test_cmd="cd $project_dir && make test || true"
    start_cmd="cd $project_dir && ./$(basename $project_dir)"
  fi

  artifacts='["project/**/build/","project/**/bin/","project/**/*.exe"]'
  log "Detected C++ project in $project_dir/"
fi

# --- Fallback entry ---
if [ -z "$entry" ]; then
  for f in "$PROJECT_DIR/main.py" "$PROJECT_DIR/app.py" "$PROJECT_DIR/index.js" "$PROJECT_DIR/src/main.rs" "$PROJECT_DIR"/*.go; do
    if [ -f "$f" ]; then
      entry="$f"
      log "Fallback file found -> $entry"
      break
    fi
  done
fi

# --- Fallback start_cmd ---
if [ -z "$start_cmd" ] && [ -n "$entry" ]; then
  case "$entry" in
    *.py) start_cmd="python $entry" ;;
    *.js) start_cmd="node $entry" ;;
    *.go) start_cmd="go run $entry" ;;
    *.rs) start_cmd="cargo run" ;;
    *.jar) start_cmd="java -jar $entry" ;;
    *) start_cmd="" ;;
  esac
  log "Guessed start_cmd='$start_cmd'"
fi

# --- 8) Detect database (improved) ---
if [ -z "$database" ] || [ "$database" = "null" ]; then
  DB_SEARCH_FILES=$(find "$PROJECT_DIR" -type f \( -name "*.py" -o -name "*.env" -o -name "settings.py" -o -name "config.*" -o -name "*.php" -o -name "*.yml" -o -name "*.yaml" \))


  for file in $DB_SEARCH_FILES; do
    if grep -qi "mysql" "$file" || grep -qi "pdo_mysql" "$file"; then
        database="mysql"
        break
    elif grep -qi "postgres" "$file" || grep -qi "pdo_pgsql" "$file"; then
        database="postgres"
        break
    fi
  done


  if [ "$database" = "unknown-database" ]; then
    for file in $DB_SEARCH_FILES; do
      if grep -q '^DATABASE_URL=.*mysql' "$file"; then
          database="mysql"
          break
      elif grep -q '^DATABASE_URL=.*postgres' "$file"; then
          database="postgres"
          break
      fi
    done

  fi
fi

case "$database" in
  postgres|mysql)
    log "ℹ️ Database detected: $database"
    ;;
  unknown-database)
    log "⚠️ No supported database detected. The project will build without a database."
    ;;
  *)
    log "⚠️ Unsupported database '$database'. Using unknown-database."
    database="unknown-database"
    ;;
esac

# --- 9) Write manifest.json ---
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg language "$language" \
    --arg build_tool "$build_tool" \
    --arg entry "$entry" \
    --arg start_cmd "$start_cmd" \
    --arg build_cmd "$build_cmd" \
    --arg test_cmd "$test_cmd" \
    --arg deps_file "$deps_file" \
    --arg database "$database" \
    --argjson has_dockerfile "$([ "$has_dockerfile" = true ] && echo true || echo false)" \
    --argjson is_mobile "$([ "$is_mobile" = true ] && echo true || echo false)" \
    --argjson artifacts "$artifacts" \
    --argjson targets "$targets" \
    '{language:$language, build_tool:$build_tool, entry:$entry, start_cmd:$start_cmd, build_cmd:$build_cmd, test_cmd:$test_cmd, deps_file:$deps_file, database:$database, has_dockerfile:$has_dockerfile, is_mobile:$is_mobile, artifacts:$artifacts, targets:$targets}' \
    > "$OUT"
else
  cat > "$OUT" <<EOF
{
  "language": "$language",
  "build_tool": "$build_tool",
  "entry": "$entry",
  "start_cmd": "$start_cmd",
  "build_cmd": "$build_cmd",
  "test_cmd": "$test_cmd",
  "deps_file": "$deps_file",
  "database": "$database",
  "has_dockerfile": $([ "$has_dockerfile" = true ] && echo true || echo false),
  "is_mobile": $([ "$is_mobile" = true ] && echo true || echo false),
  "artifacts": $artifacts,
  "targets": $targets
}
EOF
fi

log "Manifest written to $OUT"
log "Done."
