#!/bin/bash

# Concrete CMS Deployment Script: Bidirectional Sync via Git
# This script syncs data between production and development environments using Git
# Usage: ./concrete-cms-sync.sh [push|pull]
#   push - Push files/database from current environment to Git (for syncing to other environment)
#   pull - Pull files/database from Git to current environment (from other environment)

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
SYNC_UPLOADED_FILES="auto"  # Options: auto, ask, skip
FILES_GIT_REPO=""  # REQUIRED: e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files
SYNC_DATABASE="auto"  # Options: auto, skip
COMPOSER_DIR=""  # Directory containing composer.phar (e.g., /usr/local/bin or /opt/composer)
ENVIRONMENT=""  # REQUIRED: "prod" or "dev" - set to "prod" on production server, "dev" on development machine
SYNC_DIRECTION=""  # Will be set from command-line argument: "push" or "pull"
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

# Functions
print_step() {
    echo -e "\n${GREEN}==> $1${NC}\n" >&2
}

print_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
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

# Print deployment plan banner
print_deployment_plan() {
    local direction="$1"
    local direction_upper=$(echo "$direction" | tr '[:lower:]' '[:upper:]')
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "                    DEPLOYMENT PLAN - ${direction_upper}"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Environment: ${ENVIRONMENT:-not set}"
    echo "Site Path: ${SITE_PATH:-not set}"
    echo "Git Repository: ${FILES_GIT_REPO:-not set}"
    echo "Git Branch: ${FILES_GIT_BRANCH:-main}"
    echo ""
    
    if [ "$direction" = "push" ]; then
        echo "Actions to be performed:"
        if [ "$SYNC_DATABASE" = "auto" ]; then
            if [ -n "${DB_HOSTNAME:-}" ] && [ -n "${DB_DATABASE:-}" ]; then
                echo "  ✓ Export database from: ${DB_HOSTNAME}/${DB_DATABASE}"
            else
                echo "  ✓ Export database (credentials from config)"
            fi
            echo "  ✓ Push database to Git repository"
        else
            echo "  ⊘ Skip database sync (SYNC_DATABASE=skip)"
        fi
        echo "  ✓ Push config files (config/, themes/, blocks/, packages/) to Git"
        if [ "$SYNC_UPLOADED_FILES" != "skip" ]; then
            echo "  ✓ Push uploaded files (public/application/files/) to Git"
        else
            echo "  ⊘ Skip uploaded files (SYNC_UPLOADED_FILES=skip)"
        fi
        echo "  ✓ Create snapshot tags for each sync operation"
    else
        echo "Actions to be performed:"
        if [ "$SYNC_DATABASE" = "auto" ]; then
            echo "  ✓ Pull database from Git repository"
            if [ -n "${DB_HOSTNAME:-}" ] && [ -n "${DB_DATABASE:-}" ]; then
                echo "  ✓ Import database to: ${DB_HOSTNAME}/${DB_DATABASE}"
            else
                echo "  ✓ Import database (credentials from config)"
            fi
        else
            echo "  ⊘ Skip database sync (SYNC_DATABASE=skip)"
        fi
        echo "  ✓ Pull config files (config/, themes/, blocks/, packages/) from Git"
        if [ "$SYNC_UPLOADED_FILES" != "skip" ]; then
            echo "  ✓ Pull uploaded files (public/application/files/) from Git"
        else
            echo "  ⊘ Skip uploaded files (SYNC_UPLOADED_FILES=skip)"
        fi
        echo "  ✓ Install Composer dependencies"
        echo "  ✓ Clear Concrete CMS caches"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
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

# Create and push a Git tag for this snapshot
create_snapshot_tag() {
    local tag_type="${1:-sync}"  # db, files, config, or sync (default)
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local tag_name="${tag_type}-${timestamp}"
    
    # Create the tag (suppress output)
    git tag -f "${tag_name}" >/dev/null 2>&1 || {
        print_warning "Could not create tag: ${tag_name}" >&2
        return 1
    }
    
    # Push the tag to remote (suppress output)
    git push origin "${tag_name}" --force >/dev/null 2>&1 || {
        print_warning "Could not push tag to remote: ${tag_name}" >&2
        return 1
    }
    
    echo "${tag_name}"  # Return tag name via stdout
    return 0
}

# List available tags and let user select one (or "latest")
select_snapshot_tag() {
    local repo_url="$1"
    local branch="${2:-main}"
    
    print_step "Fetching available snapshot tags..."
    
    # Create temp directory for fetching tags
    local temp_dir="${SCRIPT_DIR}/.tag-list-temp"
    if [ -d "${temp_dir}" ]; then
        rm -rf "${temp_dir}"
    fi
    mkdir -p "${temp_dir}"
    cd "${temp_dir}" || {
        echo "latest"
        return 0
    }
    
    # Initialize git and fetch tags
    git init >/dev/null 2>&1
    git remote add origin "${repo_url}" >/dev/null 2>&1 || git remote set-url origin "${repo_url}" >/dev/null 2>&1
    
    # Fetch tags from remote (fetch both branch and tags)
    echo "  Fetching tags from ${repo_url}..."
    # First fetch the branch
    git fetch origin "${branch}" >/dev/null 2>&1 || true
    # Then fetch all tags
    if ! git fetch origin "refs/tags/*:refs/tags/*" >/dev/null 2>&1; then
        print_warning "Could not fetch tags from repository"
        print_warning "Will use latest from branch instead"
        echo "latest"  # Return "latest" as fallback
        cd - >/dev/null 2>&1
        rm -rf "${temp_dir}"
        return 0
    fi
    
    # Get list of tags, sorted by date (newest first)
    # Sort tags by their timestamp (newest first) - tags are named like db-20240115-143022
    local tags=$(git tag -l | sort -r | head -20)  # Show last 20 tags
    
    cd - >/dev/null 2>&1
    rm -rf "${temp_dir}"
    
    if [ -z "$tags" ]; then
        echo ""
        echo "No snapshot tags found in repository." >&2
        echo ""
        echo "This could mean:" >&2
        echo "  - No snapshots have been pushed yet (run 'push' first to create tags)" >&2
        echo "  - Tags exist but weren't fetched (check repository access)" >&2
        echo ""
        echo "Using latest from branch instead." >&2
        echo ""
        read -p "Press Enter to continue with latest, or Ctrl+C to cancel..." -r
        echo ""
        echo "latest"
        return 0
    fi
    
    # Display tags to user
    echo ""
    echo "Available snapshots:"
    echo "  0) latest (most recent from branch)"
    local count=1
    for tag in $tags; do
        echo "  ${count}) ${tag}"
        count=$((count + 1))
    done
    echo ""
    
    # Prompt user for selection
    while true; do
        read -p "Select snapshot to use (0 for latest, or number): " selection
        if [ "$selection" = "0" ] || [ "$selection" = "latest" ]; then
            echo "latest"
            return 0
        elif [ -n "$selection" ] && [ "$selection" -ge 1 ] && [ "$selection" -le "$(echo "$tags" | wc -l | tr -d ' ')" ] 2>/dev/null; then
            # Get the selected tag
            local selected_tag=$(echo "$tags" | sed -n "${selection}p")
            echo "$selected_tag"
            return 0
        else
            print_error "Invalid selection. Please enter 0 for latest or a number from the list."
        fi
    done
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
    
    # Check if SITE_PATH points to public/ directory instead of site root
    # If it ends with /public and has a parent with composer.json, use the parent
    if [[ "$SITE_PATH" == */public ]] && [ -f "$(dirname "$SITE_PATH")/composer.json" ]; then
        print_warning "SITE_PATH appears to point to public/ directory, using parent directory as site root"
        SITE_PATH="$(dirname "$SITE_PATH")"
        echo "  Adjusted SITE_PATH to: ${SITE_PATH}"
    fi
    
    # Check if it looks like a Concrete CMS site
    if [ ! -d "${SITE_PATH}/public" ] && [ ! -f "${SITE_PATH}/composer.json" ]; then
        print_warning "SITE_PATH doesn't appear to be a Concrete CMS site (no public/ or composer.json found)"
        print_warning "Expected: site root with public/ subdirectory and composer.json"
    fi
    
    PROJECT_DIR="${SITE_PATH}"  # Use SITE_PATH as PROJECT_DIR throughout
    
    command -v mysql >/dev/null 2>&1 || { print_error "mysql client is required but not installed"; exit 1; }
    
    # FILES_GIT_REPO is required (we use Git exclusively)
    if [ -z "$FILES_GIT_REPO" ]; then
        print_error "FILES_GIT_REPO must be set in .deployment-config"
        print_error "This script uses Git exclusively for all syncing operations"
        exit 1
    fi
    
    # Determine environment
    if is_running_on_production; then
        # Running on production server
        PROD_PATH="${SITE_PATH}"
        echo "✓ Running on production server (ENVIRONMENT=${ENVIRONMENT})"
        echo "  Site path: ${PROD_PATH}"
    else
        # Running on dev machine
        PROD_PATH="${SITE_PATH}"
        echo "✓ Running on development machine (ENVIRONMENT=${ENVIRONMENT})"
        echo "  Site path: ${SITE_PATH}"
    fi
    
    # Validate DB credentials are present (from .deployment-config)
    # Always need DB credentials for database operations
    if [ "$SYNC_DATABASE" = "auto" ]; then
        if [ -z "${DB_HOSTNAME:-}" ] || [ -z "${DB_DATABASE:-}" ] || [ -z "${DB_USERNAME:-}" ] || [ -z "${DB_PASSWORD:-}" ]; then
            print_error "Database credentials not found in .deployment-config file"
            print_error "Required: DB_HOSTNAME, DB_DATABASE, DB_USERNAME, DB_PASSWORD"
            print_error "Set them in ${CONFIG_FILE} or as environment variables"
            exit 1
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
    mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${DB_FILE}"
    
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
    local selected_tag="${1:-latest}"  # Tag to checkout, or "latest" for branch HEAD
    
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
    
    cd "${DB_TEMP_DIR}" || {
        print_error "Failed to change to temp directory: ${DB_TEMP_DIR}"
        return 1
    }
    
    # All git commands must send ALL output (stdout and stderr) to stderr to avoid interfering with stdout capture
    # This ensures only the file path is captured, not git command output
    # Pattern: { command 2>&1; } >&2 redirects both stdout and stderr to stderr
    { git init 2>&1; } >&2 || {
        print_error "Failed to initialize Git repository"
        return 1
    }
    
    { git remote add origin "${FILES_GIT_REPO}" 2>&1; } >&2 || { git remote set-url origin "${FILES_GIT_REPO}" 2>&1; } >&2 || {
        print_error "Failed to set Git remote: ${FILES_GIT_REPO}"
        return 1
    }
    
    # Fetch from Git repository including tags (send all output to stderr)
    if ! { git fetch origin "${FILES_GIT_BRANCH}" "refs/tags/*:refs/tags/*" 2>&1; } >&2; then
        print_error "Failed to fetch from Git repository"
        print_error "Repository: ${FILES_GIT_REPO}"
        print_error "Branch: ${FILES_GIT_BRANCH}"
        print_error "Make sure the repository exists and you have access"
        return 1
    fi
    
    # Checkout based on tag or branch
    if [ "$selected_tag" = "latest" ]; then
        # Checkout the branch (send all output to stderr)
        if ! ({ git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>&1; } >&2) && ! ({ git checkout "${FILES_GIT_BRANCH}" 2>&1; } >&2); then
            print_error "Failed to checkout branch: ${FILES_GIT_BRANCH}"
            print_error "Make sure the branch exists in the repository"
            return 1
        fi
        echo "  Using latest snapshot from branch: ${FILES_GIT_BRANCH}" >&2
    else
        # Checkout the specific tag
        if ! { git checkout "${selected_tag}" 2>&1; } >&2; then
            print_error "Failed to checkout tag: ${selected_tag}"
            print_error "Make sure the tag exists in the repository"
            return 1
        fi
        echo "  Using snapshot tag: ${selected_tag}" >&2
    fi
    
    # Check if database directory exists
    if [ ! -d "database" ]; then
        print_error "No 'database' directory found in Git repository"
        print_error "Make sure database has been exported and pushed to Git from production server"
        print_error "Expected path in repo: database/latest.sql.gz or database/production_db_*.sql.gz"
        return 1
    fi
    
    # Find the latest database file (use absolute path)
    if [ -f "database/latest.sql.gz" ]; then
        DB_FILE="${DB_TEMP_DIR}/database/latest.sql.gz"
        if [ ! -f "${DB_FILE}" ]; then
            print_error "Database file not found: ${DB_FILE}"
            return 1
        fi
        echo "✓ Database pulled from Git: ${DB_FILE}" >&2
        echo -n "${DB_FILE}"  # Only file path to stdout (no newline)
    elif [ -n "$(find database/ -name "production_db_*.sql.gz" -type f 2>/dev/null | head -1)" ]; then
        # Find the most recent database file
        DB_FILE_RELATIVE=$(find database/ -name "production_db_*.sql.gz" -type f | sort -r | head -1)
        if [ -z "$DB_FILE_RELATIVE" ]; then
            print_error "No database files found in database/ directory"
            return 1
        fi
        DB_FILE="${DB_TEMP_DIR}/${DB_FILE_RELATIVE}"
        if [ ! -f "${DB_FILE}" ]; then
            print_error "Database file not found: ${DB_FILE}"
            return 1
        fi
        echo "✓ Database pulled from Git: ${DB_FILE}" >&2
        echo -n "${DB_FILE}"  # Only file path to stdout (no newline)
    else
        print_error "No database file found in Git repository"
        print_error "Make sure database has been exported and pushed to Git from production server"
        print_error "Expected files: database/latest.sql.gz or database/production_db_*.sql.gz"
        print_error "Current directory contents:"
        ls -la . 2>/dev/null || true
        if [ -d "database" ]; then
            echo "Database directory contents:"
            ls -la database/ 2>/dev/null || true
        fi
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
    
    # Use DB credentials from .deployment-config
    echo "  Host: ${DB_HOSTNAME}"
    echo "  Database: ${DB_DATABASE}"
    echo "  User: ${DB_USERNAME}"
    mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${DB_FILE}.gz"
    
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

# Sync uploaded files via Git (handles both push and pull)
# This syncs all uploaded images, documents, and thumbnails from public/application/files/
pull_uploaded_files() {
    print_step "Syncing uploaded files (images, documents, thumbnails)..."
    
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
        
        # Push or pull based on SYNC_DIRECTION
        if [ "$SYNC_DIRECTION" = "push" ]; then
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
            # Pull direction - pull files from Git
            local selected_tag="${1:-latest}"  # Tag to checkout, or "latest" for branch HEAD
            echo "Pulling files from Git..."
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
            
            # Fetch including tags
            git fetch origin "${FILES_GIT_BRANCH}" "refs/tags/*:refs/tags/*"
            
            # Checkout based on tag or branch
            if [ "$selected_tag" = "latest" ]; then
                git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
                echo "  Using latest snapshot from branch: ${FILES_GIT_BRANCH}"
            else
                git checkout "${selected_tag}"
                echo "  Using snapshot tag: ${selected_tag}"
            fi
            
            # Copy to local files directory
            # Ensure the target directory exists
            mkdir -p "${PROJECT_DIR}/public/application/files"
            
            # Copy all files and directories, preserving structure
            # Exclude database and cache directories (they're stored separately in Git)
            if [ -n "$(ls -A "${FILES_TEMP_DIR}" 2>/dev/null)" ]; then
                # Copy contents, excluding database and cache directories
                for item in "${FILES_TEMP_DIR}"/*; do
                    if [ -e "$item" ]; then
                        item_name=$(basename "$item")
                        # Skip database and cache directories (they're synced separately)
                        if [ "$item_name" != "database" ] && [ "$item_name" != "cache" ]; then
                            cp -R "$item" "${PROJECT_DIR}/public/application/files/" 2>/dev/null || {
                                print_warning "Failed to copy: $item_name"
                            }
                        fi
                    fi
                done
                
                # Also copy hidden files/directories (except .git)
                for item in "${FILES_TEMP_DIR}"/.[^.]*; do
                    if [ -e "$item" ]; then
                        item_name=$(basename "$item")
                        if [ "$item_name" != ".git" ] && [ "$item_name" != ".gitkeep" ]; then
                            cp -R "$item" "${PROJECT_DIR}/public/application/files/" 2>/dev/null || true
                        fi
                    fi
                done
                
                # Verify some files were copied and set proper permissions
                FILE_COUNT=$(find "${PROJECT_DIR}/public/application/files" -type f 2>/dev/null | wc -l | tr -d ' ')
                if [ "$FILE_COUNT" -eq 0 ]; then
                    print_warning "No files found after copy - checking source directory"
                    echo "Source directory contents:"
                    ls -la "${FILES_TEMP_DIR}" | head -20
                    echo "Target directory contents:"
                    ls -la "${PROJECT_DIR}/public/application/files" | head -20
                else
                    echo "  Copied ${FILE_COUNT} files to ${PROJECT_DIR}/public/application/files"
                    # Set proper permissions (readable by web server)
                    chmod -R u+rw "${PROJECT_DIR}/public/application/files" 2>/dev/null || true
                    find "${PROJECT_DIR}/public/application/files" -type d -exec chmod 755 {} \; 2>/dev/null || true
                    find "${PROJECT_DIR}/public/application/files" -type f -exec chmod 644 {} \; 2>/dev/null || true
                    echo "  Set proper file permissions"
                fi
            else
                print_warning "No files found in Git repository to copy"
            fi
            
            echo "✓ Uploaded files synced via Git (images, documents, thumbnails)"
        fi
    else
        echo "Skipped uploaded files sync"
        print_warning "Uploaded images and files were NOT synced. You may need to sync them manually."
    fi
}

# Sync config files via Git (handles both push and pull)
# This syncs Concrete CMS configuration files (config/, themes/, blocks/, packages/, etc.)
pull_config_files() {
    print_step "Syncing config files via Git..."
    
    if [ -z "$FILES_GIT_REPO" ]; then
        echo "FILES_GIT_REPO not set - skipping config file sync via Git"
        return 0
    fi
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Push direction - push config files to Git
        echo "Pushing config files to Git..."
        
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
        # Pull direction - pull config files from Git
        local selected_tag="${1:-latest}"  # Tag to checkout, or "latest" for branch HEAD
        echo "Pulling config files from Git..."
        
        CONFIG_TEMP_DIR="${SCRIPT_DIR}/.config-git-temp"
        
        # Clean up and recreate
        if [ -d "${CONFIG_TEMP_DIR}" ]; then
            rm -rf "${CONFIG_TEMP_DIR}"
        fi
        
        mkdir -p "${CONFIG_TEMP_DIR}"
        cd "${CONFIG_TEMP_DIR}"
        git init
        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
        
        # Fetch including tags
        git fetch origin "${FILES_GIT_BRANCH}" "refs/tags/*:refs/tags/*"
        
        # Checkout based on tag or branch
        if [ "$selected_tag" = "latest" ]; then
            git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
            echo "  Using latest snapshot from branch: ${FILES_GIT_BRANCH}"
        else
            git checkout "${selected_tag}"
            echo "  Using snapshot tag: ${selected_tag}"
        fi
        
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
    # Parse command-line arguments - direction is REQUIRED
    if [ $# -eq 0 ]; then
        print_error "Direction argument is required"
        echo ""
        echo "Usage: $0 [push|pull]"
        echo ""
        echo "  push  - Push files/database from current environment to Git"
        echo "  pull  - Pull files/database from Git to current environment"
        echo ""
        echo "Use --help for more information"
        exit 1
    fi
    
    case "$1" in
        push|pull)
            SYNC_DIRECTION="$1"
            ;;
        -h|--help)
            echo "Usage: $0 [push|pull]"
            echo ""
            echo "  push  - Push files/database from current environment to Git"
            echo "  pull  - Pull files/database from Git to current environment"
            echo ""
            echo "The direction argument is REQUIRED."
            exit 0
            ;;
        *)
            print_error "Invalid argument: $1"
            print_error "Usage: $0 [push|pull]"
            print_error "Use --help for more information"
            exit 1
            ;;
    esac
    
    # Validate direction value
    if [ "$SYNC_DIRECTION" != "push" ] && [ "$SYNC_DIRECTION" != "pull" ]; then
        print_error "SYNC_DIRECTION must be 'push' or 'pull', got: ${SYNC_DIRECTION}"
        exit 1
    fi
    
    # Setup file descriptor 3 to duplicate stderr for database pull
    exec 3>&2
    
    # Check prerequisites first (needed to load config values for banner)
    check_prerequisites
    
    # Print deployment plan banner
    print_deployment_plan "$SYNC_DIRECTION"
    
    # Confirmation prompt
    echo -e "${YELLOW}WARNING: This will modify your site data!${NC}"
    echo ""
    read -p "Do you want to proceed with the above plan? (yes/no): " -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Deployment cancelled by user."
        exit 0
    fi
    
    echo ""
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        print_step "Pushing files and database to Git (direction: push)"
    else
        print_step "Pulling files and database from Git (direction: pull)"
    fi
    
    # Setup Git credential caching to avoid multiple prompts
    if [ -n "$FILES_GIT_REPO" ]; then
        setup_git_credentials
    fi
    
    # On pull, select snapshot tag first
    SELECTED_TAG="latest"
    if [ "$SYNC_DIRECTION" = "pull" ]; then
        SELECTED_TAG=$(select_snapshot_tag "${FILES_GIT_REPO}" "${FILES_GIT_BRANCH}")
        echo ""
        echo "Selected snapshot: ${SELECTED_TAG}"
        echo ""
    fi
    
    # Handle file syncing - always use Git
    if [ -n "$FILES_GIT_REPO" ]; then
        if [ "$SYNC_DIRECTION" = "pull" ]; then
            pull_config_files "${SELECTED_TAG}"  # Pass selected tag
        else
            pull_config_files  # Push doesn't need tag
        fi
    else
        print_error "FILES_GIT_REPO must be set in .deployment-config"
        exit 1
    fi
    
    # Optionally pull/push uploaded files (function handles both directions)
    if [ "$SYNC_DIRECTION" = "pull" ]; then
        pull_uploaded_files "${SELECTED_TAG}"  # Pass selected tag
    else
        pull_uploaded_files  # Push doesn't need tag
    fi
    
    # Install dependencies (only when pulling)
    if [ "$SYNC_DIRECTION" = "pull" ]; then
        install_dependencies
    fi
    
    # Handle database sync - always use Git
    if [ "$SYNC_DATABASE" = "auto" ]; then
        if [ -z "$FILES_GIT_REPO" ]; then
            print_error "FILES_GIT_REPO must be set for database sync"
            exit 1
        fi
        
        if [ "$SYNC_DIRECTION" = "push" ]; then
            # Push direction - export and push to Git
            export_production_database_to_git
            echo "  Database pushed to Git - run 'pull' on target environment to import"
        else
            # Pull direction - pull from Git and import
            print_step "Syncing database from Git..."
            # Call function - errors go to stderr (visible), file path to stdout (captured)
            DB_FILE=$(pull_database_from_git "${SELECTED_TAG}" 2>&3)
            EXIT_CODE=$?
            # Restore stderr
            exec 3>&2
            # Trim only trailing newlines/carriage returns from the captured path (preserve spaces in path)
            DB_FILE=$(printf '%s' "$DB_FILE" | sed 's/[\r\n]*$//')
            
            if [ $EXIT_CODE -eq 0 ] && [ -n "$DB_FILE" ]; then
                # Verify file exists
                if [ ! -f "$DB_FILE" ]; then
                    print_error "Database file path returned but file not found: '${DB_FILE}'"
                    print_error "File path length: ${#DB_FILE}"
                    print_error "Directory exists: $([ -d "$(dirname "$DB_FILE" 2>/dev/null)" ] && echo 'yes' || echo 'no')"
                    print_error "Directory contents:"
                    ls -la "$(dirname "$DB_FILE" 2>/dev/null)" 2>/dev/null || echo "Cannot list directory"
                    return 1
                fi
                import_database "${DB_FILE}"
            else
                if [ $EXIT_CODE -ne 0 ]; then
                    print_error "Failed to pull database from Git (exit code: $EXIT_CODE)"
                elif [ -z "$DB_FILE" ]; then
                    print_error "Failed to pull database from Git - no file path returned"
                    print_error "Captured output was empty or whitespace only"
                fi
                return 1
            fi
        fi
    else
        echo "Database sync disabled (SYNC_DATABASE=skip)"
    fi
    
    # Clear caches (only when pulling)
    if [ "$SYNC_DIRECTION" = "pull" ]; then
        clear_caches
    fi
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Create a single unified snapshot tag after all push operations complete
        print_step "Creating unified snapshot tag..."
        # Use a temp directory to create the tag on the remote
        TAG_TEMP_DIR="${SCRIPT_DIR}/.tag-create-temp"
        if [ -d "${TAG_TEMP_DIR}" ]; then
            rm -rf "${TAG_TEMP_DIR}"
        fi
        mkdir -p "${TAG_TEMP_DIR}"
        cd "${TAG_TEMP_DIR}"
        git init >/dev/null 2>&1
        git remote add origin "${FILES_GIT_REPO}" >/dev/null 2>&1 || git remote set-url origin "${FILES_GIT_REPO}" >/dev/null 2>&1
        git fetch origin "${FILES_GIT_BRANCH}" >/dev/null 2>&1
        git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" >/dev/null 2>&1 || git checkout "${FILES_GIT_BRANCH}" >/dev/null 2>&1
        
        # Create unified tag (not type-specific, just "snapshot")
        TAG_NAME=$(create_snapshot_tag "snapshot")
        if [ -n "$TAG_NAME" ]; then
            echo "✓ Created unified snapshot tag: ${TAG_NAME}"
        fi
        
        cd - >/dev/null 2>&1
        rm -rf "${TAG_TEMP_DIR}"
        
        if [ "$SYNC_DATABASE" = "auto" ]; then
            print_step "Files and database pushed to Git - run 'pull' on target environment to complete sync"
        else
            print_step "Files pushed to Git - run 'pull' on target environment to complete sync"
        fi
    else
        print_step "Sync completed successfully! Files and database pulled from Git"
    fi
}

# Run main function
main "$@"

