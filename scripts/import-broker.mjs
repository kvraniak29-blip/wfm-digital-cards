import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import {
  brokerUrl,
  deploymentFromEnv,
  loadBrokers,
  loadCompany,
  loadDeployment,
  normalizePhoto,
  parseArgs,
  root,
  sha256File,
  slugify,
  writeText
} from "./lib.mjs";
import { parseVCard } from "./vcard-parser.mjs";
import { validateBroker } from "./validate-data.mjs";

const ignoredRootDirs = new Set([".git", ".github", "node_modules", "dist", "assets", "config", "data", "src", "scripts", "tests", "tools", "logs", "outputs", "_archive"]);
const args = parseArgs(process.argv.slice(2));
const folderArg = args.folder || args.BrokerFolder;

if (!folderArg) fail("Použitie: npm run import-broker -- --folder \"cesta-k-priecinku\"");

try {
  const result = await importBroker(folderArg, { allowUpdate: args["yes-update"] === true || args.silent === true, overrideFile: args.override, skipTests: args["skip-tests"] === true });
  console.log(JSON.stringify(result, null, 2));
  console.log(`PASS Import bol úspešný. Zdrojový priečinok môžete ponechať, presunúť do archívu alebo odstrániť. Projekt používa internú kópiu.`);
} catch (error) {
  fail(error.message);
}

export async function importBroker(folderArg, options = {}) {
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

  const vcfFile = path.join(folder, vcfs[0]);
  const photoFile = path.join(folder, photos[0]);
  const parsed = parseVCard(await fs.readFile(vcfFile, "utf8"));
  const overrideFile = options.overrideFile || path.join(folder, "broker.json");
  const overrides = await readOptionalJson(overrideFile);
  const company = await loadCompany();
  const displayName = overrides.displayName || parsed.displayName || folderName;
  const slug = overrides.slug || slugify(displayName || folderName);
  if (!slug) throw new Error("Slug sa nedá vytvoriť z mena alebo názvu priečinka.");

  const existing = (await loadBrokers()).find((broker) => broker.slug === slug);
  if (existing && !options.allowUpdate) {
    throw new Error(`Slug už existuje: ${slug}. Ide o aktualizáciu existujúceho makléra; potvrďte aktualizáciu v aplikácii alebo použite --yes-update.`);
  }

  const broker = {
    active: overrides.active ?? true,
    slug,
    firstName: overrides.firstName || parsed.firstName || firstWord(displayName),
    lastName: overrides.lastName || parsed.lastName || restWords(displayName),
    displayName,
    title: overrides.title || parsed.title || "Realitný maklér",
    company: overrides.company || parsed.company || company.name,
    phoneDisplay: overrides.phoneDisplay || parsed.phoneE164,
    phoneE164: overrides.phoneE164 || parsed.phoneE164,
    email: overrides.email || parsed.email,
    website: overrides.website || parsed.website || company.website,
    whatsapp: overrides.whatsapp || parsed.whatsapp || `https://wa.me/${(overrides.phoneE164 || parsed.phoneE164).replace("+", "")}`,
    photo: `assets/brokers/${slug}/photo.jpg`,
    photoPosition: overrides.photoPosition || "50% 50%",
    social: {
      facebook: overrides.social?.facebook ?? (parsed.facebook || null),
      instagram: overrides.social?.instagram ?? (parsed.instagram || null)
    }
  };

  const errors = [];
  validateBroker({ ...broker, sourceFile: `import:${folder}` }, errors);
  if (errors.length) throw new Error(errors.join("\n"));

  const brokerJson = path.join(root, "data", "brokers", `${slug}.json`);
  const brokerPhoto = path.join(root, "assets", "brokers", slug, "photo.jpg");
  const statusFile = path.join(root, "data", "status", `${slug}.json`);
  const backup = await backupBroker(slug);

  try {
    await normalizePhoto(photoFile, brokerPhoto);
    await writeText(brokerJson, `${JSON.stringify(broker, null, 2)}\n`);
    execFileSync(process.execPath, ["scripts/build.mjs", "--target", "github-pages"], { cwd: root, stdio: "pipe" });
    if (!options.skipTests) {
      execFileSync(process.execPath, ["tests/build.test.mjs"], { cwd: root, stdio: "pipe" });
    }
    const deployment = deploymentFromEnv("github-pages", await loadDeployment("github-pages"));
    const status = await nextStatus(slug, statusFile, {
      slug,
      displayName,
      sourceFolder: folderName,
      sourceVcfHash: await sha256File(vcfFile),
      sourcePhotoHash: await sha256File(photoFile),
      generatedVcfHash: await sha256File(path.join(root, "dist", slug, `${slug}.vcf`)),
      publicUrl: brokerUrl(deployment, broker),
      lastCommit: currentCommit(),
      status: "PASS"
    });
    await writeText(statusFile, `${JSON.stringify(status, null, 2)}\n`);
    return { status: "PASS", slug, displayName, publicUrl: status.publicUrl, updatedExisting: Boolean(existing) };
  } catch (error) {
    await restoreBackup(backup);
    throw error;
  }
}

async function readOptionalJson(file) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    return {};
  }
}

async function backupBroker(slug) {
  const files = [
    path.join(root, "data", "brokers", `${slug}.json`),
    path.join(root, "assets", "brokers", slug, "photo.jpg"),
    path.join(root, "data", "status", `${slug}.json`)
  ];
  const backup = [];
  for (const file of files) {
    try {
      backup.push({ file, exists: true, content: await fs.readFile(file) });
    } catch {
      backup.push({ file, exists: false });
    }
  }
  return backup;
}

async function restoreBackup(backup) {
  for (const item of backup) {
    if (item.exists) {
      await fs.mkdir(path.dirname(item.file), { recursive: true });
      await fs.writeFile(item.file, item.content);
    } else {
      await fs.rm(item.file, { force: true });
    }
  }
}

async function nextStatus(slug, file, data) {
  let version = 0;
  try {
    version = JSON.parse(await fs.readFile(file, "utf8")).version || 0;
  } catch {}
  return { ...data, version: version + 1, lastGeneratedAt: new Date().toISOString() };
}

function currentCommit() {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
  } catch {
    return "";
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
