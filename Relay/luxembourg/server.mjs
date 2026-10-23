import http from 'node:http';
import https from 'node:https';
import dns from 'node:dns/promises';
import { isIP, BlockList } from 'node:net';
import { createHash, timingSafeEqual } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { pathToFileURL } from 'node:url';

const hash = s => createHash('sha256').update(s).digest();
const MAX_BYTES = 2 * 1024 ** 3;
const MAX_MS = 15 * 60 * 1000;

const blockedIPv6 = new BlockList();
for (const [address, prefix] of [['2001::', 32], ['2001:2::', 48], ['2001:db8::', 32],
  ['2001:10::', 28], ['2001:20::', 28], ['2002::', 16], ['3fff::', 20]]) {
  blockedIPv6.addSubnet(address, prefix, 'ipv6');
}

// Only globally routable destinations. Reject mapped IPv4, scoped and special IPv6.
export function isPublicIP(address) {
  const family = isIP(address);
  if (family === 6) {
    const a = address.toLowerCase();
    return /^[23][0-9a-f]{3}:/.test(a)
      && !blockedIPv6.check(a, 'ipv6') && !a.includes('%');
  }
  if (family !== 4) return false;
  const [a, b, c] = address.split('.').map(Number);
  return !(a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && (b === 168 || b === 0 || (b === 88 && c === 99) || (b === 2)))
    || (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100)))
    || (a === 203 && b === 0 && c === 113));
}

export function validateURL(value) {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password
      || url.hash || (url.port && url.port !== (url.protocol === 'https:' ? '443' : '80'))
      || value.length > 8192) throw new Error('destination');
  return url;
}

async function fetchMedia(value, signal, userAgent) {
  let url = validateURL(value);
  for (let hop = 0; hop <= 6; hop++) {
    const hostname = url.hostname.replace(/^\[|\]$/g, '');
    const addresses = isIP(hostname) ? [{ address: hostname, family: isIP(hostname) }]
      : await dns.lookup(hostname, { all: true });
    // Reject the entire answer if it mixes public and private addresses.
    if (!addresses.length || addresses.some(a => !isPublicIP(a.address))) throw new Error('destination');
    const chosen = addresses[0];
    const response = await new Promise((resolve, reject) => {
      const request = (url.protocol === 'https:' ? https : http).get(url, {
        signal,
        headers: { 'User-Agent': userAgent, 'Accept-Encoding': 'identity', Accept: 'audio/*,application/octet-stream' },
        // Pin the validated answer: a second DNS resolution cannot rebind to localhost.
        lookup: (_host, options, callback) => options?.all
          ? callback(null, [chosen]) : callback(null, chosen.address, chosen.family),
        timeout: 45_000,
      }, resolve);
      request.on('timeout', () => request.destroy(new Error('timeout')));
      request.on('error', reject);
    });
    if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
      const location = response.headers.location;
      response.destroy();
      if (!location || hop === 6) throw new Error('redirect');
      url = validateURL(new URL(location, url).href);
      continue;
    }
    if (response.statusCode !== 200) { response.destroy(); throw new Error('upstream'); }
    const type = (response.headers['content-type'] ?? '').split(';')[0].toLowerCase().trim();
    const length = Number(response.headers['content-length'] ?? 0);
    if (!(type.startsWith('audio/') || type === 'application/octet-stream')
        || !Number.isSafeInteger(length) || length < 0 || length > MAX_BYTES
        || (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity')) {
      response.destroy(); throw new Error('media');
    }
    return response;
  }
  throw new Error('redirect');
}

export function createRelay({ tokens, enabled = false, fetcher = fetchMedia, clock = Date.now,
                              userAgent = 'Autohop/1.0 (podcast download)' }) {
  if (!tokens?.length || tokens.some(t => t.length < 32)) throw new Error('Use individual random tokens of at least 32 characters');
  const credentials = tokens.map(hash);
  const slots = new Map();
  let active = 0;
  return http.createServer({ maxHeaderSize: 16_384, requestTimeout: 30_000 }, async (req, res) => {
    const send = (code, data) => {
      if (!res.headersSent) res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
    };
    const raw = req.headers.authorization ?? '';
    const presented = hash(raw.startsWith('Bearer ') ? raw.slice(7) : '');
    const index = credentials.findIndex(c => timingSafeEqual(c, presented));
    if (index < 0) return send(401, { error: 'unauthorised' });
    if (req.method !== 'GET') return send(405, { error: 'method' });
    if (req.url === '/v1/status') return send(enabled ? 200 : 503, { enabled, region: 'LU', version: 1 });
    if (req.url !== '/v1/audio') return send(404, { error: 'not_found' });
    if (!enabled) return send(503, { error: 'disabled' });
    // No resume: every fetch can produce a different DAI representation.
    if (req.headers.range) return send(409, { error: 'restart_required' });
    let source;
    try {
      const header = req.headers['x-autohop-source'];
      if (typeof header !== 'string' || header.length > 11_000) throw new Error();
      source = Buffer.from(header, 'base64').toString('utf8');
      validateURL(source);
    } catch { return send(400, { error: 'destination' }); }
    const now = clock();
    const slot = slots.get(index) ?? { active: 0, count: 0, since: now };
    if (now - slot.since >= 60_000) { slot.since = now; slot.count = 0; }
    slots.set(index, slot);
    if (active >= 12 || slot.active >= 2 || slot.count >= 10) return send(429, { error: 'rate_limit' });
    slot.count++; slot.active++; active++;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), MAX_MS);
    const close = () => controller.abort();
    res.once('close', close);
    let upstream;
    try {
      const clientAgent = req.headers['user-agent'];
      const upstreamAgent = typeof clientAgent === 'string' && /^Autohop\/[^\r\n]{1,180}$/.test(clientAgent)
        ? clientAgent : userAgent;
      upstream = await fetcher(source, controller.signal, upstreamAgent);
      const headers = { 'Content-Type': upstream.headers['content-type'],
        'Cache-Control': 'no-store', 'X-Autohop-Relay': 'lu-v1', 'Accept-Ranges': 'none' };
      if (upstream.headers['content-length']) headers['Content-Length'] = upstream.headers['content-length'];
      res.writeHead(200, headers);
      let bytes = 0;
      const limit = new Transform({ transform(chunk, _encoding, callback) {
        bytes += chunk.length;
        callback(bytes > MAX_BYTES ? new Error('size_limit') : null, chunk);
      }});
      await pipeline(upstream, limit, res, { signal: controller.signal });
    } catch {
      upstream?.destroy();
      if (!res.headersSent && !res.destroyed) send(502, { error: 'download_unavailable' });
      else res.destroy();
    } finally {
      clearTimeout(timeout); res.off('close', close);
      slot.active--; active--;
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const tokens = (process.env.RELAY_TOKENS ?? '').split(',').map(t => t.trim()).filter(Boolean);
  createRelay({ tokens, enabled: process.env.LU_EGRESS_VERIFIED === 'true' })
    .listen(Number(process.env.PORT ?? 8080), '0.0.0.0', () => console.log('Autohop relay listening'));
}
