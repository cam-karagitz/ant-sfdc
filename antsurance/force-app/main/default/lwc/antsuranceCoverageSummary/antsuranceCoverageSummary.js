import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import NAME from '@salesforce/schema/Policy_Coverage__c.Name';
import CATEGORY from '@salesforce/schema/Policy_Coverage__c.Category__c';
import LIMIT from '@salesforce/schema/Policy_Coverage__c.Limit_Amount__c';
import LIMIT_TYPE from '@salesforce/schema/Policy_Coverage__c.Limit_Type__c';
import DEDUCTIBLE from '@salesforce/schema/Policy_Coverage__c.Deductible_Amount__c';
import PREMIUM from '@salesforce/schema/Policy_Coverage__c.Premium_Amount__c';
import WHAT from '@salesforce/schema/Policy_Coverage__c.What_Is_Covered__c';
import POLICY_ID from '@salesforce/schema/Policy_Coverage__c.Policy__c';
import POLICY_NAME from '@salesforce/schema/Policy_Coverage__c.Policy__r.Name';
import HOLDER_ID from '@salesforce/schema/Policy_Coverage__c.Policy__r.Account__c';
import HOLDER_NAME from '@salesforce/schema/Policy_Coverage__c.Policy__r.Account__r.Name';
import POLICY_PREMIUM from '@salesforce/schema/Policy_Coverage__c.Policy__r.Annual_Premium__c';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { coverageGroup, coverageIcon, basisWords } from 'c/antsuranceIcons';

const OPTIONAL_FIELDS = [NAME, CATEGORY, LIMIT, LIMIT_TYPE, DEDUCTIBLE, PREMIUM, WHAT, POLICY_ID, POLICY_NAME, POLICY_PREMIUM, HOLDER_ID, HOLDER_NAME];
// Circumference of the donut's ring, which has a radius of 52 in its 120-unit viewBox.
const DONUT_LENGTH = 2 * Math.PI * 52;

/** One coverage on a policy: its limit and deductible, and how much of the policy's premium it accounts for. */
export default class AntsuranceCoverageSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    coverage;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', optionalFields: OPTIONAL_FIELDS })
    wiredCoverage({ data, error }) {
        if (data) {
            const money = (amount, blank) =>
                amount === null || amount === undefined
                    ? blank
                    : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
            const premium = getFieldValue(data, PREMIUM) ?? 0;
            const policyPremium = getFieldValue(data, POLICY_PREMIUM) ?? 0;
            const limitType = getFieldValue(data, LIMIT_TYPE);
            const limitAmount = getFieldValue(data, LIMIT);
            const hasLimit = limitAmount !== null && limitAmount !== undefined;
            this.errorMessage = undefined;
            const name = getFieldValue(data, NAME);
            const category = getFieldValue(data, CATEGORY);
            const icon = coverageIcon(name, category);
            this.coverage = {
                // The coverage by name, under the group the policy page lists it in ("The home and what is in it").
                name: name ?? category ?? 'Coverage',
                group: coverageGroup(name, category).label,
                iconName: icon.name,
                tileClass: `${icon.tileClass} c-ui-tile_large`,
                // A coverage without a dollar limit pays on a basis instead, such as actual cash value or the statutory benefit.
                limit: hasLimit ? money(limitAmount) : (limitType ?? 'Not stated'),
                limitType: hasLimit ? basisWords(limitType) : undefined,
                deductible: money(getFieldValue(data, DEDUCTIBLE), 'None'),
                premium: money(premium, '–'),
                policyPremium: money(policyPremium, '–'),
                policyId: getFieldValue(data, POLICY_ID),
                policyName: getFieldValue(data, POLICY_NAME),
                holderId: getFieldValue(data, HOLDER_ID),
                holderName: getFieldValue(data, HOLDER_NAME),
                share: policyPremium > 0 ? Math.min(premium / policyPremium, 1) : 0,
                whatIsCovered: getFieldValue(data, WHAT)
            };
        } else if (error) {
            this.coverage = undefined;
            this.errorMessage = error.body?.message ?? 'This coverage could not be loaded.';
        }
    }

    get sharePercent() {
        return new Intl.NumberFormat(LOCALE, { style: 'percent', maximumFractionDigits: 0 }).format(this.coverage.share);
    }

    get shareLabel() {
        return `${this.sharePercent} of the policy premium`;
    }

    get donutStyle() {
        return `stroke-dasharray: ${(this.coverage.share * DONUT_LENGTH).toFixed(1)} ${DONUT_LENGTH.toFixed(1)}`;
    }

    get premiumLine() {
        const { premium, policyPremium } = this.coverage;
        return `${premium} of the ${policyPremium} annual premium`;
    }

    get policyUrl() {
        return `/lightning/r/Policy__c/${this.coverage.policyId}/view`;
    }

    get holderUrl() {
        return `/lightning/r/Account/${this.coverage.holderId}/view`;
    }

    /** Opens the policy or the policyholder. A modified click is left to the browser, for a new tab. */
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
