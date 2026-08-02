# WFM Digital Cards

Statický systém digitálnych NFC vizitiek pre realitných maklérov WFM Reality.

## Architektúra

- `config/company.json` - spoločná firemná konfigurácia, farby a sociálne siete.
- `config/deployment.json` - URL nastavenia pre Netlify a GitHub Pages.
- `data/brokers/*.json` - zdroj pravdy pre každého makléra.
- `data/status/*.json` - stav posledného generovania konkrétneho makléra.
- `assets/brokers/<slug>/photo.jpg` - profilová fotografia makléra.
- `assets/branding/logo.png` - spoločné logo WFM Reality.
- `assets/branding/background.png` - spoločné pozadie vizitiek.
- `src/broker-template.html` - spoločná HTML šablóna vizitky.
- `src/index-template.html` - spoločná HTML šablóna koreňovej stránky.
- `src/styles.css` - spoločný dizajn.
- `scripts/generate-vcf.mjs` - spoločný VCF generátor.
- `scripts/generate-qr.mjs` - spoločný QR generátor.
- `dist/` - výsledok buildu pripravený na hosting.

Kontaktné údaje sa nemenia ručne v HTML, VCF ani QR. Zdrojom pravdy je JSON makléra.

## Bežné použitie cez Windows aplikáciu

Spustite:

```powershell
.\Spustit-WFM-Generator.cmd
```

Aplikácia beží ako bežný používateľ, nevyžaduje správcu a zapisuje logy do `logs/`.

Postup:

1. kliknite na `Vybrať priečinok makléra`,
2. vyberte presne jeden vstupný priečinok,
3. kliknite na `Načítať a skontrolovať`,
4. upravte načítané údaje vo formulári,
5. kliknite na `Generovať vizitku`,
6. ak chcete publikovať, zaškrtnite `Po úspechu publikovať na GitHub Pages`.

Automatický režim:

```powershell
.\tools\WFM-Card-Generator.ps1 -BrokerFolder "C:\cesta\Maklér" -Generate -Publish -Silent
```

Exit code `0` znamená PASS. Nenulový exit code znamená FAIL.

## Vstupný priečinok nového makléra

Používateľ vždy vyberá iba jeden konkrétny priečinok. Systém nikdy automaticky neimportuje všetky priečinky v koreňovom adresári.

Priečinok musí obsahovať:

- presne jeden `.vcf` súbor,
- presne jednu fotografiu `.jpg`, `.jpeg` alebo `.png`.

Voliteľne môže obsahovať `broker.json`, ktorý prepíše údaje načítané z VCF.

Príklad:

```text
Kristián Vraniak/
├── fotografia.png
└── kontakt.vcf
```

Import cez CLI:

```powershell
npm run import-broker -- --folder "C:\cesta\Kristián Vraniak"
```

Import spracuje iba uvedený priečinok. Produkčný build potom vygeneruje všetkých už registrovaných aktívnych maklérov z `data/brokers/`.

## Kanonické úložisko

Po úspešnom importe sa údaje skopírujú do:

- `data/brokers/<slug>.json`
- `assets/brokers/<slug>/photo.jpg`
- `data/status/<slug>.json`

Zdrojový priečinok potom už nie je potrebný na ďalší build. Môžete ho ponechať, presunúť do archívu alebo odstrániť. Aplikácia ho nemaže automaticky.

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

## Pridanie ďalšieho makléra bez aplikácie

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

VCF obsahuje:

- pracovný web,
- WhatsApp URL,
- Facebook URL,
- Instagram URL,
- `X-SOCIALPROFILE` polia,
- Apple kompatibilné `itemN.URL` a `itemN.X-ABLabel` polia.

Android, iPhone, Google Kontakty a Outlook môžu vlastné sociálne polia zobrazovať rozdielne. Preto zostávajú všetky sociálne odkazy aj ako tlačidlá na webovej vizitke.

## QR

QR sa generuje automaticky do:

`dist/<slug>/qr.png`

Obsahuje finálnu produkčnú URL podľa `SITE_URL` a `BASE_PATH`.

## Logo a pozadie

Spoločný branding je v:

- `assets/branding/logo.png`
- `assets/branding/background.png`

Build skončí FAIL, ak niektorý súbor chýba alebo nie je PNG. Logo sa zobrazuje v hornej časti vizitky a odkazuje na `https://www.wfmreality.sk/`. Pozadie sa kopíruje do `dist/assets/branding/background.png` a používa sa cez CSS s tmavou vrstvou kvôli čitateľnosti.

Firemné farby a cesty k brandingu sa menia v `config/company.json`.

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

Lokálny návrat na stav pred aplikáciou:

```powershell
git reset --hard backup-before-import-app-20260802
```

Použite iba vtedy, keď chcete zahodiť všetky neskoršie lokálne zmeny.

## Bežné chyby

- `Fotografia neexistuje` - vložte `assets/brokers/<slug>/photo.jpg`.
- `Telefón nie je E.164` - telefón musí byť napríklad `+421904882685`.
- `Duplicitný slug` - každý maklér musí mať unikátny slug.
- `QR sa nedá dekódovať` - zopakujte build a test.
- `Branding súbor chýba` - doplňte `assets/branding/logo.png` alebo `assets/branding/background.png`.
- `Priečinok musí obsahovať presne jeden VCF súbor` - odstráňte alebo presuňte duplicitný VCF zo vstupného priečinka.
- `Priečinok musí obsahovať presne jednu fotografiu` - nechajte vo vstupnom priečinku iba jednu fotku.
- GitHub token neplatný - spustite `gh auth login --hostname github.com --web --git-protocol https`.
