import fs from "node:fs/promises";
import path from "node:path";
import { parseArgs, root, writeText } from "./lib.mjs";
import { validateBroker } from "./validate-data.mjs";

const args = parseArgs(process.argv.slice(2));
if (!args.config || !args.photo) {
  console.error("Použitie: npm run add-broker -- --config data/new-broker.json --photo cesta-k-fotografii");
  process.exit(1);
}

const input = JSON.parse(await fs.readFile(path.resolve(args.config), "utf8"));
const errors = [];
validateBroker(input, errors, { requirePhotos: false });
if (errors.length) {
  for (const error of errors) console.error(`FAIL ${error}`);
  process.exit(1);
}

const brokerDir = path.join(root, "assets", "brokers", input.slug);
await fs.mkdir(brokerDir, { recursive: true });
const destPhoto = path.join(brokerDir, "photo.jpg");
await fs.copyFile(path.resolve(args.photo), destPhoto);
input.photo = `assets/brokers/${input.slug}/photo.jpg`;
await writeText(path.join(root, "data", "brokers", `${input.slug}.json`), `${JSON.stringify(input, null, 2)}\n`);
console.log(`PASS Maklér pridaný: ${input.slug}. Spustite npm run build.`);
