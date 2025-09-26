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

# 4) Node.js
if find_file_recursive "package.json" >/dev/null; then
  pkg_json=$(find_file_recursive "package.json")
  language="node"
  build_tool="npm"
  ts_file=$(find_file_recursive "tsconfig.json")
  [ -n "$ts_file" ] && language="typescript"

  if [ -z "$entry" ]; then
    main_field=$(jq -r '.main // empty' "$pkg_json" 2>/dev/null)
    [ -n "$main_field" ] && entry="$(dirname "$pkg_json")/$main_field"
  fi

  build_cmd="cd $(dirname "$pkg_json") && npm run build || true"
  start_cmd="cd $(dirname "$pkg_json") && npm run start || true"
  test_cmd="cd $(dirname "$pkg_json") && npm run test || true"
  artifacts='["project/**/dist/"]'
  log "Detected Node.js project in $(dirname "$pkg_json")/"
fi

# 5) Python
py_file=$(find "$PROJECT_DIR" -type f -name "*.py" | head -n1 || true)
if [ -f "$(find_file_recursive "pyproject.toml")" ] || [ -f "$(find_file_recursive "requirements.txt")" ] || [ -n "$py_file" ]; then
  language="python"
  build_tool="pip"

  if [ -z "$entry" ]; then
    entry_candidate=$(find_file_recursive "main.py")
    [ -n "$entry_candidate" ] && entry="$entry_candidate"
  fi
  if [ -z "$entry" ] && [ -n "$py_file" ]; then
    entry="$py_file"
  fi

  build_cmd="pip install -r $(find_file_recursive "requirements.txt") || true"
  test_cmd="pytest $PROJECT_DIR || true"
  start_cmd="python $entry"
  artifacts='["project/**/.venv/","project/**/dist/"]'
  log "Detected Python project in $PROJECT_DIR/"
fi

# 6) Go
go_file=$(find "$PROJECT_DIR" -type f -name "*.go" | head -n1 || true)
if [ -n "$go_file" ]; then
  language="go"
  build_tool="go"
  mainfile=$(find "$PROJECT_DIR" -type f -name "*.go" -exec grep -l "func main" {} + | head -n1)
  [ -n "$mainfile" ] && entry="$mainfile"
  build_cmd="cd $PROJECT_DIR && go build ./..."
  test_cmd="cd $PROJECT_DIR && go test ./..."
  start_cmd="go run $entry"
  artifacts='["project/**/bin/"]'
  log "Detected Go project in $PROJECT_DIR/"
fi

# 7) Rust
cargo_file=$(find_file_recursive "Cargo.toml")
if [ -f "$cargo_file" ]; then
  language="rust"
  build_tool="cargo"
  [ -z "$entry" ] && entry="$(dirname "$cargo_file")/src/main.rs"
  build_cmd="cd $(dirname "$cargo_file") && cargo build --release"
  test_cmd="cd $(dirname "$cargo_file") && cargo test"
  start_cmd="cd $(dirname "$cargo_file") && cargo run"
  artifacts='["project/**/target/release/"]'
  log "Detected Rust project in $(dirname "$cargo_file")/"
fi

# 8) Java
pom_file=$(find_file_recursive "pom.xml")
gradle_file=$(find_file_recursive "build.gradle") || gradle_file=$(find_file_recursive "build.gradle.kts")
if [ -f "$pom_file" ]; then
  language="java"
  build_tool="maven"
  [ -z "$entry" ] && entry="$(dirname "$pom_file")/src/main/java"
  build_cmd="cd $(dirname "$pom_file") && mvn -B package"
  test_cmd="cd $(dirname "$pom_file") && mvn test"
  start_cmd="cd $(dirname "$pom_file") && java -jar target/*.jar"
  artifacts='["project/**/target/*.jar"]'
  log "Detected Java (Maven) project in $(dirname "$pom_file")/"
elif [ -f "$gradle_file" ]; then
  language="java"
  build_tool="gradle"
  [ -z "$entry" ] && entry="$(dirname "$gradle_file")/src/main/java"
  build_cmd="cd $(dirname "$gradle_file") && ./gradlew build || gradle build"
  test_cmd="cd $(dirname "$gradle_file") && ./gradlew test || gradle test"
  start_cmd="cd $(dirname "$gradle_file") && java -jar build/libs/*.jar"
  artifacts='["project/**/build/libs/*.jar"]'
  log "Detected Java (Gradle) project in $(dirname "$gradle_file")/"
fi

# 9) .NET
csproj_file=$(find "$PROJECT_DIR" -type f -name "*.csproj" | head -n1)
if [ -f "$csproj_file" ]; then
  language="dotnet"
  build_tool="dotnet"
  [ -z "$entry" ] && entry="$csproj_file"
  build_cmd="cd $(dirname "$csproj_file") && dotnet build"
  test_cmd="cd $(dirname "$csproj_file") && dotnet test"
  start_cmd="cd $(dirname "$csproj_file") && dotnet run"
  artifacts='["project/**/bin/Release/"]'
  log "Detected .NET project in $(dirname "$csproj_file")/"
fi

# 10) fallback filename patterns
if [ -z "$entry" ]; then
  for f in "$PROJECT_DIR"/main.py "$PROJECT_DIR"/app.py "$PROJECT_DIR"/wsgi.py \
           "$PROJECT_DIR"/index.js "$PROJECT_DIR"/server.js "$PROJECT_DIR"/app.js \
           "$PROJECT_DIR"/src/index.js "$PROJECT_DIR"/src/main.rs \
           "$PROJECT_DIR"/*.go; do
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
    project/*.py) start_cmd="python $entry" ;;
    project/*.js) start_cmd="node $entry" ;;
    project/*.ts) start_cmd="cd project && npm run build && node dist/$(basename "$entry" .ts).js" ;;
    project/*.go) start_cmd="go run $entry" ;;
    project/*.rs) start_cmd="cd project && cargo run" ;;
    project/*.jar) start_cmd="java -jar $entry" ;;
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
