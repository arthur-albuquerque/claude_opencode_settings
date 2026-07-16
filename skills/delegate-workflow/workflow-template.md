# delegate-workflow — Workflow template (Phase 1 reference)

Disclosed reference for [`delegate-workflow`](SKILL.md). Author the Workflow per-invocation from the template below; pass real values via `args`, never hardcode into the script body. Wrappers are pinned to cheap Claude models — `haiku` for foreground wrappers, `sonnet` for detached-pattern wrappers (more steps to sequence), `sonnet` at low effort for reviewers. The session model (Fable/Opus) never runs inside the Workflow.

## Verified mechanics (2026-07-16, this repo — do not re-derive)

These four facts were established empirically; the wrapper prompts below already encode them:

1. **Workflow agents run opencode end-to-end fine** (pointer-file prompt → `opencode run` foreground → gates → commit; exit codes reliable).
2. **`run_in_background` + wait does NOT work inside workflow agents.** The agent gets a "you will be notified" promise, but ending the turn to wait draws a structured-output nudge and then termination, and the background process is killed. Never instruct a wrapper to background-and-wait.
3. **The detached pattern works:** a `nohup`-detached process survives across a wrapper's separate Bash calls, and a bounded foreground poll loop (`sleep 5` inside a loop is not blocked) collects it. This is how wrappers outlive the 10-minute foreground Bash cap.
4. **macOS has no `timeout` binary** — bound poll loops with `$SECONDS`, never `timeout <n> bash -c …`.

Also verified: changed git worktrees persist after the Workflow returns, so your merge pass can inspect them from the main session.

## The template

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

// Machine cap + per-tier caps — blast-radius control, not spend pacing (see notes).
// QA agents run outside this semaphore.
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

## Notes on the template

- **The semaphore is a machine cap plus per-tier caps — blast-radius control, not spend pacing.** Parallelism doesn't change the *total* Go tokens a batch costs, only how fast they burn and how much unmonitored in-flight work a gateway block strands: the free probe fires only at launch, so a long kimi/glm run flies blind between probes. The caps bound exactly that — `maxWorkers` protects the machine (parallel gate runs are CPU-bound), `tierCap` bounds concurrent unmonitored exposure per model tier (cheap fans to the machine cap, expensive queues 2-wide), and ladder escalation narrows the fan automatically. The actual budget control is the per-launch probe + freeze-on-block + defer/`resumeFromRunId` — the caps are subordinate to it, not a substitute. QA agents run outside the semaphore — they cost Claude tokens, not Go tokens, so reviews of one task overlap implementation of the next.
- **Tuning:** `maxWorkers: 6` assumes light gates; when gates are heavy (full test suites, builds), pass `min(6, max(2, floor(ncpu/2)))` computed in Phase 0. Drop `tierCap.expensive` to 1 if the runlog ever shows a block landing shortly after two expensive launches. Never bypass the semaphore by fanning `agent()` calls directly — the Workflow's own concurrency cap (~16) would stampede the Go window.
- Same-model retries reuse the opencode session (`-s`) so feedback attempts don't resend full context; escalation to a new model starts a fresh session with the accumulated feedback embedded in the prompt file.
- Worktrees are managed manually (deterministic path per task, shared across attempts) rather than via `isolation:'worktree'`, because retries and `-s` session reuse need attempt N+1 to see attempt N's tree.
- A `blocked` wrapper freezes all launches: waiting tasks return as `deferred`, never silently dropped.
