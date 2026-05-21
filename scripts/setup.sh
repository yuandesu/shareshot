#!/usr/bin/env bash
# Run once to create all AWS infrastructure.
# Prerequisites: aws CLI configured, docker installed.
set -euo pipefail

# ── Config — fill these in before running ─────────────────────────────────────
ACCOUNT_ID="659775407889"
REGION="us-east-1"
BUCKET="shareshot-tse-sandbox"
REPO_NAME="shareshot"
CLUSTER="dd-fargate-test"
SERVICE="shareshot"
TASK_FAMILY="shareshot"
TASK_ROLE="shareshot-task-role"
LOG_GROUP="/ecs/shareshot"

SUBNET_IDS="subnet-0b620703db142d0e2,subnet-038be5070eca57f27"
SECURITY_GROUP_ID="sg-0f3b0a2b192d9fcf5"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${GREEN}→${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }


IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"

# ── 1. IAM task role (must exist before bucket policy) ────────────────────────
info "Creating IAM role: $TASK_ROLE"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam get-role --role-name "$TASK_ROLE" &>/dev/null \
  && warn "IAM role already exists, skipping creation" \
  || (aws iam create-role \
        --role-name "$TASK_ROLE" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --output json > /dev/null \
      && success "IAM role created")

info "Attaching S3 policy to IAM role"
INLINE_POLICY=$(cat "$(dirname "$0")/../infra/iam-task-role-policy.json")
aws iam put-role-policy \
  --role-name "$TASK_ROLE" \
  --policy-name "shareshot-s3" \
  --policy-document "$INLINE_POLICY"
success "IAM role ready"

# ── 2. S3 bucket ──────────────────────────────────────────────────────────────
info "Creating S3 bucket: $BUCKET"
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION") \
  2>/dev/null && success "Bucket created" || warn "Bucket already exists, skipping"

info "Blocking public access on S3 bucket"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Apply bucket policy (restrict to task role only)
BUCKET_POLICY=$(cat "$(dirname "$0")/../infra/s3-bucket-policy.json" | sed "s/ACCOUNT_ID/$ACCOUNT_ID/g")
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$BUCKET_POLICY"
success "S3 bucket ready"

# ── 3. ECR repository ─────────────────────────────────────────────────────────
info "Creating ECR repository: $REPO_NAME"
aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" &>/dev/null \
  && warn "ECR repo already exists, skipping" \
  || (aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" --output json > /dev/null \
      && success "ECR repo created")

# ── 4. CloudWatch log group ───────────────────────────────────────────────────
info "Creating CloudWatch log group: $LOG_GROUP"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null \
  && success "Log group created" || warn "Log group already exists, skipping"

# ── 5. ECS cluster ────────────────────────────────────────────────────────────
info "Creating ECS cluster: $CLUSTER"
aws ecs describe-clusters --clusters "$CLUSTER" --region "$REGION" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text | grep -q "$CLUSTER" \
  && warn "ECS cluster already exists, skipping" \
  || (aws ecs create-cluster --cluster-name "$CLUSTER" --region "$REGION" --output json > /dev/null \
      && success "ECS cluster created")

# ── 6. Register task definition ───────────────────────────────────────────────
info "Registering task definition: $TASK_FAMILY"
TASK_DEF=$(cat "$(dirname "$0")/../infra/task-definition.json" \
  | sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" \
  | sed "s|shareshot:latest|${REPO_NAME}:latest|g")

aws ecs register-task-definition \
  --cli-input-json "$TASK_DEF" \
  --region "$REGION" \
  --output json > /dev/null
success "Task definition registered"

# ── 7. Build + push initial image ─────────────────────────────────────────────
info "Building and pushing initial Docker image"
docker buildx build --platform linux/amd64 --load -t "${REPO_NAME}:latest" "$(dirname "$0")/.."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker tag "${REPO_NAME}:latest" "$IMAGE_URI"
docker push "$IMAGE_URI"
success "Image pushed to ECR"

# ── 8. Create ECS service ─────────────────────────────────────────────────────
info "Creating ECS service: $SERVICE"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query "services[?status=='ACTIVE'].serviceName" --output text | grep -q "$SERVICE" \
  && warn "ECS service already exists, skipping" \
  || (aws ecs create-service \
        --cluster "$CLUSTER" \
        --service-name "$SERVICE" \
        --task-definition "$TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SECURITY_GROUP_ID}],assignPublicIp=ENABLED}" \
        --region "$REGION" \
        --output json > /dev/null \
      && success "ECS service created")

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Setup complete!${RESET}"
echo ""
echo "Get the task's public IP:"
echo "  TASK_ARN=\$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text)"
echo "  ENI=\$(aws ecs describe-tasks --cluster $CLUSTER --tasks \$TASK_ARN --region $REGION --query 'tasks[0].attachments[0].details[?name==\`networkInterfaceId\`].value' --output text)"
echo "  aws ec2 describe-network-interfaces --network-interface-ids \$ENI --region $REGION --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
