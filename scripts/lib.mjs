import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

export const root = process.cwd();
export const distDir = path.join(root, "dist");

export async function readJson(file) {
  return JSON.parse(await fs.readFile(path.join(root, file), "utf8"));
}

export async function loadCompany() {
  return readJson("config/company.json");
}

export async function loadDeployment(target = "netlify") {
  const all = await readJson("config/deployment.json");
  const config = all[target];
  if (!config) throw new Error(`Neznámy deployment target: ${target}`);
  return config;
}

export async function loadBrokers() {
  const dir = path.join(root, "data", "brokers");
  const files = (await fs.readdir(dir)).filter((name) => name.endsWith(".json")).sort();
  const brokers = [];
  for (const file of files) {
    brokers.push({ ...(await readJson(path.join("data", "brokers", file))), sourceFile: path.join("data", "brokers", file) });
  }
  return brokers;
}

export function deploymentFromEnv(target = "netlify", deployment) {
  const siteUrl = (process.env.SITE_URL || deployment.siteUrl || "").replace(/\/$/, "");
  const basePathRaw = process.env.BASE_PATH ?? deployment.basePath ?? "";
  const basePath = normalizeBasePath(basePathRaw);
  if (!/^https:\/\/[^/\s]+/.test(siteUrl)) throw new Error("SITE_URL musí byť HTTPS URL bez koncového lomítka.");
  return { ...deployment, siteUrl, basePath, rootUrl: `${siteUrl}/` };
}

export function normalizeBasePath(value) {
  if (!value) return "";
  const trimmed = String(value).trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  if (!trimmed.startsWith("/")) throw new Error("BASE_PATH musí byť prázdny alebo začínať lomítkom.");
  return trimmed;
}

export function publicUrl(env, suffix = "") {
  const cleanSuffix = suffix.replace(/^\/+/, "");
  return `${env.siteUrl}/${cleanSuffix}`;
}

export function assetPrefix(env) {
  return env.basePath || "";
}

export function brokerUrl(env, broker) {
  return publicUrl(env, `${broker.slug}/`);
}

export function brokerOutputDir(broker) {
  return path.join(distDir, broker.slug);
}

export function resolveSocial(broker, company, key) {
  return broker.social?.[key] || company[key] || null;
}

export function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[char]);
}

export function escapeVCard(value) {
  return String(value)
    .replace(/\\/g, "\\\\")
    .replace(/\n/g, "\\n")
    .replace(/,/g, "\\,")
    .replace(/;/g, "\\;");
}

export function foldVCardLine(line) {
  const chunks = [];
  let current = "";
  for (const char of line) {
    const next = current + char;
    if (Buffer.byteLength(next, "utf8") > 73) {
      chunks.push(current);
      current = ` ${char}`;
    } else {
      current = next;
    }
  }
  chunks.push(current);
  return chunks.join("\r\n");
}

export async function ensureJpegPhoto(source, dest) {
  const input = path.join(root, source);
  await fs.access(input);
  const meta = await sharp(input).metadata();
  if (!meta.width || !meta.height) throw new Error(`Fotografia sa nedá načítať: ${source}`);
  if (meta.format !== "jpeg") throw new Error(`Fotografia musí byť JPEG: ${source}`);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.copyFile(input, dest);
  return { input, width: meta.width, height: meta.height };
}

export async function writeText(file, content) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, content, "utf8");
}

export async function copyFileStrict(source, dest) {
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.copyFile(path.join(root, source), dest);
}

export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      out[key] = next && !next.startsWith("--") ? argv[++i] : true;
    }
  }
  return out;
}
