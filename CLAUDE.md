# Depth Studio iOS — 開發與發佈流程（給 Claude 的工作守則）

使用者只會描述「想要的功能／修正」。從改程式到 iPhone 可安裝的 IPA，其餘步驟都由 Claude 完成：

```
改程式 → 本機測試 → commit/push 到工作分支 → GitHub Actions（macOS）編譯
       → 失敗：讀 log、修正、再 push（重複到成功）
       → 成功：自動建立 GitHub Release（DepthStudio.ipa + altstore-source.json）
       → 回報 Release 連結；使用者在 AltStore 按「更新」
```

## 專案結構重點

- 原生 SwiftUI App，Xcode 專案由 **XcodeGen** 依 `project.yml` 產生（repo 內沒有 `.xcodeproj`）。
- 啟動流程：`DepthStudioRootView`（`ContentView.swift`）→ 啟動動畫 → `ModeSelectionView` 選模式 → 深度潛水 `ContentView` 或泳池平潛 `PoolModeView`。兩種模式各自獨立的介面。
- 泳池平潛（V1 基礎模式）：`PoolTimeline.swift`（泳池長度、時間節點、距離插值、分段平均速率、趟次）、`PoolHUDSettings.swift`（16 個 HUD 欄位）、`PoolHUDOverlay.swift`（預覽 HUD 與距離／速率雙曲線）、`PoolVideoHUDLayer.swift`（輸出用 Core Animation HUD）、`PoolModeView.swift`（畫面）。輸出共用 `DiveVideoExporter.exportVideo`（4K、音訊、MP4 驗證）。
- 泳池平潛下一階段（尚未實作）：AI 人體與背景追蹤、浮動速率、任意時間點距離校正（V1.1／V1.2），踢動頻率與滑行效率（V2.0）。
- 共用元件（`StudioShared.swift`）：`OutputAspect`（原始／1:1／4:5／9:16／16:9）、`ExportSizing`（每種版型都是 3840×2160 的像素量，9:16 = 2160×3840）、`HUDMetrics`（HUD 尺寸以畫面短邊為基準，預覽與輸出共用）、`PlaybackController`（@Observable，只有讀取時間的子 View 會在播放時重繪）、`PlayerLayerView`（aspect-fill，與輸出的置中裁切相同）、浮動「預覽影像」、`ExportProgressClock`（剩餘時間）、`HUDLayoutPresetStore`（「將目前排版設為預設」）。
- 輸出 HUD 一律用 `HUDLayerFactory.swift` 建 layer：`contentsScale = 1`、文字垂直置中、線寬與虛線用 `HUDMetrics.point`。圖表幾何用 `DepthProfileGeometry`／`PoolProfileGeometry`，預覽與輸出共用，修改時兩邊一起看。
- HUD 欄位的手勢必須加在 `.position()` 之前（否則觸控範圍變成整個畫面），並用 `.allowsHitTesting(isEditing)`。
- 泳池平潛速率：`PoolTimeline` 以 0.1 秒為單位的速率曲線，各段距離固定等於標記；`PoolMotionAnalyzer`（Vision 光流＋人體／顯著物偵測）提供 AI 形狀，否則為 ±0.22 m/s 內的模擬浮動。
- `project.yml` 的 `sources:` 是**逐檔列出**。新增 Swift 檔／資源時必須同步加進去，否則不會被編譯。
- 依賴：Garmin FIT Objective-C SDK（Swift Package，鎖定 revision）。
- Bundle ID：`com.bananaflow.depthstudio`；最低 iOS 17；只支援 iPhone。
- `index.html`、`sw.js`、`fit-import.js` 是網頁版 V8.18 的對照基準，**不要修改**（`tests/test_web_native_parity.py` 會檢查）。
- IPA 為**未簽名**，由 AltStore 用使用者的 Apple ID 簽名。不要加入簽名設定或需要付費開發者帳號的 entitlements／capabilities。

## 版本號

- 只在 `project.yml` 維護：`MARKETING_VERSION`（例如 `1.0.4`）。每次交付使用者可見的變更就遞增。
- Build number 由 CI 自動產生（`GITHUB_RUN_NUMBER + 100`），不用手動改 `CURRENT_PROJECT_VERSION`。
- 不要在其他檔案寫死版本號；`scripts/package_ipa.py` 與 `scripts/make_altstore_source.py` 都從 build 產物讀取。
- 新增權限說明（例如相機）用 `INFOPLIST_KEY_NS...UsageDescription` 寫在 `project.yml`；AltStore source 會自動從 Info.plist 帶入，不需另外處理。

## 本機（Linux 容器）可做的檢查

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
node --test tests/fit-import.test.mjs
python3 -m py_compile scripts/*.py && bash -n scripts/ci_build.sh
```

容器內沒有 Xcode，Swift 是否能編譯只能靠 CI 驗證。

## CI：`.github/workflows/ios-build.yml`

- 觸發：push 到 `main` 或 `claude/**`（只改 `.md`/`.txt` 不觸發），或手動 `workflow_dispatch`（可填 `notes`）。
- `checks`（ubuntu）跑上面的測試 → `build`（`macos-15`）執行 `scripts/ci_build.sh` → 發佈 Release。
- 完整 xcodebuild log 存在 artifact；console 只印 error，失敗時最後會印 `BUILD FAILURE SUMMARY`。
- Release tag：`v<MARKETING_VERSION>-build.<N>`，並標為 latest。
- **Commit message 第一段（到第一個空行為止）會成為 Release 與 AltStore 顯示的更新說明**，請用繁體中文寫給使用者看的變更摘要；技術細節寫在後面的段落。
- Commit message 含 `[no release]` 時只編譯檢查、不發佈 Release（用於未完成的中間版本，避免使用者收到不完整的更新）。
- `codemagic.yaml` 呼叫同一支 `scripts/ci_build.sh`，是手動備援，不會自動觸發。

### 監看與修正（使用 GitHub MCP 工具）

1. push 後用 `mcp__github__actions_list`（`method: list_workflow_runs`，`resource_id: ios-build.yml`，`workflow_runs_filter.branch` = 目前分支）找到最新 run。
2. 一次編譯約 5–15 分鐘。等待時用背景指令計時（例如 `sleep 300` 以 `run_in_background` 執行），不要密集輪詢。
3. 失敗時：`mcp__github__get_job_logs`（`run_id`、`failed_only: true`、`return_content: true`、`tail_lines: 300`），從 `BUILD FAILURE SUMMARY` 找到錯誤，修正後再 commit/push。
4. 成功時：用 `mcp__github__list_releases` 取得最新 Release，回報給使用者：版本、變更摘要、Release 連結，以及 AltStore 更新方式。

### 備援：GitHub macOS 無法使用時改用 Codemagic（Claude 可直接操作）

GitHub 的 macOS runner 曾整段時間拿不到機器（job 排隊 15 分鐘後被取消）。此時：

1. Codemagic API 金鑰存在雲端環境「DepthStudio (Codemagic)」的 network secret（header `x-auth-token`，由 proxy 注入，不要自己帶值）。
2. 啟動編譯：`POST https://api.codemagic.io/builds`，body `{"appId":"6b057eb0ef86a3ac863f9d89","workflowId":"depth-studio-unsigned-ios","branch":"<分支>"}`。
3. 查狀態：`GET https://api.codemagic.io/builds/<buildId>`（`build.status`、`buildActions[].status`、`buildActions[].logUrl`、`artefacts[].url`）。用背景迴圈每分鐘查一次。
4. 成功後建立公開下載連結：`POST <artefact url>/public-url`，body `{"expiresAt": <unix 秒>}`。
5. 以該連結觸發 `.github/workflows/publish-ipa.yml`（Linux，`workflow_dispatch`，inputs：`ipa_url`、`notes`、`built_by`），它會檢查 IPA、產生 AltStore source 並發佈 Release（標為 latest），AltStore 即可更新。
6. Codemagic 的 build number = Codemagic 編號 + 1000（見 `codemagic.yaml`）。

### 自動測試（iPhone 模擬器）

- `AppTests/`（XCTest）：泳池計算、輸出尺寸、預設排版、實際輸出 4K 影片並與預覽比對；圖片寫到 `build/test-artifacts/*-preview-vs-export.png`。
- `AppUITests/`（XCUITest）：拖曳每個 HUD 欄位、排版開關、設為預設後恢復。
- 執行：`scripts/ci_test.sh`；Codemagic workflow `depth-studio-tests`（`POST /builds` 的 `workflowId`）。修改 HUD、輸出或排版相關程式後都要跑一次，並下載比對圖檢查。
- 模擬器的限制（已查證，不是程式錯誤）：
  - `AVVideoCompositionCoreAnimationTool` 在模擬器會當機（IOSurface 配置失敗，連空白 HUD 也一樣）。因此測試在沒有 HUD 時實際輸出（驗證尺寸、裁切、進度與 MP4 檢查），HUD 本身則用 `HUDLayerFactory.stillTime` 產生靜態畫面，並與 SwiftUI 預覽並排比對；含 HUD 的完整輸出測試只在實機執行。
  - Vision 光流（`VNGenerateOpticalFlowRequest`）在模擬器無法建立，AI 分析測試在模擬器上會 skip。
- UI 測試要點：預覽舞台比螢幕下半部還長，拖曳下方欄位前要先捲動（`bringIntoView`）；HUD 欄位只用一個 `highPriorityGesture(DragGesture(minimumDistance: 0))` 同時處理選取與拖曳（另外的 tap 手勢會把短距離拖曳吃掉）。
- 結果下載：`GET /builds/<id>` 的 `artefacts[].url`（zip 內含 `build/test-summary.txt`、`build/test-artifacts/*.png`、`*-results.json`、當機時的 `.ips`）。

## 使用者端安裝（AltStore）

- 一次性設定：AltStore → Sources → `+` → 貼上
  `https://github.com/rs963258741-alt/DepthStudio-iOS/releases/latest/download/altstore-source.json`
- 之後每次有新版：AltStore → My Apps → 下拉重新整理 → 按 Depth Studio 的「Update」。
- 備案：在 iPhone Safari 開 Release 頁面下載 `DepthStudio.ipa` → 分享到 AltStore。
- 免費 Apple ID 的簽名 7 天到期，需讓 AltStore 在同一 Wi‑Fi 下透過 AltServer 自動 refresh。

## 需要實機驗證、CI 無法代替的項目

PhotosPicker 選片、FIT/UDDF 實檔匯入、4K MP4 輸出與存入相簿、全螢幕啟動畫面。交付時提醒使用者實測這些項目，並請其回報問題（截圖或錄影）。
