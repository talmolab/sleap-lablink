# LabLink Deployment Checklist

Use this checklist to ensure you have completed all required setup steps before deploying LabLink infrastructure.

## Pre-Deployment

### Repository Setup
- [ ] Created repository from template ("Use this template" button)
- [ ] Cloned repository to local machine
- [ ] Reviewed README.md for overview

### GitHub Secrets Configuration
- [ ] Added `AWS_ROLE_ARN` secret
  - Format: `arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME`
  - Verified IAM role exists and has correct permissions
  - Verified OIDC trust policy includes your repository
- [ ] Added `AWS_REGION` secret
  - Example: `us-west-2`, `us-east-1`, `eu-west-1`
  - Matches region in `config.yaml`
- [ ] Added `ADMIN_PASSWORD` secret
  - Strong password (12+ characters, mixed case, numbers, symbols)
  - Different from DB_PASSWORD
- [ ] Added `DB_PASSWORD` secret
  - Strong password (12+ characters, mixed case, numbers, symbols)
  - Different from ADMIN_PASSWORD

### AWS Setup

#### S3 Bucket for Terraform State
- [ ] Created S3 bucket for Terraform state
  - Bucket name format: `tf-state-YOUR-ORG-lablink`
  - Bucket is globally unique
  - Bucket in same region as deployment
- [ ] Enabled versioning on S3 bucket (recommended)
- [ ] Updated `bucket_name` in `config.yaml` to match

#### IAM Role and OIDC
- [ ] Created OIDC identity provider (if not exists)
  - Provider URL: `https://token.actions.githubusercontent.com`
  - Audience: `sts.amazonaws.com`
- [ ] Created IAM role for GitHub Actions
  - Trust policy includes your repository path
  - Has PowerUserAccess or equivalent permissions:
    - EC2 full access
    - VPC management
    - S3 access (for state)
    - Route 53 (if using DNS)
    - IAM (for instance profiles)
- [ ] Verified role ARN matches `AWS_ROLE_ARN` secret

#### Elastic IP (Optional but Recommended)
- [ ] Allocated Elastic IP in AWS
- [ ] Tagged EIP with Name = `lablink-eip` (or custom name)
- [ ] Updated `eip.tag_name` in `config.yaml` if using custom tag
- [ ] Or set `eip.strategy: "dynamic"` to create new IP each time

#### Route 53 DNS (Optional)
- [ ] Created or verified Route 53 hosted zone exists
- [ ] Updated domain nameservers to Route 53 NS records (if new zone)
- [ ] Noted zone ID or left empty for auto-lookup
- [ ] Updated `dns` section in `config.yaml`

### Configuration Customization

#### Edit `lablink-infrastructure/config/config.yaml`

**Machine/VM Settings:**
- [ ] Updated `repository` URL to your data/code repository
  - Or set to empty string if not needed
- [ ] Updated `software` name for your application
- [ ] Updated `extension` for your data file type
- [ ] Verified `machine_type` is appropriate for your workload
- [ ] Verified `ami_id` matches your AWS region
- [ ] (Optional) Updated `image` if using custom Docker image

**Application Settings:**
- [ ] Verified `region` matches `AWS_REGION` secret
- [ ] Confirmed `admin_user` is acceptable (default: "admin")

**DNS Settings** (if using DNS):
- [ ] Set `enabled: true`
- [ ] Updated `domain` to your domain name
- [ ] Chose `pattern`: "auto" or "custom"
- [ ] Set `zone_id` (or left empty for auto-lookup)
- [ ] Set `terraform_managed` based on preference
  - `true` = Terraform creates/destroys DNS records
  - `false` = You manually create DNS records in Route 53

**SSL Settings** (if using SSL):
- [ ] Set `provider`: "letsencrypt", "cloudflare", or "none"
- [ ] Updated `email` for Let's Encrypt notifications
- [ ] Set `staging: false` for production SSL certs
  - Keep `staging: true` for testing (unlimited rate)

**S3 Bucket:**
- [ ] Updated `bucket_name` to match created S3 bucket

## Deployment

### Before Running Workflow
- [ ] Reviewed all changes in `config.yaml`
- [ ] Committed and pushed changes to repository
- [ ] Verified no sensitive data in committed files

### Run Deployment
- [ ] Navigated to Actions → "Deploy LabLink Infrastructure"
- [ ] Clicked "Run workflow"
- [ ] Selected environment: `test` (first time) or `prod`
- [ ] Started workflow

### Monitor Deployment
- [ ] Workflow started successfully
- [ ] No errors in "Configure AWS credentials" step
- [ ] No errors in "Terraform Init" step
- [ ] No errors in "Terraform Apply" step
- [ ] Deployment completed successfully

## Post-Deployment Verification

### Infrastructure Created
- [ ] EC2 instance for allocator is running in AWS console
- [ ] Security group created and attached to instance
- [ ] Elastic IP associated with instance (if using)
- [ ] (If DNS) Route 53 record created or verified

### Access Verification
- [ ] Downloaded SSH key from workflow artifacts
- [ ] Set correct permissions on key: `chmod 600 lablink-key.pem`
- [ ] Can SSH into allocator:
  ```bash
  ssh -i lablink-key.pem ubuntu@<ALLOCATOR_IP_OR_DOMAIN>
  ```
- [ ] Can access allocator web interface:
  - URL: `http://<ALLOCATOR_IP_OR_DOMAIN>:5000` (or HTTPS if SSL enabled)
  - Login works with admin credentials
- [ ] Admin dashboard loads correctly

### DNS Verification (if using DNS)
- [ ] DNS resolves correctly:
  ```bash
  nslookup your-domain.com
  ```
- [ ] DNS points to correct Elastic IP or instance IP
- [ ] Web interface accessible via domain name

### SSL Verification (if using SSL)
- [ ] HTTPS works without certificate errors
- [ ] Certificate is from Let's Encrypt (or CloudFlare)
- [ ] Force HTTPS redirect works (if configured)

### Functional Testing
- [ ] Can create a test client VM from admin dashboard
- [ ] Client VM provisions successfully
- [ ] Client VM appears in "View Instances" page
- [ ] Can access client VM via Chrome Remote Desktop
- [ ] Can destroy client VM successfully

## Troubleshooting Failed Steps

### If AWS credentials fail:
1. Verify `AWS_ROLE_ARN` secret is correct
2. Check IAM role trust policy includes your repository
3. Verify OIDC provider exists in IAM

### If Terraform init fails:
1. Verify S3 bucket exists and is accessible
2. Check bucket name in `config.yaml` matches actual bucket
3. Verify AWS region in secret matches bucket region

### If Terraform apply fails:
1. Check error message for specific resource failing
2. Verify IAM role has necessary permissions for that resource
3. For AMI errors: Update `ami_id` for your region
4. For network errors: Check VPC/subnet settings

### If DNS doesn't resolve:
1. Wait 5-10 minutes for DNS propagation
2. Verify Route 53 hosted zone exists
3. Check zone ID matches (or is empty for auto-lookup)
4. Verify nameservers at domain registrar match Route 53

### If can't access web interface:
1. Check security group allows inbound on port 5000
2. Try IP address instead of domain
3. Check allocator service is running:
   ```bash
   ssh ubuntu@<IP> "docker ps"
   ```
4. Check logs:
   ```bash
   ssh ubuntu@<IP> "docker logs <CONTAINER_ID>"
   ```

## After Successful Deployment

- [ ] Documented allocator URL/IP for team
- [ ] Stored SSH key securely
- [ ] Set up monitoring/alerts (if needed)
- [ ] Created test users/VMs to verify functionality
- [ ] (Optional) Set up automatic backups of Terraform state
- [ ] (Optional) Set up CloudWatch alarms for EC2 instance

## Ongoing Maintenance

- [ ] Regularly update Docker images to latest versions
- [ ] Monitor AWS costs
- [ ] Review security group rules periodically
- [ ] Update AMI when new versions available
- [ ] Renew SSL certificates (automatic with Let's Encrypt)
- [ ] Back up Terraform state regularly

## Need Help?

- [ ] Checked [README.md](README.md) troubleshooting section
- [ ] Reviewed [lablink-infrastructure/README.md](lablink-infrastructure/README.md)
- [ ] Consulted main docs: https://talmolab.github.io/lablink/
- [ ] Searched existing issues: https://github.com/talmolab/lablink/issues
- [ ] Created new issue if problem persists

---

**Deployment Date**: _________________

**Deployed By**: _________________

**Environment**: [ ] Test  [ ] Prod

**Notes**:
