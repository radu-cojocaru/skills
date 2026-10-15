import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./stale.mjs";

const NOW = "2026-10-15T12:05:01Z";
const KEY = "owner/app#42";
const session = { id: "ab12", sessionId: "ab12-full", state: "working", name: "ship-42-fix" };

function run(overrides) {
  return decide({ now: NOW, gate_open: true, grace_secs: 600, tickets: [], launches: [], ...overrides }).actions;
}

function ticket(overrides) {
  return { key: KEY, labels: ["agent:working"], session, live: false, resume: null, orphaned: false, ...overrides };
}

test("a live session needs nothing", () => {
  assert.deepEqual(run({ tickets: [ticket({ live: true })] }), []);
});

test("agent:done and agent:failed tickets are not stale candidates", () => {
  assert.deepEqual(run({ tickets: [ticket({ labels: ["agent:done"] }), ticket({ labels: ["agent:failed"] })] }), []);
});

test("first time stale with an open gate: resume", () => {
  const a = run({ tickets: [ticket()] });
  assert.equal(a.length, 1);
  assert.equal(a[0].action, "resume");
  assert.equal(a[0].session.sessionId, "ab12-full");
});

test("first time stale with a closed gate: defer", () => {
  const a = run({ gate_open: false, tickets: [ticket()] });
  assert.equal(a[0].action, "defer");
});

test("stale again after a resume: fail with the labels to remove", () => {
  const a = run({ tickets: [ticket({ labels: ["agent:review"], resume: { session_id: "cd34", resumed_at: "2026-10-15T11:00:00Z" } })] });
  assert.equal(a[0].action, "fail");
  assert.deepEqual(a[0].labels, ["agent:review"]);
  assert.match(a[0].reason, /resumed once at 2026-10-15T11:00:00Z and stopped again/);
  assert.match(a[0].reason, /ship-42-fix/);
});

test("no session at all: orphan once, never relabel", () => {
  const a = run({ tickets: [ticket({ session: null })] });
  assert.deepEqual(a, [{ action: "orphan", key: KEY, reason: "in flight, no agent found" }]);
  assert.deepEqual(run({ tickets: [ticket({ session: null, orphaned: true })] }), []);
});

test("a blocked session with a fresh transcript is live and left alone", () => {
  assert.deepEqual(run({ tickets: [ticket({ session: { ...session, state: "blocked" }, live: true })] }), []);
});

function launch(overrides) {
  return {
    key: KEY, name: "ship-42-fix", session_id: "ab12", launched_at: "2026-10-15T11:00:00Z", closed_at: null,
    live: false, ticket_state: "OPEN", ticket_labels: ["agent:ready"], ...overrides,
  };
}

test("a launch whose session ended with the ticket still agent:ready is declined", () => {
  const a = run({ launches: [launch()] });
  assert.equal(a.length, 1);
  assert.equal(a[0].action, "decline");
  assert.equal(a[0].session_id, "ab12");
  assert.match(a[0].reason, /ended without claiming/);
});

test("a launch inside the grace period is left alone even if not live yet", () => {
  assert.deepEqual(run({ launches: [launch({ launched_at: "2026-10-15T12:00:00Z" })] }), []);
});

test("a live launch is left alone", () => {
  assert.deepEqual(run({ launches: [launch({ live: true })] }), []);
});

test("a launch whose ticket was claimed is left alone", () => {
  assert.deepEqual(run({ launches: [launch({ ticket_labels: ["agent:working"] })] }), []);
});

test("a launch whose ticket is closed or failed is closed", () => {
  const a = run({ launches: [launch({ ticket_state: "CLOSED", ticket_labels: [] }), launch({ key: "owner/app#43", ticket_labels: ["agent:failed"] })] });
  assert.deepEqual(a.map((x) => [x.action, x.reason]), [["close", "ticket closed"], ["close", "ticket failed"]]);
});

test("closed launch records are ignored", () => {
  assert.deepEqual(run({ launches: [launch({ closed_at: NOW })] }), []);
});
