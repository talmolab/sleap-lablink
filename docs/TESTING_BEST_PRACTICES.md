# LabLink Testing Best Practices

This guide provides recommendations for testing LabLink infrastructure deployments without hitting AWS or Let's Encrypt limits.

## Testing Environments

LabLink supports multiple deployment environments:

| Environment | State Storage | Use Case | SSL Recommendation |
|-------------|---------------|----------|-------------------|
| `dev` | Local file | Local development | IP-only (no SSL) |
| `test` | S3 | Staging/pre-production | CloudFlare or rotated subdomains |
| `prod` | S3 | Production | Let's Encrypt (stable domain) |
| `ci-test` | S3 | Template maintainers only | Use sparingly with Let's Encrypt |

## Let's Encrypt Rate Limits

### Understanding the Limits

Let's Encrypt production environment has strict rate limits:

| Limit Type | Limit | Applies To | Lockout Period | Override? |
|------------|-------|------------|----------------|-----------|
| Certificates per Exact Set | 5 | Same domain (e.g., `test.example.com`) | 7 days | No |
| Certificates per Registered Domain | 50 | All subdomains (e.g., `*.example.com`) | 7 days | Yes (by request) |
| New Orders | 300 | Per account | 3 hours | Yes (by request) |

**Most Important**: The "5 certificates per exact domain" limit is the one most likely to impact testing, and **there is no override available**.

### What Triggers a New Certificate?

Each of these actions triggers a new certificate issuance:
- Deploying with `terraform apply` (first time or after destroy)
- Re-deploying after DNS changes
- Re-deploying after changing the domain name
- Caddy container restart with lost certificate cache

### Rate Limit-Friendly Testing Strategies

#### Strategy 1: IP-Only Development (Recommended for Dev)

**Best for**: Local testing, development, proof-of-concept

```yaml
dns:
  enabled: false

ssl:
  provider: "none"

eip:
  strategy: "dynamic"
```

**Pros**:
- No DNS or SSL rate limits
- Fast deployments
- No external dependencies

**Cons**:
- HTTP only (no HTTPS testing)
- Different from production setup
- Must use IP address

**When to use**:
- Testing infrastructure changes
- Debugging Terraform configurations
- Validating basic functionality

---

#### Strategy 2: Subdomain Rotation (For SSL Testing)

**Best for**: Testing SSL functionality without hitting limits

**Approach**: Use different subdomains for each test deployment:

```yaml
# Test 1
dns:
  domain: "test1.lablink.example.com"

# Test 2
dns:
  domain: "test2.lablink.example.com"

# Test 3
dns:
  domain: "test3.lablink.example.com"
```

**Pros**:
- Tests full production-like setup
- Can test up to 50 times before hitting registered domain limit
- Each subdomain gets 5 attempts

**Cons**:
- Requires cleanup of DNS records
- More complex to manage
- Still counts toward registered domain limit

**When to use**:
- Testing SSL/HTTPS functionality
- Validating DNS propagation
- Pre-production testing

---

#### Strategy 3: CloudFlare SSL (No Rate Limits)

**Best for**: Frequent testing with HTTPS

```yaml
dns:
  enabled: true
  terraform_managed: false
  domain: "test.example.com"

ssl:
  provider: "cloudflare"

eip:
  strategy: "persistent"
```

**Pros**:
- No Let's Encrypt rate limits
- CloudFlare provides DDoS protection
- SSL termination at edge

**Cons**:
- Requires CloudFlare account
- Manual DNS record creation
- Different SSL provider than production (if using Let's Encrypt)

**When to use**:
- Frequent redeployments
- Testing with HTTPS enabled
- When DDoS protection is needed

---

## Recommended Testing Workflow

### Phase 1: Local Development
1. Use `dev` environment with IP-only deployment
2. Test basic infrastructure provisioning
3. Validate Terraform configurations
4. No SSL or DNS

### Phase 2: Staging Testing
1. Use `test` environment with CloudFlare SSL OR subdomain rotation
2. Test DNS resolution and SSL
3. Validate end-to-end workflow
4. Deploy infrequently (1-2 times per week max if using Let's Encrypt)

### Phase 3: Production Deployment
1. Use `prod` environment with stable domain
2. Let's Encrypt production certificates
3. Persistent EIP
4. Minimal redeployments

## Monitoring Certificate Usage

### Check Issued Certificates

Visit [crt.sh](https://crt.sh/) to see all certificates issued for your domain:

```
https://crt.sh/?q=example.com
```

This shows:
- How many certificates issued
- When they were issued
- When they expire
- How close you are to rate limits

### Calculate Remaining Quota

For a given domain, check the last 7 days:
1. Go to crt.sh with your exact domain
2. Count certificates issued in last 7 days
3. Calculate: 5 - (certificates in last 7 days) = remaining quota

Example:
- Domain: `test.lablink.example.com`
- Certificates in last 7 days: 3
- Remaining quota: 5 - 3 = **2 certificates left**

## What to Do If You Hit Rate Limits

If you see this error:
```
too many certificates already issued for exact set of domains
```

**Options:**

1. **Wait 7 days** - Rate limit window rolls on a sliding 7-day basis
2. **Use different subdomain** - Switch to `test2.lablink.example.com`
3. **Switch to IP-only** - Deploy without DNS/SSL for testing
4. **Use CloudFlare** - No rate limits

**What NOT to do:**
- Request override (not available for exact set limit)
- Delete old certificates (doesn't help, limit is on issuance)
- Create new accounts (limit is per domain, not account)

## CI/CD Testing Considerations

### GitHub Actions Workflows

The `ci-test` environment is for template maintainers testing infrastructure changes. To avoid rate limits:

**Current ci-test configuration:**
- Domain: `ci-test.lablink-template-testing.com`
- SSL: Let's Encrypt production
- **Limit**: 5 deployments per week

**Best practices for ci-test:**
- Only run on significant infrastructure changes
- Don't run on every commit
- Consider using IP-only for some tests
- Coordinate with team to avoid simultaneous deploys

## AWS Cost Optimization During Testing

To minimize AWS costs during testing:

**Use Smaller Instance Types:**
```yaml
machine:
  machine_type: "t3.medium"  # Instead of g4dn.xlarge for testing
```

**Enable Auto-Destroy:**
- Set up scheduled workflow to destroy test environments nightly
- Use `terraform destroy` after validation tests pass

**Use Dynamic EIP:**
```yaml
eip:
  strategy: "dynamic"  # Creates new EIP, cleans up on destroy
```

**Monitor Costs:**
- Set up AWS Budgets alerts
- Tag resources with environment for cost tracking
- Review AWS Cost Explorer weekly

## Summary: Quick Reference

| Scenario | DNS | SSL | EIP Strategy | Rate Limit Risk |
|----------|-----|-----|--------------|-----------------|
| Local dev/debugging | Disabled | None | Dynamic | None |
| Testing SSL functionality | Enabled | CloudFlare | Persistent | None |
| Infrequent staging tests | Enabled | Let's Encrypt | Persistent | Low (if <5/week) |
| Production deployment | Enabled | Let's Encrypt | Persistent | Low (stable) |
| Template testing (ci-test) | Enabled | Let's Encrypt | Persistent | **Medium-High** |

## Additional Resources

- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [Let's Encrypt Staging Environment](https://letsencrypt.org/docs/staging-environment/)
- [Certificate Transparency Log (crt.sh)](https://crt.sh/)
- [LabLink Deployment Checklist](../DEPLOYMENT_CHECKLIST.md)
- [Configuration Examples](../lablink-infrastructure/config/README.md)