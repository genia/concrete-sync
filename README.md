# Concrete CMS Deployment Sync Tools

Tools for syncing Concrete CMS sites between any environments using Git as the intermediary.

## Overview

This toolkit provides scripts to synchronize Concrete CMS sites between any environments using Git for all file transfers. The script is designed for seamless migration between environments - whether that's production to development, development back to production, migrating from one production server to another, or any other environment-to-environment transfer. All syncing operations are bidirectional and use Git exclusively, eliminating the need for direct SSH file transfers.

## Features

- **Bidirectional syncing** - Push from any environment to Git, pull from Git to any environment
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
   - `SITE_PATH` - Path to your Concrete CMS site root (required)
   - `FILES_GIT_REPO` - Git repository URL for syncing files (required)
   - Database credentials for the current environment
   - Other sync settings

3. **Run the sync script:**
   ```bash
   # Push current environment's data to Git
   ./concrete-cms-sync.sh push
   
   # Pull data from Git to current environment
   ./concrete-cms-sync.sh pull
   ```

## Scripts

### `concrete-cms-sync.sh`

Main bidirectional sync script. Handles both pushing data to Git and pulling data from Git.

**Usage:**
```bash
./concrete-cms-sync.sh [push|pull]
```

**Push mode** (run on the source environment):
- Exports database to Git
- Pushes uploaded files to Git
- Pushes config files (config/, themes/, blocks/, packages/) to Git
- Creates a unified snapshot tag

**Pull mode** (run on the target environment):
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
./backup-database.sh
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

The script works seamlessly between any environments. Here are common scenarios:

### Environment A → Environment B

1. On source environment:
   ```bash
   ./concrete-cms-sync.sh push
   ```
   This exports the database, pushes files and config to Git, and creates a snapshot tag.

2. On target environment:
   ```bash
   ./concrete-cms-sync.sh pull
   ```
   Select a snapshot (or use latest), and the script will pull everything and import it.

### Any Environment → Any Environment

The script is environment-agnostic. You can:
- Push from any environment to Git
- Pull from Git to any environment
- Migrate between any two environments using Git as the intermediary
- Create snapshots at any point for rollback or migration purposes

## Requirements

- Bash 3.2+
- Git
- MySQL client (`mysql`, `mysqldump`)
- rsync
- PHP with Composer (or `composer.phar`)

## For Complete Details

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed deployment instructions, component descriptions, and advanced configuration.
