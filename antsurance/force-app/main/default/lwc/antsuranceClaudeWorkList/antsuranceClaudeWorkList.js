import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// A row's marker takes the strongest tone among its chips.
const TONE_RANK = { alert: 3, watch: 2, good: 1, neutral: 0 };
// The most rows one page of the list shows: in the utility panel, and at full size. A longer list is
// stepped through with previous and next, in pages of equal length, so the conversation does not grow.
// At full size a row is three lines (what, who, why), so five of them is already most of a screen.
const MINI_ITEMS = 5;
const FULL_ITEMS = 5;

/** Rows per page so that `count` rows fall into the fewest pages of at most `most`, about equal in length. */
function pageSizeFor(count, most) {
    return count > most ? Math.ceil(count / Math.ceil(count / most)) : most;
}

/** Things to act on: each row says what it is, who it concerns and why it is on the list. */
export default class AntsuranceClaudeWorkList extends NavigationMixin(LightningElement) {
    /** { title, items: [{ title, subtitle, recordId, amount, chips: [{ label, tone }] }] } */
    @api spec;
    /** True in the utility bar panel: one dense row per item, a few to a page. */
    @api compact = false;

    page = 0;

    get items() {
        return (this.spec?.items ?? []).map((item, index) => {
            const tone = item.chips.reduce((strongest, chip) => (TONE_RANK[chip.tone] > TONE_RANK[strongest] ? chip.tone : strongest), 'neutral');
            return {
                ...item,
                key: `item-${index}`,
                url: item.recordId ? `/lightning/r/${item.recordId}/view` : undefined,
                className: `c-item c-item_${tone}`,
                chips: item.chips.map((chip, chipIndex) => ({ ...chip, key: `item-${index}-chip-${chipIndex}`, className: `c-chip c-chip_${chip.tone}` })),
                hasChips: item.chips.length > 0,
                // The compact row has room for one chip: the one that says why the item is on the list.
                topChip: this.topChip(item.chips)
            };
        });
    }

    topChip(chips) {
        if (!chips.length) {
            return undefined;
        }
        const top = chips.reduce((strongest, chip) => (TONE_RANK[chip.tone] > TONE_RANK[strongest.tone] ? chip : strongest), chips[0]);
        return { label: top.label, className: `c-chip c-chip_${top.tone}` };
    }

    get total() {
        return this.spec?.items?.length ?? 0;
    }

    get pageSize() {
        return pageSizeFor(this.total, this.compact ? MINI_ITEMS : FULL_ITEMS);
    }

    /** The rows on the page being shown. */
    get pageItems() {
        const first = this.page * this.pageSize;
        return this.items.slice(first, first + this.pageSize);
    }

    get isPaged() {
        return this.total > this.pageSize;
    }

    handlePage(event) {
        this.page = event.detail.page;
    }

    get expandLabel() {
        return `Expand ${this.spec?.title ?? 'the list'}`;
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }

    get countLabel() {
        const count = this.items.length;
        return count === 1 ? '1 item' : `${count} items`;
    }

    handleOpen(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }
}
