import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME from '@salesforce/schema/Lead.Name';
import COMPANY from '@salesforce/schema/Lead.Company';
import INTEREST from '@salesforce/schema/Lead.Product_Interest__c';
import RATING from '@salesforce/schema/Lead.Rating';
import SOURCE from '@salesforce/schema/Lead.LeadSource';
import EMAIL from '@salesforce/schema/Lead.Email';
import PHONE from '@salesforce/schema/Lead.Phone';
import CREATED from '@salesforce/schema/Lead.CreatedDate';
import IS_CONVERTED from '@salesforce/schema/Lead.IsConverted';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const FIELDS = [NAME, COMPANY, RATING, SOURCE, EMAIL, PHONE, CREATED, IS_CONVERTED];
const OPTIONAL_FIELDS = [INTEREST];
const MS_PER_DAY = 86400000;
// A rating as a chip that carries its word. Hot is the one to act on, so it alone is tinted clay.
const RATING_TONES = { Hot: 'c-chip c-chip_hot', Warm: 'c-chip c-chip_warm', Cold: 'c-chip' };

/**
 * A lead at a glance. The largest thing is what they asked about, because that decides who picks
 * the lead up and what the first call is about; then how warm they are, how to reach them, and
 * how long they have been waiting. Reads the lead through Lightning Data Service, as the page does.
 */
export default class AntsuranceLeadSummary extends LightningElement {
    @api recordId;
    lead;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredLead({ data, error }) {
        if (data) {
            const interest = getFieldValue(data, INTEREST);
            const icon = lineIcon(interest);
            const created = getFieldValue(data, CREATED);
            this.errorMessage = undefined;
            this.lead = {
                name: getFieldValue(data, NAME),
                company: getFieldValue(data, COMPANY),
                interest,
                iconName: icon.name,
                tileClass: `${icon.tileClass} c-ui-tile_large`,
                rating: getFieldValue(data, RATING),
                source: getFieldValue(data, SOURCE),
                email: getFieldValue(data, EMAIL),
                phone: getFieldValue(data, PHONE),
                isConverted: getFieldValue(data, IS_CONVERTED),
                daysWaiting: created ? Math.max(0, Math.floor((Date.now() - new Date(created).getTime()) / MS_PER_DAY)) : undefined
            };
        } else if (error) {
            this.lead = undefined;
            this.errorMessage = error.body?.message ?? 'This lead could not be loaded.';
        }
    }

    get isLoading() {
        return !this.lead && !this.errorMessage;
    }

    get interestLabel() {
        return this.lead.interest ?? 'Not said yet';
    }

    get ratingLabel() {
        return this.lead.rating ? `${this.lead.rating} lead` : undefined;
    }

    get ratingClass() {
        return RATING_TONES[this.lead.rating] ?? 'c-chip';
    }

    /** A household lead's company is the person's own name; it is only worth a line when it differs. */
    get companyLine() {
        const { company, name } = this.lead;
        return company && company !== name ? company : undefined;
    }

    get phoneUrl() {
        return `tel:${this.lead.phone}`;
    }

    get emailUrl() {
        return `mailto:${this.lead.email}`;
    }

    get hasNoWay() {
        return !this.lead.phone && !this.lead.email;
    }

    /** "Came in today from the website" or "Waiting 3 days, from a referral". */
    get waitingLine() {
        const { daysWaiting, source, isConverted } = this.lead;
        if (daysWaiting === undefined) {
            return undefined;
        }
        const from = source ? ` Source: ${source}.` : '';
        if (isConverted) {
            return `Converted to a customer.${from}`;
        }
        if (daysWaiting === 0) {
            return `Came in today.${from}`;
        }
        return `${daysWaiting === 1 ? 'Came in yesterday' : `Came in ${daysWaiting} days ago`}.${from}`;
    }
}
