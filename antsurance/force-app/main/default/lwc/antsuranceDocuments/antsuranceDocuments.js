import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import getDocuments from '@salesforce/apex/AntsuranceDocumentController.getDocuments';
import saveToFiles from '@salesforce/apex/AntsuranceDocumentController.saveToFiles';
import getFiles from '@salesforce/apex/AntsuranceFilesController.getFiles';
import { refreshApex } from '@salesforce/apex';
import LOCALE from '@salesforce/i18n/locale';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { fileIcon } from 'c/antsuranceIcons';

// The preview is the document drawn as HTML (the page's ?preview=1 mode) on a sheet as wide as a US
// Letter page, scaled to the width the tab has. A browser's own PDF viewer is not used: it enlarges
// the page with the browser's zoom, which cut the right edge off at any zoom but 100%.
const SHEET_WIDTH_PX = 816;
// How tall the sheet is taken to be until the page reports its own height: one US Letter page.
const SHEET_HEIGHT_PX = 1056;
const MESSAGE_SOURCE = 'antsurance-document';
// How long to wait, once the frame has loaded, for the page to report its height.
const HEIGHT_WAIT_MS = 4000;
// The preview's spinner is taken down after this long even if the frame never reports that it loaded.
const PREVIEW_WAIT_MS = 12000;
const FALLBACK_ERROR = 'The documents for this record could not be loaded.';
const SAVE_ERROR = 'The file could not be saved. Try again.';
const EMPTY_MESSAGES = {
    Opportunity: 'A proposal is ready once this sale has a quote.',
    Account: 'A certificate of insurance is ready once this customer has liability cover in force.'
};
const EMPTY_FALLBACK = 'This record has no documents to produce.';
const BYTES_PER_KB = 1024;
// The preview opens as the top of the sheet, this tall, so the tab is about a screen; a button shows the rest.
const FOLDED_PREVIEW_PX = 340;
// Saved files shown at a time.
const FILE_PAGE_SIZE = 4;
// Narrower than this, Save to Files and Download fold into one menu button and Open in New Tab stays.
const TIGHT_BELOW_PX = 400;

/** A file's size as a person says it: "84 KB", "1.2 MB". */
function sizeWords(bytes) {
    const kilobytes = Number(bytes ?? 0) / BYTES_PER_KB;
    if (kilobytes < 1) {
        return 'Under 1 KB';
    }
    return kilobytes < BYTES_PER_KB ? `${Math.round(kilobytes)} KB` : `${(kilobytes / BYTES_PER_KB).toFixed(1)} MB`;
}

/**
 * The documents a record can produce (declarations, ID cards, certificate, proposal), each a PDF
 * generated from the live record: pick one to preview it, then open, download or save it to Files.
 * The preview shows the whole document, fitted to the tab's width.
 */
export default class AntsuranceDocuments extends NavigationMixin(LightningElement) {
    /** The policy, policy sale or customer. Set automatically on a record page. */
    @api recordId;
    /** Set automatically on a record page. */
    @api objectApiName;

    documents;
    errorMessage;
    selectedKey;
    isLoadingPreview = true;
    // The sheet's own height in its own pixels, as the previewed page reports it.
    sheetHeight = SHEET_HEIGHT_PX;
    // Where the sheet says it can be cut for a first look without slicing a row, in its own pixels.
    folds = [];
    // How much the sheet is scaled to fit the width the tab gives it.
    scale = 1;
    // Sent with each preview and echoed by the page, so a late report from the last document is ignored.
    previewToken = 0;
    resizeObserver;
    observed;
    isSaving = false;
    saved;
    saveError;
    // The files already saved on the record, and the wire result to ask again after a save.
    files;
    filesResult;
    bones = [1, 2];
    filePageSize = FILE_PAGE_SIZE;
    filePage = 0;
    /** Whether the saved files are open. They open by themselves when there is nothing to produce, and after a save. */
    filesOpen;
    /** True when the tab is too narrow for three buttons beside the picker: two of them fold into a menu. */
    isTight = false;
    /** Whether the preview shows the whole sheet or only its top. */
    isWhole = false;

    // The holder as typed, and as last applied to the preview.
    holderDraft = '';
    addressDraft = '';
    holder = '';
    address = '';
    previewTimer;

    connectedCallback() {
        loadBrandFonts(this);
        this.handleMessage = this.handleMessage.bind(this);
        window.addEventListener('message', this.handleMessage);
    }

    disconnectedCallback() {
        window.clearTimeout(this.previewTimer);
        window.removeEventListener('message', this.handleMessage);
        this.resizeObserver?.disconnect();
    }

    /** Keeps the sheet fitted to the window it shows through, whatever width the page gives the tab. */
    renderedCallback() {
        const page = this.template.querySelector('.c-docs__page');
        if (!page || page === this.observed) {
            return;
        }
        this.resizeObserver?.disconnect();
        this.observed = page;
        this.resizeObserver = new ResizeObserver(() => this.fitSheet());
        this.resizeObserver.observe(page);
        this.fitSheet();
    }

    fitSheet() {
        const width = this.observed?.clientWidth;
        if (width) {
            const scale = Math.round((width / SHEET_WIDTH_PX) * 10000) / 10000;
            if (scale !== this.scale) {
                this.scale = scale;
            }
            const isTight = width < TIGHT_BELOW_PX;
            if (isTight !== this.isTight) {
                this.isTight = isTight;
            }
        }
    }

    /** The previewed page says how tall its sheet is, once it has drawn. */
    handleMessage(event) {
        const data = event.data;
        if (!data || data.source !== MESSAGE_SOURCE || data.token !== String(this.previewToken)) {
            return;
        }
        const height = Number(data.height);
        if (height > 0 && height < 40000) {
            this.sheetHeight = Math.ceil(height);
        }
        // Where the sheet can be cut without slicing a row of it, from the top down.
        this.folds = Array.isArray(data.folds) ? data.folds.map(Number).filter((fold) => fold > 0 && fold < 40000) : [];
    }

    // Lets the component also be opened on its own: /lightning/cmp/c__antsuranceDocuments?c__recordId=<Id>
    @wire(CurrentPageReference)
    pageReference;

    get sourceId() {
        return this.recordId ?? this.pageReference?.state?.c__recordId;
    }

    @wire(getDocuments, { recordId: '$sourceId' })
    wiredDocuments({ data, error }) {
        if (data) {
            this.documents = data;
            this.errorMessage = undefined;
            if (!data.some((document) => document.key === this.selectedKey)) {
                this.selectedKey = data[0]?.key;
                this.startPreview();
            }
        } else if (error) {
            this.documents = undefined;
            this.errorMessage = error.body?.message ?? FALLBACK_ERROR;
        }
    }

    @wire(getFiles, { recordId: '$sourceId' })
    wiredFiles(result) {
        this.filesResult = result;
        if (result.data) {
            this.files = result.data;
        } else if (result.error) {
            this.files = [];
        }
    }

    get isLoadingFiles() {
        return !this.files;
    }

    get hasFiles() {
        return this.files?.length > 0;
    }

    get fileCount() {
        return this.files?.length ?? 0;
    }

    /** The folding header says how many files are behind it, once that is known. */
    get fileCountLabel() {
        return this.files ? this.files.length : undefined;
    }

    get filesSummary() {
        if (!this.files) {
            return undefined;
        }
        return this.files.length > 0 ? `Newest: ${this.files[0].title}` : 'Copies kept as a record of what was sent';
    }

    get filesAreOpen() {
        return this.filesOpen ?? (Boolean(this.documents) && this.documents.length === 0);
    }

    handleFilesToggle(event) {
        this.filesOpen = event.detail.open;
    }

    /** The documents as tabs: one row to pick from, each with its icon. */
    get documentTabs() {
        return (this.documents ?? []).map((document) => ({ value: document.key, label: document.label, icon: document.icon, title: document.description }));
    }

    /** What the chosen document is, said once above its preview. */
    get selectedDescription() {
        const description = this.selected?.description;
        return description ? `${description} Made from this record as it stands now.` : 'Made from this record as it stands now.';
    }

    /** With documents to pick from, the tabs say what there is; the line under the title is for when there are none. */
    get showSubtitle() {
        return !this.documents || this.documents.length === 0;
    }

    handleMenu(event) {
        if (event.detail.value === 'save') {
            this.handleSave();
        } else {
            this.handleDownload();
        }
    }

    get pageFiles() {
        const page = Math.min(this.filePage, Math.max(0, Math.ceil(this.fileCount / FILE_PAGE_SIZE) - 1));
        return this.fileRows.slice(page * FILE_PAGE_SIZE, (page + 1) * FILE_PAGE_SIZE);
    }

    handleFilePage(event) {
        this.filePage = event.detail.page;
    }

    /** Each saved file with its type icon, its size and when it was saved, and by whom. */
    get fileRows() {
        const dated = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric' });
        return this.files.map((file) => {
            const kind = file.extension ? file.extension.toUpperCase() : 'File';
            const savedOn = dated.format(new Date(file.savedAt));
            return {
                ...file,
                icon: fileIcon(file.extension),
                meta: `${kind}, ${sizeWords(file.size)}, saved ${savedOn} by ${file.savedBy}`,
                url: `/lightning/r/ContentDocument/${file.contentDocumentId}/view`
            };
        });
    }

    get noFilesText() {
        return this.selected
            ? 'Save to Files keeps a copy of a document as it reads today, so there is a record of what was sent.'
            : 'Files attached to this record show here.';
    }

    get saveFirstLabel() {
        return this.isSaving ? 'Saving' : `Save the ${this.selected.label.toLowerCase()}`;
    }

    get isLoadingList() {
        return !this.documents;
    }

    get isEmpty() {
        return this.documents.length === 0;
    }

    get emptyMessage() {
        return EMPTY_MESSAGES[this.objectApiName] ?? EMPTY_FALLBACK;
    }

    get subtitle() {
        const count = this.documents?.length;
        if (!count) {
            return 'Generated from this record as it stands now.';
        }
        return count === 1 ? '1 document, generated from this record as it stands now.' : `${count} documents, generated from this record as it stands now.`;
    }

    get selected() {
        return this.documents?.find((document) => document.key === this.selectedKey);
    }

    get selectedLabel() {
        return this.selected?.label;
    }

    get takesHolder() {
        return Boolean(this.selected?.takesHolder);
    }

    get isHolderUnchanged() {
        return this.holderDraft.trim() === this.holder && this.addressDraft.trim() === this.address;
    }

    /** The page that prints the chosen document, with the certificate's holder when one was given. */
    get pdfUrl() {
        const document = this.selected;
        if (!document) {
            return undefined;
        }
        let url = document.url;
        if (document.takesHolder && this.holder) {
            url += `&holder=${encodeURIComponent(this.holder)}`;
        }
        if (document.takesHolder && this.address) {
            url += `&holderAddress=${encodeURIComponent(this.address)}`;
        }
        return url;
    }

    get embedUrl() {
        return this.pdfUrl ? `${this.pdfUrl}&preview=1&previewToken=${this.previewToken}` : undefined;
    }

    /**
     * The window opens on the top of the sheet. Shown whole, it is as tall as the scaled sheet, so the
     * page scrolls and the preview never does.
     */
    get pageStyle() {
        const whole = Math.ceil(this.sheetHeight * this.scale);
        return `height: ${this.isWhole ? whole : this.foldedHeight(whole)}px`;
    }

    /**
     * How tall the first look is. It ends under a whole row of the sheet, the lowest one that fits, so
     * no line of the document is cut through the middle. Until the sheet has said where its rows end
     * (or when none ends in the lower half of the window) it is the window's usual height.
     */
    foldedHeight(whole) {
        const most = Math.min(whole, FOLDED_PREVIEW_PX);
        const ends = (this.folds ?? []).map((fold) => Math.ceil(fold * this.scale)).filter((end) => end <= most && end >= most / 2);
        return ends.length > 0 ? Math.max(...ends) : most;
    }

    get isWholeText() {
        return this.isWhole ? 'true' : 'false';
    }

    get foldLabel() {
        return this.isWhole ? 'Show the top only' : 'Show the whole document';
    }

    get foldIcon() {
        return this.isWhole ? 'utility:chevronup' : 'utility:chevrondown';
    }

    handleFoldPreview() {
        this.isWhole = !this.isWhole;
    }

    get frameStyle() {
        return `width: ${SHEET_WIDTH_PX}px; height: ${this.sheetHeight}px; transform: scale(${this.scale})`;
    }

    get pagesNote() {
        return this.isWhole
            ? 'The whole document on one sheet. Open it in a new tab for the printed pages.'
            : 'The top of the document. Open it in a new tab for the printed pages.';
    }

    get frameTitle() {
        return this.selected ? `Preview of the ${this.selected.label.toLowerCase()}` : 'Document preview';
    }

    get saveLabel() {
        return this.isSaving ? 'Saving' : 'Save to Files';
    }

    handleChoose(event) {
        const key = event.detail.value;
        if (key !== this.selectedKey) {
            this.selectedKey = key;
            this.startPreview();
        }
    }

    handleHolderChange(event) {
        if (event.target.dataset.field === 'holder') {
            this.holderDraft = event.detail.value ?? '';
        } else {
            this.addressDraft = event.detail.value ?? '';
        }
    }

    handleHolderKey(event) {
        if (event.key === 'Enter') {
            // The typed value is only committed on change, so read it from the field.
            this.handleHolderChange({ target: event.target, detail: { value: event.target.value } });
            this.handleApplyHolder();
        }
    }

    handleApplyHolder() {
        if (this.isHolderUnchanged) {
            return;
        }
        this.holder = this.holderDraft.trim();
        this.address = this.addressDraft.trim();
        this.startPreview();
    }

    handleLoaded() {
        window.clearTimeout(this.previewTimer);
        this.isLoadingPreview = false;
        // The frame does not scroll, so the page scrolls straight through it. If the document never says
        // how tall it is, room is made for a second page so that less of it is hidden.
        const token = this.previewToken;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.previewTimer = window.setTimeout(() => {
            if (token === this.previewToken && this.sheetHeight === SHEET_HEIGHT_PX) {
                this.sheetHeight = SHEET_HEIGHT_PX * 2;
            }
        }, HEIGHT_WAIT_MS);
    }

    get frameClass() {
        return this.isLoadingPreview ? 'c-docs__pdf c-docs__pdf_loading' : 'c-docs__pdf';
    }

    handleOpen() {
        this.openInNewTab(this.pdfUrl);
    }

    handleDownload() {
        this.openInNewTab(`${this.pdfUrl}&download=1`);
    }

    async handleSave() {
        const document = this.selected;
        this.isSaving = true;
        this.saved = undefined;
        this.saveError = undefined;
        try {
            this.saved = await saveToFiles({
                recordId: this.sourceId,
                key: document.key,
                holder: document.takesHolder ? this.holder : null,
                holderAddress: document.takesHolder ? this.address : null
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved to Files', message: `${this.saved.title} is now on this record.`, variant: 'success' }));
            // Lets the Files related list on the page pick up the new file.
            this.dispatchEvent(new RefreshEvent());
            await refreshApex(this.filesResult);
            // The new copy is the newest: open the saved files on their first page so it is seen.
            this.filePage = 0;
            this.filesOpen = true;
        } catch (error) {
            this.saveError = error?.body?.message ?? SAVE_ERROR;
        } finally {
            this.isSaving = false;
        }
    }

    /** Opens a saved file in the preview. A modified click is left to the browser, for a new tab. */
    handleOpenFile(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }

    handleViewFile() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.saved.contentDocumentId }
        });
    }

    /** Shows the spinner for a new preview and clears what was said about the last document. */
    startPreview() {
        this.previewToken += 1;
        this.sheetHeight = SHEET_HEIGHT_PX;
        this.folds = [];
        this.isLoadingPreview = true;
        this.saved = undefined;
        this.saveError = undefined;
        window.clearTimeout(this.previewTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.previewTimer = window.setTimeout(() => {
            this.isLoadingPreview = false;
        }, PREVIEW_WAIT_MS);
    }

    openInNewTab(url) {
        this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url } });
    }
}
