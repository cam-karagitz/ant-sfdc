import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';

const STATE = { OPEN: 'open', SAVING: 'saving', SAVED: 'saved', CANCELLED: 'cancelled' };
const STATUS_LABELS = { open: 'Needs your OK', saving: 'Saving', saved: 'Saved', cancelled: 'Canceled' };
const SAVE_ERROR = 'Salesforce did not save this. Check the fields and try again.';

/**
 * A Salesforce form in the chat, filled in with Claude's suggestions. It is a standard record
 * form, so the user's own access, required fields and validation rules apply, and nothing is
 * written until they press the save button.
 */
export default class AntsuranceClaudeForm extends NavigationMixin(LightningElement) {
    /** { mode, objectApiName, objectLabel, recordId, recordTypeId, title, fields: [{ name, label, value, suggested, required, wide, current }] } */
    @api spec;
    /** The tool call this form answers, passed back with the outcome. */
    @api blockId;
    /** True in the utility bar panel: one column, the fields that matter first, the rest on request. */
    @api compact = false;

    /**
     * Set when this form was finished somewhere else: the same form, opened full size from the
     * panel, was saved or cancelled there. { saved, recordId }
     */
    @api
    get resolved() {
        return this.outcome;
    }
    set resolved(value) {
        this.outcome = value;
        if (value && this.isOpen) {
            this.savedId = value.recordId;
            this.state = value.saved ? STATE.SAVED : STATE.CANCELLED;
        }
    }
    outcome;
    // Compact: whether the fields Claude left empty are showing. Once open they stay open, so nothing typed is lost.
    showMore = false;

    sparkUrl = CLAUDE_SPARK;
    state = STATE.OPEN;
    errorMessage;
    savedId;
    // Suggested fields the user has changed, which no longer carry Claude's mark.
    changed = [];

    get isEditing() {
        return this.spec?.mode === 'edit';
    }

    get thing() {
        return (this.spec?.objectLabel ?? 'record').toLowerCase();
    }

    get isOpen() {
        return this.state === STATE.OPEN || this.state === STATE.SAVING;
    }

    get isSaving() {
        return this.state === STATE.SAVING;
    }

    get isSaved() {
        return this.state === STATE.SAVED;
    }

    get isCancelled() {
        return this.state === STATE.CANCELLED;
    }

    get cardClass() {
        return `c-form c-form_${this.state}${this.compact ? ' c-form_mini' : ''}`;
    }

    get iconName() {
        return this.isSaved ? 'utility:success' : this.isEditing ? 'utility:edit' : 'utility:new';
    }

    get statusLabel() {
        return STATUS_LABELS[this.state];
    }

    get saveLabel() {
        return this.isEditing ? 'Save changes' : `Create ${this.thing}`;
    }

    get hasSuggestions() {
        return (this.spec?.fields ?? []).some((field) => field.suggested);
    }

    get allFields() {
        return (this.spec?.fields ?? []).map((field) => {
            const marked = field.suggested && !this.changed.includes(field.name);
            return {
                ...field,
                key: field.name,
                className: `c-field${field.wide ? ' c-field_wide' : ''}${marked ? ' c-field_suggested' : ''}`,
                marked,
                was: field.suggested && field.current ? `Now ${field.current}` : undefined
            };
        });
    }

    /**
     * In the panel: what Claude filled in and what Salesforce requires. A country stays with its
     * state, which cannot be picked without it.
     */
    isPrimary(field, all) {
        if (field.suggested || field.required) {
            return true;
        }
        const state = field.name.replace(/CountryCode$/, 'StateCode');
        return state !== field.name && all.some((other) => other.name === state && (other.suggested || other.required));
    }

    get fields() {
        const all = this.allFields;
        if (!this.compact) {
            return all;
        }
        const primary = all.filter((field) => this.isPrimary(field, all));
        // The rest follow the first set, so opening them moves nothing the user has already filled in.
        return this.showMore ? [...primary, ...all.filter((field) => !primary.includes(field))] : primary;
    }

    get moreCount() {
        const all = this.allFields;
        return all.filter((field) => !this.isPrimary(field, all)).length;
    }

    get hasMore() {
        return this.compact && !this.showMore && this.moreCount > 0;
    }

    get moreLabel() {
        return `More fields (${this.moreCount})`;
    }

    get canExpand() {
        return this.compact && this.isOpen;
    }

    get expandLabel() {
        return `Expand ${this.spec?.title ?? 'the form'}`;
    }

    handleMore() {
        this.showMore = true;
    }

    /** The record form has its fields now and is about to grow; the chat keeps the answer in view. */
    handleLoad() {
        this.dispatchEvent(new CustomEvent('blockresize', { bubbles: true }));
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }

    get resultMessage() {
        const label = this.spec?.objectLabel ?? 'Record';
        return this.isEditing ? `${label} updated.` : `${label} created.`;
    }

    get resultLink() {
        return `Open ${this.thing}`;
    }

    get resultUrl() {
        return `/lightning/r/${this.savedId}/view`;
    }

    handleChange(event) {
        const name = event.currentTarget.dataset.name;
        if (!this.changed.includes(name)) {
            this.changed = [...this.changed, name];
        }
    }

    /** The save button: this is the only place the form writes, through the standard record form. */
    handleSave() {
        const inputs = [...this.template.querySelectorAll('lightning-input-field')];
        if (!inputs.every((input) => input.reportValidity())) {
            return;
        }
        this.errorMessage = undefined;
        this.state = STATE.SAVING;
        this.refs.form.submit();
    }

    handleSuccess(event) {
        this.savedId = event.detail.id;
        this.state = STATE.SAVED;
        const edits = this.changed.length ? ` Before saving they changed your suggestion for: ${this.changed.join(', ')}.` : '';
        this.report({
            saved: true,
            recordId: this.savedId,
            outcome: `The user pressed the save button. ${this.resultMessage} Its Id is ${this.savedId}.${edits}`
        });
    }

    handleError(event) {
        // Each field shows its own error; this line is for the ones that belong to no field.
        this.state = STATE.OPEN;
        const onFields = Object.keys(event.detail?.output?.fieldErrors ?? {}).length > 0;
        this.errorMessage = onFields ? undefined : event.detail?.detail || event.detail?.message || SAVE_ERROR;
    }

    handleCancel() {
        this.state = STATE.CANCELLED;
        this.report({ saved: false, outcome: 'The user pressed Cancel on the form. Nothing was written.' });
    }

    report(detail) {
        this.dispatchEvent(new CustomEvent('formdone', { detail: { blockId: this.blockId, title: this.spec.title, ...detail } }));
    }

    handleOpen(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: this.savedId, actionName: 'view' } });
    }
}
