#!/bin/bash
# ==============================================================================
# 1TimeLink Service Health Monitoring Script
# Checks frontend, backend API, and slack proxy endpoint health from inside caddy
# and triggers Slack webhook alerts on failures.
# ==============================================================================

# Load environment variables from .env located in the same directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [ -z "$SLACK_MONITOR_WEBHOOK" ]; then
  echo "Error: SLACK_MONITOR_WEBHOOK not set in .env."
  exit 1
fi

# Find the Docker Swarm network for the stack (usually ends in _public-net)
NETWORK_NAME=$(docker network ls --format '{{.Name}}' | grep '_public-net$' | head -n 1)

if [ -z "$NETWORK_NAME" ]; then
  echo "Could not find Docker network ending in _public-net"
  curl -X POST -H 'Content-type: application/json' --data '{"text":"🚨 *CRITICAL ALERT:* Docker overlay network not found. The Swarm stack might be offline!"}' "$SLACK_MONITOR_WEBHOOK"
  exit 1
fi

# Execute check inside Caddy container to bypass external host firewalls
CADDY_CONTAINER=$(docker ps -qf "name=1timelink_ingress" | head -n 1)

if [ -z "$CADDY_CONTAINER" ]; then
  echo "Caddy ingress container not found! Cannot execute internal health checks."
  exit 1
fi

# Capture the state of all Docker Swarm services
SWARM_STATUS=$(docker service ls --format "table {{.Name}}    {{.Replicas}}" | awk '{printf "%s\\n", $0}')

# 1. Check Frontend Nginx server (using relative networking inside swarm network)
echo "Checking http://frontend/ from inside Caddy container..."
FRONTEND_STATUS="DOWN"
if docker exec "$CADDY_CONTAINER" wget --spider -q http://frontend/; then
  FRONTEND_STATUS="UP"
fi

# 2. Check Slack Message Proxy endpoint
echo "Checking http://slack-proxy:3000/health from inside Caddy container..."
PROXY_JSON=$(docker exec "$CADDY_CONTAINER" wget -qO- http://slack-proxy:3000/health || echo "FAILED_TO_CONNECT")
PROXY_STATUS="DOWN"
if [ "$PROXY_JSON" != "FAILED_TO_CONNECT" ]; then
  PROXY_STATUS=$(echo "$PROXY_JSON" | grep -o '"status":"[^"]*"' | head -n 1 | cut -d '"' -f 4 || echo "DOWN")
fi

# 3. Check Spring Boot Actuator endpoint
echo "Checking http://backend:8080/actuator/health from inside Caddy container..."
BACKEND_JSON=$(docker exec "$CADDY_CONTAINER" wget -qO- http://backend:8080/actuator/health || echo "FAILED_TO_CONNECT")
BACKEND_STATUS="DOWN"
if [ "$BACKEND_JSON" != "FAILED_TO_CONNECT" ]; then
  BACKEND_STATUS=$(echo "$BACKEND_JSON" | grep -o '"status":"[^"]*"' | head -n 1 | cut -d '"' -f 4 || echo "DOWN")
fi

# Aggregate and alert on failures
if [ "$BACKEND_STATUS" != "UP" ] || [ "$FRONTEND_STATUS" != "UP" ] || [ "$PROXY_STATUS" != "UP" ]; then
  MESSAGE="WARNING: 1TimeLink Service Health Alert\\n\\n*Status Details:*\\n- *Frontend Nginx:* \`$FRONTEND_STATUS\`\\n- *Backend API:* \`$BACKEND_STATUS\`\\n- *Slack Proxy:* \`$PROXY_STATUS\`\\n\\n*Current Swarm Services:*\\n\`\`\`\\n${SWARM_STATUS}\`\`\`"
  curl -X POST -H 'Content-type: application/json' --data "{\"text\":\"$MESSAGE\"}" "$SLACK_MONITOR_WEBHOOK"
  echo "Alert sent: Frontend: $FRONTEND_STATUS, Backend: $BACKEND_STATUS, Proxy: $PROXY_STATUS"
  exit 1
else
  echo "All services are UP (Frontend: UP, Backend: UP, Slack Proxy: UP)."
fi
