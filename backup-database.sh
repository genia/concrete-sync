#!/bin/bash

# Simple database backup script
# Usage: ./backup-database.sh [environment]
# Environment: dev (default) or prod

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ENV=${1:-dev}

mkdir -p "${BACKUP_DIR}"

if [ "$ENV" = "prod" ]; then
    echo "Backing up production database..."
    read -p "Enter production DB hostname: " DB_HOST
    read -p "Enter production DB name: " DB_NAME
    read -p "Enter production DB username: " DB_USER
    read -s -p "Enter production DB password: " DB_PASS
    echo
    
    BACKUP_FILE="${BACKUP_DIR}/prod_db_${TIMESTAMP}.sql.gz"
    mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" | gzip > "${BACKUP_FILE}"
else
    echo "Backing up development database..."
    
    if [ ! -f "${PROJECT_DIR}/.env" ]; then
        echo "Error: .env file not found"
        exit 1
    fi
    
    source "${PROJECT_DIR}/.env"
    BACKUP_FILE="${BACKUP_DIR}/dev_db_${TIMESTAMP}.sql.gz"
    mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${BACKUP_FILE}"
fi

echo "✓ Database backed up to: ${BACKUP_FILE}"

