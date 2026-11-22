/**
 * The server-side leak scan: a transport check, not an independent masker (SECURITY_PRIVACY.md section 5,
 * ADR 0035). It catches a broken or old client by running the structured-secret rules again on text that should
 * already be masked: email address, Luhn-valid card number, IBAN with a valid checksum, API keys and tokens, a URL
 * with a path, query or fragment, and a phone number. Names are not scanned here (the device pseudonymises them).
 * Rules ported in spirit from the Swift `Detectors/*` and the old `brain/src/playbook/leak.ts`, rewritten.
 */

export const DETECTOR_NAMES = ["email", "key", "iban", "card", "url", "phone"] as const;
export type DetectorName = (typeof DETECTOR_NAMES)[number];

/** Pseudonyms (`<person:h_…>`) and router placeholders (`<person:qkzt.1>`): skipped before scanning. */
const ALLOWED_TOKEN_RE = /<(?:(?:person|email|phone|doc):h_[0-9a-f]{16}|person:[a-z]{4}\.(?:[0-9]+(?:\.first)?|me))>/g;
const ISO_DATE_RE = /\b\d{4}-\d{2}-\d{2}\b/g;

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/;

const KEY_RES: readonly RegExp[] = [
  /\bsk-ant-[A-Za-z0-9_-]{20,}/,
  /\bsk-[A-Za-z0-9_-]{20,}/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}/,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/,
  /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
  /\bxox[abpr]-[A-Za-z0-9-]{10,}/,
  /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/,
  /-----BEGIN [A-Z0-9 ]+-----/,
  /\bBearer [A-Za-z0-9._~+/=-]{16,}/,
];

/** IBAN length by country (SWIFT registry); a candidate with an unknown country or a wrong length is not an IBAN. */
const IBAN_LENGTH: Readonly<Record<string, number>> = {
  AD: 24, AE: 23, AL: 28, AT: 20, AZ: 28, BA: 20, BE: 16, BG: 22, BH: 22, BR: 29, BY: 28, CH: 21, CR: 22, CY: 28, CZ: 24,
  DE: 22, DK: 18, DO: 28, EE: 20, EG: 29, ES: 24, FI: 18, FO: 18, FR: 27, GB: 22, GE: 22, GI: 23, GL: 18, GR: 27, GT: 28,
  HR: 21, HU: 28, IE: 22, IL: 23, IQ: 23, IS: 26, IT: 27, JO: 30, KW: 30, KZ: 20, LB: 28, LC: 32, LI: 21, LT: 20, LU: 20,
  LV: 21, MC: 27, MD: 24, ME: 22, MK: 19, MR: 27, MT: 31, MU: 30, NL: 18, NO: 15, PK: 24, PL: 28, PS: 29, PT: 25, QA: 29,
  RO: 24, RS: 22, SA: 24, SC: 31, SE: 24, SI: 19, SK: 24, SM: 27, ST: 25, SV: 28, TL: 23, TN: 24, TR: 26, UA: 29, VA: 22,
  VG: 24, XK: 20,
};
const IBAN_CANDIDATE_RE = /(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])/g;

function ibanMod97(compact: string): boolean {
  const moved = compact.slice(4) + compact.slice(0, 4);
  let rem = 0;
  for (const ch of moved) {
    const v = ch >= "A" ? ch.charCodeAt(0) - 55 : ch.charCodeAt(0) - 48;
    rem = (v < 10 ? rem * 10 + v : rem * 100 + v) % 97;
  }
  return rem === 1;
}

function hasIban(text: string): boolean {
  for (const m of text.matchAll(IBAN_CANDIDATE_RE)) {
    const compact = m[0].replace(/ /g, "");
    const len = IBAN_LENGTH[compact.slice(0, 2)];
    if (len !== undefined && compact.length >= len && ibanMod97(compact.slice(0, len))) return true;
  }
  return false;
}

const CARD_RE = /(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)/g;

function luhn(digits: string): boolean {
  let sum = 0;
  let double = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return sum % 10 === 0;
}

function hasCard(text: string): boolean {
  for (const m of text.matchAll(CARD_RE)) {
    const digits = m[0].replace(/\D/g, "");
    if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) return true;
  }
  return false;
}

const URL_RE = /[A-Za-z][A-Za-z0-9+.-]{1,15}:\/\/([^\s<>"'`)\]]*)/g;

/** True for a URL that carries a path (more than a bare "/"), a query or a fragment. */
function hasUrlWithDetail(text: string): boolean {
  for (const m of text.matchAll(URL_RE)) {
    const rest = m[1] ?? "";
    const i = rest.search(/[/?#]/);
    if (i < 0) continue;
    if (rest.slice(i) !== "/") return true;
  }
  return false;
}

const PHONE_RUN_RE = /\+?\(?\d(?:[ .()-]*\d)+/g;

function hasPhone(text: string): boolean {
  for (const m of text.matchAll(PHONE_RUN_RE)) {
    const run = m[0];
    const digits = run.replace(/\D/g, "").length;
    if (run.startsWith("+")) {
      if (digits >= 8 && digits <= 15) return true;
      continue;
    }
    if (digits < 10 || digits > 15 || !/[ .()-]/.test(run)) continue;
    if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(run)) continue; // IPv4 address
    return true;
  }
  return false;
}

/**
 * The first detector that fires on `text`, or null. Pseudonyms and router placeholders are removed first (their hex
 * digits are not a phone number). Order: email, key, iban, card, url, phone, so a more specific rule names the leak
 * before a general one.
 */
export function scanForLeak(text: string): DetectorName | null {
  const t = text.replace(ALLOWED_TOKEN_RE, "\n").replace(ISO_DATE_RE, "\n");
  if (EMAIL_RE.test(t)) return "email";
  if (KEY_RES.some((re) => re.test(t))) return "key";
  if (hasIban(t)) return "iban";
  if (hasCard(t)) return "card";
  if (hasUrlWithDetail(t)) return "url";
  if (hasPhone(t)) return "phone";
  return null;
}
