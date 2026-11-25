import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_FILE = 'unicare-v2-complete-updated-v14.html';

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon'
};

function resolveSafePath(urlPathname) {
    const decoded = decodeURIComponent((urlPathname || '/').split('?')[0]);
    const requested = decoded === '/' ? DEFAULT_FILE : decoded.replace(/^\/+/, '');
    const candidate = path.resolve(ROOT_DIR, requested);
    if (!candidate.startsWith(ROOT_DIR + path.sep) && candidate !== ROOT_DIR) {
        return null;
    }
    return candidate;
}

export function createUnicareServer() {
    return http.createServer(async (req, res) => {
        if (req.method !== 'GET' && req.method !== 'HEAD') {
            res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('Method Not Allowed');
            return;
        }

        const filePath = resolveSafePath(req.url);
        if (!filePath) {
            res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('Forbidden');
            return;
        }

        try {
            const stat = await fs.stat(filePath);
            if (!stat.isFile()) {
                res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
                res.end('Not Found');
                return;
            }
            const ext = path.extname(filePath).toLowerCase();
            const contentType = MIME_TYPES[ext] || 'application/octet-stream';
            const data = req.method === 'HEAD' ? null : await fs.readFile(filePath);
            res.writeHead(200, {
                'Content-Type': contentType,
                'Cache-Control': 'no-cache'
            });
            res.end(data);
        } catch {
            res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('Not Found');
        }
    });
}

const isCliEntry = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isCliEntry) {
    const port = Number(process.env.PORT || 3000);
    const server = createUnicareServer();
    server.listen(port, '127.0.0.1', () => {
        console.log(`UNICARE local server running at http://127.0.0.1:${port}/`);
    });
}
