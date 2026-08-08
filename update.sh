#!/bin/bash
# ==============================================================================
# 1TimeLink Self-Hosted Update Script
# Run this script to pull the latest images and apply rolling updates.
# ==============================================================================

set -e

# Change directory to script location
cd "$(dirname "$0")"

# Ensure docker is running and reachable
if ! command -v docker &> /dev/null; then
  echo "Error: Docker command not found. Cannot perform update."
  exit 1
fi

echo "=================================================================="
echo "  1TIMELINK SYSTEM UPDATE"
echo "=================================================================="

echo "[1/3] Pulling latest container images from registry..."
docker compose pull

echo "[2/3] Rebuilding local Caddy ingress configuration..."
docker compose build

echo "[3/3] Deploying rolling updates to Docker Swarm..."
docker stack deploy -c docker-compose.yml 1timelink

echo "------------------------------------------------------------------"
echo "Update completed successfully!"
echo "------------------------------------------------------------------"
