# ShareShot — Claude context

## What this is

ShareShot is a Node.js screenshot sharing app deployed to ECS Fargate in the Datadog tse-sandbox AWS account. It's a demo tool for internal team use — no authentication, access control via share tokens only.

## Key constraints

- **No framework** — pure Node.js `http` module. Do not introduce Express or any web framework.
- **Single dependency** — `@aws-sdk/client-s3` only. Keep it that way unless there's a compelling reason.
- **No auth (for now)** — ownerless model: no token = owner, token present = role from `shareTokens`. See `getRole()` in `server.js`.
- **S3 is the only storage** — no local disk persistence. `data/` directory is for local dev only and is gitignored.

## AWS environment

- Account: `659775407889`, region: `us-east-1`
- S3 bucket: `shareshot-tse-sandbox`
- ECS cluster: `dd-fargate-test`, service: `shareshot`
- Task role: `shareshot-task-role`
- Security group: `sg-0f3b0a2b192d9fcf5`
- **Sandbox restriction**: the tse-sandbox compliance automation auto-removes any SG inbound rule with `0.0.0.0/0`. Always use `/32` CIDRs.

## Deploy

```bash
./scripts/deploy.sh   # build (amd64) → push ECR → register task def → update ECS service
```

Docker must be running. Build uses `docker buildx` with `--platform linux/amd64` because the dev machine is Apple Silicon but ECS runs on x86_64.

## Data model

Collection JSON stored at `s3://shareshot-tse-sandbox/collections/<id>.json`:

```json
{
  "id": "<uuid>",
  "title": "string",
  "sharedImageId": "<uuid> | null",
  "canvasData": "<fabric.js JSON string> | null",
  "shareTokens": {
    "viewer": "<uuid> | null",
    "commenter": "<uuid> | null",
    "editor": "<uuid> | null"
  },
  "createdAt": "ISO8601",
  "updatedAt": "ISO8601"
}
```

Images stored at `s3://shareshot-tse-sandbox/uploads/<id>.png`.

## Design philosophy

See `design-philosophy.md`. TL;DR: minimal color palette (near-white + indigo `#6366f1`), Work Sans font, generous whitespace. Do not deviate from the established visual language.

## Routes

| Method | Path | Auth |
|---|---|---|
| POST | `/api/images` | owner or editor/commenter via token |
| GET | `/images/:id.png` | public |
| GET | `/api/projects` | public (lists all) |
| POST | `/api/projects` | public (owner) |
| GET/PUT/DELETE | `/api/projects/:id` | token or owner |
| POST | `/api/projects/:id/tokens` | owner only |
| DELETE | `/api/projects/:id/tokens/:role` | owner only |
