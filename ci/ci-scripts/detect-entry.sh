#!/usr/bin/env bash
set -euo pipefail

LOGFILE="ci/logs/detect.log"
OUT="ci/manifest.json"
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
if [ -f Dockerfile ]; then
  has_dockerfile=true
  docker_cmd=$(awk '/ENTRYPOINT|^CMD/ {print $0; exit}' Dockerfile || true)
  if [ -n "$docker_cmd" ] && [ -z "$start_cmd" ]; then
    start_cmd="$docker_cmd"
    log "Dockerfile -> start_cmd guess='$start_cmd'"
  else
    log "Dockerfile present but no ENTRYPOINT/CMD parsed"
  fi
fi

# 4) Node.js
if [ -f package.json ]; then
  language="node"
  build_tool="npm"
  [ -f tsconfig.json ] && language="typescript"
  if [ -z "$entry" ]; then entry=$(jq -r '.main // empty' package.json 2>/dev/null || echo ""); fi
  if [ -z "$build_cmd" ]; then build_cmd=$(jq -r '.scripts.build // empty' package.json 2>/dev/null || echo ""); fi
  if [ -z "$start_cmd" ]; then start_cmd=$(jq -r '.scripts.start // empty' package.json 2>/dev/null || echo ""); fi
  if [ -z "$test_cmd" ]; then test_cmd=$(jq -r '.scripts.test // empty' package.json 2>/dev/null || echo ""); fi
  artifacts='["dist/"]'
  log "Detected Node.js project"
fi

# 5) Python
if [ -f pyproject.toml ] || [ -f requirements.txt ] || ls *.py >/dev/null 2>&1; then
  language="python"
  build_tool="pip"
  if [ -f main.py ] && [ -z "$entry" ]; then entry="main.py"; fi
  if [ -z "$entry" ]; then
    candidate=$(grep -R --line-number "if __name__.*__main__" -n --exclude-dir=venv . 2>/dev/null | head -n1 || true)
    [ -n "$candidate" ] && entry=$(echo "$candidate" | cut -d: -f1)
  fi
  if [ -z "$build_cmd" ]; then build_cmd="pip install -r requirements.txt || true"; fi
  if [ -z "$test_cmd" ]; then test_cmd="pytest || true"; fi
  artifacts='[".venv/","dist/"]'
  log "Detected Python project"
fi

# 6) Go
if ls *.go >/dev/null 2>&1; then
  language="go"
  build_tool="go"
  mainfile=$(grep -R -l "package main" . 2>/dev/null | while read f; do grep -q "func main" "$f" && echo "$f"; done | head -n1 || true)
  [ -n "$mainfile" ] && entry="$mainfile"
  build_cmd=${build_cmd:-"go build ./..."}
  test_cmd=${test_cmd:-"go test ./..."}
  artifacts='["bin/"]'
  log "Detected Go project"
fi

# 7) Rust
if [ -f Cargo.toml ]; then
  language="rust"
  build_tool="cargo"
  [ -z "$entry" ] && entry="src/main.rs"
  build_cmd=${build_cmd:-"cargo build --release"}
  test_cmd=${test_cmd:-"cargo test"}
  artifacts='["target/release/"]'
  log "Detected Rust project"
fi

# 8) Java (Maven / Gradle)
if [ -f pom.xml ]; then
  language="java"
  build_tool="maven"
  build_cmd=${build_cmd:-"mvn -B package"}
  test_cmd=${test_cmd:-"mvn test"}
  artifacts='["target/*.jar"]'
  log "Detected Java (Maven) project"
fi
if [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  language="java"
  build_tool="gradle"
  build_cmd=${build_cmd:-"./gradlew build || gradle build"}
  test_cmd=${test_cmd:-"./gradlew test || gradle test"}
  artifacts='["build/libs/*.jar"]'
  log "Detected Java (Gradle) project"
fi

# 9) .NET
if ls *.csproj >/dev/null 2>&1; then
  language="dotnet"
  build_tool="dotnet"
  entry=$(ls *.csproj | head -n1)
  build_cmd=${build_cmd:-"dotnet build"}
  test_cmd=${test_cmd:-"dotnet test"}
  artifacts='["bin/Release/"]'
  log "Detected .NET project"
fi

# 10) fallback filename patterns
if [ -z "$entry" ]; then
  for f in main.py app.py wsgi.py index.js server.js app.js src/index.js src/main.rs main.rs; do
    if [ -f "$f" ]; then
      entry="$f"
      log "Fallback file found -> $entry"
      break
    fi
  done
fi

# 11) guess start_cmd if missing
if [ -z "$start_cmd" ] && [ -n "$entry" ]; then
  case "$entry" in
    *.py) start_cmd="python $entry" ;;
    *.js) start_cmd="node $entry" ;;
    *.ts) start_cmd="npm run build && node dist/$(basename "$entry" .ts).js" ;;
    *.go) start_cmd="./$(basename $(pwd))" ;;
    *.rs) start_cmd="cargo run" ;;
    *.jar) start_cmd="java -jar $entry" ;;
    *) start_cmd="" ;;
  esac
  log "Guessed start_cmd='$start_cmd'"
fi

# write manifest (use jq if present to be safe)
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
