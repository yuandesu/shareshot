'use strict';

const http   = require('http');
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const url    = require('url');

const { S3Client, PutObjectCommand, GetObjectCommand,
        DeleteObjectCommand, ListObjectsV2Command } = require('@aws-sdk/client-s3');

// ── Config ─────────────────────────────────────────────────────────────────
const PORT       = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, 'public');
const S3_BUCKET  = process.env.S3_BUCKET;
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';

if (!S3_BUCKET) throw new Error('S3_BUCKET env var required');

// ── S3 ─────────────────────────────────────────────────────────────────────
const s3 = new S3Client({ region: AWS_REGION });

async function s3Put(key, body, contentType) {
  await s3.send(new PutObjectCommand({ Bucket: S3_BUCKET, Key: key, Body: body, ContentType: contentType }));
}

async function s3Get(key) {
  const r = await s3.send(new GetObjectCommand({ Bucket: S3_BUCKET, Key: key }));
  const chunks = [];
  for await (const chunk of r.Body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function s3Del(key) {
  await s3.send(new DeleteObjectCommand({ Bucket: S3_BUCKET, Key: key }));
}

async function s3List(prefix) {
  const r = await s3.send(new ListObjectsV2Command({ Bucket: S3_BUCKET, Prefix: prefix }));
  return (r.Contents || []).map(o => o.Key);
}

// ── Collections ─────────────────────────────────────────────────────────────
const colKey = id => `collections/${id}.json`;

async function readCol(id) {
  try { return JSON.parse((await s3Get(colKey(id))).toString()); }
  catch { return null; }
}

async function writeCol(proj) {
  await s3Put(colKey(proj.id), JSON.stringify(proj, null, 2), 'application/json');
}

async function listAllCols() {
  const keys = await s3List('collections/');
  const all  = await Promise.all(keys.map(async k => {
    try { return JSON.parse((await s3Get(k)).toString()); }
    catch { return null; }
  }));
  return all
    .filter(Boolean)
    .sort((a, b) => new Date(b.updatedAt || b.createdAt) - new Date(a.updatedAt || a.createdAt));
}

// ── Permissions ─────────────────────────────────────────────────────────────
// No token → full owner access.
// Token present → role from shareTokens, or null if token invalid.
function getRole(proj, token) {
  if (!proj) return null;
  if (!token) return 'owner';
  if (proj.shareTokens) {
    if (proj.shareTokens.editor    === token) return 'editor';
    if (proj.shareTokens.commenter === token) return 'commenter';
    if (proj.shareTokens.viewer    === token) return 'viewer';
  }
  return null;
}

// ── HTTP utils ──────────────────────────────────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js':  'application/javascript',
  '.css':  'text/css',                 '.png':  'image/png',
  '.jpg':  'image/jpeg',               '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',             '.json': 'application/json',
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString()));
    req.on('error', reject);
  });
}

function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function parseQuery(raw) {
  const r = {};
  if (!raw) return r;
  for (const p of raw.split('&')) {
    const [k, ...v] = p.split('=');
    if (k) r[decodeURIComponent(k)] = decodeURIComponent(v.join('='));
  }
  return r;
}

function serveFile(res, filePath) {
  const resolved = path.resolve(filePath);
  if (!resolved.startsWith(path.resolve(PUBLIC_DIR))) {
    res.writeHead(403); res.end(); return;
  }
  fs.stat(resolved, (err, stat) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    const mime = MIME[path.extname(resolved).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': mime, 'Content-Length': stat.size });
    fs.createReadStream(resolved).pipe(res);
  });
}

function uuid() { return crypto.randomUUID(); }
function now()  { return new Date().toISOString(); }

// ── Server ─────────────────────────────────────────────────────────────────
http.createServer(async (req, res) => {
  const { pathname, query: rawQuery } = url.parse(req.url);
  const query  = parseQuery(rawQuery);
  const method = req.method;

  try {

    // ── Images: upload ──────────────────────────────────────────────────────
    if (method === 'POST' && pathname === '/api/images') {
      const body = JSON.parse(await readBody(req));
      // Token-access users must be editor or commenter
      if (query.token) {
        const proj = body.projectId ? await readCol(body.projectId) : null;
        const role = getRole(proj, query.token);
        if (!['owner', 'editor', 'commenter'].includes(role))
          return json(res, 403, { error: 'Forbidden' });
      }
      const id  = uuid();
      const buf = Buffer.from(body.dataUrl.replace(/^data:image\/\w+;base64,/, ''), 'base64');
      await s3Put(`uploads/${id}.png`, buf, 'image/png');
      return json(res, 200, { id, url: `/images/${id}.png` });
    }

    // ── Images: serve ───────────────────────────────────────────────────────
    const imgMatch = pathname.match(/^\/images\/([a-f0-9-]{36}\.png)$/);
    if (method === 'GET' && imgMatch) {
      try {
        const buf = await s3Get(`uploads/${imgMatch[1]}`);
        res.writeHead(200, {
          'Content-Type': 'image/png',
          'Content-Length': buf.length,
          'Cache-Control': 'public, max-age=31536000, immutable',
        });
        res.end(buf);
      } catch { res.writeHead(404); res.end('Not found'); }
      return;
    }

    // ── Projects: list ──────────────────────────────────────────────────────
    if (method === 'GET' && pathname === '/api/projects') {
      return json(res, 200, await listAllCols());
    }

    // ── Projects: create ────────────────────────────────────────────────────
    if (method === 'POST' && pathname === '/api/projects') {
      const body = JSON.parse(await readBody(req));
      const proj = {
        id: uuid(), title: body.title || 'Untitled',
        sharedImageId: null, canvasData: null,
        shareTokens: { viewer: null, commenter: null, editor: null },
        createdAt: now(), updatedAt: now(),
      };
      await writeCol(proj);
      return json(res, 200, proj);
    }

    // ── Projects: get / put / delete ────────────────────────────────────────
    const projMatch = pathname.match(/^\/api\/projects\/([^/]+)$/);
    if (projMatch) {
      const proj = await readCol(projMatch[1]);
      if (!proj) return json(res, 404, { error: 'Not found' });
      const role = getRole(proj, query.token || null);
      if (!role) return json(res, 403, { error: 'Access denied' });

      if (method === 'GET') {
        // Strip shareTokens from token-based access (don't let viewers enumerate tokens)
        const resp = role === 'owner'
          ? { ...proj, role }
          : { id: proj.id, title: proj.title, sharedImageId: proj.sharedImageId,
              canvasData: proj.canvasData, createdAt: proj.createdAt, updatedAt: proj.updatedAt, role };
        return json(res, 200, resp);
      }

      if (method === 'PUT') {
        if (!['owner', 'editor', 'commenter'].includes(role)) return json(res, 403, { error: 'Forbidden' });
        const body = JSON.parse(await readBody(req));
        delete body.shareTokens; delete body.id;
        if (role === 'commenter') delete body.title;
        const updated = { ...proj, ...body, id: proj.id, shareTokens: proj.shareTokens, updatedAt: now() };
        await writeCol(updated);
        return json(res, 200, updated);
      }

      if (method === 'DELETE') {
        if (role !== 'owner') return json(res, 403, { error: 'Forbidden' });
        await s3Del(colKey(proj.id));
        if (proj.sharedImageId) await s3Del(`uploads/${proj.sharedImageId}.png`).catch(() => {});
        return json(res, 200, { ok: true });
      }
    }

    // ── Share tokens: generate ──────────────────────────────────────────────
    const tokGenMatch = pathname.match(/^\/api\/projects\/([^/]+)\/tokens$/);
    if (method === 'POST' && tokGenMatch) {
      const proj = await readCol(tokGenMatch[1]);
      if (!proj) return json(res, 404, { error: 'Not found' });
      if (getRole(proj, query.token || null) !== 'owner') return json(res, 403, { error: 'Forbidden' });
      const { role } = JSON.parse(await readBody(req));
      if (!['viewer', 'commenter', 'editor'].includes(role)) return json(res, 400, { error: 'Invalid role' });
      proj.shareTokens[role] = uuid();
      proj.updatedAt = now();
      await writeCol(proj);
      return json(res, 200, { token: proj.shareTokens[role], role });
    }

    // ── Share tokens: revoke ────────────────────────────────────────────────
    const tokDelMatch = pathname.match(/^\/api\/projects\/([^/]+)\/tokens\/([^/]+)$/);
    if (method === 'DELETE' && tokDelMatch) {
      const proj = await readCol(tokDelMatch[1]);
      if (!proj) return json(res, 404, { error: 'Not found' });
      if (getRole(proj, query.token || null) !== 'owner') return json(res, 403, { error: 'Forbidden' });
      const role = tokDelMatch[2];
      if (!['viewer', 'commenter', 'editor'].includes(role)) return json(res, 400, { error: 'Invalid role' });
      proj.shareTokens[role] = null;
      proj.updatedAt = now();
      await writeCol(proj);
      return json(res, 200, { ok: true });
    }

    // ── SPA page routes ─────────────────────────────────────────────────────
    if (method === 'GET' && pathname.match(/^\/canvas\/[^/]+$/))
      return serveFile(res, path.join(PUBLIC_DIR, 'canvas.html'));
    if (method === 'GET' && pathname.match(/^\/view\/[^/]+$/))
      return serveFile(res, path.join(PUBLIC_DIR, 'viewer.html'));

    // ── Static assets ───────────────────────────────────────────────────────
    if (method === 'GET')
      return serveFile(res, path.join(PUBLIC_DIR, pathname === '/' ? 'index.html' : pathname));

    res.writeHead(404); res.end('Not found');

  } catch (e) {
    console.error(e);
    json(res, 500, { error: e.message });
  }
}).listen(PORT, () => console.log(`ShareShot → http://localhost:${PORT}`));
