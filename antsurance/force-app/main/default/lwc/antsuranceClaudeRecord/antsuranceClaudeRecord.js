import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// What Apex calls the card drawn from the facts sent with the block, as opposed to a record's own page card.
const COMPACT = 'compact';

/**
 * One record's summary card. Where there is room, a record that has a card on its own page is
 * shown with that same card, and a record without one gets a card drawn from the facts sent with
 * the block. In the utility panel every record is a small summary: its name, its status and the
 * three facts that matter for its kind, with the full card behind Expand.
 */
export default class AntsuranceClaudeRecord extends NavigationMixin(LightningElement) {
    /** { recordId, objectApiName, card, icon, eyebrow, name, status, tone, figure, figureLabel, keyFacts: [{ label, value }], facts: [{ label, value }], body } */
    @api spec;
    /** True in the utility bar panel, which is too narrow for a page card. */
    @api compact = false;

    get isMini() {
        return this.compact;
    }

    get pageCard() {
        return this.spec?.card;
    }

    /** The three facts for the panel. Older answers carry none, so the first general facts stand in. */
    get keyFacts() {
        const picked = this.spec?.keyFacts?.length ? this.spec.keyFacts : (this.spec?.facts ?? []).slice(0, 3);
        return picked.map((fact, index) => ({ ...fact, key: `key-fact-${index}` }));
    }

    get keyFactsStyle() {
        return `grid-template-columns: repeat(${Math.max(this.keyFacts.length, 1)}, minmax(0, 1fr))`;
    }

    get miniClass() {
        return `c-mini c-mini-record c-mini-record_${this.spec?.tone ?? 'neutral'}`;
    }

    get expandLabel() {
        return `Expand ${this.spec?.name ?? 'the record'}`;
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }

    /** True unless the record has a page card of its own, which antsuranceClaudePageCard draws. */
    get isCompact() {
        return !this.pageCard || this.pageCard === COMPACT;
    }

    get iconName() {
        return this.spec?.icon ?? 'utility:record';
    }

    get cardClass() {
        return `c-record c-record_${this.spec?.tone ?? 'neutral'}`;
    }

    get statusClass() {
        return `c-chip c-chip_${this.spec?.tone ?? 'neutral'}`;
    }

    get facts() {
        return (this.spec?.facts ?? []).map((fact, index) => ({ ...fact, key: `fact-${index}` }));
    }

    /** Above a page card: who and what the record belongs to, which its own page says in the header. */
    get frameFacts() {
        return this.facts.filter((fact) => ['Customer', 'Policy', 'Line', 'Policy sale', 'Handled by', 'Location'].includes(fact.label)).slice(0, 3);
    }

    get url() {
        return `/lightning/r/${this.spec?.recordId}/view`;
    }

    handleOpen(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.spec.recordId, actionName: 'view' }
        });
    }
}
