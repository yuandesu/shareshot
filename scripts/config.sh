#!/usr/bin/env bash
# All environment-specific values live here.
# Edit this file before running setup.sh or deploy.sh.

ACCOUNT_ID="659775407889"
REGION="us-east-1"
S3_BUCKET="shareshot-tse-sandbox"
REPO_NAME="shareshot"
TASK_ROLE="shareshot-task-role"
LOG_GROUP="/ecs/shareshot"
CLUSTER="dd-fargate-test"
SERVICE="shareshot"

# Network
VPC_ID="vpc-0d99ca93852ace853"
SUBNET_IDS="subnet-0b620703db142d0e2,subnet-038be5070eca57f27"
TASK_SG="sg-0f3b0a2b192d9fcf5"   # allows port 3000 from ALB SG only
ALB_SG="sg-01b4bd0a407ed0fd1"    # allows port 80 from /32 CIDRs (sandbox blocks 0.0.0.0/0)

# ALB (created by setup.sh)
ALB_NAME="shareshot"
TG_NAME="shareshot"
