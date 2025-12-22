# Concrete CMS Deployment Guide

This guide covers the reliable way to transfer your Concrete CMS site between development and production environments.

## Overview

Concrete CMS has several components that need special handling during deployment:

1. **Code files** - Tracked in Git (with exclusions)
2. **Composer dependencies** - Installed via `composer install`
3. **Concrete CMS core** - Installed via Composer (excluded from Git)
4. **Database** - Must be exported/imported separately
5. **Uploaded files** - Stored in `public/application/files` (excluded from Git)
6. **Built assets** - CSS/JS compiled from source
7. **Environment configuration** - `.env` file (excluded from Git)

## What's Excluded from Git

Based on `.gitignore` files, the following are excluded:

- `/vendor/` - Composer dependencies
- `/public/concrete` - Concrete CMS core
- `/public/application/files` - User-uploaded files
- `/node_modules` - NPM dependencies
- `/.env` - Environment configuration
- Build artifacts (compiled CSS/JS)
- Database config files
- Cache files

## Deployment Methods

### Method 1: Automated Scripts (Recommended)

We provide two deployment scripts:

#### Deploy to Production (`deploy-to-production.sh`)

This script handles:
- Database export from dev
- Asset building
- File synchronization via rsync
- Composer dependency installation on server
- Optional database import to production
- Cache clearing

**Setup:**
1. Edit `deploy-to-production.sh` and configure:
   - `REMOTE_HOST` - Your production server SSH address
   - `REMOTE_PATH` - Path to your site on the server

2. Make the script executable:
   ```bash
   chmod +x deploy-to-production.sh
   ```

3. Run the deployment:
   ```bash
   ./deploy-to-production.sh
   ```

#### Sync from Production (`deploy-from-production.sh`)

This script pulls production data back to dev:
- Pulls code files from production
- Exports production database
- Imports to local development database
- Installs dependencies
- Syncs uploaded files (optional)

**Setup:**
1. Edit `deploy-from-production.sh` and configure:
   - `REMOTE_HOST` - Your production server SSH address
   - `REMOTE_PATH` - Path to your site on the server

2. Make the script executable:
   ```bash
   chmod +x deploy-from-production.sh
   ```

3. Run the sync:
   ```bash
   ./deploy-from-production.sh
   ```

### Method 2: Manual Deployment

If you prefer manual control or the scripts don't fit your setup:

#### Step 1: Prepare Development Environment

```bash
# Build assets
npm run prod

# Export database
mysqldump -u[user] -p[database] > backup.sql
```

#### Step 2: Deploy Code

```bash
# Push code via Git
git push origin main

# On production server, pull and install dependencies
git pull origin main
composer install --no-dev --optimize-autoloader
npm install && npm run prod
```

#### Step 3: Deploy Database

**Option A: Direct Import (if you have SSH access)**
```bash
# On production server
mysql -u[user] -p[database] < backup.sql
```

**Option B: Via phpMyAdmin or Database Tool**
- Export from dev database
- Import to production database

**Important:** Before importing, you may need to:
- Update URLs in the database (Concrete stores absolute URLs)
- Update file paths if they differ
- Clear caches after import

#### Step 4: Sync Uploaded Files

```bash
# Sync files directory
rsync -avz public/application/files/ user@production:/path/to/site/public/application/files/
```

#### Step 5: Configure Environment

On production, create `.env` file with production database credentials:
```bash
cp .env.example .env
# Edit .env with production values
```

#### Step 6: Clear Caches

```bash
./vendor/bin/concrete c5:clear-cache
```

### Method 3: Using Git + Composer (Recommended for Teams)

This is the most reliable long-term approach:

#### Initial Setup

1. **Ensure everything important is tracked:**
   ```bash
   # Check what's being ignored
   git status --ignored
   ```

2. **Create environment templates:**
   - `.env.example` (already created)
   - Document any custom config files

3. **Use Composer for all dependencies:**
   - Concrete CMS core is installed via Composer
   - All packages should be in `composer.json`

#### Deployment Workflow

**Development:**
```bash
# Make changes
git add .
git commit -m "Your changes"
git push
```

**Production:**
```bash
# Pull latest code
git pull origin main

# Install/update dependencies
composer install --no-dev --optimize-autoloader

# Build assets
npm install && npm run prod

# Clear caches
./vendor/bin/concrete c5:clear-cache

# Run migrations if needed
./vendor/bin/concrete c5:migrate
```

## Database Migration Best Practices

### Exporting Database

```bash
# Full export
mysqldump -u[user] -p[database] > backup.sql

# Compressed export (recommended)
mysqldump -u[user] -p[database] | gzip > backup.sql.gz
```

### Importing Database

```bash
# Regular import
mysql -u[user] -p[database] < backup.sql

# Compressed import
gunzip -c backup.sql.gz | mysql -u[user] -p[database]
```

### Important Notes

1. **URL Updates:** After importing, you may need to update URLs:
   ```sql
   UPDATE Config SET configValue = 'https://production-domain.com' WHERE configKey = 'site.url';
   ```

2. **File Paths:** Ensure file paths match between environments

3. **Clear Caches:** Always clear caches after database import:
   ```bash
   ./vendor/bin/concrete c5:clear-cache
   ```

## Handling Uploaded Files

**Yes, uploaded images are covered!** The deployment scripts handle uploaded files stored in `public/application/files/`.

### What Gets Synced

The `public/application/files` directory contains:
- **User-uploaded images** (photos, graphics, etc.)
- **User-uploaded documents** (PDFs, Word docs, etc.)
- **Generated thumbnails** (created by Concrete CMS)
- **File manager content** (all files uploaded through the CMS)

### Automatic Sync Behavior

Both deployment scripts include uploaded file syncing. You can control the behavior by setting `SYNC_UPLOADED_FILES` in the script:

```bash
# In deploy-to-production.sh or deploy-from-production.sh
SYNC_UPLOADED_FILES="ask"  # Options: auto, ask, skip
```

- **`ask`** (default) - Prompts you each time whether to sync files
- **`auto`** - Always syncs files automatically without prompting
- **`skip`** - Never syncs files (useful if you use a CDN or separate file storage)

### Transfer Method

For uploaded files, you can choose between three transfer methods:

```bash
# In deploy-to-production.sh or deploy-from-production.sh
UPLOADED_FILES_METHOD="git"  # Options: git, zip, rsync
```

- **`git`** (default) - Uses a Git repository as intermediary. **Best of both worlds:**
  - Fast incremental syncs (only changed files transferred)
  - Git's compression reduces transfer size
  - Version history of all file changes
  - Works efficiently in both directions
  - Handles large file sets well
  - Requires a Git repository (can be separate repo or branch)
  
  **Setup:** Configure `FILES_GIT_REPO` in the script:
  ```bash
  FILES_GIT_REPO="git@github.com:user/files-repo.git"  # Or any Git URL
  FILES_GIT_BRANCH="main"  # Branch to use
  ```

- **`zip`** - Creates a zip archive, transfers it, then extracts. Faster for large file sets because:
  - Single file transfer is more efficient than thousands of small files
  - Compression reduces transfer size
  - Less network overhead
  - Better for initial deployments or when many files have changed

- **`rsync`** - Direct incremental sync that only transfers changed files. Better when:
  - Only a few files have changed
  - You want to preserve file permissions exactly
  - You're doing frequent small updates
  - You don't want to set up a Git repository

### Setting Up Git Method

To use the Git method for file syncing:

**Option 1: Quick Setup (Recommended)**

Run the setup script:
```bash
./setup-files-git.sh
```

This will:
- Ask for your Git repository URL
- Initialize the repository
- Create/update `.deployment-config` file with your settings
- The deployment scripts will automatically load these settings

**Option 2: Manual Setup**

1. **Create a Git repository** (can be separate from your main code repo):
   ```bash
   # On GitHub/GitLab/etc, create a new repository
   # Then configure it in the scripts:
   ```

2. **Configure the scripts:**
   ```bash
   # In deploy-to-production.sh and deploy-from-production.sh
   FILES_GIT_REPO="git@github.com:user/files-repo.git"
   FILES_GIT_BRANCH="main"
   ```

3. **The scripts will automatically:**
   - Create temporary Git repos in `.files-git-temp/` directories
   - Commit and push files from source
   - Pull and extract files on destination
   - Only transfer changed files (Git's delta compression)

**Benefits:**
- Works in both directions seamlessly
- Only transfers what changed
- Full version history
- Can be shared across multiple environments
- Git's compression is very efficient

### Manual Sync

If you need to sync files manually:

```bash
# Dev to Production
rsync -avz --progress public/application/files/ user@production:/path/to/site/public/application/files/

# Production to Dev
rsync -avz --progress user@production:/path/to/site/public/application/files/ public/application/files/
```

### Important Notes

1. **File Size:** For large file sets, the sync may take time. The scripts use `--progress` to show transfer status.

2. **Thumbnails:** Thumbnails are included in the sync. If you want to exclude them (they can be regenerated), you can modify the rsync command to exclude the thumbnails directory.

3. **CDN/External Storage:** If you're using a CDN or external file storage (like S3), you may want to set `SYNC_UPLOADED_FILES="skip"` since files are stored elsewhere.

4. **First Deployment:** On first deployment, you'll definitely want to sync uploaded files to ensure all images are available on production.

5. **Database + Files:** Remember that uploaded files are referenced in the database. If you sync the database but not the files, you'll have broken image links. Always sync both together.

## Environment Configuration

### Development (.env)
```env
APP_ENV=local
APP_DEBUG=true
DB_HOSTNAME=localhost
DB_DATABASE=dev_database
```

### Production (.env)
```env
APP_ENV=production
APP_DEBUG=false
DB_HOSTNAME=production_host
DB_DATABASE=production_database
```

**Security:** Never commit `.env` files to Git!

## Troubleshooting

### Missing Files After Deployment

If files are missing after deployment:

1. **Check .gitignore:** Ensure important files aren't ignored
   ```bash
   git check-ignore -v path/to/file
   ```

2. **Verify Composer:** Ensure all packages are in `composer.json`
   ```bash
   composer show
   ```

3. **Check Build Process:** Ensure assets are built
   ```bash
   npm run prod
   ```

### Database Connection Issues

1. Verify `.env` file exists and has correct credentials
2. Check database server is accessible
3. Verify user permissions
4. Check firewall rules

### Cache Issues

Always clear caches after deployment:
```bash
./vendor/bin/concrete c5:clear-cache
```

## Recommended Workflow

1. **Development:**
   - Make changes locally
   - Test thoroughly
   - Commit to Git
   - Build assets (`npm run prod`)

2. **Staging (if available):**
   - Deploy to staging first
   - Test all functionality
   - Verify database migration

3. **Production:**
   - Export production database as backup
   - Deploy code
   - Import database (if needed)
   - Clear caches
   - Verify site is working

## Backup Strategy

**Before any deployment, always:**
1. Backup production database
2. Backup production files (if making significant changes)
3. Test deployment on staging first (if available)

**Automated backups:**
- Set up cron jobs for database backups
- Consider using Concrete CMS's built-in backup tools
- Store backups off-server

## Additional Resources

- [Concrete CMS Documentation](https://documentation.concretecms.org/)
- [Composer Documentation](https://getcomposer.org/doc/)
- [Concrete CMS Deployment Guide](https://documentation.concretecms.org/developers/installation/upgrading-concrete-cms)

