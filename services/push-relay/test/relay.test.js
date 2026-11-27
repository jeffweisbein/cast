import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRelay, httpHandler } from '../src/relay.js';

const hash = (v) => createHash('sha256').update(v).digest('hex');
const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64');
function fixture(options = {}) {
  let timestamp = 1800000000000;
  const calls = [];
  const verifierCalls = [];
  const dir = mkdtempSync(join(tmpdir(), 'cast-relay-test-'));
  const cfg = {
    dbPath: join(dir, 'test.sqlite'), now: () => timestamp,
    // Deliberate boundary fakes: production always uses Apple's maintained verifier.
    attestationVerifier: (args) => { verifierCalls.push(args); if (args.attestation.toString() !== 'valid-attestation') throw Error('bad'); return { publicKey: 'test-public-key', keyId: args.keyId }; },
    assertionVerifier: (args) => { const proof = JSON.parse(args.assertion.toString()); if (proof.digest !== hash(args.payload) || proof.counter <= args.signCount) throw Error('bad'); return { signCount: proof.counter }; },
    sendAPNs: async (request) => { calls.push(request); return options.provider ? options.provider(request) : { status: 200, reason: 'Accepted', apnsId: randomUUID() }; },
  };
  let relay = createRelay(cfg);
  let counter = 0;
  const installation = randomUUID();
  const gateway = generateKeyPairSync('ed25519');
  const publicKey = gateway.publicKey.export({ format: 'jwk' }).x;
  const deviceId = hash(Buffer.from(publicKey, 'base64url'));
  const rawCall = (path, body, headers = {}) => relay.dispatch({ method: 'POST', path: `/v1/push/${path}`, raw: JSON.stringify(body), headers, ip: 'fixture' });
  async function proof(payload, keyId = 'fixture-key') {
    const challenge = await rawCall('challenge', {});
    const bytes = JSON.stringify({ challengeId: challenge.challengeId, ...payload });
    return { keyId, attestationObject: b64('valid-attestation'), assertion: b64({ counter: ++counter, digest: hash(bytes) }), signedPayloadBase64: b64(bytes) };
  }
  const registrationPayload = () => ({ installationId: installation, bundleId: 'com.besttechie.cast', environment: 'production', apnsToken: 'ab'.repeat(32), gateway: { deviceId, publicKey } });
  const register = async (changes = {}, keyId) => rawCall('register', await proof({ ...registrationPayload(), ...changes }, keyId));
  function sendBody(reg, changes = {}) {
    const o = { kind: 'task.completed', notificationKind: 'reminder.due', gatewayDeviceId: deviceId, workspaceId: 'workspace', sessionKey: 'agent:main:session', runId: 'reminder:run-1' };
    return { relayHandle: reg.relayHandle, pushType: 'alert', priority: 10,
      payload: { aps: { alert: { title: 'Cast reminder', body: 'Your reminder is ready. Tap to view.' }, sound: 'default' }, openclaw: o },
      idempotencyKey: hash([deviceId, reg.relayHandle, o.workspaceId, o.sessionKey, o.runId].join('\n')), expiresAt: Math.floor(timestamp / 1000) + 86400, ...changes };
  }
  function headers(reg, raw, overrides = {}) {
    const signedAt = String(timestamp);
    return { authorization: `Bearer ${reg.sendGrant}`, 'x-openclaw-gateway-device-id': deviceId,
      'x-openclaw-gateway-signed-at-ms': signedAt,
      'x-openclaw-gateway-signature': sign(null, Buffer.from(`openclaw-relay-send-v1\n${deviceId}\n${signedAt}\n${raw}`), gateway.privateKey).toString('base64url'), ...overrides };
  }
  const send = (reg, body = sendBody(reg), overrides) => relay.dispatch({ method: 'POST', path: '/v1/push/send', raw: JSON.stringify(body), headers: headers(reg, JSON.stringify(body), overrides), ip: 'fixture' });
  return { get relay() { return relay; }, calls, verifierCalls, proof, rawCall, register, registrationPayload, sendBody, headers, send, installation,
    advance: (ms) => { timestamp += ms; }, restart: () => { relay.close(); relay = createRelay(cfg); }, close: () => { relay.close(); rmSync(dir, { recursive: true, force: true }); } };
}
async function rejects(promise, code) { await assert.rejects(promise, (e) => e.code === code); }

test('production registration and signed gateway reminder preserve source and expiry', async (t) => {
  const f = fixture(); t.after(f.close);
  const reg = await f.register();
  assert.equal(reg.status, 'registered'); assert.equal(reg.tokenSuffix, 'ababab');
  assert.equal(f.verifierCalls[0].allowDevelopmentEnvironment, false);
  assert.equal(f.verifierCalls[0].teamIdentifier, '2Q694P9U2Y');
  const body = f.sendBody(reg), result = await f.send(reg, body);
  assert.equal(result.ok, true); assert.equal(result.status, 200);
  assert.deepEqual(f.calls[0].payload, body.payload);
  assert.equal(f.calls[0].expiresAt, body.expiresAt * 1000);
  assert.equal(f.calls[0].environment, 'production');
});

test('real verifier rejects forged attestation; no development fallback', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'cast-relay-real-verifier-'));
  const relay = createRelay({ dbPath: join(dir, 'db'), sendAPNs: () => assert.fail('must not send') });
  t.after(() => { relay.close(); rmSync(dir, { recursive: true, force: true }); });
  const c = await relay.dispatch({ method: 'POST', path: '/v1/push/challenge', raw: '{}' });
  await rejects(relay.dispatch({ method: 'POST', path: '/v1/push/register', raw: JSON.stringify({ keyId: 'forged', attestationObject: b64('forged'), assertion: b64('forged'), signedPayloadBase64: b64({ challengeId: c.challengeId }) }) }), 'InvalidProof');
});

test('single-use challenge, signed bytes and monotonic counter reject replay and mutation', async (t) => {
  const f = fixture(); t.after(f.close);
  const proof = await f.proof(f.registrationPayload());
  await f.rawCall('register', proof);
  await rejects(f.rawCall('register', proof), 'InvalidChallenge');
  const next = await f.proof(f.registrationPayload());
  next.signedPayloadBase64 = b64({ ...JSON.parse(Buffer.from(next.signedPayloadBase64, 'base64')), environment: 'sandbox' });
  await rejects(f.rawCall('register', next), 'InvalidProof');
  const oldCounter = await f.proof(f.registrationPayload());
  const bytes = Buffer.from(oldCounter.signedPayloadBase64, 'base64');
  oldCounter.assertion = b64({ counter: 1, digest: hash(bytes) });
  await rejects(f.rawCall('register', oldCounter), 'InvalidProof');
});

test('concurrent same assertion creates only one binding; cross-install key migration fails', async (t) => {
  const f = fixture(); t.after(f.close);
  const proof = await f.proof(f.registrationPayload());
  const results = await Promise.allSettled([f.rawCall('register', proof), f.rawCall('register', proof)]);
  assert.equal(results.filter((v) => v.status === 'fulfilled').length, 1);
  await rejects(f.register({ installationId: randomUUID() }), 'InstallationMismatch');
});

test('re-registration revokes old capability, explicit revoke is owner-only and persists', async (t) => {
  const f = fixture(); t.after(f.close);
  const first = await f.register(); const second = await f.register();
  await rejects(f.send(first), 'RegistrationUnavailable');
  await f.register({}, 'another-key');
  await rejects(f.rawCall('revoke', await f.proof({ action: 'revoke', relayHandle: second.relayHandle }, 'another-key')), 'RegistrationNotOwned');
  await f.rawCall('revoke', await f.proof({ action: 'revoke', relayHandle: second.relayHandle }));
  f.restart();
  await rejects(f.send(second), 'RegistrationUnavailable');
  assert.equal(f.calls.length, 0);
});

test('gateway grant/signature/body/timestamp and routing binding are enforced', async (t) => {
  const f = fixture(); t.after(f.close); const reg = await f.register();
  await rejects(f.send(reg, undefined, { authorization: `Bearer ${'x'.repeat(43)}` }), 'Unauthorized');
  await rejects(f.send(reg, undefined, { 'x-openclaw-gateway-device-id': 'a'.repeat(64) }), 'InvalidSignature');
  await rejects(f.send(reg, undefined, { 'x-openclaw-gateway-signed-at-ms': '1700000000000' }), 'InvalidSignature');
  const body = f.sendBody(reg); const raw = JSON.stringify(body); body.priority = 5;
  await rejects(f.relay.dispatch({ method: 'POST', path: '/v1/push/send', raw: JSON.stringify(body), headers: f.headers(reg, raw) }), 'InvalidSignature');
  const wrong = f.sendBody(reg); wrong.payload.openclaw.gatewayDeviceId = 'b'.repeat(64);
  await rejects(f.send(reg, wrong), 'InvalidPayload'); assert.equal(f.calls.length, 0);
});

test('no arbitrary APS, text, expiry, or topic accepted', async (t) => {
  const f = fixture(); t.after(f.close); const reg = await f.register();
  for (const mutate of [
    b => { b.payload.aps.alert.body = 'advertisement'; },
    b => { b.payload.aps.badge = 42; },
    b => { b.topic = 'com.other.app'; },
    b => { b.expiresAt = 0; },
    b => { b.expiresAt += 2; },
    b => { b.payload.openclaw.notificationKind = 'unknown'; },
  ]) { const b = f.sendBody(reg); mutate(b); await assert.rejects(f.send(reg, b)); }
  assert.equal(f.calls.length, 0);
});

test('idempotency persists across restarts; same key/different body conflicts', async (t) => {
  const f = fixture(); t.after(f.close); const reg = await f.register(); const body = f.sendBody(reg);
  const first = await f.send(reg, body); f.restart();
  assert.deepEqual(await f.send(reg, body), first); assert.equal(f.calls.length, 1);
  await rejects(f.send(reg, { ...body, expiresAt: body.expiresAt - 10 }), 'IdempotencyConflict');
});

test('unknown provider outcome retains claim and never blindly retries', async (t) => {
  const f = fixture({ provider: async () => { throw Error('connection reset after delivery'); } }); t.after(f.close);
  const reg = await f.register(); const result = await f.send(reg);
  assert.equal(result.status, 0); assert.equal(result.ok, false);
  f.restart(); assert.deepEqual(await f.send(reg), result); assert.equal(f.calls.length, 1);
});

test('concurrent send returns pending, provider410 disables registration', async (t) => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const f = fixture({ provider: async () => { await gate; return { status: 410, reason: 'Unregistered' }; } }); t.after(f.close);
  const reg = await f.register(); const first = f.send(reg);
  const duplicate = await f.send(reg); assert.equal(duplicate.status, 0);
  release(); assert.equal((await first).status, 410);
  await rejects(f.send(reg), 'RegistrationUnavailable'); assert.equal(f.calls.length, 1);
});

test('expired challenge and expired registration fail closed', async (t) => {
  const f = fixture(); t.after(f.close); const proof = await f.proof(f.registrationPayload());
  f.advance(300001); await rejects(f.rawCall('register', proof), 'InvalidChallenge');
  const reg = await f.register(); f.advance(91 * 86400000);
  await rejects(f.send(reg), 'RegistrationUnavailable'); assert.equal(f.calls.length, 0);
});

test('challenge rate is bounded', async (t) => {
  const f = fixture(); t.after(f.close);
  for (let i = 0; i < 30; i++) await f.rawCall('challenge', {});
  await rejects(f.rawCall('challenge', {}), 'RateLimited');
});

test('HTTP interface rejects content type, oversized body, unknown path and returns secret-free errors', async (t) => {
  const f = fixture(); const server = createServer(httpHandler(f.relay));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); f.close(); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const health = await fetch(origin + '/healthz'); assert.equal(health.status, 200);
  const noType = await fetch(origin + '/v1/push/challenge', { method: 'POST', body: '{}' }); assert.equal(noType.status, 415);
  const large = await fetch(origin + '/v1/push/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: ' '.repeat(32769) }); assert.equal(large.status, 413);
  const missing = await fetch(origin + '/private'); assert.equal(missing.status, 404);
  assert.deepEqual(await missing.json(), { error: 'NotFound' });
  const challenge = await fetch(origin + '/v1/push/challenge', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }); assert.equal(challenge.status, 200);
  assert.equal(typeof (await challenge.json()).challenge, 'string');
});

test('real HTTP end-to-end protocol accepts AppAttest boundary proof and gateway Ed25519 signature', async (t) => {
  const f = fixture(); const server = createServer(httpHandler(f.relay));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); f.close(); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const regResp = await fetch(origin + '/v1/push/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(await f.proof(f.registrationPayload())) });
  assert.equal(regResp.status, 200); const reg = await regResp.json();
  const body = JSON.stringify(f.sendBody(reg));
  const sendResp = await fetch(origin + '/v1/push/send', { method: 'POST', headers: { 'content-type': 'application/json', ...f.headers(reg, body) }, body });
  assert.equal(sendResp.status, 200); assert.equal((await sendResp.json()).ok, true); assert.equal(f.calls.length, 1);
});

test('local expiry at dispatch is not APNs410 and does not revoke the registration', async (t) => {
  let count = 0;
  const f = fixture({ provider: async () => ++count === 1 ? { status: 400, reason: 'Expired' } : { status: 200, reason: 'Accepted' } }); t.after(f.close);
  const reg = await f.register(); const first = await f.send(reg);
  assert.equal(first.status, 400); assert.equal(first.reason, 'Expired');
  const next = f.sendBody(reg); next.payload.openclaw.runId = 'reminder:next';
  const o = next.payload.openclaw;
  next.idempotencyKey = hash([o.gatewayDeviceId, reg.relayHandle, o.workspaceId, o.sessionKey, o.runId].join('\n'));
  assert.equal((await f.send(reg, next)).ok, true); assert.equal(f.calls.length, 2);
});

test('forged forwarded-address headers cannot evade shared HTTP challenge limit', async (t) => {
  const f = fixture(); const server = createServer(httpHandler(f.relay));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); f.close(); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  for (let i = 0; i < 31; i++) {
    const response = await fetch(origin + '/v1/push/challenge', { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': `203.0.113.${i}` }, body: '{}' });
    assert.equal(response.status, i === 30 ? 429 : 200);
  }
});

test('HTTP expired/revoked handle is a structured definitive registration failure', async (t) => {
  const f = fixture(); const server = createServer(httpHandler(f.relay));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); f.close(); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const reg = await f.register(); await f.rawCall('revoke', await f.proof({ action: 'revoke', relayHandle: reg.relayHandle }));
  const body = JSON.stringify(f.sendBody(reg));
  const response = await fetch(origin + '/v1/push/send', { method: 'POST', headers: { 'content-type': 'application/json', ...f.headers(reg, body) }, body });
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { ok: false, status: 401, reason: 'RegistrationUnavailable', environment: 'production' });
  assert.equal(f.calls.length, 0);
});

test('public enrollment flood cannot exhaust signed-send or preissued valid-revocation quotas', async (t) => {
  const f = fixture(); t.after(f.close); const reg = await f.register();
  const revokeProof = await f.proof({ action: 'revoke', relayHandle: reg.relayHandle });
  for (let i = 0; i < 140; i++) { try { await f.rawCall('challenge', {}); } catch {} }
  assert.equal((await f.send(reg)).ok, true);
  assert.deepEqual(await f.rawCall('revoke', revokeProof), { revoked: true });
});
