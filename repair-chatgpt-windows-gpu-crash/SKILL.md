---
name: repair-chatgpt-windows-gpu-crash
description: Diagnose and repair the Microsoft Store ChatGPT app on Windows when it flash-crashes after opening the built-in browser, shows "Check the Store for more info about ChatGPT", reports OpenAI.Codex as Modified or NeedsRemediation, or logs Code Integrity event 3033 for ChatGPT.exe and vk_swiftshader.dll. Use for English or Chinese requests mentioning ChatGPT desktop 閃退, 檢查 Store, GPU process crashes, SwiftShader, or recurring repair/reinstall failures. Require an exact diagnostic match before applying the reversible Store repair and targeted launcher.
---

# Repair ChatGPT Windows GPU Crash

Diagnose the exact `ChatGPT.exe` + `vk_swiftshader.dll` Code Integrity
failure before changing state. Repair only the matched failure and preserve
the user's Skills, memories, configuration, and shortcuts.

## Workflow

1. Run the read-only diagnosis:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Diagnose -LookbackHours 24
   ```

2. Read the JSON result.
   - Continue only when `MatchedSignature` and `RepairEligible` are `true`.
   - If they are false, ask the user to reproduce the crash once and rerun
     diagnosis immediately. Do not infer this cause from the Store message
     alone.
   - Treat Chrome's own event 3033 entries as unrelated unless the event
     message explicitly names `ChatGPT.exe` or `OpenAI.Codex_`.

3. Explain the proposed changes and obtain explicit approval:
   - Create a hash-verified backup under
     `%USERPROFILE%\ChatGPT-repair-backup`.
   - Run `winget repair` only when the package is unhealthy.
   - Compile a local launcher that activates the Store app with
     `--allow-third-party-modules`.
   - Create `ChatGPT GPU Safe.lnk`. Replace `ChatGPT.lnk` only when the user
     explicitly requests it.
   - Open ChatGPT once for startup verification unless the user requests
     `-SkipLaunch`.

4. Preview without changing state:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Repair -DryRun
   ```

5. Apply after approval:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Repair -ConfirmRepair
   ```

   Add `-ReplaceDesktopShortcut` only after approval to replace the desktop
   `ChatGPT.lnk`. The original shortcut is backed up first.

6. Verify:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Verify
   ```

   Require all of:
   - `PackageStatus` is `Ok`.
   - At least one GPU child process exists.
   - The GPU command line contains `--allow-third-party-modules`.
   - No new matching ChatGPT Code Integrity 3033 event exists.

7. Let the user decide whether to test the built-in browser. Do not trigger
   it automatically. A startup pass does not prove the browser acceptance
   test.

## Rollback

Preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Rollback -DryRun
```

Apply after approval:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\Repair-ChatGPTWindowsGpuCrash.ps1" -Mode Rollback -ConfirmRollback
```

Rollback restores or removes only the generated shortcut and launcher files.
It preserves the backup and does not reset or uninstall ChatGPT.

## Boundaries

- Do not run `Reset-AppxPackage`, `Remove-AppxPackage`, or a full reinstall.
- Do not edit files under `WindowsApps`.
- Do not point a shortcut directly at the protected `ChatGPT.exe`.
- Do not disable the entire GPU sandbox or change system-wide Exploit
  Protection.
- Do not apply `codex-browser-use-fix`; it repairs Browser Plugin state, not
  this GPU/Code Integrity failure.
- Stop after three repeated failures in the same phase. Report the JSON error,
  winget log path, and unchanged end state instead of retrying blindly.

## Output contract

The PowerShell entry script emits JSON and uses these exit codes:

- `0`: operation or verification succeeded.
- `1`: operational failure with `ErrorCode` and `Message`.
- `2`: exact crash signature not matched.
- `3`: explicit approval flag missing.
- `4`: repair applied but postcondition verification failed.

Read [references/failure-signature.md](references/failure-signature.md) when
explaining the root cause, checking source provenance, or distinguishing this
failure from other ChatGPT crashes.
