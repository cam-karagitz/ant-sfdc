import { LightningElement, api, track } from 'lwc';
import submitRequest from '@salesforce/apex/AntsurancePortalController.submitRequest';
import submitClaim from '@salesforce/apex/AntsurancePortalController.submitClaim';
import findReceipt from '@salesforce/apex/AntsurancePortalController.findReceipt';

const TOPICS = ['Add Driver', 'Remove Driver', 'Add Vehicle', 'Change Address', 'Change Coverage', 'Billing Question', 'Certificate of Insurance', 'Policy Document Request', 'Cancel Policy'];
/** What happened, in a customer's words. The value is the loss type the claims team uses; the customer never sees it. */
const LOSSES = [
    { value: 'Collision', label: 'A crash or collision' },
    { value: 'Theft', label: 'Something was stolen' },
    { value: 'Vandalism', label: 'Someone damaged it on purpose' },
    { value: 'Water Damage', label: 'Water damage' },
    { value: 'Fire', label: 'Fire or smoke' },
    { value: 'Wind or Hail', label: 'Wind or hail' },
    { value: 'Glass', label: 'Broken glass' },
    { value: 'Liability', label: "I damaged someone's property" },
    { value: 'Bodily Injury', label: 'Someone was hurt' },
    { value: 'Other', label: 'Something else' }
];

/**
 * The portal's forms, by the page they live on. A field's `help` is what Claude explains when asked what it means.
 * `only` limits the policy choices to lines containing that word. `half` fields sit two to a row, so keep them
 * in pairs. `wanted` fields are not needed to send the form, but the service team will ask for them.
 */
const FORMS = {
    addDriver: {
        title: 'Add a driver',
        intro: 'Tell us who will be driving. We will confirm the change, and any difference in price, before it takes effect.',
        send: 'Send request',
        fields: [
            { name: 'policyId', label: 'Which policy', type: 'policy', only: 'Auto', required: true },
            { name: 'firstName', label: 'First name', type: 'text', required: true, half: true },
            { name: 'lastName', label: 'Last name', type: 'text', required: true, half: true },
            { name: 'dateOfBirth', label: 'Date of birth', type: 'date', half: true, wanted: true },
            { name: 'relationship', label: 'Relationship to you', type: 'select', options: ['Spouse or Partner', 'Child', 'Other Relative', 'Other'], half: true },
            { name: 'licenseNumber', label: 'License number', type: 'text', wanted: true, help: 'The number printed on their driver\'s license.' },
            { name: 'licenseState', label: 'State that issued it', type: 'text', half: true, maxLength: 2, wanted: true, help: 'Two letters, such as IL.' },
            { name: 'dateLicensed', label: 'Date first licensed', type: 'date', half: true, wanted: true, help: 'Their first full license, not a learner\'s permit.' },
            { name: 'details', label: 'Anything else we should know', type: 'area', help: 'For example, which car they will mainly drive.' }
        ]
    },
    newRequest: {
        title: 'Ask for a change',
        intro: 'Tell us what you need and a person on our service team will follow up, usually within one business day.',
        send: 'Send request',
        fields: [
            { name: 'policyId', label: 'Which policy, if it is about one', type: 'policy' },
            { name: 'topic', label: 'What it is about', type: 'select', options: TOPICS },
            { name: 'details', label: 'What would you like changed or answered', type: 'area', required: true }
        ]
    },
    newClaim: {
        title: 'File a claim',
        intro: 'Tell us what happened in your own words. An adjuster will contact you within one business day. If anyone is hurt or in danger, call 911 first.',
        send: 'File claim',
        fields: [
            { name: 'policyId', label: 'Which policy', type: 'policy', required: true },
            { name: 'dateOfLoss', label: 'When it happened', type: 'date', required: true, half: true },
            { name: 'lossType', label: 'Which is closest to what happened?', type: 'select', options: LOSSES, half: true, help: 'Pick the closest. Your adjuster confirms it.' },
            { name: 'summary', label: 'In a few words', type: 'text', maxLength: 60, help: 'A short title for the claim, such as "Rear-ended at a stop light".' },
            { name: 'whatHappened', label: 'Tell us what happened', type: 'area', required: true },
            { name: 'where', label: 'Where it happened', type: 'text' },
            { name: 'estimate', label: 'Repair estimate, if you have one', type: 'text', help: 'A rough figure from a shop or contractor. Leave it blank if you do not have one yet.' }
        ]
    }
};

/**
 * One of the portal's forms: adding a driver, asking for a change, or filing a claim. The customer fills it in,
 * or Claude fills fields for them through `fill`; either way nothing is sent until the customer presses the button.
 */
export default class AntsurancePortalForm extends LightningElement {
    @track values = {};
    @track filled = {};
    @track errors = {};
    highlighted;
    isSending = false;
    sendingStep;
    failure;
    receipt;
    photoNote;
    photoSummary;
    formKind;
    policyList = [];

    /** Which form: addDriver, newRequest or newClaim. */
    @api
    get kind() {
        return this.formKind;
    }
    set kind(value) {
        if (value !== this.formKind) {
            this.formKind = value;
            this.values = {};
            this.filled = {};
            this.errors = {};
            this.receipt = undefined;
            this.failure = undefined;
            this.photoNote = undefined;
            this.photoSummary = undefined;
            this.preselectPolicy();
        }
    }

    startPolicy;

    /** A policy to start the form on, when the customer came from that policy. */
    @api
    get presetPolicy() {
        return this.startPolicy;
    }
    set presetPolicy(value) {
        this.startPolicy = value;
        this.preselectPolicy();
    }

    /** The customer's policies, to choose from. */
    @api
    get policies() {
        return this.policyList;
    }
    set policies(value) {
        this.policyList = value ?? [];
        this.preselectPolicy();
    }

    get form() {
        return FORMS[this.formKind];
    }

    get fields() {
        return (this.form?.fields ?? []).map((field) => {
            const value = this.values[field.name] ?? '';
            const options = field.type === 'policy' ? this.policyOptions(field) : (field.options ?? []).map((option) => (typeof option === 'string' ? { value: option, label: option } : option));
            return {
                ...field,
                value,
                id: `field-${field.name}`,
                helpId: `help-${field.name}`,
                isText: field.type === 'text',
                isDate: field.type === 'date',
                isArea: field.type === 'area',
                isSelect: field.type === 'select' || field.type === 'policy',
                options: options.map((option) => ({ ...option, selected: option.value === value })),
                byClaude: Boolean(this.filled[field.name]),
                error: this.errors[field.name],
                className:
                    'c-field' +
                    (field.half ? ' c-field_half' : '') +
                    (this.filled[field.name] ? ' c-field_claude' : '') +
                    (this.highlighted === field.name ? ' c-field_pointed' : '') +
                    (this.errors[field.name] ? ' c-field_error' : '')
            };
        });
    }

    get sendLabel() {
        return this.isSending ? (this.sendingStep ?? 'Sending') : this.form.send;
    }

    /** A claim takes photos of the damage. */
    get takesPhotos() {
        return this.formKind === 'newClaim';
    }

    get photos() {
        return this.template.querySelector('c-antsurance-portal-photos');
    }

    handlePhotosChange(event) {
        this.photoSummary = event.detail;
        this.announceChange();
    }

    get receiptTitle() {
        const number = this.receipt.referenceNumber;
        if (this.formKind === 'newClaim') {
            return number ? `Claim ${number} is filed` : 'Your claim is sent';
        }
        return number ? `Request ${number} is sent` : 'Your request is sent';
    }

    get receiptNote() {
        return this.receipt.referenceNumber ? '' : 'Your reference number will show here in a moment.';
    }

    policyOptions(field) {
        return this.policyList
            .filter((policy) => policy.inForce && (!field.only || (policy.line ?? '').includes(field.only)))
            .map((policy) => ({ value: policy.id, label: `${policy.line}, ${policy.policyNumber}` }));
    }

    renderedCallback() {
        // A textarea's text is not bound by the template, so keep it in step with the values here (Claude may have filled it).
        this.template.querySelectorAll('textarea[data-name]').forEach((area) => {
            const value = this.values[area.dataset.name] ?? '';
            if (area.value !== value) {
                area.value = value;
            }
        });
    }

    /** When only one policy fits, it is the one. */
    preselectPolicy() {
        const field = this.form?.fields.find((entry) => entry.type === 'policy');
        if (!field || this.values.policyId) {
            return;
        }
        const options = this.policyOptions(field);
        if (this.startPolicy && options.some((option) => option.value === this.startPolicy)) {
            this.values = { ...this.values, policyId: this.startPolicy };
        } else if (options.length === 1 && field.required) {
            this.values = { ...this.values, policyId: options[0].value };
        }
    }

    /**
     * Puts values into fields for the customer to check. Called for Claude; fields it fills are marked until the customer edits them.
     * @param {{name: string, value: string}[]} fields The values, by field name
     * @returns {string[]} The labels of the fields that were filled
     */
    @api
    fill(fields) {
        const done = [];
        const values = { ...this.values };
        const filled = { ...this.filled };
        (fields ?? []).forEach(({ name, value }) => {
            const field = this.form?.fields.find((entry) => entry.name === name);
            if (!field || value === undefined || value === null || value === '') {
                return;
            }
            let next = String(value);
            if (field.type === 'select' && !field.options.some((option) => (option.value ?? option) === next)) {
                return;
            }
            if (field.type === 'policy' && !this.policyOptions(field).some((option) => option.value === next)) {
                return;
            }
            if (field.type === 'date') {
                next = next.slice(0, 10);
                if (!/^\d{4}-\d{2}-\d{2}$/.test(next)) {
                    return;
                }
            }
            values[name] = field.maxLength ? next.slice(0, field.maxLength) : next;
            filled[name] = true;
            done.push(field.label);
        });
        this.values = values;
        this.filled = filled;
        this.receipt = undefined;
        this.announceChange();
        return done;
    }

    /**
     * Points at a field: scrolls it into view and outlines it for a few seconds.
     * @param {string} name The field's name
     * @returns {string|undefined} The field's label when it exists on this form
     */
    @api
    highlight(name) {
        const field = this.form?.fields.find((entry) => entry.name === name);
        if (!field) {
            return undefined;
        }
        this.highlighted = name;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.template.querySelector(`[data-wrap="${name}"]`)?.scrollIntoView({ block: 'center' });
        }, 50);
        // Focus once the page has settled; focusing while it is still moving stops the scroll short.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.template.querySelector(`[data-name="${name}"]`)?.focus({ preventScroll: true });
        }, 250);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (this.highlighted === name) {
                this.highlighted = undefined;
            }
        }, 6000);
        return field.label;
    }

    /**
     * What is on the form now, for Claude to read.
     * @returns {{form: string, title: string, sent: boolean, fields: {name: string, label: string, value: string, help: string}[]}}
     */
    @api
    describe() {
        return {
            form: this.formKind,
            title: this.form?.title,
            sent: Boolean(this.receipt),
            // Only the customer can add photos; Claude is told how many there are and what is still missing.
            photos: this.takesPhotos ? `${this.photoSummary?.count ?? 0} added${this.photoSummary?.stillNeeded ? `. Still worth adding: ${this.photoSummary.stillNeeded}` : ''}` : undefined,
            fields: (this.form?.fields ?? []).map((field) => ({
                name: field.name,
                label: field.label,
                value: field.type === 'policy' ? this.policyLabel(this.values.policyId) : (this.values[field.name] ?? ''),
                required: Boolean(field.required),
                wanted: Boolean(field.wanted),
                help: field.help ?? ''
            }))
        };
    }

    policyLabel(policyId) {
        const policy = this.policyList.find((entry) => entry.id === policyId);
        return policy ? `${policy.line} ${policy.policyNumber} (Id ${policy.id})` : '';
    }

    handleInput(event) {
        const name = event.target.dataset.name;
        this.values = { ...this.values, [name]: event.target.value };
        // Once the customer edits a field, it is theirs.
        if (this.filled[name]) {
            const filled = { ...this.filled };
            delete filled[name];
            this.filled = filled;
        }
        if (this.errors[name]) {
            const errors = { ...this.errors };
            delete errors[name];
            this.errors = errors;
        }
        this.announceChange();
    }

    announceChange() {
        this.dispatchEvent(new CustomEvent('formchange'));
    }

    async handleSend(event) {
        event.preventDefault();
        const errors = {};
        this.form.fields.forEach((field) => {
            if (field.required && !String(this.values[field.name] ?? '').trim()) {
                errors[field.name] = field.type === 'policy' ? 'Choose a policy.' : 'This one is needed.';
            }
        });
        this.errors = errors;
        if (Object.keys(errors).length) {
            this.failure = 'Please fill in the fields marked below.';
            return;
        }
        this.isSending = true;
        this.failure = undefined;
        try {
            const fieldsJson = JSON.stringify(this.values);
            const kind = this.formKind === 'newClaim' ? 'claim' : this.formKind === 'addDriver' ? 'driver' : 'request';
            const waiting = this.takesPhotos ? (this.photos?.summary().count ?? 0) : 0;
            const sent = kind === 'claim' ? await submitClaim({ fieldsJson }) : await submitRequest({ kind, fieldsJson });
            // Photos wait on the form until the claim exists, so the form stays up until they are on it.
            if (!waiting) {
                this.receipt = sent;
                this.values = {};
                this.filled = {};
                this.preselectPolicy();
            }
            // It is filed a moment after it is sent. Look for its reference number, and say so either way.
            this.sendingStep = waiting ? 'Filing your claim' : undefined;
            const filed = await this.lookForReceipt(kind, sent.sentAt);
            if (waiting) {
                if (filed?.id) {
                    this.sendingStep = waiting === 1 ? 'Adding your photo' : 'Adding your photos';
                    const result = await this.photos.upload(filed.id);
                    this.photoNote =
                        result.failed === 0
                            ? `${result.added === 1 ? '1 photo is' : `${result.added} photos are`} on your claim.`
                            : `${result.added} of ${waiting} photos are on your claim. Add the rest from the claim's page.`;
                } else {
                    this.photoNote = 'Your photos are not on the claim yet. Add them from the claim\'s page once its number shows.';
                }
                this.values = {};
                this.filled = {};
                this.photoSummary = undefined;
                this.preselectPolicy();
            }
            if (filed || waiting || this.receipt === sent) {
                this.receipt = filed ?? sent;
            }
            this.dispatchEvent(new CustomEvent('sent', { detail: { form: this.formKind, receipt: filed ?? sent } }));
        } catch (error) {
            this.failure = error?.body?.message ?? 'That could not be sent. Please try again.';
        } finally {
            this.isSending = false;
            this.sendingStep = undefined;
        }
    }

    async lookForReceipt(kind, sinceMillis) {
        for (let attempt = 0; attempt < 8; attempt += 1) {
            // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, 1500));
            try {
                // eslint-disable-next-line no-await-in-loop
                const filed = await findReceipt({ kind, sinceMillis });
                if (filed) {
                    return filed;
                }
            } catch (error) {
                return undefined;
            }
        }
        return undefined;
    }

    handleAnother() {
        this.receipt = undefined;
        this.photoNote = undefined;
        this.announceChange();
    }

    /** Straight to the claim that was just filed, where its photos are; otherwise to the list. */
    handleDone() {
        const detail = this.formKind === 'newClaim' ? (this.receipt?.id ? { page: 'claim', recordId: this.receipt.id } : { page: 'claims' }) : { page: 'requests' };
        this.dispatchEvent(new CustomEvent('open', { detail, bubbles: true, composed: true }));
    }
}
