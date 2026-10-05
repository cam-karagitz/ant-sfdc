import { LightningElement, api, wire } from 'lwc';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { tidyEnding } from 'c/antsuranceText';

// The master record type, for objects that have no record types of their own.
const MASTER_RECORD_TYPE = '012000000000000AAA';

/**
 * What the bar needs to know about each object it can sit on.
 * field: the status picklist. closed: closed values the picklist itself does not mark as closed.
 * good: closed values that mean the work ended well. finalLabel: what the last step is called while the record is open.
 * labels: shorter names for values. closeFromHere: whether the button may move the record into its closed step.
 * ownAction: closed values the bar must not set, because a page action does the closing (converting a lead,
 * binding a sale). closing: what to say when the last step is picked on an open record.
 * guidance: what to do at each step, by record type name where the object has more than one.
 */
const OBJECTS = {
    Lead: {
        noun: 'Lead',
        field: 'Status',
        closed: ['Closed - Not Converted'],
        good: ['Closed - Converted'],
        finalLabel: 'Converted',
        labels: { 'Closed - Converted': 'Converted', 'Closed - Not Converted': 'Not converted' },
        closeFromHere: false,
        ownAction: ['Closed - Converted'],
        // Converting has its own page, which makes the customer, the contact and the policy sale.
        handoff: { label: 'Convert this lead', path: '/lightning/cmp/runtime_sales_lead__convertDesktopConsole?leadConvert__leadId=' },
        closing: 'Convert turns the lead into a customer and a policy sale. If they are not going ahead, mark the lead not converted.',
        guidance: {
            default: {
                'Open - Not Contacted': 'A new inquiry. Call or email within one business day, and find out what they want insured and when their current cover ends.',
                'Working - Contacted': 'You have spoken. Note what they need, rate how likely they are to buy, and convert the lead when they are ready for a quote.',
                'Closed - Converted': 'The lead is now a customer with a policy sale. Carry on from the sale and generate a quote there.',
                'Closed - Not Converted': 'Not going ahead. Note why, so the next inquiry from them starts from what was learned.'
            }
        }
    },
    Case: {
        noun: 'Status',
        field: 'Status',
        closed: [],
        good: ['Closed'],
        finalLabel: 'Closed',
        labels: {},
        closeFromHere: true,
        ownAction: [],
        closing: 'Choose how this ends.',
        guidance: {
            Claim: {
                New: 'Just reported. Contact the insured within one business day and confirm what happened.',
                'Under Investigation': 'Facts are being gathered. Confirm coverage, take statements and keep the reserve current.',
                Appraisal: 'The damage is being valued. Review the estimate and adjust the reserve to match.',
                Approved: 'Coverage and the amount are agreed. Record each payment as it is made.',
                'Payment Issued': 'Payment is out. Confirm it arrived, then close the claim.',
                Closed: 'The claim is settled and closed.',
                Denied: 'The claim was denied. The reason and the decision letter are in the file notes.'
            },
            'Policy Service': {
                New: 'Just received. Pick it up and tell the customer when to expect an answer.',
                'In Progress': 'Being worked. Make the change on the policy, then confirm it with the customer.',
                'Waiting on Customer': 'Waiting on the customer. Chase what is missing so the request does not stall.',
                Closed: 'Done and confirmed with the customer.'
            }
        }
    },
    Opportunity: {
        noun: 'Stage',
        field: 'StageName',
        closed: [],
        good: ['Bound', 'Closed Won'],
        finalLabel: 'Bound',
        labels: {},
        closeFromHere: false,
        ownAction: ['Bound', 'Closed Won'],
        closing: 'Bind Policy issues the policy and closes the sale as bound. If the customer is not going ahead, mark the sale declined.',
        guidance: {
            default: {
                'Submission Received': 'A new request. Check it is complete, then generate a quote.',
                'Underwriting Review': 'With underwriting. Answer their questions so the quote can be issued.',
                'Quote Issued': 'The customer has the options. Follow up before the quote expires.',
                'Bind Requested': 'The customer said yes. Use Bind Policy to issue the policy.',
                Bound: 'Bound. The policy is in force.',
                Declined: 'Not going ahead. Note why, in case they come back.'
            }
        }
    }
};

/**
 * A flat status bar for a lead, a claim, a service request or a policy sale: where the record is,
 * what to do at this step, and a button to move it on. It works like Salesforce's own path: with
 * nothing picked the button moves the record to its next step, and picking any other step shows that
 * step's guidance and turns the button into "Mark as <that step>". The open steps come from the
 * status picklist for the record's record type; however the record closes is drawn as one last step.
 */
export default class AntsuranceStatusPath extends NavigationMixin(LightningElement) {
    @api recordId;
    // The wire adapters below react to these two, so they are set once the page says which object this is.
    recordFields;
    picklistField;
    status;
    recordTypeId;
    recordTypeName;
    values = [];
    // The step the person has clicked, by its place in the path. Nothing is saved until they press the button.
    selectedIndex;
    isSaving = false;
    errorMessage;

    connectedCallback() {
        loadBrandFonts(this);
        // The brand face is wider than the fallback, so the steps are measured again once it has loaded.
        if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(() => this.fitSteps()).catch(() => undefined);
        }
    }

    renderedCallback() {
        if (!this.isWatchingWidth) {
            this.isWatchingWidth = true;
            // The window changing size covers every browser; the observer also catches the bar's own
            // column changing width without the window doing so, where the platform allows one.
            this.onResize = () => this.fitStepsSoon();
            window.addEventListener('resize', this.onResize);
            if (typeof ResizeObserver === 'function') {
                try {
                    this.widthObserver = new ResizeObserver(this.onResize);
                    this.widthObserver.observe(this.template.host);
                } catch (e) {
                    this.widthObserver = undefined;
                }
            }
        }
        this.fitSteps();
    }

    disconnectedCallback() {
        if (this.onResize) {
            window.removeEventListener('resize', this.onResize);
        }
        if (this.widthObserver) {
            this.widthObserver.disconnect();
            this.widthObserver = undefined;
        }
        this.isWatchingWidth = false;
    }

    /**
     * Measures once a burst of resize events has passed. A timer, not an animation frame: a tab that is
     * not in front draws no frames, and the bar should be right when the person comes back to it.
     */
    fitStepsSoon() {
        if (this.fitQueued) {
            return;
        }
        this.fitQueued = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.fitQueued = false;
            this.fitSteps();
        }, 60);
    }

    /**
     * Step names are never cut short. When the bar is too narrow to show them all, it goes compact:
     * the step the record is on (and one the person has picked) keeps its name, finished steps show
     * their tick and the rest their number. Each step's name stays its tooltip and its spoken name.
     */
    fitSteps() {
        const strip = this.template.querySelector('.c-path__steps');
        if (!strip) {
            return;
        }
        strip.classList.remove('c-path__steps_compact');
        const isCut = [...strip.querySelectorAll('.c-path__label')].some(label => label.scrollWidth > label.clientWidth + 1);
        strip.classList.toggle('c-path__steps_compact', isCut);
    }

    @api
    get objectApiName() {
        return this.objectName;
    }
    set objectApiName(value) {
        this.objectName = value;
        const config = OBJECTS[value];
        this.picklistField = config ? `${value}.${config.field}` : undefined;
        this.recordFields = config ? [this.picklistField] : undefined;
    }
    objectName;

    get config() {
        return OBJECTS[this.objectName];
    }

    @wire(getRecord, { recordId: '$recordId', fields: '$recordFields' })
    wiredRecord({ data }) {
        if (data) {
            const status = data.fields[this.config.field]?.value;
            if (status !== this.status) {
                this.selectedIndex = undefined;
            }
            this.status = status;
            this.recordTypeId = data.recordTypeId ?? MASTER_RECORD_TYPE;
            this.recordTypeName = data.recordTypeInfo?.name;
        }
    }

    @wire(getPicklistValues, { recordTypeId: '$recordTypeId', fieldApiName: '$picklistField' })
    wiredValues({ data }) {
        if (data) {
            this.values = data.values.map((entry) => ({
                value: entry.value,
                label: this.config.labels[entry.value] ?? entry.label,
                // Case statuses and sale stages say when they are closed; a converted lead status says so too.
                isClosed: entry.attributes?.closed === true || entry.attributes?.converted === true || this.config.closed.includes(entry.value)
            }));
        }
    }

    get ariaLabel() {
        return this.config ? `${this.config.noun} path` : 'Status path';
    }

    get hasSteps() {
        return Boolean(this.config) && this.values.length > 0 && Boolean(this.status);
    }

    get isClosed() {
        const current = this.values.find((entry) => entry.value === this.status);
        return current ? current.isClosed : false;
    }

    /** The open steps in order, then one closing step: how the record closed, or how it is expected to. */
    get path() {
        const open = this.values.filter((entry) => !entry.isClosed);
        const closing = this.isClosed
            ? { value: this.status, label: this.values.find((entry) => entry.value === this.status).label, isClosed: true }
            : { value: this.config.good[0], label: this.config.finalLabel, isClosed: true };
        return [...open, closing];
    }

    get currentIndex() {
        return this.path.findIndex((entry) => entry.value === this.status);
    }

    /** The picked step, when it is a real choice: a step other than the one the record is on. */
    get selected() {
        if (this.selectedIndex === undefined || this.selectedIndex === this.currentIndex) {
            return undefined;
        }
        return this.path[this.selectedIndex];
    }

    get steps() {
        const current = this.currentIndex;
        const endedWell = this.isClosed && this.config.good.includes(this.status);
        const picked = this.selected ? this.selectedIndex : -1;
        return this.path.map((entry, index) => {
            // Steps before the current one are done, unless the record closed some other way than well:
            // a denied claim never reached Approved, so its earlier steps are left unmarked.
            const isDone = this.isClosed ? endedWell && index <= current : index < current;
            let className = 'c-path__step';
            if (isDone) {
                className += ' c-path__step_done';
            } else if (index === current) {
                // A record that closed without the good outcome ends on a neutral step, not a warning.
                className += this.isClosed ? ' c-path__step_ended' : ' c-path__step_current';
            }
            if (index === picked) {
                className += ' c-path__step_picked';
            }
            const isCurrent = index === current;
            if (isCurrent || index === picked) {
                // Keeps its name when the bar goes compact.
                className += ' c-path__step_named';
            }
            return {
                ...entry,
                index,
                number: index + 1,
                isDone,
                className,
                current: isCurrent ? 'step' : undefined,
                pressed: index === picked ? 'true' : 'false',
                title: isCurrent ? `${entry.label}, where this is now` : `Show ${entry.label}`
            };
        });
    }

    get guidanceByType() {
        return this.config.guidance[this.recordTypeName] ?? this.config.guidance.default ?? {};
    }

    /** What to do at this step. Beside the buttons it may need two lines, and never ends on one or two words. */
    get guidance() {
        return tidyEnding(this.guidanceText);
    }

    get guidanceText() {
        const picked = this.selected;
        if (!picked) {
            return this.guidanceByType[this.status] ?? '';
        }
        // The last step of an open record stands for every way it can close.
        if (picked.isClosed && !this.isClosed) {
            return this.config.closing;
        }
        return this.guidanceByType[picked.value] ?? '';
    }

    /** Closed values the bar may set itself. The rest close through their own page action. */
    get closingChoices() {
        return this.values.filter((entry) => entry.isClosed && !this.config.ownAction.includes(entry.value));
    }

    /** The step the button moves to when nothing is picked. There is none when the record is closed, or when closing has its own action. */
    get nextStep() {
        if (this.isClosed || this.currentIndex < 0) {
            return undefined;
        }
        const next = this.path[this.currentIndex + 1];
        if (!next || (next.isClosed && !this.config.closeFromHere)) {
            return undefined;
        }
        return next;
    }

    /**
     * The buttons under the bar: one for the next step, one for the picked step, or one for each way
     * the record can close when the last step is picked. The first is the one the bar suggests.
     */
    get moves() {
        const picked = this.selected;
        let targets;
        if (!picked) {
            targets = this.nextStep ? [this.nextStep] : [];
        } else if (picked.isClosed && !this.isClosed) {
            // The outcome that ends well goes first.
            targets = [...this.closingChoices].sort((a, b) => this.config.good.includes(b.value) - this.config.good.includes(a.value));
        } else {
            targets = [picked];
        }
        return targets.map((entry, index) => ({
            value: entry.value,
            label: this.isClosed && !entry.isClosed ? `Reopen as ${entry.label}` : `Mark as ${entry.label}`,
            // Picking a step is a deliberate choice, so its button is the page's brand button; the standing
            // "next step" button stays quiet.
            variant: picked && index === 0 ? 'brand' : 'neutral'
        }));
    }

    get hasMoves() {
        return this.moves.length > 0 || Boolean(this.handoff);
    }

    /**
     * When the next step is one the bar does not set itself (a lead is converted on its own page), the bar
     * still says what comes next and opens it, so the last open step is never a dead end.
     */
    get handoff() {
        const offer = this.config?.handoff;
        if (!offer || this.isClosed || this.selected || this.nextStep || this.currentIndex < 0) {
            return undefined;
        }
        return { label: offer.label, url: `${offer.path}${this.recordId}` };
    }

    handleHandoff() {
        this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url: this.handoff.url } });
    }

    get hasSelection() {
        return Boolean(this.selected);
    }

    handlePick(event) {
        const index = Number(event.currentTarget.dataset.index);
        // Clicking the step the record is on, or the picked step again, puts the bar back as it was.
        this.selectedIndex = index === this.currentIndex || index === this.selectedIndex ? undefined : index;
        this.errorMessage = undefined;
    }

    handleClear() {
        this.selectedIndex = undefined;
        this.errorMessage = undefined;
    }

    async handleMove(event) {
        const value = event.currentTarget.dataset.value;
        const target = this.values.find((entry) => entry.value === value);
        this.isSaving = true;
        this.errorMessage = undefined;
        try {
            await updateRecord({ fields: { Id: this.recordId, [this.config.field]: value } });
            this.selectedIndex = undefined;
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: `${this.config.noun} is now ${target ? target.label : value}.`, variant: 'success' }));
        } catch (error) {
            this.errorMessage = error?.body?.output?.errors?.[0]?.message ?? error?.body?.message ?? 'The change could not be saved.';
        } finally {
            this.isSaving = false;
        }
    }
}
