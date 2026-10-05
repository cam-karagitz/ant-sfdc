#!/usr/bin/env node
// Runs the Ask Claude eval against the demo org (SF_TARGET_ORG).
//
//   node scripts/eval/run.mjs --variant baseline --entry v1      the chat as first measured
//   node scripts/eval/run.mjs --variant v2                       the current chat, into runs/chat/v2
//   node scripts/eval/run.mjs --flow latency --variant v1        the five timed record-page questions
//   node scripts/eval/run.mjs --truth-only                       print ground truth; no model calls
//
// Each case is one anonymous Apex run (step.apex.tmpl) that calls the same Apex method the chat
// panel calls and follows the lookup rounds as the panel does. Ground truth comes from SOQL run
// here, at run time, and is never sent to the model. Rerunning a variant resumes it: finished
// (case, rep) rows are skipped, failed attempts in errors.jsonl are tried again.
import { spawn } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CASES, LATENCY_CASES } from './cases.mjs';
import { grade } from './grade.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT = join(HERE, '..', '..');
// The chat's own function for the page-context note, loaded from the component source.
const { withPageContext } = await import(
    'data:text/javascript,' + encodeURIComponent(readFileSync(join(PROJECT, 'force-app/main/default/lwc/antsuranceClaudeClient/pageContext.js'), 'utf8'))
);
const ORG = process.env.SF_TARGET_ORG;
if (!ORG) {
    console.error('Set SF_TARGET_ORG to the alias of the org to run against.');
    process.exit(2);
}
const DEFAULT_MODEL = 'claude-opus-5-5';
const SPLIT_SEED = 20261002;
const ENTRIES = {
    // The chat before record facts and actions: the page note in the message is all Claude gets.
    v1: { call: 'AntsuranceClaudeController.sendMessage(JSON.serialize(conversation), model)', collect: '' },
    // The chat panel's own call: record facts, proposal cards and the blocks Claude draws.
    v2: {
        call: 'AntsuranceClaudeController.sendChatStep(JSON.serialize(conversation), model, recordId, surface)',
        collect:
            'for (AntsuranceClaudeActions.Proposal proposal : reply.proposals) { proposals.add(JSON.deserializeUntyped(proposal.payloadJson)); }\n' +
            '        for (AntsuranceClaudeDisplay.Block block : reply.blocks) { Map<String, Object> drawn = (Map<String, Object>) JSON.deserializeUntyped(block.specJson); drawn.put(\'kind\', block.kind); blocks.add(drawn); }\n' +
            '        usage.add(reply.usage);'
    }
};

function parseArgs(argv) {
    const args = { flow: 'chat', variant: undefined, entry: 'v2', reps: 1, concurrency: 2, timeoutS: 180, model: undefined, only: undefined, tag: undefined, truthOnly: false, regrade: false, freshTruth: false, note: undefined };
    for (let index = 0; index < argv.length; index += 1) {
        const flag = argv[index];
        const value = () => argv[(index += 1)];
        if (flag === '--flow') args.flow = value();
        else if (flag === '--variant') args.variant = value();
        else if (flag === '--entry') args.entry = value();
        else if (flag === '--reps') args.reps = Number(value());
        else if (flag === '--concurrency') args.concurrency = Number(value());
        else if (flag === '--timeout-s') args.timeoutS = Number(value());
        else if (flag === '--model') args.model = value();
        else if (flag === '--only') args.only = value().split(',');
        else if (flag === '--tag') args.tag = value();
        else if (flag === '--fresh-truth') args.freshTruth = true;
        else if (flag === '--note') args.note = value();
        else if (flag === '--truth-only') args.truthOnly = true;
        else if (flag === '--regrade') args.regrade = true;
        else throw new Error(`Unknown flag ${flag}`);
    }
    return args;
}

/** Runs the Salesforce CLI and returns its parsed --json output. */
function sf(cliArgs, timeoutMs) {
    return new Promise((resolve, reject) => {
        const child = spawn('sf', [...cliArgs, '--target-org', ORG, '--json'], { cwd: PROJECT, env: { ...process.env, SF_DISABLE_TELEMETRY: 'true' } });
        let stdout = '';
        let stderr = '';
        const timer = setTimeout(() => {
            child.kill('SIGKILL');
            reject(Object.assign(new Error(`timed out after ${timeoutMs / 1000}s`), { failureClass: 'timeout' }));
        }, timeoutMs);
        child.stdout.on('data', (chunk) => (stdout += chunk));
        child.stderr.on('data', (chunk) => (stderr += chunk));
        child.on('error', (error) => {
            clearTimeout(timer);
            reject(error);
        });
        child.on('close', () => {
            clearTimeout(timer);
            try {
                resolve(JSON.parse(stdout));
            } catch (error) {
                reject(new Error(`sf returned no JSON: ${(stderr || stdout).slice(0, 300)}`));
            }
        });
    });
}

/** Query rows without the attributes wrapper, child relationships as plain arrays. */
function tidy(value) {
    if (Array.isArray(value)) return value.map(tidy);
    if (value && typeof value === 'object') {
        if (Array.isArray(value.records) && 'totalSize' in value) return value.records.map(tidy);
        return Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'attributes').map(([key, item]) => [key, tidy(item)]));
    }
    return value;
}

async function pool(items, size, worker) {
    const queue = [...items];
    await Promise.all(
        Array.from({ length: Math.min(size, queue.length) }, async () => {
            while (queue.length) {
                // eslint-disable-next-line no-await-in-loop
                await worker(queue.shift());
            }
        })
    );
}

/** Runs every distinct truth query once and returns the rows per case, keyed as the case named them. */
async function loadTruth(cases) {
    const rowsBySoql = new Map();
    for (const item of cases) for (const soql of Object.values(item.truth)) rowsBySoql.set(soql, undefined);
    await pool([...rowsBySoql.keys()], 5, async (soql) => {
        const response = await sf(['data', 'query', '-q', soql], 60000);
        if (response.status !== 0) throw new Error(`Truth query failed: ${response.message}\n${soql}`);
        rowsBySoql.set(soql, tidy(response.result.records));
    });
    return new Map(cases.map((item) => [item.id, Object.fromEntries(Object.entries(item.truth).map(([name, soql]) => [name, rowsBySoql.get(soql)]))]));
}

/** A deterministic shuffle, so the train and test split can be reproduced. */
function shuffled(items, seed) {
    let state = seed;
    const random = () => {
        state = (state * 1664525 + 1013904223) % 4294967296;
        return state / 4294967296;
    };
    const result = [...items];
    for (let index = result.length - 1; index > 0; index -= 1) {
        const other = Math.floor(random() * (index + 1));
        [result[index], result[other]] = [result[other], result[index]];
    }
    return result;
}

/** Half of each category goes to train, the rest to test; drawn once and kept in _state.json. */
function ensureState(flowDir, cases) {
    const path = join(flowDir, '_state.json');
    const state = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : {};
    state.train_ids ??= [];
    state.test_ids ??= [];
    const known = new Set([...state.train_ids, ...state.test_ids]);
    // Cases already placed stay where they are; only new ones are drawn.
    const unplaced = cases.filter((item) => !known.has(item.id));
    if (unplaced.length) {
        const groups = new Map();
        for (const item of unplaced) groups.set(item.tags[0], [...(groups.get(item.tags[0]) ?? []), item.id]);
        let extraToTrain = state.train_ids.length <= state.test_ids.length;
        for (const ids of groups.values()) {
            const order = shuffled(ids, SPLIT_SEED + ids.length);
            // An odd group gives its spare case to train and test in turn.
            const half = ids.length % 2 === 0 ? ids.length / 2 : Math.floor(ids.length / 2) + (extraToTrain ? 1 : 0);
            if (ids.length % 2 === 1) extraToTrain = !extraToTrain;
            state.train_ids.push(...order.slice(0, half));
            state.test_ids.push(...order.slice(half));
        }
    }
    state.metrics = [{ id: 'pass', kind: 'binary', label: 'Correct' }];
    state.perf_fields = [
        { id: 'latency_s', label: 'Time', unit: 's' },
        { id: 'rounds', label: 'Lookups' },
        { id: 'tool_calls', label: 'Queries' }
    ];
    state.goal = { target: 'pass', direction: 'higher', hold: ['latency_s', 'rounds'] };
    writeFileSync(path, JSON.stringify(state, null, 2) + '\n');
    return state;
}

function readJsonl(path) {
    return existsSync(path) ? readFileSync(path, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)) : [];
}

/** The conversation as report turns: tool calls and results get their own entries. */
function toTrace(conversation) {
    const turns = [];
    for (const message of conversation) {
        if (typeof message.content === 'string') {
            turns.push({ role: message.role, content: message.content });
            continue;
        }
        for (const block of message.content) {
            if (block.type === 'text') turns.push({ role: message.role, content: block.text });
            else if (block.type === 'tool_use') turns.push({ role: 'tool_call', name: block.name, content: JSON.stringify(block.input, null, 2) });
            else if (block.type === 'tool_result') turns.push({ role: 'tool_result', content: typeof block.content === 'string' ? block.content : JSON.stringify(block.content) });
        }
    }
    return turns;
}

function median(values) {
    const sorted = [...values].sort((a, b) => a - b);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length === 0 ? NaN : sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const mean = (values) => (values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : NaN);

/** Every model call this eval has made, across all flows and variants, failed attempts included. */
function callsSoFar(runsDir) {
    let calls = 0;
    if (!existsSync(runsDir)) return calls;
    for (const flow of readdirSync(runsDir, { withFileTypes: true })) {
        if (!flow.isDirectory()) continue;
        for (const variant of readdirSync(join(runsDir, flow.name), { withFileTypes: true })) {
            if (!variant.isDirectory()) continue;
            for (const file of ['results.jsonl', 'errors.jsonl']) {
                for (const row of readJsonl(join(runsDir, flow.name, variant.name, file))) calls += row.calls ?? 0;
            }
        }
    }
    return calls;
}

/** Rows that produced an answer, and so have a time and a round count. */
const timed = (rows) => rows.filter((row) => typeof row.latency_s === 'number');

function summarize(rows, state) {
    const line = (label, subset) => {
        if (!subset.length) return `${label}: no rows`;
        const rate = mean(subset.map((row) => row.grade.pass));
        const halfWidth = 1.96 * Math.sqrt((rate * (1 - rate)) / subset.length);
        return (
            `${label}: ${(rate * 100).toFixed(1)}% correct (${subset.filter((row) => row.grade.pass).length}/${subset.length}, 95% CI +/-${(halfWidth * 100).toFixed(0)} pts), ` +
            `lookup rounds mean ${mean(timed(subset).map((row) => row.rounds)).toFixed(2)}, time median ${median(timed(subset).map((row) => row.latency_s)).toFixed(1)}s mean ${mean(timed(subset).map((row) => row.latency_s)).toFixed(1)}s`
        );
    };
    const train = new Set(state.train_ids);
    return [line('all  ', rows), line('train', rows.filter((row) => train.has(row.prompt_id))), line('test ', rows.filter((row) => !train.has(row.prompt_id)))];
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    const cases = (args.flow === 'latency' ? LATENCY_CASES : CASES).filter((item) => (!args.only || args.only.includes(item.id)) && (!args.tag || item.tags.includes(args.tag)));
    const truth = await loadTruth(cases);

    if (args.truthOnly) {
        for (const item of cases) {
            const rows = truth.get(item.id);
            const expected = item.checks(rows, { today: new Date().toISOString().slice(0, 10) }).map((check) => check({ text: '', proposals: [], blocks: [], rowsWritten: 0 }));
            console.log(`${item.id} [${item.tags.join(', ')}]${item.record ? ` on ${item.record(rows)}` : ''}\n  ${[typeof item.prompt === 'function' ? item.prompt(rows) : item.prompt].flat().join('\n  -> ')}`);
            for (const check of expected) console.log(`  - ${check.desc}: ${JSON.stringify(check.expected)}`);
        }
        return;
    }
    if (!args.variant || !/^(baseline|v\d+)$/.test(args.variant)) throw new Error('--variant must be baseline or v<N>');
    const entry = ENTRIES[args.entry];
    if (!entry) throw new Error(`--entry must be one of ${Object.keys(ENTRIES).join(', ')}`);

    const runsDir = join(HERE, 'runs');
    const flowDir = join(runsDir, args.flow);
    const variantDir = join(flowDir, args.variant);
    mkdirSync(join(variantDir, 'traces'), { recursive: true });
    const state = ensureState(flowDir, cases.length === (args.flow === 'latency' ? LATENCY_CASES : CASES).length ? cases : args.flow === 'latency' ? LATENCY_CASES : CASES);
    const resultsPath = join(variantDir, 'results.jsonl');
    const errorsPath = join(variantDir, 'errors.jsonl');
    const done = new Set(readJsonl(resultsPath).map((row) => `${row.prompt_id}#${row.rep}`));

    if (args.regrade) {
        // Scores stored answers again after a check was corrected. No model calls. Ground truth is
        // read from the org now, so regrade soon after the run and name the cases with --only.
        const byId = new Map(cases.map((item) => [item.id, item]));
        const regraded = readJsonl(resultsPath).map((row) => {
            const item = byId.get(row.prompt_id);
            if (!item || row.stop_reason === 'app_error') return row;
            // Rows from before the write check moved to the transaction's own DML count hold task and note counts.
            const out = { text: row.meta.answer, proposals: row.proposals ?? [], blocks: row.blocks ?? [], rowsWritten: row.rows_written ?? (row.writes?.tasks ?? 0) + (row.writes?.notes ?? 0), today: row.meta.org_date };
            const graded = grade(item.checks(truth.get(item.id), out), out);
            const explanation = graded.checks.map((check) => `${check.pass ? 'ok' : 'FAIL'} ${check.desc}: expected ${JSON.stringify(check.expected)}; got ${JSON.stringify(check.got)}`).join(' | ');
            if (graded.pass !== row.grade.pass) console.log(`  ${row.prompt_id} rep ${row.rep}: ${row.grade.pass} -> ${graded.pass}`);
            return { ...row, grade: { pass: graded.pass }, explanation: { pass: explanation } };
        });
        writeFileSync(resultsPath, regraded.map((row) => JSON.stringify(row)).join('\n') + '\n');
        for (const line of summarize(regraded, state)) console.log(`  ${line}`);
        return;
    }

    const template = readFileSync(join(HERE, 'step.apex.tmpl'), 'utf8').replace('{{CALL}}', entry.call).replace('{{COLLECT}}', entry.collect);
    // The real client function writes the note; Apex fills in the record's details.
    const noteTemplate = withPageContext({ objectLabel: '@@LABEL@@', name: '@@NAME@@', objectApiName: '@@API@@', recordId: '@@ID@@' }, '@@PROMPT@@');
    // The generated Apex scripts are throwaway, so they stay out of the runs folder.
    const scratch = mkdtempSync(join(tmpdir(), 'ask-claude-eval-'));

    const jobs = [];
    for (const item of cases) for (let rep = 0; rep < args.reps; rep += 1) if (!done.has(`${item.id}#${rep}`)) jobs.push({ item, rep });
    console.log(`${args.flow}/${args.variant}: ${jobs.length} of ${cases.length * args.reps} runs to do (${cases.length} cases x ${args.reps} reps, entry ${args.entry}, model ${args.model ?? DEFAULT_MODEL}); ${callsSoFar(runsDir)} model calls used so far`);

    let finished = 0;
    await pool(jobs, args.concurrency, async ({ item, rep }) => {
        // The ground truth read at the start is used unless --fresh-truth is given, which reads it again
        // just before each question: for when other work is changing the demo records during a pass.
        // Reading once keeps the pass to about half the Salesforce API calls.
        let rows;
        try {
            rows = args.freshTruth ? (await loadTruth([item])).get(item.id) : truth.get(item.id);
        } catch (error) {
            appendFileSync(errorsPath, JSON.stringify({ prompt_id: item.id, rep, failure_class: 'fixture', message: error.message, calls: 0, at: new Date().toISOString() }) + '\n');
            console.log(`  ! ${item.id} rep ${rep}: fixture: ${error.message}`);
            return;
        }
        let prompts;
        let recordId;
        try {
            // A case is one typed message, or several in a row for a follow-up conversation.
            prompts = [typeof item.prompt === 'function' ? item.prompt(rows) : item.prompt].flat();
            recordId = item.record ? item.record(rows) : null;
            item.checks(rows, { today: '2000-01-01' });
        } catch (error) {
            // The demo records this case is built on are missing, as they are while the demo data reloads.
            appendFileSync(errorsPath, JSON.stringify({ prompt_id: item.id, rep, failure_class: 'fixture', message: error.message, calls: 0, at: new Date().toISOString() }) + '\n');
            console.log(`  ! ${item.id} rep ${rep}: fixture: ${error.message}`);
            return;
        }
        const prompt = prompts.join('\n-> ');
        // A question asked from a record is asked in the utility bar panel; otherwise on the Ask Claude tab.
        const spec = { prompts, model: args.model ?? null, recordId, surface: item.surface ?? (recordId ? 'panel' : 'page'), noteTemplate };
        const apexPath = join(scratch, `${item.id}_rep${rep}.apex`);
        writeFileSync(apexPath, template.replace('{{SPEC_B64}}', Buffer.from(JSON.stringify(spec)).toString('base64')));
        const fail = (failureClass, message, out) => {
            appendFileSync(errorsPath, JSON.stringify({ prompt_id: item.id, rep, failure_class: failureClass, message, calls: out?.stepMs?.length ?? 0, model: out?.model, at: new Date().toISOString() }) + '\n');
            console.log(`  ! ${item.id} rep ${rep}: ${failureClass}: ${message}`);
        };
        const crashed = (problem) => {
            const row = {
                prompt_id: item.id,
                rep,
                prompt,
                tags: item.tags,
                split: state.train_ids.includes(item.id) ? 'train' : 'test',
                status: 'ok',
                stop_reason: 'app_error',
                grade: { pass: 0 },
                explanation: { pass: `FAIL the chat's Apex threw instead of answering: ${problem.replace(/\s+/g, ' ').slice(0, 300)}` },
                model: args.model ?? DEFAULT_MODEL,
                // At least the call that produced the tool call was made before the crash.
                calls: 1,
                proposals: [],
                blocks: [],
                meta: { record_id: recordId, answer: null, crash: problem.slice(0, 600) }
            };
            writeFileSync(join(variantDir, 'traces', `${item.id}_rep${rep}.json`), JSON.stringify([{ role: 'user', content: prompt }, { role: 'assistant', content: `[The chat showed an error: ${problem}]` }], null, 2));
            appendFileSync(resultsPath, JSON.stringify(row) + '\n');
            finished += 1;
            console.log(`  FAIL ${item.id} rep ${rep}  the chat's Apex threw  (${finished}/${jobs.length})`);
        };
        let out;
        try {
            const response = await sf(['apex', 'run', '--file', apexPath], args.timeoutS * 1000);
            const logs = response.result?.logs ?? '';
            const marker = logs.split('\n').find((logLine) => logLine.includes('|EVAL_RESULT {'));
            if (!marker) {
                const problem = [response.result?.exceptionMessage, response.result?.compileProblem, response.message, response.data?.exceptionMessage].filter(Boolean).join(' ') || 'no EVAL_RESULT line in the log';
                const where = `${response.result?.exceptionStackTrace ?? ''} ${response.data?.exceptionStackTrace ?? ''} ${logs.slice(-4000)}`;
                if (/System\.\w+Exception/.test(problem) && /Class\.AntsuranceClaude/.test(where)) {
                    // The chat's own Apex died on an exception it cannot catch. The user would see an
                    // error instead of an answer, so this is a wrong answer, not a harness failure.
                    crashed(problem);
                    return;
                }
                fail('harness', problem.slice(0, 300));
                return;
            }
            // The debug log escapes its own field separator; put the pipes back.
            out = JSON.parse(marker.slice(marker.indexOf('EVAL_RESULT ') + 'EVAL_RESULT '.length).replaceAll('&#124;', '|'));
        } catch (error) {
            fail(error.failureClass ?? 'harness', error.message);
            return;
        }
        if (out.error || !out.done) {
            fail(out.error ? 'serving' : 'unfinished', out.error ?? `no answer after ${out.stepMs.length} steps`, out);
            return;
        }
        if (!String(out.model ?? '').startsWith(args.model ?? DEFAULT_MODEL)) {
            // A classifier fallback can serve another model; that is a different thing from the chat being wrong.
            fail('served_model', `asked for ${args.model ?? DEFAULT_MODEL}, served ${out.model}`, out);
            return;
        }
        const graded = grade(item.checks(rows, out), out);
        const usage = (out.usage ?? []).filter(Boolean).reduce(
            (sum, step) => {
                for (const key of Object.keys(sum)) sum[key] += Number(step[key] ?? 0);
                return sum;
            },
            { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
        );
        const row = {
            prompt_id: item.id,
            rep,
            prompt,
            tags: item.tags,
            split: state.train_ids.includes(item.id) ? 'train' : 'test',
            status: 'ok',
            stop_reason: out.refused ? 'refusal' : 'end_turn',
            grade: { pass: item.checks(rows, out).length ? graded.pass : 1 },
            explanation: { pass: graded.checks.map((check) => `${check.pass ? 'ok' : 'FAIL'} ${check.desc}: expected ${JSON.stringify(check.expected)}; got ${JSON.stringify(check.got)}`).join(' | ') },
            model: out.model,
            latency_s: out.totalMs / 1000,
            step_s: out.stepMs.map((ms) => ms / 1000),
            calls: out.stepMs.length,
            rounds: out.stepMs.length - prompts.length,
            tool_calls: out.queries.length,
            proposals: out.proposals,
            blocks: out.blocks ?? [],
            block_kinds: (out.blocks ?? []).map((block) => block.kind),
            rows_written: out.rowsWritten,
            usage,
            // Which speed served each call: fast mode falls back to standard when it is rate limited.
            speeds: (out.usage ?? []).map((step) => step?.speed ?? null),
            meta: { record_id: recordId, answer: out.text, queries: out.queries, org_date: out.today }
        };
        writeFileSync(join(variantDir, 'traces', `${item.id}_rep${rep}.json`), JSON.stringify(
                [
                    ...toTrace(out.conversation),
                    ...(out.proposals.length ? [{ role: 'assistant', content: `Proposal cards shown: ${JSON.stringify(out.proposals, null, 2)}` }] : []),
                    ...((out.blocks ?? []).length ? [{ role: 'assistant', content: `Blocks drawn: ${JSON.stringify(out.blocks, null, 2)}` }] : [])
                ],
                null,
                2
            )
        );
        appendFileSync(resultsPath, JSON.stringify(row) + '\n');
        finished += 1;
        console.log(`  ${graded.pass ? 'pass' : 'FAIL'} ${item.id} rep ${rep}  ${row.latency_s.toFixed(1)}s  ${row.rounds} lookup rounds  ${row.block_kinds.join('+') || 'text'}  (${finished}/${jobs.length})`);
    });

    const rows = readJsonl(resultsPath);
    const errors = readJsonl(errorsPath).filter((error) => !rows.some((row) => row.prompt_id === error.prompt_id && row.rep === error.rep));
    const summary = existsSync(join(variantDir, 'summary.json')) ? JSON.parse(readFileSync(join(variantDir, 'summary.json'), 'utf8')) : {};
    if (args.note) summary.description = args.note;
    writeFileSync(join(variantDir, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
    console.log(`\n${args.flow}/${args.variant}: ${rows.length} rows, ${errors.length} unresolved failed attempts`);
    for (const line of summarize(rows, state)) console.log(`  ${line}`);
    console.log(`  model calls: this variant ${rows.reduce((sum, row) => sum + row.calls, 0)}, eval total so far ${callsSoFar(runsDir)}`);
}

main().catch((error) => {
    console.error(error.message);
    process.exit(1);
});
