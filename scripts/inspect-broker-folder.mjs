import fs from "node:fs/promises";
import path from "node:path";
import { loadCompany, parseArgs, slugify } from "./lib.mjs";
import { parseVCard } from "./vcard-parser.mjs";

const ignoredRootDirs = new Set([".git", ".github", "node_modules", "dist", "assets", "config", "data", "src", "scripts", "tests", "tools", "logs", "outputs", "_archive"]);
const args = parseArgs(process.argv.slice(2));
const folderArg = args.folder || args.BrokerFolder;

if (!folderArg) fail("Použitie: npm run inspect-broker -- --folder \"cesta-k-priecinku\"");

try {
  console.log(JSON.stringify(await inspectBrokerFolder(folderArg), null, 2));
} catch (error) {
  fail(error.message);
}

export async function inspectBrokerFolder(folderArg) {
  const folder = path.resolve(folderArg);
  const folderName = path.basename(folder);
  if (ignoredRootDirs.has(folderName) || folderName.startsWith(".")) throw new Error(`Ignorovaný priečinok nemožno importovať ako makléra: ${folderName}`);
  const stat = await fs.stat(folder).catch(() => null);
  if (!stat?.isDirectory()) throw new Error(`Priečinok neexistuje: ${folder}`);
  const files = (await fs.readdir(folder, { withFileTypes: true })).filter((entry) => entry.isFile()).map((entry) => entry.name);
  const vcfs = files.filter((file) => /\.vcf$/i.test(file));
  const photos = files.filter((file) => /\.(jpe?g|png)$/i.test(file));
  if (vcfs.length !== 1) throw new Error(`Priečinok musí obsahovať presne jeden VCF súbor. Nájdené: ${vcfs.length}`);
  if (photos.length !== 1) throw new Error(`Priečinok musí obsahovať presne jednu fotografiu JPG, JPEG alebo PNG. Nájdené: ${photos.length}`);
  const parsed = parseVCard(await fs.readFile(path.join(folder, vcfs[0]), "utf8"));
  const overrideFile = path.join(folder, "broker.json");
  const overrides = await readOptionalJson(overrideFile);
  const company = await loadCompany();
  const displayName = overrides.displayName || parsed.displayName || folderName;
  const phoneE164 = overrides.phoneE164 || parsed.phoneE164;
  return {
    folder,
    folderName,
    vcf: path.join(folder, vcfs[0]),
    photo: path.join(folder, photos[0]),
    broker: {
      active: overrides.active ?? true,
      slug: overrides.slug || slugify(displayName || folderName),
      firstName: overrides.firstName || parsed.firstName || firstWord(displayName),
      lastName: overrides.lastName || parsed.lastName || restWords(displayName),
      displayName,
      title: overrides.title || parsed.title || "Realitný maklér",
      company: overrides.company || parsed.company || company.name,
      phoneDisplay: overrides.phoneDisplay || phoneE164,
      phoneE164,
      email: overrides.email || parsed.email,
      website: overrides.website || parsed.website || company.website,
      whatsapp: overrides.whatsapp || parsed.whatsapp || (phoneE164 ? `https://wa.me/${phoneE164.replace("+", "")}` : ""),
      photoPosition: overrides.photoPosition || "50% 50%",
      social: {
        facebook: overrides.social?.facebook ?? (parsed.facebook || null),
        instagram: overrides.social?.instagram ?? (parsed.instagram || null)
      }
    }
  };
}

async function readOptionalJson(file) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    return {};
  }
}

function firstWord(value) {
  return String(value).trim().split(/\s+/)[0] || "";
}

function restWords(value) {
  return String(value).trim().split(/\s+/).slice(1).join(" ");
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
