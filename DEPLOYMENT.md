# MercurJS self-hosted deployment

This package prepares a **vanilla, single-server MercurJS/Medusa installation** on Ubuntu 22.04. It installs Node.js 20, Bun, PostgreSQL 14, Redis, Caddy, and PM2; checks out this repository; builds the API; runs migrations; configures an HTTP reverse proxy; and starts the API with PM2.

The package does **not** install Clerk, PayChangu, Stripe, custom domains, HTTPS certificates, object storage, email providers, or other third-party integrations. It does not create an Oracle Cloud VM or configure a cloud provider firewall.

> **Important:** This is a practical starter deployment for one VM. Current Mercur/Medusa guidance recommends separate server and worker processes for production. This package uses `MEDUSA_WORKER_MODE=shared` and one API process because the requested setup is vanilla and single-server. Review the split server/worker topology before using it for a high-volume or business-critical marketplace.

## Files

| File | Purpose |
| --- | --- |
| `deploy/install.sh` | Installs dependencies, provisions local PostgreSQL and Redis, builds the API, runs migrations, installs Caddy, and starts PM2. |
| `deploy/Caddyfile` | Proxies HTTP port 80 to `127.0.0.1:9000`. |
| `.env.example` | Documents the API environment variables without containing real credentials. |
| `DEPLOYMENT.md` | This runbook. |

## Prerequisites

Use a new Ubuntu 22.04 server with root or passwordless `sudo` access. The server must have enough memory for the MercurJS/Medusa API and its build. Point the repository URL at a fork or repository that the server can clone. The default in `install.sh` is:

```text
https://github.com/mw3407-coder/anchor-commerce-core.git
```

Before running the installer, make sure the server can reach GitHub over HTTPS and that inbound HTTP traffic on TCP port 80 is allowed by the cloud provider and the operating-system firewall. This package intentionally uses HTTP on port 80 only; it does not configure HTTPS or a custom domain.

## Install

Clone or upload this repository to the server, then run the installer from the repository root:

```bash
cd /path/to/anchor-commerce-core
sudo bash deploy/install.sh
```

The script is designed to be repeatable. It defaults to the non-root user that invoked `sudo`, the directory `~/anchor-commerce-core`, the `main` branch, database `medusa`, and database role `medusa`.

You can override those defaults on the command line:

```bash
sudo APP_USER=ubuntu \
  APP_DIR=/home/ubuntu/anchor-commerce-core \
  APP_REPO_URL=https://github.com/YOUR_ACCOUNT/YOUR_REPO.git \
  APP_BRANCH=main \
  PUBLIC_ORIGIN=http://YOUR_SERVER_IP \
  bash deploy/install.sh
```

The installer generates a PostgreSQL password, `JWT_SECRET`, and `COOKIE_SECRET` when those values are not provided. It writes them to `apps/api/.env` on the server with mode `600`, and copies that local environment into the generated `.medusa/server` directory. The file is ignored by Git and must never be committed.

## What the installer does

The installer performs these operations in order:

1. It verifies that the host is Ubuntu 22.04 and installs the required operating-system packages.
2. It installs Node.js 20, Bun for the application user, Caddy, and PM2.
3. It enables PostgreSQL and Redis and creates the local `medusa` database and role.
4. It checks out the requested repository branch.
5. It writes a local production environment file from generated values and the server’s public origin.
6. It installs the Bun workspace dependencies using the committed lockfile.
7. It builds the API using the Mercur/Medusa CLI into `apps/api/.medusa/server`.
8. It runs `medusa db:migrate` against the configured PostgreSQL database.
9. It validates and installs `deploy/Caddyfile`.
10. It starts the compiled API as the `anchor-backend` PM2 process and saves the PM2 process list.
11. It waits for the API health endpoint and fails if the endpoint does not respond successfully.

The installer does not run the Vendor panel or a separate worker instance. It also does not seed catalog data or create an admin user.

## Verify the deployment

After the installer completes, replace `SERVER_IP` with the server’s public IP and run:

```bash
curl -i http://SERVER_IP/health
```

A healthy API should return a successful response. Check the local process and recent logs if it does not:

```bash
sudo -u ubuntu pm2 status
sudo -u ubuntu pm2 logs anchor-backend --lines 100
sudo systemctl status caddy --no-pager
sudo journalctl -u caddy -n 100 --no-pager
```

The expected endpoints are:

```text
http://SERVER_IP/health
http://SERVER_IP/dashboard
http://SERVER_IP/seller
```

The availability of the Admin and Vendor panels depends on the exact repository configuration and the current MercurJS release. The API health endpoint is the primary installation check.

## Updating the application

From the checked-out repository on the server, fetch the desired branch and rebuild the API:

```bash
cd /home/ubuntu/anchor-commerce-core
git fetch --prune origin main
git checkout main
git reset --hard origin/main
sudo bash deploy/install.sh
```

The installer rewrites the local API environment file only from its current command-line values and generated defaults. Back up and review `apps/api/.env` before an update if you have customized it.

## Security notes

Use a restricted SSH source range in the cloud firewall and do not expose PostgreSQL, Redis, or port 9000 publicly. Caddy is the only public application listener in this package. Replace the generated secrets only through a secure server-side process, and do not put real credentials in `.env.example`, Git history, issue comments, or chat messages.

The included Caddy configuration listens on HTTP only. Do not treat it as a production HTTPS configuration. Add a domain and a deliberate certificate strategy before collecting credentials, personal data, or payment information.

## Out of scope by design

This package intentionally leaves out Clerk, PayChangu, custom domains, HTTPS, payment credentials, email delivery, object storage, monitoring, backups, multi-instance worker deployment, and cloud-provider provisioning. Those are separate decisions and should be configured only after the vanilla API is healthy.

## Source guidance

The commands in this package follow the current MercurJS and Medusa deployment model: build the API into `.medusa/server`, install or run the compiled application from that output, and run database migrations before startup. Consult the upstream documentation before adapting this starter package to a multi-instance production deployment.
