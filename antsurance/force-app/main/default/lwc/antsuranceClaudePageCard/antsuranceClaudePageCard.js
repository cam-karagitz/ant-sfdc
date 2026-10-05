import { LightningElement, api } from 'lwc';

/**
 * A record's own page card, drawn inside the chat's record block: the same card the record's page
 * shows. This is the one chat component that knows the insurance pages. An org that has Ask Claude
 * alone gets a version of this component that draws nothing, and its records are shown with the
 * compact card that antsuranceClaudeRecord draws from the facts sent with the block.
 */
export default class AntsuranceClaudePageCard extends LightningElement {
    /** Which card to draw, as AntsuranceClaudeInsurance names it: case, policy, customer, contact or quote. */
    @api card;
    @api recordId;

    get isCase() {
        return this.card === 'case';
    }

    get isPolicy() {
        return this.card === 'policy';
    }

    get isCustomer() {
        return this.card === 'customer';
    }

    get isContact() {
        return this.card === 'contact';
    }

    get isQuote() {
        return this.card === 'quote';
    }
}
