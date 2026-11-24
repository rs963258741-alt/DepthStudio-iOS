/*
 * Depth Studio FIT importer
 * Uses Garmin's official FIT JavaScript SDK (loaded only when a .FIT file is selected).
 * @garmin/fitsdk is pinned to 21.222.0 so the decoder/profile cannot silently change.
 */
const GARMIN_FIT_SDK_URL = 'https://cdn.jsdelivr.net/npm/@garmin/fitsdk@21.222.0/src/index.js';
const FIT_EPOCH_MS = 631065600000;

let garminFitSdkPromise = null;

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function finiteNumber(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function fitTimestampMs(value) {
  if (value instanceof Date) {
    const time = value.getTime();
    return Number.isFinite(time) ? time : null;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    // Garmin SDK normally returns Date objects. This fallback supports raw FIT epoch seconds.
    if (value > 1000000000000) return value;
    return value * 1000 + FIT_EPOCH_MS;
  }
  if (typeof value === 'string' && value.trim()) {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function temperatureFromRecord(record) {
  const developerFields = record && record.developerFields && typeof record.developerFields === 'object'
    ? record.developerFields
    : {};

  // Prefer an explicitly named water-temperature developer field when present.
  for (const [name, raw] of Object.entries(developerFields)) {
    if (!/(water.*temp|temp.*water)/i.test(name)) continue;
    const candidate = Array.isArray(raw) ? raw[0] : raw;
    const value = finiteNumber(candidate);
    if (value !== null && value >= -10 && value <= 60) return value;
  }

  // Garmin's native FIT Record.temperature is in degrees Celsius. In a dive activity
  // it is the temperature sensor value; files that omit it remain valid and show "--".
  const nativeValue = finiteNumber(record?.temperature);
  return nativeValue !== null && nativeValue >= -10 && nativeValue <= 60 ? nativeValue : NaN;
}

function trapezoidalAverageDepth(samples) {
  if (!Array.isArray(samples) || samples.length < 2) return samples?.[0]?.d ?? 0;
  let area = 0;
  let elapsed = 0;
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1];
    const b = samples[i];
    const dt = b.t - a.t;
    if (!(dt > 0)) continue;
    area += ((a.d + b.d) / 2) * dt;
    elapsed += dt;
  }
  return elapsed > 0 ? area / elapsed : samples.reduce((sum, p) => sum + p.d, 0) / samples.length;
}

/**
 * Convert already-decoded Garmin FIT messages into Depth Studio's common sample shape:
 * [{ t: elapsedSeconds, d: depthMeters, temp: temperatureCelsius }].
 * Exported separately so the normalizer can be regression-tested without a live FIT file.
 */
export function normalizeGarminFitMessages(messages, profileVersion = null) {
  if (!messages || typeof messages !== 'object') {
    throw new Error('FIT 解碼結果無效。');
  }

  const records = asArray(messages.recordMesgs);
  if (records.length === 0) {
    throw new Error('此 FIT 檔沒有 Garmin record 記錄訊息，無法建立潛水深度曲線。請從 Garmin Dive 或 Garmin Connect 匯出單筆潛水 FIT。');
  }

  const depthRecords = [];
  for (const record of records) {
    const timestampMs = fitTimestampMs(record?.timestamp);
    const depth = finiteNumber(record?.depth);
    if (timestampMs === null || depth === null || depth < 0 || depth > 2000) continue;
    depthRecords.push({ timestampMs, d: depth, temp: temperatureFromRecord(record) });
  }

  if (depthRecords.length < 2) {
    throw new Error('FIT 檔雖然有記錄訊息，但沒有至少兩筆帶時間戳的有效深度資料。請確認匯出的 Garmin 潛水 FIT 包含水下深度曲線。');
  }

  depthRecords.sort((a, b) => a.timestampMs - b.timestampMs);
  const originMs = depthRecords[0].timestampMs;
  const parsedRaw = depthRecords.map(point => ({
    t: (point.timestampMs - originMs) / 1000,
    d: point.d,
    temp: point.temp
  }));

  // Same timestamp handling as the established UDDF importer: keep the last point
  // to avoid zero-length interpolation intervals and artificial speed spikes.
  const samples = [];
  for (const point of parsedRaw) {
    const previous = samples[samples.length - 1];
    if (previous && Math.abs(previous.t - point.t) < 0.0001) samples[samples.length - 1] = point;
    else samples.push(point);
  }

  if (samples.length < 2) {
    throw new Error('FIT 深度資料的時間戳重複，無法建立有效時間軸。');
  }

  const summaries = asArray(messages.diveSummaryMesgs);
  const summary = summaries.length ? summaries[0] : null;
  const computedMax = samples.reduce((maximum, point) => Math.max(maximum, point.d), 0);
  const computedAverage = trapezoidalAverageDepth(samples);
  const declaredMax = finiteNumber(summary?.maxDepth);
  const declaredAverage = finiteNumber(summary?.avgDepth);
  const maxDepth = declaredMax !== null && declaredMax > 0 && declaredMax <= 2000 ? declaredMax : computedMax;
  const avgDepth = declaredAverage !== null && declaredAverage >= 0 && declaredAverage <= 2000 ? declaredAverage : computedAverage;
  const duration = Math.max(0, samples[samples.length - 1].t - samples[0].t);

  const fileId = asArray(messages.fileIdMesgs)[0] || null;
  const sessions = asArray(messages.sessionMesgs);
  const session = sessions[0] || null;
  const modelName = typeof fileId?.productName === 'string' && fileId.productName.trim()
    ? fileId.productName.trim()
    : (typeof session?.sportProfileName === 'string' && session.sportProfileName.trim() ? session.sportProfileName.trim() : 'Garmin');
  const profileText = profileVersion && Number.isFinite(Number(profileVersion.major))
    ? `FIT Profile ${profileVersion.major}.${profileVersion.minor ?? 0}`
    : 'FIT Profile';

  return {
    samples,
    maxDepth,
    avgDepth,
    duration,
    metadata: {
      modelName,
      profileText,
      sourceRecordCount: records.length,
      depthSampleCount: samples.length,
      diveSummaryCount: summaries.length,
      temperatureSampleCount: samples.filter(point => Number.isFinite(point.temp)).length,
      sport: session?.sport ?? null,
      subSport: session?.subSport ?? null
    }
  };
}

async function loadGarminFitSdk() {
  if (!garminFitSdkPromise) {
    garminFitSdkPromise = import(GARMIN_FIT_SDK_URL).catch(error => {
      garminFitSdkPromise = null;
      throw new Error('無法載入 Garmin FIT 解碼模組。請確認網路連線後重新匯入 FIT 檔。' + (error?.message ? `（${error.message}）` : ''));
    });
  }
  return garminFitSdkPromise;
}

/** Decode and validate one Garmin .FIT file, then normalize it for the existing HUD. */
export async function parseGarminFitFile(file) {
  if (!file || typeof file.arrayBuffer !== 'function') {
    throw new Error('沒有取得有效的 FIT 檔案。');
  }
  if (!/\.fit$/i.test(file.name || '')) {
    throw new Error('檔案副檔名不是 .FIT。');
  }
  if (file.size < 16) {
    throw new Error('FIT 檔案大小不足，可能不是完整的 Garmin 匯出檔。');
  }

  const { Decoder, Stream } = await loadGarminFitSdk();
  if (typeof Decoder !== 'function' || !Stream?.fromArrayBuffer) {
    throw new Error('Garmin FIT 解碼模組版本不相容。');
  }

  const buffer = await file.arrayBuffer();
  const stream = Stream.fromArrayBuffer(buffer);
  const decoder = new Decoder(stream);
  if (!decoder.isFIT()) {
    throw new Error('檔案標頭不是 Garmin FIT 格式，請確認選取的是 .FIT 原始紀錄。');
  }
  if (!decoder.checkIntegrity()) {
    throw new Error('FIT 檔案完整性檢查失敗（標頭、檔案長度或 CRC 不符）。請重新從 Garmin 匯出檔案。');
  }

  const decoded = decoder.read({
    applyScaleAndOffset: true,
    expandSubFields: true,
    expandComponents: true,
    convertTypesToStrings: true,
    convertDateTimesToDates: true,
    includeUnknownData: true,
    mergeHeartRates: false,
    decodeMemoGlobs: true
  });

  if (decoded.errors?.length) {
    const firstError = decoded.errors[0];
    throw new Error('Garmin FIT 解碼時發生錯誤：' + (firstError?.message || String(firstError)));
  }

  return normalizeGarminFitMessages(decoded.messages, decoded.profileVersion);
}
