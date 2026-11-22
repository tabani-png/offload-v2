import { expect, test } from "bun:test";
import { FIX_KIND_TABLE, FIX_RULES, fixRules, type FixProposal, type FixRules } from "../../src/opportunities/rules.ts";
import { rankOpportunities } from "../../src/opportunities/score.ts";
import { figure, type EvidenceRef } from "../../src/records/figure.ts";
import type { TaskEvidence } from "../../src/opportunities/types.ts";
import { EXCEL, ev, evalArithmetic, GDOCS, GMAIL, LEDGERLY, QBO, SLACK, STRIPE, VSCODE, weekWith, ZOOM } from "./fixtures.ts";

// Built per call so each test fails on its own while the rules are missing.
const rules: FixRules = { propose: (e) => fixRules().propose(e) };
const kinds = (p: FixProposal | null) => p?.options.map((o) => o.kind) ?? null;
const copy = ev({ systems: [STRIPE, QBO] });
const report = ev({ name: "Friday numbers", minutes: 45, instances: 1, median_minutes: 45, days: 1, cadence: { kind: "weekly", weekday: 4, hour: 16 }, systems: [GDOCS, STRIPE] });
const triage = ev({ name: "Sort the inbox", minutes: 120, instances: 20, median_minutes: 3, days: 5, systems: [GMAIL] });
const records = ev({ name: "Enter invoices", systems: [GDOCS, GMAIL, LEDGERLY] });
const ALL: TaskEvidence[] = [copy, report, triage, records, ev({ systems: [EXCEL, LEDGERLY], minutes: 90 }), ev({ systems: [LEDGERLY], minutes: 90 }), ev({ systems: [EXCEL], minutes: 90 })];

test("RULE: copy between two web apps gets a connector pair through an API integration first", () => {
  const p = rules.propose(copy)!;
  expect(p.rule).toBe("app_to_app_copy");
  expect(kinds(p)).toEqual(["api_integration", "browser_automation"]);
  expect(p.options[0]!.steps.map((s) => [s.system, s.adapter, s.runs_on])).toEqual([["dashboard.stripe.com", "openapi", "cloud"], ["qbo.intuit.com", "composio", "cloud"]]);
  expect(FIX_RULES.map((r) => r.kind)).toEqual(["report_assembly", "email_triage", "email_to_records", "app_to_app_copy", "single_app_entry"]);
});

test("RULE: a report assembled on a cadence gets a scheduled routine", () => {
  const p = rules.propose(report)!;
  expect(p.rule).toBe("report_assembly");
  expect(kinds(p)).toEqual(["scheduled_routine", "script"]);
  expect(p.options[0]!.title).toBe("A scheduled routine does it every Friday at 16:00");
  // Without the cadence the same task is a copy between apps.
  expect(rules.propose({ ...report, cadence: null, instances: 4 })!.rule).toBe("app_to_app_copy");
});

test("RULE: short repeated mail-only work gets mail rules as a setup change", () => {
  const p = rules.propose(triage)!;
  expect(p.rule).toBe("email_triage");
  expect(kinds(p)).toEqual(["setup_change", "agent_workflow"]);
  expect(p.options[0]!.steps).toEqual([{ system: "mail.google.com", surface: "web", provider: "gmail", label: "Gmail", adapter: null, runs_on: "device" }]);
  expect(p.options[0]!.title).toBe("Rules in Gmail handle it for you");
  // Long mail work is not triage.
  expect(rules.propose({ ...triage, median_minutes: 25 })?.rule ?? null).not.toBe("email_triage");
});

test("RULE: mail turned into records in other apps gets an agent workflow, an integration and browser automation", () => {
  const p = rules.propose(records)!;
  expect(p.rule).toBe("email_to_records");
  expect(kinds(p)).toEqual(["api_integration", "agent_workflow", "browser_automation"]);
  const agent = p.options.find((o) => o.kind === "agent_workflow")!;
  expect(agent.steps.map((s) => [s.system, s.adapter])).toEqual([["app.ledgerly.example", "browser"], ["docs.google.com", "composio"], ["mail.google.com", "composio"]]);
  // With no connector on any step, cloud kinds are not offered.
  expect(kinds(rules.propose(ev({ systems: [{ id: "com.apple.mail", surface: "desktop", work_kind: "email" }, LEDGERLY, EXCEL] })))).toEqual(["script", "browser_automation"]);
});

test("RULE: fewer than 3 instances, or only code, meetings or chat, gets no fix", () => {
  expect(rules.propose({ ...copy, instances: 2 })).toBeNull();
  expect(rules.propose(ev({ systems: [VSCODE], instances: 10, minutes: 120 }))).toBeNull();
  expect(rules.propose(ev({ systems: [ZOOM], instances: 10, minutes: 300 }))).toBeNull();
  expect(rules.propose(ev({ systems: [SLACK, ZOOM], instances: 10, minutes: 100 }))).toBeNull();
  expect(rules.propose(ev({ systems: [] }))).toBeNull();
  // A cadence is repetition enough.
  expect(rules.propose(report)).not.toBeNull();
});

test("ESTIMATE: golden evidence gives the exact options with Figures", () => {
  const refs: EvidenceRef[] = [{ kind: "week_record", id: "2026-W45" }, { kind: "episode", id: "ep_a" }, { kind: "episode", id: "ep_b" }];
  const p = rules.propose(copy)!;
  expect(p).toEqual({
    task_key: "k_000000000001", rule: "app_to_app_copy", leave_alone_first: false,
    options: [
      {
        option_no: 1, kind: "api_integration", rule: "app_to_app_copy", recommended: true,
        title: "Connect Stripe and QuickBooks with an integration",
        detail: "Seen 6 times this week (60 min). Steps: Stripe (direct API), QuickBooks (Composio).",
        steps: [
          { system: "dashboard.stripe.com", surface: "web", provider: "stripe", label: "Stripe", adapter: "openapi", runs_on: "cloud" },
          { system: "qbo.intuit.com", surface: "web", provider: "quickbooks", label: "QuickBooks", adapter: "composio", runs_on: "cloud" },
        ],
        figures: {
          weekly_hours_saved: figure(0.75, "hours_per_week", "(60 min x share 0.8 - 6 instances x 0.5 min review) / 60 = 0.75 h per week", refs),
          setup_hours: figure(4, "hours", "base 2 + 1 x 2 steps = 4 h", refs),
          payback_weeks: figure(5.33, "weeks", "setup 4 h / 0.75 h saved per week = 5.33 weeks", refs),
          confidence: figure(0.7, "ratio", "api_integration 0.7 x instances 1 x days 1 = 0.7", refs),
        },
      },
      {
        option_no: 2, kind: "browser_automation", rule: "app_to_app_copy", recommended: false,
        title: "Browser automation does the steps in Stripe and QuickBooks while you watch",
        detail: "Seen 6 times this week (60 min). Steps: Stripe (browser, on your Mac), QuickBooks (browser, on your Mac).",
        steps: [
          { system: "dashboard.stripe.com", surface: "web", provider: "stripe", label: "Stripe", adapter: "browser", runs_on: "device" },
          { system: "qbo.intuit.com", surface: "web", provider: "quickbooks", label: "QuickBooks", adapter: "browser", runs_on: "device" },
        ],
        figures: {
          weekly_hours_saved: figure(0.5, "hours_per_week", "(60 min x share 0.6 - 6 instances x 1 min review) / 60 = 0.5 h per week", refs),
          setup_hours: figure(5, "hours", "base 3 + 1 x 2 steps = 5 h", refs),
          payback_weeks: figure(10, "weeks", "setup 5 h / 0.5 h saved per week = 10 weeks", refs),
          confidence: figure(0.5, "ratio", "browser_automation 0.5 x instances 1 x days 1 = 0.5", refs),
        },
      },
    ],
    estimate: { taskKey: "k_000000000001", fixKind: "api_integration", weeklyHoursSaved: 0.75, setupHours: 4, ruleConfidence: 0.7, workKind: "browse", option: p.options[0]! },
  });
  expect(FIX_KIND_TABLE.api_integration).toEqual({ share: 0.8, reviewMinutes: 0.5, setupBase: 2, setupPerStep: 1, confidence: 0.7 });
});

test("ESTIMATE: every figure's arithmetic reproduces its value", () => {
  let n = 0;
  for (const e of ALL) {
    const p = rules.propose(e);
    expect(p).not.toBeNull();
    for (const o of p!.options) {
      for (const [name, f] of Object.entries(o.figures)) {
        const tol = name === "confidence" ? 0.0005 : 0.005;
        expect({ name, kind: o.kind, ok: Math.abs(evalArithmetic(f.arithmetic) - f.value) <= tol }).toEqual({ name, kind: o.kind, ok: true });
        expect(f.arithmetic.endsWith(String(f.value)) || f.arithmetic.includes(`= ${f.value} `)).toBe(true);
        n++;
      }
      expect(o.figures.payback_weeks.value).toBe(Math.round((o.figures.setup_hours.value / o.figures.weekly_hours_saved.value) * 100) / 100);
    }
  }
  expect(n).toBeGreaterThan(40);
  // A browser step in a cloud kind costs setup and confidence.
  const agent = rules.propose(records)!.options.find((o) => o.kind === "agent_workflow")!;
  expect(agent.figures.setup_hours.arithmetic).toBe("base 3 + 1 x 3 steps + 1 x 1 browser steps = 7 h");
  expect(agent.figures.confidence.arithmetic).toBe("agent_workflow 0.6 x instances 1 x days 1 x browser step 0.85 = 0.51");
});

test("ESTIMATE: an option that saves nothing is dropped and no option left gives no proposal", () => {
  // 10 min over 6 instances: browser automation's review time eats its saving.
  expect(kinds(rules.propose({ ...copy, minutes: 10 }))).toEqual(["api_integration"]);
  expect(rules.propose({ ...copy, minutes: 3 })).toBeNull();
});

test("OPTIONS: one to three options numbered from 1, the best value first and recommended", () => {
  for (const e of ALL) {
    const p = rules.propose(e)!;
    expect(p.options.length).toBeGreaterThanOrEqual(1);
    expect(p.options.length).toBeLessThanOrEqual(3);
    expect(p.options.map((o) => o.option_no)).toEqual(p.options.map((_, i) => i + 1));
    const value = (o: (typeof p.options)[number]) => (o.figures.weekly_hours_saved.value * o.figures.confidence.value) / Math.max(1, o.figures.payback_weeks.value);
    const values = p.options.map(value);
    expect(values).toEqual([...values].sort((a, b) => b - a));
    expect(p.leave_alone_first).toBe(false);
    expect(p.options.map((o) => o.recommended)).toEqual(p.options.map((_, i) => i === 0));
    expect(p.estimate.option).toEqual(p.options[0]!);
    expect([p.estimate.fixKind, p.estimate.weeklyHoursSaved, p.estimate.setupHours, p.estimate.ruleConfidence]).toEqual([
      p.options[0]!.kind, p.options[0]!.figures.weekly_hours_saved.value, p.options[0]!.figures.setup_hours.value, p.options[0]!.figures.confidence.value,
    ]);
  }
});

test("OPTIONS: below 0.5 h a week leave alone comes first and no option is recommended", () => {
  const p = rules.propose({ ...copy, minutes: 20, instances: 3, days: 1 })!;
  expect(p.leave_alone_first).toBe(true);
  expect(p.options.map((o) => o.recommended)).toEqual([false, false]);
  expect(p.options.map((o) => o.figures.weekly_hours_saved.value)).toEqual([0.24, 0.15]);
  // One instance factor and one days factor below 1.
  expect(p.options[0]!.figures.confidence.arithmetic).toBe("api_integration 0.7 x instances 0.85 x days 0.85 = 0.506");
});

test("RANK: the fix rules' estimates are ranked and an empty profile keeps their order", () => {
  const tasks = [
    { task_key: "k_000000000001", name: "Copy payouts into the books", minutes: 60, instances: 6, median: 10 },
    { task_key: "k_000000000002", name: "Sort the inbox", minutes: 120, instances: 20, median: 3 },
    { task_key: "k_000000000003", name: "Enter invoices", minutes: 60, instances: 6, median: 10 },
    { task_key: "k_000000000004", name: "Review code", minutes: 300, instances: 10, median: 30 },
  ];
  const week = weekWith("2026-W45", "2026-11-02", "2026-11-08", tasks);
  const evidence = [copy, { ...triage, task_key: "k_000000000002" }, { ...records, task_key: "k_000000000003" }, ev({ task_key: "k_000000000004", systems: [VSCODE], minutes: 300, instances: 10 })];
  const estimates = evidence.map((e) => rules.propose(e)).filter((p): p is FixProposal => p !== null).map((p) => p.estimate);
  expect(estimates.map((e) => e.taskKey)).toEqual(["k_000000000001", "k_000000000002", "k_000000000003"]);
  const ranked = rankOpportunities({ isoWeek: "2026-W45", week, recent: [week], estimates, drains: [], goals: [], taskVectors: new Map(), answers: [] });
  const value = (e: (typeof estimates)[number]) => (e.weeklyHoursSaved * e.ruleConfidence) / Math.max(1, e.setupHours / e.weeklyHoursSaved);
  const order = [...estimates].sort((a, b) => value(b) - value(a)).map((e) => e.taskKey);
  expect(ranked.map((r) => r.task_key)).toEqual(order);
  for (const r of ranked) {
    const e = estimates.find((x) => x.taskKey === r.task_key)!;
    expect(r.factors.weekly_hours_saved.value).toBe(e.weeklyHoursSaved);
    expect(r.factors.payback_weeks.value).toBe(e.option!.figures.payback_weeks.value);
    expect(r.factors.confidence.value).toBe(e.ruleConfidence);
  }
});
