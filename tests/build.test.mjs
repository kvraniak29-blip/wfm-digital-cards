import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import jsQR from "jsqr";
import { PNG } from "pngjs";
import { loadBrokers, loadCompany, readJson, root } from "../scripts/lib.mjs";
import { validateAll, validatePhotos } from "../scripts/validate-data.mjs";

const results = [];
await test("validácia JSON a company.json", async () => {
  const company = await loadCompany();
  const brokers = await loadBrokers();
  assert.equal(validateAll(company, brokers, { requirePhotos: false }).length, 0);
});
await test("validácia fotografií", async () => {
  const brokers = (await loadBrokers()).filter((broker) => broker.active);
  assert.deepEqual(await validatePhotos(brokers), []);
});
await test("build pre Netlify", async () => {
  execFileSync(process.execPath, ["scripts/build.mjs", "--target", "netlify"], { cwd: root, stdio: "pipe" });
  await verifyBuild("netlify", "https://wfm-digital-cards.netlify.app/jakub-svec/");
});
await test("build pre GitHub Pages", async () => {
  execFileSync(process.execPath, ["scripts/build.mjs", "--target", "github-pages"], { cwd: root, stdio: "pipe" });
  await verifyBuild("github-pages", "https://kvraniak29-blip.github.io/wfm-digital-cards/jakub-svec/");
});

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
  assert.ok(vcf.includes("PHOTO;ENCODING=b;TYPE=JPEG:"));
  const photoBase64 = unfoldVcf(vcf).match(/PHOTO;ENCODING=b;TYPE=JPEG:([A-Za-z0-9+/=]+)/)?.[1];
  assert.ok(photoBase64, "VCF PHOTO chýba");
  const decoded = Buffer.from(photoBase64, "base64");
  assert.ok(decoded[0] === 0xff && decoded[1] === 0xd8, "VCF PHOTO nie je JPEG");
  assert.ok(qr[0] === 0x89 && qr[1] === 0x50, "QR nie je PNG");
  assert.equal(decodeQr(qr), expectedUrl);
  for (const file of ["index.html", "assets/styles.css", "assets/script.js", "assets/favicon.svg", "jakub-svec/index.html", "jakub-svec/photo.jpg", "jakub-svec/jakub-svec.vcf", "jakub-svec/qr.png"]) {
    await fs.access(path.join(dist, file));
  }
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
