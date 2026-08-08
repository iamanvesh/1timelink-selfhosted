#!/bin/bash
# ==============================================================================
# 1TimeLink PostgreSQL DB Restore Script
# Downloads the specified database dump from S3 and restores it locally on the host.
# Usage: ./db_restore.sh <backup_filename.sql.gz>
# ==============================================================================

set -e

if [ -z "$1" ]; then
  echo "Usage: ./db_restore.sh <backup_filename.sql.gz>"
  echo "Example: ./db_restore.sh backup_2026-06-03_12-00-00.sql.gz"
  exit 1
fi

BACKUP_NAME="$1"

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
DOWNLOAD_DIR="/tmp/db_restore"
DOWNLOAD_FILE="${DOWNLOAD_DIR}/${BACKUP_NAME}"

if [ -z "$DB_PASS" ] || [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT" ]; then
  echo "Error: Database credentials or S3 configs are missing in .env."
  exit 1
fi

# Ensure download directory exists
mkdir -p "$DOWNLOAD_DIR"

echo "Downloading ${BACKUP_NAME} from S3 bucket: ${S3_BUCKET_NAME}..."
AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}" \
aws s3 cp "s3://${S3_BUCKET_NAME}/db-backups/${BACKUP_NAME}" "$DOWNLOAD_FILE" \
  --endpoint-url "${S3_ENDPOINT}"

echo "Download complete. Restoring database..."

# Decompress and pipe directly into host database
# Using clean restore logic, replaces existing schemas.
gunzip -c "$DOWNLOAD_FILE" | PGPASSWORD="${DB_PASS}" psql -h "localhost" -U "${DB_USER}" -d "${DB_NAME}"

# Cleanup temporary download
rm -f "$DOWNLOAD_FILE"

echo "Database restore completed successfully!"
