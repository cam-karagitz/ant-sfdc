import { LightningElement, api } from 'lwc';

/**
 * One section that folds: a summary line that is always in view, and the detail under it on a press.
 * Stack several for an accordion.
 *
 *   <c-antsurance-accordion label="What it rests on" count="5" summary="Policy term, coverage, deductible">
 *       ...the detail...
 *   </c-antsurance-accordion>
 *
 * `count` and `summary` say how much is behind the line before it is opened. `open` sets whether it
 * starts open, and the parent can set it again later; `toggle` carries `detail.open` after each press,
 * for a parent that wants to remember it or load the detail late. Enter and Space toggle it. The
 * detail always prints, open or not.
 */
export default class AntsuranceAccordion extends LightningElement {
    /** The section's name, always in view. */
    @api label;
    /** How many things are inside, shown as a small chip. */
    @api count;
    /** A short line saying what is inside, shown while the section is closed. */
    @api summary;
    /** A Lightning icon name to lead the line with, such as `utility:shield`. */
    @api icon;
    /** `plain` (a rule above, the default) or `card` (its own bordered box). */
    @api variant = 'plain';
    /** The heading level of the label for screen readers. */
    @api level = 3;

    isOpen = false;

    @api
    get open() {
        return this.isOpen;
    }
    set open(value) {
        this.isOpen = value === true || value === '' || value === 'true';
    }

    get sectionClass() {
        return `c-acc${this.variant === 'card' ? ' c-acc_card' : ''}${this.isOpen ? ' c-acc_open' : ''}`;
    }

    get expanded() {
        return this.isOpen ? 'true' : 'false';
    }

    get hasCount() {
        return this.count !== undefined && this.count !== null && this.count !== '';
    }

    get showSummary() {
        return Boolean(this.summary) && !this.isOpen;
    }

    handleToggle() {
        this.isOpen = !this.isOpen;
        this.dispatchEvent(new CustomEvent('toggle', { detail: { open: this.isOpen } }));
    }
}
