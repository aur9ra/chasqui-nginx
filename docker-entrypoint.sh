#!/bin/sh
set -e

# =============================================================================
# Chasqui NGINX Container Entrypoint
# =============================================================================
# Security boundary between config input and nginx execution.
# Attempt to validate all environment variables before use.
# Invalid input should fail with descriptive error messages.
# =============================================================================

# -----------------------------------------------------------------------------
# Validation Functions
# -----------------------------------------------------------------------------

# Port validation: numeric, 1024-65535 (non-privileged)
validate_port() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  esac
  if [ "$1" -lt 1024 ] || [ "$1" -gt 65535 ]; then
    return 1
  fi
  return 0
}

# Real IP header validation: alphanumeric and hyphens only
validate_header_name() {
  echo "$1" | grep -qE '^[A-Za-z0-9-]+$'
}

# CIDR validation: x.x.x.x/y format
validate_cidr() {
  echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
}

# Validate list of CIDRs (space-separated)
validate_cidr_list() {
  for item in $1; do
    validate_cidr "$item" || return 1
  done
}

# URL validation
validate_url() {
  echo "$1" | grep -qE '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$'
}

# Boolean validation: true/false/1/0 (case-insensitive)
validate_boolean() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
  true | 1 | false | 0 | '') return 0 ;;
  *) return 1 ;;
  esac
}

# Convert string to boolean value
parse_boolean() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
  true | 1) echo "true" ;;
  false | 0 | '') echo "false" ;;
  esac
}

# -----------------------------------------------------------------------------
# Environment Validation
# -----------------------------------------------------------------------------

echo "Chasqui NGINX Container Entrypoint"
echo "Validating environment variables..."

# NGINX_PORT: numeric, 1024-65535
if ! validate_port "${NGINX_PORT:-8080}"; then
  echo "[ERROR]: Invalid NGINX_PORT: ${NGINX_PORT}" >&2
  echo "Port must be numeric and in range 1024-65535 (non-privileged)" >&2
  exit 1
fi
echo "[OK] NGINX_PORT: ${NGINX_PORT:-8080}"

# SERVER_API_URL: valid HTTP/HTTPS URL
if ! validate_url "${SERVER_API_URL:-http://chasqui-server:3003}"; then
  echo "[ERROR]: Invalid SERVER_API_URL: ${SERVER_API_URL}" >&2
  echo "URL must match pattern: http(s)://hostname(:port)" >&2
  exit 1
fi
echo "[OK] SERVER_API_URL: ${SERVER_API_URL:-http://chasqui-server:3003}"

# ENABLE_API_PROXY: boolean
if ! validate_boolean "${ENABLE_API_PROXY:-false}"; then
  echo "[ERROR]: Invalid ENABLE_API_PROXY: ${ENABLE_API_PROXY}" >&2
  echo "Must be one of: true, false, 1, 0" >&2
  exit 1
fi
ENABLE_API_PROXY=$(parse_boolean "${ENABLE_API_PROXY:-false}")
echo "[OK] ENABLE_API_PROXY: ${ENABLE_API_PROXY}"

# NGINX_LOG_LEVEL: one of nginx's native levels
case "${NGINX_LOG_LEVEL:-warn}" in
debug | info | notice | warn | error | crit | alert | emerg)
  echo "[OK] NGINX_LOG_LEVEL: ${NGINX_LOG_LEVEL:-warn}"
  ;;
*)
  echo "ERROR: Invalid NGINX_LOG_LEVEL: ${NGINX_LOG_LEVEL}" >&2
  echo "Must be one of: debug, info, notice, warn, error, crit, alert, emerg" >&2
  exit 1
  ;;
esac

# REAL_IP_HEADER: alphanumeric and hyphens only (if set)
if [ -n "${REAL_IP_HEADER:-}" ]; then
  if ! validate_header_name "${REAL_IP_HEADER}"; then
    echo "ERROR: Invalid REAL_IP_HEADER: ${REAL_IP_HEADER}" >&2
    echo "Header name must contain only alphanumeric characters and hyphens" >&2
    echo "Valid examples: X-Forwarded-For, CF-Connecting-IP, X-Real-IP" >&2
    exit 1
  fi
  echo "[OK] REAL_IP_HEADER: ${REAL_IP_HEADER}"
fi

# TRUSTED_PROXIES: CIDR list (if set)
if [ -n "${TRUSTED_PROXIES:-}" ]; then
  if ! validate_cidr_list "${TRUSTED_PROXIES}"; then
    echo "ERROR: Invalid TRUSTED_PROXIES: ${TRUSTED_PROXIES}" >&2
    echo "Each entry must be valid CIDR notation (e.g., 192.168.1.0/24)" >&2
    exit 1
  fi
  echo "[OK] TRUSTED_PROXIES: ${TRUSTED_PROXIES}"
fi

# Mandatory dependency: TRUSTED_PROXIES required when REAL_IP_HEADER is set
if [ -n "${REAL_IP_HEADER:-}" ] && [ -z "${TRUSTED_PROXIES:-}" ]; then
  echo "ERROR: TRUSTED_PROXIES is required when REAL_IP_HEADER is set" >&2
  echo "Without trusted proxy definitions, nginx would accept the real IP" >&2
  echo "header from any source, allowing trivial IP spoofing attacks." >&2
  exit 1
fi

# Cache settings: accept any value (nginx will validate at runtime)
echo "[OK] CACHE_STATIC_EXPIRES: ${CACHE_STATIC_EXPIRES:-30d}"
echo "[OK] CACHE_HTML_EXPIRES: ${CACHE_HTML_EXPIRES:-0}"

# -----------------------------------------------------------------------------
# TLS Certificate Detection
# -----------------------------------------------------------------------------

TLS_ENABLED=false
if [ -f "/etc/nginx/ssl/cert.pem" ] && [ -f "/etc/nginx/ssl/key.pem" ]; then
  TLS_ENABLED=true
  echo "[OK] TLS certificates detected - HTTPS will be enabled"

  # Check certificate file permissions (warn only)
  cert_perms=$(stat -c "%a" /etc/nginx/ssl/cert.pem 2>/dev/null || echo "unknown")
  key_perms=$(stat -c "%a" /etc/nginx/ssl/key.pem 2>/dev/null || echo "unknown")

  if [ "$key_perms" != "600" ] && [ "$key_perms" != "unknown" ]; then
    echo "WARNING: Private key permissions are $key_perms (recommended: 600)" >&2
  fi
else
  echo "! No TLS certificates found - running in HTTP mode only"
fi

# -----------------------------------------------------------------------------
# Real IP Configuration Generation (if enabled)
# -----------------------------------------------------------------------------

if [ -n "${REAL_IP_HEADER:-}" ] && [ -n "${TRUSTED_PROXIES:-}" ]; then
  echo "Generating real IP configuration..."

  cat >/etc/nginx/conf.d/realip.conf <<EOF
# Auto-generated real IP configuration
# DO NOT EDIT - Generated by docker-entrypoint.sh

set_real_ip_from ${TRUSTED_PROXIES};
real_ip_header ${REAL_IP_HEADER};
real_ip_recursive on;
EOF

  echo "[OK] Real IP configuration written to /etc/nginx/conf.d/realip.conf"
fi

# -----------------------------------------------------------------------------
# Conditional Configuration Block Generation
# -----------------------------------------------------------------------------

# Generate API proxy block if enabled
if [ "$ENABLE_API_PROXY" = "true" ]; then
  # Read API proxy template and substitute SERVER_API_URL
  if [ -f "/etc/nginx/templates/api-proxy.conf.template" ]; then
    ENABLE_API_PROXY_BLOCK=$(envsubst '${SERVER_API_URL}' \
      </etc/nginx/templates/api-proxy.conf.template)
    echo "[OK] API proxy configuration loaded from template"
  else
    echo "[ERROR]: API proxy template not found" >&2
    exit 1
  fi
else
  ENABLE_API_PROXY_BLOCK="    # API proxy disabled (ENABLE_API_PROXY=false)"
fi

# Generate TLS block if certificates present
if [ "$TLS_ENABLED" = "true" ]; then
  # Read TLS template and substitute all required variables
  # Note: ENABLE_API_PROXY_BLOCK is inserted into the TLS config
  if [ -f "/etc/nginx/templates/tls.conf.template" ]; then
    export ENABLE_API_PROXY_BLOCK
    TLS_BLOCK=$(envsubst '${NGINX_PORT} ${CACHE_STATIC_EXPIRES} ${CACHE_HTML_EXPIRES} ${ENABLE_API_PROXY_BLOCK}' \
      </etc/nginx/templates/tls.conf.template)
    echo "[OK] TLS/HTTPS configuration loaded from template"
  else
    echo "[ERROR]: TLS template not found" >&2
    exit 1
  fi
else
  TLS_BLOCK=""
fi

# -----------------------------------------------------------------------------
# Security Headers Configuration
# -----------------------------------------------------------------------------

# Copy security headers configuration file (static, no template processing needed)
if [ -f "/etc/nginx/templates/security-headers.conf" ]; then
  cp /etc/nginx/templates/security-headers.conf /etc/nginx/security-headers.conf
  echo "[OK] Security headers configuration copied"
else
  echo "[ERROR]: Security headers template not found" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Template Processing
# -----------------------------------------------------------------------------

echo "Processing configuration templates..."

# Export variables for envsubst
export NGINX_PORT="${NGINX_PORT:-8080}"
export SERVER_API_URL="${SERVER_API_URL:-http://chasqui-server:3003}"
export ENABLE_API_PROXY
export ENABLE_API_PROXY_BLOCK
export CACHE_STATIC_EXPIRES="${CACHE_STATIC_EXPIRES:-30d}"
export CACHE_HTML_EXPIRES="${CACHE_HTML_EXPIRES:-0}"
export NGINX_LOG_LEVEL="${NGINX_LOG_LEVEL:-warn}"
export TLS_ENABLED
export TLS_BLOCK

# Process the main nginx.conf template (contains ${NGINX_LOG_LEVEL})
if [ -f "/etc/nginx/templates/nginx.conf.template" ]; then
  envsubst '${NGINX_LOG_LEVEL}' \
    </etc/nginx/templates/nginx.conf.template \
    >/etc/nginx/nginx.conf
  echo "[OK] Main configuration generated"
else
  echo "[ERROR]: Template file not found: /etc/nginx/templates/nginx.conf.template" >&2
  exit 1
fi

# Process the server block template
if [ -f "/etc/nginx/templates/default.conf.template" ]; then
  envsubst '${NGINX_PORT} ${SERVER_API_URL} ${ENABLE_API_PROXY} ${ENABLE_API_PROXY_BLOCK} ${CACHE_STATIC_EXPIRES} ${CACHE_HTML_EXPIRES} ${NGINX_LOG_LEVEL} ${TLS_ENABLED} ${TLS_BLOCK}' \
    </etc/nginx/templates/default.conf.template \
    >/etc/nginx/conf.d/default.conf
  echo "[OK] Server block configuration generated"
else
  echo "[ERROR]: Template file not found: /etc/nginx/templates/default.conf.template" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Configuration Validation
# -----------------------------------------------------------------------------

echo "Validating nginx configuration..."
if ! nginx -t 2>&1; then
  echo "ERROR: nginx configuration validation failed" >&2
  echo "Check the error messages above for details." >&2
  exit 1
fi
echo "[OK] nginx configuration is valid"

# -----------------------------------------------------------------------------
# Daemon Execution
# -----------------------------------------------------------------------------

echo ""
echo "Starting nginx..."
echo "Port: ${NGINX_PORT}"
echo "API Proxy: ${ENABLE_API_PROXY}"
echo "TLS: ${TLS_ENABLED}"
echo ""

# Use exec to replace shell process, allowing signals to reach nginx directly
exec nginx -g "daemon off;"
