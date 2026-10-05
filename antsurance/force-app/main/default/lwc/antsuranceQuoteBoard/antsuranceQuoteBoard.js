import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import IS_CLOSED from '@salesforce/schema/Opportunity.IsClosed';
import IS_WON from '@salesforce/schema/Opportunity.IsWon';
import CLOSE_DATE from '@salesforce/schema/Opportunity.CloseDate';
import AMOUNT from '@salesforce/schema/Opportunity.Amount';
import POLICY_ID from '@salesforce/schema/Opportunity.Policy__c';
import POLICY_NAME from '@salesforce/schema/Opportunity.Policy__r.Name';
import LINE from '@salesforce/schema/Opportunity.Line_of_Business__c';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const FIELDS = [
    'Quote.Name', 'Quote.QuoteNumber', 'Quote.Status', 'Quote.Annual_Premium__c', 'Quote.Coverage_Limit__c',
    'Quote.Deductible__c', 'Quote.Issued_Date__c', 'Quote.ExpirationDate'
];
const MS_PER_DAY = 86400000;
// A quote out this long without an answer needs chasing.
const STALE_DAYS = 15;
const WAITING = ['Issued', 'Presented'];
const CHOSEN = ['Accepted', 'Bound'];
const DEAD = ['Declined', 'Expired'];

/** The quotes on a policy sale laid side by side as options, so the terms and their status compare at a glance. */
export default class AntsuranceQuoteBoard extends NavigationMixin(LightningElement) {
    @api recordId;
    quotes;
    sale;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRelatedListRecords, { parentRecordId: '$recordId', relatedListId: 'Quotes', fields: FIELDS, sortBy: ['Quote.Annual_Premium__c'] })
    wiredQuotes({ data, error }) {
        if (data) {
            this.quotes = data.records;
            this.errorMessage = undefined;
        } else if (error) {
            this.quotes = [];
            this.errorMessage = error.body?.message ?? 'The quotes could not be loaded.';
        }
    }

    @wire(getRecord, { recordId: '$recordId', fields: [IS_CLOSED, IS_WON, CLOSE_DATE], optionalFields: [POLICY_ID, POLICY_NAME, AMOUNT, LINE] })
    wiredSale({ data }) {
        this.sale = data;
    }

    /** The line of business being quoted, which the heading's icon stands for. */
    get line() {
        return this.sale ? getFieldValue(this.sale, LINE) : undefined;
    }

    get lineIconName() {
        return lineIcon(this.line).name;
    }

    get lineTileClass() {
        return lineIcon(this.line).tileClass;
    }

    /** What became of the sale. A bound sale is closed, and the policy it became is the record to work from. */
    get outcome() {
        if (!this.sale) {
            return undefined;
        }
        const closed = getFieldValue(this.sale, CLOSE_DATE);
        const closedOn = closed
            ? new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' }).format(new Date(`${closed}T00:00:00`))
            : undefined;
        if (getFieldValue(this.sale, IS_WON)) {
            const policyId = getFieldValue(this.sale, POLICY_ID);
            const policyName = getFieldValue(this.sale, POLICY_NAME);
            return {
                className: 'c-outcome c-outcome_won',
                icon: 'utility:success',
                title: closedOn ? `Bound ${closedOn}.` : 'Bound.',
                text: policyId ? `This sale is closed and in force as policy ${policyName}.` : 'This sale is closed. No policy is linked to it yet.',
                policyUrl: policyId ? `/lightning/r/Policy__c/${policyId}/view` : undefined
            };
        }
        if (getFieldValue(this.sale, IS_CLOSED)) {
            return {
                className: 'c-outcome',
                icon: 'utility:ban',
                title: closedOn ? `Closed ${closedOn}.` : 'Closed.',
                text: 'The customer did not take any of these options.'
            };
        }
        if (this.quotes?.some((quote) => quote.fields.Status.value === 'Accepted')) {
            return {
                className: 'c-outcome',
                icon: 'utility:check',
                title: 'Ready to bind.',
                text: 'The customer accepted an option. Use Bind Policy to issue it.'
            };
        }
        return undefined;
    }

    handleOpenPolicy(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: getFieldValue(this.sale, POLICY_ID), objectApiName: 'Policy__c', actionName: 'view' }
        });
    }

    get isLoaded() {
        return this.quotes !== undefined;
    }

    get hasQuotes() {
        return this.quotes?.length > 0;
    }

    /** "Workers Compensation · 3 options, none accepted yet": the line in words, which the page's header strip leaves to this card. */
    get summary() {
        if (!this.isLoaded) {
            return 'Loading';
        }
        return this.line ? `${this.line} \u00b7 ${this.standing}` : this.standing;
    }

    get standing() {
        const count = this.quotes.length;
        if (count === 0) {
            return 'Nothing priced yet';
        }
        const chosen = this.quotes.find((quote) => CHOSEN.includes(quote.fields.Status.value));
        const options = count === 1 ? '1 option' : `${count} options`;
        return chosen ? `${options}, one ${chosen.fields.Status.value.toLowerCase()}` : `${options}, none accepted yet`;
    }

    get options() {
        const today = new Date().setHours(0, 0, 0, 0);
        const money = (amount, blank) =>
            amount === null || amount === undefined
                ? blank
                : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
        const dateFormat = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short' });
        // The recommended option is the one the sale's amount is based on. It is only worth marking among several.
        const saleAmount = this.sale ? getFieldValue(this.sale, AMOUNT) : undefined;
        const recommended =
            this.quotes.length > 1 && saleAmount ? this.quotes.find((quote) => quote.fields.Annual_Premium__c.value === saleAmount)?.id : undefined;
        // The recommended option leads, as it does on the printed proposal; the rest follow by premium.
        const ordered = [...this.quotes].sort((first, second) => Number(second.id === recommended) - Number(first.id === recommended));
        return ordered.map((quote) => {
            const value = (field) => quote.fields[field].value;
            const status = value('Status') ?? 'Draft';
            const issued = value('Issued_Date__c');
            const validUntil = value('ExpirationDate');
            const daysOut = issued ? Math.round((today - new Date(`${issued}T00:00:00`).getTime()) / MS_PER_DAY) : undefined;
            const isWaiting = WAITING.includes(status);
            const isStale = isWaiting && daysOut >= STALE_DAYS;

            let age = 'Not issued yet';
            if (CHOSEN.includes(status) || DEAD.includes(status)) {
                age = issued ? `Issued ${dateFormat.format(new Date(`${issued}T00:00:00`))}` : status;
            } else if (isWaiting && daysOut !== undefined) {
                const until = validUntil ? `, valid to ${dateFormat.format(new Date(`${validUntil}T00:00:00`))}` : '';
                age = daysOut === 0 ? `Sent today${until}` : `Sent ${daysOut} ${daysOut === 1 ? 'day' : 'days'} ago${until}`;
            }

            let tone = 'draft';
            if (CHOSEN.includes(status)) {
                tone = 'chosen';
            } else if (DEAD.includes(status)) {
                tone = 'dead';
            } else if (isWaiting) {
                tone = 'waiting';
            }
            return {
                recordId: quote.id,
                number: `Quote ${value('QuoteNumber')}`,
                premiumClass: value('Annual_Premium__c') === null ? 'c-option__premium c-option__premium_none' : 'c-option__premium',
                name: value('Name') ?? 'Option',
                status,
                isPriced: value('Annual_Premium__c') !== null,
                isRecommended: quote.id === recommended && tone !== 'dead',
                premium: money(value('Annual_Premium__c'), 'Not priced yet'),
                limit: money(value('Coverage_Limit__c'), 'Not set'),
                deductible: value('Deductible__c') === 0 ? 'None' : money(value('Deductible__c'), value('Annual_Premium__c') === null ? 'Not set' : 'None'),
                age,
                title: `Quote ${value('QuoteNumber')}: ${value('Name') ?? 'Option'}`,
                url: `/lightning/r/Quote/${quote.id}/view`,
                cardClass: `c-option c-option_${tone}`,
                statusClass: `c-option__status c-option__status_${tone}`,
                ageClass: isStale ? 'c-option__age c-option__age_stale' : 'c-option__age'
            };
        });
    }

    handleOpen(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, objectApiName: 'Quote', actionName: 'view' }
        });
    }
}
