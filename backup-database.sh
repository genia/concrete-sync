#!/bin/bash

# Simple database backup script
# Usage: ./backup-database.sh
# Backs up the database using credentials from .deployment-config

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Load configuration from .deployment-config
CONFIG_FILE="${SCRIPT_DIR}/.deployment-config"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "Error: .deployment-config file not found"
    echo "Please create .deployment-config with database credentials"
    exit 1
fi

source "${CONFIG_FILE}"

# Check required variables
if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
    echo "Error: Database credentials not found in .deployment-config"
    echo "Required: DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD"
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo "Backing up database..."
echo "  Host: ${DB_HOSTNAME}"
echo "  Database: ${DB_DATABASE}"
echo "  User: ${DB_USERNAME}"

BACKUP_FILE="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"

# Build mysqldump command with table exclusions if specified
MYSQLDUMP_CMD="mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF"

# Add --ignore-table for each excluded table (if DB_EXCLUDE_TABLES is set)
if [ -n "${DB_EXCLUDE_TABLES:-}" ]; then
    echo "  Excluding tables: ${DB_EXCLUDE_TABLES}"
    for table in $DB_EXCLUDE_TABLES; do
        MYSQLDUMP_CMD="${MYSQLDUMP_CMD} --ignore-table=${DB_DATABASE}.${table}"
    done
fi

MYSQLDUMP_CMD="${MYSQLDUMP_CMD} -h\"${DB_HOSTNAME}\" -u\"${DB_USERNAME}\" -p\"${DB_PASSWORD}\" \"${DB_DATABASE}\""

eval "${MYSQLDUMP_CMD}" | gzip > "${BACKUP_FILE}"

echo "✓ Database backed up to: ${BACKUP_FILE}"

