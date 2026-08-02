import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { loadBrokers, loadCompany, root } from "./lib.mjs";
import { fileURLToPath } from "node:url";

const isMain = fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "");

export function validateAll(company, brokers, options = {}) {
  const errors = [];
  validateCompany(company, errors);
  const slugs = new Set();
  for (const broker of brokers) {
    validateBroker(broker, errors, options);
    if (slugs.has(broker.slug)) errors.push(`Duplicitný slug: ${broker.slug}`);
    slugs.add(broker.slug);
  }
  return errors;
}

export function validateCompany(company, errors) {
  for (const key of ["name", "website", "facebook", "instagram"]) {
    if (!company[key]) errors.push(`company.json chýba pole ${key}`);
  }
  for (const key of ["website", "facebook", "instagram"]) {
    if (company[key] && !/^https:\/\/.+/.test(company[key])) errors.push(`company.${key} musí byť HTTPS URL`);
  }
  for (const key of ["primary", "secondary", "background", "surface", "text"]) {
    if (!/^#[0-9a-fA-F]{6}$/.test(company.theme?.[key] || "")) errors.push(`company.theme.${key} musí byť HEX farba`);
  }
}

export function validateBroker(broker, errors, options = {}) {
  for (const key of ["slug", "firstName", "lastName", "displayName", "title", "company", "phoneE164", "email", "website", "photo"]) {
    if (!broker[key]) errors.push(`${broker.sourceFile || broker.slug || "broker"} chýba pole ${key}`);
  }
  if (broker.slug && !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(broker.slug)) errors.push(`Neplatný slug: ${broker.slug}`);
  if (broker.phoneE164 && !/^\+[1-9]\d{7,14}$/.test(broker.phoneE164)) errors.push(`Telefón nie je E.164: ${broker.phoneE164}`);
  if (broker.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(broker.email)) errors.push(`Neplatný e-mail: ${broker.email}`);
  if (broker.website && !/^https:\/\/.+/.test(broker.website)) errors.push(`Web musí byť HTTPS URL: ${broker.website}`);
  if (broker.whatsapp && broker.whatsapp !== `https://wa.me/${broker.phoneE164.replace("+", "")}`) errors.push(`WhatsApp URL nezodpovedá telefónu: ${broker.slug}`);
}

export async function validatePhotos(brokers) {
  const errors = [];
  for (const broker of brokers.filter((item) => item.active)) {
    try {
      await fs.access(path.join(root, broker.photo));
      const meta = await sharp(path.join(root, broker.photo)).metadata();
      if (!meta.width || !meta.height) errors.push(`Fotografia sa nedá načítať: ${broker.photo}`);
    } catch {
      errors.push(`Fotografia neexistuje: ${broker.photo}`);
    }
  }
  return errors;
}

if (isMain) {
  const company = await loadCompany();
  const brokers = await loadBrokers();
  const errors = validateAll(company, brokers, { requirePhotos: false });
  if (errors.length) {
    for (const error of errors) console.error(`FAIL ${error}`);
    process.exit(1);
  }
  const photoErrors = await validatePhotos(brokers);
  if (photoErrors.length) {
    for (const error of photoErrors) console.error(`FAIL ${error}`);
    process.exit(1);
  }
  console.log(`PASS Validácia dát: ${brokers.length} maklér(ov).`);
}
