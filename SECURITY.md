# Security Policy

## Reporting a security issue

Use GitHub's private security advisory feature when available rather than opening a public issue for a vulnerability that could make unintended resets, authorization bypass, destructive partition changes, or secret exposure possible.

## Do not include sensitive material

When reporting issues, redact:

- BitLocker recovery passwords/keys and key-protector material.
- Tenant IDs, device IDs, user identifiers, internal domains, and customer names where not required.
- Credentials, tokens, certificates, private keys, and enrollment secrets.
- Full production logs that contain confidential environment data.

A minimal sanitized log excerpt plus Windows build, partition layout, BitLocker state, and controller/driver information is normally sufficient.

## Supported release

Security fixes are targeted to the latest public release unless a maintainer explicitly states otherwise.
