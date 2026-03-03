# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 0.1.3   | ✅ Active  |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly:

1. **Do NOT open a public GitHub issue** for security vulnerabilities.
2. **Email:** Send details to the repository owner via GitHub private messaging or through the [Security Advisories](https://github.com/Z0mb13V1/mindcraft/security/advisories) tab.
3. **Include:** A description of the vulnerability, steps to reproduce, and potential impact.

You can expect an initial response within 72 hours.

## Security Measures

This project implements the following security hardening:

- **No hardcoded credentials** — All API keys, passwords, and IPs loaded from environment variables or AWS SSM
- **Whitelist enforcement** — Minecraft server restricts access to pre-authorized accounts only
- **Port obscurity** — Non-default external port with AWS Security Group restrictions
- **Prototype pollution protection** — Recursive sanitization of all external config input
- **Input validation** — Command injection detection, type checking, control character stripping
- **Rate limiting** — Per-user rate limiting with automatic stale-entry cleanup
- **Path traversal guards** — Cross-platform validation on all file path inputs
- **Code sandboxing** — SES (Secure ECMAScript) sandbox for user-generated code execution
- **ESLint hardening** — Zero-warning tolerance enforced pre-commit via Husky
- **Docker isolation** — Bot runs as non-root `node` user; secrets excluded from build context

## Sensitive Files

The following files contain secrets and must **never** be committed:

| File | Purpose | Protected By |
| ---- | ------- | ------------ |
| `.env` | API keys, passwords | `.gitignore` |
| `keys.json` | API keys (legacy) | `.gitignore` |
| `aws/*.pem` | SSH keys | `.gitignore` |
| `aws/config.env` | Runtime AWS config | `.gitignore` |

## Configuration

- Set `MINECRAFT_PORT` in `.env` to configure your external Minecraft port (defaults to `42069`)
- Set `EC2_PUBLIC_IP` in `.env` for deployment scripts to reference your server IP
- All LLM API keys should be set via environment variables (see `.env.example`)
