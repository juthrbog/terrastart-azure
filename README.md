<!-- Fork: change this title to the name of your project. -->
# &lt;project-name&gt;

## Overview

<!-- Fork: replace this overview with a description of your project. -->

This is a starter template for an [OpenTofu](https://opentofu.org) project
on AWS. It gives you:

- `terraform/`: the OpenTofu code. Put your resources and modules here.
- `deployments/`: the root module that runs the code in `terraform/`. Each
  deployment has one YAML config file and one S3 backend file. The
  workspace name selects the config.
- A CI pipeline for GitLab CI and one for GitHub Actions. Both run the same
  script, `.ci/scripts/tf.sh`. They plan and apply one tier at a time
  (develop, stage, prod) and get AWS credentials through OIDC.
- [Task](https://taskfile.dev) commands for local work.

The folder name `terraform/`, the `.tf` files and the `.terraform*` files
keep their names. OpenTofu reads them the same way.

To use Terraform instead, see [Use Terraform instead](#use-terraform-instead).

## Quick start

1. Pick your CI platform. See [CI Platform](#ci-platform).
2. Add your first deployment. See [Adding a deployment](#adding-a-deployment).
3. Make the IAM OIDC provider and the CI role. See [CI Auth](#ci-auth).
4. Put your resources in `terraform/` and push. The pipeline plans the
   change.

## Usage

### Config

See the [default config](./deployments/configs/default.yaml) for options and
their descriptions. `deployments/main.tf` loads the whole file. OpenTofu does
not read the `ci:` block. Only the CI script reads it.

Only `.yaml` files belong in `deployments/configs/`. The GitHub setup job
stops with an error when it finds any other file there, for example a config
saved as `.yml`. Rename such a file to `.yaml`.

### Naming

A deployment name has the form `<env>-<deployment_id>`, for example
`develop-a1b2c3d4`:

- `env` is the tier: `develop`, `stage` or `prod`. See
  [Change the tiers](#change-the-tiers).
- `deployment_id` is a random ID. Make it with
  [`task gen-deploy-id`](#task-commands).

Use the deployment name for the config file name, the tfbackend file name,
the workspace name and the CI job names.

A deployment ID from `task gen-deploy-id` has 8 lowercase hex characters, for
example `0a1b2c3d`. It always has at least one letter. YAML reads some
hex values as numbers, for example `12345678` or `1234e567` (a float).
OpenTofu then changes the value, and `1234e567` becomes a number with 571
digits. So the task never prints such a value. Put the ID in quotes in the
config, as `default.yaml` shows. `tf.sh` stops with an error when `env` or
`deployment_id` is an unquoted value that YAML reads as a number.

A deployment is one config file in `deployments/configs/`. The file name
without `.yaml` is the deployment name. CI uses the deployment name as the
workspace name.

## CI Platform

This template has a pipeline for GitLab CI and a pipeline for GitHub Actions.
A fork uses only one of them. Both pipelines call the same script,
[`.ci/scripts/tf.sh`](./.ci/scripts/tf.sh), so they run the same OpenTofu
steps. The platform files only start jobs, pass the deployment name, and
move plan files between jobs.

After you fork, delete the files of the platform that you do not use:

| Command | Keeps | Deletes |
| --- | --- | --- |
| `task ci:use-github` | `.github/` | `.gitlab-ci.yml`, `.ci/templates/`, `.ci/configs/`, `.ci/image/` |
| `task ci:use-gitlab` | `.gitlab-ci.yml`, `.ci/templates/`, `.ci/configs/`, `.ci/image/` | `.github/` |

Both tasks keep `.ci/scripts/`. Each task lists the files and asks you to
confirm before it deletes them. If [gum](https://github.com/charmbracelet/gum)
is installed, the task asks with gum. If not, it asks a `[y/N]` question. Any
answer other than `y` or `yes` cancels. Then delete the sections of this
README that are about the other platform.

## CI Auth

### AWS

CI jobs get temporary AWS credentials through OIDC (OpenID Connect). OIDC lets
AWS trust a token that the CI platform makes for each job. You store no AWS
keys in CI.

Each deployment config names the IAM role that CI uses for it:

```yaml
ci:
  aws_role_arn: arn:aws:iam::<account-id>:role/<role-name>
```

`tf.sh` stops with an error if this value is missing or is not an IAM role
ARN. The same role runs plan, apply and destroy for that deployment.

Make these roles before the first pipeline run, in the place where you manage
IAM. A useful naming convention is `ci-<repo>-<purpose>`, for example
`ci-my-repo-deploy`. Each AWS account also needs an IAM OIDC identity
provider for your CI platform. The trust policy of the role says which tokens
can use the role. Limit it to your project and to the branches and
environments that run jobs.

CI authenticates with OIDC only. Static AWS access keys are not used.

#### State access

Each deployment's state is at
`<workspace_key_prefix>/<deployment>/<key>` in the state bucket. You can
limit a CI role to its own prefix, for example `s3:GetObject` and
`s3:PutObject` on `<bucket>/<workspace_key_prefix>/*` and `s3:ListBucket`
with the condition `s3:prefix` like `<workspace_key_prefix>/*`. `tf.sh`
works with such a role:

- `tf.sh` runs `init` with `TF_WORKSPACE` set to the deployment. So `init`
  reads only that workspace's state, not the state of the `default`
  workspace at the bucket root.
- A role like this may not be able to create a new workspace. When the
  prefix already has other workspaces, OpenTofu must read the bucket root to
  create one. Create the workspace once with wider credentials before the
  first pipeline of a new deployment:

  ```bash
  cd deployments
  tofu init -backend-config=backends/<deployment>.s3.tfbackend
  tofu workspace select -or-create <deployment>
  ```

  If the workspace is missing, the CI job tries to create it and stops with
  an error that points here.

A role with read access to the whole bucket needs none of this. Its first
job creates the workspace.

`tf.sh` picks the auth mode from the platform, not from the AWS variables that
happen to be set:

| Where `tf.sh` runs | How it gets credentials |
| --- | --- |
| GitLab CI (`GITLAB_CI` is set) | From the GitLab job token. `tf.sh` unsets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `AWS_PROFILE` first, and prints a warning if one of them was set. |
| GitHub Actions (`GITHUB_ACTIONS` is set) | From `aws-actions/configure-aws-credentials`, which runs before `tf.sh`. `tf.sh` stops if `AWS_ACCESS_KEY_ID` is not set. |
| Your machine | The normal AWS credential chain, for example `AWS_PROFILE` and an SSO session |

Before OpenTofu runs, `tf.sh` runs `aws sts get-caller-identity`. In CI the
caller must be the role in `ci.aws_role_arn`: the same account and the same
role name. If it is not, the job stops before OpenTofu touches AWS. CI jobs
need the AWS CLI for this check. On your own machine, only the account must
match. See [Run the CI script locally](#run-the-ci-script-locally).

#### GitLab OIDC

GitLab makes a JWT (JSON Web Token) for each job. The `id_tokens` key under
`default:` in [`tf-templates.yml`](./.ci/templates/tf-templates.yml) puts it
in `GITLAB_OIDC_TOKEN`. `tf.sh` writes the token to a file for this job only
(`${TMPDIR:-/tmp}/gitlab-oidc-<job id>.jwt`) and points
`AWS_WEB_IDENTITY_TOKEN_FILE` at it. It exports `AWS_ROLE_ARN` from
`ci.aws_role_arn`. The AWS SDK then trades the token for role credentials.
`tf.sh` deletes the token file when it exits.

If the identity check fails and `PRINT_OIDC_CLAIMS` is `"true"` (the
default), the job log shows the claims in the token. Compare them with the
trust policy. If `PRINT_OIDC_CLAIMS` is `"false"`, the log does not show the
claims. In CI the identity check always runs.

The audience (`aud`) of the token is set by `OIDC_AUDIENCE` in
`tf-templates.yml`. By default it is `$CI_SERVER_URL`, the URL of your GitLab
instance. On gitlab.com, the identity provider is `gitlab.com` and the
audience is `https://gitlab.com`. A sample trust policy for gitlab.com:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/gitlab.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "gitlab.com:aud": "https://gitlab.com",
          "gitlab.com:sub": "project_path:<group>/<project>:ref_type:branch:ref:<default-branch>"
        }
      }
    }
  ]
}
```

On a self-managed GitLab instance, make the IAM OIDC provider with your
GitLab URL (`https://<your-gitlab-host>`) as the provider URL and as the
audience. In the policy, change `gitlab.com` to `<your-gitlab-host>` in the
provider ARN and in the condition keys, and set the `aud` value to
`https://<your-gitlab-host>`.

This policy allows only jobs on the default branch. GitLab also runs plan
jobs on other branches and in merge requests. The `sub` claim of those jobs
names that branch. If you want plans on other branches, change
`StringEquals` to `StringLike` and set the `sub` value to
`project_path:<group>/<project>:ref_type:branch:ref:*`. This lets jobs on
every branch of the project use the role, because one role runs plan and
apply.

> **Warning:** Do not use `ref:*` on the role of a prod deployment. With
> `ref:*`, every person who can push a branch gets full apply and destroy
> rights with that role. That person can change `.gitlab-ci.yml` on the branch
> to run `tofu apply` or `tofu destroy`. Protected branches, manual
> prod applies and the destroy rules do not stop this. A fork merge request
> pipeline that a Maintainer runs in this project also gets a matching token.
> Do these things instead:
>
> - Keep prod roles on the default-branch `sub` above.
> - Protect the default branch. Allow no push and no force push for the
>   Developer role.
> - If you want plans for prod on other branches, give plan jobs a separate
>   read-only role. The template uses one role per deployment, so this needs a
>   change to `tf.sh`.
> - Never run fork merge request pipelines in this project.

The `sub` claim names the branch, not the environment. AWS cannot check the
`environment` or `environment_protected` claims of a GitLab token. On
gitlab.com, AWS can also check some other claims, for example
`ref_protected`. Add `"gitlab.com:ref_protected": "true"` under
`StringEquals` to allow only protected branches. On a self-managed GitLab
instance, AWS checks only `sub` and `aud`. Protected branches and
[protected environments](#gitlab-environments) are then the real controls.

GitLab jobs run in an image that you build from this repo. See
[CI image](#ci-image).

#### GitHub OIDC

The `aws-actions/configure-aws-credentials` action gets the credentials. It
uses the role and region of the deployment, from `ci.aws_role_arn` and
`aws.region`. `tf.sh` then checks that the credentials belong to that role.

The identity provider is `token.actions.githubusercontent.com`. The audience
(`aud`) is `sts.amazonaws.com`. The `sub` claim depends on the job:

| Job | `sub` claim |
| --- | --- |
| Plan on a pull request | `repo:<owner>/<repo>:pull_request` |
| Plan or destroy-plan on the default branch | `repo:<owner>/<repo>:ref:refs/heads/<default-branch>` |
| Apply for a tier | `repo:<owner>/<repo>:environment:<tier>` (`develop`, `stage` or `prod`) |
| Destroy | `repo:<owner>/<repo>:environment:destroy` |

A sample trust policy for a role in the prod tier:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": [
            "repo:<owner>/<repo>:pull_request",
            "repo:<owner>/<repo>:ref:refs/heads/<default-branch>",
            "repo:<owner>/<repo>:environment:prod",
            "repo:<owner>/<repo>:environment:destroy"
          ]
        }
      }
    }
  ]
}
```

For a role in another tier, change `environment:prod` to the tier name.

> **Warning:** A pull request run uses the workflow files and `tf.sh` from the
> pull request branch. So the `pull_request` `sub` gives the full role to every
> person who can push a branch and open a pull request. That person can change
> the plan job to run `tofu apply` with the prod role. The required
> reviewers of `prod` and `destroy` do not stop this. If this matters to you,
> remove `repo:<owner>/<repo>:pull_request` from the policy of prod roles. Pull
> request plans for prod then fail. Another option is to give plan jobs a
> separate read-only role. This is a known limit of the template, because it
> uses one role per deployment for plan, apply and destroy.

> **Warning:** The `environment:<name>` `sub` is safe only when the
> environment allows the default branch only (see
> [GitHub Environments](#github-environments)). Without that limit, every
> person with write access can push a branch with a new workflow that uses
> `environment: prod` or `environment: destroy`. GitHub gives that job the
> same `sub`, and the role trusts it. No pull request or merge is needed. The
> `is_default_branch` check in `terraform.yml` does not stop this, because the
> branch can change that file.
>
> If you cannot limit environments to a branch, add the branch to the `sub`
> claim. Change the OIDC subject format of the repository with the GitHub
> API:
>
> ```bash
> gh api -X PUT repos/<owner>/<repo>/actions/oidc/customization/sub \
>   -F use_default=false -f 'include_claim_keys[]=repo' \
>   -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=ref'
> ```
>
> The `sub` of an apply job then also holds the branch, for example
> `repo:<owner>/<repo>:environment:prod:ref:refs/heads/<default-branch>`. The
> format changes for every job, so update every trust policy. Look at the
> claims of a test run before you rely on them. Also protect the default
> branch with a ruleset.

Some runs cannot get credentials:

- Pull requests from forks get no OIDC token from GitHub. They run only the
  validate and setup jobs. No job that uses AWS runs.
- A manual run on a branch that is not the default branch has the `sub`
  claim `repo:<owner>/<repo>:ref:refs/heads/<branch>`. The sample policy does
  not allow it, so its plan and destroy-plan jobs fail. Start manual runs on
  the default branch, or add that `sub` value to the policy.
- A merge queue run (`merge_group`) runs only the validate and setup jobs. See
  [Merge queue](#merge-queue-github).

#### AWS session length on GitHub

The credentials from `configure-aws-credentials` last a fixed time and do not
renew. If a job runs longer, OpenTofu loses access to AWS in the middle of
the apply. It can then fail to write the state.

The repository variable `AWS_ROLE_DURATION_SECONDS` sets the session length.
Set it under Settings > Secrets and variables > Actions > Variables. If it is
not set, the session lasts 3600 seconds (one hour). AWS allows 900 to 43200
seconds. The setup job stops with an error for other values.

Each job stops 5 minutes before its credentials end. For example, 3600
seconds gives a job time limit of 55 minutes. Time that a job waits for
approval or in the queue does not count.

To allow longer applies:

1. Raise `MaxSessionDuration` of every deployment role in IAM to at least the
   new value. If a role allows less, the credentials step of its jobs fails.
2. Set `AWS_ROLE_DURATION_SECONDS` to the new value.

GitHub-hosted runners stop every job after 6 hours. So a value above 21900
gives no extra time on those runners.

## Pipeline

Every job definition is in this repo, so a fork owns its whole pipeline.

> **Tip:** If many GitLab projects use this pipeline, you can move
> `.ci/templates/tf-templates.yml` to a shared project and include it from
> there.

### Files

| Path | Platform | Holds |
| --- | --- | --- |
| [`.ci/scripts/tf.sh`](./.ci/scripts/tf.sh) | Both | All OpenTofu steps: `validate`, `plan`, `apply`, `destroy-plan`, `destroy`, and `matrix` (the deployment list for GitHub) |
| [`.gitlab-ci.yml`](./.gitlab-ci.yml) | GitLab | Pipeline inputs, `workflow:rules` and the two local includes |
| [`.ci/templates/tf-templates.yml`](./.ci/templates/tf-templates.yml) | GitLab | `.validate`, `.plan`, `.apply`, `.destroy-plan`, `.destroy`, the stage list, and the `default:` image and `id_tokens` |
| [`.ci/image/Dockerfile`](./.ci/image/Dockerfile) | GitLab | The image that every GitLab job runs in |
| [`.ci/configs/`](./.ci/configs/) | GitLab | `validate.yml` holds the shared `validate` job. The other files hold one job per deployment. Each of those jobs extends a template above and sets `DEPLOYMENT` |
| [`.github/workflows/terraform.yml`](./.github/workflows/terraform.yml) | GitHub | Triggers, inputs, the `validate` and `setup` jobs, and one job per tier and step |
| [`.github/workflows/tf-deploy.yml`](./.github/workflows/tf-deploy.yml) | GitHub | The steps for one tier: checkout, tools, AWS credentials, `tf.sh`, plan files, and the list of deployments with changes |
| [`.github/actions/setup-tools/action.yml`](./.github/actions/setup-tools/action.yml) | GitHub | Installs the pinned OpenTofu and yq versions on the runner |

### CI image

GitLab jobs run in a container image. [`.ci/image/Dockerfile`](./.ci/image/Dockerfile)
builds it. The image holds:

- OpenTofu (`tofu`), the same version as
  [`.github/actions/setup-tools/action.yml`](./.github/actions/setup-tools/action.yml)
  and the `TF_IMAGE` tag in `tf-templates.yml`
- mikefarah yq 4 (`tf.sh` reads the deployment configs with it)
- the AWS CLI v2 (the identity check) and jq (the change marker and the token
  claims)
- shellcheck (the validate job lints `tf.sh`)
- bash, git and ca-certificates

Each download in the Dockerfile is pinned to a SHA256 hash. The base image is
pinned to a digest.

`TF_IMAGE` in [`tf-templates.yml`](./.ci/templates/tf-templates.yml)
selects the image. By default it is `$CI_REGISTRY_IMAGE/tofu:1.13.1`.
`CI_REGISTRY_IMAGE` is the address of this project's GitLab container
registry. Build and push the image before the first pipeline runs:

```bash
docker login <registry>
docker buildx build --platform linux/amd64 \
  -t <registry>/<group>/<project>/tofu:<tofu-version> \
  --push .ci/image
```

`<registry>` is the host of your GitLab container registry. In a job, GitLab
puts it in `$CI_REGISTRY`. On gitlab.com it is `registry.gitlab.com`. On a
self-managed instance, it is the registry host that your admin set up for
`<your-gitlab-host>`. The project page Deploy > Container registry shows the
full address.

Replace `<tofu-version>` with `TOFU_VERSION` from the Dockerfile.
Use `linux/arm64` if your runners are ARM. If your runners pull from another
registry, push the image there and change `TF_IMAGE`.

The templates set no `pull_policy`. The runner uses its own pull policy.
Each OpenTofu version has its own image tag, so you do not have to force a
pull.

### Change a tool version

The OpenTofu and yq versions are pinned in more than one place. Keep them
the same, so both pipelines and your machine run the same tools.

To change the OpenTofu version:

1. In [`.ci/image/Dockerfile`](./.ci/image/Dockerfile), change
   `TOFU_VERSION`, `TOFU_SHA256_AMD64` and `TOFU_SHA256_ARM64`. The
   Dockerfile header says where to find the hashes.
2. In [`tf-templates.yml`](./.ci/templates/tf-templates.yml), change the tag
   in `TF_IMAGE`.
3. In [`.github/actions/setup-tools/action.yml`](./.github/actions/setup-tools/action.yml),
   change `tofu_version` and the two hashes in `checksums`. Use the same
   hashes as the Dockerfile. Every GitHub job uses this action.
4. Make sure that the new version meets `required_version` in
   `deployments/versions.tf` and `terraform/versions.tf`. The default is
   `>= 1.13.0`, and CI pins 1.13.1. If you raise the lowest version that the
   code needs, change `required_version` in both files. They must match.
5. Update the version shown in the CI image section of this README.
6. Build and push the image with the new tag (GitLab only).

To change the yq version, change `YQ_VERSION` and its two hashes in the
Dockerfile and in `.github/actions/setup-tools/action.yml`. Then build and
push the image. `tf.sh` needs mikefarah yq 4.18 or newer.

The AWS CLI version is pinned only in the Dockerfile. GitHub jobs use the AWS
CLI of the runner image.

### Provider lock file

`deployments/.terraform.lock.hcl` records the provider versions and their
hashes. Keep it in the repository. Without it, each plan picks the newest
provider version that the version constraints allow. The template comes with
a lock file that pins the AWS provider (`~> 6.0` in `versions.tf`) to 6.71.0.
The hashes come from the OpenTofu registry (`registry.opentofu.org`). They
cover every platform that the provider is built for, including
`linux_amd64`, `linux_arm64`, `darwin_amd64` and `darwin_arm64`.

After you add a provider or change a provider version, update the lock file
in `deployments/` and commit it:

```bash
cd deployments/
tofu init -backend=false -upgrade
tofu providers lock \
  -platform=linux_amd64 -platform=linux_arm64 \
  -platform=darwin_amd64 -platform=darwin_arm64
```

The `providers lock` command records hashes for every platform. Without it,
the lock file can hold hashes only for your machine, and CI init fails with
a checksum error.

CI also saves a copy of the lock file next to each plan file:
`deployments/<deployment>.lock.hcl` for a plan, and
`deployments/<deployment>-destroy.lock.hcl` for a destroy plan. The apply or
destroy job puts that copy back before `tofu init`, and runs init with
`-lockfile=readonly`. So apply uses the same providers as the plan, even when
a new provider version comes out between plan and apply. `.gitignore` ignores
these copies.

### Order of jobs

A tier is a group of deployments with the same `env` value: `develop`,
`stage` or `prod`. Both pipelines run validate first. Then they plan and
apply one tier at a time, in the order develop, stage, prod. To use other
tiers, see [Change the tiers](#change-the-tiers). If a job fails, the later
tiers do not run. On GitHub, this is also true
when a job is cancelled. A skipped job does not stop the later tiers.

Each pipeline has these inputs. You set them when you start a run by hand:

- `destroy`: Run only destroy-plan and destroy jobs. Destroy jobs run only on
  the default branch. `destroy` wins over `force-plan` and `force-apply`. On
  GitHub, a destroy run covers one deployment, named in the `deployment`
  input. On GitLab, it covers every deployment that has jobs in
  `.ci/configs/destroy.yml`, all tiers at once (see the table below).
- `deployment` (GitHub only): The one deployment to destroy, for example
  `develop-a1b2c3d4`. A run with `destroy` turned on and no `deployment`
  stops in the setup job. A run with `deployment` set and `destroy` turned
  off also stops.
- `force-plan`: Run all plan jobs.
- `force-apply`: Run all plan and apply jobs. Apply jobs run only on the
  default branch.

On a push or a pull request (GitLab: merge request) without these inputs,
plan jobs run when a file under `deployments/` or `terraform/` changed. Apply
jobs run only on the default branch. A manual run without inputs works
differently on each platform. See the table below.

Some rules differ between the platforms:

| Rule | GitLab | GitHub |
| --- | --- | --- |
| Plan on a push to a branch that is not the default branch | Yes, if files changed. If the branch has an open merge request, the merge request pipeline plans instead, and the push starts no branch pipeline | No. Open a pull request to get plans |
| Plan on a push to the default branch | Always | Only if files changed |
| Apply for a plan with no changes | Runs. Nothing changes | Skipped. See [Applies with no changes](#applies-with-no-changes-github) |
| Manual approval for apply | Prod apply jobs are manual. With `force-apply`, every apply job is manual | Only prod, through the reviewers of the `prod` environment |
| Manual approval for destroy | Each destroy job is manual | Through the reviewers of the `destroy` environment |
| What a destroy run covers | Every deployment in `.ci/configs/destroy.yml`, all tiers at the same time | One deployment, from the `deployment` input |
| Manual run on the default branch without inputs | Plans and applies every deployment (prod apply stays manual), because `changes:` is always true for manual pipelines | Runs only validate and setup. Use `force-plan` or `force-apply` |
| A new commit while a pipeline runs | See [Auto-cancel](#auto-cancel) | Nothing is cancelled |

### Change the tiers

The tiers are `develop`, `stage` and `prod`, in that order. This is a
default. You can add, remove or rename tiers, but the tier names are in many
files. Change all of these places together:

| File | What to change |
| --- | --- |
| [`.ci/scripts/tf.sh`](./.ci/scripts/tf.sh) | `TIERS`. Its order is the pipeline order. A config whose `env` is not in this list fails |
| [`.ci/templates/tf-templates.yml`](./.ci/templates/tf-templates.yml) (GitLab) | `stages:`. Each tier has a `plan-<tier>`, an `apply-<tier>` and a `destroy-<tier>` stage. The `.apply` rules find prod by the `prod-` prefix of the deployment name. Prod apply jobs are manual |
| [`.ci/configs/`](./.ci/configs/) (GitLab) | The `stage:` of each job, and the stage names in the commented examples |
| [`.github/workflows/terraform.yml`](./.github/workflows/terraform.yml) (GitHub) | The setup job outputs (one per tier), the `plan-<tier>`, `apply-<tier>`, `destroy-plan-<tier>` and `destroy-<tier>` jobs, the `needs:` chains, the `environment:` names and the header comment |
| [`deployments/configs/default.yaml`](./deployments/configs/default.yaml) | The `env` line |
| [`Taskfile.yml`](./Taskfile.yml) | The GitHub Environments in the next-steps text of `ci:use-github` |
| This README | This section, [Order of jobs](#order-of-jobs), the `sub` table in [GitHub OIDC](#github-oidc) and [GitHub Environments](#github-environments) |

Outside the repository, also change:

- On GitHub, the environments under Settings > Environments, and the
  `environment:<tier>` values in the trust policies of the roles.
- On GitLab, the protected environments, if you protect them by name (for
  example `prod-*`).

On GitHub, `tf.sh matrix` prints one line per tier in `TIERS`, and the setup
job reads each of them as an output. A tier with no job in `terraform.yml`
never runs. After the change, run
[actionlint](https://github.com/rhysd/actionlint) on the workflow files.

A deployment whose `env` changes gets a new name, so it is a new deployment.
See [Removing a deployment](#removing-a-deployment).

### Applies with no changes (GitHub)

After a tier's plan jobs, a `changes` job reads the change marker of each
plan. The marker is the file `deployments/<deployment>.changes`. `tf.sh plan`
writes `true` when the plan changes a resource or an output, and `false` when
it changes nothing. A data source read does not count as a change. An import
or a `moved` block counts.

The apply job of the tier applies only the deployments with `true`. When no
plan in the tier has changes, the apply job is skipped, so nobody has to
approve an apply that does nothing. This is also true with `force-apply`. An
apply of a plan with no changes does nothing, so `force-apply` gives you new
plans, not extra applies. A skipped apply does not stop the later tiers.

GitLab keeps the marker in the plan artifact, but its apply jobs do not read
it.

### Merge queue (GitHub)

The workflow runs on the `merge_group` event, so you can make its checks
required for a merge queue. A merge queue run runs only the validate and
setup jobs. It plans and applies nothing, because the pull request already
ran its plans. Pushes to the merge queue branches (`gh-readonly-queue/...`)
do not start a second run.

### Where tf.sh gets its values

Each job sets only `DEPLOYMENT`, the deployment name. `tf.sh` loads
`deployments/configs/$DEPLOYMENT.yaml` and reads `env`, `deployment_id`,
`aws.region` and `ci.aws_role_arn`. It stops with an error in these cases:

- A field is missing.
- `env` is not one of the tiers in `TIERS` (see
  [Change the tiers](#change-the-tiers)).
- `<env>-<deployment_id>` is not the same as the file name.
- `env` or `deployment_id` is an unquoted value that YAML reads as a number.
- `ci.aws_role_arn` is not an IAM role ARN.
- `deployments/backends/$DEPLOYMENT.s3.tfbackend` does not exist.

On GitHub, the setup job runs `tf.sh matrix`. It reads every config except
`default.yaml` and groups the deployments by tier. You do not list
deployments in the workflow files. It stops with an error if any config is
not valid, or if `deployments/configs/` holds a file that is not `.yaml`. For
a destroy run, the setup job sets `ONLY_DEPLOYMENT` to the `deployment`
input. `tf.sh matrix` then reads and checks only that config, and stops if it
does not exist.

`tf.sh` sets `TF_IN_AUTOMATION=1` and `CHECKPOINT_DISABLE=1` for every
OpenTofu command. OpenTofu then prints shorter output. `CHECKPOINT_DISABLE`
matters only for Terraform: it stops calls to the HashiCorp version check
service.

### One job per deployment at a time

Only one job can change a deployment at a time. A second job for the same
deployment waits. On GitLab, the templates set `resource_group: $DEPLOYMENT`.
On GitHub, each job sets `concurrency: tf-<deployment>`. GitHub keeps only
one waiting job per group. If a third job starts to wait, GitHub cancels the
older waiting job.

On GitHub, pull request plans use the same group as the default-branch jobs.
So a default-branch run can end with a cancelled plan or apply job, when pull
request plans for the same deployment wait at the same time. The later tiers
of that run then do not run, and the change is not applied. The next push
applies it only if that push changes a file under `deployments/` or
`terraform/`. If this happens, do one of these:

- Re-run the failed and cancelled jobs of the run.
- Start a manual run on the default branch with `force-apply` turned on.

### Stale plans

The lock covers one job, not the pair of plan and apply. A newer pipeline can
plan and apply a deployment between the plan and the apply of an older
pipeline. The older apply then fails with `Saved plan is stale`. Nothing
changes in AWS. To apply the change:

- On GitLab, run the plan job of that pipeline again. Then run its apply job.
- On GitHub, start a manual run on the default branch with `force-apply`
  turned on. A re-run of only the failed apply job uses the same stale plan.

### Auto-cancel

On GitLab, `workflow:rules` in `.gitlab-ci.yml` sets what happens to an
older pipeline when a new commit arrives. This works when the project setting
"Auto-cancel redundant pipelines" is on, which is the default.

- On the default branch, GitLab never cancels the older pipeline. Every
  merged change gets its plan and apply.
- On other branches, GitLab cancels the older pipeline only while its running
  jobs are interruptible. Only validate and plan jobs are interruptible.
  After an apply, destroy-plan or destroy job starts, GitLab keeps the older
  pipeline running.

On GitHub, the workflow sets no run-level `concurrency`. A new commit does not
cancel an older run. Only the per-deployment queue above cancels a waiting
job.

### State lock left after a failed job

The S3 backend locks the state while a job runs (`use_lockfile = true`). If a
job stops before OpenTofu can release the lock, the lock stays. For example,
a runner is lost, a job hits its time limit, or someone cancels the job. Each
later plan or apply for that deployment then fails with
`Error acquiring the state lock`. The error message shows the lock ID.

To remove the lock:

1. Make sure that no job for that deployment still runs, on any branch.
2. Log in to the deployment's account. See [Manual](#manual).
3. In `deployments/`, run init and select the workspace:

   ```bash
   tofu init -backend-config=backends/<deployment>.s3.tfbackend -reconfigure
   tofu workspace select <deployment>
   ```

4. Run `tofu force-unlock <LOCK_ID>`. Use the lock ID from the error
   message.

If the job stopped during an apply or destroy, part of the change can be
done. The saved plan is then stale. Run a new plan, look at it, and apply it.

### Plan files hold secrets

The plan jobs keep the plan file as a job artifact for 7 days, so the apply
or destroy job can use it. A plan file holds every value in plain text,
including values that OpenTofu marks as sensitive.

- On GitHub, every person who can read the repository can download the
  artifacts. In a public repository, that is everyone.
- On GitLab, the plan and destroy-plan templates set `access: developer`.
  Only users with the Developer role or higher can download the artifacts.
  Apply and destroy jobs upload no artifacts.

The plan text is also in the job logs, and on GitHub in the step summary of
each plan job. OpenTofu hides values that are marked as sensitive in this
text. It shows all other values, for example a password in a variable that
is not marked `sensitive`. `retention-days` and `expire_in` do not apply to
logs and step summaries. GitHub keeps them for the log retention time of the
repository. GitLab keeps job logs until someone deletes them, unless your
instance sets a limit.

- Keep the repository private, or keep secret values out of the state.
- Mark every secret variable and output as `sensitive`.
- To keep plan files for less time, lower `retention-days` in
  `tf-deploy.yml` (GitHub) or `expire_in` in `tf-templates.yml` (GitLab).
- On GitHub, lower the log retention under Settings > Actions > General.

### GitHub Environments

A GitHub Environment is a named set of rules for jobs. For example, an
environment can make a job wait until a reviewer approves it. The workflow
uses these environments:

| Jobs | Environment |
| --- | --- |
| Plan and destroy-plan | None |
| Apply for a tier | `develop`, `stage` or `prod` |
| Destroy | `destroy` |

Make the environments before the first run. If a job names an environment
that does not exist, GitHub makes it with no rules.

1. In the repository, go to Settings > Environments.
2. Make four environments: `develop`, `stage`, `prod` and `destroy`.
3. In each environment, set "Deployment branches and tags" to "Selected
   branches and tags". Add only the default branch.
4. In `prod` and `destroy`, turn on "Required reviewers" and add the people
   or teams that approve.

The environment name is in the `sub` claim of apply and destroy jobs. See
[GitHub OIDC](#github-oidc). Step 3 is what keeps that `sub` on the default
branch.

### Without required reviewers

Some GitHub plans do not offer required reviewers for private repositories.
Required reviewers in private repositories need GitHub Enterprise. On GitHub
Free, private repositories also cannot limit environments to a branch, so step
3 above is not available. In that case, prod applies and destroys do not wait
for approval.

The workflow still runs apply and destroy jobs only on the default branch. The
setup job checks this (`is_default_branch`). This check only prevents
mistakes. It is not a security control, because a branch can change the
workflow file. Without a branch limit on the environments, every person with
write access can get the prod or destroy role from a branch. To close this,
add the branch to the `sub` claim, as the second warning in
[GitHub OIDC](#github-oidc) shows.

Use manual runs (`workflow_dispatch`) as the approval step:

1. In `.github/workflows/terraform.yml`, add
   `&& github.event_name == 'workflow_dispatch'` to the `if:` of the
   `apply-prod` job. Put it inside the braces, before the closing `}}`. If you
   put it after `}}`, GitHub treats the condition as always true. The full
   line is:

   ```yaml
   if: ${{ !cancelled() && !failure() && !contains(needs.*.result, 'cancelled') && needs.setup.outputs.apply == 'true' && needs.plan-prod.result == 'success' && needs.plan-prod.outputs.changed != '' && needs.plan-prod.outputs.changed != '[]' && github.event_name == 'workflow_dispatch' }}
   ```

   Run [actionlint](https://github.com/rhysd/actionlint) on the file after
   the edit. It finds this mistake.
2. To apply prod, start the workflow by hand on the default branch, from the
   Actions tab. Turn on `force-apply`.

A push to the default branch then plans prod but does not apply it. Destroy
jobs already run only from a manual run with `destroy` turned on. This
fallback is weaker than reviewers, because every user with write access can
start a manual run.

### GitLab environments

Each GitLab job uses the environment named after its deployment, for example
`prod-a1b2c3d4`:

| Job | `environment:action` |
| --- | --- |
| Plan and destroy-plan | `prepare` (makes no deployment record) |
| Apply | `start` |
| Destroy | `stop` |

GitLab makes each environment when its first job runs. It guesses the tier of
the environment (production, staging and so on) from the name. If the guess
is wrong, change the tier in Operate > Environments.

With GitLab Premium or Ultimate, protect the prod environments:

1. Go to Settings > CI/CD > Protected environments.
2. Protect each `prod-*` environment. Allow deploys only for the users or
   roles that are allowed to apply to prod.
3. If you want approvals, set the number of required approvals.
4. Run a plan job for a prod deployment as a user who cannot deploy. Make
   sure that the plan job still runs. GitLab does not document whether a
   protected environment also blocks `prepare` jobs.

Also protect the default branch. See the warning in
[GitLab OIDC](#gitlab-oidc). AWS cannot check the environment claims of a
GitLab token, so the trust policy cannot require a protected environment.

## Adding a deployment

1. Generate a deployment ID with `task gen-deploy-id`.
2. Copy `deployments/configs/default.yaml` to
   `deployments/configs/<env>-<deployment_id>.yaml`. Fill in the values,
   including `ci.aws_role_arn`, and remove the comments. Keep the
   quotes around `deployment_id`.
3. Copy `deployments/backends/default.s3.tfbackend` to
   `deployments/backends/<env>-<deployment_id>.s3.tfbackend` and fill
   it in.
4. Make the IAM role for `ci.aws_role_arn`. See [CI Auth](#ci-auth). If
   the role may use only its own prefix of the state bucket, also create
   the workspace once. See [State access](#state-access).
5. If you added a provider or changed a provider version, update
   `deployments/.terraform.lock.hcl`. See
   [Provider lock file](#provider-lock-file).

On GitHub, you are done. The workflow finds the new config.

On GitLab, also add a job to each file in `.ci/configs/` that you need. Each
job sets its `stage`, `extends` and `DEPLOYMENT`. The stages are
`plan-<env>`, `apply-<env>` and `destroy-<env>`. Plan and destroy-plan jobs
have no `needs:`. The apply job lists its plan job in `needs:`, and the
destroy job lists its destroy-plan job. The job then waits for that job and
gets its artifacts (the plan file). For example, in `plan.yml`:

```yaml
develop-a1b2c3d4-plan:
  stage: plan-develop
  extends: .plan
  variables:
    DEPLOYMENT: develop-a1b2c3d4
```

`apply.yml` and `destroy.yml` have commented examples. Delete the
`*-placeholder` stub in a file when you add its first real job.

## Removing a deployment

Do not only delete the config file. On GitHub, the deployment then leaves
the pipeline without a word, and its AWS resources and its state stay. On
GitLab, its jobs fail. Also do not keep the config after a destroy. The next
change under `terraform/` or `deployments/` then makes the deployment again.

Do these steps in this order:

1. Destroy the deployment while its config still exists:
   - On GitHub, start the workflow by hand on the default branch. Turn on
     `destroy` and set `deployment` to the deployment name. Approve the
     `destroy` environment.
   - On GitLab, add the destroy-plan and destroy jobs for the deployment to
     `.ci/configs/destroy.yml` if they are not there. Start a pipeline on the
     default branch with `destroy` set to `true`. Start only the manual
     destroy job of this deployment.
2. Delete the empty workspace. Log in to the deployment's account (see
   [Manual](#manual)) and run these commands in `deployments/`:

   ```bash
   tofu init -backend-config=backends/<deployment>.s3.tfbackend -reconfigure
   tofu workspace select default
   tofu workspace delete <deployment>
   ```

   OpenTofu refuses to delete a workspace whose state still holds
   resources. So this step also makes sure that the destroy is complete.
3. In one pull request or merge request, delete these files:
   - `deployments/configs/<deployment>.yaml`
   - `deployments/backends/<deployment>.s3.tfbackend`
   - On GitLab, the jobs of the deployment in `.ci/configs/`
4. On GitLab, delete the stopped environment in Operate > Environments.

A rename of a config, for example to move it to another tier, is a remove
and an add. The new name is a new workspace with empty state. OpenTofu tries
to make every resource again, and the old resources stay under the old
workspace. Destroy the old deployment first, or move the state by hand.

## Deployment Selection

You must select and activate a deployment config before running plan/apply locally.

### With Task

`task tf-switch` provides a fuzzy-search picker over all deployment configs.
Select a deployment and it runs `tofu init` and `workspace select`
automatically. It needs [fzf](https://github.com/junegunn/fzf) and OpenTofu.
If one is missing, the task stops and says how to install it. If you press
Esc or pick nothing, the task stops and changes nothing.

> **Note:** Log in with `aws sso login --profile <profile>` and export
> `AWS_PROFILE` and `AWS_DEFAULT_REGION` for the target account before running
> `tf-switch`.

```
task tf-switch
```

After selecting the deployment, run `tofu plan` and `tofu apply`
commands as needed.

### Manual

1. Log in to the AWS account of the deployment, and set the profile and
   region for the next commands:

   ```bash
   aws sso login --profile <profile>
   export AWS_PROFILE=<profile> AWS_DEFAULT_REGION=<region>
   ```

2. Run OpenTofu against the workspace of the deployment:

   ```bash
   cd deployments/
   tofu init -backend-config=backends/<env>-<deployment_id>.s3.tfbackend -reconfigure
   tofu workspace select -or-create <env>-<deployment_id>
   tofu plan
   ```

The AWS provider uses your SSO session credentials. To use a specific role
locally instead (for example, the CI role), make a profile in
`~/.aws/config` with `role_arn = <ci role>` and
`source_profile = <sso profile>`. Then set `AWS_PROFILE` to that profile. You
can also get role credentials with `aws sts assume-role`.

### Run the CI script locally

You can run `tf.sh` on your own machine. It needs:

- bash 4 or newer. macOS has bash 3.2 as `/bin/bash`. Run `brew install bash`
  (or install bash 4 or newer with your package manager) and make sure that
  the new bash is first on your `PATH`. `tf.sh` stops with an error on an
  older bash.
- mikefarah yq 4.18 or newer.
- [OpenTofu](https://opentofu.org/docs/intro/install/) 1.13 or newer.

`tf.sh` uses your normal AWS credential chain, so `AWS_PROFILE` works:

```bash
aws sso login --profile <profile>
AWS_PROFILE=<profile> DEPLOYMENT=<env>-<deployment_id> .ci/scripts/tf.sh plan
```

Before OpenTofu runs, `tf.sh` checks with the AWS CLI that your credentials
are for the account of `ci.aws_role_arn`. If the account is different, it
stops. If you use another role in the same account, it prints a warning and
goes on. If the AWS CLI is not installed, or `PRINT_OIDC_CLAIMS=false` is
set, it skips this check. In CI, `PRINT_OIDC_CLAIMS=false` never skips it.

The plan writes these files in `deployments/`. Git ignores them:

- `<env>-<deployment_id>.out`, the plan file
- `<env>-<deployment_id>.lock.hcl`, the copy of the lock file
- `<env>-<deployment_id>.changes`, the change marker. `tf.sh` skips
  it if jq is not installed.

Do not run `tf.sh` in a shell that has `GITLAB_CI` or `GITHUB_ACTIONS` set.
`tf.sh` then uses the CI auth mode.

## Task Commands

This project uses [Task](https://taskfile.dev) for common operations. The
tasks do not install tools. A task that needs a missing tool stops and says
how to install it. The tasks run `tofu`. See
[Use Terraform instead](#use-terraform-instead).

| Command              | Description                                          | Needs |
| -------------------- | ---------------------------------------------------- | ----- |
| `task tf-switch`     | Fuzzy-search deployments, init + workspace select    | fzf, OpenTofu |
| `task ls-deploys`    | List deployments and their descriptions              | |
| `task gen-deploy-id` | Generate a unique deployment ID (8 hex characters)   | hexdump |
| `task gen-docs`      | Write `terraform/README.md` and a README for each module in `terraform/modules/`. It replaces the whole content of these files | terraform-docs |
| `task tf-fmt`        | Format the OpenTofu code recursively                 | OpenTofu |
| `task ci:use-github` | Keep GitHub Actions and delete the GitLab CI files   | gum (optional) |
| `task ci:use-gitlab` | Keep GitLab CI and delete the GitHub Actions files   | gum (optional) |

## Use Terraform instead

OpenTofu is the default. To use Terraform, change three things:

1. Set `TF_BIN=terraform`. `tf.sh` and the tasks run `$TF_BIN`. In CI, set it
   as a CI/CD variable (GitLab) or as `env:` on the jobs (GitHub).
2. Install Terraform in the CI image (`.ci/image/Dockerfile`), or in
   `.github/actions/setup-tools/action.yml` with
   `hashicorp/setup-terraform` and `terraform_wrapper: false`.
3. Update the lock file with `terraform`, as
   [Provider lock file](#provider-lock-file) shows, and commit it. The
   committed lock file has hashes for the OpenTofu registry only. Terraform
   adds hashes for its own registry (`registry.terraform.io`).

`required_version` is `>= 1.13.0`, so Terraform 1.13 and newer also work.
