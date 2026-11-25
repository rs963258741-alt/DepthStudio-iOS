import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeGarminFitMessages } from '../fit-import.js';

const date = seconds => new Date(Date.UTC(2026, 0, 1, 0, 0, seconds));

test('normalizes depth records and prefers Garmin dive summary values', () => {
  const result = normalizeGarminFitMessages({
    fileIdMesgs: [{ productName: 'Descent Test Device' }],
    sessionMesgs: [{ sport: 'diving', subSport: 'apnea' }],
    recordMesgs: [
      { timestamp: date(0), depth: 0, temperature: 28 },
      { timestamp: date(1), depth: 4.2, temperature: 28.1 },
      { timestamp: date(2), depth: 9.1, temperature: 28.2 },
      { timestamp: date(3), depth: 0, temperature: 28.1 }
    ],
    diveSummaryMesgs: [{ maxDepth: 9.4, avgDepth: 4.6 }]
  }, { major: 21, minor: 222 });

  assert.equal(result.samples.length, 4);
  assert.deepEqual(result.samples.map(point => point.t), [0, 1, 2, 3]);
  assert.equal(result.samples[2].d, 9.1);
  assert.equal(result.samples[2].temp, 28.2);
  assert.equal(result.maxDepth, 9.4);
  assert.equal(result.avgDepth, 4.6);
  assert.equal(result.duration, 3);
  assert.equal(result.metadata.modelName, 'Descent Test Device');
  assert.equal(result.metadata.profileText, 'FIT Profile 21.222');
});

test('collapses duplicate timestamps without creating zero-length intervals', () => {
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: date(0), depth: 0 },
      { timestamp: date(1), depth: 2 },
      { timestamp: date(1), depth: 3 },
      { timestamp: date(2), depth: 0 }
    ]
  });
  assert.equal(result.samples.length, 3);
  assert.equal(result.samples[1].d, 3);
  assert.equal(result.samples[1].t, 1);
});

test('calculates maximum and time-weighted average when dive summary is absent', () => {
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: date(0), depth: 0 },
      { timestamp: date(1), depth: 4 },
      { timestamp: date(2), depth: 8 }
    ]
  });
  assert.equal(result.maxDepth, 8);
  assert.equal(result.avgDepth, 4);
});

test('accepts missing temperature data without inventing a value', () => {
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: date(0), depth: 0 },
      { timestamp: date(1), depth: 5 }
    ]
  });
  assert.equal(Number.isNaN(result.samples[0].temp), true);
  assert.equal(result.metadata.temperatureSampleCount, 0);
});

test('reads an explicitly named water-temperature developer field first', () => {
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: date(0), depth: 0, temperature: 21, developerFields: { waterTemperature: 27.5 } },
      { timestamp: date(1), depth: 5, temperature: 21, developerFields: { water_temperature: 27.7 } }
    ]
  });
  assert.equal(result.samples[0].temp, 27.5);
  assert.equal(result.samples[1].temp, 27.7);
});

test('rejects FIT data without usable timestamped depth samples', () => {
  assert.throws(
    () => normalizeGarminFitMessages({ recordMesgs: [{ timestamp: date(0), heartRate: 80 }] }),
    /沒有至少兩筆帶時間戳的有效深度資料/
  );
});

test('rejects non-record files', () => {
  assert.throws(
    () => normalizeGarminFitMessages({ sessionMesgs: [{ sport: 'diving' }] }),
    /沒有 Garmin record 記錄訊息/
  );
});


test('converts raw FIT epoch timestamps when the SDK returns numeric seconds', () => {
  const fitEpoch = 631065600;
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: fitEpoch, depth: 0 },
      { timestamp: fitEpoch + 2, depth: 6 }
    ]
  });
  assert.deepEqual(result.samples.map(point => point.t), [0, 2]);
  assert.equal(result.duration, 2);
});

test('ignores invalid timestamps and implausible depth samples', () => {
  const result = normalizeGarminFitMessages({
    recordMesgs: [
      { timestamp: null, depth: 30 },
      { timestamp: date(0), depth: 0 },
      { timestamp: date(1), depth: 4 },
      { timestamp: date(2), depth: 2501 },
      { timestamp: date(3), depth: 0 }
    ],
    diveSummaryMesgs: [{ maxDepth: 2501, avgDepth: -1 }]
  });
  assert.deepEqual(result.samples.map(point => point.d), [0, 4, 0]);
  assert.equal(result.maxDepth, 4);
  assert.equal(result.avgDepth, 2);
});
