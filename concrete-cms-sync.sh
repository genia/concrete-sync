#!/bin/bash

# Concrete CMS Deployment Script: Bidirectional Sync via Git
# This script syncs data between any environments using Git as the intermediary
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
UNIFIED_TEMP_DIR="${SCRIPT_DIR}/.unified-temp"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Default values (can be overridden by .deployment-config or environment variables)
# SITE_PATH is the path to the Concrete CMS site root (where composer.json, public/, etc. are)
SITE_PATH=""  # REQUIRED: e.g., /var/www/html or /home/user/site
SYNC_UPLOADED_FILES="auto"  # Options: auto, ask, skip
FILES_GIT_REPO=""  # REQUIRED: e.g., git@github.com:user/files-repo.git
FILES_GIT_BRANCH="main"  # Branch to use for files
SYNC_DATABASE="auto"  # Options: auto, skip
COMPOSER_DIR=""  # Directory containing composer.phar (e.g., /usr/local/bin or /opt/composer)
SYNC_DIRECTION=""  # Will be set from command-line argument: "push" or "pull"
# DB credentials will be loaded from .deployment-config
# Uses database credentials from the current environment's .deployment-config

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
DB_HOSTNAME="${DB_HOSTNAME:-}"
DB_DATABASE="${DB_DATABASE:-}"
DB_USERNAME="${DB_USERNAME:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_EXCLUDE_TABLES="${DB_EXCLUDE_TABLES:-}"  # Space-separated list of tables to exclude
DB_EXCLUDE_TABLES="${DB_EXCLUDE_TABLES:-}"  # Space-separated list of tables to exclude

# Set composer command
if [ -n "$COMPOSER_DIR" ]; then
    COMPOSER_CMD="php ${COMPOSER_DIR}/composer.phar"
else
    # Fallback to system composer if COMPOSER_DIR not set
    COMPOSER_CMD="composer"
fi

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
    echo -e "${YELLOW}Warning: $1${NC}" >&2
}

print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
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
            if [ -n "${DB_EXCLUDE_TABLES:-}" ]; then
                echo "  ⊘ Excluding tables: ${DB_EXCLUDE_TABLES}"
            fi
            echo "  ✓ Push database to Git repository"
        else
            echo "  ⊘ Skip database sync (SYNC_DATABASE=skip)"
        fi
        echo "  ✓ Push application/ directory (config, themes, blocks, packages, express, etc.) to Git"
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
        echo "  ✓ Pull application/ directory (config, themes, blocks, packages, express, etc.) from Git"
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
    
    print_step "Fetching available snapshot tags..." >&2
    
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
    # All output except final selected tag goes to stderr
    echo "  Fetching tags from ${repo_url}..." >&2
    # First fetch the branch
    git fetch origin "${branch}" >/dev/null 2>&1 || true
    # Then fetch all tags - use the correct refspec format with force flag
    if ! git fetch origin "+refs/tags/*:refs/tags/*" >/dev/null 2>&1; then
        print_warning "Could not fetch tags from repository" >&2
        print_warning "Will use latest from branch instead" >&2
        echo "latest"  # Return "latest" as fallback (stdout only)
        cd - >/dev/null 2>&1
        rm -rf "${temp_dir}"
        return 0
    fi
    
    # Get list of all tags, sorted by date (newest first)
    # Show all tags (not just snapshot-*) to support both old and new formats
    local tags=$(git tag -l 2>/dev/null | sort -r | head -20)  # Show last 20 tags
    
    # If no tags found locally, try fetching from remote directly
    if [ -z "$tags" ] || [ -z "$(echo "$tags" | tr -d '[:space:]')" ]; then
        echo "  Checking remote tags directly..." >&2
        local remote_tags=$(git ls-remote --tags origin 2>/dev/null | sed 's|.*refs/tags/||' | grep -v '\^{}$' | sort -r | head -20)
        if [ -n "$remote_tags" ] && [ -n "$(echo "$remote_tags" | tr -d '[:space:]')" ]; then
            local remote_count=$(echo "$remote_tags" | grep -v '^$' | wc -l | tr -d ' ')
            echo "  Found ${remote_count} tag(s) on remote, fetching..." >&2
            # Fetch each tag individually using process substitution to avoid subshell
            while IFS= read -r tag; do
                tag=$(echo "$tag" | tr -d '[:space:]')  # Remove whitespace
                if [ -n "$tag" ]; then
                    git fetch origin "refs/tags/${tag}:refs/tags/${tag}" >/dev/null 2>&1 || true
                fi
            done < <(echo "$remote_tags")
            # Get tags again after fetching
            tags=$(git tag -l 2>/dev/null | sort -r | head -20)
        fi
    fi
    
    # Convert tags to array for proper iteration (do this before checking count)
    local tag_array=()
    if [ -n "$tags" ] && [ -n "$(echo "$tags" | tr -d '[:space:]')" ]; then
        # Use process substitution to avoid subshell issues
        while IFS= read -r tag; do
            # Trim whitespace
            tag=$(echo "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$tag" ]; then
                tag_array+=("$tag")
            fi
        done < <(echo "$tags")
    fi
    
    # Check if tags were found using array length
    local tag_count=${#tag_array[@]}
    
    # If no tags in array, try direct git command as fallback
    if [ "$tag_count" -eq 0 ]; then
        echo "  No tags found in initial fetch, trying direct git command..." >&2
        local direct_tags=$(git tag -l 2>/dev/null)
        if [ -n "$direct_tags" ] && [ -n "$(echo "$direct_tags" | tr -d '[:space:]')" ]; then
            echo "  Found tags via direct command, adding to array..." >&2
            # Try to use direct tags
            while IFS= read -r tag; do
                tag=$(echo "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ -n "$tag" ]; then
                    tag_array+=("$tag")
                fi
            done < <(echo "$direct_tags")
            tag_count=${#tag_array[@]}
            echo "  After fallback, tag_count: ${tag_count}" >&2
        fi
    else
        echo "  Found ${tag_count} tag(s)" >&2
    fi
    
    # Change back to original directory before cleanup
    cd - >/dev/null 2>&1
    
    # Re-check array count after directory change (arrays should persist, but verify)
    tag_count=${#tag_array[@]}
    
    if [ "$tag_count" -eq 0 ]; then
        rm -rf "${temp_dir}"
        echo "" >&2
        echo "No snapshot tags found in repository." >&2
        echo "" >&2
        echo "This could mean:" >&2
        echo "  - No snapshots have been pushed yet (run 'push' first to create tags)" >&2
        echo "  - Tags exist but weren't fetched (check repository access)" >&2
        echo "" >&2
        echo "Using latest from branch instead." >&2
        echo "" >&2
        echo -n "Press Enter to continue with latest, or Ctrl+C to cancel... " >&2
        read -r
        echo "" >&2
        echo "latest"  # Only this goes to stdout
        return 0
    fi
    
    rm -rf "${temp_dir}"
    
    local page_size=10
    local current_page=0
    local start_idx=0
    local end_idx=$((page_size - 1))
    
    # Display tags with paging
    # NOTE: All menu output goes to stderr since stdout is captured by the caller
    while true; do
        echo "" >&2
        echo "Available snapshots:" >&2
        echo "  0) latest (most recent from branch)" >&2
        
        # Display current page of tags
        local display_count=0
        for ((i=$start_idx; i<=$end_idx && i<$tag_count; i++)); do
            local tag_num=$((i + 1))
            local tag_value="${tag_array[$i]}"
            if [ -n "$tag_value" ]; then
                echo "  ${tag_num}) ${tag_value}" >&2
                display_count=$((display_count + 1))
            fi
        done
        
        # Show paging info
        local total_pages=$(( (tag_count + page_size - 1) / page_size ))
        local current_page_num=$((current_page + 1))
        if [ $total_pages -gt 1 ]; then
            echo "" >&2
            echo "Page ${current_page_num} of ${total_pages} (showing tags $((start_idx + 1))-$((end_idx + 1 > tag_count ? tag_count : end_idx + 1)) of ${tag_count})" >&2
            if [ $end_idx -lt $((tag_count - 1)) ]; then
                echo "Press Enter to see more tags, or enter a number to select" >&2
            else
                echo "Press Enter to go back to first page, or enter a number to select" >&2
            fi
        fi
        echo "" >&2
        
        # Prompt user (prompt to stderr, read from stdin/terminal)
        echo -n "Select snapshot to use (0 for latest, or number): " >&2
        read selection
        
        # Handle empty input (paging)
        if [ -z "$selection" ]; then
            if [ $end_idx -lt $((tag_count - 1)) ]; then
                # Show next page
                current_page=$((current_page + 1))
                start_idx=$((start_idx + page_size))
                end_idx=$((end_idx + page_size))
                if [ $end_idx -ge $tag_count ]; then
                    end_idx=$((tag_count - 1))
                fi
                continue
            else
                # Wrap around to first page
                current_page=0
                start_idx=0
                end_idx=$((page_size - 1))
                continue
            fi
        fi
        
        # Handle selection
        if [ "$selection" = "0" ] || [ "$selection" = "latest" ]; then
            echo "latest"
            return 0
        elif [ -n "$selection" ] && [ "$selection" -ge 1 ] && [ "$selection" -le "$tag_count" ] 2>/dev/null; then
            # Get the selected tag from array (array is 0-indexed, selection is 1-indexed)
            local selected_tag="${tag_array[$((selection - 1))]}"
            if [ -n "$selected_tag" ]; then
                echo "$selected_tag"
                return 0
            else
                print_error "Could not find tag at position ${selection}"
            fi
        else
            print_error "Invalid selection. Please enter 0 for latest or a number from 1 to ${tag_count}."
        fi
    done
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
    
    
    command -v mysql >/dev/null 2>&1 || { print_error "mysql client is required but not installed"; exit 1; }
    
    # rsync is required for efficient file syncing
    command -v rsync >/dev/null 2>&1 || { print_error "rsync is required but not installed"; exit 1; }
    
    # FILES_GIT_REPO is required (we use Git exclusively)
            if [ -z "$FILES_GIT_REPO" ]; then
                print_error "FILES_GIT_REPO must be set in .deployment-config"
        print_error "This script uses Git exclusively for all syncing operations"
                exit 1
            fi
            
    # Set path (behavior is controlled by push/pull argument)
    echo "✓ Site path: ${SITE_PATH}"
    
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

# Export database (legacy function, kept for compatibility)
export_database() {
    print_step "Exporting database..."
    
    mkdir -p "${DB_BACKUP_DIR}"
    DB_FILE="${DB_BACKUP_DIR}/db_${TIMESTAMP}.sql"
    
    # DB credentials are already loaded from .deployment-config in check_prerequisites
    # Uses database credentials from the current environment's .deployment-config
    
    echo "Exporting database..."
    
    # Use DB credentials from .deployment-config
        echo "  Host: ${DB_HOSTNAME}"
        echo "  Database: ${DB_DATABASE}"
        echo "  User: ${DB_USERNAME}"
    mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" | gzip > "${DB_FILE}.gz"
    
    echo "✓ Database exported to ${DB_FILE}.gz"
    echo "${DB_FILE}.gz"
}

# Import database
import_database() {
    print_step "Importing database..."
    
    if [ -z "$1" ]; then
        print_error "Database file path required"
        return 1
    fi
    
    DB_FILE="$1"
    
    # DB credentials already loaded from .deployment-config in check_prerequisites
    # Uses database credentials from the current environment's .deployment-config
    
    print_warning "Importing database - this will REPLACE your database!"
    echo "  Source: ${DB_FILE}"
    echo "  Target: ${DB_HOSTNAME}/${DB_DATABASE}"
    echo ""
    echo "This will drop all existing tables and import fresh data from the database dump."
    
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
    IMPORT_ERROR=0
    if [[ "$DB_FILE" == *.gz ]]; then
        # Use set -o pipefail to catch errors from any command in the pipeline
        set +e  # Don't exit on error
        gunzip -c "${DB_FILE}" | mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" 2>&1
        IMPORT_ERROR=$?
        set -e
    else
        set +e
        mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" < "${DB_FILE}" 2>&1
        IMPORT_ERROR=$?
        set -e
    fi
    
    if [ "$IMPORT_ERROR" -eq 0 ]; then
        echo "✓ Database imported successfully"
        
        # Verify import by checking if key tables exist
        echo "Verifying database import..."
        TABLE_COUNT=$(mysql -h"${DB_HOSTNAME}" -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DB_DATABASE}';" \
            -s -N 2>/dev/null || echo "0")
        
        if [ "$TABLE_COUNT" -gt "0" ]; then
            echo "✓ Database verification: ${TABLE_COUNT} table(s) found"
        else
            print_warning "Database import completed but no tables found - this may indicate an issue"
        fi
    else
        print_error "Database import failed (exit code: ${IMPORT_ERROR})"
        return 1
    fi
}


# Install dependencies
install_dependencies() {
    print_step "Installing dependencies..."
    
    # Change to site directory (important: may have been in temp directories)
    cd "${SITE_PATH}" || { print_error "Cannot change to SITE_PATH: ${SITE_PATH}"; return 1; }
    
    # Install Composer dependencies
    ${COMPOSER_CMD} install
    
    echo "✓ Dependencies installed"
}

# Fix common post-sync issues (Doctrine proxies, bootstrap files, etc.)
fix_site_issues() {
    print_step "Fixing common post-sync issues..."
    
    local fixed_anything=false
    
    # Detect structure: check for public/application first (composer structure), then application (flat)
    local app_path=""
    if [ -d "${SITE_PATH}/public/application" ]; then
        app_path="${SITE_PATH}/public/application"
    elif [ -d "${SITE_PATH}/application" ]; then
        app_path="${SITE_PATH}/application"
    fi
    
    if [ -n "$app_path" ]; then
        # Ensure proxies directory exists and is writable (required for orm:generate-proxies)
        mkdir -p "${app_path}/config/doctrine/proxies"
        chmod 775 "${app_path}/config/doctrine/proxies" 2>/dev/null || true
        # Also ensure parent directories are writable
        chmod 775 "${app_path}/config/doctrine" 2>/dev/null || true
        chmod 775 "${app_path}/config" 2>/dev/null || true
        
        # Regenerate bootstrap directory if missing (required for Concrete CMS)
        if [ ! -d "${app_path}/bootstrap" ] || [ ! -f "${app_path}/bootstrap/autoload.php" ]; then
            echo "  Regenerating bootstrap/ directory..."
            mkdir -p "${app_path}/bootstrap"
            
            # Detect vendor location (composer structure vs flat structure)
            local vendor_path=""
            if [ -d "${SITE_PATH}/vendor" ]; then
                vendor_path="../../../vendor"
            elif [ -d "${SITE_PATH}/concrete/vendor" ]; then
                vendor_path="../../concrete/vendor"
            else
                vendor_path="../../../vendor"  # Default fallback
            fi
            
            # Create autoload.php
            cat > "${app_path}/bootstrap/autoload.php" << 'BOOTSTRAP_AUTOLOAD'
<?php

defined('C5_EXECUTE') or die('Access Denied.');

# Load in the composer vendor files
# For flat structure: vendor is at concrete/vendor/
# For public/ structure: vendor is at ../../../vendor/ (from public/application/bootstrap/)
# Try flat structure first, then fall back to public structure
if (file_exists(__DIR__ . "/../../concrete/vendor/autoload.php")) {
    require_once __DIR__ . "/../../concrete/vendor/autoload.php";
    $vendor_path = __DIR__ . "/../../concrete/vendor";
} else {
    require_once __DIR__ . "/../../../vendor/autoload.php";
    $vendor_path = __DIR__ . "/../../../vendor";
}

# Try loading in environment info
try {
    (new \Symfony\Component\Dotenv\Dotenv('CONCRETE5_ENV'))
        ->usePutenv()->load(__DIR__ . '/../../../.env');
} catch (\Symfony\Component\Dotenv\Exception\PathException $e) {
    // Ignore missing file exception
}

# Add the vendor directory to the include path
ini_set('include_path', $vendor_path . PATH_SEPARATOR . get_include_path());
BOOTSTRAP_AUTOLOAD
            
            # Create app.php (custom application handler - can be customized)
            cat > "${app_path}/bootstrap/app.php" << 'BOOTSTRAP_APP'
<?php

/* @var Concrete\Core\Application\Application $app */
/* @var Concrete\Core\Console\Application $console only set in CLI environment */

/*
 * ----------------------------------------------------------------------------
 * # Custom Application Handler
 *
 * You can customize this file to add custom routes, bindings, events, etc.
 * ----------------------------------------------------------------------------
 */
BOOTSTRAP_APP
            
            # Create start.php (instantiates Concrete CMS application)
            cat > "${app_path}/bootstrap/start.php" << 'BOOTSTRAP_START'
<?php

use Concrete\Core\Application\Application;

/*
 * ----------------------------------------------------------------------------
 * Instantiate Concrete
 * ----------------------------------------------------------------------------
 */
$app = new Application();

/*
 * ----------------------------------------------------------------------------
 * Detect the environment based on the hostname of the server
 * ----------------------------------------------------------------------------
 */
$app->detectEnvironment([
    'local' => [
        'hostname',
    ],
    'production' => [
        'live.site',
    ],
]);

return $app;
BOOTSTRAP_START
            
            fixed_anything=true
        fi
    fi
    
    # Clear caches and regenerate Doctrine proxies
    if [ -f "${SITE_PATH}/vendor/bin/concrete" ] || [ -f "${SITE_PATH}/concrete/vendor/bin/concrete" ]; then
        cd "${SITE_PATH}"
        echo "  Clearing caches..."
        # Try concrete/vendor first (flat structure), then vendor (composer structure)
        if [ -f "concrete/vendor/bin/concrete" ]; then
            CONCRETE_CMD="./concrete/vendor/bin/concrete"
        else
            CONCRETE_CMD="./vendor/bin/concrete"
        fi
        
        $CONCRETE_CMD c5:clear-cache 2>/dev/null || true
        fixed_anything=true
        
        # Clear Doctrine caches (can cause stale page references and dashboard menu issues)
        echo "  Clearing Doctrine caches..."
        $CONCRETE_CMD orm:clear-cache:metadata 2>/dev/null || true
        $CONCRETE_CMD orm:clear-cache:query 2>/dev/null || true
        $CONCRETE_CMD orm:clear-cache:result 2>/dev/null || true
        
        # Generate Doctrine proxies for all entities (including Community Store and other packages)
        echo "  Regenerating Doctrine proxies..."
        if $CONCRETE_CMD orm:generate-proxies 2>/dev/null; then
            echo "  ✓ Doctrine proxies regenerated"
        else
            echo "  ⚠ Proxy generation may have failed - ensure proxies directory is writable by web server"
        fi
        
        # Update packages to re-register controllers (fixes dashboard menu and page controller issues)
        echo "  Updating packages to re-register controllers..."
        $CONCRETE_CMD c5:package:update --all --force 2>/dev/null || true
        
        # Reindex content to fix multilingual page controller mappings
        echo "  Reindexing content (fixes multilingual page controllers)..."
        $CONCRETE_CMD task:reindex-content 2>/dev/null || true
    fi
    
    if [ "$fixed_anything" = true ]; then
        echo "✓ Site issues fixed"
    else
        echo "✓ No issues found to fix"
    fi
}

# Clear caches
clear_caches() {
    print_step "Clearing caches..."
    
    # Ensure proxies directory exists and is writable (required for orm:generate-proxies)
    # Proxies are excluded from syncing (so they won't be synced with wrong paths)
    local proxies_dir=""
    if [ -d "${SITE_PATH}/public/application/config/doctrine" ]; then
        proxies_dir="${SITE_PATH}/public/application/config/doctrine/proxies"
    elif [ -d "${SITE_PATH}/application/config/doctrine" ]; then
        proxies_dir="${SITE_PATH}/application/config/doctrine/proxies"
    fi
    
    if [ -n "$proxies_dir" ]; then
        mkdir -p "$proxies_dir"
        chmod 775 "$proxies_dir" 2>/dev/null || true
        # Also ensure parent directories are writable
        chmod 775 "$(dirname "$proxies_dir")" 2>/dev/null || true
        chmod 775 "$(dirname "$(dirname "$proxies_dir")")" 2>/dev/null || true
    fi
    
    if [ -f "${SITE_PATH}/vendor/bin/concrete" ] || [ -f "${SITE_PATH}/concrete/vendor/bin/concrete" ]; then
        cd "${SITE_PATH}"
        # Try concrete/vendor first (flat structure), then vendor (composer structure)
        if [ -f "concrete/vendor/bin/concrete" ]; then
            CONCRETE_CMD="./concrete/vendor/bin/concrete"
        else
            CONCRETE_CMD="./vendor/bin/concrete"
        fi
        
        # Clear all caches (including page cache, dashboard menu cache, etc.)
        echo "  Clearing all caches..."
        $CONCRETE_CMD c5:clear-cache 2>/dev/null || true
        
        # Clear Doctrine caches (can cause stale page references and dashboard menu issues)
        echo "  Clearing Doctrine caches..."
        $CONCRETE_CMD orm:clear-cache:metadata 2>/dev/null || true
        $CONCRETE_CMD orm:clear-cache:query 2>/dev/null || true
        $CONCRETE_CMD orm:clear-cache:result 2>/dev/null || true
    fi
    
    echo "✓ Caches cleared"
}

# Update packages to re-register controllers and single pages after database sync
update_packages() {
    print_step "Updating packages to re-register controllers..."
    
    if [ -f "${SITE_PATH}/vendor/bin/concrete" ] || [ -f "${SITE_PATH}/concrete/vendor/bin/concrete" ]; then
        cd "${SITE_PATH}"
        # Try concrete/vendor first (flat structure), then vendor (composer structure)
        if [ -f "concrete/vendor/bin/concrete" ]; then
            CONCRETE_CMD="./concrete/vendor/bin/concrete"
        else
            CONCRETE_CMD="./vendor/bin/concrete"
        fi
        
        # Update all installed packages to re-register their controllers and single pages
        # This is important after a database sync to ensure controllers are properly registered
        echo "  Updating all packages..."
        $CONCRETE_CMD c5:package:update --all --force 2>/dev/null || true
        
        # Reindex content to fix multilingual page controller mappings
        # This can fix issues where multilingual pages exist but their controllers aren't found
        echo "  Reindexing content (fixes multilingual page controllers)..."
        $CONCRETE_CMD task:reindex-content 2>/dev/null || true
        
        echo "✓ Packages updated and content reindexed"
    fi
}

# Main sync flow
main() {
    # Parse command-line arguments - direction is REQUIRED
    if [ $# -eq 0 ]; then
        print_error "Command argument is required"
        echo ""
        echo "Usage: $0 [push|pull|fix]"
        echo ""
        echo "  push  - Push files/database from current environment to Git"
        echo "  pull  - Pull files/database from Git to current environment"
        echo "  fix   - Fix common post-sync issues (Doctrine proxies, bootstrap files, caches)"
        echo ""
        echo "Use --help for more information"
        exit 1
    fi
    
    case "$1" in
        push|pull)
            SYNC_DIRECTION="$1"
            ;;
        fix)
            # Fix mode: just fix issues, no syncing
            # Note: This assumes package files are already synced. If you're seeing
            # controller errors, run 'pull' first to sync package files from Git.
            check_prerequisites
            fix_site_issues
            exit 0
            ;;
        -h|--help)
        echo "Usage: $0 [push|pull|fix]"
            echo ""
            echo "  push  - Push files/database from current environment to Git"
            echo "  pull  - Pull files/database from Git to current environment"
        echo "  fix   - Fix common post-sync issues (Doctrine proxies, bootstrap files, caches)"
        echo "         Note: Assumes package files are already synced. For controller errors,"
        echo "         run 'pull' first to sync package files from Git."
            echo ""
        echo "The command argument is REQUIRED."
            exit 0
            ;;
        *)
            print_error "Invalid argument: $1"
            print_error "Usage: $0 [push|pull|fix]"
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
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Push mode: Add all components (config, files, database) to one commit, then push once
        print_step "Preparing unified snapshot for Git..."
        
        if [ -z "$FILES_GIT_REPO" ]; then
        print_error "FILES_GIT_REPO must be set in .deployment-config"
        exit 1
    fi
    
        # Create single unified temp directory for all push operations
        UNIFIED_TEMP_DIR="${SCRIPT_DIR}/.unified-push-temp"
        if [ -d "${UNIFIED_TEMP_DIR}" ]; then
            rm -rf "${UNIFIED_TEMP_DIR}"
        fi
        mkdir -p "${UNIFIED_TEMP_DIR}"
        cd "${UNIFIED_TEMP_DIR}"
        git init
        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
        
        # Fetch and checkout existing branch
        git fetch origin "${FILES_GIT_BRANCH}" 2>/dev/null || true
        if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}" 2>/dev/null; then
            git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
        else
            git checkout -b "${FILES_GIT_BRANCH}"
        fi
        
        # 1. Add config files (application/ and packages/)
        if [ -d "${SITE_PATH}/public/application" ]; then
            echo "  Adding application/ directory..."
            mkdir -p "${UNIFIED_TEMP_DIR}/application"
            rsync -av \
                --exclude='files' \
                --exclude='cache' \
                --exclude='node_modules' \
                --exclude='**/node_modules' \
                --exclude='config/doctrine/proxies' \
                --exclude='bootstrap/' \
                --exclude='.git/objects' \
                --exclude='.git/packed-refs' \
                --exclude='.git/index' \
                --exclude='.git/logs' \
                --exclude='.git/hooks' \
                --exclude='.git/info' \
                --include='.git/config' \
                --include='.git/HEAD' \
                --include='.git/refs/remotes/origin/**' \
                --include='.git/refs/heads/**' \
                --exclude='.git/**' \
                "${SITE_PATH}/public/application/" "${UNIFIED_TEMP_DIR}/application/" 2>/dev/null || true
        fi
        
        if [ -d "${SITE_PATH}/public/packages" ]; then
            echo "  Adding packages/ directory..."
            mkdir -p "${UNIFIED_TEMP_DIR}/packages"
            rsync -av \
                --exclude='node_modules' \
                --exclude='**/node_modules' \
                --exclude='cache' \
                --exclude='config/doctrine/proxies' \
                --exclude='.git/objects' \
                --exclude='.git/packed-refs' \
                --exclude='.git/index' \
                --exclude='.git/logs' \
                --exclude='.git/hooks' \
                --exclude='.git/info' \
                --include='.git/config' \
                --include='.git/HEAD' \
                --include='.git/refs/remotes/origin/**' \
                --include='.git/refs/heads/**' \
                --exclude='.git/**' \
                "${SITE_PATH}/public/packages/" "${UNIFIED_TEMP_DIR}/packages/" 2>/dev/null || true
        fi
        
        # 2. Add uploaded files (if not skipping)
        if [ "$SYNC_UPLOADED_FILES" != "skip" ]; then
            local sync_files="y"
            if [ "$SYNC_UPLOADED_FILES" = "ask" ]; then
                read -p "Do you want to sync uploaded files (images, documents)? (y/n) " -n 1 -r
                echo
                sync_files="$REPLY"
            fi
            
            if [[ $sync_files =~ ^[Yy]$ ]]; then
                echo "  Adding uploaded files..."
                mkdir -p "${UNIFIED_TEMP_DIR}/files"
                if [ -d "${SITE_PATH}/public/application/files" ]; then
                    rsync -av \
                        --exclude='database' \
                        --exclude='cache' \
                        --exclude='.git' \
                        "${SITE_PATH}/public/application/files/" "${UNIFIED_TEMP_DIR}/files/" 2>/dev/null || true
                fi
            fi
        fi
        
        # 3. Add database (if not skipping)
    if [ "$SYNC_DATABASE" = "auto" ]; then
            echo "  Adding database..."
            mkdir -p "${UNIFIED_TEMP_DIR}/database"
            DB_FILE="database/db_${TIMESTAMP}.sql.gz"
            
            # Build mysqldump command with table exclusions if specified
            MYSQLDUMP_CMD="mysqldump --no-tablespaces --single-transaction --set-gtid-purged=OFF"
            
            # Add --ignore-table for each excluded table
            if [ -n "$DB_EXCLUDE_TABLES" ]; then
                echo "  Excluding tables: ${DB_EXCLUDE_TABLES}"
                for table in $DB_EXCLUDE_TABLES; do
                    MYSQLDUMP_CMD="${MYSQLDUMP_CMD} --ignore-table=${DB_DATABASE}.${table}"
                done
            else
                echo "  Including all tables (no exclusions)"
            fi
            
            MYSQLDUMP_CMD="${MYSQLDUMP_CMD} -h\"${DB_HOSTNAME}\" -u\"${DB_USERNAME}\" -p\"${DB_PASSWORD}\" \"${DB_DATABASE}\""
            
            echo "  Exporting database..."
            # Run mysqldump, capture stderr separately, pipe stdout to gzip
            DUMP_ERRORS=$(mktemp)
            set +e  # Don't exit on error temporarily
            eval "${MYSQLDUMP_CMD}" 2>"${DUMP_ERRORS}" | gzip > "${UNIFIED_TEMP_DIR}/${DB_FILE}"
            DUMP_EXIT_CODE=${PIPESTATUS[0]}
            set -e
            
            # Check for errors
            if [ $DUMP_EXIT_CODE -ne 0 ]; then
                print_error "Database export failed (exit code: ${DUMP_EXIT_CODE})"
                if [ -s "${DUMP_ERRORS}" ]; then
                    echo "Error details:"
                    cat "${DUMP_ERRORS}"
                fi
                rm -f "${DUMP_ERRORS}"
                exit 1
            fi
            
            # Show any warnings (but don't fail)
            if [ -s "${DUMP_ERRORS}" ]; then
                echo "  Warnings from mysqldump:"
                cat "${DUMP_ERRORS}"
            fi
            rm -f "${DUMP_ERRORS}"
            
            # Verify the dump was created and has content
            if [ -f "${UNIFIED_TEMP_DIR}/${DB_FILE}" ] && [ -s "${UNIFIED_TEMP_DIR}/${DB_FILE}" ]; then
                DUMP_SIZE=$(du -h "${UNIFIED_TEMP_DIR}/${DB_FILE}" | cut -f1)
                # Count tables in the dump for verification
                TABLE_COUNT=$(gunzip -c "${UNIFIED_TEMP_DIR}/${DB_FILE}" | grep -c "^CREATE TABLE" || echo "0")
                echo "  ✓ Database exported (${DUMP_SIZE}, ${TABLE_COUNT} tables)"
            else
                print_error "Database export failed: empty or missing file"
                exit 1
            fi
            ln -sf "db_${TIMESTAMP}.sql.gz" "${UNIFIED_TEMP_DIR}/database/latest.sql.gz" 2>/dev/null || \
                cp "${UNIFIED_TEMP_DIR}/${DB_FILE}" "${UNIFIED_TEMP_DIR}/database/latest.sql.gz"
        fi
        
        # 4. Single commit and push
        git add -A
        if ! git diff --staged --quiet; then
            git commit -m "Unified snapshot $(date +%Y-%m-%d\ %H:%M:%S)" || true
            if git show-ref --verify --quiet "refs/remotes/origin/${FILES_GIT_BRANCH}"; then
                git pull origin "${FILES_GIT_BRANCH}" --no-edit 2>/dev/null || true
            fi
            git push origin "HEAD:${FILES_GIT_BRANCH}" || git push -u origin "${FILES_GIT_BRANCH}"
            echo "✓ All components pushed to Git in single commit"
        else
            echo "No changes to sync"
        fi
        
        cd - >/dev/null 2>&1
    else
        # Pull mode: use unified structure (same as push)
        print_step "Pulling unified snapshot from Git..."
        
        if [ -z "$FILES_GIT_REPO" ]; then
            print_error "FILES_GIT_REPO must be set in .deployment-config"
            exit 1
        fi
        
        # Create unified temp directory for all pull operations
        if [ -d "${UNIFIED_TEMP_DIR}" ]; then
            rm -rf "${UNIFIED_TEMP_DIR}"
        fi
        mkdir -p "${UNIFIED_TEMP_DIR}"
        cd "${UNIFIED_TEMP_DIR}"
        git init
        git remote add origin "${FILES_GIT_REPO}" 2>/dev/null || git remote set-url origin "${FILES_GIT_REPO}"
        
        # Fetch including tags
        git fetch origin "${FILES_GIT_BRANCH}" "refs/tags/*:refs/tags/*" 2>/dev/null || true
        
        # Checkout based on tag or branch
        if [ "$SELECTED_TAG" = "latest" ]; then
            git checkout -b "${FILES_GIT_BRANCH}" "origin/${FILES_GIT_BRANCH}" 2>/dev/null || git checkout "${FILES_GIT_BRANCH}"
            echo "  Using latest snapshot from branch: ${FILES_GIT_BRANCH}"
        else
            git checkout "${SELECTED_TAG}"
            echo "  Using snapshot tag: ${SELECTED_TAG}"
        fi
        
        # Pull config files (application/ and packages/)
        if [ -d "${UNIFIED_TEMP_DIR}/application" ]; then
            echo "  Syncing application directory (config, themes, blocks, packages, express, etc.)..."
            rsync_output=$(rsync -av --stats \
                --exclude='files' \
                --exclude='cache' \
                --exclude='node_modules' \
                --exclude='**/node_modules' \
                --exclude='config/doctrine/proxies' \
                --exclude='bootstrap/' \
                --exclude='.git/objects' \
                --exclude='.git/packed-refs' \
                --exclude='.git/index' \
                --exclude='.git/logs' \
                --exclude='.git/hooks' \
                --exclude='.git/info' \
                --include='.git/config' \
                --include='.git/HEAD' \
                --include='.git/refs/remotes/origin/**' \
                --include='.git/refs/heads/**' \
                --exclude='.git/**' \
                "${UNIFIED_TEMP_DIR}/application/" "${SITE_PATH}/public/application/" 2>&1)
            files_transferred=$(echo "$rsync_output" | grep -E "(Number of regular files transferred|Number of files transferred)" | grep -oE "[0-9]+" | head -1 || echo "0")
            if [ -n "$files_transferred" ] && [ "$files_transferred" != "0" ] && [ "$files_transferred" != "" ]; then
                echo "  ✓ Application synced: ${files_transferred} file(s)"
            fi
        fi
        
        if [ -d "${UNIFIED_TEMP_DIR}/packages" ] && [ "$(ls -A "${UNIFIED_TEMP_DIR}/packages" 2>/dev/null)" ]; then
            echo "  Syncing packages directory..."
            mkdir -p "${SITE_PATH}/public/packages"
            rsync_output=$(rsync -av --stats \
                --exclude='node_modules' \
                --exclude='**/node_modules' \
                --exclude='cache' \
                --exclude='config/doctrine/proxies' \
                --exclude='.git/objects' \
                --exclude='.git/packed-refs' \
                --exclude='.git/index' \
                --exclude='.git/logs' \
                --exclude='.git/hooks' \
                --exclude='.git/info' \
                --include='.git/config' \
                --include='.git/HEAD' \
                --include='.git/refs/remotes/origin/**' \
                --include='.git/refs/heads/**' \
                --exclude='.git/**' \
                "${UNIFIED_TEMP_DIR}/packages/" "${SITE_PATH}/public/packages/" 2>&1)
            files_transferred=$(echo "$rsync_output" | grep -E "(Number of regular files transferred|Number of files transferred)" | grep -oE "[0-9]+" | head -1 || echo "0")
            if [ -n "$files_transferred" ] && [ "$files_transferred" != "0" ] && [ "$files_transferred" != "" ]; then
                echo "  ✓ Packages synced: ${files_transferred} file(s)"
            fi
        fi
        
        # Pull uploaded files (from files/ subdirectory)
        if [ "$SYNC_UPLOADED_FILES" != "skip" ]; then
            local sync_files="y"
            if [ "$SYNC_UPLOADED_FILES" = "ask" ]; then
                read -p "Do you want to sync uploaded files (images, documents)? (y/n) " -n 1 -r
                echo
                sync_files="$REPLY"
            fi
            
            if [[ $sync_files =~ ^[Yy]$ ]]; then
                if [ -d "${UNIFIED_TEMP_DIR}/files" ]; then
                    echo "  Syncing uploaded files..."
                    mkdir -p "${SITE_PATH}/public/application/files"
                    rsync_output=$(rsync -av --stats \
                        --exclude='database' \
                        --exclude='cache' \
                        --exclude='.git' \
                        "${UNIFIED_TEMP_DIR}/files/" "${SITE_PATH}/public/application/files/" 2>&1)
                    files_transferred=$(echo "$rsync_output" | grep -E "(Number of regular files transferred|Number of files transferred)" | grep -oE "[0-9]+" | head -1 || echo "0")
                    files_created=$(echo "$rsync_output" | grep -E "Number of created files" | grep -oE "[0-9]+" | head -1 || echo "0")
                    files_deleted=$(echo "$rsync_output" | grep -E "Number of deleted files" | grep -oE "[0-9]+" | head -1 || echo "0")
                    
                    if [ -n "$files_transferred" ] && [ "$files_transferred" != "0" ] && [ "$files_transferred" != "" ]; then
                        echo "  ✓ Files synced: ${files_transferred} file(s) transferred"
                        if [ -n "$files_created" ] && [ "$files_created" != "0" ] && [ "$files_created" != "" ]; then
                            echo "    New files: ${files_created} file(s) created"
                        fi
                        if [ -n "$files_deleted" ] && [ "$files_deleted" != "0" ] && [ "$files_deleted" != "" ]; then
                            echo "    Removed files: ${files_deleted} file(s) deleted"
                        fi
                    else
                        echo "  ✓ Files are up to date (no changes needed)"
                    fi
                    
                    # Set proper permissions
                    chmod -R u+rw "${SITE_PATH}/public/application/files" 2>/dev/null || true
                    find "${SITE_PATH}/public/application/files" -type d -exec chmod 755 {} \; 2>/dev/null || true
                    find "${SITE_PATH}/public/application/files" -type f -exec chmod 644 {} \; 2>/dev/null || true
                else
                    echo "  ⊘ No files directory found in snapshot"
                fi
            fi
        fi
        
        # Install dependencies
        install_dependencies
        
        # Handle database sync
        if [ "$SYNC_DATABASE" = "auto" ]; then
            if [ -d "${UNIFIED_TEMP_DIR}/database" ]; then
                # Find the latest database file
                if [ -f "${UNIFIED_TEMP_DIR}/database/latest.sql.gz" ]; then
                    DB_FILE="${UNIFIED_TEMP_DIR}/database/latest.sql.gz"
                elif [ -n "$(find "${UNIFIED_TEMP_DIR}/database" -name "db_*.sql.gz" -type f 2>/dev/null | head -1)" ]; then
                    DB_FILE=$(find "${UNIFIED_TEMP_DIR}/database" -name "db_*.sql.gz" -type f | sort -r | head -1)
                else
                    print_error "No database file found in snapshot"
                    exit 1
                fi
                
                if [ -f "$DB_FILE" ]; then
                    import_database "${DB_FILE}"
                else
                    print_error "Database file not found: ${DB_FILE}"
                    exit 1
                fi
            else
                print_error "No database directory found in snapshot"
                exit 1
            fi
    else
        echo "Database sync disabled (SYNC_DATABASE=skip)"
    fi
    
        cd - >/dev/null 2>&1
        rm -rf "${UNIFIED_TEMP_DIR}"
    fi
    
    # Clear caches and update packages (only when pulling)
    if [ "$SYNC_DIRECTION" = "pull" ]; then
        clear_caches
        update_packages
    fi
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Create a single unified snapshot tag on the commit we just pushed
        print_step "Creating unified snapshot tag..."
        # Use the unified temp directory which has the commit we just pushed
        if [ -d "${UNIFIED_TEMP_DIR}" ] && [ -d "${UNIFIED_TEMP_DIR}/.git" ]; then
            cd "${UNIFIED_TEMP_DIR}"
            # Create unified tag on current HEAD (the commit we just pushed)
            TAG_NAME=$(create_snapshot_tag "snapshot")
            if [ -n "$TAG_NAME" ]; then
                echo "✓ Created unified snapshot tag: ${TAG_NAME}"
            fi
            cd - >/dev/null 2>&1
            # Keep temp directory for inspection (will be cleaned up on next push)
            echo ""
            echo "Snapshot directory kept at: ${UNIFIED_TEMP_DIR}"
            echo "  - Database dump: ${UNIFIED_TEMP_DIR}/database/"
            echo "  - Run 'gunzip -c ${UNIFIED_TEMP_DIR}/database/latest.sql.gz | grep TABLE' to inspect"
        else
            # Fallback: create tag in fresh checkout
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
            TAG_NAME=$(create_snapshot_tag "snapshot")
            if [ -n "$TAG_NAME" ]; then
                echo "✓ Created unified snapshot tag: ${TAG_NAME}"
            fi
            cd - >/dev/null 2>&1
            rm -rf "${TAG_TEMP_DIR}"
        fi
        
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

