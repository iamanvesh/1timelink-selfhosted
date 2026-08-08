#!/bin/bash

set -e

cd "$(dirname "$0")"

if ! command -v docker &> /dev/null; then
    echo "Error: Docker command not found. Cannot perform update."
    exit 1
fi

echo "=================================================================="
echo "  1TIMELINK SYSTEM UPDATE"
echo "=================================================================="

echo "[1/3] Pulling latest application images from registry..."
docker compose pull frontend backend slack-proxy

echo "[2/3] Building local Caddy ingress image..."
docker compose build ingress

echo "[3/3] Deploying rolling updates to Docker Swarm..."
docker stack deploy \
    --with-registry-auth \
    -c docker-compose.yml \
    1timelink

echo "------------------------------------------------------------------"
echo "Update completed successfully!"
echo "------------------------------------------------------------------"