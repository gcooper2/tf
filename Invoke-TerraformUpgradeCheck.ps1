#requires -Version 7.0

<#
.SYNOPSIS
Guides a Terraform provider major-version upgrade and can apply explicitly approved argument renames.

.DESCRIPTION
Runs Terraform initialization when requested, reports relevant HashiCorp upgrade-guide
rules, loops over terraform validate -json, and optionally applies safe argument-name
fixes before validating again. It can also run plan-only Terraform tests and terraform
plan. The script never runs terraform apply or destroy.

.EXAMPLE
./Invoke-TerraformUpgradeCheck.ps1 `
    -Root C:\Terraform\MyRoot `
    -Provider azurerm `
    -FromMajor 2 `
    -ToMajor 3 `
    -RunInitUpgrade `
    -ApplySafeFixes

.EXAMPLE
./Invoke-TerraformUpgradeCheck.ps1 `
    -Root C:\Terraform\MyRoot `
    -Provider azurerm `
    -FromMajor 4 `
    -ToMajor 5 `
    -RunInitUpgrade `
    -RunTests `
    -RunPlan `
    -VarFiles @('global.tfvars', 'deployment.tfvars')
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [ValidateSet('azurerm', 'azuread')]
    [string] $Provider,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int] $FromMajor,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int] $ToMajor,

    [string] $RulesPath = (Join-Path $PSScriptRoot 'upgrade-rules.json'),
    [string[]] $VarFiles = @(),
    [switch] $RunInitUpgrade,
    [switch] $ApplySafeFixes,
    [ValidateRange(1, 100)]
    [int] $MaxAutoFixPasses = 20,
    [switch] $RunTests,
    [switch] $RunPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-InputPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $BasePath
    )

    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $BasePath $Path
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "File does not exist: $candidate"
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

function Invoke-TerraformCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $ShowOutput
    )

    $displayArguments = $Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }
    Write-Host ("terraform {0}" -f ($displayArguments -join ' ')) -ForegroundColor DarkGray

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:TerraformExecutable
    $startInfo.WorkingDirectory = $script:TerraformRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($environmentName in @('TF_CLI_ARGS', "TF_CLI_ARGS_$($Arguments[0])")) {
        if ($startInfo.Environment.ContainsKey($environmentName)) {
            if ($script:WarnedTerraformCliArgs.Add($environmentName)) {
                Write-Warning "Ignoring $environmentName so environment defaults cannot change this command's safety options."
            }
            $null = $startInfo.Environment.Remove($environmentName)
        }
    }
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()

    $lines = @(if ([string]::IsNullOrEmpty($stdout)) {
        @()
    }
    else {
        @($stdout.TrimEnd("`r", "`n") -split '\r?\n')
    })
    $errorLines = @(if ([string]::IsNullOrEmpty($stderr)) {
        @()
    }
    else {
        @($stderr.TrimEnd("`r", "`n") -split '\r?\n')
    })

    if ($ShowOutput -and $lines.Count -gt 0) {
        $lines | ForEach-Object { Write-Host $_ }
    }
    if ($errorLines.Count -gt 0) {
        $errorLines | ForEach-Object { Write-Warning $_ }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
        Text     = $stdout
        ErrorText = $stderr
    }
}

function Get-TerraformFiles {
    $excluded = '[\\/](\.terraform|\.git|terraform-upgrade-results)[\\/]'
    return @(Get-ChildItem -LiteralPath $script:TerraformRoot -File -Recurse |
        Where-Object {
            ($_.Name -like '*.tf' -or $_.Name -like '*.tf.json') -and
            $_.FullName -notmatch $excluded
        })
}

function Get-SourceLine {
    param(
        [AllowNull()] [string] $FileName,
        [int] $LineNumber
    )

    if ([string]::IsNullOrWhiteSpace($FileName) -or $LineNumber -lt 1) {
        return ''
    }

    $path = if ([IO.Path]::IsPathRooted($FileName)) {
        $FileName
    }
    else {
        Join-Path $script:TerraformRoot $FileName
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }

    $lines = @(Get-Content -LiteralPath $path)
    if ($LineNumber -gt $lines.Count) {
        return ''
    }

    return [string] $lines[$LineNumber - 1]
}

function Get-DiagnosticBlockContext {
    param([AllowNull()] [string] $ContextText)

    if (-not [string]::IsNullOrWhiteSpace($ContextText) -and
        $ContextText -match '(?i)\b(resource|data|provider)\s+"([^"]+)"') {
        $kind = if ($Matches[1] -eq 'data') { 'data_source' } else { $Matches[1].ToLowerInvariant() }
        return [pscustomobject]@{
            Kind = $kind
            Type = $Matches[2]
        }
    }

    return $null
}

function Test-RuleTarget {
    param(
        [Parameter(Mandatory)] [object] $Rule,
        [AllowNull()] [object] $Context
    )

    $target = Get-OptionalProperty -InputObject $Rule -Name 'target'
    if ($null -eq $target) {
        return $true
    }

    $targetKind = [string] (Get-OptionalProperty -InputObject $target -Name 'kind')
    $targetType = [string] (Get-OptionalProperty -InputObject $target -Name 'type')

    if ($targetKind -in @('global', 'environment')) {
        return $true
    }

    if ($null -eq $Context) {
        return $false
    }

    return ($Context.Kind -eq $targetKind -and $Context.Type -eq $targetType)
}

function Test-RuleMatchesDiagnostic {
    param(
        [Parameter(Mandatory)] [object] $Rule,
        [Parameter(Mandatory)] [object] $Diagnostic
    )

    $category = [string] (Get-OptionalProperty -InputObject $Rule -Name 'category')
    if ($category -in @('behavior', 'recreate')) {
        return $false
    }

    $context = Get-DiagnosticBlockContext -ContextText $Diagnostic.ContextText
    if (-not (Test-RuleTarget -Rule $Rule -Context $context)) {
        return $false
    }

    $diagnosticText = "$($Diagnostic.Summary) $($Diagnostic.Detail)"
    $sourceLine = Get-SourceLine -FileName $Diagnostic.FileName -LineNumber $Diagnostic.Line
    $match = Get-OptionalProperty -InputObject $Rule -Name 'match'

    if ($null -ne $match) {
        $diagnosticRegex = [string] (Get-OptionalProperty -InputObject $match -Name 'diagnosticRegex')
        $sourceRegex = [string] (Get-OptionalProperty -InputObject $match -Name 'sourceRegex')

        if ($diagnosticRegex -and $diagnosticText -notmatch $diagnosticRegex) {
            return $false
        }
        if ($sourceRegex -and $sourceLine -notmatch $sourceRegex) {
            return $false
        }
        if ($diagnosticRegex -or $sourceRegex) {
            return $true
        }
    }

    $oldValue = [string] (Get-OptionalProperty -InputObject $Rule -Name 'old')
    $newValue = [string] (Get-OptionalProperty -InputObject $Rule -Name 'new')
    $token = if ($oldValue) { ($oldValue -split '\.')[-1] } else { ($newValue -split '\.')[-1] }

    if (-not $token) {
        return $false
    }

    $tokenRegex = '(?i)\b{0}\b' -f [regex]::Escape($token)
    return ($diagnosticText -match $tokenRegex -or $sourceLine -match $tokenRegex)
}

function Get-MatchingRulesForDiagnostic {
    param([Parameter(Mandatory)] [object] $Diagnostic)

    foreach ($rule in $script:BoundaryRules) {
        if (Test-RuleMatchesDiagnostic -Rule $rule -Diagnostic $Diagnostic) {
            $rule
        }
    }
}

function Get-DiagnosticRecords {
    param([Parameter(Mandatory)] [object] $Validation)

    $diagnostics = @(Get-OptionalProperty -InputObject $Validation -Name 'diagnostics')
    foreach ($diagnostic in $diagnostics) {
        $range = Get-OptionalProperty -InputObject $diagnostic -Name 'range'
        $start = Get-OptionalProperty -InputObject $range -Name 'start'
        $end = Get-OptionalProperty -InputObject $range -Name 'end'
        $fileName = [string] (Get-OptionalProperty -InputObject $range -Name 'filename')
        $line = [int] (Get-OptionalProperty -InputObject $start -Name 'line')
        $column = [int] (Get-OptionalProperty -InputObject $start -Name 'column')
        $endLine = [int] (Get-OptionalProperty -InputObject $end -Name 'line')
        $endColumn = [int] (Get-OptionalProperty -InputObject $end -Name 'column')
        $severity = [string] (Get-OptionalProperty -InputObject $diagnostic -Name 'severity')
        $summary = [string] (Get-OptionalProperty -InputObject $diagnostic -Name 'summary')
        $detail = [string] (Get-OptionalProperty -InputObject $diagnostic -Name 'detail')
        $snippet = Get-OptionalProperty -InputObject $diagnostic -Name 'snippet'
        $contextText = [string] (Get-OptionalProperty -InputObject $snippet -Name 'context')

        [pscustomobject]@{
            Severity = $severity
            Summary  = $summary
            Detail   = $detail
            FileName = $fileName
            Line     = $line
            Column   = $column
            EndLine  = $endLine
            EndColumn = $endColumn
            ContextText = $contextText
            GroupKey = "$severity|$summary|$detail"
            Fingerprint = "$severity|$summary|$detail|$fileName|$line|$column"
        }
    }
}

function Show-ValidationDiagnostics {
    param(
        [Parameter(Mandatory)] [object[]] $Diagnostics,
        [AllowNull()] [System.Collections.Generic.HashSet[string]] $PreviousFingerprints
    )

    $currentFingerprints = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($diagnostic in $Diagnostics) {
        $null = $currentFingerprints.Add($diagnostic.Fingerprint)
    }

    if ($null -ne $PreviousFingerprints) {
        $resolved = @($PreviousFingerprints | Where-Object { -not $currentFingerprints.Contains($_) }).Count
        $new = @($currentFingerprints | Where-Object { -not $PreviousFingerprints.Contains($_) }).Count
        Write-Host "Since the previous pass: $resolved resolved, $new new." -ForegroundColor Cyan
    }

    foreach ($group in @($Diagnostics | Group-Object -Property GroupKey)) {
        $example = $group.Group[0]
        $color = if ($example.Severity -eq 'error') { 'Red' } else { 'Yellow' }
        Write-Host "[$($example.Severity.ToUpper())] $($example.Summary) ($($group.Count) occurrence(s))" -ForegroundColor $color
        if ($example.Detail) {
            Write-Host $example.Detail
        }

        foreach ($diagnostic in $group.Group) {
            $location = if ($diagnostic.FileName) {
                "$($diagnostic.FileName):$($diagnostic.Line):$($diagnostic.Column)"
            }
            else {
                'No source location supplied'
            }
            Write-Host "  - $location"
            $sourceLine = Get-SourceLine -FileName $diagnostic.FileName -LineNumber $diagnostic.Line
            if ($sourceLine) {
                Write-Host "    $($sourceLine.Trim())" -ForegroundColor DarkGray
            }
        }

        $matchingRules = foreach ($diagnostic in $group.Group) {
            Get-MatchingRulesForDiagnostic -Diagnostic $diagnostic
        }

        if (@($matchingRules).Count -eq 0) {
            Write-Host '  Suggestion: No exact catalog match; review this diagnostic manually.' -ForegroundColor Yellow
        }
        else {
            foreach ($rule in @($matchingRules | Sort-Object id -Unique)) {
                $confidence = [string] (Get-OptionalProperty -InputObject $rule -Name 'confidence')
                $suggestion = [string] (Get-OptionalProperty -InputObject $rule -Name 'suggestion')
                $guideUrl = [string] (Get-OptionalProperty -InputObject $rule -Name 'guideUrl')
                $guideSection = [string] (Get-OptionalProperty -InputObject $rule -Name 'guideSection')
                Write-Host "  Suggested action [$confidence]: $suggestion" -ForegroundColor Green
                Write-Host "  Source: $guideSection - $guideUrl" -ForegroundColor DarkCyan
            }
        }
        Write-Host ''
    }

    return $currentFingerprints
}

function Resolve-SafeTerraformPath {
    param([AllowNull()] [string] $FileName)

    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    $candidate = if ([IO.Path]::IsPathRooted($FileName)) { $FileName } else { Join-Path $script:TerraformRoot $FileName }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $null
    }

    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    $rootPrefix = $script:TerraformRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $resolved.StartsWith($rootPrefix, $comparison) -or
        -not $resolved.EndsWith('.tf', $comparison) -or
        $resolved.EndsWith('.tf.json', $comparison) -or
        $resolved -match '[\\/](\.terraform|\.git|terraform-upgrade-results)[\\/]' -or
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return $null
    }

    return $resolved
}

function Invoke-SafeArgumentRenames {
    param([Parameter(Mandatory)] [object[]] $Diagnostics)

    $changed = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $destinationAlreadyPresent = @{}
    foreach ($diagnostic in $Diagnostics) {
        if ($diagnostic.Severity -ne 'error' -or $diagnostic.Line -lt 1 -or
            $diagnostic.EndLine -ne $diagnostic.Line -or $diagnostic.EndColumn -lt 1) {
            continue
        }

        $automaticRules = @(Get-MatchingRulesForDiagnostic -Diagnostic $diagnostic | Where-Object {
            $fix = Get-OptionalProperty -InputObject $_ -Name 'fix'
            $null -ne $fix -and [string] (Get-OptionalProperty -InputObject $fix -Name 'operation') -eq 'rename_argument'
        })
        if ($automaticRules.Count -ne 1) {
            continue
        }

        $rule = $automaticRules[0]
        $fix = Get-OptionalProperty -InputObject $rule -Name 'fix'
        $from = [string] (Get-OptionalProperty -InputObject $fix -Name 'from')
        $to = [string] (Get-OptionalProperty -InputObject $fix -Name 'to')
        $path = Resolve-SafeTerraformPath -FileName $diagnostic.FileName
        if (-not $path -or -not $seen.Add("$path|$($diagnostic.Line)|$from|$to")) {
            continue
        }

        $originalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $content = Get-Content -LiteralPath $path -Raw
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $originalHash) {
            continue
        }
        $lines = [regex]::Split($content, '(?<=\n)')
        $lineIndex = $diagnostic.Line - 1
        if ($lineIndex -ge $lines.Count) {
            continue
        }

        $pattern = '^(?<indent>[^\S\r\n]*){0}(?<equals>[^\S\r\n]*=)' -f [regex]::Escape($from)
        $lineRegex = [regex]::new($pattern)
        $lineMatch = $lineRegex.Match($lines[$lineIndex])
        $expectedStartColumn = $lineMatch.Groups['indent'].Length + 1
        $expectedEndColumn = $expectedStartColumn + $from.Length
        if (-not $lineMatch.Success -or $diagnostic.Column -ne $expectedStartColumn -or
            $diagnostic.EndColumn -ne $expectedEndColumn) {
            continue
        }

        $destinationKey = "$path|$to"
        if (-not $destinationAlreadyPresent.ContainsKey($destinationKey)) {
            $destinationPattern = '(?m)^[^\S\r\n]*{0}[^\S\r\n]*=' -f [regex]::Escape($to)
            $destinationAlreadyPresent[$destinationKey] = ($content -match $destinationPattern)
        }
        if ($destinationAlreadyPresent[$destinationKey]) {
            continue
        }

        $lines[$lineIndex] = $lineRegex.Replace($lines[$lineIndex], ('${indent}' + $to + '${equals}'), 1)
        $firstBytes = @(Get-Content -LiteralPath $path -AsByteStream -TotalCount 3)
        $encoding = if ($firstBytes.Count -eq 3 -and $firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF) {
            'utf8BOM'
        }
        else {
            'utf8'
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $originalHash) {
            Write-Warning "Skipping $($diagnostic.FileName) because it changed after validation."
            continue
        }
        Set-Content -LiteralPath $path -Value ($lines -join '') -NoNewline -Encoding $encoding
        Write-Host "  Updated $($diagnostic.FileName):$($diagnostic.Line): $from -> $to" -ForegroundColor Green
        $changed++
    }

    return $changed
}

function Get-UsedTerraformTypes {
    param([Parameter(Mandatory)] [IO.FileInfo[]] $Files)

    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($file.Name -like '*.tf.json') {
            try {
                $jsonConfiguration = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                foreach ($jsonKind in @('resource', 'data', 'provider')) {
                    $container = Get-OptionalProperty -InputObject $jsonConfiguration -Name $jsonKind
                    if ($null -eq $container) {
                        continue
                    }
                    $kind = if ($jsonKind -eq 'data') { 'data_source' } else { $jsonKind }
                    foreach ($property in $container.PSObject.Properties) {
                        $null = $used.Add("$kind`:$($property.Name)")
                    }
                }
            }
            catch {
                Write-Warning "Unable to inspect JSON Terraform file: $($file.FullName)"
            }
            continue
        }

        foreach ($match in [regex]::Matches($text, '(?m)^\s*(resource|data|provider)\s+"([^"]+)"')) {
            $kind = if ($match.Groups[1].Value -eq 'data') { 'data_source' } else { $match.Groups[1].Value }
            $null = $used.Add("$kind`:$($match.Groups[2].Value)")
        }
    }
    return ,$used
}

function Test-RuleRelevantToRoot {
    param(
        [Parameter(Mandatory)] [object] $Rule,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $UsedTypes,
        [Parameter(Mandatory)] [IO.FileInfo[]] $Files
    )

    $target = Get-OptionalProperty -InputObject $Rule -Name 'target'
    $kind = [string] (Get-OptionalProperty -InputObject $target -Name 'kind')
    $type = [string] (Get-OptionalProperty -InputObject $target -Name 'type')

    if ($kind -notin @('global', 'environment') -and -not $UsedTypes.Contains("$kind`:$type")) {
        return $false
    }

    $oldValue = [string] (Get-OptionalProperty -InputObject $Rule -Name 'old')
    $category = [string] (Get-OptionalProperty -InputObject $Rule -Name 'category')
    if (-not $oldValue -or $category -in @('behavior', 'required', 'recreate', 'replace-resource')) {
        return $true
    }

    $token = ($oldValue -split '\.')[-1]
    $pattern = '(?i)\b{0}\b' -f [regex]::Escape($token)
    foreach ($file in $Files) {
        if ((Get-Content -LiteralPath $file.FullName -Raw) -match $pattern) {
            return $true
        }
    }

    return $false
}

function Show-RelevantGuideRules {
    $files = @(Get-TerraformFiles)
    $usedTypes = Get-UsedTerraformTypes -Files $files
    $relevant = foreach ($rule in $script:BoundaryRules) {
        if (Test-RuleRelevantToRoot -Rule $rule -UsedTypes $usedTypes -Files $files) {
            $rule
        }
    }

    Write-Host "Relevant HashiCorp guide checks: $(@($relevant).Count)" -ForegroundColor Cyan
    foreach ($rule in @($relevant | Sort-Object { $_.target.type }, old, id)) {
        $target = Get-OptionalProperty -InputObject $rule -Name 'target'
        $targetKind = [string] (Get-OptionalProperty -InputObject $target -Name 'kind')
        $targetType = [string] (Get-OptionalProperty -InputObject $target -Name 'type')
        $category = [string] (Get-OptionalProperty -InputObject $rule -Name 'category')
        $confidence = [string] (Get-OptionalProperty -InputObject $rule -Name 'confidence')
        $suggestion = [string] (Get-OptionalProperty -InputObject $rule -Name 'suggestion')
        Write-Host "- [$confidence/$category] $targetKind $targetType" -ForegroundColor Yellow
        Write-Host "  $suggestion"
    }
    Write-Host ''
}

function ConvertTo-HclStructuralLines {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines)

    $inBlockComment = $false
    $heredocTerminator = $null
    $heredocAllowsIndent = $false

    foreach ($line in $Lines) {
        if ($null -ne $heredocTerminator) {
            $candidate = if ($heredocAllowsIndent) { $line.TrimStart() } else { $line }
            if ($candidate -eq $heredocTerminator) {
                $heredocTerminator = $null
                $heredocAllowsIndent = $false
            }
            ''
            continue
        }

        $builder = [Text.StringBuilder]::new()
        $inString = $false
        $escaped = $false
        for ($index = 0; $index -lt $line.Length; $index++) {
            $character = $line[$index]
            $nextCharacter = if ($index + 1 -lt $line.Length) { $line[$index + 1] } else { [char] 0 }

            if ($inBlockComment) {
                if ($character -eq '*' -and $nextCharacter -eq '/') {
                    $inBlockComment = $false
                    $index++
                }
                continue
            }

            if ($inString) {
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($character -eq '\') {
                    $escaped = $true
                }
                elseif ($character -eq '"') {
                    $inString = $false
                }
                continue
            }

            if ($character -eq '#') {
                break
            }
            if ($character -eq '/' -and $nextCharacter -eq '/') {
                break
            }
            if ($character -eq '/' -and $nextCharacter -eq '*') {
                $inBlockComment = $true
                $index++
                continue
            }
            if ($character -eq '"') {
                $inString = $true
                $null = $builder.Append('""')
                continue
            }

            $null = $builder.Append($character)
        }

        $structuralLine = $builder.ToString()
        if ($structuralLine -match '<<(-)?\s*([A-Za-z_][A-Za-z0-9_-]*)') {
            $heredocAllowsIndent = ($Matches[1] -eq '-')
            $heredocTerminator = $Matches[2]
        }
        $structuralLine
    }

    if ($inBlockComment -or $null -ne $heredocTerminator) {
        throw 'An unterminated block comment or heredoc prevents safely checking the Terraform test file.'
    }
}

function Assert-HclTestFilePlanOnly {
    param([Parameter(Mandatory)] [IO.FileInfo] $TestFile)

    $lines = @(Get-Content -LiteralPath $TestFile.FullName)
    $structuralLines = @(ConvertTo-HclStructuralLines -Lines $lines)
    $runCount = 0

    for ($lineIndex = 0; $lineIndex -lt $structuralLines.Count; $lineIndex++) {
        $line = [string] $structuralLines[$lineIndex]
        if ($line -notmatch '^\s*run\b') {
            continue
        }
        $runMatch = [regex]::Match($line, '^\s*run\s+""\s*(\{)?\s*$')
        if (-not $runMatch.Success) {
            throw "Unsafe or unsupported run block syntax in $($TestFile.FullName) at line $($lineIndex + 1)."
        }

        $runCount++
        $openingLine = $lineIndex
        if (-not $runMatch.Groups[1].Success) {
            do {
                $openingLine++
            } while ($openingLine -lt $structuralLines.Count -and
                [string]::IsNullOrWhiteSpace([string] $structuralLines[$openingLine]))

            if ($openingLine -ge $structuralLines.Count -or
                [string] $structuralLines[$openingLine] -notmatch '^\s*\{\s*$') {
                throw "Unable to prove that the run block in $($TestFile.FullName) is plan-only."
            }
        }

        $depth = 1
        $commands = [System.Collections.Generic.List[string]]::new()
        for ($blockLine = $openingLine + 1; $blockLine -lt $structuralLines.Count; $blockLine++) {
            $blockText = [string] $structuralLines[$blockLine]
            if ($depth -eq 1 -and $blockText -match '^\s*command\s*=\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$') {
                $commands.Add($Matches[1].ToLowerInvariant())
            }
            elseif ($depth -eq 1 -and $blockText -match '^\s*command\s*=') {
                throw "Unable to prove the command in $($TestFile.FullName) at line $($blockLine + 1) is plan-only."
            }

            $depth += [regex]::Matches($blockText, '\{').Count
            $depth -= [regex]::Matches($blockText, '\}').Count
            if ($depth -lt 0) {
                throw "Unbalanced braces prevent safely checking $($TestFile.FullName)."
            }
            if ($depth -eq 0) {
                $lineIndex = $blockLine
                break
            }
        }

        if ($depth -ne 0 -or $commands.Count -ne 1 -or $commands[0] -ne 'plan') {
            throw "Unsafe test file: $($TestFile.FullName). Every run block must contain exactly one direct 'command = plan' assignment."
        }
    }

    return $runCount
}

function Assert-PlanOnlyTests {
    $searchDirectories = @($script:TerraformRoot)
    $testsDirectory = Join-Path $script:TerraformRoot 'tests'
    if (Test-Path -LiteralPath $testsDirectory -PathType Container) {
        $searchDirectories += $testsDirectory
    }

    $jsonTests = @($searchDirectories | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter '*.tftest.json' -File
    })
    if ($jsonTests.Count -gt 0) {
        throw 'JSON Terraform test files are not run because this tool cannot safely prove that every run is plan-only.'
    }

    $hclTests = @($searchDirectories | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter '*.tftest.hcl' -File
    })
    if ($hclTests.Count -eq 0) {
        return @()
    }

    foreach ($testFile in $hclTests) {
        $null = Assert-HclTestFilePlanOnly -TestFile $testFile
    }

    return $hclTests
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Terraform root does not exist: $Root"
}
if (-not (Test-Path -LiteralPath $RulesPath -PathType Leaf)) {
    throw "Upgrade rules file does not exist: $RulesPath"
}
if ($ToMajor -ne ($FromMajor + 1)) {
    throw 'Upgrade one major-version boundary at a time (for example, 2 to 3).'
}

$script:TerraformRoot = (Resolve-Path -LiteralPath $Root).Path
$terraformCommand = Get-Command terraform -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $terraformCommand) {
    throw 'Terraform was not found. Install Terraform and add it to PATH.'
}
$script:TerraformExecutable = $terraformCommand.Source
if ($IsWindows -and [IO.Path]::GetExtension($script:TerraformExecutable) -ne '.exe') {
    throw "Terraform must resolve to the native terraform.exe on Windows, not $script:TerraformExecutable"
}
$script:WarnedTerraformCliArgs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$configurationFiles = @(Get-TerraformFiles)
if ($configurationFiles.Count -eq 0) {
    throw "No .tf or .tf.json configuration files were found under $script:TerraformRoot"
}

$resolvedVarFiles = @(foreach ($file in $VarFiles) {
    Resolve-InputPath -Path $file -BasePath $script:TerraformRoot
})

try {
    $catalog = Get-Content -LiteralPath $RulesPath -Raw | ConvertFrom-Json -Depth 50 -ErrorAction Stop
}
catch {
    throw "Unable to read upgrade rules JSON: $($_.Exception.Message)"
}

$allRules = @(Get-OptionalProperty -InputObject $catalog -Name 'rules')
$allowedCategories = @('rename', 'remove', 'replace-resource', 'required', 'value-change', 'behavior', 'deprecated', 'recreate')
$allowedConfidence = @('high', 'medium', 'low')
$seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($rule in $allRules) {
    $id = [string] (Get-OptionalProperty -InputObject $rule -Name 'id')
    $category = [string] (Get-OptionalProperty -InputObject $rule -Name 'category')
    $confidence = [string] (Get-OptionalProperty -InputObject $rule -Name 'confidence')
    $guideUrl = [string] (Get-OptionalProperty -InputObject $rule -Name 'guideUrl')
    $suggestion = [string] (Get-OptionalProperty -InputObject $rule -Name 'suggestion')
    $target = Get-OptionalProperty -InputObject $rule -Name 'target'

    if (-not $id -or -not $seenIds.Add($id)) { throw "Missing or duplicate catalog rule id: $id" }
    if ($category -notin $allowedCategories) { throw "Invalid category in catalog rule $id" }
    if ($confidence -notin $allowedConfidence) { throw "Invalid confidence in catalog rule $id" }
    if (-not $suggestion -or $null -eq $target) { throw "Incomplete catalog rule: $id" }
    if ($guideUrl -notmatch '^https://(registry\.terraform\.io/providers/hashicorp/|github\.com/hashicorp/)') {
        throw "Catalog rule $id does not use an official HashiCorp URL."
    }

    $match = Get-OptionalProperty -InputObject $rule -Name 'match'
    foreach ($regexName in @('diagnosticRegex', 'sourceRegex')) {
        $pattern = [string] (Get-OptionalProperty -InputObject $match -Name $regexName)
        if ($pattern) {
            try { $null = [regex]::new($pattern) }
            catch { throw "Invalid $regexName in catalog rule $id" }
        }
    }

    $fix = Get-OptionalProperty -InputObject $rule -Name 'fix'
    if ($null -ne $fix) {
        $operation = [string] (Get-OptionalProperty -InputObject $fix -Name 'operation')
        $from = [string] (Get-OptionalProperty -InputObject $fix -Name 'from')
        $to = [string] (Get-OptionalProperty -InputObject $fix -Name 'to')
        $oldLeaf = ([string] (Get-OptionalProperty -InputObject $rule -Name 'old') -split '\.')[-1]
        $newLeaf = ([string] (Get-OptionalProperty -InputObject $rule -Name 'new') -split '\.')[-1]

        if ($operation -ne 'rename_argument' -or $category -ne 'rename' -or $confidence -ne 'high') {
            throw "Catalog rule $id has an unsafe automatic fix definition."
        }
        if ($from -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$' -or $to -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
            throw "Catalog rule $id has an invalid automatic argument rename."
        }
        if ($from -ne $oldLeaf -or $to -ne $newLeaf -or $from -eq $to) {
            throw "Catalog rule $id automatic fix does not match its documented rename."
        }
    }
}

$script:BoundaryRules = @($allRules | Where-Object {
    $_.provider -eq $Provider -and [int] $_.fromMajor -eq $FromMajor -and [int] $_.toMajor -eq $ToMajor
})
if ($script:BoundaryRules.Count -eq 0) {
    throw "No rules exist for $Provider $FromMajor to $ToMajor."
}

Write-Host "Terraform upgrade check: $Provider $FromMajor -> $ToMajor" -ForegroundColor Cyan
Write-Host "Root: $script:TerraformRoot"
if ($resolvedVarFiles.Count -gt 0) {
    Write-Host 'Variable files, in precedence order:'
    $resolvedVarFiles | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ''

if ($RunInitUpgrade) {
    Write-Warning 'terraform init -upgrade can update .terraform.lock.hcl and module selections.'
    $initArguments = @('init', '-upgrade', '-input=false', '-no-color')
    if (-not $RunPlan) {
        $initArguments += '-backend=false'
        Write-Host 'Validation-only mode: skipping backend initialization.' -ForegroundColor Cyan
    }
    $init = Invoke-TerraformCommand -Arguments $initArguments -ShowOutput
    if ($init.ExitCode -ne 0) {
        throw 'terraform init -upgrade failed.'
    }
}

$versionResult = Invoke-TerraformCommand -Arguments @('version', '-json')
if ($versionResult.ExitCode -ne 0) {
    throw 'Unable to determine the Terraform/provider versions.'
}
try {
    $versionInfo = $versionResult.Text | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw 'terraform version -json returned unreadable output.'
}

$terraformVersionText = [string] (Get-OptionalProperty -InputObject $versionInfo -Name 'terraform_version')
try {
    $terraformVersion = [version] (($terraformVersionText -split '-')[0])
}
catch {
    throw "Terraform reported an unreadable version: $terraformVersionText"
}
if ($RunTests -and $terraformVersion -lt [version] '1.6.0') {
    throw 'Terraform 1.6.0 or newer is required to run Terraform tests.'
}

$providerSelections = Get-OptionalProperty -InputObject $versionInfo -Name 'provider_selections'
$providerAddress = "registry.terraform.io/hashicorp/$Provider"
$providerVersionProperty = if ($null -ne $providerSelections) { $providerSelections.PSObject.Properties[$providerAddress] } else { $null }
if ($null -eq $providerVersionProperty) {
    throw "Terraform did not report a selected $Provider provider. Initialize the root and confirm the provider is required here."
}
else {
    $selectedVersion = [string] $providerVersionProperty.Value
    $selectedMajor = [int] (($selectedVersion -split '[.-]')[0])
    if ($selectedMajor -ne $ToMajor) {
        throw "Selected $Provider version is $selectedVersion; expected major version $ToMajor. Update the version constraint and run with -RunInitUpgrade."
    }
    Write-Host "Selected $Provider provider: $selectedVersion" -ForegroundColor Green
}
Write-Host ''

Show-RelevantGuideRules

$previousFingerprints = $null
$validationPass = 0
$autoFixPass = 0
do {
    $validationPass++
    Write-Host "Validation pass $validationPass" -ForegroundColor Cyan
    $validationResult = Invoke-TerraformCommand -Arguments @('validate', '-json')

    try {
        $validation = $validationResult.Text | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    }
    catch {
        Write-Host $validationResult.Text
        throw "terraform validate did not return valid JSON. Exit code: $($validationResult.ExitCode)"
    }

    $formatVersion = [string] (Get-OptionalProperty -InputObject $validation -Name 'format_version')
    if ($formatVersion -notmatch '^1(?:\.|$)') {
        throw "Unsupported terraform validate JSON format: $formatVersion"
    }

    $isValid = [bool] (Get-OptionalProperty -InputObject $validation -Name 'valid')
    $errorCount = [int] (Get-OptionalProperty -InputObject $validation -Name 'error_count')
    $warningCount = [int] (Get-OptionalProperty -InputObject $validation -Name 'warning_count')
    $diagnostics = @(Get-DiagnosticRecords -Validation $validation)

    if ($diagnostics.Count -gt 0) {
        $previousFingerprints = Show-ValidationDiagnostics -Diagnostics $diagnostics -PreviousFingerprints $previousFingerprints
    }

    if ($isValid -and $validationResult.ExitCode -ne 0) {
        throw "terraform validate reported success JSON but exited with code $($validationResult.ExitCode)."
    }

    if ($isValid) {
        Write-Host "Validation passed with $warningCount warning(s)." -ForegroundColor Green
        break
    }

    Write-Host "Validation failed with $errorCount error(s) and $warningCount warning(s)." -ForegroundColor Red

    if ($ApplySafeFixes -and $autoFixPass -lt $MaxAutoFixPasses) {
        Write-Host 'Checking for catalog-approved argument renames...' -ForegroundColor Cyan
        $changed = Invoke-SafeArgumentRenames -Diagnostics $diagnostics
        if ($changed -gt 0) {
            $autoFixPass++
            Write-Host "Applied $changed edit(s). Running validation again." -ForegroundColor Cyan
            Write-Host ''
            continue
        }
        Write-Host 'No safe automatic edit is available for the remaining errors.' -ForegroundColor Yellow
    }
    elseif ($ApplySafeFixes -and $autoFixPass -ge $MaxAutoFixPasses) {
        Write-Warning "Stopped automatic editing after $MaxAutoFixPasses pass(es)."
    }

    try {
        $answer = Read-Host 'Edit and save the Terraform files, then press Enter to validate again; enter Q to quit'
    }
    catch {
        Write-Host 'Interactive input is unavailable, so the validation loop stopped.' -ForegroundColor Yellow
        exit 1
    }
    if ($null -eq $answer -or $answer.Trim() -match '(?i)^q$') {
        Write-Host 'Stopped by user.' -ForegroundColor Yellow
        exit 1
    }
    Write-Host ''
} while ($true)

if ($RunTests) {
    $testFiles = @(Assert-PlanOnlyTests)
    if ($testFiles.Count -eq 0) {
        Write-Warning 'No .tftest.hcl files were found; Terraform tests were skipped.'
    }
    else {
        Write-Host "Running $($testFiles.Count) plan-only Terraform test file(s)..." -ForegroundColor Cyan
        $testArguments = @('test', '-json')
        $testResult = Invoke-TerraformCommand -Arguments $testArguments -ShowOutput
        if ($testResult.ExitCode -ne 0) {
            throw 'terraform test failed.'
        }
        Write-Host 'Terraform tests passed.' -ForegroundColor Green
    }
}

$finalExitCode = 0
if ($RunPlan) {
    Write-Warning 'Plan output can contain sensitive environment information. It is not saved by this script.'
    $planArguments = @('plan', '-input=false', '-no-color', '-detailed-exitcode')
    foreach ($file in $resolvedVarFiles) {
        $planArguments += "-var-file=$file"
    }
    $planResult = Invoke-TerraformCommand -Arguments $planArguments -ShowOutput
    switch ($planResult.ExitCode) {
        0 { Write-Host 'Terraform plan succeeded with no changes.' -ForegroundColor Green }
        2 {
            Write-Host 'Terraform plan succeeded and contains changes to review.' -ForegroundColor Yellow
            $finalExitCode = 2
        }
        default { throw 'terraform plan failed.' }
    }
}

exit $finalExitCode
