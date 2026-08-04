import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import sharp from "sharp";
import jsQR from "jsqr";
import { PNG } from "pngjs";
import { loadBrokers, loadCompany, readJson, root, slugify } from "../scripts/lib.mjs";
import { validateAll, validateBranding, validatePhotos } from "../scripts/validate-data.mjs";
import { parseVCard } from "../scripts/vcard-parser.mjs";

const results = [];
const realKristianSlug = "kristian-vraniak";
const testSlug = "wfm-test-broker";
const testDisplayName = "WFM Test Broker";
const workRoot = path.join(root, "work", "tests");
const protectedBefore = await captureProtectedBrokerFiles();

await cleanupTestBroker(testSlug);

await test("validácia JSON, company.json a branding", async () => {
  const company = await loadCompany();
  const brokers = await loadBrokers();
  assert.equal(validateAll(company, brokers, { requirePhotos: false }).length, 0);
  assert.deepEqual(await validateBranding(company), []);
});

await test("Windows PowerShell generátor je uložený ako UTF-8 BOM", async () => {
  const ps1 = await fs.readFile(path.join(root, "tools", "WFM-Card-Generator.ps1"));
  assert.equal(ps1[0], 0xef);
  assert.equal(ps1[1], 0xbb);
  assert.equal(ps1[2], 0xbf);
  const text = ps1.toString("utf8");
  assert.ok(!text.includes("ArgumentList.Add"));
  assert.ok(!text.includes("Invoke-Expression"));
  assert.ok(!text.includes("BackgroundWorker"));
  assert.ok(!text.includes("add_DoWork"));
  assert.ok(!text.includes("add_RunWorkerCompleted"));
  assert.ok(!text.includes(".DoWork +="));
  assert.ok(!text.includes(".RunWorkerCompleted +="));
  assert.ok(text.includes("System.Diagnostics.Process"));
  assert.ok(text.includes("System.Windows.Forms.Timer"));
  assert.ok(text.includes("ResultFile"));
});

await test("Windows PowerShell validácia nevracia null pri nulovom počte chýb", async () => {
  if (process.platform !== "win32") return;
  const output = execFileSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-ValidationSelfTest",
    "-Silent"
  ], { cwd: root, encoding: "utf8" });
  assert.ok(output.includes("PASS") || output.length === 0);
  await assertLatestGeneratorLogClean();
});

await test("Windows PowerShell načítanie priečinka dokončí validáciu aj fotografiu", async () => {
  if (process.platform !== "win32") return;
  const folder = await makeFixtureFolder("Windows Load", "jpg", {
    firstName: "Kristián",
    lastName: "Vraniak",
    displayName: "Kristián Vraniak",
    phoneE164: "+421948104075",
    email: "kristian.vraniak@wfmreality.sk",
    whatsapp: "https://wa.me/421948104075",
    slug: "kristian-vraniak",
    photoPosition: "50% 42%",
    social: {
      facebook: "https://www.facebook.com/WFMReality/",
      instagram: "https://www.instagram.com/wfmreality.sk/"
    }
  });
  const output = execFileSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    folder,
    "-BrokerLoadSelfTest",
    "-Silent"
  ], { cwd: root, encoding: "utf8" });
  assert.ok(output.includes("PASS") || output.length === 0);
  await assertLatestGeneratorLogClean();
});

await test("Windows PowerShell GUI self-test načíta fotografiu a aktivuje lokálne generovanie", async () => {
  if (process.platform !== "win32") return;
  const folder = await makeFixtureFolder("Windows GUI Load", "jpg", {
    firstName: "Kristián",
    lastName: "Vraniak",
    displayName: "Kristián Vraniak",
    phoneE164: "+421948104075",
    email: "kristian.vraniak@wfmreality.sk",
    whatsapp: "https://wa.me/421948104075",
    slug: realKristianSlug,
    photoPosition: "50% 42%",
    social: {
      facebook: "https://www.facebook.com/WFMReality/",
      instagram: "https://www.instagram.com/wfmreality.sk/"
    }
  });
  const output = execFileSync("powershell.exe", [
    "-NoProfile",
    "-STA",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    folder,
    "-GuiLoadSelfTest",
    "-Silent"
  ], { cwd: root, encoding: "utf8" });
  assert.ok(output.includes("PASS") || output.length === 0);
  await assertLatestGeneratorLogClean();
});

await test("Windows PowerShell GUI self-test klikne lokálne generovanie a skončí PASS", async () => {
  if (process.platform !== "win32") return;
  await cleanupTestBroker(testSlug);
  const folder = await makeFixtureFolder("Windows GUI Generate", "jpg", testBrokerOverrides());
  const output = execFileSync("powershell.exe", [
    "-NoProfile",
    "-STA",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    folder,
    "-GuiGenerateSelfTest",
    "-Silent"
  ], { cwd: root, encoding: "utf8" });
  assert.ok(output.includes("PASS") || output.length === 0);
  await assertLatestGeneratorLogClean();
});

await test("Windows PowerShell child proces vytvorí ResultFile PASS a výstupy", async () => {
  if (process.platform !== "win32") return;
  await cleanupTestBroker(testSlug);
  const folder = await makeFixtureFolder("Windows Child Process", "jpg", testBrokerOverrides());
  const overrideFile = path.join(workRoot, `override-${Date.now()}.json`);
  const resultFile = path.join(workRoot, `result-pass-${Date.now()}.json`);
  await fs.writeFile(overrideFile, `${JSON.stringify(testBrokerOverrides(), null, 2)}\n`, "utf8");
  const child = spawnSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    folder,
    "-OverrideFile",
    overrideFile,
    "-ResultFile",
    resultFile,
    "-Generate",
    "-Silent",
    "-SkipImportTests"
  ], { cwd: root, encoding: "utf8" });
  assert.equal(child.status, 0, child.stderr || child.stdout);
  const result = JSON.parse(await fs.readFile(resultFile, "utf8"));
  assert.equal(result.status, "PASS");
  assert.equal(result.slug, testSlug);
  assert.equal(result.published, false);
  for (const file of [
    `dist/${testSlug}/index.html`,
    `dist/${testSlug}/${testSlug}.vcf`,
    `dist/${testSlug}/photo.jpg`,
    `dist/${testSlug}/qr.png`
  ]) {
    await fs.access(path.join(root, file));
  }
  await assertLatestGeneratorLogClean();
});

await test("Windows PowerShell child proces vytvorí ResultFile FAIL pri neplatnom vstupe", async () => {
  if (process.platform !== "win32") return;
  const resultFile = path.join(workRoot, `result-fail-${Date.now()}.json`);
  const missingFolder = path.join(workRoot, `missing-${Date.now()}`);
  const child = spawnSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    missingFolder,
    "-ResultFile",
    resultFile,
    "-Generate",
    "-Silent",
    "-SkipImportTests"
  ], { cwd: root, encoding: "utf8" });
  assert.equal(child.status, 1);
  const result = JSON.parse(await fs.readFile(resultFile, "utf8"));
  assert.equal(result.status, "FAIL");
  assert.match(result.message, /Priečinok makléra neexistuje/);
  assert.notEqual(result.message, "PASS");
  await assertLatestGeneratorLogClean();
});

await test("publikovanie je na ne-main vetve blokované cez ResultFile FAIL", async () => {
  if (process.platform !== "win32") return;
  const branch = currentGitBranch();
  if (branch === "main") return;
  await cleanupTestBroker(testSlug);
  const folder = await makeFixtureFolder("Windows Publish Block", "jpg", testBrokerOverrides());
  const resultFile = path.join(workRoot, `result-publish-block-${Date.now()}.json`);
  const child = spawnSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "tools/WFM-Card-Generator.ps1",
    "-BrokerFolder",
    folder,
    "-ResultFile",
    resultFile,
    "-Generate",
    "-Publish",
    "-Silent",
    "-SkipImportTests"
  ], { cwd: root, encoding: "utf8" });
  assert.equal(child.status, 1);
  const result = JSON.parse(await fs.readFile(resultFile, "utf8"));
  assert.equal(result.status, "FAIL");
  assert.equal(result.published, true);
  assert.match(result.message, /Publikovanie je povolené iba na vetve main/);
  await assertLatestGeneratorLogClean();
});

await test("cleanup testov odmieta reálne maklérske slugy", async () => {
  await assert.rejects(() => cleanupTestBroker(realKristianSlug), /Odmietnuté čistenie netestovacieho slugu/);
  await assert.rejects(() => cleanupTestBroker("jakub-svec"), /Odmietnuté čistenie netestovacieho slugu/);
  await cleanupTestBroker(testSlug);
});

await test("validácia fotografií", async () => {
  const brokers = (await loadBrokers()).filter((broker) => broker.active);
  assert.deepEqual(await validatePhotos(brokers), []);
});

await test("slug s diakritikou", async () => {
  assert.equal(slugify("Kristián Vraniak"), realKristianSlug);
});

await test("VCF parser, zalomené riadky a Base64 fotografia", async () => {
  const parsed = parseVCard(sampleVcf({ folded: true, includePhoto: true }));
  assert.equal(parsed.displayName, "Kristián Vraniak");
  assert.equal(parsed.phoneE164, "+421900111222");
  assert.equal(parsed.facebook, "https://www.facebook.com/WFMReality/");
  assert.ok(parsed.photoBase64.length > 0);
});

await test("import jedného vybraného priečinka JPG", async () => {
  const folder = await makeFixtureFolder(testDisplayName, "jpg", testBrokerOverrides());
  await runImport(folder);
  const broker = JSON.parse(await fs.readFile(path.join(root, "data", "brokers", `${testSlug}.json`), "utf8"));
  assert.equal(broker.slug, testSlug);
  assert.equal(broker.displayName, testDisplayName);
  assert.ok((await fs.readFile(path.join(root, "assets", "brokers", testSlug, "photo.jpg")))[0] === 0xff);
});

await test("aktualizácia existujúceho makléra", async () => {
  const folder = await makeFixtureFolder(testDisplayName, "jpg", { ...testBrokerOverrides(), title: "Senior testovací maklér" });
  await runImport(folder);
  const broker = JSON.parse(await fs.readFile(path.join(root, "data", "brokers", `${testSlug}.json`), "utf8"));
  assert.equal(broker.title, "Senior testovací maklér");
  const status = JSON.parse(await fs.readFile(path.join(root, "data", "status", `${testSlug}.json`), "utf8"));
  assert.ok(status.version >= 2);
});

await test("import PNG a normalizácia na JPEG", async () => {
  await cleanupTestBroker(testSlug);
  const folder = await makeFixtureFolder(testDisplayName, "png", testBrokerOverrides());
  await runImport(folder);
  const photo = await fs.readFile(path.join(root, "assets", "brokers", testSlug, "photo.jpg"));
  assert.ok(photo[0] === 0xff && photo[1] === 0xd8);
});

await test("konflikt slugu bez potvrdenia aktualizácie", async () => {
  const folder = await makeFixtureFolder(testDisplayName, "jpg", testBrokerOverrides());
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

await test("lokálny HTTP server podporuje GitHub Pages basePath", async () => {
  execFileSync(process.execPath, ["scripts/build.mjs", "--target", "github-pages"], { cwd: root, stdio: "pipe" });
  const previewPort = 4187;
  const previewRoot = `http://127.0.0.1:${previewPort}`;
  const child = spawn(process.execPath, ["scripts/serve.mjs"], { cwd: root, env: { ...process.env, PORT: String(previewPort) }, stdio: "pipe" });
  try {
    await waitForHttp(`${previewRoot}/wfm-digital-cards/`);
    for (const url of [
      `${previewRoot}/wfm-digital-cards/`,
      `${previewRoot}/wfm-digital-cards/assets/styles.css`,
      `${previewRoot}/wfm-digital-cards/assets/branding/logo.png`,
      `${previewRoot}/wfm-digital-cards/assets/branding/background.png`,
      `${previewRoot}/wfm-digital-cards/jakub-svec/`
    ]) {
      const response = await fetch(url);
      assert.equal(response.status, 200, url);
    }
    const missing = await fetch(`${previewRoot}/wfm-digital-cards/%2e%2e/package.json`);
    assert.notEqual(missing.status, 200);
  } finally {
    child.kill();
    await new Promise((resolve) => child.once("exit", resolve));
  }
});

await test("chránené dáta Jakuba a existujúceho Kristiána zostali nezmenené", async () => {
  await assertProtectedBrokerFilesUnchanged(protectedBefore);
});

await cleanupTestBroker(testSlug);

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

function testBrokerOverrides() {
  return {
    slug: testSlug,
    firstName: "WFM",
    lastName: "Test Broker",
    displayName: testDisplayName,
    title: "Testovací maklér",
    phoneDisplay: "+421 900 111 222",
    phoneE164: "+421900111222",
    email: "wfm.test.broker@example.com",
    whatsapp: "https://wa.me/421900111222"
  };
}

function currentGitBranch() {
  try {
    return execFileSync("git", ["branch", "--show-current"], { cwd: root, encoding: "utf8" }).trim();
  } catch {
    return "";
  }
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

async function cleanupTestBroker(slug) {
  const protectedSlugs = new Set(["jakub-svec", realKristianSlug]);
  if (protectedSlugs.has(slug) || !slug.startsWith("wfm-test-")) {
    throw new Error(`Odmietnuté čistenie netestovacieho slugu: ${slug}`);
  }
  await fs.rm(path.join(root, "data", "brokers", `${slug}.json`), { force: true });
  await fs.rm(path.join(root, "data", "status", `${slug}.json`), { force: true });
  await fs.rm(path.join(root, "assets", "brokers", slug), { recursive: true, force: true });
}

async function captureProtectedBrokerFiles() {
  const files = [
    protectedFile("jakub-svec", "data/brokers/jakub-svec.json"),
    protectedFile("jakub-svec", "assets/brokers/jakub-svec/photo.jpg"),
    protectedFile(realKristianSlug, `data/brokers/${realKristianSlug}.json`),
    protectedFile(realKristianSlug, `assets/brokers/${realKristianSlug}/photo.jpg`)
  ];
  const snapshot = [];
  for (const item of files) {
    const file = path.join(root, item.relativePath);
    const bytes = await fs.readFile(file).catch(() => null);
    snapshot.push({
      ...item,
      existed: Boolean(bytes),
      hash: bytes ? crypto.createHash("sha256").update(bytes).digest("hex") : null
    });
  }
  return snapshot;
}

function protectedFile(slug, relativePath) {
  return { slug, relativePath };
}

async function assertProtectedBrokerFilesUnchanged(snapshot) {
  for (const item of snapshot) {
    const file = path.join(root, item.relativePath);
    const bytes = await fs.readFile(file).catch(() => null);
    if (!item.existed) {
      assert.equal(bytes, null, `${item.relativePath} pred testom neexistoval a test ho nemal vytvoriť`);
      continue;
    }
    assert.ok(bytes, `${item.relativePath} pred testom existoval a po teste chýba`);
    const hash = crypto.createHash("sha256").update(bytes).digest("hex");
    assert.equal(hash, item.hash, `${item.relativePath} sa počas testu zmenil`);
  }
}

async function assertLatestGeneratorLogClean() {
  const logsDir = path.join(root, "logs");
  const files = (await fs.readdir(logsDir).catch(() => [])).filter((file) => /^WFM-Generator-.*\.log$/.test(file));
  assert.ok(files.length > 0, "Generátor nevytvoril log");
  const stats = await Promise.all(files.map(async (file) => ({ file, stat: await fs.stat(path.join(logsDir, file)) })));
  stats.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  const text = await fs.readFile(path.join(logsDir, stats[0].file), "utf8");
  assert.ok(!/There is no Runspace available|property 'DoWork' cannot be found|property 'Count' cannot be found|Exception setting "Text"/i.test(text));
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

async function waitForHttp(url) {
  let lastError;
  for (let i = 0; i < 40; i += 1) {
    try {
      const response = await fetch(url);
      if (response.status === 200) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw lastError || new Error(`Server neodpovedá: ${url}`);
}
