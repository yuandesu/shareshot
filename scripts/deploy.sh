#!/usr/bin/env bash
# Build, push, and redeploy. Run this every time you want to ship a new version.
# Prerequisites: aws CLI configured, docker running.
set -euo pipefail

# ── Config — must match setup.sh ─────────────────────────────────────────────
ACCOUNT_ID="659775407889"
REGION="us-east-1"
REPO_NAME="shareshot"
CLUSTER="dd-fargate-test"
SERVICE="shareshot"
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; RESET='\033[0m'
step() { echo -e "${GREEN}→${RESET} $*"; }

IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Build ──────────────────────────────────────────────────────────────────
step "Building Docker image..."
docker buildx build --platform linux/amd64 --load -t "${REPO_NAME}:latest" "${SCRIPT_DIR}/.."

# ── 2. Push to ECR ────────────────────────────────────────────────────────────
step "Logging into ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

step "Pushing image..."
docker tag "${REPO_NAME}:latest" "${IMAGE_URI}:latest"
docker push "${IMAGE_URI}:latest"

# ── 3. Register new task definition revision ──────────────────────────────────
step "Registering task definition..."
TASK_DEF=$(cat "${SCRIPT_DIR}/../infra/task-definition.json" \
  | sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g")

NEW_REVISION=$(aws ecs register-task-definition \
  --cli-input-json "${TASK_DEF}" \
  --region "${REGION}" \
  --query "taskDefinition.revision" \
  --output text)

echo "  task definition revision: ${NEW_REVISION}"

# ── 4. Update ECS service ─────────────────────────────────────────────────────
step "Deploying to ECS..."
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --task-definition "shareshot:${NEW_REVISION}" \
  --force-new-deployment \
  --region "${REGION}" \
  --output json \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)['service']
d = s['deployments'][0]
print(f'  status:  {d[\"status\"]}')
print(f'  desired: {d[\"desiredCount\"]}  running: {d[\"runningCount\"]}  pending: {d[\"pendingCount\"]}')
"

# ── 5. Wait for stable (optional — Ctrl-C to skip) ────────────────────────────
step "Waiting for service to stabilise (Ctrl-C to skip)..."
aws ecs wait services-stable \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}" \
  --region "${REGION}" \
  && echo -e "${GREEN}✓ Deployment complete${RESET}" \
  || echo "  Timed out waiting — check the console if needed."
