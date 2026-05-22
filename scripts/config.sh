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

# Network (used by setup.sh when creating the ECS service)
SUBNET_IDS="subnet-0b620703db142d0e2,subnet-038be5070eca57f27"
SECURITY_GROUP_ID="sg-0f3b0a2b192d9fcf5"
