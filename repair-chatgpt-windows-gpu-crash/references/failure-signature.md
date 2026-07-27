# Failure signature and source evidence

## Exact match

Apply the targeted repair only when Windows Code Integrity event `3033`
contains both:

- `ChatGPT.exe` or an `OpenAI.Codex_...\app\ChatGPT.exe` path.
- `vk_swiftshader.dll`.

The Store-facing symptom is commonly:

`Check the Store for more info about ChatGPT`

The package may report:

`Modified, NeedsRemediation`

The app log may also show a GPU child crash followed by `launch-failed`.
Those symptoms alone are not the authorization gate because other failures
can produce them.

## Why the launcher is targeted

Chromium's Windows sandbox normally adds
`MITIGATION_FORCE_MS_SIGNED_BINS`. Chromium documents
`--allow-third-party-modules` as disabling the `BINARY_SIGNATURE`
mitigation, and the Windows sandbox source skips the signed-binaries
mitigation when that switch is present. The GPU initialization source also
documents the SwiftShader preload required before that mitigation is active.

The launcher uses Windows `IApplicationActivationManager` so it can activate
the packaged Store app by AUMID while passing the Chromium switch. A direct
shortcut to an executable under `WindowsApps` is not equivalent and can fail
with a Windows path or permission error.

## False positives

- Google Chrome can emit its own event 3033 for its own
  `vk_swiftshader.dll`. Do not classify that as a ChatGPT event.
- The Code Integrity log can roll over when another Chromium app produces
  frequent events. If the exact ChatGPT event is absent, reproduce once and
  diagnose immediately.
- A generic Store remediation message without the exact event can come from
  package corruption, licensing, permissions, or another crash path.

## Change scope

The repair:

1. Backs up Skills, memories, configuration, and ChatGPT shortcuts with
   SHA-256 verification.
2. Uses `winget repair` only if the Store package is unhealthy.
3. Creates a user-local launcher and shortcut.
4. Leaves ChatGPT user data, package files, `.codex`, and `.agents` unchanged.

The Chromium switch relaxes the child-process binary-signature mitigation for
this ChatGPT launch. It does not disable the complete GPU sandbox and does not
change a system-wide mitigation.

## Primary sources

Checked 2026-07-27:

- Chromium sandbox switch:
  https://chromium.googlesource.com/chromium/src/+/64dc570e00d7bed0381134d8b474d0c2acd5a180/sandbox/policy/switches.cc
- Chromium Windows sandbox policy:
  https://chromium.googlesource.com/chromium/src/+/04d774d3827c8532b1b7d3966629f9193a35dd0e/sandbox/policy/win/sandbox_win.cc
- Chromium GPU SwiftShader preload:
  https://chromium.googlesource.com/chromium/src/+/refs/heads/main/gpu/ipc/service/gpu_init.cc
- Microsoft `IApplicationActivationManager::ActivateApplication`:
  https://learn.microsoft.com/windows/win32/api/shobjidl_core/nf-shobjidl_core-iapplicationactivationmanager-activateapplication
- Microsoft winget repair:
  https://learn.microsoft.com/windows/package-manager/winget/repair
- Microsoft MSIX package integrity remediation:
  https://learn.microsoft.com/windows/msix/desktop/tamper-protection
- Microsoft `PackageStatus.NeedsRemediation`:
  https://learn.microsoft.com/uwp/api/windows.applicationmodel.packagestatus.needsremediation
