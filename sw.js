/* Depth Studio V8.12 — OPFS streaming download with progress and byte-range support. */
'use strict';

self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('message', event => {
  if (event.data?.type === 'DEPTHSTUDIO_VERSION_CHECK') {
    const port = event.ports && event.ports[0];
    if (port) port.postMessage({ type: 'DEPTHSTUDIO_VERSION', version: '8.12' });
  }
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' && request.method !== 'HEAD') return;
  const requestUrl = new URL(request.url);
  const downloadPath = new URL('__depthstudio_download__', self.registration.scope).pathname;
  if (requestUrl.origin !== self.location.origin || requestUrl.pathname !== downloadPath) return;

  let releaseWorker;
  let released = false;
  const lifetime = new Promise(resolve => { releaseWorker = resolve; });
  const finish = () => { if (!released) { released = true; releaseWorker(); } };
  event.waitUntil(lifetime);

  event.respondWith((async () => {
    let bytesSent = 0;
    let totalBytes = 0;
    const id = requestUrl.searchParams.get('id') || '';
    let clientsForPage = [];
    const notify = async (phase, extra = {}) => {
      const payload = { type: 'depthstudio-download-progress', id, phase, sent: bytesSent, total: totalBytes, ...extra };
      for (const client of clientsForPage) { try { client.postMessage(payload); } catch (_) {} }
    };
    try {
      // Resolve the page client first so storage errors can be reported too.
      const allClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const scopeUrl = new URL(self.registration.scope);
      clientsForPage = allClients.filter(client => {
        try { const u = new URL(client.url); return u.origin === scopeUrl.origin && u.pathname.startsWith(scopeUrl.pathname); }
        catch (_) { return false; }
      });

      const storedName = requestUrl.searchParams.get('file') || '';
      const downloadName = requestUrl.searchParams.get('name') || 'DepthStudio_Export.mp4';
      if (!storedName || /[\\/\0]/.test(storedName) || storedName === '.' || storedName === '..') {
        throw new Error('下載檔案名稱無效。');
      }
      if (!self.navigator?.storage || typeof self.navigator.storage.getDirectory !== 'function') {
        throw new Error('此 iPhone 瀏覽器的 Service Worker 無法讀取網站私有檔案空間。');
      }
      const root = await self.navigator.storage.getDirectory();
      const handle = await root.getFileHandle(storedName);
      const file = await handle.getFile();
      if (!file || file.size < 1024) throw new Error('找不到完整的 MP4 檔案。');

      let responseBlob = file;
      let status = 200;
      let contentRange = '';
      const rangeHeader = request.headers.get('Range');
      if (rangeHeader) {
        const match = /^bytes=(\d*)-(\d*)$/i.exec(rangeHeader.trim());
        if (!match) {
          finish();
          return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${file.size}`, 'Cache-Control': 'no-store' } });
        }
        let start, end;
        if (match[1] === '') {
          const suffix = Math.max(0, Number(match[2]) || 0);
          start = Math.max(0, file.size - suffix); end = file.size - 1;
        } else {
          start = Number(match[1]); end = match[2] === '' ? file.size - 1 : Math.min(file.size - 1, Number(match[2]));
        }
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= file.size || end < start) {
          finish();
          return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${file.size}`, 'Cache-Control': 'no-store' } });
        }
        responseBlob = file.slice(start, end + 1, 'video/mp4');
        status = 206;
        contentRange = `bytes ${start}-${end}/${file.size}`;
      }

      totalBytes = responseBlob.size;
      await notify('start');
      if (request.method === 'HEAD') {
        const headHeaders = new Headers({
          'Content-Type': 'video/mp4',
          'Content-Length': String(responseBlob.size),
          'Content-Disposition': `attachment; filename="${downloadName.replace(/[\r\n"\\;]/g, '_').replace(/[^\x20-\x7E]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(downloadName)}`,
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'no-store, no-cache, must-revalidate',
          'X-Content-Type-Options': 'nosniff'
        });
        if (contentRange) headHeaders.set('Content-Range', contentRange);
        finish();
        return new Response(null, { status, headers: headHeaders });
      }

      const reader = responseBlob.stream().getReader();
      const reportThreshold = 1024 * 1024;
      let nextReport = reportThreshold;
      const body = new ReadableStream({
        async pull(controller) {
          try {
            const result = await reader.read();
            if (result.done) {
              controller.close();
              await notify('complete');
              finish();
              return;
            }
            const chunk = result.value;
            bytesSent += chunk.byteLength;
            controller.enqueue(chunk);
            if (bytesSent >= nextReport || bytesSent >= totalBytes) {
              await notify('progress');
              nextReport = bytesSent + reportThreshold;
            }
          } catch (error) {
            try { controller.error(error); } catch (_) {}
            await notify('error', { message: error?.message || String(error) });
            finish();
          }
        },
        async cancel(reason) {
          try { await reader.cancel(reason); } catch (_) {}
          await notify('cancelled', { message: '瀏覽器取消或中斷下載' });
          finish();
        }
      }, { highWaterMark: 1 });

      const asciiName = downloadName.replace(/[\r\n"\\;]/g, '_').replace(/[^\x20-\x7E]/g, '_') || 'DepthStudio_Export.mp4';
      const encodedName = encodeURIComponent(downloadName).replace(/[!'()*]/g, ch => '%' + ch.charCodeAt(0).toString(16).toUpperCase());
      const headers = new Headers({
        'Content-Type': 'video/mp4',
        'Content-Length': String(responseBlob.size),
        'Content-Disposition': `attachment; filename="${asciiName}"; filename*=UTF-8''${encodedName}`,
        'Cache-Control': 'no-store, no-cache, must-revalidate',
        'Pragma': 'no-cache',
        'X-Content-Type-Options': 'nosniff',
        'Accept-Ranges': 'bytes'
      });
      if (contentRange) headers.set('Content-Range', contentRange);
      return new Response(body, { status, headers });
    } catch (error) {
      await notify('error', { message: error?.message || String(error) });
      finish();
      return new Response('Depth Studio 下載失敗：' + (error?.message || String(error)), {
        status: 404,
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
      });
    }
  })());
});
