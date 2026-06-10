# sleap-lablink → lablink-template HEAD Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `sleap-lablink` up to `talmolab/lablink-template` HEAD (commit `03c6f36`) so it is ready for deployment, preserving SLEAP-specific config and branding.

**Architecture:** Hybrid in-place migration. Template-driven files (Terraform, scripts, workflows, infra README, root tooling) are copied verbatim from a pinned template clone; SLEAP-specific artifacts (active `config.yaml` values, branding docs, AWS resource records) are re-applied on top. `deployment_name=sleap-lablink`, single active `config.yaml` (test default, HTTP/manual-DNS), fresh EIPs.

**Tech Stack:** Terraform ≥1.6.6, AWS, GitHub Actions (OIDC), Bash, YAML (Hydra config), Docker (for config validation).

**Design spec:** `docs/superpowers/specs/2026-06-09-sleap-lablink-template-sync-design.md`

**Branch:** `sync-template-head` (already created; design doc already committed here).

---

## Conventions for this plan

- All paths are relative to repo root `/Users/andrewpark/talmolab/sleap-lablink` unless absolute.
- The pinned template clone lives at `/tmp/lablink-template-sync` (Task 1 creates it).
- "Verify" steps that need `terraform` assume Terraform ≥1.6.6 on PATH. If Terraform is not installed, the grep-based checks in each task are the mandatory gate; the deploy workflow re-runs `terraform validate` in CI regardless.
- Commit after each task. Commit messages use Conventional Commits and end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## Task 1: Pin the template source

**Files:** none in repo (creates `/tmp/lablink-template-sync`).

- [ ] **Step 1: Clone the template at the pinned commit**

```bash
rm -rf /tmp/lablink-template-sync
git clone https://github.com/talmolab/lablink-template /tmp/lablink-template-sync
git -C /tmp/lablink-template-sync checkout 03c6f36125c02ab2f6d75a6543c90ccd6badc67d
```

- [ ] **Step 2: Verify the pinned HEAD**

Run: `git -C /tmp/lablink-template-sync rev-parse HEAD`
Expected: `03c6f36125c02ab2f6d75a6543c90ccd6badc67d`

- [ ] **Step 3: Confirm we are on the work branch**

Run: `git rev-parse --abbrev-ref HEAD`
Expected: `sync-template-head`

---

## Task 2: Replace Terraform core, add alb.tf, remove Lambda/tfvars/moved-scripts

**Files:**
- Modify (overwrite): `lablink-infrastructure/main.tf`, `lablink-infrastructure/backend.tf`, `lablink-infrastructure/user_data.sh`, `lablink-infrastructure/README.md`, `lablink-infrastructure/backend-dev.hcl`, `lablink-infrastructure/backend-test.hcl`, `lablink-infrastructure/backend-prod.hcl`
- Create: `lablink-infrastructure/alb.tf`
- Delete: `lablink-infrastructure/lambda_function.py`, `lablink-infrastructure/terraform.tfvars`, `lablink-infrastructure/init-terraform.sh`, `lablink-infrastructure/verify-deployment.sh`

- [ ] **Step 1: Copy template Terraform files verbatim**

```bash
T=/tmp/lablink-template-sync/lablink-infrastructure
cp "$T/main.tf"        lablink-infrastructure/main.tf
cp "$T/backend.tf"     lablink-infrastructure/backend.tf
cp "$T/alb.tf"         lablink-infrastructure/alb.tf
cp "$T/user_data.sh"   lablink-infrastructure/user_data.sh
cp "$T/README.md"      lablink-infrastructure/README.md
cp "$T/backend-dev.hcl"  lablink-infrastructure/backend-dev.hcl
cp "$T/backend-test.hcl" lablink-infrastructure/backend-test.hcl
cp "$T/backend-prod.hcl" lablink-infrastructure/backend-prod.hcl
```

- [ ] **Step 2: Remove obsolete files**

```bash
git rm -f lablink-infrastructure/lambda_function.py \
          lablink-infrastructure/terraform.tfvars \
          lablink-infrastructure/init-terraform.sh \
          lablink-infrastructure/verify-deployment.sh
```

- [ ] **Step 3: Verify no old naming/Lambda references remain in Terraform**

Run: `grep -rn "resource_suffix\|lambda\|config_path\|archive_file" lablink-infrastructure/*.tf`
Expected: no output (exit 1 from grep).

- [ ] **Step 4: Verify new naming is present**

Run: `grep -ln "deployment_name" lablink-infrastructure/main.tf`
Expected: `lablink-infrastructure/main.tf`

- [ ] **Step 5: (Strong check, needs Terraform + a temp config) Validate HCL**

`main.tf` reads `config/config.yaml` via `file()`, which does not exist yet at this point. Create a throwaway minimal config so `terraform validate` can evaluate locals, then delete it:

```bash
cd lablink-infrastructure
cp /tmp/lablink-template-sync/lablink-infrastructure/config/config.yaml config/config.yaml.tmpvalidate
mv config/config.yaml config/config.yaml.bak 2>/dev/null || true
cp config/config.yaml.tmpvalidate config/config.yaml
terraform init -backend=false -input=false
terraform fmt -check
terraform validate
# restore
rm -f config/config.yaml config/config.yaml.tmpvalidate
mv config/config.yaml.bak config/config.yaml 2>/dev/null || true
cd ..
```

Expected: `terraform validate` prints `Success! The configuration is valid.` and `terraform fmt -check` exits 0 (no diff). If Terraform is absent, skip this step.

- [ ] **Step 6: Commit**

```bash
git add lablink-infrastructure/main.tf lablink-infrastructure/backend.tf \
        lablink-infrastructure/alb.tf lablink-infrastructure/user_data.sh \
        lablink-infrastructure/README.md lablink-infrastructure/backend-*.hcl
git commit -m "$(printf 'refactor(infra): adopt template HEAD Terraform (deployment_name naming, alb.tf, drop Lambda)\n\nReplaces main.tf/backend.tf/user_data.sh/infra README and backend hcls with\nlablink-template@03c6f36. Adds alb.tf (ACM path). Removes lambda_function.py,\nterraform.tfvars, and the init/verify scripts now living in scripts/.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: Consolidate config into a single SLEAP `config.yaml` + example flavors

**Files:**
- Create: `lablink-infrastructure/config/config.yaml` (SLEAP, new schema — overwrites existing)
- Create: `lablink-infrastructure/config/{acm,cloudflare,dev,ip-only,letsencrypt,letsencrypt-manual,prod,test}.example.yaml`, `lablink-infrastructure/config/custom-startup.sh`, `lablink-infrastructure/config/README.md`
- Modify (overwrite): `lablink-infrastructure/config/example.config.yaml`
- Delete: `lablink-infrastructure/config/config-dev.yaml`, `config-test.yaml`, `config-prod.yaml`, `config-prod.bak.yaml`

- [ ] **Step 1: Copy template example flavors, custom-startup, and config README (skip ci-test)**

```bash
T=/tmp/lablink-template-sync/lablink-infrastructure/config
cp "$T/acm.example.yaml"               lablink-infrastructure/config/
cp "$T/cloudflare.example.yaml"        lablink-infrastructure/config/
cp "$T/dev.example.yaml"               lablink-infrastructure/config/
cp "$T/ip-only.example.yaml"           lablink-infrastructure/config/
cp "$T/letsencrypt.example.yaml"       lablink-infrastructure/config/
cp "$T/letsencrypt-manual.example.yaml" lablink-infrastructure/config/
cp "$T/prod.example.yaml"              lablink-infrastructure/config/
cp "$T/test.example.yaml"             lablink-infrastructure/config/
cp "$T/custom-startup.sh"             lablink-infrastructure/config/
cp "$T/README.md"                     lablink-infrastructure/config/README.md
cp "$T/example.config.yaml"           lablink-infrastructure/config/example.config.yaml
# NOTE: deliberately NOT copying ci-test.example.yaml (template-maintainer only)
```

- [ ] **Step 2: Write the SLEAP active `config.yaml` (new schema, test default)**

Overwrite `lablink-infrastructure/config/config.yaml` with exactly:

```yaml
# SLEAP LabLink - Active Configuration
# Single active config (template single-config model). Default = TEST environment.
# To deploy PROD, edit machine.image (versioned), allocator.image_tag (pinned),
# dns.domain ("lablink.sleap.ai"), and ssl.provider ("letsencrypt") before deploying.
# Validated in CI via lablink-validate-config.

db:
  dbname: "lablink_db"
  user: "lablink"
  password: "PLACEHOLDER_DB_PASSWORD"  # Injected from GitHub secret at deploy time
  host: "localhost"
  port: 5432
  table_name: "vms"
  message_channel: "vm_updates"

machine:
  machine_type: "g4dn.xlarge"  # GPU instance for SLEAP ML workloads
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-f474d5bf1e8c4894c8c33bb903c613c7489e3574-test"
  ami_id: "ami-0601752c11b394251"  # us-west-2 Ubuntu 24.04 + Docker + Nvidia
  repository: "https://github.com/talmolab/sleap-tutorial-data.git"
  software: "sleap"
  extension: "slp"

allocator:
  image_tag: "linux-amd64-latest-test"  # base lablink-allocator-image tag

app:
  admin_user: "admin"
  admin_password: "PLACEHOLDER_ADMIN_PASSWORD"  # Injected from GitHub secret at deploy time
  region: "us-west-2"

dns:
  enabled: true
  terraform_managed: false  # Manual Route53 records
  domain: "test.lablink.sleap.ai"  # Full domain (no subdomain construction)
  zone_id: "Z010760118DSWF5IYKMOM"

eip:
  strategy: "persistent"  # Tag derived as sleap-lablink-eip-test

ssl:
  provider: "none"  # HTTP (matches current working test state)
  email: "admin@sleap.ai"
  certificate_arn: ""

startup_script:
  enabled: false
  path: "config/custom-startup.sh"
  on_error: "continue"

# S3 bucket for Terraform state
bucket_name: "tf-state-lablink-allocator-bucket"
```

- [ ] **Step 3: Remove old per-env config files**

```bash
git rm -f lablink-infrastructure/config/config-dev.yaml \
          lablink-infrastructure/config/config-test.yaml \
          lablink-infrastructure/config/config-prod.yaml \
          lablink-infrastructure/config/config-prod.bak.yaml
```

- [ ] **Step 4: Verify config.yaml is valid YAML and has the new schema keys**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('lablink-infrastructure/config/config.yaml')); \
assert 'allocator' in d and 'image_tag' in d['allocator'], 'missing allocator.image_tag'; \
assert 'startup_script' in d, 'missing startup_script'; \
assert d['dns']['domain']=='test.lablink.sleap.ai', 'wrong domain'; \
assert 'pattern' not in d['dns'] and 'custom_subdomain' not in d['dns'], 'stale dns keys'; \
assert 'tag_name' not in d['eip'], 'stale eip.tag_name'; \
assert 'staging' not in d['ssl'], 'stale ssl.staging'; \
print('config.yaml OK')"
```

Expected: `config.yaml OK`

- [ ] **Step 5: Verify SLEAP client image is carried over**

Run: `grep -n "lablink-sleap-client-image" lablink-infrastructure/config/config.yaml`
Expected: one match with the `f474d5bf...-test` tag.

- [ ] **Step 6: Commit**

```bash
git add lablink-infrastructure/config/
git commit -m "$(printf 'feat(config): single SLEAP config.yaml on new schema + template example flavors\n\nConsolidates config-{dev,test,prod}.yaml into one active config.yaml using the\nnew allocator/startup_script schema (test default: HTTP, manual DNS,\ntest.lablink.sleap.ai). Adds template *.example.yaml flavors, custom-startup.sh,\nand config/README.md. Skips ci-test.example.yaml (template-maintainer only).\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: Add root `scripts/`

**Files:**
- Create: `scripts/setup.sh`, `scripts/configure.sh`, `scripts/init-terraform.sh`, `scripts/verify-deployment.sh`, `scripts/estimate-costs.sh`, `scripts/cleanup-orphaned-resources.sh`, `scripts/validate-all-configs.sh`, `scripts/validate-all-configs.ps1`

- [ ] **Step 1: Copy the scripts directory**

```bash
mkdir -p scripts
cp /tmp/lablink-template-sync/scripts/*.sh  scripts/
cp /tmp/lablink-template-sync/scripts/*.ps1 scripts/
chmod +x scripts/*.sh
```

- [ ] **Step 2: Verify all shell scripts parse**

```bash
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done
echo "shell syntax check done"
```

Expected: `shell syntax check done` with no `SYNTAX ERROR` lines.

- [ ] **Step 3: Verify expected script set is present**

Run: `ls scripts/`
Expected: `cleanup-orphaned-resources.sh  configure.sh  estimate-costs.sh  init-terraform.sh  setup.sh  validate-all-configs.ps1  validate-all-configs.sh  verify-deployment.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/
git commit -m "$(printf 'feat(scripts): add template scripts/ (setup, configure, init, verify, costs, cleanup, validate)\n\nMoves init-terraform.sh and verify-deployment.sh to scripts/ and adds the new\nhelper scripts from lablink-template@03c6f36.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 5: Sync workflows, set `deployment_name=sleap-lablink`, drop dead CI

**Files:**
- Modify (overwrite then edit): `.github/workflows/terraform-deploy.yml`
- Modify (overwrite): `.github/workflows/terraform-destroy.yml`
- Create: `.github/workflows/config-validation.yml`, `.github/workflows/startup-script-validation.yml`
- Delete: `.github/workflows/client-vm-infrastructure-test.yml`

- [ ] **Step 1: Copy template workflows**

```bash
W=/tmp/lablink-template-sync/.github/workflows
cp "$W/terraform-deploy.yml"            .github/workflows/terraform-deploy.yml
cp "$W/terraform-destroy.yml"           .github/workflows/terraform-destroy.yml
cp "$W/config-validation.yml"           .github/workflows/config-validation.yml
cp "$W/startup-script-validation.yml"   .github/workflows/startup-script-validation.yml
```

- [ ] **Step 2: Set the SLEAP `deployment_name` default in the deploy workflow**

In `.github/workflows/terraform-deploy.yml`, change both occurrences of `my-lablink` to `sleap-lablink`:
- The `workflow_dispatch.inputs.deployment_name.default: "my-lablink"` → `default: "sleap-lablink"`
- The auto-trigger fallback `DEPLOYMENT_NAME="${{ vars.DEPLOYMENT_NAME || 'my-lablink' }}"` → `'sleap-lablink'`

```bash
sed -i.bak 's/my-lablink/sleap-lablink/g' .github/workflows/terraform-deploy.yml && rm -f .github/workflows/terraform-deploy.yml.bak
```

- [ ] **Step 3: Remove the dead client-vm CI workflow**

```bash
git rm -f .github/workflows/client-vm-infrastructure-test.yml
```

- [ ] **Step 4: Verify deployment_name default and that the dead workflow's bad path is gone**

```bash
grep -n "sleap-lablink" .github/workflows/terraform-deploy.yml   # expect 2 matches
grep -rn "my-lablink\|packages/allocator" .github/workflows/      # expect no output
```

Expected: two `sleap-lablink` matches; second grep produces no output.

- [ ] **Step 5: Verify all workflow YAML parses**

```bash
for f in .github/workflows/*.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" || echo "YAML ERROR: $f"; done
echo "workflow yaml check done"
```

Expected: `workflow yaml check done` with no `YAML ERROR` lines.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/
git commit -m "$(printf 'ci: sync workflows to template HEAD; deployment_name=sleap-lablink; drop dead CI\n\nReplaces terraform-deploy/destroy with template@03c6f36 (reads allocator.image_tag\nfrom config, deployment_name+environment vars). Adds config-validation and\nstartup-script-validation. Sets deployment_name default to sleap-lablink. Removes\nclient-vm-infrastructure-test.yml (referenced nonexistent packages/allocator/).\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 6: Add root tooling/docs and align root `.gitignore`

**Files:**
- Create: `CLAUDE.md`, `AGENTS.md`, `MANUAL_CLEANUP_GUIDE.md`, `docs/TESTING_BEST_PRACTICES.md`
- Modify (overwrite): `.gitignore` (root)

- [ ] **Step 1: Copy root tooling/docs**

```bash
cp /tmp/lablink-template-sync/CLAUDE.md               CLAUDE.md
cp /tmp/lablink-template-sync/AGENTS.md               AGENTS.md
cp /tmp/lablink-template-sync/MANUAL_CLEANUP_GUIDE.md MANUAL_CLEANUP_GUIDE.md
mkdir -p docs
cp /tmp/lablink-template-sync/docs/TESTING_BEST_PRACTICES.md docs/TESTING_BEST_PRACTICES.md
```

- [ ] **Step 2: Align root `.gitignore` with template**

The template `.gitignore` drops the obsolete `!lablink-infrastructure/terraform.tfvars` exception (we deleted that file) and adds `terraform-state-backup-*` plus the `.claude/commands` tracking comment. Overwrite:

```bash
cp /tmp/lablink-template-sync/.gitignore .gitignore
```

- [ ] **Step 3: Verify config.yaml is still tracked (not newly ignored)**

```bash
git check-ignore lablink-infrastructure/config/config.yaml; echo "exit=$?"
```

Expected: `exit=1` (NOT ignored — the template `.gitignore` explicitly keeps `config.yaml`). If it prints the path with `exit=0`, STOP and investigate before continuing.

- [ ] **Step 4: Confirm `.dockerignore` and `lablink-infrastructure/.gitignore` need no change**

```bash
diff .dockerignore /tmp/lablink-template-sync/.dockerignore && echo ".dockerignore identical"
diff lablink-infrastructure/.gitignore /tmp/lablink-template-sync/lablink-infrastructure/.gitignore && echo "infra .gitignore identical"
```

Expected: both print "identical" (no diff). If they differ, copy the template versions over.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md AGENTS.md MANUAL_CLEANUP_GUIDE.md docs/TESTING_BEST_PRACTICES.md .gitignore
git commit -m "$(printf 'docs: add template CLAUDE.md/AGENTS.md/MANUAL_CLEANUP_GUIDE/testing docs; align .gitignore\n\nPulls operational docs and agent guides from lablink-template@03c6f36 and aligns\nroot .gitignore (drops the removed terraform.tfvars exception). openspec/ and\n.claude/commands/ intentionally not imported.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 7: Update SLEAP-branded docs for the new naming/structure

These docs keep their SLEAP branding but contain stale references to the old model. Apply the concrete replacements below, then verify no stale patterns remain. Read each file first, apply edits, and preserve surrounding SLEAP-specific prose.

**Files:** Modify `README.md`, `DEPLOYMENT.md`, `DEPLOYMENT_CHECKLIST.md`, `AWS_RESOURCES.md`

### 7a. `README.md`

- [ ] **Step 1: Apply replacements**

| Find (current) | Replace with |
|----------------|--------------|
| `cp config/config-test.yaml config/config.yaml` (line ~41) | *(delete this line)* — config.yaml is the single active config; no copy needed for test |
| `cp config/config-prod.yaml config/config.yaml` (line ~63) | `# For prod: edit config.yaml (image, allocator.image_tag, dns.domain=lablink.sleap.ai, ssl.provider=letsencrypt) before deploying` |
| `Update \`eip.tag_name\` in \`config.yaml\` if using a different tag name.` (~204) | `The EIP name tag is derived automatically as \`{deployment_name}-eip-{environment}\` (e.g. \`sleap-lablink-eip-test\`).` |
| DNS block showing `pattern: "auto"` / `custom_subdomain` (~284-289) | Replace with the new DNS schema: `enabled`, `terraform_managed`, `domain` (full domain), `zone_id`. No `pattern`/`custom_subdomain`. |
| `staging: true  # true = staging certs...` (~297) | `provider: "none"  # "none"=HTTP, "letsencrypt", "cloudflare", "acm"` and remove the `staging` line; add `certificate_arn: ""` |
| `tag_name: "lablink-eip"  # Tag to find reusable EIP` (~310) | `strategy: "persistent"  # reuse EIP tagged {deployment_name}-eip-{env}, or "dynamic"` |
| Project-structure tree lines `terraform.tfvars` (~454) and `verify-deployment.sh` under infra (~456) | Remove `terraform.tfvars`; move `verify-deployment.sh` and `init-terraform.sh` under a new root `scripts/` entry; add `alb.tf`, `scripts/`, drop `lambda_function.py` |

- [ ] **Step 2: Verify no stale patterns in README.md**

Run: `grep -n "resource_suffix\|config-test.yaml\|config-prod.yaml\|custom_subdomain\|tag_name\|staging:\|terraform.tfvars\|lambda" README.md`
Expected: no output.

### 7b. `DEPLOYMENT.md`

- [ ] **Step 3: Replace the multi-config narrative with the single-config model**

- Replace the "Configuration Files" table (lines ~59-61 listing `config-dev/test/prod.yaml`) with a short note: there is now a single active `config.yaml`; environment is selected at deploy time via the `environment` workflow input; use the `*.example.yaml` flavors as references.
- Remove the per-env `**File**: config-*.yaml` headers (~66, ~87, ~110).
- Replace every `cp config/config-<env>.yaml config/config.yaml` (lines ~140, ~186, ~248, ~350, ~353, ~356, ~560) with edit-in-place guidance: for test, deploy as-is; for prod, edit `config.yaml` (`machine.image` versioned, `allocator.image_tag` pinned, `dns.domain: lablink.sleap.ai`, `ssl.provider: letsencrypt`) before deploying.
- Replace `custom_subdomain: "test"` / `custom_subdomain: ""` (~93, ~116) with `domain: "test.lablink.sleap.ai"` / `domain: "lablink.sleap.ai"`.
- Replace `staging: true` / `staging: false` (~100, ~123, ~421, ~506, ~564) with `provider: "none"` (test/HTTP) / `provider: "letsencrypt"` (prod/HTTPS); update the "If rate limited" note to reference switching `ssl.provider` to `none` or `cloudflare`.
- Replace `./init-terraform.sh dev` (~154) with `../scripts/init-terraform.sh dev` (run from `lablink-infrastructure/`).
- Update the `diff config/config-test.yaml config/config-prod.yaml` example (~560) to `diff` against an `*.example.yaml` flavor or describe the prod edits directly.
- Update any `-var="resource_suffix=..."` Terraform invocation to `-var="deployment_name=sleap-lablink" -var="environment=<env>"`.

- [ ] **Step 4: Verify no stale patterns in DEPLOYMENT.md**

Run: `grep -n "resource_suffix\|config-dev.yaml\|config-test.yaml\|config-prod.yaml\|custom_subdomain\|staging:\|init-terraform.sh dev" DEPLOYMENT.md`
Expected: no output.

### 7c. `DEPLOYMENT_CHECKLIST.md`

- [ ] **Step 5: Apply replacements**

- `Updated \`eip.tag_name\` in \`config.yaml\` (using default "lablink-eip")` (~54) → `Set \`deployment_name=sleap-lablink\` (EIP tag derived as \`sleap-lablink-eip-{env}\`)`
- `Chose \`pattern: "custom"\` with subdomain \`test\`` (~89) → `Set \`dns.domain: "test.lablink.sleap.ai"\` (full domain)`
- `Set \`staging: true\` for testing (HTTP only...)` (~97) → `Set \`ssl.provider: "none"\` for testing (HTTP only)`
- `Note: \`staging: true\` means HTTP only (no SSL certificate)` (~152) → `Note: \`ssl.provider: "none"\` means HTTP only (no SSL certificate)`
- `For production, set \`staging: false\` to enable HTTPS...` (~154) → `For production, set \`ssl.provider: "letsencrypt"\` to enable HTTPS with Let's Encrypt`

- [ ] **Step 6: Verify no stale patterns in DEPLOYMENT_CHECKLIST.md**

Run: `grep -n "tag_name\|pattern:\|staging:" DEPLOYMENT_CHECKLIST.md`
Expected: no output.

### 7d. `AWS_RESOURCES.md`

- [ ] **Step 7: Update EIP/DNS records for fresh-IP + new naming**

- Add a banner near the top: the migration to `deployment_name=sleap-lablink` allocates **new** EIPs; the IDs/IPs below are pre-migration and will be replaced after the first new deploy.
- `Config: custom_subdomain: "test"` (~103) → `Config: dns.domain: "test.lablink.sleap.ai"`
- `Config: custom_subdomain: ""` (~105) → `Config: dns.domain: "lablink.sleap.ai"`
- `Config uses tag_name: "lablink-eip" → Terraform looks for lablink-eip-test or lablink-eip-prod` (~137) → `EIP name tag derived as {deployment_name}-eip-{environment} → sleap-lablink-eip-test / sleap-lablink-eip-prod`
- Mark the existing Name tags `lablink-eip-test` / `lablink-eip-prod` as **(pre-migration; superseded by sleap-lablink-eip-*)**.

- [ ] **Step 8: Verify no stale patterns in AWS_RESOURCES.md**

Run: `grep -n "custom_subdomain\|tag_name: \"lablink-eip\"" AWS_RESOURCES.md`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add README.md DEPLOYMENT.md DEPLOYMENT_CHECKLIST.md AWS_RESOURCES.md
git commit -m "$(printf 'docs: update SLEAP docs for deployment_name naming and single-config model\n\nReplaces resource_suffix/custom_subdomain/ssl.staging/per-env-config references\nwith deployment_name+environment, full-domain DNS, ssl.provider, and the single\nactive config.yaml model. Marks pre-migration EIPs as superseded.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 8: EIP-strategy verification + full repo validation sweep

**Files:** none (verification only; may produce a follow-up note).

- [ ] **Step 1: Verify the template's `persistent`-no-matching-tag EIP behavior**

Read the EIP block in `lablink-infrastructure/main.tf` and confirm what happens when no EIP with tag `sleap-lablink-eip-test` exists:

```bash
grep -n "aws_eip\|eip_strategy\|persistent\|data \"aws_eip\"\|count\b" lablink-infrastructure/main.tf
```

Decision:
- If `persistent` creates+tags a new EIP when none matches (a `resource "aws_eip"` gated on strategy, not a hard `data "aws_eip"` lookup) → the SLEAP `config.yaml` `eip.strategy: "persistent"` is correct for the fresh-IP first deploy. No change.
- If `persistent` does a `data "aws_eip"` lookup that fails when no tag matches → set `eip.strategy: "dynamic"` in `config.yaml` for the first deploy, OR document pre-allocating+tagging `sleap-lablink-eip-test` in `AWS_RESOURCES.md`. Apply whichever and amend the relevant commit.

- [ ] **Step 2: Repo-wide stale-pattern sweep**

```bash
grep -rn "resource_suffix\|custom_subdomain\|ssl.staging\|eip.tag_name\|packages/allocator\|lambda_function\|terraform.tfvars\|config-prod.yaml\|config-test.yaml\|config-dev.yaml" \
  --include="*.tf" --include="*.yml" --include="*.yaml" --include="*.sh" --include="*.md" \
  . | grep -v "docs/superpowers/" | grep -v "AWS_RESOURCES.md.*superseded" || echo "NO STALE PATTERNS"
```

Expected: `NO STALE PATTERNS` (or only intentional historical mentions inside `docs/superpowers/` specs/plans, which are excluded). Investigate anything else.

- [ ] **Step 3: Confirm final file tree matches the design**

```bash
echo "--- should NOT exist ---"
ls lablink-infrastructure/lambda_function.py lablink-infrastructure/terraform.tfvars \
   lablink-infrastructure/init-terraform.sh lablink-infrastructure/verify-deployment.sh \
   lablink-infrastructure/config/config-prod.yaml .github/workflows/client-vm-infrastructure-test.yml 2>&1 | sed 's/^/  /'
echo "--- should exist ---"
ls lablink-infrastructure/alb.tf scripts/setup.sh CLAUDE.md AGENTS.md MANUAL_CLEANUP_GUIDE.md \
   docs/TESTING_BEST_PRACTICES.md lablink-infrastructure/config/ip-only.example.yaml 2>&1 | sed 's/^/  /'
```

Expected: every "should NOT exist" path reports "No such file or directory"; every "should exist" path lists successfully.

- [ ] **Step 4: (Strong check, needs Terraform) Final validate with the real SLEAP config**

```bash
cd lablink-infrastructure
terraform init -backend=false -input=false
terraform fmt -check
terraform validate
cd ..
```

Expected: `Success! The configuration is valid.` and `fmt -check` exits 0.

- [ ] **Step 5: (Optional, needs Docker) Validate config.yaml against the schema**

```bash
docker pull ghcr.io/talmolab/lablink-allocator-image:linux-amd64-latest-test
docker run --rm -v "$(pwd)/lablink-infrastructure/config/config.yaml:/config/config.yaml:ro" \
  ghcr.io/talmolab/lablink-allocator-image:linux-amd64-latest-test \
  lablink-validate-config --config /config/config.yaml || echo "validation tool unavailable or flagged issues — review output"
```

Expected: validation passes. If the tool's invocation differs, mirror what `.github/workflows/config-validation.yml` runs.

- [ ] **Step 6: Commit any fixes from this sweep**

```bash
git add -A
git commit -m "$(printf 'fix: resolve EIP strategy + stale-reference sweep findings\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')" || echo "nothing to commit"
```

---

## Task 9: Open the PR

**Files:** none.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin sync-template-head
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base main --head sync-template-head \
  --title "Sync to lablink-template HEAD (deployment-ready)" \
  --body "$(printf 'Brings sleap-lablink up to lablink-template@03c6f36.\n\n## What changed\n- Terraform: deployment_name+environment naming, alb.tf, expanded IAM, Lambda removed\n- Config: single SLEAP config.yaml on new schema (test default: HTTP, manual DNS) + example flavors\n- Scripts: root scripts/ (setup/configure/init/verify/costs/cleanup/validate)\n- CI: synced deploy/destroy, added config + startup-script validation, removed dead client-vm CI\n- Docs: CLAUDE.md/AGENTS.md/MANUAL_CLEANUP_GUIDE/testing docs; SLEAP docs updated for new model\n\n## Decisions\n- deployment_name=sleap-lablink, fresh EIPs (Route53 updated post-deploy)\n- Single active config.yaml; edit for prod\n- Skipped openspec/ and .claude/commands/\n\n## Operator runbook (post-merge, live AWS)\n1. (Recommended) Destroy old resource_suffix-named infra, or accept destroy+recreate on first apply\n2. Run deploy workflow (deployment_name=sleap-lablink, environment=test)\n3. Update Route53 A records to the new EIP\n4. Update AWS_RESOURCES.md with new EIP IDs/IPs\n\nSpec: docs/superpowers/specs/2026-06-09-sleap-lablink-template-sync-design.md\nPlan: docs/superpowers/plans/2026-06-09-sleap-lablink-template-sync.md\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)')"
```

- [ ] **Step 3: Report the PR URL back to the user.**

---

## Self-review notes (author)

- **Spec coverage:** Every "Replace/Add/Remove/Keep+update" bullet in the design maps to a task (T2 Terraform+remove; T3 config; T4 scripts; T5 workflows; T6 root tooling/.gitignore; T7 SLEAP docs). EIP-strategy risk → T8.1. Operator runbook → carried into the PR body (T9), not executed here (touches live AWS). ✅
- **Out-of-scope respected:** no image changes, no DNS/ACM switch, no openspec/.claude import. ✅
- **No-placeholder check:** all copy/edit/verify steps have concrete commands or explicit find→replace mappings with line anchors. The only judgment step is T7 prose editing, bounded by exact replacement tables + grep gates. ✅
- **Consistency:** `deployment_name=sleap-lablink`, `environment` var, `allocator.image_tag`, `ssl.provider`, full-domain `dns.domain`, `eip.strategy` used identically across tasks. ✅
