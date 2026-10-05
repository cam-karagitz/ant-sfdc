/**
 * @description File notes for the timeline on claim, service request, policy and customer pages.
 * A note written on a case also belongs to that case's policy and customer, so it shows on all three.
 * Salesforce's own notes on the record are read into the same timeline, and a note can be saved as one.
 * Reads and writes run with the user's own access.
 */
public with sharing class AntsuranceNotesController {
    private static final Integer MAX_NOTES = 100;
    private static final Integer MAX_BODY = 32000;
    private static final String EMPTY_NOTE = 'Write something before saving the note.';
    private static final String TOO_LONG = 'That note is too long. Keep it under 32,000 characters.';
    private static final String WRONG_RECORD = 'File notes can be added to claims, service requests, policies and customers.';
    private static final String NO_ACCESS = 'The file notes could not be read or saved. Check your access to File Notes.';
    /** The note type that saves to Salesforce's own Notes instead of a file note. */
    @TestVisible
    private static final String SALESFORCE_NOTE = AntsuranceSalesforceNotes.NOTE_TYPE + ' note';

    /**
     * @description One note in the timeline.
     */
    public class Note {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String noteType;
        @AuraEnabled
        public String body;
        @AuraEnabled
        public Datetime noteDate;
        @AuraEnabled
        public String author;
        /** True for a note saved from Claude's own claim analysis. */
        @AuraEnabled
        public Boolean byClaude = false;
        /** Who chose to keep a note Claude wrote. */
        @AuraEnabled
        public String savedBy;
        /** The claim or request the note was written on, when the timeline is for a policy or customer. */
        @AuraEnabled
        public Id caseId;
        @AuraEnabled
        public String caseLabel;
        /** Set on a note kept in Salesforce's own Notes: the note's file, to open it there. */
        @AuraEnabled
        public Id documentId;
    }

    /** Newest first, whichever kind of note each is. A note with no date goes last. */
    private class NewestFirst implements Comparator<Note> {
        public Integer compare(Note first, Note second) {
            if (first.noteDate == second.noteDate) {
                return 0;
            }
            if (first.noteDate == null || second.noteDate == null) {
                return first.noteDate == null ? 1 : -1;
            }
            return first.noteDate > second.noteDate ? -1 : 1;
        }
    }

    /**
     * @description The notes on a claim, service request, policy or customer, newest first.
     * @param recordId The record whose file is on screen
     * @return Up to 100 notes; empty for any other kind of record
     * @throws AuraHandledException when the user cannot read file notes
     */
    @AuraEnabled(cacheable=true)
    public static List<Note> getNotes(Id recordId) {
        String parentField = parentFieldFor(recordId);
        List<Note> notes = new List<Note>();
        if (parentField == null) {
            return notes;
        }
        try {
            for (File_Note__c record : (List<File_Note__c>) Database.queryWithBinds(
                'SELECT Id, Note_Type__c, Body__c, Note_Date__c, Author_Name__c, CreatedBy.Name, CreatedDate, Case__c, Case__r.CaseNumber, Case__r.Subject ' +
                    'FROM File_Note__c WHERE ' + parentField + ' = :recordId ORDER BY Note_Date__c DESC NULLS LAST, CreatedDate DESC LIMIT :maxNotes',
                new Map<String, Object>{ 'recordId' => recordId, 'maxNotes' => MAX_NOTES },
                AccessLevel.USER_MODE
            )) {
                Note note = new Note();
                note.recordId = record.Id;
                note.noteType = record.Note_Type__c;
                note.body = record.Body__c;
                note.noteDate = record.Note_Date__c == null ? record.CreatedDate : record.Note_Date__c;
                note.author = String.isBlank(record.Author_Name__c) ? record.CreatedBy.Name : record.Author_Name__c;
                if (AntsuranceClaimRules.isClaudeNote(record)) {
                    // Saved from Claude's analysis: the file shows Claude wrote it and who chose to keep it.
                    note.byClaude = true;
                    note.savedBy = note.author.startsWith(AntsuranceClaimRules.CLAUDE_AUTHOR) ? note.author.substringAfter('saved by ').trim() : note.author.substringBefore(',').trim();
                    note.author = AntsuranceClaimRules.CLAUDE_AUTHOR;
                }
                // On a case's own timeline the case is already the page, so it is not repeated on each note.
                if (record.Case__c != null && parentField != 'Case__c') {
                    note.caseId = record.Case__c;
                    note.caseLabel = record.Case__r.CaseNumber + ': ' + record.Case__r.Subject;
                }
                notes.add(note);
            }
            // Salesforce's own notes attached to this record, in the same timeline.
            List<AntsuranceSalesforceNotes.Entry> own = AntsuranceSalesforceNotes.notesOn(recordId, MAX_NOTES);
            for (AntsuranceSalesforceNotes.Entry entry : own) {
                Note note = new Note();
                note.recordId = entry.documentId;
                note.documentId = entry.documentId;
                note.noteType = SALESFORCE_NOTE;
                note.body = AntsuranceSalesforceNotes.withTitle(entry);
                note.noteDate = entry.writtenAt;
                note.author = entry.author;
                notes.add(note);
            }
            if (!own.isEmpty()) {
                notes.sort(new NewestFirst());
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        return notes;
    }

    /**
     * @description Whether a note can be saved to Salesforce's own Notes here, so the composer offers it only where it works.
     * @return True when the org has Notes turned on
     */
    @AuraEnabled(cacheable=true)
    public static Boolean salesforceNotesOn() {
        return AntsuranceSalesforceNotes.isOn();
    }

    /**
     * @description Adds a note to the file of a claim, service request, policy or customer.
     * @param recordId The record whose file is on screen
     * @param noteType One of the Note_Type__c values, or "Salesforce note" to keep it in Salesforce's own Notes; blank is saved as General
     * @param body The note text, which may use Markdown
     * @throws AuraHandledException when the note is empty or too long, or the record is of another kind
     */
    @AuraEnabled
    public static void addNote(Id recordId, String noteType, String body) {
        if (String.isBlank(body)) {
            throw handled(EMPTY_NOTE);
        }
        if (body.length() > MAX_BODY) {
            throw handled(TOO_LONG);
        }
        String parentField = parentFieldFor(recordId);
        if (parentField == null) {
            throw handled(WRONG_RECORD);
        }
        if (noteType == SALESFORCE_NOTE) {
            try {
                AntsuranceSalesforceNotes.create(recordId, body.trim());
            } catch (DmlException e) {
                throw handled(e.getDmlMessage(0));
            } catch (AntsuranceSalesforceNotes.NotesOffException e) {
                throw handled(e.getMessage());
            }
            return;
        }
        File_Note__c note = new File_Note__c(
            Note_Type__c = String.isBlank(noteType) ? 'General' : noteType,
            Body__c = body.trim(),
            Note_Date__c = Datetime.now()
        );
        note.put(parentField, recordId);
        try {
            // A note on a case or policy also belongs to the records above it.
            if (parentField == 'Case__c') {
                Case parent = [SELECT Policy__c, AccountId FROM Case WHERE Id = :recordId WITH USER_MODE];
                note.Policy__c = parent.Policy__c;
                note.Account__c = parent.AccountId;
            } else if (parentField == 'Policy__c') {
                note.Account__c = [SELECT Account__c FROM Policy__c WHERE Id = :recordId WITH USER_MODE].Account__c;
            }
            insert as user note;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    /** The File_Note__c lookup that points at this kind of record, or null if notes do not apply to it. */
    private static String parentFieldFor(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.SObjectType objectType = recordId.getSObjectType();
        if (objectType == Case.SObjectType) {
            return 'Case__c';
        }
        if (objectType == Policy__c.SObjectType) {
            return 'Policy__c';
        }
        return objectType == Account.SObjectType ? 'Account__c' : null;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
