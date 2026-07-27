#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Repair', 'Verify', 'Rollback')]
    [string] $Mode = 'Diagnose',

    [ValidateRange(1, 168)]
    [int] $LookbackHours = 24,

    [ValidateNotNullOrEmpty()]
    [string] $PackageName = 'OpenAI.Codex',

    [ValidateNotNullOrEmpty()]
    [string] $StoreId = '9PLM9XGG6VKS',

    [ValidateNotNullOrEmpty()]
    [string] $LauncherRoot = (
        Join-Path $env:LOCALAPPDATA 'ChatGPT-GPU-Fix'
    ),

    [ValidateNotNullOrEmpty()]
    [string] $BackupRoot = (
        Join-Path $env:USERPROFILE 'ChatGPT-repair-backup'
    ),

    [switch] $ConfirmRepair,
    [switch] $ReplaceDesktopShortcut,
    [switch] $ConfirmRollback,
    [switch] $SkipLaunch,
    [switch] $DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$corePath = Join-Path $PSScriptRoot 'ChatGPTCrashFix.Core.psm1'
$launcherSourcePath = Join-Path $PSScriptRoot 'ChatGPTSafeLauncher.cs'
Import-Module $corePath -Force

function Complete-Result {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [int] $ExitCode = 0
    )

    $Result | ConvertTo-Json -Depth 8
    exit $ExitCode
}

function Get-InstalledChatGPTPackage {
    $package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $package) {
        throw "PackageNotFound: $PackageName is not installed for the current user."
    }

    $package
}

function Get-CodeIntegrityQuery {
    param(
        [Parameter(Mandatory = $true)]
        [datetime] $Since
    )

    try {
        $events = @(
            Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-CodeIntegrity/Operational'
                Id        = 3033
                StartTime = $Since
            } -ErrorAction Stop
        )

        [pscustomobject]@{
            Events = $events
            Error  = $null
        }
    }
    catch {
        $message = $_.Exception.Message
        if (
            $_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or
            $message -match '(?i)No events were found'
        ) {
            [pscustomobject]@{
                Events = @()
                Error  = $null
            }
        }
        else {
            [pscustomobject]@{
                Events = @()
                Error  = $message
            }
        }
    }
}

function Get-Diagnosis {
    param(
        [datetime] $Since = (Get-Date).AddHours(-$LookbackHours)
    )

    $package = Get-InstalledChatGPTPackage
    $eventQuery = Get-CodeIntegrityQuery -Since $Since
    $classification = Get-ChatGPTCrashClassification `
        -PackageStatus ([string]$package.Status) `
        -Events @($eventQuery.Events)

    [pscustomobject]@{
        Mode                  = 'Diagnose'
        CheckedAt             = (Get-Date).ToString('o')
        LookbackStart         = $Since.ToString('o')
        PackageName           = $package.Name
        PackageFullName       = $package.PackageFullName
        PackageFamilyName     = $package.PackageFamilyName
        PackageVersion        = [string]$package.Version
        PackageStatus         = [string]$package.Status
        InstallLocation       = $package.InstallLocation
        EventQueryError       = $eventQuery.Error
        MatchedSignature      = $classification.MatchedSignature
        MatchingEventCount    = $classification.MatchingEventCount
        NeedsPackageRepair    = $classification.NeedsPackageRepair
        RepairEligible        = $classification.RepairEligible
        Reason                = $classification.Reason
        MatchingEvents        = @(
            $classification.MatchingEvents |
                Select-Object TimeCreated, Id, Message
        )
    }
}

function Get-WingetPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')
    )

    $installer = Get-AppxPackage -Name Microsoft.DesktopAppInstaller `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $installer) {
        $candidates += Join-Path $installer.InstallLocation 'winget.exe'
    }

    $path = $candidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $path) {
        throw 'WingetUnavailable: Microsoft App Installer is required for Store repair.'
    }

    $path
}

function Copy-DirectoryVerified {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force |
        Copy-Item -Destination $Destination -Recurse -Force

    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
    $mismatches = New-Object System.Collections.Generic.List[string]

    foreach ($sourceFile in $sourceFiles) {
        $relative = $sourceFile.FullName.Substring($Source.Length).
            TrimStart('\')
        $destinationFile = Join-Path $Destination $relative

        if (-not (Test-Path -LiteralPath $destinationFile)) {
            $mismatches.Add("Missing:$relative")
            continue
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName `
            -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationFile `
            -Algorithm SHA256).Hash

        if ($sourceHash -ne $destinationHash) {
            $mismatches.Add("HashMismatch:$relative")
        }
    }

    [pscustomobject]@{
        Source        = $Source
        Destination   = $Destination
        FilesVerified = $sourceFiles.Count
        Mismatches    = @($mismatches)
    }
}

function Copy-FileVerified {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $destinationHash = (
        Get-FileHash -LiteralPath $Destination -Algorithm SHA256
    ).Hash

    [pscustomobject]@{
        Source        = $Source
        Destination   = $Destination
        FilesVerified = 1
        Mismatches    = @(
            if ($sourceHash -ne $destinationHash) {
                'HashMismatch'
            }
        )
    }
}

function New-CriticalBackup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

    $results = New-Object System.Collections.Generic.List[object]
    $items = @(
        [pscustomobject]@{
            Source      = Join-Path $env:USERPROFILE '.codex\skills'
            Destination = Join-Path $backupDirectory 'codex\skills'
        },
        [pscustomobject]@{
            Source      = Join-Path $env:USERPROFILE '.codex\memories'
            Destination = Join-Path $backupDirectory 'codex\memories'
        },
        [pscustomobject]@{
            Source      = Join-Path $env:USERPROFILE '.codex\config.toml'
            Destination = Join-Path $backupDirectory 'codex\config.toml'
        },
        [pscustomobject]@{
            Source      = Join-Path $env:USERPROFILE '.agents\skills'
            Destination = Join-Path $backupDirectory 'agents\skills'
        }
    )

    foreach ($item in $items) {
        if (-not (Test-Path -LiteralPath $item.Source)) {
            continue
        }

        if ((Get-Item -LiteralPath $item.Source).PSIsContainer) {
            $results.Add((
                Copy-DirectoryVerified `
                    -Source $item.Source `
                    -Destination $item.Destination
            ))
        }
        else {
            $results.Add((
                Copy-FileVerified `
                    -Source $item.Source `
                    -Destination $item.Destination
            ))
        }
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutBackupDirectory = Join-Path $backupDirectory 'shortcuts'
    foreach ($shortcut in @(
        Get-ChildItem -LiteralPath $desktop -Filter 'ChatGPT*.lnk' `
            -File -Force -ErrorAction SilentlyContinue
    )) {
        $results.Add((
            Copy-FileVerified `
                -Source $shortcut.FullName `
                -Destination (
                    Join-Path $shortcutBackupDirectory $shortcut.Name
                )
        ))
    }

    $mismatches = @(
        foreach ($result in $results) {
            foreach ($mismatch in @($result.Mismatches)) {
                [pscustomobject]@{
                    Source = $result.Source
                    Issue  = $mismatch
                }
            }
        }
    )

    $summary = [pscustomobject]@{
        CreatedAt       = (Get-Date).ToString('o')
        BackupDirectory = $backupDirectory
        FilesVerified   = (
            ($results | Measure-Object -Property FilesVerified -Sum).Sum
        )
        MismatchCount   = $mismatches.Count
        Mismatches      = $mismatches
        Items           = @($results)
    }

    $summary | ConvertTo-Json -Depth 7 |
        Set-Content -LiteralPath (
            Join-Path $backupDirectory 'backup-manifest.json'
        ) -Encoding UTF8

    if ($mismatches.Count -gt 0) {
        throw "BackupVerificationFailed: $($mismatches.Count) mismatches."
    }

    $summary
}

function Invoke-StoreRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LogDirectory
    )

    $winget = Get-WingetPath
    $stdout = Join-Path $LogDirectory 'winget-repair.stdout.log'
    $stderr = Join-Path $LogDirectory 'winget-repair.stderr.log'
    $arguments = @(
        'repair',
        '--id', $StoreId,
        '--source', 'msstore',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity',
        '--force',
        '--verbose-logs'
    )

    $process = Start-Process `
        -FilePath $winget `
        -ArgumentList $arguments `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr

    if (-not $process.WaitForExit(180000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'WingetRepairTimeout: Store repair exceeded 180 seconds.'
    }

    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        throw "WingetRepairFailed: exit code $($process.ExitCode). Logs: $stdout"
    }

    [pscustomobject]@{
        ExitCode  = $process.ExitCode
        StdoutLog = $stdout
        StderrLog = $stderr
    }
}

function Get-CSharpCompiler {
    $windowsRoot = Split-Path -Parent ([Environment]::SystemDirectory)
    $candidates = @(
        "$windowsRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$windowsRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    $compiler = $candidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $compiler) {
        throw 'CSharpCompilerUnavailable: .NET Framework csc.exe was not found.'
    }

    $compiler
}

function Install-SafeLauncher {
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter(Mandatory = $true)] [string] $BackupDirectory
    )

    New-Item -ItemType Directory -Path $LauncherRoot -Force | Out-Null

    $launcherSource = Join-Path $LauncherRoot 'ChatGPTSafeLauncher.cs'
    $launcherExe = Join-Path $LauncherRoot 'ChatGPT-SafeLauncher.exe'
    Copy-Item -LiteralPath $launcherSourcePath `
        -Destination $launcherSource -Force

    $compiler = Get-CSharpCompiler
    $compileOutput = @(
        & $compiler /nologo /target:winexe /platform:anycpu /optimize+ `
            /reference:System.Windows.Forms.dll `
            "/out:$launcherExe" `
            $launcherSource 2>&1
    )

    if (
        $LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $launcherExe)
    ) {
        throw "LauncherCompileFailed: $($compileOutput -join [Environment]::NewLine)"
    }

    $aumid = Get-ChatGPTAumid `
        -PackageFamilyName $Package.PackageFamilyName `
        -ApplicationId 'App'

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutName = if ($ReplaceDesktopShortcut) {
        'ChatGPT.lnk'
    }
    else {
        'ChatGPT GPU Safe.lnk'
    }
    $shortcutPath = Join-Path $desktop $shortcutName
    $shortcutExisted = Test-Path -LiteralPath $shortcutPath
    $shortcutBackup = $null

    if ($shortcutExisted) {
        $shortcutBackupDirectory = Join-Path $BackupDirectory 'shortcuts'
        New-Item -ItemType Directory -Path $shortcutBackupDirectory `
            -Force | Out-Null
        $shortcutBackup = Join-Path $shortcutBackupDirectory $shortcutName
        Copy-Item -LiteralPath $shortcutPath `
            -Destination $shortcutBackup -Force
    }

    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcherExe
    $shortcut.Arguments = '"{0}"' -f $aumid
    $shortcut.WorkingDirectory = $LauncherRoot
    $shortcut.Description = 'ChatGPT GPU safe launcher'

    $chatGptExe = Join-Path $Package.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $chatGptExe) {
        $shortcut.IconLocation = "$chatGptExe,0"
    }
    $shortcut.Save()

    [pscustomobject]@{
        Aumid                    = $aumid
        LauncherExe              = $launcherExe
        LauncherSource           = $launcherSource
        ShortcutPath             = $shortcutPath
        ShortcutExistedBeforeFix = $shortcutExisted
        ShortcutBackup           = $shortcutBackup
        ReplacedDesktopShortcut  = [bool]$ReplaceDesktopShortcut
        BackupDirectory          = $BackupDirectory
        InstalledAt              = (Get-Date).ToString('o')
    }
}

function Get-Verification {
    param(
        [Parameter(Mandatory = $true)]
        [datetime] $Since
    )

    $package = Get-InstalledChatGPTPackage
    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" `
            -ErrorAction SilentlyContinue
    )
    $gpuProcesses = @(
        $processes |
            Where-Object { $_.CommandLine -match '--type=gpu-process' }
    )
    $gpuWithFix = @(
        $gpuProcesses |
            Where-Object {
                $_.CommandLine -match '--allow-third-party-modules'
            }
    )

    $eventQuery = Get-CodeIntegrityQuery -Since $Since
    $classification = Get-ChatGPTCrashClassification `
        -PackageStatus ([string]$package.Status) `
        -Events @($eventQuery.Events)

    $passed = (
        [string]$package.Status -eq 'Ok' -and
        $processes.Count -gt 0 -and
        $gpuWithFix.Count -gt 0 -and
        -not $classification.MatchedSignature -and
        -not $eventQuery.Error
    )

    [pscustomobject]@{
        Mode                         = 'Verify'
        CheckedAt                    = (Get-Date).ToString('o')
        Since                        = $Since.ToString('o')
        Passed                       = $passed
        PackageStatus                = [string]$package.Status
        ChatGPTProcessCount           = $processes.Count
        GpuProcessCount               = $gpuProcesses.Count
        GpuProcessesWithFixFlag       = $gpuWithFix.Count
        NewMatchingCodeIntegrity3033  = $classification.MatchingEventCount
        EventQueryError               = $eventQuery.Error
        GpuCommandLines               = @(
            $gpuProcesses |
                Select-Object ProcessId, ParentProcessId, CommandLine
        )
    }
}

function Save-LauncherState {
    param(
        [Parameter(Mandatory = $true)] $State
    )

    $State | ConvertTo-Json -Depth 7 |
        Set-Content -LiteralPath (
            Join-Path $LauncherRoot 'state.json'
        ) -Encoding UTF8
}

function Get-LauncherState {
    $statePath = Join-Path $LauncherRoot 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "StateNotFound: $statePath"
    }

    Get-Content -LiteralPath $statePath -Raw |
        ConvertFrom-Json
}

function Invoke-Rollback {
    if (-not $ConfirmRollback -and -not $DryRun) {
        throw 'ApprovalRequired: pass -ConfirmRollback after explicit user approval.'
    }

    $state = Get-LauncherState
    $actions = New-Object System.Collections.Generic.List[string]

    if ($DryRun) {
        return [pscustomobject]@{
            Mode    = 'Rollback'
            DryRun  = $true
            Actions = @(
                "Restore or remove shortcut: $($state.ShortcutPath)",
                "Remove generated launcher files from: $LauncherRoot"
            )
        }
    }

    if (
        [bool]$state.ShortcutExistedBeforeFix -and
        $state.ShortcutBackup -and
        (Test-Path -LiteralPath $state.ShortcutBackup)
    ) {
        Copy-Item -LiteralPath $state.ShortcutBackup `
            -Destination $state.ShortcutPath -Force
        $actions.Add("Restored:$($state.ShortcutPath)")
    }
    elseif (Test-Path -LiteralPath $state.ShortcutPath) {
        Remove-Item -LiteralPath $state.ShortcutPath -Force
        $actions.Add("Removed:$($state.ShortcutPath)")
    }

    foreach ($fileName in @(
        'ChatGPT-SafeLauncher.exe',
        'ChatGPTSafeLauncher.cs',
        'state.json'
    )) {
        $path = Join-Path $LauncherRoot $fileName
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $actions.Add("Removed:$path")
        }
    }

    if (
        (Test-Path -LiteralPath $LauncherRoot) -and
        -not (Get-ChildItem -LiteralPath $LauncherRoot -Force |
            Select-Object -First 1)
    ) {
        Remove-Item -LiteralPath $LauncherRoot -Force
        $actions.Add("RemovedEmptyDirectory:$LauncherRoot")
    }

    [pscustomobject]@{
        Mode            = 'Rollback'
        RolledBack      = $true
        Actions         = @($actions)
        BackupPreserved = $state.BackupDirectory
    }
}

try {
    switch ($Mode) {
        'Diagnose' {
            Complete-Result -Result (Get-Diagnosis)
        }

        'Verify' {
            $since = (Get-Date).AddMinutes(-10)
            $statePath = Join-Path $LauncherRoot 'state.json'
            if (Test-Path -LiteralPath $statePath) {
                $state = Get-LauncherState
                if ($state.PSObject.Properties['LastLaunchTime']) {
                    $since = [datetime]$state.LastLaunchTime
                }
            }

            $verification = Get-Verification -Since $since
            $code = if ($verification.Passed) { 0 } else { 4 }
            Complete-Result -Result $verification -ExitCode $code
        }

        'Rollback' {
            $rollback = Invoke-Rollback
            Complete-Result -Result $rollback
        }

        'Repair' {
            $diagnosis = Get-Diagnosis

            if (-not $diagnosis.MatchedSignature) {
                Complete-Result -ExitCode 2 -Result ([pscustomobject]@{
                    Mode       = 'Repair'
                    Applied    = $false
                    ErrorCode  = 'SignatureNotMatched'
                    Message    = 'The targeted Code Integrity 3033 + vk_swiftshader signature was not found.'
                    Diagnosis  = $diagnosis
                })
            }

            if (-not $ConfirmRepair -and -not $DryRun) {
                Complete-Result -ExitCode 3 -Result ([pscustomobject]@{
                    Mode      = 'Repair'
                    Applied   = $false
                    ErrorCode = 'ApprovalRequired'
                    Message   = 'Pass -ConfirmRepair only after explicit user approval.'
                    Diagnosis = $diagnosis
                })
            }

            if ($DryRun) {
                Complete-Result -Result ([pscustomobject]@{
                    Mode      = 'Repair'
                    DryRun    = $true
                    Applied   = $false
                    Diagnosis = $diagnosis
                    PlannedActions = @(
                        'Hash-verified backup of Skills, memories, config, and ChatGPT shortcuts',
                        $(if ($diagnosis.NeedsPackageRepair) {
                            'Run winget Store repair'
                        } else {
                            'Skip Store repair because package status is Ok'
                        }),
                        'Compile the external IApplicationActivationManager launcher',
                        $(if ($ReplaceDesktopShortcut) {
                            'Back up and replace Desktop\ChatGPT.lnk'
                        } else {
                            'Create Desktop\ChatGPT GPU Safe.lnk'
                        }),
                        $(if ($SkipLaunch) {
                            'Skip launch verification'
                        } else {
                            'Cold-launch ChatGPT and verify the GPU child flag and Code Integrity events'
                        })
                    )
                })
            }

            $backup = New-CriticalBackup
            Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
                Stop-Process -Force
            Start-Sleep -Seconds 2

            $storeRepair = $null
            if ($diagnosis.NeedsPackageRepair) {
                $storeRepair = Invoke-StoreRepair `
                    -LogDirectory $backup.BackupDirectory

                $postRepairPackage = Get-InstalledChatGPTPackage
                if ([string]$postRepairPackage.Status -ne 'Ok') {
                    throw "PackageStillUnhealthy: $($postRepairPackage.Status)"
                }
            }

            $package = Get-InstalledChatGPTPackage
            $launcher = Install-SafeLauncher `
                -Package $package `
                -BackupDirectory $backup.BackupDirectory

            $lastLaunchTime = $null
            $verification = $null
            if (-not $SkipLaunch) {
                $lastLaunchTime = Get-Date
                Start-Process `
                    -FilePath $launcher.LauncherExe `
                    -ArgumentList ('"{0}"' -f $launcher.Aumid) `
                    -WindowStyle Hidden
                Start-Sleep -Seconds 10
                $verification = Get-Verification -Since $lastLaunchTime
            }

            $state = [pscustomobject]@{
                Aumid                    = $launcher.Aumid
                LauncherExe              = $launcher.LauncherExe
                LauncherSource           = $launcher.LauncherSource
                ShortcutPath             = $launcher.ShortcutPath
                ShortcutExistedBeforeFix = $launcher.ShortcutExistedBeforeFix
                ShortcutBackup           = $launcher.ShortcutBackup
                ReplacedDesktopShortcut  = $launcher.ReplacedDesktopShortcut
                BackupDirectory          = $backup.BackupDirectory
                InstalledAt              = $launcher.InstalledAt
                LastLaunchTime           = if ($lastLaunchTime) {
                    $lastLaunchTime.ToString('o')
                } else {
                    $null
                }
            }
            Save-LauncherState -State $state

            $passed = if ($SkipLaunch) {
                $true
            }
            else {
                [bool]$verification.Passed
            }

            $result = [pscustomobject]@{
                Mode           = 'Repair'
                Applied        = $true
                Passed         = $passed
                Diagnosis      = $diagnosis
                Backup         = $backup
                StoreRepair    = $storeRepair
                Launcher       = $state
                Verification   = $verification
            }
            $exitCode = if ($passed) { 0 } else { 4 }
            Complete-Result -Result $result -ExitCode $exitCode
        }
    }
}
catch {
    Complete-Result -ExitCode 1 -Result ([pscustomobject]@{
        Mode      = $Mode
        Applied   = $false
        ErrorCode = 'OperationFailed'
        Message   = $_.Exception.Message
        Type      = $_.Exception.GetType().FullName
    })
}
