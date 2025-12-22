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
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Default values (can be overridden by .deployment-config or environment variables)
REMOTE_HOST=""  # e.g., user@example.com
REMOTE_PATH=""  # e.g., /var/www/html
REMOTE_USER=""  # SSH user (combined with REMOTE_HOST if needed)
SYNC_UPLOADED_FILES="ask"  # Options: auto, ask, skip
UPLOADED_FILES_METHOD="git"  # Options: git, zip, rsync
FILES_GIT_REPO=""  # e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files

# Load configuration from .deployment-config if it exists
CONFIG_FILE="${PROJECT_DIR}/.deployment-config"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# Environment variables override config file values
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PATH="${REMOTE_PATH:-}"
REMOTE_USER="${REMOTE_USER:-}"
SYNC_UPLOADED_FILES="${SYNC_UPLOADED_FILES:-ask}"
UPLOADED_FILES_METHOD="${UPLOADED_FILES_METHOD:-git}"
FILES_GIT_REPO="${FILES_GIT_REPO:-}"
FILES_GIT_BRANCH="${FILES_GIT_BRANCH:-main}"

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
    
    command -v mysql >/dev/null 2>&1 || { print_error "mysql client is required but not installed"; exit 1; }
    
    if is_running_on_production; then
        # Running on production server - REMOTE_PATH should be current directory or set
        if [ -z "$REMOTE_PATH" ]; then
            REMOTE_PATH="${PROJECT_DIR}"
            echo "Running on production server, using current directory: ${REMOTE_PATH}"
        fi
        PROD_PATH="${REMOTE_PATH}"
        echo "✓ Running directly on production server at ${PROD_PATH}"
    else
        # Running from dev, need REMOTE_HOST and REMOTE_PATH
        if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PATH" ]; then
            print_error "REMOTE_HOST and REMOTE_PATH must be set (via env vars or script config)"
            print_error "Example: REMOTE_HOST=server.com REMOTE_PATH=/path/to/site ./deploy-from-production.sh"
            exit 1
        fi
        command -v rsync >/dev/null 2>&1 || { print_error "rsync is required but not installed"; exit 1; }
        command -v ssh >/dev/null 2>&1 || { print_error "ssh is required but not installed"; exit 1; }
        command -v scp >/dev/null 2>&1 || { print_error "scp is required but not installed"; exit 1; }
        PROD_PATH="${REMOTE_PATH}"
        echo "✓ Will connect to production server: ${REMOTE_HOST}:${PROD_PATH}"
    fi
    
    if [ ! -f "${PROJECT_DIR}/.env" ] && ! is_running_on_production; then
        print_error ".env file not found (required for local dev database)"
        exit 1
    fi
    
    echo "✓ All prerequisites met"
}

# Export database from production
export_production_database() {
    print_step "Exporting database from production..."
    
    mkdir -p "${DB_BACKUP_DIR}"
    DB_FILE="${DB_BACKUP_DIR}/production_db_${TIMESTAMP}.sql"
    
    # Get production DB credentials
    read -p "Enter production DB hostname: " PROD_DB_HOST
    read -p "Enter production DB name: " PROD_DB_NAME
    read -p "Enter production DB username: " PROD_DB_USER
    read -s -p "Enter production DB password: " PROD_DB_PASS
    echo
    
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
    
    print_warning "This will overwrite your local database!"
    read -p "Are you sure? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Database import cancelled"
        return 1
    fi
    
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
    
    if [ "$SYNC_UPLOADED_FILES" = "auto" ]; then
        SYNC_YES="y"
    else
        read -p "Do you want to sync uploaded files (images, documents) from production? (y/n) " -n 1 -r
        echo
        SYNC_YES="$REPLY"
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
                    PROD_FILES_TEMP_DIR="${PROD_PATH}/.files-git-temp"
                    cd "${PROD_PATH}"
                    
                    if [ ! -d "${PROD_FILES_TEMP_DIR}" ]; then
                        mkdir -p "${PROD_FILES_TEMP_DIR}"
                        cd "${PROD_FILES_TEMP_DIR}"
                        git init
                        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
                    else
                        cd "${PROD_FILES_TEMP_DIR}"
                        git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
                    fi
                    
                    # Copy files to temp directory
                    rm -rf *
                    cp -r ../public/application/files/* . 2>/dev/null || true
                    
                    # Commit and push
                    git add -A
                    if ! git diff --staged --quiet; then
                        git commit -m "Sync files from production $(date +%Y-%m-%d\ %H:%M:%S)" || true
                        git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
                    fi
                    echo "✓ Files pushed to Git"
                else
                    # Running from dev, push via SSH
                    ssh "${REMOTE_HOST}" << EOF
                        cd ${PROD_PATH}
                        if [ ! -d ".files-git-temp" ]; then
                            mkdir -p .files-git-temp
                            cd .files-git-temp
                            git init
                            git remote add origin ${FILES_GIT_REPO} 2>/dev/null || git remote set-url origin ${FILES_GIT_REPO}
                        else
                            cd .files-git-temp
                            git fetch origin ${FILES_GIT_BRANCH} 2>/dev/null || true
                        fi
                        
                        # Copy files to temp directory
                        rm -rf *
                        cp -r ../public/application/files/* . 2>/dev/null || true
                        
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
                    FILES_TEMP_DIR="${PROJECT_DIR}/.files-git-temp"
                    
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
        read -p "Do you want to sync the database? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            DB_FILE=$(export_production_database)
            import_database "${DB_FILE}"
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

