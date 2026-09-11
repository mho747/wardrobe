# Self-hosting Wardrobe

Wardrobe is designed to keep personal wardrobe data and model-reference images outside the Git repository and outside the application image.

## Security model

The public configuration is intentionally conservative:

- the web service binds to `127.0.0.1` by default;
- secrets live only in the local `.env` file;
- personal data lives only in the configured data directory;
- the application container uses a read-only root filesystem;
- Linux capabilities are dropped and `no-new-privileges` is enabled;
- backups and update state use separate persistent directories;
- an application rollback does not overwrite the user-data directory.

Do not expose port `4173` directly to the public internet. If remote access is required, place Wardrobe behind an authenticated HTTPS reverse proxy or zero-trust access layer and keep the application port private.

## Docker setup

```bash
git clone https://github.com/mho747/wardrobe.git
cd wardrobe
cp .env.example .env
mkdir -p data backups update-state candidates
```

Add a local `OPENAI_API_KEY` to `.env` and add your own `data/model-reference.png`. These files are ignored by Git.

Start the stack:

```bash
docker compose up -d --build
```

By default, Wardrobe is available only from the same host at `http://127.0.0.1:4173`.

## Persistent paths

The public defaults use repository-relative directories:

```dotenv
WARDROBE_DATA_HOST_PATH=./data
WARDROBE_BACKUP_HOST_PATH=./backups
WARDROBE_UPDATE_STATE_HOST_PATH=./update-state
WARDROBE_CANDIDATES_ROOT=./candidates
```

For a NAS or server, override these values locally with paths appropriate for that system. Do not commit machine-specific absolute paths.

## Trusted LAN access

If access from other devices on a trusted LAN is required, set `WARDROBE_BIND_ADDRESS` in the local `.env` to the server's LAN address. Keep that value out of Git and do not use `0.0.0.0` unless you fully understand the exposure created by doing so.

## Backups

The `wardrobe-backup` service reads the data directory and writes compressed backups into the configured backup directory. Retention is controlled by:

```dotenv
BACKUP_INTERVAL_SECONDS=86400
BACKUP_RETENTION_DAYS=30
```

Backups can contain personal images and wardrobe metadata. Protect the backup directory with the same care as the live data directory.

## Update checks

The `wardrobe-update-check` service checks the configured GitHub repository and branch and records update status. It does not need access to the Docker socket and does not install an update by itself.

## Secrets

`OPENAI_API_KEY` and the optional `OPENAI_ADMIN_API_KEY` must remain server-side. Never put them in browser code, screenshots, issues, logs, Docker image layers, or commits.

The optional admin key is only for the read-only Costs view. Prefer a separate credential with the minimum permissions required for that use case.

## Public repository hygiene

The repository ignores `.env`, `data/`, `backups/`, `update-state/`, and `candidates/`. Before publishing a fork, also inspect Git history for any secrets, photos, private hostnames, LAN addresses, or absolute machine-specific paths that may have been committed previously.
