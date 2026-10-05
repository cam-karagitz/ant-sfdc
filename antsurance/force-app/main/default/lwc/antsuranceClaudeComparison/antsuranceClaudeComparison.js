import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// In the utility panel a long comparison shows only the rows that differ until the user asks for the rest.
const MINI_ROWS = 6;

/** Two to four options side by side on the same rows, with the recommended one marked. */
export default class AntsuranceClaudeComparison extends NavigationMixin(LightningElement) {
    /** { title, columns: [{ name, recordId, recommended }], rows: [{ label, values: [] }], reason } */
    @api spec;
    /** True in the utility bar panel: two options in one table, never stacked. */
    @api compact = false;

    // Compact: which option sits beside the recommended one, and whether rows that match are showing.
    otherIndex;
    showSame = false;

    get options() {
        const rows = this.spec?.rows ?? [];
        return (this.spec?.columns ?? []).map((column, index) => ({
            ...column,
            key: `option-${index}`,
            className: `c-option${column.recommended ? ' c-option_recommended' : ''}`,
            url: column.recordId ? `/lightning/r/${column.recordId}/view` : undefined,
            cells: rows.map((row, rowIndex) => ({ key: `option-${index}-row-${rowIndex}`, label: row.label, value: row.values[index] }))
        }));
    }

    /** The grid's size, read by the stylesheet: one column per option, one row per compared fact plus the name. */
    get gridStyle() {
        return `--c-options: ${this.options.length}; --c-rows: ${(this.spec?.rows ?? []).length + 1}`;
    }

    get recommendedName() {
        return this.options.find((option) => option.recommended)?.name;
    }

    get hasReason() {
        return Boolean(this.spec?.reason && this.recommendedName);
    }

    get reasonLead() {
        return `Why ${this.recommendedName}`;
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

    // ---------- Compact, for the utility panel ----------

    /** The option every other is set against: the recommended one, or the first. */
    get leadIndex() {
        const recommended = (this.spec?.columns ?? []).findIndex((column) => column.recommended);
        return recommended < 0 ? 0 : recommended;
    }

    get shownOtherIndex() {
        const count = (this.spec?.columns ?? []).length;
        const fallback = this.leadIndex === 0 ? 1 : 0;
        return this.otherIndex !== undefined && this.otherIndex < count && this.otherIndex !== this.leadIndex ? this.otherIndex : fallback;
    }

    get pair() {
        return [this.leadIndex, this.shownOtherIndex]
            .map((index) => this.options[index])
            .filter(Boolean)
            .map((option) => ({ ...option, headClass: option.recommended ? 'c-pair__head c-pair__head_recommended' : 'c-pair__head' }));
    }

    /** With three or four options, the ones that can sit beside the lead option. */
    get hasSwitch() {
        return this.options.length > 2;
    }

    get switchLabel() {
        return `Compare ${this.options[this.leadIndex]?.name} with`;
    }

    get choices() {
        return this.options
            .map((option, index) => ({ option, index }))
            .filter(({ index }) => index !== this.leadIndex)
            .map(({ option, index }) => ({
                key: `choice-${index}`,
                index,
                name: option.name,
                pressed: index === this.shownOtherIndex ? 'true' : 'false',
                className: `c-switch__choice${index === this.shownOtherIndex ? ' c-switch__choice_on' : ''}`
            }));
    }

    get allPairRows() {
        const [lead, other] = [this.leadIndex, this.shownOtherIndex];
        return (this.spec?.rows ?? []).map((row, index) => {
            const differs = row.values[lead] !== row.values[other];
            return {
                key: `pair-row-${index}`,
                label: row.label,
                lead: row.values[lead],
                other: row.values[other],
                differs,
                className: differs ? 'c-pair__row c-pair__row_differs' : 'c-pair__row'
            };
        });
    }

    /** A long comparison leads with what differs; a short one shows every row in its own order. */
    get trimsRows() {
        const rows = this.allPairRows;
        return rows.length > MINI_ROWS && rows.some((row) => row.differs) && rows.some((row) => !row.differs);
    }

    get pairRows() {
        return this.trimsRows && !this.showSame ? this.allPairRows.filter((row) => row.differs) : this.allPairRows;
    }

    get sameLabel() {
        const same = this.allPairRows.filter((row) => !row.differs).length;
        const rows = same === 1 ? '1 matching row' : `${same} matching rows`;
        return this.showSame ? `Hide ${rows}` : `Show ${rows}`;
    }

    get expandLabel() {
        return `Expand ${this.spec?.title ?? 'the comparison'}`;
    }

    handleChoice(event) {
        this.otherIndex = Number(event.currentTarget.dataset.index);
    }

    handleToggle() {
        this.showSame = !this.showSame;
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }
}
