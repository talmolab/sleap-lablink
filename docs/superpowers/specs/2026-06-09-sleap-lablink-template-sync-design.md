# Design: Sync sleap-lablink to lablink-template HEAD

**Date:** 2026-06-09
**Status:** Approved (pending spec review)
**Author:** Andrew Park (andrew@talmolab.org) + Claude

## Problem

`sleap-lablink` is the official "Example Deployment" of [`talmolab/lablink-template`](https://github.com/talmolab/lablink-template),
but it is pinned to a much older version of the template. Since the fork, the template
has merged ~25+ PRs, several of them breaking changes. `sleap-lablink` must be brought
up to template HEAD so it is ready for deployment on the current infrastructure.

### Key divergences (current → template HEAD)

| Area | Current (sleap-lablink) | Template HEAD |
|------|-------------------------|---------------|
| Resource naming | `resource_suffix` (e.g. `lablink-eip-test`) | `deployment_name` + `environment` (e.g. `sleap-lablink-eip-test`) |
| Allocator image | passed via `-var allocator_image_tag` | read from `allocator.image_tag` in `config.yaml` |
| Lambda | `lambda_function.py` present | removed |
| Load balancer | none | `alb.tf` (used only when `ssl.provider=acm`) |
| IAM | minimal | expanded EC2 VM-management + IAM role-passing perms |
| Config schema | `dns.{pattern,custom_subdomain,app_name,create_zone}`, `eip.tag_name`, `ssl.staging` | `allocator:`, `startup_script:` sections; full-domain DNS; simplified `eip`/`ssl`; `ssl.certificate_arn` |
| Config files | `config.yaml` + `config-{dev,test,prod}.yaml` + backups | single active `config.yaml` + `*.example.yaml` flavors |
| Scripts | `lablink-infrastructure/{init-terraform,verify-deployment}.sh` | root `scripts/` (setup, configure, init-terraform, verify-deployment, estimate-costs, cleanup-orphaned-resources, validate-all-configs) |
| CI | `client-vm-infrastructure-test.yml` (references nonexistent `packages/allocator/`) | `config-validation.yml`, `startup-script-validation.yml` |

## Decisions (from brainstorming)

1. **Scope:** Full alignment with template HEAD.
2. **Live deployments / EIPs:** Fresh IPs. `deployment_name=sleap-lablink`; new EIPs will be
   allocated; Route53 A records updated manually afterward. (Brief cutover downtime accepted.)
3. **Multi-env config:** Single active `config.yaml` (pure template model). Edit it per deploy
   for prod. Old per-env config files removed; template `*.example.yaml` kept as reference.
4. **SSL default:** `none` (HTTP) for the active config, matching the current working test state
   (HTTPS previously caused websocket "missed messages").
5. **DNS:** `terraform_managed: false` (manual Route53 records), matching current operations.
6. **Dev tooling:** Include `CLAUDE.md`, `AGENTS.md`, `docs/`, `MANUAL_CLEANUP_GUIDE.md`.
   Skip `openspec/` and `.claude/commands/` (template-maintenance artifacts).

## Execution strategy

Hybrid in-place migration. Template-driven files (Terraform, scripts, workflows, infra README)
are entirely controlled by `config.yaml` and carry no SLEAP customization, so they are replaced
**verbatim** with their template-HEAD versions. SLEAP-specific artifacts (active config values,
branding docs, AWS resource records) are then re-applied on top.

This is NOT a fresh re-instantiate: the repo, git history, and SLEAP-branded docs are preserved.

## File-by-file plan

### Replace with template HEAD (no SLEAP content)
- `lablink-infrastructure/main.tf`
- `lablink-infrastructure/backend.tf`
- `lablink-infrastructure/user_data.sh`
- `lablink-infrastructure/README.md`
- `lablink-infrastructure/.gitignore`
- `lablink-infrastructure/backend-{dev,test,prod}.hcl` (reconcile; do NOT add `ci-test` — template-maintainer only)
- `.github/workflows/terraform-deploy.yml`
- `.github/workflows/terraform-destroy.yml`

### Add from template
- `lablink-infrastructure/alb.tf`
- `lablink-infrastructure/config/*.example.yaml` (ip-only, cloudflare, letsencrypt, letsencrypt-manual, acm, dev, test, prod) — **skip `ci-test.example.yaml`**
- `lablink-infrastructure/config/custom-startup.sh`
- `lablink-infrastructure/config/README.md`
- `scripts/setup.sh`, `scripts/configure.sh`, `scripts/init-terraform.sh`, `scripts/verify-deployment.sh`, `scripts/estimate-costs.sh`, `scripts/cleanup-orphaned-resources.sh`, `scripts/validate-all-configs.sh`, `scripts/validate-all-configs.ps1`
- `.github/workflows/config-validation.yml`
- `.github/workflows/startup-script-validation.yml`
- `CLAUDE.md`, `AGENTS.md`, `MANUAL_CLEANUP_GUIDE.md`
- `docs/TESTING_BEST_PRACTICES.md`

### Remove
- `lablink-infrastructure/lambda_function.py`
- `lablink-infrastructure/init-terraform.sh` (moved to `scripts/`)
- `lablink-infrastructure/verify-deployment.sh` (moved to `scripts/`)
- `lablink-infrastructure/terraform.tfvars` (new workflow passes vars directly; `config_path` var removed)
- `lablink-infrastructure/config/config-{dev,test,prod}.yaml`
- `lablink-infrastructure/config/config-prod.bak.yaml`
- `.github/workflows/client-vm-infrastructure-test.yml` (dead: references nonexistent `packages/allocator/`)

### Keep + update for new structure (SLEAP-specific)
- `README.md` — SLEAP branding kept; update for `deployment_name`/`environment` naming, single-config model, `scripts/` paths, removed Lambda.
- `DEPLOYMENT.md` — update env table + steps for new naming/structure.
- `DEPLOYMENT_CHECKLIST.md` — update for new workflow inputs (`deployment_name`), single config.
- `AWS_RESOURCES.md` — keep as the SLEAP AWS record; mark old EIP IDs stale and add a note that new EIPs are allocated on first new deploy (fill in after cutover).
- `LICENSE` — unchanged.
- `.dockerignore` — reconcile with template version.
- `lablink-infrastructure/config/example.env` — keep.
- `lablink-infrastructure/config/example.config.yaml` — keep (already present; reconcile with template if it ships one).

### Decide during implementation
- `.gitignore` (root) — reconcile current vs template (union; ensure `config.yaml` handling matches template's intent — template tracks `config.yaml`).

## New `config/config.yaml` (SLEAP, new schema)

Single active config, defaulting to the **test** environment (matches current `config.yaml`):

```yaml
db:
  dbname: "lablink_db"
  user: "lablink"
  password: "PLACEHOLDER_DB_PASSWORD"   # injected from GitHub secret at deploy
  host: "localhost"
  port: 5432
  table_name: "vms"
  message_channel: "vm_updates"

machine:
  machine_type: "g4dn.xlarge"
  image: "ghcr.io/talmolab/lablink-sleap-client-image:linux-amd64-<sha>-test"   # carry current SLEAP client image
  ami_id: "ami-0601752c11b394251"
  repository: "https://github.com/talmolab/sleap-tutorial-data.git"
  software: "sleap"
  extension: "slp"

allocator:
  image_tag: "linux-amd64-latest-test"   # base lablink-allocator-image tag

app:
  admin_user: "admin"
  admin_password: "PLACEHOLDER_ADMIN_PASSWORD"   # injected from GitHub secret at deploy
  region: "us-west-2"

dns:
  enabled: true
  terraform_managed: false               # manual Route53 records
  domain: "test.lablink.sleap.ai"        # full domain (no subdomain construction)
  zone_id: "Z010760118DSWF5IYKMOM"

eip:
  strategy: "persistent"                 # tag derived as sleap-lablink-eip-test (see EIP note below)

ssl:
  provider: "none"                       # HTTP (matches current working test state)
  email: "admin@sleap.ai"
  certificate_arn: ""

startup_script:
  enabled: false
  path: "config/custom-startup.sh"
  on_error: "continue"

bucket_name: "tf-state-lablink-allocator-bucket"
```

The exact SLEAP client image SHA is carried over from the current `config.yaml`
(`linux-amd64-f474d5bf1e8c4894c8c33bb903c613c7489e3574-test`) unless a newer one is preferred.

**EIP note (implementation check):** confirm the template's behavior for `strategy: persistent`
when *no* EIP with the derived tag (`sleap-lablink-eip-{env}`) exists yet. If the template
*creates and tags* a new EIP in that case (expected), `persistent` is correct and the first deploy
yields the fresh IP that subsequent deploys reuse. If instead it *errors* on a missing tag, switch
the first deploy to `strategy: dynamic`, or pre-allocate and tag an EIP `sleap-lablink-eip-test`
before deploying. Verify against `main.tf` during implementation.

A prod profile (root `lablink.sleap.ai`, `ssl.provider=letsencrypt`, versioned image,
`allocator.image_tag` pinned) is documented in `DEPLOYMENT.md` as the edits to make before a
prod deploy — not stored as a separate active file.

## Deploy workflow customization

The template workflow is used as-is except:
- `workflow_dispatch.inputs.deployment_name.default`: `my-lablink` → `sleap-lablink`.
- Auto-trigger fallback already reads `vars.DEPLOYMENT_NAME`; document setting repo variable
  `DEPLOYMENT_NAME=sleap-lablink`.

Existing GitHub secrets (`AWS_ROLE_ARN`, `AWS_REGION`, `ADMIN_PASSWORD`, `DB_PASSWORD`) are
unchanged and still consumed by the template workflow's secret-injection step.

## Validation (in-repo, before deploy)
- `terraform fmt -check` + `terraform validate` in `lablink-infrastructure/` (workflow already does this).
- `scripts/validate-all-configs.sh` to validate every `*.example.yaml` + `config.yaml` against the
  schema (requires Docker + `lablink-allocator-image`).
- `bash -n` / shellcheck on `user_data.sh` and `scripts/*.sh` where available.

## Post-merge operational runbook (operator-run; touches live AWS — NOT done by this change)
1. (Optional, recommended) Destroy old `resource_suffix`-named test/prod infra with the pre-migration
   code, or accept that the first new apply will destroy+recreate within the same state.
2. Trigger the new deploy workflow (`deployment_name=sleap-lablink`, `environment=test`).
3. New EIP allocated → read the new public IP from workflow output.
4. Update Route53 A record `test.lablink.sleap.ai` → new IP (and `lablink.sleap.ai` when prod is cut over).
5. Update `AWS_RESOURCES.md` with new EIP allocation IDs / IPs.
6. Verify with `scripts/verify-deployment.sh` and the allocator web UI.

## Out of scope
- Changing the SLEAP client/allocator images themselves.
- Migrating to Terraform-managed DNS or ACM/ALB SSL (files are present and available, but the
  active config stays manual-DNS + HTTP).
- Preserving the current EIPs/IPs (explicitly chose fresh IPs).
- Importing `openspec/` or `.claude/commands/`.

## Risks
- **Resource recreation:** the naming change makes Terraform destroy old + create new resources.
  Acceptable per the fresh-IP decision, but the operator must expect a full replace on first apply.
- **DNS cutover gap:** brief downtime between new EIP allocation and Route53 record update.
- **Image SHA drift:** the carried-over client image SHA should be confirmed current before deploy.
