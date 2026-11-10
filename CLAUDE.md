# CLAUDE.md

## This repository is public

`osh-labs/SEM-docmost` is a public fork of Docmost. Everything committed here, including commit messages, PR titles and descriptions, issues, comments, docs and notes, can be read by anyone and stays in git history even after a later deletion.

Never commit, and remove when found:

- Personal data: people's names, email addresses, phone numbers, usernames or account handles of team members. Refer to roles instead ("the owner", "a member", "the test user").
- Credentials and secrets: `.env` contents, API keys, access keys, tokens, passwords, `SECRET_KEY`, `APP_SECRET`, age private keys, OAuth client secrets. `deploy/.env` is git-ignored; keep it that way and never force-add it.
- Account and infrastructure identifiers that are not needed to use the docs: AWS account IDs, IAM ARNs with account numbers, S3 bucket names, instance IPs and private hostnames, Lightsail key names. Use placeholders such as `<bucket>`, `<ip>`, `<account-id>`.
- Pasted command output or logs, until they are checked for any of the above.

Public by design and fine to keep: the domains `docs.southeastexpeditionmed.com` and `docs-mcp.southeastexpeditionmed.com`, role mailboxes such as `docs@southeastexpeditionmed.com`, image digests, and commit hashes.

Before every commit or PR, check the diff and the message for the items above, for example:

```bash
git diff --cached | grep -n -i -E '@[a-z0-9.-]+\.[a-z]{2,}|AKIA[0-9A-Z]{16}|AGE-SECRET-KEY|arn:aws:iam::[0-9]{12}|[0-9]{12}'
```

The same rule applies to the sidecar fork `osh-labs/docmost-mcp-remote`, which is also public.

## Layout

- `apps/`, `packages/`: upstream Docmost. Do not modify; production runs the unmodified upstream image.
- `deploy/`: Compose stack, Caddyfile, scripts and runbook (`deploy/README.md`) for the Lightsail host.
- `docs/mcp/`: build plan, security review and test report for the Docmost + remote MCP deployment.

## Workflow

- The production host follows `main`. Changes reach it only through a PR merged by the owner, then `git pull` on the host.
- Validate `deploy/` changes with `docker compose config`, `bash -n` and shellcheck before opening a PR.
