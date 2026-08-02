import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import sharp from "sharp";
import jsQR from "jsqr";
import { PNG } from "pngjs";
import { loadBrokers, loadCompany, readJson, root, slugify } from "../scripts/lib.mjs";
import { validateAll, validateBranding, validatePhotos } from "../scripts/validate-data.mjs";
import { parseVCard } from "../scripts/vcard-parser.mjs";

const results = [];
const testSlug = "kristian-vraniak";
const workRoot = path.join(root, "work", "tests");

await cleanupTestBroker();

await test("validácia JSON, company.json a branding", async () => {
  const company = await loadCompany();
  const brokers = await loadBrokers();
  assert.equal(validateAll(company, brokers, { requirePhotos: false }).length, 0);
  assert.deepEqual(await validateBranding(company), []);
});

await test("validácia fotografií", async () => {
  const brokers = (await loadBrokers()).filter((broker) => broker.active);
  assert.deepEqual(await validatePhotos(brokers), []);
});

await test("slug s diakritikou", async () => {
  assert.equal(slugify("Kristián Vraniak"), testSlug);
});

await test("VCF parser, zalomené riadky a Base64 fotografia", async () => {
  const parsed = parseVCard(sampleVcf({ folded: true, includePhoto: true }));
  assert.equal(parsed.displayName, "Kristián Vraniak");
  assert.equal(parsed.phoneE164, "+421900111222");
  assert.equal(parsed.facebook, "https://www.facebook.com/WFMReality/");
  assert.ok(parsed.photoBase64.length > 0);
});

await test("import jedného vybraného priečinka JPG", async () => {
  const folder = await makeFixtureFolder("Kristián Vraniak", "jpg");
  await runImport(folder);
  const broker = JSON.parse(await fs.readFile(path.join(root, "data", "brokers", `${testSlug}.json`), "utf8"));
  assert.equal(broker.slug, testSlug);
  assert.equal(broker.displayName, "Kristián Vraniak");
  assert.ok((await fs.readFile(path.join(root, "assets", "brokers", testSlug, "photo.jpg")))[0] === 0xff);
});

await test("aktualizácia existujúceho makléra", async () => {
  const folder = await makeFixtureFolder("Kristián Vraniak", "jpg", { title: "Senior maklér" });
  await runImport(folder);
  const broker = JSON.parse(await fs.readFile(path.join(root, "data", "brokers", `${testSlug}.json`), "utf8"));
  assert.equal(broker.title, "Senior maklér");
  const status = JSON.parse(await fs.readFile(path.join(root, "data", "status", `${testSlug}.json`), "utf8"));
  assert.ok(status.version >= 2);
});

await test("import PNG a normalizácia na JPEG", async () => {
  await cleanupTestBroker();
  const folder = await makeFixtureFolder("Kristián Vraniak", "png");
  await runImport(folder);
  const photo = await fs.readFile(path.join(root, "assets", "brokers", testSlug, "photo.jpg"));
  assert.ok(photo[0] === 0xff && photo[1] === 0xd8);
});

await test("konflikt slugu bez potvrdenia aktualizácie", async () => {
  const folder = await makeFixtureFolder("Kristián Vraniak", "jpg");
  assert.throws(() => execFileSync(process.execPath, ["scripts/import-broker.mjs", "--folder", folder, "--skip-tests"], { cwd: root, stdio: "pipe" }));
});

await test("viac VCF súborov skončí FAIL", async () => {
  const folder = await makeFixtureFolder("Viac VCF", "jpg");
  await fs.writeFile(path.join(folder, "extra.vcf"), sampleVcf(), "utf8");
  assert.throws(() => execFileSync(process.execPath, ["scripts/inspect-broker-folder.mjs", "--folder", folder], { cwd: root, stdio: "pipe" }));
});

await test("viac fotografií skončí FAIL", async () => {
  const folder = await makeFixtureFolder("Viac Foto", "jpg");
  await sharp({ create: { width: 20, height: 20, channels: 3, background: "#ffffff" } }).jpeg().toFile(path.join(folder, "extra.jpg"));
  assert.throws(() => execFileSync(process.execPath, ["scripts/inspect-broker-folder.mjs", "--folder", folder], { cwd: root, stdio: "pipe" }));
});

await test("chýbajúce povinné údaje skončia FAIL", async () => {
  const folder = await makeFixtureFolder("Bez Telefonu", "jpg", { phoneE164: "" });
  assert.throws(() => execFileSync(process.execPath, ["scripts/import-broker.mjs", "--folder", folder, "--yes-update", "--skip-tests"], { cwd: root, stdio: "pipe" }));
});

await test("ignorovanie ostatných koreňových priečinkov", async () => {
  assert.throws(() => execFileSync(process.execPath, ["scripts/inspect-broker-folder.mjs", "--folder", "assets"], { cwd: root, stdio: "pipe" }));
});

await test("build pre Netlify", async () => {
  execFileSync(process.execPath, ["scripts/build.mjs", "--target", "netlify"], { cwd: root, stdio: "pipe" });
  await verifyBuild("netlify", "https://wfm-digital-cards.netlify.app/jakub-svec/");
});

await test("build pre GitHub Pages a zachovanie Jakubovej URL", async () => {
  execFileSync(process.execPath, ["scripts/build.mjs", "--target", "github-pages"], { cwd: root, stdio: "pipe" });
  await verifyBuild("github-pages", "https://kvraniak29-blip.github.io/wfm-digital-cards/jakub-svec/");
});

await cleanupTestBroker();

for (const item of results) console.log(`${item.ok ? "PASS" : "FAIL"} ${item.name}${item.note ? ` - ${item.note}` : ""}`);
if (results.some((item) => !item.ok)) process.exit(1);

async function test(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
  } catch (error) {
    results.push({ name, ok: false, note: error.message });
  }
}

async function verifyBuild(target, expectedUrl) {
  const dist = path.join(root, "dist");
  const manifest = await readJson("dist/manifest.json");
  assert.equal(manifest.target, target);
  const html = await fs.readFile(path.join(dist, "jakub-svec", "index.html"), "utf8");
  const vcf = await fs.readFile(path.join(dist, "jakub-svec", "jakub-svec.vcf"), "utf8");
  const photo = await fs.readFile(path.join(dist, "jakub-svec", "photo.jpg"));
  const qr = await fs.readFile(path.join(dist, "jakub-svec", "qr.png"));
  assert.ok(html.includes(`<link rel="canonical" href="${expectedUrl}">`));
  assert.ok(html.includes(`assets/branding/logo.png`));
  assert.ok(html.includes(`href="./jakub-svec.vcf"`));
  assert.ok(html.includes(`href="tel:+421904882685"`));
  assert.ok(html.includes(`href="https://wa.me/421904882685"`));
  assert.ok(html.includes(`href="mailto:jakub.svec@wfmreality.sk"`));
  assert.ok(html.includes(`href="https://www.wfmreality.sk/"`));
  assert.ok(html.includes(`href="https://www.facebook.com/WFMReality/"`));
  assert.ok(html.includes(`href="https://www.instagram.com/wfmreality.sk/"`));
  assert.ok(photo[0] === 0xff && photo[1] === 0xd8);
  assert.ok(vcf.includes("BEGIN:VCARD"));
  assert.ok(vcf.includes("VERSION:3.0"));
  assert.ok(vcf.includes("END:VCARD"));
  assert.ok(vcf.includes("FN:Jakub Švec"));
  assert.ok(vcf.includes("TEL;TYPE=CELL,VOICE:+421904882685"));
  assert.ok(vcf.includes("URL;TYPE=WORK:https://www.wfmreality.sk/"));
  assert.ok(vcf.includes("URL;TYPE=WHATSAPP:https://wa.me/421904882685"));
  assert.ok(vcf.includes("URL;TYPE=FACEBOOK:https://www.facebook.com/WFMReality/"));
  assert.ok(vcf.includes("URL;TYPE=INSTAGRAM:https://www.instagram.com/wfmreality.sk/"));
  assert.ok(vcf.includes("X-SOCIALPROFILE;TYPE=facebook:https://www.facebook.com/WFMReality/"));
  assert.ok(vcf.includes("PHOTO;ENCODING=b;TYPE=JPEG:"));
  const photoBase64 = unfoldVcf(vcf).match(/PHOTO;ENCODING=b;TYPE=JPEG:([A-Za-z0-9+/=]+)/)?.[1];
  assert.ok(photoBase64, "VCF PHOTO chýba");
  const decoded = Buffer.from(photoBase64, "base64");
  assert.ok(decoded[0] === 0xff && decoded[1] === 0xd8, "VCF PHOTO nie je JPEG");
  assert.ok(qr[0] === 0x89 && qr[1] === 0x50, "QR nie je PNG");
  assert.equal(decodeQr(qr), expectedUrl);
  for (const file of ["index.html", "assets/styles.css", "assets/script.js", "assets/favicon.svg", "assets/branding/logo.png", "assets/branding/background.png", "jakub-svec/index.html", "jakub-svec/photo.jpg", "jakub-svec/jakub-svec.vcf", "jakub-svec/qr.png"]) {
    await fs.access(path.join(dist, file));
  }
}

async function makeFixtureFolder(name, imageType, overrides = {}) {
  const folder = path.join(workRoot, `${name}-${imageType}-${Date.now()}`);
  await fs.mkdir(folder, { recursive: true });
  await fs.writeFile(path.join(folder, "kontakt.vcf"), sampleVcf(overrides), "utf8");
  const image = sharp({ create: { width: 80, height: 80, channels: 3, background: "#0b4c55" } });
  if (imageType === "png") await image.png().toFile(path.join(folder, "fotografia.png"));
  else await image.jpeg().toFile(path.join(folder, "fotografia.jpg"));
  if (Object.keys(overrides).length) {
    await fs.writeFile(path.join(folder, "broker.json"), `${JSON.stringify(overrides, null, 2)}\n`, "utf8");
  }
  return folder;
}

function sampleVcf(overrides = {}) {
  const firstName = overrides.firstName ?? "Kristián";
  const lastName = overrides.lastName ?? "Vraniak";
  const displayName = overrides.displayName ?? "Kristián Vraniak";
  const title = overrides.title ?? "Realitný maklér";
  const phone = overrides.phoneE164 ?? "+421900111222";
  const email = overrides.email ?? "kristian.vraniak@example.com";
  const photo = "R0lGODlhAQABAAAAACw=";
  const photoLine = overrides.folded
    ? `PHOTO;ENCODING=b;TYPE=JPEG:${photo.slice(0, 10)}\r\n ${photo.slice(10)}`
    : `PHOTO;ENCODING=b;TYPE=JPEG:${photo}`;
  return [
    "BEGIN:VCARD",
    "VERSION:3.0",
    `N:${lastName};${firstName};;;`,
    `FN:${displayName}`,
    "ORG:WFM Reality",
    `TITLE:${title}`,
    `TEL;TYPE=CELL,VOICE:${phone}`,
    `EMAIL;TYPE=INTERNET,WORK:${email}`,
    "URL;TYPE=WORK:https://www.wfmreality.sk/",
    "URL;TYPE=FACEBOOK:https://www.facebook.com/WFMReality/",
    "URL;TYPE=INSTAGRAM:https://www.instagram.com/wfmreality.sk/",
    "X-SOCIALPROFILE;TYPE=whatsapp:https://wa.me/421900111222",
    photoLine,
    "END:VCARD",
    ""
  ].join("\r\n");
}

async function runImport(folder) {
  execFileSync(process.execPath, ["scripts/import-broker.mjs", "--folder", folder, "--yes-update", "--skip-tests"], { cwd: root, stdio: "pipe" });
}

async function cleanupTestBroker() {
  await fs.rm(path.join(root, "data", "brokers", `${testSlug}.json`), { force: true });
  await fs.rm(path.join(root, "data", "status", `${testSlug}.json`), { force: true });
  await fs.rm(path.join(root, "assets", "brokers", testSlug), { recursive: true, force: true });
}

function unfoldVcf(vcf) {
  return vcf.replace(/\r\n[ \t]/g, "");
}

function decodeQr(buffer) {
  const png = PNG.sync.read(buffer);
  const code = jsQR(Uint8ClampedArray.from(png.data), png.width, png.height);
  assert.ok(code, "QR sa nedá dekódovať");
  return code.data;
}
