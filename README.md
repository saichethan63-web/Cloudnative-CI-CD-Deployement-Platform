# Cloud-Native CI/CD Deployment Platform

A containerised web application with a fully automated pipeline: every push to `main` is tested, built into a Docker image, scanned, pushed to Amazon ECR and deployed to an AWS EC2 host provisioned by Terraform. Prometheus and Grafana provide application and infrastructure visibility.

**Stack:** AWS (VPC, EC2, ECR, S3, IAM, SSM) · Docker / Docker Compose · Nginx · GitHub Actions · Terraform · Prometheus · Grafana

## Architecture

```
                    git push                     OIDC (no stored AWS keys)
   Developer ───────────────▶ GitHub Actions ─────────────────────────────┐
                              │ lint + test                                │
                              │ validate compose / nginx / prometheus      ▼
                              │ build image, smoke test, Trivy scan   ┌─────────┐
                              │ push image ───────────────────────────▶ Amazon  │
                              │ upload release bundle ─────────────┐  │  ECR    │
                              │ SSM SendCommand                    ▼  └────┬────┘
                              └───────────────▶ ┌──────────┐  ┌────────┐   │ pull
                                                │   SSM    │  │   S3   │   │
                                                └────┬─────┘  └───┬────┘   │
 ┌──────────────────────── AWS VPC (public subnet) ───┼────────────┼────────┼──────┐
 │  EC2 (Amazon Linux 2023, Docker, IMDSv2, encrypted EBS)          ▼        ▼      │
 │  ┌────────────────────── docker compose network ──────────────────────────────┐  │
 │  │  Internet ─▶ :80 Nginx ─┬─▶ app:3000        (Node.js, /metrics internal)    │  │
 │  │                         └─▶ grafana:3000    (served at /grafana/)           │  │
 │  │  Prometheus ◀── scrapes ── app, node-exporter, cAdvisor, nginx-exporter     │  │
 │  └─────────────────────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Key design choices:

- **No SSH, no AWS keys in GitHub.** Deploys run through AWS Systems Manager; GitHub assumes an IAM role via OIDC, limited to the `main` branch and the `production` environment.
- **Immutable, traceable releases.** Images are tagged with the commit SHA. The release bundle (compose file, Nginx and monitoring config) is stored in S3 under the same SHA, so a rollback restores code *and* config.
- **Automatic rollback.** The server-side deploy helper health-checks the new release and reverts to the previous image if it fails.
- **Environment-based configuration.** Nginx config is a template rendered from environment variables; the app reads everything from env vars; `.env` is generated at deploy time (the Grafana password comes from SSM Parameter Store).
- **Zero-config DNS for redeploys.** Nginx re-resolves the app via Docker DNS, so it follows the app container to its new IP.

## Repository layout

```
app/                       Node.js service, tests, Dockerfile (multi-stage, non-root)
nginx/                     nginx.conf + templates/default.conf.template (env-driven)
monitoring/
  prometheus/              scrape config + alert rules
  grafana/                 provisioned datasource + "Platform Overview" dashboard
docker-compose.yml         app, nginx, prometheus, grafana, node-exporter, cAdvisor, nginx-exporter
terraform/                 VPC, security group, EC2, EIP, ECR, S3, IAM, OIDC, SSM parameter
.github/workflows/         ci-cd.yml, rollback.yml, terraform.yml
scripts/                   ssm-deploy.sh, set-github-config.sh, load-test.sh
```

## 1. Run it locally

Requires Docker with Compose v2.

```bash
make up                 # copies .env.example to .env, builds and starts everything
open http://localhost:8080            # app UI
open http://localhost:8080/grafana/   # login: admin / changeme-local-only
make load               # generate traffic for the dashboards
```

Run the app tests without Docker: `make test` (Node 20+).

## 2. Deploy to AWS

Prerequisites: an AWS account, AWS CLI configured with admin-capable credentials (for the one-off Terraform run), Terraform ≥ 1.5, a GitHub repository, and the GitHub CLI (`gh`).

```bash
# 1. Push this project to your GitHub repo (branch: main)

# 2. Provision infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set github_repository = "owner/repo"
terraform init
terraform apply

# 3. Give GitHub what it needs (variables + AWS_ROLE_ARN secret + production environment)
cd .. && make gh-config

# 4. Wait ~3 minutes for the server bootstrap, then trigger the pipeline
git commit --allow-empty -m "first deploy" && git push
```

When the **Deploy to AWS** job finishes, open the URLs from `terraform output app_url` and `terraform output grafana_url`.

Grafana password:

```bash
aws ssm get-parameter --with-decryption --name "$(terraform -chdir=terraform output -raw grafana_password_parameter)" \
  --query Parameter.Value --output text
```

If your AWS account already has the GitHub OIDC provider, set `create_github_oidc_provider = false` in `terraform.tfvars`.

Optional: add required reviewers to the `production` environment (GitHub → Settings → Environments) for a manual approval gate before deploys.

## 3. The CI/CD pipeline

| Job | What it does |
|---|---|
| **Lint and test** | ESLint, Jest with coverage |
| **Validate config** | `docker compose config`, `nginx -t` on the rendered template, `promtool check config` (incl. alert rules), dashboard JSON, ShellCheck |
| **Build, scan, push** | Builds the image, smoke-tests the running container, Trivy scan (fails on fixable CRITICAL CVEs), then on `main` pushes `:<sha>` and `:latest` to ECR |
| **Deploy to AWS** | Uploads the release bundle to S3, runs the deploy helper on EC2 via SSM, then verifies `/api/info` reports the new commit SHA |

Pull requests run everything except the AWS steps. `terraform.yml` runs `fmt`, `validate` and a Trivy config scan for infrastructure changes. **Rollback:** Actions → *Rollback* → enter a previously deployed commit SHA.

## 4. Monitoring

Prometheus scrapes five targets every 15 seconds. The **Cloud-Native Platform Overview** dashboard (auto-provisioned) has three sections:

- **Application health:** up/down, request rate, 5xx error rate, p50/p95/p99 latency, in-flight requests, Node.js heap and event-loop lag.
- **Infrastructure:** host CPU, memory, swap, disk usage, disk I/O, load average.
- **Containers and Nginx:** CPU and memory per Compose service, Nginx connections and request rate, scrape-target status.

Alert rules (`monitoring/prometheus/alert.rules.yml`) cover app down, high error rate, high p95 latency, host CPU/memory/disk and exporter outages. They show up in Prometheus and in the dashboard's "Active alerts" tile; add Alertmanager if you want notifications.

To trigger them for a demo, use the buttons in the web UI ("Trigger 10 server errors") or `scripts/load-test.sh`.

Prometheus is bound to `127.0.0.1` on the server. To view it from your laptop:

```bash
aws ssm start-session --target <instance-id> --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9090"],"localPortNumber":["9090"]}'
```

## 5. Security notes

- Only port 80 is open (restrict with `http_allowed_cidrs`); SSH is closed by default, use SSM Session Manager.
- IMDSv2 enforced, EBS and S3 encrypted, S3 public access blocked and TLS-only, ECR scan-on-push.
- Containers: non-root user, read-only filesystem, all capabilities dropped, memory limits.
- Nginx hides `/metrics`, rate-limits `/api/`, and only Grafana's login protects dashboards.
- The Grafana password is generated by Terraform and stored in SSM (it also exists in Terraform state, so use an encrypted remote backend: see `terraform/backend.tf.example`).

## 6. Cost and cleanup

A `t3.small`, 30 GB gp3 volume and Elastic IP cost roughly US$20-25 a month in `ap-south-1`. Use `t3.medium` if Prometheus and Grafana feel tight. To remove everything:

```bash
make tf-destroy
```

## Known limitations and next steps

- HTTP only. To add HTTPS, put the instance behind an ALB with an ACM certificate, or add Certbot/Caddy and open port 443.
- Single instance, no high availability. The natural upgrade is an ALB + Auto Scaling group, or ECS Fargate, using the same image and pipeline.
- Prometheus data lives on the instance's EBS volume (15-day retention).
- `node-exporter` runs on the Docker bridge network, so its network-interface metrics describe the container; CPU, memory and disk metrics are host-level.
- Add Alertmanager (Slack/email) and a CloudWatch status-check alarm for notifications.
