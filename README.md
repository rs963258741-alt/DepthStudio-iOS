# Depth Studio iOS — V8.18 功能對齊版

## 安裝與自動建置

[![iOS build → AltStore](https://github.com/rs963258741-alt/DepthStudio-iOS/actions/workflows/ios-build.yml/badge.svg)](https://github.com/rs963258741-alt/DepthStudio-iOS/actions/workflows/ios-build.yml)

每次 push 到 `main` 或 `claude/**` 分支，GitHub Actions 會在 macOS 上編譯未簽名 IPA，並發佈到 [Releases](https://github.com/rs963258741-alt/DepthStudio-iOS/releases)。

**AltStore 一次性設定：** AltStore → Sources → `+` → 貼上

```
https://github.com/rs963258741-alt/DepthStudio-iOS/releases/latest/download/altstore-source.json
```

之後有新版本時，在 AltStore → My Apps 按 Depth Studio 的 **Update** 即可。也可以在 iPhone Safari 打開最新 Release，下載 `DepthStudio.ipa` 後分享到 AltStore。

開發流程細節（版本號、CI、除錯方式）見 [`CLAUDE.md`](CLAUDE.md)。Codemagic（`codemagic.yaml`）保留為手動備援，與 GitHub Actions 共用 `scripts/ci_build.sh`。

這個 Repository 是獨立的原生 iOS App 專案。網頁版原始專案不在這裡修改；本專案以使用者提供的 `DepthStudio_WebPreview_V8_18.zip` 作為功能比對基準。

## 版本

- App version：`1.0.3`
- Build：由 CI 自動編號（GitHub Actions run number + 100）
- Minimum iOS：`17.0`
- Bundle ID：`com.bananaflow.depthstudio`
- Build：GitHub Actions macOS（主要）／Codemagic（備援）+ XcodeGen + Xcode
- IPA：使用 `scripts/package_ipa.py` 產生，封裝結構沿用先前在 AltStore 實際安裝成功的 Payload ZIP 方式。

## V8.18 功能對照

| 網頁版 V8.18 功能 | 原生 iOS 對應 | 狀態 |
|---|---|---|
| MP4／MOV 影片匯入 | PhotosPicker 相簿選片，另保留 Files 匯入 | 已接線，待 iPhone 實測 |
| ATMOS UDDF／XML 匯入 | 原有 `AtmosUDDFParser`，支援 FIT／UDDF／XML 檔案選取 | 保留 |
| Garmin FIT 匯入 | Garmin 官方 FIT Objective-C SDK，驗證並解碼時間戳／深度樣本 | 保留 |
| 示範資料、重設外觀 | 原生示範潛水資料、HUD 設定重設 | 已實作 |
| 9:16 透明 HUD 預覽 | SwiftUI 9:16 stage + 透明 HUD | 已實作 |
| 15 個獨立 HUD 欄位 | 15 個欄位 ID 與 V8.18 一致 | 已比對 |
| 欄位拖曳、縮放、旋轉 | 原生手勢、獨立比例與角度、直角快捷鍵 | 已實作 |
| 欄位中心吸附 | 與可見欄位中心 2% 門檻吸附及輔助線 | 已實作 |
| 單項重設／全部恢復 | 單項 Transform 重設、全版位置與 Transform 重設 | 已實作 |
| HUD 顯示／隱藏 | 15 項個別切換、全部顯示／隱藏 | 已實作 |
| 全域 HUD 透明度、字級、垂直偏移 | 原生 Slider，範圍對應 V8.18 | 已實作 |
| 姓名、七種旗幟、六種潛水種類 | 與 V8.18 選項相同；姓名最多 30 字 | 已實作 |
| 深度、時間、水溫、速度與曲線 | 原生插值、深度圖、移動讀值點及三等分時間軸 | 已實作 |
| 影片／手錶時間差 | -120 至 +120 秒，0.5 秒步進 | 已實作 |
| 深度摘要 | 最大深度、平均深度、紀錄時間及裝置資訊 | 已實作 |
| 4K MP4 輸出 | AVFoundation + Core Animation HUD 合成；長邊至少 3840 px | 已實作，待實機輸出測試 |
| MP4／影音軌驗證 | 檢查 ftyp／moov／mdat、解析度、封包數、首個影格解碼及來源音訊軌 | 已實作，待實機輸出測試 |
| 完成影片交付 | 儲存至 iPhone Photos，並提供 ShareLink 備用 | 原生平台對應 |
| 偏好設定持久化 | UserDefaults | 原生平台對應 |

## 原生平台差異

網頁版 V8.18 使用 Mediabunny／WebCodecs／OPFS，並以直接下載連結交付影片；iOS 版使用 AVFoundation／Core Animation，在裝置上輸出 MP4 後寫入 Photos，另可透過系統分享介面另存。兩者的內部編碼與檔案儲存 API 不相同，但使用者可操作的匯入、HUD 編輯、同步、4K 輸出及輸出驗證功能依 V8.18 對齊。iOS 的輸出影格時間採來源軌 `minFrameDuration`，若來源沒有有效固定影格時間，會使用 30 fps fallback；變動影格率素材仍應在 iPhone 上抽測。

## 品牌動畫

開場動畫保留原本的潛水員、深度環形及海浪動態。Logo 使用本次提供的深底白銀配色 PNG，因為它在深海藍背景上有較佳對比；動畫內尺寸縮小為 56 × 46 pt，不作主視覺放大。

## 建置

Codemagic workflow：`depth-studio-unsigned-ios`（畫面名稱：`Depth Studio · V8.18 Native Parity + Fullscreen Launch + AltStore IPA`）。執行後會產生 `build/DepthStudio.ipa` 與 `build/xcodebuild-release.log`。

IPA 由 `scripts/package_ipa.py` 產生，必須保留 `Payload/` 位於 ZIP 根目錄的結構。不要在 Windows 端重新壓縮 `.app`。

## 本次可重現檢查

```bash
python -m unittest discover -s tests -p 'test_*.py' -v
node --test tests/fit-import.test.mjs
python -m py_compile scripts/package_ipa.py
swiftc -frontend -parse *.swift
```

目前環境可執行 Swift 語法解析、Python／Node 測試、YAML／Shell 靜態檢查與 IPA 結構模擬；不能代替 Apple Xcode 的 iOS SDK 型別檢查、實際 Codemagic build、PhotosPicker 真機互動或 iPhone 影片匯出驗收。請以 Codemagic 編譯與 iPhone 實機結果作最終確認。


## Full-screen launch configuration

The iOS target includes `LaunchScreen.storyboard` and sets `UILaunchStoryboardName=LaunchScreen`. This adds the missing native launch-screen configuration and is intended to correct the legacy 2:3 letterboxing observed in the supplied iPhone recording. The actual device screen bounds still require the next iPhone build to verify. The IPA packager and Codemagic workflow validate that the compiled storyboard is present.
