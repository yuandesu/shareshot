# ShareShot

A lightweight screenshot annotation and sharing platform built for internal team demos. Upload screenshots, annotate them on a canvas, and share with role-based access links — no login required.

## Features

- **Canvas annotation** — draw, mark up, and capture screenshots with Fabric.js
- **Role-based sharing** — generate viewer / commenter / editor links per project (Google Drive style)
- **S3-backed storage** — all images and project data persisted to AWS S3
- **No auth** — demo-phase simplicity; access control via share tokens and network-level ECS security groups

## Architecture

```
Browser → ECS Fargate (Node.js, port 3000) → S3 (images + collection JSON)
```

- **Runtime**: Node.js 20, zero framework (pure `http` module)
- **Storage**: AWS S3 (`shareshot-tse-sandbox`)
- **Compute**: ECS Fargate on `dd-fargate-test` cluster
- **Dependency**: `@aws-sdk/client-s3` only

## Permission model

| Access | How |
|---|---|
| Owner | No token in URL |
| Editor | `?token=<editor-token>` |
| Commenter | `?token=<commenter-token>` — can annotate, cannot rename |
| Viewer | `?token=<viewer-token>` — read only |

Tokens are UUID strings stored in the project's S3 JSON. Share links look like:  
`http://<host>:3000/canvas/<project-id>?token=<token>`

## Local development

```bash
cp .env.example .env   # fill in AWS_REGION and S3_BUCKET
npm install
node server.js
```

Requires AWS credentials with read/write access to the S3 bucket (via env vars, `~/.aws/credentials`, or IAM role).

## Deploy to AWS

**One-time setup** (creates S3 bucket, ECR repo, IAM role, ECS service):
```bash
./scripts/setup.sh
```

**Redeploy** (build → push → update ECS):
```bash
./scripts/deploy.sh
```

> Requires: AWS CLI configured, Docker (with buildx for cross-platform amd64 builds), `colima start` if using Colima on Apple Silicon.

**Get current public IP** (IP changes on task restart):
```bash
TASK_ARN=$(aws ecs list-tasks --cluster dd-fargate-test --service-name shareshot --region us-east-1 --query 'taskArns[0]' --output text)
ENI=$(aws ecs describe-tasks --cluster dd-fargate-test --tasks $TASK_ARN --region us-east-1 --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
aws ec2 describe-network-interfaces --network-interface-ids $ENI --region us-east-1 --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```

**Add a team member's access** (sandbox blocks 0.0.0.0/0 inbound rules):
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0f3b0a2b192d9fcf5 \
  --protocol tcp --port 3000 \
  --cidr <their-ip>/32 \
  --region us-east-1
```
Team members can find their IP at [checkip.amazonaws.com](https://checkip.amazonaws.com).

## Project structure

```
server.js              # HTTP server, all routes
public/
  index.html           # Project grid (home)
  canvas.html          # Annotation canvas
  viewer.html          # Read-only share view
infra/
  task-definition.json # ECS task definition
  iam-task-role-policy.json
  s3-bucket-policy.json
scripts/
  setup.sh             # One-time AWS infra setup
  deploy.sh            # Build + push + redeploy
```
