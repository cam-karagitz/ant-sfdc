import { LightningElement, api, wire } from 'lwc';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import LOCALE from '@salesforce/i18n/locale';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';
import getBrief from '@salesforce/apex/AntsuranceClaimsAssistantBrief.getBrief';
import writeBrief from '@salesforce/apex/AntsuranceClaimsAssistantBrief.writeBrief';
import addTask from '@salesforce/apex/AntsuranceClaimsAssistantBrief.addTask';
import getNotes from '@salesforce/apex/AntsuranceNotesController.getNotes';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { clauses, keepTogether, tidyEnding } from 'c/antsuranceText';
import { recall, remember } from 'c/antsuranceUiMemory';

// Any save to the claim changes this field, which is the cue to check whether the brief is still current.
const CHANGE_SIGNAL = ['Case.LastModifiedDate'];
const WRITING_CAPTIONS = [
    'Reading the claim and its policy',
    'Going through the file notes',
    'Checking coverage and the reserve',
    'Writing the brief'
];
const CAPTION_INTERVAL_MS = 1600;
const FALLBACK_ERROR = 'The brief could not be loaded. Refresh the page and try again.';

export default class AntsuranceClaimBrief extends LightningElement {
    @api recordId;

    sparkUrl = CLAUDE_SPARK;
    brief;
    errorMessage;
    isWriting = false;
    captionIndex = 0;
    captionTimer;
    // Counts loads so that a slow, older response cannot overwrite a newer one.
    loadSequence = 0;
    addingIndex;
    // The part of the brief in view. Where the claim stands, until the reader picks another.
    tab;

    connectedCallback() {
        loadBrandFonts(this);
        this.tab = recall(`${this.recordId}:brief-tab`);
    }

    disconnectedCallback() {
        this.stopCaptions();
    }

    @wire(getRecord, { recordId: '$recordId', fields: CHANGE_SIGNAL })
    wiredClaim({ data }) {
        if (data) {
            this.load();
        }
    }

    // The file notes card shares this cached list, so a note added anywhere on the page arrives here too.
    @wire(getNotes, { recordId: '$recordId' })
    wiredNotes({ data }) {
        if (data && this.brief) {
            this.load();
        }
    }

    get isLoading() {
        return !this.brief && !this.errorMessage && !this.isWriting;
    }

    get isBusy() {
        return this.isLoading || this.isWriting ? 'true' : 'false';
    }

    get hasBrief() {
        return Boolean(this.brief?.exists);
    }

    get isEmpty() {
        return Boolean(this.brief) && !this.brief.exists;
    }

    get showRewrite() {
        return this.hasBrief;
    }

    get metaLine() {
        if (this.isWriting) {
            return 'Claude is reading the file';
        }
        if (!this.hasBrief || !this.brief.writtenAt) {
            return 'Claude’s read of the file';
        }
        const written = new Date(this.brief.writtenAt);
        const day = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' }).format(written);
        const time = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(written);
        return `Written by Claude on ${day} at ${time}`;
    }

    get writingCaption() {
        return WRITING_CAPTIONS[this.captionIndex];
    }

    get changeSummary() {
        const changes = this.brief?.changes ?? [];
        return changes.length ? `${changes.join(', ')} since this was written.` : 'Rewrite the brief to bring it up to date.';
    }

    /** Every labelled point the brief has. */
    get allPoints() {
        return [
            { label: 'Where it stands', text: this.brief.standing },
            { label: 'Coverage', text: this.brief.coverage },
            { label: 'The money', text: this.brief.money }
        ]
            .filter((point) => point.text)
            .map((point) => ({ label: point.label, text: tidyEnding(point.text) }));
    }

    /** The headline in its clauses, so a long one breaks after its semicolon and not mid-clause. */
    get headlineParts() {
        return clauses(this.brief.headline);
    }

    /**
     * The brief's parts as tabs under the headline, one in view at a time, so the card keeps its
     * height however much Claude wrote: where the claim stands first, then coverage, the money, what
     * to watch and what to do next.
     */
    get tabs() {
        const tabs = this.allPoints.map((point) => ({ value: point.label, label: point.label }));
        if (this.hasWatch) {
            const urgent = this.watch.some((item) => item.level === 'high');
            tabs.push({ value: 'watch', label: 'Watch', count: this.watch.length, tone: urgent ? 'watch' : undefined, title: 'Things to watch' });
        }
        if (this.hasNext) {
            tabs.push({ value: 'next', label: 'Next steps', count: this.nextActions.length });
        }
        return tabs;
    }

    get hasTabs() {
        return this.tabs.length > 1;
    }

    get currentTab() {
        const tabs = this.tabs;
        return tabs.some((tab) => tab.value === this.tab) ? this.tab : tabs[0]?.value;
    }

    /** The labeled point in view, when the tab is one of them. */
    get point() {
        return this.allPoints.find((point) => point.label === this.currentTab);
    }

    get panelLabel() {
        return this.tabs.find((tab) => tab.value === this.currentTab)?.title ?? this.currentTab;
    }

    get showWatch() {
        return this.currentTab === 'watch';
    }

    get showNext() {
        return this.currentTab === 'next';
    }

    handleTab(event) {
        this.tab = event.detail.value;
        remember(`${this.recordId}:brief-tab`, this.tab);
    }

    get watch() {
        return (this.brief.watch ?? []).map((item, index) => ({
            ...item,
            text: tidyEnding(item.text),
            key: `watch-${index}`,
            rowClass: item.level === 'high' ? 'c-watch c-watch_high' : 'c-watch'
        }));
    }

    get hasWatch() {
        return this.watch.length > 0;
    }

    get nextActions() {
        return (this.brief.nextActions ?? []).map((step, index) => ({
            ...step,
            // Shown only: the task added from a step takes its wording from the stored brief.
            action: keepTogether(step.action),
            reason: tidyEnding(step.reason),
            key: `step-${index}`,
            index,
            number: index + 1,
            isAdding: this.addingIndex === index
        }));
    }

    get hasNext() {
        return this.nextActions.length > 0;
    }

    async load() {
        this.loadSequence += 1;
        const sequence = this.loadSequence;
        try {
            const brief = await getBrief({ caseId: this.recordId });
            if (sequence === this.loadSequence && !this.isWriting) {
                this.brief = brief;
                this.errorMessage = undefined;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
            }
        }
    }

    async handleWrite() {
        if (this.isWriting) {
            return;
        }
        this.isWriting = true;
        this.errorMessage = undefined;
        this.startCaptions();
        // Anything still loading is now out of date.
        this.loadSequence += 1;
        try {
            this.brief = await writeBrief({ caseId: this.recordId });
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isWriting = false;
            this.stopCaptions();
        }
    }

    async handleAddTask(event) {
        const index = Number(event.currentTarget.dataset.index);
        const step = this.brief.nextActions[index];
        if (!step || this.addingIndex !== undefined) {
            return;
        }
        this.addingIndex = index;
        try {
            await addTask({ caseId: this.recordId, subject: step.action });
            this.brief = {
                ...this.brief,
                nextActions: this.brief.nextActions.map((item, position) => (position === index ? { ...item, hasTask: true } : item))
            };
            this.dispatchEvent(new ShowToastEvent({ title: 'Task added', message: step.action, variant: 'success' }));
            // Lets the activity timeline pick up the new task.
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'The task was not added', message: error?.body?.message ?? 'Try again.', variant: 'error' })
            );
        } finally {
            this.addingIndex = undefined;
        }
    }

    startCaptions() {
        this.captionIndex = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex = Math.min(this.captionIndex + 1, WRITING_CAPTIONS.length - 1);
        }, CAPTION_INTERVAL_MS);
    }

    stopCaptions() {
        clearInterval(this.captionTimer);
        this.captionTimer = undefined;
    }
}
