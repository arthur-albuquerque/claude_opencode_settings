---
name: delegate-workflow
description: Workflow-tier delegation — run a batch of 3+ independent opencode worker tasks through a deterministic ultracode Workflow (tier-capped concurrency, model-ladder retries, per-task QA, budget-resumable). Use when a delegation job decomposes into 3+ independent, non-overlapping coding tasks — migrations, test backfills, multi-module features, overnight runs. For 1–2 tasks, use direct delegation from the coordinator doctrine instead; this tier's wrapper overhead is pure surcharge there.
---

# delegate-workflow — Workflow tier for opencode delegation

**Role contract:** you (the coordinator) do NOT write feature code and the Claude agents inside the Workflow do NOT write feature code — opencode workers do all coding. You keep Phase 0 (diagnose, decompose, gate-check, dispatch) and Phase 2 (final review, merge, commit, report). The Workflow in between is plumbing: thin wrapper agents that launch opencode workers, run gates, and return structured JSON, with the escalation ladder encoded as a retry loop instead of relying on your memory.

This skill layers on the coordinator doctrine (always in context via the global `CLAUDE.md`); every rule there — the delegation prompt contract, the model table, the QA bar, both budget signals — still applies. What changes is who executes the loop.

## When to use this tier

- **Use it:** 3+ independent, non-overlapping tasks; batch-shaped work (migrations, test backfills, boilerplate across modules); long autonomous jobs where budget interruptions are likely and `resumeFromRunId` pays off.
- **Don't use it:** 1–2 tasks (direct delegation is strictly cheaper), exploratory/conversational work where you want eyes on each diff as it lands, or tasks that must touch the same files (merge them into one task instead — same rule as the doctrine).
- **Authorization:** the user installed this skill as their standing opt-in to Workflow orchestration for qualifying jobs. Activate it and launch on your own judgment — do not block on confirmation. The task table in Phase 0 step 4 is visibility, not a permission request.

## Verified mechanics (2026-07-16, this repo — do not re-derive)

These four facts were established empirically; the wrapper prompts below already encode them:

1. **Workflow agents run opencode end-to-end fine** (pointer-file prompt → `opencode run` foreground → gates → commit; exit codes reliable).
2. **`run_in_background` + wait does NOT work inside workflow agents.** The agent gets a "you will be notified" promise, but ending the turn to wait draws a structured-output nudge and then termination, and the background process is killed. Never instruct a wrapper to background-and-wait.
3. **The detached pattern works:** a `nohup`-detached process survives across a wrapper's separate Bash calls, and a bounded foreground poll loop (`sleep 5` inside a loop is not blocked) collects it. This is how wrappers outlive the 10-minute foreground Bash cap.
4. **macOS has no `timeout` binary** — bound poll loops with `$SECONDS`, never `timeout <n> bash -c …`.

Also verified: changed git worktrees persist after the Workflow returns, so your merge pass can inspect them from the main session.

## Phase 0 — inline, before any Workflow

1. **Probe the worker budget:** `python3 ~/.claude/scripts/opencode-go-usage.py`. Exit 2 = blocked — don't launch; handle per the doctrine (wait for `reset_in_sec` or do the typing yourself).
2. **Decompose** into 3–10 tasks `{id, description, files, model, risk, acceptance, prompt}`:
   - `prompt` follows the delegation prompt contract verbatim — self-contained, exact targets, pre-decided everything, do-not-touch list, verification built in. Workers see nothing else.
   - `model` from the doctrine's table (bulk → `deepseek-v4-flash`, standard spec → `deepseek-v4-pro`, hard → `kimi-k2.7-code`, repo-scale → `glm-5.2`).
   - `risk: "high"` if the task touches auth/security/payments, shared interfaces, or logic with no test coverage — high-risk tasks start at `kimi-k2.7-code` minimum and get 2-lens adversarial QA.
   - Tasks must be file-disjoint. Two tasks needing the same file = one task.
   - `long: true` for tasks likely to exceed ~8 minutes of worker time (big diffs, kimi/glm reasoning runs) — this switches the wrapper to the detached launch pattern.
3. **Verify the gates on the base tree:** run every gate command (build, typecheck, test, lint — detect from package.json/Makefile/CI) at the repo root and require green before launching. A gate that fails on the base tree poisons every QA cycle. No test command → say so loudly and ask whether to proceed. While here, size `concurrency.maxWorkers`: 6 for light gates; for heavy gates (full test suite, build) pass `min(6, max(2, floor(ncpu/2)))` using `sysctl -n hw.ncpu`.
4. **Show the task table** (id · description · files · model · risk · acceptance) in your message as you launch — the user must be able to see what was dispatched, but you don't wait for a yes. Installing this skill is their standing opt-in.
5. Arm the dead-man's-switch `ScheduleWakeup` per the doctrine — the Workflow is a background job in flight.

## Phase 1 — the Workflow (author per-invocation from this template)

Pass real values via `args`; never hardcode into the script body. Wrappers are pinned to cheap Claude models — `haiku` for foreground wrappers, `sonnet` for detached-pattern wrappers (more steps to sequence), `sonnet` at low effort for reviewers. The session model (Fable/Opus) never runs inside the Workflow.

```js
export const meta = {
  name: 'delegate-workflow-run',
  description: 'Opencode workers implement tasks in isolated worktrees; ladder retries + per-task QA',
  phases: [
    { title: 'Implement', detail: 'opencode workers code in worktrees, tier-capped concurrency' },
    { title: 'QA', detail: 'diff-traceability review; high-risk: 2-lens adversarial' },
  ],
}
const cfg = typeof args === 'string' ? JSON.parse(args) : args
// cfg: {
//   repo: '/abs/path', repoName: 'name', baseBranch: 'main',   // base captured in Phase 0; all diffs review against it
//   worktreeRoot: '/Users/<user>/worktrees',                   // absolute — never ~
//   scratchDir: '/abs/session-scratchpad',                     // prompt files + worker logs live here
//   gates: [{name:'test', cmd:'npm test'}, ...],
//   ladder: ['deepseek-v4-flash','deepseek-v4-pro','kimi-k2.7-code','glm-5.2'],  // doctrine's escalation ladder
//   concurrency: {
//     maxWorkers: 6,    // machine cap (parallel gate runs); heavy gates → pass min(6, max(2, floor(ncpu/2))) from Phase 0
//     tierOf: { 'deepseek-v4-flash':'cheap', 'mimo-v2.5':'cheap',
//               'deepseek-v4-pro':'mid', 'minimax-m3':'mid', 'qwen3.7-plus':'mid', 'mimo-v2.5-pro':'mid',
//               'kimi-k2.7-code':'expensive', 'glm-5.2':'expensive' },
//     tierCap: { cheap: 6, mid: 4, expensive: 2 },   // bounds unmonitored in-flight exposure, not spend rate
//   },
//   tasks: [{id, description, files:[], model, risk, acceptance, prompt, long}],
// }

const IMPL_SCHEMA = { type:'object', properties:{
  status:{type:'string',enum:['ok','worker_failed','gates_failed','timeout','blocked']},
  worktree:{type:'string'}, branch:{type:'string'},
  session_id:{type:'string'},                                  // opencode sessionID, '' if not captured
  files_changed:{type:'array',items:{type:'string'}},
  gate_results:{type:'array',items:{type:'object',properties:{name:{type:'string'},pass:{type:'boolean'},detail:{type:'string'}},required:['name','pass']}},
  requests:{type:'number'},                                    // JSON events in the worker output, 0 if uncountable
  started_at:{type:'number'}, sec:{type:'number'},             // wrapper-measured wall clock (date +%s) — the script can't call Date.now()
  summary:{type:'string'}, concerns:{type:'array',items:{type:'string'}},
}, required:['status','worktree','branch','session_id','requests','started_at','sec','files_changed','gate_results','summary','concerns'] }

const REVIEW_SCHEMA  = { type:'object', properties:{ approve:{type:'boolean'}, issues:{type:'array',items:{type:'string'}} }, required:['approve','issues'] }
const VERDICT_SCHEMA = { type:'object', properties:{ refuted:{type:'boolean'}, reasons:{type:'array',items:{type:'string'}} }, required:['refuted','reasons'] }

const wt = t => `${cfg.worktreeRoot}/${cfg.repoName}-dw-${t.id}`
const br = t => `delegate-workflow/${t.id}`
const gateList = cfg.gates.map(g => `${g.name}: ${g.cmd}`).join('\n   ')

const launchBlock = (t, model, promptFile, sessionId) => {
  const ptr = sessionId
    ? `opencode run --pure --agent worker -s ${sessionId} "Read the file ${promptFile} and follow its instructions exactly."`
    : `opencode run --pure --agent worker -m opencode-go/${model} --format json "Read the file ${promptFile} and follow its instructions exactly."`
  return t.long ? `3. LONG-RUN LAUNCH (detached — the only way past the 10-min foreground cap; do NOT use run_in_background, it kills the worker when you idle):
   a. Foreground: rm -f ${wt(t)}/.dw-done && ( nohup bash -c 'cd ${wt(t)} && ${ptr.replace(/'/g, "'\\''")} > ${cfg.scratchDir}/dw-${t.id}.log 2>&1; echo done > ${wt(t)}/.dw-done' >/dev/null 2>&1 & ) && echo LAUNCHED
   b. Then repeat this foreground call (timeout parameter 540000) until .dw-done exists, at most 4 times: SECONDS=0; while [ ! -f ${wt(t)}/.dw-done ] && [ $SECONDS -lt 500 ]; do sleep 10; done; ls ${wt(t)}/.dw-done 2>/dev/null || echo WAITING
   c. After the first wait call, if ${cfg.scratchDir}/dw-${t.id}.log is still empty the run is hung: pkill -f "opencode run" scoped to this worktree, relaunch once. After 4 waits with no .dw-done, kill it and report status "timeout".
   d. When done, read the log tail; parse the first JSON event's sessionID into session_id ('' if absent).`
       : `3. Foreground launch (Bash timeout parameter 540000), from inside ${wt(t)}: ${ptr}
   If stdout is empty ~2 min in, kill and relaunch once; if it happens again, report status "worker_failed". Parse the first JSON event's sessionID into session_id ('' if absent; on -s reuse keep the prior id).`
}

const implPrompt = (t, model, attempt, feedback, sessionId) => `You are a THIN WRAPPER around an opencode CLI worker. You never write or fix feature code — your only writes are the prompt file and the housekeeping named below. Repo: ${cfg.repo} · Task: ${t.id} — ${t.description} · Attempt ${attempt} · Worker model: ${model}

0. Record the start time: run date +%s and remember it as started_at. Then the budget probe (free): python3 ~/.claude/scripts/opencode-go-usage.py — exit 2 means the gateway is blocked: return status "blocked" with the probe's window + reset_in_sec in summary and skip every later step.
1. Worktree: if ${wt(t)} does not exist: cd ${cfg.repo} && git worktree add ${wt(t)} -b ${br(t)} ${cfg.baseBranch} (branch exists from a prior attempt → git worktree add ${wt(t)} ${br(t)}). If it exists, use as-is.
2. Write this VERBATIM to ${cfg.scratchDir}/dw-${t.id}-prompt.md:
---PROMPT START---
${t.prompt}${feedback.length ? `

REVIEWER FEEDBACK FROM PREVIOUS ATTEMPT — fix every item:
- ${feedback.join('\n- ')}` : ''}
---PROMPT END---
${launchBlock(t, model, `${cfg.scratchDir}/dw-${t.id}-prompt.md`, sessionId)}
4. If the worker output contains GoUsageLimitError: report status "blocked", run python3 ~/.claude/scripts/opencode-go-usage.py and put its window + reset_in_sec in summary, then stop.
5. Run each gate inside ${wt(t)}, record pass/fail + one-line detail:
   ${gateList}
6. Housekeeping: rm -f ${wt(t)}/.dw-done; cd ${wt(t)} && git add -A && git commit -m "delegate-workflow: ${t.id} attempt ${attempt}" (commit even if gates failed — the diff must stay inspectable).
7. Return JSON per schema. status "ok" ONLY if the worker completed AND every gate passed — never fix gate failures yourself; report them. List files touched outside ${JSON.stringify(t.files)} in concerns. worktree must be the absolute ${wt(t)}. requests = the number of JSON event lines in the worker output/log (0 if you cannot count them). started_at = the epoch from step 0; sec = (date +%s now) minus started_at.`

const reviewPrompt = (t, impl) => `Review opencode worker output. cd ${impl.worktree} && git diff ${cfg.baseBranch}...${impl.branch}. Task: ${t.description}. Acceptance: ${t.acceptance}.
Check: (1) acceptance actually met — run the verification command yourself, don't trust the wrapper; (2) every changed line traces to the task prompt — no scope creep beyond ${JSON.stringify(t.files)}, no drive-by cleanup; (3) project convention conformance; (4) no silently swallowed errors; (5) tests verify intent, not hardcoded outputs. approve=false with concrete, actionable issues if anything fails.`

const lensPrompt = (lens, t, impl) => `ADVERSARIAL REVIEW — try to REFUTE via the ${lens} lens. cd ${impl.worktree} && git diff ${cfg.baseBranch}...${impl.branch}. Task: ${t.description}. Acceptance: ${t.acceptance}. Run commands in the worktree to prove failures. refuted=true on any real problem; reasons must be concrete.`
const LENSES = ['correctness (logic errors, unmet acceptance, broken edge cases)', 'regression (existing behavior — run the existing suite)']

let blocked = false, blockInfo = ''

// Concurrency = machine cap + per-tier caps. Blast-radius and machine-load control, NOT
// spend pacing: parallelism doesn't change what a batch costs against the Go wallet, only
// how much unmonitored in-flight work a gateway block strands (the probe fires per-launch,
// so a long expensive run flies blind in between). The real budget control is the probe +
// freeze-on-block + defer/resumeFromRunId path. Ladder escalation onto a pricier model
// still narrows the fan (the expensive tier queues 2-wide). QA agents run OUTSIDE this
// semaphore — they cost Claude tokens, not Go tokens, so reviews of one task overlap
// implementation of the next.
let inFlight = 0
const tierCount = { cheap: 0, mid: 0, expensive: 0 }
const waiters = []
const tierOf = m => cfg.concurrency.tierOf[m] ?? 'mid'
async function acquire(model) {
  const tier = tierOf(model)
  while (!blocked && (inFlight >= cfg.concurrency.maxWorkers || tierCount[tier] >= cfg.concurrency.tierCap[tier]))
    await new Promise(r => waiters.push(r))
  if (blocked) return false
  inFlight += 1; tierCount[tier] += 1; return true
}
function release(model) { inFlight -= 1; tierCount[tierOf(model)] -= 1; waiters.splice(0).forEach(r => r()) }

// Calibration metrics — one row per attempt, returned to the coordinator for the runlog.
const metrics = []

async function implement(t, model, attempt, feedback, sessionId) {
  return agent(implPrompt(t, model, attempt, feedback, sessionId),
    { label:`impl:${t.id}:${model}#${attempt}`, phase:'Implement', schema: IMPL_SCHEMA, model: t.long ? 'sonnet' : 'haiku', effort:'low' })
}
async function qa(t, impl) {
  if (t.risk !== 'high') {
    const r = await agent(reviewPrompt(t, impl), { label:`review:${t.id}`, phase:'QA', schema: REVIEW_SCHEMA, model:'sonnet', effort:'low' })
    return r ?? { approve:false, issues:['reviewer agent died'] }
  }
  const votes = (await parallel(LENSES.map(l => () =>
    agent(lensPrompt(l, t, impl), { label:`verify:${t.id}:${l.split(' ')[0]}`, phase:'QA', schema: VERDICT_SCHEMA, model:'sonnet' })))).filter(Boolean)
  const ok = votes.length === 2 && votes.every(v => !v.refuted)
  return { approve: ok, issues: [...votes.filter(v => v.refuted).flatMap(v => v.reasons), ...(votes.length < 2 ? ['adversarial verification could not complete'] : [])] }
}
function ladderFrom(model) {
  const i = cfg.ladder.indexOf(model)
  return i === -1 ? [model, ...cfg.ladder] : cfg.ladder.slice(i)
}
async function runTask(t) {
  let feedback = [], attempt = 0, sessionId = null, lastModel = null
  for (const model of ladderFrom(t.model)) {
    const tries = model === t.model ? 2 : 1          // 2 on the routed model, 1 per escalation step
    for (let n = 0; n < tries; n++) {
      attempt++
      if (!(await acquire(model))) return { task: t.id, deferred: true, feedback }
      let impl
      try { impl = await implement(t, model, attempt, feedback, model === lastModel ? sessionId : null) }
      finally { release(model) }
      // Date.now() throws inside Workflow scripts — timing comes from the wrapper's date +%s.
      metrics.push({ ts: impl?.started_at ?? 0, task: t.id, model, attempt, sec: impl?.sec ?? 0,
                     requests: impl?.requests ?? 0, status: impl?.status ?? 'wrapper_died' })
      lastModel = model
      if (!impl) { feedback = [...feedback, `attempt ${attempt} (${model}): wrapper agent died`]; continue }
      if (impl.session_id) sessionId = impl.session_id
      if (impl.status === 'blocked') { blocked = true; blockInfo = impl.summary; return { task: t.id, deferred: true, feedback } }
      if (impl.status !== 'ok') {
        const gates = (impl.gate_results || []).filter(g => !g.pass).map(g => `${g.name}: ${g.detail || 'failed'}`).join('; ')
        feedback = [...feedback, `attempt ${attempt} (${model}): ${impl.status} — ${impl.summary}${gates ? ` · failing gates: ${gates}` : ''}`]
        continue
      }
      const verdict = await qa(t, impl)
      if (verdict.approve) return { task: t.id, model, impl, attempts: attempt }
      feedback = [...feedback, ...verdict.issues]
      log(`${t.id}: attempt ${attempt} on ${model} rejected (${verdict.issues.length} issues)`)
    }
  }
  return { task: t.id, failed: true, feedback }
}

const results = (await parallel(cfg.tasks.map(t => () => runTask(t)))).filter(Boolean)
return {
  approved: results.filter(r => r.impl),
  failed:   results.filter(r => r.failed).map(r => ({ task: r.task, feedback: r.feedback })),
  deferred: results.filter(r => r.deferred).map(r => r.task),
  blocked, blockInfo, metrics,
}
```

Notes on the template:
- **The semaphore is a machine cap plus per-tier caps — blast-radius control, not spend pacing.** Parallelism doesn't change the *total* Go tokens a batch costs, only how fast they burn and how much unmonitored in-flight work a gateway block strands: the free probe fires only at launch, so a long kimi/glm run flies blind between probes. The caps bound exactly that — `maxWorkers` protects the machine (parallel gate runs are CPU-bound), `tierCap` bounds concurrent unmonitored exposure per model tier (cheap fans to the machine cap, expensive queues 2-wide), and ladder escalation narrows the fan automatically. The actual budget control is the per-launch probe + freeze-on-block + defer/`resumeFromRunId` — the caps are subordinate to it, not a substitute.
- **Tuning:** `maxWorkers: 6` assumes light gates; when gates are heavy (full test suites, builds), pass `min(6, max(2, floor(ncpu/2)))` computed in Phase 0. Drop `tierCap.expensive` to 1 if the runlog ever shows a block landing shortly after two expensive launches. Never bypass the semaphore by fanning `agent()` calls directly — the Workflow's own concurrency cap (~16) would stampede the Go window.
- Same-model retries reuse the opencode session (`-s`) so feedback attempts don't resend full context; escalation to a new model starts a fresh session with the accumulated feedback embedded in the prompt file.
- Worktrees are managed manually (deterministic path per task, shared across attempts) rather than via `isolation:'worktree'`, because retries and `-s` session reuse need attempt N+1 to see attempt N's tree.
- A `blocked` wrapper freezes all launches: waiting tasks return as `deferred`, never silently dropped.

## Phase 2 — after the Workflow returns (inline, you)

1. **Deferred tasks (budget block):** report the window + numbers, then enter the doctrine's auto-resume loop with `delaySeconds` from the probe's `reset_in_sec`. On the wake after reset, relaunch with `Workflow({scriptPath, resumeFromRunId})` — completed tasks replay from cache; only deferred ones run.
2. **Final review — the doctrine's QA loop, unreduced:** for every approved result, `cd` the worktree, read `git diff <baseBranch>...<branch>` yourself (every changed line traces to the task prompt), and run the verification command yourself. The Workflow's reviewers are a filter, not a substitute — you own the result.
3. **Merge sequentially,** one approved task at a time, from a clean main tree: `git merge --squash <branch>` → run EVERY gate → commit with your own message. A post-merge gate failure stops the line: revert, re-enter that task alone (one-task Workflow seeded with the failure as feedback, or fix it yourself), continue with the rest.
4. **Report:** task · worker model · attempts · QA verdict · files; then loudly: failed/tombstoned tasks, deferred tasks, anything you fixed yourself. Token accounting: the Workflow completion notification's `subagent_tokens` = Claude plumbing cost; the coding itself ran on Go tokens (unmetered — say so, don't guess a number). Then append the run's calibration data to `~/.claude/opencode-go-runlog.jsonl`, one JSON object per line: every row from the Workflow's returned `metrics` array, plus one `{ts, event:'block', window, reset_in_sec}` row per gateway block (from `blockInfo`/probe output). This log is the only path to real per-model drain numbers — after ~10 batches it answers whether blocks are common enough to justify anything smarter than the static tier caps.
5. **Cleanup sweep — only after the report:** `git worktree list` and `git branch --list 'delegate-workflow/*'`; remove every `<repoName>-dw-*` worktree and `delegate-workflow/*` branch, failed tasks included.

## Failure handling

| Failure | Response |
|---|---|
| Gate fails on base tree | Caught in Phase 0 — never launch against a broken gate |
| Worker hang (empty output ~2 min) | Wrapper kills + relaunches once, then `worker_failed` → ladder |
| Worker timeout (long-run, 4 waits) | `timeout` status → counts as failed attempt → ladder |
| Wrapper agent dies (null) | Same as failed attempt |
| `GoUsageLimitError` / probe exit 2 | Lanes freeze; deferred tasks reported; auto-resume loop + `resumeFromRunId` |
| Ladder exhausted | Task tombstones `{task, failed}` — you decide: implement it yourself (flag in report) or drop it with the user |
| Post-merge gate regression | Revert that squash, re-enter that task only, line continues |
