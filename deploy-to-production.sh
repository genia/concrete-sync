#!/bin/bash

# Concrete CMS Deployment Script: Dev to Production
# This script handles the complete deployment process including:
# - Database export/import
# - File synchronization
# - Composer dependencies
# - Asset building
# - Environment configuration

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
REMOTE_HOST=""  # e.g., user@example.com
REMOTE_PATH=""  # e.g., /var/www/html (path to site on remote server)
REMOTE_USER=""  # SSH user (combined with REMOTE_HOST if needed)
SYNC_UPLOADED_FILES="auto"  # Options: auto, ask, skip
UPLOADED_FILES_METHOD="git"  # Options: git, zip, rsync
FILES_GIT_REPO=""  # e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files
SYNC_DATABASE="auto"  # Options: auto, skip
COMPOSER_DIR=""  # Directory containing composer.phar (e.g., /usr/local/bin or /opt/composer)
# DB credentials will be loaded from .deployment-config
# On dev: uses local dev database credentials (for export)
# Production DB credentials will be loaded from production .deployment-config via SSH

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
COMPOSER_DIR="${COMPOSER_DIR:-}"
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

PROJECT_DIR="${SITE_PATH}"  # Use SITE_PATH as PROJECT_DIR throughout
DB_BACKUP_DIR="${SITE_PATH}/backups"

# If REMOTE_USER is set but REMOTE_HOST doesn't include user, combine them
if [ -n "$REMOTE_USER" ] && [ -n "$REMOTE_HOST" ] && [[ ! "$REMOTE_HOST" == *"@"* ]]; then
    REMOTE_HOST="${REMOTE_USER}@${REMOTE_HOST}"
fi

# Database credentials will be loaded from .deployment-config in check_prerequisites

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
    
    command -v mysqldump >/dev/null 2>&1 || { print_error "mysqldump is required but not installed"; exit 1; }
    command -v rsync >/dev/null 2>&1 || { print_error "rsync is required but not installed"; exit 1; }
    # Check for composer (either via COMPOSER_DIR or system composer)
    if [ -n "$COMPOSER_DIR" ]; then
        if [ ! -f "${COMPOSER_DIR}/composer.phar" ]; then
            print_error "composer.phar not found at ${COMPOSER_DIR}/composer.phar"
            exit 1
        fi
        command -v php >/dev/null 2>&1 || { print_error "php is required to run composer.phar"; exit 1; }
    else
        command -v composer >/dev/null 2>&1 || { print_error "composer is required but not installed (or set COMPOSER_DIR in .deployment-config)"; exit 1; }
    fi
    
    if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PATH" ]; then
        print_error "REMOTE_HOST and REMOTE_PATH must be set"
        print_error "Set in .deployment-config or as environment variables:"
        print_error "  REMOTE_HOST=server.com REMOTE_PATH=/path/to/site"
        exit 1
    fi
    
    # Validate DB credentials are present (from .deployment-config)
    if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
        print_error "Database credentials not found in .deployment-config file"
        print_error "Required: DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD"
        print_error "Set them in ${CONFIG_FILE} or as environment variables"
        exit 1
    fi
    
    echo "✓ All prerequisites met"
    echo "  Local site path: ${SITE_PATH}"
    echo "  Production server: ${REMOTE_HOST}:${REMOTE_PATH}"
}

# Export database
export_database() {
    print_step "Exporting database from development..."
    
    mkdir -p "${DB_BACKUP_DIR}"
    DB_FILE="${DB_BACKUP_DIR}/database_${TIMESTAMP}.sql"
    
    echo "Exporting database..."
    echo "  Host: ${DB_HOSTNAME}"
    echo "  Database: ${DB_DATABASE}"
    echo "  User: ${DB_USERNAME}"
    
    mysqldump -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" \
        "${DB_DATABASE}" > "${DB_FILE}"
    
    # Compress the dump
    gzip -f "${DB_FILE}"
    DB_FILE="${DB_FILE}.gz"
    
    FILE_SIZE=$(du -h "${DB_FILE}" | cut -f1)
    echo "✓ Database exported"
    echo "  File: ${DB_FILE}"
    echo "  Size: ${FILE_SIZE}"
    echo "${DB_FILE}"
}

# Build assets
build_assets() {
    print_step "Building assets..."
    
    # Change to project directory (important: may have been in temp directories)
    cd "${PROJECT_DIR}" || { print_error "Cannot change to PROJECT_DIR: ${PROJECT_DIR}"; return 1; }
    
    if [ ! -d "${PROJECT_DIR}/node_modules" ]; then
        echo "Installing npm dependencies..."
        npm install
    fi
    
    npm run prod
    
    echo "✓ Assets built"
}

# Create deployment package
create_deployment_package() {
    print_step "Creating deployment package..."
    
    # Files to exclude from git but include in deployment
    # We'll use rsync with exclusions
    
    echo "✓ Deployment package prepared"
}

# Deploy files via rsync
deploy_files() {
    print_step "Deploying files to production..."
    
    # Exclude patterns for rsync
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
        "--exclude=public/application/files"  # We'll sync this separately
    )
    
    # Sync code files
    rsync -avz --delete \
        "${EXCLUDE_PATTERNS[@]}" \
        "${PROJECT_DIR}/" \
        "${REMOTE_HOST}:${REMOTE_PATH}/"
    
    echo "✓ Files deployed"
}

# Deploy uploaded files separately
# This syncs all uploaded images, documents, and thumbnails from public/application/files/
deploy_uploaded_files() {
    print_step "Deploying uploaded files (images, documents, thumbnails)..."
    
    # Check sync behavior setting
    if [ "$SYNC_UPLOADED_FILES" = "skip" ]; then
        echo "Skipping uploaded files sync (SYNC_UPLOADED_FILES=skip)"
        return 0
    fi
    
    if [ "$SYNC_UPLOADED_FILES" = "skip" ]; then
        echo "Skipping uploaded files sync (SYNC_UPLOADED_FILES=skip)"
        return 0
    elif [ "$SYNC_UPLOADED_FILES" = "ask" ]; then
        read -p "Do you want to sync uploaded files (images, documents)? (y/n) " -n 1 -r
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
                FILES_TEMP_DIR="${SCRIPT_DIR}/.files-git-temp"
                
                # Initialize or update local git repo for files
                if [ ! -d "${FILES_TEMP_DIR}" ]; then
                    echo "Initializing Git repository for files..."
                    mkdir -p "${FILES_TEMP_DIR}"
                    cd "${FILES_TEMP_DIR}"
                    git init
                    git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
                else
                    cd "${FILES_TEMP_DIR}"
                    git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
                fi
                
                # Copy files to temp directory
                echo "Preparing files for Git..."
                rm -rf "${FILES_TEMP_DIR}"/*
                cp -r "${PROJECT_DIR}/public/application/files/"* "${FILES_TEMP_DIR}/" 2>/dev/null || true
                
                # Commit and push
                cd "${FILES_TEMP_DIR}"
                git add -A
                if git diff --staged --quiet; then
                    echo "No file changes to sync"
                else
                    git commit -m "Sync files $(date +%Y-%m-%d\ %H:%M:%S)" || true
                    echo "Pushing to Git repository..."
                    git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
                fi
                
                # Pull on remote server
                echo "Pulling files on production server..."
                ssh "${REMOTE_HOST}" << EOF
                    cd ${REMOTE_PATH}
                    TEMP_DIR="\$HOME/.concrete-sync-files-temp"
                    if [ ! -d "\${TEMP_DIR}" ]; then
                        mkdir -p "\${TEMP_DIR}"
                        cd "\${TEMP_DIR}"
                        git init
                        git remote add origin ${FILES_GIT_REPO} 2>/dev/null || git remote set-url origin ${FILES_GIT_REPO}
                    else
                        cd "\${TEMP_DIR}"
                    fi
                    git fetch origin ${FILES_GIT_BRANCH}
                    git reset --hard origin/${FILES_GIT_BRANCH}
                    mkdir -p ${REMOTE_PATH}/public/application/files
                    cp -r * ${REMOTE_PATH}/public/application/files/ 2>/dev/null || true
                    echo "✓ Files synced from Git"
EOF
                
                echo "✓ Uploaded files synced via Git (images, documents, thumbnails)"
            fi
        fi
        
        if [ "$UPLOADED_FILES_METHOD" = "zip" ]; then
            # Zip-based transfer (faster for large file sets)
            echo "Creating zip archive of uploaded files..."
            ZIP_FILE="${PROJECT_DIR}/backups/files_${TIMESTAMP}.zip"
            mkdir -p "${PROJECT_DIR}/backups"
            
            cd "${PROJECT_DIR}/public/application"
            zip -r "${ZIP_FILE}" files/ > /dev/null
            cd "${PROJECT_DIR}"
            
            FILE_SIZE=$(du -h "${ZIP_FILE}" | cut -f1)
            echo "Archive created: ${ZIP_FILE} (${FILE_SIZE})"
            echo "Transferring to production server..."
            
            # Transfer zip file
            scp "${ZIP_FILE}" "${REMOTE_HOST}:${REMOTE_PATH}/files_temp.zip"
            
            # Extract on remote server
            echo "Extracting on production server..."
            ssh "${REMOTE_HOST}" << EOF
                cd ${REMOTE_PATH}
                mkdir -p public/application/files
                unzip -o files_temp.zip -d public/application/
                rm files_temp.zip
                echo "✓ Files extracted"
EOF
            
            # Clean up local zip
            rm "${ZIP_FILE}"
            echo "✓ Uploaded files synced via zip transfer (images, documents, thumbnails)"
        elif [ "$UPLOADED_FILES_METHOD" = "rsync" ]; then
            # Rsync-based transfer (incremental, better for small changes)
            echo "Syncing uploaded files via rsync from ${PROJECT_DIR}/public/application/files/..."
            rsync -avz --progress \
                "${PROJECT_DIR}/public/application/files/" \
                "${REMOTE_HOST}:${REMOTE_PATH}/public/application/files/"
            echo "✓ Uploaded files synced via rsync (images, documents, thumbnails)"
        fi
    else
        echo "Skipped uploaded files sync"
        print_warning "Uploaded images and files were NOT synced. You may need to sync them manually."
    fi
}

# Run post-deployment commands on remote
post_deployment() {
    print_step "Running post-deployment tasks on server..."
    
    ssh "${REMOTE_HOST}" << EOF
        cd ${REMOTE_PATH}
        
        # Load composer command from remote config
        CONFIG_DIR=\$(find ~ -name '.deployment-config' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null) || CONFIG_DIR=\$(dirname ${REMOTE_PATH})/concrete-sync
        if [ -f "\${CONFIG_DIR}/.deployment-config" ]; then
            source "\${CONFIG_DIR}/.deployment-config"
        fi
        if [ -n "\${COMPOSER_DIR:-}" ]; then
            COMPOSER_CMD="php \${COMPOSER_DIR}/composer.phar"
        else
            COMPOSER_CMD="composer"
        fi
        
        # Install Composer dependencies
        \${COMPOSER_CMD} install --no-dev --optimize-autoloader
        
        # Clear caches
        ./vendor/bin/concrete c5:clear-cache
        
        # Run database migrations if needed
        # ./vendor/bin/concrete c5:migrate
        
        echo "✓ Post-deployment tasks completed"
EOF
    
    echo "✓ Remote tasks completed"
}

# Import database to production
import_database() {
    print_step "Importing database to production..."
    
    if [ -z "$1" ]; then
        print_error "Database file path required"
        return 1
    fi
    
    DB_FILE="$1"
    
    # Production DB credentials are in production .deployment-config file
    # We'll load them via SSH when importing
    # Find the deployment config file on production server (it's in the concrete-sync directory)
    echo "Importing database..."
    echo "  Source: ${DB_FILE}"
    echo "  Target: Production database (credentials from production .deployment-config)"
    echo "  Server: ${REMOTE_HOST}"
    
    # Transfer and import database
    # Production .deployment-config has production DB credentials
    # Try to find the config file: look for .deployment-config in common locations
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "${DB_FILE}" | ssh "${REMOTE_HOST}" \
            "CONFIG_DIR=\$(find ~ -name '.deployment-config' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null) || CONFIG_DIR=\$(dirname ${REMOTE_PATH})/concrete-sync; \
             [ -f \"\${CONFIG_DIR}/.deployment-config\" ] && cd \"\${CONFIG_DIR}\" && source .deployment-config && \
             mysql -h\${DB_HOSTNAME} -u\${DB_USERNAME} -p\${DB_PASSWORD} \${DB_DATABASE}"
    else
        ssh "${REMOTE_HOST}" \
            "CONFIG_DIR=\$(find ~ -name '.deployment-config' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null) || CONFIG_DIR=\$(dirname ${REMOTE_PATH})/concrete-sync; \
             [ -f \"\${CONFIG_DIR}/.deployment-config\" ] && cd \"\${CONFIG_DIR}\" && source .deployment-config && \
             mysql -h\${DB_HOSTNAME} -u\${DB_USERNAME} -p\${DB_PASSWORD} \${DB_DATABASE}" < "${DB_FILE}"
    fi
    
    echo "✓ Database imported to production"
}

# Main deployment flow
main() {
    print_step "Starting deployment to production"
    
    check_prerequisites
    
    # Export database
    DB_FILE=$(export_database)
    
    # Build assets
    build_assets
    
    # Deploy files
    deploy_files
    
    # Optionally deploy uploaded files
    deploy_uploaded_files
    
    # Run post-deployment tasks
    post_deployment
    
    # Import database if enabled
    if [ "$SYNC_DATABASE" = "auto" ]; then
        import_database "${DB_FILE}"
    else
        echo "Database sync disabled (SYNC_DATABASE=skip)"
        echo "Database backup saved at: ${DB_FILE}"
        echo "Import manually when ready"
    fi
    
    print_step "Deployment completed successfully!"
    echo -e "${GREEN}Database backup: ${DB_FILE}${NC}"
}

# Run main function
main "$@"

