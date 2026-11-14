/**
 * Person-name masker: the model router's second masking pass (m5-03, ADR 0005, SECURITY_PRIVACY section 5).
 *
 * Names the device missed become person placeholders: `<person:TAG.N>` for a full name or a surname,
 * `<person:TAG.N.first>` for a lone given name, `<person:TAG.me>` for the member's own name. `TAG` is a random 4-letter
 * tag per masker (one masker per run). Placeholder-shaped input that is not a device pseudonym and not this run's own
 * placeholder becomes `<name>` first. The name map lives only in this closure: never enumerable, logged or returned.
 *
 * Rules (no I/O, standard library only):
 * - a lexicon given name, optionally with middle initials and lowercase particles, followed by capitalised surname
 *   word(s) (hyphens allowed) is a full name; alone it is a lone given name;
 * - an ambiguous given name counts only with a following surname or after a cue or honorific;
 * - after an honorific, capitalised word(s) are a surname (or a full name); the honorific stays;
 * - after a cue, capitalised word(s) are a name even when not in the lexicon; "and" or "," continues the list;
 * - a word already known in this run as a given name or surname is masked wherever it appears;
 * - a possessive `'s` stays outside the placeholder.
 */
import { AMBIGUOUS_GIVEN_NAMES, CUES, GIVEN_NAMES, HONORIFICS, NOT_NAMES } from "./lexicon.ts";
import { STOP_WORDS } from "./stopwords.ts";

export interface NameMaskerOptions {
  ownName?: string;
  ownNameToModels?: "mask" | "keep";
  /** Random source for the run tag; defaults to crypto randomness. */
  random?: () => number;
}

export interface NameMasker {
  readonly tag: string;
  mask(text: string): string;
}

const GIVEN = new Set(GIVEN_NAMES);
const AMBIGUOUS = new Set(AMBIGUOUS_GIVEN_NAMES);
const HONORIFIC = new Set(HONORIFICS);
const NEVER = new Set<string>([...NOT_NAMES, ...STOP_WORDS, ...HONORIFICS]);
/** Sign-off cues need a comma or line break before a name that is not already a lexicon or known name. */
const SIGN_OFF = new Set(["Thanks", "Thank you", "Cheers", "Regards", "Best", "Signed,"]);
const PARTICLES = new Set([
  "van", "von", "der", "den", "de", "del", "della", "da", "di", "du", "la", "le", "bin", "ibn", "al", "el", "dos",
  "das", "ter", "ten",
]);
/** Given names that are also month abbreviations: not a name before a day number ("Jan 5"). */
const MONTH_ABBREV = new Set(["Jan", "Jun"]);

const DEVICE_PSEUDONYM = /^<(?:person|email|phone|doc):h_[0-9a-f]{16}>$/;
const WORD = /(?<![\p{L}\p{M}\p{N}_])\p{L}[\p{L}\p{M}]*(?:['’-]\p{L}[\p{L}\p{M}]*)*/gu;
const NAME_SHAPE = /^\p{Lu}(?=.*\p{Ll})[\p{L}\p{M}'’-]*$/u;
const INITIAL = /^\p{Lu}$/u;

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const CUE_BEFORE = new RegExp(
  `(?<![\\p{L}\\p{N}])(${[...CUES].sort((a, b) => b.length - a.length).map(escapeRe).join("|")})([,:]?)(\\s+)$`,
  "u",
);

function defaultRandom(): number {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return buf[0]! / 0x1_0000_0000;
}

function makeTag(random: () => number): string {
  let tag = "";
  for (let i = 0; i < 4; i++) {
    const r = random();
    const k = Math.min(25, Math.max(0, Math.floor((Number.isFinite(r) ? r : 0) * 26)));
    tag += String.fromCharCode(97 + k);
  }
  return tag;
}

interface Token {
  text: string;
  start: number;
  end: number;
  /** End including a possessive 's, for gap computation. */
  rawEnd: number;
}

type SpanKind = "full" | "given" | "surname" | "own" | "cue";
interface Span {
  kind: SpanKind;
  /** Token index range [from, to] inclusive that is replaced. */
  from: number;
  to: number;
  given?: string;
  surname?: string;
  key?: string;
}

interface Person {
  n: number;
  given?: string;
  surname?: string;
}

export function createNameMasker(opts: NameMaskerOptions = {}): NameMasker {
  const tag = makeTag(opts.random ?? defaultRandom);
  const ownMode = opts.ownNameToModels ?? "mask";
  const ownWords = (opts.ownName ?? "").trim().split(/\s+/).filter((w) => w.length > 0);
  const ownSet = new Set(ownWords);

  // Per-run name map. Closure only: never exposed, logged or returned.
  let nextN = 1;
  const byFull = new Map<string, Person>();
  const byGiven = new Map<string, Person>();
  const bySurname = new Map<string, Person>();

  const ownPlaceholder = new RegExp(`^<person:${tag}\\.(?:me|[1-9][0-9]*(?:\\.first)?)>$`);
  const keepAsIs = (p: string): boolean => p === "<name>" || DEVICE_PSEUDONYM.test(p) || ownPlaceholder.test(p);

  function newPerson(given?: string, surname?: string): Person {
    const p: Person = { n: nextN++ };
    if (given !== undefined) p.given = given;
    if (surname !== undefined) p.surname = surname;
    return p;
  }

  function registerFull(given: string, surname: string, key: string): Person {
    let p = byFull.get(key);
    if (!p) {
      const g = byGiven.get(given);
      p = g && g.surname === undefined ? g : newPerson(given, surname);
      if (p.surname === undefined) p.surname = surname;
      byFull.set(key, p);
    }
    if (!byGiven.has(given)) byGiven.set(given, p);
    if (!bySurname.has(surname)) bySurname.set(surname, p);
    return p;
  }

  function registerGiven(given: string): Person {
    let p = byGiven.get(given);
    if (!p) {
      p = newPerson(given);
      byGiven.set(given, p);
    }
    return p;
  }

  function registerSurname(surname: string): Person {
    let p = bySurname.get(surname);
    if (!p) {
      p = newPerson(undefined, surname);
      bySurname.set(surname, p);
    }
    return p;
  }

  const ph = (n: number | "me", first = false): string => `<person:${tag}.${n}${first ? ".first" : ""}>`;

  function maskPlain(text: string): string {
    // Tokenise words; placeholders and anything between them act as gaps.
    const tokens: Token[] = [];
    for (const m of text.matchAll(WORD)) {
      let word = m[0];
      const start = m.index!;
      const rawEnd = start + word.length;
      const poss = /['’]s$/.exec(word);
      if (poss && word.length > 2) word = word.slice(0, -2);
      tokens.push({ text: word, start, end: start + word.length, rawEnd });
    }
    const gap = (i: number): string => text.slice(tokens[i - 1]!.rawEnd, tokens[i]!.start);
    const hasPossessive = (i: number): boolean => tokens[i]!.rawEnd !== tokens[i]!.end;
    const isOwn = (i: number): boolean => ownSet.has(tokens[i]!.text);
    const shaped = (i: number): boolean => NAME_SHAPE.test(tokens[i]!.text);
    /** A capitalised word that may be part of a name (not a stop word, not the member's own name). */
    const nameable = (i: number): boolean =>
      i < tokens.length && shaped(i) && !NEVER.has(tokens[i]!.text) && !isOwn(i);
    const spaceBefore = (i: number): boolean => i > 0 && /^[  ]$/.test(gap(i));

    /** From a first name word at i, extend over initials, particles and up to two surname words. */
    function extendSurname(i: number): { to: number; surname?: string } {
      if (hasPossessive(i)) return { to: i };
      let j = i + 1;
      let last = i;
      let surname: string | undefined;
      let words = 0;
      let afterInitial = false;
      while (j < tokens.length && words < 2) {
        const g = gap(j);
        const t = tokens[j]!.text;
        const sep = afterInitial ? /^\.?[  ]$/ : /^[  ]$/;
        afterInitial = false;
        if (!sep.test(g)) break;
        if (INITIAL.test(t) && words === 0 && j + 1 < tokens.length && /^\.?[  ]$/.test(gap(j + 1))) {
          afterInitial = true;
          j++;
          continue;
        }
        if (PARTICLES.has(t) && words === 0) {
          let k = j + 1;
          while (k < tokens.length && PARTICLES.has(tokens[k]!.text) && spaceBefore(k)) k++;
          if (k < tokens.length && spaceBefore(k) && nameable(k)) {
            j = k;
            continue;
          }
          break;
        }
        if (!nameable(j)) break;
        surname = t;
        last = j;
        words++;
        if (hasPossessive(j)) break;
        j++;
      }
      return surname === undefined ? { to: i } : { to: last, surname };
    }

    function ownSpanAt(i: number): number | undefined {
      if (ownWords.length === 0 || tokens[i]!.text !== ownWords[0]) {
        return isOwn(i) ? i : undefined;
      }
      let j = i;
      for (let k = 1; k < ownWords.length; k++) {
        if (j + 1 >= tokens.length || tokens[j + 1]!.text !== ownWords[k] || !/^\s+$/.test(gap(j + 1))) return i;
        j++;
      }
      return j;
    }

    const cueBefore = (i: number): RegExpExecArray | null =>
      CUE_BEFORE.exec(text.slice(Math.max(0, tokens[i]!.start - 40), tokens[i]!.start));

    const spans: Span[] = [];
    const keyOf = (from: number, to: number): string =>
      tokens
        .slice(from, to + 1)
        .map((t) => t.text)
        .filter((w) => !INITIAL.test(w))
        .join(" ");

    let listCue = false; // inside a cue-introduced list ("cc A and B")
    for (let i = 0; i < tokens.length; i++) {
      const t = tokens[i]!.text;
      const own = ownSpanAt(i);
      if (own !== undefined) {
        spans.push({ kind: "own", from: i, to: own });
        i = own;
        listCue = false;
        continue;
      }
      if (!shaped(i)) {
        if (!(listCue && t === "and")) listCue = false;
        continue;
      }

      // Honorific + name: keep the honorific, mask what follows.
      if (HONORIFIC.has(t)) {
        const n = i + 1;
        if (n < tokens.length && /^\.?[  ]+$/.test(gap(n)) && nameable(n)) {
          const ext = extendSurname(n);
          if (ext.surname !== undefined) {
            spans.push({ kind: "full", from: n, to: ext.to, given: tokens[n]!.text, surname: ext.surname, key: keyOf(n, ext.to) });
            i = ext.to;
          } else {
            spans.push({ kind: "surname", from: n, to: n, surname: tokens[n]!.text });
            i = n;
          }
        }
        listCue = false;
        continue;
      }

      if (!nameable(i)) {
        listCue = false;
        continue;
      }
      if (MONTH_ABBREV.has(t) && /^\s+\d/.test(text.slice(tokens[i]!.rawEnd))) continue;

      // Cue + name (lexicon or not), and lists continued with "and" or ",".
      const cue = cueBefore(i);
      let cued = false;
      if (cue) {
        const word = cue[1]!;
        const sep = cue[2]! + cue[3]!;
        const known = GIVEN.has(t) || byGiven.has(t) || bySurname.has(t);
        cued = !SIGN_OFF.has(word) || known || /[,\n]/.test(sep) || word.endsWith(",");
      } else if (listCue && i > 0) {
        cued = /^(?:\s*,\s*|\s+)$/.test(gap(i)) || /^\s+$/.test(gap(i));
      }

      const ext = extendSurname(i);
      if (GIVEN.has(t) || (AMBIGUOUS.has(t) && (ext.surname !== undefined || cued))) {
        if (ext.surname !== undefined) {
          spans.push({ kind: "full", from: i, to: ext.to, given: t, surname: ext.surname, key: keyOf(i, ext.to) });
        } else {
          spans.push({ kind: "given", from: i, to: i, given: t });
        }
        i = ext.to;
        listCue = cued || listCue;
        continue;
      }
      if (cued) {
        if (ext.surname !== undefined) {
          spans.push({ kind: "full", from: i, to: ext.to, given: t, surname: ext.surname, key: keyOf(i, ext.to) });
        } else {
          spans.push({ kind: "cue", from: i, to: i, given: t });
        }
        i = ext.to;
        listCue = true;
        continue;
      }
      listCue = false;
    }

    // Full names first (numbered by appearance), then the rest.
    const out = new Map<number, string>();
    const covered = new Set<number>();
    for (const s of spans) for (let k = s.from; k <= s.to; k++) covered.add(k);
    for (const s of spans) {
      if (s.kind === "full") out.set(s.from, ph(registerFull(s.given!, s.surname!, s.key!).n));
    }
    for (const s of spans) {
      if (s.kind === "own") {
        out.set(s.from, ownMode === "mask" ? ph("me") : text.slice(tokens[s.from]!.start, tokens[s.to]!.end));
      } else if (s.kind === "given") {
        out.set(s.from, ph(registerGiven(s.given!).n, true));
      } else if (s.kind === "surname") {
        out.set(s.from, ph(registerSurname(s.surname!).n));
      } else if (s.kind === "cue") {
        const word = s.given!;
        if (!byGiven.has(word) && bySurname.has(word)) out.set(s.from, ph(bySurname.get(word)!.n));
        else out.set(s.from, ph(registerGiven(word).n, true));
      }
    }
    // Words known in this run, wherever they appear.
    for (let i = 0; i < tokens.length; i++) {
      if (covered.has(i) || !shaped(i) || isOwn(i)) continue;
      const t = tokens[i]!.text;
      const g = byGiven.get(t);
      if (g) {
        spans.push({ kind: "given", from: i, to: i });
        out.set(i, ph(g.n, true));
        continue;
      }
      const s = bySurname.get(t);
      if (s) {
        spans.push({ kind: "surname", from: i, to: i });
        out.set(i, ph(s.n));
      }
    }

    spans.sort((a, b) => a.from - b.from);
    let result = "";
    let pos = 0;
    for (const s of spans) {
      const start = tokens[s.from]!.start;
      const end = tokens[s.to]!.end;
      result += text.slice(pos, start) + out.get(s.from)!;
      pos = end;
    }
    return result + text.slice(pos);
  }

  function mask(text: string): string {
    // 1. Placeholder-shaped input that is not a device pseudonym or this run's own placeholder becomes <name>.
    const pre = text.replace(/<person:[^<>]*>/g, (p) => (keepAsIs(p) ? p : "<name>"));
    // 2. Mask names in the text between placeholders that pass unchanged.
    let result = "";
    let pos = 0;
    for (const m of pre.matchAll(/<[a-z]+:[^<>\s]*>|<name>/g)) {
      if (!keepAsIs(m[0])) continue;
      result += maskPlain(pre.slice(pos, m.index)) + m[0];
      pos = m.index! + m[0].length;
    }
    return result + maskPlain(pre.slice(pos));
  }

  return Object.freeze({ tag, mask });
}
