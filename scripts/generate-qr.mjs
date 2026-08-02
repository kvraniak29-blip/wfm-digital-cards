import QRCode from "qrcode";

export async function generateQr(file, url) {
  await QRCode.toFile(file, url, {
    width: 560,
    margin: 3,
    errorCorrectionLevel: "M",
    color: {
      dark: "#071d31",
      light: "#ffffff"
    }
  });
}
