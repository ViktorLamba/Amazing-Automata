#!/usr/bin/env bash
set -euo pipefail

LOGFILE="ci/logs/detect.log"
OUT="manifest.json"
mkdir -p ci logs ci/logs

log() { echo "$(date -Iseconds) $*" | tee -a "$LOGFILE" >&2; }

language="unknown"
build_tool="unknown"
entry=""
start_cmd=""
build_cmd=""
test_cmd=""
deps_file=""         # ← новое поле
has_dockerfile=false
is_mobile=false
artifacts='[]'
targets='["linux/amd64"]'

log "Start detect-entry..."

PROJECT_DIR="project"

find_file_recursive() {
  local pattern="$1"
  find "$PROJECT_DIR" -type f -name "$pattern" | head -n1
}

# 1) manual override .deployrc
if [ -f .deployrc ]; then
  log "Found .deployrc — reading overrides"
  entry=$(jq -r '.entry // empty' .deployrc 2>/dev/null || echo "")
  start_cmd=$(jq -r '.start_cmd // empty' .deployrc 2>/dev/null || echo "")
  build_cmd=$(jq -r '.build_cmd // empty' .deployrc 2>/dev/null || echo "")
  test_cmd=$(jq -r '.test_cmd // empty' .deployrc 2>/dev/null || echo "")
  targets=$(jq -c '.targets // ["linux/amd64"]' .deployrc 2>/dev/null || echo '["linux/amd64"]')
fi

# 2) Procfile
if [ -f Procfile ] && [ -z "$start_cmd" ]; then
  line=$(grep -E '^web:' Procfile | head -n1 || true)
  if [ -n "$line" ]; then
    start_cmd=$(echo "$line" | sed 's/^web:\s*//')
    log "Procfile -> start_cmd='$start_cmd'"
  fi
fi

# 3) Dockerfile
if [ -f "$PROJECT_DIR/Dockerfile" ]; then
  has_dockerfile=true
fi

# 5) Python
pyproject_file=$(find_file_recursive "pyproject.toml")
requirements_file=$(find_file_recursive "requirements.txt")
any_py_file=$(find "$PROJECT_DIR" -type f -name "*.py" | head -n1 || true)

if [ -f "$pyproject_file" ] || [ -f "$requirements_file" ] || [ -n "$any_py_file" ]; then
  language="python"
  build_tool="pip"

  # Определяем корневую папку проекта для Python
  if [ -f "$pyproject_file" ]; then
    project_dir=$(dirname "$pyproject_file")
  elif [ -f "$requirements_file" ]; then
    project_dir=$(dirname "$requirements_file")
  else
    project_dir=$(dirname "$any_py_file")
  fi

  # 1️⃣ Сначала ищем в корне
  entry=""
  if [ -f "$project_dir/manage.py" ]; then
      entry="$project_dir/manage.py"
  elif [ -f "$project_dir/main.py" ]; then
      entry="$project_dir/main.py"
  else
      any_root_py=$(find "$project_dir" -maxdepth 1 -type f -name "*.py" | head -n1 || true)
      if [ -n "$any_root_py" ]; then
          entry="$any_root_py"
      fi
  fi

  # 2️⃣ Если в корне не нашли — рекурсивно в подкаталогах
  if [ -z "$entry" ]; then
      manage_py=$(find "$project_dir" -mindepth 1 -type f -name "manage.py" | head -n1 || true)
      main_py=$(find "$project_dir" -mindepth 1 -type f -name "main.py" | head -n1 || true)
      any_py=$(find "$project_dir" -mindepth 1 -type f -name "*.py" | head -n1 || true)

      if [ -n "$manage_py" ]; then
          entry="$manage_py"
      elif [ -n "$main_py" ]; then
          entry="$main_py"
      elif [ -n "$any_py" ]; then
          entry="$any_py"
      fi
  fi

  # 3️⃣ Фолбэк
  if [ -z "$entry" ]; then
      entry="$project_dir/manage.py"
  fi

  # Build / Test / Start
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

# 6) Go
go_mod_file=$(find "$PROJECT_DIR" -type f -name "go.mod" | head -n1 || true)
main_go_file=$(find "$PROJECT_DIR" -type f -name "main.go" | head -n1 || true)
any_go_file=$(find "$PROJECT_DIR" -type f -name "*.go" | head -n1 || true)

if [ -f "$go_mod_file" ] || [ -f "$main_go_file" ] || [ -n "$any_go_file" ]; then
  language="go"
  build_tool="go"
  if [ -f "$go_mod_file" ]; then
    project_dir=$(dirname "$go_mod_file")
    deps_file="$go_mod_file"
  elif [ -f "$main_go_file" ]; then
    project_dir=$(dirname "$main_go_file")
  else
    project_dir=$(dirname "$any_go_file")
  fi

  mainfile=$(find "$project_dir" -type f -name "*.go" -exec grep -l "func main" {} + | head -n1 || true)
  if [ -n "$mainfile" ]; then
    entry="$mainfile"
  else
    entry="$project_dir/main.go"
  fi

  build_cmd="cd $project_dir && go build ./..."
  test_cmd="cd $project_dir && go test ./..."
  start_cmd="cd $project_dir && go run $(basename "$entry")"
  artifacts='["project/**/bin/"]'
  log "Detected Go project in $project_dir/"
fi

# 7) Rust
cargo_file=$(find_file_recursive "Cargo.toml")
if [ -f "$cargo_file" ]; then
  language="rust"
  build_tool="cargo"
  deps_file="$cargo_file"
  project_dir=$(dirname "$cargo_file")
  main_rs_candidate=$(find "$project_dir" -name "main.rs" | head -n1 || true)
  any_rs_candidate=$(find "$project_dir" -name "*.rs" | head -n1 || true)

  if [ -n "$main_rs_candidate" ]; then
    entry="$main_rs_candidate"
  elif [ -n "$any_rs_candidate" ]; then
    entry="$any_rs_candidate"
  else
    entry="$project_dir/src/main.rs"
  fi

  build_cmd="cd $project_dir && cargo build --release"
  test_cmd="cd $project_dir && cargo test"
  start_cmd="cd $project_dir && cargo run"
  artifacts='["project/**/target/release/"]'
  log "Detected Rust project in $project_dir/"
fi

# 8) C++
cmake_file=$(find_file_recursive "CMakeLists.txt")
makefile_file=$(find_file_recursive "Makefile")

if [ -f "$cmake_file" ] || [ -f "$makefile_file" ]; then
  language="cpp"
  build_tool="cmake"
  if [ -f "$cmake_file" ]; then
    project_dir=$(dirname "$cmake_file")
    deps_file="$cmake_file"
  else
    project_dir=$(dirname "$makefile_file")
    build_tool="make"
    deps_file="$makefile_file"
  fi

  main_cpp_candidate=$(find "$project_dir" -name "main.cpp" | head -n1 || true)
  any_cpp_candidate=$(find "$project_dir" -name "*.cpp" | head -n1 || true)

  if [ -n "$main_cpp_candidate" ]; then
    entry="$main_cpp_candidate"
  elif [ -n "$any_cpp_candidate" ]; then
    entry="$any_cpp_candidate"
  else
    entry="$project_dir/main.cpp"
  fi

  if [ "$build_tool" = "cmake" ]; then
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

# fallback entry
if [ -z "$entry" ]; then
  for f in "$PROJECT_DIR/main.py" "$PROJECT_DIR/app.py" "$PROJECT_DIR/index.js" "$PROJECT_DIR/src/main.rs" "$PROJECT_DIR"/*.go; do
    if [ -f "$f" ]; then
      entry="$f"
      log "Fallback file found -> $entry"
      break
    fi
  done
fi

# fallback start_cmd
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

# write manifest with deps_file
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg language "$language" \
    --arg build_tool "$build_tool" \
    --arg entry "$entry" \
    --arg start_cmd "$start_cmd" \
    --arg build_cmd "$build_cmd" \
    --arg test_cmd "$test_cmd" \
    --arg deps_file "$deps_file" \
    --argjson has_dockerfile "$([ "$has_dockerfile" = true ] && echo true || echo false)" \
    --argjson is_mobile "$([ "$is_mobile" = true ] && echo true || echo false)" \
    --argjson artifacts "$artifacts" \
    --argjson targets "$targets" \
    '{language:$language, build_tool:$build_tool, entry:$entry, start_cmd:$start_cmd, build_cmd:$build_cmd, test_cmd:$test_cmd, deps_file:$deps_file, has_dockerfile:$has_dockerfile, is_mobile:$is_mobile, artifacts:$artifacts, targets:$targets}' \
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
  "has_dockerfile": $([ "$has_dockerfile" = true ] && echo true || echo false),
  "is_mobile": $([ "$is_mobile" = true ] && echo true || echo false),
  "artifacts": $artifacts,
  "targets": $targets
}
EOF
fi

log "Manifest written to $OUT"
log "Done."
