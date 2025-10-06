# SLEAP LabLink Deployment Checklist

Use this checklist to ensure you have completed all required setup steps before deploying SLEAP LabLink infrastructure.

## Pre-Deployment

### Repository Setup
- [x] Created repository from template ("Use this template" button)
- [x] Cloned repository to local machine
- [x] Reviewed README.md for overview

### GitHub Secrets Configuration
- [x] Added `AWS_ROLE_ARN` secret
  - Format: `arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME`
  - Verified IAM role exists and has correct permissions
  - Verified OIDC trust policy includes `talmolab/sleap-lablink` repository
- [x] Added `AWS_REGION` secret
  - Set to: `us-west-2`
  - Matches region in `config.yaml`
- [x] Added `ADMIN_PASSWORD` secret
  - Strong password (12+ characters, mixed case, numbers, symbols)
  - Different from DB_PASSWORD
- [x] Added `DB_PASSWORD` secret
  - Strong password (12+ characters, mixed case, numbers, symbols)
  - Different from ADMIN_PASSWORD

### AWS Setup

#### S3 Bucket for Terraform State
- [x] Created S3 bucket for Terraform state
  - Bucket name: `tf-state-lablink-allocator-bucket`
  - Bucket is globally unique
  - Bucket in same region as deployment (us-west-2)
- [x] Enabled versioning on S3 bucket (recommended)
- [x] Updated `bucket_name` in `config.yaml` to match

#### IAM Role and OIDC
- [x] Created OIDC identity provider (if not exists)
  - Provider URL: `https://token.actions.githubusercontent.com`
  - Audience: `sts.amazonaws.com`
- [x] Created IAM role for GitHub Actions
  - Trust policy includes `talmolab/sleap-lablink` repository path
  - Has PowerUserAccess or equivalent permissions:
    - EC2 full access
    - VPC management
    - S3 access (for state)
    - Route 53 (for DNS)
    - IAM (for instance profiles)
- [x] Verified role ARN matches `AWS_ROLE_ARN` secret

#### Elastic IP (Optional but Recommended)
- [x] Allocated Elastic IP in AWS
- [x] Tagged EIP with Name = `lablink-eip`
- [x] Updated `eip.tag_name` in `config.yaml` (using default "lablink-eip")
- [x] Using `eip.strategy: "persistent"` to reuse EIP across deployments

#### Route 53 DNS
- [x] Created or verified Route 53 hosted zone exists
  - Hosted zone: `lablink.sleap.ai`
  - Zone ID: `Z010760118DSWF5IYKMOM`
- [x] Updated domain nameservers to Route 53 NS records (if new zone)
- [x] Hardcoded zone ID in `config.yaml`
- [x] Updated `dns` section in `config.yaml`

### Configuration Customization

#### Edit `lablink-infrastructure/config/config.yaml`

**Machine/VM Settings:**
- [x] Updated `repository` URL to SLEAP tutorial data
  - Repository: `https://github.com/talmolab/sleap-tutorial-data.git`
- [x] Updated `software` name for SLEAP
  - Software: `sleap`
- [x] Updated `extension` for SLEAP data files
  - Extension: `slp`
- [x] Verified `machine_type` is appropriate for SLEAP workload
  - Type: `g4dn.xlarge` (GPU instance for ML)
- [x] Verified `ami_id` matches us-west-2 region
  - AMI: `ami-0601752c11b394251` (Ubuntu 24.04 + Docker + Nvidia)
- [x] Using Docker image: `ghcr.io/talmolab/lablink-client-base-image:linux-amd64-latest-test`

**Application Settings:**
- [x] Verified `region` matches `AWS_REGION` secret (us-west-2)
- [x] Confirmed `admin_user` is acceptable (default: "admin")

**DNS Settings:**
- [x] Set `enabled: true`
- [x] Updated `domain` to `lablink.sleap.ai`
- [x] Chose `pattern: "custom"` with subdomain `test`
  - Will create: `test.lablink.sleap.ai`
- [x] Set `zone_id: "Z010760118DSWF5IYKMOM"`
- [x] Set `terraform_managed: false` (manual DNS records in Route 53)

**SSL Settings:**
- [x] Set `provider: "letsencrypt"` for auto-SSL with Caddy
- [x] Updated `email` to `admin@sleap.ai` for Let's Encrypt notifications
- [x] Set `staging: true` for testing (HTTP only, unlimited deployments)
  - Note: Set to `false` for production HTTPS with trusted certs

**S3 Bucket:**
- [x] Updated `bucket_name` to `tf-state-lablink-allocator-bucket`

## Deployment

### Before Running Workflow
- [x] Reviewed all changes in `config.yaml`
- [ ] Committed and pushed changes to repository
- [x] Verified no sensitive data in committed files (passwords use PLACEHOLDER)

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
- [ ] Downloaded SSH key from workflow artifacts (`lablink-key-test`)
- [ ] Set correct permissions on key: `chmod 600 lablink-key.pem`
- [ ] Can SSH into allocator:
  ```bash
  ssh -i lablink-key.pem ubuntu@test.lablink.sleap.ai
  ```
- [ ] Can access allocator web interface:
  - URL: `http://test.lablink.sleap.ai` (HTTP only in staging mode)
  - Login works with admin credentials (username: `admin`)
- [ ] Admin dashboard loads correctly

### DNS Verification
- [ ] DNS resolves correctly:
  ```bash
  nslookup test.lablink.sleap.ai
  ```
- [ ] DNS points to correct Elastic IP
- [ ] Web interface accessible via domain name

### SSL Verification (Staging Mode)
- [ ] Note: `staging: true` means HTTP only (no SSL certificate)
- [ ] HTTP works without redirects to HTTPS
- [ ] For production, set `staging: false` to enable HTTPS with Let's Encrypt

### Functional Testing
- [ ] Can create a test client VM from admin dashboard
- [ ] Client VM provisions successfully with SLEAP configuration:
  - Instance type: `g4dn.xlarge` (GPU)
  - Docker image: `ghcr.io/talmolab/lablink-client-base-image:linux-amd64-latest-test`
  - SLEAP tutorial data cloned from repository
- [ ] Client VM appears in "View Instances" page
- [ ] Can access client VM via Chrome Remote Desktop
- [ ] SLEAP is available and functional on client VM
- [ ] Can open `.slp` files from tutorial data
- [ ] Can destroy client VM successfully

## Troubleshooting Failed Steps

### If AWS credentials fail:
1. Verify `AWS_ROLE_ARN` secret is correct
2. Check IAM role trust policy includes your repository
3. Verify OIDC provider exists in IAM

### If Terraform init fails:
1. Verify S3 bucket exists and is accessible: `tf-state-lablink-allocator-bucket`
2. Check bucket name in `config.yaml` matches actual bucket
3. Verify AWS region in secret matches bucket region (us-west-2)

### If Terraform apply fails:
1. Check error message for specific resource failing
2. Verify IAM role has necessary permissions for that resource
3. For AMI errors: Verify `ami-0601752c11b394251` exists in us-west-2
4. For network errors: Check VPC/subnet settings
5. For EIP errors: Verify EIP is tagged with `lablink-eip`

### If DNS doesn't resolve:
1. Wait 5-10 minutes for DNS propagation
2. Verify Route 53 hosted zone exists for `lablink.sleap.ai`
3. Check zone ID matches: `Z010760118DSWF5IYKMOM`
4. Verify nameservers at domain registrar match Route 53
5. Test DNS: `nslookup test.lablink.sleap.ai`

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
