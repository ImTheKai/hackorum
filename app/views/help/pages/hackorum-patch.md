# Applying Patches with hackorum-patch

The `hackorum-patch` script is a standalone Ruby tool that downloads patches from Hackorum topics and applies them to your local PostgreSQL repository. It automates the tedious process of manually downloading, extracting, and applying patch series.

## Download

<a href="/scripts/hackorum-patch" download class="download-link">Download hackorum-patch</a>

Or install directly to `~/bin` using curl:

```bash
mkdir -p ~/bin && curl -o ~/bin/hackorum-patch https://hackorum.dev/scripts/hackorum-patch && chmod +x ~/bin/hackorum-patch
```

If `~/bin` is not already in your PATH, add it to your shell configuration (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
export PATH="$HOME/bin:$PATH"
```

## Requirements

- **Ruby** (2.7 or later) - The script is written in Ruby and uses only standard library modules
- **Git** - Required for branch/worktree management and applying patches

Check if Ruby is installed:

```bash
ruby --version
```

If Ruby is not installed, you can install it using your system's package manager:

```bash
# Debian/Ubuntu
sudo apt install ruby

# Fedora
sudo dnf install ruby

# macOS (using Homebrew)
brew install ruby
```

## Quick Start

From within a git checkout of the PostgreSQL repository, apply patches from a Hackorum topic with a single command:

```bash
hackorum-patch <topic_id>
```

For example, if you're reviewing topic #12345:

```bash
hackorum-patch 12345
```

This downloads the latest patchset from the topic, detects the appropriate base commit, creates a `review/t12345` branch, and applies all patches.

## How It Works

When you run `hackorum-patch`, it performs the following steps:

1. **Downloads the patchset** - Fetches the latest patches from the topic as a tar.gz archive
2. **Extracts patches** - Unpacks the archive to a temporary directory
3. **Detects the base commit** - Analyzes the patch index entries (the "before" hashes in `index abc123..def456` lines) and uses `git log --find-object` to find where those blobs exist in your local history
4. **Creates a branch or worktree** - Sets up an isolated environment for reviewing the patches
5. **Applies patches** - Uses `git am --3way` to apply each patch as a proper commit, preserving author information and commit messages

## Recommended Workflow: Using Worktrees

For the best experience reviewing PostgreSQL patches, we recommend using **git worktrees**. This approach lets you:

- Keep your main checkout on `master` for quick lookups and reference
- Review multiple patch series simultaneously in separate directories
- Avoid constantly switching branches and recompiling

### First-Time Setup

If you haven't cloned the PostgreSQL repository yet, or want to set up a fresh review environment:

```bash
# Clone PostgreSQL to a directory that will serve as your "main" checkout
git clone https://github.com/postgres/postgres.git ~/postgres/master

# Navigate to the repo
cd ~/postgres/master

# Your first use of hackorum-patch with --worktree=yes
# (replace <topic_id> with the actual topic ID you want to review)
hackorum-patch <topic_id> --worktree=yes
```

This creates a worktree at `~/postgres/review/t<topic_id>` (a sibling directory to your main checkout).

### Directory Structure

After setting up a few review worktrees, your directory structure will look like:

```
~/postgres/
├── master/             # Main checkout (stays on master)
└── review/
    ├── t12345/         # Worktree for topic 12345
    ├── t12346/         # Worktree for topic 12346
    └── t12400/         # Worktree for topic 12400
```

### Subsequent Reviews

Once you have at least one worktree, `hackorum-patch` automatically detects your worktree setup and creates new worktrees in the same parent directory:

```bash
cd ~/postgres/master
hackorum-patch <topic_id>  # Automatically creates ~/postgres/review/t<topic_id>
```

The script detects existing worktrees and uses the same parent directory (`~/postgres/review/`) for consistency.

### After Applying Patches

```bash
# Navigate to the worktree
cd ~/postgres/review/t<topic_id>

# Build and test
./configure --enable-debug --enable-cassert
make -j8
make check
```

### Cleaning Up

When you're done reviewing a patchset:

```bash
# Remove the worktree
cd ~/postgres/master
git worktree remove ~/postgres/review/t<topic_id>

# Optionally delete the branch too
git branch -D review/t<topic_id>
```

## Using Local Archives

If you've already downloaded a patchset (or want to apply patches from a local file), you can pass the archive path instead of a topic ID:

```bash
hackorum-patch ~/Downloads/topic-12345-patchset.tar.gz
```

The script extracts the topic ID from the filename if it matches the pattern `topic-XXXX-patchset.tar.gz`.

## Command Reference

```
Usage: hackorum-patch <topic_id|archive.tar.gz> [<branch_name>] [OPTIONS]

Arguments:
  topic_id          Topic ID from Hackorum (numeric)
  archive.tar.gz    Local patchset archive file
  branch_name       Custom branch name (optional, default: review/tXXXX)

Options:
  --force                   Overwrite existing branch/worktree
  --base-commit=COMMIT      Specify base commit (default: auto-detect)
  --worktree=MODE           Worktree mode: yes, no, auto (default: auto)
  --worktree-path=PATH      Specify worktree location
  --server=URL              Server URL (default: https://hackorum.dev)
  -h, --help                Show help message
  -v, --version             Show version number
```

### Option Details

| Option | Description |
|--------|-------------|
| `--force` | Deletes and recreates the branch/worktree if it already exists |
| `--base-commit=COMMIT` | Manually specify the base commit instead of auto-detection. Useful when you want to apply patches to a specific point in history |
| `--worktree=yes` | Always create a worktree (even if none exist yet) |
| `--worktree=no` | Never use worktrees; create a regular branch instead |
| `--worktree=auto` | Auto-detect based on existing worktrees (default) |
| `--worktree-path=PATH` | Override the default worktree location |
| `--server=URL` | Use a different Hackorum server |

## Troubleshooting

### Patch conflicts

If a patch fails to apply cleanly, the script will stop and show instructions:

```
[FAIL] Failed to apply 0002-Add-feature.patch

You can resolve conflicts and continue with:
  cd /path/to/worktree
  git am --continue

Or abort with:
  git am --abort
```

After resolving conflicts in the affected files, stage them with `git add` and run `git am --continue`.

### Branch already exists

Use `--force` to overwrite an existing branch:

```bash
hackorum-patch <topic_id> --force
```

### Working directory has uncommitted changes

In branch mode (non-worktree), the script requires a clean working directory. Either commit or stash your changes:

```bash
git stash
hackorum-patch <topic_id>
git stash pop
```

Or use worktree mode, which doesn't require a clean checkout:

```bash
hackorum-patch <topic_id> --worktree=yes
```
