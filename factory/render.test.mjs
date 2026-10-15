import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildRuns, render, duration, relative } from "./render.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const NOW = Date.parse("2026-10-15T12:30:00Z");
const events = readFileSync(join(here, "fixtures", "events.jsonl"), "utf8")
  .split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));

const byKey = (runs, repo, issue) => runs.filter((r) => r.repo === repo && r.issue === issue);

test("runs are grouped on repo + issue; the same number in two repos is two runs", () => {
  const runs = buildRuns(events, NOW);
  assert.equal(byKey(runs, "owner/app", 42).length, 1);
  assert.equal(byKey(runs, "owner/web", 42).length, 1);
});

test("a merged run has its PR, agent, model, outcome and duration", () => {
  const [run] = byKey(buildRuns(events, NOW), "owner/app", 42);
  assert.equal(run.outcome, "merged");
  assert.equal(run.agent, "ship-42-fix-login");
  assert.equal(run.model, "sonnet");
  assert.deepEqual(run.pr, { number: 7, url: "https://github.com/owner/app/pull/7" });
  assert.equal(run.started, "2026-10-15T10:00:00Z");
  assert.equal(run.ended, "2026-10-15T11:00:00Z");
  assert.equal(run.duration_ms, 3600000);
});

test("a live run with a resume is 'resumed' and counts its resumes", () => {
  const [run] = byKey(buildRuns(events, NOW), "owner/web", 42);
  assert.equal(run.outcome, "resumed");
  assert.equal(run.resumes, 1);
  assert.equal(run.ended, null);
  assert.equal(run.duration_ms, NOW - Date.parse("2026-10-15T10:00:00Z"));
});

test("a relaunch after failed starts a new run", () => {
  const runs = byKey(buildRuns(events, NOW), "owner/app", 50);
  assert.equal(runs.length, 2);
  assert.deepEqual(runs.map((r) => r.outcome), ["failed", "closed"]);
  assert.equal(runs[0].reason, "Rebase could not be resolved.");
  assert.equal(runs[1].model, "opus");
});

test("held and failed runs end; an orphan stays running with a mark", () => {
  const runs = buildRuns(events, NOW);
  assert.equal(byKey(runs, "owner/app", 60)[0].outcome, "held");
  assert.equal(byKey(runs, "owner/app", 62)[0].outcome, "failed");
  const [orphan] = byKey(runs, "owner/app", 61);
  assert.equal(orphan.ended, null);
  assert.equal(orphan.orphan, "in flight, no agent found");
});

test("events without a repo/issue (gate, error) do not make runs", () => {
  const runs = buildRuns(events, NOW);
  assert.ok(runs.every((r) => r.repo && r.issue));
});

test("an error event for a ticket with no run does not open one", () => {
  const runs = buildRuns([
    { ts: "2026-10-15T10:00:00Z", type: "error", repo: "owner/app", issue: 99, reason: "launch refused" },
    { ts: "2026-10-15T10:05:00Z", type: "launch", repo: "owner/app", issue: 98, title: "x" },
    { ts: "2026-10-15T10:10:00Z", type: "error", repo: "owner/app", issue: 98, reason: "resume refused" },
  ], NOW);
  assert.equal(byKey(runs, "owner/app", 99).length, 0);
  assert.equal(byKey(runs, "owner/app", 98).length, 1);
  assert.deepEqual(byKey(runs, "owner/app", 98)[0].events, ["launch", "error"]);
});

test("the recent list is capped at 50, newest first", () => {
  const many = [];
  for (let i = 1; i <= 60; i++) {
    const t = new Date(Date.parse("2026-10-01T00:00:00Z") + i * 3600000).toISOString().replace(/\.\d+Z$/, "Z");
    many.push({ ts: t, type: "claimed", repo: "owner/x", issue: i, title: `T${i}`, url: `u${i}` });
    many.push({ ts: t, type: "merged", repo: "owner/x", issue: i, title: `T${i}`, url: `u${i}` });
  }
  const html = render({ events: many }, NOW);
  const rows = html.split('<table id="recent">')[1].split("</table>")[0].match(/<tr>/g).length - 1;
  assert.equal(rows, 50);
  assert.ok(html.indexOf("#60</a>") < html.indexOf("#11</a>"));
  assert.ok(!html.includes("#10</a>"));
});

test("each Needs you category is in the rendered page", () => {
  const html = render({ events, lastTick: { ts: "2026-10-15T12:25:00Z", outcome: "idle" }, gate: { open: false, session_pct: 72, weekly_pct: 20, resets_at: "2026-10-15T14:00:00Z" } }, NOW);
  const needs = html.split('id="needs-you"')[1].split("</ul>")[0];
  assert.match(needs, /failed.*#62.*Tests red after the one fix/);
  assert.match(needs, /held.*#60.*PR #9.*Gate failed: no-automerge/);
  assert.match(needs, /no agent.*#61.*in flight, no agent found/);
  assert.match(needs, /needs setup.*owner\/new.*setup-repo\.sh owner\/new/);
  // owner/later was launched after its needs_setup, so it cleared.
  assert.ok(!needs.includes("owner/later"));
  // A failed ticket relaunched is no longer under Needs you.
  assert.ok(!/failed.*#50/.test(needs));
  assert.match(html, /Last tick.*2026-10-15 12:25:00 UTC.*5m ago.*idle/s);
  assert.match(html, /closed.*session 72%.*weekly 20%.*resets/s);
  assert.match(html, /<meta http-equiv="refresh" content="60">/);
});

test("the Now table lists running runs only", () => {
  const html = render({ events }, NOW);
  const running = html.split('<table id="running">')[1].split("</table>")[0];
  assert.match(running, /ship-42-web-thing/);
  assert.match(running, /#1<\/a> First/);
  assert.ok(!running.includes("ship-42-fix-login"));
});

test("an empty state renders", () => {
  const html = render({ events: [] }, NOW);
  assert.match(html, /no tick yet/);
  assert.match(html, /nothing needs you/);
  assert.match(html, /no runs yet/);
});

test("duration and relative formatting", () => {
  assert.equal(duration(42000), "42s");
  assert.equal(duration(125 * 60000), "2h 5m");
  assert.equal(duration(30 * 3600000), "1d 6h");
  assert.equal(relative("2026-10-15T12:25:00Z", NOW), "5m ago");
  assert.equal(relative("2026-10-15T14:00:00Z", NOW), "in 1h 30m");
});
