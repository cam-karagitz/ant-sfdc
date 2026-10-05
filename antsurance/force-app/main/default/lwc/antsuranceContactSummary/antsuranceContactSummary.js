import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import NAME from '@salesforce/schema/Contact.Name';
import FIRST_NAME from '@salesforce/schema/Contact.FirstName';
import LAST_NAME from '@salesforce/schema/Contact.LastName';
import TITLE from '@salesforce/schema/Contact.Title';
import EMAIL from '@salesforce/schema/Contact.Email';
import PHONE from '@salesforce/schema/Contact.Phone';
import MOBILE from '@salesforce/schema/Contact.MobilePhone';
import BIRTHDATE from '@salesforce/schema/Contact.Birthdate';
import ROLE from '@salesforce/schema/Contact.Household_Role__c';
import PRIMARY from '@salesforce/schema/Contact.Primary_Member__c';
import DRIVER from '@salesforce/schema/Contact.Licensed_Driver__c';
import PREFERS from '@salesforce/schema/Contact.Preferred_Contact_Method__c';
import ACCOUNT_ID from '@salesforce/schema/Contact.AccountId';
import ACCOUNT_NAME from '@salesforce/schema/Contact.Account.Name';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const OPTIONAL_FIELDS = [FIRST_NAME, LAST_NAME, TITLE, EMAIL, PHONE, MOBILE, BIRTHDATE, ROLE, PRIMARY, DRIVER, PREFERS, ACCOUNT_ID, ACCOUNT_NAME];
const POLICY_FIELDS = [
    'Policy_Participant__c.Role__c',
    'Policy_Participant__c.Status__c',
    'Policy_Participant__c.Policy__c',
    'Policy_Participant__c.Policy__r.Name',
    'Policy_Participant__c.Policy__r.Line_of_Business__c'
];
const MS_PER_YEAR = 365.25 * 86400000;

/** A person at a glance: who they are to the customer, how they like to be reached, and the policies they are on. */
export default class AntsuranceContactSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    person;
    roles = [];
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: [NAME], optionalFields: OPTIONAL_FIELDS })
    wiredContact({ data, error }) {
        if (data) {
            const value = (field) => getFieldValue(data, field);
            const initials = [value(FIRST_NAME), value(LAST_NAME)]
                .filter(Boolean)
                .map((part) => part.charAt(0).toUpperCase())
                .join('');
            this.errorMessage = undefined;
            this.person = {
                name: value(NAME),
                initials,
                role: value(ROLE) ?? value(TITLE) ?? 'Contact',
                accountId: value(ACCOUNT_ID),
                accountName: value(ACCOUNT_NAME),
                email: value(EMAIL),
                phone: value(PHONE),
                mobile: value(MOBILE),
                prefers: value(PREFERS),
                birthdate: value(BIRTHDATE),
                isPrimary: value(PRIMARY) === true,
                isDriver: value(DRIVER) === true
            };
        } else if (error) {
            this.person = undefined;
            this.errorMessage = error.body?.message ?? 'This contact could not be loaded.';
        }
    }

    @wire(getRelatedListRecords, { parentRecordId: '$recordId', relatedListId: 'Policy_Roles__r', fields: POLICY_FIELDS })
    wiredRoles({ data }) {
        this.roles = data ? data.records : [];
    }

    get tags() {
        const tags = [];
        if (this.person.isPrimary) {
            tags.push('Main contact');
        }
        if (this.person.isDriver) {
            tags.push('Licensed driver');
        }
        if (this.person.birthdate) {
            const age = Math.floor((Date.now() - new Date(`${this.person.birthdate}T00:00:00`).getTime()) / MS_PER_YEAR);
            tags.push(`Age ${age}`);
        }
        return tags;
    }

    get hasTags() {
        return this.tags.length > 0;
    }

    /** Ways to reach the person, with the one they prefer first. */
    get ways() {
        const { phone, mobile, email, prefers } = this.person;
        const ways = [
            { key: 'Phone', icon: 'utility:call', value: phone, href: `tel:${phone}` },
            { key: 'Text', icon: 'utility:phone_portrait', value: mobile, href: `tel:${mobile}` },
            { key: 'Email', icon: 'utility:email', value: email, href: `mailto:${email}` }
        ].filter((way) => way.value);
        return ways
            .map((way) => {
                const isPreferred = way.key === prefers;
                return { ...way, isPreferred, className: isPreferred ? 'c-reach__way c-reach__way_preferred' : 'c-reach__way' };
            })
            .sort((first, second) => Number(second.isPreferred) - Number(first.isPreferred));
    }

    get hasPolicies() {
        return this.policies.length > 0;
    }

    /** "On 2 policies: personal auto and homeowners." */
    get policiesLine() {
        const lines = [...new Set(this.policies.map((policy) => (policy.line ?? '').toLowerCase()).filter(Boolean))];
        const count = this.policies.length;
        const listed = lines.length > 1 ? `${lines.slice(0, -1).join(', ')} and ${lines[lines.length - 1]}` : lines[0];
        return `On ${count} ${count === 1 ? 'policy' : 'policies'}${listed ? `: ${listed}` : ''}.`;
    }

    /** One row per policy, however many roles the person has on it. */
    get policies() {
        const byPolicy = new Map();
        this.roles.forEach((record) => {
            const policyId = record.fields.Policy__c.value;
            const policy = record.fields.Policy__r.value;
            const role = record.fields.Role__c.value;
            if (!policy) {
                return;
            }
            const line = policy.fields.Line_of_Business__c.value;
            const existing = byPolicy.get(policyId);
            if (existing) {
                existing.role = `${existing.role}, ${role.toLowerCase()}`;
            } else {
                byPolicy.set(policyId, {
                    key: policyId,
                    policyId,
                    number: policy.fields.Name.value,
                    line,
                    // Sentence case, so two roles read "Named insured, driver".
                    role: role.charAt(0) + role.slice(1).toLowerCase(),
                    icon: lineIcon(line).name,
                    url: `/lightning/r/Policy__c/${policyId}/view`
                });
            }
        });
        return [...byPolicy.values()];
    }

    get accountUrl() {
        return `/lightning/r/Account/${this.person.accountId}/view`;
    }

    open(event, recordId, objectApiName) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    handleOpenAccount(event) {
        this.open(event, this.person.accountId, 'Account');
    }

    handleOpenPolicy(event) {
        this.open(event, event.currentTarget.dataset.recordId, 'Policy__c');
    }
}
