import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ROLE from '@salesforce/schema/Policy_Participant__c.Role__c';
import STATUS from '@salesforce/schema/Policy_Participant__c.Status__c';
import RELATIONSHIP from '@salesforce/schema/Policy_Participant__c.Relationship_to_Insured__c';
import IS_PRIMARY from '@salesforce/schema/Policy_Participant__c.Is_Primary__c';
import CONTACT_ID from '@salesforce/schema/Policy_Participant__c.Contact__c';
import CONTACT_NAME from '@salesforce/schema/Policy_Participant__c.Contact__r.Name';
import POLICY_ID from '@salesforce/schema/Policy_Participant__c.Policy__c';
import POLICY_NAME from '@salesforce/schema/Policy_Participant__c.Policy__r.Name';
import POLICY_LINE from '@salesforce/schema/Policy_Participant__c.Policy__r.Line_of_Business__c';
import LICENSE_NUMBER from '@salesforce/schema/Policy_Participant__c.License_Number__c';
import LICENSE_STATE from '@salesforce/schema/Policy_Participant__c.License_State__c';
import YEARS_LICENSED from '@salesforce/schema/Policy_Participant__c.Years_Licensed__c';
import RATING from '@salesforce/schema/Policy_Participant__c.Driver_Rating__c';
import VIOLATIONS from '@salesforce/schema/Policy_Participant__c.Violations_Past_3_Years__c';
import ACCIDENTS from '@salesforce/schema/Policy_Participant__c.Accidents_Past_3_Years__c';
import GOOD_STUDENT from '@salesforce/schema/Policy_Participant__c.Good_Student_Discount__c';
import VEHICLE from '@salesforce/schema/Policy_Participant__c.Primary_Vehicle__c';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { roleIcon } from 'c/antsuranceIcons';

const FIELDS = [ROLE, STATUS, IS_PRIMARY, CONTACT_ID, POLICY_ID];
const OPTIONAL_FIELDS = [
    RELATIONSHIP, CONTACT_NAME, POLICY_NAME, POLICY_LINE, LICENSE_NUMBER, LICENSE_STATE, YEARS_LICENSED,
    RATING, VIOLATIONS, ACCIDENTS, GOOD_STUDENT, VEHICLE
];
const BLANK = '–';
const DRIVER_ROLES = ['Driver', 'Excluded Driver'];
const RATING_TONES = { Preferred: 'good', Standard: 'neutral', 'Non-Standard': 'bad', 'Inexperienced Operator': 'warn' };

/** A person on a policy: who they are, their role and, for a driver, the license and record they are rated on. */
export default class AntsuranceParticipantSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    person;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredParticipant({ data, error }) {
        if (data) {
            const count = (field) => getFieldValue(data, field) ?? 0;
            const contactName = getFieldValue(data, CONTACT_NAME) ?? 'No person linked';
            this.errorMessage = undefined;
            this.person = {
                role: getFieldValue(data, ROLE) ?? 'Participant',
                status: getFieldValue(data, STATUS) ?? 'Active',
                relationship: getFieldValue(data, RELATIONSHIP),
                isPrimary: getFieldValue(data, IS_PRIMARY),
                contactId: getFieldValue(data, CONTACT_ID),
                contactName,
                initials: contactName
                    .split(/\s+/)
                    .map((word) => word.charAt(0).toUpperCase())
                    .slice(0, 2)
                    .join(''),
                policyId: getFieldValue(data, POLICY_ID),
                policyName: getFieldValue(data, POLICY_NAME),
                policyLine: getFieldValue(data, POLICY_LINE),
                licenseNumber: getFieldValue(data, LICENSE_NUMBER) ?? 'No license on file',
                licenseState: getFieldValue(data, LICENSE_STATE) ?? BLANK,
                yearsLicensed: getFieldValue(data, YEARS_LICENSED) ?? BLANK,
                rating: getFieldValue(data, RATING),
                violations: count(VIOLATIONS),
                accidents: count(ACCIDENTS),
                goodStudent: getFieldValue(data, GOOD_STUDENT),
                vehicle: getFieldValue(data, VEHICLE)
            };
        } else if (error) {
            this.person = undefined;
            this.errorMessage = error.body?.message ?? 'This participant could not be loaded.';
        }
    }

    get isDriver() {
        return DRIVER_ROLES.includes(this.person.role);
    }

    get roleIconName() {
        return roleIcon(this.person?.role).name;
    }

    get roleTileClass() {
        return `${roleIcon(this.person?.role).tileClass} c-ui-tile_small c-person__role-icon`;
    }

    get roleLine() {
        const { role, isPrimary, relationship } = this.person;
        const parts = [isPrimary ? `Primary ${role.toLowerCase()}` : role];
        if (relationship && relationship !== 'Self') {
            parts.push(relationship.toLowerCase());
        }
        return parts.join(', ');
    }

    get statusClass() {
        return this.person.status === 'Active' ? 'c-status c-status_good' : 'c-status';
    }

    get ratingClass() {
        return `c-license__rating c-license__rating_${RATING_TONES[this.person.rating] ?? 'neutral'}`;
    }

    get violationsClass() {
        return this.person.violations > 0 ? 'c-record__flagged' : '';
    }

    get accidentsClass() {
        return this.person.accidents > 0 ? 'c-record__flagged' : '';
    }

    get driverNote() {
        const notes = [];
        if (this.person.vehicle) {
            notes.push(`Mainly drives the ${this.person.vehicle}`);
        }
        if (this.person.goodStudent) {
            notes.push('Good student discount');
        }
        return notes.join('. ');
    }

    get contactUrl() {
        return `/lightning/r/Contact/${this.person.contactId}/view`;
    }

    get policyUrl() {
        return `/lightning/r/Policy__c/${this.person.policyId}/view`;
    }

    navigate(event, recordId, objectApiName) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    handleOpenContact(event) {
        this.navigate(event, this.person.contactId, 'Contact');
    }

    handleOpenPolicy(event) {
        this.navigate(event, this.person.policyId, 'Policy__c');
    }
}
