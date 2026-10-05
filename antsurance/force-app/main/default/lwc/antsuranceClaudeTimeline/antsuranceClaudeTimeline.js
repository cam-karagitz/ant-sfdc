import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';

// Each colored dot has its word beside the date, so the color is never the only signal.
const TONE_WORDS = { good: 'Progress', watch: 'Pending', alert: 'Problem' };
// The most events one page of the timeline shows: in the utility panel, and at full size. A longer
// history is stepped through with previous and next, in pages of equal length, opening on the latest events.
const MINI_EVENTS = 4;
const FULL_EVENTS = 6;

/** Events per page so that `count` events fall into the fewest pages of at most `most`, about equal in length. */
function pageSizeFor(count, most) {
    return count > most ? Math.ceil(count / Math.ceil(count / most)) : most;
}

/** Dated events in order, on a rail. */
export default class AntsuranceClaudeTimeline extends LightningElement {
    /** { title, events: [{ date, title, detail, tone }] } */
    @api spec;
    /** True in the utility bar panel. */
    @api compact = false;

    // The page the user stepped to. Until they do, the page with the latest events is shown.
    chosenPage;

    get events() {
        const thisYear = new Date().getFullYear();
        const withYear = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
        const withoutYear = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', timeZone: 'UTC' });
        return (this.spec?.events ?? []).map((event, index) => {
            const day = new Date(`${event.date}T12:00:00Z`);
            return {
                ...event,
                key: `event-${index}`,
                // The year is plain when it is this one.
                when: (day.getUTCFullYear() === thisYear ? withoutYear : withYear).format(day),
                className: `c-event c-event_${event.tone}`,
                toneWord: TONE_WORDS[event.tone],
                toneClass: `c-event__tone c-event__tone_${event.tone}`
            };
        });
    }

    /** Whether the events run newest first, in which case the latest ones are at the top. */
    get newestFirst() {
        const events = this.spec?.events ?? [];
        return events.length > 1 && events[0].date > events[events.length - 1].date;
    }

    get total() {
        return this.spec?.events?.length ?? 0;
    }

    get pageSize() {
        return pageSizeFor(this.total, this.compact ? MINI_EVENTS : FULL_EVENTS);
    }

    get page() {
        const lastPage = Math.max(0, Math.ceil(this.total / this.pageSize) - 1);
        return this.chosenPage ?? (this.newestFirst ? 0 : lastPage);
    }

    /** The events on the page being shown, in the order Claude gave them. */
    get pageEvents() {
        const first = this.page * this.pageSize;
        return this.events.slice(first, first + this.pageSize);
    }

    get isPaged() {
        return this.total > this.pageSize;
    }

    handlePage(event) {
        this.chosenPage = event.detail.page;
    }

    get expandLabel() {
        return `Expand ${this.spec?.title ?? 'the timeline'}`;
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }
}
