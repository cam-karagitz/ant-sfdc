import { LightningElement, api } from 'lwc';

/**
 * Where the full Antsurance app draws a record's own page card inside the chat. Ask Claude installed
 * alone has no such cards, so this draws nothing: every record is shown with the compact card that
 * antsuranceClaudeRecord draws from the facts sent with the block.
 */
export default class AntsuranceClaudePageCard extends LightningElement {
    @api card;
    @api recordId;
}
