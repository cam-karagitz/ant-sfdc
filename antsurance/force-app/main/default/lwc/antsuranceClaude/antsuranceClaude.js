import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { RefreshEvent } from 'lightning/refresh';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';
import USER_NAME from '@salesforce/schema/User.Name';
import USER_FIRST_NAME from '@salesforce/schema/User.FirstName';
import USER_PHOTO from '@salesforce/schema/User.SmallPhotoUrl';
import LOCALE from '@salesforce/i18n/locale';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';
import getModels from '@salesforce/apex/AntsuranceClaudeController.getModels';
import getWords from '@salesforce/apex/AntsuranceClaudeController.getWords';
import getRecordContext from '@salesforce/apex/AntsuranceClaudeController.getRecordContext';
import getRecordFiles from '@salesforce/apex/AntsuranceClaudeController.getRecordFiles';
import getRecordFile from '@salesforce/apex/AntsuranceClaudeController.getRecordFile';
import confirmAction from '@salesforce/apex/AntsuranceClaudeActions.confirm';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { askClaude, withAppNotes, withPageContext, withToolOutcome, withUserMessage } from 'c/antsuranceClaudeClient';
import BlockModal from 'c/antsuranceClaudeBlockModal';
import FileViewer from 'c/antsuranceClaudeFileViewer';
import { ACCEPT, LIMITS, forViewing, prepareFile, prepareRecordFile, sizeLabel, summarize, toReference } from './attachments';

// The utility bar panel has room for four starting points.
const PANEL_SUGGESTIONS = 4;
// The two starting points the chat words itself from the open record; the rest come with their question.
const STARTER = { SUMMARIZE: 'summarize', NEXT_STEP: 'next_step' };
// Where the chat is, for Apex to tell Claude how much room it has to draw.
const SURFACE = { PANEL: 'panel', PAGE: 'page' };
// Each block Claude can draw, and the flag the template uses to pick its component.
const BLOCK_FLAGS = {
    record: 'isRecord',
    metrics: 'isMetrics',
    chart: 'isChart',
    work_list: 'isWorkList',
    form: 'isForm',
    draft: 'isDraft',
    comparison: 'isComparison',
    timeline: 'isTimeline'
};
const NEXT_QUESTIONS = 'next_questions';
// What a block is called over the page when it has no title of its own.
const BLOCK_NAMES = { metrics: 'Figures', draft: 'Draft', chart: 'Chart', work_list: 'List', form: 'Form', comparison: 'Comparison', timeline: 'Timeline', record: 'Record' };
// Blocks rise into place one after another.
const REVEAL_STEP_MS = 90;
const FALLBACK_ERROR = 'Something went wrong talking to Claude. Try again.';
const FILE_ERROR = 'That file could not be attached. Try again.';
const TOO_MANY_FILES = `A message can carry up to ${LIMITS.files} files. Remove one to add another.`;
// What is asked when files are sent with nothing typed.
const ASK_ABOUT_ONE = 'What does this show?';
const ASK_ABOUT_SEVERAL = 'What do these show?';
// A sent message shows its files as one strip: this many small pictures, then what they are.
const STRIP_TILES = 3;
const CONFIRM_ERROR = 'That could not be saved. Try again.';
// How each kind of proposal card looks. A card is a change Claude prepared; nothing is saved until Confirm.
const ACTION_ICONS = { task: 'utility:task', file_note: 'utility:note', case_status: 'utility:record_update' };
const ACTION_STATE = { PENDING: 'pending', SAVING: 'saving', DONE: 'done', CANCELLED: 'cancelled' };
// Photo URLs for users who have not uploaded a picture contain this path.
const DEFAULT_PHOTO_PATH = '/profilephoto/005/';
// Remembers the model picked in the menu for this browser.
const MODEL_STORAGE_KEY = 'antsurance.claude.model';
// Space left above the latest question when the log scrolls to it.
const QUESTION_MARGIN_PX = 16;
// In the panel an answer scrolls to the top, with this much left above it.
const PANEL_ANSWER_MARGIN_PX = 8;
// How long the view keeps following an answer whose blocks are still growing. A record form can
// take ten seconds to load its fields; the hold ends at once when the user scrolls, clicks or types.
const SCROLL_HOLD_MS = 15000;
const SCROLL_HOLD_STEP_MS = 250;
// How long a record form takes to paint its fields after it reports it has loaded.
const FORM_SETTLE_MS = 400;
// The composer grows with its text up to this height, then scrolls.
const MAX_INPUT_HEIGHT_PX = 160;

function readStoredModel() {
    try {
        return window.localStorage.getItem(MODEL_STORAGE_KEY);
    } catch (error) {
        return null;
    }
}

// What an object is called while Claude reads it, when the org's words do not name it. The API name is never shown.
const plainWordFor = (objectName) => `${objectName.replace(/__c$/i, '').replace(/_/g, ' ').toLowerCase()} records`;
// A follow-up that starts a change, as opposed to one that only reads, by how it begins.
const STARTS_A_CHANGE =
    /^(add|approve|assign|bind|book|cancel|change|close|create|deny|draft|edit|email|escalate|file|flag|issue|log|lower|make|mark|move|note|open a form|postpone|prepare|propose|push|put|raise|reassign|record|remind|renew|reopen|reschedule|schedule|send|set|start|update|write)\b/i;

const recordUrl = (recordId) => `/lightning/r/${recordId}/view`;

/** A proposal from Apex as the card that shows it, in the given state. */
function toCard(proposal, state = ACTION_STATE.PENDING, extra = {}) {
    const isPending = state === ACTION_STATE.PENDING || state === ACTION_STATE.SAVING;
    const isDone = state === ACTION_STATE.DONE;
    const isCancelled = state === ACTION_STATE.CANCELLED;
    return {
        ...proposal,
        ...extra,
        state,
        isPending,
        isSaving: state === ACTION_STATE.SAVING,
        isDone,
        isCancelled,
        iconName: isDone ? 'utility:success' : ACTION_ICONS[proposal.kind],
        statusLabel: isDone ? 'Saved' : isCancelled ? 'Canceled' : 'Needs your OK',
        cardClass: `c-action c-action_${state}`,
        hasBody: Boolean(proposal.body),
        details: proposal.details.map((detail, index) => ({
            ...detail,
            key: `${proposal.id}-detail-${index}`,
            url: detail.recordId ? recordUrl(detail.recordId) : undefined
        })),
        resultUrl: extra.resultRecordId ? recordUrl(extra.resultRecordId) : undefined
    };
}

/** The objects a set of SOQL statements read, for example ['Case', 'Opportunity']. */
function objectsQueried(queries) {
    const objects = queries.map((soql) => {
        // Drop subqueries so the outer FROM is the one that matches.
        const outer = soql.replace(/\([^()]*\)/g, '');
        return outer.match(/\bfrom\s+(\w+)/i)?.[1];
    });
    return [...new Set(objects.filter(Boolean))];
}

export default class AntsuranceClaude extends NavigationMixin(LightningElement) {
    /** The record on screen, when there is one. Set automatically on record pages. */
    @api recordId;
    /** Tighter layout without the header band, for the utility bar panel. */
    @api compact = false;

    nextScrolled = false;
    nextEnded = false;

    sparkUrl = CLAUDE_SPARK;
    // The open record's object and name, shown in the composer and passed to Claude.
    recordContext;

    // What is shown in the panel.
    turns = [];
    draft = '';
    errorMessage;
    isSending = false;

    // What is sent to the API. Turns that came back from Apex (tool calls, tool results,
    // answers) are kept exactly as returned so each request replays the conversation unchanged.
    apiMessages = [];
    // What the user did with proposal cards since their last message, told to Claude with the next one.
    appNotes = [];
    // Objects Claude has read so far while an answer is in flight.
    progress = [];
    nextTurnId = 0;
    shouldScroll = false;

    // Photos and PDFs waiting in the composer to go with the next message.
    pending = [];
    // How many files are being read or redrawn right now.
    preparing = 0;
    // Files on the open record that could be attached without uploading.
    recordFiles = [];
    isDragging = false;
    dragDepth = 0;
    // The files of the latest message that carried any. They travel with every question until a
    // message brings new ones; earlier files are told to Claude by name only. Kept in memory, never stored.
    liveFiles = [];
    acceptedTypes = ACCEPT;

    // Model choices come from Apex so the list lives in one place.
    models = [];
    model;

    @wire(getRecord, { recordId: USER_ID, fields: [USER_NAME, USER_FIRST_NAME, USER_PHOTO] })
    user;

    @wire(getModels)
    wiredModels({ data, error }) {
        if (data) {
            this.models = data;
            const remembered = readStoredModel();
            this.model =
                this.model ??
                data.find((option) => option.value === remembered)?.value ??
                data.find((option) => option.isDefault)?.value;
        }
        // A question handed over before the models were known goes out now, under the right model's name.
        if ((data || error) && this.queuedPrompt) {
            const prompt = this.queuedPrompt;
            this.queuedPrompt = undefined;
            this.send(prompt);
        }
    }
    queuedPrompt;

    // The starting points and the words for objects. They depend on what the org holds, so they come from Apex
    // (AntsuranceClaudeModel); until they arrive the chat offers none.
    words;

    @wire(getWords)
    wiredWords({ data }) {
        if (data) {
            this.words = data;
        }
    }

    @wire(getRecordContext, { recordId: '$recordId' })
    wiredRecordContext({ data, error }) {
        // No record, no access, or a failed lookup all mean chatting without page context.
        this.recordContext = error ? undefined : (data ?? undefined);
        this.loadRecordFiles();
    }

    /** The open record's photos and PDFs, for "Use this record's files". Read again each time the menu opens. */
    async loadRecordFiles() {
        const recordId = this.recordContext?.recordId;
        if (!recordId) {
            this.recordFiles = [];
            return;
        }
        try {
            const files = await getRecordFiles({ recordId });
            if (recordId === this.recordContext?.recordId) {
                this.recordFiles = files;
            }
        } catch (error) {
            this.recordFiles = [];
        }
    }

    connectedCallback() {
        loadBrandFonts(this);
    }

    get chatClass() {
        // Once there is a conversation the header slims and the helper line goes, so an answer card fits.
        const started = this.isEmpty ? '' : ' c-chat_started';
        return `${this.compact ? 'c-chat c-chat_compact' : 'c-chat'}${started}`;
    }

    /** In the panel the composer is one line until it is in use, so the conversation gets the height. */
    get composerClass() {
        return this.draft || this.hasPending || this.preparing ? 'c-composer c-composer_filled' : 'c-composer';
    }

    get hasPending() {
        return this.pending.length > 0;
    }

    get isPreparing() {
        return this.preparing > 0;
    }

    get showFiles() {
        return this.hasPending || this.isPreparing;
    }

    get hasRecordFiles() {
        return this.recordFiles.length > 0;
    }

    get recordFilesLabel() {
        return `Use this ${this.recordContext?.objectLabel.toLowerCase() ?? 'record'}'s files`;
    }

    /** The open record's files as menu items; one already attached, or too large to send, cannot be picked. */
    get recordFileOptions() {
        return this.recordFiles.map((file) => {
            const attached = this.pending.some((item) => item.documentId === file.documentId);
            // The name alone, so it stays on one line; a word after it only when the file cannot be picked.
            const note = attached ? 'attached' : file.whyNot?.toLowerCase();
            return {
                value: file.documentId,
                label: note ? `${file.name} (${note})` : file.name,
                icon: file.kind === 'pdf' ? 'utility:pdf_ext' : 'utility:image',
                disabled: attached || Boolean(file.whyNot)
            };
        });
    }

    get dropClass() {
        return this.isDragging ? 'c-drop c-drop_on' : 'c-drop';
    }

    get attachTitle() {
        return 'Attach photos or PDFs. You can also paste them or drop them here.';
    }

    get isAttachDisabled() {
        return this.isSending;
    }

    get placeholder() {
        return this.compact && this.recordContext ? `Ask about this ${this.recordContext.objectLabel.toLowerCase()}` : (this.words?.placeholder ?? 'Ask a question');
    }

    get hasHeader() {
        return !this.compact;
    }

    /** On the Ask Claude tab, as opposed to the utility bar panel. */
    get isPage() {
        return !this.compact;
    }

    /** The open record's name, shown in the composer so it is clear what "this" means. */
    get contextLabel() {
        return this.recordContext?.name;
    }

    get contextTitle() {
        return this.recordContext ? `Claude can see this ${this.recordContext.objectLabel.toLowerCase()}: ${this.recordContext.name}` : undefined;
    }

    get suggestions() {
        const words = this.words;
        if (!words) {
            return [];
        }
        const context = this.recordContext;
        const thing = context?.objectLabel.toLowerCase();
        let options;
        if (context) {
            // Starting points on a record page, by object. One without a question of its own asks about "this <thing>".
            options = (words.recordStarters[context.objectApiName] ?? words.anyRecordStarters).map((suggestion) => {
                if (suggestion.key === STARTER.SUMMARIZE) {
                    return { ...suggestion, prompt: `Summarize this ${thing}` };
                }
                return suggestion.key === STARTER.NEXT_STEP ? { ...suggestion, prompt: `What should I do next on this ${thing}?` } : suggestion;
            });
        } else {
            options = this.compact ? words.starters.slice(0, PANEL_SUGGESTIONS) : words.starters;
        }
        return options.map((suggestion, index) => ({ ...suggestion, id: `suggestion-${index}` }));
    }

    get surface() {
        return this.compact ? SURFACE.PANEL : SURFACE.PAGE;
    }

    get emptyHint() {
        return this.recordContext
            ? `Ask about this ${this.recordContext.objectLabel.toLowerCase()} or anything else in Salesforce.`
            : 'Ask in plain language. Claude looks up the records and answers.';
    }

    get modelOptions() {
        return this.models.map(({ value, label }) => ({ value, label, checked: value === this.model }));
    }

    get modelLabel() {
        return this.models.find((option) => option.value === this.model)?.label ?? 'Model';
    }

    get userName() {
        return getFieldValue(this.user.data, USER_NAME) ?? 'You';
    }

    get userFirstName() {
        return getFieldValue(this.user.data, USER_FIRST_NAME);
    }

    get userPhotoUrl() {
        return getFieldValue(this.user.data, USER_PHOTO);
    }

    /** False for Salesforce's default gray silhouette, which is replaced by initials. */
    get hasUserPhoto() {
        const url = this.userPhotoUrl;
        return Boolean(url) && !url.includes(DEFAULT_PHOTO_PATH);
    }

    get userInitials() {
        const words = this.userName.split(/\s+/).filter(Boolean);
        const letters = words.length > 1 ? [words[0], words[words.length - 1]] : words;
        return letters.map((word) => word.charAt(0).toUpperCase()).join('');
    }

    get emptyGreeting() {
        return this.userFirstName ? `How can I help, ${this.userFirstName}?` : 'How can I help?';
    }

    get progressLabel() {
        const wordFor = (objectName) => this.words?.objectWords?.[objectName] ?? plainWordFor(objectName);
        return this.progress.length ? `Reading ${[...new Set(this.progress.map(wordFor))].join(', ')}` : undefined;
    }

    get isEmpty() {
        return this.turns.length === 0 && !this.isSending;
    }

    get isSendDisabled() {
        return this.isSending || this.isPreparing || (this.draft.trim().length === 0 && !this.hasPending);
    }

    get isResetDisabled() {
        return this.isSending || this.turns.length === 0;
    }

    renderedCallback() {
        if (this.shouldScroll) {
            this.shouldScroll = false;
            this.scrollToLatest();
            this.holdScroll();
        }
    }

    disconnectedCallback() {
        clearInterval(this.holdTimer);
    }

    scrollToLatest() {
        const log = this.refs.log;
        if (!log) {
            return;
        }
        // Keep the latest question at the top of the view with its answer under it, so a long
        // answer is read from its start. A short answer leaves the log at its end, as before.
        // The panel is short, so there the answer itself goes to the top once it has arrived.
        const rows = log.querySelectorAll('.c-turn');
        const questions = log.querySelectorAll('.c-turn_user');
        const latest = rows[rows.length - 1];
        const answered = this.compact && !this.isSending && latest && !latest.classList.contains('c-turn_user');
        const asked = answered ? latest : questions[questions.length - 1];
        if (asked) {
            const top = asked.getBoundingClientRect().top - log.getBoundingClientRect().top + log.scrollTop;
            log.scrollTop = Math.max(0, top - (answered ? PANEL_ANSWER_MARGIN_PX : QUESTION_MARGIN_PX));
        } else {
            log.scrollTop = log.scrollHeight;
        }
    }

    /**
     * A form or a record card is still loading its fields when it is first drawn, and grows a moment
     * later. For a few seconds the view follows that growth, unless the user starts scrolling. A timer
     * watches the height rather than a ResizeObserver, which does not report while the tab is hidden.
     */
    holdScroll() {
        const log = this.refs.log;
        if (!log) {
            return;
        }
        if (!this.holdListening) {
            this.holdListening = true;
            const release = () => {
                this.holdUntil = 0;
            };
            ['wheel', 'touchmove', 'keydown', 'mousedown'].forEach((type) => log.addEventListener(type, release, { passive: true }));
        }
        this.holdUntil = Date.now() + SCROLL_HOLD_MS;
        this.heldHeight = log.scrollHeight;
        if (!this.holdTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.holdTimer = setInterval(() => {
                if (Date.now() >= this.holdUntil) {
                    clearInterval(this.holdTimer);
                    this.holdTimer = undefined;
                } else if (log.scrollHeight !== this.heldHeight) {
                    this.heldHeight = log.scrollHeight;
                    this.scrollToLatest();
                }
            }, SCROLL_HOLD_STEP_MS);
        }
    }
    holdListening = false;
    holdTimer;
    holdUntil = 0;
    heldHeight = 0;

    handleInput(event) {
        this.draft = event.target.value;
        this.resizeInput();
    }

    handleKeydown(event) {
        if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
            event.preventDefault();
            this.handleSend();
        }
    }

    handleAttach() {
        this.refs.file.click();
    }

    handleFilesPicked(event) {
        const files = [...event.target.files];
        // So the same file can be picked again after it is removed.
        event.target.value = '';
        this.addFiles(files);
    }

    /** A screenshot or a copied file pasted into the question. Pasted text is left alone. */
    handlePaste(event) {
        const files = [...(event.clipboardData?.files ?? [])];
        if (files.length) {
            event.preventDefault();
            this.addFiles(files);
        }
    }

    handleDragEnter(event) {
        if (this.carriesFiles(event)) {
            event.preventDefault();
            this.dragDepth += 1;
            this.isDragging = true;
        }
    }

    handleDragOver(event) {
        if (this.carriesFiles(event)) {
            // Without this the browser opens the file instead of handing it over.
            event.preventDefault();
        }
    }

    handleDragLeave(event) {
        if (this.carriesFiles(event)) {
            this.dragDepth = Math.max(0, this.dragDepth - 1);
            this.isDragging = this.dragDepth > 0;
        }
    }

    handleDrop(event) {
        if (!this.carriesFiles(event)) {
            return;
        }
        event.preventDefault();
        this.dragDepth = 0;
        this.isDragging = false;
        this.addFiles([...event.dataTransfer.files]);
    }

    carriesFiles(event) {
        return !this.isSending && [...(event.dataTransfer?.types ?? [])].includes('Files');
    }

    /** Picks one of the open record's files: it is read from Salesforce and attached like an uploaded one. */
    async handleRecordFile(event) {
        const documentId = event.detail.value;
        const recordId = this.recordContext?.recordId;
        if (!this.hasRoomFor(1)) {
            return;
        }
        this.errorMessage = undefined;
        this.preparing += 1;
        try {
            const file = await getRecordFile({ recordId, documentId });
            this.addPrepared({ ...(await prepareRecordFile(file)), documentId });
        } catch (error) {
            this.errorMessage = error?.body?.message ?? error?.message ?? FILE_ERROR;
        } finally {
            this.preparing -= 1;
        }
        this.refs.input?.focus();
    }

    /** Reads each file, redraws a photo small enough to send, and says in plain words why one was left out. */
    async addFiles(files) {
        if (!files.length || this.isSending) {
            return;
        }
        this.errorMessage = undefined;
        const room = LIMITS.files - this.pending.length - this.preparing;
        const taken = files.slice(0, Math.max(0, room));
        const problems = files.length > taken.length ? [TOO_MANY_FILES] : [];
        this.preparing += taken.length;
        for (const file of taken) {
            try {
                // One at a time: redrawing several phone photos at once is heavy on a small machine.
                // eslint-disable-next-line no-await-in-loop
                const added = this.addPrepared(await prepareFile(file));
                if (!added) {
                    problems.push(this.errorMessage);
                }
            } catch (error) {
                problems.push(error?.message ?? FILE_ERROR);
            } finally {
                this.preparing -= 1;
            }
        }
        this.errorMessage = problems.length ? [...new Set(problems)].join(' ') : undefined;
        this.refs.input?.focus();
    }

    hasRoomFor(count) {
        if (this.pending.length + this.preparing + count > LIMITS.files) {
            this.errorMessage = TOO_MANY_FILES;
            return false;
        }
        return true;
    }

    /** Adds a file that is ready to send, unless it would take the message over its size limit. */
    addPrepared(file) {
        const total = this.pending.reduce((sum, item) => sum + item.bytes, file.bytes);
        if (total > LIMITS.totalBytes) {
            this.errorMessage = `"${file.name}" does not fit: the files on one message can add up to ${sizeLabel(LIMITS.totalBytes)}. Send it in its own message.`;
            return false;
        }
        this.pending = [...this.pending, file];
        return true;
    }

    /** A file in the composer, looked at full size before it is sent. */
    handleViewPending(event) {
        this.openViewer(this.pending.map(forViewing), event.currentTarget.dataset.id);
    }

    /** The files on a sent message, one at a time, over the page. */
    handleViewSent(event) {
        const turn = this.turns.find((candidate) => candidate.id === event.currentTarget.dataset.turn);
        if (turn) {
            this.openViewer(turn.files);
        }
    }

    openViewer(files, startId) {
        FileViewer.open({
            // Photos get room to be looked at; a message with PDFs only is a short list.
            size: files.some((file) => file.isImage) ? 'medium' : 'small',
            label: files.length === 1 ? files[0].displayName : `${files.length} files sent to Claude`,
            files,
            startId
        });
    }

    handleRemoveFile(event) {
        const id = event.currentTarget.dataset.id;
        this.pending = this.pending.filter((file) => file.id !== id);
        this.errorMessage = undefined;
        this.refs.input?.focus();
    }

    handleModelSelect(event) {
        this.model = event.detail.value;
        try {
            window.localStorage.setItem(MODEL_STORAGE_KEY, this.model);
        } catch (error) {
            // Storage can be unavailable; the choice then lasts for this page only.
        }
    }

    /** Where the row of follow-up questions has been scrolled to, so it fades only at an edge with more past it. */
    get nextClass() {
        return `c-next${this.nextScrolled ? ' c-next_scrolled' : ''}${this.nextEnded ? ' c-next_ended' : ''}`;
    }

    handleNextScroll(event) {
        const row = event.currentTarget;
        this.nextScrolled = row.scrollLeft > 2;
        this.nextEnded = row.scrollLeft + row.clientWidth >= row.scrollWidth - 2;
    }

    handleSuggestion(event) {
        this.send(event.currentTarget.dataset.prompt);
    }

    handleSend() {
        this.send(this.draft);
    }

    /** Asks a question as if the user had typed it. The Ask Claude page uses this for its suggested questions. */
    @api
    ask(prompt) {
        return this.send(prompt);
    }

    /**
     * Starts a new chat with a question, as when another page hands one over. The Ask Claude page
     * uses this for a question passed in its address.
     */
    @api
    startWith(prompt) {
        this.handleReset();
        if (this.models.length) {
            return this.send(prompt);
        }
        this.queuedPrompt = prompt;
        return undefined;
    }

    handleReset() {
        this.retry = undefined;
        this.turns = [];
        this.apiMessages = [];
        this.appNotes = [];
        this.pending = [];
        this.liveFiles = [];
        this.errorMessage = undefined;
        this.setDraft('');
    }

    async send(text) {
        const attached = this.pending;
        const typed = text.trim();
        // Files sent with nothing typed still ask something.
        const prompt = typed || (attached.length > 1 ? ASK_ABOUT_SEVERAL : attached.length ? ASK_ABOUT_ONE : '');
        if (!prompt || this.isSending || this.isPreparing) {
            return;
        }
        // A new question replaces the offer to retry one that ran out of time.
        this.clearRetry();
        const notes = this.appNotes;
        const outgoing = withUserMessage(this.apiMessages, withAppNotes(notes, withPageContext(this.recordContext, prompt)), attached.map(toReference));
        const turnsBefore = this.turns;
        const liveBefore = this.liveFiles;

        this.errorMessage = undefined;
        this.setDraft('');
        if (attached.length) {
            // These files now travel with the conversation, in place of any sent before them.
            this.liveFiles = attached.map(({ id, mediaType, data }) => ({ id, mediaType, data }));
            this.pending = [];
        }
        this.addTurn({ author: this.userFirstName ?? 'You', text: prompt, isUser: true, files: attached.map(forViewing) });
        await this.exchange({
            messages: outgoing,
            notes,
            modelLabel: this.modelLabel,
            prompt: typed,
            turnsBefore,
            carried: { queries: [], proposals: [], blocks: [] },
            undo: () => {
                this.pending = attached;
                this.liveFiles = liveBefore;
            }
        });
    }

    /**
     * Sends a conversation to Claude and shows the answer. `carried` is what an earlier attempt at the
     * same question had already gathered before it ran out of time.
     */
    async exchange({ messages, notes, modelLabel, prompt, turnsBefore, carried, undo }) {
        this.isSending = true;
        // The next answer brings its own row of questions, which starts unscrolled.
        this.nextScrolled = false;
        this.nextEnded = false;
        this.progress = objectsQueried(carried.queries);
        try {
            const answer = await askClaude({
                messages,
                model: this.model,
                // The chat can show proposal cards, so Claude gets the open record's facts and may propose changes.
                withActions: true,
                recordId: this.recordContext?.recordId,
                surface: this.surface,
                files: this.liveFiles,
                // Claude asked for records: show what was looked up while it carries on.
                onProgress: (queries) => {
                    this.progress = objectsQueried([...carried.queries, ...queries]);
                    this.shouldScroll = true;
                }
            });
            this.addTurn({
                author: modelLabel,
                text: answer.text,
                queries: [...carried.queries, ...answer.queries],
                proposals: [...carried.proposals, ...answer.proposals],
                blocks: [...carried.blocks, ...answer.blocks]
            });
            if (answer.conversation) {
                this.apiMessages = answer.conversation;
                // Claude has now been told about the cards acted on before this message.
                this.appNotes = this.appNotes.filter((note) => !notes.includes(note));
            }
        } catch (error) {
            if (error?.timedOut) {
                // Salesforce's two-minute limit ran out. The question stays where it is, and the step that
                // did not finish can be sent again from where it stopped.
                this.retry = {
                    messages: error.conversation,
                    notes,
                    modelLabel,
                    prompt,
                    turnsBefore,
                    undo,
                    carried: {
                        queries: [...carried.queries, ...error.queries],
                        proposals: [...carried.proposals, ...error.proposals],
                        blocks: [...carried.blocks, ...error.blocks]
                    }
                };
                this.addTurn({ author: modelLabel, text: error.message, isRetry: true });
            } else {
                // Put the question back, with its files, so it can be edited or resent.
                this.turns = turnsBefore;
                this.setDraft(prompt);
                undo?.();
                this.errorMessage = error?.body?.message ?? error?.message ?? FALLBACK_ERROR;
            }
        } finally {
            this.isSending = false;
            this.progress = [];
            this.shouldScroll = true;
        }
    }

    /** Try again on a step that ran out of time: the same step, with nothing asked twice. */
    handleRetry() {
        const retry = this.retry;
        if (!retry || this.isSending) {
            return;
        }
        this.clearRetry();
        this.exchange(retry);
    }

    clearRetry() {
        if (this.retry) {
            this.retry = undefined;
            this.turns = this.turns.filter((turn) => !turn.isRetry);
        }
    }
    retry;

    /** Confirm on a proposal card: this is the only place the chat writes a record. */
    async handleConfirm(event) {
        const card = this.findCard(event.currentTarget.dataset.id);
        if (!card || card.state !== ACTION_STATE.PENDING) {
            return;
        }
        this.updateCard(card.id, ACTION_STATE.SAVING);
        try {
            const outcome = await confirmAction({ payloadJson: card.payloadJson });
            this.updateCard(card.id, ACTION_STATE.DONE, {
                resultMessage: outcome.message,
                resultRecordId: outcome.recordId,
                resultLinkLabel: outcome.linkLabel
            });
            this.appNotes = [...this.appNotes, `The user pressed Confirm on the "${card.title}" card. ${outcome.message}`];
            // Pages showing the records this touched pick up the change.
            notifyRecordUpdateAvailable(outcome.touchedIds.map((recordId) => ({ recordId })));
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.updateCard(card.id, ACTION_STATE.PENDING, { errorMessage: error?.body?.message ?? CONFIRM_ERROR });
        }
    }

    handleCancel(event) {
        const card = this.findCard(event.currentTarget.dataset.id);
        if (!card || card.state !== ACTION_STATE.PENDING) {
            return;
        }
        this.updateCard(card.id, ACTION_STATE.CANCELLED);
        this.appNotes = [...this.appNotes, `The user pressed Cancel on the "${card.title}" card. Nothing was written.`];
    }

    /**
     * A form Claude drew was saved or cancelled. The form wrote the record itself, as the user;
     * here Claude's record of that tool call is brought up to date and open pages are refreshed.
     */
    handleFormDone(event) {
        const { blockId, outcome, saved, recordId } = event.detail;
        this.apiMessages = withToolOutcome(this.apiMessages, blockId, outcome);
        // The same form may be open twice, small in the panel and full size over the page; both show how it ended.
        this.turns = this.turns.map((turn) =>
            turn.blocks.some((block) => block.id === blockId)
                ? { ...turn, blocks: turn.blocks.map((block) => (block.id === blockId ? { ...block, resolved: { saved: Boolean(saved), recordId } } : block)) }
                : turn
        );
        if (saved) {
            notifyRecordUpdateAvailable([{ recordId }]);
            this.dispatchEvent(new RefreshEvent());
        }
    }

    /** A form finished loading its fields and grew; while the view is following the answer, follow it. */
    handleBlockResize(event) {
        event.stopPropagation();
        if (Date.now() < this.holdUntil) {
            // Once now and once after the fields have painted.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            [0, FORM_SETTLE_MS].forEach((delay) => setTimeout(() => Date.now() < this.holdUntil && this.scrollToLatest(), delay));
        }
    }

    /** Expand on a compact block: the same block, full size, over the page. */
    handleBlockExpand(event) {
        event.stopPropagation();
        const blockId = event.currentTarget.dataset.id;
        const block = this.turns.flatMap((turn) => turn.blocks).find((candidate) => candidate.id === blockId);
        if (!block) {
            return;
        }
        // The modal is as wide as the block needs: most blocks fill the small one, and only a
        // comparison or a row of figures with three or four across asks for more.
        const across = block.kind === 'comparison' ? block.spec.columns?.length : block.kind === 'metrics' ? block.spec.tiles?.length : 0;
        BlockModal.open({
            size: across > 3 ? 'large' : across > 2 ? 'medium' : 'small',
            label: block.spec.title ?? block.spec.name ?? block.spec.subject ?? BLOCK_NAMES[block.kind],
            kind: block.kind,
            spec: block.spec,
            blockId: block.id,
            onformdone: (formEvent) => this.handleFormDone(formEvent)
        });
    }

    /** Opens a record named on a card in the app rather than reloading the page. */
    handleOpenRecord(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }

    findCard(cardId) {
        return this.turns.flatMap((turn) => turn.proposals).find((card) => card.id === cardId);
    }

    updateCard(cardId, state, extra = {}) {
        this.turns = this.turns.map((turn) =>
            turn.proposals.some((card) => card.id === cardId)
                ? { ...turn, proposals: turn.proposals.map((card) => (card.id === cardId ? toCard(card.proposal, state, { proposal: card.proposal, ...extra }) : card)) }
                : turn
        );
    }

    addTurn({ author, text, isUser = false, isRetry = false, queries = [], proposals = [], blocks = [], files = [] }) {
        const time = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(new Date());
        this.nextTurnId += 1;
        const id = `turn-${this.nextTurnId}`;
        const drawn = blocks
            .filter((block) => BLOCK_FLAGS[block.kind])
            .map((block, index) => ({ ...block, [BLOCK_FLAGS[block.kind]]: true, style: `animation-delay: ${index * REVEAL_STEP_MS}ms` }));
        const nextQuestions = blocks
            .filter((block) => block.kind === NEXT_QUESTIONS)
            .flatMap((block) => block.spec.questions)
            .map((question, index) => ({ key: `${id}-next-${index}`, text: question, startsChange: STARTS_A_CHANGE.test(question.trim()) }));
        this.turns = [
            // Follow-up questions belong to the latest answer only.
            ...this.turns.map((turn) => (turn.hasNext ? { ...turn, hasNext: false } : turn)),
            {
                id,
                author,
                text,
                // A step that ran out of time shows its notice and a button in place of an answer.
                isRetry,
                files,
                hasFiles: files.length > 0,
                // Several files are one strip, never a column of pictures: a few small tiles, then what they are.
                fileTiles: files.slice(0, STRIP_TILES),
                filesText: files.length ? summarize(files) : undefined,
                filesMore: files.length > STRIP_TILES ? `+${files.length - STRIP_TILES}` : undefined,
                filesLabel: files.length === 1 ? `View ${files[0].displayName}, sent with this message` : `View the ${files.length} files sent with this message`,
                hasText: Boolean(text) && !isRetry,
                blocks: drawn,
                hasBlocks: drawn.length > 0,
                nextQuestions,
                hasNext: nextQuestions.length > 0,
                proposals: proposals.map((proposal) => toCard(proposal, ACTION_STATE.PENDING, { proposal })),
                hasProposals: proposals.length > 0,
                isUser,
                isClaude: !isUser,
                meta: `${author} • ${time}`,
                rowClass: isUser ? 'c-turn c-turn_user' : 'c-turn',
                hasQueries: queries.length > 0,
                queryLabel: queries.length === 1 ? '1 Salesforce query' : `${queries.length} Salesforce queries`,
                queries: queries.map((soql, index) => ({ id: `${id}-query-${index}`, soql }))
            }
        ];
        this.shouldScroll = true;
    }

    setDraft(value) {
        this.draft = value;
        const input = this.refs.input;
        if (input) {
            input.value = value;
            this.resizeInput();
        }
    }

    resizeInput() {
        const input = this.refs.input;
        input.style.height = 'auto';
        input.style.height = `${Math.min(input.scrollHeight, MAX_INPUT_HEIGHT_PX)}px`;
    }
}
