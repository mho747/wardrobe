<div align="center">

# Wardrobe

A local-first AI wardrobe gallery with private-by-default self-hosting, Docker backups, update checks, and rollback verification.

[![License: MIT](https://img.shields.io/badge/license-MIT-191919?style=flat-square)](LICENSE)
[![Node 22+](https://img.shields.io/badge/node-22%2B-191919?style=flat-square)](package.json)
[![CI](https://github.com/mho747/wardrobe/actions/workflows/ci.yml/badge.svg)](https://github.com/mho747/wardrobe/actions/workflows/ci.yml)

</div>

> This repository is a maintained fork of [tandpfun/wardrobe](https://github.com/tandpfun/wardrobe). The upstream project created the original Wardrobe experience and bundled Codex workflows. This fork keeps that foundation and adds a stronger self-hosting and operations layer.

![Wardrobe gallery](docs/screenshots/gallery.png)

![Modeled wardrobe editor](docs/screenshots/editor.png)

## What this fork adds

Alongside the upstream wardrobe and Codex workflows, this fork adds:

- Docker-based self-hosting with a read-only application filesystem and dropped Linux capabilities
- private-by-default networking (`127.0.0.1` unless the operator explicitly chooses otherwise)
- persistent user data outside the image and Git repository
- scheduled local backups with retention controls
- read-only GitHub update checks
- isolated candidate builds before an update is promoted
- verified application rollback without overwriting wardrobe data
- safer handling for large photo uploads and import-processing failures
- an optional server-side OpenAI Costs view that keeps admin credentials out of the browser

Personal wardrobes, reference photos, generated images, API keys, backups, and runtime state are intentionally excluded from Git.

## Quick start — local development

```bash
git clone https://github.com/mho747/wardrobe.git
cd wardrobe
npm install
cp .env.example .env
npm run dev
```

Add your own `OPENAI_API_KEY` to the local `.env` and place your own PNG reference image at `data/model-reference.png`. Neither file should ever be committed.

Open `http://localhost:5173`.

## Quick start — Docker

```bash
git clone https://github.com/mho747/wardrobe.git
cd wardrobe
cp .env.example .env
mkdir -p data backups update-state candidates
# Add your own data/model-reference.png and OPENAI_API_KEY locally.
docker compose up -d --build
```

The Docker configuration binds to `127.0.0.1:4173` by default. Change `WARDROBE_BIND_ADDRESS` only when you intentionally want the service reachable from a trusted network. Do not commit that local value.

See [Self-hosting](docs/SELF_HOSTING.md) for the security model, persistence, backups, updates, and rollback design.

## Import with Codex

This repo includes two Codex skills: one imports clothes and generates modeled item photos; the other styles complete outfits and generates a modeled lookbook.

```text
$import-clothes Import the clothes from ~/Pictures/outfits, create modeled photos, and add them to this wardrobe.
$generate-outfits Create modeled outfit ideas from my wardrobe.
```

The import workflow reads local source images, reviews generated outputs, then writes the user's library to `data/`. The outfit workflow curates items from that local library and stores generated looks under `data/` as well.

## What Wardrobe does

- Detects garments in source photos with the OpenAI Responses API
- Extracts product-style cutouts with the OpenAI Images API
- Generates optional modeled editorial previews
- Keeps originals, jobs, generated images, and the JSON database in the local data directory
- Supports drag, drop, paste, editing, review, regeneration, and approval

## Privacy and secrets

The public repository contains application code and generic configuration only. Runtime and personal material is excluded through `.gitignore` and `.dockerignore`, including:

- `.env` and other local environment files
- `data/`
- `backups/`
- `update-state/`
- `candidates/`

Keep API keys server-side. The optional `OPENAI_ADMIN_API_KEY` is intended only for the read-only Costs view and must never be sent to the browser or committed to Git.

## Configuration

| Variable | Default / purpose |
| --- | --- |
| `OPENAI_API_KEY` | Required for imports; local secret |
| `OPENAI_ADMIN_API_KEY` | Optional server-only key for the Costs view |
| `OPENAI_COSTS_PROJECT_ID` | Optional project scope for the Costs view |
| `OPENAI_VISION_MODEL` | `gpt-5.4-mini` |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2` |
| `OPENAI_IMAGE_QUALITY` | `high` |
| `WARDROBE_BIND_ADDRESS` | `127.0.0.1` in the public example |
| `WARDROBE_HOST_PORT` | `4173` |
| `WARDROBE_DATA_HOST_PATH` | `./data` |
| `WARDROBE_BACKUP_HOST_PATH` | `./backups` |
| `WARDROBE_UPDATE_STATE_HOST_PATH` | `./update-state` |

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Please never include personal wardrobe images, generated private assets, local network details, `.env` files, or credentials in issues or pull requests.

## Upstream and license

Wardrobe was originally created in [tandpfun/wardrobe](https://github.com/tandpfun/wardrobe). This fork preserves that attribution and is distributed under the same [MIT License](LICENSE).
