// Adapt the web repo's existing synthetic fixtures to a real localhost server.
// UIKit and WKWebView are real; only account/relay data is mocked.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.resolve(process.argv[2]);
const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(web, 'package.json'));
const { buildSync } = require('esbuild');
const { WebSocketServer } = require('ws');
const modulePath = path.join(web, '.ios-mocks.cjs');
buildSync({ entryPoints: [path.join(web, 'screenshots/mocks.ts')], bundle: true,
  platform: 'node', format: 'cjs', outfile: modulePath });
const { setupMocks, overrideSettings } = require(modulePath);
const scripts = [];
let graphql, websocket;
await setupMocks({
  addInitScript(fn, arg) { scripts.push(`(${fn.toString()})(${JSON.stringify(arg) ?? ''});`); },
  route(pattern, handler) { if (pattern.source.includes('api')) graphql = handler; },
  routeWebSocket(_pattern, handler) { websocket = handler; },
});
const server = createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  try {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    const operation = body.operationName ?? body.query?.match(/(?:query|mutation)\s+(\w+)/)?.[1];
    console.log(req.method, req.url, operation);
    const fulfill = ({ status = 200, contentType = 'application/json', body }) => {
      res.writeHead(status, { 'Content-Type': contentType }); res.end(body);
    };
    if (operation === 'GetCollections') {
      fulfill({ body: JSON.stringify({ data: { collections: [] } }) }); return;
    }
    if (operation === 'GetSettings') overrideSettings({
      homeOrder: ['11111111-1111-1111-1111-111111111111'],
      lastView: { type: 'home', homeId: '11111111-1111-1111-1111-111111111111' },
    });
    await graphql({ request: () => ({ method: () => req.method, postDataJSON: () => body }),
      fulfill, fallback: () => fulfill({ body: '{"data":{}}' }) });
  } catch (error) { console.error(error); res.writeHead(500); res.end('{}'); }
});
new WebSocketServer({ server }).on('connection', socket => websocket({
  send: value => socket.send(value), onMessage: callback => socket.on('message', callback),
}));
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
scripts.unshift(`(() => {
  const nativeFetch = window.fetch.bind(window);
  const api = 'http://localhost:${port}';
  window.fetch = (input, options) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    if (url.hostname === 'api.homecast.cloud' || url.port === '8080')
      return nativeFetch(api + url.pathname + url.search, options);
    if (url.origin !== location.origin) return Promise.reject(new Error('External network disabled by iOS test'));
    return nativeFetch(input, options);
  };
  const NativeSocket = window.WebSocket;
  window.WebSocket = class extends NativeSocket {
    constructor(url, protocols) { super('ws://localhost:${port}/ws', protocols); }
  };
})();`);
const index = path.join(web, 'dist/index.html');
let html = fs.readFileSync(index, 'utf8');
html = html.replace(/<script id="ios-fixture">[\s\S]*?<\/script>/, '');
fs.writeFileSync(index, html.replace('<head>', `<head><script id="ios-fixture">${scripts.join('\n')}</script>`));
for (const name of ['header', 'status', 'room']) {
  const destination = path.join(web, 'dist/native', name, 'login');
  fs.mkdirSync(destination, { recursive: true });
  fs.copyFileSync(path.join(here, 'RecentFixtures', `${name}.html`), path.join(destination, 'index.html'));
}
console.log(`READY synthetic API port ${port}; web ${web}`);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
