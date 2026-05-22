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

# 6. Security groups
info "Security groups"
# ALB SG — allows HTTP from /32 CIDRs (sandbox blocks 0.0.0.0/0)
aws ec2 describe-security-groups --filters "Name=group-name,Values=shareshot-alb-sg" \
  --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -q "sg-" \
  && warn "ALB SG already exists" \
  || (aws ec2 create-security-group \
        --group-name "shareshot-alb-sg" --description "ShareShot ALB inbound" \
        --vpc-id "${VPC_ID}" --region "${REGION}" --output json >/dev/null && ok "ALB SG created")
# Task SG — allows port 3000 from ALB SG only (set up manually or update after ALB SG is known)
aws ec2 describe-security-groups --filters "Name=group-name,Values=shareshot-sg" \
  --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -q "sg-" \
  && warn "task SG already exists" \
  || (aws ec2 create-security-group \
        --group-name "shareshot-sg" --description "ShareShot task inbound from ALB" \
        --vpc-id "${VPC_ID}" --region "${REGION}" --output json >/dev/null && ok "task SG created")

# 7. ALB + Target Group + Listener
info "ALB: ${ALB_NAME}"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${ALB_NAME}" --region "${REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets $(echo "${SUBNET_IDS}" | tr ',' ' ') \
    --security-groups "${ALB_SG}" \
    --scheme internet-facing --type application \
    --region "${REGION}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  ok "ALB created"
else
  warn "ALB already exists"
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "${TG_NAME}" --region "${REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" --protocol HTTP --port 3000 \
    --vpc-id "${VPC_ID}" --target-type ip \
    --health-check-path / \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --region "${REGION}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "${REGION}" --output json >/dev/null
  ok "target group + listener created"
else
  warn "target group already exists"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
  --region "${REGION}" --query 'LoadBalancers[0].DNSName' --output text)

# 8. Task definition
info "Task definition: ${REPO_NAME}"
aws ecs register-task-definition \
  --cli-input-json "$(sub < "${DIR}/../infra/task-definition.json")" \
  --region "${REGION}" --output json >/dev/null
ok "registered"

# 9. ECS service (with ALB)
info "ECS service: ${SERVICE}"
SVC_STATUS=$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
  --region "${REGION}" --query 'services[0].status' --output text 2>/dev/null || echo "MISSING")
if [[ "$SVC_STATUS" == "ACTIVE" ]]; then
  warn "already exists"
else
  aws ecs create-service \
    --cluster "${CLUSTER}" --service-name "${SERVICE}" \
    --task-definition "${REPO_NAME}" --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${REPO_NAME},containerPort=3000" \
    --health-check-grace-period-seconds 30 \
    --region "${REGION}" --output json >/dev/null
  ok "created"
fi

echo ""
echo -e "${G}Infrastructure ready.${R}"
echo "  URL: http://${ALB_DNS}"
echo ""
echo "Add your IP to the ALB SG (sandbox blocks 0.0.0.0/0):"
echo "  aws ec2 authorize-security-group-ingress --group-id ${ALB_SG} --protocol tcp --port 80 --cidr \$(curl -s https://checkip.amazonaws.com)/32 --region ${REGION}"
echo ""
echo "Then run: ./scripts/deploy.sh"
