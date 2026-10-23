# What the Plaud app can do to the device

Every operation the Android app (Tinnotech `penblesdk`) can run over BLE, grouped by what it does. Method names are from `IBleAgent` / `IWifiAgent`. Command numbers (the BLE opcode) are given where confirmed from the decompile. This is the menu of things `plaude-pirate` *could* do; today it only lists and downloads.

## 📥 Recording transfer (what we already do)

| Method | Cmd | Does |
|---|---|---|
| `getRecSessions` | 26 | List recordings (session id = start time, size, attributes) |
| `syncFileStart` | 28 | Start streaming one recording to the app |
| `syncFileStop` | 30 | Stop the current transfer |
| `fileDataCheck` | — | Verify a transferred chunk |
| `getRecTags` / `getRecMarkings` | — | In-recording tags / bookmarks the user set |

## 🗑️ Deleting and storage (the part you want)

| Method | Cmd | Does |
|---|---|---|
| **`syncFileDel(sessionId)`** | **31** | **Delete one recording.** The app wraps this as `deleteFile` and calls it right after a successful cloud backup. This is the hook for "delete after download". |
| `clearRecordFile` | 104 | Delete **all** recordings at once |
| `getStorage` | 6 | Free / used space on the device |
| `setAutoDeleteRecordFile` / `getAutoDeleteRecordFile` | setting 4 | Device-side auto-delete (tell the device to drop files itself after a retention window) |
| `setAutoSync` / `getAutoSync` | — | Device's own auto-upload toggle |

## 🎙️ Recording control

`startRecord`, `startImmediateRecord`, `startSyncRecord`, `stopRecord` (145), `stopImmediateRecord`, `recordPause` (21), `recordResume` (22). Plus modes: `getRecMode`/`setRecMode`, `getRecScene`/`setRecScene`, `getPreRecord`/`setPreRecord`, `getSaveRAWFile`/`setSaveRAWFile`, `getAutoRecord`/`setAutoRecord`, `setAutoStopRecord`, `setAutoCallRecord`, `setAlarmRec`.

## 📊 Device status & identity

`getState`, `getDeviceStatus`, `getStorage` (6), `getBattStatus`, `getBatteryMode`, `getSsn` (serial), `getBleDeviceName`/`setBleDeviceName`, `getSDFlashCID`, `appGetThirdVersion`, `getSigmaLteStatus`, `syncTime` (set the clock).

## ⚙️ Settings (audio, power, UI)

Audio: `setMICGain`, `setVpuGain`, `setVpuCLK`, `setVadSensitivity`, `openVAD`, `getANC`/`setANC`, `setLDAC`, `setSoundEffect`, `setSoundPlusToken`.
Power/UI: `setAutoPowerOff`, `setBackLightBrightness`, `setBackLightTime`, `setLedStatus`, `setLanguage`, `setBatteryMode`/`setBatteryModeExt`, `setAirplaneMode`, `setPrivacy`, `setNightAutoUpgrade`, `setIBeaconWakeup`, `setAutoEarDetection`, `writeMotorCmd` (haptics), `calibrate`, `resetLens`, `setActive`, `getAllKeyFunc` (button mapping).

## 📶 Wi-Fi (fast transfer + direct cloud upload)

`openWiFi`/`closeWiFi`, `getWifiList`/`getWifiInfo`/`setSyncWifi`/`deleteWifiInfo`, `getRouterSsid`/`setRouterSsid`, `testWifiInfo`/`testWifiResult`, `getWiFiChannel`/`setWiFiChannel`, `getLteUpload`/`setLteUpload`, and `setWebsocket*` / `setWebsocketDevToken` / `setWebsocketSerToken` (the cloud upload endpoint + tokens the device uses to upload on its own). The `IWifiAgent` side (`connectWifi`, `getFileList`, `fileSyncStart`/`fileSyncStop`, `fileDelete`, `speedTest`, `getDeviceLog`) is the high-speed transfer path over Wi-Fi instead of BLE.

## 🔎 Find My / finding the device

`getFindMyState`/`setFindMyState`/`resetFindMy`, `getFindDevice`/`setFindDevice`.

## 🔄 Firmware / OTA

`appFotaPush`, `interruptFotaPush`, `getSyncOtaFileInfo`, `sendLte4gOta`, `getNightAutoUpgrade`/`setNightAutoUpgrade`.

## 🔐 Pairing / security / multi-device

`connectionBLE`, `disconnectBle`, `depair` (unbind), `resetPassword`, `setAppKey`, `getSecurityCheck`/`setSecurityCheck`, `connectDualDevice`/`disconnectDualDevice`/`setDualConnection`, `sendHostBudPairReq` (earbud pairing), `getPairedList`, `armTokenCollision`/`resendCollisionToken` (bind-token collision handling).

## 🪵 Logs / diagnostics / sensors

`startSyncDeviceLogFile`/`stopSyncDeviceLogFile`/`deleteDeviceLogFile` (146)/`getDeviceLogFileList`, `bleRateTest`, `readDataEntry`/`writeDataEntry`, `readExecution`/`writeExecution`, `syncEyeData`/`clearEyeData` (motion/angle sensor data).

---

## For plaude-pirate: the "free up space" feature

Everything needed is already in our protocol layer. After a recording is **downloaded, decrypted and verified** (`data.count == size`, header check passes), send:

```
syncFileDel = command 31, payload: sessionId (u32 LE) + CRC
```

Design notes:
- Gate it behind an explicit, off-by-default option. Deleting the only copy off the device is irreversible.
- Only delete after the local `.ogg` exists and decrypted cleanly — never on a partial pull.
- `getStorage` (command 6) gives free/used, so the UI can show how full the device is and how much a cleanup would reclaim.
- The app's own `deleteFile` wrapper does exactly this one-session-at-a-time delete after a cloud backup, so the behavior and cadence match what the device already expects.
