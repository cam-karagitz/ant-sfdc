import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LOCALE from '@salesforce/i18n/locale';
import TIME_ZONE from '@salesforce/i18n/timeZone';
import getReview from '@salesforce/apex/AntsuranceUnderwritingController.getReview';
import draftMemo from '@salesforce/apex/AntsuranceUnderwritingController.draftMemo';
import decide from '@salesforce/apex/AntsuranceUnderwritingController.decide';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';
import { pageOf } from 'c/antsuranceUiMemory';

// How many of the memo's points are in view at once, so the card stays about one screen tall.
const POINTS_SHOWN = 3;

const STATUS = {
    waiting: { label: 'Waiting on an underwriter', tone: 'c-review__status c-review__status_waiting' },
    Approved: { label: 'Approved', tone: 'c-review__status c-review__status_approved' },
    'Approved with Conditions': { label: 'Approved with conditions', tone: 'c-review__status c-review__status_approved' },
    Declined: { label: 'Declined', tone: 'c-review__status c-review__status_declined' }
};
const DECIDED_MESSAGE = {
    Approved: 'Approved. The quote is issued and valid for 30 days.',
    'Approved with Conditions': 'Approved with conditions. The quote is issued and valid for 30 days.',
    Declined: 'Declined. The quote is closed.'
};

const NO_BREAK_SPACE = '\u00a0';

/**
 * keepTogether, and the last three words of a longer sentence stay on one line, so a point in a narrow
 * column does not end on a word or a date by itself. Kept here, not imported, so this component never
 * depends on a newer copy of the shared text module than the browser has cached.
 */
function tidyEnding(text) {
    const kept = keepTogether(text);
    if (typeof kept !== 'string') {
        return kept;
    }
    const words = kept.split(' ');
    return words.length < 8 ? kept : `${words.slice(0, -3).join(' ')} ${words.slice(-3).join(NO_BREAK_SPACE)}`;
}

/** Numbers a list of strings so each row has a stable key. */
function keyed(values) {
    return (values ?? []).map((text, index) => ({ key: `${index}`, text: tidyEnding(text) }));
}

/**
 * The underwriter's review of a referred quote. It shows why the configurator referred the quote,
 * lets Claude draft a memo from the file, and records the decision. A quote that was never referred
 * renders nothing, so the card can sit on every quote page.
 */
// The card's two columns need 46rem; under that it is one column.
const NARROW_PX = 736;

export default class AntsuranceUnderwritingReview extends LightningElement {
    @api recordId;
    review;
    wiredResult;
    isDrafting = false;
    isDeciding = false;
    errorMessage;

    // Below this width the card is one column. Its parts then sit behind tabs, so the card stays about a screen tall.
    isNarrow = false;
    narrowTab = 'decision';
    widthWatcher;
    onWindowResize;

    connectedCallback() {
        loadBrandFonts(this);
        this.onWindowResize = () => this.measure();
        window.addEventListener('resize', this.onWindowResize);
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.onWindowResize);
        this.widthWatcher?.disconnect();
        this.widthWatcher = undefined;
    }

    renderedCallback() {
        this.measure();
        // A tab that is not in front draws no frames, so the window's resize event is listened for as well.
        if (!this.widthWatcher && window.ResizeObserver) {
            this.widthWatcher = new ResizeObserver(() => this.measure());
            this.widthWatcher.observe(this.template.host);
        }
    }

    measure() {
        const width = this.template.host.getBoundingClientRect().width;
        if (width > 0 && width < NARROW_PX !== this.isNarrow) {
            this.isNarrow = width < NARROW_PX;
        }
    }

    /** One column and a memo to read: the recommendation, the memo's points and the open questions take a tab each. */
    get showNarrowTabs() {
        return this.isNarrow && this.hasDetail;
    }

    get narrowTabs() {
        const tabs = [{ value: 'decision', label: 'Recommendation' }];
        if (this.hasPoints) {
            tabs.push({ value: 'points', label: 'Memo', count: this.points.length });
        }
        if (this.questionsOnRight) {
            tabs.push({ value: 'questions', label: 'To find out', count: this.questions.length, tone: 'watch' });
        }
        return tabs;
    }

    get chosenNarrowTab() {
        return this.narrowTabs.some((tab) => tab.value === this.narrowTab) ? this.narrowTab : 'decision';
    }

    handleNarrowTab(event) {
        this.narrowTab = event.detail.value;
    }

    @wire(getReview, { quoteId: '$recordId' })
    wiredReview(result) {
        this.wiredResult = result;
        if (result.data) {
            this.review = result.data;
        } else if (result.error) {
            this.review = undefined;
        }
    }

    get isVisible() {
        const review = this.review;
        return Boolean(review && (review.needsReview || review.decision || review.memo));
    }

    get memo() {
        return this.review?.memo;
    }

    get canDecide() {
        return this.review?.canDecide === true;
    }

    get isBusy() {
        return this.isDrafting || this.isDeciding;
    }

    get reasons() {
        return keyed(this.review?.reasons);
    }

    get hasReasons() {
        return this.reasons.length > 0;
    }

    get points() {
        return (this.memo?.points ?? []).map((point, index) => ({ label: point.label, detail: tidyEnding(point.detail), key: `${index}` }));
    }

    get headline() {
        return tidyEnding(this.memo?.headline);
    }

    pointsPage = 0;

    get pointsShown() {
        return POINTS_SHOWN;
    }

    get shownPoints() {
        return pageOf(this.points, this.pointsPage, POINTS_SHOWN);
    }

    handlePointsPage(event) {
        this.pointsPage = event.detail.page;
    }

    get hasPoints() {
        return this.points.length > 0;
    }

    get isMemoShown() {
        return Boolean(this.memo) && !this.isDrafting;
    }

    /** The memo's points, and its open questions when the conditions hold the left: the part that moves to the right when there is room. */
    get hasDetail() {
        return this.isMemoShown && (this.hasPoints || this.questionsOnRight);
    }

    /** The left column carries the conditions; the open questions go right. With no conditions, the questions take the left. */
    get questionsOnRight() {
        return this.isMemoShown && this.hasQuestions && this.hasConditions;
    }

    get questionsOnLeft() {
        return this.isMemoShown && this.hasQuestions && !this.hasConditions;
    }

    get showConditions() {
        return this.isMemoShown && this.hasConditions;
    }

    get bodyClass() {
        const base = this.hasDetail ? 'c-review__body c-review__body_memo' : 'c-review__body';
        return this.showNarrowTabs ? `${base} c-review__show_${this.chosenNarrowTab}` : base;
    }

    /**
     * Once there is a memo, the decision Claude recommends is the filled button, so the card's one
     * strong action and its recommendation agree. Until then the card leads with drafting the memo.
     */
    variantFor(decision) {
        const recommended = (this.memo?.recommendation ?? '').trim().toLowerCase();
        if (!recommended) {
            return 'neutral';
        }
        const wanted = recommended.startsWith('decline') ? 'decline' : recommended.includes('condition') ? 'conditions' : 'approve';
        return wanted === decision ? 'brand' : 'neutral';
    }

    get approveVariant() {
        return this.variantFor('approve');
    }

    get conditionsVariant() {
        return this.variantFor('conditions');
    }

    get declineVariant() {
        return this.variantFor('decline');
    }

    get conditions() {
        return keyed(this.memo?.conditions);
    }

    get hasConditions() {
        return this.conditions.length > 0;
    }

    get questions() {
        return keyed(this.memo?.questions);
    }

    get hasQuestions() {
        return this.questions.length > 0;
    }

    get status() {
        return STATUS[this.review?.decision] ?? STATUS.waiting;
    }

    get statusLabel() {
        return this.status.label;
    }

    get statusClass() {
        return this.status.tone;
    }

    /** "Oct 2, 2026 at 9:14 PM", in the user's Salesforce time zone. */
    get writtenLabel() {
        const written = this.memo?.writtenAt;
        if (!written) {
            return '';
        }
        const at = new Date(written);
        const day = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric', timeZone: TIME_ZONE }).format(at);
        const time = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit', timeZone: TIME_ZONE }).format(at);
        return `${day} at ${time}`;
    }

    async handleDraft() {
        this.isDrafting = true;
        this.errorMessage = undefined;
        try {
            this.review = await draftMemo({ quoteId: this.recordId });
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The memo could not be drafted. Try again.';
        } finally {
            this.isDrafting = false;
        }
    }

    async handleDecide(event) {
        const { decision } = event.currentTarget.dataset;
        this.isDeciding = true;
        this.errorMessage = undefined;
        try {
            this.review = await decide({ quoteId: this.recordId, decision });
            await refreshApex(this.wiredResult);
            // The quote's status, dates and review flag changed, so the rest of the page re-reads it.
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({ title: 'Decision recorded', message: DECIDED_MESSAGE[decision], variant: 'success' }));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'The decision could not be saved. Try again.';
        } finally {
            this.isDeciding = false;
        }
    }
}
