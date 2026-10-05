import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { recall, remember } from 'c/antsuranceUiMemory';
import { HEALTHY_LOSS_RATIO, PLACEHOLDER, compactMoney, count, plural, toDate } from 'c/antsuranceCockpitFormat';

const RANGES = [
    { key: '3m', label: '3M', title: 'The last 3 months', months: 3 },
    { key: '6m', label: '6M', title: 'The last 6 months', months: 6 },
    { key: '1y', label: '1Y', title: 'The last year', months: 12 }
];
const DEFAULT_RANGE = '6m';
const RANGE_MEMORY = 'home:loss-trend-range';
const MS_PER_DAY = 86400000;
const WEEK = 7;
// The highest value sits this far under the top of the plot, so the line never touches it.
const HEADROOM = 1.12;
// Gridline steps in percentage points. The first that needs no more than three intervals is used.
const STEPS = [50, 100, 200, 250, 500, 1000, 2500, 5000];
const MAX_INTERVALS = 3;
// A month label that would start past this point has no room before the card's edge and is left out.
const LAST_MONTH_LABEL = 98.5;
// The threshold's label steps aside while the crosshair is in the third of the plot it sits in.
const LABEL_REACH = 33;
// With more month labels than this, every other one is dropped when the card is narrow.
const MANY_MONTHS = 8;

const FULL_DATE = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric' });
const MONTH = new Intl.DateTimeFormat(LOCALE, { month: 'short' });
const MONTH_AND_YEAR = new Intl.DateTimeFormat(LOCALE, { month: 'short', year: 'numeric' });

const percent = (ratio) => (ratio == null ? PLACEHOLDER : `${Math.round(ratio)}%`);
const place = (value) => value.toFixed(2);

/** What the tooltip, the slider's spoken value and the table say about one day. */
function describe(point) {
    return {
        date: FULL_DATE.format(point.date),
        ratio: percent(point.ratio),
        incurred: compactMoney(point.incurred),
        claims: count(point.claims),
        soFar: `${compactMoney(point.incurred)} incurred on ${plural(point.claims, 'claim')}`,
        thatDay: point.newClaims > 0 ? `That day: ${plural(point.newClaims, 'claim')}, ${compactMoney(point.newIncurred)}` : 'No losses that day'
    };
}

/**
 * Everything the plot draws for one period, worked out once when the data or the period changes so
 * that moving the pointer only moves the crosshair.
 * @param {object} trend { startDate, incurred, claims }: running totals, one entry a day, ending today
 * @param {number} premium A year of premium on the policies in force today, which every day is measured against
 * @param {string} rangeKey Which of RANGES is shown
 * @returns {object} The points and where each part of the plot sits, as percentages of the plot
 */
function buildView(trend, premium, rangeKey) {
    const days = trend?.incurred?.length ?? 0;
    if (!trend?.startDate || days < 2) {
        return undefined;
    }
    const start = toDate(trend.startDate);
    const dayAt = (index) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + index);
    const last = days - 1;
    const today = dayAt(last);
    const range = RANGES.find((option) => option.key === rangeKey) ?? RANGES[RANGES.length - 1];
    const opens = new Date(today.getFullYear(), today.getMonth() - range.months, today.getDate());
    const from = Math.min(Math.max(Math.round((opens.getTime() - start.getTime()) / MS_PER_DAY), 0), last - 1);

    const points = [];
    for (let index = from; index <= last; index++) {
        const before = Math.max(index - 1, 0);
        const incurred = trend.incurred[index];
        points.push({
            date: dayAt(index),
            incurred,
            claims: trend.claims[index],
            // With no premium in force there is nothing to measure against, and so no ratio.
            ratio: premium > 0 ? (incurred / premium) * 100 : null,
            newClaims: trend.claims[index] - trend.claims[before],
            newIncurred: incurred - trend.incurred[before],
            x: ((index - from) / (last - from)) * 100
        });
    }
    const drawn = points.filter((point) => point.ratio !== null);
    if (drawn.length < 2) {
        return { points, drawn: [], ticks: [], months: [], rows: [] };
    }

    const top = Math.max(...drawn.map((point) => point.ratio), HEALTHY_LOSS_RATIO) * HEADROOM;
    const step = STEPS.find((size) => Math.ceil(top / size) <= MAX_INTERVALS) ?? STEPS[STEPS.length - 1];
    const ceiling = Math.ceil(top / step) * step;
    const yOf = (ratio) => 100 - (ratio / ceiling) * 100;
    drawn.forEach((point) => {
        point.y = yOf(point.ratio);
    });

    const ticks = [];
    for (let value = 0; value <= ceiling; value += step) {
        ticks.push({ key: `tick-${value}`, label: `${value}%`, style: `top: ${place(yOf(value))}%` });
    }
    const months = points
        .filter((point) => point.date.getDate() === 1 && point.x <= LAST_MONTH_LABEL)
        .map((point) => ({
            key: `month-${point.date.getTime()}`,
            label: (point.date.getMonth() === 0 ? MONTH_AND_YEAR : MONTH).format(point.date),
            // The names sit in a row that runs on under the gutter, so the last one has room; each is placed by the plot's own width.
            style: `left: calc((100% - var(--c-gutter)) * ${(point.x / 100).toFixed(4)})`
        }));

    const first = drawn[0];
    const end = drawn[drawn.length - 1];
    const line = drawn.map((point) => `${place(point.x)},${place(point.y)}`).join(' ');
    // The threshold's label goes to the side where the line is further from it.
    const labelLeft = Math.abs(first.ratio - HEALTHY_LOSS_RATIO) >= Math.abs(end.ratio - HEALTHY_LOSS_RATIO);
    // Month ends and today, for the table a screen reader gets in place of the picture.
    const rows = points
        .filter((point, index) => index === points.length - 1 || points[index + 1].date.getDate() === 1)
        .map((point) => ({ key: `row-${point.date.getTime()}`, ...describe(point) }));

    return {
        points,
        drawn,
        ticks,
        months,
        rows,
        line,
        area: `${place(first.x)},100 ${line} ${place(end.x)},100`,
        monthsClass: `c-chart__months${months.length > MANY_MONTHS ? ' c-chart__months_many' : ''}`,
        markStyle: `top: ${place(yOf(HEALTHY_LOSS_RATIO))}%`,
        labelLeft,
        endStyle: `left: ${place(end.x)}%; top: ${place(end.y)}%`,
        endLabelStyle: `top: ${place(end.y)}%`,
        endLabel: percent(end.ratio)
    };
}

/**
 * How the loss ratio built, as one line: the losses incurred by each day, by date of loss, over the
 * premium in force today. Moving the pointer along the plot, or the arrow keys once it has focus,
 * reads off any day: the ratio so far, what had been incurred and what that day added. The last day
 * is the loss ratio among the six figures. It is a running total, so it only ever climbs.
 */
export default class AntsuranceCockpitTrend extends LightningElement {
    range = recall(RANGE_MEMORY, DEFAULT_RANGE);
    source;
    view;
    /** The day being read, as an index into the points on show; undefined when nothing is. */
    activeIndex;

    @api
    get cockpit() {
        return this.source;
    }

    set cockpit(value) {
        this.source = value;
        this.draw();
    }

    connectedCallback() {
        loadBrandFonts(this);
    }

    draw() {
        this.view = buildView(this.source?.lossTrend, this.source?.figures?.premiumInForce, this.range);
        // Home refreshes itself while it is open; a day being read stays read when it is still on show.
        if (this.activeIndex > this.lastIndex) {
            this.activeIndex = undefined;
        }
    }

    get isLoading() {
        return this.source ? 'false' : 'true';
    }

    get hasLine() {
        return Boolean(this.view?.drawn.length);
    }

    get isEmpty() {
        return Boolean(this.source) && !this.hasLine;
    }

    get lastIndex() {
        return (this.view?.points.length ?? 0) - 1;
    }

    /** What the line measures, with the premium it is measured against once that is known. */
    get basis() {
        const premium = this.source?.figures?.premiumInForce;
        return `Losses to date, by date of loss, over the ${premium > 0 ? `${compactMoney(premium)} ` : ''}premium in force today.`;
    }

    /** The threshold's label, out of the way while the tooltip would sit on part of it. */
    get markLabelClass() {
        const left = this.view?.labelLeft;
        const x = this.hasLine ? this.view.points[this.activeIndex]?.x : undefined;
        const covered = x !== undefined && (left ? x < LABEL_REACH : x > 100 - LABEL_REACH);
        return `c-plot__mark-label ${left ? 'c-plot__mark-label_left' : 'c-plot__mark-label_right'}${covered ? ' c-plot__mark-label_away' : ''}`;
    }

    get ranges() {
        return RANGES.map((option) => ({
            ...option,
            pressed: String(option.key === this.range),
            className: `c-range__option${option.key === this.range ? ' c-range__option_on' : ''}`
        }));
    }

    get plotClass() {
        return `c-plot${this.hasLine ? ' c-plot_live' : ''}`;
    }

    get plotTabIndex() {
        return this.hasLine ? '0' : '-1';
    }

    /** The day under the crosshair, with where to draw it and what to say about it. */
    get active() {
        const point = this.hasLine ? this.view.points[this.activeIndex] : undefined;
        if (!point) {
            return undefined;
        }
        const left = `left: ${place(point.x)}%`;
        return {
            ...describe(point),
            hairStyle: left,
            tipStyle: left,
            tipClass: `c-tip${point.x > 50 ? ' c-tip_before' : ''}`,
            hasDot: point.ratio !== null,
            dotStyle: `${left}; top: ${place(point.y ?? 0)}%`
        };
    }

    /** What a screen reader says for the day the slider is on; today when nothing is being read. */
    get spoken() {
        if (!this.hasLine) {
            return '';
        }
        const day = describe(this.view.points[this.activeIndex ?? this.lastIndex]);
        return `${day.date}: loss ratio to date ${day.ratio}. ${day.soFar}. ${day.thatDay}.`;
    }

    get sliderNow() {
        return this.activeIndex ?? this.lastIndex;
    }

    handleRange(event) {
        this.range = event.currentTarget.dataset.key;
        remember(RANGE_MEMORY, this.range);
        this.activeIndex = undefined;
        this.draw();
    }

    read(index) {
        const next = Math.min(Math.max(index, 0), this.lastIndex);
        if (next !== this.activeIndex) {
            this.activeIndex = next;
        }
    }

    /** The crosshair snaps to the day nearest the pointer, so nobody has to aim at the line. */
    handlePointer(event) {
        const box = event.currentTarget.getBoundingClientRect();
        if (!this.hasLine || !box.width) {
            return;
        }
        const share = Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1);
        this.read(Math.round(share * this.lastIndex));
    }

    /** A mouse that leaves stops reading. A finger that lifts leaves the day on show until focus moves away. */
    handleLeave(event) {
        if (event.pointerType === 'mouse') {
            this.activeIndex = undefined;
        }
    }

    handleFocus(event) {
        // Arriving by keyboard starts on today. A click has already put the crosshair under the pointer.
        if (this.hasLine && this.activeIndex === undefined && event.currentTarget.matches(':focus-visible')) {
            this.read(this.lastIndex);
        }
    }

    handleBlur() {
        this.activeIndex = undefined;
    }

    handleKey(event) {
        if (!this.hasLine) {
            return;
        }
        const at = this.activeIndex ?? this.lastIndex;
        const moves = {
            ArrowLeft: at - 1,
            ArrowDown: at - 1,
            ArrowRight: at + 1,
            ArrowUp: at + 1,
            PageDown: at - WEEK,
            PageUp: at + WEEK,
            Home: 0,
            End: this.lastIndex
        };
        if (event.key === 'Escape') {
            this.activeIndex = undefined;
        } else if (event.key in moves) {
            event.preventDefault();
            this.read(moves[event.key]);
        }
    }
}
