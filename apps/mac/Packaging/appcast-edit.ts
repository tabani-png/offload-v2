// Appcast edits for promote-mac.yml (DEPLOYMENT section 4): promote a beta item to stable with a phased rollout, or
// halt an item by removing it. Pure string functions over generate_appcast's output; the caller re-signs the feed.
// Usage: bun appcast-edit.ts <appcast.xml> <promote|halt> <version> [interval-seconds]
import { readFileSync, writeFileSync } from "node:fs";

const ITEM = /[ \t]*<item>[\s\S]*?<\/item>\n?/g;

function itemsFor(xml: string, version: string): RegExpMatchArray[] {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`version must be MAJOR.MINOR.PATCH, got ${version}`);
  const tag = `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`;
  const found = [...xml.matchAll(ITEM)].filter((m) => m[0].includes(tag));
  if (found.length === 0) throw new Error(`no item for ${version} in the appcast`);
  if (found.length > 1) throw new Error(`${found.length} items for ${version} in the appcast; expected one`);
  return found;
}

function replaceAt(xml: string, m: RegExpMatchArray, body: string): string {
  return xml.slice(0, m.index!) + body + xml.slice(m.index! + m[0].length);
}

/** Moves the item for `version` to the stable channel with `sparkle:phasedRolloutInterval` (seconds per group). */
export function promote(xml: string, version: string, intervalSeconds: number): string {
  if (!Number.isInteger(intervalSeconds) || intervalSeconds < 1) throw new Error("phased rollout interval must be a positive integer");
  const [m] = itemsFor(xml, version);
  let item = m![0]
    .replace(/\n?[ \t]*<sparkle:channel>[^<]*<\/sparkle:channel>/g, "")
    .replace(/\n?[ \t]*<sparkle:phasedRolloutInterval>[^<]*<\/sparkle:phasedRolloutInterval>/g, "");
  item = item.replace(
    /(\n[ \t]*)(<sparkle:shortVersionString>[^<]*<\/sparkle:shortVersionString>)/,
    `$1$2$1<sparkle:phasedRolloutInterval>${intervalSeconds}</sparkle:phasedRolloutInterval>`,
  );
  return replaceAt(xml, m!, item);
}

/** Removes the item for `version` (Sparkle only moves forward; roll forward by re-releasing as a higher version). */
export function halt(xml: string, version: string): string {
  const [m] = itemsFor(xml, version);
  return replaceAt(xml, m!, "");
}

if (import.meta.main) {
  const [file, action, version, interval] = process.argv.slice(2);
  if (!file || !version || (action !== "promote" && action !== "halt")) {
    console.error("usage: bun appcast-edit.ts <appcast.xml> <promote|halt> <version> [interval-seconds]");
    process.exit(2);
  }
  const xml = readFileSync(file, "utf8");
  try {
    const out = action === "promote" ? promote(xml, version, Number(interval ?? 86400)) : halt(xml, version);
    writeFileSync(file, out);
    console.log(`appcast: ${action} ${version}`);
  } catch (e) {
    console.error(`appcast: ${(e as Error).message}`);
    process.exit(1);
  }
}
