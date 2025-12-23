# Concrete CMS Deployment Sync Tools

Tools for syncing Concrete CMS sites between development and production environments using Git as the intermediary.

## Overview

This toolkit provides scripts to synchronize Concrete CMS sites between environments (development and production) using Git for all file transfers. All syncing operations are bidirectional and use Git exclusively, eliminating the need for direct SSH file transfers.

## Features

- **Bidirectional syncing** - Push from production to Git, pull from Git to development (or vice versa)
- **Git-based file transfer** - All files (uploaded files, config files, database dumps) synced via Git
- **Snapshot tagging** - Automatic tagging of complete site snapshots for easy restoration
- **Incremental updates** - Only changed files are transferred using rsync
- **Database syncing** - Export/import MySQL databases with proper handling
- **Composer integration** - Automatic dependency installation
- **Interactive tag selection** - Choose specific snapshots or use latest

## Quick Start

1. **Copy the example config file:**
   ```bash
   cp .deployment-config.example .deployment-config
   ```

2. **Edit `.deployment-config`** with your settings:
   - `ENVIRONMENT` - Set to `prod` on production server, `dev` on development machine
   - `SITE_PATH` - Path to your Concrete CMS site root
   - `FILES_GIT_REPO` - Git repository URL for syncing files
   - Database credentials
   - Other sync settings

3. **Run the sync script:**
   ```bash
   # Push from production to Git
   ./concrete-cms-sync.sh push
   
   # Pull from Git to development
   ./concrete-cms-sync.sh pull
   ```

## Scripts

### `concrete-cms-sync.sh`

Main bidirectional sync script. Handles both pushing data to Git and pulling data from Git.

**Usage:**
```bash
./concrete-cms-sync.sh [push|pull]
```

**Push mode** (typically run on production):
- Exports database to Git
- Pushes uploaded files to Git
- Pushes config files (config/, themes/, blocks/, packages/) to Git
- Creates a unified snapshot tag

**Pull mode** (typically run on development):
- Prompts for snapshot selection (latest or specific tag)
- Pulls database from Git and imports it
- Pulls uploaded files from Git
- Pulls config files from Git
- Installs Composer dependencies
- Clears caches

### `backup-database.sh`

Simple database backup script.

**Usage:**
```bash
./backup-database.sh [dev|prod]
```

Creates a compressed database backup in the current directory.

### `setup-files-git.sh`

Initial setup script for configuring Git repository for file syncing.

**Usage:**
```bash
./setup-files-git.sh
```

## Configuration

All configuration is done via `.deployment-config`. See `.deployment-config.example` for all available options.

### Key Configuration Variables

- `ENVIRONMENT` - `prod` or `dev` (required)
- `SITE_PATH` - Path to Concrete CMS site root (required)
- `FILES_GIT_REPO` - Git repository URL for syncing (required)
- `FILES_GIT_BRANCH` - Git branch to use (default: `main`)
- `SYNC_DATABASE` - `auto` to sync database, `skip` to skip (default: `auto`)
- `SYNC_UPLOADED_FILES` - `auto` to sync files, `skip` to skip (default: `auto`)
- `COMPOSER_DIR` - Directory containing `composer.phar` (if not in PATH)

## How It Works

1. **Git as Intermediary**: All data (files, database dumps, config) is stored in a Git repository
2. **Snapshot Tags**: Each complete sync creates a unified tag (`snapshot-YYYY-MM-DD_HH-MM-SS`) marking a point-in-time snapshot
3. **Incremental Syncs**: Uses rsync to only transfer files that have changed
4. **Bidirectional**: Same script handles both directions based on the `push`/`pull` argument

## Deployment Workflow

### Production → Development

1. On production server:
   ```bash
   ./concrete-cms-sync.sh push
   ```
   This exports the database, pushes files and config to Git, and creates a snapshot tag.

2. On development machine:
   ```bash
   ./concrete-cms-sync.sh pull
   ```
   Select a snapshot (or use latest), and the script will pull everything and import it.

### Development → Production

1. On development machine:
   ```bash
   ./concrete-cms-sync.sh push
   ```
   (Note: This pushes to Git, but typically you'd pull from production, not push to it)

2. On production server:
   ```bash
   ./concrete-cms-sync.sh pull
   ```
   Select a snapshot and pull the changes.

## Requirements

- Bash 3.2+
- Git
- MySQL client (`mysql`, `mysqldump`)
- rsync
- PHP with Composer (or `composer.phar`)

## For Complete Details

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed deployment instructions, component descriptions, and advanced configuration.
