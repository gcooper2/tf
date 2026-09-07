#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot '../Invoke-TerraformUpgradeCheck.ps1'),
    [string] $TestDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'terraform-local-module-tests')
)

# Run with pwsh -NoProfile -File ./tests/Test-LocalModules.ps1.
# Fixtures are retained in the printed directory for inspection. No Terraform,
# cloud credentials, downloaded providers, or external PowerShell modules are used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Skipped = 0
$originalDataDirectory = [Environment]::GetEnvironmentVariable('TF_DATA_DIR', 'Process')
$originalLocation = Get-Location
$testRun = Join-Path $TestDirectory ([guid]::NewGuid().ToString('N'))
$testRun = (New-Item -Path $testRun -ItemType Directory -Force).FullName

function Assert-Check {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
    Write-Host "PASS: $Message"
}

function New-TestFolder {
    param([string] $Path)
    return (New-Item -Path $Path -ItemType Directory -Force).FullName
}

function Set-TestFile {
    param([string] $Path, [string] $Text = '# fixture')
    $null = New-TestFolder (Split-Path -Parent $Path)
    Set-Content -LiteralPath $Path -Value $Text -Encoding utf8 -NoNewline
}

function Set-Manifest {
    param([string] $DataDirectory, [object[]] $Modules)
    $manifestPath = Join-Path $DataDirectory 'modules/modules.json'
    Set-TestFile $manifestPath (@{ Modules = @($Modules) } | ConvertTo-Json -Depth 10)
}

function New-ModuleRecord {
    param([string] $Key, [string] $Source, [string] $Dir)
    return [pscustomobject] @{ Key = $Key; Source = $Source; Dir = $Dir }
}

function Test-ContainsDirectory {
    param([string] $Directory)
    return @($script:TerraformSourceDirectories).Contains($Directory)
}

function Assert-RejectedPath {
    param([string] $Path, [string] $Message)
    Assert-Check ([string]::IsNullOrEmpty([string] (Resolve-SafeTerraformPath -FileName $Path))) $Message
}

try {
    # Load function definitions only; never execute the assistant's main workflow.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $ScriptPath).Path, [ref] $tokens, [ref] $parseErrors)
    Assert-Check (@($parseErrors).Count -eq 0) 'Assistant has valid PowerShell syntax'
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false))
    foreach ($function in $functions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    Assert-Check ($null -ne (Get-Command Update-TerraformSourceDirectories -ErrorAction SilentlyContinue)) 'Module discovery function is available'

    [Environment]::SetEnvironmentVariable('TF_DATA_DIR', $null, 'Process')
    $repository = New-TestFolder (Join-Path $testRun 'repository')
    $script:TerraformRoot = New-TestFolder (Join-Path $repository 'root')
    $rootBefore = $script:TerraformRoot
    $moduleA = New-TestFolder (Join-Path $repository 'modules/a')
    $moduleB = New-TestFolder (Join-Path $moduleA 'child')
    $unrelated = New-TestFolder (Join-Path $repository 'modules/unrelated')
    $unusedChild = New-TestFolder (Join-Path $moduleA 'unused')
    $prefixSibling = New-TestFolder (Join-Path $repository 'modules/a-other')
    $rootChild = New-TestFolder (Join-Path $script:TerraformRoot 'unreferenced')
    $defaultData = Join-Path $script:TerraformRoot '.terraform'
    $remote = New-TestFolder (Join-Path $defaultData 'modules/remote')
    $remoteChild = New-TestFolder (Join-Path $remote 'child')
    foreach ($directory in @($script:TerraformRoot, $moduleA, $moduleB, $unrelated, $unusedChild, $prefixSibling, $rootChild, $remote, $remoteChild)) {
        Set-TestFile (Join-Path $directory 'main.tf')
    }
    Set-TestFile (Join-Path $moduleA 'extra.tf.json') '{}'
    Set-TestFile (Join-Path $moduleA 'values.tfvars') 'example = true'
    Set-TestFile (Join-Path $moduleA 'README.md') 'fixture'
    Set-TestFile (Join-Path $moduleA '.git/ignored.tf')
    Set-TestFile (Join-Path $moduleA 'terraform-upgrade-results/ignored.tf')

    # Deliberately put children before parents and include duplicate module paths.
    $records = @(
        (New-ModuleRecord 'a.child' './child' '../modules/a/child'),
        (New-ModuleRecord 'remote.child' './child' '.terraform/modules/remote/child'),
        (New-ModuleRecord '' '' '.'),
        (New-ModuleRecord 'a' '../modules/a' '../modules/a'),
        (New-ModuleRecord 'a_again' '../modules/a' '../modules/a'),
        (New-ModuleRecord 'remote' 'example/remote/cloud' '.terraform/modules/remote'),
        (New-ModuleRecord 'mismatched' '../modules/a' '../modules/unrelated'),
        (New-ModuleRecord 'orphan.child' '../modules/unrelated' '../modules/unrelated')
    )
    Set-Manifest $defaultData $records
    $caller = New-TestFolder (Join-Path $testRun 'unrelated-caller')
    Set-Location -LiteralPath $caller
    Update-TerraformSourceDirectories
    Assert-Check ($script:TerraformRoot -eq $rootBefore) 'Module discovery preserves Terraform working root'
    Assert-Check (@($script:TerraformSourceDirectories).Count -eq 3) 'Only root and the two referenced local module directories are selected'
    Assert-Check (Test-ContainsDirectory $moduleA) 'Sibling local module outside root is selected'
    Assert-Check (Test-ContainsDirectory $moduleB) 'Nested local module is selected even when the manifest is unordered'
    Assert-Check (-not (Test-ContainsDirectory $remoteChild)) 'Local child of a downloaded module remains excluded'
    Assert-Check (-not (Test-ContainsDirectory $unrelated)) 'Mismatched and orphaned manifest entries are excluded'

    $files = @(Get-TerraformFiles)
    Assert-Check ($files.Count -eq 4) 'Scan includes only direct Terraform files from selected module directories'
    Assert-Check (@($files | Where-Object FullName -eq (Join-Path $moduleA 'extra.tf.json')).Count -eq 1) 'JSON Terraform files are scanned'
    Assert-Check ((Resolve-SafeTerraformPath -FileName '../modules/a/main.tf') -eq (Join-Path $moduleA 'main.tf')) 'Diagnostic-relative path resolves from Terraform root despite a different current directory'
    Assert-RejectedPath (Join-Path $unrelated 'main.tf') 'Unrelated sibling cannot be edited'
    Assert-RejectedPath (Join-Path $unusedChild 'main.tf') 'Unreferenced child of an allowed module cannot be edited'
    Assert-RejectedPath (Join-Path $rootChild 'main.tf') 'Unreferenced child of root cannot be edited'
    Assert-RejectedPath '../modules/a/../a-other/main.tf' 'Traversal and similarly prefixed sibling cannot extend edit scope'
    Assert-RejectedPath (Join-Path $remote 'main.tf') 'Downloaded module cannot be edited'
    Assert-RejectedPath (Join-Path $moduleA 'extra.tf.json') 'JSON Terraform is not automatically edited'
    Assert-RejectedPath (Join-Path $moduleA 'values.tfvars') 'Variable files are not automatically edited'
    Assert-RejectedPath (Join-Path $moduleA '.git/ignored.tf') 'Git directory is excluded'
    Assert-RejectedPath (Join-Path $moduleA 'terraform-upgrade-results/ignored.tf') 'Generated results directory is excluded'

    # Demonstrate an actual rename in a module outside Root with a real catalog rule.
    $rulesFile = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $ScriptPath).Path) 'upgrade-rules.json'
    $catalog = Get-Content -LiteralPath $rulesFile -Raw | ConvertFrom-Json -Depth 50
    $script:BoundaryRules = @($catalog.rules | Where-Object id -eq 'azurerm-2-3-storage-allow-public-rename')
    Assert-Check ($script:BoundaryRules.Count -eq 1) 'Expected audited rename is present in the catalog'
    $before = "resource `"azurerm_storage_account`" `"example`" {`r`n  allow_blob_public_access = false`r`n}`r`n"
    $moduleFile = Join-Path $moduleA 'main.tf'
    Set-TestFile $moduleFile $before
    $diagnostic = [pscustomobject] @{
        Severity = 'error'; Summary = 'Unsupported argument'
        Detail = 'An argument named "allow_blob_public_access" is not expected here.'
        FileName = '../modules/a/main.tf'; Line = 2; Column = 3
        EndLine = 2; EndColumn = 3 + 'allow_blob_public_access'.Length
        ContextText = 'resource "azurerm_storage_account" "example"'
    }
    $editCount = Invoke-SafeArgumentRenames -Diagnostics @($diagnostic, $diagnostic)
    $after = Get-Content -LiteralPath $moduleFile -Raw
    Assert-Check ($editCount -eq 1) 'Duplicate diagnostics produce a single edit in the local module'
    Assert-Check ($after -ceq $before.Replace('allow_blob_public_access', 'allow_nested_items_to_be_public')) 'Module edit changes only the reported argument and preserves value and line endings'

    # Bare dot and dot-dot are valid local module sources too.
    Set-Manifest $defaultData @(
        (New-ModuleRecord '' '' '.'),
        (New-ModuleRecord 'a' '../modules/a/child' '../modules/a/child'),
        (New-ModuleRecord 'a.parent' '..' '../modules/a'),
        (New-ModuleRecord 'a.same' '.' '../modules/a/child')
    )
    Update-TerraformSourceDirectories
    Assert-Check (@($script:TerraformSourceDirectories).Count -eq 3 -and (Test-ContainsDirectory $moduleA)) 'Dot and dot-dot sources resolve correctly and duplicate directories collapse'

    foreach ($mode in @('relative', 'absolute')) {
        $customData = if ($mode -eq 'relative') {
            Join-Path $script:TerraformRoot 'custom-data'
        }
        else {
            Join-Path $testRun 'external-data'
        }
        $customRemote = New-TestFolder (Join-Path $customData 'modules/remote')
        $customRemoteChild = New-TestFolder (Join-Path $customRemote 'child')
        $detachedRemote = New-TestFolder (Join-Path $testRun "detached-remote-$mode")
        $detachedRemoteChild = New-TestFolder (Join-Path $detachedRemote 'child')
        Set-TestFile (Join-Path $customRemoteChild 'main.tf')
        Set-TestFile (Join-Path $detachedRemoteChild 'main.tf')
        Set-Manifest $customData @(
            (New-ModuleRecord '' '' '.'),
            (New-ModuleRecord 'a' '../modules/a' '../modules/a'),
            (New-ModuleRecord 'remote' 'example/remote/cloud' $customRemote),
            (New-ModuleRecord 'remote.child' './child' $customRemoteChild),
            (New-ModuleRecord 'detached' 'example/detached/cloud' $detachedRemote),
            (New-ModuleRecord 'detached.child' './child' $detachedRemoteChild)
        )
        $environmentValue = if ($mode -eq 'relative') { 'custom-data' } else { $customData }
        [Environment]::SetEnvironmentVariable('TF_DATA_DIR', $environmentValue, 'Process')
        Update-TerraformSourceDirectories
        Assert-Check (@($script:TerraformSourceDirectories).Count -eq 2 -and (Test-ContainsDirectory $moduleA)) "$mode TF_DATA_DIR selects its own manifest independently of caller directory"
        Assert-RejectedPath (Join-Path $customRemoteChild 'main.tf') "$mode TF_DATA_DIR does not expose a downloaded module's local child for edits"
        Assert-RejectedPath (Join-Path $detachedRemoteChild 'main.tf') "$mode TF_DATA_DIR rejects remote ancestry even outside the cache directory"
    }

    # Missing or malformed metadata must never preserve a previous broad allow-list.
    $missingData = Join-Path $testRun 'missing-data'
    [Environment]::SetEnvironmentVariable('TF_DATA_DIR', $missingData, 'Process')
    Update-TerraformSourceDirectories -WarningVariable missingWarnings
    Assert-Check (@($script:TerraformSourceDirectories).Count -eq 1 -and (Test-ContainsDirectory $script:TerraformRoot)) 'Missing manifest resets selected directories to root only'
    Assert-Check (@($missingWarnings).Count -gt 0) 'Missing manifest is explained with a warning'
    Set-TestFile (Join-Path $missingData 'modules/modules.json') '{ broken json'
    Update-TerraformSourceDirectories -WarningVariable brokenWarnings
    Assert-Check (@($script:TerraformSourceDirectories).Count -eq 1) 'Malformed manifest leaves root usable'
    Assert-Check (@($brokenWarnings).Count -gt 0) 'Malformed manifest is explained with a warning'
    Set-Manifest $missingData @(
        (New-ModuleRecord '' '' '.'),
        (New-ModuleRecord 'a' '../modules/a' '../modules/a')
    )
    Update-TerraformSourceDirectories
    Assert-Check (Test-ContainsDirectory $moduleA) 'Discovery refresh picks up a manifest created after initialization'
    Set-Manifest $missingData @((New-ModuleRecord '' '' '.'))
    Update-TerraformSourceDirectories -WarningVariable rootOnlyWarnings
    Assert-Check (@($script:TerraformSourceDirectories).Count -eq 1 -and @($rootOnlyWarnings).Count -eq 0) 'Valid root-only module manifest is accepted without a spurious warning'

    # Test directory links if this machine permits their creation. They are retained.
    $link = Join-Path $repository 'linked-module'
    $directoryLinkCreated = $false
    try {
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $link -Target $moduleA
        $directoryLinkCreated = $true
    }
    catch {
        $script:Skipped++
        Write-Host "SKIP: directory link creation is unavailable: $($_.Exception.Message)"
    }
    if ($directoryLinkCreated) {
        Set-Manifest $missingData @(
            (New-ModuleRecord '' '' '.'),
            (New-ModuleRecord 'linked' '../linked-module' '../linked-module'),
            (New-ModuleRecord 'linked.child' './child' '../linked-module/child')
        )
        Update-TerraformSourceDirectories
        Assert-Check (@($script:TerraformSourceDirectories).Count -eq 1) 'Directory links and descendants through a linked ancestor are excluded from discovery'
        # Defense-in-depth: even an accidentally admitted path cannot authorize writes.
        $script:TerraformSourceDirectories = @($script:TerraformRoot, $link, (Join-Path $link 'child'))
        Assert-RejectedPath (Join-Path $link 'main.tf') 'Directory junction or symlink cannot authorize an edit'
        Assert-RejectedPath (Join-Path $link 'child/main.tf') 'Link in an ancestor directory cannot authorize an edit'
    }

    $fileLink = Join-Path $script:TerraformRoot 'linked.tf'
    $fileLinkCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $fileLink -Target $moduleFile
        $fileLinkCreated = $true
    }
    catch {
        $script:Skipped++
        Write-Host "SKIP: file symlink creation is unavailable: $($_.Exception.Message)"
    }
    if ($fileLinkCreated) {
        $script:TerraformSourceDirectories = @($script:TerraformRoot, $moduleA)
        Assert-RejectedPath $fileLink 'File symlink cannot authorize an edit'
    }

    Write-Host "Completed: $($script:Checks) checks passed; $($script:Skipped) checks skipped."
    Write-Host "Fixtures: $testRun"
}
finally {
    [Environment]::SetEnvironmentVariable('TF_DATA_DIR', $originalDataDirectory, 'Process')
    Set-Location -LiteralPath $originalLocation.Path
}
