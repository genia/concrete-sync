#!/bin/bash

# Concrete CMS Deployment Script: Production to Dev
# This script pulls the latest from production to your development environment
# Use this to sync production data and files back to dev

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - EDIT THESE VALUES or use .deployment-config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Default values (can be overridden by .deployment-config or environment variables)
# SITE_PATH is the path to the Concrete CMS site root (where composer.json, public/, etc. are)
SITE_PATH=""  # REQUIRED: e.g., /var/www/html or /home/user/site
REMOTE_HOST=""  # e.g., user@example.com (only needed when running from dev)
REMOTE_PATH=""  # e.g., /var/www/html (path to site on remote server)
REMOTE_USER=""  # SSH user (combined with REMOTE_HOST if needed)
SYNC_UPLOADED_FILES="auto"  # Options: auto, ask, skip
FILES_GIT_REPO=""  # REQUIRED: e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files
SYNC_DATABASE="auto"  # Options: auto, skip
COMPOSER_DIR=""  # Directory containing composer.phar (e.g., /usr/local/bin or /opt/composer)
ENVIRONMENT=""  # REQUIRED: "prod" or "dev" - set to "prod" on production server, "dev" on development machine
# DB credentials will be loaded from .deployment-config
# On dev: uses local dev database credentials
# On production: uses production database credentials

# Load configuration from .deployment-config if it exists
CONFIG_FILE="${SCRIPT_DIR}/.deployment-config"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# Environment variables override config file values
SITE_PATH="${SITE_PATH:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PATH="${REMOTE_PATH:-}"
REMOTE_USER="${REMOTE_USER:-}"
SYNC_UPLOADED_FILES="${SYNC_UPLOADED_FILES:-auto}"
FILES_GIT_REPO="${FILES_GIT_REPO:-}"
FILES_GIT_BRANCH="${FILES_GIT_BRANCH:-main}"
SYNC_DATABASE="${SYNC_DATABASE:-auto}"
COMPOSER_DIR="${COMPOSER_DIR:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
DB_HOSTNAME="${DB_HOSTNAME:-}"
DB_DATABASE="${DB_DATABASE:-}"
DB_USERNAME="${DB_USERNAME:-}"
DB_PASSWORD="${DB_PASSWORD:-}"

# Set composer command
if [ -n "$COMPOSER_DIR" ]; then
    COMPOSER_CMD="php ${COMPOSER_DIR}/composer.phar"
else
    # Fallback to system composer if COMPOSER_DIR not set
    COMPOSER_CMD="composer"
fi

# Set PROJECT_DIR to SITE_PATH (the actual site location)
# For backwards compatibility, if SITE_PATH not set but PROJECT_DIR is, use that
if [ -z "$SITE_PATH" ] && [ -n "${PROJECT_DIR:-}" ]; then
    SITE_PATH="${PROJECT_DIR}"
fi

DB_BACKUP_DIR="${SITE_PATH}/backups"

# If REMOTE_USER is set but REMOTE_HOST doesn't include user, combine them
if [ -n "$REMOTE_USER" ] && [ -n "$REMOTE_HOST" ] && [[ ! "$REMOTE_HOST" == *"@"* ]]; then
    REMOTE_HOST="${REMOTE_USER}@${REMOTE_HOST}"
fi

# Functions
print_step() {
    echo -e "\n${GREEN}==> $1${NC}\n"
}

print_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

print_error() {
    echo -e "${RED}Error: $1${NC}"
}

# Check if running on production server directly
is_running_on_production() {
    # Check ENVIRONMENT variable from config file
    if [ -n "$ENVIRONMENT" ]; then
        if [ "$ENVIRONMENT" = "prod" ] || [ "$ENVIRONMENT" = "production" ]; then
            return 0
        elif [ "$ENVIRONMENT" = "dev" ] || [ "$ENVIRONMENT" = "development" ]; then
            return 1
        else
            print_error "ENVIRONMENT must be 'prod' or 'dev', got: ${ENVIRONMENT}"
            exit 1
        fi
    fi
    
    # Fallback: if ENVIRONMENT not set, check legacy RUNNING_ON_PRODUCTION variable
    if [ "${RUNNING_ON_PRODUCTION:-}" = "true" ]; then
        return 0
    fi
    
    # Default: assume dev if not explicitly set
    return 1
}

# Setup Git credential caching for this script session
setup_git_credentials() {
    # Only needed for HTTPS URLs (SSH uses keys, no prompts)
    if [[ "$FILES_GIT_REPO" != https://* ]]; then
        return 0  # SSH URL, no credential caching needed
    fi
    
    # Check if credential helper is already configured
    if git config --global credential.helper >/dev/null 2>&1; then
        echo "Git credential helper already configured"
        return 0
    fi
    
    # Configure Git to cache credentials for 1 hour (3600 seconds)
    # This avoids prompting for credentials multiple times during script execution
    # We use --global so it persists, but user can override if needed
    git config --global credential.helper 'cache --timeout=3600' 2>/dev/null || {
        print_warning "Could not configure Git credential caching"
        print_warning "You may be prompted for credentials multiple times"
        return 0
    }
    
    echo "Git credential caching enabled (1 hour timeout)"
    echo "You will be prompted for credentials once, then they will be cached for this session"
    echo ""
    echo "Tip: To avoid prompts entirely, use SSH URLs (git@github.com:user/repo.git)"
    echo "     or set up SSH keys for your GitHub account"
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # ENVIRONMENT is required
    if [ -z "$ENVIRONMENT" ]; then
        print_error "ENVIRONMENT must be set in .deployment-config"
        print_error "Set it to 'prod' on production server or 'dev' on development machine:"
        print_error "  ENVIRONMENT=prod  # or ENVIRONMENT=dev"
        exit 1
    fi
    
    # Validate ENVIRONMENT value
    if [ "$ENVIRONMENT" != "prod" ] && [ "$ENVIRONMENT" != "production" ] && [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "development" ]; then
        print_error "ENVIRONMENT must be 'prod' or 'dev', got: ${ENVIRONMENT}"
        exit 1
    fi
    
    # SITE_PATH is required
    if [ -z "$SITE_PATH" ]; then
        print_error "SITE_PATH must be set (path to Concrete CMS site root)"
        print_error "Set it in .deployment-config or as environment variable:"
        print_error "  SITE_PATH=/path/to/site"
        exit 1
    fi
    
    # Resolve and validate SITE_PATH
    if [ ! -d "$SITE_PATH" ]; then
        print_error "SITE_PATH does not exist: ${SITE_PATH}"
        exit 1
    fi
    
    # Check if it looks like a Concrete CMS site
    if [ ! -d "${SITE_PATH}/public" ] && [ ! -f "${SITE_PATH}/composer.json" ]; then
        print_warning "SITE_PATH doesn't appear to be a Concrete CMS site (no public/ or composer.json found)"
    fi
    
    PROJECT_DIR="${SITE_PATH}"  # Use SITE_PATH as PROJECT_DIR throughout
    
    command -v mysql >/dev/null 2>&1 || { print_error "mysql client is required but not installed"; exit 1; }
    
    # Determine if we're on production or dev based on ENVIRONMENT
    if is_running_on_production; then
        # Running on production server
        PROD_PATH="${SITE_PATH}"
        echo "✓ Running on production server (ENVIRONMENT=${ENVIRONMENT})"
        echo "  Site path: ${PROD_PATH}"
    elif [ -n "$REMOTE_HOST" ]; then
        # REMOTE_HOST is set, so we're running from dev
        if [ -z "$REMOTE_PATH" ]; then
            print_error "REMOTE_PATH must be set when REMOTE_HOST is set"
            print_error "Set in .deployment-config or as environment variable:"
            print_error "  REMOTE_PATH=/path/to/site"
            exit 1
        fi
        PROD_PATH="${REMOTE_PATH}"
        echo "✓ Running from dev machine"
        echo "  Local site path: ${SITE_PATH}"
        echo "  Production server: ${REMOTE_HOST}:${PROD_PATH}"
        
        # Check if using Git method for database
        USE_GIT_FOR_DB=false
        if [ -n "$FILES_GIT_REPO" ] && [ "$SYNC_DATABASE" = "auto" ]; then
            USE_GIT_FOR_DB=true
        fi
    else
        # REMOTE_HOST not set - check if we're on production
        if [ "${RUNNING_ON_PRODUCTION:-}" = "true" ] || [ "$REMOTE_PATH" = "$SITE_PATH" ]; then
            # Running on production server
            PROD_PATH="${SITE_PATH}"
            echo "✓ Running directly on production server"
            echo "  Site path: ${PROD_PATH}"
        else
            # REMOTE_HOST not set - using Git method
            USE_GIT_FOR_DB=false
            if [ -n "$FILES_GIT_REPO" ] && [ "$SYNC_DATABASE" = "auto" ]; then
                USE_GIT_FOR_DB=true
            fi
            
            if [ -z "$FILES_GIT_REPO" ]; then
                print_error "FILES_GIT_REPO must be set in .deployment-config"
                exit 1
            fi
            
            if [ "$USE_GIT_FOR_DB" = "true" ]; then
                echo "✓ Using Git method for both files and database (no REMOTE_HOST needed)"
            else
                echo "✓ Using Git method for files"
            fi
            PROD_PATH="${REMOTE_PATH:-${SITE_PATH}}"
        fi
    fi
    
    # Validate DB credentials are present (from .deployment-config)
    # On production: always need DB credentials
    # On dev: only need DB credentials if importing database (not when using Git method)
    if is_running_on_production; then
        # Always need DB credentials on production
        if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
            print_error "Database credentials not found in .deployment-config file"
            print_error "Required: DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD"
            print_error "Set them in ${CONFIG_FILE} or as environment variables"
            exit 1
        fi
    else
        # On dev: check if we need DB credentials
        USE_GIT_FOR_DB=false
        if [ "$UPLOADED_FILES_METHOD" = "git" ] && [ -n "$FILES_GIT_REPO" ] && [ "$SYNC_DATABASE" = "auto" ] && [ -z "$REMOTE_HOST" ]; then
            USE_GIT_FOR_DB=true
        fi
        
        if [ "$USE_GIT_FOR_DB" != "true" ] && [ "$SYNC_DATABASE" = "auto" ]; then
            # Need DB credentials for import (when not using Git method)
            if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
                print_error "Database credentials not found in .deployment-config file"
                print_error "Required: DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD"
                print_error "Set them in ${CONFIG_FILE} or as environment variables"
                exit 1
            fi
        elif [ "$USE_GIT_FOR_DB" = "true" ]; then
            # Using Git method - only need local dev DB credentials for import
            if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
                print_warning "Local database credentials not found - will be needed for import"
                print_warning "Set DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD in ${CONFIG_FILE}"
            fi
        fi
    fi
    
    echo "✓ All prerequisites met"
}

# Export database from production and push to Git
export_production_database_to_git() {
    print_step "Exporting database from production and pushing to Git..."
    
    if [ -z "$FILES_GIT_REPO" ]; then
        print_error "FILES_GIT_REPO must be configured for Git-based database sync"
        return 1
    fi
    
    # DB credentials are already loaded from .deployment-config
    echo "Exporting database..."
    echo "  Host: ${DB_HOSTNAME}"
    echo "  Database: ${DB_DATABASE}"
    echo "  User: ${DB_USERNAME}"
    
    # Create temp directory for Git operations
    DB_TEMP_DIR="${SCRIPT_DIR}/.db-git-temp"
    if [ -d "${DB_TEMP_DIR}" ]; then
        rm -rf "${DB_TEMP_DIR}"
    fi
    mkdir -p "${DB_TEMP_DIR}/database"
    
    cd "${DB_TEMP_DIR}"
    git init
    git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
    
    # Try to fetch existing branch
    git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
    if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}" 2>/dev/null; then
        git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
    else
        git checkout -b "${FILES_GIT_BRANCH}"
    fi
    
    # Export database to compressed file
    DB_FILE="database/production_db_${TIMESTAMP}.sql.gz"
    mysqldump --no-tablespaces -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${DB_FILE}"
    
    # Keep only the latest database backup (remove old ones)
    find database/ -name "production_db_*.sql.gz" -type f ! -name "production_db_${TIMESTAMP}.sql.gz" -delete
    
    # Also create/update a symlink or copy to "latest.sql.gz" for easy access
    ln -sf "production_db_${TIMESTAMP}.sql.gz" "database/latest.sql.gz" 2>/dev/null || \
        cp "${DB_FILE}" "database/latest.sql.gz"
    
    # Commit and push
    git add -A
    if ! git diff --staged --quiet; then
        git commit -m "Database backup from production $(date +%Y-%m-%d\ %H:%M:%S)" || true
        # Pull first to merge any remote changes, then push
        if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}"; then
            git pull origin "${FILES_GIT_BRANCH}" --no-edit 2>/dev/null || true
        fi
        git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
        echo "✓ Database exported and pushed to Git"
    else
        echo "No database changes to sync"
    fi
    
    echo "${DB_FILE}"
}

# Pull database from Git and return path to file
pull_database_from_git() {
    print_step "Pulling database from Git..."
    
    if [ -z "$FILES_GIT_REPO" ]; then
        print_error "FILES_GIT_REPO must be configured for Git-based database sync"
        return 1
    fi
    
    # Create temp directory for Git operations
    DB_TEMP_DIR="${SCRIPT_DIR}/.db-git-temp"
    if [ -d "${DB_TEMP_DIR}" ]; then
        rm -rf "${DB_TEMP_DIR}"
    fi
    mkdir -p "${DB_TEMP_DIR}"
    
    cd "${DB_TEMP_DIR}"
    git init
    git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
    
    git fetch origin "${FILES_GIT_BRANCH}"
    git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
    
    # Find the latest database file (use absolute path)
    if [ -f "database/latest.sql.gz" ]; then
        DB_FILE="${DB_TEMP_DIR}/database/latest.sql.gz"
        echo "✓ Database pulled from Git: ${DB_FILE}"
        echo "${DB_FILE}"
    elif [ -n "$(find database/ -name "production_db_*.sql.gz" -type f 2>/dev/null | head -1)" ]; then
        # Find the most recent database file
        DB_FILE_RELATIVE=$(find database/ -name "production_db_*.sql.gz" -type f | sort -r | head -1)
        DB_FILE="${DB_TEMP_DIR}/${DB_FILE_RELATIVE}"
        echo "✓ Database pulled from Git: ${DB_FILE}"
        echo "${DB_FILE}"
    else
        print_error "No database file found in Git repository"
        print_error "Make sure database has been exported and pushed to Git from production server"
        return 1
    fi
}

# Export database from production
export_production_database() {
    print_step "Exporting database from production..."
    
    mkdir -p "${DB_BACKUP_DIR}"
    DB_FILE="${DB_BACKUP_DIR}/production_db_${TIMESTAMP}.sql"
    
    # DB credentials are already loaded from .deployment-config in check_prerequisites
    # On production: these are production DB credentials from production .deployment-config
    # On dev: these would be dev DB credentials (but we need production, so use SSH with production config)
    
    echo "Exporting database..."
    
    if is_running_on_production; then
        # Running on production server - use DB credentials from production .deployment-config
        echo "  Host: ${DB_HOSTNAME}"
        echo "  Database: ${DB_DATABASE}"
        echo "  User: ${DB_USERNAME}"
        mysqldump --no-tablespaces -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${DB_FILE}.gz"
    elif [ -n "$REMOTE_HOST" ]; then
        # Running from dev - need to export from production via SSH
        # Production .deployment-config has production DB credentials
        # The deployment config is in the concrete-sync directory (same level as site, or find it)
        # Try common locations: ../concrete-sync or ~/concrete-sync
        echo "  Connecting to production server: ${REMOTE_HOST}"
        echo "  Will use production database credentials from production .deployment-config file"
        ssh "${REMOTE_HOST}" \
            "CONFIG_DIR=\$(find ~ -name '.deployment-config' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null) || CONFIG_DIR=\$(dirname ${REMOTE_PATH})/concrete-sync; \
             [ -f \"\${CONFIG_DIR}/.deployment-config\" ] && cd \"\${CONFIG_DIR}\" && source .deployment-config && \
             mysqldump --no-tablespaces -h\${DB_HOSTNAME} -u\${DB_USERNAME} -p\${DB_PASSWORD} \${DB_DATABASE}" \
            | gzip > "${DB_FILE}.gz"
    else
        # No REMOTE_HOST - cannot export from production without SSH access
        print_error "Cannot export database from production without REMOTE_HOST"
        print_error "Either set REMOTE_HOST in config or run this script on production server"
        return 1
    fi
    
    echo "✓ Database exported from production to ${DB_FILE}.gz"
    echo "${DB_FILE}.gz"
}

# Import database to local dev
import_database() {
    print_step "Importing database to local development..."
    
    if [ -z "$1" ]; then
        print_error "Database file path required"
        return 1
    fi
    
    DB_FILE="$1"
    
    if is_running_on_production; then
        print_warning "Running on production server - database import not applicable"
        print_warning "This script is for syncing FROM production TO dev"
        return 1
    fi
    
    # DB credentials already loaded from .deployment-config in check_prerequisites
    # These are the local dev database credentials
    
    print_warning "Importing database - this will REPLACE your local database!"
    echo "  Source: ${DB_FILE}"
    echo "  Target: ${DB_HOSTNAME}/${DB_DATABASE}"
    echo ""
    echo "This will drop all existing tables and import fresh data from production."
    
    # Drop existing database and recreate it for clean import
    echo "Preparing database (dropping existing if present)..."
    mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" \
        -e "DROP DATABASE IF EXISTS \`${DB_DATABASE}\`;" 2>/dev/null || true
    
    echo "Creating fresh database..."
    mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" \
        -e "CREATE DATABASE \`${DB_DATABASE}\`;" 2>/dev/null || {
        print_error "Failed to create database. It may already exist or you may not have permissions."
        return 1
    }
    
    # Import database
    echo "Importing database..."
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "${DB_FILE}" | mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}"
    else
        mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" < "${DB_FILE}"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✓ Database imported to local development"
    else
        print_error "Database import failed"
        return 1
    fi
    
    echo "✓ Database imported to local development"
}

# Pull uploaded files from production via Git
# This syncs all uploaded images, documents, and thumbnails from public/application/files/
pull_uploaded_files() {
    print_step "Pulling uploaded files (images, documents, thumbnails) from production..."
    
    # Check sync behavior setting
    if [ "$SYNC_UPLOADED_FILES" = "skip" ]; then
        echo "Skipping uploaded files sync (SYNC_UPLOADED_FILES=skip)"
        return 0
    fi
    
    if [ "$SYNC_UPLOADED_FILES" = "skip" ]; then
        echo "Skipping uploaded files sync (SYNC_UPLOADED_FILES=skip)"
        return 0
    elif [ "$SYNC_UPLOADED_FILES" = "ask" ]; then
        read -p "Do you want to sync uploaded files (images, documents) from production? (y/n) " -n 1 -r
        echo
        SYNC_YES="$REPLY"
    else
        # auto
        SYNC_YES="y"
    fi
    
    if [[ $SYNC_YES =~ ^[Yy]$ ]]; then
        if [ -z "$FILES_GIT_REPO" ]; then
            print_error "FILES_GIT_REPO must be configured in .deployment-config"
            return 1
        fi
        
        echo "Syncing uploaded files via Git..."
        
        # Push from production server to Git
        if is_running_on_production; then
            # Running on production server directly
            PROD_FILES_TEMP_DIR="${SCRIPT_DIR}/.files-git-temp"
            
            # Clean up and recreate temp directory to avoid conflicts
            if [ -d "${PROD_FILES_TEMP_DIR}" ]; then
                echo "Cleaning up existing temp directory..."
                rm -rf "${PROD_FILES_TEMP_DIR}"
            fi
            
            mkdir -p "${PROD_FILES_TEMP_DIR}"
            cd "${PROD_FILES_TEMP_DIR}"
            git init
            git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
            
            # Try to fetch existing branch
            git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
            if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}" 2>/dev/null; then
                git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
            else
                git checkout -b "${FILES_GIT_BRANCH}"
            fi
            
            # Copy files to temp directory from production site
            rm -rf *
            cp -r "${PROD_PATH}/public/application/files/"* . 2>/dev/null || true
            
            # Commit and push
            git add -A
            if ! git diff --staged --quiet; then
                git commit -m "Sync files from production $(date +%Y-%m-%d\ %H:%M:%S)" || true
                # Pull first to merge any remote changes, then push
                if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}"; then
                    git pull origin "${FILES_GIT_BRANCH}" --no-edit 2>/dev/null || true
                fi
                git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
            else
                # Even if no changes, pull to stay in sync
                if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}"; then
                    git pull origin "${FILES_GIT_BRANCH}" --no-edit 2>/dev/null || true
                fi
            fi
            echo "✓ Files pushed to Git"
        else
            # Running from dev - pull files from Git
            echo "Pulling files from Git to local development..."
            FILES_TEMP_DIR="${SCRIPT_DIR}/.files-git-temp"
            
            # Clean up and recreate to ensure clean state
            if [ -d "${FILES_TEMP_DIR}" ]; then
                echo "Cleaning up existing temp directory..."
                rm -rf "${FILES_TEMP_DIR}"
            fi
            
            mkdir -p "${FILES_TEMP_DIR}"
            cd "${FILES_TEMP_DIR}"
            git init
            git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
            
            git fetch origin "${FILES_GIT_BRANCH}"
            git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
            
            # Copy to local files directory
            mkdir -p "${PROJECT_DIR}/public/application/files"
            cp -r "${FILES_TEMP_DIR}"/* "${PROJECT_DIR}/public/application/files/" 2>/dev/null || true
            
            echo "✓ Uploaded files synced via Git (images, documents, thumbnails)"
        fi
    else
        echo "Skipped uploaded files sync"
        print_warning "Uploaded images and files were NOT synced. You may need to sync them manually."
    fi
}

# Pull config files from production via Git
# This syncs Concrete CMS configuration files (config/, themes/, blocks/, packages/, etc.)
pull_config_files() {
    print_step "Pulling config files from production via Git..."
    
    if [ -z "$FILES_GIT_REPO" ]; then
        echo "FILES_GIT_REPO not set - skipping config file sync via Git"
        return 0
    fi
    
    if is_running_on_production; then
        # Running on production - push config files to Git
        echo "Pushing config files from production to Git..."
        
        CONFIG_TEMP_DIR="${SCRIPT_DIR}/.config-git-temp"
        
        # Clean up and recreate temp directory
        if [ -d "${CONFIG_TEMP_DIR}" ]; then
            rm -rf "${CONFIG_TEMP_DIR}"
        fi
        
        mkdir -p "${CONFIG_TEMP_DIR}/config"
        cd "${CONFIG_TEMP_DIR}"
        git init
        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
        
        # Try to fetch existing branch
        git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
        if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}" 2>/dev/null; then
            git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
        else
            git checkout -b "${FILES_GIT_BRANCH}"
        fi
        
        # Copy config files from production site
        # Sync key Concrete CMS directories
        if [ -d "${PROD_PATH}/public/application/config" ]; then
            cp -r "${PROD_PATH}/public/application/config"/* "${CONFIG_TEMP_DIR}/config/" 2>/dev/null || true
        fi
        if [ -d "${PROD_PATH}/public/application/themes" ]; then
            cp -r "${PROD_PATH}/public/application/themes" "${CONFIG_TEMP_DIR}/" 2>/dev/null || true
        fi
        if [ -d "${PROD_PATH}/public/application/blocks" ]; then
            cp -r "${PROD_PATH}/public/application/blocks" "${CONFIG_TEMP_DIR}/" 2>/dev/null || true
        fi
        if [ -d "${PROD_PATH}/public/application/packages" ]; then
            cp -r "${PROD_PATH}/public/application/packages" "${CONFIG_TEMP_DIR}/" 2>/dev/null || true
        fi
        
        # Commit and push
        git add -A
        if ! git diff --staged --quiet; then
            git commit -m "Sync config files from production $(date +%Y-%m-%d\ %H:%M:%S)" || true
            if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}"; then
                git pull origin "${FILES_GIT_BRANCH}" --no-edit 2>/dev/null || true
            fi
            git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
            echo "✓ Config files pushed to Git"
        else
            echo "No config file changes to sync"
        fi
    else
        # Running from dev - pull config files from Git
        echo "Pulling config files from Git to local development..."
        
        CONFIG_TEMP_DIR="${SCRIPT_DIR}/.config-git-temp"
        
        # Clean up and recreate
        if [ -d "${CONFIG_TEMP_DIR}" ]; then
            rm -rf "${CONFIG_TEMP_DIR}"
        fi
        
        mkdir -p "${CONFIG_TEMP_DIR}"
        cd "${CONFIG_TEMP_DIR}"
        git init
        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
        
        git fetch origin "${FILES_GIT_BRANCH}"
        git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
        
        # Copy config files to local site
        if [ -d "${CONFIG_TEMP_DIR}/config" ]; then
            mkdir -p "${PROJECT_DIR}/public/application/config"
            cp -r "${CONFIG_TEMP_DIR}/config"/* "${PROJECT_DIR}/public/application/config/" 2>/dev/null || true
        fi
        if [ -d "${CONFIG_TEMP_DIR}/themes" ]; then
            mkdir -p "${PROJECT_DIR}/public/application/themes"
            cp -r "${CONFIG_TEMP_DIR}/themes"/* "${PROJECT_DIR}/public/application/themes/" 2>/dev/null || true
        fi
        if [ -d "${CONFIG_TEMP_DIR}/blocks" ]; then
            mkdir -p "${PROJECT_DIR}/public/application/blocks"
            cp -r "${CONFIG_TEMP_DIR}/blocks"/* "${PROJECT_DIR}/public/application/blocks/" 2>/dev/null || true
        fi
        if [ -d "${CONFIG_TEMP_DIR}/packages" ]; then
            mkdir -p "${PROJECT_DIR}/public/application/packages"
            cp -r "${CONFIG_TEMP_DIR}/packages"/* "${PROJECT_DIR}/public/application/packages/" 2>/dev/null || true
        fi
        
        echo "✓ Config files synced from Git"
    fi
}

# Install dependencies
install_dependencies() {
    print_step "Installing dependencies..."
    
    # Change to project directory (important: may have been in temp directories)
    cd "${PROJECT_DIR}" || { print_error "Cannot change to PROJECT_DIR: ${PROJECT_DIR}"; return 1; }
    
    # Install Composer dependencies
    ${COMPOSER_CMD} install
    
    echo "✓ Dependencies installed"
}

# Clear caches
clear_caches() {
    print_step "Clearing caches..."
    
    if [ -f "${PROJECT_DIR}/vendor/bin/concrete" ]; then
        ./vendor/bin/concrete c5:clear-cache
    fi
    
    echo "✓ Caches cleared"
}

# Main sync flow
main() {
    if is_running_on_production; then
        print_step "Running on production server - pushing files to Git for dev sync"
    else
        print_step "Starting sync from production to dev"
    fi
    
    check_prerequisites
    
    # Setup Git credential caching to avoid multiple prompts
    if [ -n "$FILES_GIT_REPO" ]; then
        setup_git_credentials
    fi
    
    # Handle file syncing - always use Git
    if [ -n "$FILES_GIT_REPO" ]; then
        pull_config_files  # Function handles both push (production) and pull (dev)
    else
        print_error "FILES_GIT_REPO must be set in .deployment-config"
        exit 1
    fi
    
    # Optionally pull/push uploaded files (function handles both directions)
    pull_uploaded_files
    
    # Install dependencies (only if running from dev)
    if ! is_running_on_production; then
        install_dependencies
    fi
    
    # Handle database sync - always use Git
    if [ "$SYNC_DATABASE" = "auto" ]; then
        if [ -z "$FILES_GIT_REPO" ]; then
            print_error "FILES_GIT_REPO must be set for database sync"
            exit 1
        fi
        
        if is_running_on_production; then
            # Running on production - export and push to Git
            export_production_database_to_git
            echo "  This will be imported when you run this script from dev machine"
        else
            # Running from dev - pull from Git and import
            print_step "Syncing database from production to dev via Git..."
            DB_FILE=$(pull_database_from_git)
            if [ -n "$DB_FILE" ] && [ -f "$DB_FILE" ]; then
                import_database "${DB_FILE}"
            else
                print_error "Failed to pull database from Git"
            fi
        fi
    else
        if is_running_on_production; then
            echo "Database sync disabled (SYNC_DATABASE=skip)"
        else
            echo "Database sync disabled (SYNC_DATABASE=skip)"
        fi
    fi
    
    # Clear caches (only if running from dev)
    if ! is_running_on_production; then
        clear_caches
    fi
    
    if is_running_on_production; then
        if [ "$SYNC_DATABASE" = "auto" ]; then
            print_step "Files and database pushed to Git - run this script from dev machine to complete sync"
        else
            print_step "Files pushed to Git - run this script from dev machine to complete sync"
        fi
    else
        print_step "Sync from production completed successfully!"
    fi
}

# Run main function
main "$@"

