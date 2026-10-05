import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import SPARK from '@salesforce/resourceUrl/claudeSpark';
import briefMe from '@salesforce/apex/AntsuranceCockpitController.briefMe';
import briefMeForToday from '@salesforce/apex/AntsuranceCockpitController.briefMeForToday';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { clauses, keepTogether, tidyEnding } from 'c/antsuranceText';
import { clockTime, plural } from 'c/antsuranceCockpitFormat';
import { pageOf } from 'c/antsuranceUiMemory';

// How many things to do first are in view at once. With room, all of them (a briefing has at most five)
// and the card ends level with the rail beside it. In a narrower card each takes more lines, so three
// show and the rest are a step away.
const PRIORITIES_WIDE = 5;
const PRIORITIES_NARROW = 3;
const WIDE_FROM_PX = 760;
const MEASURE_EVERY_MS = 1000;
const DAY_MS = 86400000;

/** The calendar day a moment falls on, as a number that grows by one each day, in the reader's own time. */
function dayNumber(moment) {
    const at = new Date(moment);
    return Date.UTC(at.getFullYear(), at.getMonth(), at.getDate()) / DAY_MS;
}

/**
 * Claude's briefing, the focal point of Home: one sentence on the day and the few things to do first,
 * three in view at a time, each with why and the record it is about. What to watch is drawn beside it, in the rail. It is written when the person asks,
 * stored on their user record, and shown from there the next time Home opens. A stored briefing from an
 * earlier day is never called today's: the card names its day, and Home has a new one written as it
 * loads, once, showing the working state meanwhile. If that fails the old one stays, with its chip and a retry.
 */
export default class AntsuranceCockpitBriefing extends NavigationMixin(LightningElement) {
    @api cockpit;
    isWriting = false;
    /** The stored briefing (by when it was written) that one attempt to replace has already been made for. */
    triedFor;
    shown;

    /** The briefing to show: the stored one, or the one just written. Home decides which. */
    @api
    get briefing() {
        return this.shown;
    }

    set briefing(value) {
        this.shown = value;
        this.writeForToday();
    }

    errorMessage;
    sparkUrl = SPARK;
    // Which page of the things to do first is in view. A new briefing starts at the top.
    priorityPage = 0;
    pagedFor;
    isNarrow = false;
    watcher;

    connectedCallback() {
        loadBrandFonts(this);
    }

    renderedCallback() {
        if (this.remeasure) {
            return;
        }
        // The card's own width decides how many things to do first are in view. A browser draws no frames
        // for a tab that is not in front, so an observer alone can miss a change of width: the window's
        // resize and a slow timer measure it as well.
        this.remeasure = () => this.measure();
        this.measure();
        if (typeof ResizeObserver !== 'undefined') {
            this.watcher = new ResizeObserver(this.remeasure);
            this.watcher.observe(this.template.host);
        }
        window.addEventListener('resize', this.remeasure);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(this.remeasure, MEASURE_EVERY_MS);
    }

    measure() {
        const width = this.template.host.getBoundingClientRect().width;
        // Hidden, or not laid out yet: keep what was last known.
        if (width === 0) {
            return;
        }
        const narrow = width < WIDE_FROM_PX;
        if (narrow !== this.isNarrow) {
            this.isNarrow = narrow;
        }
    }

    disconnectedCallback() {
        this.watcher?.disconnect();
        this.watcher = undefined;
        window.removeEventListener('resize', this.remeasure);
        clearInterval(this.timer);
        this.remeasure = undefined;
    }

    get hasBriefing() {
        return Boolean(this.briefing);
    }

    get isReady() {
        return Boolean(this.cockpit);
    }

    /** Work Claude prepared on its own that is waiting for this person. */
    get hasDeskWork() {
        return (this.cockpit?.desk?.waiting ?? 0) > 0;
    }

    get deskLine() {
        const { waiting, topTitle } = this.cockpit.desk;
        const waits = `${plural(waiting, 'piece')} of prepared work ${waiting === 1 ? 'waits' : 'wait'} for your approval.`;
        if (!topTitle) {
            return keepTogether(waits);
        }
        // A piece is titled "Claim: what to do", and one colon is enough for a sentence.
        const [subject, ...action] = topTitle.split(': ');
        const top = action.length > 0 ? `Most important, on ${subject}: ${action.join(': ')}.` : `Most important: ${topTitle}.`;
        return tidyEnding(`${waits} ${top}`);
    }

    handleDesk() {
        this.dispatchEvent(new CustomEvent('opendesk'));
        // The band promises the pieces that are waiting, so the desk shows those whichever view was last open.
        window.dispatchEvent(new CustomEvent('antsurancedeskwaiting'));
    }

    /** From an earlier day: the server says so, and so does the date it was written, which a cached copy of the page cannot get wrong. */
    get isStale() {
        const briefing = this.briefing;
        if (!briefing) {
            return false;
        }
        return briefing.isStale === true || (Boolean(briefing.writtenAt) && dayNumber(briefing.writtenAt) < dayNumber(Date.now()));
    }

    /** "Today's briefing" only when it is: an older one is named for its day, "Sunday's briefing", or its date once a week has passed. */
    get title() {
        const writtenAt = this.briefing?.writtenAt;
        if (!this.isStale || this.isWriting) {
            return "Today's briefing";
        }
        if (!writtenAt) {
            return 'An earlier briefing';
        }
        const written = new Date(writtenAt);
        if (dayNumber(Date.now()) - dayNumber(writtenAt) < 7) {
            return `${new Intl.DateTimeFormat(LOCALE, { weekday: 'long' }).format(written)}'s briefing`;
        }
        return `Briefing from ${new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' }).format(written)}`;
    }

    get showStaleChip() {
        return this.isStale && !this.isWriting;
    }

    /**
     * Has today's briefing written when the one Home holds is from an earlier day. One attempt for each
     * stored briefing while this page lives: a failure leaves the old one in place with the button to try again.
     * The server decides whether there is anything to write (and for whom), so a cached page costs nothing.
     */
    writeForToday() {
        const briefing = this.shown;
        if (!briefing?.writeOnLoad || !briefing.writtenAt || this.isWriting || this.triedFor === briefing.writtenAt) {
            return;
        }
        this.triedFor = briefing.writtenAt;
        this.write(briefMeForToday);
    }

    /** The headline in its clauses, so a long one breaks after its semicolon and not mid-clause. */
    get headlineParts() {
        return clauses(this.briefing.headline);
    }

    /** "Written by Claude today at 9:41 AM", or with the day when it is from an earlier one. */
    get writtenLabel() {
        const writtenAt = this.briefing?.writtenAt;
        if (this.isWriting) {
            return 'Claude is writing it now';
        }
        if (!writtenAt) {
            return 'Written by Claude';
        }
        if (!this.isStale) {
            return `Written by Claude today at ${clockTime(writtenAt)}`;
        }
        const day = new Intl.DateTimeFormat(LOCALE, { weekday: 'long', month: 'short', day: 'numeric' }).format(new Date(writtenAt));
        return `Written by Claude on ${day} at ${clockTime(writtenAt)}`;
    }

    get priorities() {
        return (this.briefing?.priorities ?? []).map((priority, index) => ({
            ...priority,
            key: `${priority.recordId}-${index}`,
            number: index + 1,
            title: keepTogether(priority.title),
            why: tidyEnding(priority.why),
            recordName: keepTogether(priority.recordName),
            url: `/lightning/r/${priority.objectApiName}/${priority.recordId}/view`,
            className: priority.isDone ? 'c-priority c-priority_done' : 'c-priority',
            // The first thing to do carries the page's one filled button.
            variant: index === 0 && !priority.isDone ? 'brand' : 'neutral'
        }));
    }

    get priorityCount() {
        return (this.briefing?.priorities ?? []).length;
    }

    get prioritiesShown() {
        return this.isNarrow ? PRIORITIES_NARROW : PRIORITIES_WIDE;
    }

    get page() {
        // A briefing written since the page was chosen starts again at the top.
        return this.pagedFor === this.briefing?.writtenAt ? this.priorityPage : 0;
    }

    get shownPriorities() {
        return pageOf(this.priorities, this.page, this.prioritiesShown);
    }

    handlePriorityPage(event) {
        this.priorityPage = event.detail.page;
        this.pagedFor = this.briefing?.writtenAt;
    }

    /** What Claude will read, in today's numbers. */
    get reads() {
        const cockpit = this.cockpit;
        if (!cockpit) {
            return '';
        }
        return [
            plural(cockpit.openTaskCount, 'open task'),
            plural(cockpit.figures.openClaimCount, 'open claim'),
            plural(cockpit.renewalCount, 'renewal'),
            plural(cockpit.referrals.length, 'referral'),
            plural(cockpit.openSaleCount, 'open sale')
        ].join(', ');
    }

    get refreshLabel() {
        return this.isStale ? 'Brief me again' : 'Refresh';
    }

    get refreshVariant() {
        return this.isStale ? 'brand' : 'neutral';
    }

    handleBrief() {
        this.write(briefMe);
    }

    async write(ask) {
        this.isWriting = true;
        this.errorMessage = undefined;
        try {
            const briefing = await ask();
            // Home shows it at once, in this card and in the rail, and reloads so anything that changed meanwhile comes back with it.
            if (briefing) {
                this.dispatchEvent(new CustomEvent('briefed', { detail: briefing }));
            }
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'Claude could not write the briefing. Try again in a moment.';
        } finally {
            this.isWriting = false;
        }
    }

    handleOpen(event) {
        // A modified click on a link is left to the browser, so the record can be opened in a new tab.
        if (event.currentTarget.tagName === 'A') {
            if (event.metaKey || event.ctrlKey || event.shiftKey) {
                return;
            }
            event.preventDefault();
        }
        const { recordId, object: objectApiName } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }
}
