# Chasqui NGINX

Chasqui is a lightweight, modular CMS and server. This repository contains the **NGINX** component, serving as the public-facing HTTP layer.

**Note:** This is the companion to the [Chasqui Server](https://github.com/aur9ra/chasqui-server) and [Chasqui Frontend](https://github.com/aur9ra/chasqui-frontend). NGINX serves static files from the frontend build, media assets from the server content directory, and optionally proxies API requests to the server.

**Note:** This project is very early in development.

### Installation

The deployment environment is designed to be "ready-to-run" and performs no building locally (Prerequisites: [Docker](https://www.docker.com/get-started/) (desktop is NOT required), [Docker Compose](https://docs.docker.com/compose/install/), and [Git](https://git-scm.com/downloads)).

**Note:** If you are unable to run the container in your specific environment, please open an issue in the repository!

1. **clone the repository**:

   ```bash
   git clone https://github.com/aur9ra/chasqui-nginx.git
   cd chasqui-nginx
   ```

2. **start NGINX**:

   ```bash
   export GITHUB_USER=aur9ra
   ./run-nginx.sh
   ```

   **Note:** The script will automatically create `.env` from `.env.example` if it doesn't exist. Edit `.env` to customize configuration.

### Common Docker Commands

- **view logs**: `docker compose -f docker-compose.deploy.yml logs -f`
- **check status**: `docker ps`
- **stop containers**: `docker compose -f docker-compose.deploy.yml stop`
- **shutdown & remove containers**: `docker compose -f docker-compose.deploy.yml down`
- **restart containers**: `docker compose -f docker-compose.deploy.yml restart`
- **update image**: `./run-nginx.sh` (Pulls/builds and restarts)

---

## Configuration

Configuration is managed through environment variables in the `.env` file. Key options include:

- **`NGINX_PORT`**: External HTTP port (default: 8080)
- **`ENABLE_API_PROXY`**: Enable `/api/*` proxying to the server (default: false)
- **`CONTENT_DIR`**: Path to server content directory

**Security Note:** `ENABLE_API_PROXY` defaults to `false` because the server API has no authentication. Only enable this if you need external API access and understand the security implications.

**TLS Note:** TLS/HTTPS setup is currently manual. Place certificates (`cert.pem` and `key.pem`) in the `ssl/` directory. See [BUILD.md](./BUILD.md) for detailed instructions.

## Local Development (Build Mode)

If you'd like to build the container yourself or customize the configuration, please refer to [BUILD.md](./BUILD.md).
