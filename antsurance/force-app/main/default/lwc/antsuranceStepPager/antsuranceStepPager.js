import { LightningElement, api } from 'lwc';

/**
 * A previous and next pager for a list inside a component, so a long list is stepped through and
 * never scrolled: it says where the reader is ("1 to 6 of 23") and draws nothing when everything
 * fits on one page. The parent keeps the page and slices its rows:
 *
 *   <c-antsurance-step-pager total={rows.length} page-size="6" page={page} label="overdue tasks" onpagechange={handlePage}>
 *
 * `pagechange` carries `detail.page`, counted from 0.
 */
export default class AntsuranceStepPager extends LightningElement {
    /** How many rows there are in all. */
    @api total = 0;
    /** How many rows one page shows. */
    @api pageSize = 6;
    /** The page being shown, counted from 0. */
    @api page = 0;
    /** What is being paged, in lower case, for screen readers: "overdue tasks", "file notes". */
    @api label = 'rows';

    get size() {
        return Math.max(1, Number(this.pageSize) || 1);
    }

    get count() {
        return Number(this.total) || 0;
    }

    get lastPage() {
        return Math.max(0, Math.ceil(this.count / this.size) - 1);
    }

    get current() {
        return Math.min(Math.max(0, Number(this.page) || 0), this.lastPage);
    }

    get isNeeded() {
        return this.count > this.size;
    }

    get isFirst() {
        return this.current === 0;
    }

    get isLast() {
        return this.current === this.lastPage;
    }

    get rangeLabel() {
        const first = this.current * this.size + 1;
        const last = Math.min(this.count, first + this.size - 1);
        return first === last ? `${first} of ${this.count}` : `${first} to ${last} of ${this.count}`;
    }

    get navLabel() {
        return `Pages of ${this.label}`;
    }

    get previousLabel() {
        return `Previous ${this.label}`;
    }

    get nextLabel() {
        return `Next ${this.label}`;
    }

    handlePrevious() {
        this.go(this.current - 1);
    }

    handleNext() {
        this.go(this.current + 1);
    }

    go(page) {
        this.dispatchEvent(new CustomEvent('pagechange', { detail: { page: Math.min(Math.max(0, page), this.lastPage) } }));
    }
}
