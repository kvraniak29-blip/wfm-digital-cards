export function unfoldVCard(text) {
  return String(text).replace(/\r?\n[ \t]/g, "");
}

export function parseVCard(text) {
  const lines = unfoldVCard(text).split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  if (!lines.includes("BEGIN:VCARD") || !lines.includes("END:VCARD")) {
    throw new Error("VCF neobsahuje BEGIN:VCARD alebo END:VCARD.");
  }

  const fields = [];
  for (const line of lines) {
    const index = line.indexOf(":");
    if (index < 1) continue;
    const head = line.slice(0, index);
    const value = unescapeVCard(line.slice(index + 1));
    const [rawName, ...paramParts] = head.split(";");
    const name = rawName.replace(/^item\d+\./i, "").toUpperCase();
    const params = paramParts.map((part) => part.toUpperCase());
    fields.push({ rawName, name, params, value });
  }

  const n = find(fields, "N")?.value.split(";") || [];
  const urls = fields.filter((field) => field.name === "URL");
  const socialProfiles = fields.filter((field) => field.name === "X-SOCIALPROFILE");
  const phone = find(fields, "TEL")?.value || "";
  const email = find(fields, "EMAIL")?.value || "";
  const website = urls.find((field) => field.params.some((p) => p.includes("WORK")))?.value || urls[0]?.value || "";

  return {
    firstName: n[1] || "",
    lastName: n[0] || "",
    displayName: find(fields, "FN")?.value || [n[1], n[0]].filter(Boolean).join(" "),
    company: find(fields, "ORG")?.value || "",
    title: find(fields, "TITLE")?.value || "",
    phoneE164: normalizePhone(phone),
    email,
    website,
    whatsapp: socialUrl(urls, socialProfiles, "WHATSAPP") || "",
    facebook: socialUrl(urls, socialProfiles, "FACEBOOK") || socialUrl(urls, socialProfiles, "facebook") || "",
    instagram: socialUrl(urls, socialProfiles, "INSTAGRAM") || socialUrl(urls, socialProfiles, "instagram") || "",
    photoBase64: photoValue(fields)
  };
}

function find(fields, name) {
  return fields.find((field) => field.name === name);
}

function socialUrl(urls, profiles, type) {
  const upper = type.toUpperCase();
  return urls.find((field) => field.params.some((param) => param.includes(upper)))?.value
    || profiles.find((field) => field.params.some((param) => param.includes(upper.toLowerCase()) || param.includes(upper)))?.value
    || "";
}

function photoValue(fields) {
  const photo = find(fields, "PHOTO")?.value || "";
  return photo.replace(/^data:image\/jpeg;base64,/i, "");
}

function normalizePhone(value) {
  const clean = String(value).replace(/[^\d+]/g, "");
  if (clean.startsWith("+")) return clean;
  return clean ? `+${clean}` : "";
}

function unescapeVCard(value) {
  return String(value)
    .replace(/\\n/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\");
}
