# ChatGPT Windows GPU 閃退修復工具

一個單一、可攜式的 Codex Skill，用來診斷並修復 Microsoft Store
ChatGPT Windows 桌面版在開啟內建瀏覽器後閃退，接著顯示
「檢查 Store 以尋找有關此 ChatGPT 的詳細資訊」的特定問題。

此 Skill 只會在 Windows 事件紀錄精確符合
`ChatGPT.exe` + `vk_swiftshader.dll` + Code Integrity 事件 `3033`
時執行修復，並提供備份、Dry Run、驗證及復原流程。

> A single portable Codex Skill for diagnosing and repairing the specific
> ChatGPT Windows GPU/SwiftShader Code Integrity 3033 crash, with backup,
> dry-run, verification, and rollback.

## 適用範圍

目標問題通常包含以下現象：

- ChatGPT Windows 桌面版可啟動，但開啟內建瀏覽器後閃退。
- 再次啟動時顯示「檢查 Store 以尋找有關此 ChatGPT 的詳細資訊」。
- `OpenAI.Codex` 套件狀態可能是 `Modified` 或
  `NeedsRemediation`。
- Code Integrity Operational log 的事件 `3033` 同時包含：
  - `ChatGPT.exe` 或 `OpenAI.Codex_...\app\ChatGPT.exe`
  - `vk_swiftshader.dll`

Store 訊息本身不是修復條件；若沒有上述精確事件，Skill 會停止而不套用
此修復。

## Skill 會做什麼

1. 以唯讀方式檢查 ChatGPT 套件狀態與 Code Integrity 事件。
2. 先將 Skills、memories、Codex 設定與 ChatGPT 捷徑做 SHA-256
   驗證備份。
3. 僅在套件狀態異常時執行 Microsoft Store `winget repair`。
4. 在本機編譯一個小型 `IApplicationActivationManager` 啟動器，以
   `--allow-third-party-modules` 啟動 Store App。
5. 預設建立獨立的 `ChatGPT GPU Safe.lnk`，不覆蓋原捷徑。
6. 驗證套件狀態、GPU 子程序啟動參數，以及是否產生新的相符事件。
7. 提供只移除本 Skill 產生之啟動器與捷徑的復原流程。

它不會重設或解除安裝 ChatGPT、不會修改 `WindowsApps` 內的檔案，也不會
變更系統全域 Exploit Protection。

## 安裝

### 交給 Codex 安裝

將以下要求交給 Codex：

```text
Install the Skill from:
https://github.com/Fuika0306/ChatGPT-Windows-GPU-Crash-Fix/tree/main/repair-chatgpt-windows-gpu-crash
```

### 手動安裝

```powershell
git clone https://github.com/Fuika0306/ChatGPT-Windows-GPU-Crash-Fix.git

$source = Join-Path $PWD `
    'ChatGPT-Windows-GPU-Crash-Fix\repair-chatgpt-windows-gpu-crash'
$destination = Join-Path $env:USERPROFILE `
    '.codex\skills\repair-chatgpt-windows-gpu-crash'

New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') `
    -Destination $destination -Recurse -Force
```

安裝後重新開啟 Codex，讓它重新載入 Skills。

## 使用方式

直接對 Codex 說：

```text
Use $repair-chatgpt-windows-gpu-crash to diagnose my ChatGPT Windows Store crash.
```

或手動執行腳本。以下假設 Skill 安裝在預設位置：

```powershell
$script = Join-Path $env:USERPROFILE `
    '.codex\skills\repair-chatgpt-windows-gpu-crash\scripts\Repair-ChatGPTWindowsGpuCrash.ps1'
```

### 1. 唯讀診斷

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Diagnose -LookbackHours 24
```

只有輸出中的 `MatchedSignature` 與 `RepairEligible` 都是 `true` 時，
才符合此修復的適用範圍。

### 2. 預覽變更

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Repair -DryRun
```

### 3. 套用修復

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Repair -ConfirmRepair
```

預設會另外建立 `ChatGPT GPU Safe.lnk`。只有明確需要取代桌面原捷徑時，
才加入：

```powershell
-ReplaceDesktopShortcut
```

### 4. 驗證

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Verify
```

完整通過條件：

- `PackageStatus` 為 `Ok`
- ChatGPT 與 GPU 子程序存在
- GPU 子程序包含 `--allow-third-party-modules`
- 沒有新的相符 ChatGPT Code Integrity 3033 事件

Skill 不會自動開啟內建瀏覽器；是否進行瀏覽器驗收由使用者決定。

## 復原

先預覽：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Rollback -DryRun
```

確認後套用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $script -Mode Rollback -ConfirmRollback
```

復原只會還原或移除 Skill 所建立的捷徑與啟動器，備份會保留。

## 輸出與 Exit Code

PowerShell 入口腳本輸出 JSON：

| Exit code | 意義 |
| --- | --- |
| `0` | 操作或驗證成功 |
| `1` | 操作失敗，JSON 內含 `ErrorCode` 與 `Message` |
| `2` | 未找到精確的崩潰特徵 |
| `3` | 缺少明確的修復或復原確認參數 |
| `4` | 已套用修復，但後置驗證未通過 |

## 隱私與資料範圍

此儲存庫只包含 Skill 指令、PowerShell/C# 原始碼、參考資料與測試：

- 不包含使用者名稱、電子郵件、Token、密碼或私人金鑰。
- 不包含 ChatGPT 對話、帳號資料、日誌、備份或編譯後的執行檔。
- 執行時產生的備份與狀態檔只保存在目前 Windows 使用者的本機目錄。

## 專案結構

```text
repair-chatgpt-windows-gpu-crash/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   └── failure-signature.md
└── scripts/
    ├── ChatGPTCrashFix.Core.psm1
    ├── ChatGPTSafeLauncher.cs
    ├── Repair-ChatGPTWindowsGpuCrash.ps1
    └── tests/
        └── Test-ChatGPTCrashFix.ps1
```

## 測試

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\repair-chatgpt-windows-gpu-crash\scripts\tests\Test-ChatGPTCrashFix.ps1
```

測試涵蓋精確事件分類、修復閘門、AUMID、文件同步、PowerShell
語法解析與 C# 啟動器編譯。

## 技術依據

完整故障特徵、誤判排除與 Chromium／Microsoft 來源連結請見
[failure-signature.md](repair-chatgpt-windows-gpu-crash/references/failure-signature.md)。

## License

[MIT](LICENSE)
