import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import RECORD_TYPE from '@salesforce/schema/Case.RecordType.DeveloperName';
import CREATED from '@salesforce/schema/Case.CreatedDate';
import IS_CLOSED from '@salesforce/schema/Case.IsClosed';
import PRIORITY from '@salesforce/schema/Case.Priority';
import ORIGIN from '@salesforce/schema/Case.Origin';
import STATUS from '@salesforce/schema/Case.Status';
import CLOSED_DATE from '@salesforce/schema/Case.ClosedDate';
import CLOSED_ON from '@salesforce/schema/Case.Closed_On__c';
import DAYS_OPEN from '@salesforce/schema/Case.Days_Open__c';
import SEVERITY from '@salesforce/schema/Case.Severity__c';
import LOSS_TYPE from '@salesforce/schema/Case.Loss_Type__c';
import LOSS_DATE from '@salesforce/schema/Case.Date_of_Loss__c';
import REPORTED from '@salesforce/schema/Case.Reported_Date__c';
import ESTIMATED from '@salesforce/schema/Case.Estimated_Loss__c';
import RESERVE from '@salesforce/schema/Case.Reserve_Amount__c';
import PAID from '@salesforce/schema/Case.Paid_Amount__c';
import SIU from '@salesforce/schema/Case.SIU_Referral__c';
import SUBROGATION from '@salesforce/schema/Case.Subrogation_Potential__c';
import COVERAGE_CHECK from '@salesforce/schema/Case.Coverage_Check__c';
import REQUEST_TYPE from '@salesforce/schema/Case.Request_Type__c';
import POLICY_ID from '@salesforce/schema/Case.Policy__c';
import POLICY_NAME from '@salesforce/schema/Case.Policy__r.Name';
import POLICY_LINE from '@salesforce/schema/Case.Policy__r.Line_of_Business__c';
import POLICY_DEDUCTIBLE from '@salesforce/schema/Case.Policy__r.Deductible__c';
import CUSTOMER_ID from '@salesforce/schema/Case.AccountId';
import CUSTOMER_NAME from '@salesforce/schema/Case.Account.Name';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { tidyEnding } from 'c/antsuranceText';

const FIELDS = [RECORD_TYPE, CREATED, IS_CLOSED, PRIORITY, ORIGIN, STATUS, CLOSED_DATE];
const OPTIONAL_FIELDS = [
    SEVERITY, LOSS_TYPE, LOSS_DATE, REPORTED, ESTIMATED, RESERVE, PAID, SIU, SUBROGATION, COVERAGE_CHECK,
    REQUEST_TYPE, POLICY_ID, POLICY_NAME, POLICY_LINE, POLICY_DEDUCTIBLE, CLOSED_ON, DAYS_OPEN, CUSTOMER_ID, CUSTOMER_NAME
];
const MS_PER_DAY = 86400000;
const BLANK = '–';
const COVERED = 'In force on date of loss';
const SERIOUS = ['High', 'Catastrophic'];
// How a claim's severity is set at intake. These tiers mirror the rule Claude is given in
// AntsuranceClaimsAssistantIntake; change them there and here together. `over` is the dollar amount a
// claim must exceed to be in the tier; a claim can also be placed in a tier for what happened, not its size.
const SEVERITY_TIERS = [
    { name: 'Low', over: 0, range: '$5,000 or less', rule: 'Low severity: minor damage, about $5,000 or less, with nobody hurt.' },
    { name: 'Medium', over: 5000, range: '$5,000 to $25,000', rule: 'Medium severity: about $5,000 to $25,000, a vehicle that cannot be driven, or an injury treated and released the same day or needing a few weeks off work.' },
    { name: 'High', over: 25000, range: '$25,000 to $200,000', rule: 'High severity: about $25,000 to $200,000, a stolen or totaled vehicle, a home or premises that cannot be used, or an injury needing surgery or a stay in hospital.' },
    { name: 'Catastrophic', over: 200000, range: 'over $200,000', rule: 'Catastrophic severity: more than about $200,000, a life-threatening injury or a death, or a loss affecting several homes, units or people.' }
];
const DENIED = 'Denied';
const AUTO = 'Personal Auto';
// What is left to do on an open request of each type. The first one has a button that does it.
const ADD_DRIVER = 'Add Driver';
const NEXT_STEPS = {
    [ADD_DRIVER]: 'Add the driver to the policy.',
    'Add Vehicle': 'Add the vehicle to the policy as an insured asset.',
    'Change Coverage': 'Confirm the change with the customer, then update the policy.',
    'Change Address': 'Update the address on the customer and the policy.',
    'Billing Question': 'Check the payment status on the policy and reply.',
    'Certificate of Insurance': 'Issue the certificate from the policy\'s Documents tab.',
    'Policy Document Request': 'Send the documents from the policy\'s Documents tab.'
};

/**
 * For a claim, a reserve meter: what is paid, what is still reserved and how that compares with the
 * estimate, under a banner saying whether the policy covered the loss. For a service request, the essentials.
 * Either way the card ends by naming the customer in full, linked: the strip under the page's title gives a
 * name a column about thirty characters wide, and broke a longer one over two lines, so it carries the person to
 * call and the card carries whose claim or request it is.
 */
export default class AntsuranceCaseSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    record;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredCase({ data, error }) {
        if (data) {
            this.errorMessage = undefined;
            this.record = {
                recordType: getFieldValue(data, RECORD_TYPE),
                created: getFieldValue(data, CREATED),
                isClosed: getFieldValue(data, IS_CLOSED),
                priority: getFieldValue(data, PRIORITY) ?? BLANK,
                origin: getFieldValue(data, ORIGIN) ?? BLANK,
                status: getFieldValue(data, STATUS),
                closedOn: getFieldValue(data, CLOSED_ON) ?? getFieldValue(data, CLOSED_DATE),
                storedDaysOpen: getFieldValue(data, DAYS_OPEN),
                severity: getFieldValue(data, SEVERITY),
                lossType: getFieldValue(data, LOSS_TYPE),
                lossDate: getFieldValue(data, LOSS_DATE),
                reported: getFieldValue(data, REPORTED),
                estimate: getFieldValue(data, ESTIMATED) ?? 0,
                reserve: getFieldValue(data, RESERVE) ?? 0,
                paid: getFieldValue(data, PAID) ?? 0,
                siuReferral: getFieldValue(data, SIU),
                subrogation: getFieldValue(data, SUBROGATION),
                coverageCheck: getFieldValue(data, COVERAGE_CHECK),
                requestType: getFieldValue(data, REQUEST_TYPE) ?? 'Service request',
                policyId: getFieldValue(data, POLICY_ID),
                policyName: getFieldValue(data, POLICY_NAME),
                policyLine: getFieldValue(data, POLICY_LINE),
                deductible: getFieldValue(data, POLICY_DEDUCTIBLE),
                customerId: getFieldValue(data, CUSTOMER_ID),
                customerName: getFieldValue(data, CUSTOMER_NAME)
            };
        } else if (error) {
            this.record = undefined;
            this.errorMessage = error.body?.message ?? 'This case could not be loaded.';
        }
    }

    get isClaim() {
        return this.record?.recordType === 'Claim';
    }

    get cardTitle() {
        return this.isClaim ? 'Claim financials' : 'Service request';
    }

    money(amount) {
        return amount === null || amount === undefined
            ? BLANK
            : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount);
    }

    get outstanding() {
        return this.money(Math.max(this.record.reserve - this.record.paid, 0));
    }

    get isClosed() {
        return this.record.isClosed === true;
    }

    get isDenied() {
        return this.record.status === DENIED;
    }

    /** The big number: what is still reserved on an open claim, what was paid on a closed one. */
    get figure() {
        return this.isClosed ? this.paid : this.outstanding;
    }

    get figureCaption() {
        if (this.isDenied) {
            return 'paid. The claim was denied.';
        }
        return this.isClosed ? 'paid in total' : 'outstanding reserve';
    }

    /** A date as Oct 2, 2026, from a date or a date and time. */
    shortDate(value) {
        if (!value) {
            return undefined;
        }
        const date = value.length === 10 ? new Date(`${value}T00:00:00`) : new Date(value);
        return new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
    }

    get paid() {
        return this.money(this.record.paid);
    }

    get reserve() {
        return this.money(this.record.reserve);
    }

    get estimate() {
        return this.money(this.record.estimate);
    }

    get deductible() {
        return this.money(this.record.deductible);
    }

    /**
     * What the claim pays against the estimate: the estimate less the deductible. The reserve is measured
     * against this, never against the gross estimate (the rule is AntsuranceClaimRules in Apex; keep the two
     * together). Undefined when there is no estimate.
     */
    get payable() {
        const estimate = this.record.estimate;
        return estimate > 0 ? Math.max(estimate - (this.record.deductible ?? 0), 0) : undefined;
    }

    /** Where the reserve stands against what is payable, in one plain line. Nothing on a closed claim. */
    get reserveLine() {
        // An amount stays with the words around it: the line never ends on "$2,500 deductible." alone.
        return tidyEnding(this.reserveText);
    }

    get reserveText() {
        const payable = this.payable;
        if (this.isClosed || payable === undefined) {
            return '';
        }
        const against = this.record.deductible > 0 ? `the estimate less the ${this.deductible} deductible` : 'the estimate';
        if (!(this.record.reserve > 0)) {
            return `No reserve is set yet. ${against.charAt(0).toUpperCase()}${against.slice(1)} is ${this.money(payable)}.`;
        }
        const difference = this.record.reserve - payable;
        if (Math.abs(difference) <= 1) {
            return `The reserve covers ${against}.`;
        }
        return difference < 0
            ? `The reserve is ${this.money(-difference)} below ${against}.`
            : `The reserve is ${this.money(difference)} above ${against}.`;
    }

    // The bar spans whichever is larger, the reserve or what is payable, so a reserve below the payable amount shows as a gap.
    get scale() {
        return Math.max(this.record.reserve, this.payable ?? 0, 1);
    }

    percent(amount) {
        return `${Math.max((amount / this.scale) * 100, 0).toFixed(1)}%`;
    }

    get paidStyle() {
        return `width: ${this.percent(Math.min(this.record.paid, this.record.reserve))}`;
    }

    get openStyle() {
        return `width: ${this.percent(this.record.reserve - this.record.paid)}`;
    }

    get gapStyle() {
        return `width: ${this.percent((this.payable ?? 0) - this.record.reserve)}`;
    }

    get barLabel() {
        const line = this.reserveLine;
        return `${this.paid} paid of ${this.reserve} reserved, against an estimate of ${this.estimate}.${line ? ` ${line}` : ''}`;
    }

    get hasBanner() {
        return this.isClosed || Boolean(this.record.coverageCheck);
    }

    /** A closed claim says how and when it ended; an open one says whether the policy covered the loss. */
    get coverageLabel() {
        const check = this.record.coverageCheck;
        const problem = check && check !== COVERED ? check.toLowerCase() : undefined;
        if (this.isClosed) {
            const when = this.shortDate(this.record.closedOn);
            const outcome = [this.isDenied ? 'Denied' : 'Closed', when ? `on ${when}` : undefined].filter(Boolean).join(' ');
            return problem ? `${outcome}: ${problem}` : outcome;
        }
        return problem ? `Coverage problem: ${problem}` : 'Policy in force on the date of loss';
    }

    get coverageClass() {
        if (this.isClosed) {
            return this.isDenied ? 'c-banner c-banner_bad' : 'c-banner c-banner_closed';
        }
        return this.record.coverageCheck === COVERED ? 'c-banner c-banner_good' : 'c-banner c-banner_bad';
    }

    get coverageIcon() {
        if (this.isClosed) {
            return this.isDenied ? 'utility:ban' : 'utility:lock';
        }
        return this.record.coverageCheck === COVERED ? 'utility:check' : 'utility:warning';
    }

    get coverageIconVariant() {
        return this.isClosed && !this.isDenied ? undefined : 'inverse';
    }

    get severityLabel() {
        return `Severity: ${this.record.severity}`;
    }

    get severityTier() {
        return SEVERITY_TIERS.find((tier) => tier.name === this.record.severity);
    }

    /** The intake rule for this tier, in full, for the chip's tooltip and for a screen reader. */
    get severityRule() {
        return this.severityTier?.rule ?? `${this.record.severity} severity, set when the claim was taken in.`;
    }

    /**
     * Why the claim carries its severity, in a few words drawn from the record: the size of the loss when
     * that is what puts it in its tier, otherwise the kind of loss, since a tier can be set for what
     * happened (an injury, a home that cannot be used) whatever the amount.
     */
    get severityReason() {
        const tier = this.severityTier;
        if (!tier) {
            return '';
        }
        const hasEstimate = this.record.estimate > 0;
        const amount = hasEstimate ? this.record.estimate : this.record.reserve;
        // The tier this amount alone would give: the highest one whose floor it exceeds.
        const byAmount = amount > 0 ? [...SEVERITY_TIERS].reverse().find((candidate) => amount > candidate.over) : undefined;
        if (byAmount?.name === tier.name) {
            const what = hasEstimate ? 'Estimate' : 'Reserve';
            return tier.name === 'Catastrophic' ? `${what} ${tier.range}` : `${what} of ${tier.range}`;
        }
        const lossType = this.record.lossType;
        if (lossType && lossType !== 'Other') {
            return `${lossType.charAt(0)}${lossType.slice(1).toLowerCase()} claim`;
        }
        return 'Set when the claim was taken in';
    }

    get severityClass() {
        // The shared chip, so severity looks the same here as anywhere else it shows.
        return SERIOUS.includes(this.record.severity) ? 'c-ui-severity c-ui-severity_serious' : 'c-ui-severity';
    }

    daysSince(dateValue) {
        if (!dateValue) {
            return BLANK;
        }
        const from = dateValue.length === 10 ? new Date(`${dateValue}T00:00:00`) : new Date(dateValue);
        return Math.max(Math.floor((Date.now() - from.getTime()) / MS_PER_DAY), 0);
    }

    get daysSinceLoss() {
        return this.daysSince(this.record.lossDate);
    }

    /** Days open stops counting when the case closes; Salesforce works that out in a formula field. */
    get daysOpen() {
        const stored = this.record.storedDaysOpen;
        return stored === null || stored === undefined ? this.daysSince(this.record.reported ?? this.record.created) : stored;
    }

    get openCaption() {
        return this.isClosed ? 'days to close' : 'days open';
    }

    get requestCaption() {
        if (this.isClosed) {
            const when = this.shortDate(this.record.closedOn);
            return when ? `Closed on ${when}.` : 'Closed.';
        }
        return NEXT_STEPS[this.record.requestType] ?? 'Open. Work it from the policy.';
    }

    get requestState() {
        return this.isClosed ? 'Done' : 'To do';
    }

    get requestStateClass() {
        return this.isClosed ? 'c-next c-next_done' : 'c-next';
    }

    /** An open request to add a driver to an auto policy can be worked from here. */
    get canAddDriver() {
        return !this.isClosed && this.record.requestType === ADD_DRIVER && this.record.policyLine === AUTO && Boolean(this.record.policyId);
    }

    get showOpenPolicy() {
        return !this.canAddDriver && Boolean(this.record.policyId);
    }

    /** Opens the policy's Add a Driver action over the policy page. */
    handleAddDriver() {
        const policyId = this.record.policyId;
        const background = encodeURIComponent(`/lightning/r/Policy__c/${policyId}/view`);
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/lightning/action/quick/Policy__c.Add_Driver?objectApiName=Policy__c&context=RECORD_DETAIL&recordId=${policyId}&backgroundContext=${background}`
            }
        });
    }

    get customerUrl() {
        return `/lightning/r/Account/${this.record.customerId}/view`;
    }

    handleOpenCustomer(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.record.customerId, objectApiName: 'Account', actionName: 'view' }
        });
    }

    get policyUrl() {
        return `/lightning/r/Policy__c/${this.record.policyId}/view`;
    }

    handleOpenPolicy(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.record.policyId, objectApiName: 'Policy__c', actionName: 'view' }
        });
    }
}
