# Contributing

Thanks for helping improve Wardrobe.

## Development

```bash
npm install
cp .env.example .env
npm run dev
```

Before opening a pull request:

```bash
npm run check
```

Keep changes focused and describe what changed, why it changed, and how it was tested.

## Privacy and repository hygiene

Never commit or paste into an issue or pull request:

- `.env` or any API/admin key
- files from `data/`, `backups/`, `update-state/`, or `candidates/`
- personal reference photos, wardrobe photos, or generated private images
- private hostnames, LAN addresses, absolute home/NAS paths, tokens, or credentials
- logs containing user content or secrets

Use placeholders such as `127.0.0.1`, `192.168.x.x`, `/path/to/data`, and `YOUR_KEY_HERE` in documentation and examples.

## Pull requests

A good pull request should:

1. preserve the local-first privacy model;
2. keep secrets server-side;
3. avoid making the service publicly reachable by default;
4. include or update verification steps when deployment behavior changes;
5. keep user data independent from application rollback whenever possible.

For security-sensitive changes, explain the threat or failure mode being addressed and the safest rollback path.
