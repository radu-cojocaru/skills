import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { record, prFor } from "./record.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const NOW = "2026-10-15T12:05:01Z";
const REPO = "owner/app";

function issue(number, labels, extra = {}) {
  return {
    repository: { nameWithOwner: REPO, name: "app" },
    number,
    title: `Ticket ${number}`,
    labels: labels.map((name) => ({ name })),
    url: `https://github.com/${REPO}/issues/${number}`,
    ...extra,
  };
}

function run(overrides) {
  return record({ now: NOW, snapshot: {}, issues: [], prs: {}, lookups: {}, launches: [], live: [], ...overrides });
}

function types(events) {
  return events.map((e) => e.type);
}

test("idle tick: nothing changes, no events, snapshot unchanged", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: issue(42, []).url } };
  const out = run({ snapshot, issues: [issue(42, ["agent:working"])] });
  assert.deepEqual(out.events, []);
  assert.deepEqual(out.snapshot, snapshot);
});

test("a claim is one claimed event with the launch's agent and model", () => {
  const launches = [{ full: REPO, repo: "app", issue: 42, name: "ship-42-ticket-42", model: "opus" }];
  const out = run({ issues: [issue(42, ["agent:working"])], launches });
  assert.deepEqual(types(out.events), ["claimed"]);
  assert.equal(out.events[0].agent, "ship-42-ticket-42");
  assert.equal(out.events[0].model, "opus");
  assert.equal(out.events[0].repo, REPO);
  assert.equal(out.events[0].issue, 42);
  assert.equal(out.events[0].ts, NOW);
  assert.deepEqual(out.snapshot[`${REPO}#42`].labels, ["agent:working"]);
});

test("moving to review is one review event", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: "u" } };
  const out = run({ snapshot, issues: [issue(42, ["agent:review"])] });
  assert.deepEqual(types(out.events), ["review"]);
});

test("a PR opens once, matched by Fixes #n, and sticks to the snapshot", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:review"], title: "Ticket 42", url: "u" } };
  const prs = { [REPO]: [{ number: 7, title: "Ticket 42", body: "Fixes #42", url: "pr7", headRefName: "x" }] };
  const out = run({ snapshot, issues: [issue(42, ["agent:review"])], prs });
  assert.deepEqual(types(out.events), ["pr_opened"]);
  assert.deepEqual(out.events[0].pr, { number: 7, url: "pr7" });
  const again = run({ snapshot: out.snapshot, issues: [issue(42, ["agent:review"])], prs });
  assert.deepEqual(again.events, []);
  assert.deepEqual(again.snapshot[`${REPO}#42`].pr, { number: 7, url: "pr7" });
});

test("a PR is matched by the issue number in its branch name", () => {
  const prs = [{ number: 9, body: "", headRefName: "issue-42-fix-login" }, { number: 8, body: "", headRefName: "issue-420" }];
  assert.equal(prFor(prs, 42).number, 9);
  assert.equal(prFor(prs, 420).number, 8);
  assert.equal(prFor(prs, 4), null);
});

test("a merged ticket ends as merged with its PR", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:done"], title: "Ticket 42", url: "u", pr: { number: 7, url: "pr7" } } };
  const lookups = {
    [`${REPO}#42`]: {
      state: "CLOSED",
      stateReason: "COMPLETED",
      labels: [{ name: "agent:done" }],
      closedByPullRequestsReferences: [{ number: 7, url: "pr7" }],
    },
  };
  const out = run({ snapshot, lookups });
  assert.deepEqual(types(out.events), ["merged"]);
  assert.deepEqual(out.events[0].pr, { number: 7, url: "pr7" });
  assert.deepEqual(out.snapshot, {});
});

test("a ticket closed by hand ends as closed with its stateReason", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: "u" } };
  const lookups = { [`${REPO}#42`]: { state: "CLOSED", stateReason: "NOT_PLANNED", labels: [], closedByPullRequestsReferences: [] } };
  const out = run({ snapshot, lookups });
  assert.deepEqual(types(out.events), ["closed"]);
  assert.equal(out.events[0].reason, "not_planned");
  assert.deepEqual(out.snapshot, {});
});

test("an open ticket off every agent:* label ends as closed, unlabelled", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: "u" } };
  const lookups = { [`${REPO}#42`]: { state: "OPEN", stateReason: null, labels: [{ name: "bug" }], closedByPullRequestsReferences: [] } };
  const out = run({ snapshot, lookups });
  assert.deepEqual(types(out.events), ["closed"]);
  assert.equal(out.events[0].reason, "unlabelled");
  assert.deepEqual(out.snapshot, {});
});

test("a ticket put back on agent:ready leaves the snapshot without an event", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:failed"], failed: true, title: "Ticket 42", url: "u" } };
  const lookups = { [`${REPO}#42`]: { state: "OPEN", labels: [{ name: "agent:ready" }], closedByPullRequestsReferences: [] } };
  const out = run({ snapshot, lookups });
  assert.deepEqual(out.events, []);
  assert.deepEqual(out.snapshot, {});
});

test("a key missing from the search with no lookup is kept for next tick", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: "u" } };
  const out = run({ snapshot });
  assert.deepEqual(out.events, []);
  assert.deepEqual(out.snapshot, snapshot);
});

test("a held PR: agent:done, open PR, no live session, once, with the gate", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:review"], title: "Ticket 42", url: "u", pr: { number: 7, url: "pr7" } } };
  const lookups = { [`${REPO}#42`]: { held_reason: "Gate failed: no-automerge label on the issue\n\ndetails" } };
  const out = run({ snapshot, issues: [issue(42, ["agent:done"])], lookups });
  assert.deepEqual(types(out.events), ["held"]);
  assert.equal(out.events[0].reason, "Gate failed: no-automerge label on the issue");
  assert.equal(out.snapshot[`${REPO}#42`].held, true);
  const again = run({ snapshot: out.snapshot, issues: [issue(42, ["agent:done"])] });
  assert.deepEqual(again.events, []);
});

test("agent:done with a live session is merging, not held", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:review"], title: "Ticket 42", url: "u", pr: { number: 7, url: "pr7" } } };
  const out = run({ snapshot, issues: [issue(42, ["agent:done"])], live: [`${REPO}#42`] });
  assert.deepEqual(out.events, []);
  assert.equal(out.snapshot[`${REPO}#42`].held, undefined);
});

test("a failed ticket: one failed event with the comment's first line, then silence", () => {
  const snapshot = { [`${REPO}#42`]: { labels: ["agent:working"], title: "Ticket 42", url: "u" } };
  const lookups = { [`${REPO}#42`]: { last_comment: "Rebase could not be resolved.\nMore detail." } };
  const out = run({ snapshot, issues: [issue(42, ["agent:failed"])], lookups });
  assert.deepEqual(types(out.events), ["failed"]);
  assert.equal(out.events[0].reason, "Rebase could not be resolved.");
  assert.equal(out.snapshot[`${REPO}#42`].failed, true);
  const again = run({ snapshot: out.snapshot, issues: [issue(42, ["agent:failed"])] });
  assert.deepEqual(again.events, []);
  // Relabelled and claimed again: a new run.
  const rerun = run({ snapshot: again.snapshot, issues: [issue(42, ["agent:working"])] });
  assert.deepEqual(types(rerun.events), ["claimed"]);
  assert.equal(rerun.snapshot[`${REPO}#42`].failed, undefined);
});

test("a ticket first seen on agent:failed is one failed event", () => {
  const out = run({ issues: [issue(42, ["agent:failed"])] });
  assert.deepEqual(types(out.events), ["failed"]);
});

test("the same issue number in two repos is two runs", () => {
  const other = { ...issue(42, ["agent:working"]), repository: { nameWithOwner: "owner/web", name: "web" } };
  const out = run({ issues: [issue(42, ["agent:working"]), other] });
  assert.deepEqual(types(out.events), ["claimed", "claimed"]);
  assert.deepEqual(Object.keys(out.snapshot).sort(), ["owner/app#42", "owner/web#42"]);
  const outAgain = run({ snapshot: out.snapshot, issues: [issue(42, ["agent:review"]), other] });
  assert.deepEqual(outAgain.events.map((e) => [e.type, e.repo]), [["review", REPO]]);
});

test("the CLI reads stdin and writes {snapshot, events}", () => {
  const input = JSON.stringify({ now: NOW, snapshot: {}, issues: [issue(1, ["agent:working"])], prs: {}, lookups: {}, launches: [], live: [] });
  const out = JSON.parse(execFileSync("node", [join(here, "record.mjs")], { input, encoding: "utf8" }));
  assert.deepEqual(types(out.events), ["claimed"]);
  assert.ok(out.snapshot[`${REPO}#1`]);
});
