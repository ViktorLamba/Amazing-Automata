#!/usr/bin/env bash
set -euo pipefail

# 1. Определяем проект и создаём manifest.json
bash ci/ci-scripts/detect-entry.sh

# 2. Проверяем manifest.json
MANIFEST="project/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  echo "❌ Manifest not found! Run detect-entry.sh first."
  exit 1
fi

LANGUAGE=$(jq -r '.language' "$MANIFEST")
HAS_DOCKERFILE=$(jq -r '.has_dockerfile' "$MANIFEST")

IMAGE_NAME="auto-project:latest"

echo "📦 Language: $LANGUAGE"
echo "📄 Dockerfile present: $HAS_DOCKERFILE"

# 3. Выбор стратегии сборки
if [ "$HAS_DOCKERFILE" = "true" ]; then
  echo "🚀 Building Docker image from existing Dockerfile..."
  docker build -t "$IMAGE_NAME" project/
else
  echo "⚙️  No Dockerfile found. Generating from manifest..."
  bash ci/ci-scripts/docker-build-from-manifest.sh "$MANIFEST" "$IMAGE_NAME"
fi

echo "✅ Build finished. Image: $IMAGE_NAME"
