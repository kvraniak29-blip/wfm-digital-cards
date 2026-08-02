import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.cwd(), "dist");
const port = Number(process.env.PORT || 4173);
const manifest = loadManifest();
const basePath = normalizeBasePath(manifest.basePath || "");
const mime = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".png", "image/png"],
  [".vcf", "text/vcard; charset=utf-8"],
  [".xml", "application/xml; charset=utf-8"],
  [".txt", "text/plain; charset=utf-8"],
  [".json", "application/json; charset=utf-8"]
]);

http.createServer((req, res) => {
  try {
    const url = new URL(req.url || "/", `http://127.0.0.1:${port}`);
    const pathname = stripBasePath(decodeURIComponent(url.pathname));
    const file = resolveRequest(pathname);
    if (!file) return send(res, 404, "Not found");

    fs.readFile(file, (err, body) => {
      if (err) return send(res, 404, "Not found");
      res.writeHead(200, { "Content-Type": mime.get(path.extname(file).toLowerCase()) || "application/octet-stream" });
      res.end(body);
    });
  } catch {
    send(res, 400, "Bad request");
  }
}).listen(port, "127.0.0.1", () => {
  const prefix = basePath || "";
  console.log(`PASS Lokálny server: http://127.0.0.1:${port}${prefix}/`);
});

function loadManifest() {
  const file = path.join(root, "manifest.json");
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function normalizeBasePath(value) {
  const trimmed = String(value || "").trim().replace(/\/+$/, "");
  if (!trimmed || trimmed === "/") return "";
  return trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

function stripBasePath(pathname) {
  let current = pathname || "/";
  if (basePath && (current === basePath || current.startsWith(`${basePath}/`))) {
    current = current.slice(basePath.length) || "/";
  }
  return current;
}

function resolveRequest(pathname) {
  const normalizedUrlPath = pathname.endsWith("/") ? `${pathname}index.html` : pathname;
  const relative = normalizedUrlPath.replace(/^\/+/, "");
  const normalizedRelative = path.normalize(relative);
  if (normalizedRelative.startsWith("..") || path.isAbsolute(normalizedRelative)) return null;
  const file = path.resolve(root, normalizedRelative);
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) return null;
  return file;
}

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  res.end(body);
}
