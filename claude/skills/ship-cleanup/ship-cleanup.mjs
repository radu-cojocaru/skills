#!/usr/bin/env node
// Clears what a finished /ship run leaves behind: the git worktree under
// .claude/worktrees/, its local branch, stale origin/* refs, and the
// ~/.claude/jobs/<id> record of a background agent that is no longer running.
//
// Dry run by default — pass --apply to actually remove anything. A worktree
// is removed only when its directory name carries a number (so it came from
// /ship, not from a hand-made one like `crawler-render`), its tree is clean,
// and its PR is MERGED — so a run that finds work in progress is a no-op that
// says why.
//
// Removing a job record only sticks once the daemon is down: the daemon holds
// the session list in memory, so while it runs it rewrites every record you
// delete and respawns the process behind it, so --apply stops it first.
//
// Used by the /ship-cleanup skill. Safe to run by hand:
//   node .claude/skills/ship-cleanup/ship-cleanup.mjs
//   node .claude/skills/ship-cleanup/ship-cleanup.mjs --apply
//   node .claude/skills/ship-cleanup/ship-cleanup.mjs --apply --keep-daemon
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const APPLY = process.argv.includes("--apply");
const AS_JSON = process.argv.includes("--json");
const KEEP_DAEMON = process.argv.includes("--keep-daemon");
const JOBS_DIR = join(homedir(), ".claude", "jobs");

function run(cmd, args, { allowFail = false } = {}) {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (error) {
    if (allowFail) return null;
    throw new Error(`${cmd} ${args.join(" ")} failed: ${error.stderr || error.message}`);
  }
}

const repoRoot = run("git", ["rev-parse", "--show-toplevel"]);

/** Worktrees this repo owns under .claude/worktrees/ — never anyone else's. */
function shipWorktrees() {
  const porcelain = run("git", ["worktree", "list", "--porcelain"]);
  const managed = join(repoRoot, ".claude", "worktrees");
  const found = [];
  let current = {};
  for (const line of `${porcelain}\n`.split("\n")) {
    if (line.startsWith("worktree ")) current = { path: line.slice(9) };
    else if (line.startsWith("branch ")) current.branch = line.slice(7).replace("refs/heads/", "");
    else if (line.startsWith("locked")) current.locked = true;
    else if (line === "" && current.path) {
      if (current.path.startsWith(managed + "/")) found.push(current);
      current = {};
    }
  }
  return found;
}

/** The branch name GitHub knows this worktree by. The local branch can differ
 *  from what was pushed — /ship names its worktree branch `worktree-ship-N`
 *  while the PR head is `ship-N` — and a PR is only findable by its head. */
function remoteBranchFor(path, localBranch) {
  const upstream = run(
    "git",
    ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    { allowFail: true },
  );
  if (!upstream) return localBranch;
  const slash = upstream.indexOf("/");
  return slash === -1 ? upstream : upstream.slice(slash + 1);
}

function ghJson(args) {
  const raw = run("gh", args, { allowFail: true });
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/** MERGED / OPEN / CLOSED / NONE for a branch, from GitHub rather than git —
 *  a squash merge leaves no ancestry, so `git branch --merged` reports a
 *  landed branch as unmerged. */
function prStateFor(branch) {
  const list = ghJson([
    "pr",
    "list",
    "--head",
    branch,
    "--state",
    "all",
    "--limit",
    "1",
    "--json",
    "number,state",
  ]);
  if (list === null) return { state: "UNKNOWN", number: null };
  const [pr] = list;
  return pr ? { state: pr.state, number: pr.number } : { state: "NONE", number: null };
}

function isDirty(path) {
  const status = run("git", ["-C", path, "status", "--porcelain"], { allowFail: true });
  return status === null ? true : status.length > 0;
}

/**
 * Only worktrees whose directory name carries a digit are ours to remove.
 * `/ship` names every worktree after its ticket, so a number is the mark of a
 * machine-made one; a hand-made worktree like `crawler-render` has none and is
 * left alone even when its branch has landed and its tree is clean.
 *
 * Deliberately a heuristic, not a proof — a hand-made worktree called
 * `fix-utf8` would pass it. The clean-tree and PR-MERGED checks below are
 * still the real guard; this one exists so that a hand-made worktree the
 * operator is living in does not get swept up the moment its PR merges.
 */
function looksMachineMade(path) {
  return /\d/.test(basename(path));
}

/** Background-agent id → state, from the daemon. A record is a leftover once
 *  its agent is gone, `done`, or `stopped` — stopped means the user already
 *  looked and killed it. `working` and `blocked` are checked against GitHub
 *  before being kept; see ticketIsClosed(). */
function agentStates() {
  const raw = run("claude", ["agents", "--json", "--all"], { allowFail: true });
  if (!raw) return null;
  try {
    const map = new Map();
    for (const a of JSON.parse(raw)) if (a.id) map.set(a.id, a.state ?? a.status ?? "unknown");
    return map;
  } catch {
    return null;
  }
}

/**
 * What the box has left, in GiB. Linux only — /proc/meminfo is the one source
 * that does not lie about cache. Returns null anywhere else, and the report
 * simply omits the line rather than guessing.
 */
function memorySnapshot() {
  let meminfo;
  try {
    meminfo = readFileSync("/proc/meminfo", "utf8");
  } catch {
    return null;
  }
  const kb = (key) => {
    const hit = new RegExp(`^${key}:\\s+(\\d+) kB$`, "m").exec(meminfo);
    return hit ? Number(hit[1]) / 1048576 : null;
  };
  const total = kb("MemTotal");
  const available = kb("MemAvailable");
  if (total === null || available === null) return null;
  const swapTotal = kb("SwapTotal") ?? 0;
  const swapUsed = swapTotal - (kb("SwapFree") ?? 0);
  return { total, available, swapTotal, swapUsed, claude: claudeMemory() };
}

/** How much of that is Claude's own — the number this cleanup actually moves. */
function claudeMemory() {
  const raw = run("ps", ["-eo", "rss,args"], { allowFail: true });
  if (!raw) return null;
  let rss = 0;
  let procs = 0;
  for (const line of raw.split("\n").slice(1)) {
    // Match the executable, not the whole command line: `node
    // .claude/skills/…` (this very script), an editor holding a ~/.claude
    // file, a tail on a daemon log — all say "claude" in their args without
    // being a session. Sessions run either `claude …` or the versioned binary
    // under .../claude/versions/<v>.
    const hit = /^\s*(\d+)\s+(\S+)/.exec(line);
    if (!hit) continue;
    const exe = hit[2];
    if (!/(^|\/)claude$/.test(exe) && !/\/claude\/versions\//.test(exe)) continue;
    rss += Number(hit[1]);
    procs += 1;
  }
  return { gib: rss / 1048576, procs };
}

const gib = (n) => `${n.toFixed(1)} GiB`;

function daemonRunning() {
  const status = run("claude", ["daemon", "status"], { allowFail: true });
  if (status === null) return false;
  return !/^not running/m.test(status);
}

/**
 * The ticket an agent was launched on, or null.
 *
 * `intent` is free text the agent wrote, so a bare number in it is not a
 * ticket reference — "Apply migration 0059 for #560" or "Bump Node 24 in CI"
 * would both resolve to some real, closed number in a repo this far along, and
 * `gh issue view` answers for PR numbers too. Deleting a live agent's record
 * on a false hit is expensive: it can also make the run believe nothing is
 * live and stop the daemon out from under that agent.
 *
 * So only count the forms a launch actually writes: `#N`, `/ship-bg N`, and
 * the `<command-args>N</command-args>` a slash-command invocation records.
 * Anything else is "cannot answer", which the caller treats as live.
 */
function ticketNumberIn(intent) {
  const patterns = [/#(\d+)\b/, /\bship-bg\s+(\d+)\b/, /<command-args>\s*(\d+)\b/];
  for (const pattern of patterns) {
    const hit = pattern.exec(intent);
    if (hit) return Number(hit[1]);
  }
  return null;
}

/**
 * Is the ticket this agent was working on already finished on GitHub?
 *
 * An agent's own `working` / `blocked` is not evidence that anything is live.
 * An agent that dies mid-wait keeps saying `working` forever, and the daemon
 * faithfully resurrects that frozen moment on every restart — including its
 * timestamps, so age tells you nothing either. On 2026-09-05 the record for
 * #538 still read `working — PR #549 launched, awaiting CI`: the issue had
 * closed two days earlier and #549 was never opened at all.
 *
 * So ask GitHub, not the record. The ticket number in `intent` is the
 * strongest signal; the PRs in `children` are the fallback when there is no
 * ticket. Anything we cannot answer counts as live, and is kept.
 */
function ticketIsClosed(dir) {
  let record;
  try {
    record = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
  } catch {
    return false;
  }
  const ticket = ticketNumberIn(record.intent ?? "");
  if (ticket !== null) {
    const issue = ghJson(["issue", "view", String(ticket), "--json", "state"]);
    if (issue) return issue.state === "CLOSED";
  }
  const prs = (record.children ?? [])
    .filter((c) => c.kind === "pr")
    .map((c) => Number(c.id))
    .filter(Number.isFinite);
  if (prs.length === 0) return false;
  return prs.every((pr) => {
    const data = ghJson(["pr", "view", String(pr), "--json", "state"]);
    return data !== null && data.state !== "OPEN";
  });
}

const actions = [];
const skipped = [];

for (const wt of shipWorktrees()) {
  const branch = wt.branch ?? "(detached)";
  const label = `${wt.path.replace(repoRoot + "/", "")} [${branch}]`;
  if (!looksMachineMade(wt.path)) {
    skipped.push({ item: label, reason: "no number in the name — hand-made, not ours to remove" });
    continue;
  }
  if (isDirty(wt.path)) {
    skipped.push({ item: label, reason: "uncommitted changes — look before removing" });
    continue;
  }
  const pr = prStateFor(remoteBranchFor(wt.path, branch));
  if (pr.state !== "MERGED") {
    const detail = pr.number ? `PR #${pr.number} is ${pr.state}` : `no PR found (${pr.state})`;
    skipped.push({ item: label, reason: `${detail} — not finished` });
    continue;
  }
  actions.push({
    kind: "worktree",
    item: label,
    path: wt.path,
    branch,
    locked: wt.locked === true,
    pr: pr.number,
  });
}

const states = agentStates();
if (states === null) {
  skipped.push({
    item: "~/.claude/jobs",
    reason: "`claude agents --json` did not answer — job records left alone",
    live: true,
  });
} else if (existsSync(JOBS_DIR)) {
  for (const entry of readdirSync(JOBS_DIR)) {
    if (entry === "pins.json") continue;
    const dir = join(JOBS_DIR, entry);
    const state = states.get(entry);
    const item = `~/.claude/jobs/${entry}`;
    if (state === undefined || state === "done" || state === "stopped") {
      actions.push({ kind: "job", item, path: dir });
    } else if (ticketIsClosed(dir)) {
      // Says `working` or `blocked`, but its ticket is closed on GitHub. The
      // agent died mid-wait and the daemon has been reviving the corpse.
      actions.push({ kind: "job", item, path: dir, note: `${state}, but its ticket is closed` });
    } else if (state === "blocked") {
      // Kept on purpose: a blocked agent is waiting on the user, and its
      // record holds the reason. Read it, then `claude stop` to release it.
      skipped.push({
        item,
        reason: `agent is BLOCKED and waiting on you — read why, then \`claude stop ${entry}\` to release it`,
        live: true,
      });
    } else {
      skipped.push({ item, reason: `agent is ${state} — leave it alone`, live: true });
    }
  }
}

// The daemon holds the session list in memory. Deleting a job record while it
// runs frees nothing: within seconds it rewrites the record and respawns the
// session, each one carrying its whole transcript back into RAM. Stopping it
// is the only thing that sticks — and it is safe here precisely because we
// only reach this line when nothing live is left to lose. It restarts on
// demand at the next `claude agents` or `claude --bg`.
const removesJobs = actions.some((a) => a.kind === "job");
const somethingLive = skipped.some((s) => s.live);
if (removesJobs && !KEEP_DAEMON && !somethingLive && daemonRunning()) {
  actions.unshift({
    kind: "daemon",
    item: "the background daemon (`claude daemon stop --any`)",
    note: "so the job records below stay deleted",
  });
} else if (removesJobs && somethingLive && daemonRunning()) {
  skipped.push({
    item: "the background daemon",
    reason:
      "an agent is still live — daemon left up, so removed job records may come back until it is stopped",
  });
}

const memoryBefore = memorySnapshot();

if (APPLY) {
  // Daemon first: any record removed while it is up gets rewritten.
  for (const action of actions.filter((a) => a.kind === "daemon")) {
    run("claude", ["daemon", "stop", "--any"], { allowFail: true });
    action.done = true;
  }
  for (const action of actions.filter((a) => a.kind !== "daemon")) {
    if (action.kind === "worktree") {
      if (action.locked) run("git", ["worktree", "unlock", action.path], { allowFail: true });
      run("git", ["worktree", "remove", action.path]);
      // -D, not -d: a squash merge leaves the branch looking unmerged to git.
      run("git", ["branch", "-D", action.branch], { allowFail: true });
    } else {
      rmSync(action.path, { force: true, recursive: true });
    }
    action.done = true;
  }
  run("git", ["worktree", "prune"], { allowFail: true });
  run("git", ["fetch", "origin", "--prune"], { allowFail: true });
}

// Read after the work, so an --apply run reports what it actually freed.
const memoryAfter = memorySnapshot();
const freed =
  APPLY && memoryBefore && memoryAfter ? memoryAfter.available - memoryBefore.available : null;

const result = { applied: APPLY, removed: actions, skipped, memory: memoryAfter, freed };

if (AS_JSON) {
  console.log(JSON.stringify(result, null, 2));
} else {
  const verb = APPLY ? "Removed" : "Would remove";
  const stopVerb = APPLY ? "Stopped" : "Would stop";
  if (actions.length === 0) console.log("Nothing to clean up.");
  for (const a of actions) {
    const suffix = a.pr ? ` (PR #${a.pr})` : a.note ? ` (${a.note})` : "";
    console.log(`${a.kind === "daemon" ? stopVerb : verb}: ${a.item}${suffix}`);
  }
  for (const s of skipped) console.log(`Kept:    ${s.item} — ${s.reason}`);
  if (!APPLY && actions.length > 0) console.log("\nDry run. Pass --apply to remove these.");
  if (memoryAfter) {
    // Three short lines, not one long one: this gets read on a phone.
    const m = memoryAfter;
    const won = freed !== null && freed > 0.05 ? ` (freed ${gib(freed)})` : "";
    const claude = m.claude ? `${gib(m.claude.gib)} in ${m.claude.procs} procs` : "unknown";
    console.log(`\nMemory: ${gib(m.available)} of ${gib(m.total)} available${won}`);
    console.log(
      m.swapTotal > 0 ? `Swap:   ${gib(m.swapUsed)} of ${gib(m.swapTotal)} used` : "Swap:   none",
    );
    console.log(`Claude: ${claude}`);
  }
}
