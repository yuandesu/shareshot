# ShareShot

Internal tool for annotating screenshots and sharing them with the team. Upload an image, draw on it, generate a share link with viewer / commenter / editor permissions.

No login required — access is controlled by share tokens.

## Stack

- Node.js (no framework) + Fabric.js canvas
- AWS S3 for storage, ECS Fargate + ALB for compute
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
./scripts/setup.sh    # one-time: provision S3, ECR, IAM, ALB, ECS
./scripts/deploy.sh   # build → push → redeploy (run this on every update)
```

Requires AWS CLI, Docker with buildx. On Apple Silicon: `colima start` first.

## Access

The app runs behind an ALB with a stable DNS name:
**http://shareshot-2000439380.us-east-1.elb.amazonaws.com**

The tse-sandbox blocks `0.0.0.0/0` SG rules. To give someone access, add their IP to the ALB SG:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-01b4bd0a407ed0fd1 --protocol tcp --port 80 \
  --cidr <ip>/32 --region us-east-1
# find your IP: curl checkip.amazonaws.com
```
