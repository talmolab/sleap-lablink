# SLEAP LabLink Deployment Guide

This guide covers deploying SLEAP LabLink to Dev, Test, and Production environments.

📋 **Checklist**: See [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md) for detailed pre-deployment checklist
📚 **AWS Resources**: See [AWS_RESOURCES.md](AWS_RESOURCES.md) for EIPs, AMIs, and DNS details

---

## Environment Overview

| Aspect | Dev | Test | Prod |
|--------|-----|------|------|
| **Purpose** | Local development | Staging/pre-production | Production |
| **DNS** | None (IP only) | test.lablink.sleap.ai | lablink.sleap.ai |
| **URL** | http://\<IP\>:5000 | http://test.lablink.sleap.ai | https://lablink.sleap.ai |
| **EIP** | Dynamic (new each time) | sleap-lablink-eip-test<br/>54.214.215.124 *(pre-migration; will change after new EIP deploy)* | sleap-lablink-eip-prod<br/>44.224.160.186 *(pre-migration; will change after new EIP deploy)* |
| **SSL** | None (HTTP) | Staging (HTTP) | Let's Encrypt (HTTPS) |
| **State** | Local file | S3 backend | S3 backend |
| **Image Tag** | `latest-test` | `latest-test` | `latest` or version tag |
| **Deployment** | Local Terraform | GitHub Actions | GitHub Actions |
| **Rate Limits** | None | Unlimited | SSL: 5 certs/week |

**When to use:**
- **Dev**: Fast local iteration, testing infrastructure changes without AWS overhead
- **Test**: Pre-production staging, unlimited testing with persistent DNS
- **Prod**: Production deployment with HTTPS for end users

---

## Prerequisites

### One-Time Setup (Already Completed ✅)

- ✅ **AWS Resources**: EIPs, Route53, S3 bucket (see [AWS_RESOURCES.md](AWS_RESOURCES.md))
- ✅ **GitHub Secrets**: AWS_ROLE_ARN, AWS_REGION, ADMIN_PASSWORD, DB_PASSWORD
- ✅ **DNS Records**: test.lablink.sleap.ai and lablink.sleap.ai configured

### Required Tools

**For Dev (Local Deployment):**
- Terraform 1.6.6+
- AWS CLI configured with credentials
- Git

**For Test/Prod (GitHub Actions):**
- Git
- GitHub repository access
- Browser (to run workflows)

---

## Environment Configurations

Configuration is in [`lablink-infrastructure/config/config.yaml`](lablink-infrastructure/config/config.yaml) — a **single active file**. The environment (`test` or `prod`) is selected at deploy time via the `environment` workflow input. Reference flavors are available as `*.example.yaml` files in the same directory (e.g. `test.example.yaml`, `prod.example.yaml`).

### Dev Configuration

**Key Settings:**
```yaml
dns:
  enabled: false  # No DNS, use IP address only

eip:
  strategy: "dynamic"  # Creates new EIP each deployment

ssl:
  provider: "none"  # HTTP only, no SSL

machine:
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-f474d5bf1e8c4894c8c33bb903c613c7489e3574-test"
```

**Access**: `http://<EC2_PUBLIC_IP>:5000`

### Test Configuration

**Key Settings:**
```yaml
dns:
  enabled: true
  domain: "test.lablink.sleap.ai"

eip:
  strategy: "persistent"  # Reuses sleap-lablink-eip-test

ssl:
  provider: "none"  # HTTP only (unlimited deployments)

machine:
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-f474d5bf1e8c4894c8c33bb903c613c7489e3574-test"
```

**Access**: `http://test.lablink.sleap.ai`

### Production Configuration

Edit `config.yaml` before deploying to prod: pin `machine.image` to a versioned tag, pin `allocator.image_tag`, set `dns.domain=lablink.sleap.ai`, and set `ssl.provider=letsencrypt`.

**Key Settings:**
```yaml
dns:
  enabled: true
  domain: "lablink.sleap.ai"

eip:
  strategy: "persistent"  # Reuses sleap-lablink-eip-prod

ssl:
  provider: "letsencrypt"  # HTTPS with trusted certificates (RATE LIMITED)

machine:
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-<version>"
```

**Access**: `https://lablink.sleap.ai`

---

## Deployment Instructions

### Deploy to Dev (Local)

**1. Set local passwords in config.yaml:**
```yaml
db:
  password: "your-dev-db-password"  # Replace PLACEHOLDER

app:
  admin_password: "your-dev-admin-password"  # Replace PLACEHOLDER
```

**2. Initialize Terraform (run from `lablink-infrastructure/`):**
```bash
# From lablink-infrastructure/
../scripts/init-terraform.sh \
  dev
```

**3. Deploy:**
```bash
terraform plan -var="deployment_name=sleap-lablink" -var="environment=dev"
terraform apply -var="deployment_name=sleap-lablink" -var="environment=dev"
```

**4. Get access information:**
```bash
terraform output ec2_public_ip
# Access: http://<IP>:5000
```

**5. Verify:**
- SSH: `ssh -i lablink-key.pem ubuntu@<IP>`
- Web: Navigate to `http://<IP>:5000/admin`
- Login: username `admin`, password from step 1

**6. Destroy when done:**
```bash
terraform destroy -var="deployment_name=sleap-lablink" -var="environment=dev"
```

---

### Deploy to Test (GitHub Actions)

**1. Commit and push (test is the default active config — deploy as-is):**
```bash
git add config/config.yaml
git commit -m "Configure for test deployment"
git push
```

**2. Run GitHub Actions workflow:**
1. Go to **Actions** → **Deploy LabLink Infrastructure**
2. Click **Run workflow**
3. Select environment: **`test`**
4. Click **Run workflow**

**3. Monitor deployment** (~20-30 minutes):
- Watch workflow progress in GitHub Actions
- Look for ✅ green checkmarks on each step

**4. Download SSH key:**
- Go to workflow run → Artifacts
- Download `lablink-key-test`
- Extract `lablink-key.pem`

**5. Verify deployment:**

**DNS Resolution:**
```bash
nslookup test.lablink.sleap.ai
# Should return the IP from: terraform output -raw ec2_public_ip
# (Pre-migration IP was 54.214.215.124 — this will change after new sleap-lablink-eip-test is deployed)
```

**Web Access:**
- URL: `http://test.lablink.sleap.ai`
- Admin: `http://test.lablink.sleap.ai/admin`
- Login: username `admin`, password from GitHub secret

**SSH Access:**
```bash
chmod 600 lablink-key.pem
ssh -i lablink-key.pem ubuntu@test.lablink.sleap.ai
```

**Functional Test:**
1. Log into admin dashboard
2. Create test client VM
3. Wait for provisioning (~5 minutes)
4. Access via Chrome Remote Desktop
5. Verify SLEAP is available
6. Open tutorial data (.slp files)
7. Destroy test VM

---

### Deploy to Production (GitHub Actions)

**⚠️ Important**: Test in Test environment first before deploying to production!

**1. Edit `config.yaml` for production:** Set `machine.image` to a versioned tag, pin `allocator.image_tag`, set `dns.domain=lablink.sleap.ai`, and set `ssl.provider=letsencrypt`.

**2. (Optional) Use specific image version:**

Edit `config.yaml`:
```yaml
machine:
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-<version>"  # Specific version
```

Or use the current release tag:
```yaml
machine:
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-<version>"
```

**3. Commit and push:**
```bash
git add config/config.yaml
git commit -m "Configure for production deployment"
git push
```

**4. Run GitHub Actions workflow:**
1. Go to **Actions** → **Deploy LabLink Infrastructure**
2. Click **Run workflow**
3. Select environment: **`prod`**
4. Click **Run workflow**

**5. Monitor deployment** (~25-35 minutes):
- Deployment takes longer due to SSL certificate acquisition
- Watch for HTTPS/SSL validation steps

**6. Download SSH key:**
- Go to workflow run → Artifacts
- Download `lablink-key-prod`
- Extract `lablink-key.pem`

**7. Verify production deployment:**

**DNS Resolution:**
```bash
nslookup lablink.sleap.ai
# Should return the IP from: terraform output -raw ec2_public_ip
# (Pre-migration IP was 44.224.160.186 — this will change after new sleap-lablink-eip-prod is deployed)
```

**HTTPS Access:**
```bash
curl -I https://lablink.sleap.ai
# Should return: HTTP/2 200 (or 302 redirect)
```

**Web Access:**
- URL: `https://lablink.sleap.ai`
- Admin: `https://lablink.sleap.ai/admin`
- Login: username `admin`, password from GitHub secret
- Verify SSL certificate is valid (green padlock)

**SSH Access:**
```bash
chmod 600 lablink-key.pem
ssh -i lablink-key.pem ubuntu@lablink.sleap.ai
```

**Production Testing:**
1. Log into admin dashboard
2. Create production client VM
3. Verify SLEAP functionality
4. Document any issues
5. Keep VM for demonstration or destroy

---

## Post-Deployment

### Save Important Information

**For each environment, document:**
- [ ] Allocator URL
- [ ] Admin credentials location (GitHub secrets)
- [ ] SSH key location (store securely, don't commit!)
- [ ] Deployment date
- [ ] Docker image version used

### Update Team Documentation

- [ ] Share allocator URL with team
- [ ] Document access procedures
- [ ] Set up monitoring (optional)

---

## Switching Between Environments

The environment is selected at deploy time via the `environment` workflow input — there is no need to copy files. Edit `lablink-infrastructure/config/config.yaml` directly:

- **Test**: Deploy with `environment=test` as-is; `dns.domain` should be `test.lablink.sleap.ai` and `ssl.provider` `none`.
- **Prod**: Edit `config.yaml` to set `dns.domain=lablink.sleap.ai`, `ssl.provider=letsencrypt`, and pin image tags before deploying with `environment=prod`.

Reference `*.example.yaml` files in `lablink-infrastructure/config/` for per-flavor settings.

**Important**: Always commit the updated `config.yaml` before running GitHub Actions workflows!

---

## Destroying Infrastructure

### Destroy Dev (Local)

```bash
cd lablink-infrastructure
terraform destroy -var="deployment_name=sleap-lablink" -var="environment=dev"
```

### Destroy Test or Prod (GitHub Actions)

1. Go to **Actions** → **Destroy LabLink Infrastructure**
2. Click **Run workflow**
3. Type **`yes`** in confirm_destroy field
4. Select environment: `test` or `prod`
5. Click **Run workflow**

**⚠️ Warning**:
- This destroys all resources (EC2, security groups, etc.)
- DNS records persist (manual management)
- EIPs persist (will be unassociated)
- S3 state bucket persists

---

## Troubleshooting

### DNS Not Resolving

**Symptoms**: `nslookup` fails or returns wrong IP

**Solutions**:
1. Wait 5-10 minutes for DNS propagation
2. Verify DNS record exists in Route53
3. Check zone ID matches: `Z010760118DSWF5IYKMOM`
4. Verify nameservers at domain registrar

**Check:**
```bash
nslookup test.lablink.sleap.ai
nslookup lablink.sleap.ai
```

### SSL Certificate Not Obtained (Production)

**Symptoms**: HTTPS doesn't work, HTTP only

**Solutions**:
1. Wait 5-10 minutes for Let's Encrypt validation
2. Verify DNS resolves correctly first
3. Check Caddy logs:
   ```bash
   ssh ubuntu@lablink.sleap.ai
   sudo journalctl -u caddy -f
   ```
4. Verify ports 80 and 443 are accessible
5. Check if rate limit hit (5 certs/week)

**If rate limited**: Wait 7 days or switch `ssl.provider` to `none` or `cloudflare`

### Can't Access Web Interface

**Symptoms**: Connection timeout or refused

**Solutions**:
1. Verify EC2 instance is running in AWS console
2. Check security group allows inbound traffic:
   - Port 5000 (dev/test HTTP)
   - Port 80 (prod HTTP redirect)
   - Port 443 (prod HTTPS)
3. Verify allocator container is running:
   ```bash
   ssh ubuntu@<IP>
   docker ps
   docker logs <container-id>
   ```

### Wrong URL / Environment Mismatch

**Symptoms**: Deployed to wrong domain or IP

**Solutions**:
1. Verify correct `config.yaml` was committed
2. Check `dns.domain` setting:
   - Test: `"test.lablink.sleap.ai"`
   - Prod: `"lablink.sleap.ai"`
3. Verify correct environment selected in GitHub Actions
4. Check Terraform output:
   ```bash
   terraform output allocator_fqdn
   ```

### Terraform State Conflicts

**Symptoms**: "State locked" error

**Solutions**:
1. Wait for other operations to complete
2. Check DynamoDB lock table in AWS console
3. Force unlock (last resort):
   ```bash
   terraform force-unlock <LOCK_ID>
   ```

### GitHub Actions Authentication Failed

**Symptoms**: "Unable to assume role" error

**Solutions**:
1. Verify `AWS_ROLE_ARN` secret is correct
2. Check IAM role trust policy includes repository
3. Verify OIDC provider exists in AWS
4. Check IAM role has required permissions

---

## Best Practices

### Development Workflow

1. **Test locally (Dev)** → 2. **Deploy to Test** → 3. **Deploy to Prod**

### Configuration Management

- ✅ Use the `*.example.yaml` reference configs
- ✅ Keep `config.yaml` in version control
- ✅ Document which config is active
- ✅ Test config changes in Dev/Test first

### Production Deployments

- ✅ Use specific Docker image tags (not `latest-test`)
- ✅ Test in Test environment first
- ✅ Deploy during maintenance windows
- ✅ Monitor SSL certificate acquisition
- ✅ Keep SSH keys secure (don't commit!)
- ✅ Document deployment in team wiki

### Security

- ✅ Never commit passwords or keys
- ✅ Use GitHub secrets for sensitive values
- ✅ Rotate passwords regularly
- ✅ Use HTTPS in production (`ssl.provider: "letsencrypt"`)
- ✅ Restrict security group rules to known IPs (optional)

### Cost Management

- ✅ Destroy Dev environments when not in use
- ✅ Monitor AWS costs for Test/Prod
- ✅ EIPs cost $0.005/hour when not associated
- ✅ Consider instance scheduling for Test environment

---

## Additional Resources

- **Deployment Checklist**: [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md)
- **AWS Resources**: [AWS_RESOURCES.md](AWS_RESOURCES.md)
- **Main README**: [README.md](README.md)
- **LabLink Docs**: https://talmolab.github.io/lablink/
- **Infrastructure README**: [lablink-infrastructure/README.md](lablink-infrastructure/README.md)
- **GitHub Issues**: https://github.com/talmolab/lablink/issues

---

## Quick Reference

### Environment Access URLs

| Environment | URL | Admin Dashboard |
|-------------|-----|-----------------|
| Dev | `http://<IP>:5000` | `http://<IP>:5000/admin` |
| Test | `http://test.lablink.sleap.ai` | `http://test.lablink.sleap.ai/admin` |
| Prod | `https://lablink.sleap.ai` | `https://lablink.sleap.ai/admin` |

### SSH Access

```bash
# Dev
ssh -i lablink-key.pem ubuntu@<EC2_IP>

# Test
ssh -i lablink-key.pem ubuntu@test.lablink.sleap.ai
# or use IP from: terraform output -raw ec2_public_ip
# (Pre-migration IP was 54.214.215.124 — will change after new sleap-lablink-eip-test deploy)

# Prod
ssh -i lablink-key.pem ubuntu@lablink.sleap.ai
# or use IP from: terraform output -raw ec2_public_ip
# (Pre-migration IP was 44.224.160.186 — will change after new sleap-lablink-eip-prod deploy)
```

### Config File Comparison

Compare the active `config.yaml` against a reference flavor file, or review the prod changes needed:

```bash
# View differences between active config and a reference flavor
diff lablink-infrastructure/config/config.yaml lablink-infrastructure/config/prod.example.yaml

# Key differences (test → prod):
# - dns.domain: "test.lablink.sleap.ai" → "lablink.sleap.ai"
# - ssl.provider: "none" → "letsencrypt"
# - machine.image: latest-test → versioned tag
```
