import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';
import FORM_NUMBER from '@salesforce/schema/Policy_Endorsement__c.Form_Number__c';
import TYPE from '@salesforce/schema/Policy_Endorsement__c.Type__c';
import STATUS from '@salesforce/schema/Policy_Endorsement__c.Status__c';
import EFFECTIVE from '@salesforce/schema/Policy_Endorsement__c.Effective_Date__c';
import PREMIUM_CHANGE from '@salesforce/schema/Policy_Endorsement__c.Premium_Change__c';
import LIMIT from '@salesforce/schema/Policy_Endorsement__c.Limit_Amount__c';
import DESCRIPTION from '@salesforce/schema/Policy_Endorsement__c.Description__c';
import POLICY from '@salesforce/schema/Policy_Endorsement__c.Policy__c';
import POLICY_NUMBER from '@salesforce/schema/Policy_Endorsement__c.Policy__r.Name';
import POLICY_LINE from '@salesforce/schema/Policy_Endorsement__c.Policy__r.Line_of_Business__c';
import POLICY_PREMIUM from '@salesforce/schema/Policy_Endorsement__c.Policy__r.Annual_Premium__c';
import POLICYHOLDER from '@salesforce/schema/Policy_Endorsement__c.Policy__r.Account__r.Name';

const FIELDS = [FORM_NUMBER, TYPE, STATUS, EFFECTIVE, PREMIUM_CHANGE, LIMIT, DESCRIPTION, POLICY, POLICY_NUMBER, POLICY_LINE, POLICY_PREMIUM, POLICYHOLDER];

// What each type of form does to a policy, in a sentence. Used only for a form that has no description of
// its own: the page shows a form's description beside this card, and the two must not say different things.
const DOES = {
    Endorsement: 'Adds to or changes what the policy covers.',
    Exclusion: 'Takes something out of what the policy covers.',
    Benefit: 'Gives the policyholder an extra service.',
    Discount: 'Lowers the premium.',
    'Lienholder or Mortgagee': 'Names a lender with an interest in what is insured.'
};

/**
 * One form on a policy: its number and type, what it does to the premium, and the policy it sits on.
 */
export default class AntsuranceEndorsementSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    form;
    errorMessage;
    policyUrl;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredForm({ data, error }) {
        if (error) {
            this.form = undefined;
            this.errorMessage = error.body?.message ?? 'This form could not be loaded.';
            return;
        }
        if (!data) {
            return;
        }
        this.errorMessage = undefined;
        const change = getFieldValue(data, PREMIUM_CHANGE);
        const premium = getFieldValue(data, POLICY_PREMIUM);
        const limit = getFieldValue(data, LIMIT);
        const type = getFieldValue(data, TYPE);
        const status = getFieldValue(data, STATUS);
        const effective = getFieldValue(data, EFFECTIVE);
        this.form = {
            number: getFieldValue(data, FORM_NUMBER) ?? 'No form number',
            type,
            statusLine: effective ? `${status} since ${this.date(effective)}` : status,
            ...this.effect(change, premium),
            does: getFieldValue(data, DESCRIPTION) ? undefined : (DOES[type] ?? 'Changes the policy.'),
            limit: limit ? this.money(limit) : undefined,
            policyId: getFieldValue(data, POLICY),
            policyNumber: getFieldValue(data, POLICY_NUMBER),
            policyLine: [getFieldValue(data, POLICY_LINE), getFieldValue(data, POLICYHOLDER)].filter(Boolean).join(', '),
            line: getFieldValue(data, POLICY_LINE)
        };
        this.preparePolicyUrl();
    }

    get policyIconName() {
        return lineIcon(this.form?.line).name;
    }

    get policyTileClass() {
        return lineIcon(this.form?.line).tileClass;
    }

    /** The premium change as a signed figure, with what share of the policy premium it is. */
    effect(change, premium) {
        if (!change) {
            return { effect: 'None', effectNote: 'This form does not change the premium.', tone: 'none' };
        }
        const saves = change < 0;
        const share = premium ? Math.abs(change) / premium : undefined;
        const shareText = share === undefined ? '' : `, ${new Intl.NumberFormat(LOCALE, { style: 'percent', maximumFractionDigits: 1 }).format(share)} of the ${this.money(premium)} premium`;
        return {
            effect: `${saves ? '−' : '+'}${this.money(Math.abs(change))}`,
            effectNote: `${saves ? 'Off' : 'On'} the premium each year${shareText}.`,
            tone: saves ? 'saves' : 'adds'
        };
    }

    get effectClass() {
        return `c-form__figure c-form__figure_${this.form.tone}`;
    }

    money(value) {
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(value);
    }

    date(value) {
        // A date field arrives as yyyy-mm-dd; read it as a local day so it does not slip to the day before.
        const [year, month, day] = value.split('-').map(Number);
        return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(year, month - 1, day));
    }

    get policyPage() {
        return { type: 'standard__recordPage', attributes: { recordId: this.form.policyId, objectApiName: 'Policy__c', actionName: 'view' } };
    }

    async preparePolicyUrl() {
        this.policyUrl = this.form.policyId ? await this[NavigationMixin.GenerateUrl](this.policyPage) : undefined;
    }

    handleOpenPolicy(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.policyPage);
    }
}
