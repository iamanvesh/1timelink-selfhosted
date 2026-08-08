#!/bin/bash
# ==============================================================================
# 1TimeLink PostgreSQL DB Backup Script
# Dumps the local host database and uploads it to S3/R2 cloud storage.
# ==============================================================================

set -e

# Load environment variables from .env located in the same directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# Configuration
DB_USER=${SPRING_DATASOURCE_USERNAME:-"onetimelink_user"}
DB_NAME=${POSTGRES_DB:-"onetimelink"}
DB_PASS=${SPRING_DATASOURCE_PASSWORD}
BACKUP_DIR="/home/onetimelink/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.sql.gz"

if [ -z "$DB_PASS" ] || [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT" ]; then
  echo "Error: Database credentials or S3 configs are missing in .env."
  exit 1
fi

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

echo "Starting database backup at ${TIMESTAMP}..."

# Dump the host database directly using local psql connection
PGPASSWORD="${DB_PASS}" pg_dump -h "localhost" -U "${DB_USER}" "${DB_NAME}" | gzip > "$BACKUP_FILE"

echo "Backup created locally: $BACKUP_FILE"

# Upload to custom S3/R2 bucket using client-configured credentials
echo "Uploading to S3 bucket: $S3_BUCKET_NAME..."
AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}" \
aws s3 cp "$BACKUP_FILE" "s3://${S3_BUCKET_NAME}/db-backups/backup_${TIMESTAMP}.sql.gz" \
  --endpoint-url "${S3_ENDPOINT}"

# Cleanup local backup after upload
rm -f "$BACKUP_FILE"

echo "Backup and upload completed successfully!"
