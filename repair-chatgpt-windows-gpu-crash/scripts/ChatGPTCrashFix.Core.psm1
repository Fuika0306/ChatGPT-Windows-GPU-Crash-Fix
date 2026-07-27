Set-StrictMode -Version 2.0

function Get-ChatGPTCrashClassification {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $PackageStatus,

        [AllowNull()]
        [object[]] $Events
    )

    $matchingEvents = @(
        foreach ($eventRecord in @($Events)) {
            if ($null -eq $eventRecord) {
                continue
            }

            $eventId = 0
            if ($null -ne $eventRecord.PSObject.Properties['Id']) {
                $eventId = [int]$eventRecord.Id
            }

            $message = ''
            if ($null -ne $eventRecord.PSObject.Properties['Message']) {
                $message = [string]$eventRecord.Message
            }

            if (
                $eventId -eq 3033 -and
                $message -match '(?i)(ChatGPT\.exe|OpenAI\.Codex_)' -and
                $message -match '(?i)vk_swiftshader\.dll'
            ) {
                $eventRecord
            }
        }
    )

    $statusText = [string]$PackageStatus
    $needsPackageRepair = (
        $statusText -match '(?i)NeedsRemediation|Modified|Tampered'
    )
    $matchedSignature = $matchingEvents.Count -gt 0

    $reason = if ($matchedSignature) {
        'MatchedCodeIntegrity3033VkSwiftShader'
    }
    else {
        'SignatureNotMatched'
    }

    [pscustomobject]@{
        MatchedSignature  = $matchedSignature
        RepairEligible    = $matchedSignature
        NeedsPackageRepair = $needsPackageRepair
        PackageStatus     = $statusText
        MatchingEventCount = $matchingEvents.Count
        Reason            = $reason
        MatchingEvents    = $matchingEvents
    }
}

function Get-ChatGPTAumid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageFamilyName,

        [ValidateNotNullOrEmpty()]
        [string] $ApplicationId = 'App'
    )

    '{0}!{1}' -f $PackageFamilyName, $ApplicationId
}

Export-ModuleMember -Function @(
    'Get-ChatGPTCrashClassification',
    'Get-ChatGPTAumid'
)
