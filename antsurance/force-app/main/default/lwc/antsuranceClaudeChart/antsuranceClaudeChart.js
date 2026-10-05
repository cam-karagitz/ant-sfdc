import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';

// Slices of a donut, in order. Neighbours differ in lightness so they read apart without a legend lookup.
const SLICE_COLORS = ['#ae5f46', '#e9b9a8', '#8a4a35', '#d9b25c', '#a9bd8b', '#d8d5c8'];
// A column chart with more points or longer labels than this is drawn as bars, which have room for them.
const MAX_COLUMNS = 8;
const MAX_COLUMN_LABEL = 12;
// The room one column takes, in rem, when the card is sized to its columns.
const COLUMN_REM = 6.5;
// A donut's card: the ring, then a legend whose figures sit close to their labels.
const DONUT_REM = 32;
// A line labels every point up to this many, then only the ones that matter.
const MAX_LINE_VALUES = 8;
const MAX_LINE_LABELS = 6;
// Where a line's highest and lowest values sit in the plot, as a share of its height from the top.
const LINE_TOP = 22;
const LINE_SPAN = 62;
// In the utility panel a bar chart shows this many rows until the user asks for the rest.
const MINI_BARS = 5;
// The compact line fills more of its short plot, since it carries no value labels.
const MINI_LINE_TOP = 10;
const MINI_LINE_SPAN = 80;

const number = (options) => new Intl.NumberFormat(LOCALE, options);

/** How a unit's values are written in full and in the short form used on a crowded chart. */
function formatters(unit) {
    if (unit === 'dollars') {
        const full = number({ style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 });
        const short = number({ style: 'currency', currency: CURRENCY, notation: 'compact', maximumFractionDigits: 1 });
        return { full: (value) => full.format(value), short: (value) => short.format(value) };
    }
    if (unit === 'percent') {
        const percent = number({ maximumFractionDigits: 1 });
        const write = (value) => `${percent.format(value)}%`;
        return { full: write, short: write };
    }
    const full = number({ maximumFractionDigits: 1 });
    const short = number({ notation: 'compact', maximumFractionDigits: 1 });
    return { full: (value) => full.format(value), short: (value) => short.format(value) };
}

/** A bar, column, line or donut chart of one series, drawn without a charting library. */
export default class AntsuranceClaudeChart extends LightningElement {
    /** { title, caption, chartType, unit, points: [{ label, value }], highlight } */
    @api spec;
    /** True in the utility bar panel, where the chart is drawn small with the rest behind Expand. */
    @api compact = false;

    // Compact bars: whether the rows past the first few are showing.
    showAll = false;

    get points() {
        return this.spec?.points ?? [];
    }

    get format() {
        return formatters(this.spec?.unit);
    }

    get hasHighlight() {
        return Boolean(this.spec?.highlight);
    }

    /** The largest value, or 1 when every value is zero so nothing divides by zero. */
    get max() {
        return Math.max(...this.points.map((point) => point.value), 0) || 1;
    }

    get wantsColumns() {
        return this.spec?.chartType === 'column';
    }

    /** Columns need few points and short labels; otherwise the same data is drawn as bars. */
    get isColumn() {
        return this.wantsColumns && this.points.length <= MAX_COLUMNS && this.points.every((point) => point.label.length <= MAX_COLUMN_LABEL);
    }

    get isBar() {
        return this.spec?.chartType === 'bar' || (this.wantsColumns && !this.isColumn);
    }

    get isLine() {
        return this.spec?.chartType === 'line';
    }

    get isDonut() {
        return this.spec?.chartType === 'donut';
    }

    /** Read out in place of the drawing. */
    get summary() {
        return `${this.spec?.title}: ${this.points.map((point) => `${point.label} ${this.format.full(point.value)}`).join(', ')}`;
    }

    /** Bars, and the stand-in for columns where the chat is too narrow for them. */
    get bars() {
        return this.points.map((point, index) => {
            const picked = point.label === this.spec.highlight;
            const share = Math.max(point.value > 0 ? 1.5 : 0, (point.value / this.max) * 100);
            return {
                key: `bar-${index}`,
                label: point.label,
                display: this.format.full(point.value),
                className: this.barClass('c-bar', picked),
                fillStyle: `width: ${share.toFixed(2)}%`
            };
        });
    }

    /** A few columns, or a ring and its legend, leave half of a wide card empty, so the card is sized to them. */
    get chartStyle() {
        if (this.isColumn) {
            return `max-width: ${Math.max(20, this.points.length * COLUMN_REM + 2.5)}rem`;
        }
        return this.isDonut ? `max-width: ${DONUT_REM}rem` : undefined;
    }

    get barsClass() {
        return this.isColumn ? 'c-bars c-bars_fallback' : 'c-bars';
    }

    get showBars() {
        return this.isBar || this.isColumn;
    }

    get columns() {
        return this.points.map((point, index) => {
            const picked = point.label === this.spec.highlight;
            const share = Math.max(point.value > 0 ? 1.5 : 0, (point.value / this.max) * 100);
            return {
                key: `column-${index}`,
                label: point.label,
                display: this.format.short(point.value),
                className: this.barClass('c-column', picked),
                fillStyle: `height: ${share.toFixed(2)}%`
            };
        });
    }

    barClass(base, picked) {
        return `${base}${this.hasHighlight ? (picked ? ` ${base}_picked` : ` ${base}_quiet`) : ''}`;
    }

    // ---------- Line ----------

    /** Each point's place in the plot, as percentages from the left and the top. */
    get linePlaces() {
        const values = this.points.map((point) => point.value);
        const highest = Math.max(...values);
        const lowest = Math.min(...values);
        // Start from zero unless the values sit well above it, where a zero base would flatten the trend.
        const floor = lowest >= 0 && lowest <= highest / 2 ? 0 : lowest - (highest - lowest) * 0.15;
        const range = highest - floor || 1;
        const peak = values.indexOf(highest);
        const step = Math.ceil(this.points.length / MAX_LINE_LABELS);
        const last = this.points.length - 1;
        return this.points.map((point, index) => {
            const picked = point.label === this.spec.highlight;
            const showValue = this.points.length <= MAX_LINE_VALUES || picked || index === 0 || index === last || index === peak;
            return {
                key: `dot-${index}`,
                label: point.label,
                // Counted back from the latest point, so that one is always named.
                showLabel: (last - index) % step === 0,
                display: this.format.short(point.value),
                showValue,
                x: ((index + 0.5) / this.points.length) * 100,
                y: LINE_TOP + (1 - (point.value - floor) / range) * LINE_SPAN,
                picked
            };
        });
    }

    get dots() {
        return this.linePlaces.map((place) => ({
            ...place,
            className: `c-line__dot${place.picked ? ' c-line__dot_picked' : ''}`,
            style: `left: ${place.x.toFixed(2)}%; top: ${place.y.toFixed(2)}%`
        }));
    }

    get linePath() {
        return this.linePlaces.map((place) => `${place.x.toFixed(2)},${place.y.toFixed(2)}`).join(' ');
    }

    get areaPath() {
        const places = this.linePlaces;
        return places.length ? `${places[0].x.toFixed(2)},100 ${this.linePath} ${places[places.length - 1].x.toFixed(2)},100` : '';
    }

    get lineLabelsStyle() {
        return `grid-template-columns: repeat(${this.points.length}, minmax(0, 1fr))`;
    }

    // ---------- Donut ----------

    get total() {
        return this.points.reduce((sum, point) => sum + point.value, 0);
    }

    get slices() {
        const whole = this.total || 1;
        const gap = this.points.length > 1 ? 0.7 : 0;
        const share = number({ maximumFractionDigits: 0 });
        let before = 0;
        return this.points.map((point, index) => {
            const percent = (point.value / whole) * 100;
            const slice = {
                key: `slice-${index}`,
                label: point.label,
                display: this.format.full(point.value),
                share: `${share.format(percent)}%`,
                color: SLICE_COLORS[index % SLICE_COLORS.length],
                swatchStyle: `background: ${SLICE_COLORS[index % SLICE_COLORS.length]}`,
                dash: `${Math.max(percent - gap, 0).toFixed(3)} ${(100 - Math.max(percent - gap, 0)).toFixed(3)}`,
                // The ring starts at twelve o'clock.
                offset: (25 - before).toFixed(3),
                className: `c-legend__row${point.label === this.spec.highlight ? ' c-legend__row_picked' : ''}`
            };
            before += percent;
            return slice;
        });
    }

    /** The sum in the middle of the ring. Percentages add up to nothing worth showing. */
    get showTotal() {
        return this.spec?.unit !== 'percent';
    }

    get totalDisplay() {
        return this.format.short(this.total);
    }
    // ---------- Compact, for the utility panel ----------

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }

    handleToggle() {
        this.showAll = !this.showAll;
    }

    get expandLabel() {
        return `Expand ${this.spec?.title ?? 'the chart'}`;
    }

    /** Columns have room in the panel as slim bars without labels, however many there are. */
    get isMiniColumn() {
        return this.wantsColumns;
    }

    get isMiniBar() {
        return this.spec?.chartType === 'bar';
    }

    /** The label sits over its bar so the bar gets the card's full width. */
    get miniBars() {
        const bars = this.bars;
        if (this.showAll || bars.length <= MINI_BARS) {
            return bars;
        }
        const picked = this.points.findIndex((point) => point.label === this.spec.highlight);
        // The highlighted row is kept even when it falls outside the first few.
        return picked >= MINI_BARS ? [...bars.slice(0, MINI_BARS - 1), bars[picked]] : bars.slice(0, MINI_BARS);
    }

    get hasMoreBars() {
        return this.bars.length > MINI_BARS;
    }

    get moreBarsLabel() {
        return this.showAll ? `Show top ${MINI_BARS}` : `Show all ${this.bars.length}`;
    }

    get miniColumns() {
        return this.points.map((point, index) => {
            const picked = point.label === this.spec.highlight;
            const share = Math.max(point.value > 0 ? 2 : 0, (point.value / this.max) * 100);
            return {
                key: `mini-column-${index}`,
                className: this.barClass('c-mini-column', picked),
                fillStyle: `height: ${share.toFixed(2)}%`
            };
        });
    }

    get miniDots() {
        return this.linePlaces.map((place) => {
            const y = MINI_LINE_TOP + ((place.y - LINE_TOP) / LINE_SPAN) * MINI_LINE_SPAN;
            return { key: `mini-${place.key}`, x: place.x, y, className: `c-line__dot${place.picked ? ' c-line__dot_picked' : ''}`, style: `left: ${place.x.toFixed(2)}%; top: ${y.toFixed(2)}%` };
        });
    }

    get miniLinePath() {
        return this.miniDots.map((dot) => `${dot.x.toFixed(2)},${dot.y.toFixed(2)}`).join(' ');
    }

    get miniAreaPath() {
        const dots = this.miniDots;
        return dots.length ? `${dots[0].x.toFixed(2)},100 ${this.miniLinePath} ${dots[dots.length - 1].x.toFixed(2)},100` : '';
    }

    /**
     * The only points a compact line or column chart names: the first, the last, and the one Claude
     * picked out (or the highest, when it picked none), each with its value.
     */
    get miniStats() {
        const points = this.points;
        if (!points.length) {
            return [];
        }
        const last = points.length - 1;
        let middle = points.findIndex((point) => point.label === this.spec.highlight);
        if (middle < 0) {
            middle = points.reduce((best, point, index) => (point.value > points[best].value ? index : best), 0);
        }
        const picks = [...new Set([0, middle, last])].sort((a, b) => a - b);
        return picks.map((index) => ({
            key: `stat-${index}`,
            label: points[index].label,
            display: this.format.short(points[index].value),
            className: `c-mini-stat${index === middle ? ' c-mini-stat_picked' : ''}`
        }));
    }

    get hasMiniStats() {
        return this.isMiniColumn || this.isLine;
    }

    get miniStatsStyle() {
        return `grid-template-columns: repeat(${this.miniStats.length}, minmax(0, 1fr))`;
    }

    /** A donut becomes one bar cut into its shares. */
    get segments() {
        return this.slices.map((slice, index) => ({
            ...slice,
            key: `segment-${index}`,
            style: `flex-grow: ${Math.max(this.points[index].value, 0)}; background: ${slice.color}`
        }));
    }

    get totalFull() {
        return this.format.full(this.total);
    }
}
