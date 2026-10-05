import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import NAME from '@salesforce/schema/Quote.Name';
import NUMBER from '@salesforce/schema/Quote.QuoteNumber';
import STATUS from '@salesforce/schema/Quote.Status';
import PREMIUM from '@salesforce/schema/Quote.Annual_Premium__c';
import LIMIT from '@salesforce/schema/Quote.Coverage_Limit__c';
import DEDUCTIBLE from '@salesforce/schema/Quote.Deductible__c';
import ISSUED from '@salesforce/schema/Quote.Issued_Date__c';
import EXPIRES from '@salesforce/schema/Quote.ExpirationDate';
import UNDERWRITER from '@salesforce/schema/Quote.Underwriter__c';
import SALE_ID from '@salesforce/schema/Quote.OpportunityId';
import SALE_NAME from '@salesforce/schema/Quote.Opportunity.Name';
import SALE_LINE from '@salesforce/schema/Quote.Opportunity.Line_of_Business__c';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const FIELDS = [NAME, NUMBER, STATUS, SALE_ID];
const OPTIONAL_FIELDS = [PREMIUM, LIMIT, DEDUCTIBLE, ISSUED, EXPIRES, UNDERWRITER, SALE_NAME, SALE_LINE];
const SIBLING_FIELDS = ['Quote.Name', 'Quote.Annual_Premium__c', 'Quote.Status'];
const MS_PER_DAY = 86400000;
const MONTHS = 12;
// A quote this close to expiring is worth chasing.
const EXPIRING_SOON_DAYS = 7;
const WAITING = ['Issued', 'Presented'];
const CHOSEN = ['Accepted', 'Bound'];

/**
 * One quote as an offer: what it costs, how that compares with the other options on the sale,
 * the terms and how long it stays valid.
 */
export default class AntsuranceQuoteSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    quote;
    siblings = [];
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredQuote({ data, error }) {
        if (data) {
            const money = (field, blank) => {
                const amount = getFieldValue(data, field);
                return amount === null || amount === undefined
                    ? blank
                    : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
            };
            const issued = getFieldValue(data, ISSUED);
            this.errorMessage = undefined;
            this.quote = {
                option: getFieldValue(data, NAME),
                number: getFieldValue(data, NUMBER),
                status: getFieldValue(data, STATUS) ?? 'Draft',
                premiumAmount: getFieldValue(data, PREMIUM),
                premium: money(PREMIUM, undefined),
                // The terms show only on a priced quote, where a blank or zero deductible means there is none.
                limit: money(LIMIT, 'Not set'),
                deductible: getFieldValue(data, DEDUCTIBLE) ? money(DEDUCTIBLE, 'None') : 'None',
                issuedDate: issued,
                issued: issued ? this.shortDate(issued) : undefined,
                expiresDate: getFieldValue(data, EXPIRES),
                underwriter: getFieldValue(data, UNDERWRITER),
                saleId: getFieldValue(data, SALE_ID),
                saleName: getFieldValue(data, SALE_NAME),
                line: getFieldValue(data, SALE_LINE),
                lineIconName: lineIcon(getFieldValue(data, SALE_LINE)).name,
                lineTileClass: lineIcon(getFieldValue(data, SALE_LINE)).tileClass
            };
        } else if (error) {
            this.quote = undefined;
            this.errorMessage = error.body?.message ?? 'This quote could not be loaded.';
        }
    }

    get saleId() {
        return this.quote?.saleId;
    }

    // The other quotes on the same sale, to say how this one compares.
    @wire(getRelatedListRecords, { parentRecordId: '$saleId', relatedListId: 'Quotes', fields: SIBLING_FIELDS })
    wiredSiblings({ data }) {
        this.siblings = data ? data.records.filter((record) => record.id !== this.recordId) : [];
    }

    shortDate(value) {
        return new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' }).format(new Date(`${value}T00:00:00`));
    }

    daysFromToday(value) {
        const today = new Date().setHours(0, 0, 0, 0);
        return Math.round((new Date(`${value}T00:00:00`).getTime() - today) / MS_PER_DAY);
    }

    get statusClass() {
        let tone = 'draft';
        if (CHOSEN.includes(this.quote.status)) {
            tone = 'chosen';
        } else if (WAITING.includes(this.quote.status)) {
            tone = 'waiting';
        }
        return `c-offer__status c-offer__status_${tone}`;
    }

    get isPriced() {
        return this.quote.premiumAmount !== null && this.quote.premiumAmount !== undefined;
    }

    get underwriterLabel() {
        return `${this.isPriced ? 'Priced' : 'Started'} by ${this.quote.underwriter}`;
    }

    get perLine() {
        const amount = this.quote.premiumAmount;
        const monthly = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount / MONTHS);
        return `a year, about ${monthly} a month`;
    }

    /** How this premium sits against the other options on the sale. */
    get comparisonDelta() {
        const mine = this.quote.premiumAmount;
        const others = this.siblings.map((record) => record.fields.Annual_Premium__c.value).filter((amount) => amount !== null && amount !== undefined);
        if (mine === null || mine === undefined || !others.length) {
            return undefined;
        }
        // Compared with the cheapest other option, or the dearest one when this is the cheapest.
        const cheapest = Math.min(...others);
        return mine <= cheapest ? mine - Math.max(...others) : mine - cheapest;
    }

    get comparison() {
        const delta = this.comparisonDelta;
        if (delta === undefined) {
            return undefined;
        }
        const count = this.siblings.length + 1;
        const amount = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(Math.abs(delta));
        if (delta < 0) {
            return `Lowest of ${count} options, ${amount} a year under the dearest`;
        }
        if (delta === 0) {
            return `Same premium as the other ${count === 2 ? 'option' : 'options'}`;
        }
        return `${amount} a year more than the cheapest of ${count} options`;
    }

    get comparisonClass() {
        return this.comparisonDelta < 0 ? 'c-offer__compare c-offer__compare_low' : 'c-offer__compare';
    }

    get hasValidity() {
        return Boolean(this.quote.issuedDate && this.quote.expiresDate);
    }

    get daysLeft() {
        return this.daysFromToday(this.quote.expiresDate);
    }

    get isWaiting() {
        return WAITING.includes(this.quote.status);
    }

    get validityLabel() {
        const until = this.shortDate(this.quote.expiresDate);
        if (!this.isWaiting) {
            return `Valid to ${until}`;
        }
        const days = this.daysLeft;
        if (days < 0) {
            return `Expired ${until}`;
        }
        if (days === 0) {
            return 'Expires today';
        }
        return `${days} ${days === 1 ? 'day' : 'days'} left, to ${until}`;
    }

    get isUrgent() {
        return this.isWaiting && this.daysLeft <= EXPIRING_SOON_DAYS;
    }

    get validityClass() {
        return this.isUrgent ? 'c-valid__left c-valid__left_urgent' : 'c-valid__left';
    }

    get validityBarClass() {
        return this.isUrgent ? 'c-valid__bar c-valid__bar_urgent' : 'c-valid__bar';
    }

    // How much of the validity window has been used.
    get validityStyle() {
        const total = this.daysFromToday(this.quote.expiresDate) - this.daysFromToday(this.quote.issuedDate);
        const used = -this.daysFromToday(this.quote.issuedDate);
        const share = total > 0 ? Math.min(Math.max(used / total, 0), 1) : 1;
        return `width: ${(share * 100).toFixed(0)}%`;
    }

    get saleUrl() {
        return `/lightning/r/Opportunity/${this.quote.saleId}/view`;
    }

    handleOpenSale(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.quote.saleId, objectApiName: 'Opportunity', actionName: 'view' }
        });
    }
}
