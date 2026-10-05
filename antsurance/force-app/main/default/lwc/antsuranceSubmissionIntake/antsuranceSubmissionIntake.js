import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/AntsuranceSubmissionIntake.getContext';
import readUpload from '@salesforce/apex/AntsuranceSubmissionIntake.readUpload';
import readRecordFile from '@salesforce/apex/AntsuranceSubmissionIntake.readRecordFile';
import readSample from '@salesforce/apex/AntsuranceSubmissionIntake.readSample';
import assemble from '@salesforce/apex/AntsuranceSubmissionIntake.assemble';
import advise from '@salesforce/apex/AntsuranceSubmissionIntake.advise';
import startQuote from '@salesforce/apex/AntsuranceQuoteConfigurator.startQuote';
import SAMPLE_APPLICATION from '@salesforce/resourceUrl/antsuranceSubmissionApplication';
import SAMPLE_LOSS_RUN from '@salesforce/resourceUrl/antsuranceSubmissionLossRun';
import SAMPLE_COVER_NOTE from '@salesforce/resourceUrl/antsuranceSubmissionCoverNote';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';
import { leaveAnswers, runKey, keepRun, recallRun, forgetRun } from 'c/antsuranceSubmissionHandover';

const NO_BREAK_SPACE = '\u00a0';
const SAMPLE_URLS = {
    antsuranceSubmissionApplication: SAMPLE_APPLICATION,
    antsuranceSubmissionLossRun: SAMPLE_LOSS_RUN,
    antsuranceSubmissionCoverNote: SAMPLE_COVER_NOTE
};
const MEDIA_TYPES = { pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' };
const ACCEPT = '.pdf,.png,.jpg,.jpeg,.gif,.webp';
// A photo is redrawn no longer than this on a side, the size Claude reads at full detail.
const PHOTO_SIDE_PX = 1568;
const PHOTO_QUALITIES = [0.85, 0.7, 0.55, 0.4];
const MAX_PDF_PAGES = 20;
const ROWS_A_PAGE = 5;
// In a narrow column each row stacks and is taller, so a page holds fewer and the card stays about a screen tall.
const ROWS_A_NARROW_PAGE = 3;
const ISSUES_A_PAGE = 4;
const NARROW_PX = 704;
const FALLBACK_ERROR = 'Something went wrong. Try again.';
const STATUS = {
    read: { label: 'Read', className: 'c-chip c-chip_read' },
    worked_out: { label: 'Worked out', className: 'c-chip c-chip_worked' },
    conflict: { label: 'Documents disagree', className: 'c-chip c-chip_conflict' },
    not_found: { label: 'Not found', className: 'c-chip c-chip_none' },
    changed: { label: 'Set by you', className: 'c-chip c-chip_changed' }
};
const ISSUE_KINDS = {
    missing: { label: 'Missing', icon: 'utility:question_mark', className: 'c-ui-tile c-ui-tile_small c-ui-tile_sand' },
    inconsistent: { label: 'Documents disagree', icon: 'utility:warning', className: 'c-ui-tile c-ui-tile_small c-ui-tile_amber' },
    differs_from_record: { label: 'Differs from our record', icon: 'utility:change_record_type', className: 'c-ui-tile c-ui-tile_small c-ui-tile_amber' },
    unreadable: { label: 'Could not read', icon: 'utility:hide', className: 'c-ui-tile c-ui-tile_small c-ui-tile_sand' },
    appetite: { label: 'For the underwriter', icon: 'utility:shield', className: 'c-ui-tile c-ui-tile_small c-ui-tile_clay' }
};
const DOCUMENT_ICONS = { application: 'utility:form', loss_run: 'utility:table', cover_note: 'utility:email', schedule: 'utility:list', other: 'utility:file' };

let nextFileNumber = 0;

function sizeLabel(bytes) {
    return bytes >= 1000000 ? `${(bytes / 1000000).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1000))} KB`;
}

function extensionOf(name) {
    const dot = (name ?? '').lastIndexOf('.');
    return dot < 0 ? '' : name.slice(dot + 1).toLowerCase();
}

function toBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    const parts = [];
    for (let start = 0; start < bytes.length; start += 0x8000) {
        parts.push(String.fromCharCode.apply(null, bytes.subarray(start, start + 0x8000)));
    }
    return window.btoa(parts.join(''));
}

/** A rough page count: how many page objects the file declares. Zero when the file packs them out of sight. */
function pdfPages(buffer) {
    const text = new TextDecoder('latin1').decode(buffer);
    return (text.match(/\/Type\s*\/Page(?![s\w])/g) ?? []).length;
}

function loadImage(file) {
    return new Promise((resolve, reject) => {
        const url = URL.createObjectURL(file);
        const image = new Image();
        image.onload = () => {
            URL.revokeObjectURL(url);
            resolve(image);
        };
        image.onerror = () => {
            URL.revokeObjectURL(url);
            reject(new Error('unreadable'));
        };
        image.src = url;
    });
}

/** Redraws a photo as a JPEG small enough to send, lowering quality and then size until it fits. */
async function shrinkPhoto(file, maxBytes) {
    const image = await loadImage(file);
    let side = PHOTO_SIDE_PX;
    for (let attempt = 0; attempt < 3; attempt += 1) {
        const scale = Math.min(1, side / Math.max(image.naturalWidth, image.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        const context = canvas.getContext('2d');
        context.fillStyle = '#ffffff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        for (const quality of PHOTO_QUALITIES) {
            const base64 = canvas.toDataURL('image/jpeg', quality).split(',')[1];
            const bytes = Math.floor((base64.length * 3) / 4);
            if (bytes <= maxBytes) {
                return { base64, bytes };
            }
        }
        side = Math.round(side * 0.7);
    }
    return undefined;
}

export default class AntsuranceSubmissionIntake extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    context;
    loadError;
    // The documents chosen for this reading, in order, each with where it is in the process.
    files = [];
    notice;
    isDragging = false;
    isReading = false;
    showsRecordFiles = false;

    assembly;
    assemblyError;
    advice;
    // idle, loading, ready or failed.
    adviceState = 'idle';
    adviceError;
    // True when the person has changed an answer since Claude wrote the issues and the reply.
    isAdviceStale = false;
    choices = {};
    tab = 'answers';
    page = 0;
    issuePage = 0;
    isNarrow = false;
    onWindowResize;
    measureTimer;
    isStarting = false;
    hasCopied = false;

    accept = ACCEPT;

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
        this.onWindowResize = () => this.measure();
        window.addEventListener('resize', this.onWindowResize);
        // A tab that is not in front draws no frames, so the width is read on a timer as well as on resize.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.measureTimer = setInterval(() => this.measure(), 1500);
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.onWindowResize);
        clearInterval(this.measureTimer);
    }

    renderedCallback() {
        this.measure();
    }

    measure() {
        const width = this.template.host.getBoundingClientRect().width;
        if (width > 0 && width < NARROW_PX !== this.isNarrow) {
            this.isNarrow = width < NARROW_PX;
            this.page = 0;
            this.issuePage = 0;
        }
    }

    async load() {
        try {
            this.context = await getContext({ recordId: this.recordId });
            this.loadError = undefined;
            this.restore();
        } catch (error) {
            this.loadError = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    // ------------------------------------------------------------ keeping a reading for this tab

    get storeKey() {
        return runKey(this.context?.customerName, this.context?.lineOfBusiness);
    }

    /** What was read earlier in this tab for the same customer and line: on this record, or on the lead it came from. */
    restore() {
        const run = recallRun(this.storeKey);
        if (!run || !Array.isArray(run.files) || run.files.length === 0 || this.files.length > 0) {
            return;
        }
        this.files = run.files.map((file) => ({ ...file, id: this.newId(), base64: undefined, status: 'read' }));
        this.choices = run.choices ?? {};
        this.advice = run.advice;
        this.adviceState = run.advice ? 'ready' : 'idle';
        this.runAssemble();
    }

    remember() {
        const files = this.readFiles.map(({ name, source, refId, kind, reading, sizeText }) => ({ name, source, refId, kind, reading, sizeText }));
        if (files.length === 0) {
            forgetRun(this.storeKey);
            return;
        }
        keepRun(this.storeKey, { files, choices: this.choices, advice: this.isAdviceStale ? undefined : this.advice });
    }

    // ------------------------------------------------------------ state

    get isLoading() {
        return !this.context && !this.loadError;
    }

    get canRead() {
        return this.context?.canRead === true;
    }

    get isSale() {
        return this.context?.recordKind === 'sale';
    }

    get hasFiles() {
        return this.files.length > 0;
    }

    get readFiles() {
        return this.files.filter((file) => file.status === 'read');
    }

    get waitingFiles() {
        return this.files.filter((file) => file.status === 'ready' || file.status === 'failed');
    }

    get hasResult() {
        return this.assembly !== undefined;
    }

    get isResting() {
        return !this.hasFiles;
    }

    get roomLeft() {
        return (this.context?.maxFiles ?? 4) - this.files.length;
    }

    get cardClass() {
        return this.isDragging ? 'c-intake c-intake_dragging' : 'c-intake';
    }

    get intro() {
        return this.isSale
            ? "Drop the broker's documents here. Claude fills in the quote for you to check."
            : "Drop the broker's documents here. Claude reads them against the quote questions.";
    }

    get capsText() {
        const pdf = sizeLabel(this.context?.maxPdfBytes ?? 900000);
        return `Up to ${this.context?.maxFiles ?? 4} files. PDFs up to ${pdf} and ${MAX_PDF_PAGES} pages. Photos are resized for you.`;
    }

    get hasSample() {
        return (this.context?.samples ?? []).length > 0 && this.isResting;
    }

    get recordFiles() {
        const chosen = new Set(this.files.filter((file) => file.source === 'record').map((file) => file.refId));
        return (this.context?.files ?? []).map((file) => {
            const isChosen = chosen.has(file.id);
            const isOff = !file.readable || isChosen || this.roomLeft <= 0;
            return {
                ...file,
                isOff,
                detail: isChosen ? 'Already added' : file.readable ? `${(file.extension ?? '').toUpperCase()} · ${file.sizeLabel}` : file.whyNot,
                className: isOff ? 'c-pick c-pick_off' : 'c-pick c-ui-open'
            };
        });
    }

    get hasRecordFiles() {
        return (this.context?.files ?? []).length > 0 && !this.isReading;
    }

    get recordFilesLabel() {
        return this.isSale ? "Use this sale's files" : "Use this lead's files";
    }

    get canAddMore() {
        return this.roomLeft > 0 && !this.isReading;
    }

    get fileChips() {
        return this.files.map((file, index) => {
            const isRead = file.status === 'read';
            const isFailed = file.status === 'failed';
            const isBusy = file.status === 'reading';
            let detail = file.sizeText;
            if (isBusy) {
                detail = `Reading ${index + 1} of ${this.files.length}`;
            } else if (isRead) {
                const pages = file.reading.pages;
                detail = `${file.reading.kindLabel}${pages ? `, ${pages} ${pages === 1 ? 'page' : 'pages'}` : ''}`;
            } else if (isFailed) {
                detail = 'Could not be read';
            }
            return {
                id: file.id,
                name: file.name,
                detail,
                error: isFailed ? file.error : undefined,
                isBusy,
                isFailed,
                canRemove: !this.isReading,
                icon: isRead ? (DOCUMENT_ICONS[file.reading.kind] ?? 'utility:file') : isFailed ? 'utility:warning' : file.kind === 'pdf' ? 'utility:file' : 'utility:image',
                removeLabel: `Remove ${file.name}`,
                className: `c-file${isRead ? ' c-file_read' : ''}${isFailed ? ' c-file_failed' : ''}`
            };
        });
    }

    get fileErrors() {
        return this.files.filter((file) => file.status === 'failed' && file.error).map((file) => ({ id: file.id, text: `${file.name}: ${file.error}` }));
    }

    get recordFilesExpanded() {
        return this.showsRecordFiles ? 'true' : 'false';
    }

    get canStartReading() {
        return this.waitingFiles.length > 0 && !this.isReading;
    }

    get readLabel() {
        const waiting = this.waitingFiles.length;
        if (this.readFiles.length > 0) {
            return waiting === 1 ? 'Read the one left' : `Read the ${waiting} left`;
        }
        return waiting === 1 ? 'Read it with Claude' : `Read ${waiting} with Claude`;
    }

    get readingLine() {
        const busy = this.files.find((file) => file.status === 'reading');
        return busy ? `Claude is reading ${busy.name}. Each document takes about ten seconds.` : undefined;
    }

    // ------------------------------------------------------------ adding documents

    newId() {
        nextFileNumber += 1;
        return `file-${nextFileNumber}`;
    }

    handleBrowse() {
        this.template.querySelector('input[type="file"]')?.click();
    }

    handleChosen(event) {
        const files = [...event.target.files];
        event.target.value = '';
        this.addFiles(files);
    }

    handleDragOver(event) {
        if (!this.canRead || this.isReading) {
            return;
        }
        event.preventDefault();
        this.isDragging = true;
    }

    handleDragLeave(event) {
        // Leaving a child for another part of the card is not leaving the card.
        if (!event.currentTarget.contains(event.relatedTarget)) {
            this.isDragging = false;
        }
    }

    handleDrop(event) {
        event.preventDefault();
        this.isDragging = false;
        if (this.canRead && !this.isReading) {
            this.addFiles([...(event.dataTransfer?.files ?? [])]);
        }
    }

    async addFiles(chosen) {
        const refused = [];
        for (const file of chosen) {
            if (this.roomLeft <= 0) {
                refused.push(`${file.name} was left out: ${this.context.maxFiles} files is the most for one reading.`);
                continue;
            }
            const extension = extensionOf(file.name);
            const mediaType = MEDIA_TYPES[extension];
            if (!mediaType) {
                refused.push(`${file.name} was left out: Claude reads PDFs and photos here.`);
                continue;
            }
            try {
                // eslint-disable-next-line no-await-in-loop
                const prepared = extension === 'pdf' ? await this.preparePdf(file) : await this.preparePhoto(file);
                if (prepared.refusal) {
                    refused.push(prepared.refusal);
                    continue;
                }
                this.files = [...this.files, { id: this.newId(), name: file.name, source: 'upload', kind: extension === 'pdf' ? 'pdf' : 'photo', status: 'ready', ...prepared }];
            } catch (error) {
                refused.push(`${file.name} could not be opened.`);
            }
        }
        this.notice = refused.length > 0 ? refused.join(' ') : undefined;
    }

    async preparePdf(file) {
        if (file.size > this.context.maxPdfBytes) {
            return { refusal: `${file.name} was left out: it is ${sizeLabel(file.size)} and the limit for a PDF is ${sizeLabel(this.context.maxPdfBytes)}. Send the pages that matter.` };
        }
        const buffer = await file.arrayBuffer();
        const pages = pdfPages(buffer);
        if (pages > MAX_PDF_PAGES) {
            return { refusal: `${file.name} was left out: it has about ${pages} pages and the limit is ${MAX_PDF_PAGES}. Send the pages that matter.` };
        }
        return { mediaType: 'application/pdf', base64: toBase64(buffer), sizeText: `PDF · ${sizeLabel(file.size)}` };
    }

    async preparePhoto(file) {
        const photo = await shrinkPhoto(file, this.context.maxImageBytes);
        if (!photo) {
            return { refusal: `${file.name} was left out: it could not be made small enough to send.` };
        }
        return { mediaType: 'image/jpeg', base64: photo.base64, sizeText: `Photo · ${sizeLabel(photo.bytes)}` };
    }

    handleUseSample() {
        const added = this.context.samples
            .slice(0, Math.max(0, this.roomLeft))
            .map((sample) => ({ id: this.newId(), name: sample.title, source: 'sample', refId: sample.id, kind: 'pdf', status: 'ready', sizeText: `Sample PDF · ${sample.sizeLabel}` }));
        this.files = [...this.files, ...added];
        this.notice = undefined;
    }

    handleToggleRecordFiles() {
        this.showsRecordFiles = !this.showsRecordFiles;
    }

    handlePickRecordFile(event) {
        const picked = (this.context?.files ?? []).find((file) => file.id === event.currentTarget.dataset.id);
        if (!picked || !picked.readable || this.roomLeft <= 0 || this.files.some((file) => file.refId === picked.id)) {
            return;
        }
        this.files = [
            ...this.files,
            { id: this.newId(), name: picked.title, source: 'record', refId: picked.id, kind: picked.extension === 'pdf' ? 'pdf' : 'photo', status: 'ready', sizeText: `${picked.extension.toUpperCase()} · ${picked.sizeLabel}` }
        ];
        this.showsRecordFiles = this.roomLeft > 0;
    }

    handleRemove(event) {
        const { id } = event.currentTarget.dataset;
        const wasRead = this.files.find((file) => file.id === id)?.status === 'read';
        this.files = this.files.filter((file) => file.id !== id);
        if (this.files.length === 0) {
            this.reset();
        } else if (wasRead) {
            this.afterReading();
        }
    }

    handleStartOver() {
        this.files = [];
        this.reset();
    }

    reset() {
        this.assembly = undefined;
        this.assemblyError = undefined;
        this.advice = undefined;
        this.adviceState = 'idle';
        this.adviceError = undefined;
        this.isAdviceStale = false;
        this.choices = {};
        this.notice = undefined;
        this.tab = 'answers';
        this.page = 0;
        this.issuePage = 0;
        this.hasCopied = false;
        forgetRun(this.storeKey);
    }

    // ------------------------------------------------------------ reading

    patch(id, changes) {
        this.files = this.files.map((file) => (file.id === id ? { ...file, ...changes } : file));
    }

    /** One document, one request, so a slow document never costs the ones already read. */
    async readOne(file) {
        this.patch(file.id, { status: 'reading', error: undefined });
        try {
            let reading;
            if (file.source === 'sample') {
                reading = await readSample({ recordId: this.recordId, name: file.refId });
            } else if (file.source === 'record') {
                reading = await readRecordFile({ recordId: this.recordId, documentId: file.refId });
            } else {
                reading = await readUpload({ recordId: this.recordId, name: file.name, mediaType: file.mediaType, base64: file.base64 });
            }
            // The file itself is let go once it has been read: only what it said is kept.
            this.patch(file.id, { status: 'read', reading, base64: undefined });
        } catch (error) {
            this.patch(file.id, { status: 'failed', error: error?.body?.message ?? FALLBACK_ERROR });
        }
    }

    async handleRead() {
        if (this.isReading) {
            return;
        }
        this.isReading = true;
        this.notice = undefined;
        this.showsRecordFiles = false;
        try {
            for (const file of this.waitingFiles) {
                // eslint-disable-next-line no-await-in-loop
                await this.readOne(file);
            }
        } finally {
            this.isReading = false;
        }
        await this.afterReading();
    }

    async handleRetryFile(event) {
        const file = this.files.find((item) => item.id === event.currentTarget.dataset.id);
        if (!file || this.isReading) {
            return;
        }
        this.isReading = true;
        try {
            await this.readOne(file);
        } finally {
            this.isReading = false;
        }
        await this.afterReading();
    }

    get readingsJson() {
        return JSON.stringify(this.readFiles.map((file) => ({ ...file.reading, name: file.name })));
    }

    async afterReading() {
        if (this.readFiles.length === 0) {
            this.assembly = undefined;
            return;
        }
        await this.runAssemble();
        if (this.assembly) {
            this.runAdvise();
        }
    }

    /** Lays the documents against the questions. No call to Claude: it is quick, and it is the part a person can trust to add up. */
    async runAssemble() {
        try {
            this.assembly = await assemble({ recordId: this.recordId, readingsJson: this.readingsJson, choicesJson: JSON.stringify(this.choices) });
            this.assemblyError = undefined;
            const lastPage = Math.max(0, Math.ceil(this.assembly.rows.length / this.rowsAPage) - 1);
            this.page = Math.min(this.page, lastPage);
            this.remember();
        } catch (error) {
            this.assemblyError = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    async runAdvise() {
        this.adviceState = 'loading';
        this.adviceError = undefined;
        const asked = this.readingsJson + JSON.stringify(this.choices);
        try {
            const advice = await advise({ recordId: this.recordId, readingsJson: this.readingsJson, choicesJson: JSON.stringify(this.choices) });
            if (asked !== this.readingsJson + JSON.stringify(this.choices)) {
                // The documents or the answers moved on while Claude was writing.
                this.isAdviceStale = true;
            } else {
                this.isAdviceStale = false;
            }
            this.advice = advice;
            this.adviceState = 'ready';
            this.issuePage = 0;
            this.hasCopied = false;
            this.remember();
        } catch (error) {
            this.adviceState = this.advice ? 'ready' : 'failed';
            this.adviceError = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    handleAdviseAgain() {
        this.runAdvise();
    }

    // ------------------------------------------------------------ the result

    get headline() {
        if (this.advice?.headline && !this.isAdviceStale) {
            return keepTogether(this.advice.headline);
        }
        const count = this.readFiles.length;
        return `${count} ${count === 1 ? 'document' : 'documents'} read for ${this.context.customerName ?? 'this customer'}.`;
    }

    get tally() {
        const { settled, conflicts, notFound } = this.assembly;
        const parts = [`${settled} ${settled === 1 ? 'answer' : 'answers'} filled`];
        if (conflicts > 0) {
            parts.push(`${conflicts} where the documents disagree`);
        }
        if (notFound > 0) {
            parts.push(`${notFound} not in the documents`);
        }
        return `${parts.join(', ')}.`;
    }

    get issues() {
        return (this.advice?.issues ?? []).map((issue, index) => ({ ...issue, key: `issue-${index}`, ...ISSUE_KINDS[issue.kind], detail: keepTogether(issue.detail), ask: keepTogether(issue.ask) }));
    }

    get missingIssues() {
        return this.issues.filter((issue) => issue.kind !== 'appetite');
    }

    get appetiteIssues() {
        return this.issues.filter((issue) => issue.kind === 'appetite');
    }

    /** What the documents leave open, worked out without Claude, for while it is writing or if it cannot. */
    get openRows() {
        return (this.assembly?.rows ?? [])
            .filter((row) => row.status === 'conflict' || row.status === 'not_found')
            .map((row) => ({
                key: row.key,
                ...ISSUE_KINDS[row.status === 'conflict' ? 'inconsistent' : 'missing'],
                title: row.label,
                detail: row.status === 'conflict' ? row.sources.map((source) => `${source.document} says ${source.valueLabel}`).join('. ') + '.' : 'None of the documents answers this.'
            }));
    }

    get isAdviceLoading() {
        return this.adviceState === 'loading';
    }

    get isAdviceReady() {
        return this.adviceState === 'ready' && this.advice !== undefined;
    }

    get isAdviceFailed() {
        return this.adviceState === 'failed';
    }

    get showsOpenRows() {
        return !this.isAdviceReady && this.openRows.length > 0;
    }

    get hasNothingMissing() {
        return this.isAdviceReady && this.missingIssues.length === 0;
    }

    get referralCount() {
        return (this.assembly?.referrals.length ?? 0) + (this.assembly?.conditionals.length ?? 0);
    }

    get tabs() {
        const missing = this.isAdviceReady ? this.missingIssues.length : this.openRows.length;
        const appetite = this.referralCount + this.appetiteIssues.length;
        return [
            { value: 'answers', label: 'Answers', count: this.assembly.rows.length },
            { value: 'appetite', label: 'Appetite', count: appetite, tone: this.referralCount > 0 ? 'watch' : undefined },
            { value: 'missing', label: 'Missing', count: missing, tone: missing > 0 ? 'watch' : undefined },
            { value: 'reply', label: 'Reply to the broker' },
            { value: 'documents', label: 'Documents', count: this.readFiles.length }
        ];
    }

    get isAnswers() {
        return this.tab === 'answers';
    }

    get isAppetite() {
        return this.tab === 'appetite';
    }

    get isMissing() {
        return this.tab === 'missing';
    }

    get isReply() {
        return this.tab === 'reply';
    }

    get isDocuments() {
        return this.tab === 'documents';
    }

    handleTab(event) {
        this.tab = event.detail.value;
    }

    handlePage(event) {
        this.page = event.detail.page;
    }

    get rowCount() {
        return this.assembly.rows.length;
    }

    get rowsAPage() {
        return this.isNarrow ? ROWS_A_NARROW_PAGE : ROWS_A_PAGE;
    }

    get issuesAPage() {
        return this.isNarrow ? ROWS_A_NARROW_PAGE : ISSUES_A_PAGE;
    }

    get missingCount() {
        return this.missingIssues.length;
    }

    get shownMissing() {
        return this.missingIssues.slice(this.issuePage * this.issuesAPage, (this.issuePage + 1) * this.issuesAPage);
    }

    handleIssuePage(event) {
        this.issuePage = event.detail.page;
    }

    get rows() {
        return this.assembly.rows.slice(this.page * this.rowsAPage, (this.page + 1) * this.rowsAPage).map((row) => {
            const isConflict = row.status === 'conflict';
            const first = row.sources[0];
            const isPick = row.type === 'choice' || row.type === 'toggle';
            const isAmount = row.type === 'number' || row.type === 'currency';
            // Each document's own figure, once: the person chooses, the page never does.
            const seen = new Set();
            const sides = row.sources
                .filter((source) => (seen.has(source.value) ? false : seen.add(source.value)))
                .map((source) => ({
                    key: `${row.key}-${source.value}`,
                    value: source.value,
                    label: `${source.document}: ${source.valueLabel}`,
                    where: this.whereOf(source),
                    words: source.words ? `"${source.words}"` : undefined
                }));
            const others = row.sources.length - 1;
            return {
                ...row,
                statusLabel: STATUS[row.status].label,
                statusClass: STATUS[row.status].className,
                isConflict,
                isPick,
                isAmount,
                isText: !isPick && !isAmount,
                inputLabel: `Answer for ${row.label}`,
                inputValue: row.value ?? '',
                picks: [
                    { value: '', label: isConflict ? 'Choose' : 'Not answered', selected: row.value == null },
                    ...row.options.map((option) => ({ ...option, selected: option.value === row.value }))
                ],
                sides,
                hasSource: !isConflict && first !== undefined,
                where: first ? `${this.whereOf(first)}${others > 0 ? ` and ${others} more` : ''}` : undefined,
                words: first?.words ? `"${first.words}"` : undefined,
                note: first?.basis === 'worked_out' && row.status === 'worked_out' ? first.note : undefined,
                sourceFile: first ? this.fileNamed(first.document)?.id : undefined,
                sourcePage: first?.page,
                canView: first ? this.canView(this.fileNamed(first.document)) : false,
                viewLabel: first?.page ? `Open page ${first.page}` : 'Open the document',
                emptyText: row.status === 'not_found' ? 'Not in the documents. The quote keeps its usual starting answer.' : row.status === 'changed' ? 'Your answer. No document gave one.' : undefined
            };
        });
    }

    whereOf(source) {
        return source.page ? `${source.document}, page ${source.page}` : source.document;
    }

    fileNamed(name) {
        return this.files.find((file) => file.name === name);
    }

    canView(file) {
        return file !== undefined && (file.source === 'sample' || file.source === 'record');
    }

    /** Opens the document a figure came from: the sample at its page, a record's file in the file viewer. */
    handleView(event) {
        const { id, page } = event.currentTarget.dataset;
        const file = this.files.find((item) => item.id === id);
        if (!file) {
            return;
        }
        if (file.source === 'sample') {
            window.open(`${SAMPLE_URLS[file.refId]}${page ? `#page=${page}` : ''}`, '_blank', 'noopener');
        } else if (file.source === 'record') {
            this[NavigationMixin.Navigate]({ type: 'standard__namedPage', attributes: { pageName: 'filePreview' }, state: { selectedRecordId: file.refId } });
        }
    }

    setChoice(key, value) {
        const choices = { ...this.choices };
        if (value === '' || value === undefined || value === null) {
            delete choices[key];
        } else {
            choices[key] = String(value);
        }
        this.choices = choices;
        this.isAdviceStale = this.advice !== undefined;
        this.runAssemble();
    }

    handleAnswer(event) {
        this.setChoice(event.target.dataset.key, event.target.value.trim());
    }

    handleSide(event) {
        const { key, value } = event.currentTarget.dataset;
        this.setChoice(key, value);
    }

    get referrals() {
        return (this.assembly?.referrals ?? []).map((reason, index) => ({ key: `referral-${index}`, reason }));
    }

    get conditionals() {
        return (this.assembly?.conditionals ?? []).map((item, index) => ({
            key: `conditional-${index}`,
            lead: `If the ${item.document.toLowerCase()} is right`,
            detail: `${item.question}: ${item.valueLabel}. That would send the quote to an underwriter for "${item.reasons.join('", "')}".`
        }));
    }

    get hasNoAppetite() {
        return this.referralCount === 0 && this.appetiteIssues.length === 0;
    }

    get documents() {
        return this.readFiles.map((file) => {
            const { reading } = file;
            const notes = [...(reading.problems ?? [])];
            if (reading.unreadable) {
                notes.push(`Could not be read: ${reading.unreadable}`);
            }
            return {
                id: file.id,
                name: file.name,
                icon: DOCUMENT_ICONS[reading.kind] ?? 'utility:file',
                summary: keepTogether(reading.summary),
                count: (reading.answers ?? []).length,
                line: `${reading.kindLabel}${reading.pages ? `, ${reading.pages} ${reading.pages === 1 ? 'page' : 'pages'}` : ''}`,
                notes: notes.map((text, index) => ({ key: `${file.id}-note-${index}`, text: keepTogether(text) })),
                hasNotes: notes.length > 0,
                facts: (reading.facts ?? []).slice(0, 6).map((fact, index) => ({ key: `${file.id}-fact-${index}`, label: fact.label, value: keepTogether(fact.value) })),
                hasFacts: (reading.facts ?? []).length > 0,
                canView: this.canView(file)
            };
        });
    }

    get replyText() {
        return this.advice ? `Subject: ${this.advice.replySubject ?? ''}\n\n${this.advice.replyBody ?? ''}` : '';
    }

    get copyLabel() {
        return this.hasCopied ? 'Copied' : 'Copy the reply';
    }

    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.replyText);
            this.hasCopied = true;
        } catch (error) {
            // The browser would not copy for us: select the text so one keystroke copies it.
            const box = this.template.querySelector('textarea');
            box?.focus();
            box?.select();
        }
    }

    // ------------------------------------------------------------ on to the quote

    get canQuote() {
        return this.context?.canQuote === true && this.assembly !== undefined;
    }

    get quoteDisabled() {
        return this.isStarting || this.isReading || this.assembly.settled === 0;
    }

    get footNote() {
        if (!this.isSale) {
            return 'Convert the lead to a policy sale to quote it. What was read is kept in this browser tab until then.';
        }
        if (!this.context.canQuote) {
            return 'This sale is closed, so no new quote can be started from here.';
        }
        // The button starts a draft quote on the sale at once, because the configurator lives on the quote's
        // own page: the line says so, and how to be rid of the draft. Its last sentence stays on one line.
        const opens = `This opens a draft quote on the sale with these answers. ${'Cancel on the quote discards it.'.replace(/ /g, NO_BREAK_SPACE)}`;
        const open = this.assembly.conflicts + this.assembly.notFound;
        return open > 0 ? `${open} ${open === 1 ? 'answer still starts' : 'answers still start'} from the quote's usual answer. ${opens}` : opens;
    }

    async handleOpenQuote() {
        if (this.isStarting) {
            return;
        }
        this.isStarting = true;
        try {
            const quoteId = await startQuote({ opportunityId: this.recordId });
            const count = this.readFiles.length;
            const kept = leaveAnswers(quoteId, JSON.parse(this.assembly.answersJson), `the broker's submission (${count} ${count === 1 ? 'document' : 'documents'})`);
            if (!kept) {
                this.dispatchEvent(new ShowToastEvent({ title: 'The answers could not be carried over', message: 'This browser would not hold them. The quote has opened with its usual starting answers.', variant: 'warning' }));
            }
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: quoteId, objectApiName: 'Quote', actionName: 'view' } });
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'The quote could not be started', message: error?.body?.message ?? FALLBACK_ERROR, variant: 'error' }));
        } finally {
            this.isStarting = false;
        }
    }
}
