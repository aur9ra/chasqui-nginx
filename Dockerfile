# Chasqui NGINX Container
# =============================================================================
# Single-stage build for minimal size and non-root execution
# =============================================================================

FROM nginx:1.27-alpine

# Install envsubst for template processing
# The gettext package adds ~1MB; multi-stage complexity is unnecessary
RUN apk add --no-cache gettext

# Create required directories with nginx user ownership
# This ensures the non-root user can write to necessary locations
RUN mkdir -p /var/cache/nginx \
             /var/log/nginx \
             /etc/nginx/conf.d \
             /etc/nginx/templates \
             /etc/nginx/ssl \
    && chown -R nginx:nginx /var/cache/nginx \
                            /var/log/nginx \
                            /etc/nginx

# Copy configuration files
# Templates are processed by entrypoint to substitute environment variables
COPY templates/ /etc/nginx/templates/
COPY docker-entrypoint.sh /

# Make entrypoint executable and set ownership
RUN chmod +x /docker-entrypoint.sh \
    && chown nginx:nginx /docker-entrypoint.sh

# Switch to non-root user
# UID 101 is the nginx user in Alpine Linux
USER nginx

# Expose default HTTP port
# Note: The actual port is configured via NGINX_PORT env var
EXPOSE 8080

# Healthcheck
# Verifies the /health endpoint responds correctly
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${NGINX_PORT:-8080}/health || exit 1

# Entry point
# The entrypoint script validates environment and generates configuration
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
