# LabLink Infrastructure Template

> **GitHub Template Repository** for deploying LabLink infrastructure to AWS

[![License](https://img.shields.io/badge/License-BSD%202--Clause-orange.svg)](https://opensource.org/licenses/BSD-2-Clause)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-purple.svg)](https://www.terraform.io/)

Deploy your own LabLink infrastructure for cloud-based VM allocation and management. This template uses Terraform and GitHub Actions to automate deployment of the LabLink allocator service to AWS.

📖 **Main Documentation**: https://talmolab.github.io/lablink/

## What is LabLink?

LabLink automates deployment and management of cloud-based VMs for running research software. It provides:
- **Web interface** for requesting and managing VMs
- **Automatic VM provisioning** with your software pre-installed
- **GPU support** for ML/AI workloads
- **Chrome Remote Desktop** access to VM GUI
- **Flexible configuration** for different research needs

## Quick Start

### 1. Use This Template

Click the **"Use this template"** button at the top of this repository to create your own deployment repository.

### 2. Set Up GitHub Secrets

Go to your repository → Settings → Secrets and variables → Actions, and add these secrets:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `AWS_ROLE_ARN` | IAM role ARN for GitHub Actions OIDC | `arn:aws:iam::123456789012:role/github-actions-role` |
| `AWS_REGION` | AWS region for deployment | `us-west-2` |
| `ADMIN_PASSWORD` | Password for allocator web interface | `your-secure-password` |
| `DB_PASSWORD` | PostgreSQL database password | `your-secure-db-password` |

### 3. Configure Your Deployment

Edit [`lablink-infrastructure/config/config.yaml`](lablink-infrastructure/config/config.yaml):

```yaml
# Update these values for your deployment:
machine:
  repository: "https://github.com/YOUR_ORG/YOUR_DATA_REPO.git"
  software: "your-software-name"
  extension: "your-file-ext"

dns:
  enabled: true  # Set to true if using custom domain
  domain: "your-domain.com"

bucket_name: "tf-state-YOUR-ORG-lablink"  # Must be globally unique
```

See [Configuration Reference](#configuration-reference) for all options.

### 4. Deploy

**Via GitHub Actions (Recommended):**
1. Go to Actions → "Deploy LabLink Infrastructure"
2. Click "Run workflow"
3. Select environment (`test` or `prod`)
4. Click "Run workflow"

**Via Local Terraform:**
```bash
cd lablink-infrastructure
terraform init -backend-config=backend-test.hcl
terraform apply
```

### 5. Access Your Infrastructure

After deployment completes:
- **Allocator URL**: Check workflow output or Terraform output for the URL/IP
- **SSH Access**: Download the PEM key from workflow artifacts
- **Web Interface**: Navigate to allocator URL in your browser

## Prerequisites

### Required

- **AWS Account** with permissions to create:
  - EC2 instances
  - Security Groups
  - Elastic IPs
  - (Optional) Route 53 records for DNS

- **GitHub Account** with ability to:
  - Create repositories from templates
  - Configure GitHub Actions secrets
  - Run GitHub Actions workflows

- **Basic Knowledge** of:
  - Terraform (helpful but not required)
  - AWS services

### AWS Setup Required

Before deploying, you must set up:

1. **S3 Bucket** for Terraform state storage
2. **IAM Role** for GitHub Actions OIDC authentication
3. **(Optional) Elastic IP** for persistent allocator address
4. **(Optional) Route 53 Hosted Zone** for custom domain

See [AWS Setup Guide](#aws-setup-guide) below for detailed instructions.

## GitHub Secrets Setup

### AWS_ROLE_ARN

Create an IAM role with OIDC provider for GitHub Actions:

1. Create OIDC provider in IAM (if not exists):
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`

2. Create IAM role with trust policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringLike": {
             "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
           }
         }
       }
     ]
   }
   ```

3. Attach permissions:
   - `PowerUserAccess` (or custom policy with EC2, VPC, S3, Route53, IAM permissions)

4. Copy the Role ARN and add to GitHub secrets

### AWS_REGION

The AWS region where your infrastructure will be deployed. Must match the region in your `config.yaml`.

Common regions:
- `us-west-2` (Oregon)
- `us-east-1` (N. Virginia)
- `eu-west-1` (Ireland)

**Important**: AMI IDs are region-specific. If you change regions, update the `ami_id` in `config.yaml`.

### ADMIN_PASSWORD

Password for accessing the allocator web interface. Choose a strong password (12+ characters, mixed case, numbers, symbols).

This password is used to log in to the admin dashboard where you can:
- Create and destroy client VMs
- View VM status
- Assign VMs to users

### DB_PASSWORD

Password for the PostgreSQL database used by the allocator service. Choose a different strong password than `ADMIN_PASSWORD`.

This is stored securely and injected into the configuration at deployment time.

## AWS Setup Guide

### 1. Create S3 Bucket for Terraform State

```bash
# Create bucket (must be globally unique)
aws s3 mb s3://tf-state-YOUR-ORG-lablink --region us-west-2

# Enable versioning (recommended)
aws s3api put-bucket-versioning \
  --bucket tf-state-YOUR-ORG-lablink \
  --versioning-configuration Status=Enabled
```

Update `bucket_name` in `lablink-infrastructure/config/config.yaml` to match.

### 2. (Optional) Allocate Elastic IP

For persistent allocator IP address across deployments:

```bash
# Allocate EIP
aws ec2 allocate-address --domain vpc --region us-west-2

# Tag it for reuse
aws ec2 create-tags \
  --resources eipalloc-XXXXXXXX \
  --tags Key=Name,Value=lablink-eip
```

Update `eip.tag_name` in `config.yaml` if using a different tag name.

### 3. (Optional) Set Up Route 53 for DNS

If using a custom domain:

1. Create or use existing hosted zone:
   ```bash
   aws route53 create-hosted-zone --name your-domain.com --caller-reference $(date +%s)
   ```

2. Update your domain's nameservers to point to Route 53 NS records

3. Update `dns` section in `config.yaml`:
   ```yaml
   dns:
     enabled: true
     domain: "your-domain.com"
     zone_id: "Z..." # Optional - will auto-lookup if empty
   ```

### 4. Set Up OIDC Provider and IAM Role

See [GitHub Secrets Setup](#github-secrets-setup) above for detailed IAM role configuration.

## Configuration Reference

All configuration is in `lablink-infrastructure/config/config.yaml`.

### Database Settings

```yaml
db:
  dbname: "lablink_db"
  user: "lablink"
  password: "PLACEHOLDER_DB_PASSWORD"  # Injected from GitHub secret
  host: "localhost"
  port: 5432
```

### Client VM Settings

```yaml
machine:
  machine_type: "g4dn.xlarge"  # AWS instance type
  image: "ghcr.io/talmolab/lablink-client-base-image:latest"  # Docker image
  ami_id: "ami-0601752c11b394251"  # Region-specific AMI
  repository: "https://github.com/YOUR_ORG/YOUR_REPO.git"  # Your code/data repo
  software: "your-software"  # Software identifier
  extension: "ext"  # Data file extension
```

**Instance Types**:
- `g4dn.xlarge` - GPU instance (NVIDIA T4, good for ML)
- `t3.large` - CPU-only, cheaper
- `p3.2xlarge` - More powerful GPU (NVIDIA V100)

**AMI IDs** (Ubuntu 24.04 with Docker + Nvidia):
- `us-west-2`: `ami-0601752c11b394251`
- Other regions: Use AWS Console to find similar AMI or create custom

### Application Settings

```yaml
app:
  admin_user: "admin"
  admin_password: "PLACEHOLDER_ADMIN_PASSWORD"  # Injected from secret
  region: "us-west-2"  # Must match AWS_REGION secret
```

### DNS Settings

```yaml
dns:
  enabled: false  # true to use DNS, false for IP-only
  terraform_managed: false  # true = Terraform creates records
  domain: "lablink.example.com"
  zone_id: ""  # Leave empty for auto-lookup
  app_name: "lablink"
  pattern: "auto"  # "auto" or "custom"
```

**DNS Patterns**:
- `auto`: Creates `{env}.{app_name}.{domain}` (e.g., `test.lablink.example.com`)
- `custom`: Uses `custom_subdomain` value

### SSL/TLS Settings

```yaml
ssl:
  provider: "none"  # "letsencrypt", "cloudflare", or "none"
  email: "admin@example.com"  # For Let's Encrypt notifications
  staging: true  # true = staging certs, false = production certs
```

**SSL Providers**:
- `none`: HTTP only (for testing)
- `letsencrypt`: Automatic SSL with Caddy
- `cloudflare`: Use CloudFlare proxy for SSL

### Elastic IP Settings

```yaml
eip:
  strategy: "persistent"  # "persistent" or "dynamic"
  tag_name: "lablink-eip"  # Tag to find reusable EIP
```

## Deployment Workflows

### Deploy LabLink Infrastructure

Deploys or updates your LabLink infrastructure.

**Triggers**:
- Manual: Actions → "Deploy LabLink Infrastructure" → Run workflow
- Automatic: Push to `test` branch

**Inputs**:
- `environment`: `test` or `prod`
- `image_tag`: (Optional) Specific Docker image tag for prod

**What it does**:
1. Configures AWS credentials via OIDC
2. Injects passwords from GitHub secrets into config
3. Runs Terraform to create/update infrastructure
4. Verifies deployment and DNS
5. Uploads SSH key as artifact

### Destroy LabLink Infrastructure

**⚠️ WARNING**: This destroys all infrastructure and data!

**Triggers**:
- Manual only: Actions → "Destroy LabLink Infrastructure" → Run workflow

**Inputs**:
- `confirm_destroy`: Must type "yes" to confirm
- `environment`: `test` or `prod`

### Test Client VM Infrastructure

Tests that client VMs can be provisioned correctly.

**Triggers**:
- Manual only

## Customization

### For Different Research Software

1. Update `config.yaml`:
   ```yaml
   machine:
     repository: "https://github.com/your-org/your-software-data.git"
     software: "your-software-name"
     extension: "your-file-ext"  # e.g., "h5", "npy", "csv"
   ```

2. (Optional) Use custom Docker image:
   ```yaml
   machine:
     image: "ghcr.io/your-org/your-custom-image:latest"
   ```

### For Different AWS Regions

1. Update `config.yaml`:
   ```yaml
   app:
     region: "eu-west-1"  # Your region
   machine:
     ami_id: "ami-XXXXXXX"  # Region-specific AMI
   ```

2. Update GitHub secret `AWS_REGION`

3. Find appropriate AMI for region (Ubuntu 24.04 with Docker)

### For Different Instance Types

```yaml
machine:
  machine_type: "t3.xlarge"  # No GPU, cheaper
  # or
  machine_type: "p3.2xlarge"  # More powerful GPU
```

See [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/) for options.

## Troubleshooting

### Deployment Fails with "InvalidAMI"

**Cause**: AMI ID doesn't exist in your region

**Solution**: Update `ami_id` in `config.yaml` with a region-appropriate AMI

### Cannot Access Allocator Web Interface

**Cause**: Security group or DNS not configured

**Solution**:
1. Check security group allows inbound traffic on port 5000
2. If using DNS, verify DNS records propagated
3. Try accessing via public IP first

### Terraform State Lock Error

**Cause**: Previous deployment didn't complete or cleanup

**Solution**:
```bash
# In lablink-infrastructure/
terraform force-unlock LOCK_ID
```

### DNS Not Resolving

**Cause**: DNS propagation delay or Route 53 not configured

**Solution**:
1. Wait 5-10 minutes for propagation
2. Verify Route 53 hosted zone exists
3. Check nameservers match at domain registrar
4. Use `nslookup your-domain.com` to test

### More Help

- **Main Documentation**: https://talmolab.github.io/lablink/
- **Infrastructure Docs**: [lablink-infrastructure/README.md](lablink-infrastructure/README.md)
- **GitHub Issues**: https://github.com/talmolab/lablink/issues
- **Deployment Checklist**: [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md)

## Project Structure

```
lablink-template/
├── .github/workflows/          # GitHub Actions workflows
│   ├── terraform-deploy.yml    # Deploy infrastructure
│   ├── terraform-destroy.yml   # Destroy infrastructure
│   └── client-vm-infrastructure-test.yml
├── lablink-infrastructure/     # Terraform infrastructure
│   ├── config/
│   │   ├── config.yaml         # Main configuration
│   │   └── example.config.yaml # Configuration reference
│   ├── main.tf                 # Core Terraform config
│   ├── backend.tf              # Terraform backend
│   ├── backend-*.hcl           # Environment-specific backends
│   ├── terraform.tfvars        # Terraform variables
│   ├── user_data.sh            # EC2 initialization script
│   ├── verify-deployment.sh    # Deployment verification
│   └── README.md               # Infrastructure documentation
├── README.md                   # This file
├── DEPLOYMENT_CHECKLIST.md     # Pre-deployment checklist
└── LICENSE
```

## Contributing

Found an issue with the template or want to suggest improvements?

1. Open an issue: https://github.com/talmolab/lablink-template/issues
2. For LabLink core issues: https://github.com/talmolab/lablink/issues

## License

BSD 2-Clause License - see [LICENSE](LICENSE) file for details.

## Links

- **Main LabLink Repository**: https://github.com/talmolab/lablink
- **Documentation**: https://talmolab.github.io/lablink/
- **Template Repository**: https://github.com/talmolab/lablink-template
- **Example Deployment**: https://github.com/talmolab/sleap-lablink (SLEAP-specific configuration)

---

**Need Help?** Check the [Deployment Checklist](DEPLOYMENT_CHECKLIST.md) or [Troubleshooting](#troubleshooting) section above.
