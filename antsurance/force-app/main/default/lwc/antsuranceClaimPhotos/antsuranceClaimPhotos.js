import { LightningElement, api, wire } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import { refreshApex } from '@salesforce/apex';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import getPhotos from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.getPhotos';
import savePhoto from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.savePhoto';
import assessBatch from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.assessBatch';
import finishAssessment from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.finishAssessment';
import applySuggestion from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.applySuggestion';
import addNote from '@salesforce/apex/AntsuranceClaimsAssistantPhotos.addNote';
import getNotes from '@salesforce/apex/AntsuranceNotesController.getNotes';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether, tidyEnding } from 'c/antsuranceText';

const FALLBACK_ERROR = 'Something went wrong. Try again.';
const ASSESSING_CAPTIONS = ['Looking at each photo', 'Marking the damage', 'Checking it against the reported loss', 'Writing it up'];
const CAPTION_INTERVAL_MS = 2200;
// A photo is redrawn smaller before it is saved: phone photos run to several megabytes, and Claude
// gains nothing past about 1,300 pixels on the long edge.
const LONG_EDGE = 1280;
const TARGET_BYTES = 380000;
const SHRINK_ATTEMPTS = 6;
const BASE64_RATIO = 0.75;
const SEVERITY_RANK = { minor: 1, moderate: 2, severe: 3 };
const VERDICTS = {
    consistent: { label: 'Fits the reported loss', icon: 'utility:success', className: 'c-verdict c-verdict_fits' },
    check: { label: 'Something to check', icon: 'utility:warning', className: 'c-verdict c-verdict_check' },
    unclear: { label: 'Cannot tell from these photos', icon: 'utility:info', className: 'c-verdict' }
};
const NEXT_STEPS = {
    photo_estimate: { label: 'A photo estimate is enough', icon: 'utility:photo' },
    field_appraiser: { label: 'Send a field appraiser', icon: 'utility:checkin' },
    call_insured: { label: 'Call the insured first', icon: 'utility:call' }
};
// What confirming each kind of suggestion does, shown before the handler confirms.
const EFFECTS = {
    set_reserve: (amount) => `This sets the reserve to ${amount} and records why in a file note.`,
    add_task: () => 'This adds a task on the claim, assigned to you and due in two days.'
};

function readAsDataUrl(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('The photo could not be read.'));
        reader.readAsDataURL(file);
    });
}

function loadImage(dataUrl) {
    return new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error('That file is not a photo this browser can open.'));
        image.src = dataUrl;
    });
}

/** Redraws a photo as a JPEG small enough to save and to send to Claude. Returns it base64 encoded. */
async function shrink(file) {
    const source = await loadImage(await readAsDataUrl(file));
    let edge = LONG_EDGE;
    let quality = 0.82;
    let data;
    for (let attempt = 0; attempt < SHRINK_ATTEMPTS; attempt++) {
        const scale = Math.min(1, edge / Math.max(source.naturalWidth, source.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(source.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(source.naturalHeight * scale));
        const context = canvas.getContext('2d');
        // A white ground, so a photo with transparency does not turn black as a JPEG.
        context.fillStyle = '#fff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(source, 0, 0, canvas.width, canvas.height);
        data = canvas.toDataURL('image/jpeg', quality).split(',')[1];
        if (data.length * BASE64_RATIO <= TARGET_BYTES) {
            break;
        }
        // Give up some quality first, then some size.
        if (quality > 0.62) {
            quality -= 0.1;
        } else {
            edge = Math.round(edge * 0.8);
        }
    }
    return data;
}

/**
 * The photographs on a claim and Claude's assessment of them: what is damaged in each and roughly
 * where, whether it fits the reported loss, what else to photograph, a rough repair range and the
 * next step. Suggestions change the claim only when the handler confirms them.
 */
export default class AntsuranceClaimPhotos extends LightningElement {
    @api recordId;

    view;
    errorMessage;
    isAssessing = false;
    // Batches that did not come back, each { ids, message, retryable }, and the same for the last step.
    failures = [];
    finishFailure;
    // True when a new assessment was asked for and none of its batches has landed yet, so the next
    // one to land must replace what is stored rather than add to it.
    startsAfresh = false;
    // While several batches run: how many photos are done, of how many.
    progress;
    captionIndex = 0;
    captionTimer;
    uploading = 0;
    confirming;
    applying;
    applied = [];
    noteAdded = false;
    isAddingNote = false;
    notesResult;
    // Which folding section is open in each tab beside the photos: one at a time.
    openRead = 'shows';
    openNext = 'step';

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
    }

    disconnectedCallback() {
        clearInterval(this.captionTimer);
    }

    // Held only so the file notes card can be refreshed after a note is added from here.
    @wire(getNotes, { recordId: '$recordId' })
    wiredNotes(result) {
        this.notesResult = result;
    }

    async load() {
        try {
            this.view = await getPhotos({ caseId: this.recordId });
            this.errorMessage = undefined;
            // The Documents tab shows this card under a "Photos" tab with its count.
            this.dispatchEvent(new CustomEvent('photoschange', { detail: { count: (this.view?.photos ?? []).length } }));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        }
    }

    /** The tab after the viewer's own, once there is an assessment to act on. */
    get nextTab() {
        return this.isAssessed ? 'What next' : undefined;
    }

    /** Whether each folding section is open. Opening one closes the others in its tab. */
    get folds() {
        const open = {};
        ['shows', 'vehicle', 'signals'].forEach((name) => {
            open[name] = this.openRead === name;
        });
        ['step', 'range', 'suggest', 'needed', 'note'].forEach((name) => {
            open[name] = this.openNext === name;
        });
        return open;
    }

    handleFold(event) {
        const name = event.currentTarget.dataset.name;
        const group = ['shows', 'vehicle', 'signals'].includes(name) ? 'openRead' : 'openNext';
        this[group] = event.detail.open ? name : undefined;
    }

    get noteGist() {
        return this.noteAdded ? 'Added to the file' : 'A note Claude drafted';
    }

    /** A marked area, an answer or a moved box changes the stored assessment, so the read beside the photos is loaded again. */
    handleMarksSaved() {
        return this.load();
    }

    get isLoading() {
        return !this.view && !this.errorMessage;
    }

    get isBusy() {
        return this.isLoading || this.isAssessing || this.uploading > 0 ? 'true' : 'false';
    }

    get photos() {
        return this.view?.photos ?? [];
    }

    get isEmpty() {
        return Boolean(this.view) && this.photos.length === 0;
    }

    get hasPhotos() {
        return this.photos.length > 0;
    }

    get assessable() {
        return this.photos.filter((photo) => photo.assessable).length;
    }

    get cannotAssess() {
        return this.assessable === 0 || this.isAssessing || this.uploading > 0;
    }

    /** The groups of photos that each fit one call to Claude, as the server planned them. */
    get batches() {
        return this.view?.batches ?? [];
    }

    get isComplete() {
        const found = this.view?.assessment;
        return Boolean(found) && found.complete !== false;
    }

    get isAssessed() {
        return this.isComplete && !this.isAssessing;
    }

    /** Part way: some photos are assessed and the overall read is not written yet. */
    get isPartial() {
        return Boolean(this.view?.assessment) && !this.isComplete && !this.isAssessing;
    }

    get isUnassessed() {
        return this.hasPhotos && !this.view?.assessment && !this.isAssessing;
    }

    /** The batches that still hold a photo Claude has not looked at. */
    get pendingBatches() {
        const done = new Set((this.view?.assessment?.photos ?? []).map((read) => read.documentId));
        return this.batches.filter((ids) => ids.some((id) => !done.has(id)));
    }

    get partialLine() {
        const done = this.view?.assessment?.photos?.length ?? 0;
        const total = this.batches.reduce((count, ids) => count + ids.length, 0);
        const left = this.pendingBatches.reduce((count, ids) => count + ids.length, 0);
        if (left === 0) {
            return `All ${done} photos are assessed. The overall read has not been written yet.`;
        }
        return `${done} of ${total} photos are assessed. The overall read is written once the rest are done.`;
    }

    get continueLabel() {
        return this.pendingBatches.length > 0 ? 'Assess the rest' : 'Write the overall read';
    }

    get progressLine() {
        if (!this.progress) {
            return undefined;
        }
        return this.progress.finishing
            ? `All ${this.progress.total} photos assessed. Writing the overall read.`
            : `Assessed ${this.progress.done} of ${this.progress.total} photos`;
    }

    get failureRows() {
        const position = new Map(this.photos.map((photo, index) => [photo.documentId, index + 1]));
        const rows = this.failures.map((failure, index) => {
            const numbers = failure.ids.map((id) => position.get(id)).filter(Boolean);
            const which =
                numbers.length === 1 ? `Photo ${numbers[0]} was` : `Photos ${numbers[0]} to ${numbers[numbers.length - 1]} were`;
            return { key: `failure-${index}`, index, title: `${which} not assessed`, message: failure.message, isFinish: false };
        });
        if (this.finishFailure) {
            rows.push({ key: 'failure-finish', index: -1, title: 'The overall read was not written', message: this.finishFailure.message, isFinish: true });
        }
        return rows;
    }

    get hasFailures() {
        return this.failureRows.length > 0 && !this.isAssessing;
    }

    /** Offered when nothing failed: a failure has its own Try again. */
    get canContinue() {
        return !this.hasFailures;
    }

    get metaLine() {
        const photos = this.photos.filter((photo) => photo.kind === 'image').length;
        const videos = this.photos.length - photos;
        if (this.photos.length === 0) {
            return 'Claude marks the damage and checks it against the reported loss';
        }
        const parts = [`${photos} ${photos === 1 ? 'photo' : 'photos'}`];
        if (videos > 0) {
            parts.push(`${videos} ${videos === 1 ? 'video' : 'videos'}`);
        }
        return `${parts.join(' and ')} on file`;
    }

    get assessLabel() {
        if (this.isAssessing) {
            return 'Assessing';
        }
        return this.view?.assessment ? 'Assess again' : 'Assess the photos with Claude';
    }

    get assessVariant() {
        return this.view?.assessment ? 'neutral' : 'brand';
    }

    get assessingNote() {
        return this.batches.length > 1
            ? 'Claude looks at a few photos at a time with the claim file beside them, then writes the overall read. What is done is kept if a step fails.'
            : 'Claude is looking at the photos with the claim file beside them. This takes about twenty seconds.';
    }

    get addLabel() {
        return this.uploading > 0 ? `Saving ${this.uploading}` : 'Add photos';
    }

    get addClass() {
        return this.uploading > 0 ? 'c-add c-add_busy' : 'c-add';
    }

    get assessingCaption() {
        return ASSESSING_CAPTIONS[this.captionIndex];
    }

    get staleLine() {
        const count = this.view?.addedSince ?? 0;
        if (!this.isComplete || count === 0) {
            return undefined;
        }
        return `${count} ${count === 1 ? 'photo has' : 'photos have'} been added since this assessment.`;
    }

    get money() {
        return (value) => new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, minimumFractionDigits: 0, maximumFractionDigits: 0 }).format(value);
    }

    /** The assessment, shaped for the template. Text shown here is kept from breaking badly; what is saved is as Claude wrote it. */
    get assessment() {
        const found = this.view?.assessment;
        if (!found || found.complete === false) {
            return undefined;
        }
        const money = this.money;
        const verdict = VERDICTS[found.consistency] ?? VERDICTS.unclear;
        const step = NEXT_STEPS[found.nextStep] ?? NEXT_STEPS.field_appraiser;
        const hasRange = found.repairLow !== null && found.repairLow !== undefined && found.repairHigh !== null && found.repairHigh !== undefined;
        const panels = {};
        (found.photos ?? []).forEach((photo) =>
            (photo.damage ?? []).forEach((area) => {
                if (area.panel && area.panel !== 'none' && (SEVERITY_RANK[area.severity] ?? 0) > (SEVERITY_RANK[panels[area.panel]] ?? 0)) {
                    panels[area.panel] = area.severity;
                }
            })
        );
        const signals = [...(found.likelyTotalLoss ? ['Likely total loss'] : []), ...(found.signals ?? [])];
        const needed = found.photosNeeded ?? [];
        const suggestions = found.suggestions ?? [];
        const when = found.assessedAt
            ? new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(found.assessedAt))
            : undefined;
        const leftOut = found.photosLeftOut ?? 0;
        return {
            ...found,
            damageSummary: tidyEnding(found.damageSummary),
            lossSeen: found.lossSeen,
            verdictLabel: verdict.label,
            verdictIcon: verdict.icon,
            verdictClass: verdict.className,
            consistencyNote: tidyEnding(found.consistencyNote),
            panels,
            hasVehicle: Object.keys(panels).length > 0,
            panelCount: Object.keys(panels).length === 1 ? '1 panel' : `${Object.keys(panels).length} panels`,
            signalRows: signals.map((text, index) => ({ text, key: `signal-${index}` })),
            hasSignals: signals.length > 0,
            neededRows: needed.map((text, index) => ({ text: tidyEnding(text), key: `needed-${index}` })),
            hasNeeded: needed.length > 0,
            stepLabel: step.label,
            stepIcon: step.icon,
            nextStepReason: tidyEnding(found.nextStepReason),
            hasRange,
            rangeLabel: hasRange ? (found.repairLow === found.repairHigh ? money(found.repairLow) : `${money(found.repairLow)} to ${money(found.repairHigh)}`) : undefined,
            repairBasis: tidyEnding(found.repairBasis),
            suggestionRows: suggestions.map((suggestion, index) => ({
                ...suggestion,
                title: keepTogether(suggestion.title),
                reason: tidyEnding(suggestion.reason),
                index,
                key: `suggestion-${index}`,
                isConfirming: this.confirming === index,
                isApplying: this.applying === index,
                isDone: this.applied.includes(index),
                applyLabel: suggestion.kind === 'add_task' ? 'Add task' : 'Apply',
                effect: (EFFECTS[suggestion.kind] ?? (() => ''))(suggestion.amount === null || suggestion.amount === undefined ? '' : money(suggestion.amount))
            })),
            hasSuggestions: suggestions.length > 0,
            suggestionCount: suggestions.length === 1 ? '1 thing to do' : `${suggestions.length} things to do`,
            neededCount: needed.length === 1 ? '1 photo' : `${needed.length} photos`,
            hasNote: Boolean(found.note),
            footLine: [
                when ? `Assessed ${when}` : undefined,
                leftOut > 0 ? `Claude looked at the first ${found.photos?.length ?? 0} photos; ${leftOut} more ${leftOut === 1 ? 'was' : 'were'} left out` : undefined
            ]
                .filter(Boolean)
                .join('. ')
        };
    }

    startCaptions() {
        this.captionIndex = 0;
        clearInterval(this.captionTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.captionTimer = setInterval(() => {
            this.captionIndex = Math.min(this.captionIndex + 1, ASSESSING_CAPTIONS.length - 1);
        }, CAPTION_INTERVAL_MS);
    }

    async handleFiles(event) {
        const files = [...event.target.files].filter((file) => file.type.startsWith('image/'));
        // Clearing the input lets the same photo be chosen again after a failure.
        event.target.value = '';
        if (files.length === 0) {
            return;
        }
        this.errorMessage = undefined;
        this.uploading = files.length;
        let saved = 0;
        for (const file of files) {
            try {
                // eslint-disable-next-line no-await-in-loop
                const base64Data = await shrink(file);
                const name = `${file.name.replace(/\.[^.]+$/, '') || 'Photo'}.jpg`;
                // One at a time: each save carries a whole photo.
                // eslint-disable-next-line no-await-in-loop
                await savePhoto({ caseId: this.recordId, fileName: name, base64Data });
                saved++;
            } catch (error) {
                this.errorMessage = error?.body?.message ?? error?.message ?? FALLBACK_ERROR;
            }
            this.uploading--;
        }
        this.uploading = 0;
        if (saved > 0) {
            this.dispatchEvent(new ShowToastEvent({ title: saved === 1 ? 'Photo added' : `${saved} photos added`, variant: 'success' }));
            await this.load();
            this.dispatchEvent(new RefreshEvent());
        }
    }

    handleAssess() {
        // A new assessment replaces the stored one, starting with its first batch.
        return this.run(this.batches, true);
    }

    handleContinue() {
        return this.run(this.pendingBatches, false);
    }

    handleRetry(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (index < 0) {
            return this.run([], false);
        }
        // Only the batch that failed is asked for again.
        return this.run([this.failures[index].ids], false);
    }

    /**
     * Assesses batches one request at a time, so no request holds more than one call to Claude, then
     * has the overall read written. A batch that fails is noted and the rest carry on; what the
     * others found is already saved on the claim.
     */
    async run(batches, fresh) {
        if (this.isAssessing) {
            return;
        }
        this.isAssessing = true;
        this.errorMessage = undefined;
        this.confirming = undefined;
        this.applied = [];
        this.noteAdded = false;
        this.finishFailure = undefined;
        let starting = fresh || this.startsAfresh;
        // One batch that is every photo on the claim is a single call that also writes the overall read.
        const only = starting && batches.length === 1 && this.batches.length === 1;
        const total = this.batches.reduce((count, ids) => count + ids.length, 0);
        const retried = new Set(batches.flat());
        const failures = this.failures.filter((failure) => !failure.ids.some((id) => retried.has(id)) && !fresh);
        this.startCaptions();
        for (const ids of batches) {
            const done = starting ? 0 : (this.view?.assessment?.photos?.length ?? 0);
            this.progress = this.batches.length > 1 ? { done, total, finishing: false } : undefined;
            let step;
            try {
                // One batch at a time, each in its own request: Salesforce allows a request 120 seconds of callouts.
                // eslint-disable-next-line no-await-in-loop
                step = await assessBatch({ caseId: this.recordId, documentIds: ids, fresh: starting, only });
            } catch (error) {
                step = { ok: false, error: error?.body?.message ?? FALLBACK_ERROR, retryable: true };
            }
            if (step.ok) {
                this.view = { ...this.view, assessment: step.assessment, addedSince: 0 };
                starting = false;
            } else {
                failures.push({ ids, message: step.error, retryable: step.retryable });
            }
        }
        this.startsAfresh = starting;
        this.failures = failures;
        const hasReads = (this.view?.assessment?.photos?.length ?? 0) > 0;
        if (!only && failures.length === 0 && hasReads && this.view.assessment.complete === false) {
            this.progress = { done: total, total, finishing: true };
            let step;
            try {
                step = await finishAssessment({ caseId: this.recordId });
            } catch (error) {
                step = { ok: false, error: error?.body?.message ?? FALLBACK_ERROR };
            }
            if (step.ok) {
                this.view = { ...this.view, assessment: step.assessment, addedSince: 0 };
            } else {
                this.finishFailure = { message: step.error };
            }
        }
        clearInterval(this.captionTimer);
        this.progress = undefined;
        this.isAssessing = false;
    }

    handleSuggest(event) {
        this.confirming = Number(event.currentTarget.dataset.index);
    }

    handleCancelSuggestion() {
        this.confirming = undefined;
    }

    async handleConfirmSuggestion(event) {
        const index = Number(event.currentTarget.dataset.index);
        const suggestion = this.view.assessment.suggestions[index];
        this.applying = index;
        this.errorMessage = undefined;
        try {
            const message = await applySuggestion({
                caseId: this.recordId,
                kind: suggestion.kind,
                amount: suggestion.amount,
                title: suggestion.title,
                reason: suggestion.reason
            });
            this.applied = [...this.applied, index];
            this.confirming = undefined;
            this.dispatchEvent(new ShowToastEvent({ title: message, variant: 'success' }));
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            if (this.notesResult) {
                await refreshApex(this.notesResult);
            }
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.applying = undefined;
        }
    }

    async handleAddNote() {
        const found = this.view.assessment;
        this.isAddingNote = true;
        this.errorMessage = undefined;
        try {
            await addNote({ caseId: this.recordId, noteType: found.noteType, body: found.note });
            this.noteAdded = true;
            if (this.notesResult) {
                await refreshApex(this.notesResult);
            }
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.errorMessage = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isAddingNote = false;
        }
    }
}
