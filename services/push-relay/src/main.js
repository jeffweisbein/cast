import { createServer } from 'node:http';
import { chmodSync, lstatSync, mkdirSync, readFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { createAPNsSender } from './apns.js';
import { createRelay, httpHandler } from './relay.js';

process.umask(0o077);
const stateDirectory = process.env.CAST_RELAY_STATE_DIR;
const keyPath = process.env.CAST_APNS_KEY_PATH;
const keyID = process.env.CAST_APNS_KEY_ID;
if (!stateDirectory || !isAbsolute(stateDirectory) || !keyPath || !isAbsolute(keyPath) || !keyID) {
  throw new Error('Set absolute CAST_RELAY_STATE_DIR, CAST_APNS_KEY_PATH and CAST_APNS_KEY_ID');
}
function privatePath(path, directory = false) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) || (stat.mode & 0o077) !== 0 || stat.uid !== process.getuid()) {
    throw new Error('Relay state and provider credential must be owner-only, owned by the service user, and not symlinks');
  }
}
mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
privatePath(stateDirectory, true);
privatePath(keyPath);
const sender = createAPNsSender({ keyID, privateKey: readFileSync(keyPath) });
const dbPath = join(stateDirectory, 'relay.sqlite');
try { privatePath(dbPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
const relay = createRelay({ dbPath, sendAPNs: sender });
chmodSync(dbPath, 0o600);
const handler = httpHandler(relay);
let active = 0;
const server = createServer((req, res) => {
  if (active >= 128) { res.writeHead(503, { 'content-type': 'application/json' }).end('{"error":"Capacity"}'); return; }
  active++;
  res.once('close', () => { active--; });
  void handler(req, res);
});
server.requestTimeout = 10000;
server.headersTimeout = 5000;
server.keepAliveTimeout = 5000;
server.maxConnections = 128;
server.listen(19890, '127.0.0.1', () => console.log('Cast push relay listening on loopback19890'));
let closing = false;
function shutdown() {
  if (closing) return;
  closing = true;
  server.close(() => { relay.close(); process.exit(0); });
  setTimeout(() => process.exit(1), 15000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
