/**
 * @description Reads a document attached to a claim, for the documents card on the claim page.
 * The handler picks a PDF or image (a contractor's estimate, a mitigation invoice, a police
 * report); Claude reads it against the claim file and reports what it is, the key facts and
 * figures, how it compares with the estimate and reserve, anything that looks off, and what to do
 * next. Nothing on the claim changes until the handler confirms a suggestion, and each change is
 * made as that user.
 */
public with sharing class AntsuranceClaimsAssistantDocuments {
    private static final Integer MAX_DOCUMENTS = 50;
    private static final Integer MAX_READING_TOKENS = 3000;
    private static final Integer MAX_TASK_SUBJECT = 255;
    private static final Integer TASK_DUE_IN_DAYS = 2;
    // Matches the limit in AntsuranceAiClient, so the card can say so before the handler clicks.
    private static final Integer MAX_BYTES = 1500000;
    private static final Integer BYTES_PER_KB = 1024;
    private static final Integer CENTS_PER_DOLLAR = 100;
    private static final Map<String, String> MEDIA_TYPES = new Map<String, String>{
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp'
    };

    @TestVisible
    private static final String SET_RESERVE = 'set_reserve';
    @TestVisible
    private static final String SET_ESTIMATE = 'set_estimate';
    @TestVisible
    private static final String FLAG_SUBROGATION = 'flag_subrogation';
    @TestVisible
    private static final String FLAG_FRAUD = 'flag_fraud';
    @TestVisible
    private static final String ADD_TASK = 'add_task';
    private static final List<String> SUGGESTION_KINDS = new List<String>{ SET_RESERVE, SET_ESTIMATE, FLAG_SUBROGATION, FLAG_FRAUD, ADD_TASK };
    private static final List<String> MATCHES = new List<String>{ 'yes', 'unclear', 'no' };

    @TestVisible
    private static final String NO_ACCESS = 'The claim or its files could not be read or saved. Check your access.';
    @TestVisible
    private static final String NOT_ON_CLAIM = 'That file is not attached to this claim.';
    @TestVisible
    private static final String WRONG_TYPE = 'Claude can read PDFs and images here.';
    @TestVisible
    private static final String TOO_LARGE = 'This file is larger than 1.5 MB, which is the most Claude can read here.';
    @TestVisible
    private static final String UNKNOWN_SUGGESTION = 'That suggestion cannot be applied.';
    @TestVisible
    private static final String NEEDS_AMOUNT = 'That suggestion has no amount to apply.';

    private static final String INSTRUCTIONS =
        'You are a claims examiner at Antsurance, an insurance carrier, reading a document that has been attached to a claim. ' +
        'You are given the claim file as text and the document itself. Read the whole document, including every line item and total, then report on it for the handler.\n\n' +
        'Use only the document and the claim file. Never invent a figure, a name or a fact, and say so when something cannot be read.\n\n' +
        'document_type: what the document is, in two to four words, such as Mitigation invoice, Repair estimate or Police crash report.\n\n' +
        'issuer: who issued it. document_date: its date as YYYY-MM-DD, or empty.\n\n' +
        'matches_claim: yes when the names, address, vehicle and dates in the document fit this claim; no when they clearly belong to something else; unclear otherwise. ' +
        'match_note: one sentence on what matched or did not.\n\n' +
        'summary: two sentences on what the document says and why it matters to this claim.\n\n' +
        'key_facts: up to eight facts a handler wants at a glance, as a short label and a short value: dates, parties, reference numbers, scope of work, findings and the main parts of the total. ' +
        'Leave the grand total out of this list, because it is shown on its own.\n\n' +
        'total_amount: the document\'s grand total in dollars, or null when it has none.\n\n' +
        'comparison: how the document compares with the claim. Set its figures against the estimate, the reserve, payments and any reserve breakdown in the file notes, ' +
        'do the arithmetic, and state each difference in dollars. When the document has no money in it, say what it changes about liability, coverage or the facts instead. One to three sentences.\n\n' +
        'concerns: zero to three things that look off: line items that do not add up to the total (check the sum), work outside the loss described, duplicates of something already paid, ' +
        'missing details, or anything that conflicts with the file. Empty when the document is in order.\n\n' +
        'suggestions: zero to three things the handler could do right now, each of one kind:\n' +
        '- set_reserve when the document shows the reserve should be a different figure. amount is the new total reserve for the whole claim, not the change. ' +
        'When the file notes break the reserve into lines, replace the line this document covers and keep the others, and show that working in the reason. ' +
        'Treat the deductible the way the file\'s own reserve notes do; when the file gives no lead, reserve the full cost and mention the deductible in the reason.\n' +
        '- set_estimate when the document gives a better figure for the total estimated loss. amount is the new total estimate.\n' +
        '- flag_subrogation when the document shows another party is at fault or responsible and the subrogation flag is not already set.\n' +
        '- flag_fraud when the document raises a real fraud concern and the possible fraud flag is not already set.\n' +
        '- add_task for a concrete follow-up. Put the task subject in title: it starts with a verb and is at most twelve words.\n' +
        'For each, title is a short label for a button, such as Set reserve to $48,450, amount is filled for the two set kinds and null otherwise, and reason is one sentence. ' +
        'A reserve or an estimate is set in whole dollars: round the amount up to the next dollar and write it without cents.\n' +
        'Do not suggest what is already true, such as a reserve already at that figure, a flag already set, or a follow-up an open task already covers.\n\n' +
        'note_type and note: a file note that records this document on the claim, at most 80 words, written as two or three labeled points, each on its own paragraph, ' +
        'in the form **Label:** text. For example **Document:**, **Amount:** and **Against the file:**.\n\n' +
        'Write in plain words. Write money with a dollar sign and thousands separators, and dates month first, like Sep 28. Do not use dashes as punctuation. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH +
        ' When a suggestion would change the reserve, follow this: ' +
        AntsuranceClaimRules.RESERVE_RULE;

    /**
     * @description A file attached to the claim.
     */
    public class DocumentItem {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String extension;
        @AuraEnabled
        public String sizeLabel;
        @AuraEnabled
        public Datetime addedAt;
        /** False when Claude cannot read this file here; whyNot says why. */
        @AuraEnabled
        public Boolean readable;
        @AuraEnabled
        public String whyNot;
    }

    /**
     * @description A labelled fact from a document.
     */
    public class KeyFact {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
    }

    /**
     * @description Something the handler could do after reading a document. Applied only on confirmation.
     */
    public class Suggestion {
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public Decimal amount;
        @AuraEnabled
        public String reason;
    }

    /**
     * @description Claude's reading of one document.
     */
    public class Reading {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String documentType;
        @AuraEnabled
        public String issuer;
        @AuraEnabled
        public Date documentDate;
        @AuraEnabled
        public String matchesClaim;
        @AuraEnabled
        public String matchNote;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public List<KeyFact> keyFacts = new List<KeyFact>();
        @AuraEnabled
        public Decimal totalAmount;
        @AuraEnabled
        public String comparison;
        @AuraEnabled
        public List<String> concerns = new List<String>();
        @AuraEnabled
        public List<Suggestion> suggestions = new List<Suggestion>();
        @AuraEnabled
        public String noteType;
        @AuraEnabled
        public String note;
    }

    /**
     * @description Lists the files attached to a claim, newest first.
     * @param caseId The claim on screen
     * @return The claim's files, each flagged with whether Claude can read it here
     * @throws AuraHandledException when the files cannot be read
     */
    @AuraEnabled
    public static List<DocumentItem> getDocuments(Id caseId) {
        List<DocumentItem> items = new List<DocumentItem>();
        try {
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize, ContentDocument.CreatedDate
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Title
                LIMIT :MAX_DOCUMENTS
            ]) {
                DocumentItem item = new DocumentItem();
                item.documentId = link.ContentDocumentId;
                item.title = link.ContentDocument.Title;
                item.extension = link.ContentDocument.FileExtension?.toLowerCase();
                item.sizeLabel = sizeLabel(link.ContentDocument.ContentSize);
                item.addedAt = link.ContentDocument.CreatedDate;
                item.whyNot = whyNotReadable(item.extension, link.ContentDocument.ContentSize);
                item.readable = item.whyNot == null;
                items.add(item);
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        return items;
    }

    /**
     * @description Has Claude read one of the claim's files against the claim.
     * @param caseId The claim on screen
     * @param documentId The file (ContentDocument) to read
     * @return What the document is, its key facts, how it compares with the claim, and suggestions
     * @throws AuraHandledException when the file is not on this claim, is of a kind or size Claude
     * cannot read here, or Claude cannot be reached
     */
    @AuraEnabled
    public static Reading readDocument(Id caseId, Id documentId) {
        ContentVersion version;
        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseId AND ContentDocumentId = :documentId
                WITH USER_MODE
                LIMIT 1
            ];
            if (links.isEmpty()) {
                throw handled(NOT_ON_CLAIM);
            }
            Id versionId = links[0].ContentDocument.LatestPublishedVersionId;
            version = [SELECT Title, FileExtension, ContentSize FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1];
            String problem = whyNotReadable(version.FileExtension?.toLowerCase(), version.ContentSize);
            if (problem != null) {
                throw handled(problem);
            }
            // The file body is loaded only once the type and size are known to be acceptable.
            version.VersionData = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1].VersionData;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }

        String prompt =
            AntsuranceClaimsAssistantBrief.describeClaim(caseId) +
            '\n\nThe attached document is titled "' +
            version.Title +
            '". Read it and report on it for this claim.';
        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, prompt)
                .returning(readingSchema())
                .attach(MEDIA_TYPES.get(version.FileExtension.toLowerCase()), version.VersionData);
            question.maxTokens = MAX_READING_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
        Reading reading = toReading(answer);
        reading.documentId = documentId;
        reading.title = version.Title;
        return reading;
    }

    /**
     * @description Applies one suggestion the handler confirmed, as that user. Changing the reserve
     * or the estimate also records why in a file note.
     * @param caseId The claim on screen
     * @param kind set_reserve, set_estimate, flag_subrogation, flag_fraud or add_task
     * @param amount The new reserve or estimate, for the two set kinds
     * @param title The task subject, for add_task
     * @param reason Claude's reason, kept in the file note for a reserve or estimate change
     * @param documentTitle The document the suggestion came from
     * @return A short confirmation of what was done
     * @throws AuraHandledException when the kind is unknown, an amount is missing, or the save fails
     */
    @AuraEnabled
    public static String applySuggestion(Id caseId, String kind, Decimal amount, String title, String reason, String documentTitle) {
        if (!SUGGESTION_KINDS.contains(kind)) {
            throw handled(UNKNOWN_SUGGESTION);
        }
        Boolean setsFigure = kind == SET_RESERVE || kind == SET_ESTIMATE;
        if (setsFigure && (amount == null || amount < 0)) {
            throw handled(NEEDS_AMOUNT);
        }
        try {
            Case claim = [SELECT ContactId, Reserve_Amount__c, Estimated_Loss__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
            if (setsFigure) {
                Decimal figure = amount.setScale(2, RoundingMode.HALF_UP);
                Boolean isReserve = kind == SET_RESERVE;
                Decimal before = isReserve ? claim.Reserve_Amount__c : claim.Estimated_Loss__c;
                Case change = new Case(Id = caseId);
                change.put(isReserve ? 'Reserve_Amount__c' : 'Estimated_Loss__c', figure);
                update as user change;

                String label = isReserve ? 'Reserve' : 'Estimate';
                String note =
                    '**' +
                    label +
                    ' changed:** From ' +
                    money(before) +
                    ' to ' +
                    money(figure) +
                    (String.isBlank(documentTitle) ? '.' : ' after reading ' + documentTitle + '.') +
                    (String.isBlank(reason) ? '' : '\n\n**Why:** ' + reason.trim());
                AntsuranceNotesController.addNote(caseId, 'Reserve', note);
                return label + ' set to ' + money(figure) + '.';
            }
            if (kind == ADD_TASK) {
                if (String.isBlank(title)) {
                    throw handled(UNKNOWN_SUGGESTION);
                }
                insert as user new Task(
                    WhatId = caseId,
                    WhoId = claim.ContactId,
                    OwnerId = UserInfo.getUserId(),
                    Subject = title.trim().left(MAX_TASK_SUBJECT),
                    Description = reason,
                    ActivityDate = Date.today().addDays(TASK_DUE_IN_DAYS),
                    Status = 'Not Started',
                    Priority = 'Normal'
                );
                return 'Task added.';
            }
            Boolean isFraud = kind == FLAG_FRAUD;
            Case flagged = new Case(Id = caseId);
            flagged.put(isFraud ? 'SIU_Referral__c' : 'Subrogation_Potential__c', true);
            update as user flagged;
            return isFraud ? 'Flagged for possible fraud.' : 'Flagged for subrogation.';
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    /**
     * @description Adds Claude's summary of a document to the claim's file notes.
     * @param caseId The claim on screen
     * @param noteType One of the file note types
     * @param body The note text, in Markdown
     * @throws AuraHandledException when the note is empty or cannot be saved
     */
    @AuraEnabled
    public static void addNote(Id caseId, String noteType, String body) {
        AntsuranceNotesController.addNote(caseId, noteType, body);
    }

    private static String whyNotReadable(String extension, Integer size) {
        if (!MEDIA_TYPES.containsKey(extension)) {
            return WRONG_TYPE;
        }
        return size > MAX_BYTES ? TOO_LARGE : null;
    }

    private static String sizeLabel(Integer bytes) {
        if (bytes == null) {
            return '';
        }
        Decimal kilobytes = Decimal.valueOf(bytes) / BYTES_PER_KB;
        return kilobytes < BYTES_PER_KB
            ? Math.max(1, kilobytes.round(RoundingMode.HALF_UP)) + ' KB'
            : (kilobytes / BYTES_PER_KB).setScale(1, RoundingMode.HALF_UP) + ' MB';
    }

    /** $9,971.20 or $48,450: cents are shown only when there are some. */
    @TestVisible
    private static String money(Decimal value) {
        if (value == null) {
            return 'not set';
        }
        Decimal rounded = value.setScale(2, RoundingMode.HALF_UP);
        Decimal dollars = rounded.setScale(0, RoundingMode.DOWN);
        Integer cents = ((rounded - dollars) * CENTS_PER_DOLLAR).intValue();
        return '$' + dollars.format() + (cents == 0 ? '' : '.' + String.valueOf(cents).leftPad(2, '0'));
    }

    @TestVisible
    private static AntsuranceAiClient.Shape readingSchema() {
        List<String> noteTypes = new List<String>();
        for (Schema.PicklistEntry entry : File_Note__c.Note_Type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                noteTypes.add(entry.getValue());
            }
        }
        AntsuranceAiClient.Shape keyFact = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('A short label.'))
            .field('value', AntsuranceAiClient.text('A short value.'));
        AntsuranceAiClient.Shape suggestion = new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(SUGGESTION_KINDS, 'What applying it does.'))
            .field('reason', AntsuranceAiClient.text('One sentence on why, with the working for a figure.'))
            .field('amount', AntsuranceAiClient.optionalNumber('The new total reserve or estimate for the set kinds, otherwise null.'))
            .field('title', AntsuranceAiClient.text('A short button label, or the task subject for add_task.'));
        return new AntsuranceAiClient.Shape()
            .field('document_type', AntsuranceAiClient.text('What the document is, in two to four words.'))
            .field('issuer', AntsuranceAiClient.text('Who issued it.'))
            .field('document_date', AntsuranceAiClient.text('YYYY-MM-DD, or empty.'))
            .field('match_note', AntsuranceAiClient.text('One sentence on what matched this claim or did not.'))
            .field('matches_claim', AntsuranceAiClient.choice(MATCHES, 'Whether the document belongs to this claim.'))
            .field('key_facts', AntsuranceAiClient.listOf(keyFact.toJson(), 'Up to eight facts at a glance.'))
            .field('total_amount', AntsuranceAiClient.optionalNumber('The grand total in dollars, or null.'))
            .field('summary', AntsuranceAiClient.text('Two sentences on what it says and why it matters here.'))
            .field('comparison', AntsuranceAiClient.text('How it compares with the estimate, reserve and notes, with the differences in dollars.'))
            .field('concerns', AntsuranceAiClient.listOf(AntsuranceAiClient.text('Something that looks off.'), 'Zero to three concerns.'))
            .field('suggestions', AntsuranceAiClient.listOf(suggestion.toJson(), 'Zero to three things the handler could do now.'))
            .field('note_type', AntsuranceAiClient.choice(noteTypes, 'The kind of file note this is.'))
            .field('note', AntsuranceAiClient.text('A file note recording the document, as labeled points.'));
    }

    @TestVisible
    private static Reading toReading(Map<String, Object> answer) {
        Reading reading = new Reading();
        reading.documentType = (String) answer.get('document_type');
        reading.issuer = (String) answer.get('issuer');
        reading.matchesClaim = (String) answer.get('matches_claim');
        reading.matchNote = (String) answer.get('match_note');
        reading.summary = (String) answer.get('summary');
        reading.comparison = (String) answer.get('comparison');
        reading.noteType = (String) answer.get('note_type');
        reading.note = (String) answer.get('note');
        reading.totalAmount = AntsuranceAiClient.toDecimal(answer.get('total_amount'));
        reading.concerns = AntsuranceAiClient.toStrings(answer.get('concerns'));
        try {
            String dateText = (String) answer.get('document_date');
            reading.documentDate = String.isBlank(dateText) ? null : Date.valueOf(dateText.trim());
        } catch (Exception e) {
            reading.documentDate = null;
        }
        if (answer.get('key_facts') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('key_facts')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                KeyFact fact = new KeyFact();
                fact.label = (String) values.get('label');
                fact.value = (String) values.get('value');
                if (String.isNotBlank(fact.label) && String.isNotBlank(fact.value)) {
                    reading.keyFacts.add(fact);
                }
            }
        }
        if (answer.get('suggestions') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('suggestions')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                Suggestion suggestion = new Suggestion();
                suggestion.kind = (String) values.get('kind');
                suggestion.title = (String) values.get('title');
                suggestion.amount = AntsuranceAiClient.toDecimal(values.get('amount'));
                suggestion.reason = (String) values.get('reason');
                Boolean setsFigure = suggestion.kind == SET_RESERVE || suggestion.kind == SET_ESTIMATE;
                // A figure change with no figure cannot be applied, so it is not offered.
                if (String.isNotBlank(suggestion.title) && (!setsFigure || suggestion.amount != null)) {
                    reading.suggestions.add(suggestion);
                }
            }
        }
        return reading;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
