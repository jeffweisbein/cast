import test from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createAPNsSender } from '../src/apns.js';

test('real HTTP2 request uses exact APNs topic/type/expiry and verifiable ES256 JWT', async (t) => {
  const key = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const seen = [];
  const server = http2.createServer();
  server.on('stream', (stream, headers) => {
    let data = ''; stream.on('data', c => { data += c; });
    stream.on('end', () => { seen.push({ headers, data }); stream.respond({ ':status': 200, 'apns-id': 'fixture-accepted' }); stream.end(); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const origins = [];
  const now = 1800000000000;
  const sender = createAPNsSender({ keyID: 'ABCDEFGHIJ', privateKey: key.privateKey.export({ format: 'pem', type: 'pkcs8' }), now: () => now,
    connect: (origin) => { origins.push(origin); return http2.connect(`http://127.0.0.1:${server.address().port}`); } });
  const payload = { aps: { alert: { title: 'Cast reminder', body: 'Your reminder is ready. Tap to view.' }, sound: 'default' }, openclaw: { kind: 'task.completed', notificationKind: 'reminder.due' } };
  assert.equal((await sender({ token: 'ab'.repeat(32), environment: 'production', payload, expiresAt: now + 86400000, collapseID: 'stable-event' })).status, 200);
  assert.equal(origins[0], 'https://api.push.apple.com');
  const h = seen[0].headers;
  assert.equal(h['apns-topic'], 'com.besttechie.cast'); assert.equal(h['apns-push-type'], 'alert');
  assert.equal(h['apns-priority'], '10'); assert.equal(h['apns-expiration'], String(now / 1000 + 86400));
  assert.equal(h['apns-collapse-id'].length, 64); assert.deepEqual(JSON.parse(seen[0].data), payload);
  const jwt = h.authorization.slice('bearer '.length).split('.');
  assert.deepEqual(JSON.parse(Buffer.from(jwt[0], 'base64url')), { alg: 'ES256', kid: 'ABCDEFGHIJ' });
  assert.deepEqual(JSON.parse(Buffer.from(jwt[1], 'base64url')), { iss: '2Q694P9U2Y', iat: now / 1000 });
  assert.equal(verify('sha256', Buffer.from(jwt.slice(0, 2).join('.')), { key: key.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(jwt[2], 'base64url')), true);
  await sender({ token: 'ab'.repeat(32), environment: 'production', payload, expiresAt: 0, collapseID: 'task-event' });
  assert.equal(seen[1].headers['apns-expiration'], '0');
  const expired = await sender({ token: 'ab'.repeat(32), environment: 'production', payload, expiresAt: now - 1000, collapseID: 'expired' });
  assert.equal(expired.status, 400); assert.equal(expired.reason, 'Expired'); assert.equal(seen.length, 2);
});

test('provider rejects non-P256 keys and malformed device tokens before transport', async () => {
  const wrong = generateKeyPairSync('ec', { namedCurve: 'secp384r1' });
  assert.throws(() => createAPNsSender({ keyID: 'ABCDEFGHIJ', privateKey: wrong.privateKey.export({ format: 'pem', type: 'pkcs8' }) }), /P-256/);
  const valid = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const sender = createAPNsSender({ keyID: 'ABCDEFGHIJ', privateKey: valid.privateKey.export({ format: 'pem', type: 'pkcs8' }), connect: () => assert.fail('must not connect') });
  await assert.rejects(sender({ token: 'invalid', environment: 'production', payload: {}, expiresAt: 0, collapseID: 'invalid' }), /device token/);
});
