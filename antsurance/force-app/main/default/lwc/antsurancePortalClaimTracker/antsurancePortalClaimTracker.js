import { LightningElement, api } from 'lwc';

/**
 * A claim's progress as a customer understands it: five steps, the one it is on, and the last update in plain words.
 * `compact` is the small form used inside the conversation.
 */
export default class AntsurancePortalClaimTracker extends LightningElement {
    @api claim;
    @api compact = false;
    /** Whether the whole tracker opens the claim when pressed. */
    @api linked = false;

    get rootClass() {
        return this.compact ? 'c-claim c-claim_compact' : 'c-claim';
    }

    get steps() {
        return (this.claim?.steps ?? []).map((step, index) => ({
            ...step,
            key: `${index}`,
            className: `c-claim__step c-claim__step_${step.state}`,
            isDone: step.state === 'done',
            current: step.state === 'current' ? 'step' : undefined
        }));
    }

    get statusClass() {
        if (!this.claim?.isOpen) {
            return 'c-chip';
        }
        return this.claim.statusWord === 'Payment sent' ? 'c-chip c-chip_good' : 'c-chip c-chip_clay';
    }

    get about() {
        const claim = this.claim;
        const parts = [];
        if (claim?.policyLine) {
            // The policy number and the date each stay in one piece when the line wraps.
            parts.push(`${claim.policyLine} policy ${String(claim.policyNumber ?? '').replace(/-/g, '\u2011')}`);
        }
        if (claim?.lossDateText) {
            parts.push(`happened\u00A0${claim.lossDateText.replace(/ /g, '\u00A0')}`);
        }
        // On the claim's own page, where there is room, when it was reported too.
        if (!this.linked && !this.compact && claim?.reportedText) {
            parts.push(`reported\u00A0${claim.reportedText.replace(/ /g, '\u00A0')}`);
        }
        return parts.join(', ');
    }

    get paid() {
        return this.claim?.paidText ? `Paid so far: ${this.claim.paidText}` : '';
    }

    get adjuster() {
        return this.claim?.handler ? `Your adjuster is ${this.claim.handler}.` : '';
    }

    handleOpen() {
        this.dispatchEvent(new CustomEvent('open', { detail: { page: 'claim', recordId: this.claim.id }, bubbles: true, composed: true }));
    }
}
