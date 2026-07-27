$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected [$Expected], got [$Actual]."
    }
}

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Split-Path -Parent $scriptsRoot
$corePath = Join-Path $scriptsRoot 'ChatGPTCrashFix.Core.psm1'
$entryPath = Join-Path $scriptsRoot 'Repair-ChatGPTWindowsGpuCrash.ps1'
$launcherSourcePath = Join-Path $scriptsRoot 'ChatGPTSafeLauncher.cs'
$skillPath = Join-Path $skillRoot 'SKILL.md'

if (-not (Test-Path -LiteralPath $corePath)) {
    throw "Core module is missing: $corePath"
}

Import-Module $corePath -Force

$matchingEvent = [pscustomobject]@{
    Id      = 3033
    Message = 'Code Integrity determined that ChatGPT.exe attempted to load C:\Package\app\vk_swiftshader.dll that did not meet the Microsoft signing level requirements.'
}

$matchingHealthy = Get-ChatGPTCrashClassification `
    -PackageStatus 'Ok' `
    -Events @($matchingEvent)

Assert-Equal $matchingHealthy.MatchedSignature $true `
    'A ChatGPT vk_swiftshader Code Integrity 3033 event must match'
Assert-Equal $matchingHealthy.NeedsPackageRepair $false `
    'An Ok package must not request Store repair'
Assert-Equal $matchingHealthy.RepairEligible $true `
    'A matched signature must be eligible for the targeted launcher repair'

$matchingUnhealthy = Get-ChatGPTCrashClassification `
    -PackageStatus 'Modified, NeedsRemediation' `
    -Events @($matchingEvent)

Assert-Equal $matchingUnhealthy.MatchedSignature $true `
    'The crash signature must remain matched when the package is unhealthy'
Assert-Equal $matchingUnhealthy.NeedsPackageRepair $true `
    'NeedsRemediation must request Store repair'

$unrelatedEvent = [pscustomobject]@{
    Id      = 3033
    Message = 'Code Integrity determined that OtherApp.exe attempted to load unrelated.dll.'
}

$unrelated = Get-ChatGPTCrashClassification `
    -PackageStatus 'Modified, NeedsRemediation' `
    -Events @($unrelatedEvent)

Assert-Equal $unrelated.MatchedSignature $false `
    'An unrelated Code Integrity event must not authorize this repair'
Assert-Equal $unrelated.RepairEligible $false `
    'An unrelated event must stop the targeted repair'

$wrongEventId = [pscustomobject]@{
    Id      = 1000
    Message = $matchingEvent.Message
}

$wrongId = Get-ChatGPTCrashClassification `
    -PackageStatus 'Modified, NeedsRemediation' `
    -Events @($wrongEventId)

Assert-Equal $wrongId.MatchedSignature $false `
    'The DLL text without Code Integrity event 3033 must not match'

$aumid = Get-ChatGPTAumid `
    -PackageFamilyName 'OpenAI.Codex_2p2nqsd0c76g0' `
    -ApplicationId 'App'

Assert-Equal $aumid 'OpenAI.Codex_2p2nqsd0c76g0!App' `
    'The AUMID must be derived from the installed package family'

foreach ($path in @($entryPath, $launcherSourcePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required implementation file is missing: $path"
    }
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $entryPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "PowerShell entry script has parse errors: $($parseErrors -join '; ')"
}

$entryText = Get-Content -LiteralPath $entryPath -Raw
if ($entryText -notmatch '\[switch\]\s*\$DryRun') {
    throw 'The entry script must expose a dedicated -DryRun switch.'
}
if ($entryText -match 'SupportsShouldProcess') {
    throw 'The entry script must not use global -WhatIf because Appx auto-import contaminates JSON output.'
}

$skillText = Get-Content -LiteralPath $skillPath -Raw
if ($skillText -match '-Confirm:\$false') {
    throw 'SKILL.md must not document -Confirm for a script without SupportsShouldProcess.'
}
if ($skillText -notmatch '-Mode Repair -DryRun') {
    throw 'SKILL.md must document the dedicated Repair -DryRun command.'
}

$windowsRoot = Split-Path -Parent ([Environment]::SystemDirectory)
$cscCandidates = @(
    "$windowsRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$windowsRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if (-not $csc) {
    throw 'The .NET Framework C# compiler was not found.'
}

$testOutput = Join-Path $env:TEMP (
    'ChatGPTSafeLauncher-test-{0}.exe' -f [guid]::NewGuid().ToString('N')
)

try {
    & $csc /nologo /target:winexe /platform:anycpu /optimize+ `
        /reference:System.Windows.Forms.dll `
        "/out:$testOutput" `
        $launcherSourcePath

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $testOutput)) {
        throw 'ChatGPTSafeLauncher.cs did not compile successfully.'
    }
}
finally {
    if (Test-Path -LiteralPath $testOutput) {
        Remove-Item -LiteralPath $testOutput -Force
    }
}

[pscustomobject]@{
    Passed = $true
    Tests  = 16
    Scope  = 'classification, gating, AUMID, docs sync, PowerShell parse, launcher compile'
}
