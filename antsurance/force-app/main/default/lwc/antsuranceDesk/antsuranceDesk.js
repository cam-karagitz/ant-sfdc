import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import LOCALE from '@salesforce/i18n/locale';
import getDesk from '@salesforce/apex/AntsuranceDeskController.getDesk';
import planShift from '@salesforce/apex/AntsuranceDeskController.planShift';
import preparePiece from '@salesforce/apex/AntsuranceDeskController.preparePiece';
import prepareAgain from '@salesforce/apex/AntsuranceDeskController.prepareAgain';
import noteFailure from '@salesforce/apex/AntsuranceDeskController.noteFailure';
import tryAgain from '@salesforce/apex/AntsuranceDeskController.tryAgain';
import discard from '@salesforce/apex/AntsuranceDeskController.discard';
import approve from '@salesforce/apex/AntsuranceDeskController.approve';
import dismiss from '@salesforce/apex/AntsuranceDeskController.dismiss';
import AutonomyPanel from 'c/antsuranceDeskAutonomy';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { keepTogether } from 'c/antsuranceText';
import { pageOf } from 'c/antsuranceUiMemory';
import { clockTime, count, fullDate, money, plural, shortDate } from 'c/antsuranceCockpitFormat';

const EMAIL_STYLE = "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.5; color: #141413;";
// Two pieces are prepared at a time: each is a call to Claude of ten to twenty seconds.
const PIECES_SHOWN = 6;
const LANES = 2;
const LANE_STAGGER_MS = 400;
// What to say when Salesforce ended the request itself, so no reason came back from Claude's client.
const CUT_OFF = "Salesforce ended the request before Claude answered; it allows two minutes for one request. Try this piece again.";

/** What each kind of work looks like on the desk, and what approving it does. */
const KINDS = {
    brief: { icon: 'utility:note', tile: 'c-tile c-tile_brief', approveLabel: 'Store on the claim', openLabel: 'Open claim', noun: 'claim', canEdit: false },
    memo: { icon: 'utility:contract', tile: 'c-tile c-tile_memo', approveLabel: 'Store on the quote', openLabel: 'Review quote', noun: 'quote', canEdit: false },
    outreach: { icon: 'utility:email', tile: 'c-tile c-tile_outreach', approveLabel: 'Open as email', openLabel: 'Open policy', noun: 'policy', canEdit: true },
    reserve: { icon: 'utility:moneybag', tile: 'c-tile c-tile_reserve', approveLabel: 'Change the reserve', openLabel: 'Open claim', noun: 'claim', canEdit: true },
    followup: { icon: 'utility:reminder', tile: 'c-tile c-tile_followup', approveLabel: 'Add the task', openLabel: 'Open sale', noun: 'sale', canEdit: true }
};

const STATUS_CHIPS = {
    Waiting: { label: 'Waiting for you', className: 'c-chip c-chip_watch' },
    'Done by Claude': { label: 'Done by Claude', className: 'c-chip c-chip_good' },
    Approved: { label: 'Approved', className: 'c-chip c-chip_good' },
    Dismissed: { label: 'Dismissed', className: 'c-chip' },
    'Could not be prepared': { label: 'Could not be prepared', className: 'c-chip c-chip_alert' },
    Replaced: { label: 'Replaced', className: 'c-chip' }
};

const RISK_CHIPS = { Low: 'c-chip c-chip_good', Medium: 'c-chip c-chip_watch', High: 'c-chip c-chip_alert' };

/** Turns text into HTML-safe text, so a draft can go into the email composer's rich body as written. */
function escapeHtml(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function paragraphsOf(text, prefix) {
    return (text ?? '')
        .split(/\n\s*\n/)
        .map((paragraph, index) => ({ key: `${prefix}-${index}`, text: paragraph.trim() }))
        .filter((paragraph) => paragraph.text);
}

function sameDay(left, right) {
    return left.getFullYear() === right.getFullYear() && left.getMonth() === right.getMonth() && left.getDate() === right.getDate();
}

/**
 * Claude's desk: the work Claude prepared on its own. What needs a person waits here to be
 * approved, edited or dismissed; what Claude was allowed to do alone is listed as done. A shift is
 * run from here, one piece at a time, so the person sees what Claude is doing while it works.
 */
export default class AntsuranceDesk extends NavigationMixin(LightningElement) {
    desk;
    errorMessage;
    /** "waiting" or "log". */
    view = 'waiting';
    // Drafts Claude replaced with a newer piece stay out of the log until asked for.
    showsReplaced = false;
    // The page each list is on. Six pieces are in view at a time, so the desk stays about one screen tall.
    pages = {};
    /** The open row, by work id. One row is open at a time. */
    openKey;
    /** What the open row is showing under its work: nothing more, the approval's confirm step, the dismiss step, or the edit fields. */
    rowMode = 'view';
    /** What the person changed on a piece before approving it, by work id. */
    editsByPiece = {};
    /** The values in the edit fields while they are open. */
    draft = {};
    dismissReason = '';
    isBusy = false;
    /** The failed piece being tried again, by work id. */
    retryingId;
    /** The shift in progress or just finished. */
    shift;

    connectedCallback() {
        loadBrandFonts(this);
        this.load();
        this.showWaitingView = () => this.showWaitingPieces();
        window.addEventListener('antsurancedeskwaiting', this.showWaitingView);
    }

    disconnectedCallback() {
        window.removeEventListener('antsurancedeskwaiting', this.showWaitingView);
    }

    /** Shows the pieces waiting for the person, whichever view was open. Home's "Open the desk" asks for this. */
    @api
    showWaitingPieces() {
        this.view = 'waiting';
    }

    /** Reloads the desk from Salesforce. Home calls this when something else on the page changed a record. */
    @api
    async refresh() {
        // A reload in the middle of a shift would fight the shift's own updates.
        if (!this.isRunning) {
            await this.load();
        }
    }

    async load() {
        try {
            this.desk = await getDesk();
            this.errorMessage = undefined;
        } catch (error) {
            this.errorMessage = error?.body?.message ?? "Claude's desk could not be loaded.";
        }
    }

    get isReady() {
        return Boolean(this.desk);
    }

    get isRunning() {
        return Boolean(this.shift) && !this.shift.finished;
    }

    // ------------------------------------------------------------------ the summary

    get waitingCount() {
        return this.desk?.waiting.length ?? 0;
    }

    get doneAloneCount() {
        return (this.desk?.log ?? []).filter((piece) => piece.status === 'Done by Claude').length;
    }

    get summary() {
        const waiting = this.waitingCount;
        const alone = this.doneAloneCount;
        if (waiting === 0 && (this.desk?.log.length ?? 0) === 0) {
            return 'Claude has not run a shift yet.';
        }
        const waits = waiting === 0 ? 'Nothing waits for you.' : `${plural(waiting, 'piece')} ${waiting === 1 ? 'waits' : 'wait'} for you.`;
        const kept = this.finished.length;
        if (kept === 0) {
            return waits;
        }
        const own = alone === 0 ? '' : `, ${count(alone)} of them done by Claude on its own`;
        return `${waits} The log holds ${plural(kept, 'finished piece')}${own}.`;
    }

    get lastShiftLabel() {
        const last = this.desk?.lastPreparedAt;
        return last ? `Last work prepared ${this.when(last)}.` : 'A shift looks across the book for routine work and prepares up to twelve pieces.';
    }

    /** "today at 5:42 PM" or "Oct 3 at 5:42 PM". */
    when(value) {
        const date = new Date(value);
        const day = sameDay(date, new Date()) ? 'today' : new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' }).format(date);
        return `${day} at ${clockTime(value)}`;
    }

    /** A time on its own, at the end of a row: "5:42 PM" today, "Oct 3, 5:42 PM" before that. */
    stamp(value) {
        const date = new Date(value);
        if (sameDay(date, new Date())) {
            return clockTime(value);
        }
        return `${new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' }).format(date)}, ${clockTime(value)}`;
    }

    // ------------------------------------------------------------------ the two views

    get views() {
        return [
            { key: 'waiting', label: 'Waiting for you', count: count(this.waitingCount) },
            { key: 'log', label: 'The log', count: count(this.finished.length) }
        ].map((view) => {
            const selected = view.key === this.view;
            return { ...view, pressed: selected ? 'true' : 'false', className: selected ? 'c-switch__item c-switch__item_selected' : 'c-switch__item' };
        });
    }

    get showWaiting() {
        return this.view === 'waiting';
    }

    get showLog() {
        return this.view === 'log';
    }

    handleView(event) {
        this.view = event.currentTarget.dataset.key;
        this.closeRow();
    }

    /** Six pieces at a time. One more than that is shown with them: a pager to reach a single row costs more than the row. */
    shownOf(total) {
        return total === PIECES_SHOWN + 1 ? total : PIECES_SHOWN;
    }

    get waitingShown() {
        return this.shownOf((this.desk?.waiting ?? []).length);
    }

    get logShown() {
        return this.shownOf(this.log.length);
    }

    handlePage(event) {
        this.pages = { ...this.pages, [event.currentTarget.dataset.list]: event.detail.page };
        this.closeRow();
    }

    get waiting() {
        return (this.desk?.waiting ?? []).map((piece) => this.decorate(piece, 'waiting'));
    }

    get shownWaiting() {
        return pageOf(this.waiting, this.pages.waiting ?? 0, this.waitingShown);
    }

    get hasWaiting() {
        return this.waitingCount > 0;
    }

    get waitingEmpty() {
        return (this.desk?.log.length ?? 0) === 0
            ? 'Run a shift and Claude will look across the book, prepare the routine work, and queue here whatever needs your approval.'
            : 'Nothing needs you. What Claude did on its own is in the log.';
    }

    // ------------------------------------------------------------------ pieces that could not be prepared

    /** Pieces Claude timed out on or could not be reached for. Each can be tried again on its own. */
    get failed() {
        return (this.desk?.failed ?? []).map((piece) => {
            const kind = KINDS[piece.kindKey] ?? KINDS.brief;
            const retrying = this.retryingId === piece.workId;
            return {
                ...piece,
                key: `failed:${piece.workId}`,
                icon: kind.icon,
                title: keepTogether(piece.title),
                reason: keepTogether(piece.reason),
                whenLabel: this.stamp(piece.preparedAt),
                retryLabel: retrying ? 'Trying again' : 'Try again',
                retrying
            };
        });
    }

    get hasFailed() {
        return (this.desk?.failed.length ?? 0) > 0;
    }

    get failedHeading() {
        const failed = this.desk?.failed.length ?? 0;
        return `${plural(failed, 'piece')} could not be prepared`;
    }

    /** Tries one failed piece again. It is one call to Claude, as it was in the shift. */
    async handleTryAgain(event) {
        const { workId } = event.currentTarget.dataset;
        this.retryingId = workId;
        this.isBusy = true;
        this.errorMessage = undefined;
        try {
            this.desk = await tryAgain({ workId });
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (error) {
            // Salesforce ended the request itself. The piece stays listed, to try once more.
            this.errorMessage = error?.body?.message && !/LimitException|internal server error/i.test(error.body.message) ? error.body.message : CUT_OFF;
        } finally {
            this.retryingId = undefined;
            this.isBusy = false;
        }
    }

    async handleDiscard(event) {
        const { workId } = event.currentTarget.dataset;
        this.isBusy = true;
        this.errorMessage = undefined;
        try {
            this.desk = await discard({ workId });
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'That could not be removed. Refresh the desk.';
        } finally {
            this.isBusy = false;
        }
    }

    /** Everything in the log that is not still waiting, so a piece is never listed twice. */
    get settled() {
        const waiting = new Set((this.desk?.waiting ?? []).map((piece) => piece.workId));
        return (this.desk?.log ?? []).filter((piece) => !waiting.has(piece.workId));
    }

    /**
     * The log holds what is finished: done by Claude, approved or dismissed. A piece Claude later
     * replaced with a newer one is an old draft, so it is folded away until asked for.
     */
    get finished() {
        return this.settled.filter((piece) => piece.status !== 'Replaced');
    }

    get replacedCount() {
        return this.settled.length - this.finished.length;
    }

    get hasReplaced() {
        return this.replacedCount > 0;
    }

    get replacedLabel() {
        return this.showsReplaced ? 'Hide replaced drafts' : `Show ${plural(this.replacedCount, 'replaced draft')}`;
    }

    handleReplaced() {
        this.showsReplaced = !this.showsReplaced;
        this.pages = { ...this.pages, log: 0 };
    }

    get log() {
        return (this.showsReplaced ? this.settled : this.finished).map((piece) => this.decorate(piece, 'log'));
    }

    get shownLog() {
        return pageOf(this.log, this.pages.log ?? 0, this.logShown);
    }

    get hasLog() {
        return this.settled.length > 0;
    }

    // ------------------------------------------------------------------ a piece

    /** Everything the template needs to draw one piece, with the person's edits laid over Claude's work. */
    decorate(piece, list) {
        let stored = {};
        try {
            stored = JSON.parse(piece.work || '{}');
        } catch {
            stored = {};
        }
        const work = { ...stored, ...(this.editsByPiece[piece.workId] ?? {}) };
        const kind = KINDS[piece.kindKey] ?? KINDS.brief;
        const key = `${list}:${piece.workId}`;
        const isOpen = this.openKey === key;
        const isWaiting = piece.status === 'Waiting';
        // A piece that could not be prepared has no work to draw, only its reason.
        const hasWork = piece.status !== 'Could not be prepared';
        const status = STATUS_CHIPS[piece.status] ?? { label: piece.status, className: 'c-chip' };
        const view = {
            ...piece,
            key,
            isOpen,
            expanded: isOpen ? 'true' : 'false',
            className: isOpen ? 'c-piece c-piece_open' : 'c-piece',
            icon: kind.icon,
            tileClass: kind.tile,
            title: keepTogether(piece.title),
            reason: keepTogether(piece.reason),
            recordName: keepTogether(piece.recordName),
            recordUrl: `/lightning/r/${piece.recordObject}/${piece.recordId}/view`,
            openLabel: kind.openLabel,
            whenLabel: this.stamp(piece.preparedAt),
            preparedLabel: this.when(piece.preparedAt),
            statusLabel: status.label,
            statusClass: status.className,
            isWaiting,
            // The log shows the status of every piece; the waiting list only says when a record has moved on.
            showStatus: list === 'log',
            showChanged: isWaiting && piece.changedSince,
            changedText: `The ${kind.noun} has changed since Claude prepared this, so it may be out of date.`,
            isBrief: hasWork && piece.kindKey === 'brief',
            isMemo: hasWork && piece.kindKey === 'memo',
            isOutreach: hasWork && piece.kindKey === 'outreach',
            isReserve: hasWork && piece.kindKey === 'reserve',
            isFollowUp: hasWork && piece.kindKey === 'followup',
            approveLabel: kind.approveLabel,
            canEdit: kind.canEdit,
            canDecide: isWaiting && list === 'waiting',
            outcome: this.outcomeOf(piece)
        };
        if (view.isBrief) {
            view.headline = keepTogether(work.headline);
            view.standing = keepTogether(work.standing);
            view.nextActions = (work.nextActions ?? []).map((text, index) => ({ key: `next-${index}`, text: keepTogether(text) }));
            view.hasNextActions = view.nextActions.length > 0;
            view.confirmText = 'This stores the brief on the claim, in place of any brief there now. Nothing else on the claim changes.';
        } else if (view.isMemo) {
            view.recommendation = work.recommendation;
            view.headline = keepTogether(work.headline);
            view.points = (work.points ?? []).map((point, index) => ({ key: `point-${index}`, label: point.label, detail: keepTogether(point.detail) }));
            view.conditions = (work.conditions ?? []).map((text, index) => ({ key: `condition-${index}`, text: keepTogether(text) }));
            view.hasConditions = view.conditions.length > 0;
            view.confirmText = 'This stores the memo on the quote for the underwriter to read. The underwriter still decides.';
        } else if (view.isOutreach) {
            view.riskLabel = work.risk ? `${work.risk} risk of leaving` : '';
            view.riskClass = RISK_CHIPS[work.risk] ?? 'c-chip';
            view.riskReason = keepTogether(work.riskReason);
            view.toLine = [work.toName, work.toEmail].filter(Boolean).join(', ') || 'No contact on the policy';
            view.subject = work.subject;
            view.paragraphs = paragraphsOf(work.body, 'body').map((paragraph) => ({ ...paragraph, text: keepTogether(paragraph.text) }));
            view.callOpening = keepTogether(work.callOpening);
            view.termsLine = keepTogether(
                [
                    work.currentPremium == null ? null : `${money(work.currentPremium)} now`,
                    work.renewalPremium == null ? null : `${money(work.renewalPremium)} at renewal`,
                    work.expires ? `expires ${fullDate(work.expires)}` : null
                ]
                    .filter(Boolean)
                    .join(', ')
            );
            view.confirmText = `This opens the email to ${work.toName ?? 'the customer'} in the composer on the policy. Nothing is sent until you press Send there.`;
        } else if (view.isReserve) {
            view.oldReserveLabel = money(work.oldReserve);
            view.newReserveLabel = money(work.newReserve);
            view.estimateLabel = money(work.estimate);
            view.paidLabel = money(work.paid);
            view.changeLabel = `Up ${money((work.newReserve ?? 0) - (work.oldReserve ?? 0))}`;
            view.deductibleLabel = work.deductible > 0 ? money(work.deductible) : '';
            // From the claim as it is now while the review waits; a decided one keeps what was true when it was prepared.
            const daysOpen = piece.daysOpen ?? work.daysOpen;
            view.daysOpenLabel = daysOpen > 0 ? `${daysOpen} ${daysOpen === 1 ? 'day' : 'days'}` : '';
            view.factors = (work.factors ?? []).map((factor, index) => ({ key: `factor-${index}`, label: factor.label, detail: keepTogether(factor.detail) }));
            view.hasFactors = view.factors.length > 0;
            view.confirmText = keepTogether(`This changes the reserve on the claim from ${money(work.oldReserve)} to ${money(work.newReserve)}. Nothing is paid.`);
        } else if (view.isFollowUp) {
            view.taskSubject = work.taskSubject;
            view.note = keepTogether(work.note);
            view.dueLabel = work.dueDate ? fullDate(String(work.dueDate).slice(0, 10)) : '';
            view.emailSubject = work.emailSubject;
            view.emailParagraphs = paragraphsOf(work.emailBody, 'email').map((paragraph) => ({ ...paragraph, text: keepTogether(paragraph.text) }));
            view.optionsLine = keepTogether((work.options ?? []).map((option) => `${option.name} at ${money(option.premium)}`).join(', '));
            view.toLine = [work.toName, work.toEmail].filter(Boolean).join(', ');
            view.confirmText = keepTogether(`This adds the task "${work.taskSubject}" to your list, due ${shortDate(String(work.dueDate ?? '').slice(0, 10))}, with the note and the draft email in it. Nothing is sent.`);
        }
        if (isOpen) {
            view.isView = this.rowMode === 'view';
            view.isConfirm = this.rowMode === 'confirm';
            view.isDismiss = this.rowMode === 'dismiss';
            view.isEdit = this.rowMode === 'edit';
        }
        return view;
    }

    /** What happened to a piece, for the log: "Approved by Jordan Avery today at 5:50 PM. Reserve changed from ..." */
    outcomeOf(piece) {
        if (piece.status === 'Waiting') {
            return '';
        }
        const parts = [];
        if (piece.status === 'Could not be prepared') {
            parts.push(`Claude could not prepare this ${this.when(piece.preparedAt)}. ${piece.reason ?? ''} It is under Waiting for you, to try again.`);
        } else if (piece.status === 'Done by Claude') {
            parts.push(`Done by Claude ${this.when(piece.preparedAt)}, under "Does it and tells me".`);
        } else if (piece.decidedAt) {
            parts.push(`${piece.status} by ${piece.decidedBy ?? 'someone'} ${this.when(piece.decidedAt)}.`);
        }
        if (piece.note) {
            parts.push(piece.status === 'Dismissed' ? `Reason: ${piece.note}` : piece.note);
        }
        return keepTogether(parts.join(' '));
    }

    findPiece(workId) {
        return [...(this.desk?.waiting ?? []), ...(this.desk?.log ?? [])].find((piece) => piece.workId === workId);
    }

    workOf(piece) {
        let stored = {};
        try {
            stored = JSON.parse(piece.work || '{}');
        } catch {
            stored = {};
        }
        return { ...stored, ...(this.editsByPiece[piece.workId] ?? {}) };
    }

    // ------------------------------------------------------------------ opening a row and deciding

    closeRow() {
        this.openKey = undefined;
        this.rowMode = 'view';
        this.dismissReason = '';
        this.errorMessage = undefined;
    }

    handleToggle(event) {
        const { key } = event.currentTarget.dataset;
        const opening = this.openKey !== key;
        this.closeRow();
        if (opening) {
            this.openKey = key;
        }
    }

    handleAskApprove() {
        this.rowMode = 'confirm';
        this.errorMessage = undefined;
    }

    handleAskDismiss() {
        this.rowMode = 'dismiss';
        this.dismissReason = '';
        this.errorMessage = undefined;
    }

    handleEdit(event) {
        const piece = this.findPiece(event.currentTarget.dataset.workId);
        const work = this.workOf(piece);
        this.draft = { subject: work.subject, body: work.body, newReserve: work.newReserve, taskSubject: work.taskSubject, note: work.note };
        this.rowMode = 'edit';
        this.errorMessage = undefined;
    }

    handleDraft(event) {
        this.draft = { ...this.draft, [event.target.dataset.field]: event.target.value };
    }

    /** Keeps what the person changed. Nothing is saved to Salesforce until they approve. */
    handleKeepEdits(event) {
        const piece = this.findPiece(event.currentTarget.dataset.workId);
        const fields = { outreach: ['subject', 'body'], reserve: ['newReserve'], followup: ['taskSubject', 'note'] }[piece.kindKey] ?? [];
        const edits = {};
        fields.forEach((field) => {
            const value = this.draft[field];
            if (value !== undefined && value !== null && `${value}`.trim() !== '') {
                edits[field] = field === 'newReserve' ? Number(value) : `${value}`.trim();
            }
        });
        this.editsByPiece = { ...this.editsByPiece, [piece.workId]: edits };
        this.rowMode = 'view';
    }

    handleBack() {
        this.rowMode = 'view';
        this.errorMessage = undefined;
    }

    handleReason(event) {
        this.dismissReason = event.target.value;
    }

    async handleApprove(event) {
        const piece = this.findPiece(event.currentTarget.dataset.workId);
        const work = this.workOf(piece);
        await this.decide(async () => {
            if (piece.kindKey === 'outreach') {
                this.openComposer(piece, work);
            }
            this.desk = await approve({ workId: piece.workId, editsJson: JSON.stringify(this.editsByPiece[piece.workId] ?? {}) });
        });
    }

    async handleDismiss(event) {
        const { workId } = event.currentTarget.dataset;
        await this.decide(async () => {
            this.desk = await dismiss({ workId, reason: this.dismissReason });
        });
    }

    async handleAgain(event) {
        const { workId } = event.currentTarget.dataset;
        await this.decide(async () => {
            this.desk = await prepareAgain({ workId });
            const edits = { ...this.editsByPiece };
            delete edits[workId];
            this.editsByPiece = edits;
        });
    }

    /** Runs one decision, then closes the row and tells Home so its counts and lists follow. */
    async decide(action) {
        this.isBusy = true;
        this.errorMessage = undefined;
        try {
            await action();
            this.closeRow();
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (error) {
            this.errorMessage = error?.body?.message ?? 'That could not be done. Try again.';
        } finally {
            this.isBusy = false;
        }
    }

    /** Opens Salesforce's email composer on the policy with the draft in it. Nothing is sent until the person sends it. */
    openComposer(piece, work) {
        const html = paragraphsOf(work.body, 'mail')
            .map((paragraph) => `<p style="${EMAIL_STYLE} margin: 0 0 12px;">${escapeHtml(paragraph.text).replace(/\n/g, '<br>')}</p>`)
            .join('');
        this[NavigationMixin.Navigate]({
            type: 'standard__quickAction',
            attributes: { apiName: 'Global.SendEmail' },
            state: {
                recordId: piece.recordId,
                defaultFieldValues: encodeDefaultFieldValues({ Subject: work.subject, HtmlBody: html, ToAddress: work.toEmail ?? '' })
            }
        });
    }

    handleOpen(event) {
        // A modified click on a link is left to the browser, so the record can be opened in a new tab.
        if (event.currentTarget.tagName === 'A') {
            if (event.metaKey || event.ctrlKey || event.shiftKey) {
                return;
            }
            event.preventDefault();
        }
        const { recordId, object: objectApiName } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    // ------------------------------------------------------------------ what Claude may do

    async handleAutonomy() {
        const result = await AutonomyPanel.open({ size: 'small', label: 'What Claude may do' });
        if (result === 'saved') {
            await this.load();
            this.dispatchEvent(new CustomEvent('changed'));
        }
    }

    // ------------------------------------------------------------------ the shift

    get runLabel() {
        return this.isRunning ? 'Claude is working' : "Run Claude's shift";
    }

    get shiftSteps() {
        return (this.shift?.steps ?? []).map((step) => {
            const finished = step.done + step.failed >= step.total;
            const started = step.active > 0 || step.done + step.failed > 0;
            let stateClass = 'c-step';
            if (finished) {
                stateClass += ' c-step_done';
            } else if (started) {
                stateClass += ' c-step_active';
            }
            return {
                ...step,
                className: stateClass,
                isDone: finished,
                isActive: started && !finished,
                progress: `${count(step.done + step.failed)} of ${count(step.total)}`
            };
        });
    }

    get shiftBarStyle() {
        const { prepared = 0, failed = 0, total = 0 } = this.shift ?? {};
        return `width: ${total === 0 ? 100 : Math.round(((prepared + failed) / total) * 100)}%`;
    }

    get shiftHeadline() {
        const shift = this.shift;
        if (!shift) {
            return '';
        }
        if (!shift.planned) {
            return 'Claude is looking across the book';
        }
        if (shift.total === 0) {
            return 'Nothing new to prepare';
        }
        if (!shift.finished) {
            return `Claude is preparing ${plural(shift.total, 'piece')}`;
        }
        const failed = shift.failed > 0 ? ` ${plural(shift.failed, 'piece')} could not be prepared: see below to try ${shift.failed === 1 ? 'it' : 'them'} again.` : '';
        return `Shift finished: ${plural(shift.prepared, 'piece')} prepared.${failed}`;
    }

    get shiftDetail() {
        const shift = this.shift;
        if (!shift?.planned) {
            return 'Open claims, renewals in the next 30 days, quotes waiting on an underwriter or on a customer, and reserves below what is payable on their estimates.';
        }
        const parts = [];
        if (shift.total === 0) {
            parts.push('Every claim, renewal and quote that calls for routine work already has it, or is unchanged since Claude last prepared it.');
        } else if (shift.finished) {
            const alone = shift.prepared - shift.waitingAdded;
            const needed = shift.waitingAdded > 0 ? `${count(shift.waitingAdded)} needed your approval and joined the list below.` : 'None of it needed your approval.';
            parts.push(alone > 0 ? `${needed} Claude did ${count(alone)} on its own.` : needed);
        } else {
            parts.push('Each piece is one request to Claude of ten to twenty seconds. A piece that takes too long is set aside to try again, and the shift carries on.');
        }
        if (shift.leftOver) {
            parts.push(shift.leftOver);
        }
        if (shift.switchedOff?.length) {
            parts.push(`Switched off: ${shift.switchedOff.join(', ')}.`);
        }
        return parts.join(' ');
    }

    get shiftFinished() {
        return Boolean(this.shift?.finished);
    }

    handleCloseShift() {
        this.shift = undefined;
    }

    async handleRun() {
        this.errorMessage = undefined;
        this.shift = { planned: false, finished: false, steps: [], total: 0, prepared: 0, failed: 0, waitingAdded: 0 };
        let plan;
        try {
            plan = await planShift();
        } catch (error) {
            this.shift = undefined;
            this.errorMessage = error?.body?.message ?? 'The shift could not be planned.';
            return;
        }
        const steps = plan.steps.map((step) => ({ key: step.kind, label: step.label, total: step.items.length, done: 0, failed: 0, active: 0 }));
        this.shift = { ...this.shift, planned: true, steps, total: plan.pieceCount, leftOver: plan.leftOver, switchedOff: plan.switchedOff, finished: plan.pieceCount === 0 };
        if (plan.pieceCount === 0) {
            return;
        }
        const queue = [];
        plan.steps.forEach((step) => step.items.forEach((item) => queue.push({ kind: step.kind, recordId: item.recordId, name: item.name })));
        const lanes = [];
        for (let lane = 0; lane < Math.min(LANES, queue.length); lane++) {
            lanes.push(this.workLane(queue, lane * LANE_STAGGER_MS));
        }
        await Promise.all(lanes);
        this.shift = { ...this.shift, finished: true };
        await this.load();
        this.view = 'waiting';
        this.dispatchEvent(new CustomEvent('changed'));
    }

    /** One lane of the shift: takes the next piece off the queue until none is left. */
    async workLane(queue, delay) {
        if (delay > 0) {
            // Started a moment apart, so the two lanes' first calls travel separately.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, delay));
        }
        while (queue.length > 0) {
            const next = queue.shift();
            this.bumpStep(next.kind, { active: 1 });
            // eslint-disable-next-line no-await-in-loop
            const outcome = await this.prepareOne(next);
            this.bumpStep(next.kind, { active: -1, done: outcome === 'failed' ? 0 : 1, failed: outcome === 'failed' ? 1 : 0 });
            this.shift = {
                ...this.shift,
                prepared: this.shift.prepared + (outcome === 'failed' ? 0 : 1),
                failed: this.shift.failed + (outcome === 'failed' ? 1 : 0),
                waitingAdded: this.shift.waitingAdded + (outcome === 'waiting' ? 1 : 0)
            };
        }
    }

    /**
     * Prepares one piece: one request, one call to Claude. A piece that fails or times out is kept on
     * the desk as "could not be prepared" with the reason, and the shift moves on to the next.
     */
    async prepareOne(next) {
        try {
            const piece = await preparePiece({ kind: next.kind, recordId: next.recordId, recordName: next.name });
            if (piece.status === 'Could not be prepared') {
                return 'failed';
            }
            return piece.status === 'Waiting' ? 'waiting' : 'done';
        } catch (error) {
            // The request itself ended: Salesforce stopped it, or the connection dropped. Record it so it can be tried again.
            const said = error?.body?.message;
            const reason = said && !/LimitException|internal server error/i.test(said) ? said : CUT_OFF;
            try {
                await noteFailure({ kind: next.kind, recordId: next.recordId, recordName: next.name, reason });
            } catch {
                // The desk could not record it either; the next shift finds the record again.
            }
            return 'failed';
        }
    }

    bumpStep(kind, change) {
        const steps = this.shift.steps.map((step) =>
            step.key === kind ? { ...step, active: step.active + (change.active ?? 0), done: step.done + (change.done ?? 0), failed: step.failed + (change.failed ?? 0) } : step
        );
        this.shift = { ...this.shift, steps };
    }
}
