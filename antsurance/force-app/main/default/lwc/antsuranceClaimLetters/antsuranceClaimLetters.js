import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LOCALE from '@salesforce/i18n/locale';
import LOCKUP from '@salesforce/resourceUrl/antsuranceLockupOnWhite';
import getLetters from '@salesforce/apex/AntsuranceClaimLetters.getLetters';
import draftLetter from '@salesforce/apex/AntsuranceClaimLetters.draft';
import reviseLetter from '@salesforce/apex/AntsuranceClaimLetters.revise';
import layoutLetter from '@salesforce/apex/AntsuranceClaimLetters.layout';
import approveLetter from '@salesforce/apex/AntsuranceClaimLetters.approve';
import savePdf from '@salesforce/apex/AntsuranceClaimLetters.savePdf';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { tidyEnding } from 'c/antsuranceText';
import { pageOf } from 'c/antsuranceUiMemory';

const FALLBACK_ERROR = 'Something went wrong. Try again.';
const DRAFTING_CAPTIONS = ['Reading the claim file', 'Checking the coverage and the figures', 'Writing the letter'];
const REVISING_CAPTIONS = ['Reading your request', 'Changing the letter'];
const CAPTION_INTERVAL_MS = 2000;
// The preview follows the typing after a short pause, so a letter is not laid out on every key.
const LAYOUT_PAUSE_MS = 350;
const ON_FILE_PAGE_SIZE = 4;
const GAP_PATTERN = /\[[^\]\n]{1,80}\]/g;
// What each letter is for, said by its icon; the title carries the meaning.
const ICONS = {
    acknowledgment: { name: 'utility:email', tint: 'olive' },
    reservation: { name: 'utility:shield', tint: 'amber' },
    confirmation: { name: 'utility:success', tint: 'olive' },
    information: { name: 'utility:question', tint: 'sand' },
    payment: { name: 'utility:moneybag', tint: 'clay' },
    notice: { name: 'utility:forward', tint: 'amber' }
};
const WORK_TABS = [
    { value: 'edit', label: 'Edit' },
    { value: 'preview', label: 'Preview' }
];

/**
 * Claim letters, on the claim's Documents tab. At rest it is a short list: the letters this claim
 * could use now, each with why, and the letters already approved. Opening one has Claude draft it;
 * the adjuster edits the text beside a preview of the page, can ask Claude for a change in words,
 * and approves it, which saves the letter as a PDF on the claim and a file note. Nothing is sent.
 *
 * Fires `lettersaved` with `detail.documentId` after a letter is saved, so the tab around it can
 * refresh its lists, and `letterschange` with `detail.documentIds` whenever the letters on file are
 * read, so the documents list beside it does not show the same files twice.
 */
export default class AntsuranceClaimLetters extends NavigationMixin(LightningElement) {
    @api recordId;

    desk;
    errorMessage;
    onFilePage = 0;

    // The letter being worked on. Undefined while the list is showing.
    letter;
    sheet;
    workError;
    workTabs = WORK_TABS;
    lockup = LOCKUP;
    tab = 'edit';
    // drafting, ready, revising, confirming, saving, pdfFailed
    phase;
    request = '';
    showBasis = false;
    showHeader = false;
    noteId;
    captionIndex = 0;
    captionTimer;
    layoutTimer;
    layoutToken = 0;

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
    }

    disconnectedCallback() {
        clearInterval(this.captionTimer);
        clearTimeout(this.layoutTimer);
    }

    renderedCallback() {
        // A textarea shows only what is put in its value property: a value written in the template
        // is set as an attribute, which a textarea ignores, and the box stays empty. So the letter is
        // written into each box here, once it is on the page and again whenever Claude rewrites the
        // draft. A box that already holds the same text is left alone, which is every time the person
        // types, so the caret stays where they are typing.
        const boxes = [
            [this.refs.toBox, this.toText],
            [this.refs.referenceBox, this.referenceText],
            [this.refs.bodyBox, this.body]
        ];
        for (const [box, text] of boxes) {
            if (box && box.value !== text) {
                box.value = text;
            }
        }
    }

    async load() {
        try {
            this.desk = await getLetters({ caseId: this.recordId });
            this.errorMessage = undefined;
            const documentIds = this.desk.onFile.map((row) => row.documentId).filter(Boolean);
            this.dispatchEvent(new CustomEvent('letterschange', { detail: { documentIds } }));
        } catch (error) {
            this.errorMessage = this.reduce(error);
        }
    }

    // ---------- The list ----------

    get isList() {
        return !this.letter && !this.phase;
    }

    get isLoading() {
        return !this.desk && !this.errorMessage;
    }

    get busy() {
        return this.isLoading || this.isWorking ? 'true' : 'false';
    }

    get options() {
        return (this.desk?.options ?? []).map((option) => {
            const icon = ICONS[option.kind] ?? ICONS.information;
            return { ...option, why: tidyEnding(option.why), icon: icon.name, tileClass: `c-ui-tile c-ui-tile_${icon.tint}`, buttonTitle: `Draft the ${option.title.toLowerCase()} with Claude` };
        });
    }

    get hasOptions() {
        return this.options.length > 0;
    }

    get hasNoOptions() {
        return Boolean(this.desk) && !this.hasOptions;
    }

    get notNow() {
        return this.desk?.notNow;
    }

    get metaLine() {
        if (!this.desk) {
            return 'Drafted by Claude from the claim, approved by you';
        }
        const count = this.options.length;
        const offered = count === 0 ? 'No letter is due now' : count === 1 ? '1 letter this claim could use now' : `${count} letters this claim could use now`;
        return `${offered}. Claude drafts, you edit and approve. Nothing is sent from here.`;
    }

    get onFile() {
        const dateFormat = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' });
        return (this.desk?.onFile ?? []).map((row) => {
            const when = row.approvedAt ? dateFormat.format(new Date(row.approvedAt)) : '';
            return {
                ...row,
                // Each part stays on one line, so a name or a date is never split.
                metaParts: [row.toWhom, row.approvedBy ? `approved by ${row.approvedBy}` : '', when]
                    .filter(Boolean)
                    .map((text, index, all) => ({ key: `m-${index}`, text: index < all.length - 1 ? `${text} ·` : text })),
                hasPdf: Boolean(row.documentId),
                isSaving: this.savingNoteId === row.noteId,
                openTitle: `Open ${row.title}`
            };
        });
    }

    get hasOnFile() {
        return this.onFile.length > 0;
    }

    get onFileCount() {
        return this.onFile.length;
    }

    get onFileRows() {
        return pageOf(this.onFile, this.onFilePage, ON_FILE_PAGE_SIZE);
    }

    get onFilePageSize() {
        return ON_FILE_PAGE_SIZE;
    }

    handleOnFilePage(event) {
        this.onFilePage = event.detail.page;
    }

    handleOpenFile(event) {
        this.openFile(event.currentTarget.dataset.id);
    }

    openFile(documentId) {
        if (!documentId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: documentId }
        });
    }

    savingNoteId;

    /** A letter whose note was saved but whose PDF was not: make the PDF now. */
    async handleSaveMissingPdf(event) {
        const noteId = event.currentTarget.dataset.id;
        if (this.savingNoteId) {
            return;
        }
        this.savingNoteId = noteId;
        try {
            const saved = await savePdf({ noteId });
            this.announceSaved(saved);
            await this.load();
        } catch (error) {
            this.errorMessage = this.reduce(error);
        } finally {
            this.savingNoteId = undefined;
        }
    }

    // ---------- Drafting ----------

    async handleDraft(event) {
        const kind = event.currentTarget.dataset.kind;
        const option = this.options.find((each) => each.kind === kind);
        this.letter = undefined;
        this.sheet = undefined;
        this.workError = undefined;
        this.workTitle = option?.title ?? 'Letter';
        this.workTo = option?.toWhom ?? '';
        this.draftKind = kind;
        this.request = '';
        this.showBasis = false;
        this.noteId = undefined;
        this.tab = 'edit';
        this.startCaptions('drafting');
        try {
            this.accept(await draftLetter({ caseId: this.recordId, kind }));
            this.phase = 'ready';
        } catch (error) {
            this.workError = this.reduce(error);
            this.phase = 'failed';
        } finally {
            this.stopCaptions();
        }
        this.focusWork();
    }

    handleRetryDraft() {
        this.handleDraft({ currentTarget: { dataset: { kind: this.draftKind } } });
    }

    workTitle;
    workTo;
    draftKind;

    /** Takes a letter from the server into the editor and lays it out. */
    accept(letter) {
        // A text box holds line feeds only, so the letter is kept the same way and a box and its text always compare equal.
        const lineFeeds = (text) => (text ?? '').replace(/\r\n?/g, '\n');
        this.letter = {
            ...letter,
            body: lineFeeds(letter.body),
            addressee: (letter.addressee ?? []).map(lineFeeds),
            reference: (letter.reference ?? []).map(lineFeeds),
            signer: [...(letter.signer ?? [])],
            basis: [...(letter.basis ?? [])]
        };
        // The address and reference come from the record, so they stay folded unless one has a gap to fill.
        this.showHeader = this.headerGapCount > 0;
        this.refreshSheet(true);
    }

    get isDrafting() {
        return this.phase === 'drafting';
    }

    get isFailed() {
        return this.phase === 'failed';
    }

    get isRevising() {
        return this.phase === 'revising';
    }

    get isConfirming() {
        return this.phase === 'confirming';
    }

    get isSaving() {
        return this.phase === 'saving';
    }

    get isPdfFailed() {
        return this.phase === 'pdfFailed';
    }

    get isWorking() {
        return this.isDrafting || this.isRevising || this.isSaving;
    }

    get hasLetter() {
        return Boolean(this.letter);
    }

    get caption() {
        const captions = this.isRevising ? REVISING_CAPTIONS : DRAFTING_CAPTIONS;
        return captions[Math.min(this.captionIndex, captions.length - 1)];
    }

    get workMeta() {
        if (this.isDrafting) {
            return this.workTo;
        }
        const pages = this.sheet?.pages;
        const length = pages ? (pages === 1 ? '1 page' : `${pages} pages`) : '';
        return [this.workTo, 'Draft by Claude, not saved', length].filter(Boolean).join(' · ');
    }

    startCaptions(phase) {
        this.phase = phase;
        this.captionIndex = 0;
        clearInterval(this.captionTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex += 1;
        }, CAPTION_INTERVAL_MS);
    }

    stopCaptions() {
        clearInterval(this.captionTimer);
        this.captionTimer = undefined;
    }

    focusWork() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.refs.back?.focus(), 0);
    }

    // ---------- Editing ----------

    get toText() {
        return (this.letter?.addressee ?? []).join('\n');
    }

    get referenceText() {
        return (this.letter?.reference ?? []).join('\n');
    }

    get salutation() {
        return this.letter?.salutation ?? '';
    }

    get body() {
        return this.letter?.body ?? '';
    }

    get fieldsLocked() {
        return this.isRevising || this.isSaving || this.isConfirming;
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        const lines = value.split('\n');
        if (field === 'addressee' || field === 'reference') {
            this.letter = { ...this.letter, [field]: lines };
        } else {
            this.letter = { ...this.letter, [field]: value };
        }
        this.refreshSheet(false);
    }

    /** Lays the letter out again: at once after Claude writes, after a pause while the adjuster types. */
    refreshSheet(now) {
        clearTimeout(this.layoutTimer);
        const run = async () => {
            const token = ++this.layoutToken;
            try {
                const sheet = await layoutLetter({ letterJson: JSON.stringify(this.letter) });
                if (token === this.layoutToken) {
                    this.sheet = sheet;
                }
            } catch (error) {
                if (token === this.layoutToken) {
                    this.workError = this.reduce(error);
                }
            }
        };
        if (now) {
            run();
        } else {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.layoutTimer = setTimeout(run, LAYOUT_PAUSE_MS);
        }
    }

    get gaps() {
        const text = [this.toText, this.referenceText, this.salutation, this.body].join('\n');
        const found = [];
        for (const match of text.match(GAP_PATTERN) ?? []) {
            const gap = match.slice(1, -1).trim();
            if (!found.includes(gap)) {
                found.push(gap);
            }
        }
        return found;
    }

    get headerGapCount() {
        const found = [this.toText, this.referenceText, this.salutation].join('\n').match(GAP_PATTERN) ?? [];
        return found.length === 0 ? undefined : found.length;
    }

    get headerSummary() {
        if (this.headerGapCount) {
            return this.headerGapCount === 1 ? 'A gap to fill' : 'Gaps to fill';
        }
        return (this.letter?.addressee ?? []).filter((line) => line.trim() !== '')[0] ?? 'No addressee yet';
    }

    handleHeaderToggle(event) {
        this.showHeader = event.detail.open;
    }

    get hasGaps() {
        return this.gaps.length > 0;
    }

    get gapLine() {
        const count = this.gaps.length;
        const list = this.gaps.join(', ');
        return count === 1 ? `Fill 1 gap before approving: ${list}.` : `Fill ${count} gaps before approving: ${list}.`;
    }

    get hasBasis() {
        return (this.letter?.basis ?? []).length > 0;
    }

    get basis() {
        return (this.letter?.basis ?? []).map((text, index) => ({ key: `basis-${index}`, text }));
    }

    get basisCount() {
        return this.letter?.basis?.length ?? 0;
    }

    handleBasisToggle(event) {
        this.showBasis = event.detail.open;
    }

    // ---------- The preview: the page as it will print ----------

    get sheetAddressee() {
        return this.lines(this.sheet?.addressee, 'to');
    }

    get sheetReference() {
        return this.lines(this.sheet?.reference, 'ref');
    }

    get sheetSalutation() {
        return this.segments(this.sheet?.salutation ?? '');
    }

    get sheetParagraphs() {
        return (this.sheet?.paragraphs ?? []).map((paragraph) => ({ key: `p-${paragraph.index}`, lines: this.lines(paragraph.lines, `p-${paragraph.index}`) }));
    }

    get sheetSigner() {
        return (this.sheet?.signer ?? []).map((text, index) => ({ key: `s-${index}`, text, className: index === 0 ? 'c-sheet__line c-sheet__line_strong' : 'c-sheet__line' }));
    }

    get sheetDate() {
        return this.sheet?.dateLine ?? '';
    }

    get sheetClosing() {
        return this.sheet?.closing ?? '';
    }

    get sheetLabel() {
        return `Preview of the ${(this.workTitle ?? 'letter').toLowerCase()} as it will print`;
    }

    lines(values, prefix) {
        return (values ?? []).map((text, index) => ({ key: `${prefix}-${index}`, parts: this.segments(text) }));
    }

    /** A line cut into plain text and gaps, so a gap can be marked on the page. */
    segments(text) {
        const parts = [];
        let last = 0;
        for (const match of text.matchAll(GAP_PATTERN)) {
            if (match.index > last) {
                parts.push({ key: `t-${last}`, text: text.slice(last, match.index), className: '' });
            }
            parts.push({ key: `g-${match.index}`, text: match[0], className: 'c-gap' });
            last = match.index + match[0].length;
        }
        if (last < text.length || parts.length === 0) {
            parts.push({ key: `t-${last}`, text: text.slice(last), className: '' });
        }
        return parts;
    }

    // Narrow: the editor and the preview take a tab each. Wide: both show and the tabs are hidden.
    get editClass() {
        return this.tab === 'edit' ? 'c-pane c-pane_edit' : 'c-pane c-pane_edit c-pane_off';
    }

    get previewClass() {
        return this.tab === 'preview' ? 'c-pane c-pane_preview' : 'c-pane c-pane_preview c-pane_off';
    }

    handleTab(event) {
        this.tab = event.detail.value;
    }

    // ---------- Asking Claude for a change ----------

    handleRequestInput(event) {
        this.request = event.target.value;
    }

    handleRequestKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleRevise();
        }
    }

    get cannotRevise() {
        return this.fieldsLocked || this.request.trim() === '';
    }

    async handleRevise() {
        if (this.cannotRevise) {
            return;
        }
        this.workError = undefined;
        this.startCaptions('revising');
        try {
            this.accept(await reviseLetter({ caseId: this.recordId, letterJson: JSON.stringify(this.letter), request: this.request }));
            this.request = '';
        } catch (error) {
            this.workError = this.reduce(error);
        } finally {
            this.stopCaptions();
            this.phase = 'ready';
        }
    }

    // ---------- Approving ----------

    get cannotApprove() {
        return this.hasGaps || this.fieldsLocked || this.body.trim() === '' || this.toText.trim() === '';
    }

    get approveHint() {
        if (this.hasGaps) {
            return this.gapLine;
        }
        if (this.toText.trim() === '') {
            return 'Say who the letter is to before approving it.';
        }
        if (this.body.trim() === '') {
            return 'The letter has no text yet.';
        }
        return 'Approving saves the letter as a PDF on this claim and adds a file note. Nothing is sent.';
    }

    get hintClass() {
        return this.hasGaps ? 'c-foot__hint c-foot__hint_watch' : 'c-foot__hint';
    }

    handleApprove() {
        if (!this.cannotApprove) {
            this.workError = undefined;
            this.phase = 'confirming';
        }
    }

    handleCancelApprove() {
        this.phase = 'ready';
    }

    /** Two requests: the note first, then the PDF made from it. A page cannot be rendered in a request that has saved. */
    async handleConfirm() {
        this.phase = 'saving';
        this.workError = undefined;
        try {
            this.noteId = await approveLetter({ caseId: this.recordId, letterJson: JSON.stringify(this.letter) });
        } catch (error) {
            this.workError = this.reduce(error);
            this.phase = 'ready';
            return;
        }
        await this.finishPdf();
    }

    async finishPdf() {
        this.phase = 'saving';
        try {
            const saved = await savePdf({ noteId: this.noteId });
            this.announceSaved(saved);
            this.closeWork();
            await this.load();
        } catch (error) {
            // The letter is approved and in the file notes; only its PDF is missing, and that can be tried again.
            this.workError = `The letter is approved and in the file notes, but its PDF was not saved. ${this.reduce(error)}`;
            this.phase = 'pdfFailed';
        }
    }

    handleRetryPdf() {
        this.finishPdf();
    }

    announceSaved(saved) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Letter saved to this claim', message: `"${saved.title}" is in the files and the file notes. Nothing was sent.`, variant: 'success' }));
        this.dispatchEvent(new CustomEvent('lettersaved', { detail: { documentId: saved.documentId } }));
    }

    handleBack() {
        this.closeWork();
        if (this.noteId) {
            // A letter approved without its PDF now shows in the list, where the PDF can be saved.
            this.load();
        }
    }

    closeWork() {
        clearTimeout(this.layoutTimer);
        this.stopCaptions();
        this.layoutToken += 1;
        this.letter = undefined;
        this.sheet = undefined;
        this.phase = undefined;
        this.workError = undefined;
        this.request = '';
    }

    get backLabel() {
        return this.noteId || !this.hasLetter ? 'All letters' : 'Discard and go back';
    }

    get showEditor() {
        return this.hasLetter && !this.isDrafting;
    }

    get showFootActions() {
        return !this.isConfirming && !this.isSaving && !this.isPdfFailed;
    }

    reduce(error) {
        return error?.body?.message ?? error?.message ?? FALLBACK_ERROR;
    }
}
