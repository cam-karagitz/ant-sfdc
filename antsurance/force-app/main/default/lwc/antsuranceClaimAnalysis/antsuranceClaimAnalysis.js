import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent, registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import NOTE_TYPE from '@salesforce/schema/File_Note__c.Note_Type__c';
import addNote from '@salesforce/apex/AntsuranceNotesController.addNote';
import getDocket from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.getDocket';
import readDocumentStep from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.readDocumentStep';
import readVideoStep from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.readVideoStep';
import videoData from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.videoData';
import checkCoverageStep from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.checkCoverageStep';
import writeReportStep from '@salesforce/apex/AntsuranceClaimsAssistantAnalysis.writeReportStep';
import assessBatch from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.assessBatch';
import finishAssessment from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.finishAssessment';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether, tidyEnding } from 'c/antsuranceText';
import { pageOf, recall, remember } from 'c/antsuranceUiMemory';
import { framesFromMp4 } from './videoFrames';

const FRAMES = 6;
const FRAME_LONG_EDGE = 640;
const FRAME_QUALITY = 0.72;
const MEDIA_WAIT_MS = 20000;
const VIDEO_TYPES = { mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm', avi: 'video/x-msvideo' };
const FALLBACK_ERROR = 'That did not work. Try again.';
const NO_PLAYBACK = 'This browser could not play that video to take frames from it. Skip it, or add stills from it as photos.';

const GROUPS = [
    { kind: 'photo', title: 'Photos', one: 'photo', many: 'photos' },
    { kind: 'video', title: 'Videos', one: 'video', many: 'videos' },
    { kind: 'document', title: 'Documents', one: 'document', many: 'documents' },
    { kind: 'note', title: 'File notes and statements', one: 'file note', many: 'file notes' }
];
// Photos and videos are looked at, so they are tiles in a row that steps sideways. The rest is read, so it gets full-width rows.
const VISUAL_KINDS = ['photo', 'video'];
const FILE_KINDS = ['photo', 'video', 'document'];
const ROWS_PER_PAGE = 5;
// What Claude can look at or read here, and so what is worth adding from this tab.
const ACCEPTED_FORMATS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf', '.mp4', '.mov'];
// File Note has no record types, so its picklists hang off the master record type.
const MASTER_RECORD_TYPE = '012000000000000AAA';
const DEFAULT_NOTE_TYPE = 'Investigation';
const TILE_ICONS = { video: 'utility:video', document: 'utility:file', note: 'utility:note', statement: 'utility:quotation_marks' };

const STATE_WORDS = { waiting: 'Waiting', working: 'Working', done: 'Done', reused: 'Already done', failed: 'Did not finish', skipped: 'Skipped' };

function when(value) {
    if (!value) {
        return '';
    }
    const date = new Date(value);
    const sameYear = date.getFullYear() === new Date().getFullYear();
    return new Intl.DateTimeFormat('en-US', sameYear ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
}

function firstSentence(text) {
    if (!text) {
        return '';
    }
    const stop = text.indexOf('. ');
    return stop > 0 ? text.slice(0, stop + 1) : text;
}

/** Waits for one event on a media element, or fails if the element errors or nothing happens in time. */
function once(element, eventName) {
    return new Promise((resolve, reject) => {
        let timer;
        const finish = (settle, value) => {
            clearTimeout(timer);
            element.removeEventListener(eventName, onEvent);
            element.removeEventListener('error', onError);
            settle(value);
        };
        const onEvent = () => finish(resolve);
        const onError = () => finish(reject, new Error('media error'));
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        timer = setTimeout(() => finish(reject, new Error('media timeout')), MEDIA_WAIT_MS);
        element.addEventListener(eventName, onEvent);
        element.addEventListener('error', onError);
    });
}

/**
 * The Analysis tab on a claim.
 *
 * Top to bottom: one line saying what evidence there is, with the button to analyze it; the steps of
 * a run ticking off, folded to one line once it has finished; the evidence docket (every photo,
 * video, document, file note and the insured's own statement, each saying whether Claude has looked
 * at it), one kind at a time, photos and videos as tiles that step sideways and the rest as rows;
 * and the adjuster's report. A claim with no photo, video or document says so and takes them here. Once there is a
 * report the docket folds away, so the tab opens on the report and stays about one screen tall.
 *
 * Salesforce allows a request 120 seconds of callout time, so this component drives the run: each
 * step is its own request with at most one call to Claude. A step that fails keeps everything
 * already done, shows why in place, and can be tried again alone or skipped.
 */
export default class AntsuranceClaimAnalysis extends NavigationMixin(LightningElement) {
    @api recordId;

    docket;
    errorMessage;
    isLoading = true;
    isRunning = false;
    steps = [];
    failedIndex;
    hasRun = false;
    // The docket is open until there is a report to read; after that it folds away above it.
    docketToggled;
    // Which kind of evidence the docket is showing, and which page of its rows.
    kind;
    rowPage = 0;
    rowsPerPage = ROWS_PER_PAGE;
    acceptedFormats = ACCEPTED_FORMATS;
    // Adding evidence: whether the panel is open (it opens by itself on a claim with no files), and the note being written in it.
    addToggled;
    noteTypes = [];
    noteType = DEFAULT_NOTE_TYPE;
    noteDraft = '';
    noteError;
    isSavingNote = false;

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE, fieldApiName: NOTE_TYPE })
    wiredNoteTypes({ data }) {
        if (data) {
            this.noteTypes = data.values.map(({ label, value }) => ({ label, value }));
        }
    }

    connectedCallback() {
        loadBrandFonts(this);
        this.kind = recall(`${this.recordId}:analysis-docket-kind`);
        this.load();
        // A note or a file added on another tab of the page (File Notes, Documents) is evidence here too.
        this.refreshHandler = registerRefreshHandler(this, () => (this.isRunning ? Promise.resolve() : this.load()));
    }

    disconnectedCallback() {
        unregisterRefreshHandler(this.refreshHandler);
    }

    async load() {
        try {
            this.docket = await getDocket({ caseId: this.recordId });
            this.errorMessage = undefined;
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isLoading = false;
        }
    }

    // ---------------------------------------------------------------- the docket

    get hasDocket() {
        return Boolean(this.docket);
    }

    get items() {
        return this.docket?.items ?? [];
    }

    get groups() {
        return GROUPS.map((group) => {
            const members = this.items
                .filter((item) => item.kind === group.kind || (group.kind === 'note' && item.kind === 'statement'))
                .map((item) => this.tile(item));
            return {
                ...group,
                tiles: members,
                count: members.length,
                hasTiles: members.length > 0,
                isVisual: VISUAL_KINDS.includes(group.kind),
                pagerLabel: group.title.toLowerCase()
            };
        }).filter((group) => group.hasTiles);
    }

    get hasSeveralKinds() {
        return this.groups.length > 1;
    }

    get kindTabs() {
        return this.groups.map((group) => ({ value: group.kind, label: group.title, count: group.count }));
    }

    /** The kind of evidence in view: the one chosen, or the first there is any of. */
    get group() {
        const groups = this.groups;
        return groups.find((group) => group.kind === this.kind) ?? groups[0];
    }

    handleKind(event) {
        this.kind = event.detail.value;
        this.rowPage = 0;
        remember(`${this.recordId}:analysis-docket-kind`, this.kind);
    }

    /** The rows of the kind in view that are on the page in view. */
    get pageRows() {
        return pageOf(this.group?.tiles, this.rowPage, ROWS_PER_PAGE);
    }

    handleRowPage(event) {
        this.rowPage = event.detail.page;
    }

    /** No photo, video or document at all: the tab says so and takes them here, instead of leaving it to be noticed. */
    get noFiles() {
        return this.hasDocket && !this.isRunning && !this.items.some((item) => FILE_KINDS.includes(item.kind));
    }

    get missingLine() {
        return this.hasReport
            ? "This report rests on the file notes and the insured's statement alone."
            : "Claude will have only the file notes and the insured's statement to go on.";
    }

    /** Closed until "Add evidence" is pressed, on every claim: open at rest it pushed the report a screen down. */
    get addOpen() {
        return !this.isRunning && Boolean(this.addToggled);
    }

    get addPressed() {
        return this.addOpen ? 'true' : 'false';
    }

    handleToggleAdd() {
        this.addToggled = !this.addOpen;
    }

    /** What was just added joins the docket as not yet looked at, and the docket opens on it so it is seen to arrive. */
    async showAdded(kind) {
        await this.load();
        this.docketToggled = true;
        this.kind = this.groups.some((group) => group.kind === kind) ? kind : this.groups[0]?.kind;
        this.rowPage = 0;
        // The other cards on the page (Documents, File Notes) read the same claim.
        this.dispatchEvent(new RefreshEvent());
    }

    async handleUploadFinished(event) {
        const count = event.detail.files.length;
        this.dispatchEvent(new ShowToastEvent({ title: count === 1 ? 'File added to the claim' : `${count} files added to the claim`, variant: 'success' }));
        await this.showAdded(GROUPS[0].kind);
    }

    handleNoteInput(event) {
        this.noteDraft = event.target.value;
        this.noteError = undefined;
    }

    handleNoteType(event) {
        this.noteType = event.detail.value;
    }

    get noteDisabled() {
        return this.isSavingNote || !this.noteDraft.trim();
    }

    async handleSaveNote() {
        this.isSavingNote = true;
        try {
            await addNote({ recordId: this.recordId, noteType: this.noteType, body: this.noteDraft });
            this.noteDraft = '';
            if (this.refs.note) {
                this.refs.note.value = '';
            }
            this.dispatchEvent(new ShowToastEvent({ title: 'File note added to the claim', variant: 'success' }));
            await this.showAdded('note');
        } catch (error) {
            this.noteError = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isSavingNote = false;
        }
    }

    tile(item) {
        const isPhoto = item.kind === 'photo';
        const isFile = Boolean(item.documentId);
        // A note's title already carries its date, so its second line is only who wrote it.
        const meta = [item.author || item.kindLabel, item.sizeLabel, isFile && item.addedAt ? `added ${when(item.addedAt)}` : ''].filter(Boolean).join(', ');
        let status;
        let statusClass = 'c-chip';
        if (item.readable === false) {
            status = 'Cannot be read here';
            statusClass += ' c-chip_quiet';
        } else if (item.looked) {
            status = item.kind === 'video' && item.frames ? `Read from ${item.frames} frames` : isFile ? 'Claude has looked' : 'In the report';
            statusClass += ' c-chip_good';
        } else {
            status = isFile ? 'Not looked at yet' : 'Not in a report yet';
            statusClass += ' c-chip_quiet';
        }
        return {
            ...item,
            isPhoto,
            icon: TILE_ICONS[item.kind],
            meta: keepTogether(meta),
            status,
            statusClass,
            tileStatusClass: `${statusClass} c-tile__status`,
            line: tidyEnding(item.readable === false ? item.whyNot : item.lookedLine),
            canOpen: isFile || Boolean(item.recordId),
            openLabel: `Open ${item.title}`
        };
    }

    get summary() {
        const parts = GROUPS.map((group) => {
            const count = this.items.filter((item) => item.kind === group.kind).length;
            return count ? `${count} ${count === 1 ? group.one : group.many}` : null;
        }).filter(Boolean);
        if (this.items.some((item) => item.kind === 'statement')) {
            parts.push("the insured's statement");
        }
        if (!parts.length) {
            return 'Nothing has been submitted on this claim yet.';
        }
        const last = parts.pop();
        return parts.length ? `${parts.join(', ')} and ${last}` : last;
    }

    get report() {
        return this.docket?.report;
    }

    get docketOpen() {
        return this.docketToggled ?? !this.hasReport;
    }

    get docketToggleLabel() {
        return this.docketOpen ? 'Hide the evidence' : 'Show the evidence';
    }

    get docketToggleIcon() {
        return this.docketOpen ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get docketPressed() {
        return this.docketOpen ? 'true' : 'false';
    }

    handleToggleDocket() {
        this.docketToggled = !this.docketOpen;
    }

    get hasReport() {
        return Boolean(this.report);
    }

    get runLabel() {
        return this.hasReport ? 'Analyze again' : 'Analyze the evidence';
    }

    get runVariant() {
        return this.hasReport && !this.report.stale ? 'neutral' : 'brand';
    }

    get runDisabled() {
        return this.isRunning || this.isLoading;
    }

    /** With a report to read the head is one line; the report says for itself when it is out of date. */
    get headClass() {
        return this.hasReport ? 'c-head c-head_compact' : 'c-head';
    }

    get intro() {
        if (this.hasReport) {
            return undefined;
        }
        return 'Claude looks at every photo and video, reads every document, checks coverage against the policy, and writes one report: the damage, whether it is covered, the reserve, and where to start.';
    }

    handleOpen(event) {
        const item = this.items.find((entry) => entry.key === event.currentTarget.dataset.key);
        if (!item) {
            return;
        }
        if (item.documentId) {
            this[NavigationMixin.Navigate]({ type: 'standard__namedPage', attributes: { pageName: 'filePreview' }, state: { selectedRecordId: item.documentId } });
        } else if (item.recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: item.recordId, actionName: 'view' } });
        }
    }

    // ---------------------------------------------------------------- the run

    get showSteps() {
        return this.steps.length > 0;
    }

    get stepRows() {
        return this.steps.map((step, index) => {
            const isFailed = step.state === 'failed';
            return {
                ...step,
                number: index + 1,
                index,
                className: `c-step c-step_${step.state}`,
                isWorking: step.state === 'working',
                isDone: step.state === 'done' || step.state === 'reused',
                isFailed,
                isSkipped: step.state === 'skipped',
                reused: step.state === 'reused',
                isWaiting: step.state === 'waiting',
                stateWord: STATE_WORDS[step.state],
                line: keepTogether(step.line),
                canSkip: isFailed && step.kind !== 'report',
                // A finished step can be done afresh, which also redoes what follows it; the last step is redone by any of them.
                canRedo: !this.isRunning && (step.state === 'done' || step.state === 'reused') && step.kind !== 'report',
                retryLabel: step.kind === 'photos' && step.resumeAt > 0 ? 'Try the rest again' : 'Try again'
            };
        });
    }

    get stepCount() {
        return this.steps.length;
    }

    /** The run stays open while it works or has stopped part way; finished, it folds to one line. */
    get runOpen() {
        return this.isRunning || this.failedIndex !== undefined;
    }

    get runSummary() {
        const skipped = this.steps.filter((step) => step.state === 'skipped').length;
        const reused = this.steps.filter((step) => step.state === 'reused').length;
        const parts = [skipped ? `${this.steps.length - skipped} finished, ${skipped} skipped` : 'Every step finished'];
        if (reused) {
            parts.push(`${reused} already done and kept`);
        }
        return parts.join(', ');
    }

    get runHeading() {
        if (this.isRunning) {
            return 'Analyzing the evidence';
        }
        return this.failedIndex === undefined ? 'What Claude did' : 'The analysis stopped part way';
    }

    /** The steps of a run, from the docket as it stands: only what there is evidence for. */
    plan() {
        const steps = [];
        const photos = this.items.filter((item) => item.kind === 'photo');
        if (photos.length) {
            steps.push({ id: 'photos', kind: 'photos', label: `Looking at ${photos.length === 1 ? 'the photo' : `the ${photos.length} photos`}`, resumeAt: 0 });
        }
        this.items
            .filter((item) => item.kind === 'video')
            .forEach((item) => steps.push({ id: `video-${item.documentId}`, kind: 'video', label: `Watching ${item.title}`, item }));
        this.items
            .filter((item) => item.kind === 'document' && item.readable !== false)
            .forEach((item) => steps.push({ id: `doc-${item.documentId}`, kind: 'document', label: `Reading ${item.title}`, item }));
        steps.push({ id: 'coverage', kind: 'coverage', label: 'Checking coverage against the policy' });
        steps.push({ id: 'report', kind: 'report', label: 'Writing the report' });
        return steps.map((step) => ({ ...step, state: 'waiting', line: undefined, error: undefined }));
    }

    handleRun() {
        this.steps = this.plan();
        this.failedIndex = undefined;
        this.hasRun = true;
        // A second run looks again at what the first run already has only where something changed.
        this.runFrom(0);
    }

    handleRetry() {
        if (this.failedIndex !== undefined) {
            this.runFrom(this.failedIndex);
        }
    }

    /** Does one finished step afresh, without using what is stored, then everything after it, which depends on it. */
    handleRedo(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (this.isRunning || Number.isNaN(index)) {
            return;
        }
        this.steps = this.steps.map((step, position) => {
            if (position < index) {
                return step;
            }
            return { ...step, state: 'waiting', line: undefined, error: undefined, fresh: position === index || step.kind === 'coverage', resumeAt: 0 };
        });
        this.runFrom(index);
    }

    handleSkip() {
        if (this.failedIndex === undefined) {
            return;
        }
        const index = this.failedIndex;
        this.patch(index, { state: 'skipped', line: 'Skipped. The report will say this was not looked at.', error: undefined });
        this.runFrom(index + 1);
    }

    patch(index, changes) {
        this.steps = this.steps.map((step, position) => (position === index ? { ...step, ...changes } : step));
    }

    async runFrom(start) {
        this.isRunning = true;
        this.failedIndex = undefined;
        for (let index = start; index < this.steps.length; index++) {
            this.patch(index, { state: 'working', error: undefined });
            let outcome;
            try {
                // One step at a time on purpose: each is its own request, and the coverage check and report read what the earlier ones stored.
                // eslint-disable-next-line no-await-in-loop
                outcome = await this.perform(index);
            } catch (error) {
                outcome = { ok: false, error: error?.body?.message ?? error?.message ?? FALLBACK_ERROR };
            }
            if (!outcome.ok) {
                this.patch(index, { state: 'failed', error: outcome.error ?? FALLBACK_ERROR, line: outcome.line });
                this.failedIndex = index;
                this.isRunning = false;
                return;
            }
            this.patch(index, { state: outcome.skipped ? 'skipped' : outcome.reused ? 'reused' : 'done', line: outcome.line });
        }
        this.isRunning = false;
        await this.load();
        // The coverage check and photos cards elsewhere on the page read the same record.
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        this.refs.report?.refresh();
    }

    perform(index) {
        const step = this.steps[index];
        switch (step.kind) {
            case 'photos':
                return this.performPhotos(index);
            case 'video':
                return this.performVideo(index);
            case 'document':
                return readDocumentStep({ caseId: this.recordId, documentId: step.item.documentId, again: step.fresh === true });
            case 'coverage':
                return checkCoverageStep({ caseId: this.recordId, again: step.fresh === true });
            default:
                return writeReportStep({ caseId: this.recordId });
        }
    }

    /** Photos: a fresh assessment on the claim is used as it is; otherwise each batch is its own request. */
    async performPhotos(index) {
        const batches = this.docket.photoBatches ?? [];
        if (!batches.length) {
            return { ok: true, skipped: true, line: 'None of the photos can be assessed here, so they were not looked at.' };
        }
        if (this.docket.photosFresh && !this.steps[index].fresh) {
            return { ok: true, reused: true, line: `Used the assessment already on the claim. ${this.docket.photosLine ?? ''}`.trim() };
        }
        const only = batches.length === 1;
        const total = batches.reduce((sum, batch) => sum + batch.length, 0);
        let done = 0;
        let assessment;
        for (let position = 0; position < batches.length; position++) {
            const resumeAt = this.steps[index].resumeAt ?? 0;
            if (position >= resumeAt) {
                // eslint-disable-next-line no-await-in-loop
                const result = await assessBatch({ caseId: this.recordId, documentIds: batches[position], fresh: position === 0, only });
                if (!result.ok) {
                    return { ok: false, error: result.error, line: done ? `Assessed ${done} of ${total} photos before this stopped.` : undefined };
                }
                assessment = result.assessment;
                this.patch(index, { resumeAt: position + 1 });
            }
            done += batches[position].length;
            if (!only) {
                this.patch(index, { line: `Assessed ${done} of ${total} photos` });
            }
        }
        if (!only) {
            const finished = await finishAssessment({ caseId: this.recordId });
            if (!finished.ok) {
                return { ok: false, error: finished.error, line: `Assessed all ${total} photos. The overall read was not written.` };
            }
            assessment = finished.assessment;
        }
        return { ok: true, line: firstSentence(assessment?.damageSummary) };
    }

    /** A video: frames are taken in the browser, because Claude reads images, not video. */
    async performVideo(index) {
        const item = this.steps[index].item;
        if (item.looked && item.lookedLine && !this.steps[index].fresh) {
            return { ok: true, reused: true, line: `Read from ${item.frames} frames. ${item.lookedLine}` };
        }
        let frames;
        try {
            const data = await videoData({ caseId: this.recordId, documentId: item.documentId });
            const bytes = Uint8Array.from(atob(data), (character) => character.charCodeAt(0));
            // First by decoding the file directly, which works even while this tab is in the background.
            frames = await framesFromMp4(bytes, this.refs.canvas, { count: FRAMES, longEdge: FRAME_LONG_EDGE, quality: FRAME_QUALITY });
            if (!frames) {
                const extension = (item.kindLabel ?? '').split(' ')[0].toLowerCase();
                frames = await this.framesByPlaying(bytes, VIDEO_TYPES[extension] ?? 'video/mp4', index);
            }
        } catch (error) {
            return { ok: false, error: error?.body?.message ?? NO_PLAYBACK };
        }
        if (!frames?.length) {
            return { ok: false, error: NO_PLAYBACK };
        }
        this.patch(index, { line: `Took ${frames.length} frames. Claude is looking at them.` });
        return readVideoStep({ caseId: this.recordId, documentId: item.documentId, frames });
    }

    /** The fallback: plays the video out of sight and draws evenly spaced frames from it. A browser only does this for a tab in view. */
    async framesByPlaying(bytes, type, index) {
        if (document.visibilityState === 'hidden') {
            this.patch(index, { line: 'Waiting for this tab to be in view. The browser only plays a video in a tab you can see.' });
            await new Promise((resolve) => {
                const onChange = () => {
                    if (document.visibilityState !== 'hidden') {
                        document.removeEventListener('visibilitychange', onChange);
                        resolve();
                    }
                };
                document.addEventListener('visibilitychange', onChange);
            });
            this.patch(index, { line: undefined });
        }
        const video = this.refs.video;
        const canvas = this.refs.canvas;
        // A blob address, because the page's content policy allows media from blob: and not from data:.
        const source = URL.createObjectURL(new Blob([bytes], { type }));
        try {
            const loaded = once(video, 'loadeddata');
            video.src = source;
            video.load();
            await loaded;
            const scale = Math.min(1, FRAME_LONG_EDGE / Math.max(video.videoWidth, video.videoHeight, 1));
            canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
            canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
            const context = canvas.getContext('2d');
            const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 0;
            const frames = [];
            for (let position = 0; position < FRAMES; position++) {
                if (duration) {
                    const seeked = once(video, 'seeked');
                    video.currentTime = (duration * (position + 0.5)) / FRAMES;
                    // Frames are taken in order, one seek at a time.
                    // eslint-disable-next-line no-await-in-loop
                    await seeked;
                }
                context.drawImage(video, 0, 0, canvas.width, canvas.height);
                frames.push(canvas.toDataURL('image/jpeg', FRAME_QUALITY).split('base64,')[1]);
                if (!duration) {
                    break;
                }
            }
            return frames;
        } finally {
            video.removeAttribute('src');
            video.load();
            URL.revokeObjectURL(source);
        }
    }

    handleReportChanged() {
        // An action in the report (a reserve change, a file note) changes the claim, so the docket is read again.
        this.load();
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    }
}
