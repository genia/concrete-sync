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
UPLOADED_FILES_METHOD="git"  # Options: git, zip, rsync
FILES_GIT_REPO=""  # e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files
SYNC_DATABASE="auto"  # Options: auto, skip
PROD_DB_HOST=""  # Production database hostname (from config or env)
PROD_DB_NAME=""  # Production database name (from config or env)
PROD_DB_USER=""  # Production database username (from config or env)
PROD_DB_PASS=""  # Production database password (from config or env)

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
UPLOADED_FILES_METHOD="${UPLOADED_FILES_METHOD:-git}"
FILES_GIT_REPO="${FILES_GIT_REPO:-}"
FILES_GIT_BRANCH="${FILES_GIT_BRANCH:-main}"
SYNC_DATABASE="${SYNC_DATABASE:-auto}"
PROD_DB_HOST="${PROD_DB_HOST:-}"
PROD_DB_NAME="${PROD_DB_NAME:-}"
PROD_DB_USER="${PROD_DB_USER:-}"
PROD_DB_PASS="${PROD_DB_PASS:-}"

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
    # If REMOTE_HOST is not set, assume we're running on production server
    [ -z "$REMOTE_HOST" ]
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites..."
    
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
    
    if is_running_on_production; then
        # Running on production server - SITE_PATH is the production site
        PROD_PATH="${SITE_PATH}"
        echo "✓ Running directly on production server"
        echo "  Site path: ${PROD_PATH}"
    else
        # Running from dev, need REMOTE_HOST and REMOTE_PATH
        if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PATH" ]; then
            print_error "REMOTE_HOST and REMOTE_PATH must be set when running from dev"
            print_error "Set in .deployment-config or as environment variables:"
            print_error "  REMOTE_HOST=server.com REMOTE_PATH=/path/to/site"
            exit 1
        fi
        command -v rsync >/dev/null 2>&1 || { print_error "rsync is required but not installed"; exit 1; }
        command -v ssh >/dev/null 2>&1 || { print_error "ssh is required but not installed"; exit 1; }
        command -v scp >/dev/null 2>&1 || { print_error "scp is required but not installed"; exit 1; }
        PROD_PATH="${REMOTE_PATH}"
        echo "✓ Running from dev machine"
        echo "  Local site path: ${SITE_PATH}"
        echo "  Production server: ${REMOTE_HOST}:${PROD_PATH}"
    fi
    
    if [ ! -f "${PROJECT_DIR}/.env" ] && ! is_running_on_production; then
        print_error ".env file not found at ${PROJECT_DIR}/.env (required for local dev database)"
        exit 1
    fi
    
    echo "✓ All prerequisites met"
}

# Export database from production
export_production_database() {
    print_step "Exporting database from production..."
    
    mkdir -p "${DB_BACKUP_DIR}"
    DB_FILE="${DB_BACKUP_DIR}/production_db_${TIMESTAMP}.sql"
    
    # Get production DB credentials from config or prompt
    if [ -z "$PROD_DB_HOST" ] || [ -z "$PROD_DB_NAME" ] || [ -z "$PROD_DB_USER" ] || [ -z "$PROD_DB_PASS" ]; then
        print_warning "Production DB credentials not in config, prompting..."
        read -p "Enter production DB hostname: " PROD_DB_HOST
        read -p "Enter production DB name: " PROD_DB_NAME
        read -p "Enter production DB username: " PROD_DB_USER
        read -s -p "Enter production DB password: " PROD_DB_PASS
        echo
    fi
    
    if is_running_on_production; then
        # Running on production server directly
        mysqldump -h"${PROD_DB_HOST}" -u"${PROD_DB_USER}" -p"${PROD_DB_PASS}" "${PROD_DB_NAME}" | gzip > "${DB_FILE}.gz"
    else
        # Export via SSH
        ssh "${REMOTE_HOST}" \
            "mysqldump -h${PROD_DB_HOST} -u${PROD_DB_USER} -p${PROD_DB_PASS} ${PROD_DB_NAME}" \
            | gzip > "${DB_FILE}.gz"
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
    
    # Load local DB config from .env
    if [ ! -f "${PROJECT_DIR}/.env" ]; then
        print_error ".env file not found (required for local dev database)"
        return 1
    fi
    source "${PROJECT_DIR}/.env"
    
    print_warning "Importing database - this will overwrite your local database!"
    
    # Import database
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "${DB_FILE}" | mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}"
    else
        mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" < "${DB_FILE}"
    fi
    
    echo "✓ Database imported to local development"
}

# Pull files from production
pull_files() {
    print_step "Pulling files from production..."
    
    if is_running_on_production; then
        # Running on production - this doesn't make sense, skip it
        echo "Running on production server - skipping file pull (already have files)"
        return 0
    fi
    
    # Exclude patterns
    EXCLUDE_PATTERNS=(
        "--exclude=.git"
        "--exclude=.env"
        "--exclude=node_modules"
        "--exclude=.idea"
        "--exclude=backups"
        "--exclude=tests"
        "--exclude=phpunit.xml"
        "--exclude=.phpunit.*"
        "--exclude=public/hot"
        "--exclude=public/mix-manifest.json"
        "--exclude=vendor"  # We'll install via composer
    )
    
    # Pull code files
    rsync -avz \
        "${EXCLUDE_PATTERNS[@]}" \
        "${REMOTE_HOST}:${PROD_PATH}/" \
        "${PROJECT_DIR}/"
    
    echo "✓ Files pulled from production"
}

# Pull uploaded files from production
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
        if [ "$UPLOADED_FILES_METHOD" = "git" ]; then
            # Git-based transfer (best of both worlds - fast, incremental, versioned)
            echo "Syncing uploaded files via Git intermediary..."
            
            if [ -z "$FILES_GIT_REPO" ]; then
                print_error "FILES_GIT_REPO must be configured for git method"
                print_warning "Falling back to zip method"
                UPLOADED_FILES_METHOD="zip"
            else
                # Push from production server to Git
                echo "Pushing files from production to Git..."
                
                if is_running_on_production; then
                    # Running on production server directly
                    PROD_FILES_TEMP_DIR="${SCRIPT_DIR}/.files-git-temp"
                    
                    if [ ! -d "${PROD_FILES_TEMP_DIR}" ]; then
                        mkdir -p "${PROD_FILES_TEMP_DIR}"
                        cd "${PROD_FILES_TEMP_DIR}"
                        git init
                        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
                    else
                        cd "${PROD_FILES_TEMP_DIR}"
                        git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
                    fi
                    
                    # Copy files to temp directory from production site
                    rm -rf *
                    cp -r "${PROD_PATH}/public/application/files/"* . 2>/dev/null || true
                    
                    # Commit and push
                    git add -A
                    if ! git diff --staged --quiet; then
                        git commit -m "Sync files from production $(date +%Y-%m-%d\ %H:%M:%S)" || true
                        git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
                    fi
                    echo "✓ Files pushed to Git"
                else
                    # Running from dev, push via SSH
                    # Use a temp directory in the home directory (not in the site directory)
                    ssh "${REMOTE_HOST}" << EOF
                        TEMP_DIR="\$HOME/.concrete-sync-files-temp"
                        if [ ! -d "\${TEMP_DIR}" ]; then
                            mkdir -p "\${TEMP_DIR}"
                            cd "\${TEMP_DIR}"
                            git init
                            git remote add origin ${FILES_GIT_REPO} 2>/dev/null || git remote set-url origin ${FILES_GIT_REPO}
                        else
                            cd "\${TEMP_DIR}"
                            git fetch origin ${FILES_GIT_BRANCH} 2>/dev/null || true
                        fi
                        
                        # Copy files to temp directory from production site
                        rm -rf *
                        cp -r ${PROD_PATH}/public/application/files/* . 2>/dev/null || true
                        
                        # Commit and push
                        git add -A
                        if ! git diff --staged --quiet; then
                            git commit -m "Sync files from production \$(date +%Y-%m-%d\ %H:%M:%S)" || true
                            git push origin HEAD:${FILES_GIT_BRANCH} || git push -u origin ${FILES_GIT_BRANCH}
                        fi
                        echo "✓ Files pushed to Git"
EOF
                fi
                
                # Pull to local dev (only if not running on production)
                if ! is_running_on_production; then
                    echo "Pulling files from Git to local development..."
                    FILES_TEMP_DIR="${SCRIPT_DIR}/.files-git-temp"
                    
                    if [ ! -d "${FILES_TEMP_DIR}" ]; then
                        mkdir -p "${FILES_TEMP_DIR}"
                        cd "${FILES_TEMP_DIR}"
                        git init
                        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
                    else
                        cd "${FILES_TEMP_DIR}"
                    fi
                    
                    git fetch origin "${FILES_GIT_BRANCH}"
                    git reset --hard "origin/${FILES_GIT_BRANCH}"
                    
                    # Copy to local files directory
                    mkdir -p "${PROJECT_DIR}/public/application/files"
                    cp -r "${FILES_TEMP_DIR}"/* "${PROJECT_DIR}/public/application/files/" 2>/dev/null || true
                    
                    echo "✓ Uploaded files synced via Git (images, documents, thumbnails)"
                else
                    echo "✓ Files pushed to Git (running on production, pull from dev machine)"
                fi
            fi
        fi
        
        if [ "$UPLOADED_FILES_METHOD" = "zip" ]; then
            # Zip-based transfer (faster for large file sets)
            if is_running_on_production; then
                echo "Running on production - zip method not applicable (use git method or run from dev)"
                print_warning "Skipping zip transfer when running on production server"
            else
                echo "Creating zip archive on production server..."
                ZIP_FILE="files_${TIMESTAMP}.zip"
                
                # Create zip on remote server
                ssh "${REMOTE_HOST}" << EOF
                    cd ${PROD_PATH}/public/application
                    zip -r /tmp/${ZIP_FILE} files/ > /dev/null
                    echo "Archive created on server"
EOF
                
                # Download zip file
                echo "Downloading zip archive..."
                scp "${REMOTE_HOST}:/tmp/${ZIP_FILE}" "${PROJECT_DIR}/backups/${ZIP_FILE}"
                
                # Extract locally
                echo "Extracting files..."
                mkdir -p "${PROJECT_DIR}/public/application/files"
                cd "${PROJECT_DIR}/public/application"
                unzip -o "${PROJECT_DIR}/backups/${ZIP_FILE}" > /dev/null
                cd "${PROJECT_DIR}"
                
                # Clean up
                rm "${PROJECT_DIR}/backups/${ZIP_FILE}"
                ssh "${REMOTE_HOST}" "rm /tmp/${ZIP_FILE}"
                
                echo "✓ Uploaded files synced via zip transfer (images, documents, thumbnails)"
            fi
        elif [ "$UPLOADED_FILES_METHOD" = "rsync" ]; then
            # Rsync-based transfer (incremental, better for small changes)
            if is_running_on_production; then
                echo "Running on production - rsync method not applicable (use git method or run from dev)"
                print_warning "Skipping rsync transfer when running on production server"
            else
                echo "Syncing uploaded files via rsync from production..."
                rsync -avz --progress \
                    "${REMOTE_HOST}:${PROD_PATH}/public/application/files/" \
                    "${PROJECT_DIR}/public/application/files/"
                echo "✓ Uploaded files synced via rsync (images, documents, thumbnails)"
            fi
        fi
    else
        echo "Skipped uploaded files sync"
        print_warning "Uploaded images and files were NOT synced. You may need to sync them manually."
    fi
}

# Install dependencies
install_dependencies() {
    print_step "Installing dependencies..."
    
    # Install Composer dependencies
    composer install
    
    # Install npm dependencies if needed
    if [ -f "${PROJECT_DIR}/package.json" ]; then
        if [ ! -d "${PROJECT_DIR}/node_modules" ]; then
            npm install
        fi
        npm run dev
    fi
    
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
    
    # Pull files (only if running from dev)
    if ! is_running_on_production; then
        pull_files
    fi
    
    # Optionally pull/push uploaded files
    pull_uploaded_files
    
    # Install dependencies (only if running from dev)
    if ! is_running_on_production; then
        install_dependencies
    fi
    
    # Export and import database (only if running from dev)
    if ! is_running_on_production; then
        if [ "$SYNC_DATABASE" = "auto" ]; then
            DB_FILE=$(export_production_database)
            import_database "${DB_FILE}"
        else
            echo "Database sync disabled (SYNC_DATABASE=skip)"
        fi
        
        # Clear caches
        clear_caches
    fi
    
    if is_running_on_production; then
        print_step "Files pushed to Git - run this script from dev machine to complete sync"
    else
        print_step "Sync from production completed successfully!"
    fi
}

# Run main function
main "$@"

