import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { RefreshEvent, registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import LOCALE from '@salesforce/i18n/locale';
import CLAUDE_SPARK from '@salesforce/resourceUrl/claudeSpark';
import NOTE_TYPE from '@salesforce/schema/File_Note__c.Note_Type__c';
import getNotes from '@salesforce/apex/AntsuranceNotesController.getNotes';
import addNote from '@salesforce/apex/AntsuranceNotesController.addNote';
import salesforceNotesOn from '@salesforce/apex/AntsuranceNotesController.salesforceNotesOn';
import getRecordContext from '@salesforce/apex/AntsuranceClaudeController.getRecordContext';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { noteIcon } from 'c/antsuranceIcons';
import { askClaude, withPageContext } from 'c/antsuranceClaudeClient';

// File Note has no record types, so its picklists hang off the master record type.
const MASTER_RECORD_TYPE = '012000000000000AAA';
const MS_PER_DAY = 86400000;
const DEFAULT_TYPE = 'General';
// Chosen as a note's type, this keeps the note in Salesforce's own Notes instead of a file note.
const SALESFORCE_NOTE = 'Salesforce note';
const FALLBACK_ERROR = 'Something went wrong. Try again.';
// Each note type gets its own tint on its chip, so the kind of activity reads at a glance.
const TYPE_TONES = {
    Contact: 'contact',
    Investigation: 'investigation',
    Coverage: 'coverage',
    Reserve: 'money',
    Payment: 'money',
    Underwriting: 'underwriting',
    Service: 'contact'
};

// A note longer than this is shown as its opening lines until it is asked for, so one long note
// (an analysis, a reserve build-up) does not push the rest of the file off the screen.
const LONG_NOTE = 280;
const MOST_LINES = 3;
const EXCERPT = 260;
// Notes shown at a time. With long notes folded, four is about a screen.
const PAGE_SIZE = 4;
const BULLET = /^\s*(?:[-+*]|\d+[.)])\s+/;
// A list item of more words than this is a sentence, and the preview ends it with a stop.
const LONG_ITEM_WORDS = 4;
// A line that is only a rule: three or more dashes, stars or underscores.
const RULE = /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/;

/**
 * The opening of a note as plain words, ending at a whole word. The items of a list run on with commas.
 * It ends at the first rule: what is under one (the letter an approval note carries) is another part
 * of the note, not the rest of its first sentence.
 */
function openingOf(body) {
    let plain = '';
    let lastWasItem = false;
    let lastItemWords = 0;
    const lines = String(body ?? '').split('\n');
    const rule = lines.findIndex((line, index) => index > 0 && RULE.test(line));
    (rule > 0 ? lines.slice(0, rule) : lines)
        .forEach((line) => {
            const isItem = BULLET.test(line);
            const words = line.replace(BULLET, '').replace(/[*_`#>]/g, '').trim();
            if (words) {
                let join = '';
                if (plain) {
                    // A line with no stop at its end is a lead-in ("Status") to the line under it.
                    const needsStop = !/[.:;,!?]$/.test(plain);
                    // Short items run on with commas ("photos, estimate, invoice"). Items that are sentences each end in a stop.
                    const betweenItems = !needsStop ? ' ' : lastItemWords > LONG_ITEM_WORDS ? '. ' : ', ';
                    join = isItem && lastWasItem ? betweenItems : `${needsStop ? ':' : ''} `;
                }
                plain += join + words;
                lastWasItem = isItem;
                lastItemWords = isItem ? words.split(' ').length : 0;
            }
        });
    plain = plain.replace(/\s+/g, ' ');
    if (plain.length <= EXCERPT) {
        return plain;
    }
    const cut = plain.slice(0, EXCERPT);
    return `${cut.slice(0, cut.lastIndexOf(' ')).replace(/[,;:.]$/, '')}...`;
}

// Avatar tints. A person keeps the same one on every note, whatever the note is about.
const AVATAR_TONES = ['sky', 'olive', 'clay', 'amber', 'oat'];

/** A dated timeline of file notes for a claim, service request, policy or customer, with a Markdown composer. */
export default class AntsuranceFileNotes extends NavigationMixin(LightningElement) {
    @api recordId;

    sparkUrl = CLAUDE_SPARK;
    notes;
    notesResult;
    loadError;
    recordContext;
    askedAgain = false;
    fileNoteTypes = [];
    canKeepInNotes = false;

    isComposing = false;
    isDrafting = false;
    isSaving = false;
    draft = '';
    noteType = DEFAULT_TYPE;
    saveError;
    draftingLabel = 'Claude is reading the file';
    /** The long notes the reader has opened, by record id. */
    opened = [];
    bones = [1, 2, 3];
    pageSize = PAGE_SIZE;
    /** The page of notes being shown, counted from 0. */
    page = 0;

    @wire(getNotes, { recordId: '$recordId' })
    wiredNotes(result) {
        this.notesResult = result;
        if (result.data) {
            this.notes = result.data;
            this.loadError = undefined;
            // The first answer can be the browser's kept copy from before a note was added on another tab of
            // this page (the Analysis tab's Add evidence), so it is asked for again, once, as it is shown.
            if (!this.askedAgain) {
                this.askedAgain = true;
                refreshApex(this.notesResult);
            }
        } else if (result.error) {
            this.notes = [];
            this.loadError = result.error.body?.message ?? 'The file notes could not be loaded.';
        }
    }

    @wire(getRecordContext, { recordId: '$recordId' })
    wiredRecordContext({ data }) {
        this.recordContext = data ?? undefined;
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE, fieldApiName: NOTE_TYPE })
    wiredTypes({ data }) {
        if (data) {
            this.fileNoteTypes = data.values.map(({ label, value }) => ({ label, value }));
        }
    }

    @wire(salesforceNotesOn)
    wiredNotesOn({ data }) {
        this.canKeepInNotes = data === true;
    }

    /** The file note types, and where the org has Notes turned on, the choice to keep the note there instead. */
    get typeOptions() {
        return this.canKeepInNotes ? [...this.fileNoteTypes, { label: 'Salesforce note', value: SALESFORCE_NOTE }] : this.fileNoteTypes;
    }

    connectedCallback() {
        loadBrandFonts(this);
        // A note or a file added elsewhere on the page (the Analysis tab, Salesforce's own Notes) asks the page to refresh.
        this.refreshHandler = registerRefreshHandler(this, () => (this.notesResult ? refreshApex(this.notesResult) : Promise.resolve()));
    }

    disconnectedCallback() {
        unregisterRefreshHandler(this.refreshHandler);
    }

    get isLoaded() {
        return this.notes !== undefined;
    }

    get hasNotes() {
        return this.notes?.length > 0;
    }

    /** The empty state steps aside while the first note is being written. */
    get showsEmpty() {
        return !this.isComposing && !this.loadError;
    }

    get countLabel() {
        if (!this.isLoaded) {
            return 'Loading';
        }
        const count = this.notes.length;
        return count === 1 ? '1 note, newest first' : `${count} notes, newest first`;
    }

    get isBusy() {
        return this.isDrafting || this.isSaving;
    }

    get hasDraft() {
        return this.draft.trim().length > 0;
    }

    get isSaveDisabled() {
        return this.isBusy || !this.hasDraft;
    }

    get timeline() {
        const today = new Date().setHours(0, 0, 0, 0);
        const dateFormat = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'short', year: 'numeric' });
        return this.notes.map((note) => {
            // Authors are stored as "Name, Role".
            const [authorName, ...role] = (note.author ?? 'Unknown').split(',');
            const written = new Date(note.noteDate);
            const days = Math.round((today - new Date(written).setHours(0, 0, 0, 0)) / MS_PER_DAY);
            let ago = `${days} days ago`;
            if (days <= 0) {
                ago = 'Today';
            } else if (days === 1) {
                ago = 'Yesterday';
            }
            const tone = TYPE_TONES[note.noteType] ?? 'general';
            const body = note.body ?? '';
            const isLong = body.length > LONG_NOTE || body.trim().split('\n').filter((line) => line.trim()).length > MOST_LINES;
            const isOpen = this.opened.includes(note.recordId);
            const person = authorName.trim();
            const avatar = AVATAR_TONES[[...person].reduce((sum, letter) => sum + letter.charCodeAt(0), 0) % AVATAR_TONES.length];
            // A note saved from Claude's analysis says so, and says who chose to keep it.
            const byClaude = Boolean(note.byClaude);
            const claudeRole = note.savedBy ? `analysis, kept by ${note.savedBy}` : 'analysis';
            return {
                ...note,
                byClaude,
                authorName: authorName.trim(),
                authorRole: byClaude ? claudeRole : role.join(',').trim(),
                initials: authorName
                    .trim()
                    .split(/\s+/)
                    .map((word) => word.charAt(0).toUpperCase())
                    .slice(0, 2)
                    .join(''),
                when: `${ago}, ${dateFormat.format(written)}`,
                markerClass: byClaude ? 'c-note__marker c-note__marker_claude' : `c-note__marker c-note__marker_${avatar}`,
                typeClass: `c-note__type c-note__type_${tone}`,
                typeIcon: noteIcon(note.noteType).name,
                isLong,
                isOpen,
                isFolded: isLong && !isOpen,
                excerpt: isLong ? openingOf(note.body) : undefined,
                foldLabel: isOpen ? 'Show less' : 'Read the whole note',
                caseUrl: note.caseId ? `/lightning/r/Case/${note.caseId}/view` : undefined,
                // A note kept in Salesforce's own Notes opens there.
                documentUrl: note.documentId ? `/lightning/r/ContentDocument/${note.documentId}/view` : undefined
            };
        });
    }

    /** The notes on the page being shown. */
    get pageNotes() {
        const page = Math.min(this.page, Math.max(0, Math.ceil(this.notes.length / PAGE_SIZE) - 1));
        return this.timeline.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    }

    get noteCount() {
        return this.notes?.length ?? 0;
    }

    handlePage(event) {
        this.page = event.detail.page;
    }

    /** Opens a long note in full, or folds it back to its opening lines. */
    handleFold(event) {
        const { recordId } = event.currentTarget.dataset;
        this.opened = this.opened.includes(recordId) ? this.opened.filter((id) => id !== recordId) : [...this.opened, recordId];
    }

    handleNew() {
        this.isComposing = true;
        this.saveError = undefined;
    }

    handleCancel() {
        this.isComposing = false;
        this.isDrafting = false;
        this.draft = '';
        this.noteType = DEFAULT_TYPE;
        this.saveError = undefined;
    }

    handleTypeChange(event) {
        this.noteType = event.detail.value;
    }

    handleBodyInput(event) {
        this.draft = event.target.value;
    }

    /** Asks Claude to read the file and write a first draft, which the user can edit before saving. */
    async handleDraft() {
        const thing = this.recordContext?.objectLabel.toLowerCase() ?? 'record';
        const prompt =
            `Draft a file note for this ${thing}, dated today, for whoever picks the file up next. ` +
            'Say where it stands, what has been done, what is outstanding and the next step. ' +
            'Read the existing file notes first: File_Note__c records whose Case__c, Policy__c or Account__c is this record ' +
            '(Body__c, Note_Date__c, Note_Type__c, Author_Name__c). ' +
            'Write 60 to 110 words of Markdown using short bold lead-ins. ' +
            'Reply with the note text only: no greeting, no heading, no record links and no closing line.';
        this.isComposing = true;
        this.isDrafting = true;
        this.saveError = undefined;
        this.draftingLabel = 'Claude is reading the file';
        try {
            const answer = await askClaude({
                messages: [{ role: 'user', content: withPageContext(this.recordContext, prompt) }],
                onProgress: () => {
                    this.draftingLabel = 'Claude is writing the note';
                }
            });
            this.draft = answer.text ?? '';
        } catch (error) {
            this.saveError = error?.body?.message ?? error?.message ?? FALLBACK_ERROR;
        } finally {
            this.isDrafting = false;
        }
    }

    renderedCallback() {
        // The textarea is not bound to the draft, so a draft from Claude is written into it once it renders.
        const body = this.refs.body;
        if (body && body.value !== this.draft) {
            body.value = this.draft;
        }
    }

    async handleSave() {
        this.isSaving = true;
        this.saveError = undefined;
        try {
            await addNote({ recordId: this.recordId, noteType: this.noteType, body: this.draft });
            await refreshApex(this.notesResult);
            // The page's other cards read the same file: the evidence on the Analysis tab, for one.
            this.dispatchEvent(new RefreshEvent());
            // The new note is the newest, so it is on the first page.
            this.page = 0;
            this.handleCancel();
        } catch (error) {
            this.saveError = error?.body?.message ?? FALLBACK_ERROR;
        } finally {
            this.isSaving = false;
        }
    }

    handleOpenDocument(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__namedPage', attributes: { pageName: 'filePreview' }, state: { selectedRecordId: event.currentTarget.dataset.recordId } });
    }

    handleOpenCase(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, objectApiName: 'Case', actionName: 'view' }
        });
    }
}
