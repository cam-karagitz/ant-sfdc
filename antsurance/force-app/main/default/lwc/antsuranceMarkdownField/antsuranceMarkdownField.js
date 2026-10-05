import { LightningElement, api, wire } from 'lwc';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
import { loadBrandFonts } from 'c/antsuranceFonts';

/**
 * Shows one long text field as rendered Markdown, with editing in place. Point it at any
 * long text field through its page properties, for example a customer brief or underwriting notes.
 */
export default class AntsuranceMarkdownField extends LightningElement {
    @api recordId;
    @api objectApiName;
    /** API name of the long text field to show, such as Customer_Brief__c. */
    @api fieldApiName;
    @api title = 'Notes';
    /** Kept so existing pages that set it still load. The empty state is now a single "Add" line. */
    @api emptyText = 'Nothing written yet.';
    /** Draw nothing while the field is empty, for a page where an empty note box would only be clutter. */
    @api hideWhenEmpty = false;

    value;
    isLoaded = false;
    isEditing = false;
    isSaving = false;
    draft = '';
    errorMessage;

    get fields() {
        return this.objectApiName && this.fieldApiName ? [`${this.objectApiName}.${this.fieldApiName}`] : undefined;
    }

    @wire(getRecord, { recordId: '$recordId', fields: '$fields' })
    wiredRecord({ data, error }) {
        if (data) {
            this.value = data.fields[this.fieldApiName]?.value ?? '';
            this.isLoaded = true;
            this.errorMessage = undefined;
        } else if (error) {
            this.isLoaded = true;
            this.errorMessage = error.body?.message ?? 'This field could not be loaded.';
        }
    }

    connectedCallback() {
        loadBrandFonts(this);
    }

    get hasValue() {
        return Boolean(this.value);
    }

    /** With nothing written and nobody writing, the card steps back to a single line. */
    get isEmptyAndIdle() {
        return this.isLoaded && !this.hasValue && !this.isEditing && !this.errorMessage;
    }

    /** The quiet "Add" line, unless the page asked for nothing at all while the field is empty. */
    get showAdd() {
        return this.isEmptyAndIdle && !(this.hideWhenEmpty === true || this.hideWhenEmpty === 'true');
    }

    get addLabel() {
        return `Add ${this.title.toLowerCase()}`;
    }

    get canEdit() {
        return this.isLoaded && !this.isEditing && !this.errorMessage;
    }

    get editLabel() {
        return `Edit ${this.title.toLowerCase()}`;
    }

    handleEdit() {
        this.draft = this.value ?? '';
        this.isEditing = true;
    }

    renderedCallback() {
        // The textarea is not bound to the draft, so it is filled once when editing starts.
        const input = this.refs.input;
        if (input && !input.dataset.filled) {
            input.value = this.draft;
            input.dataset.filled = 'true';
            input.focus();
        }
    }

    handleInput(event) {
        this.draft = event.target.value;
    }

    handleCancel() {
        this.isEditing = false;
        this.errorMessage = undefined;
    }

    async handleSave() {
        this.isSaving = true;
        this.errorMessage = undefined;
        try {
            await updateRecord({ fields: { Id: this.recordId, [this.fieldApiName]: this.draft.trim() } });
            this.isEditing = false;
        } catch (error) {
            this.errorMessage = error.body?.message ?? 'That could not be saved.';
        } finally {
            this.isSaving = false;
        }
    }
}
