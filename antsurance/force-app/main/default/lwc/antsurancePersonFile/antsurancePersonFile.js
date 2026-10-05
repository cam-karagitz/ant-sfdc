import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import getFile from '@salesforce/apex/AntsurancePersonFileController.getFile';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon, roleIcon } from 'c/antsuranceIcons';

const WHOLE = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
// Policies shown at a time. Few people are on more.
const PAGE_SIZE = 5;
const FALLBACK_ERROR = "This person's policies and claims could not be loaded.";

/** "Named Insured" and "Driver" as "Named insured and driver". */
function rolesInWords(roles) {
    const words = roles.map((role) => role.toLowerCase());
    if (words.length === 0) {
        return 'No role recorded';
    }
    const joined = words.length < 3 ? words.join(' and ') : `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`;
    return joined.charAt(0).toUpperCase() + joined.slice(1);
}

/**
 * Under a participant's fields: the person's file across the company. A participant record holds one
 * role on one policy; an adjuster or underwriter wants the rest: every policy the person is on and
 * what they are on each, the claims and requests that name them, and who else is on this policy.
 */
export default class AntsurancePersonFile extends NavigationMixin(LightningElement) {
    @api recordId;

    file;
    errorMessage;
    bones = [1, 2];
    pageSize = PAGE_SIZE;
    policyPage = 0;
    /** The tab being shown: policies, cases or others. */
    tab = 'policies';

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getFile, { participantId: '$recordId' })
    wiredFile({ data, error }) {
        if (data) {
            this.file = data;
            this.errorMessage = undefined;
        } else if (error) {
            this.file = undefined;
            this.errorMessage = error.body?.message ?? FALLBACK_ERROR;
        }
    }

    get hasContact() {
        return Boolean(this.file.contactId);
    }

    get policyCount() {
        return this.file.policies.length;
    }

    /** The whole picture in one sentence: "Maria is on 2 policies, with 1 open claim." */
    get headline() {
        const { firstName, personName, policies, openClaimCount } = this.file;
        if (!this.hasContact) {
            return `${personName} is on this policy, with no contact record to look further.`;
        }
        const reach = policies.length > 1 ? `on ${policies.length} policies` : 'on this policy only';
        let claims = 'with no open claims';
        if (openClaimCount === 1) {
            claims = 'with 1 open claim';
        } else if (openClaimCount > 1) {
            claims = `with ${openClaimCount} open claims`;
        }
        return `${firstName} is ${reach}, ${claims}.`;
    }

    get policies() {
        return this.file.policies.map((policy) => ({
            ...policy,
            icon: lineIcon(policy.line),
            rolesLine: rolesInWords(policy.roles),
            lineAndItem: [policy.line, policy.insuredItem].filter(Boolean).join(', '),
            // Most policies are active, so only the ones that are not say so.
            showsStatus: Boolean(policy.status) && policy.status !== 'Active',
            url: `/lightning/r/Policy__c/${policy.policyId}/view`
        }));
    }

    get pagePolicies() {
        return this.policies.slice(this.policyPage * PAGE_SIZE, (this.policyPage + 1) * PAGE_SIZE);
    }

    handlePolicyPage(event) {
        this.policyPage = event.detail.page;
    }

    /** Three tabs, each saying how many are behind it. Open claims tint their count. */
    get tabs() {
        return [
            { value: 'policies', label: 'Policies and roles', count: this.policyCount, icon: 'utility:shield' },
            { value: 'cases', label: 'Claims and requests', count: this.file.caseCount, icon: 'utility:case', tone: this.file.openClaimCount > 0 ? 'watch' : undefined },
            { value: 'others', label: 'Also on this policy', count: this.file.others.length, icon: 'utility:people' }
        ];
    }

    handleTab(event) {
        this.tab = event.detail.value;
    }

    get showsPolicies() {
        return this.tab === 'policies';
    }

    get showsCases() {
        return this.tab === 'cases';
    }

    get showsOthers() {
        return this.tab === 'others';
    }

    get othersTitle() {
        return `Also on this policy (${this.file.others.length})`;
    }

    get hasCases() {
        return this.file.cases.length > 0;
    }

    get noCasesText() {
        return `No claim or service request names ${this.file.firstName}.`;
    }

    get cases() {
        const day = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' });
        return this.file.cases.map((item) => {
            const happened = new Date(`${item.happenedOn}T00:00:00`);
            const parts = [`${item.kind} ${item.caseNumber}`, item.status];
            if (item.incurred) {
                parts.push(`$${WHOLE.format(item.incurred)} incurred`);
            }
            if (item.policyName) {
                parts.push(item.policyName);
            }
            let tone = item.kind === 'Claim' ? 'claim' : 'request';
            if (item.isClosed) {
                tone = 'closed';
            }
            return {
                ...item,
                day: day.format(happened),
                year: String(happened.getFullYear()),
                meta: parts.join(', '),
                dotClass: `c-case__dot c-case__dot_${tone}`,
                url: `/lightning/r/Case/${item.caseId}/view`
            };
        });
    }

    /** When more name the person than the list holds, a link to the contact, where all of them are. */
    get moreCases() {
        const { caseCount, cases } = this.file;
        return caseCount > cases.length ? `View all ${caseCount} on the contact` : undefined;
    }

    get contactUrl() {
        return `/lightning/r/Contact/${this.file.contactId}/view`;
    }

    get hasOthers() {
        return this.file.others.length > 0;
    }

    get others() {
        return this.file.others.map((person) => ({
            ...person,
            icon: roleIcon(person.role),
            // "Driver, spouse or partner": the role, then how they are related to the insured when it adds something.
            roleLine:
                person.relationship && person.relationship !== 'Self'
                    ? `${rolesInWords([person.role].filter(Boolean))}, ${person.relationship.toLowerCase()}`
                    : rolesInWords([person.role].filter(Boolean)),
            url: `/lightning/r/Policy_Participant__c/${person.participantId}/view`
        }));
    }

    handleOpen(event) {
        // The link keeps its address for "open in a new tab"; a plain click stays inside the app.
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
