#!/usr/bin/env node
// The dashboard: node render.mjs <state-dir> <out-file>
// Reads events.jsonl, last-tick.json, gate.json, launches.json and
// snapshot.json from the state dir and writes one self-contained page.
// buildRuns(events) and render(state) are exported for the tests.

import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";

const ENDINGS = new Set(["merged", "closed", "held", "failed"]);
const RECENT = 50;

export function buildRuns(events, now = Date.now()) {
  const open = new Map(); // key -> run in progress
  const runs = [];
  for (const e of events) {
    if (!e.repo || e.issue === undefined || e.issue === null) continue;
    const key = `${e.repo}#${e.issue}`;
    let run = open.get(key);
    const starts = e.type === "launch" || e.type === "claimed";
    if (!run || (starts && run.ended)) {
      run = { repo: e.repo, issue: Number(e.issue), title: e.title ?? "", url: e.url ?? "", agent: null, model: null,
              pr: null, started: e.ts, ended: null, outcome: "running", reason: null, resumes: 0, events: [] };
      runs.push(run);
      open.set(key, run);
    }
    run.events.push(e.type);
    if (e.title) run.title = e.title;
    if (e.url) run.url = e.url;
    if (e.agent) run.agent = e.agent;
    if (e.model) run.model = e.model;
    if (e.pr) run.pr = e.pr;
    if (e.type === "resume") run.resumes += 1;
    if (ENDINGS.has(e.type)) {
      run.ended = e.ts;
      run.outcome = e.type;
      run.reason = e.reason ?? null;
    } else if (e.type === "orphan") {
      run.orphan = e.reason ?? "in flight, no agent found";
    }
  }
  for (const run of runs) {
    if (!run.ended && run.resumes > 0) run.outcome = "resumed";
    const end = run.ended ? Date.parse(run.ended) : now;
    run.duration_ms = Math.max(0, end - Date.parse(run.started));
  }
  return runs;
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export function relative(ts, now = Date.now()) {
  const t = Date.parse(ts);
  if (Number.isNaN(t)) return "";
  const diff = now - t;
  const abs = Math.abs(diff);
  const units = [["d", 86400000], ["h", 3600000], ["m", 60000], ["s", 1000]];
  let out = "";
  for (const [u, ms] of units) {
    if (abs >= ms) {
      const n = Math.floor(abs / ms);
      out = `${n}${u}`;
      if (u === "d") out += ` ${Math.floor((abs % ms) / 3600000)}h`;
      else if (u === "h") out += ` ${Math.floor((abs % ms) / 60000)}m`;
      break;
    }
  }
  if (!out) out = "0s";
  return diff >= 0 ? `${out} ago` : `in ${out}`;
}

export function duration(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

function when(ts, now) {
  if (!ts) return "—";
  return `<time datetime="${esc(ts)}" title="${esc(ts)}">${esc(ts.replace("T", " ").replace(/(\.\d+)?Z$/, " UTC"))}</time> <small>${esc(relative(ts, now))}</small>`;
}

function link(url, text) {
  return url ? `<a href="${esc(url)}">${esc(text)}</a>` : esc(text);
}

function issueLink(run) {
  return link(run.url, `#${run.issue}`);
}

function prLink(run) {
  return run.pr ? link(run.pr.url, `PR #${run.pr.number}`) : "—";
}

function repoShort(repo) {
  return repo.includes("/") ? repo.split("/")[1] : repo;
}

export function render(state, now = Date.now()) {
  const events = state.events ?? [];
  const runs = buildRuns(events, now);
  const running = runs.filter((r) => !r.ended);
  const ended = runs.filter((r) => r.ended).sort((a, b) => Date.parse(b.ended) - Date.parse(a.ended)).slice(0, RECENT);
  const lastTick = state.lastTick ?? null;
  const gate = state.gate ?? null;

  // Needs you: failed and held runs still open on the last snapshot (or the
  // latest run for the key), orphans and needs_setup not cleared by a later
  // launch/claim.
  const latestByKey = new Map();
  for (const r of runs) latestByKey.set(`${r.repo}#${r.issue}`, r);
  const failed = [...latestByKey.values()].filter((r) => r.outcome === "failed");
  const held = [...latestByKey.values()].filter((r) => r.outcome === "held");
  const orphans = [...latestByKey.values()].filter((r) => !r.ended && r.orphan);
  const needsSetup = new Map();
  for (const e of events) {
    if (e.type === "needs_setup") needsSetup.set(e.repo, e);
    else if ((e.type === "launch" || e.type === "claimed") && needsSetup.has(e.repo)) needsSetup.delete(e.repo);
  }

  const rows = (list, cells) => list.map((r) => `<tr>${cells(r).map((c) => `<td>${c}</td>`).join("")}</tr>`).join("\n");

  let gateHtml = "no gate check yet";
  if (gate) {
    if (gate.open === true) gateHtml = `<span class="ok">open</span> · session ${esc(gate.session_pct)}% · weekly ${esc(gate.weekly_pct)}%`;
    else gateHtml = `<span class="bad">closed</span>${gate.error ? ` · ${esc(gate.error)}` : ` · session ${esc(gate.session_pct)}% · weekly ${esc(gate.weekly_pct)}%`}${gate.resets_at ? ` · resets ${when(gate.resets_at, now)}` : ""}`;
    if (gate.checked_at) gateHtml += ` <small>(checked ${esc(relative(gate.checked_at, now))})</small>`;
  }

  const needs = [];
  for (const r of failed) needs.push(`<li class="bad"><b>failed</b> ${esc(repoShort(r.repo))} ${issueLink(r)} ${esc(r.title)} — ${esc(r.reason ?? "")} <small>${esc(relative(r.ended, now))}</small>. Relabel <code>agent:ready</code> to retry.</li>`);
  for (const r of held) needs.push(`<li class="warn"><b>held</b> ${esc(repoShort(r.repo))} ${issueLink(r)} ${prLink(r)} ${esc(r.title)} — ${esc(r.reason ?? "merge gate")} <small>${esc(relative(r.ended, now))}</small>. The repo is blocked until it is merged or closed.</li>`);
  for (const r of orphans) needs.push(`<li class="warn"><b>no agent</b> ${esc(repoShort(r.repo))} ${issueLink(r)} ${esc(r.title)} — ${esc(r.orphan)}. The repo is blocked until it is dealt with.</li>`);
  for (const e of needsSetup.values()) needs.push(`<li class="warn"><b>needs setup</b> ${esc(e.repo)} — run <code>setup-repo.sh ${esc(e.repo)}</code>. The repo is blocked until it is set up.</li>`);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Ship factory</title>
<style>
  :root { color-scheme: light dark; --bad: #c0392b; --warn: #b9770e; --ok: #1e8449; --muted: #777; }
  body { font: 15px/1.45 system-ui, sans-serif; margin: 0 auto; padding: 16px; max-width: 1100px; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  h2 { font-size: 16px; margin: 24px 0 8px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #8884; vertical-align: top; }
  th { font-weight: 600; font-size: 13px; color: var(--muted); }
  small { color: var(--muted); }
  .bad { color: var(--bad); } .warn { color: var(--warn); } .ok { color: var(--ok); }
  ul { padding-left: 20px; } li { margin: 4px 0; }
  code { font-size: 13px; }
  .wrap { overflow-x: auto; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; margin: 0; }
  dt { color: var(--muted); }
</style>
</head>
<body>
<h1>Ship factory</h1>

<h2>Now</h2>
<dl>
  <dt>Last tick</dt><dd>${lastTick ? `${when(lastTick.ts, now)} · ${esc(lastTick.outcome)}` : "no tick yet"}</dd>
  <dt>Usage gate</dt><dd>${gateHtml}</dd>
  <dt>Running</dt><dd>${running.length}</dd>
</dl>
<div class="wrap">
<table id="running">
<thead><tr><th>Repo</th><th>Issue</th><th>PR</th><th>Agent</th><th>Model</th><th>Running for</th><th>Resumes</th></tr></thead>
<tbody>
${running.length ? rows(running, (r) => [esc(repoShort(r.repo)), `${issueLink(r)} ${esc(r.title)}`, prLink(r), esc(r.agent ?? "—"), esc(r.model ?? "—"), esc(duration(r.duration_ms)), String(r.resumes)]) : `<tr><td colspan="7"><small>nothing running</small></td></tr>`}
</tbody>
</table>
</div>

<h2>Needs you</h2>
${needs.length ? `<ul id="needs-you">\n${needs.join("\n")}\n</ul>` : `<p id="needs-you"><small>nothing needs you</small></p>`}

<h2>Recent runs</h2>
<div class="wrap">
<table id="recent">
<thead><tr><th>Repo</th><th>Issue</th><th>PR</th><th>Model</th><th>Start</th><th>End</th><th>Duration</th><th>Outcome</th></tr></thead>
<tbody>
${ended.length ? rows(ended, (r) => [esc(repoShort(r.repo)), `${issueLink(r)} ${esc(r.title)}`, prLink(r), esc(r.model ?? "—"), when(r.started, now), when(r.ended, now), esc(duration(r.duration_ms)), `<span class="${r.outcome === "merged" ? "ok" : r.outcome === "failed" ? "bad" : "warn"}">${esc(r.outcome)}</span>${r.reason ? ` <small>${esc(r.reason)}</small>` : ""}`]) : `<tr><td colspan="8"><small>no runs yet</small></td></tr>`}
</tbody>
</table>
</div>

<p><small>Rendered ${esc(new Date(now).toISOString())}. Reloads every 60 s.</small></p>
</body>
</html>
`;
}

function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}

export function loadState(stateDir) {
  const events = [];
  const eventsPath = join(stateDir, "events.jsonl");
  if (existsSync(eventsPath)) {
    for (const line of readFileSync(eventsPath, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { events.push(JSON.parse(line)); } catch { /* skip a torn line */ }
    }
  }
  return {
    events,
    lastTick: readJson(join(stateDir, "last-tick.json"), null),
    gate: readJson(join(stateDir, "gate.json"), null),
    launches: readJson(join(stateDir, "launches.json"), []),
    snapshot: readJson(join(stateDir, "snapshot.json"), {}),
  };
}

function main() {
  const [stateDir, outFile] = process.argv.slice(2);
  if (!stateDir || !outFile) {
    console.error("usage: render.mjs <state-dir> <out-file>");
    process.exit(1);
  }
  const html = render(loadState(stateDir));
  const tmp = `${outFile}.tmp.${process.pid}`;
  writeFileSync(tmp, html);
  renameSync(tmp, outFile);
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/^.*\//, "/"))) main();
