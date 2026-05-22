# ShareShot

Internal tool for annotating screenshots and sharing them with the team. Upload an image, draw on it, generate a share link with viewer / commenter / editor permissions.

No login required — access is controlled by share tokens.

## Stack

- Node.js (no framework) + Fabric.js canvas
- AWS S3 for storage, ECS Fargate for compute
- Single dependency: `@aws-sdk/client-s3`

## Run locally

```bash
cp .env.example .env   # set AWS_REGION and S3_BUCKET
npm install
node server.js
```

Needs AWS credentials with S3 read/write access.

## Deploy

Edit `scripts/config.sh` with your account details, then:

```bash
./scripts/setup.sh    # one-time: provision S3, ECR, IAM, ECS
./scripts/deploy.sh   # build → push → redeploy (run this on every update)
```

Requires AWS CLI, Docker with buildx. On Apple Silicon: `colima start` first.

## Sandbox note

The tse-sandbox blocks `0.0.0.0/0` SG rules. To give someone access, add their IP:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0f3b0a2b192d9fcf5 --protocol tcp --port 3000 \
  --cidr <ip>/32 --region us-east-1
# find your IP: curl checkip.amazonaws.com
```

The public IP changes on every task restart. To get the current one:

```bash
TASK=$(aws ecs list-tasks --cluster dd-fargate-test --service-name shareshot --region us-east-1 --query 'taskArns[0]' --output text)
ENI=$(aws ecs describe-tasks --cluster dd-fargate-test --tasks $TASK --region us-east-1 --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
aws ec2 describe-network-interfaces --network-interface-ids $ENI --region us-east-1 --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```
