# WFM Digital Cards

Statický systém digitálnych NFC vizitiek pre realitných maklérov WFM Reality.

## Architektúra

- `config/company.json` - spoločná firemná konfigurácia, farby a sociálne siete.
- `config/deployment.json` - URL nastavenia pre Netlify a GitHub Pages.
- `data/brokers/*.json` - zdroj pravdy pre každého makléra.
- `assets/brokers/<slug>/photo.jpg` - profilová fotografia makléra.
- `src/broker-template.html` - spoločná HTML šablóna vizitky.
- `src/index-template.html` - spoločná HTML šablóna koreňovej stránky.
- `src/styles.css` - spoločný dizajn.
- `scripts/generate-vcf.mjs` - spoločný VCF generátor.
- `scripts/generate-qr.mjs` - spoločný QR generátor.
- `dist/` - výsledok buildu pripravený na hosting.

Kontaktné údaje sa nemenia ručne v HTML, VCF ani QR. Zdrojom pravdy je JSON makléra.

## Inštalácia

```powershell
npm ci
```

## Lokálny build a testovanie

```powershell
npm run validate
npm run build:netlify
npm test
npm run serve
```

Lokálny server otvorí výstup z `dist/` na `http://127.0.0.1:4173/`.

## Deployment premenné

Build podporuje:

- `SITE_URL`
- `BASE_PATH`

Netlify:

```powershell
$env:SITE_URL="https://wfm-digital-cards.netlify.app"
$env:BASE_PATH=""
npm run build:netlify
```

GitHub Pages:

```powershell
$env:SITE_URL="https://kvraniak29-blip.github.io/wfm-digital-cards"
$env:BASE_PATH="/wfm-digital-cards"
npm run build:github-pages
```

## Netlify deployment

Projekt používa bezplatný statický build:

- Build command: `npm run build:netlify`
- Publish directory: `dist`
- Site ID: `6103c4f1-b7ba-428c-93c5-ae947cbd9232`

Platené Netlify funkcie, doplnky, plán ani platobná karta sa nesmú aktivovať.

Produkčný deploy:

```powershell
netlify deploy --prod --dir=dist --site 6103c4f1-b7ba-428c-93c5-ae947cbd9232 --message "Deploy WFM digital cards"
```

## GitHub Pages deployment

Workflow je v `.github/workflows/deploy-pages.yml`.

Po pushi do `main` workflow:

1. nainštaluje závislosti cez `npm ci`,
2. spustí testy,
3. spustí `npm run build:github-pages`,
4. nasadí `dist/` cez GitHub Pages.

## Prepnutie hostingu

Hosting sa prepína iba cez `SITE_URL` a `BASE_PATH`, nie úpravou šablón.

Netlify URL Jakuba:

`https://wfm-digital-cards.netlify.app/jakub-svec/`

GitHub Pages URL Jakuba:

`https://kvraniak29-blip.github.io/wfm-digital-cards/jakub-svec/`

QR kód sa vždy generuje podľa aktuálneho buildu.

## Pridanie ďalšieho makléra

Minimálny postup:

1. priprav JSON podľa vzoru,
2. priprav fotografiu,
3. spusti add-broker,
4. spusti build a testy.

Príkaz:

```powershell
npm run add-broker -- --config data/new-broker.json --photo C:\cesta\photo.jpg
npm run build
npm test
```

Príklad JSON:

```json
{
  "active": true,
  "slug": "jan-novak",
  "firstName": "Ján",
  "lastName": "Novák",
  "displayName": "Ján Novák",
  "title": "Realitný maklér",
  "company": "WFM Reality",
  "phoneDisplay": "+421 900 000 000",
  "phoneE164": "+421900000000",
  "email": "jan.novak@wfmreality.sk",
  "website": "https://www.wfmreality.sk/",
  "whatsapp": "https://wa.me/421900000000",
  "photo": "assets/brokers/jan-novak/photo.jpg",
  "social": {
    "facebook": null,
    "instagram": null
  }
}
```

Ak je sociálna sieť `null`, použije sa firemný profil z `company.json`.

## Výmena fotografie

Fotografiu uložte ako:

`assets/brokers/<slug>/photo.jpg`

Build ju prekopíruje do `dist/<slug>/photo.jpg`, použije v Open Graph a vloží do VCF. Placeholder sa nepoužíva; bez fotografie build zlyhá.

## VCF

VCF sa generuje automaticky vo formáte vCard 3.0 s CRLF koncami riadkov a Base64 JPEG fotografiou.

## QR

QR sa generuje automaticky do:

`dist/<slug>/qr.png`

Obsahuje finálnu produkčnú URL podľa `SITE_URL` a `BASE_PATH`.

## Deaktivovanie makléra

V JSON nastavte:

```json
"active": false
```

Maklér sa nezobrazí na koreňovej stránke a nebude mať generovaný výstup.

## NFC Tools

Zapíšte iba finálnu produkčnú URL vizitky:

1. Write
2. Add a record
3. URL / URI
4. vložiť finálnu URL
5. Write

Čip nezamykajte pred testom na Androide a iPhone.

## Rollback

Netlify: vrátiť predchádzajúci deploy v Netlify UI.

GitHub Pages: revertovať commit na `main` a nechať workflow znova nasadiť predchádzajúci stav.

## Bežné chyby

- `Fotografia neexistuje` - vložte `assets/brokers/<slug>/photo.jpg`.
- `Telefón nie je E.164` - telefón musí byť napríklad `+421904882685`.
- `Duplicitný slug` - každý maklér musí mať unikátny slug.
- `QR sa nedá dekódovať` - zopakujte build a test.
- GitHub token neplatný - spustite `gh auth login --hostname github.com --web --git-protocol https`.
