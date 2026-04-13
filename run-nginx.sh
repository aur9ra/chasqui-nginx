#!/bin/bash
# =============================================================================
# Chasqui NGINX Deployment Script
# =============================================================================
# Orchestrates container startup with path resolution and pre-run validation
# =============================================================================

set -euo pipefail

# Determine script directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default IMAGE_TAG to "dev" for local development environments.
# This ensures the script looks for a development image by default,
# which is appropriate for the intended development workflow.
IMAGE_TAG="${IMAGE_TAG:-dev}"

echo "Beginning Chasqui NGINX Deployment..."
echo "Script directory: $SCRIPT_DIR"
echo ""

# -----------------------------------------------------------------------------
# Environment Loading
# -----------------------------------------------------------------------------

echo "Loading environment configuration..."

set -a # Automatically export all variables
source "$SCRIPT_DIR/.env.default"
if [ -f "$SCRIPT_DIR/.env" ]; then
  echo "Loading user overrides from .env"
  source "$SCRIPT_DIR/.env"
else
  # Create .env file if it doesn't exist to ensure user has a place
  # for custom configuration. We copy from the example to provide
  # documented options, falling back to an empty file if needed.
  if [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo "Created .env from template"
  else
    touch "$SCRIPT_DIR/.env"
    echo "Created empty .env file"
  fi
  echo ""
  echo "Edit .env to customize configuration"
  echo "Reference: .env.default (defaults) and BUILD.md (documentation)"
  echo ""
fi
set +a # Stop auto-export of variables

# -----------------------------------------------------------------------------
# Architecture Detection
# -----------------------------------------------------------------------------

echo "Detecting host architecture..."

ARCH=$(uname -m)
case "$ARCH" in
x86_64)
  PLATFORM="linux/amd64"
  echo "Detected architecture: x86_64 (AMD64)"
  ;;
aarch64 | arm64)
  PLATFORM="linux/arm64"
  echo "Detected architecture: ARM64"
  ;;
armv7l)
  PLATFORM="linux/arm/v7"
  echo "Detected architecture: ARMv7"
  ;;
*)
  echo "[WARNING] Unknown architecture $ARCH, defaulting to amd64" >&2
  PLATFORM="linux/amd64"
  ;;
esac

# -----------------------------------------------------------------------------
# Path Resolution
# -----------------------------------------------------------------------------

echo "Resolving paths..."

# Export resolved paths for Docker Compose
# These are evaluated in shell context, ensuring correct resolution
export CONTENT_DIR="${CONTENT_DIR:-../server/content}"

# Convert to absolute paths for better error messages
CONTENT_DIR="$(cd "$SCRIPT_DIR" && cd "$CONTENT_DIR" 2>/dev/null && pwd || echo "$CONTENT_DIR")"

export CONTENT_DIR

echo "Content directory: $CONTENT_DIR"

# -----------------------------------------------------------------------------
# Pre-run Validation
# -----------------------------------------------------------------------------

# Note: Static files are in the chasqui_dist Docker volume.
# NGINX will serve from /dist/container inside the container.
# If the volume is empty, NGINX will return 404s until the frontend
# completes its initial build.

# -----------------------------------------------------------------------------
# Docker Network Setup
# -----------------------------------------------------------------------------

echo ""
echo "Checking Docker infrastructure..."

if ! docker network inspect chasqui_network >/dev/null 2>&1; then
  echo "Creating chasqui_network..."
  docker network create chasqui_network
else
  echo "chasqui_network exists"
fi

if ! docker volume inspect chasqui_dist >/dev/null 2>&1; then
  echo "Creating chasqui_dist volume..."
  docker volume create chasqui_dist
else
  echo "chasqui_dist volume exists"
fi

# -----------------------------------------------------------------------------
# TLS Certificate Handling
# -----------------------------------------------------------------------------

echo ""
echo "Checking for TLS certificates..."

TLS_MOUNT=""
if [ -f "$SCRIPT_DIR/ssl/cert.pem" ] && [ -f "$SCRIPT_DIR/ssl/key.pem" ]; then
  echo "TLS certificates found - HTTPS will be enabled"

  # Set restrictive permissions on SSL directory
  chmod 700 "$SCRIPT_DIR/ssl" 2>/dev/null || true
  chmod 600 "$SCRIPT_DIR/ssl"/*.pem 2>/dev/null || true

  # Certificates are mounted via docker-compose volume, not command line
  TLS_MOUNT=""
else
  echo "[WARNING] No TLS certificates found in ssl/ directory" >&2
  echo "         Running in HTTP mode only" >&2
  echo ""
  echo "This is acceptable for:"
  echo "  - Local development"
  echo "  - Private networks (VPN, internal)"
  echo "  - Deployments behind Cloudflare or other TLS-terminating proxies"
  echo ""
  echo "For direct internet exposure, TLS is MANDATORY."
  echo "See BUILD.md for certificate setup instructions."
  echo ""
fi

# -----------------------------------------------------------------------------
# Container Deployment
# -----------------------------------------------------------------------------

echo ""
echo "Deploying NGINX container..."

# Attempt to pull the pre-built image from the registry.
# If the pull fails (e.g., no network, image doesn't exist), fall back to
# building from the local Dockerfile. This provides a seamless development
# experience where developers can work offline or with custom modifications.
IMAGE_NAME="ghcr.io/${GITHUB_USER:-chasqui}/chasqui-nginx:${IMAGE_TAG}"

echo "Pulling image: ${IMAGE_NAME}..."
if docker pull --platform "$PLATFORM" "$IMAGE_NAME" 2>/dev/null; then
  echo "Image pulled successfully"
else
  echo "Image pull failed, building locally from Dockerfile..."
  if ! docker compose -f docker-compose.yml build; then
    echo "Build failed — clearing BuildKit cache and retrying..."
    docker builder prune --all --force
    docker compose -f docker-compose.yml build
  fi
fi

# Start the container using the deployment compose file.
# If that fails (e.g., image was built locally with different naming),
# fall back to the development compose file which uses the local build context.
echo "Starting container..."
docker compose -f docker-compose.deploy.yml up -d 2>/dev/null || docker compose -f docker-compose.yml up -d

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

echo ""
echo "Waiting for container to start..."
sleep 2

if docker ps | grep -q chasqui-nginx; then
  echo "Container is running"

  # Quick health check
  NGINX_PORT="${NGINX_PORT:-8080}"
  if curl -s "http://localhost:${NGINX_PORT}/health" 2>/dev/null | grep -q "healthy"; then
    echo "Health check passed."
  else
    echo "Health check not responding yet (may need a few more seconds. check your deployment's health)"
  fi
else
  echo "ERROR: Container failed to start" >&2
  echo "Check logs with: docker logs chasqui-nginx" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Configuration Summary
# -----------------------------------------------------------------------------

echo ""
echo "=================================="
echo "  NGINX Configuration Summary"
echo "=================================="
echo "Port:              ${NGINX_PORT:-8080}"
echo "Static files:      chasqui_dist volume → /dist/container"
echo "Content directory: $CONTENT_DIR"
echo "API proxy:         ${ENABLE_API_PROXY:-false}"
if [ -f "$SCRIPT_DIR/ssl/cert.pem" ]; then
  echo "TLS:               Enabled (HTTPS on port 443)"
else
  echo "TLS:               Disabled (HTTP only)"
fi
echo "Container:         chasqui-nginx"
echo "=================================="
echo ""
echo "Container logs: docker logs -f chasqui-nginx"
echo "Stop:           docker compose -f docker-compose.deploy.yml down"
echo ""
echo "[OK] Deployment Complete"
