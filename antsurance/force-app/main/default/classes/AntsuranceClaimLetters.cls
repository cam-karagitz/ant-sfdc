/**
 * @description Claim letters. Says which letters a claim could use now, has Claude draft one for the
 * adjuster to edit, lays the letter out the way its PDF prints, and saves an approved letter to the claim.
 *
 * Nothing here sends anything to anyone. Claude writes only the salutation and the body: the addressee,
 * the date, the reference lines and the signature come from the record, and the adjuster can change
 * every word before approving.
 *
 * An approved letter is kept twice on the claim: as a file note that carries its full text, written by
 * the person who approved it, and as a PDF made from that note. The note is saved in one request and the
 * PDF in the next, because Salesforce does not render a page in a request that has already saved.
 *
 * One Claude call per request.
 */
public with sharing class AntsuranceClaimLetters {
    public static final String ACKNOWLEDGMENT = 'acknowledgment';
    public static final String RESERVATION = 'reservation';
    public static final String CONFIRMATION = 'confirmation';
    public static final String INFORMATION = 'information';
    public static final String PAYMENT = 'payment';
    public static final String NOTICE = 'notice';

    /** How a letter's file note opens. The PDF is made from the text under it. */
    public static final String NOTE_OPENING = '**Letter approved:**';
    /** What a saved letter's file says about itself, followed by the Id of its note. */
    public static final String FILE_MARK = 'Antsurance letter ';
    private static final String NOTE_RULE = '---';

    // How each part of the letter opens in its file note. A part the letter does not have is left out,
    // and the rest is still read for what it is, never by where it stands. The body opens with its mark
    // and runs to the closing; a paragraph is one line, so nothing the adjuster writes is taken for a part.
    private static final String TO_MARK = '**To:**';
    private static final String DATE_MARK = '**Date:**';
    private static final String REFERENCE_MARK = '**Reference:**';
    private static final String SALUTATION_MARK = '**Salutation:**';
    private static final String BODY_MARK = '**Letter:**';
    private static final String CLOSING_MARK = '**Closing:**';
    private static final String SIGNED_MARK = '**Signed:**';

    /** The widest line of the letter, in characters, at the size the page prints. */
    private static final Integer LINE_CHARS = 98;
    /** A last line shorter than this is pulled up by setting the paragraph a little narrower. */
    private static final Integer SHORT_LAST_LINE = 28;
    private static final Integer MAX_BODY = 6000;
    private static final Integer MAX_LINES = 8;
    private static final Integer MAX_LINE_LENGTH = 80;
    private static final Integer MAX_QUESTIONS = 6;
    private static final Integer MAX_ON_FILE = 30;

    // The printed page, in points, so the preview can say how many pages the letter takes.
    // These match the page's style rules: change one and change the other.
    private static final Decimal PAGE_HEIGHT = 694;
    private static final Decimal HEAD_HEIGHT = 56;
    private static final Decimal ADDRESS_GAP = 20;
    private static final Decimal LINE_HEIGHT = 14;
    private static final Decimal BLOCK_GAP = 14;
    private static final Decimal PARAGRAPH_GAP = 9;
    private static final Decimal SIGNING_GAP = 26;

    private static final String COMPANY = 'Antsurance Insurance Company';
    /** The claims line on the letterhead and on the declarations page. */
    private static final String CLAIMS_LINE = '1-800-555-0199';
    private static final String DEFAULT_TITLE = 'Claims Adjuster';
    private static final String CLOSING = 'Sincerely,';

    @TestVisible
    private static final String NOT_A_CLAIM = 'Letters are written from a claim.';
    @TestVisible
    private static final String NO_ACCESS = 'You do not have access to this claim.';
    @TestVisible
    private static final String NOT_OFFERED = 'This claim does not support that letter now.';
    @TestVisible
    private static final String NO_ADDRESSEE = 'Say who the letter is to before approving it.';
    @TestVisible
    private static final String NO_BODY = 'The letter has no text yet.';
    @TestVisible
    private static final String TOO_LONG = 'The letter is too long to save. Shorten it to about two pages.';
    @TestVisible
    private static final String HAS_GAPS = 'Fill each gap in square brackets before approving the letter.';
    @TestVisible
    private static final String NO_REQUEST = 'Say what to change.';
    @TestVisible
    private static final String NOT_A_LETTER = 'That file note is not an approved letter.';
    @TestVisible
    private static final String SAVE_ERROR = 'The letter could not be saved. Try again.';
    @TestVisible
    private static final String STORAGE_FULL = 'The org is out of storage, so the letter could not be saved.';

    private static final Map<String, String> TITLES = new Map<String, String>{
        ACKNOWLEDGMENT => 'Acknowledgment of claim',
        RESERVATION => 'Reservation of rights',
        CONFIRMATION => 'Coverage confirmation',
        INFORMATION => 'Request for information',
        PAYMENT => 'Payment explanation',
        NOTICE => 'Notice of claim to the other carrier'
    };
    private static final Map<String, String> NOTE_TYPES = new Map<String, String>{
        ACKNOWLEDGMENT => 'Contact',
        RESERVATION => 'Coverage',
        CONFIRMATION => 'Coverage',
        INFORMATION => 'Contact',
        PAYMENT => 'Payment',
        NOTICE => 'Contact'
    };

    private static final String WHO =
        'You write claim correspondence for Antsurance, an insurance carrier, for an adjuster to edit and approve. ' +
        'You are given the claim file as text and told which letter to write. The addressee block, the date, the reference lines and the ' +
        'signature are already on the letter: write only the salutation and the body.\n\n' +
        'How to write: plain, courteous and exact, the way an experienced claims professional writes. Short sentences. No legal flourishes, ' +
        'no filler, and no sympathy beyond one plain sentence where a loss is fresh. Three to five paragraphs of at most four sentences each, ' +
        'and no more than 240 words in all, so the letter fits one page. ' +
        'No headings, lists, bold or Markdown, and never a dash used as punctuation.\n\n' +
        'What you may say: only what the file holds. Name a coverage or an endorsement only as the file lists it, and where you rely on one say ' +
        '"as shown on your declarations page". Never quote or paraphrase policy wording the file does not contain. Use the amounts under FIGURES ' +
        'exactly and work out no others. Write dates as October 5, 2026 and money as $46,421.\n\n' +
        'What you must leave out: the reserve, internal notes and opinions, anything about fraud or special investigation, underwriting notes, ' +
        'other customers, anything Claude wrote earlier in the file, and any promise of payment or of an outcome the file does not record. ' +
        'A letter never says coverage is denied.\n\n' +
        'Gaps: when the letter needs a fact the file does not hold, such as a name, a claim number, an address or a date, write it as a gap in ' +
        'square brackets that says what goes there, for example [other carrier\'s claim number], and list each gap under gaps. Never invent the ' +
        'fact. Use square brackets for nothing else.\n\n' +
        'salutation: "Dear" and the full name of the person the letter is addressed to, then a comma, with no title such as Mr. or Ms. ' +
        'When the letter goes to a company and no person is named, write "To the claims department:".\n' +
        'paragraphs: the body, one entry for each paragraph.\n' +
        'gaps: each gap you left, without its brackets. Empty when there are none.\n' +
        'basis: up to five short lines for the adjuster, each naming the fact in the file that a statement in the letter rests on. Not part of the letter.';

    private static final Map<String, String> ASKS = new Map<String, String>{
        ACKNOWLEDGMENT => 'An acknowledgment of the claim, to the insured. Say the claim has been received. Say in one sentence what was reported, in plain words. ' +
        'Name the adjuster under SIGNED BY as the person handling it and the one to contact. Say what happens next, from the open tasks in the file. ' +
        'Ask for anything under STILL TO ASK, if there is anything. Do not say whether the loss is covered.',
        RESERVATION => 'A reservation of rights, to the insured. Its purpose is to tell the insured that Antsurance is investigating the claim, has not yet decided whether ' +
        'or how far the policy covers it, and keeps its rights under the policy while it does. Say which coverage on the policy may respond, from COVERAGE CHECK, ' +
        'and what question is still open, in plain words and without accusing anyone. Say what is being done to answer it and what the insured should send ' +
        'or do, from STILL TO ASK. Say once, in these words, that Antsurance reserves its rights under the policy. Say that this letter is not a denial of the ' +
        'claim, and that nothing done during the investigation gives up any right of Antsurance or of the insured under the policy. If FIGURES shows a payment ' +
        'already made, say that it was made and that it does not change this.',
        CONFIRMATION => 'A coverage confirmation, to the insured. Say the loss is covered under the coverage named in COVERAGE CHECK, as shown on the declarations page. ' +
        'State the deductible and, from FIGURES, what is payable on the current estimate, and say that the amount can change as estimates and invoices come in. ' +
        'Say what happens next, from the open tasks in the file.',
        INFORMATION => 'A request for documents or information, to the insured. Say what is needed in ordinary sentences, each item with a clause on why it is needed, ' +
        'taken from STILL TO ASK. At most five items. Say how to send it: by replying to this letter or by calling the adjuster under SIGNED BY. Say the claim ' +
        'moves forward when it arrives. Give no deadline unless the file records one.',
        PAYMENT => 'A payment explanation, to the insured. Using FIGURES only, walk through the arithmetic in words, one amount to a sentence: what the loss is estimated at, ' +
        'the deductible that applies, what is payable, what has been paid so far, and what remains. Say what a remaining amount waits on only if the file says; ' +
        'otherwise say the adjuster will confirm it. Say who to call with a question.',
        NOTICE => 'A notice of claim to the other party\'s insurance carrier. Its purpose is to put that carrier on notice that its insured was involved in a loss with ' +
        'Antsurance\'s insured, and that Antsurance will seek recovery of what it pays. Give our insured\'s name, the date and place of the loss and a description ' +
        'in two sentences, from the file. Ask them to acknowledge the claim, confirm coverage for their insured, keep all evidence, and send their adjuster\'s ' +
        'contact details. Do not state our policy\'s limits or deductible or what has been paid. The other driver\'s name, their carrier and their claim number ' +
        'are gaps unless the file gives them.'
    };

    private static final String REVISE =
        'The adjuster has read the letter below and asks for a change. Make that change and no other: keep every other sentence as it stands, ' +
        'including edits the adjuster has made, unless the change requires touching it. Return the whole letter again.';

    /** A letter the claim could use now. */
    public class Option {
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        /** Who it goes to, such as "To Chinedu Okafor". */
        @AuraEnabled
        public String toWhom;
        /** One line on why the claim supports it now. */
        @AuraEnabled
        public String why;
    }

    /** A letter that was approved and is on the claim. */
    public class OnFile {
        @AuraEnabled
        public Id noteId;
        /** The saved PDF, or null when only the note was saved. */
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String toWhom;
        @AuraEnabled
        public String approvedBy;
        @AuraEnabled
        public Datetime approvedAt;
    }

    /** What the Letters section shows at rest. */
    public class Desk {
        @AuraEnabled
        public List<Option> options = new List<Option>();
        @AuraEnabled
        public List<OnFile> onFile = new List<OnFile>();
        /** Letters the claim does not support now, each with the reason, in one sentence. Null when there is nothing to say. */
        @AuraEnabled
        public String notNow;
    }

    /** A letter: what the editor holds, what Claude returns and what is approved. */
    public class Letter {
        @AuraEnabled
        public String kind { get; set; }
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public List<String> addressee { get; set; }
        @AuraEnabled
        public String dateLine { get; set; }
        @AuraEnabled
        public List<String> reference { get; set; }
        @AuraEnabled
        public String salutation { get; set; }
        /** The body, with a blank line between paragraphs. */
        @AuraEnabled
        public String body { get; set; }
        @AuraEnabled
        public String closing { get; set; }
        @AuraEnabled
        public List<String> signer { get; set; }
        /** What Claude's draft rests on, for the adjuster to check. Not part of the letter. */
        @AuraEnabled
        public List<String> basis { get; set; }

        public Letter() {
            addressee = new List<String>();
            reference = new List<String>();
            signer = new List<String>();
            basis = new List<String>();
        }
    }

    /** A paragraph as its printed lines. */
    public class Paragraph {
        @AuraEnabled
        public Integer index { get; set; }
        @AuraEnabled
        public List<String> lines { get; set; }
    }

    /** The letter as the page prints it: every line already broken, so the preview and the PDF agree. */
    public class Sheet {
        @AuraEnabled
        public String title { get; set; }
        @AuraEnabled
        public List<String> addressee { get; set; }
        @AuraEnabled
        public String dateLine { get; set; }
        @AuraEnabled
        public List<String> reference { get; set; }
        @AuraEnabled
        public String salutation { get; set; }
        @AuraEnabled
        public List<Paragraph> paragraphs { get; set; }
        @AuraEnabled
        public String closing { get; set; }
        @AuraEnabled
        public List<String> signer { get; set; }
        /** How many pages the letter takes, worked out from the heights the page prints at. */
        @AuraEnabled
        public Integer pages { get; set; }
        /** The gaps still in square brackets, without the brackets. */
        @AuraEnabled
        public List<String> gaps { get; set; }
    }

    /** The saved PDF. */
    public class Saved {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public String title;
    }

    /** Everything about the claim a letter draws on. */
    private class ClaimFile {
        Case claim;
        AntsuranceClaimsAssistantCoverage.Check check;
        List<String> questions = new List<String>();
        /** How many of the questions are the coverage check's own; the rest are what the analysis found missing. */
        Integer fromCheck = 0;
        AntsuranceClaimRules.Position position;
        String handlerName;
        String handlerTitle;
        List<OnFile> onFile = new List<OnFile>();
    }

    /**
     * @description The letters a claim could use now, and the letters already approved on it.
     * @param caseId The claim
     * @return The options, each with why, and the letters on file, newest first
     * @throws AuraHandledException when the record is not a claim or cannot be read
     */
    @AuraEnabled
    public static Desk getLetters(Id caseId) {
        ClaimFile file = load(caseId);
        Desk desk = new Desk();
        desk.onFile = file.onFile;
        List<String> notNow = new List<String>();
        for (String kind : new List<String>{ ACKNOWLEDGMENT, RESERVATION, CONFIRMATION, INFORMATION, PAYMENT, NOTICE }) {
            String why = whyNow(kind, file);
            if (why != null) {
                Option option = new Option();
                option.kind = kind;
                option.title = TITLES.get(kind);
                option.toWhom = 'To ' + (kind == NOTICE ? 'the other party\'s carrier' : insuredName(file.claim));
                option.why = why;
                desk.options.add(option);
            }
        }
        Boolean hasCheck = file.check != null && file.check.exists == true;
        if (!hasCheck) {
            notNow.add('A coverage letter needs the coverage check first.');
        } else if (file.check.verdict == AntsuranceClaimsAssistantCoverage.NOT_COVERED) {
            notNow.add('The coverage check says the loss is not covered. A denial is written by a person, not drafted here.');
        }
        desk.notNow = notNow.isEmpty() ? null : String.join(notNow, ' ');
        return desk;
    }

    /**
     * @description Has Claude draft a letter from the claim. Nothing is saved.
     * @param caseId The claim
     * @param kind Which letter, as getLetters names it
     * @return The draft: addressee, date, reference lines and signature from the record, salutation and body from Claude
     * @throws AuraHandledException when the claim does not support that letter, or Claude cannot be reached
     */
    @AuraEnabled
    public static Letter draft(Id caseId, String kind) {
        ClaimFile file = load(caseId);
        if (!TITLES.containsKey(kind) || whyNow(kind, file) == null) {
            throw handled(NOT_OFFERED);
        }
        Letter letter = frame(kind, file);
        String prompt = 'LETTER TO WRITE\n' + ASKS.get(kind) + '\n\n' + context(letter, file, caseId);
        return write(letter, new AntsuranceAiClient.Question(WHO, prompt));
    }

    /**
     * @description Has Claude change a letter the way the adjuster asks, in words. Nothing is saved.
     * @param caseId The claim
     * @param letterJson The letter as it stands in the editor
     * @param request What to change, such as "shorter" or "add the deductible"
     * @return The letter with a new salutation and body; everything else as it was
     * @throws AuraHandledException when the request is empty or Claude cannot be reached
     */
    @AuraEnabled
    public static Letter revise(Id caseId, String letterJson, String request) {
        if (String.isBlank(request)) {
            throw handled(NO_REQUEST);
        }
        ClaimFile file = load(caseId);
        Letter letter = read(letterJson);
        String prompt =
            'LETTER TO WRITE\n' + (ASKS.containsKey(letter.kind) ? ASKS.get(letter.kind) : 'A letter about this claim.') + '\n\n' +
            REVISE + '\n\nTHE ADJUSTER ASKS\n' + request.normalizeSpace().abbreviate(600) + '\n\n' +
            'THE LETTER AS IT STANDS\n' + blankAs(letter.salutation, '') + '\n\n' + blankAs(letter.body, '') + '\n\n' + context(letter, file, caseId);
        return write(letter, new AntsuranceAiClient.Question(WHO, prompt));
    }

    /**
     * @description Lays a letter out the way its PDF prints, for the preview beside the editor.
     * @param letterJson The letter as it stands in the editor
     * @return Every line as printed, the page count and the gaps still open
     */
    @AuraEnabled
    public static Sheet layout(String letterJson) {
        return sheetOf(read(letterJson));
    }

    /**
     * @description Approves a letter: writes the file note that records who approved it and carries its
     * text. Call savePdf next, in its own request, to put the PDF on the claim. Nothing is sent.
     * @param caseId The claim
     * @param letterJson The letter as approved
     * @return The file note
     * @throws AuraHandledException when the letter is empty, too long or still has a gap, or the note cannot be saved
     */
    @AuraEnabled
    public static Id approve(Id caseId, String letterJson) {
        Letter letter = read(letterJson);
        if (present(letter.addressee).isEmpty()) {
            throw handled(NO_ADDRESSEE);
        }
        if (String.isBlank(letter.body)) {
            throw handled(NO_BODY);
        }
        if (letter.body.length() > MAX_BODY) {
            throw handled(TOO_LONG);
        }
        if (!gapsIn(letter).isEmpty()) {
            throw handled(HAS_GAPS);
        }
        try {
            Case claim = [SELECT Id, Policy__c, AccountId, RecordType.DeveloperName FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
            if (claim.RecordType?.DeveloperName != 'Claim') {
                throw handled(NOT_A_CLAIM);
            }
            File_Note__c note = new File_Note__c(
                Case__c = caseId,
                Policy__c = claim.Policy__c,
                Account__c = claim.AccountId,
                Note_Type__c = NOTE_TYPES.containsKey(letter.kind) ? NOTE_TYPES.get(letter.kind) : 'Contact',
                Note_Date__c = Datetime.now(),
                Body__c = noteFor(letter)
            );
            insert as user note;
            return note.Id;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlType(0) == StatusCode.STORAGE_LIMIT_EXCEEDED ? STORAGE_FULL : SAVE_ERROR);
        }
    }

    /**
     * @description Renders an approved letter as a PDF and saves it to the claim's files. Safe to call
     * again: a letter that already has its PDF gets the same file back.
     * @param noteId The file note approve returned
     * @return The saved file
     * @throws AuraHandledException when the note is not an approved letter, or the file cannot be saved
     */
    @AuraEnabled
    public static Saved savePdf(Id noteId) {
        File_Note__c note;
        try {
            note = [SELECT Id, Body__c, Note_Date__c, Case__c FROM File_Note__c WHERE Id = :noteId WITH USER_MODE LIMIT 1];
        } catch (QueryException e) {
            throw handled(NOT_A_LETTER);
        }
        if (!isLetterNote(note) || note.Case__c == null) {
            throw handled(NOT_A_LETTER);
        }
        Saved saved = new Saved();
        saved.title = parse(note.Body__c).title + ', ' + note.Note_Date__c.format('MMM d, yyyy');
        Map<Id, Id> filed = documentsByNote(note.Case__c);
        if (filed.containsKey(note.Id)) {
            saved.documentId = filed.get(note.Id);
            return saved;
        }
        PageReference page = Page.AntsuranceClaimLetter;
        page.getParameters().put('id', note.Id);
        // A test cannot render a page, so it saves a stand-in for the PDF.
        Blob pdf = Test.isRunningTest() ? Blob.valueOf('PDF') : page.getContentAsPDF();
        ContentVersion file = new ContentVersion(
            Title = saved.title,
            PathOnClient = AntsuranceDocumentFormat.fileSafe(saved.title) + '.pdf',
            VersionData = pdf,
            Description = FILE_MARK + note.Id,
            FirstPublishLocationId = note.Case__c
        );
        try {
            insert as user file;
            saved.documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id WITH USER_MODE].ContentDocumentId;
        } catch (DmlException e) {
            throw handled(e.getDmlType(0) == StatusCode.STORAGE_LIMIT_EXCEEDED ? STORAGE_FULL : SAVE_ERROR);
        }
        return saved;
    }

    /**
     * @description True for the file note of an approved letter.
     * @param note The note, with Body__c
     * @return Whether the note carries a letter
     */
    public static Boolean isLetterNote(File_Note__c note) {
        return note != null && String.isNotBlank(note.Body__c) && note.Body__c.trim().startsWith(NOTE_OPENING);
    }

    /**
     * @description The letter a file note carries.
     * @param noteBody The note's text, as approve wrote it
     * @return The letter, with whatever parts could be read
     */
    public static Letter parse(String noteBody) {
        Letter letter = new Letter();
        String text = noteBody == null ? '' : noteBody.replace('\r\n', '\n').replace('\r', '\n');
        String opening = text.substringBefore('\n' + NOTE_RULE);
        List<String> blocks = new List<String>();
        for (String block : text.substringAfter('\n' + NOTE_RULE).split('\n[ \t]*\n')) {
            if (String.isNotBlank(block)) {
                blocks.add(block.trim());
            }
        }
        if (!blocks.isEmpty() && blocks[0].startsWith(TO_MARK)) {
            readMarked(letter, blocks);
        } else {
            readByPosition(letter, blocks);
        }
        // The opening names the letter and then who it is to. Reading up to the addressee's own name keeps
        // a title whole whatever it says.
        String named = opening.substringAfter(NOTE_OPENING);
        Integer toAt = letter.addressee.isEmpty() ? -1 : named.indexOf(', to ' + letter.addressee[0] + '. ');
        letter.title = blankAs(toAt < 0 ? opening.substringBetween(NOTE_OPENING, ', to ') : named.left(toAt), 'Letter').trim();
        for (String kind : TITLES.keySet()) {
            if (TITLES.get(kind) == letter.title) {
                letter.kind = kind;
            }
        }
        return letter;
    }

    /**
     * Reads a note whose parts are marked, as noteFor writes them. A part that is not there stays empty.
     * The closing is the last block, or the one before the signature, so a paragraph that happens to
     * open with a mark is still a paragraph.
     */
    private static void readMarked(Letter letter, List<String> blocks) {
        Integer last = blocks.size() - 1;
        if (last > 0 && blocks[last].startsWith(SIGNED_MARK) && blocks[last - 1].startsWith(CLOSING_MARK)) {
            letter.signer = linesOf(blocks[last].removeStart(SIGNED_MARK));
            last--;
        }
        if (blocks[last].startsWith(CLOSING_MARK)) {
            letter.closing = blocks[last].removeStart(CLOSING_MARK).normalizeSpace();
            last--;
        }
        Integer at = 0;
        while (at <= last && !blocks[at].startsWith(BODY_MARK)) {
            String block = blocks[at++];
            if (block.startsWith(TO_MARK)) {
                letter.addressee = linesOf(block.removeStart(TO_MARK));
            } else if (block.startsWith(DATE_MARK)) {
                letter.dateLine = block.removeStart(DATE_MARK).normalizeSpace();
            } else if (block.startsWith(REFERENCE_MARK)) {
                letter.reference = linesOf(block.removeStart(REFERENCE_MARK));
            } else if (block.startsWith(SALUTATION_MARK)) {
                letter.salutation = block.removeStart(SALUTATION_MARK).normalizeSpace();
            }
        }
        List<String> paragraphs = new List<String>();
        while (at <= last) {
            String block = blocks[at++];
            paragraphs.add((paragraphs.isEmpty() ? block.removeStart(BODY_MARK) : block).normalizeSpace());
        }
        letter.body = String.join(paragraphs, '\n\n');
    }

    /**
     * Reads a note saved before the parts were marked. In order: addressee, date, reference, salutation,
     * the paragraphs, then the closing with the signature under it.
     */
    private static void readByPosition(Letter letter, List<String> blocks) {
        if (blocks.size() < 6) {
            letter.body = String.join(blocks, '\n\n');
            return;
        }
        letter.addressee = linesOf(blocks[0]);
        letter.dateLine = blocks[1].normalizeSpace();
        letter.reference = linesOf(blocks[2]);
        letter.salutation = blocks[3].normalizeSpace();
        List<String> last = linesOf(blocks[blocks.size() - 1]);
        letter.closing = last.remove(0);
        letter.signer = last;
        List<String> paragraphs = new List<String>();
        for (Integer i = 4; i < blocks.size() - 1; i++) {
            paragraphs.add(blocks[i].normalizeSpace());
        }
        letter.body = String.join(paragraphs, '\n\n');
    }

    /**
     * @description A letter as its printed lines.
     * @param letter The letter
     * @return The sheet the preview and the PDF both draw
     */
    public static Sheet sheetOf(Letter letter) {
        Sheet sheet = new Sheet();
        sheet.title = letter.title;
        sheet.addressee = present(letter.addressee);
        sheet.dateLine = letter.dateLine;
        sheet.reference = present(letter.reference);
        sheet.salutation = letter.salutation;
        sheet.closing = String.isBlank(letter.closing) ? CLOSING : letter.closing;
        sheet.signer = present(letter.signer);
        sheet.paragraphs = new List<Paragraph>();
        // The date, the reference lines and the salutation are each set off by a gap where the letter has
        // them, and take no room where it does not. The closing always prints, with the signature under it.
        Decimal height = HEAD_HEIGHT + ADDRESS_GAP + LINE_HEIGHT * sheet.addressee.size();
        if (String.isNotBlank(sheet.dateLine)) {
            height += BLOCK_GAP + LINE_HEIGHT;
        }
        if (!sheet.reference.isEmpty()) {
            height += BLOCK_GAP + LINE_HEIGHT * sheet.reference.size();
        }
        if (String.isNotBlank(sheet.salutation)) {
            height += BLOCK_GAP + LINE_HEIGHT;
        }
        height += BLOCK_GAP + LINE_HEIGHT + SIGNING_GAP + LINE_HEIGHT * sheet.signer.size();
        for (String text : paragraphsOf(letter.body)) {
            Paragraph paragraph = new Paragraph();
            paragraph.index = sheet.paragraphs.size();
            paragraph.lines = fit(text, LINE_CHARS);
            sheet.paragraphs.add(paragraph);
            height += PARAGRAPH_GAP + LINE_HEIGHT * paragraph.lines.size();
        }
        sheet.pages = Math.max(1, (Integer) Math.ceil(height / PAGE_HEIGHT));
        sheet.gaps = gapsIn(letter);
        return sheet;
    }

    /** The claim and what a letter draws on from it. */
    private static ClaimFile load(Id caseId) {
        ClaimFile file = new ClaimFile();
        try {
            List<Case> claims = [
                SELECT
                    Id,
                    CaseNumber,
                    Subject,
                    Status,
                    IsClosed,
                    RecordType.DeveloperName,
                    Handled_By__c,
                    Owner.Name,
                    Date_of_Loss__c,
                    Reported_Date__c,
                    Loss_Location__c,
                    Estimated_Loss__c,
                    Reserve_Amount__c,
                    Paid_Amount__c,
                    Subrogation_Potential__c,
                    Coverage_Read__c,
                    Claude_Analysis__c,
                    Contact.Name,
                    Account.Name,
                    Account.RecordType.DeveloperName,
                    Account.BillingStreet,
                    Account.BillingCity,
                    Account.BillingState,
                    Account.BillingPostalCode,
                    Policy__r.Name,
                    Policy__r.Line_of_Business__c,
                    Policy__r.Deductible__c,
                    Policy__r.Coverage_Limit__c
                FROM Case
                WHERE Id = :caseId
                WITH USER_MODE
                LIMIT 1
            ];
            if (claims.isEmpty() || claims[0].RecordType?.DeveloperName != 'Claim') {
                throw handled(NOT_A_CLAIM);
            }
            file.claim = claims[0];
            String handler = String.isBlank(file.claim.Handled_By__c) ? file.claim.Owner?.Name : file.claim.Handled_By__c;
            file.handlerName = blankAs(handler, COMPANY).substringBefore(',').trim();
            file.handlerTitle = handler != null && handler.contains(',') ? handler.substringAfter(',').trim() : null;
            List<File_Note__c> notes = [
                SELECT Id, Body__c, Note_Date__c, Author_Name__c, CreatedBy.Name
                FROM File_Note__c
                WHERE Case__c = :caseId
                WITH USER_MODE
                ORDER BY Note_Date__c DESC NULLS LAST, CreatedDate DESC
                LIMIT 200
            ];
            Map<Id, Id> filed = documentsByNote(caseId);
            for (File_Note__c note : notes) {
                // The file's own notes say what the handler's title is: "Marcus Lindahl, Property Adjuster".
                if (file.handlerTitle == null && String.isNotBlank(note.Author_Name__c) && note.Author_Name__c.startsWith(file.handlerName + ',')) {
                    file.handlerTitle = note.Author_Name__c.substringAfter(',').trim();
                }
                if (isLetterNote(note) && file.onFile.size() < MAX_ON_FILE) {
                    Letter letter = parse(note.Body__c);
                    OnFile row = new OnFile();
                    row.noteId = note.Id;
                    row.documentId = filed.get(note.Id);
                    row.title = letter.title;
                    row.toWhom = letter.addressee.isEmpty() ? null : 'To ' + letter.addressee[0];
                    row.approvedBy = note.CreatedBy?.Name;
                    row.approvedAt = note.Note_Date__c;
                    file.onFile.add(row);
                }
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        file.handlerTitle = blankAs(file.handlerTitle, DEFAULT_TITLE);
        try {
            file.check = AntsuranceClaimsAssistantCoverage.getCheck(caseId);
        } catch (Exception e) {
            // A check that cannot be read is the same as no check: no coverage letter is offered.
            file.check = null;
        }
        if (file.check != null && file.check.exists == true && file.check.questions != null) {
            for (String question : file.check.questions) {
                addQuestion(file.questions, question);
            }
        }
        file.fromCheck = file.questions.size();
        for (String gap : evidenceNeeded(file.claim.Claude_Analysis__c)) {
            addQuestion(file.questions, gap);
        }
        AntsuranceClaimRules.Terms terms = AntsuranceClaimRules.termsFor(file.claim);
        file.position = AntsuranceClaimRules.position(file.claim.Reserve_Amount__c, file.claim.Estimated_Loss__c, terms.deductible, terms.limitAmount);
        return file;
    }

    /** The saved letters on a claim: the note each PDF was made from, and the PDF. */
    private static Map<Id, Id> documentsByNote(Id caseId) {
        Map<Id, Id> byNote = new Map<Id, Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.LatestPublishedVersion.Description
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
            WITH USER_MODE
            LIMIT 200
        ]) {
            String description = link.ContentDocument?.LatestPublishedVersion?.Description;
            if (String.isNotBlank(description) && description.startsWith(FILE_MARK)) {
                String noteId = description.substringAfter(FILE_MARK).trim();
                if (noteId instanceof Id) {
                    byNote.put((Id) noteId, link.ContentDocumentId);
                }
            }
        }
        return byNote;
    }

    /** What the analysis says is still missing, when the claim has one. */
    private static List<String> evidenceNeeded(String storedAnalysis) {
        List<String> needed = new List<String>();
        if (String.isBlank(storedAnalysis)) {
            return needed;
        }
        try {
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(storedAnalysis);
            Map<String, Object> report = (Map<String, Object>) stored.get('report');
            List<Object> gaps = report == null ? null : (List<Object>) report.get('gaps');
            if (gaps != null) {
                for (Object each : gaps) {
                    Map<String, Object> gap = (Map<String, Object>) each;
                    if (gap.get('kind') == 'evidence_needed' && String.isNotBlank((String) gap.get('text'))) {
                        needed.add((String) gap.get('text'));
                    }
                }
            }
        } catch (Exception e) {
            // An analysis this class cannot read asks for nothing.
            needed.clear();
        }
        return needed;
    }

    private static void addQuestion(List<String> questions, String question) {
        String text = question == null ? '' : question.normalizeSpace();
        if (text != '' && !questions.contains(text) && questions.size() < MAX_QUESTIONS) {
            questions.add(text);
        }
    }

    /** Why the claim supports a letter now, or null when it does not. */
    private static String whyNow(String kind, ClaimFile file) {
        Case claim = file.claim;
        Boolean hasCheck = file.check != null && file.check.exists == true;
        Boolean open = claim.IsClosed != true;
        if (kind == ACKNOWLEDGMENT) {
            Boolean early = claim.Status == 'New' || claim.Status == 'Under Investigation';
            if (!open || !early || isOnFile(file, ACKNOWLEDGMENT)) {
                return null;
            }
            return (claim.Reported_Date__c == null ? 'A new claim.' : 'Reported ' + shortDate(claim.Reported_Date__c) + '.') + ' No acknowledgment is on file.';
        }
        if (kind == RESERVATION) {
            if (!open || !hasCheck || file.check.verdict != AntsuranceClaimsAssistantCoverage.NEEDS_REVIEW) {
                return null;
            }
            String question = file.check.questions == null || file.check.questions.isEmpty() ? firstSentence(file.check.summary) : file.check.questions[0];
            return 'The coverage check needs review.' + (String.isBlank(question) ? '' : ' Still open: ' + endStop(question));
        }
        if (kind == CONFIRMATION) {
            if (!open || !hasCheck || file.check.verdict != AntsuranceClaimsAssistantCoverage.COVERED) {
                return null;
            }
            return 'The coverage check found the loss covered' + (String.isBlank(file.check.respondingLabel) ? '.' : ' under ' + file.check.respondingLabel + '.');
        }
        if (kind == INFORMATION) {
            if (!open || file.questions.isEmpty()) {
                return null;
            }
            Integer count = file.questions.size();
            return (count == 1 ? 'One thing is still to ask: ' : count + ' things are still to ask' + askedBy(file.fromCheck, count - file.fromCheck) + '. First: ') + endStop(file.questions[0]);
        }
        if (kind == PAYMENT) {
            if (claim.Paid_Amount__c == null || claim.Paid_Amount__c <= 0) {
                return null;
            }
            return money(claim.Paid_Amount__c) + ' has been paid. This says what was paid, the deductible and what remains.';
        }
        if (kind == NOTICE) {
            return open && claim.Subrogation_Potential__c == true ? 'The claim is marked for recovery from the other party. This puts their carrier on notice.' : null;
        }
        return null;
    }

    /**
     * Where the questions come from, so the count agrees with the coverage check's own, which shows on the same
     * claim: ": 3 from the coverage check and 2 the analysis found missing".
     */
    private static String askedBy(Integer fromCheck, Integer fromAnalysis) {
        if (fromCheck > 0 && fromAnalysis > 0) {
            return ': ' + fromCheck + ' from the coverage check and ' + fromAnalysis + ' the analysis found missing';
        }
        String all = fromCheck + fromAnalysis == 2 ? 'both' : 'all';
        return ', ' + all + (fromCheck > 0 ? ' from the coverage check' : ' found missing by the analysis');
    }

    private static Boolean isOnFile(ClaimFile file, String kind) {
        for (OnFile row : file.onFile) {
            if (row.title == TITLES.get(kind)) {
                return true;
            }
        }
        return false;
    }

    /** The letter before Claude writes it: everything the record decides. */
    private static Letter frame(String kind, ClaimFile file) {
        Case claim = file.claim;
        Letter letter = new Letter();
        letter.kind = kind;
        letter.title = TITLES.get(kind);
        letter.dateLine = longDate(Date.today());
        letter.closing = CLOSING;
        letter.signer = new List<String>{ file.handlerName, file.handlerTitle, COMPANY };
        if (file.handlerName == COMPANY) {
            letter.signer = new List<String>{ 'Claims Department', COMPANY };
        }
        String lossDate = claim.Date_of_Loss__c == null ? null : 'Date of loss: ' + longDate(claim.Date_of_Loss__c);
        if (kind == NOTICE) {
            letter.addressee = new List<String>{ '[other party\'s insurance carrier]', 'Claims Department', '[carrier\'s mailing address]' };
            letter.reference = present(
                new List<String>{
                    'Re: Claim ' + claim.CaseNumber + ', our insured ' + insuredName(claim),
                    'Your insured: [other driver\'s name]',
                    'Your claim number: [other carrier\'s claim number]',
                    lossDate
                }
            );
            return letter;
        }
        List<String> to = new List<String>{ insuredName(claim) };
        Boolean isBusiness = claim.Account?.RecordType?.DeveloperName == 'Business';
        if (isBusiness && claim.Account?.Name != null && claim.Account.Name != to[0]) {
            to.add(claim.Account.Name);
        }
        if (String.isNotBlank(claim.Account?.BillingStreet)) {
            to.add(claim.Account.BillingStreet.replaceAll('\\s*[\\r\\n]+\\s*', ', '));
        }
        String cityLine = String.join(present(new List<String>{ claim.Account?.BillingCity, AntsuranceAddress.state(claim.Account, 'Billing') }), ', ');
        cityLine = String.join(present(new List<String>{ cityLine, claim.Account?.BillingPostalCode }), ' ');
        if (String.isNotBlank(cityLine)) {
            to.add(cityLine);
        }
        if (to.size() == 1) {
            to.add('[mailing address]');
        }
        letter.addressee = to;
        letter.reference = present(
            new List<String>{
                'Re: Claim ' + claim.CaseNumber + (String.isBlank(claim.Subject) ? '' : ', ' + claim.Subject.normalizeSpace()),
                claim.Policy__r == null ? null : 'Policy number: ' + claim.Policy__r.Name,
                lossDate
            }
        );
        return letter;
    }

    /** Asks Claude for the salutation and the body, and puts them on the letter. */
    private static Letter write(Letter letter, AntsuranceAiClient.Question question) {
        question.effort = 'medium';
        question.maxTokens = 2500;
        question.returning(
            new AntsuranceAiClient.Shape()
                .field('salutation', AntsuranceAiClient.text('The salutation, ending in a comma or a colon.'))
                .field('paragraphs', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One paragraph of the body.'), 'Three to five paragraphs.'))
                .field('gaps', AntsuranceAiClient.listOf(AntsuranceAiClient.text('What is missing, without brackets.'), 'Each gap left in the letter. Empty when there are none.'))
                .field('basis', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One fact in the file a statement rests on.'), 'Up to five.'))
        );
        Map<String, Object> answer;
        try {
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
        List<String> paragraphs = new List<String>();
        for (String paragraph : AntsuranceAiClient.toStrings(answer.get('paragraphs'))) {
            String text = tidy(paragraph);
            if (text != '') {
                paragraphs.add(text);
            }
        }
        letter.salutation = blankAs(tidy((String) answer.get('salutation')), 'To whom it may concern:');
        letter.body = String.join(paragraphs, '\n\n');
        letter.basis = new List<String>();
        for (String basis : AntsuranceAiClient.toStrings(answer.get('basis'))) {
            if (String.isNotBlank(basis) && letter.basis.size() < 5) {
                letter.basis.add(tidy(basis));
            }
        }
        return letter;
    }

    /** What Claude is given beside the instruction: what is already on the letter, the figures and the file. */
    private static String context(Letter letter, ClaimFile file, Id caseId) {
        Case claim = file.claim;
        List<String> figures = new List<String>();
        AntsuranceClaimRules.Position at = file.position;
        if (at != null && at.estimate != null) {
            figures.add('Estimated loss: ' + money(at.estimate) + '.');
            figures.add('Deductible: ' + (at.deductible == null ? 'not recorded.' : money(at.deductible) + '.'));
            if (at.payable != null) {
                figures.add('Payable on that estimate, after the deductible' + (at.cappedByLimit == true ? ' and held to the limit' : '') + ': ' + money(at.payable) + '.');
            }
        } else {
            figures.add('No estimate is recorded.');
        }
        Decimal paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
        figures.add(paid > 0 ? 'Paid so far: ' + money(paid) + '.' : 'Nothing has been paid yet.');
        if (paid > 0 && at != null && at.payable != null) {
            Decimal remaining = at.payable - paid;
            figures.add(remaining > 0 ? 'Remaining of what is payable: ' + money(remaining) + '.' : 'Nothing remains to be paid on the current estimate.');
        }
        List<String> coverage = new List<String>();
        if (file.check != null && file.check.exists == true) {
            coverage.add('Verdict: ' + file.check.verdict + '.');
            if (String.isNotBlank(file.check.respondingLabel)) {
                coverage.add('Coverage that responds: ' + file.check.respondingLabel + '.');
            }
            if (String.isNotBlank(file.check.summary)) {
                coverage.add(file.check.summary);
            }
        } else {
            coverage.add('No coverage check has been written.');
        }
        return String.join(
            new List<String>{
                'ADDRESSED TO\n' + String.join(present(letter.addressee), '\n'),
                'REFERENCE LINES ALREADY ON THE LETTER\n' + String.join(present(letter.reference), '\n'),
                'SIGNED BY\n' + String.join(present(letter.signer), ', '),
                'HOW TO REACH US\nThe claims line, ' + CLAIMS_LINE + ', is on the letterhead. To give a way to reach the adjuster, say to call that number or to reply to this letter. Give no other number or address.',
                'TODAY\n' + longDate(Date.today()),
                'FIGURES\n' + String.join(figures, '\n'),
                'COVERAGE CHECK\n' + String.join(coverage, '\n'),
                'STILL TO ASK\n' + (file.questions.isEmpty() ? 'Nothing is recorded.' : '- ' + String.join(file.questions, '\n- ')),
                'THE CLAIM FILE\n' + AntsuranceClaimsAssistantBrief.describeClaim(caseId)
            },
            '\n\n'
        );
    }

    /**
     * The file note for an approved letter: who approved it, then the letter itself, each part under its
     * mark. A part the letter does not have, such as reference lines the adjuster cleared, is left out,
     * so parse reads back exactly the letter that was approved.
     */
    private static String noteFor(Letter letter) {
        String title = blankAs(letter.title, 'Letter');
        List<String> addressee = present(letter.addressee);
        List<String> blocks = new List<String>{
            // Whole sentences, because the first lines of a note are what its preview shows. parse reads the title and the addressee from the first.
            NOTE_OPENING + ' ' + title + ', to ' + addressee[0] + '. Claude drafted it. ' + UserInfo.getName() + ' read, edited and approved it on ' +
                Datetime.now().format('MMM d, yyyy') + '. The PDF is in this claim\'s files. Nothing is sent from this system.',
            NOTE_RULE
        };
        addPart(blocks, TO_MARK, addressee);
        addPart(blocks, DATE_MARK, new List<String>{ letter.dateLine });
        addPart(blocks, REFERENCE_MARK, letter.reference);
        addPart(blocks, SALUTATION_MARK, new List<String>{ letter.salutation });
        List<String> paragraphs = paragraphsOf(letter.body);
        if (!paragraphs.isEmpty()) {
            paragraphs[0] = BODY_MARK + ' ' + paragraphs[0];
        }
        blocks.addAll(paragraphs);
        addPart(blocks, CLOSING_MARK, new List<String>{ blankAs(letter.closing, CLOSING) });
        addPart(blocks, SIGNED_MARK, letter.signer);
        return String.join(blocks, '\n\n');
    }

    /** Adds one part of the letter to its note under its mark, or nothing when the part is empty. */
    private static void addPart(List<String> blocks, String mark, List<String> lines) {
        List<String> kept = new List<String>();
        for (String line : present(lines)) {
            kept.add(line.normalizeSpace());
        }
        if (!kept.isEmpty()) {
            blocks.add(mark + ' ' + String.join(kept, '\n'));
        }
    }

    private static Letter read(String letterJson) {
        Letter letter;
        try {
            letter = (Letter) JSON.deserialize(letterJson, Letter.class);
        } catch (Exception e) {
            throw handled(NO_BODY);
        }
        if (letter == null) {
            throw handled(NO_BODY);
        }
        letter.addressee = capped(letter.addressee);
        letter.reference = capped(letter.reference);
        letter.signer = capped(letter.signer);
        letter.basis = letter.basis == null ? new List<String>() : letter.basis;
        letter.title = TITLES.containsKey(letter.kind) ? TITLES.get(letter.kind) : blankAs(letter.title, 'Letter').normalizeSpace().abbreviate(60);
        // The preview is what the adjuster approves, so what it shows is settled here, once, for the preview
        // and the saved letter alike: a letter with no date is dated today, the closing is the usual one,
        // and a salutation the adjuster cleared stays cleared.
        letter.dateLine = blankAs(letter.dateLine, longDate(Date.today())).normalizeSpace();
        letter.salutation = String.isBlank(letter.salutation) ? null : letter.salutation.normalizeSpace();
        letter.closing = blankAs(letter.closing, CLOSING).normalizeSpace();
        return letter;
    }

    /** The lines of an address or a signature: no blanks, no more than the page has room for, none too long for it. */
    private static List<String> capped(List<String> lines) {
        List<String> kept = new List<String>();
        for (String line : present(lines)) {
            if (kept.size() < MAX_LINES) {
                kept.add(line.normalizeSpace().abbreviate(MAX_LINE_LENGTH));
            }
        }
        return kept;
    }

    private static List<String> paragraphsOf(String body) {
        List<String> paragraphs = new List<String>();
        if (String.isBlank(body)) {
            return paragraphs;
        }
        for (String block : body.replace('\r\n', '\n').replace('\r', '\n').split('\n[ \t]*\n')) {
            if (String.isNotBlank(block)) {
                paragraphs.add(block.normalizeSpace());
            }
        }
        return paragraphs;
    }

    private static List<String> linesOf(String block) {
        return present(block.split('\n'));
    }

    private static List<String> present(List<String> values) {
        List<String> kept = new List<String>();
        if (values != null) {
            for (String value : values) {
                if (String.isNotBlank(value)) {
                    kept.add(value.trim());
                }
            }
        }
        return kept;
    }

    /** The gaps still written in square brackets anywhere on the letter, without the brackets and each once. */
    private static List<String> gapsIn(Letter letter) {
        List<String> everything = new List<String>();
        everything.addAll(present(letter.addressee));
        everything.addAll(present(letter.reference));
        everything.add(blankAs(letter.salutation, ''));
        everything.add(blankAs(letter.body, ''));
        List<String> gaps = new List<String>();
        Matcher found = Pattern.compile('\\[([^\\]\\n]{1,80})\\]').matcher(String.join(everything, '\n'));
        while (found.find()) {
            String gap = found.group(1).normalizeSpace();
            if (!gaps.contains(gap)) {
                gaps.add(gap);
            }
        }
        return gaps;
    }

    /**
     * Breaks a paragraph into lines of at most maxChars, filling each line the way a letter reads.
     * A last line of a word or two is avoided by setting the paragraph narrower, as long as that
     * takes no more lines: the widest setting whose last line is long enough, or failing that the
     * one whose last line is longest.
     */
    @TestVisible
    private static List<String> fit(String text, Integer maxChars) {
        List<String> words = text.normalizeSpace().split(' ');
        List<String> lines = fill(words, maxChars);
        if (lines.size() < 2 || lines[lines.size() - 1].length() >= SHORT_LAST_LINE) {
            return lines;
        }
        List<String> best = lines;
        for (Integer width = maxChars - 2; width >= maxChars / 2; width -= 2) {
            List<String> narrower = fill(words, width);
            if (narrower.size() > lines.size()) {
                break;
            }
            if (narrower[narrower.size() - 1].length() >= SHORT_LAST_LINE) {
                return narrower;
            }
            if (narrower[narrower.size() - 1].length() > best[best.size() - 1].length()) {
                best = narrower;
            }
        }
        return best;
    }

    private static List<String> fill(List<String> words, Integer maxChars) {
        List<String> lines = new List<String>();
        String current = '';
        for (String word : words) {
            if (current != '' && current.length() + 1 + word.length() > maxChars) {
                lines.add(current);
                current = word;
            } else {
                current = current == '' ? word : current + ' ' + word;
            }
        }
        lines.add(current);
        return lines;
    }

    /** What Claude wrote, as plain text: no Markdown marks, no dashes used as punctuation. */
    private static String tidy(String text) {
        if (text == null) {
            return '';
        }
        return text.replace('**', '').replace('—', ', ').replace(' – ', ', ').replace('–', '-').replace(' ,', ',').normalizeSpace();
    }

    private static String insuredName(Case claim) {
        return blankAs(claim.Contact?.Name, blankAs(claim.Account?.Name, 'the insured'));
    }

    private static String firstSentence(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        String flat = text.normalizeSpace();
        Integer stop = flat.indexOf('. ');
        return stop < 0 ? flat : flat.left(stop + 1);
    }

    private static String endStop(String text) {
        String flat = text.normalizeSpace();
        return flat.endsWith('.') || flat.endsWith('?') ? flat : flat + '.';
    }

    private static String shortDate(Date value) {
        return Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d');
    }

    private static String longDate(Date value) {
        return Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMMM d, yyyy');
    }

    private static String money(Decimal amount) {
        return amount == null ? 'not set' : '$' + amount.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String blankAs(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
