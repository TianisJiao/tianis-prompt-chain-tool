export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

export function imageType(bytes) {
  if (bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((n, i) => bytes[i] === n)) return { mime: "image/png", extension: "png" };
  if (bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return { mime: "image/jpeg", extension: "jpg" };
  if (bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP") return { mime: "image/webp", extension: "webp" };
  return null;
}

export function validateCaptions(value) {
  if (!Array.isArray(value) || value.length !== 3 || value.some(text => typeof text !== "string" || !text.trim() || text.trim().length > 240)) throw new Error("Invalid caption output");
  const captions = value.map(text => text.trim());
  if (new Set(captions).size !== 3) throw new Error("Duplicate caption output");
  return captions;
}

export function responseText(response) {
  if (response.status !== "completed") throw new Error("Incomplete model response");
  const content = (response.output ?? []).filter(item => item.type === "message").flatMap(item => item.content ?? []);
  if (content.some(item => item.type === "refusal")) throw new Error("Model declined this image");
  const text = content.filter(item => item.type === "output_text").map(item => item.text).join("").trim();
  if (!text) throw new Error("Empty model response");
  return text;
}
