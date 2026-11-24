# CloudSentinel

Guardrails for a small AWS account, built with Terraform and GitHub Actions.

The idea is to catch the same mistake in three places:

1. **Before deploy**: Terraform changes are scanned in CI, so a public bucket or an over-broad IAM policy never gets applied.
2. **During deploy**: CI talks to AWS through OIDC with short-lived credentials. There are no access keys in GitHub.
3. **After deploy**: if someone makes a bucket public by hand in the console, CloudTrail picks it up, EventBridge triggers a Lambda, and the bucket is locked down again with an email alert.

Everything stays inside the AWS free tier. A $5 budget alarm is the first thing that gets created.

## Status

| Phase | What | State |
|---|---|---|
| 1 | Bootstrap: state bucket, GitHub OIDC roles, budget | done |
| 2 | Main stack + CI (fmt, validate, TFLint, Checkov, plan on PR, apply on main) | done |
| 3 | Auto-remediation: CloudTrail → EventBridge → Lambda → SNS | next |
| 4 | Docs, demo, screenshots | |

## Layout

```
bootstrap/     one-time setup, applied from a laptop with admin credentials
infra/         the main stack, applied only by CI
scripts/tf     runs Terraform from the official Docker image (nothing to install)
.github/workflows/terraform.yml
```

## Bootstrap

`bootstrap/` holds the pieces that CI itself depends on, so it can't be applied by CI:

- **State bucket** `cloudsentinel-tfstate-<account-id>`: versioned, SSE-S3 encrypted, all public access blocked,
  TLS-only bucket policy, old versions expire after 90 days. Locking uses S3 lock files (`use_lockfile`),
  so there is no DynamoDB table.
- **GitHub OIDC provider** plus two roles:
  - `cloudsentinel-gha-plan`: assumable from any pull request in this repo. Read-only, and may only write
    `*.tflock` objects in the state bucket.
  - `cloudsentinel-gha-apply`: assumable only from workflows on `main`. Write access is limited to
    `cloudsentinel-*` resources (S3, CloudTrail, EventBridge, Lambda, SNS, Lambda log groups).
- **Permissions boundary** `cloudsentinel-workload-boundary`. The apply role can only create IAM roles under
  `/cloudsentinel/` and only with this boundary attached, and it can't remove it. Without that, a role that
  can create roles can create an admin role and use it. The boundary allows bucket lock-down actions, SNS
  publish and Lambda logging. No IAM, no object reads or writes.
- **Budget** `cloudsentinel-monthly`: $5/month, email at 50% and 100% actual, and at 100% forecast.

I checked the apply role with the IAM policy simulator:

| Attempt | Result |
|---|---|
| create role under `/cloudsentinel/` with the boundary | allowed |
| same role without the boundary | denied |
| create role outside `/cloudsentinel/` | denied |
| remove a role's boundary | denied (explicit) |
| attach a policy to the CI role itself | denied |
| delete or re-policy the state bucket | denied (explicit) |
| create a `cloudsentinel-*` bucket | allowed |
| create any other bucket | denied |
| launch an EC2 instance | denied |

Checkov: 100 passed, 0 failed. Six checks are skipped, each with a reason in the code (access logging,
replication, KMS CMK and event notifications on the state bucket; two on the boundary, which has to work on
every bucket by design).

### Running it the first time

Needs Docker and admin credentials in `~/.aws` (region `eu-north-1`).

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars     # set alert_email

# The bucket that will hold the state doesn't exist yet, so start on local state.
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
../scripts/tf init
../scripts/tf apply

# Move the state into the bucket it just created.
cp backend.hcl.example backend.hcl               # put your account id in the bucket name
rm backend_override.tf
../scripts/tf init -migrate-state -backend-config=backend.hcl
rm terraform.tfstate terraform.tfstate.backup
```

After that it's a normal stack: `../scripts/tf plan`, `../scripts/tf apply`.

`terraform.tfvars`, `backend.hcl` and `*_override.tf` are git-ignored, so the alert email and the account id
stay out of the repo.

## CI

`.github/workflows/terraform.yml` has three jobs:

| Job | Runs on | What it does |
|---|---|---|
| checks | every PR and every push to main | `terraform fmt`, `validate` (both stacks), TFLint with the AWS ruleset, Checkov, Gitleaks |
| plan | PRs | assumes `cloudsentinel-gha-plan` through OIDC, runs `terraform plan` for `infra/` |
| apply | main | assumes `cloudsentinel-gha-apply`, plans, then applies that saved plan |

plan and apply only start if checks pass. The repo has four secrets: the two role ARNs, the state
bucket name and the alert email. There are no AWS keys anywhere. The account id is masked in the logs,
and the email is a sensitive variable, so the plan shows `(sensitive value)`.

`main` is protected: changes go through a PR, the checks and plan jobs must pass, and force-pushes
and deletes are blocked.

**Pre-deploy gate in action:** [PR #2](https://github.com/ArpitSinghal-DevOps/cloudsentinel/pull/2)
adds a bucket with public access blocks off and a `Principal: "*"` policy. Checkov fails it with 12
findings (CKV_AWS_53/54/55/56 for the access blocks, CKV_AWS_70 for the wildcard principal), so the
plan never runs. The PR stays open on purpose.

### The OIDC subject gotcha

The first plan run failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. CloudTrail
showed the token's subject:

```
repo:ArpitSinghal-DevOps@144610884/cloudsentinel@1470357600:pull_request
```

GitHub includes the numeric owner and repo ids in the subject, so a trust policy matching
`repo:ArpitSinghal-DevOps/cloudsentinel:*` never matches. The roles now pin both ids. That is stricter
too: if the repo were deleted and someone re-created one with the same name, it would get a new id and
could not assume the roles.

## Cost

Everything here is free: IAM, OIDC and the first budget cost nothing, and the state bucket holds a few
hundred KB. The later phases use one CloudTrail trail (management events only, free), EventBridge for AWS
service events (free), and Lambda and SNS within their free tiers. Nothing that bills by the hour (NAT
gateways, load balancers, EC2, RDS), and the CI role can't create any of it.
