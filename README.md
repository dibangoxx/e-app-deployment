# FlashInfo E-Commerce Platform

Full-stack home goods e-commerce app — Node.js/Express API, HTML/CSS/JS frontend, all 12 AWS infrastructure pillars in Terraform.

---

## Local Testing (Start Here)

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | ≥ 4.25 | docker.com |
| Docker Compose | ≥ 2.23 | bundled with Docker Desktop |
| make | any | pre-installed Mac/Linux; `choco install make` on Windows |

### 1 — First-time setup

```bash
cd flashinfo-platform
cp .env.local .env        # edit Stripe key if testing payments
```

### 2 — Start the full stack

```bash
make up
```

First run ~3 min (image pulls). Subsequent starts ~20 sec.

### 3 — Verify healthy

```bash
make health
# → http://localhost:3001/health
```

### 4 — Smoke test

```bash
chmod +x scripts/smoke-test.sh
./scripts/smoke-test.sh
```

### 5 — Unit + integration tests

```bash
make test
```

---

## Service URLs

| Service | URL | Login |
|---------|-----|-------|
| Frontend | http://localhost:3000 | — |
| API | http://localhost:3001 | — |
| Health | http://localhost:3001/health | — |
| Adminer (DB) | http://localhost:8080 | Server: postgres / User: flashinfo_admin / Pass: flashinfo_local_password |
| Redis UI | http://localhost:8081 | admin / admin |
| OpenSearch | http://localhost:5601 | — |
| LocalStack | http://localhost:4566 | — |

---

## Test Accounts

| Role | Email | Password |
|------|-------|----------|
| Admin | admin@flashinfo.local | Admin1234! |
| Customer | customer@flashinfo.local | Test1234! |

---

## API Quick Reference

```bash
# Register
curl -X POST http://localhost:3001/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"you@test.com","password":"Pass1234!","given_name":"Jane","family_name":"Doe"}'

# Login → get token
TOKEN=$(curl -s -X POST http://localhost:3001/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"you@test.com","password":"Pass1234!"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

# List products
curl http://localhost:3001/api/v1/products

# Search
curl "http://localhost:3001/api/v1/search?q=chair"

# Add to cart
curl -X POST http://localhost:3001/api/v1/cart/add \
  -H "Content-Type: application/json" \
  -d '{"session_id":"my-session","product_id":"<id>","quantity":2}'

# Checkout
curl -X POST http://localhost:3001/api/v1/orders/checkout \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"items":[{"product_id":"<id>","quantity":1}],"shipping_address":{"first_name":"Jane","last_name":"Doe","address_line1":"123 Main St","city":"Austin","state_province":"TX","postal_code":"78701","country_code":"US"},"payment_method_id":"pm_card_visa"}'
```

---

## Makefile Commands

```bash
make up           # Start everything
make down         # Stop everything
make logs         # Tail all logs
make logs-api     # API logs only
make shell-api    # Shell inside API container
make shell-db     # psql shell
make shell-redis  # redis-cli
make test         # Run tests
make health       # Check API health
make ls-buckets   # LocalStack S3 buckets
make ls-queues    # LocalStack SQS queues
make reset        # Full wipe and rebuild
```

---

## Local vs AWS Mapping

| Component | Local | AWS |
|-----------|-------|-----|
| Database | PostgreSQL 15 container | Aurora PostgreSQL Serverless v2 |
| Cache | Redis 7 container | ElastiCache Redis 7.1 |
| Search | OpenSearch 2.11 container | Amazon OpenSearch |
| Storage | LocalStack S3 | S3 + Object Lock |
| Queues | LocalStack SQS | Amazon SQS |
| Events | LocalStack EventBridge | Amazon EventBridge |
| Secrets | LocalStack Secrets Manager | AWS Secrets Manager |
| Auth | Local JWT / bcrypt | Cognito + JWT |
| CDN | nginx proxy | CloudFront + WAF |

---

## Deploy to AWS (after local tests pass)

```bash
cd terraform
cp environments/prod/terraform.tfvars terraform.tfvars
# Edit domain_name, certificate_arn, ses_from_email, alert_email

# Bootstrap (once)
make tf-bootstrap-backend

# If bootstrap fails with AccessDenied, request this minimum IAM policy:
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Action": [
#         "s3:CreateBucket",
#         "s3:HeadBucket",
#         "s3:PutBucketVersioning",
#         "s3:PutBucketEncryption"
#       ],
#       "Resource": [
#         "arn:aws:s3:::flashinfo-tfstate",
#         "arn:aws:s3:::flashinfo-tfstate/*"
#       ]
#     },
#     {
#       "Effect": "Allow",
#       "Action": [
#         "dynamodb:DescribeTable",
#         "dynamodb:CreateTable",
#         "dynamodb:UpdateTable",
#         "dynamodb:DescribeTimeToLive",
#         "dynamodb:UpdateTimeToLive"
#       ],
#       "Resource": "arn:aws:dynamodb:us-east-1:<account-id>:table/flashinfo-tfstate-lock"
#     }
#   ]
# }

terraform init && terraform plan -out=tfplan && terraform apply tfplan
```

---

## Run Locally Without Docker (macOS)

If Docker is unavailable, you can run FlashInfo with local PostgreSQL + Redis.

### 1 — Install prerequisites

```bash
brew install node@20 postgresql@15 redis
brew services start postgresql@15
brew services start redis
```

### 2 — Initialize database

```bash
cd flashinfo-platform
make local-db-init
```

### 3 — Run app (API + frontend)

```bash
make local-up
```

### 4 — Open in browser

- Storefront: http://localhost:3001/
- Operations app: http://localhost:3001/src/operations.html

### 5 — Admin login for operations app

- Email: `admin@flashinfo.local`
- Password: `Admin1234!`
