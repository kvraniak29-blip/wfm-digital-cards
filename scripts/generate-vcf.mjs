import fs from "node:fs/promises";
import { escapeVCard, foldVCardLine } from "./lib.mjs";

export async function generateVcf(broker, photoFile) {
  const photo = await fs.readFile(photoFile);
  const photoBase64 = photo.toString("base64");
  const decoded = Buffer.from(photoBase64, "base64");
  if (decoded[0] !== 0xff || decoded[1] !== 0xd8) throw new Error(`VCF fotografia nemá JPEG hlavičku: ${broker.slug}`);

  const lines = [
    "BEGIN:VCARD",
    "VERSION:3.0",
    `N:${escapeVCard(broker.lastName)};${escapeVCard(broker.firstName)};;;`,
    `FN:${escapeVCard(broker.displayName)}`,
    `ORG:${escapeVCard(broker.company)}`,
    `TITLE:${escapeVCard(broker.title)}`,
    `TEL;TYPE=CELL,VOICE:${broker.phoneE164}`,
    `EMAIL;TYPE=INTERNET,WORK:${broker.email}`,
    `URL:${broker.website}`,
    `PHOTO;ENCODING=b;TYPE=JPEG:${photoBase64}`,
    "END:VCARD"
  ];

  return `${lines.map(foldVCardLine).join("\r\n")}\r\n`;
}
