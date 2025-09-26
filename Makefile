.PHONY: detect build run test docker-build

detect:
	bash ci/ci-scripts/detect-entry.sh
	@echo "Manifest:"
	cat ci/manifest.json

build:
	@if [ -f ci/manifest.json ]; then \
	  BUILD_CMD=$$(jq -r '.build_cmd // empty' ci/manifest.json); \
	  if [ -n "$$BUILD_CMD" ]; then echo "Running: $$BUILD_CMD"; bash -lc "$$BUILD_CMD"; else echo "No build_cmd found"; fi \
	else \
	  echo "Run 'make detect' first"; exit 1; \
	fi

run:
	@if [ -f ci/manifest.json ]; then \
	  START_CMD=$$(jq -r '.start_cmd // empty' ci/manifest.json); \
	  if [ -n "$$START_CMD" ]; then echo "Run: $$START_CMD"; bash -lc "$$START_CMD"; else echo "No start_cmd in manifest"; fi \
	else \
	  echo "Run 'make detect' first"; exit 1; \
	fi

test:
	@if [ -f ci/manifest.json ]; then \
	  TEST_CMD=$$(jq -r '.test_cmd // empty' ci/manifest.json); \
	  if [ -n "$$TEST_CMD" ]; then echo "Test: $$TEST_CMD"; bash -lc "$$TEST_CMD"; else echo "No test_cmd in manifest"; fi \
	else \
	  echo "Run 'make detect' first"; exit 1; \
	fi

docker-build:
	@if [ -f Dockerfile ] || ( [ -f ci/manifest.json ] && [ "$$(jq -r '.has_dockerfile' ci/manifest.json)" = "true" ] ); then \
	  PLAT=$$(jq -r '.targets | join(",")' ci/manifest.json 2>/dev/null || echo "linux/amd64"); \
	  echo "Building multi-arch: $$PLAT"; \
	  docker buildx create --use || true; \
	  docker buildx build --platform $$PLAT -t myimage:latest . --load; \
	else \
	  echo "No Dockerfile found or manifest.has_dockerfile != true"; exit 1; \
	fi
