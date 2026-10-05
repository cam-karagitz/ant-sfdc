// Checks for the Ask Claude eval. Every check is programmatic: it compares the answer text, the
// blocks the chat drew (a chart, a record card, a form and so on) or the action proposals it
// returned with values the runner read from the org with SOQL.
// Run `node scripts/eval/grade.mjs` to self-test the checks (no model calls).

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const MONTH_PATTERN = MONTHS.map((month) => `${month}|${month.slice(0, 3)}`).join('|') + '|Sept';
const WORD_NUMBERS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
    'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty'];
const MULTIPLIERS = { k: 1e3, m: 1e6, mm: 1e6, million: 1e6, thousand: 1e3, bn: 1e9, billion: 1e9 };
// How someone says a thing is not in the CRM, or that they will not or cannot do it.
const UNKNOWN_OR_DECLINED = new RegExp(
    "can['’]?t|cannot|can not|unable|not able|won['’]t|" +
        "do(?:es)?n['’]t (?:have|hold|store|track|record|exist|include|see|show)|do(?:es)? not (?:have|hold|store|track|record|exist|include|see|show)|" +
        "(?:is|are)n['’]t (?:stored|available|recorded|tracked|in |any|something|a |an |one of|valid)|(?:is|are) not (?:stored|available|recorded|tracked|in |something|a |an |one of|valid)|" +
        "couldn['’]t find|could not find|didn['’]t find|did not find|not found|no (?:such|matching|record|policy|field|data|claims? (?:on|for))|" +
        "there (?:is|are) no\\b|nothing (?:in|on)|only (?:read|look)|read[- ]only",
    'i'
);

/** The answer as plain words: Markdown links become their text and emphasis marks are dropped. */
export function plain(text) {
    return String(text ?? '')
        .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
        .replace(/[*_`#|>]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

const UNIT_WRITERS = {
    dollars: (value) => `$${Number(value).toLocaleString('en-US')}`,
    percent: (value) => `${value}%`,
    count: (value) => String(value)
};

/** What a block shows, as words: the same content a person reads off it in the chat. */
export function blockText(block) {
    const line = (...parts) => parts.filter((part) => part !== undefined && part !== null && part !== '').join(' ');
    switch (block.kind) {
        case 'metrics':
            return block.tiles.map((tile) => line(`${tile.label}:`, tile.value, tile.note)).join('. ');
        case 'chart':
            return [line(block.title, block.caption), ...block.points.map((point) => `${point.label}: ${(UNIT_WRITERS[block.unit] ?? String)(point.value)}`)].join('. ');
        case 'work_list':
            return [block.title, ...block.items.map((item) => line(item.title, item.subtitle, item.amount, ...item.chips.map((chip) => chip.label)))].join('. ');
        case 'record':
            return [line(block.eyebrow, block.name, block.status, block.figureLabel, block.figure), ...(block.facts ?? []).map((fact) => `${fact.label}: ${fact.value}`), block.body ?? ''].join('. ');
        case 'form':
            return [block.title, ...block.fields.map((field) => `${field.label}: ${field.value ?? ''}`)].join('. ');
        case 'draft':
            return [line('To', block.toName, block.toEmail), block.subject, block.body].join('. ');
        case 'comparison':
            return [block.title, block.columns.map((column) => column.name).join(', '), ...block.rows.map((row) => `${row.label}: ${row.values.join(', ')}`), block.reason ?? ''].join('. ');
        case 'timeline':
            return [block.title, ...block.events.map((event) => line(event.date, event.title, event.detail))].join('. ');
        default:
            // Follow-up questions are not part of the answer.
            return '';
    }
}

/** Everything the answer says: Claude's words and what its blocks show. */
export function said(out) {
    return [out.text ?? '', ...(out.blocks ?? []).map(blockText)].filter(Boolean).join('\n');
}

/** The blocks an answer drew, leaving out the follow-up questions. */
export const drawn = (out) => (out.blocks ?? []).filter((block) => block.kind !== 'next_questions');

/** Blanks out dates so a day or year is never read as a count or an amount. */
function withoutDates(text) {
    return text
        .replace(/\b\d{4}-\d{2}-\d{2}\b/g, ' ')
        .replace(new RegExp(`\\b\\d{1,2}(?:st|nd|rd|th)?\\s+(?:of\\s+)?(?:${MONTH_PATTERN})\\.?(?:,?\\s+\\d{4})?`, 'gi'), ' ')
        .replace(new RegExp(`\\b(?:${MONTH_PATTERN})\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+\\d{4})?`, 'gi'), ' ')
        .replace(new RegExp(`\\b(?:${MONTH_PATTERN})\\.?\\s+\\d{4}`, 'gi'), ' ')
        .replace(/\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/g, ' ');
}

/** Every number written in the text, with the precision it was written to. */
export function numbersIn(text) {
    const found = [];
    const cleaned = withoutDates(plain(text));
    const pattern = /(?<![\w.-])(\$)?\s?(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?\s?(%|(?:k|m|mm|bn|million|thousand|billion)\b)?/gi;
    for (const match of cleaned.matchAll(pattern)) {
        const [raw, dollar, whole, fraction = '', suffix = ''] = match;
        const unit = suffix.toLowerCase();
        const multiplier = MULTIPLIERS[unit] ?? 1;
        const decimals = fraction ? fraction.length - 1 : 0;
        found.push({
            raw: raw.trim(),
            value: Number(whole.replace(/,/g, '') + fraction) * multiplier,
            // The size of the last digit written: 1.08M is good to 10,000.
            quantum: Math.pow(10, -decimals) * multiplier,
            money: Boolean(dollar),
            percent: unit === '%',
            bare: !dollar && !unit && !fraction
        });
    }
    const words = cleaned.toLowerCase();
    WORD_NUMBERS.forEach((word, value) => {
        if (new RegExp(`\\b${word}\\b`).test(words)) {
            found.push({ raw: word, value, quantum: 1, money: false, percent: false, bare: true });
        }
    });
    return found;
}

const result = (pass, desc, expected, got) => ({ pass: Boolean(pass), desc, expected, got });

/** A whole number of things, written exactly. */
export function count(expected, what = 'count') {
    return (out) => {
        const text = plain(said(out));
        const numbers = numbersIn(said(out)).filter((number) => number.bare);
        let pass = numbers.some((number) => number.value === expected);
        if (expected === 0 && /\b(?:no|none|zero|not any|aren['’]t any|isn['’]t any)\b/i.test(text)) {
            pass = true;
        }
        return result(pass, what, expected, numbers.map((number) => number.raw).join(' '));
    };
}

/**
 * An amount or percentage. A rounded figure passes when it is the expected value at the precision
 * shown and that precision is within 3% of the value, so $1.08M passes for 1,076,575 and $1.1M does not.
 */
export function amount(expected, what = 'amount') {
    return (out) => {
        const numbers = numbersIn(said(out));
        const pass = numbers.some(
            (number) =>
                Math.abs(number.value - expected) <= Math.max(number.quantum / 2, 0.5) + 1e-9 &&
                number.quantum <= Math.max(1, Math.abs(expected) * 0.03)
        );
        return result(pass, what, expected, numbers.map((number) => number.raw).join(' '));
    };
}

/** Every one of these appears in the answer (case-insensitive). */
export function containsAll(values, what = 'mentions') {
    return (out) => {
        const text = plain(said(out)).toLowerCase();
        const missing = values.filter((value) => !text.includes(String(value).toLowerCase()));
        return result(missing.length === 0, what, values, missing.length ? `missing: ${missing.join('; ')}` : 'all present');
    };
}

/** At least one of these appears in the answer. */
export function containsAny(values, what = 'mentions one of') {
    return (out) => {
        const text = plain(said(out)).toLowerCase();
        const hit = values.find((value) => text.includes(String(value).toLowerCase()));
        return result(hit !== undefined, what, values, hit ?? 'none present');
    };
}

/** For each record, at least one of its names appears: a claim by number or by subject, say. */
export function eachAny(rows, what = 'names each record') {
    return (out) => {
        const text = plain(said(out)).toLowerCase();
        const missing = rows.filter((names) => !names.some((name) => name && text.includes(String(name).toLowerCase())));
        return result(missing.length === 0, what, rows, missing.length ? `missing: ${missing.map((names) => names[0]).join('; ')}` : 'all present');
    };
}

/** None of these appear, as text or as a regular expression. */
export function containsNone(patterns, what = 'does not mention') {
    return (out) => {
        const text = plain(said(out));
        const hit = patterns.find((pattern) => (pattern instanceof RegExp ? pattern.test(text) : text.toLowerCase().includes(String(pattern).toLowerCase())));
        return result(hit === undefined, what, patterns.map(String), hit === undefined ? 'none present' : `found ${hit}`);
    };
}

/** A date given as YYYY-MM-DD, written any of the usual ways, with or without the year. */
export function date(iso, what = 'date') {
    return (out) => {
        const [year, month, day] = iso.split('-').map(Number);
        const name = `(?:${MONTHS[month - 1]}|${MONTHS[month - 1].slice(0, 3)}${month === 9 ? '|Sept' : ''})\\.?`;
        const pattern = new RegExp(`\\b0?${day}(?:st|nd|rd|th)?\\s+(?:of\\s+)?${name}(?!\\w)|${name}\\s+0?${day}(?:st|nd|rd|th)?\\b|${iso}|\\b0?${month}/0?${day}(?:/(?:${year}|${year % 100}))?\\b`, 'i');
        // A timeline writes its dates as YYYY-MM-DD, which the pattern also takes.
        const text = plain(said(out));
        return result(pattern.test(text), what, iso, text.slice(0, 160));
    };
}

/** A yes or no question: the opening sentence takes the expected side. */
export function yesNo(expected, what = 'yes or no') {
    return (out) => {
        const lead = plain(out.text).split(/(?<=[.!?])\s/)[0].toLowerCase();
        const negative = /\bno\b|\bnot\b|n['’]t\b/.test(lead);
        const positive = /\byes\b/.test(lead) || !negative;
        return result(expected ? positive && !/\bno\b/.test(lead) : negative, what, expected, lead.slice(0, 160));
    };
}

/** The answer says the thing is not in the CRM, or declines to do it. */
export function unknownOrDeclined(what = 'says it cannot see or do that') {
    return (out) => {
        const text = plain(out.text);
        return result(UNKNOWN_OR_DECLINED.test(text), what, 'a plain statement that it is not available or not possible', text.slice(0, 200));
    };
}

/** One proposal of this kind whose fields satisfy the test. Nothing is written by a proposal. */
export function proposes(kind, test, what) {
    return (out) => {
        const ofKind = (out.proposals ?? []).filter((proposal) => proposal.kind === kind);
        const failures = ofKind.map((proposal) => test(proposal));
        const pass = failures.some((failure) => failure === true);
        return result(pass, what ?? `proposes a ${kind}`, kind, ofKind.length ? JSON.stringify(ofKind).slice(0, 400) + (pass ? '' : ` -> ${failures.join('; ')}`) : 'no such proposal');
    };
}

/** No proposal card and no form: nothing the user could save with a press. */
export function proposesNothing(what = 'proposes nothing') {
    return (out) => {
        const offered = [...(out.proposals ?? []).map((proposal) => proposal.kind), ...drawn(out).filter((block) => block.kind === 'form').map(() => 'form')];
        return result(offered.length === 0, what, 0, offered.length ? offered.join(', ') : 0);
    };
}

/** One block of this kind (or one of these kinds) whose content satisfies the test. */
export function shows(kinds, test = () => true, what) {
    const wanted = [kinds].flat();
    return (out) => {
        const ofKind = drawn(out).filter((block) => wanted.includes(block.kind));
        const verdicts = ofKind.map((block) => test(block));
        const pass = verdicts.some((verdict) => verdict === true);
        const others = drawn(out).map((block) => block.kind).join(', ') || 'no blocks';
        return result(pass, what ?? `draws a ${wanted.join(' or ')}`, wanted.join(' or '), ofKind.length ? JSON.stringify(ofKind).slice(0, 500) + (pass ? '' : ` -> ${verdicts.join('; ')}`) : `drew ${others}`);
    };
}

/** No block of these kinds; with no kinds given, no block at all (follow-up questions aside). */
export function showsNo(kinds, what) {
    const banned = kinds ? [kinds].flat() : undefined;
    return (out) => {
        const found = drawn(out).filter((block) => !banned || banned.includes(block.kind)).map((block) => block.kind);
        return result(found.length === 0, what ?? (banned ? `draws no ${banned.join(' or ')}` : 'draws no block'), 0, found.length ? found.join(', ') : 0);
    };
}

/** At most this many blocks under the answer (follow-up questions aside). */
export function atMostBlocks(limit = 2) {
    return (out) => result(drawn(out).length <= limit, `at most ${limit} blocks`, limit, drawn(out).length);
}

const sameLabel = (a, b) => {
    const [left, right] = [a, b].map((label) => String(label ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim());
    return left !== '' && right !== '' && (left === right || left.includes(right) || right.includes(left));
};

/**
 * For use inside shows(): the chart's points are exactly these labels and values. A label matches
 * when one contains the other, so "Workers Comp" stands for "Workers Compensation".
 */
export function chartPoints(expected, { exact = true } = {}) {
    return (block) => {
        const missing = expected.filter((want) => !block.points.some((point) => sameLabel(point.label, want.label) && Math.abs(point.value - want.value) <= 0.5));
        if (missing.length) return `points missing or wrong: ${missing.map((want) => `${want.label}=${want.value}`).join(', ')}`;
        if (exact && block.points.length !== expected.length) return `${block.points.length} points for ${expected.length} values`;
        return true;
    };
}

/** For use inside shows(): the form's field holds this value (compared as text, ignoring case), or any value when none is given. */
export function formField(block, name, value) {
    const field = (block.fields ?? []).find((candidate) => candidate.name.toLowerCase() === name.toLowerCase());
    if (!field) return `no ${name} field`;
    if (value === undefined) return true;
    const got = String(field.value ?? '');
    const same = typeof value === 'number' ? Number(got) === value : value instanceof RegExp ? value.test(got) : got.toLowerCase() === String(value).toLowerCase() || got.slice(0, 15) === String(value).slice(0, 15);
    return same || `${name} is ${JSON.stringify(field.value)}`;
}

/** The exchange wrote no record: the Apex transaction that ran the chat made no DML. */
export function writesNothing(what = 'writes nothing') {
    return (out) => result(out.rowsWritten === 0, what, 0, `${out.rowsWritten} rows written`);
}

/** Runs a case's checks against one run's output. A case passes when every check does. */
export function grade(checks, out) {
    const results = checks.map((check) => check(out));
    return { pass: results.every((check) => check.pass) ? 1 : 0, checks: results };
}

export function addDays(iso, days) {
    const value = new Date(`${iso}T12:00:00Z`);
    value.setUTCDate(value.getUTCDate() + days);
    return value.toISOString().slice(0, 10);
}

// Self-test: reference answers must pass and empty or wrong answers must fail.
if (import.meta.url === `file://${process.argv[1]}`) {
    const answer = (text, extra = {}) => ({ text, proposals: [], rowsWritten: 0, ...extra });
    const cases = [
        ['count exact', count(28), answer('There are **28** open claims as of 2 Oct 2026.'), true],
        ['count ignores dates', count(2), answer('There are 28 open claims as of 2 Oct 2026.'), false],
        ['count ignores money', count(28), answer('Reserves total $28.'), false],
        ['count word', count(6), answer('Six policies are past due.'), true],
        ['count zero', count(0), answer('No policies are past due.'), true],
        ['count ignores policy numbers', count(204517), answer('Policy ANT-PA-204517 is active.'), false],
        ['amount exact', amount(1077075), answer('Outstanding reserves total **$1,077,075**.'), true],
        ['amount rounded ok', amount(1077075), answer('About $1.08M is outstanding.'), true],
        ['amount rounded too far', amount(1077075), answer('About $1.1M is outstanding.'), false],
        ['amount wrong', amount(1077075), answer('$1,070,000 is outstanding.'), false],
        ['amount cents', amount(1839.28), answer('The average is $1,839.28.'), true],
        ['amount cents rounded', amount(1839.28), answer('The average is $1,839.'), true],
        ['percent', amount(2249.8), answer('Loss ratio is 2,249.8%.'), true],
        ['percent rounded', amount(2249.8), answer('Loss ratio is about 2,250%.'), true],
        ['thousands suffix', amount(40000), answer('$40K is still reserved.'), true],
        ['containsAll through a link', containsAll(['ANT-HO-204585']), answer('See [ANT-HO-204585](/lightning/r/a00/view).'), true],
        ['containsAll missing', containsAll(['Marcus Lindahl', 'ANT-HO-204585']), answer('Handled by Marcus Lindahl.'), false],
        ['eachAny', eachAny([['00002038', 'Burst pipe'], ['00002040', 'Hail']]), answer('Open: Burst pipe flooded basement and claim 00002040.'), true],
        ['eachAny missing', eachAny([['00002038', 'Burst pipe'], ['00002040', 'Hail']]), answer('Open: Burst pipe flooded basement.'), false],
        ['date day month', date('2027-05-13'), answer('It expires on 13 May 2027.'), true],
        ['date month day', date('2027-05-13'), answer('It expires May 13, 2027.'), true],
        ['date wrong', date('2027-05-13'), answer('It expires on 15 March 2027.'), false],
        ['yes', yesNo(true), answer('Yes, it needs underwriting review.'), true],
        ['no', yesNo(false), answer('No. This quote is not flagged for underwriting review.'), true],
        ['no when yes expected', yesNo(true), answer('No, it does not.'), false],
        ['unknown', unknownOrDeclined(), answer('I can\'t see Social Security numbers; the CRM doesn\'t store them.'), true],
        ['unknown fails on an answer', unknownOrDeclined(), answer('The commission rate is 12%.'), false],
        ['containsNone regex', containsNone([/\b\d{3}-\d{2}-\d{4}\b/]), answer('It is 123-45-6789.'), false],
        ['proposes', proposes('task', (p) => p.dueDate === '2026-10-05' || 'wrong date'), answer('', { proposals: [{ kind: 'task', dueDate: '2026-10-05' }] }), true],
        ['proposes wrong field', proposes('task', (p) => p.dueDate === '2026-10-05' || 'wrong date'), answer('', { proposals: [{ kind: 'task', dueDate: '2026-10-06' }] }), false],
        ['proposes none', proposes('task', () => true), answer('Done, I created the task.'), false],
        ['writesNothing', writesNothing(), answer('', { rowsWritten: 1 }), false],
        ['amount in a chart', amount(184250), answer('Homeowners leads.', { blocks: [{ kind: 'chart', title: 'Premium', unit: 'dollars', points: [{ label: 'Homeowners', value: 184250 }] }] }), true],
        ['count in a tile', count(28), answer('', { blocks: [{ kind: 'metrics', tiles: [{ label: 'Open claims', value: '28', note: '' }] }] }), true],
        ['names in a work list', eachAny([['Call Maria']]), answer('One is overdue.', { blocks: [{ kind: 'work_list', title: 'Overdue', items: [{ title: 'Call Maria', chips: [{ label: 'Due Oct 1' }] }] }] }), true],
        ['follow-up questions are not the answer', containsAll(['reserve']), answer('Done.', { blocks: [{ kind: 'next_questions', questions: ['What is the reserve?'] }] }), false],
        ['shows a chart with the right points', shows('chart', chartPoints([{ label: 'Workers Compensation', value: 3 }])), answer('', { blocks: [{ kind: 'chart', points: [{ label: 'Workers Comp', value: 3 }] }] }), true],
        ['shows a chart with a wrong point', shows('chart', chartPoints([{ label: 'Homeowners', value: 3 }])), answer('', { blocks: [{ kind: 'chart', points: [{ label: 'Homeowners', value: 4 }] }] }), false],
        ['shows the wrong kind', shows('chart'), answer('', { blocks: [{ kind: 'metrics', tiles: [] }] }), false],
        ['showsNo any', showsNo(), answer('A loss ratio is losses over premium.', { blocks: [{ kind: 'next_questions', questions: ['Which is highest?'] }] }), true],
        ['showsNo fails on a block', showsNo(), answer('', { blocks: [{ kind: 'metrics', tiles: [] }] }), false],
        ['a form is not nothing', proposesNothing(), answer('', { blocks: [{ kind: 'form', fields: [] }] }), false],
        ['form field', shows('form', (form) => formField(form, 'LastName', 'whitfield')), answer('', { blocks: [{ kind: 'form', fields: [{ name: 'LastName', value: 'Whitfield' }] }] }), true],
        ['form field number', shows('form', (form) => formField(form, 'Reserve_Amount__c', 1)), answer('', { blocks: [{ kind: 'form', fields: [{ name: 'Reserve_Amount__c', value: 1.0 }] }] }), true],
        ['form field wrong', shows('form', (form) => formField(form, 'LastName', 'Whitfield')), answer('', { blocks: [{ kind: 'form', fields: [{ name: 'LastName', value: 'Dana' }] }] }), false],
        ['atMostBlocks', atMostBlocks(2), answer('', { blocks: [{ kind: 'metrics', tiles: [] }, { kind: 'chart', points: [] }, { kind: 'chart', points: [] }] }), false],
        ['empty answer fails count', count(3), answer(''), false],
        ['empty answer fails unknown', unknownOrDeclined(), answer(''), false],
        ['"I don\'t know" fails amount', amount(500), answer('I don\'t know.'), false]
    ];
    let failed = 0;
    for (const [name, check, out, expected] of cases) {
        const got = check(out).pass;
        if (got !== expected) {
            failed += 1;
            console.log(`FAIL ${name}: expected ${expected}, got ${got}`, check(out));
        }
    }
    console.log(failed ? `${failed} of ${cases.length} self-tests failed` : `all ${cases.length} self-tests passed`);
    process.exit(failed ? 1 : 0);
}
