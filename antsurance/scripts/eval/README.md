# Ask Claude eval

Measures whether the chat on the Ask Claude tab and in the utility bar answers correctly, how many
record lookups it needs, and how long it takes. It asks 84 questions an insurance user would ask:
counts, totals and rankings, lookups, questions asked from a record page, multi-step questions and
follow-ups, things the chat should say it cannot see or do, requests to act that must come back
as a proposal card and never as a write, and 21 questions (tag `display`) whose answer has a
natural shape, which check that Claude drew that block and filled it correctly: a chart whose
points match SOQL, the right record's card, a form on the right object with the right values, a
draft to the right person, a comparison, a timeline, and plain words where no block belongs.

## How it works

- `cases.mjs` holds the questions. Each names the SOQL that gives its ground truth and the checks
  on the answer. `LATENCY_CASES` are the five record-page questions used for timing.
- `run.mjs` reads the ground truth from the org with `sf data query` at run time, then runs each
  case as anonymous Apex (`step.apex.tmpl`). That script calls the same method the chat panel calls,
  `AntsuranceClaudeController.sendChatStep`, with the page-context note built by the chat's own
  `withPageContext`, and follows lookup rounds the way `c/antsuranceClaudeClient` does. The model
  never sees the ground truth.
- `grade.mjs` scores the answer. Every check is programmatic: a count or amount written in the
  answer (a rounded figure passes only at the precision shown), names that must appear, a date,
  a plain statement that something is not available, the proposal cards returned, the blocks
  drawn, and the record counts before and after. An answer is Claude's words plus what its blocks
  show, so a figure on a tile or in a chart counts as said; follow-up question buttons do not.
  `node scripts/eval/grade.mjs` self-tests the checks.
- Results go to `runs/<flow>/<variant>/`: `results.jsonl` (one row per case and rep, with the
  grade, the reason for each check, time, lookup rounds and token counts), `traces/` (the full
  exchange) and `errors.jsonl` (attempts that failed before there was an answer to score).
  `runs/chat/_state.json` holds the train and test split.

## Running it

From `antsurance/`, with the demo org authorized and `SF_TARGET_ORG` set to its alias:

```
node scripts/eval/run.mjs --truth-only                 # print ground truth; no model calls
node scripts/eval/run.mjs --variant v3                 # a full pass into runs/chat/v3
node scripts/eval/run.mjs --variant v3 --only count-open-claims,record-claim-summary
node scripts/eval/run.mjs --flow latency --variant v2 --reps 2   # the five timed questions
node scripts/eval/run.mjs --variant v3 --regrade --only <id>     # rescore stored answers after fixing a check
node scripts/eval/run.mjs --variant v3 --tag display             # only the cases about what the chat draws
node scripts/eval/run.mjs --variant v3 --fresh-truth             # read ground truth again before each question
```

A full pass is about 140 model calls, under 150 Salesforce API calls (one `sf apex run` per case
and one query per distinct ground truth) and five minutes. Rerunning a variant resumes it. Variants are named `baseline` or `v<N>`; put what changed
in `runs/chat/v<N>/change.md`.

## Reading the numbers

- One rep of 84 cases resolves about 4 points overall and about 6 on a 42-case split. Do not
  act on a difference smaller than that without more reps.
- Ground truth is read once, when the pass starts. If other work is changing the demo records
  during a pass, add `--fresh-truth`: each case then reads its ground truth again just before it
  asks its question, at about twice the Salesforce API calls. A case whose records are missing is
  logged as a `fixture` error; rerun to resume. If a record still changed between the truth query
  and the answer, fix nothing in the chat: rescore that row with `--regrade` once the data has
  settled.
- A question asked from a record is asked as the utility bar panel asks it (`surface` panel);
  the rest are asked as the Ask Claude tab does. A case can set `surface` itself.
- Time is measured inside Apex, around each call. Fast mode has its own rate limit and falls back
  to standard speed when other work is using the key, so compare times only between runs whose
  rows show `speeds` as `fast`, and use the latency flow at `--concurrency 2` for a headline.
- A case fails as `app_error` when the chat's own Apex throws: the user would have seen an error.
- The eval never confirms a proposal, so it writes nothing to the org. Each case also checks
  that its own Apex transaction made no DML.
