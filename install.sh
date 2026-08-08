#!/bin/bash
# ==============================================================================
# 1TimeLink Self-Hosted VPS Installer
# Target OS: Ubuntu 22.04 LTS / Debian 12 (Must run as root/sudo)
# ==============================================================================

set -e

# Configuration
APP_USER="onetimelink"
INSTALL_DIR="/home/$APP_USER/app"

# Helper for colorized outputs
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_warn() { echo -e "\e[33m[WARNING]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo_error "Please run this script as root or using sudo."
fi

# Ensure .env exists in current directory before installation
if [ ! -f "./.env" ]; then
  echo_error "Configuration file '.env' not found in current directory.\nPlease copy '.env.example' to '.env' and fill in all variables before running this script."
fi

echo_info "Loading and validating configurations from .env..."

# Function to read variables safely from .env without sourcing (to prevent code execution)
get_env_var() {
  grep -E "^$1=" "./.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}

# Load and validate required parameters (excluding optional OTEL configurations)
SPRING_DATASOURCE_URL=$(get_env_var "SPRING_DATASOURCE_URL")
SPRING_DATASOURCE_USERNAME=$(get_env_var "SPRING_DATASOURCE_USERNAME")
SPRING_DATASOURCE_PASSWORD=$(get_env_var "SPRING_DATASOURCE_PASSWORD")
DB_ENCRYPTION_KEY=$(get_env_var "DB_ENCRYPTION_KEY")
APP_BASE_URL=$(get_env_var "APP_BASE_URL")
LICENSE_KEY=$(get_env_var "LICENSE_KEY")
SLACK_CLIENT_ID=$(get_env_var "SLACK_CLIENT_ID")
SLACK_CLIENT_SECRET=$(get_env_var "SLACK_CLIENT_SECRET")
SLACK_SIGNING_SECRET=$(get_env_var "SLACK_SIGNING_SECRET")
SLACK_PROXY_SECRET=$(get_env_var "SLACK_PROXY_SECRET")
S3_ACCESS_KEY_ID=$(get_env_var "S3_ACCESS_KEY_ID")
S3_SECRET_ACCESS_KEY=$(get_env_var "S3_SECRET_ACCESS_KEY")
S3_ENDPOINT=$(get_env_var "S3_ENDPOINT")
S3_BUCKET_NAME=$(get_env_var "S3_BUCKET_NAME")

# Database setup helper variables
POSTGRES_DB=$(get_env_var "POSTGRES_DB")
POSTGRES_USER=$(get_env_var "POSTGRES_USER")
POSTGRES_PASSWORD=$(get_env_var "POSTGRES_PASSWORD")

# Check if any required variables are missing or blank
REQUIRED_VARS=(
  "SPRING_DATASOURCE_URL"
  "DB_ENCRYPTION_KEY"
  "APP_BASE_URL"
  "LICENSE_KEY"
  "SLACK_CLIENT_ID"
  "SLACK_CLIENT_SECRET"
  "SLACK_SIGNING_SECRET"
  "SLACK_PROXY_SECRET"
  "S3_ACCESS_KEY_ID"
  "S3_SECRET_ACCESS_KEY"
  "S3_ENDPOINT"
  "S3_BUCKET_NAME"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
  val=$(get_env_var "$var")
  if [ -z "$val" ]; then
    MISSING_VARS+=("$var")
  fi
done

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
  echo_error "The following required configuration variables are missing or empty in .env:\n${MISSING_VARS[*]}"
fi

# Resolve DB username, password and database name
DB_USER=${SPRING_DATASOURCE_USERNAME:-$POSTGRES_USER}
DB_PASS=${SPRING_DATASOURCE_PASSWORD:-$POSTGRES_PASSWORD}
DB_NAME=${POSTGRES_DB:-"onetimelink"}

if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  echo_error "Database credentials (SPRING_DATASOURCE_USERNAME / POSTGRES_USER and SPRING_DATASOURCE_PASSWORD / POSTGRES_PASSWORD) must be set in .env."
fi

# Parse domain from APP_BASE_URL for Caddy SSL certificate registration
APP_DOMAIN=$(echo "$APP_BASE_URL" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:[0-9]*$||')
if [ -z "$APP_DOMAIN" ]; then
  echo_error "Failed to parse domain name from APP_BASE_URL: '$APP_BASE_URL'"
fi

# Prompt for GitHub registry credentials
echo_info "Enter your GitHub Registry credentials (required to pull private container images):"
read -p "GitHub Username: " GH_USER
read -sp "GitHub Personal Access Token (PAT): " GH_PAT
echo ""

if [ -z "$GH_USER" ] || [ -z "$GH_PAT" ]; then
  echo_error "GitHub credentials cannot be empty."
fi

# 2. Update System Packages
echo_info "Updating package lists..."
apt-get update -y

# 3. Install Core Tools
echo_info "Installing core system utilities..."
apt-get install -y curl gnupg lsb-release openssl git

# 4. Install PostgreSQL on Host
echo_info "Installing PostgreSQL database server..."
apt-get install -y postgresql postgresql-contrib

# Start and enable PostgreSQL
systemctl start postgresql
systemctl enable postgresql

# Configure PostgreSQL to accept connections from Docker subnet
echo_info "Configuring PostgreSQL access control..."
PG_VERSION=$(psql -V | awk '{print $3}' | cut -d. -f1)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

# Listen on all interfaces so containers can connect
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" "$PG_CONF"

# Allow connections from Docker network range
if ! grep -q "172.16.0.0/12" "$PG_HBA"; then
  echo "host    all             all             172.16.0.0/12           md5" >> "$PG_HBA"
fi

# Get host gateway IP on the default docker bridge interface
DOCKER_GW_IP="172.17.0.1"

# Idempotently create Postgres User and DB using .env values
echo_info "Setting up PostgreSQL database '$DB_NAME' and user '$DB_USER'..."

USER_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER';")
if [ "$USER_EXISTS" != "1" ]; then
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
else
  sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
fi

DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';")
if [ "$DB_EXISTS" != "1" ]; then
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
fi

# Restart PostgreSQL to apply changes
systemctl restart postgresql
echo_success "PostgreSQL configured successfully."

# 5. Install Docker Engine
echo_info "Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# Ensure Docker is active
systemctl start docker
systemctl enable docker
echo_success "Docker Engine installed successfully."

# 6. Initialize Docker Swarm (Single Node)
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  echo_info "Initializing Docker Swarm (single-node mode)..."
  docker swarm init --advertise-addr 127.0.0.1
  echo_success "Docker Swarm initialized."
else
  echo_info "Docker Swarm is already active."
fi

# 7. Create Dedicated Non-Root App User
if id "$APP_USER" &>/dev/null; then
  echo_info "User '$APP_USER' already exists."
else
  echo_info "Creating unprivileged system user '$APP_USER'..."
  useradd -m -s /bin/bash "$APP_USER"
fi

# Add user to docker group
usermod -aG docker "$APP_USER"
echo_success "User '$APP_USER' configured in 'docker' group."

# Authenticate docker to registry under the app user context
echo_info "Logging in to GitHub Container Registry (ghcr.io) as '$APP_USER'..."
if echo "$GH_PAT" | sudo -u "$APP_USER" docker login ghcr.io -u "$GH_USER" --password-stdin; then
  echo_success "GitHub Container Registry authentication succeeded."
else
  echo_error "GitHub Registry authentication failed. Please check your credentials."
fi

# 8. Setup Deployment Files & Permissions
echo_info "Setting up deployment directory..."
mkdir -p "$INSTALL_DIR"

# Copy config files directly from current directory
cp ./docker-compose.yml "$INSTALL_DIR/"
cp ./Caddyfile "$INSTALL_DIR/"
cp ./Dockerfile.caddy "$INSTALL_DIR/"
cp ./slack-manifest.yaml "$INSTALL_DIR/" 2>/dev/null || true
cp ./vps-administration.md "$INSTALL_DIR/" 2>/dev/null || true
cp ./update.sh "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/update.sh" 2>/dev/null || true

# If SPRING_DATASOURCE_URL points to localhost/127.0.0.1, update it to the docker gateway IP
if [[ "$SPRING_DATASOURCE_URL" == *"localhost"* ]] || [[ "$SPRING_DATASOURCE_URL" == *"127.0.0.1"* ]]; then
  echo_info "Adjusting SPRING_DATASOURCE_URL localhost reference to Docker Gateway IP ($DOCKER_GW_IP)..."
  SPRING_DATASOURCE_URL=$(echo "$SPRING_DATASOURCE_URL" | sed "s/localhost/$DOCKER_GW_IP/g" | sed "s/127.0.0.1/$DOCKER_GW_IP/g")
fi

# Copy the configured .env to the installation directory
cp ./.env "$INSTALL_DIR/.env"

# Inject resolved gateway URL and parsed DOMAIN variable to the final runtime config
sed -i "s|^SPRING_DATASOURCE_URL=.*|SPRING_DATASOURCE_URL=$SPRING_DATASOURCE_URL|g" "$INSTALL_DIR/.env"

# Append or replace the DOMAIN variable
if grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
  sed -i "s|^DOMAIN=.*|DOMAIN=$APP_DOMAIN|g" "$INSTALL_DIR/.env"
else
  echo "DOMAIN=$APP_DOMAIN" >> "$INSTALL_DIR/.env"
fi

# Ensure all files in the directory are owned by the unprivileged user
chown -R "$APP_USER:$APP_USER" "/home/$APP_USER"
chmod 600 "$INSTALL_DIR/.env"

echo_success "Deployment files configured in $INSTALL_DIR"
echo "------------------------------------------------------------------"
echo -e "\e[32mBootstrap installation and registry authentication complete!\e[0m"
echo "------------------------------------------------------------------"
echo "Next Steps for the administrator:"
echo "1. Log in as the unprivileged user:"
echo "   su - $APP_USER"
echo "2. Build and deploy the application stack:"
echo "   cd $INSTALL_DIR"
echo "   docker compose build"
echo "   docker stack deploy -c docker-compose.yml 1timelink"
echo "------------------------------------------------------------------"
