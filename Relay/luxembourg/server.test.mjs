import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { createRelay, isPublicIP, validateURL } from './server.mjs';
const token = 'a'.repeat(48);

test('rejects private, special and mapped addresses', () => {
  for (const address of ['127.0.0.1', '10.0.0.1', '169.254.169.254', '100.64.0.1', '192.168.0.1', '198.18.1.1', '::1', '::ffff:127.0.0.1', 'fe80::1', 'fc00::1', '2001:db8::1', '2002:7f00:1::']) assert.equal(isPublicIP(address), false, address);
  for (const address of ['1.1.1.1', '8.8.8.8', '2606:4700:4700::1111']) assert.equal(isPublicIP(address), true);
});
test('rejects credentials, other ports and protocols', () => {
  for (const url of ['file:///etc/passwd', 'https://user:pass@example.com/a', 'https://example.com:8080/a']) assert.throws(() => validateURL(url));
});
async function withRelay(options, body) {
  const server = createRelay({ tokens: [token], ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try { await body(`http://127.0.0.1:${server.address().port}`); }
  finally { await new Promise(resolve => server.close(resolve)); }
}
const headers = { Authorization: `Bearer ${token}`, 'X-Autohop-Source': Buffer.from('https://example.com/a.mp3').toString('base64') };
test('authenticates status and disabled switch', async () => withRelay({}, async base => {
  assert.equal((await fetch(base + '/v1/status')).status, 401);
  assert.equal((await fetch(base + '/v1/audio', { headers })).status, 503);
}));
test('streams bytes without altering them or forwarding client credentials', async () => {
  const audio = Buffer.from('fixture audio payload');
  await withRelay({ enabled: true, fetcher: async (source, signal, agent) => {
    assert.equal(source, 'https://example.com/a.mp3');
    assert.equal(signal.aborted, false);
    assert.match(agent, /Autohop/);
    const response = Readable.from([audio]);
    response.headers = { 'content-type': 'audio/mpeg', 'content-length': String(audio.length) };
    return response;
  }}, async base => {
    const response = await fetch(base + '/v1/audio', { headers });
    assert.equal(response.headers.get('x-autohop-relay'), 'lu-v1');
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), audio);
    assert.equal((await fetch(base + '/v1/audio', { headers: { ...headers, Range: 'bytes=5-' } })).status, 409);
  });
});
test('enforces per-credential request limit', async () => withRelay({ enabled: true, fetcher: async () => { throw new Error('upstream'); } }, async base => {
  for (let i = 0; i < 10; i++) assert.equal((await fetch(base + '/v1/audio', { headers })).status, 502);
  assert.equal((await fetch(base + '/v1/audio', { headers })).status, 429);
}));

test('refuses localhost destinations before making an upstream connection', async () => withRelay({ enabled: true }, async base => {
  for (const source of ['http://127.0.0.1/admin', 'http://169.254.169.254/latest/meta-data/', 'http://[::1]/']) {
    const response = await fetch(base + '/v1/audio', { headers: { ...headers,
      'X-Autohop-Source': Buffer.from(source).toString('base64') } });
    assert.equal(response.status, 502);
  }
}));

test('rejects malformed destinations and unsupported methods without fetching', async () => withRelay({ enabled: true, fetcher: () => assert.fail('must not fetch') }, async base => {
  assert.equal((await fetch(base + '/v1/audio', { headers: { ...headers, 'X-Autohop-Source': '###' } })).status, 400);
  assert.equal((await fetch(base + '/v1/audio', { method: 'POST', headers })).status, 405);
}));
