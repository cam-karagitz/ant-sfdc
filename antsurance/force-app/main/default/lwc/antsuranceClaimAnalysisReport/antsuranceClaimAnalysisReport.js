import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import PRINT_STYLES from '@salesforce/resourceUrl/antsuranceClaimAnalysisPrint';
import addTasks from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.addTasks';
import setReserve from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.setReserve';
import addToNotes from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.addToNotes';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { clauses, keepTogether, tidyEnding } from 'c/antsuranceText';
import { recall, remember } from 'c/antsuranceUiMemory';

const VERDICTS = {
    Covered: 'c-chip c-chip_good',
    'Needs review': 'c-chip c-chip_watch',
    'Not covered': 'c-chip c-chip_ended'
};
const CONSISTENCY = {
    consistent: { label: 'Fits the reported loss', className: 'c-chip c-chip_good' },
    check: { label: 'Something to check', className: 'c-chip c-chip_watch' },
    unclear: { label: 'Cannot tell from the photos', className: 'c-chip c-chip_quiet' }
};
const SEVERITIES = {
    minor: { label: 'Minor', className: 'c-chip c-chip_minor' },
    moderate: { label: 'Moderate', className: 'c-chip c-chip_moderate' },
    severe: { label: 'Severe', className: 'c-chip c-chip_severe' }
};
const FALLBACK_ERROR = 'That could not be saved. Try again.';
const HEADLINE_CHECK_MS = 1500;
// Three at a time: with the masthead above them, four ran past the bottom of a laptop window.
const EVIDENCE_PAGE_SIZE = 3;
const STEPS_PAGE_SIZE = 3;
const SECTIONS = ['summary', 'evidence', 'damage', 'coverage', 'flags', 'reserve', 'steps'];

function money(value) {
    if (value === null || value === undefined) {
        return '';
    }
    const rounded = Math.round(Number(value));
    return `${rounded < 0 ? '-' : ''}$${Math.abs(rounded).toLocaleString('en-US')}`;
}

const SMALL_WORDS = new Set(['the', 'a', 'an', 'on', 'of', 'to', 'and', 'with', 'for', 'in', 'at', 'by', 'from']);

/** The words of a task or step that say what it is, lower case, without the small joining words. */
function tellingWords(text) {
    return new Set(
        (text ?? '')
            .toLowerCase()
            .split(/[^a-z0-9$]+/)
            .filter((word) => word && !SMALL_WORDS.has(word))
    );
}

function dateOnly(value) {
    if (!value) {
        return '';
    }
    // A date field arrives as YYYY-MM-DD; noon keeps it on its own day in every time zone.
    return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T12:00:00`));
}

function dateAndTime(value) {
    if (!value) {
        return '';
    }
    const date = new Date(value);
    const day = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
    const time = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' }).format(date);
    return `${day} at ${time}`;
}

/**
 * The adjuster's report.
 *
 * Always in view: the headline, three figures (coverage, payable, reserve) and the actions. Under
 * them the seven sections sit behind tabs, one at a time, so the report is never a long scroll:
 * what happened, the evidence reviewed (four rows a page), the damage with Claude's boxes over the
 * photos, coverage (what it rests on folds away under the figures), gaps and flags, the reserve with
 * its arithmetic, and where to start. The tab, the page and what was folded open are remembered for
 * the claim while the browser session lasts.
 *
 * Three actions, each confirm-first: add next steps as tasks, set the reserve, add the report to the
 * file notes. On paper it is one document: every section in order under its numbered heading, every
 * row, everything unfolded, without the app around it.
 */
export default class AntsuranceClaimAnalysisReport extends NavigationMixin(LightningElement) {
    @api recordId;
    @api docket;

    current;
    chosen = new Set();
    pending;
    isSaving = false;
    actionError;
    doneLines = {};
    // The next steps already added as tasks from this page, so the same one is not added twice.
    added = new Set();
    // Which section is showing, which page of the evidence, and what is folded open under Coverage.
    tab = 'summary';
    evidencePage = 0;
    stepsPage = 0;
    folds = {};
    // True from just before the page prints until just after: every section shows, in full.
    isPrinting = false;
    /** True when a clause of the headline is too long for one line, so the headline is drawn as running text. */
    headlineRunsOn = false;

    @api
    get report() {
        return this.current;
    }
    set report(value) {
        const rewritten = value?.writtenAt !== this.current?.writtenAt;
        this.current = value;
        if (rewritten) {
            // A new report starts with every next step chosen and nothing yet acted on.
            this.chosen = new Set((value?.steps ?? []).map((step, index) => index));
            this.pending = undefined;
            this.doneLines = {};
            this.added = new Set();
            this.actionError = undefined;
            if (this.current) {
                // A rewritten report may have fewer rows than the page the reader was on.
                this.evidencePage = 0;
                this.stepsPage = 0;
            }
        }
    }

    connectedCallback() {
        loadBrandFonts(this);
        // Print rules have to reach the page around this component, so they are a page stylesheet, not this component's own.
        loadStyle(this, PRINT_STYLES).catch(() => {});
        const tab = recall(this.memoryKey('tab'), 'summary');
        this.tab = SECTIONS.includes(tab) ? tab : 'summary';
        this.evidencePage = Number(recall(this.memoryKey('evidence-page'), 0)) || 0;
        this.folds = { findings: recall(this.memoryKey('fold-findings'), false) === true, questions: recall(this.memoryKey('fold-questions'), false) === true };
        // Printing from the browser's own menu reaches here too, so paper always gets the whole report.
        this.beforePrint = () => {
            this.isPrinting = true;
        };
        this.afterPrint = () => {
            this.isPrinting = false;
            this.removeAttribute('data-printing');
        };
        window.addEventListener('beforeprint', this.beforePrint);
        window.addEventListener('afterprint', this.afterPrint);
    }

    disconnectedCallback() {
        window.removeEventListener('beforeprint', this.beforePrint);
        window.removeEventListener('afterprint', this.afterPrint);
        window.removeEventListener('resize', this.remeasure);
        clearInterval(this.measureTimer);
        this.remeasure = undefined;
    }

    renderedCallback() {
        this.fitHeadline();
        if (this.remeasure) {
            return;
        }
        // The masthead's width changes with the window. A tab that is not in front draws no frames, so
        // the window's resize and a slow timer both look again.
        this.remeasure = () => this.fitHeadline();
        window.addEventListener('resize', this.remeasure);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.measureTimer = setInterval(this.remeasure, HEADLINE_CHECK_MS);
    }

    /**
     * A headline breaks after its clauses when each clause fits on a line of its own. When one does not,
     * holding the clauses apart gave three short lines beside half an empty card, so the headline runs on
     * as plain text and fills the width in even lines.
     */
    fitHeadline() {
        const headline = this.refs.headline;
        const ruler = this.refs.ruler;
        if (!headline || !ruler || headline.clientWidth === 0) {
            return;
        }
        const widest = Math.max(0, ...[...ruler.children].map((clause) => clause.getBoundingClientRect().width));
        const runsOn = widest > headline.clientWidth;
        if (runsOn !== this.headlineRunsOn) {
            this.headlineRunsOn = runsOn;
        }
    }

    get headlineClass() {
        return this.headlineRunsOn ? 'c-mast__headline c-mast__headline_runs' : 'c-mast__headline';
    }

    memoryKey(name) {
        return `${this.recordId}:analysis-${name}`;
    }

    // ---------------------------------------------------------------- one section at a time

    get tabs() {
        const flags = (this.current?.gaps ?? []).length;
        const steps = (this.current?.steps ?? []).length;
        return [
            { value: 'summary', label: 'Summary', title: 'What happened' },
            { value: 'evidence', label: 'Evidence', count: this.evidenceCount, title: 'Evidence reviewed' },
            { value: 'damage', label: 'Damage' },
            { value: 'coverage', label: 'Coverage' },
            { value: 'flags', label: 'Flags', count: flags || undefined, tone: this.hasToCheck ? 'watch' : undefined, title: 'Gaps and flags' },
            { value: 'reserve', label: 'Reserve' },
            { value: 'steps', label: 'Next steps', count: steps || undefined, title: 'Where to start' }
        ];
    }

    /** The class of each section: the chosen one shows, and on paper they all do. */
    /**
     * The three figures (coverage, payable, reserve) are the summary in numbers, so on screen they sit
     * with the Summary tab. The other tabs open straight under the headline: with the figures above
     * every one of them, no tab of a full report fitted a screen. Print shows them once, at the top.
     */
    get figuresClass() {
        return this.isPrinting || this.tab === 'summary' ? 'c-figures' : 'c-figures c-figures_away';
    }

    get panels() {
        const classes = {};
        SECTIONS.forEach((name) => {
            classes[name] = this.isPrinting || name === this.tab ? 'c-section' : 'c-section c-panel_off';
        });
        return classes;
    }

    get reportClass() {
        return this.isPrinting ? 'c-report c-report_paper' : 'c-report c-report_screen';
    }

    /** A section's numbered heading. On screen its tab names it, so the heading is for paper. */
    get titleClass() {
        return this.isPrinting ? 'c-section__title' : 'c-section__title c-screenoff';
    }

    /** The claim and who it belongs to are on the page around the report; on paper the report has to say. */
    get claimClass() {
        return this.isPrinting ? 'c-mast__claim' : 'c-mast__claim c-screenoff';
    }

    get metaClass() {
        return this.isPrinting ? 'c-mast__meta' : 'c-mast__meta c-screenoff';
    }

    handleTab(event) {
        this.tab = event.detail.value;
        remember(this.memoryKey('tab'), this.tab);
    }

    handleStepsPage(event) {
        this.stepsPage = event.detail.page;
    }

    handleEvidencePage(event) {
        this.evidencePage = event.detail.page;
        remember(this.memoryKey('evidence-page'), this.evidencePage);
    }

    /** What is folded open under Coverage. On paper, all of it. */
    get foldOpen() {
        return { findings: this.isPrinting || this.folds.findings === true, questions: this.isPrinting || this.folds.questions === true };
    }

    handleFold(event) {
        const name = event.currentTarget.dataset.fold;
        this.folds = { ...this.folds, [name]: event.detail.open };
        remember(this.memoryKey(`fold-${name}`), event.detail.open);
    }

    /** Reloads the photos inside the report. For the parent, after a run. */
    @api
    refresh() {
        this.refs.viewer?.refresh();
    }

    // ---------------------------------------------------------------- masthead

    get claimLine() {
        return `Claim ${this.docket?.caseNumber ?? ''}`;
    }

    get subject() {
        return keepTogether(this.docket?.subject);
    }

    get lossLine() {
        return [this.docket?.lossType, this.docket?.dateOfLoss ? `loss on ${dateOnly(this.docket.dateOfLoss)}` : ''].filter(Boolean).join(', ');
    }

    get writtenLine() {
        return keepTogether(`Written by Claude on ${dateAndTime(this.current?.writtenAt)}`);
    }

    /** The headline in its clauses, so a long one breaks after its semicolon and not before an amount. */
    get headlineParts() {
        return clauses(this.current?.headline);
    }

    get check() {
        return this.current?.check;
    }

    get hasCheck() {
        return Boolean(this.check);
    }

    get verdict() {
        return this.check?.verdict ?? 'Not checked';
    }

    get verdictClass() {
        return VERDICTS[this.check?.verdict] ?? 'c-chip c-chip_quiet';
    }

    get verdictNote() {
        if (!this.check) {
            return 'Coverage could not be checked on this claim.';
        }
        return this.check.respondingLabel ? keepTogether(`Under ${this.check.respondingLabel}`) : 'No coverage on the policy responds.';
    }

    get payable() {
        return this.check?.payable === null || this.check?.payable === undefined ? 'Not worked out' : money(this.check.payable);
    }

    get payableNote() {
        const check = this.check;
        if (!check || check.payable === null || check.payable === undefined) {
            return 'There is no estimate or no coverage to work it from.';
        }
        if (check.liabilityOpen) {
            return 'Only if the insured is found liable.';
        }
        if (check.cappedByLimit) {
            return keepTogether(`Capped by the ${money(check.limitAmount)} limit.`);
        }
        return keepTogether(`On a ${money(check.estimate)} estimate, after the deductible.`);
    }

    get hasRecommendation() {
        return this.current?.reserveRecommended !== null && this.current?.reserveRecommended !== undefined;
    }

    get reserveFigure() {
        return this.hasRecommendation ? money(this.current.reserveRecommended) : money(this.current?.reserveNow ?? 0);
    }

    get reserveDifference() {
        return this.hasRecommendation ? Math.round(this.current.reserveRecommended - (this.current.reserveNow ?? 0)) : 0;
    }

    get reserveNote() {
        if (!this.hasRecommendation) {
            return 'The reserve now. No change is recommended.';
        }
        // The second sentence stays whole where it can, so a narrow cell breaks after "Recommended." and not after "The".
        return keepTogether(`Recommended. The\u00a0reserve\u00a0now is ${money(this.current.reserveNow ?? 0)}.`);
    }

    get reserveChange() {
        if (!this.hasRecommendation) {
            return undefined;
        }
        const difference = this.reserveDifference;
        if (difference === 0) {
            return { label: 'No change', className: 'c-chip c-chip_quiet' };
        }
        return { label: `${difference > 0 ? 'Up' : 'Down'} ${money(Math.abs(difference))}`, className: 'c-chip c-chip_watch' };
    }

    get isStale() {
        return this.current?.stale === true;
    }

    get staleLine() {
        const changes = this.current?.changes ?? [];
        return `${changes.join('. ')}${changes.length ? '.' : ''} Analyze again to bring this report up to date.`;
    }

    // ---------------------------------------------------------------- sections

    get whatHappened() {
        return this.current?.whatHappened ?? '';
    }

    get evidenceCount() {
        return (this.current?.evidence ?? []).length;
    }

    get evidencePageSize() {
        return EVIDENCE_PAGE_SIZE;
    }

    /** Every row is drawn, so paper gets them all; the rows off the page being read are hidden on screen. */
    get evidence() {
        const lastPage = Math.max(0, Math.ceil(this.evidenceCount / EVIDENCE_PAGE_SIZE) - 1);
        const first = Math.min(this.evidencePage, lastPage) * EVIDENCE_PAGE_SIZE;
        return (this.current?.evidence ?? []).map((line, index) => {
            const onPage = this.isPrinting || (index >= first && index < first + EVIDENCE_PAGE_SIZE);
            return {
                ...line,
                shows: tidyEnding(line.shows),
                className: `c-evidence__row${line.readable ? '' : ' c-evidence__row_unread'}${onPage ? '' : ' c-offpage'}${index === first ? ' c-evidence__row_first' : ''}`,
                canOpen: Boolean(line.documentId || line.recordId),
                openLabel: `Open ${line.title}`
            };
        });
    }

    /** The label of the viewer's first tab, which holds Claude's read. On paper the read is set out under the photo. */
    get readTab() {
        return this.isPrinting ? undefined : "Claude's read";
    }

    /** The label of the viewer's last tab: what the photos mean for handling and cost, when the report says either. */
    get handlingTab() {
        if (this.isPrinting || (!this.hasSignals && !this.repairRange)) {
            return undefined;
        }
        return this.repairRange ? 'Signs and cost' : 'Signs';
    }

    get hasPhotos() {
        return (this.current?.photoIds ?? []).length > 0;
    }

    get photoIds() {
        return this.current?.photoIds ?? [];
    }

    get damageText() {
        return this.current?.damage || (this.hasPhotos ? '' : 'No photos or videos were assessed, so the damage has not been seen. Add them to the claim and analyze again.');
    }

    get consistency() {
        const entry = CONSISTENCY[this.current?.consistency];
        return entry ? { ...entry, note: tidyEnding(this.current.consistencyNote) } : undefined;
    }

    get signals() {
        return (this.current?.signals ?? []).map((text, index) => ({ key: index, text: tidyEnding(text) }));
    }

    get hasSignals() {
        return this.signals.length > 0;
    }

    /** Whether the photos say anything about handling or cost, which sits folded under the photo. */
    get hasHandling() {
        return this.hasSignals || Boolean(this.repairRange);
    }

    /** Beside the row's label, in a few words that fit its line: what is inside, by its count and its figure. */
    get handlingSummary() {
        const parts = [];
        if (this.hasSignals) {
            parts.push(`${this.signals.length} ${this.signals.length === 1 ? 'sign' : 'signs'}`);
        }
        if (this.repairRange) {
            parts.push(`rough range ${this.repairRange.figure}`);
        }
        const line = parts.length > 0 ? parts.join(', ') : 'how far the photos go toward the estimate';
        return line.charAt(0).toUpperCase() + line.slice(1);
    }

    get repairRange() {
        const { repairLow, repairHigh } = this.current ?? {};
        if (repairLow === null || repairLow === undefined || repairHigh === null || repairHigh === undefined) {
            return undefined;
        }
        return { figure: `${money(repairLow)} to ${money(repairHigh)}`, basis: tidyEnding(this.current.repairBasis) };
    }

    get damageAreas() {
        return (this.current?.damageAreas ?? []).map((area, index) => ({
            key: index,
            area: area.area,
            detail: tidyEnding(area.detail),
            where: `Photo ${area.photoNumber}`,
            chip: SEVERITIES[area.severity] ?? SEVERITIES.minor
        }));
    }

    get coverageText() {
        return this.current?.coverage ?? '';
    }

    get coverageFacts() {
        const check = this.check;
        if (!check) {
            return [];
        }
        const facts = [];
        if (check.respondingLabel) {
            facts.push({ key: 'responds', label: 'Responds', value: check.respondingLabel, recordId: check.respondingId, isLink: Boolean(check.respondingId) });
        }
        if (check.limitAmount !== null && check.limitAmount !== undefined) {
            facts.push({ key: 'limit', label: 'Limit', value: money(check.limitAmount), note: check.limitBasis });
        } else if (check.limitBasis) {
            // A coverage with no dollar limit, such as one that pays actual cash value.
            facts.push({ key: 'limit', label: 'Limit', value: check.limitBasis });
        }
        if (check.respondingLabel) {
            facts.push({ key: 'deductible', label: 'Deductible', value: check.deductible ? money(check.deductible) : 'None' });
        }
        if (check.payable !== null && check.payable !== undefined) {
            facts.push({ key: 'payable', label: this.payableLabel, value: money(check.payable), note: check.cappedByLimit ? 'Capped by the limit' : undefined });
        }
        return facts;
    }

    /** The same words the coverage check card uses for the same figure. */
    get payableLabel() {
        const check = this.check;
        if (check.verdict === 'Not covered') {
            return 'Payable';
        }
        if (check.liabilityOpen) {
            return 'Payable if the insured is liable';
        }
        return check.verdict === 'Covered' ? 'Payable on the estimate' : 'Payable if covered';
    }

    get findings() {
        return (this.check?.findings ?? []).map((finding, index) => ({
            key: index,
            number: index + 1,
            text: tidyEnding(finding.text),
            sourceKind: finding.sourceKind,
            sourceLabel: keepTogether(finding.sourceLabel),
            recordId: finding.recordId,
            isLink: Boolean(finding.recordId)
        }));
    }

    get hasFindings() {
        return this.findings.length > 0;
    }

    /** What the findings draw on, said before they are opened: "Policy, coverage, claim". */
    get findingsSummary() {
        const kinds = [...new Set(this.findings.map((finding) => finding.sourceKind).filter(Boolean))];
        if (!kinds.length) {
            return undefined;
        }
        const line = kinds.map((kind) => kind.toLowerCase()).join(', ');
        return `From the ${line}`;
    }

    get questions() {
        return (this.check?.questions ?? []).map((text, index) => ({ key: index, text: tidyEnding(text) }));
    }

    get hasQuestions() {
        return this.questions.length > 0;
    }

    gapsOf(kind) {
        return (this.current?.gaps ?? []).filter((gap) => gap.kind === kind).map((gap, index) => ({ key: `${kind}-${index}`, text: tidyEnding(gap.text) }));
    }

    get evidenceNeeded() {
        return this.gapsOf('evidence_needed');
    }

    get toCheck() {
        return this.gapsOf('check');
    }

    get hasEvidenceNeeded() {
        return this.evidenceNeeded.length > 0;
    }

    get hasToCheck() {
        return this.toCheck.length > 0;
    }

    get noGaps() {
        return !this.hasEvidenceNeeded && !this.hasToCheck;
    }

    get reserveLines() {
        return (this.current?.reserveLines ?? []).map((line, index) => ({
            key: index,
            label: keepTogether(line.label),
            amount: line.amount < 0 ? `less ${money(Math.abs(line.amount))}` : money(line.amount)
        }));
    }

    get reserveNowText() {
        return money(this.current?.reserveNow ?? 0);
    }

    get reserveReason() {
        return this.current?.reserveReason ?? '';
    }

    get canSetReserve() {
        return this.hasRecommendation && this.reserveDifference !== 0 && !this.doneLines.reserve;
    }

    get setReserveLabel() {
        return `Set the reserve to ${this.reserveFigure}`;
    }

    /**
     * True for a next step that is already an open task on the claim, whether added from here or by
     * hand. A task written by hand rarely has the step's exact words, so it also counts when every
     * telling word of the shorter one is in the longer: "Interview Chinedu on water source" is the
     * step "Interview Chinedu Okafor on water source, depth and weekend rain".
     */
    onTaskList(step, index) {
        if (this.added.has(index)) {
            return true;
        }
        const words = tellingWords(step.subject);
        return (this.docket?.openTasks ?? []).some((subject) => {
            const other = tellingWords(subject);
            const [few, many] = other.size <= words.size ? [other, words] : [words, other];
            return few.size >= 3 && [...few].every((word) => many.has(word));
        });
    }

    get steps() {
        const all = this.current?.steps ?? [];
        const lastPage = Math.max(0, Math.ceil(all.length / STEPS_PAGE_SIZE) - 1);
        const first = Math.min(this.stepsPage, lastPage) * STEPS_PAGE_SIZE;
        return all.map((step, index) => {
            const added = this.onTaskList(step, index);
            const onPage = this.isPrinting || (index >= first && index < first + STEPS_PAGE_SIZE);
            return {
                key: index,
                className: `c-next__row${onPage ? '' : ' c-offpage'}${index === first ? ' c-next__row_first' : ''}`,
                number: index + 1,
                subject: keepTogether(step.subject),
                why: tidyEnding(step.why),
                checked: this.chosen.has(index) && !added,
                added,
                inputId: `step-${index}`
            };
        });
    }

    get hasSteps() {
        return this.steps.length > 0;
    }

    get stepsPageSize() {
        return STEPS_PAGE_SIZE;
    }

    /** The steps ticked to become tasks, leaving out any that already are. */
    get chosenSteps() {
        return (this.current?.steps ?? []).filter((step, index) => this.chosen.has(index) && !this.onTaskList(step, index));
    }

    get chosenCount() {
        return this.chosenSteps.length;
    }

    get addTasksLabel() {
        const count = this.chosenCount;
        if (count === 0) {
            return 'Add as tasks';
        }
        return count === this.steps.length && count > 1 ? `Add all ${count} as tasks` : `Add ${count} as ${count === 1 ? 'a task' : 'tasks'}`;
    }

    /** Said in place of the button's count when there is nothing left to add. */
    get allOnList() {
        return this.hasSteps && this.steps.every((step) => step.added);
    }

    get addTasksDisabled() {
        return this.chosenCount === 0;
    }

    // ---------------------------------------------------------------- acting on it, each on a press

    get confirm() {
        if (!this.pending) {
            return undefined;
        }
        const count = this.chosenCount;
        const lines = {
            tasks: `This adds ${count === 1 ? 'one task' : `${count} tasks`} on the claim, assigned to you and due in two days.`,
            reserve: `This changes the reserve from ${this.reserveNowText} to ${this.reserveFigure} and records why in a file note.`,
            note: "This adds a summary of the report to the claim's file notes."
        };
        return { line: keepTogether(lines[this.pending]) };
    }

    get confirmingTasks() {
        return this.pending === 'tasks';
    }

    get confirmingReserve() {
        return this.pending === 'reserve';
    }

    get confirmingNote() {
        return this.pending === 'note';
    }

    get tasksDone() {
        return this.doneLines.tasks;
    }

    get reserveDone() {
        return this.doneLines.reserve;
    }

    get noteDone() {
        return this.doneLines.note;
    }

    get noteDisabled() {
        return Boolean(this.doneLines.note);
    }

    handleChoose(event) {
        const index = Number(event.target.dataset.index);
        const chosen = new Set(this.chosen);
        if (event.target.checked) {
            chosen.add(index);
        } else {
            chosen.delete(index);
        }
        this.chosen = chosen;
    }

    handleAsk(event) {
        this.pending = event.currentTarget.dataset.action;
        this.actionError = undefined;
    }

    handleCancel() {
        this.pending = undefined;
        this.actionError = undefined;
    }

    async handleConfirm() {
        const action = this.pending;
        this.isSaving = true;
        this.actionError = undefined;
        try {
            let done;
            if (action === 'tasks') {
                const subjects = this.chosenSteps.map((step) => step.subject);
                done = await addTasks({ caseId: this.recordId, subjects });
                this.added = new Set([...this.added, ...this.chosen]);
                this.chosen = new Set();
            } else if (action === 'reserve') {
                done = await setReserve({ caseId: this.recordId });
            } else {
                done = await addToNotes({ caseId: this.recordId });
            }
            this.doneLines = { ...this.doneLines, [action]: done };
            this.pending = undefined;
            this.dispatchEvent(new CustomEvent('reportchanged'));
        } catch (error) {
            this.actionError = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isSaving = false;
        }
    }

    handlePrint() {
        // The page stylesheet shows only the report that carries this mark, so other pages kept open behind this one stay out of it.
        this.setAttribute('data-printing', '');
        this.isPrinting = true;
        // Let every section draw before the browser takes the page.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => window.print(), 150);
    }

    handleOpenRecord(event) {
        const recordId = event.currentTarget.dataset.record;
        if (recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
        }
    }

    handleOpenEvidence(event) {
        const line = (this.current?.evidence ?? []).find((entry) => entry.key === event.currentTarget.dataset.key);
        if (line?.documentId) {
            this[NavigationMixin.Navigate]({ type: 'standard__namedPage', attributes: { pageName: 'filePreview' }, state: { selectedRecordId: line.documentId } });
        } else if (line?.recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: line.recordId, actionName: 'view' } });
        }
    }
}
