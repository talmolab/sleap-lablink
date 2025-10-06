# AWS Resources for SLEAP LabLink

This document lists all pre-provisioned AWS resources for SLEAP LabLink deployment in us-west-2.

## Elastic IP Addresses

### Test Environment
- **Name Tag**: `lablink-eip-test`
- **IP Address**: `54.214.215.124`
- **Allocation ID**: `eipalloc-0fc32cd69d36f45dd`
- **Region**: `us-west-2`
- **Status**: Public IP

### Production Environment
- **Name Tag**: `lablink-eip-prod`
- **IP Address**: `44.224.160.186`
- **Allocation ID**: `eipalloc-0dac4adf5f4b71e4d`
- **Region**: `us-west-2`
- **Status**: Public IP

## Amazon Machine Images (AMIs)

### Client VM AMI (GPU-enabled)
- **AMI ID**: `ami-0601752c11b394251`
- **Name**: Custom Ubuntu 24.04 with Docker + Nvidia GPU Driver
- **Description**: Pre-installed Docker and Nvidia GPU drivers for ML workloads
- **Architecture**: x86_64
- **Platform**: Linux/UNIX
- **Base Image**: Ubuntu Server 24.04 LTS (HVM), SSD Volume Type
- **Region**: us-west-2
- **Use Case**: Client VMs for SLEAP GPU processing

### Allocator VM AMI
- **AMI ID**: `ami-0bd08c9d4aa9f0bc6`
- **Name**: Custom Ubuntu 24.04 with Docker
- **Description**: Pre-installed Docker for allocator service
- **Architecture**: x86_64
- **Platform**: Linux/UNIX
- **Base Image**: Ubuntu Server 24.04 LTS (HVM), SSD Volume Type
- **Region**: us-west-2
- **Use Case**: Allocator EC2 instance

## Route 53 DNS

### Hosted Zone
- **Domain**: `lablink.sleap.ai`
- **Zone ID**: `Z010760118DSWF5IYKMOM`
- **Type**: Public hosted zone
- **Region**: Global (Route 53)
- **Nameservers**:
  - `ns-158.awsdns-19.com`
  - `ns-697.awsdns-23.net`
  - `ns-1839.awsdns-37.co.uk`
  - `ns-1029.awsdns-00.org`

### DNS Records (Current)

#### NS Record
- **Name**: `lablink.sleap.ai`
- **Type**: NS (Nameserver)
- **TTL**: 172800 seconds
- **Values**: See nameservers above

#### SOA Record
- **Name**: `lablink.sleap.ai`
- **Type**: SOA (Start of Authority)
- **TTL**: 900 seconds
- **Value**: `ns-158.awsdns-19.com. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400`

#### ACM Validation
- **Name**: `_fc70af18a10e573b77526e702016d905.lablink.sleap.ai`
- **Type**: CNAME
- **TTL**: 300 seconds
- **Value**: `_cd1ccc9bf6b75b2c4e055c6fea073515.xlfgrmvvlj.acm-validations.aws.`
- **Purpose**: AWS Certificate Manager SSL certificate validation

#### Test Environment
- **Name**: `test.lablink.sleap.ai`
- **Type**: A (Address)
- **TTL**: 300 seconds
- **Value**: `54.214.215.124` (lablink-eip-test)
- **Status**: ✅ **CONFIGURED**

#### Production Environment (Root Domain)
- **Name**: `lablink.sleap.ai` (root domain)
- **Type**: A (Address)
- **TTL**: 300 seconds
- **Value**: `44.224.160.186` (lablink-eip-prod)
- **Status**: ✅ **CONFIGURED**

### DNS Management Strategy

**Current Configuration**: `terraform_managed: false`

This means:
- ✅ A records are manually created in Route 53 console
- ✅ DNS records persist even if you run `terraform destroy`
- ✅ Full control over DNS changes
- ⚠️ You must manually update records if EIP changes

**Environment to DNS Mapping:**
- **Test**: `test.lablink.sleap.ai` → `54.214.215.124`
  - Config: `custom_subdomain: "test"`
- **Production**: `lablink.sleap.ai` → `44.224.160.186`
  - Config: `custom_subdomain: ""` (empty = root domain)

**Alternative - Terraform-Managed DNS:**
If you prefer Terraform to create/destroy records automatically:
1. Set `terraform_managed: true` in config.yaml
2. Terraform will create A records during deployment
3. ⚠️ Terraform will DELETE A records during destroy

## S3 Bucket

### Terraform State Storage
- **Bucket Name**: `tf-state-lablink-allocator-bucket`
- **Region**: `us-west-2`
- **Versioning**: Enabled (recommended)
- **Purpose**: Stores Terraform state for test and prod environments
- **Access**: Via IAM role with GitHub Actions OIDC

## GitHub Secrets

The following secrets must be configured in the GitHub repository:

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `AWS_ROLE_ARN` | IAM role for OIDC authentication | `arn:aws:iam::ACCOUNT_ID:role/github-actions-role` |
| `AWS_REGION` | AWS deployment region | `us-west-2` |
| `ADMIN_PASSWORD` | Allocator web interface password | `[secure password]` |
| `DB_PASSWORD` | PostgreSQL database password | `[secure password]` |

## Notes

### EIP Tag Naming Convention
- Terraform automatically appends the environment suffix to EIP tag names
- Config uses `tag_name: "lablink-eip"` → Terraform looks for `lablink-eip-test` or `lablink-eip-prod`
- No need to include environment suffix in config.yaml

### AMI Updates
- AMIs are custom-built and maintained by the SLEAP team
- Both AMIs are based on Ubuntu 24.04 LTS
- Client AMI includes Nvidia GPU drivers for GPU instance types
- Update AMI IDs in config.yaml if new versions are created

### Resource Dependencies
- EIPs must exist before Terraform deployment
- Route 53 hosted zone must exist before DNS-enabled deployments
- S3 bucket must exist before running Terraform with S3 backend
- IAM role must be created and configured with OIDC trust policy

## Maintenance

### Updating Resources
1. **EIPs**: Persistent across deployments - do not delete unless decommissioning environment
2. **AMIs**: Update config.yaml when new AMIs are created
3. **DNS**: Managed by Terraform when `terraform_managed: false` - update manually in Route 53
4. **S3 State**: Enable versioning for rollback capability

### Cost Considerations
- EIPs: No charge while associated with running instances
- EIPs: $0.005/hour when not associated with running instances
- S3 State Storage: Minimal cost for state files
- Route 53: $0.50/month per hosted zone + query charges
