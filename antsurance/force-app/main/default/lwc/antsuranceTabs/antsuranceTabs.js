import { LightningElement, api } from 'lwc';

const MOVES = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };

/**
 * A row of tabs for the peer sections of one thing, such as the parts of a report. It draws the tabs
 * only; the parent shows the section that is chosen:
 *
 *   <c-antsurance-tabs label="Sections of the report" tabs={tabs} value={tab} onselect={handleTab}></c-antsurance-tabs>
 *   <div role="tabpanel" aria-label="Damage" lwc:if={showsDamage}>...</div>
 *
 * `tabs` is a list of `{ value, label, count, tone, icon, title }`. Only `value` and `label` are
 * needed. `count` shows how much is behind a tab; `tone: 'watch'` tints that count amber when the
 * section holds something to look at. `select` carries `detail.value`.
 *
 * Keyboard: Tab reaches the chosen tab; Left and Right (or Up and Down) move to and choose its
 * neighbors; Home and End go to the first and last. It hides itself in print, where the parent
 * prints every section.
 */
export default class AntsuranceTabs extends LightningElement {
    /** What the tabs are sections of, for screen readers. */
    @api label = 'Sections';
    /** `{ value, label, count, tone, icon, title }` for each tab, in order. */
    @api tabs = [];
    /** The chosen tab's value. The first tab when unset. */
    @api value;
    /** `line` (an underline, the default) or `pill` (a segmented control, for a small space). */
    @api
    get variant() {
        return this.chosenVariant;
    }
    set variant(value) {
        this.chosenVariant = value;
        // The stylesheet sizes the two differently: a row fills its parent, a segmented control is as wide as its tabs.
        this.classList.toggle('c-host_pill', value === 'pill');
    }

    chosenVariant = 'line';

    focusNext = false;

    get chosen() {
        const list = this.tabs ?? [];
        return list.some((tab) => tab.value === this.value) ? this.value : list[0]?.value;
    }

    get stripClass() {
        return this.variant === 'pill' ? 'c-tabs c-tabs_pill' : 'c-tabs';
    }

    get rows() {
        const chosen = this.chosen;
        return (this.tabs ?? []).map((tab) => {
            const selected = tab.value === chosen;
            const hasCount = tab.count !== undefined && tab.count !== null && tab.count !== '';
            return {
                ...tab,
                selected: selected ? 'true' : 'false',
                tabIndex: selected ? 0 : -1,
                className: `c-tab c-ui-focus${selected ? ' c-tab_on' : ''}`,
                hasCount,
                countClass: `c-tab__count${tab.tone === 'watch' ? ' c-tab__count_watch' : ''}`
            };
        });
    }

    renderedCallback() {
        if (this.focusNext) {
            this.focusNext = false;
            const chosen = this.template.querySelector('.c-tab_on');
            chosen?.focus();
            chosen?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
        }
    }

    handleClick(event) {
        this.choose(event.currentTarget.dataset.value);
    }

    handleKey(event) {
        const list = this.tabs ?? [];
        const at = list.findIndex((tab) => tab.value === this.chosen);
        let to;
        if (MOVES[event.key]) {
            to = (at + MOVES[event.key] + list.length) % list.length;
        } else if (event.key === 'Home') {
            to = 0;
        } else if (event.key === 'End') {
            to = list.length - 1;
        }
        if (to === undefined || !list[to]) {
            return;
        }
        event.preventDefault();
        this.focusNext = true;
        this.choose(list[to].value);
    }

    choose(value) {
        if (value !== this.chosen) {
            this.dispatchEvent(new CustomEvent('select', { detail: { value } }));
        } else if (this.focusNext) {
            // Nothing will re-render, so move the focus now.
            this.renderedCallback();
        }
    }
}
