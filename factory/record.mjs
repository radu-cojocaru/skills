#!/usr/bin/env node
// The Record step: compare GitHub's view of the in-flight tickets with the
// last snapshot and produce one event per change. Pure: reads one JSON
// object on stdin, prints {snapshot, events} on stdout. The tick does the
// I/O around it. See record.test.mjs for the cases.
//
// Input: {now, snapshot, issues, prs, lookups, launches, live}
//   snapshot  previous state/snapshot.json: "<owner/repo>#<n>" -> entry
//   issues    open issues on agent:working/review/done/failed
//             [{repository: {nameWithOwner}, number, title, labels: [{name}], url}]
//   prs       open PRs per repo: {"<owner/repo>": [{number, title, body, url, headRefName}]}
//   lookups   for snapshot keys missing from issues:
//             {key: {state, stateReason, labels, closedByPullRequestsReferences, last_comment?, held_reason?}}
//             last_comment / held_reason may also be given for keys in issues.
//   launches  launches.json, for the agent name and model on claimed events
//   live      keys with a live session, as an array

import { readFileSync } from "node:fs";

const IN_FLIGHT = ["agent:working", "agent:review", "agent:done", "agent:failed"];

export function keyOf(repo, number) {
  return `${repo}#${number}`;
}

function labelNames(labels) {
  return (labels ?? []).map((l) => (typeof l === "string" ? l : l.name));
}

function firstLine(text) {
  if (!text) return null;
  const line = String(text).split(/\r?\n/).find((l) => l.trim() !== "");
  return line ? line.trim() : null;
}

const CLOSING = /\b(?:fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved)\s*:?\s*#(\d+)\b/gi;

/** The open PR for an issue in its repo: a closing keyword in the body, else
 *  the number as a whole token in the branch name. */
export function prFor(prs, number) {
  const n = String(number);
  for (const pr of prs ?? []) {
    for (const m of (pr.body ?? "").matchAll(CLOSING)) if (m[1] === n) return pr;
  }
  for (const pr of prs ?? []) {
    const tokens = (pr.headRefName ?? "").split(/[^0-9]+/).filter(Boolean);
    if (tokens.includes(n)) return pr;
  }
  return null;
}

function prRef(pr) {
  return pr ? { number: pr.number, url: pr.url } : undefined;
}

export function record(input) {
  const now = input.now;
  const prev = input.snapshot ?? {};
  const live = new Set(input.live ?? []);
  const launches = input.launches ?? [];
  const lookups = input.lookups ?? {};
  const next = {};
  const events = [];

  const base = (key, entry) => {
    const [repo, issue] = key.split("#");
    const ev = { ts: now, repo, issue: Number(issue), title: entry.title, url: entry.url };
    if (entry.pr) ev.pr = entry.pr;
    return ev;
  };
  const emit = (type, key, entry, extra = {}) => events.push({ ...base(key, entry), type, ...extra });

  const launchFor = (key) => {
    const [repo, issue] = key.split("#");
    const hits = launches.filter((l) => (l.full ?? l.repo) === repo && Number(l.issue) === Number(issue));
    return hits.length ? hits[hits.length - 1] : null;
  };

  const seen = new Set();
  for (const issue of input.issues ?? []) {
    const repo = issue.repository?.nameWithOwner ?? issue.repository;
    const key = keyOf(repo, issue.number);
    seen.add(key);
    const labels = labelNames(issue.labels);
    const has = (l) => labels.includes(l);
    const old = prev[key];
    const look = lookups[key] ?? {};
    const pr = old?.pr ?? prRef(prFor(input.prs?.[repo], issue.number));
    const entry = { labels, title: issue.title, url: issue.url };
    if (pr) entry.pr = pr;

    // A failed ticket relabelled and re-claimed starts a new run.
    const fresh = !old || (old.failed && (has("agent:working") || has("agent:review")) && !has("agent:failed"));
    const oldLabels = fresh ? [] : old.labels ?? [];
    const had = (l) => oldLabels.includes(l);
    if (!fresh) {
      if (old.held) entry.held = true;
      if (old.failed) entry.failed = true;
    }

    if (fresh && (has("agent:working") || has("agent:review") || has("agent:done"))) {
      const l = launchFor(key);
      emit("claimed", key, entry, l ? { agent: l.name, model: l.model } : {});
    }
    if ((has("agent:review") || has("agent:done")) && !had("agent:review") && !had("agent:done")) {
      emit("review", key, entry);
    }
    if (pr && !old?.pr) {
      emit("pr_opened", key, entry);
    }
    if (has("agent:failed") && !entry.failed) {
      entry.failed = true;
      emit("failed", key, entry, { reason: firstLine(look.last_comment) ?? "see the issue's last comment" });
    }
    if (has("agent:done") && pr && !live.has(key) && !entry.held) {
      entry.held = true;
      emit("held", key, entry, { reason: firstLine(look.held_reason) ?? "merge gate" });
    }
    next[key] = entry;
  }

  for (const key of Object.keys(prev)) {
    if (seen.has(key)) continue;
    const old = prev[key];
    const look = lookups[key];
    if (!look) {
      // No lookup this tick: keep it and try again next time.
      next[key] = old;
      continue;
    }
    const labels = labelNames(look.labels);
    if (look.state === "CLOSED") {
      const closers = look.closedByPullRequestsReferences ?? [];
      const merged = closers.find((p) => p.merged !== false) ?? null;
      if (merged) {
        const entry = { ...old, pr: { number: merged.number, url: merged.url } };
        emit("merged", key, entry);
      } else {
        emit("closed", key, old, { reason: (look.stateReason ?? "closed").toLowerCase() });
      }
      continue;
    }
    if (!labels.some((l) => l.startsWith("agent:"))) {
      emit("closed", key, old, { reason: "unlabelled" });
      continue;
    }
    if (!labels.some((l) => IN_FLIGHT.includes(l))) {
      // Back on agent:ready (or agent:implemented): the run is over, no event.
      continue;
    }
    // Still in flight; the search index has not caught up. Keep it.
    next[key] = old;
  }

  return { snapshot: next, events };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, "/"))) {
  const input = JSON.parse(readFileSync(0, "utf8") || "{}");
  process.stdout.write(JSON.stringify(record(input)) + "\n");
}
