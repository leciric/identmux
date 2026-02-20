# identmux

Stateless interactive identity multiplexer for development environments.

Maps filesystem project directories to user identities and SSH authentication keys. Configure once, rerun anytime.

## Quick start

```bash
# Interactive setup
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash

# Reapply existing configuration
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash -s -- --apply

# Load config from URL
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash -s -- --config https://example.com/my-config.yaml

# Preview changes without writing
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash -s -- --dry-run

# Export current config
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash -s -- --export

# Update git remote URLs in existing repos
curl -fsSL https://raw.githubusercontent.com/leciric/identmux/main/identmux.sh | bash -s -- --update-remotes
```

Or run directly:

```bash
./identmux.sh
./identmux.sh --apply
./identmux.sh --update-remotes
./identmux.sh --dry-run
```

## What it does

identmux maps:

```
filesystem path  ->  identity  ->  SSH key + git user
```

For example:

```
~/company/*   -> work identity     (work email, work SSH key)
~/personal/*  -> personal identity (personal email, personal SSH key)
```

When applied, identmux:

1. **Generates SSH keys** (ed25519) for each identity if they don't exist
2. **Writes SSH host aliases** to `~/.ssh/config` so different keys route to the same host
3. **Configures Git `includeIf`** directives in `~/.gitconfig` so repos under mapped paths automatically use the correct name and email
4. **Writes URL rewrite rules** into each per-identity gitconfig so that `git clone git@github.com:org/repo` or `git clone https://github.com/org/repo` automatically routes to the correct SSH alias when run inside a mapped directory — no manual remote editing required
5. **Optionally updates existing repo remotes** to point to the correct SSH alias for their directory's identity

All managed sections are delimited with markers and are fully idempotent — rerunning overwrites only the managed blocks.

## Configuration

Config file: `~/.config/identmux/config.yaml`

```yaml
version: 1
default: personal

identities:
  personal:
    name: "John Doe"
    email: "john@personal.com"
    ssh_key: "~/.ssh/id_ed25519_personal"
    hosts:
      - github.com
      - gitlab.com
    paths:
      - "~/personal"
      - "~/oss"

  work:
    name: "John Doe"
    email: "john@company.com"
    ssh_key: "~/.ssh/id_ed25519_work"
    hosts:
      - github.com
      - gitlab.com
      - git.internal.company.com
    paths:
      - "~/company"
      - "~/projects/client-work"
```

## Managed files

| File | What identmux writes |
|---|---|
| `~/.config/identmux/config.yaml` | Full config (source of truth) |
| `~/.ssh/config` | SSH `Host` aliases with `IdentityFile` directives |
| `~/.gitconfig` | `includeIf` directives + default `[user]` block |
| `~/.config/identmux/gitconfig-*` | Per-identity `[user]` name/email + URL rewrite rules |
| `~/.ssh/id_ed25519_*` | Generated SSH keys (only if missing) |

All modifications to `~/.ssh/config` and `~/.gitconfig` are wrapped in managed block delimiters:

```
# >>> identmux managed start >>>
...
# <<< identmux managed end <<<
```

Content outside these blocks is never touched.

## SSH host aliases

For each identity, identmux creates an SSH host alias:

```
Host github.com-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
    IdentitiesOnly yes
```

The **default identity** also gets a plain `Host github.com` entry.

Non-default identities are accessed exclusively through their alias — you never need to reference the alias directly, since URL rewriting handles it automatically (see below).

If identmux detects an existing `Host github.com` definition outside its managed block, it will print a warning — that entry may shadow or conflict with identity routing.

## Automatic host rewriting

For non-default identities, identmux writes URL rewrite rules directly into the per-identity gitconfig:

```ini
[url "git@github.com-work:"]
    insteadOf = git@github.com:
    insteadOf = https://github.com/
```

These rules are loaded by Git only when a repo sits under a mapped directory (via `includeIf`). The result is fully automatic identity routing:

```bash
cd ~/company
git clone git@github.com:org/repo.git   # routes to git@github.com-work: automatically
git clone https://github.com/org/repo   # also routes to the work SSH alias
```

No manual remote editing or alias usage is required. Git rewrites the host before SSH sees it, so the correct key is used transparently.

## Git identity routing

identmux uses Git's native `includeIf` mechanism. For each identity's mapped paths, it adds:

```ini
[includeIf "gitdir:~/company/"]
    path = ~/.config/identmux/gitconfig-work
```

Any repo under `~/company/` will automatically use the work identity's name, email, and SSH key for all Git operations.

## Modes

| Flag | Description |
|---|---|
| *(none)* | Interactive wizard (or menu if config exists) |
| `--apply` | Reapply existing config non-interactively |
| `--config <url>` | Fetch config from URL and apply |
| `--export` | Print config to stdout |
| `--update-remotes` | Update git remote URLs in existing repos to match SSH aliases |
| `--dry-run` | Preview all changes without writing |
| `--help` | Show usage |
| `--version` | Print version |

### Interactive menu

When a config already exists and you run `./identmux.sh` without flags, you are presented with a menu:

1. Reapply existing configuration
2. Overwrite with new configuration
3. Edit interactively (re-run wizard)
4. Show current configuration
5. Update git remotes in existing repositories

### Updating existing repo remotes

When you run `--update-remotes` (or choose option 5 from the menu, or answer yes to the prompt shown after a fresh `--apply`), identmux:

- Walks every directory configured under each identity's `paths`
- Finds all git repositories (direct subdirectories with a `.git/` folder)
- Checks every remote in each repo for URLs matching a configured host
- Computes the correct SSH URL for the repo's identity:
  - Default identity → `git@github.com:user/repo.git`
  - Other identities → `git@github.com-work:user/repo.git`
- Shows a summary of all proposed changes and asks for a single confirmation before applying

Handles both SSH (`git@host:`) and HTTPS (`https://host/`) source URLs, and normalizes them all to SSH. Supports `--dry-run` to preview without making changes.

## Requirements

- Bash 4+
- `ssh-keygen` (for key generation)
- `git` (optional — Git config integration is skipped if not present)
- `curl` (for remote execution / `--config`)

## Design principles

- **Stateless**: No daemon, no background process, no installation
- **Declarative**: Config file is the source of truth
- **Idempotent**: Safe to rerun — same input produces same output
- **Non-destructive**: Only modifies managed blocks; existing config is preserved
- **Portable**: Works on any system with Bash 4+ and OpenSSH

## License

MIT
