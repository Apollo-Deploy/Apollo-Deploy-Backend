#!/usr/bin/env bash
# =============================================================================
# bootstrap-vps.sh — Prepares a fresh VPS for Apollo Deploy
#
# What it does:
#   1. Installs Docker Engine (if not already present)
#   2. Creates the /opt/apollo directory structure
#   3. Syncs nginx config from the local repo to the VPS
#   4. Creates a placeholder for the GeoIP database
#
# Usage:
#   bash infra/scripts/bootstrap-vps.sh user@1.2.3.4
#   bash infra/scripts/bootstrap-vps.sh -p 2222 deploy@my-vps.example.com
#
# After bootstrap:
#   1. Copy terraform.tfvars.example → terraform.tfvars in environments/vps/
#   2. Run: terraform -chdir=infra/terraform/environments/vps init
#   3. Run: terraform -chdir=infra/terraform/environments/vps apply
# =============================================================================

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
SSH_PORT=22
while getopts "p:" opt; do
  case $opt in
    p) SSH_PORT="$OPTARG" ;;
    *) echo "Usage: $0 [-p ssh_port] user@host" && exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 [-p ssh_port] user@host"
  exit 1
fi

REMOTE="$1"
SSH="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new"
SCP="scp -P ${SSH_PORT}"

# ── Repo root (relative to this script) ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "==> Bootstrapping VPS: ${REMOTE} (port ${SSH_PORT})"

# ── 1. Install Docker ─────────────────────────────────────────────────────────
echo "==> Installing Docker Engine..."
$SSH "$REMOTE" bash <<'ENDSSH'
set -euo pipefail
if command -v docker &>/dev/null; then
  echo "Docker already installed: $(docker --version)"
  exit 0
fi

# Detect OS and install Docker accordingly
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID}"
else
  echo "Cannot detect OS — install Docker manually then re-run." && exit 1
fi

case "${OS_ID}" in
  ubuntu|debian)
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/${OS_ID} $(. /etc/os-release && echo ${VERSION_CODENAME}) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ;;
  centos|rhel|fedora|almalinux|rocky)
    dnf install -y -q dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ;;
  *)
    echo "Unsupported OS: ${OS_ID}. Install Docker manually." && exit 1
    ;;
esac

systemctl enable --now docker
echo "Docker installed: $(docker --version)"
ENDSSH

# ── 2. Create directory structure ─────────────────────────────────────────────
echo "==> Creating /opt/apollo directory structure..."
$SSH "$REMOTE" bash <<'ENDSSH'
set -euo pipefail
mkdir -p \
  /opt/apollo/platform/nginx \
  /opt/apollo/signal/geoip

chmod 755 /opt/apollo
echo "Directory structure ready."
ENDSSH

# ── 3. Sync nginx config ──────────────────────────────────────────────────────
echo "==> Syncing nginx config to VPS..."
NGINX_SRC="${REPO_ROOT}/apollo-platform-api/scripts/nginx/"
if [ -d "${NGINX_SRC}" ]; then
  rsync -az --delete -e "${SSH/-p ${SSH_PORT}/-e ssh -p ${SSH_PORT}}" \
    "${NGINX_SRC}" "${REMOTE}:/opt/apollo/platform/nginx/"
  echo "nginx config synced."
else
  echo "WARNING: nginx config directory not found at ${NGINX_SRC}"
  echo "         Sync manually: rsync -az apollo-platform-api/scripts/nginx/ ${REMOTE}:/opt/apollo/platform/nginx/"
fi

# ── 4. GeoIP placeholder reminder ────────────────────────────────────────────
echo ""
echo "==> Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Upload the GeoIP database:"
echo "       scp -P ${SSH_PORT} apollo-signal-api/geoip/dbip-city-lite.mmdb \\"
echo "           ${REMOTE}:/opt/apollo/signal/geoip/"
echo ""
echo "  2. Configure terraform:"
echo "       cd infra/terraform/environments/vps"
echo "       cp terraform.tfvars.example terraform.tfvars"
echo "       # Edit terraform.tfvars with your values"
echo ""
echo "  3. Deploy:"
echo "       terraform init"
echo "       terraform plan"
echo "       terraform apply"
echo ""
echo "  4. Run database migrations (first deploy only):"
echo "       ssh -p ${SSH_PORT} ${REMOTE} \\"
echo "         'docker exec apollo-platform-postgres psql -U postgres -c \"CREATE DATABASE apollo_deploy_signal;\"'"
echo "       # Then run each service's migration scripts"
echo ""
echo "  5. Register OAuth clients (after platform is healthy):"
echo "       ssh -p ${SSH_PORT} ${REMOTE} \\"
echo "         'docker exec apollo-platform bun run oauth:register-clients'"
echo "       # Add returned IDs to terraform.tfvars and re-apply"
