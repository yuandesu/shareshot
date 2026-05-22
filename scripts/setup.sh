#!/usr/bin/env bash
# Provision all AWS infrastructure. Run once before the first deploy.
# Prerequisites: aws CLI configured.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/config.sh"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0m'
ok()   { echo -e "${G}✓${R} $*"; }
info() { echo -e "${G}→${R} $*"; }
warn() { echo -e "${Y}⚠${R}  $*"; }

# Substitute placeholders in an infra file
sub() {
  sed -e "s|@@ACCOUNT_ID@@|${ACCOUNT_ID}|g" \
      -e "s|@@REGION@@|${REGION}|g" \
      -e "s|@@S3_BUCKET@@|${S3_BUCKET}|g" \
      -e "s|@@TASK_ROLE@@|${TASK_ROLE}|g" \
      -e "s|@@REPO_NAME@@|${REPO_NAME}|g" \
      -e "s|@@LOG_GROUP@@|${LOG_GROUP}|g"
}

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# 1. IAM role (must exist before bucket policy references it)
info "IAM role: ${TASK_ROLE}"
aws iam get-role --role-name "${TASK_ROLE}" &>/dev/null \
  && warn "already exists" \
  || (aws iam create-role --role-name "${TASK_ROLE}" \
        --assume-role-policy-document "${TRUST}" --output json >/dev/null && ok "created")
aws iam put-role-policy --role-name "${TASK_ROLE}" --policy-name "shareshot-s3" \
  --policy-document "$(sub < "${DIR}/../infra/iam-task-role-policy.json")"
ok "policy attached"

# 2. S3 bucket
info "S3 bucket: ${S3_BUCKET}"
aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${REGION}" 2>/dev/null \
  && ok "created" || warn "already exists"
aws s3api put-public-access-block --bucket "${S3_BUCKET}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-policy --bucket "${S3_BUCKET}" \
  --policy "$(sub < "${DIR}/../infra/s3-bucket-policy.json")"
ok "bucket ready"

# 3. ECR repository
info "ECR repo: ${REPO_NAME}"
aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" &>/dev/null \
  && warn "already exists" \
  || (aws ecr create-repository --repository-name "${REPO_NAME}" --region "${REGION}" --output json >/dev/null && ok "created")

# 4. CloudWatch log group
info "Log group: ${LOG_GROUP}"
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" 2>/dev/null \
  && ok "created" || warn "already exists"

# 5. ECS cluster
info "ECS cluster: ${CLUSTER}"
aws ecs describe-clusters --clusters "${CLUSTER}" --region "${REGION}" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text | grep -q "${CLUSTER}" \
  && warn "already exists" \
  || (aws ecs create-cluster --cluster-name "${CLUSTER}" --region "${REGION}" --output json >/dev/null && ok "created")

# 6. Task definition
info "Task definition: ${REPO_NAME}"
aws ecs register-task-definition \
  --cli-input-json "$(sub < "${DIR}/../infra/task-definition.json")" \
  --region "${REGION}" --output json >/dev/null
ok "registered"

# 7. ECS service
info "ECS service: ${SERVICE}"
aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" --region "${REGION}" \
  --query "services[?status=='ACTIVE'].serviceName" --output text | grep -q "${SERVICE}" \
  && warn "already exists" \
  || (aws ecs create-service \
        --cluster "${CLUSTER}" --service-name "${SERVICE}" \
        --task-definition "${REPO_NAME}" --desired-count 1 --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SECURITY_GROUP_ID}],assignPublicIp=ENABLED}" \
        --region "${REGION}" --output json >/dev/null \
      && ok "created")

echo ""
echo -e "${G}Infrastructure ready.${R} Now run: ./scripts/deploy.sh"
