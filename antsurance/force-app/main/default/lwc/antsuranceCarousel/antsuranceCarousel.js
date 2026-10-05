import { LightningElement, api } from 'lwc';

/**
 * Shows things one at a time, or a few at a time, in a row that steps sideways: photos, option cards,
 * tiles. Put the things straight inside it; each child is one slide.
 *
 *   <c-antsurance-carousel label="Photos on this claim" per-view="1" onslidechange={handleSlide}>
 *       <img src={one.url} alt={one.alt} />
 *       <img src={two.url} alt={two.alt} />
 *   </c-antsurance-carousel>
 *
 * `per-view` is how many slides show at once (1 to 6); with `item-min-width` (pixels) fewer show
 * where the row is too narrow for that many. It draws previous and next buttons, a count
 * ("2 of 5", or "1 to 3 of 7") and dots, and none of them when everything fits. Left and Right move
 * it while the row has the focus, a swipe moves it on a touch screen, and `slidechange` carries
 * `detail.index` (the first slide in view, from 0) and `detail.count`. In print every slide shows.
 */
export default class AntsuranceCarousel extends LightningElement {
    /** What the slides are, for screen readers: "Photos on this claim". */
    @api label = 'Slides';
    /** How many slides show at once. */
    @api perView = 1;
    /** The space between slides, as a CSS length. */
    @api gap = '0.75rem';
    /** The narrowest a slide may be, in pixels. When set, fewer than `per-view` show where there is no room for them all. */
    @api itemMinWidth;

    count = 0;
    index = 0;
    settle;
    // How many slides there is room for, when `item-min-width` is set.
    room;
    watcher;

    get shown() {
        const asked = Math.min(6, Math.max(1, Number(this.perView) || 1));
        const fits = Math.min(asked, this.room ?? asked);
        // Never more columns than slides, so two tiles share the row instead of leaving a third of it empty.
        return Math.max(1, Math.min(fits, this.count || fits));
    }

    get lastIndex() {
        return Math.max(0, this.count - this.shown);
    }

    get isNeeded() {
        return this.count > this.shown;
    }

    get isFirst() {
        return this.index <= 0;
    }

    get isLast() {
        return this.index >= this.lastIndex;
    }

    get countLabel() {
        const first = this.index + 1;
        const last = Math.min(this.count, this.index + this.shown);
        return first === last ? `${first} of ${this.count}` : `${first} to ${last} of ${this.count}`;
    }

    /** One dot per position the row can rest at, while there are few enough to take in. */
    get dots() {
        const stops = Math.ceil(this.count / this.shown);
        if (stops < 2 || stops > 8) {
            return [];
        }
        const at = Math.min(stops - 1, Math.round(this.index / this.shown));
        return Array.from({ length: stops }, (unused, stop) => ({
            key: stop,
            index: Math.min(stop * this.shown, this.lastIndex),
            label: `Show ${stop + 1} of ${stops}`,
            current: stop === at ? 'true' : 'false',
            className: `c-car__dot c-ui-focus${stop === at ? ' c-car__dot_on' : ''}`
        }));
    }

    get hasDots() {
        return this.dots.length > 0;
    }

    get previousLabel() {
        return `Previous in ${this.label}`;
    }

    get nextLabel() {
        return `Next in ${this.label}`;
    }

    get slides() {
        return this.template.querySelector('slot')?.assignedElements?.() ?? [];
    }

    renderedCallback() {
        const track = this.refs.track;
        if (this.watcher || !track || !Number(this.itemMinWidth) || typeof ResizeObserver === 'undefined') {
            return;
        }
        this.watcher = new ResizeObserver(() => this.measure());
        this.watcher.observe(track);
    }

    disconnectedCallback() {
        clearTimeout(this.settle);
        this.watcher?.disconnect();
        this.watcher = undefined;
    }

    /** Works out how many slides of at least `item-min-width` fit across the row. */
    measure() {
        const track = this.refs.track;
        const least = Number(this.itemMinWidth);
        if (!track || !least) {
            return;
        }
        const gap = parseFloat(getComputedStyle(track).columnGap) || 0;
        const room = Math.max(1, Math.floor((track.clientWidth + gap) / (least + gap)));
        if (room !== this.room) {
            this.room = room;
            this.layout();
        }
    }

    handleSlotChange() {
        this.count = this.slides.length;
        this.layout();
    }

    layout() {
        const slides = this.slides;
        const shown = this.shown;
        const track = this.refs.track;
        if (track) {
            track.style.gap = this.gap;
        }
        slides.forEach((slide, at) => {
            // Each slide takes an equal share of the row and snaps to its start.
            slide.style.flex = `0 0 calc((100% - ${shown - 1} * ${this.gap}) / ${shown})`;
            slide.style.minWidth = '0';
            slide.style.scrollSnapAlign = 'start';
            slide.setAttribute('role', 'group');
            slide.setAttribute('aria-roledescription', 'slide');
            if (!slide.hasAttribute('aria-label')) {
                slide.setAttribute('aria-label', `${at + 1} of ${slides.length}`);
            }
        });
        if (this.index > this.lastIndex) {
            this.index = this.lastIndex;
        }
    }

    /** Moves to a slide. Also for a parent: `this.refs.carousel.show(2)`. */
    @api
    show(index) {
        const to = Math.min(Math.max(0, Number(index) || 0), this.lastIndex);
        const slide = this.slides[to];
        const track = this.refs.track;
        if (!slide || !track) {
            return;
        }
        // Where the slide starts, measured from the row's own first slide, so padding and what holds the row do not matter.
        const first = this.slides[0].getBoundingClientRect().left;
        // It steps straight there. A glide can be cut short by the next press and leave the row between two slides.
        track.scrollTo({ left: slide.getBoundingClientRect().left - first, behavior: 'auto' });
        this.arrive(to);
    }

    arrive(index) {
        if (index !== this.index) {
            this.index = index;
            this.dispatchEvent(new CustomEvent('slidechange', { detail: { index, count: this.count } }));
        }
    }

    handlePrevious() {
        this.show(this.index - this.shown);
    }

    handleNext() {
        this.show(this.index + this.shown);
    }

    handleDot(event) {
        this.show(Number(event.currentTarget.dataset.index));
    }

    handleKey(event) {
        if (event.key === 'ArrowRight') {
            event.preventDefault();
            this.show(this.index + 1);
        } else if (event.key === 'ArrowLeft') {
            event.preventDefault();
            this.show(this.index - 1);
        } else if (event.key === 'Home') {
            event.preventDefault();
            this.show(0);
        } else if (event.key === 'End') {
            event.preventDefault();
            this.show(this.lastIndex);
        }
    }

    /** After a swipe or a drag of the row, works out which slide it came to rest on. */
    handleScroll() {
        clearTimeout(this.settle);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.settle = setTimeout(() => {
            const track = this.refs.track;
            if (!track) {
                return;
            }
            const edge = track.getBoundingClientRect().left;
            let nearest = 0;
            let distance = Infinity;
            this.slides.forEach((slide, at) => {
                const away = Math.abs(slide.getBoundingClientRect().left - edge);
                if (away < distance) {
                    distance = away;
                    nearest = at;
                }
            });
            this.arrive(Math.min(nearest, this.lastIndex));
        }, 120);
    }
}
