# Project Rules

This repository builds `ghcr.io/ai-setups/pg-autobackup`: the official PostgreSQL image plus pgBackRest, which archives WAL continuously and takes scheduled full backups into S3-compatible storage, and a restore command.

- This is a public repository. Issues, pull requests, commits and files describe only this image; never name other repositories, projects, buckets, accounts or endpoints. Examples use placeholders.
- The backup policy is fixed in the image; a container only supplies where the repository lives and its credentials. Add an option only for a concrete need.
- Run `bash tests/smoke.sh` before delivering any change; it builds the image and checks backup and restore against a local repository.
- Every change goes through an issue, a branch and a pull request.
