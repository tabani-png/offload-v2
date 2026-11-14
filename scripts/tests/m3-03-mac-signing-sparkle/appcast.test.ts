// RELEASE: promote and halt edit the appcast the way DEPLOYMENT section 4 describes. Pure string functions.
import { expect, test } from "bun:test";
import { halt, promote } from "../../../apps/mac/Packaging/appcast-edit";

const item = (v: string, build: string, beta: boolean) => `    <item>
      <title>${v}</title>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${v}</sparkle:shortVersionString>${beta ? "\n      <sparkle:channel>beta</sparkle:channel>" : ""}
      <enclosure url="https://downloads.example.test/Offload-${v}.zip" sparkle:edSignature="c2ln" length="10" type="application/octet-stream"/>
    </item>`;

const feed = (...items: string[]) => `<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Offload</title>
${items.join("\n")}
  </channel>
</rss>
`;

test("RELEASE: promote moves a beta item to stable with a phased rollout", () => {
  const xml = feed(item("1.2.4", "44", true), item("1.2.3", "42", false));
  const out = promote(xml, "1.2.4", 86400);
  const promoted = out.split("<item>")[1]!;
  expect(promoted).not.toContain("<sparkle:channel>");
  expect(promoted).toContain("<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>");
  // The other item is untouched.
  expect(out).toContain(item("1.2.3", "42", false));
  // Promoting twice keeps one interval element.
  expect(promote(out, "1.2.4", 3600).match(/phasedRolloutInterval>/g)!.length).toBe(2);
});

test("RELEASE: halt removes the item and nothing else", () => {
  const xml = feed(item("1.2.4", "44", true), item("1.2.3", "42", false));
  const out = halt(xml, "1.2.4");
  expect(out).not.toContain("1.2.4");
  expect(out).toContain(item("1.2.3", "42", false));
});

test("RELEASE: promote and halt refuse a version that is not exactly one item", () => {
  const xml = feed(item("1.2.3", "42", false));
  expect(() => promote(xml, "9.9.9", 86400)).toThrow(/no item/);
  expect(() => halt(feed(item("1.2.3", "42", true), item("1.2.3", "43", false)), "1.2.3")).toThrow(/2 items/);
  expect(() => promote(xml, "1.2.3", 0)).toThrow(/interval/);
});
