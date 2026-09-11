# Security policy

Wardrobe processes personal images and uses server-side API credentials, so security and privacy issues should be handled carefully.

## Supported version

Security fixes are applied to the current `main` branch.

## Reporting a vulnerability

Please avoid posting credentials, private images, local network details, or exploit instructions in a public issue.

If GitHub private vulnerability reporting is available for this repository, use that channel. Otherwise, open a minimal public issue stating that you need a private channel for a security report, without including sensitive details.

## Security expectations

Changes should preserve these defaults:

- secrets remain server-side and outside Git;
- user data remains outside the application image and repository;
- the service is not publicly reachable by default;
- deployment containers run with least privilege where practical;
- update and rollback paths must not silently overwrite user data;
- examples and documentation use placeholders instead of real hostnames, addresses, paths, credentials, or personal images.
