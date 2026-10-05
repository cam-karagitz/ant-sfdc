import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import CURRENCY from '@salesforce/i18n/currency';
import LOCALE from '@salesforce/i18n/locale';
import getCustomerSummary from '@salesforce/apex/AntsuranceInsightsController.getCustomerSummary';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { lineIcon } from 'c/antsuranceIcons';

const MS_PER_DAY = 86400000;
// Renewals this close are called out on the policy tile.
const RENEWAL_WINDOW_DAYS = 60;
const MAX_FACES = 4;
const STATUS_TONES = { Active: 'good', 'Pending Renewal': 'warn', Lapsed: 'bad', Cancelled: 'bad', Expired: 'bad' };

// The card lists this many policies; a customer or agency with more gets a link to the full list.
const POLICIES_SHOWN = 5;

/** A customer's household or business at a glance: who is in it, how the book is performing and each policy. */
export default class AntsuranceCustomerSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    summary;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getCustomerSummary, { accountId: '$recordId' })
    wiredSummary({ data, error }) {
        if (data) {
            this.summary = data;
            this.errorMessage = undefined;
        } else if (error) {
            this.summary = undefined;
            this.errorMessage = error.body?.message ?? 'The customer summary could not be loaded.';
        }
    }

    get cardTitle() {
        return this.summary?.isAgency ? 'Book of business' : 'Customer at a glance';
    }

    get listTitle() {
        return this.summary.isAgency ? 'Policies produced' : 'Policies';
    }

    get emptyMessage() {
        return this.summary.isAgency ? 'This agency has not placed any policies yet.' : 'This customer has no policies yet.';
    }

    get sinceLabel() {
        const since = this.summary.customerSince;
        if (!since) {
            return this.summary.isAgency ? 'Agency partner' : 'New customer';
        }
        // Counted by the calendar on the server: a division by the length of a year reads a year short on an anniversary.
        const years = this.summary.yearsSince ?? 0;
        const year = since.slice(0, 4);
        // An agency is appointed to sell for Antsurance; it is not a customer.
        const lead = this.summary.isAgency ? `Appointed ${year}` : `Customer since ${year}`;
        if (years < 1) {
            return lead;
        }
        return `${lead}, ${years} ${years === 1 ? 'year' : 'years'}`;
    }

    get phoneUrl() {
        return `tel:${this.summary.phone.replace(/[^+\d]/g, '')}`;
    }

    get hasMembers() {
        return this.summary.members.length > 0;
    }

    get membersLabel() {
        return this.summary.isAgency ? 'Contacts' : 'Members';
    }

    get faces() {
        const members = this.summary.members;
        const shown = members.slice(0, MAX_FACES).map((member) => ({
            key: member.recordId,
            recordId: member.recordId,
            url: `/lightning/r/Contact/${member.recordId}/view`,
            title: member.role ? `${member.name}, ${member.role}` : member.name,
            initials: member.name
                .split(/\s+/)
                .map((word) => word.charAt(0).toUpperCase())
                .slice(0, 2)
                .join('')
        }));
        const extra = members.length - shown.length;
        if (extra > 0) {
            shown.push({ key: 'more', initials: `+${extra}`, title: `${extra} more` });
        }
        return shown;
    }

    get stats() {
        const { policiesInForce, openClaims, openRequests } = this.summary;
        if (this.summary.isAgency) {
            // An agency's book: everything it has placed, how much of it is in force, and what is open on it.
            // The count of every policy, not the length of the list, which holds the first fifty.
            const produced = this.summary.policyCount ?? this.summary.policies.length;
            return [
                { label: produced === 1 ? 'policy produced' : 'policies produced', value: produced },
                { label: 'in force', value: policiesInForce },
                { label: openClaims === 1 ? 'open claim' : 'open claims', value: openClaims }
            ];
        }
        return [
            { label: policiesInForce === 1 ? 'policy in force' : 'policies in force', value: policiesInForce },
            { label: openClaims === 1 ? 'open claim' : 'open claims', value: openClaims },
            { label: openRequests === 1 ? 'open request' : 'open requests', value: openRequests }
        ];
    }

    money(amount) {
        return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, notation: 'compact', maximumFractionDigits: 1 }).format(amount ?? 0);
    }

    get premiumLabel() {
        return this.money(this.summary.premiumInForce);
    }

    get lossLabel() {
        return this.money(this.summary.incurredLosses);
    }

    // Both bars share one scale, set by whichever amount is larger.
    barStyle(amount) {
        const scale = Math.max(this.summary.premiumInForce, this.summary.incurredLosses, 1);
        return `width: ${Math.max((amount / scale) * 100, amount > 0 ? 2 : 0).toFixed(1)}%`;
    }

    get premiumBarStyle() {
        return this.barStyle(this.summary.premiumInForce);
    }

    get lossBarStyle() {
        return this.barStyle(this.summary.incurredLosses);
    }

    // Claims above a year of premium are worth a second look; a single large loss can do that to any customer.
    get lossBarClass() {
        return this.summary.incurredLosses > this.summary.premiumInForce ? 'c-compare__bar c-compare__bar_over' : 'c-compare__bar c-compare__bar_loss';
    }

    get compareNote() {
        const { premiumInForce, incurredLosses, openClaims, claimCount } = this.summary;
        if (!incurredLosses) {
            // A claim with nothing reserved or paid adds nothing to the bar, and is still a claim.
            if (openClaims > 0) {
                return `${openClaims} open ${openClaims === 1 ? 'claim' : 'claims'}, no reserve set yet.`;
            }
            return claimCount > 0 ? 'Claims on file, with nothing reserved or paid.' : 'No claims on these policies.';
        }
        if (!premiumInForce) {
            return 'Claims on file, with no premium in force.';
        }
        const ratio = incurredLosses / premiumInForce;
        if (ratio >= 1) {
            return `Claims are ${ratio.toFixed(1)} times a year of premium.`;
        }
        return `Claims are ${Math.round(ratio * 100)}% of a year of premium.`;
    }

    get compareLabel() {
        return `${this.premiumLabel} premium a year against ${this.lossLabel} of claims incurred. ${this.compareNote}`;
    }

    /** An agency's card is its numbers only: the policies it produced are listed in the page's main column. */
    get isSummaryOnly() {
        return this.summary.isAgency === true && this.hasPolicies;
    }

    get hasPolicies() {
        return this.summary.policies.length > 0;
    }

    get policies() {
        const today = new Date().setHours(0, 0, 0, 0);
        const money = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 });
        return this.summary.policies.slice(0, POLICIES_SHOWN).map((policy) => {
            const days = policy.expirationDate
                ? Math.round((new Date(`${policy.expirationDate}T00:00:00`).getTime() - today) / MS_PER_DAY)
                : undefined;
            const renewal =
                policy.inForce && days !== undefined && days >= 0 && days <= RENEWAL_WINDOW_DAYS ? `renews in ${days} ${days === 1 ? 'day' : 'days'}` : undefined;
            return {
                ...policy,
                icon: lineIcon(policy.lineOfBusiness).name,
                tileClass: `c-tile__icon ${lineIcon(policy.lineOfBusiness).tileClass}`,
                premiumLabel: money.format(policy.premium),
                detail: [this.summary.isAgency ? policy.policyholder : policy.name, renewal].filter(Boolean).join(', '),
                title: `${policy.lineOfBusiness} policy ${policy.name}`,
                url: `/lightning/r/Policy__c/${policy.recordId}/view`,
                statusClass: `c-tile__status c-tile__status_${STATUS_TONES[policy.status] ?? 'neutral'}`
            };
        });
    }

    /** A long list shows its first few policies and a link to the rest. */
    get hasMorePolicies() {
        return this.summary.policies.length > POLICIES_SHOWN;
    }

    get viewAllLabel() {
        return `View all ${this.summary.policyCount ?? this.summary.policies.length}`;
    }

    get policyRelationship() {
        return this.summary.isAgency ? 'Policies_Produced__r' : 'Policies__r';
    }

    get viewAllUrl() {
        return `/lightning/r/Account/${this.recordId}/related/${this.policyRelationship}/view`;
    }

    handleViewAll(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: { recordId: this.recordId, objectApiName: 'Account', relationshipApiName: this.policyRelationship, actionName: 'view' }
        });
    }

    navigate(event, objectApiName) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, objectApiName, actionName: 'view' }
        });
    }

    handleOpenPolicy(event) {
        this.navigate(event, 'Policy__c');
    }

    handleOpenContact(event) {
        this.navigate(event, 'Contact');
    }
}
