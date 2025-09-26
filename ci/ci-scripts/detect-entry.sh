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
has_dockerfile=false
is_mobile=false
artifacts='[]'
targets='["linux/amd64"]'

log "Start detect-entry..."

PROJECT_DIR="project"

# рекурсивная функция поиска файла по имени/шаблону
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
  dockerfile="${PROJECT_DIR}/Dockerfile"
  [ -f Dockerfile ] && dockerfile="Dockerfile"
  docker_cmd=$(awk '/ENTRYPOINT|^CMD/ {print $0; exit}' "$dockerfile" || true)
  if [ -n "$docker_cmd" ] && [ -z "$start_cmd" ]; then
    start_cmd="$docker_cmd"
    log "Dockerfile -> start_cmd guess='$start_cmd'"
  else
    log "Dockerfile present but no ENTRYPOINT/CMD parsed"
  fi
fi


# 5) Python
pyproject_file=$(find_file_recursive "pyproject.toml")
requirements_file=$(find_file_recursive "requirements.txt")
py_file=$(find "$PROJECT_DIR" -type f -name "*.py" | head -n1 || true)

if [ -f "$pyproject_file" ] || [ -f "$requirements_file" ] || [ -n "$py_file" ]; then
  language="python"
  build_tool="pip"

  # Определяем корневую папку Python проекта
  if [ -f "$pyproject_file" ]; then
    project_dir=$(dirname "$pyproject_file")
  elif [ -f "$requirements_file" ]; then
    project_dir=$(dirname "$requirements_file")
  else
    project_dir=$(dirname "$py_file")
  fi

  # Принудительно устанавливаем Python entry
  main_py_candidate=$(find "$project_dir" -name "main.py" | head -n1 || true)
  any_py_candidate=$(find "$project_dir" -name "*.py" | head -n1 || true)

  if [ -n "$main_py_candidate" ] && [ -f "$main_py_candidate" ]; then
    entry="$main_py_candidate"
    log "Set Python entry to main.py: $entry"
  elif [ -n "$any_py_candidate" ] && [ -f "$any_py_candidate" ]; then
    entry="$any_py_candidate"
    log "Set Python entry to first .py file: $entry"
  else
    log "Warning: No Python source files found in $project_dir"
    entry="$project_dir/main.py"  # fallback path
  fi

  # Обновляем команды с правильным путём
  if [ -f "$requirements_file" ]; then
    build_cmd="cd $project_dir && pip install -r requirements.txt || true"
  else
    build_cmd="cd $project_dir && pip install . || true"
  fi
  
  test_cmd="cd $project_dir && pytest . || true"
  start_cmd="cd $project_dir && python $(basename "$entry")"
  artifacts='["project/**/.venv/","project/**/dist/"]'
  log "Detected Python project in $project_dir/"
fi

# 6) Go
go_mod_file=$(find "$PROJECT_DIR" -type f -name "go.mod" | head -n1 || true)
main_go_file=$(find "$PROJECT_DIR" -type f -name "main.go" | head -n1 || true)
any_go_file=$(find "$PROJECT_DIR" -type f -name "*.go" | head -n1 || true)

if [ -f "$go_mod_file" ] || [ -f "$main_go_file" ] || [ -n "$any_go_file" ]; then
  language="go"
  build_tool="go"

  # Определяем корень go-проекта
  if [ -f "$go_mod_file" ]; then
    project_dir=$(dirname "$go_mod_file")
  elif [ -f "$main_go_file" ]; then
    project_dir=$(dirname "$main_go_file")
  else
    project_dir=$(dirname "$any_go_file")
  fi

  # Находим файл с func main
  mainfile=$(find "$project_dir" -type f -name "*.go" -exec grep -l "func main" {} + | head -n1 || true)
  if [ -n "$mainfile" ] && [ -f "$mainfile" ]; then
    entry="$mainfile"
    log "Set Go entry to file with func main: $entry"
  else
    entry="$project_dir/main.go"  # fallback
    log "Warning: No file with func main found, fallback entry: $entry"
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
  
  # Принудительно устанавливаем Rust entry, даже если он уже не пустой
  project_dir=$(dirname "$cargo_file")
  
  # Ищем main.rs во всей папке проекта рекурсивно
  main_rs_candidate=$(find "$project_dir" -name "main.rs" | head -n1 || true)
  lib_rs_candidate=$(find "$project_dir" -name "lib.rs" | head -n1 || true)
  any_rs_candidate=$(find "$project_dir" -name "*.rs" | head -n1 || true)
  
  if [ -n "$main_rs_candidate" ] && [ -f "$main_rs_candidate" ]; then
    entry="$main_rs_candidate"
    log "Set Rust entry to main.rs: $entry"
  elif [ -n "$lib_rs_candidate" ] && [ -f "$lib_rs_candidate" ]; then
    entry="$lib_rs_candidate"
    log "Set Rust entry to lib.rs: $entry"
  elif [ -n "$any_rs_candidate" ] && [ -f "$any_rs_candidate" ]; then
    entry="$any_rs_candidate"
    log "Set Rust entry to first .rs file: $entry"
  else
    log "Warning: No Rust source files found in $project_dir"
    entry="$project_dir/src/main.rs"  # fallback path
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
  
  # Определяем корневую папку проекта
  if [ -f "$cmake_file" ]; then
    project_dir=$(dirname "$cmake_file")
    build_tool="cmake"
  else
    project_dir=$(dirname "$makefile_file")
    build_tool="make"
  fi
  
  # Ищем основные C++ файлы во всей папке проекта рекурсивно
  main_cpp_candidate=$(find "$project_dir" -name "main.cpp" | head -n1 || true)
  main_cc_candidate=$(find "$project_dir" -name "main.cc" | head -n1 || true)
  main_cxx_candidate=$(find "$project_dir" -name "main.cxx" | head -n1 || true)
  any_cpp_candidate=$(find "$project_dir" -name "*.cpp" | head -n1 || true)
  any_cc_candidate=$(find "$project_dir" -name "*.cc" | head -n1 || true)
  any_cxx_candidate=$(find "$project_dir" -name "*.cxx" | head -n1 || true)
  any_cplusplus_candidate=$(find "$project_dir" -name "*.c++" | head -n1 || true)
  
  # Приоритет поиска entry point
  if [ -n "$main_cpp_candidate" ] && [ -f "$main_cpp_candidate" ]; then
    entry="$main_cpp_candidate"
    log "Set C++ entry to main.cpp: $entry"
  elif [ -n "$main_cc_candidate" ] && [ -f "$main_cc_candidate" ]; then
    entry="$main_cc_candidate"
    log "Set C++ entry to main.cc: $entry"
  elif [ -n "$main_cxx_candidate" ] && [ -f "$main_cxx_candidate" ]; then
    entry="$main_cxx_candidate"
    log "Set C++ entry to main.cxx: $entry"
  elif [ -n "$any_cpp_candidate" ] && [ -f "$any_cpp_candidate" ]; then
    entry="$any_cpp_candidate"
    log "Set C++ entry to first .cpp file: $entry"
  elif [ -n "$any_cc_candidate" ] && [ -f "$any_cc_candidate" ]; then
    entry="$any_cc_candidate"
    log "Set C++ entry to first .cc file: $entry"
  elif [ -n "$any_cxx_candidate" ] && [ -f "$any_cxx_candidate" ]; then
    entry="$any_cxx_candidate"
    log "Set C++ entry to first .cxx file: $entry"
  elif [ -n "$any_cplusplus_candidate" ] && [ -f "$any_cplusplus_candidate" ]; then
    entry="$any_cplusplus_candidate"
    log "Set C++ entry to first .c++ file: $entry"
  else
    log "Warning: No C++ source files found in $project_dir"
    entry="$project_dir/main.cpp"  # fallback path
  fi
  
  # Команды сборки в зависимости от build tool
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


# 10) fallback entry
if [ -z "$entry" ]; then
  for f in "$PROJECT_DIR/main.py" "$PROJECT_DIR/app.py" "$PROJECT_DIR/wsgi.py" \
           "$PROJECT_DIR/index.js" "$PROJECT_DIR/server.js" "$PROJECT_DIR/app.js" \
           "$PROJECT_DIR/src/index.js" "$PROJECT_DIR/src/main.ts" "$PROJECT_DIR/src/main.tsx" \
           "$PROJECT_DIR/src/main.rs" "$PROJECT_DIR"/*.go; do
    if [ -f "$f" ]; then
      entry="$f"
      log "Fallback file found -> $entry"
      break
    fi
  done
fi

# 11) final fallback start_cmd
if [ -z "$start_cmd" ] && [ -n "$entry" ]; then
  case "$entry" in
    *.py) start_cmd="python $entry" ;;
    *.js) start_cmd="node $entry" ;;
    *.ts|*.tsx) start_cmd="cd $PROJECT_DIR && npm run build && node dist/$(basename "$entry" .ts).js" ;;
    *.go) start_cmd="go run $entry" ;;
    *.rs) start_cmd="cd $PROJECT_DIR && cargo run" ;;
    *.jar) start_cmd="java -jar $entry" ;;
    *) start_cmd="" ;;
  esac
  log "Guessed start_cmd='$start_cmd'"
fi

# write manifest
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg language "$language" \
    --arg build_tool "$build_tool" \
    --arg entry "$entry" \
    --arg start_cmd "$start_cmd" \
    --arg build_cmd "$build_cmd" \
    --arg test_cmd "$test_cmd" \
    --argjson has_dockerfile "$([ "$has_dockerfile" = true ] && echo true || echo false)" \
    --argjson is_mobile "$([ "$is_mobile" = true ] && echo true || echo false)" \
    --argjson artifacts "$artifacts" \
    --argjson targets "$targets" \
    '{language:$language, build_tool:$build_tool, entry:$entry, start_cmd:$start_cmd, build_cmd:$build_cmd, test_cmd:$test_cmd, has_dockerfile:$has_dockerfile, is_mobile:$is_mobile, artifacts:$artifacts, targets:$targets}' \
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
  "has_dockerfile": $([ "$has_dockerfile" = true ] && echo true || echo false),
  "is_mobile": $([ "$is_mobile" = true ] && echo true || echo false),
  "artifacts": $artifacts,
  "targets": $targets
}
EOF
fi

log "Manifest written to $OUT"
log "Done."
