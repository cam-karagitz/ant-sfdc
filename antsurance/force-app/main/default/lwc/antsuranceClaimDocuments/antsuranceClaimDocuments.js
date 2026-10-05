import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import { refreshApex } from '@salesforce/apex';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import getDocuments from '@salesforce/apex/AntsuranceClaimsAssistantDocuments.getDocuments';
import readDocument from '@salesforce/apex/AntsuranceClaimsAssistantDocuments.readDocument';
import applySuggestion from '@salesforce/apex/AntsuranceClaimsAssistantDocuments.applySuggestion';
import addNote from '@salesforce/apex/AntsuranceClaimsAssistantDocuments.addNote';
import getNotes from '@salesforce/apex/AntsuranceNotesController.getNotes';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';
import { recall, remember } from 'c/antsuranceUiMemory';

const ACCEPTED_FORMATS = ['.pdf', '.png', '.jpg', '.jpeg', '.gif', '.webp'];
const IMAGE_EXTENSIONS = ['png', 'jpg', 'jpeg', 'gif', 'webp'];
const VIDEO_EXTENSIONS = ['mp4', 'mov', 'm4v', 'webm', 'avi'];
const READING_CAPTIONS = ['Opening the document', 'Reading every line', 'Checking it against the claim', 'Writing it up'];
const CAPTION_INTERVAL_MS = 1800;
const FALLBACK_ERROR = 'Something went wrong. Try again.';
// What confirming each kind of suggestion does, shown before the handler confirms.
const EFFECTS = {
    set_reserve: (amount) => `This sets the reserve to ${amount} and records why in a file note.`,
    set_estimate: (amount) => `This sets the estimated loss to ${amount} and records why in a file note.`,
    flag_subrogation: () => 'This turns on the subrogation flag on the claim.',
    flag_fraud: () => 'This flags the claim for possible fraud.',
    add_task: () => 'This adds a task on the claim, assigned to you and due in two days.'
};
const MATCHES = {
    yes: { icon: 'utility:success', className: 'c-match c-match_yes' },
    no: { icon: 'utility:warning', className: 'c-match c-match_no' },
    unclear: { icon: 'utility:info', className: 'c-match' }
};

export default class AntsuranceClaimDocuments extends NavigationMixin(LightningElement) {
    @api recordId;

    acceptedFormats = ACCEPTED_FORMATS;
    documents;
    errorMessage;
    // What Claude found, and where each document is in the process, by document Id.
    states = {};
    captionIndex = 0;
    captionTimer;
    notesResult;
    // Approved letters are files on the claim too. They are listed under Letters, so they are left out here.
    letterDocumentIds = [];
    /** Which of the three sections is in view: photos, files or letters. Remembered for the claim while the browser session lasts. */
    section = 'photos';
    photoCount;
    letterCount;

    connectedCallback() {
        loadBrandFonts(this);
        this.section = recall(`${this.recordId}:documents-section`, 'photos');
        this.load();
    }

    // ------------------------------------------------------------------ the three sections

    get sections() {
        return [
            { value: 'photos', label: 'Photos', count: this.photoCount },
            { value: 'files', label: 'Files', count: this.listed?.length },
            { value: 'letters', label: 'Letters', count: this.letterCount }
        ];
    }

    paneClass(name) {
        return this.section === name ? 'c-pane' : 'c-pane c-pane_away';
    }

    get photosClass() {
        return this.paneClass('photos');
    }

    get filesClass() {
        return this.paneClass('files');
    }

    get lettersClass() {
        return this.paneClass('letters');
    }

    handleSection(event) {
        this.section = event.detail.value;
        remember(`${this.recordId}:documents-section`, this.section);
    }

    handlePhotosChange(event) {
        this.photoCount = event.detail.count;
    }

    disconnectedCallback() {
        clearInterval(this.captionTimer);
    }

    // Held only so the file notes card can be refreshed after a note is added from here:
    // it reads the same cached list.
    @wire(getNotes, { recordId: '$recordId' })
    wiredNotes(result) {
        this.notesResult = result;
    }

    get isLoading() {
        return !this.documents && !this.errorMessage;
    }

    get isBusy() {
        return this.isLoading || Object.values(this.states).some((state) => state.isReading) ? 'true' : 'false';
    }

    get listed() {
        return this.documents?.filter((item) => !this.letterDocumentIds.includes(item.documentId));
    }

    get isEmpty() {
        return this.listed?.length === 0;
    }

    get metaLine() {
        const count = this.listed?.length ?? 0;
        if (count === 0) {
            return 'Claude reads PDFs and images against the claim';
        }
        return `${count} on file. Claude reads PDFs and images against the claim.`;
    }

    get readingCaption() {
        return READING_CAPTIONS[this.captionIndex];
    }

    get rows() {
        const money = this.money;
        const dateFormat = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' });
        return (this.listed ?? []).map((item) => {
            const state = this.states[item.documentId] ?? {};
            const isImage = IMAGE_EXTENSIONS.includes(item.extension);
            const added = item.addedAt ? `added ${dateFormat.format(new Date(item.addedAt))}` : '';
            return {
                ...item,
                icon: item.extension === 'pdf' ? 'doctype:pdf' : isImage ? 'doctype:image' : 'doctype:attachment',
                kind: item.extension === 'pdf' ? 'PDF' : isImage ? 'Image' : 'File',
                meta: [item.extension?.toUpperCase(), item.sizeLabel, added].filter(Boolean).join(' · '),
                // Why Claude does not read this one here, in a line under its name. A video is read from the Analysis tab.
                skipLine: item.readable
                    ? undefined
                    : VIDEO_EXTENSIONS.includes(item.extension)
                      ? 'A video. Claude reads it on the Analysis tab, from frames sampled across it.'
                      : item.whyNot,
                isReading: Boolean(state.isReading),
                error: state.error,
                readLabel: state.isReading ? 'Reading' : state.reading ? 'Read again' : 'Read with Claude',
                itemClass: state.reading || state.isReading || state.error ? 'c-item c-item_open' : 'c-item',
                reading: state.reading ? this.present(state, money, dateFormat) : undefined
            };
        });
    }

    get money() {
        return (value) => {
            const cents = Math.round(value * 100) % 100 !== 0;
            return new Intl.NumberFormat(LOCALE, {
                style: 'currency',
                currency: CURRENCY,
                minimumFractionDigits: cents ? 2 : 0,
                maximumFractionDigits: cents ? 2 : 0
            }).format(value);
        };
    }

    /** Shapes one reading for the template. */
    present(state, money, dateFormat) {
        const reading = state.reading;
        const match = MATCHES[reading.matchesClaim] ?? MATCHES.unclear;
        const dated = reading.documentDate ? dateFormat.format(new Date(`${reading.documentDate}T12:00:00`)) : undefined;
        const concerns = reading.concerns ?? [];
        const suggestions = reading.suggestions ?? [];
        return {
            ...reading,
            // Shown only: what is applied or added to the file notes uses the reading as Claude returned it.
            summary: keepTogether(reading.summary),
            comparison: keepTogether(reading.comparison),
            matchNote: keepTogether(reading.matchNote),
            fromLine: [reading.issuer, dated].filter(Boolean).join(' · '),
            totalLabel: reading.totalAmount === null || reading.totalAmount === undefined ? undefined : money(reading.totalAmount),
            matchIcon: match.icon,
            matchClass: match.className,
            facts: (reading.keyFacts ?? []).map((fact, index) => ({ ...fact, key: `fact-${index}` })),
            hasFacts: (reading.keyFacts ?? []).length > 0,
            concernRows: concerns.map((text, index) => ({ text: keepTogether(text), key: `concern-${index}` })),
            hasConcerns: concerns.length > 0,
            suggestionRows: suggestions.map((suggestion, index) => ({
                ...suggestion,
                title: keepTogether(suggestion.title),
                reason: keepTogether(suggestion.reason),
                index,
                key: `suggestion-${index}`,
                isConfirming: state.confirming === index,
                isApplying: state.applying === index,
                isDone: (state.applied ?? []).includes(index),
                // A suggestion that adds a task says so on its button; the others change the claim.
                applyLabel: suggestion.kind === 'add_task' ? 'Add task' : 'Apply',
                effect: (EFFECTS[suggestion.kind] ?? (() => ''))(suggestion.amount === null || suggestion.amount === undefined ? '' : money(suggestion.amount))
            })),
            hasSuggestions: suggestions.length > 0,
            noteAdded: Boolean(state.noteAdded),
            isAddingNote: Boolean(state.isAddingNote)
        };
    }

    renderedCallback() {
        if (!this.arrived) {
            return;
        }
        const reading = this.template.querySelector(`[data-reading="${this.arrived}"]`);
        if (reading) {
            this.arrived = undefined;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            window.requestAnimationFrame(() => reading.scrollIntoView({ behavior: 'smooth', block: 'start' }));
        }
    }

    setState(documentId, changes) {
        this.states = { ...this.states, [documentId]: { ...(this.states[documentId] ?? {}), ...changes } };
    }

    async load() {
        try {
            this.documents = await getDocuments({ caseId: this.recordId });
            this.errorMessage = undefined;
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    handleUploadFinished(event) {
        const count = event.detail.files.length;
        this.dispatchEvent(
            new ShowToastEvent({ title: count === 1 ? 'Document added' : `${count} documents added`, variant: 'success' })
        );
        this.load();
        this.dispatchEvent(new RefreshEvent());
    }

    handleLettersChange(event) {
        this.letterDocumentIds = event.detail.documentIds;
        this.letterCount = event.detail.documentIds.length;
    }

    /** A letter was approved: it is a new file and a new file note on the claim. */
    handleLetterSaved() {
        this.load();
        refreshApex(this.notesResult);
        this.dispatchEvent(new RefreshEvent());
    }

    handlePreview(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }

    async handleRead(event) {
        const documentId = event.currentTarget.dataset.id;
        if (this.states[documentId]?.isReading) {
            return;
        }
        this.setState(documentId, { isReading: true, error: undefined, reading: undefined, applied: [], confirming: undefined, noteAdded: false });
        this.startCaptions();
        try {
            const reading = await readDocument({ caseId: this.recordId, documentId });
            this.setState(documentId, { reading });
            // The read opens under the file, often below the fold: bring it into view once it is drawn.
            this.arrived = documentId;
        } catch (error) {
            this.setState(documentId, { error: error?.body?.message ?? FALLBACK_ERROR });
        } finally {
            this.setState(documentId, { isReading: false });
            this.stopCaptions();
        }
    }

    handleApply(event) {
        const { id, index } = event.currentTarget.dataset;
        this.setState(id, { confirming: Number(index) });
    }

    handleCancelApply(event) {
        this.setState(event.currentTarget.dataset.id, { confirming: undefined });
    }

    async handleConfirmApply(event) {
        const documentId = event.currentTarget.dataset.id;
        const index = Number(event.currentTarget.dataset.index);
        const state = this.states[documentId];
        const suggestion = state?.reading?.suggestions?.[index];
        if (!suggestion || state.applying !== undefined) {
            return;
        }
        this.setState(documentId, { applying: index });
        try {
            const message = await applySuggestion({
                caseId: this.recordId,
                kind: suggestion.kind,
                amount: suggestion.amount,
                title: suggestion.title,
                reason: suggestion.reason,
                documentTitle: state.reading.title
            });
            this.setState(documentId, { applied: [...(state.applied ?? []), index], confirming: undefined });
            this.dispatchEvent(new ShowToastEvent({ title: message, variant: 'success' }));
            await this.refreshPage();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'That was not applied', message: error?.body?.message ?? FALLBACK_ERROR, variant: 'error' })
            );
        } finally {
            this.setState(documentId, { applying: undefined });
        }
    }

    async handleAddNote(event) {
        const documentId = event.currentTarget.dataset.id;
        const reading = this.states[documentId]?.reading;
        if (!reading || this.states[documentId].isAddingNote) {
            return;
        }
        this.setState(documentId, { isAddingNote: true });
        try {
            await addNote({ caseId: this.recordId, noteType: reading.noteType, body: reading.note });
            this.setState(documentId, { noteAdded: true });
            this.dispatchEvent(new ShowToastEvent({ title: 'Added to the file notes', variant: 'success' }));
            await this.refreshPage();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'The note was not added', message: error?.body?.message ?? FALLBACK_ERROR, variant: 'error' })
            );
        } finally {
            this.setState(documentId, { isAddingNote: false });
        }
    }

    /** Brings the rest of the claim page up to date after a change made from this card. */
    async refreshPage() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        this.dispatchEvent(new RefreshEvent());
        if (this.notesResult) {
            await refreshApex(this.notesResult);
        }
    }

    startCaptions() {
        this.captionIndex = 0;
        clearInterval(this.captionTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex = Math.min(this.captionIndex + 1, READING_CAPTIONS.length - 1);
        }, CAPTION_INTERVAL_MS);
    }

    stopCaptions() {
        if (!Object.values(this.states).some((state) => state.isReading)) {
            clearInterval(this.captionTimer);
            this.captionTimer = undefined;
        }
    }
}
