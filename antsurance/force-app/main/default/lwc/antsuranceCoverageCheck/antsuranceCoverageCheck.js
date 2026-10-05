import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import getCheck from '@salesforce/apex/AntsuranceClaimsAssistantCoverage.getCheck';
import writeCheck from '@salesforce/apex/AntsuranceClaimsAssistantCoverage.writeCheck';
import confirmCheck from '@salesforce/apex/AntsuranceClaimsAssistantCoverage.confirm';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether, tidyEnding } from 'c/antsuranceText';
import { pageOf, recall, remember } from 'c/antsuranceUiMemory';

// Any save to the claim changes this field, which is the cue to ask whether the check is still current.
const CHANGE_SIGNAL = ['Case.LastModifiedDate'];
const CHECKING_CAPTIONS = [
    'Reading the loss against the policy term',
    'Matching it to the coverages on the policy',
    'Going through the endorsements and exclusions',
    'Checking who and what is on the policy'
];
const CAPTION_INTERVAL_MS = 1600;
const FALLBACK_ERROR = 'The coverage check could not be loaded. Refresh the page and try again.';
const COVERED = 'Covered';
const NOT_COVERED = 'Not covered';
// How many rows of the reasoning are in view at once. The rest are a step away.
const FINDINGS_SHOWN = 4;
const POINTS_SHOWN = 3;

/**
 * The coverage check on a claim page. Closed, it is one band: the verdict, the coverage that
 * responds, the limit and deductible, and what that leaves payable on the estimate. Opened, it
 * shows Claude's reasoning in tabs, a few rows at a time, so it stays about one screen tall: the
 * findings, each linked to the record it rests on; what is still to ask; what would change the
 * answer; and what else was taken into account. Claude advises; the adjuster confirms.
 *
 * The same check can be reached a second way: the coverage agent (c-antsurance-coverage-agent, the
 * strip at the foot of the card) works the file step by step on Claude Managed Agents and stores
 * its finding in the same shape, so everything above reads it without knowing which wrote it.
 *
 * Another component can embed just the band: <c-antsurance-coverage-check record-id={claimId} band-only>.
 * With band-only it shows the verdict, the responding coverage and what is payable, and nothing to
 * press; call refresh() on it after running a check elsewhere.
 */
export default class AntsuranceCoverageCheck extends NavigationMixin(LightningElement) {
    @api recordId;
    /** Show only the band (verdict, responding coverage, payable), with no reasoning and nothing to press. */
    @api bandOnly = false;

    check;
    errorMessage;
    isChecking = false;
    isConfirming = false;
    isOpen = false;
    // Which part of the reasoning is in view, and which page of it.
    view;
    pages = {};
    captionIndex = 0;
    captionTimer;
    // Counts loads so that a slow, older response cannot overwrite a newer one.
    loadSequence = 0;
    // Whether the check on the claim was reached by the coverage agent, and whether the agent is at work now.
    byAgent = false;
    agentBusy = false;

    connectedCallback() {
        loadBrandFonts(this);
        this.isOpen = recall(`${this.recordId}:coverage-open`, false) === true;
        this.view = recall(`${this.recordId}:coverage-view`);
    }

    disconnectedCallback() {
        this.stopCaptions();
    }

    @wire(getRecord, { recordId: '$recordId', fields: CHANGE_SIGNAL })
    wiredClaim({ data }) {
        if (data && !this.isChecking) {
            this.load();
        }
    }

    /** Reads the stored check again. For a component that embeds this one and has just run a check itself. */
    @api
    refresh() {
        return this.load();
    }

    async load() {
        const sequence = ++this.loadSequence;
        try {
            const check = await getCheck({ caseId: this.recordId });
            if (sequence === this.loadSequence) {
                this.check = check;
                this.errorMessage = undefined;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
            }
        }
    }

    // ------------------------------------------------------------ state

    get hasCheck() {
        return Boolean(this.check?.exists) && !this.isChecking;
    }

    /** Whether a check is stored on the claim, for the agent strip to say what a stopped run leaves behind. */
    get checkOnRecord() {
        return Boolean(this.check?.exists);
    }

    get isEmpty() {
        return Boolean(this.check) && !this.check.exists && !this.isChecking;
    }

    get canAct() {
        return !this.bandOnly;
    }

    /** A failed check stays on screen with its reason and a way to try again; any stored check stays above it. */
    get canRetry() {
        return !this.bandOnly && !this.isChecking;
    }

    get showStart() {
        return this.isEmpty && !this.bandOnly;
    }

    get showToggle() {
        return this.hasCheck && !this.bandOnly;
    }

    get isBusy() {
        return this.isChecking || (!this.check && !this.errorMessage) ? 'true' : 'false';
    }

    get cardClass() {
        return `c-cov c-cov_${this.tone}`;
    }

    /** covered, review or none: drives the top edge and the chip, never a warning colour. */
    get tone() {
        if (!this.hasCheck) {
            return 'idle';
        }
        if (this.check.verdict === COVERED) {
            return 'covered';
        }
        return this.check.verdict === NOT_COVERED ? 'none' : 'review';
    }

    get chipClass() {
        return `c-cov__chip c-cov__chip_${this.tone}`;
    }

    get checkingCaption() {
        return CHECKING_CAPTIONS[this.captionIndex];
    }

    // ------------------------------------------------------------ the band

    get respondsText() {
        if (this.check.respondingLabel) {
            return this.check.respondingLabel;
        }
        return this.check.verdict === NOT_COVERED ? 'Nothing on the policy' : 'Not settled yet';
    }

    get respondsNote() {
        if (this.check.respondingLabel) {
            // The name is a link to the record, which says what it is. Only an endorsement is worth pointing out.
            return this.check.respondingKind === 'Endorsement' ? 'An endorsement on the policy' : undefined;
        }
        return this.check.verdict === NOT_COVERED ? 'No coverage pays for this loss' : 'See the reasoning';
    }

    get hasResponding() {
        return Boolean(this.check.respondingId);
    }

    get limitText() {
        if (!this.check.respondingLabel) {
            return 'None applies';
        }
        if (this.check.limitAmount === null || this.check.limitAmount === undefined) {
            return this.check.limitBasis ? this.check.limitBasis : 'No stated limit';
        }
        return `${this.money(this.check.limitAmount)} limit`;
    }

    get deductibleNote() {
        if (!this.check.respondingLabel) {
            return 'No limit or deductible to apply';
        }
        const basis = this.check.limitAmount !== null && this.check.limitAmount !== undefined && this.check.limitBasis ? `${this.check.limitBasis}, ` : '';
        const deductible = this.check.deductible ? `${this.money(this.check.deductible)} deductible` : 'no deductible';
        const line = `${basis}${deductible}`;
        return line.charAt(0).toUpperCase() + line.slice(1);
    }

    get payableLabel() {
        if (this.check.verdict === NOT_COVERED) {
            return 'Payable';
        }
        if (this.check.liabilityOpen) {
            return 'Payable if the insured is liable';
        }
        return this.check.verdict === COVERED ? 'Payable on the estimate' : 'Payable if covered';
    }

    get payableText() {
        if (this.check.payable === null || this.check.payable === undefined) {
            return this.check.respondingLabel ? 'No estimate yet' : 'Not known yet';
        }
        return this.money(this.check.payable);
    }

    get payableNote() {
        if (this.check.verdict === NOT_COVERED) {
            return 'The policy does not respond';
        }
        if (this.check.payable === null || this.check.payable === undefined) {
            return this.check.respondingLabel ? 'Add an estimate to the claim' : 'Depends on which coverage responds';
        }
        if (this.check.liabilityOpen) {
            return keepTogether(`Liability is not established. Estimate ${this.money(this.check.estimate)}`);
        }
        if (this.check.cappedByLimit) {
            return keepTogether(`Capped by the limit, on a ${this.money(this.check.estimate)} estimate`);
        }
        return keepTogether(`Of a ${this.money(this.check.estimate)} estimate, after the deductible`);
    }

    get toggleLabel() {
        return this.isOpen ? 'Hide the reasoning' : 'Show the reasoning';
    }

    get toggleIcon() {
        return this.isOpen ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get expanded() {
        return this.isOpen ? 'true' : 'false';
    }

    get showReasoning() {
        return this.hasCheck && this.isOpen && !this.bandOnly;
    }

    get emptyText() {
        return this.bandOnly
            ? 'Coverage has not been checked on this claim yet.'
            : "Claude reads the loss against the policy's term, its coverages, endorsements and exclusions, and who and what is on it, then shows what each finding rests on.";
    }

    get extraFacts() {
        return tidyEnding(this.check.extraFacts);
    }

    get hasExtraFacts() {
        return Boolean(this.check.extraFacts);
    }

    // ------------------------------------------------------------ the reasoning

    get summary() {
        return tidyEnding(this.check.summary);
    }

    get findings() {
        return (this.check.findings ?? []).map((finding, index) => ({
            key: `finding-${index}`,
            text: tidyEnding(finding.text),
            recordId: finding.recordId,
            hasSource: Boolean(finding.sourceLabel),
            isLinked: Boolean(finding.recordId),
            // "Evidence" over "Evidence supplied" says the same thing twice.
            sourceKind: (finding.sourceLabel ?? '').toLowerCase().startsWith((finding.sourceKind ?? '').toLowerCase()) ? undefined : finding.sourceKind,
            sourceLabel: keepTogether(finding.sourceLabel),
            sourceTitle: `Open ${finding.sourceLabel}`
        }));
    }

    get questions() {
        return (this.check.questions ?? []).map((text, index) => ({ key: `question-${index}`, text: tidyEnding(text) }));
    }

    get wouldChange() {
        return (this.check.wouldChange ?? []).map((text, index) => ({ key: `change-${index}`, text: tidyEnding(text) }));
    }

    get hasQuestions() {
        return this.questions.length > 0;
    }

    get hasWouldChange() {
        return this.wouldChange.length > 0;
    }

    /** What else Claude took into account, one point a row: the lead-in on its own line, what it says beneath. */
    get extraPoints() {
        return (this.check.extraFacts ?? '')
            .split(/\n+/)
            .map((line) => line.trim())
            .filter(Boolean)
            .map((line, index) => {
                const colon = line.indexOf(': ');
                const hasLead = colon > 1 && colon <= 70;
                return { key: `extra-${index}`, lead: hasLead ? line.slice(0, colon) : undefined, text: tidyEnding(hasLead ? line.slice(colon + 2) : line) };
            });
    }

    /** The parts of the reasoning that have anything in them, as tabs. */
    get reasonTabs() {
        const tabs = [{ value: 'record', label: 'The record', count: this.findings.length, title: 'What the record shows' }];
        if (this.hasQuestions) {
            tabs.push({ value: 'ask', label: 'To ask', count: this.questions.length, title: 'Still to ask the insured' });
        }
        if (this.hasWouldChange) {
            tabs.push({ value: 'change', label: 'What would change this', count: this.wouldChange.length });
        }
        if (this.extraPoints.length) {
            tabs.push({ value: 'also', label: 'Also taken into account', count: this.extraPoints.length });
        }
        return tabs;
    }

    get currentView() {
        return this.reasonTabs.some((tab) => tab.value === this.view) ? this.view : 'record';
    }

    get showsRecord() {
        return this.currentView === 'record';
    }

    get showsAsk() {
        return this.currentView === 'ask';
    }

    get showsChange() {
        return this.currentView === 'change';
    }

    get showsAlso() {
        return this.currentView === 'also';
    }

    get findingsShown() {
        return FINDINGS_SHOWN;
    }

    get pointsShown() {
        return POINTS_SHOWN;
    }

    get findingsPage() {
        return this.pages.record ?? 0;
    }

    get alsoPage() {
        return this.pages.also ?? 0;
    }

    get shownFindings() {
        return pageOf(this.findings, this.findingsPage, FINDINGS_SHOWN);
    }

    get shownExtraPoints() {
        return pageOf(this.extraPoints, this.alsoPage, POINTS_SHOWN);
    }

    /** Keeps the findings numbered through the pages: the second page starts at 5. */
    get findingsStyle() {
        const last = Math.max(0, Math.ceil(this.findings.length / FINDINGS_SHOWN) - 1);
        return `counter-reset: finding ${Math.min(this.findingsPage, last) * FINDINGS_SHOWN}`;
    }

    handleView(event) {
        this.view = event.detail.value;
        remember(`${this.recordId}:coverage-view`, this.view);
    }

    handlePage(event) {
        this.pages = { ...this.pages, [event.currentTarget.dataset.list]: event.detail.page };
    }

    get isStale() {
        return this.hasCheck && this.check.stale;
    }

    get staleText() {
        const changes = this.check?.changes ?? [];
        return changes.length ? `${changes.join(', ')} since this was checked.` : 'The claim has changed since this was checked.';
    }

    get writtenLine() {
        const by = this.byAgent ? 'Investigated by the coverage agent' : 'Checked by Claude';
        return this.check.writtenAt ? `${by} on ${this.when(this.check.writtenAt)}` : by;
    }

    get isConfirmed() {
        return Boolean(this.check?.confirmedAt);
    }

    get confirmedLine() {
        return `Confirmed by ${this.check.confirmedBy} on ${this.when(this.check.confirmedAt)}`;
    }

    /** Not while the agent works: its finding is about to replace what is on screen, and nobody has read that yet. */
    get cannotConfirm() {
        return this.isConfirming || this.check.stale || this.agentBusy;
    }

    get metaLine() {
        if (this.isChecking) {
            return 'Claude is reading the policy';
        }
        if (this.agentBusy) {
            return 'The coverage agent is working the file';
        }
        if (!this.hasCheck) {
            return 'Does the policy respond to this loss?';
        }
        if (this.isConfirmed) {
            return keepTogether(this.confirmedLine);
        }
        return this.byAgent ? 'The coverage agent’s finding, for you to confirm' : 'Claude’s read, for you to confirm';
    }

    // ------------------------------------------------------------ actions

    async handleCheck() {
        if (this.agentBusy) {
            // The agent is about to store its own finding; a second read now would only be written over.
            return;
        }
        this.isChecking = true;
        this.errorMessage = undefined;
        this.startCaptions();
        // A load already on its way must not overwrite what this returns.
        const sequence = ++this.loadSequence;
        try {
            const check = await writeCheck({ caseId: this.recordId });
            if (sequence === this.loadSequence) {
                this.check = check;
                this.isOpen = true;
            }
            // This check replaced whatever the coverage agent had stored, so its strip goes back to its offer.
            this.template.querySelector('c-antsurance-coverage-agent')?.refresh();
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'Claude could not check coverage. Try again.';
        } finally {
            this.isChecking = false;
            this.stopCaptions();
        }
    }

    async handleConfirm() {
        if (this.agentBusy) {
            return;
        }
        this.isConfirming = true;
        this.errorMessage = undefined;
        const sequence = ++this.loadSequence;
        try {
            const check = await confirmCheck({ caseId: this.recordId });
            if (sequence === this.loadSequence) {
                this.check = check;
            }
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The confirmation could not be saved. Try again.';
        } finally {
            this.isConfirming = false;
        }
    }

    /** The coverage agent has stored its finding: show it, opened, as any other check. */
    handleAgentFinished() {
        this.errorMessage = undefined;
        this.isOpen = true;
        remember(`${this.recordId}:coverage-open`, true);
        return this.load();
    }

    handleAgentStanding(event) {
        this.byAgent = event.detail.byAgent === true;
    }

    handleAgentWorking(event) {
        const wasBusy = this.agentBusy;
        this.agentBusy = event.detail.busy === true;
        if (wasBusy && !this.agentBusy) {
            // However the run ended (finished, stopped or failed), show what is on the claim now before Confirm comes back.
            this.load();
        }
    }

    handleToggle() {
        this.isOpen = !this.isOpen;
        remember(`${this.recordId}:coverage-open`, this.isOpen);
    }

    handleOpenRecord(event) {
        const recordId = event.currentTarget.dataset.recordId;
        if (recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
        }
    }

    // ------------------------------------------------------------ helpers

    startCaptions() {
        this.captionIndex = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex = (this.captionIndex + 1) % CHECKING_CAPTIONS.length;
        }, CAPTION_INTERVAL_MS);
    }

    stopCaptions() {
        clearInterval(this.captionTimer);
        this.captionTimer = undefined;
    }

    money(value) {
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(value);
    }

    when(value) {
        const date = new Date(value);
        const day = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' }).format(date);
        const time = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(date);
        return keepTogether(`${day} at ${time}`);
    }
}
