import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { getRecord } from 'lightning/uiRecordApi';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { refreshApex } from '@salesforce/apex';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { coverageGroup, coverageIcon, basisWords } from 'c/antsuranceIcons';
import { tidyEnding } from 'c/antsuranceText';

const RELATED_LIST = 'Coverages__r';
const CHILD = 'Policy_Coverage__c';
const FIELDS = ['Name', 'Category__c', 'Limit_Amount__c', 'Limit_Type__c', 'Deductible_Amount__c', 'Premium_Amount__c', 'What_Is_Covered__c', 'Status__c'].map(
    (name) => `${CHILD}.${name}`
);
const WHOLE = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
// How a limit reads when it is a basis and not an amount.
const BASIS_AS_LIMIT = { 'Actual Cash Value': 'Actual cash value', Statutory: 'Statutory', 'Replacement Cost': 'Replacement cost' };

// After New opens there is no signal when it is saved, so the list looks again a few times.
const RECHECKS_AFTER_NEW = 10;
const RECHECK_EVERY_MS = 4000;

function money(amount) {
    return `$${WHOLE.format(Math.round(Number(amount)))}`;
}

/**
 * The coverages on a policy, which are the heart of the record: one dense row each, grouped by what
 * they protect, so an underwriter sees all of them on one screen and a newcomer can read them.
 * Reads the policy's coverages through Lightning Data Service, as the related list does.
 *
 * On a policy's own page it needs no setting. On the page of something that belongs to a policy
 * (a coverage, an insured asset), set `parentField` to that record's lookup to the policy: the card
 * then shows that policy's coverages, with the one being viewed marked, so the page says where the
 * record sits and lets the reader step to its neighbours.
 */
export default class AntsurancePolicyCoverages extends NavigationMixin(LightningElement) {
    @api
    get recordId() {
        return this.pageRecordId;
    }
    set recordId(value) {
        this.pageRecordId = value;
        this.resolve();
    }
    pageRecordId;
    @api
    get objectApiName() {
        return this.pageObject;
    }
    set objectApiName(value) {
        this.pageObject = value;
        this.resolve();
    }
    pageObject;
    /** The page record's lookup to its policy ("Policy__c"), when the page is not the policy's own. */
    @api
    get parentField() {
        return this.lookupName;
    }
    set parentField(value) {
        this.lookupName = value;
        this.resolve();
    }
    lookupName;
    /** How many coverages to show at a time; the rest are stepped to. Leave empty to show them all, as a policy's own page does. */
    @api rows;
    page = 0;
    // The policy whose coverages are shown, and what the lookup wire is asked for.
    policyId;
    lookupFields;
    records;
    recordsResult;
    errorMessage;
    recheckTimer;
    rechecksLeft = 0;

    connectedCallback() {
        loadBrandFonts(this);
    }

    disconnectedCallback() {
        this.stopRechecking();
    }

    /** Works out which policy to show: the page's own record, or the one its lookup points at. */
    resolve() {
        if (!this.lookupName) {
            this.lookupFields = undefined;
            this.policyId = this.pageRecordId;
        } else if (this.pageObject) {
            this.lookupFields = [`${this.pageObject}.${this.lookupName}`];
        }
    }

    @wire(getRecord, { recordId: '$pageRecordId', fields: '$lookupFields' })
    wiredParent({ data }) {
        if (data && this.lookupName) {
            this.policyId = data.fields[this.lookupName]?.value;
        }
    }

    get onPolicyPage() {
        return !this.lookupName;
    }

    get title() {
        return this.onPolicyPage ? 'Coverages' : 'Coverages on this policy';
    }

    @wire(getRelatedListRecords, { parentRecordId: '$policyId', relatedListId: RELATED_LIST, fields: FIELDS, sortBy: [`-${CHILD}.Premium_Amount__c`], pageSize: 30 })
    wiredCoverages(result) {
        this.recordsResult = result;
        if (result.data) {
            this.records = result.data.records;
            this.errorMessage = undefined;
        } else if (result.error) {
            const body = result.error.body;
            this.errorMessage = (Array.isArray(body) ? body[0]?.message : body?.message) ?? 'The coverages could not be loaded.';
        }
    }

    get isLoading() {
        return !this.records && !this.errorMessage;
    }

    get isEmpty() {
        return Boolean(this.records) && this.records.length === 0;
    }

    get hasRows() {
        return this.records?.length > 0;
    }

    get countLabel() {
        return this.records ? String(this.records.length) : '';
    }

    get totalPremium() {
        return (this.records ?? []).reduce((sum, record) => sum + (Number(record.fields.Premium_Amount__c?.value) || 0), 0);
    }

    /** "$2,380 a year", beside the title. */
    get summary() {
        const total = this.totalPremium;
        return total > 0 ? `${money(total)} a year` : '';
    }

    /** How many rows one page holds, or 0 when the card shows every coverage. */
    get pageSize() {
        const size = Math.floor(Number(this.rows));
        return size > 0 ? size : 0;
    }

    get rowCount() {
        return this.records?.length ?? 0;
    }

    get isPaged() {
        return this.pageSize > 0 && this.rowCount > this.pageSize;
    }

    handlePage(event) {
        this.page = event.detail.page;
    }

    get skeletonRows() {
        return [1, 2, 3, 4].map((key) => ({ key }));
    }

    get viewAllUrl() {
        return `/lightning/r/Policy__c/${this.policyId}/related/${RELATED_LIST}/view`;
    }

    /**
     * The coverages as rows under the heading of what each protects, the groups in a fixed order.
     * When the card shows a few at a time, a page is cut from that same order, so stepping walks
     * through the groups and a group that runs over a page carries its heading onto the next.
     */
    get groups() {
        const groups = this.allGroups;
        if (!this.isPaged) {
            return groups;
        }
        const lastPage = Math.ceil(this.rowCount / this.pageSize) - 1;
        const first = Math.min(Math.max(0, this.page), lastPage) * this.pageSize;
        let passed = 0;
        return groups
            .map((group) => {
                const rows = group.rows.slice(Math.max(0, first - passed), Math.max(0, first + this.pageSize - passed));
                passed += group.rows.length;
                return { ...group, rows };
            })
            .filter((group) => group.rows.length > 0);
    }

    get allGroups() {
        const total = this.totalPremium;
        const byGroup = new Map();
        (this.records ?? []).forEach((record) => {
            const value = (name) => record.fields[name]?.value;
            const name = value('Name');
            const group = coverageGroup(name, value('Category__c'));
            const icon = coverageIcon(name, value('Category__c'));
            const limit = value('Limit_Amount__c');
            const limitType = value('Limit_Type__c');
            const deductible = value('Deductible_Amount__c');
            const premium = Number(value('Premium_Amount__c')) || 0;
            const share = total > 0 ? Math.round((premium / total) * 100) : 0;
            const isCurrent = record.id === this.pageRecordId;
            const row = {
                id: record.id,
                isCurrent,
                // The coverage whose page this is stays put when clicked, and says which one it is.
                className: isCurrent ? 'c-cov__row c-cov__row_current' : 'c-cov__row c-ui-open',
                name,
                url: `/lightning/r/${record.id}/view`,
                iconName: icon.name,
                tileClass: icon.tileClass,
                // The stored text marks its exclusions in bold; here it is one plain line.
                // The last three words stay together, so the line never ends on "are excluded." by itself.
                covers: tidyEnding((value('What_Is_Covered__c') ?? '').replace(/\*\*/g, '')),
                limit: limit !== null && limit !== undefined ? money(limit) : (BASIS_AS_LIMIT[limitType] ?? 'Not set'),
                // With an amount, how it applies follows in words; without one, the basis is the limit.
                basis: limit !== null && limit !== undefined ? basisWords(limitType) : '',
                deductible: deductible !== null && deductible !== undefined ? money(deductible) : 'None',
                deductibleClass: deductible !== null && deductible !== undefined ? 'c-cov__figure' : 'c-cov__figure c-cov__figure_none',
                // Said beside the limit when the list is too narrow for a Deductible column.
                deductibleFold: deductible !== null && deductible !== undefined ? `${money(deductible)} deductible` : 'no deductible',
                premium: premium > 0 ? money(premium) : '',
                shareLabel: `${share}% of the premium`,
                shareStyle: `width: ${Math.max(share, 2)}%`,
                // A coverage that is not active says so beside its name; an active one needs no chip.
                showStatus: Boolean(value('Status__c')) && value('Status__c') !== 'Active',
                status: value('Status__c')
            };
            if (!byGroup.has(group.key)) {
                byGroup.set(group.key, { key: group.key, label: group.label, order: group.order, rows: [] });
            }
            byGroup.get(group.key).rows.push(row);
        });
        return [...byGroup.values()].sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));
    }

    handleOpen(event) {
        // The link keeps its address for "open in a new tab"; a plain click stays inside the app.
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        this.open(event.currentTarget.dataset.recordId);
    }

    /** A click anywhere on a row opens it; a click on the link inside is left to the link. */
    handleRowClick(event) {
        if (event.target.closest('a') || event.metaKey || event.ctrlKey || event.shiftKey || event.currentTarget.dataset.recordId === this.pageRecordId) {
            return;
        }
        this.open(event.currentTarget.dataset.recordId);
    }

    open(recordId) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
    }

    handleViewAll(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: { recordId: this.policyId, objectApiName: 'Policy__c', relationshipApiName: RELATED_LIST, actionName: 'view' }
        });
    }

    handleNew() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: CHILD, actionName: 'new' },
            state: { defaultFieldValues: encodeDefaultFieldValues({ Policy__c: this.policyId }), navigationLocation: 'RELATED_LIST' }
        });
        this.stopRechecking();
        this.rechecksLeft = RECHECKS_AFTER_NEW;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.recheckTimer = setInterval(() => {
            this.rechecksLeft -= 1;
            this.refresh();
            if (this.rechecksLeft <= 0) {
                this.stopRechecking();
            }
        }, RECHECK_EVERY_MS);
    }

    /** Asks for the coverages again. Pages call this after an action that adds or changes one. */
    @api
    async refresh() {
        try {
            if (this.recordsResult) {
                await refreshApex(this.recordsResult);
            }
        } catch (error) {
            // The rows on screen stay as they are; the next visit to the page reads them fresh.
        }
    }

    stopRechecking() {
        if (this.recheckTimer) {
            clearInterval(this.recheckTimer);
            this.recheckTimer = undefined;
        }
    }
}
