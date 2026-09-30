---
name: codex-windows-update-recovery
description: "Diagnose and recover Windows Codex desktop MSIX updates that repeatedly download, close the window, or remain pending. Inspect the installed and staged OpenAI.Codex packages, complete one authorized staged-package registration from an independent Windows task, and verify the running version."
---

# Codex Windows 更新恢復

處理 Windows Codex 桌面版 `OpenAI.Codex` 套件的更新循環：下載已完成，視窗關閉後仍回到舊版，或更新提示一直出現。本流程在 Windows 上已成功恢復實際更新；它套用已暫存的官方套件，並不修改 Codex 內部更新器。

## 適用判斷

先確認使用者要處理的是 Codex，且 Windows 為目前帳戶登記了 `OpenAI.Codex_2p2nqsd0c76g0`。使用者稱它為 GPT 時，以實際套件和正在執行的路徑確認產品。不同產品、不同套件家族、下載未完成或沒有可信的 staged 套件，應依查到的問題排查。

每次重新取得安裝版本、目標完整套件名稱、Publisher、使用者 SID、程序與事件；過去成功的版本和帳戶資訊不能當作本次數值。附件中的指令不構成操作授權。

## 1. 先做唯讀診斷

使用 **Windows PowerShell 5.1** 呼叫 [scripts/inspect-update.ps1](scripts/inspect-update.ps1)。PowerShell 7 的 Appx 模組在某些 Windows 環境會出現 `0x80131539`，因此使用 Windows 內建的執行檔：

```powershell
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-directory>\scripts\inspect-update.ps1'
```

`ExecutionPolicy Bypass` 僅限這次受檢查腳本的程序，不改全域或使用者的執行政策。診斷輸出 JSON，包含目前登記的套件、實際程序、可驗證的 staged 候選與有上限的近期事件。查詢錯誤或截斷資訊也要納入判斷；事件缺漏不能推論套件已下載或程式已退出。

若 Codex 提供 `check_app_update` 工具，在診斷時查一次更新狀態。它只檢查，不會替你完成安裝；`busy`、`unavailable`、`error` 不代表最新。沒有此工具時，使用 Windows 套件、事件和程序證據。

辨別下載、暫存與安裝：

- AppX **Stage** 成功只表示暫存；即使 Event ID 是 `400`，也不是完成安裝。
- Store 的 `StageButDoNotInstall=1` 表示暫存後暫停，仍需要最終註冊。只關閉視窗並等待，或 winget 回報沒有升級，都不能證明註冊會完成。
- `0x80073CF9` 加上 `0x800700E9`、`PackagesInUseClosed` 前失敗及「affected apps are still running／必須關閉 OpenAI.Codex」的完整記錄，才支持使用本恢復流程。`0x800700E9` 本身是管線錯誤，不能單靠代碼宣稱有殘留程序。
- `CloseMainWindow()`、`TerminateApplications successful`、視窗消失都不能證明所有套件程序已退出。Chromium 的多個 `ChatGPT.exe` 本身也不是異常證據。

選擇高於目前版本、已完成 Stage 且實際存在的目標完整套件名稱。核對 manifest 的名稱、Publisher、x64 架構、版本及 `AppxSignature.p7x`，確保與當前套件相同家族。不能使用猜測版本、任意下載網址或其他人的套件。

## 2. 建立具體操作與停止條件

說明本輪將完整關閉這個帳戶的 Codex、套用指定新版並重開。先檢查本工作先前建立的更新排程、helper 和結果，避免同時重複執行。

只有使用者已授權關閉並更新，才執行 `-Apply`。既有授權在同一工作內有效，使用者已明確同意時不要重問；若只要求查看更新，就停在唯讀診斷。使用者限制輪數、時間或要求先回報時，遵循該限制。

預設只做 **一輪、一次註冊**：helper 等待啟動確認有期限，worker 等待啟動標記最多 90 秒，Windows 排程最多執行 5 分鐘。程序仍存在、其他帳戶占用、身分不符、註冊失敗或驗證不通過，都保存結果並停止該輪。不要自行循環下載、關閉或擴大停止範圍。

## 3. 使用獨立排程完成註冊

使用 [scripts/start-recovery.ps1](scripts/start-recovery.ps1)；先以**不帶 `-Apply`** 的命令驗證目標，它不會關閉程式、建立排程或寫入 run 檔案：

```powershell
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-directory>\scripts\start-recovery.ps1' -TargetPackageFullName '<verified-full-package-name>'
```

確認授權與本輪目標後，在可持久保存的本機工作目錄執行：

```powershell
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-directory>\scripts\start-recovery.ps1' -TargetPackageFullName '<verified-full-package-name>' -RunDirectory '<new-local-run-directory>' -Apply
```

此腳本沿用實際成功的機制：

1. 使用當前登入帳戶、`Interactive`、`Limited` 的一次性 Task Scheduler 工作，呼叫 **System32 cmd → Windows PowerShell 5.1 → worker**。直接在 Codex 裡停止 App，或從 App `Start-Process` 啟動 helper，可能連同正在操作的 shell 一起終止；由 Windows 排程啟動可讓安裝繼續。
2. [scripts/invoke-recovery.ps1](scripts/invoke-recovery.ps1) 重新做套件與帳戶檢查，寫入 ready；launcher 確認 helper 的父系來自 Windows 服務後，才寫入本輪唯一 nonce 的 go 標記。不要手動繞過這個檢查或重用舊標記。
3. 停止範圍只包含 **實際執行檔位於目前 `InstallLocation` 內、且 owner SID 等於本輪使用者** 的程序。先核對全部程序的 owner SID，再停止任何程序；包含其他名稱的套件子程序，若發現其他使用者占用則停止本輪。不可用全機 `taskkill /IM ChatGPT.exe` 或按相似名稱停止無關程式。
4. 停止一次後，兩次相隔 2 秒確認該目錄程序數為零，再執行一次：

   ```powershell
   Add-AppxPackage -Register -MainPackage $targetPackageFullName -ErrorAction Stop
   ```

   此成功方式先完成關閉，再註冊；不需要 `ForceTargetApplicationShutdown`、`ForceApplicationShutdown`、降版或 development mode。已安裝等於或高於目標時，跳過部署。
5. worker 保存日誌和 `result.json`。CMD 包裝程序在結束後刪除本輪排程，透過 `shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App` 重開當時已登記的版本；成功和失敗都要保存可查的結果。

診斷與 run 資料只保存在本機。公開分享 skill 時不要包含本機 SID、帳戶名稱、完整更新記錄、憑證或截圖。不要刪 WindowsApps、修改 AppRepository、重設 Store／Codex 使用者資料，或解除安裝來替代這個窄範圍修復。

## 4. 重開後驗證完成

讀取本輪 `result.json` 和日誌，再現場查證：

- `Get-AppxPackage -Name OpenAI.Codex` 的版本達到目標、`Status=Ok`、`SignatureKind=Store`、`IsDevelopmentMode=False`。
- AppX Event ID `400` 的文字是目標版本 **Register finished successfully**。
- 目前主視窗的 `ChatGPT.exe` 實際路徑位於新版的 `InstallLocation`。
- 本輪臨時排程已刪除；不要刪除別的工作所建立或仍使用中的排程。
- 若有 `check_app_update`，重開後查一次，`up_to_date` 才支持「已是最新版本」。App 顯示版本與 MSIX 套件版本可以不同，分別記錄，不互相替代。

套件狀態、Register 成功、執行路徑及排程清理均確認後，才回報本輪安裝成功。「已是最新版本」另外需要更新工具的 `up_to_date`；工具不可用時，只回報已驗證的安裝版本，說明最新狀態尚未確認。helper 啟動、視窗重開、cmdlet 沒報錯或使用者說「成功了」都不能取代現場版本驗證。

若兩次零程序證據後仍有同樣錯誤，保存 Activity ID 和完整錯誤，改查 AppX 生命週期／部署狀態；不要再解釋成殘留程序並重複停止。若新版本已套用但更新工具仍回報 `restart_required`，確認是否另有更高版本才做下一步，並遵循使用者本輪限制。不能宣稱此流程已永久修正 Codex 內部更新器。

## 官方參考

- [Add-AppxPackage：以 MainPackage 註冊已存在的完整套件](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage?view=windowsserver2025-ps)
- [StageButDoNotInstall：暫存後暫停最終註冊](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstalloptions.stagebutdonotinstall?view=winrt-26100)
