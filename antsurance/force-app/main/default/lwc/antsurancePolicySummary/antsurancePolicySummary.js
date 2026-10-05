import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import ANTSURANCE_LOCKUP from '@salesforce/resourceUrl/antsuranceLockupIvory';
import NAME from '@salesforce/schema/Policy__c.Name';
import STATUS from '@salesforce/schema/Policy__c.Status__c';
import LINE_OF_BUSINESS from '@salesforce/schema/Policy__c.Line_of_Business__c';
import EFFECTIVE from '@salesforce/schema/Policy__c.Effective_Date__c';
import EXPIRATION from '@salesforce/schema/Policy__c.Expiration_Date__c';
import PREMIUM from '@salesforce/schema/Policy__c.Annual_Premium__c';
import LIMIT from '@salesforce/schema/Policy__c.Coverage_Limit__c';
import DEDUCTIBLE from '@salesforce/schema/Policy__c.Deductible__c';
import PAYMENT_STATUS from '@salesforce/schema/Policy__c.Payment_Status__c';
import BILLING from '@salesforce/schema/Policy__c.Billing_Frequency__c';
import INSURED_ITEM from '@salesforce/schema/Policy__c.Insured_Item__c';
import HOLDER_ID from '@salesforce/schema/Policy__c.Account__c';
import HOLDER_NAME from '@salesforce/schema/Policy__c.Account__r.Name';
import PRODUCER_ID from '@salesforce/schema/Policy__c.Producer__c';
import PRODUCER_NAME from '@salesforce/schema/Policy__c.Producer__r.Name';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const FIELDS = [NAME, STATUS, LINE_OF_BUSINESS, EFFECTIVE, EXPIRATION, PREMIUM, LIMIT, DEDUCTIBLE, PAYMENT_STATUS, BILLING, INSURED_ITEM];
// Who holds the policy and the agency that produced it. Read apart from the rest, so a reader who cannot see
// the customer or the agency still gets the card.
const OPTIONAL_FIELDS = [HOLDER_ID, HOLDER_NAME, PRODUCER_ID, PRODUCER_NAME];
const MS_PER_DAY = 86400000;
const BLANK = '–';
// Circumference of the term ring (radius 52 in a 120 unit box).
const RING_LENGTH = 2 * Math.PI * 52;
const STATUS_TONES = { Active: 'good', 'Pending Renewal': 'warn', Lapsed: 'bad', Cancelled: 'bad', Expired: 'bad' };

/**
 * The policy as an insurance card: number, line, who holds it and who produced it, how far through its term it
 * is, and the key amounts. The policyholder and the producing agency are named here in full, each linked: the
 * strip under the page's title gives a name a narrow column and broke a long one over two lines.
 */
export default class AntsurancePolicySummary extends NavigationMixin(LightningElement) {
    @api recordId;
    logoUrl = ANTSURANCE_LOCKUP;
    policy;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    get lineIconName() {
        return lineIcon(this.policy?.lineOfBusiness).name;
    }

    get lineTileClass() {
        return `${lineIcon(this.policy?.lineOfBusiness).tileClass} c-ui-tile_large`;
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredPolicy({ data, error }) {
        if (data) {
            const money = (field) => {
                const amount = getFieldValue(data, field);
                return amount === null || amount === undefined
                    ? BLANK
                    : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
            };
            const date = (field) => {
                const value = getFieldValue(data, field);
                return value
                    ? new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
                    : BLANK;
            };
            this.errorMessage = undefined;
            this.policy = {
                name: getFieldValue(data, NAME),
                status: getFieldValue(data, STATUS) ?? 'No status',
                lineOfBusiness: getFieldValue(data, LINE_OF_BUSINESS) ?? 'Policy',
                paymentStatus: getFieldValue(data, PAYMENT_STATUS) ?? BLANK,
                billing: getFieldValue(data, BILLING),
                premium: money(PREMIUM),
                limit: money(LIMIT),
                // A policy with no deductible (workers compensation on guaranteed cost) reads "None", not "$0".
                deductible: getFieldValue(data, DEDUCTIBLE) === 0 ? 'None' : money(DEDUCTIBLE),
                period: `${date(EFFECTIVE)} to ${date(EXPIRATION)}`,
                effectiveDate: getFieldValue(data, EFFECTIVE),
                expirationDate: getFieldValue(data, EXPIRATION),
                insuredItem: getFieldValue(data, INSURED_ITEM),
                holderId: getFieldValue(data, HOLDER_ID),
                holderName: getFieldValue(data, HOLDER_NAME),
                producerId: getFieldValue(data, PRODUCER_ID),
                producerName: getFieldValue(data, PRODUCER_NAME)
            };
        } else if (error) {
            this.policy = undefined;
            this.errorMessage = error.body?.message ?? 'This policy could not be loaded.';
        }
    }

    get holderUrl() {
        return `/lightning/r/Account/${this.policy.holderId}/view`;
    }

    get producerUrl() {
        return `/lightning/r/Account/${this.policy.producerId}/view`;
    }

    /** Opens the policyholder or the agency. A modified click is left to the browser, for a new tab. */
    handleOpenCustomer(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, objectApiName: 'Account', actionName: 'view' }
        });
    }

    get statusClass() {
        return `c-pill c-pill_${STATUS_TONES[this.policy.status] ?? 'neutral'}`;
    }

    get paymentClass() {
        return this.policy.paymentStatus === 'Past Due' ? 'c-card__alert' : '';
    }

    get billingLabel() {
        return this.policy.billing ?? BLANK;
    }

    get hasTerm() {
        return Boolean(this.policy.effectiveDate && this.policy.expirationDate);
    }

    get daysLeft() {
        const today = new Date().setHours(0, 0, 0, 0);
        return Math.round((new Date(`${this.policy.expirationDate}T00:00:00`).getTime() - today) / MS_PER_DAY);
    }

    get daysNumber() {
        return Math.abs(this.daysLeft);
    }

    get daysCaption() {
        const unit = this.daysNumber === 1 ? 'day' : 'days';
        return this.daysLeft >= 0 ? `${unit} left` : `${unit} past`;
    }

    /** Share of the term that has passed, from 0 to 1. */
    get termElapsed() {
        const start = new Date(`${this.policy.effectiveDate}T00:00:00`).getTime();
        const end = new Date(`${this.policy.expirationDate}T00:00:00`).getTime();
        return Math.min(Math.max((Date.now() - start) / (end - start), 0), 1);
    }

    get ringStyle() {
        return `stroke-dasharray: ${(this.termElapsed * RING_LENGTH).toFixed(1)} ${RING_LENGTH.toFixed(1)}`;
    }

    get termLabel() {
        return `${Math.round(this.termElapsed * 100)}% of the policy term has passed`;
    }
}
