import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import getContext from '@salesforce/apex/AntsuranceClaimsAssistantIntake.getContext';
import readMessage from '@salesforce/apex/AntsuranceClaimsAssistantIntake.readMessage';
import createClaim from '@salesforce/apex/AntsuranceClaimsAssistantIntake.createClaim';
import { loadBrandFonts } from 'c/antsuranceFonts';

const STEP_COMPOSE = 'compose';
const STEP_NOT_CLAIM = 'notClaim';
const STEP_REVIEW = 'review';
const MIN_MESSAGE_LENGTH = 20;
const READING_CAPTIONS = ['Reading the message', 'Matching it to the customer’s policies', 'Drafting the claim'];
const CAPTION_INTERVAL_MS = 1500;
const CHANNEL_ICONS = { Email: 'utility:email', Web: 'utility:world', Phone: 'utility:call' };
const CHANNEL_HINTS = { Email: 'An email', Web: 'A web form message', Phone: 'A handler\u2019s call notes' };
const FALLBACK_ERROR = 'Something went wrong. Try again.';

const toOptions = (values) => (values ?? []).map((value) => ({ label: value, value }));

export default class AntsuranceClaimIntake extends NavigationMixin(LightningElement) {
    @api recordId;

    context;
    loadError;
    errorMessage;
    step = STEP_COMPOSE;
    message = '';
    sampleKey;
    isReading = false;
    isCreating = false;
    captionIndex = 0;
    captionTimer;
    // Claude's reading of the message, and the form the handler edits from it.
    draft;
    form = {};

    connectedCallback() {
        loadBrandFonts(this);
    }

    disconnectedCallback() {
        clearInterval(this.captionTimer);
    }

    @wire(getContext, { recordId: '$recordId' })
    wiredContext({ data, error }) {
        if (data) {
            this.context = data;
            this.loadError = data.policies.length ? undefined : 'This customer has no policies to file a claim under.';
        } else if (error) {
            this.loadError = error.body?.message ?? FALLBACK_ERROR;
        }
    }

    renderedCallback() {
        // Going back to the message puts the text back in the box.
        const input = this.refs.message;
        if (input && input.value !== this.message) {
            input.value = this.message;
        }
    }

    get isComposing() {
        return this.step === STEP_COMPOSE;
    }

    get isNotClaim() {
        return this.step === STEP_NOT_CLAIM;
    }

    get isReviewing() {
        return this.step === STEP_REVIEW;
    }

    get customerLabel() {
        return this.context?.customerName ?? 'the customer';
    }

    get samples() {
        return (this.context?.samples ?? []).map((sample) => ({
            ...sample,
            icon: CHANNEL_ICONS[sample.channel] ?? 'utility:chat',
            hint: CHANNEL_HINTS[sample.channel],
            chipClass: sample.key === this.sampleKey ? 'c-chip c-chip_on' : 'c-chip'
        }));
    }

    get hasSamples() {
        return this.samples.length > 0;
    }

    get readingCaption() {
        return READING_CAPTIONS[this.captionIndex];
    }

    get readLabel() {
        return this.isReading ? 'Reading' : 'Read with Claude';
    }

    get isReadDisabled() {
        return this.isReading || !this.context?.policies.length || this.message.trim().length < MIN_MESSAGE_LENGTH;
    }

    get createLabel() {
        return this.isCreating ? 'Creating' : 'Create claim';
    }

    get today() {
        const now = new Date();
        const pad = (value) => String(value).padStart(2, '0');
        return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    }

    get dateHelp() {
        return this.form.dateOfLoss ? undefined : 'The message did not say when it happened.';
    }

    get policyRows() {
        return (this.context?.policies ?? []).map((policy) => {
            const isSelected = policy.policyId === this.form.policyId;
            return {
                ...policy,
                isSelected,
                isPick: Boolean(this.draft?.policyId) && policy.policyId === this.draft.policyId,
                notInForce: !policy.inForce,
                detail: [policy.policyNumber, policy.insuredItem].filter(Boolean).join(' · '),
                rowClass: isSelected ? 'c-policy c-policy_on' : 'c-policy'
            };
        });
    }

    /** Whether the chosen policy covered the date of loss, worked out the way the claim automation does. */
    get coverageNote() {
        const policy = this.context?.policies.find((option) => option.policyId === this.form.policyId);
        const lossDate = this.form.dateOfLoss;
        if (!policy || !lossDate) {
            return undefined;
        }
        const warn = (text) => ({ text, icon: 'utility:warning', className: 'c-cover c-cover_warn' });
        if (!policy.inForce) {
            return warn(`This policy is ${policy.status.toLowerCase()}, so it may not respond to this loss.`);
        }
        if ((policy.effectiveDate && lossDate < policy.effectiveDate) || (policy.expirationDate && lossDate > policy.expirationDate)) {
            return warn('The date of loss is outside this policy’s term.');
        }
        return { text: 'In force on the date of loss.', icon: 'utility:success', className: 'c-cover' };
    }

    get lossTypeOptions() {
        return toOptions(this.context?.lossTypes);
    }

    get severityOptions() {
        return toOptions(this.context?.severities);
    }

    get originOptions() {
        return toOptions(this.context?.origins);
    }

    get contactOptions() {
        return (this.context?.contacts ?? []).map((person) => ({ label: person.name, value: person.contactId }));
    }

    get watchRows() {
        return (this.draft?.watch ?? []).map((text, index) => ({ text, key: `watch-${index}` }));
    }

    get hasWatch() {
        return this.watchRows.length > 0;
    }

    get missingRows() {
        return (this.draft?.missing ?? []).map((text, index) => ({ text, key: `missing-${index}` }));
    }

    get hasMissing() {
        return this.missingRows.length > 0;
    }

    handleSample(event) {
        const sample = this.context.samples.find((item) => item.key === event.currentTarget.dataset.key);
        this.sampleKey = sample.key;
        this.message = sample.text;
        this.refs.message.value = sample.text;
        this.errorMessage = undefined;
    }

    handleMessageInput(event) {
        this.message = event.target.value;
        this.sampleKey = undefined;
    }

    async handleRead() {
        if (this.isReadDisabled) {
            return;
        }
        this.isReading = true;
        this.errorMessage = undefined;
        this.startCaptions();
        try {
            const draft = await readMessage({ recordId: this.recordId, message: this.message });
            this.draft = draft;
            this.form = this.formFrom(draft);
            this.step = draft.isClaim ? STEP_REVIEW : STEP_NOT_CLAIM;
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isReading = false;
            clearInterval(this.captionTimer);
        }
    }

    formFrom(draft) {
        const sample = this.context.samples.find((item) => item.key === this.sampleKey);
        return {
            policyId: draft.policyId ?? this.context.fromPolicyId ?? undefined,
            subject: draft.subject ?? '',
            dateOfLoss: draft.dateOfLoss ?? null,
            estimatedLoss: draft.estimatedLoss ?? null,
            lossType: draft.lossType ?? 'Other',
            severity: draft.severity ?? 'Low',
            lossLocation: draft.lossLocation ?? '',
            description: draft.description ?? '',
            contactId: draft.contactId ?? undefined,
            origin: draft.origin ?? sample?.channel ?? 'Email'
        };
    }

    handleBack() {
        this.step = STEP_COMPOSE;
        this.errorMessage = undefined;
    }

    handleFileAnyway() {
        this.draft = { ...this.draft, policyReason: undefined, missing: [], watch: [] };
        this.step = STEP_REVIEW;
    }

    handlePolicyChange(event) {
        this.form = { ...this.form, policyId: event.target.value };
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.form = { ...this.form, [field]: value === '' ? null : value };
    }

    async handleCreate() {
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-combobox, lightning-textarea')];
        const allValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        if (!this.form.policyId) {
            this.errorMessage = 'Choose the policy this claim falls under.';
            return;
        }
        if (!allValid || this.isCreating) {
            return;
        }
        this.isCreating = true;
        this.errorMessage = undefined;
        try {
            const created = await createClaim({
                claimJson: JSON.stringify({
                    ...this.form,
                    accountId: this.context.accountId,
                    message: this.message,
                    missing: this.draft?.missing ?? []
                })
            });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: `Claim ${created.caseNumber} opened`,
                    message: created.coverageCheck ? `Coverage check: ${created.coverageCheck}.` : undefined,
                    variant: 'success'
                })
            );
            this.dispatchEvent(new RefreshEvent());
            this.dispatchEvent(new CloseActionScreenEvent());
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: created.caseId, objectApiName: 'Case', actionName: 'view' }
            });
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
            this.isCreating = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    startCaptions() {
        this.captionIndex = 0;
        clearInterval(this.captionTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex = Math.min(this.captionIndex + 1, READING_CAPTIONS.length - 1);
        }, CAPTION_INTERVAL_MS);
    }
}
