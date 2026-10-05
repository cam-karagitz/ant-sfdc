import { LightningElement, api } from 'lwc';
import addRequestNote from '@salesforce/apex/AntsurancePortalController.addRequestNote';
import withdrawRequest from '@salesforce/apex/AntsurancePortalController.withdrawRequest';

/**
 * A service request's own page: what was asked, where it stands, the details that were sent, and what the
 * customer can do now (add a note for the team, withdraw it while it has only been received, ask Claude).
 * A note or a withdrawal is filed a moment after it is sent, so the page says so and asks the app to read
 * the request again (`changed`).
 */
export default class AntsurancePortalRequest extends LightningElement {
    @api request;
    note = '';
    isSending = false;
    isConfirming = false;
    message;
    failure;

    get steps() {
        return (this.request?.steps ?? []).map((step, index) => ({
            ...step,
            key: `${index}`,
            className: `c-track__step c-track__step_${step.state}`,
            isDone: step.state === 'done',
            current: step.state === 'current' ? 'step' : undefined
        }));
    }

    get statusClass() {
        return this.request.isOpen ? 'c-chip c-chip_clay' : 'c-chip';
    }

    get sentLine() {
        const parts = [`Sent ${this.request.openedText}`];
        if (this.request.policyNumber) {
            parts.push(`about ${this.request.policyLine ? `your ${this.request.policyLine.toLowerCase()} policy` : `policy ${this.request.policyNumber}`}`);
        }
        return parts.join(', ');
    }

    get handledBy() {
        return this.request.handler ? `${this.request.handler} at Antsurance has it.` : '';
    }

    /** Who has it is said once: in the latest line while it is only received, here once someone is working on it. */
    get showHandler() {
        return Boolean(this.request.isOpen && this.request.handler);
    }

    get facts() {
        return (this.request.facts ?? []).map((fact, index) => ({ ...fact, key: `${index}` }));
    }

    /** A request sent from the portal carries the customer's own note; one taken by staff is their summary of it. */
    get askedTitle() {
        return this.hasFacts ? 'In your words' : 'What was asked';
    }

    get hasFacts() {
        return this.facts.length > 0;
    }

    get notes() {
        return (this.request.notes ?? []).map((note, index) => ({ ...note, key: `${index}` }));
    }

    get hasNotes() {
        return this.notes.length > 0;
    }

    get sendDisabled() {
        return this.isSending || !this.note.trim();
    }

    handleNote(event) {
        this.note = event.target.value;
    }

    async handleAddNote() {
        this.isSending = true;
        this.failure = undefined;
        try {
            const receipt = await addRequestNote({ requestId: this.request.id, text: this.note });
            this.message = receipt.message;
            this.note = '';
            const area = this.template.querySelector('textarea');
            if (area) {
                area.value = '';
            }
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (error) {
            this.failure = error?.body?.message ?? 'That could not be sent. Please try again.';
        } finally {
            this.isSending = false;
        }
    }

    handleWithdraw() {
        this.isConfirming = true;
    }

    handleKeep() {
        this.isConfirming = false;
    }

    async handleConfirmWithdraw() {
        this.isSending = true;
        this.failure = undefined;
        try {
            const receipt = await withdrawRequest({ requestId: this.request.id });
            this.message = receipt.message;
            this.isConfirming = false;
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (error) {
            this.failure = error?.body?.message ?? 'That could not be done. Please try again.';
        } finally {
            this.isSending = false;
        }
    }

    handleAsk() {
        this.dispatchEvent(new CustomEvent('ask', { detail: { text: `Where does my request "${this.request.title}" stand?` } }));
    }

    handlePolicy() {
        this.dispatchEvent(new CustomEvent('open', { detail: { page: 'policy', recordId: this.request.policyId } }));
    }
}
