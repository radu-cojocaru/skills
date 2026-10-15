#!/usr/bin/env node
// Stale-run and declined-launch decisions. Pure: one JSON object on stdin,
// {actions} on stdout. The tick gathers the facts and carries out the
// actions. See stale.test.mjs.
//
// Input: {now, gate_open, grace_secs, tickets, launches}
//   tickets   in-flight tickets from the Record step, each
//             {key, labels, session: {id, sessionId, state, name} | null, live, resume: {session_id, resumed_at} | null, orphaned}
//   launches  launches.json entries with the tick's findings attached:
//             {key, name, session_id, launched_at, closed_at, live, ticket_state, ticket_labels}
//
// Output actions, one per ticket or launch that needs something:
//   {action: "resume" | "defer" | "fail" | "orphan", key, ...}     tickets
//   {action: "decline" | "close", key, ...}                       launches

import { readFileSync } from "node:fs";

const STALE_LABELS = ["agent:working", "agent:review"];

export function decide(input) {
  const actions = [];
  const gateOpen = Boolean(input.gate_open);
  const now = Date.parse(input.now ?? "") || Date.now();
  const grace = (input.grace_secs ?? 600) * 1000;

  for (const t of input.tickets ?? []) {
    const labels = t.labels ?? [];
    if (!labels.some((l) => STALE_LABELS.includes(l))) continue;
    if (t.live) continue;
    if (!t.session) {
      if (!t.orphaned) actions.push({ action: "orphan", key: t.key, reason: "in flight, no agent found" });
      continue;
    }
    if (!t.resume) {
      if (gateOpen) {
        actions.push({ action: "resume", key: t.key, session: t.session });
      } else {
        actions.push({ action: "defer", key: t.key, session: t.session, reason: "gate closed" });
      }
      continue;
    }
    actions.push({
      action: "fail",
      key: t.key,
      session: t.session,
      labels: labels.filter((l) => STALE_LABELS.includes(l)),
      reason: `Factory: run \`${t.session.name ?? t.session.id}\` was resumed once at ${t.resume.resumed_at} and stopped again`,
    });
  }

  for (const l of input.launches ?? []) {
    if (l.closed_at) continue;
    const labels = l.ticket_labels ?? [];
    if (l.ticket_state === "CLOSED" || labels.includes("agent:failed")) {
      actions.push({ action: "close", key: l.key, reason: l.ticket_state === "CLOSED" ? "ticket closed" : "ticket failed" });
      continue;
    }
    if (l.live) continue;
    const age = now - (Date.parse(l.launched_at ?? "") || 0);
    if (age < grace) continue;
    if (labels.includes("agent:ready")) {
      actions.push({ action: "decline", key: l.key, session_id: l.session_id, name: l.name, reason: "Factory: `/ship-bg` ended without claiming" });
    }
  }

  return { actions };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, "/"))) {
  const input = JSON.parse(readFileSync(0, "utf8") || "{}");
  process.stdout.write(JSON.stringify(decide(input)) + "\n");
}
