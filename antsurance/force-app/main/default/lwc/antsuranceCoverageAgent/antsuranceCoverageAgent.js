import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';
import getStanding from '@salesforce/apex/AntsuranceCoverageAgent.getStanding';
import start from '@salesforce/apex/AntsuranceCoverageAgent.start';
import poll from '@salesforce/apex/AntsuranceCoverageAgent.poll';
import readDocument from '@salesforce/apex/AntsuranceCoverageAgent.readDocument';
import stop from '@salesforce/apex/AntsuranceCoverageAgent.stop';
import { keepTogether, tidyEnding } from 'c/antsuranceText';
import { pageOf, recall, remember } from 'c/antsuranceUiMemory';

// A timer, not animation frames: a tab in the background draws no frames, and the agent must still be answered.
const POLL_MS = 1500;
const STEPS_SHOWN = 5;
// Three polls in a row that fail are a real problem; one is a blip.
const MAX_FAILED_POLLS = 3;
const MAX_MINUTES = 8;
const FALLBACK_ERROR = 'The coverage agent could not be reached. Try again in a moment.';
const TOO_LONG = 'The coverage agent is taking longer than expected, so this page has stopped waiting. Try again.';

/**
 * The claims coverage agent, as a strip at the foot of the coverage check card.
 *
 * At rest it is one row: what the agent does and a button, or, when the check on the claim is the
 * agent's, when it ran and how many steps it took, with the steps one click away. While it runs,
 * each step appears in plain words as it happens, with what it found.
 *
 * The agent's loop runs on Claude Managed Agents. This component only keeps it moving: it asks
 * Salesforce every second or two where the run stands (each ask is one short Apex request that
 * also runs any tool the agent is waiting on), and runs a document reading as a request of its
 * own because that one is slow. When the finding is stored it fires `finished` so the card reloads.
 *
 * Events: `finished` when a finding has been stored; `standing` with `detail.byAgent` whenever it
 * learns whether the check on the claim is the agent's; `working` with `detail.busy`.
 */
export default class AntsuranceCoverageAgent extends LightningElement {
    @api recordId;
    /** Set by the card while its own check is running, so two reads are not started at once. */
    @api disabled = false;
    /** Set by the card: whether a coverage check is stored on the claim, so a stopped run can say what still stands. */
    @api checkOnRecord = false;

    ready = false;
    lastRun;
    run;
    sessionId;
    isRunning = false;
    problem;
    page;
    startedAt;
    failedPolls = 0;
    // Counts runs so that a stopped or replaced run cannot write over the one on screen.
    watch = 0;
    // The run Stop was pressed on. Stop can come before the session's id is known; it is applied as soon as it is.
    stoppedRun;
    // A session the page lost touch with while it was still going. The next press picks it up instead of paying for a new one.
    resumeId;
    // Stop was pressed on this visit and no run has started since: the strip says so until the next run.
    stopped = false;

    connectedCallback() {
        this.load();
        // Coming back to the page while a run is still going picks it up where it was.
        const remembered = recall(this.memoryKey);
        if (remembered) {
            this.follow(remembered);
        }
    }

    disconnectedCallback() {
        this.watch++;
        this.isRunning = false;
    }

    /** Reads again whether the check on the claim is the agent's. For the card, after it runs its own check. */
    @api
    refresh() {
        return this.load();
    }

    async load() {
        try {
            const standing = await getStanding({ caseId: this.recordId });
            this.ready = standing.ready;
            this.lastRun = standing.lastRun;
        } catch (error) {
            // The card works without the agent; say nothing and offer nothing.
            this.ready = false;
        }
        this.dispatchEvent(new CustomEvent('standing', { detail: { byAgent: Boolean(this.lastRun) } }));
    }

    // ------------------------------------------------------------ state

    get memoryKey() {
        return `${this.recordId}:coverage-agent-session`;
    }

    get isOffered() {
        return this.ready || this.isRunning;
    }

    get busy() {
        return this.isRunning ? 'true' : 'false';
    }

    /** The run on screen: the live one while it runs, otherwise the one kept beside the stored check. */
    get shown() {
        return this.isRunning ? this.run : this.lastRun;
    }

    get steps() {
        return (this.shown?.steps ?? []).map((step, index) => ({
            key: step.key ?? `step-${index}`,
            label: keepTogether(step.label),
            detail: keepTogether(step.detail ?? (step.state === 'working' ? 'In progress' : '')),
            rowClass: `c-agent__step c-agent__step_${step.state}`
        }));
    }

    get hasSteps() {
        return this.steps.length > 0;
    }

    get stepsShown() {
        return STEPS_SHOWN;
    }

    get lastPage() {
        return Math.max(0, Math.ceil(this.steps.length / STEPS_SHOWN) - 1);
    }

    /** While it runs, the newest steps are in view unless the person has paged back; afterwards, the first. */
    get currentPage() {
        if (this.page !== undefined) {
            return Math.min(this.page, this.lastPage);
        }
        return this.isRunning ? this.lastPage : 0;
    }

    get shownSteps() {
        return pageOf(this.steps, this.currentPage, STEPS_SHOWN);
    }

    /** Keeps the steps numbered through the pages. */
    get stepsStyle() {
        return `counter-reset: step ${this.currentPage * STEPS_SHOWN}`;
    }

    get showHow() {
        return !this.isRunning && Boolean(this.lastRun) && this.hasSteps;
    }

    get closing() {
        return keepTogether(this.lastRun?.closing ?? this.lastRun?.saying);
    }

    get howSummary() {
        return 'Each step it took and what it found';
    }

    get lead() {
        return 'Coverage agent';
    }

    get line() {
        if (this.isRunning) {
            const steps = this.run?.steps ?? [];
            const current = steps.length ? steps[steps.length - 1] : undefined;
            if (!current) {
                return 'Opening the file';
            }
            return current.state === 'working' ? `Working: ${this.lowerFirst(current.label)}` : 'Deciding what to read next';
        }
        if (this.stopped) {
            // A stopped run stores nothing, so what was on the claim before it is what is there now.
            return this.checkOnRecord ? 'Stopped. The earlier check stands.' : 'Stopped. Nothing was recorded.';
        }
        if (this.lastRun) {
            const count = this.lastRun.steps?.length ?? 0;
            const when = this.lastRun.finishedAt ? ` on ${this.when(this.lastRun.finishedAt)}` : '';
            const took = this.lastRun.seconds ? ` in ${this.duration(this.lastRun.seconds)}` : '';
            return keepTogether(`Investigated this claim${when}: ${count} ${count === 1 ? 'step' : 'steps'}${took}.`);
        }
        return tidyEnding('Works the file step by step: the notes, the documents, the photos and earlier claims. About a minute.');
    }

    get startLabel() {
        if (this.resumeId) {
            return 'Try again';
        }
        return this.lastRun ? 'Investigate again' : 'Investigate with the coverage agent';
    }

    // ------------------------------------------------------------ actions

    async handleStart() {
        this.stopped = false;
        this.problem = undefined;
        this.page = undefined;
        this.run = { steps: [] };
        this.sessionId = undefined;
        const resumed = this.resumeId;
        this.resumeId = undefined;
        if (resumed) {
            // The investigation the page lost touch with is still there, with whatever it had found.
            remember(this.memoryKey, resumed);
            this.follow(resumed, undefined, true);
            return;
        }
        this.setRunning(true);
        const watch = ++this.watch;
        try {
            const run = await start({ caseId: this.recordId });
            if (watch !== this.watch) {
                if (this.stoppedRun === watch) {
                    // Stop was pressed while the session was being opened. It exists now, so it is stopped now.
                    this.interrupt(run.sessionId);
                } else {
                    // The page was left while the session was being opened: coming back picks it up.
                    remember(this.memoryKey, run.sessionId);
                }
                return;
            }
            remember(this.memoryKey, run.sessionId);
            this.follow(run.sessionId, watch);
        } catch (error) {
            if (watch === this.watch) {
                this.fail(error?.body?.message ?? FALLBACK_ERROR);
            }
        }
    }

    handleStop() {
        this.stopped = true;
        const sessionId = this.sessionId;
        this.stoppedRun = this.watch;
        this.watch++;
        this.setRunning(false);
        remember(this.memoryKey, null);
        this.run = undefined;
        this.sessionId = undefined;
        if (sessionId) {
            this.interrupt(sessionId);
        }
        // With no session id yet, start is still on its way: handleStart stops the session when it arrives.
    }

    /** Tells the session to stop. Tried twice: a session only just opened may not answer the first time. */
    async interrupt(sessionId) {
        for (let attempt = 0; attempt < 2; attempt++) {
            try {
                // eslint-disable-next-line no-await-in-loop
                await stop({ caseId: this.recordId, sessionId });
                return;
            } catch (error) {
                // eslint-disable-next-line no-await-in-loop
                await this.pause(POLL_MS);
            }
        }
        // The page has stopped waiting either way.
    }

    handlePage(event) {
        this.page = event.detail.page;
    }

    // ------------------------------------------------------------ the run

    /** Keeps one session moving until it finishes, fails or is replaced. */
    async follow(sessionId, existingWatch, isResumed) {
        const watch = existingWatch ?? ++this.watch;
        this.sessionId = sessionId;
        this.startedAt = Date.now();
        this.failedPolls = 0;
        this.run = this.run ?? { steps: [] };
        this.setRunning(true);
        while (watch === this.watch) {
            // eslint-disable-next-line no-await-in-loop
            await this.pause(POLL_MS);
            if (watch !== this.watch) {
                return;
            }
            if (Date.now() - this.startedAt > MAX_MINUTES * 60000) {
                this.fail(TOO_LONG);
                return;
            }
            let run;
            try {
                // eslint-disable-next-line no-await-in-loop
                run = await poll({ caseId: this.recordId, sessionId });
                this.failedPolls = 0;
            } catch (error) {
                if (watch !== this.watch) {
                    // Stopped or replaced while this poll was out: its failure is nobody's news.
                    return;
                }
                this.failedPolls++;
                if (this.failedPolls >= MAX_FAILED_POLLS) {
                    this.fail(error?.body?.message ?? FALLBACK_ERROR);
                    // The session has not ended, only this page's hold on it (a finding that would not save, a
                    // dropped connection). One more press picks it up where it is; if that fails too, the next starts afresh.
                    this.resumeId = isResumed ? undefined : sessionId;
                    return;
                }
                continue;
            }
            if (watch !== this.watch) {
                return;
            }
            this.run = run;
            if (run.status === 'failed') {
                this.fail(run.problem ?? FALLBACK_ERROR);
                return;
            }
            if (run.status === 'done') {
                this.finish(run);
                return;
            }
            for (const reading of run.toRead ?? []) {
                try {
                    // A document is read in a request of its own: it is slow, and one at a time keeps each inside its time limit.
                    // eslint-disable-next-line no-await-in-loop
                    await readDocument({ caseId: this.recordId, sessionId, toolUseId: reading.toolUseId });
                } catch (error) {
                    if (watch === this.watch) {
                        this.fail(error?.body?.message ?? FALLBACK_ERROR);
                    }
                    return;
                }
                if (watch !== this.watch) {
                    return;
                }
            }
        }
    }

    finish(run) {
        remember(this.memoryKey, null);
        this.lastRun = { ...run, finishedAt: run.finishedAt ?? new Date().toISOString() };
        this.page = undefined;
        this.setRunning(false);
        this.dispatchEvent(new CustomEvent('standing', { detail: { byAgent: true } }));
        this.dispatchEvent(new CustomEvent('finished'));
    }

    fail(message) {
        this.watch++;
        remember(this.memoryKey, null);
        this.problem = message;
        this.setRunning(false);
        // A finding stored before the run stopped is still on the claim; show the card what is there.
        if (this.run?.recorded) {
            this.dispatchEvent(new CustomEvent('finished'));
        }
        this.load();
    }

    setRunning(value) {
        if (this.isRunning !== value) {
            this.isRunning = value;
            this.dispatchEvent(new CustomEvent('working', { detail: { busy: value } }));
        }
    }

    // ------------------------------------------------------------ helpers

    pause(milliseconds) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((resolve) => setTimeout(resolve, milliseconds));
    }

    lowerFirst(text) {
        return text ? text.charAt(0).toLowerCase() + text.slice(1) : '';
    }

    duration(seconds) {
        if (seconds < 90) {
            return `${seconds} seconds`;
        }
        const minutes = Math.round(seconds / 60);
        return `${minutes} minutes`;
    }

    when(value) {
        const date = new Date(value);
        const day = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' }).format(date);
        const time = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(date);
        return `${day} at ${time}`;
    }
}
