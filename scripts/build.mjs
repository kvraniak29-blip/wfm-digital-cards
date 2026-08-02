import fs from "node:fs/promises";
import path from "node:path";
import {
  assetPrefix,
  brokerOutputDir,
  brokerUrl,
  deploymentFromEnv,
  distDir,
  escapeHtml,
  ensureJpegPhoto,
  loadBrokers,
  loadCompany,
  loadDeployment,
  parseArgs,
  publicUrl,
  resolveSocial,
  root,
  writeText
} from "./lib.mjs";
import { validateAll, validatePhotos } from "./validate-data.mjs";
import { generateVcf } from "./generate-vcf.mjs";
import { generateQr } from "./generate-qr.mjs";

const args = parseArgs(process.argv.slice(2));
const target = args.target || process.env.DEPLOY_TARGET || "netlify";
const company = await loadCompany();
const deployment = await loadDeployment(target);
const env = deploymentFromEnv(target, deployment);
const brokers = await loadBrokers();
const activeBrokers = brokers.filter((broker) => broker.active);
const validationErrors = [
  ...validateAll(company, brokers, { requirePhotos: false }),
  ...(await validatePhotos(activeBrokers))
];

if (validationErrors.length) {
  for (const error of validationErrors) console.error(`FAIL ${error}`);
  process.exit(1);
}

await fs.rm(distDir, { recursive: true, force: true });
await fs.mkdir(path.join(distDir, "assets"), { recursive: true });
await fs.copyFile(path.join(root, "src", "styles.css"), path.join(distDir, "assets", "styles.css"));
await fs.copyFile(path.join(root, "src", "script.js"), path.join(distDir, "assets", "script.js"));
await writeText(path.join(distDir, "assets", "favicon.svg"), faviconSvg(company));

const brokerTemplate = await fs.readFile(path.join(root, "src", "broker-template.html"), "utf8");
const indexTemplate = await fs.readFile(path.join(root, "src", "index-template.html"), "utf8");
const manifest = [];

for (const broker of activeBrokers) {
  const outDir = brokerOutputDir(broker);
  await fs.mkdir(outDir, { recursive: true });
  const photoOut = path.join(outDir, "photo.jpg");
  await ensureJpegPhoto(broker.photo, photoOut);
  const vcf = await generateVcf(broker, photoOut);
  await writeText(path.join(outDir, `${broker.slug}.vcf`), vcf);
  const url = brokerUrl(env, broker);
  await generateQr(path.join(outDir, "qr.png"), url);
  const facebook = resolveSocial(broker, company, "facebook");
  const instagram = resolveSocial(broker, company, "instagram");
  const buttons = [
    button("Uložiť kontakt", `./${broker.slug}.vcf`, iconDownload(), `Stiahnuť kontakt ${broker.displayName} vo formáte vCard`, true),
    button("Zavolať", `tel:${broker.phoneE164}`, iconPhone(), `Zavolať ${broker.displayName}`),
    button("WhatsApp", broker.whatsapp || `https://wa.me/${broker.phoneE164.replace("+", "")}`, iconMessage(), `Napísať cez WhatsApp`),
    button("Napísať e-mail", `mailto:${broker.email}`, iconMail(), `Napísať e-mail ${broker.displayName}`),
    button("Web WFM Reality", broker.website, iconGlobe(), "Otvoriť web WFM Reality"),
    button("Facebook WFM Reality", facebook, iconFacebook(), "Otvoriť Facebook WFM Reality"),
    button("Instagram WFM Reality", instagram, iconInstagram(), "Otvoriť Instagram WFM Reality")
  ].join("\n        ");

  const html = render(brokerTemplate, {
    title: `${broker.displayName} | ${company.name}`,
    description: `Digitálna NFC vizitka: ${broker.displayName}, ${broker.title}, ${company.name}.`,
    canonicalUrl: url,
    ogTitle: `${broker.displayName} | ${company.name}`,
    ogDescription: `${broker.title} - ${company.name}`,
    ogImage: publicUrl(env, `${broker.slug}/photo.jpg`),
    assetPrefix: assetPrefix(env),
    companyName: company.name,
    displayName: broker.displayName,
    brokerTitle: broker.title,
    phoneDisplay: broker.phoneDisplay,
    email: broker.email,
    website: broker.website,
    buttons
  });
  await writeText(path.join(outDir, "index.html"), html);
  manifest.push({ slug: broker.slug, url, qr: `${broker.slug}/qr.png`, vcf: `${broker.slug}/${broker.slug}.vcf`, photo: `${broker.slug}/photo.jpg` });
}

const brokerList = activeBrokers.map((broker) => (
  `<li><a class="broker-link" href="${assetPrefix(env)}/${broker.slug}/"><span><strong>${escapeHtml(broker.displayName)}</strong><span>${escapeHtml(broker.title)}</span></span><span aria-hidden="true">→</span></a></li>`
)).join("\n        ");

await writeText(path.join(distDir, "index.html"), render(indexTemplate, {
  companyName: company.name,
  rootUrl: env.rootUrl,
  assetPrefix: assetPrefix(env),
  brokerList
}));
await writeText(path.join(distDir, "robots.txt"), "User-agent: *\nAllow: /\n");
await writeText(path.join(distDir, "sitemap.xml"), sitemap(env, activeBrokers));
await writeText(path.join(distDir, "manifest.json"), `${JSON.stringify({ target, siteUrl: env.siteUrl, basePath: env.basePath, brokers: manifest }, null, 2)}\n`);

console.log(`PASS Build ${target}: ${activeBrokers.length} aktívny maklér, výstup dist/.`);

function render(template, values) {
  return template.replace(/\{\{([a-zA-Z0-9]+)\}\}/g, (_, key) => values[key] ?? "");
}

function button(label, href, svg, ariaLabel, download = false) {
  const primary = label === "Uložiť kontakt" ? " primary" : "";
  return `<a class="button${primary}" href="${href}" aria-label="${escapeHtml(ariaLabel)}"${download ? " download" : ""}>${svg}<span>${escapeHtml(label)}</span></a>`;
}

function sitemap(env, brokers) {
  const urls = [env.rootUrl, ...brokers.map((broker) => brokerUrl(env, broker))];
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((url) => `  <url><loc>${url}</loc></url>`).join("\n")}\n</urlset>\n`;
}

function faviconSvg(company) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="${company.theme.background}"/><path d="M12 42V19h7l4 12 4-12h7l4 12 4-12h10v7h-5v16h-8V30l-5 12h-5l-5-12v12h-7V26h-5v16z" fill="${company.theme.secondary}"/></svg>\n`;
}

function iconDownload() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>`;
}
function iconPhone() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.3 1.7.6 2.5a2 2 0 0 1-.5 2.1L8 9.5a16 16 0 0 0 6.5 6.5l1.2-1.2a2 2 0 0 1 2.1-.5c.8.3 1.6.5 2.5.6a2 2 0 0 1 1.7 2z"/></svg>`;
}
function iconMessage() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 8.7 8.7 0 0 1-4-.9L3 21l1.7-4.6a8.4 8.4 0 1 1 16.3-4.9z"/></svg>`;
}
function iconMail() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="m22 6-10 7L2 6"/></svg>`;
}
function iconGlobe() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15 15 0 0 1 0 20"/><path d="M12 2a15 15 0 0 0 0 20"/></svg>`;
}
function iconInstagram() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><path d="M17.5 6.5h.01"/></svg>`;
}
function iconFacebook() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M14 8h3V4h-3c-3.1 0-5 1.9-5 5v3H6v4h3v6h4v-6h3.2l.8-4h-4V9c0-.7.3-1 1-1z"/></svg>`;
}
