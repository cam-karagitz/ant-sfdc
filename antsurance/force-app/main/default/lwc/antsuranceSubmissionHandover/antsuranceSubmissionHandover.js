/**
 * Carries what "Read a submission" found from one page to the next, in this browser tab only.
 *
 * Two things travel. Answers a person has confirmed go to the quote configurator for one new quote:
 * they are taken once and then gone. A run (what each document said, and the person's corrections)
 * is kept for a couple of hours, so coming back to the sale, or to the sale a lead became, does not
 * mean reading the documents again.
 *
 * Nothing here reaches the server, and nothing outlives the tab.
 */
const ANSWERS = 'antsurance.submission.answers.';
const RUN = 'antsurance.submission.run.';
const ANSWERS_FRESH_MS = 15 * 60 * 1000;
const RUN_FRESH_MS = 2 * 60 * 60 * 1000;

function store() {
    try {
        return window.sessionStorage;
    } catch (error) {
        // Storage is switched off in this browser: the page works without the handover.
        return undefined;
    }
}

function read(key, freshMs) {
    try {
        const raw = store()?.getItem(key);
        if (!raw) {
            return undefined;
        }
        const kept = JSON.parse(raw);
        return Date.now() - kept.at <= freshMs ? kept : undefined;
    } catch (error) {
        return undefined;
    }
}

function write(key, value) {
    try {
        store().setItem(key, JSON.stringify({ ...value, at: Date.now() }));
        return true;
    } catch (error) {
        return false;
    }
}

/**
 * @param {string} quoteId The new quote the answers are for
 * @param {object} answers Answers keyed by question, as the configurator keeps them
 * @param {string} from Where they came from, in words, for the line the configurator shows
 * @returns {boolean} False when the browser would not keep them
 */
export function leaveAnswers(quoteId, answers, from) {
    return write(ANSWERS + quoteId, { answers, from });
}

/**
 * @param {string} quoteId The quote being opened
 * @returns {{answers: object, from: string}|undefined} The answers left for it, once
 */
export function takeAnswers(quoteId) {
    const kept = read(ANSWERS + quoteId, ANSWERS_FRESH_MS);
    try {
        store()?.removeItem(ANSWERS + quoteId);
    } catch (error) {
        // Nothing to clear.
    }
    return kept && kept.answers && typeof kept.answers === 'object' ? kept : undefined;
}

/** The key a run is kept under: the customer and the line, so a lead's reading is found again on its sale. */
export function runKey(customerName, lineOfBusiness) {
    return `${(customerName ?? '').trim().toLowerCase()}|${(lineOfBusiness ?? '').trim().toLowerCase()}`;
}

export function keepRun(key, run) {
    return write(RUN + key, { run });
}

export function recallRun(key) {
    return read(RUN + key, RUN_FRESH_MS)?.run;
}

export function forgetRun(key) {
    try {
        store()?.removeItem(RUN + key);
    } catch (error) {
        // Nothing to clear.
    }
}
