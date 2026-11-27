import http2 from 'node:http2';
import { createHash, createPrivateKey, sign } from 'node:crypto';

export const TOPIC = 'com.besttechie.cast';
export const TEAM = '2Q694P9U2Y';
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

// The provider credential never leaves this process. Do not log requests or device tokens.
export function createAPNsSender({ keyID, privateKey, now = Date.now, connect = http2.connect }) {
  if (!/^[A-Z0-9]{10}$/.test(keyID)) throw new Error('Invalid APNs key ID');
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new Error('APNs requires a P-256 key');
  }
  let cached;
  function jwt() {
    const issued = Math.floor(now() / 1000);
    if (cached && issued - cached.issued < 3000) return cached.token;
    const unsigned = `${b64({ alg: 'ES256', kid: keyID })}.${b64({ iss: TEAM, iat: issued })}`;
    const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    cached = { issued, token: `${unsigned}.${signature}` };
    return cached.token;
  }
  return async function send({ token, environment, payload, expiresAt, collapseID }) {
    if (!/^[a-f0-9]{32,512}$/i.test(token)) throw new Error('Invalid APNs device token');
    if (!['production', 'sandbox'].includes(environment)) throw new Error('Invalid APNs environment');
    const expiration = Math.floor(expiresAt / 1000);
    if (!Number.isSafeInteger(expiration) || (expiration !== 0 && expiration <= Math.floor(now() / 1000))) return { status: 400, reason: 'Expired' };
    const digest = createHash('sha256').update(collapseID).digest('hex');
    const apnsRequestID = `${digest.slice(0, 8)}-${digest.slice(8, 12)}-5${digest.slice(13, 16)}-${((parseInt(digest[16], 16) & 3) | 8).toString(16)}${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
    const data = JSON.stringify(payload);
    if (Buffer.byteLength(data) > 4096) throw new Error('APNs payload exceeds limit');
    const origin = environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
    return await new Promise((resolve) => {
      let done = false;
      let session;
      const finish = (value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        session?.destroy();
        resolve(value);
      };
      const timer = setTimeout(() => finish({ status: 0, reason: 'OutcomeUnknown' }), 10000);
      try {
        session = connect(origin);
        session.on('error', () => finish({ status: 0, reason: 'OutcomeUnknown' }));
        const req = session.request({
          ':method': 'POST', ':path': `/3/device/${token}`,
          authorization: `bearer ${jwt()}`, 'apns-topic': TOPIC,
          'apns-push-type': 'alert', 'apns-priority': '10',
          'apns-expiration': String(expiration),
          'apns-collapse-id': digest, 'apns-id': apnsRequestID,
          'content-type': 'application/json',
        });
        let status = 0;
        let apnsId;
        let body = '';
        req.on('response', (headers) => { status = Number(headers[':status']); apnsId = headers['apns-id']; });
        req.on('data', (chunk) => { if (body.length < 4096) body += chunk; });
        req.on('error', () => finish({ status: 0, reason: 'OutcomeUnknown' }));
        req.on('end', () => {
          let reason = status === 200 ? 'Accepted' : 'ProviderRejected';
          try { const parsed = JSON.parse(body); if (typeof parsed.reason === 'string' && /^[A-Za-z]{1,80}$/.test(parsed.reason)) reason = parsed.reason; } catch {}
          finish({ status, reason, ...(typeof apnsId === 'string' ? { apnsId } : {}) });
        });
        req.end(data);
      } catch { finish({ status: 0, reason: 'OutcomeUnknown' }); }
    });
  };
}
