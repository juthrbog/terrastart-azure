<!-- Fork: change this title to the name of your project. -->
# &lt;project-name&gt;

## Overview

<!-- Fork: replace this overview with a description of your project. -->

This is a starter template for an [OpenTofu](https://opentofu.org) project
on Azure. It gives you:

- `terraform/`: the OpenTofu code. Put your resources and modules here.
- `deployments/`: the root module that runs the code in `terraform/`. Each
  deployment has one YAML config file and one azurerm backend file. The
  workspace name selects the config.
- A CI pipeline for GitLab CI and one for GitHub Actions. Both run the same
  script, `.ci/scripts/tf.sh`. They plan and apply one tier at a time
  (develop, stage, prod) and sign in to Azure through OIDC, with no stored
  secrets.
- [Task](https://taskfile.dev) commands for local work.

The folder name `terraform/`, the `.tf` files and the `.terraform*` files
keep their names. OpenTofu reads them the same way.

The template works with the Azure public cloud only
(`login.microsoftonline.com` and `management.azure.com`). Sovereign clouds,
for example Azure Government or Azure China, are not supported out of the
box.

To use Terraform instead, see [Use Terraform instead](#use-terraform-instead).

## Quick start

1. Pick your CI platform. See [CI Platform](#ci-platform).
2. Add your first deployment. See [Adding a deployment](#adding-a-deployment).
3. Make the state storage account, the CI identity, its roles and its
   federated credentials. See [CI Auth](#ci-auth).
4. Put your resources in `terraform/` and push. The pipeline plans the
   change.

## Usage

### Config

See the [default config](./deployments/configs/default.yaml) for options and
their descriptions. `deployments/main.tf` loads the whole file. OpenTofu does
not read the `ci:` block. Only the CI script reads it.

The `azure:` block sets the region, the subscription and the tenant of the
deployment:

```yaml
azure:
  location: eastus
  subscription_id: "<subscription-guid>"
  tenant_id: "<tenant-guid>"
```

`location` is the lowercase short name of an Azure region, for example
`eastus` or `westeurope`. Run `az account list-locations -o table` and use the
Name column. The azurerm provider has no provider-level region, so
`deployments/main.tf` passes `location` to `terraform/` as `var.location`.
Set `location = var.location` on each resource that needs a region.

The azurerm provider also has no default tags. `deployments/main.tf` builds
the tags `Name`, `env`, `deployment_id`, `service`, `owner` and `managed_by`
from the config and passes them to `terraform/` as `var.tags`. Set
`tags = var.tags` on each resource that supports tags.

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

### Azure

CI jobs sign in to Azure with OIDC (OpenID Connect) workload identity
federation. The CI platform makes a signed token for each job. Entra ID (the
Azure sign-in service) trusts that token when the CI identity has a
federated credential that matches it. Entra ID then gives the job an access
token for that identity. You store no client secrets, certificates or
storage account keys in CI.

Use one CI identity per deployment. A user-assigned managed identity is the
simple choice, and the commands below make one. An Entra ID app registration
also works. Each deployment config names the client ID of its identity:

```yaml
ci:
  azure_client_id: "<client-guid>"
```

`tf.sh` stops with an error if this value, `azure.subscription_id` or
`azure.tenant_id` is missing or is not a GUID. The same identity runs plan,
apply and destroy for that deployment.

Make these things before the first pipeline run:

1. A storage account for the state, with one container per deployment. See
   [State storage](#state-storage).
2. The CI identity of the deployment. See [CI identity](#ci-identity).
3. The roles of the identity. See [Roles](#roles).
4. The federated credentials of the identity, for your CI platform. See
   [GitLab OIDC](#gitlab-oidc) or [GitHub OIDC](#github-oidc).

The commands below use the Azure CLI (`az`). Run them as a user who may
make resources and role assignments, for example an Owner of the
subscription. A useful naming convention for identities is
`ci-<repo>-<deployment>`, for example `ci-my-repo-develop-a1b2c3d4`.

#### State storage

The azurerm backend keeps the state as blobs in a storage account. One
account can hold the state of many deployments. Give each deployment its own
container, for example `tfstate-<deployment_id>`. Then each CI identity can
reach only its own state.

Make the resource group and the storage account once:

```bash
az group create -n <state-rg> -l <location>

az storage account create -n <state-account> -g <state-rg> -l <location> \
  --sku Standard_ZRS --kind StorageV2 \
  --min-tls-version TLS1_2 --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false
```

- `<state-account>` must be unique in all of Azure: 3 to 24 lowercase
  letters and numbers.
- Set `--sku` yourself. The default is `Standard_RAGRS`. `Standard_ZRS`
  keeps copies in three zones of the region. Use `Standard_LRS` or
  `Standard_GRS` if ZRS is not available in your region.
- `--allow-shared-key-access false` turns off the storage account keys. All
  access then goes through Entra ID and Azure roles. The backend file sets
  `use_azuread_auth = true` for this.
- Use `TLS1_2`. Azure does not support `TLS1_3` here yet.

Turn on blob versioning and soft delete, so you can get back an old or
deleted state file. Use a number of days from 1 to 365:

```bash
az storage account blob-service-properties update -n <state-account> -g <state-rg> \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30
```

Make the container of each deployment. The storage account keys are off, so
make it through Azure Resource Manager:

```bash
az storage container-rm create -n tfstate-<deployment_id> \
  --storage-account <state-account> -g <state-rg>
```

Another way is `az storage container create -n tfstate-<deployment_id>
--account-name <state-account> --auth-mode login`. It needs a data role
(for example Storage Blob Data Contributor) on the account for the user who
runs it.

Then copy `deployments/backends/default.azurerm.tfbackend` to
`deployments/backends/<deployment>.azurerm.tfbackend` and fill in the
resource group, the account and the container. The backend file has no
sign-in settings. Those come from the `ARM_*` variables that `tf.sh` exports,
so the same file works in CI and on your machine. A state account in another
subscription needs no extra setting: with `use_azuread_auth = true` the
backend finds the account by name. A state account in another tenant does
not work with a managed identity, because the identity lives in one tenant.

#### State access

The backend keeps the state of workspace `<ws>` in the blob
`<key>env:<ws>`, for example `terraform.tfstateenv:develop-a1b2c3d4`, in the
container of the backend file. The `default` workspace uses the blob named
by `key`. This project never uses the `default` workspace.

- `tf.sh` runs `init` with `TF_WORKSPACE` set to the deployment. So `init`
  reads only that workspace's blob, not the blob of the `default` workspace.
- State locking uses a lease on the state blob (see
  [State lock left after a failed job](#state-lock-left-after-a-failed-job)).
- The CI identity needs the role Storage Blob Data Contributor on its
  container. With it, the first job creates the workspace by itself. See
  [Roles](#roles).

If the identity may not create blobs in the container, the CI job stops with
an error that points here. Create the workspace once with wider rights, then
run the job again:

```bash
cd deployments
tofu init -backend-config=backends/<deployment>.azurerm.tfbackend
tofu workspace select -or-create <deployment>
```

Do not share one container between deployments with different identities.
A role on a container gives access to every blob in it, so each identity
could read and change the state of the other deployments.

#### CI identity

Make a user-assigned managed identity for the deployment. Keep it in a
resource group that the deployment does not manage, so a destroy cannot
delete it:

```bash
az identity create -n ci-<repo>-<deployment> -g <identity-rg> -l <location>
az identity show -n ci-<repo>-<deployment> -g <identity-rg> \
  --query '{clientId: clientId, principalId: principalId}' -o json
```

- Put `clientId` in `ci.azure_client_id` of the deployment config.
- Use `principalId` for the role assignments below.

If you use an app registration instead, use its Application (client) ID as
`ci.azure_client_id`. Add the federated credentials under Certificates &
secrets > Federated credentials, with the same issuer, subject and audience
values as below. Do not add a client secret.

#### Roles

Give the identity these roles. Use `--assignee-object-id` with
`--assignee-principal-type ServicePrincipal`. This works right after you
make the identity, without a lookup in Entra ID:

```bash
# Read and write its own state.
az role assignment create \
  --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<state-subscription-id>/resourceGroups/<state-rg>/providers/Microsoft.Storage/storageAccounts/<state-account>/blobServices/default/containers/tfstate-<deployment_id>

# Make and change the resources of the deployment.
az role assignment create \
  --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope /subscriptions/<subscription-id>
```

- Contributor on the subscription is the simple choice. You can use a
  narrower role or scope, for example Contributor on one resource group.
- The identity check of `tf.sh` reads the subscription (the action
  `Microsoft.Resources/subscriptions/read`). A role on a resource group only
  may not allow this. Then also give the identity Reader on the
  subscription.
- Contributor cannot make role assignments. If your code makes role
  assignments (`azurerm_role_assignment`), also give the identity Role Based
  Access Control Administrator (with a condition that limits the roles it
  may assign) or User Access Administrator.
- A new role assignment can take up to about 10 minutes to work.

You also need Storage Blob Data Contributor on the container (or the
account) to run OpenTofu on your own machine. Owner and Contributor do not
give access to blob data.

#### Resource provider registration

Azure must register a resource provider (for example `Microsoft.Storage` or
`Microsoft.Network`) in a subscription before you can make its resources
there. By default, azurerm 4.x tries to register a long list of providers on
each run. If the identity may not register one of them, every plan fails.

So `deployments/providers.tf` sets `resource_provider_registrations =
"none"`. Register the providers that your code needs once per subscription,
as a user with enough rights:

```bash
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.Storage --query registrationState -o tsv
```

Registration can take a few minutes. If the CI identity may register
providers (for example Contributor on the subscription), you can list them in
`resource_providers_to_register` in `providers.tf` instead. Do not use
`skip_provider_registration`. It is deprecated, and it conflicts with
`resource_provider_registrations`.

#### How tf.sh signs in

`tf.sh` picks the auth mode from the platform, not from the Azure variables
that happen to be set:

| Where `tf.sh` runs | How it gets credentials |
| --- | --- |
| GitLab CI (`GITLAB_CI` is set) | From the GitLab job token in `GITLAB_OIDC_TOKEN`. `tf.sh` exports it as `ARM_OIDC_TOKEN`. |
| GitHub Actions (`GITHUB_ACTIONS` is set) | OpenTofu asks GitHub for OIDC tokens itself, with `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN`. `tf.sh` stops if they are not set. |
| Your machine | Your Azure CLI login (`az login`). See [Run the CI script locally](#run-the-ci-script-locally). |

In CI, `tf.sh` exports `ARM_USE_OIDC=true`, `ARM_CLIENT_ID` (from
`ci.azure_client_id`), `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` (from the
`azure:` block). The azurerm provider and the backend read these. `tf.sh` also
exports `ARM_USE_CLI=false`, so OpenTofu cannot fall back to a stray Azure CLI
login on the runner.

Some other `ARM_*` variables make OpenTofu sign in another way, for example
`ARM_CLIENT_SECRET`, `ARM_ACCESS_KEY` or `ARM_USE_MSI`. In CI, `tf.sh` unsets
all of these first, and prints a warning if one of them was set. So a group,
organization or instance CI/CD variable cannot change the identity of a job.

#### Identity check

Before OpenTofu runs, `tf.sh` checks the sign-in. In CI it uses curl and jq,
not the Azure CLI:

1. It gets the job's OIDC token. On GitHub, it asks GitHub for a token with
   the audience `api://AzureADTokenExchange`.
2. It trades the token with Entra ID for an access token of
   `ci.azure_client_id` in `azure.tenant_id`.
3. It checks that the access token is for that tenant (`tid`) and that client
   ID (`appid` or `azp`). If the token cannot be read, it prints a warning
   and goes on.
4. It reads `azure.subscription_id` with the access token. If this fails, it
   prints the error code and message from Azure.

If any step fails, the job stops before OpenTofu touches Azure. `tf.sh` never
prints a token.

When Entra ID refuses the trade, the log shows the `AADSTS` error from Entra
ID and a hint. The common errors:

| Error | Meaning | What to do |
| --- | --- | --- |
| `AADSTS700213` | No federated credential matches the subject of the token. The message shows the subject that was sent. A wrong issuer or audience can also give this error. | Compare the subject in the message with the credential. The match is exact and case-sensitive. |
| `AADSTS700211` | No federated credential has the issuer of the token. | Fix the issuer. See [GitLab OIDC](#gitlab-oidc) or [GitHub OIDC](#github-oidc). |
| `AADSTS70021` | No federated credential matches the token. | If you made the credential a few minutes ago, wait a few minutes and run the job again. If not, check issuer, subject and audience. |
| `AADSTS70025` | The identity has no federated credentials. | Add one. |
| `AADSTS700016` | Entra ID cannot find the client ID in the tenant. | Check `ci.azure_client_id` and `azure.tenant_id`. |
| `AADSTS700024` | The OIDC token has expired. | Run the job again. |
| `AADSTS700223`, `AADSTS700238` | The tenant does not allow workload identity federation for this identity. | Ask your Entra ID admin. |
| `AADSTS90002` | The tenant does not exist. | Check `azure.tenant_id`. |

If the trade fails and `PRINT_OIDC_CLAIMS` is `"true"` (the default), the job
log also shows the claims in the OIDC token, for example `iss`, `sub` and
`aud`. Compare them with the federated credential: issuer = `iss`, subject =
`sub`, audience = `aud`. If `PRINT_OIDC_CLAIMS` is `"false"`, the log does not
show the claims. In CI the identity check always runs.

If the trade works but reading the subscription fails (for example
`AuthorizationFailed` or `SubscriptionNotFound`), the identity has no role
on the subscription, or the subscription ID is wrong. See [Roles](#roles).

#### Federated credentials

A federated credential tells Entra ID which tokens may sign in as the
identity. It has three values, and a token must match all three:

- issuer: who made the token (`iss`)
- subject: which job made it (`sub`)
- audience: who the token is for (`aud`). Use `api://AzureADTokenExchange`.

Rules for federated credentials:

- The match is exact and case-sensitive. Wildcards do not work.
- Azure accepts a wrong subject when you make the credential. The error comes
  only when a job tries to sign in.
- An identity can have at most 20 federated credentials.
- Each credential has exactly one audience. The issuer and subject pair must
  be unique for each identity.
- The name has 3 to 120 characters: letters, numbers, `-` and `_`. It starts
  with a letter or number. You cannot change it later.
- Make the credentials of one identity one after another. Two at the same
  time on the same identity fail with HTTP 409.
- A new credential can take a few minutes to work.
- Federated credentials on user-assigned managed identities do not work in
  the Malaysia South region. Make the identity in another region.

#### GitLab OIDC

GitLab makes a JWT (JSON Web Token) for each job. The `id_tokens` key under
`default:` in [`tf-templates.yml`](./.ci/templates/tf-templates.yml) puts it
in `GITLAB_OIDC_TOKEN`. `tf.sh` exports it as `ARM_OIDC_TOKEN`, and the azurerm
provider and backend trade it with Entra ID. No token file is written.

The federated credential for GitLab uses these values:

| Value | GitLab |
| --- | --- |
| Issuer | `$CI_SERVER_URL`, the URL of your GitLab instance with no trailing slash. On gitlab.com: `https://gitlab.com` |
| Audience | `OIDC_AUDIENCE` in `tf-templates.yml`. By default `api://AzureADTokenExchange` |
| Subject | `project_path:<group>/<project>:ref_type:branch:ref:<branch>` |

Add one credential for the default branch to each identity:

```bash
az identity federated-credential create --name gitlab-default-branch \
  --identity-name ci-<repo>-<deployment> -g <identity-rg> \
  --issuer https://gitlab.com \
  --subject 'project_path:<group>/<project>:ref_type:branch:ref:<default-branch>' \
  --audiences api://AzureADTokenExchange
```

On a self-managed GitLab instance, use `https://<your-gitlab-host>` as the
issuer.

This credential allows only jobs on the default branch. GitLab also runs plan
jobs on other branches and in merge requests. The `sub` claim of those jobs
names that branch (in a merge request pipeline, the source branch). Their
plans fail with `AADSTS700213` until the identity trusts that branch too.
The subject names the branch, not the environment. GitLab cannot put the
environment name in `sub`. You have two ways to allow plans on other branches:

- Add one credential per branch. This works for a few long-lived branches.
  Remember the limit of 20 credentials per identity.
- Add one flexible federated credential. It matches claims with an
  expression, and it allows wildcards. Flexible federated credentials are a
  preview feature of Entra ID, so they can change. They work on user-assigned
  managed identities and on app registrations. A GitLab expression must
  match `sub` and also check `project_id`:

  ```bash
  az identity federated-credential create --name gitlab-all-branches \
    --identity-name ci-<repo>-<deployment> -g <identity-rg> \
    --issuer https://gitlab.com \
    --audiences api://AzureADTokenExchange \
    --claims-matching-expression-value "claims['sub'] matches 'project_path:<group>/<project>:ref_type:branch:ref:*' and claims['project_id'] eq '<project-id>'" \
    --claims-matching-expression-version 1
  ```

  The project ID is on the project overview page. These flags need a recent
  Azure CLI. Without them, make the credential with `az rest` and the
  Azure Resource Manager API version `2025-01-31-preview`. The azurerm
  provider cannot make flexible credentials.

> **Warning:** Do not trust every branch on the identity of a prod
> deployment. With a `ref:*` expression, every person who can push a branch
> gets full apply and destroy rights with that identity. That person can
> change `.gitlab-ci.yml` on the branch to run `tofu apply` or `tofu destroy`.
> Protected branches, manual prod applies and the destroy rules do not stop
> this. A fork merge request pipeline that a Maintainer runs in this project
> also gets a token from this project. Do these things instead:
>
> - Keep prod identities on the default-branch credential above.
> - Protect the default branch. Allow no push and no force push for the
>   Developer role.
> - If you want plans for prod on other branches, give plan jobs a separate
>   identity with read-only roles. The template uses one identity per
>   deployment, so this needs a change to `tf.sh`.
> - Never run fork merge request pipelines in this project.

A standard federated credential checks only the issuer, the subject and the
audience. It cannot check the `environment`, `environment_protected` or
`ref_protected` claims of a GitLab token. Protected branches and
[protected environments](#gitlab-environments) are the real controls.

GitLab can put some other values in `sub`, with the project setting
`ci_id_token_sub_claim_components` (for example `deployment_tier` or
`environment_protected`, GitLab 18.7 and newer). This setting changes the
`sub` of every job in the project, so the template does not use it.

GitLab jobs run in an image that you build from this repo. See
[CI image](#ci-image).

#### GitHub OIDC

There is no Azure login step in the workflow. Jobs that run `tf.sh` have the
permission `id-token: write`, so GitHub sets `ACTIONS_ID_TOKEN_REQUEST_URL`
and `ACTIONS_ID_TOKEN_REQUEST_TOKEN`. The azurerm provider and backend read
them, ask GitHub for a new OIDC token each time they need a new Azure token,
and trade it with Entra ID. So the Azure access does not run out during a
long job. Do not add an `azure/login` step.

The federated credential for GitHub uses these values:

| Value | GitHub |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Audience | `api://AzureADTokenExchange` |
| Subject | Depends on the job. See the table below |

In the table below, `<prefix>` is the start of the subject. Repositories
made, renamed or moved on github.com after 2026-07-15 use the ID form,
`repo:<owner>@<owner_id>/<repo>@<repo_id>`. A repository made from this
template today uses this form. To get the IDs, run
`gh api repos/<owner>/<repo> --jq '.owner.id, .id'`. Older repositories use
the name form, `repo:<owner>/<repo>`, unless an admin turned on the ID form
in the OIDC settings of the organization or repository.

| Job | `sub` claim |
| --- | --- |
| Plan on a pull request | `<prefix>:pull_request` |
| Plan or destroy-plan on a push or a manual run on the default branch (destroy-plan runs only on a manual run) | `<prefix>:ref:refs/heads/<default-branch>` |
| Apply for a tier | `<prefix>:environment:<tier>` (`develop`, `stage` or `prod`) |
| Destroy | `<prefix>:environment:destroy` |

A job with an environment always sends the `environment` subject, never the
`pull_request` or `ref` subject. So plan and destroy-plan jobs have no
environment.

If you are not sure which form your repository uses, run a plan and look at
the `AADSTS700213` message or the claims that `PRINT_OIDC_CLAIMS` prints.
Both show the subject that was sent.

Each identity needs four credentials. For an identity in the prod tier:

```bash
id=ci-<repo>-<deployment>
prefix='repo:<owner>@<owner_id>/<repo>@<repo_id>' # or 'repo:<owner>/<repo>'
for pair in \
  "github-pull-request $prefix:pull_request" \
  "github-default-branch $prefix:ref:refs/heads/<default-branch>" \
  "github-env-prod $prefix:environment:prod" \
  "github-env-destroy $prefix:environment:destroy"; do
  read -r name subject <<<"$pair"
  az identity federated-credential create --name "$name" \
    --identity-name "$id" -g <identity-rg> \
    --issuer https://token.actions.githubusercontent.com \
    --subject "$subject" \
    --audiences api://AzureADTokenExchange
done
```

The loop makes the credentials one after another. For an identity in another
tier, change `environment:prod` to the tier name.

> **Warning:** A pull request run uses the workflow files and `tf.sh` from the
> pull request branch. So the `pull_request` credential gives the full
> identity to every person who can push a branch and open a pull request.
> That person can change the plan job to run `tofu apply` with the prod
> identity. The required reviewers of `prod` and `destroy` do not stop this.
> If this matters to you, do not add the `pull_request` credential to prod
> identities. Pull request plans for prod then fail. Another option is to give
> plan jobs a separate identity with read-only roles. This is a known limit of
> the template, because it uses one identity per deployment for plan, apply
> and destroy.

> **Warning:** The `environment:<name>` credential is safe only when the
> environment allows the default branch only (see
> [GitHub Environments](#github-environments)). Without that limit, every
> person with write access can push a branch with a new workflow that uses
> `environment: prod` or `environment: destroy`. GitHub gives that job the
> same `sub`, and the identity trusts it. No pull request or merge is needed.
> The `is_default_branch` check in `terraform.yml` does not stop this,
> because the branch can change that file.
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
> `<prefix>:environment:prod:ref:refs/heads/<default-branch>`. The
> format changes for every job, so update every federated credential. Look at
> the claims of a test run before you rely on them. Also protect the default
> branch with a ruleset.
>
> With this format, the `sub` of a pull request job holds
> `refs/pull/<number>/merge`, which changes for each pull request. A standard
> federated credential must match exactly, so it cannot match it, and pull
> request plans fail. You then need a flexible federated credential
> (preview) whose expression matches `sub` with `*` and also checks
> `claims['repository_id'] eq '<repo_id>'`. Or you go without pull request
> plans.

Some runs cannot sign in:

- Pull requests from forks get no OIDC token from GitHub. They run only the
  validate and setup jobs. No job that uses Azure runs.
- A manual run on a branch that is not the default branch has the `sub`
  claim `<prefix>:ref:refs/heads/<branch>`. The credentials above
  do not allow it, so its plan and destroy-plan jobs fail. Start manual runs
  on the default branch, or add a credential for that branch.
- A merge queue run (`merge_group`) runs only the validate and setup jobs. See
  [Merge queue](#merge-queue-github).

#### Job time limit (GitHub)

The Azure access of a job does not run out. OpenTofu gets new tokens while
the job runs. So the only limit is the job time limit.

The repository variable `TF_TIMEOUT_MINUTES` sets how long each plan, apply
or destroy job may run. Set it under Settings > Secrets and variables >
Actions > Variables. If it is not set, the limit is 60 minutes. It must be a
whole number from 1 to 360. The setup job stops with an error for other
values. Time that a job waits for approval or in the queue does not count.

If a job hits the limit during an apply, OpenTofu stops in the middle and the
state lock stays. See
[State lock left after a failed job](#state-lock-left-after-a-failed-job).
Set the limit well above your longest apply.

GitHub-hosted runners stop every job after 6 hours, which is the highest
value (360).

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
| [`.github/workflows/tf-deploy.yml`](./.github/workflows/tf-deploy.yml) | GitHub | The steps for one tier: checkout, tools, `tf.sh`, plan files, and the list of deployments with changes |
| [`.github/actions/setup-tools/action.yml`](./.github/actions/setup-tools/action.yml) | GitHub | Installs the pinned OpenTofu and yq versions on the runner |

### CI image

GitLab jobs run in a container image. [`.ci/image/Dockerfile`](./.ci/image/Dockerfile)
builds it. The image holds:

- OpenTofu (`tofu`), the same version as
  [`.github/actions/setup-tools/action.yml`](./.github/actions/setup-tools/action.yml)
  and the `TF_IMAGE` tag in `tf-templates.yml`
- mikefarah yq 4 (`tf.sh` reads the deployment configs with it)
- curl and jq (the identity check calls Entra ID and Azure Resource Manager
  with curl, and reads the replies with jq. jq also writes the change marker)
- shellcheck (the validate job lints `tf.sh`)
- bash, git and ca-certificates

The image has no Azure CLI. It is large and hard to pin, and `tf.sh` does not
need it in CI.

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

curl and jq come from the Debian packages in the Dockerfile. GitHub jobs use
the curl and jq of the runner image.

### Provider lock file

`deployments/.terraform.lock.hcl` records the provider versions and their
hashes. Keep it in the repository. Without it, each plan picks the newest
provider version that the version constraints allow. The template comes with
a lock file that pins the azurerm provider (`~> 4.0` in `versions.tf`) to
4.81.0. The hashes come from the OpenTofu registry (`registry.opentofu.org`).
They cover all 15 platforms that the provider is built for, including
`linux_amd64`, `linux_arm64`, `darwin_amd64` and `darwin_arm64`.

> **Note:** 4.81.0 is most likely the last 4.x release. azurerm 5 is the
> current major version, and the 4.x line gets no more fixes. To move to it,
> change the constraint to `~> 5.0` in both `versions.tf` files, read the
> azurerm 5 upgrade guide, and update the lock file. In azurerm 5,
> `resource_provider_registrations` is `"none"` by default.

After you add a provider or change a provider version, update the lock file
in `deployments/` and commit it:

```bash
cd deployments/
tofu init -backend=false -upgrade
tofu providers lock \
  -platform=linux_amd64 -platform=linux_arm64 -platform=linux_386 -platform=linux_arm \
  -platform=darwin_amd64 -platform=darwin_arm64 \
  -platform=windows_amd64 -platform=windows_arm64 -platform=windows_386 \
  -platform=freebsd_amd64 -platform=freebsd_386 -platform=freebsd_arm \
  -platform=openbsd_amd64 -platform=openbsd_386 \
  -platform=solaris_amd64
```

The `providers lock` command records hashes for every platform in the list.
Without it, the lock file can hold hashes only for your machine, and CI init
fails with a checksum error. A new provider may not be built for every
platform in this list. Remove the platforms that it does not support.

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
| This README | This section, [Order of jobs](#order-of-jobs), the `sub` table and the example in [GitHub OIDC](#github-oidc) and [GitHub Environments](#github-environments) |

Outside the repository, also change:

- On GitHub, the environments under Settings > Environments, and the
  federated credentials with the `environment:<tier>` subject on the
  identities.
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
`azure.location`, `azure.subscription_id`, `azure.tenant_id` and
`ci.azure_client_id`. It stops with an error in these cases:

- A field is missing.
- `env` is not one of the tiers in `TIERS` (see
  [Change the tiers](#change-the-tiers)).
- `<env>-<deployment_id>` is not the same as the file name.
- `env` or `deployment_id` is an unquoted value that YAML reads as a number.
- `azure.location` is not a lowercase short region name, for example
  `eastus`.
- `azure.subscription_id`, `azure.tenant_id` or `ci.azure_client_id` is not
  a GUID.
- `deployments/backends/$DEPLOYMENT.azurerm.tfbackend` does not exist.

`tf.sh` exports `ARM_SUBSCRIPTION_ID` and `ARM_TENANT_ID` from the config. In
CI it also exports the sign-in variables. See
[How tf.sh signs in](#how-tfsh-signs-in).

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
changes in Azure. To apply the change:

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

The azurerm backend locks the state while a job runs. It takes a lease on the
state blob and writes the lock details to the blob. If a job stops before
OpenTofu can release the lock, the lease stays. For example, a runner is
lost, a job hits its time limit, or someone cancels the job. Each later plan
or apply for that deployment then fails with `Error acquiring the state
lock`. The error message shows the lock ID.

To remove the lock:

1. Make sure that no job for that deployment still runs, on any branch.
2. Log in to the deployment's tenant. See [Manual](#manual). You need
   Storage Blob Data Contributor on the state container.
3. In `deployments/`, run init and select the workspace:

   ```bash
   tofu init -backend-config=backends/<deployment>.azurerm.tfbackend -reconfigure
   tofu workspace select <deployment>
   ```

4. Run `tofu force-unlock <LOCK_ID>`. Use the lock ID from the error
   message.

If `force-unlock` does not work, break the lease on the blob:

```bash
az storage blob lease break --auth-mode login \
  --account-name <state-account> --container-name <container> \
  --blob-name 'terraform.tfstateenv:<deployment>'
```

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
[GitHub OIDC](#github-oidc). Entra ID compares it case by case, so use the
same spelling in the environment and in the federated credential. Step 3 is
what keeps that `sub` on the default branch.

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
write access can get the prod or destroy identity from a branch. To close
this, add the branch to the `sub` claim, as the second warning in
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
[GitLab OIDC](#gitlab-oidc). The federated credential cannot check the
environment claims of a GitLab token, so it cannot require a protected
environment.

## Adding a deployment

1. Generate a deployment ID with `task gen-deploy-id`.
2. Copy `deployments/configs/default.yaml` to
   `deployments/configs/<env>-<deployment_id>.yaml`. Fill in the values,
   including the `azure:` block and `ci.azure_client_id`, and remove the
   comments. Keep the quotes around `deployment_id` and the IDs.
3. Make the state container of the deployment. See
   [State storage](#state-storage).
4. Copy `deployments/backends/default.azurerm.tfbackend` to
   `deployments/backends/<env>-<deployment_id>.azurerm.tfbackend` and fill
   it in.
5. Make the CI identity, its roles and its federated credentials. See
   [CI Auth](#ci-auth). Put its client ID in `ci.azure_client_id`.
6. Register the resource providers that the deployment needs in its
   subscription. See
   [Resource provider registration](#resource-provider-registration).
7. If you added a provider or changed a provider version, update
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
the pipeline without a word, and its Azure resources and its state stay. On
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
2. Delete the empty workspace. Log in to the deployment's tenant (see
   [Manual](#manual)) and run these commands in `deployments/`:

   ```bash
   tofu init -backend-config=backends/<deployment>.azurerm.tfbackend -reconfigure
   tofu workspace select default
   tofu workspace delete <deployment>
   ```

   OpenTofu refuses to delete a workspace whose state still holds
   resources. So this step also makes sure that the destroy is complete.
3. In one pull request or merge request, delete these files:
   - `deployments/configs/<deployment>.yaml`
   - `deployments/backends/<deployment>.azurerm.tfbackend`
   - On GitLab, the jobs of the deployment in `.ci/configs/`
4. Delete the CI identity of the deployment, its role assignments and its
   state container. Deleting a managed identity also deletes its federated
   credentials. Its role assignments stay and show as "Identity not found",
   so delete them too.
5. On GitLab, delete the stopped environment in Operate > Environments.

A rename of a config, for example to move it to another tier, is a remove
and an add. The new name is a new workspace with empty state. OpenTofu tries
to make every resource again, and the old resources stay under the old
workspace. Destroy the old deployment first, or move the state by hand.

## Deployment Selection

You must select and activate a deployment config before running plan/apply locally.

On your own machine, OpenTofu uses your Azure CLI login. You run as
yourself, not as the CI identity. A managed identity cannot sign in from
outside Azure. So your user needs the same roles as the CI identity: for
example Contributor on the subscription and Storage Blob Data Contributor on
the state container.

### With Task

`task tf-switch` provides a fuzzy-search picker over all deployment configs.
Select a deployment and it runs `tofu init` and `workspace select`
automatically. It needs [fzf](https://github.com/junegunn/fzf) and OpenTofu.
If one is missing, the task stops and says how to install it. If you press
Esc or pick nothing, the task stops and changes nothing.

> **Note:** Log in with `az login --tenant <tenant-id>` for the tenant of the
> deployment before running `tf-switch`.

```
task tf-switch
```

After selecting the deployment, run `tofu plan` and `tofu apply`
commands as needed.

### Manual

1. Log in to the tenant of the deployment:

   ```bash
   az login --tenant <tenant-id>
   ```

   The provider takes the subscription from `azure.subscription_id` in the
   config, so you do not need to change your default subscription.

2. Run OpenTofu against the workspace of the deployment:

   ```bash
   cd deployments/
   tofu init -backend-config=backends/<env>-<deployment_id>.azurerm.tfbackend -reconfigure
   tofu workspace select -or-create <env>-<deployment_id>
   tofu plan
   ```

If you set `ARM_CLIENT_ID` with `ARM_CLIENT_SECRET` or a client certificate
in your shell, the provider and the backend use that identity instead of your
Azure CLI login.

### Run the CI script locally

You can run `tf.sh` on your own machine. It needs:

- bash 4 or newer. macOS has bash 3.2 as `/bin/bash`. Run `brew install bash`
  (or install bash 4 or newer with your package manager) and make sure that
  the new bash is first on your `PATH`. `tf.sh` stops with an error on an
  older bash.
- mikefarah yq 4.18 or newer.
- [OpenTofu](https://opentofu.org/docs/intro/install/) 1.13 or newer.
- The [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
  logged in with `az login`.

`tf.sh` uses your Azure CLI login:

```bash
az login --tenant <tenant-id>
DEPLOYMENT=<env>-<deployment_id> .ci/scripts/tf.sh plan
```

Before OpenTofu runs, `tf.sh` checks your login with the Azure CLI and jq. It
stops if your login cannot see `azure.subscription_id`, or if that
subscription is in another tenant than `azure.tenant_id`. If your default
subscription is a different one, it prints a note and goes on, because
OpenTofu uses the subscription from the config. It also prints a note that
you run as yourself, not as the CI identity. If the Azure CLI or jq is not
installed, or `PRINT_OIDC_CLAIMS=false` is set, it skips this check. In CI,
`PRINT_OIDC_CLAIMS=false` never skips it.

`tf.sh` also prints a note if `ARM_CLIENT_SECRET` or another credential
variable is set in your shell. If `ARM_CLIENT_ID` is also set, OpenTofu uses
that credential instead of your Azure CLI login.

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
The azurerm backend of Terraform has some settings that OpenTofu does not
have, and the other way around. The backend file of this template uses only
settings that both have.
