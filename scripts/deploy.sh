#!/usr/bin/env bash
# Build, push, and redeploy. Run this every time you want to ship a new version.
# Prerequisites: aws CLI configured, docker + buildx running (colima start if on Apple Silicon).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/config.sh"

G='\033[0;32m'; R='\033[0m'
step() { echo -e "${G}→${R} $*"; }

IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

sub() {
  sed -e "s|@@ACCOUNT_ID@@|${ACCOUNT_ID}|g" \
      -e "s|@@REGION@@|${REGION}|g" \
      -e "s|@@S3_BUCKET@@|${S3_BUCKET}|g" \
      -e "s|@@TASK_ROLE@@|${TASK_ROLE}|g" \
      -e "s|@@REPO_NAME@@|${REPO_NAME}|g" \
      -e "s|@@LOG_GROUP@@|${LOG_GROUP}|g"
}

step "Building (linux/amd64)..."
docker buildx build --platform linux/amd64 --load -t "${REPO_NAME}:latest" "${DIR}/.."

step "Pushing to ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker tag "${REPO_NAME}:latest" "${IMAGE_URI}:latest"
docker push "${IMAGE_URI}:latest"

step "Registering task definition..."
NEW_REV=$(aws ecs register-task-definition \
  --cli-input-json "$(sub < "${DIR}/../infra/task-definition.json")" \
  --region "${REGION}" --query "taskDefinition.revision" --output text)
echo "  revision: ${NEW_REV}"

step "Updating service..."
aws ecs update-service \
  --cluster "${CLUSTER}" --service "${SERVICE}" \
  --task-definition "${REPO_NAME}:${NEW_REV}" \
  --force-new-deployment --region "${REGION}" --output json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)['service']['deployments'][0]
print(f'  {d[\"status\"]}  desired={d[\"desiredCount\"]} running={d[\"runningCount\"]} pending={d[\"pendingCount\"]}')
"

step "Waiting for stable (Ctrl-C to skip)..."
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}" --region "${REGION}" \
  && echo -e "${G}✓ Deployed${R}" \
  || echo "  Timed out — check the console."
