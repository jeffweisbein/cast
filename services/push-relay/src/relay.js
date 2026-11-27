import { DatabaseSync } from 'node:sqlite';
import { createHash, createPublicKey, randomBytes, randomUUID, timingSafeEqual, verify } from 'node:crypto';
import { verifyAttestation, verifyAssertion } from 'node-app-attest';
import { TOPIC, TEAM } from './apns.js';

const DAY = 86400000;
const hash = (v) => createHash('sha256').update(v).digest('hex');
const opaque = () => randomBytes(32).toString('base64url');
const fail = (status, code) => { throw Object.assign(new Error(code), { status, code }); };
const object = (v) => v && typeof v === 'object' && !Array.isArray(v);
const exact = (v, required, optional = []) => object(v) && required.every((k) => Object.hasOwn(v, k)) && Object.keys(v).every((k) => [...required, ...optional].includes(k));
const bounded = (v, max = 512) => typeof v === 'string' && v.length > 0 && v.length <= max && !/[\x00-\x1f\x7f]/.test(v);
const uuid = (v) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function base64(v, max = 24000) {
  if (typeof v !== 'string' || v.length === 0 || v.length > max || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(v)) fail(400, 'InvalidProof');
  return Buffer.from(v, 'base64');
}
function parse(v) { try { return JSON.parse(v); } catch { fail(400, 'InvalidJSON'); } }

export function createRelay({ dbPath, sendAPNs, now = Date.now, attestationVerifier = verifyAttestation, assertionVerifier = verifyAssertion }) {
  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000; PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY, value TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS keys(id TEXT PRIMARY KEY, public_key TEXT NOT NULL, counter INTEGER NOT NULL, installation TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS registrations(handle TEXT PRIMARY KEY, key_id TEXT NOT NULL REFERENCES keys(id), installation TEXT NOT NULL, gateway TEXT NOT NULL, public_key TEXT NOT NULL, token TEXT NOT NULL, grant_hash TEXT NOT NULL, expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS reg_binding ON registrations(key_id, installation, gateway);
    CREATE TABLE IF NOT EXISTS deliveries(handle TEXT NOT NULL REFERENCES registrations(handle), event TEXT NOT NULL, request_hash TEXT NOT NULL, result TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(handle,event));
    CREATE TABLE IF NOT EXISTS rates(bucket TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL);`);
  let inFlight = 0;
  let nextPrune = 0;
  const get = (sql, ...args) => db.prepare(sql).get(...args);
  const run = (sql, ...args) => db.prepare(sql).run(...args);
  function transaction(fn) { db.exec('BEGIN IMMEDIATE'); try { const result = fn(); db.exec('COMMIT'); return result; } catch (error) { db.exec('ROLLBACK'); throw error; } }
  function prune() {
    if (now() < nextPrune) return;
    transaction(() => {
      run('DELETE FROM challenges WHERE expires<=?', now());
      run('DELETE FROM rates WHERE expires<=?', now());
      run('DELETE FROM deliveries WHERE handle IN (SELECT handle FROM registrations WHERE expires<=?)', now());
      run('DELETE FROM registrations WHERE expires<=?', now());
    });
    nextPrune = now() + 60000;
  }
  function rate(subject, limit, duration = 60000) {
    const bucket = hash(subject) + ':' + Math.floor(now() / duration);
    const old = get('SELECT count FROM rates WHERE bucket=?', bucket);
    if (old?.count >= limit) fail(429, 'RateLimited');
    if (!old && get('SELECT COUNT(*) AS n FROM rates').n >= 20000) fail(503, 'Capacity');
    run('INSERT INTO rates VALUES(?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=count+1', bucket, now() + duration);
  }
  function capacity(table, limit) { if (get(`SELECT COUNT(*) AS n FROM ${table}`).n >= limit) fail(503, 'Capacity'); }
  function appProof(body) {
    if (!exact(body, ['keyId', 'assertion', 'signedPayloadBase64'], ['attestationObject']) || !bounded(body.keyId, 128)) fail(400, 'InvalidProof');
    const bytes = base64(body.signedPayloadBase64, 16000);
    const payload = parse(bytes.toString('utf8'));
    if (!object(payload) || !bounded(payload.challengeId, 64)) fail(400, 'InvalidProof');
    const challenge = get('SELECT * FROM challenges WHERE id=?', payload.challengeId);
    if (!challenge || challenge.expires <= now()) fail(401, 'InvalidChallenge');
    const existing = get('SELECT * FROM keys WHERE id=?', body.keyId);
    let publicKey = existing?.public_key;
    try {
      if (!existing) {
        const attested = attestationVerifier({ attestation: base64(body.attestationObject), challenge: challenge.value, keyId: body.keyId, bundleIdentifier: TOPIC, teamIdentifier: TEAM, allowDevelopmentEnvironment: false });
        publicKey = attested.publicKey;
        if (attested.keyId && attested.keyId !== body.keyId) fail(401, 'InvalidProof');
      } else if (body.attestationObject !== undefined) {
        // An already known key does not need re-attestation; assertions still prove ownership.
        base64(body.attestationObject);
      }
      const asserted = assertionVerifier({ assertion: base64(body.assertion), payload: bytes, publicKey, bundleIdentifier: TOPIC, teamIdentifier: TEAM, signCount: existing?.counter ?? 0 });
      if (!Number.isSafeInteger(asserted.signCount) || asserted.signCount <= (existing?.counter ?? 0)) fail(401, 'InvalidProof');
      return { payload, keyID: body.keyId, publicKey, existing, counter: asserted.signCount };
    } catch { fail(401, 'InvalidProof'); }
  }
  function consume(proof, installation) {
    if (proof.existing) {
      if (proof.existing.installation !== installation) fail(403, 'InstallationMismatch');
      run('UPDATE keys SET counter=? WHERE id=?', proof.counter, proof.keyID);
    } else {
      capacity('keys', 10000);
      run('INSERT INTO keys VALUES(?,?,?,?)', proof.keyID, proof.publicKey, proof.counter, installation);
    }
    run('DELETE FROM challenges WHERE id=?', proof.payload.challengeId);
  }
  function register(body) {
    return transaction(() => {
      const proof = appProof(body);
      const p = proof.payload;
      if (!exact(p, ['challengeId', 'installationId', 'bundleId', 'environment', 'apnsToken', 'gateway']) || !uuid(p.installationId) || p.bundleId !== TOPIC || p.environment !== 'production' || typeof p.apnsToken !== 'string' || !/^[a-f0-9]{32,512}$/i.test(p.apnsToken) || !exact(p.gateway, ['deviceId', 'publicKey']) || !/^[a-f0-9]{64}$/.test(p.gateway.deviceId) || !/^[A-Za-z0-9_-]{43}$/.test(p.gateway.publicKey)) fail(400, 'InvalidRegistration');
      const gatewayBytes = Buffer.from(p.gateway.publicKey, 'base64url');
      if (gatewayBytes.length !== 32 || hash(gatewayBytes) !== p.gateway.deviceId) fail(400, 'InvalidGateway');
      // A reinstall uses a new installation ID; existing attest keys cannot migrate silently.
      consume(proof, p.installationId);
      rate(`register-key:${proof.keyID}`, 20, DAY);
      capacity('registrations', 50000);
      run('UPDATE registrations SET revoked=1 WHERE key_id=? AND installation=? AND gateway=?', proof.keyID, p.installationId, p.gateway.deviceId);
      const relayHandle = opaque();
      const sendGrant = opaque();
      const expiresAtMs = now() + 90 * DAY;
      run('INSERT INTO registrations VALUES(?,?,?,?,?,?,?,?,0)', relayHandle, proof.keyID, p.installationId, p.gateway.deviceId, p.gateway.publicKey, p.apnsToken.toLowerCase(), hash(sendGrant), expiresAtMs);
      return { status: 'registered', relayHandle, sendGrant, expiresAtMs, tokenSuffix: p.apnsToken.slice(-6) };
    });
  }
  function revoke(body) {
    return transaction(() => {
      const proof = appProof(body);
      const p = proof.payload;
      if (!exact(p, ['challengeId', 'relayHandle', 'action']) || p.action !== 'revoke' || !bounded(p.relayHandle, 64)) fail(400, 'InvalidRevocation');
      const reg = get('SELECT * FROM registrations WHERE handle=?', p.relayHandle);
      if (!reg || reg.key_id !== proof.keyID) fail(403, 'RegistrationNotOwned');
      consume(proof, reg.installation);
      rate(`revoke-key:${proof.keyID}`, 30);
      run('UPDATE registrations SET revoked=1 WHERE handle=?', p.relayHandle);
      return { revoked: true };
    });
  }
  function validateSend(body, reg) {
    if (!exact(body, ['relayHandle', 'pushType', 'priority', 'payload', 'idempotencyKey', 'expiresAt']) || body.pushType !== 'alert' || body.priority !== 10 || !/^[a-f0-9]{64}$/.test(body.idempotencyKey) || !Number.isSafeInteger(body.expiresAt)) fail(400, 'InvalidSend');
    const p = body.payload;
    if (!exact(p, ['aps', 'openclaw']) || !exact(p.aps, ['alert', 'sound']) || !exact(p.aps.alert, ['title', 'body']) || p.aps.sound !== 'default' || !exact(p.openclaw, ['kind', 'gatewayDeviceId', 'workspaceId', 'sessionKey', 'runId'], ['notificationKind'])) fail(400, 'InvalidPayload');
    const o = p.openclaw;
    const reminder = o.notificationKind === 'reminder.due';
    if (o.kind !== 'task.completed' || (o.notificationKind !== undefined && !reminder) || o.gatewayDeviceId !== reg.gateway || !bounded(o.workspaceId, 128) || !bounded(o.sessionKey, 1024) || !bounded(o.runId, 512) || Buffer.byteLength(JSON.stringify(p)) > 4096) fail(400, 'InvalidPayload');
    if (p.aps.alert.title !== (reminder ? 'Cast reminder' : 'Cast task complete') || p.aps.alert.body !== (reminder ? 'Your reminder is ready. Tap to view.' : 'Your task is ready. Tap to return.')) fail(400, 'InvalidPayload');
    if (reminder ? body.expiresAt <= Math.floor(now() / 1000) || body.expiresAt > Math.floor(now() / 1000) + 86400 : body.expiresAt !== 0) fail(400, 'InvalidExpiration');
    const expectedID = hash([o.gatewayDeviceId, body.relayHandle, o.workspaceId, o.sessionKey, o.runId].join('\n'));
    if (body.idempotencyKey !== expectedID) fail(400, 'InvalidIdempotencyKey');
  }
  async function send(body, raw, headers) {
    if (!object(body) || !bounded(body.relayHandle, 64)) fail(400, 'InvalidSend');
    const reg = get('SELECT * FROM registrations WHERE handle=?', body.relayHandle);
    if (!reg || reg.revoked || reg.expires <= now()) fail(401, 'RegistrationUnavailable');
    const authorization = headers.authorization;
    const grant = typeof authorization === 'string' && /^Bearer ([A-Za-z0-9_-]{43})$/.exec(authorization)?.[1];
    if (!grant || !timingSafeEqual(Buffer.from(hash(grant)), Buffer.from(reg.grant_hash))) fail(401, 'Unauthorized');
    const signedAt = headers['x-openclaw-gateway-signed-at-ms'];
    const signature = headers['x-openclaw-gateway-signature'];
    if (headers['x-openclaw-gateway-device-id'] !== reg.gateway || typeof signedAt !== 'string' || !/^\d{13}$/.test(signedAt) || Math.abs(Number(signedAt) - now()) > 300000 || typeof signature !== 'string' || !/^[A-Za-z0-9_-]{86}$/.test(signature)) fail(401, 'InvalidSignature');
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: reg.public_key }, format: 'jwk' });
    if (!verify(null, Buffer.from(`openclaw-relay-send-v1\n${reg.gateway}\n${signedAt}\n${raw}`), key, Buffer.from(signature, 'base64url'))) fail(401, 'InvalidSignature');
    validateSend(body, reg);
    const requestHash = hash(raw);
    const old = get('SELECT * FROM deliveries WHERE handle=? AND event=?', reg.handle, body.idempotencyKey);
    if (old) {
      if (old.request_hash !== requestHash) fail(409, 'IdempotencyConflict');
      return JSON.parse(old.result);
    }
    rate(`send-registration:${reg.handle}`, 30);
    rate(`send-gateway:${reg.gateway}`, 120);
    if (inFlight >= 8) fail(503, 'Capacity');
    capacity('deliveries', 100000);
    const pending = { ok: false, status: 0, reason: 'OutcomeUnknown', environment: 'production' };
    run('INSERT INTO deliveries VALUES(?,?,?,?,?)', reg.handle, body.idempotencyKey, requestHash, JSON.stringify(pending), now());
    inFlight++;
    try {
      const current = get('SELECT revoked,expires FROM registrations WHERE handle=?', reg.handle);
      if (!current || current.revoked || current.expires <= now()) fail(401, 'RegistrationUnavailable');
      const apns = await sendAPNs({ token: reg.token, environment: 'production', payload: body.payload, expiresAt: body.expiresAt * 1000, collapseID: body.idempotencyKey });
      const result = { ok: apns.status === 200, status: apns.status, reason: apns.reason, environment: 'production' };
      if (apns.apnsId) result.apnsId = apns.apnsId;
      transaction(() => {
        run('UPDATE deliveries SET result=? WHERE handle=? AND event=?', JSON.stringify(result), reg.handle, body.idempotencyKey);
        if (apns.status === 410 || apns.reason === 'BadDeviceToken' || apns.reason === 'DeviceTokenNotForTopic') run('UPDATE registrations SET revoked=1 WHERE handle=?', reg.handle);
      });
      return result;
    } catch (error) {
      if (error.status) throw error;
      return pending; // The durable pre-I/O claim forbids blind retries after ambiguous outcomes.
    } finally { inFlight--; }
  }
  async function dispatch({ method, path, raw = '', headers = {}, ip = 'unknown' }) {
    prune();
    if (method === 'GET' && path === '/healthz') return { ok: true };
    if (method !== 'POST' || !['/v1/push/challenge', '/v1/push/register', '/v1/push/revoke', '/v1/push/send'].includes(path)) fail(404, 'NotFound');
    const limit = path.endsWith('/send') ? 8192 : path.endsWith('/challenge') ? 256 : 32768;
    if (Buffer.byteLength(raw) > limit) fail(413, 'BodyTooLarge');
    const body = parse(raw);
    // Public enrollment must not consume the authenticated notification quota.
    if (path.endsWith('/challenge')) {
      if (!exact(body, [])) fail(400, 'InvalidChallengeRequest');
      rate(`challenge:${ip}`, 30);
      capacity('challenges', 5000);
      const challengeId = opaque(), challenge = opaque(), expiresAtMs = now() + 300000;
      run('INSERT INTO challenges VALUES(?,?,?)', challengeId, challenge, expiresAtMs);
      return { challengeId, challenge, expiresAtMs };
    }
    if (path.endsWith('/register')) { rate(`register-ip:${ip}`, 30); return register(body); }
    if (path.endsWith('/revoke')) return revoke(body);
    return send(body, raw, headers);
  }
  return { dispatch, close: () => db.close() };
}

export function httpHandler(relay) {
  return async (req, res) => {
    res.setHeader('content-type', 'application/json');
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-content-type-options', 'nosniff');
    try {
      const path = req.url;
      const limit = path === '/v1/push/send' ? 8192 : path === '/v1/push/challenge' ? 256 : 32768;
      if (req.method === 'POST' && req.headers['content-type']?.split(';')[0].trim() !== 'application/json') fail(415, 'JSONRequired');
      let bytes = 0;
      const chunks = [];
      for await (const chunk of req) { bytes += chunk.length; if (bytes > limit) fail(413, 'BodyTooLarge'); chunks.push(chunk); }
      // Never trust client-controlled forwarding headers. Behind Funnel this is
      // intentionally a shared proxy bucket; signed identity limits add granularity.
      const ip = req.socket.remoteAddress || 'unknown';
      const result = await relay.dispatch({ method: req.method, path, raw: Buffer.concat(chunks).toString('utf8'), headers: req.headers, ip });
      res.writeHead(200).end(JSON.stringify(result));
    } catch (error) {
      const status = error.status ?? 500;
      const code = error.code ?? 'InternalError';
      const body = req.url === '/v1/push/send'
        ? { ok: false, status, reason: code, environment: 'production' }
        : { error: code };
      res.writeHead(status).end(JSON.stringify(body));
    }
  };
}
