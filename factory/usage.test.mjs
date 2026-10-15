// Tests for usage.jq, the /usage gate filter, against a saved stream-json
// fixture from Claude Code 2.1.300 (session 3%, weekly 17%, Fable 2%).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, "fixtures", "usage.jsonl"), "utf8");

function gate(input, sessionMax, weeklyMax) {
  const out = execFileSync(
    "jq",
    ["-s", "--arg", "session_max", String(sessionMax), "--arg", "weekly_max", String(weeklyMax), "-f", join(here, "usage.jq")],
    { input, encoding: "utf8" },
  );
  return JSON.parse(out);
}

test("open gate", () => {
  const g = gate(fixture, 70, 90);
  assert.equal(g.open, true);
  assert.equal(g.session_pct, 3);
  assert.equal(g.weekly_pct, 17);
  assert.equal(g.resets_at, null);
  assert.deepEqual(g.scoped_over, []);
  assert.equal(g.error, null);
});

test("session over closes the gate with the session reset", () => {
  const g = gate(fixture, 3, 90);
  assert.equal(g.open, false);
  assert.equal(g.resets_at, "2026-10-15T19:39:59.511967+00:00");
});

test("weekly over closes the gate with the weekly reset", () => {
  const g = gate(fixture, 70, 17);
  assert.equal(g.open, false);
  assert.equal(g.resets_at, "2026-10-19T09:59:59.511988+00:00");
  // Fable at 2% is also >= 2? No: weekly_max is 17 here, so no scoped model is over.
  assert.deepEqual(g.scoped_over, []);
});

test("both over picks the earliest reset", () => {
  const g = gate(fixture, 1, 1);
  assert.equal(g.open, false);
  assert.equal(g.resets_at, "2026-10-15T19:39:59.511967+00:00");
  assert.deepEqual(g.scoped_over, ["fable"]);
});

test("scoped model over skips that model only", () => {
  const g = gate(fixture, 70, 2);
  // weekly_all is 17 >= 2, so the gate is closed in this fixture; check the
  // scoped list independently with a tailored input.
  assert.deepEqual(g.scoped_over, ["fable"]);
  const tailored = JSON.stringify({
    type: "assistant",
    usage_report: {
      rate_limits: {
        limits: [
          { kind: "session", percent: 10, resets_at: "2026-01-01T00:00:00Z" },
          { kind: "weekly_all", percent: 20, resets_at: "2026-01-02T00:00:00Z" },
          { kind: "weekly_scoped", percent: 95, resets_at: "2026-01-02T00:00:00Z", scope: { model: { display_name: "Fable" } } },
        ],
      },
    },
  });
  const t = gate(tailored, 70, 90);
  assert.equal(t.open, true);
  assert.deepEqual(t.scoped_over, ["fable"]);
});

test("limits on the system message are also found", () => {
  const sys = JSON.stringify({
    type: "system",
    subtype: "init",
    rate_limits: {
      limits: [
        { kind: "session", percent: 50, resets_at: "2026-01-01T00:00:00Z" },
        { kind: "weekly_all", percent: 60, resets_at: "2026-01-02T00:00:00Z" },
      ],
    },
  });
  const g = gate(sys, 70, 90);
  assert.equal(g.open, true);
  assert.equal(g.session_pct, 50);
});

test("empty input is a closed gate with an error", () => {
  const g = gate("", 70, 90);
  assert.equal(g.open, false);
  assert.match(g.error, /no rate_limits/);
  assert.equal(g.resets_at, undefined);
});

test("output without limits is a closed gate with an error", () => {
  const g = gate('{"type":"result","subtype":"success"}\n', 70, 90);
  assert.equal(g.open, false);
  assert.match(g.error, /no rate_limits/);
});

test("unparseable input makes jq fail", () => {
  assert.throws(() => gate("not json", 70, 90));
});
