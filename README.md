# Terraform Upgrade Assistant

A small PowerShell 7 helper for working through Terraform AzureRM and AzureAD
provider upgrades one major-version boundary at a time.

It repeatedly runs `terraform validate -json`, groups the diagnostics, and uses
the included HashiCorp-based rule catalog to suggest what to review or replace.
You make and review every source change yourself. The assistant does not edit
Terraform files and never runs `terraform apply` or `terraform destroy`.

## What is included

The tool has two runtime files:

- `Invoke-TerraformUpgradeCheck.ps1` — the PowerShell 7 command.
- `upgrade-rules.json` — curated upgrade guidance for the supported AzureRM and
  AzureAD major-version boundaries.

No external PowerShell modules are required.

The catalog contains 291 suggestion rules sourced from these immutable
HashiCorp provider guides:

- [AzureRM 3.0 upgrade guide](https://github.com/hashicorp/terraform-provider-azurerm/blob/v3.0.0/website/docs/guides/3.0-upgrade-guide.html.markdown)
- [AzureRM 4.0 upgrade guide](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.0.0/website/docs/guides/4.0-upgrade-guide.html.markdown)
- [AzureRM 5.0 upgrade guide](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.0.0/website/docs/guides/5.0-upgrade-guide.html.markdown)
- [AzureAD 3.0 upgrade guide](https://github.com/hashicorp/terraform-provider-azuread/blob/v3.0.0/docs/guides/3.0-upgrade-guide.md)

It includes every resource and data source explicitly listed as removed in the
AzureRM 4.0 and 5.0 guides, plus documented schema, default, behavior, and
replacement changes across all four supported boundaries. It remains a review
aid; read the linked guide for the boundary you are upgrading.

## Requirements

- PowerShell 7 (`pwsh`).
- Terraform CLI available on `PATH`.
- A Terraform root module to check.
- Network access when Terraform needs to download providers or modules.
- Azure credentials and backend access only if you choose to run a real plan.

Use a clean version-control branch and a non-production environment. Back up
state before a major provider upgrade.

## Download v1.0.0

Run this one PowerShell 7 command on the target machine to download and extract
the v1.0.0 release into the current directory:

```powershell
$release = 'v1.0.0'; $asset = "terraform-upgrade-assistant-$release.zip"; $archive = Join-Path ([IO.Path]::GetTempPath()) $asset; Invoke-WebRequest "https://raw.githubusercontent.com/gcooper2/tf/main/$asset" -OutFile $archive; Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $PWD 'terraform-upgrade-assistant-v1.0.0') -Force
```

Repository: <https://github.com/gcooper2/tf>

## Basic workflow

The command handles one Terraform root and one provider boundary per run.

1. Change only the selected provider's version constraint to the target version.
2. Run the matching command below with `-RunInitUpgrade`.
3. Read the grouped errors and suggestions.
4. Edit the Terraform files yourself.
5. Return to the terminal and press **Enter** to validate again.
6. Repeat until validation passes. Enter `Q` to stop safely.
7. Optionally run plan-only Terraform tests and a real speculative plan.
8. Review and commit the Terraform changes and `.terraform.lock.hcl` before
   starting the next boundary.

The loop waits for Enter before rerunning. It does not repeatedly run against
unchanged files, and it stops safely if interactive input is unavailable.

Set these example paths once before using the commands:

```powershell
$tool = 'C:\Tools\terraform-upgrade-assistant-v1.0.0\Invoke-TerraformUpgradeCheck.ps1'
$root = 'C:\Terraform\MyModule'
```

### 1. AzureAD 2.53.1 to 3.9.0

Set the AzureAD constraint to:

```hcl
version = "= 3.9.0"
```

Run:

```powershell
& $tool -Root $root -Provider azuread -FromMajor 2 -ToMajor 3 -RunInitUpgrade
```

### 2. AzureRM 2.99.0 to 3.117.1

Set the AzureRM constraint to:

```hcl
version = "= 3.117.1"
```

Run:

```powershell
& $tool -Root $root -Provider azurerm -FromMajor 2 -ToMajor 3 -RunInitUpgrade
```

### 3. AzureRM 3.117.1 to 4.81.0

Set the AzureRM constraint to:

```hcl
version = "= 4.81.0"
```

Run:

```powershell
& $tool -Root $root -Provider azurerm -FromMajor 3 -ToMajor 4 -RunInitUpgrade
```

### 4. AzureRM 4.81.0 to 5.2.0

Set the AzureRM constraint to:

```hcl
version = "= 5.2.0"
```

Run:

```powershell
& $tool -Root $root -Provider azurerm -FromMajor 4 -ToMajor 5 -RunInitUpgrade
```

Do not combine boundaries. Finish validation and plan review for one boundary
before changing the next provider version.

## Optional checks

### Plan-only Terraform tests

Add `-RunTests` to run Terraform test files after validation succeeds:

```powershell
& $tool -Root $root -Provider azurerm -FromMajor 3 -ToMajor 4 -RunTests
```

For safety, every `run` block in every discovered `.tftest.hcl` file must
explicitly contain:

```hcl
command = plan
```

Terraform defaults a test `run` block to apply when `command` is omitted. The
assistant therefore refuses to run tests if a run block omits `command = plan`
or selects apply. Terraform test does not accept `-var-file`; put test inputs in
the `.tftest.hcl` `variables` blocks or supply them with `TF_VAR_*` environment
variables.

### Real speculative plan

Add `-RunPlan` only when the root is configured for the intended backend,
workspace, credentials, and environment:

```powershell
& $tool -Root $root -Provider azurerm -FromMajor 3 -ToMajor 4 -RunPlan
```

This runs `terraform plan`, which can read remote state and Azure APIs but does
not apply the proposed changes. Review the entire plan, especially replacements
and deletions.

Pass multiple variable files in the order Terraform should read them:

```powershell
& $tool `
    -Root $root `
    -Provider azurerm `
    -FromMajor 3 `
    -ToMajor 4 `
    -RunPlan `
    -VarFiles @('variables\global.tfvars', 'variables\deployment.tfvars')
```

The order is preserved; when the same variable appears more than once, the
later file takes precedence. `-VarFiles` is used only for the optional real
plan, not for `terraform test`.

You can request both safe test modes after validation:

```powershell
& $tool `
    -Root $root `
    -Provider azurerm `
    -FromMajor 3 `
    -ToMajor 4 `
    -RunTests `
    -RunPlan `
    -VarFiles @('variables\global.tfvars', 'variables\deployment.tfvars')
```

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-Root` | Terraform root module directory. Required. |
| `-Provider` | Selected provider: `azurerm` or `azuread`. Required. |
| `-FromMajor` | Starting major version for this one boundary. Required. |
| `-ToMajor` | Target major version for this one boundary. Required. |
| `-RulesPath` | Alternate rule catalog path. Defaults to `upgrade-rules.json` beside the script. |
| `-RunInitUpgrade` | Runs `terraform init -upgrade` before the validation loop. |
| `-RunTests` | Runs only Terraform tests proven to contain explicit plan-only run blocks. |
| `-RunPlan` | Runs a real speculative `terraform plan` after validation succeeds. |
| `-VarFiles` | An ordered array of variable-file paths for `-RunPlan`. |

## Safety and limitations

- The assistant never writes `.tf`, `.tfvars`, state, or plan files and never
  invokes `terraform apply` or `terraform destroy`.
- `terraform init -upgrade` can update `.terraform.lock.hcl` and `.terraform/`.
  It can also select newer versions of other providers when their constraints
  allow it. Review the lock-file diff.
- Suggestions are guidance, not automatic fixes. A renamed field may also need
  a different value type, resource ID, state migration, or design decision.
- Validation checks syntax and provider schemas. It cannot prove that a change
  is operationally safe or detect every changed default and runtime behavior.
- Plan-only tests and speculative plans can contact providers and read remote
  systems. They do not create, update, or delete infrastructure through this
  assistant.
- The assistant ignores `TF_CLI_ARGS` and the matching
  `TF_CLI_ARGS_<subcommand>` value for each Terraform command it starts. This
  prevents environment defaults from changing the checked test directory,
  saving a plan, or selecting destroy mode. Pass supported options through the
  script parameters instead.
- Run the workflow separately for every Terraform root module.

## License

MIT. See [LICENSE](LICENSE).

