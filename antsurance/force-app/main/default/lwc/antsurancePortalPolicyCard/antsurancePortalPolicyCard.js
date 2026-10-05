import { LightningElement, api } from 'lwc';

const ICONS = [
    ['Auto', 'utility:travel_and_places'],
    ['Home', 'utility:home'],
    ['Renters', 'utility:home'],
    ['Umbrella', 'utility:shield'],
    ['Property', 'utility:company'],
    ['Liability', 'utility:shield'],
    ['Compensation', 'utility:people']
];

/**
 * One of the customer's policies as a card: what it is, what it insures, what it costs and when it renews.
 * Pressing it asks the portal to open the policy. `compact` is the small form used inside the conversation.
 */
export default class AntsurancePortalPolicyCard extends LightningElement {
    @api policy;
    @api compact = false;

    get cardClass() {
        return this.compact ? 'c-policy c-policy_compact' : 'c-policy';
    }

    get icon() {
        const line = this.policy?.line ?? '';
        const match = ICONS.find(([word]) => line.includes(word));
        return match ? match[1] : 'utility:shield';
    }

    get statusClass() {
        if (this.policy?.status === 'Active') {
            return 'c-chip c-chip_good';
        }
        return this.policy?.status === 'Renewing soon' ? 'c-chip c-chip_watch' : 'c-chip';
    }

    get renewal() {
        const policy = this.policy;
        if (!policy?.inForce || !policy.endsText) {
            return policy?.endsText ? `Ended ${policy.endsText}` : '';
        }
        return `Renews ${policy.endsText}`;
    }

    get renewalOffer() {
        const policy = this.policy;
        return policy?.renewalPremiumText ? `Renewal offer ${policy.renewalPremiumText} a year, ${policy.renewalChangeText}` : '';
    }

    get label() {
        return `Open your ${this.policy?.line ?? ''} policy`;
    }

    handleOpen() {
        this.dispatchEvent(new CustomEvent('open', { detail: { page: 'policy', recordId: this.policy.id }, bubbles: true, composed: true }));
    }
}
