/**
 * @description Salesforce's own notes (the standard Notes feature, stored as files of type SNOTE) on a
 * claim, policy or customer, so a note written in the Notes composer, on a phone or by another app
 * reads in the file beside the notes written here. A Salesforce note keeps its text as HTML; the file
 * shows Markdown, so this turns one into the other in both directions. Reads and writes run with the
 * user's own access.
 *
 * An org can have Notes turned off, and then the ContentNote object does not exist. This class names it
 * only at run time, so it compiles and installs either way; with Notes off it reads nothing and says so
 * when asked to save.
 */
public with sharing class AntsuranceSalesforceNotes {
    /** How the platform types a note among a record's files. */
    public static final String FILE_TYPE = 'SNOTE';
    /** What a Salesforce note is called as a kind of file note: "Salesforce note". */
    public static final String NOTE_TYPE = 'Salesforce';
    /** The name a brief or a coverage check keeps its number of Salesforce notes under. */
    public static final String COUNT_KEY = 'salesforceNotes';
    private static final Integer MAX_TITLE = 80;
    private static final String UNTITLED = 'Note';
    private static final String NOTE_OBJECT = 'ContentNote';
    private static final String NOTES_OFF = 'Salesforce Notes is turned off in this org. Turn Notes on in Setup, or save this as a file note.';

    /** Thrown when a note is to be saved to Salesforce Notes and the org has Notes turned off. */
    public class NotesOffException extends Exception {
    }

    /**
     * @description Whether Salesforce Notes is turned on in this org.
     * @return True when the ContentNote object exists here
     */
    public static Boolean isOn() {
        return !actAsOff && noteObject() != null;
    }

    /** The ContentNote object, looked up by name once a transaction; null where Notes is turned off. */
    private static Schema.SObjectType noteObject() {
        if (!lookedUp) {
            lookedUp = true;
            noteType = Schema.getGlobalDescribe().get(NOTE_OBJECT);
        }
        return noteType;
    }

    private static Boolean lookedUp = false;
    private static Schema.SObjectType noteType;

    // Two seams for tests, so that what is done with a Salesforce note is tested the same way in an org
    // with Notes on and in one with it off, where no ContentNote can be made. Neither is set outside a test.
    /** Makes this org read as one with Notes turned off. */
    @TestVisible
    private static Boolean actAsOff = false;
    /** The Salesforce notes on each record, newest first, read in place of the org's own. */
    @TestVisible
    private static Map<Id, List<Entry>> standIns;

    /**
     * Puts a stand-in Salesforce note on a record for a test: what notesOn would read had the note been
     * written in the Notes composer, with its text already Markdown.
     */
    @TestVisible
    private static Id standIn(Id recordId, String title, String body, Datetime writtenAt) {
        if (standIns == null) {
            standIns = new Map<Id, List<Entry>>();
        }
        if (!standIns.containsKey(recordId)) {
            standIns.put(recordId, new List<Entry>());
        }
        List<Entry> onRecord = standIns.get(recordId);
        Integer made = 0;
        for (List<Entry> each : standIns.values()) {
            made += each.size();
        }
        Entry entry = new Entry();
        // Shaped like the Id of a note's file, which is all the code that carries it needs.
        entry.documentId = ContentDocument.SObjectType.getDescribe().getKeyPrefix() + String.valueOf(made + 1).leftPad(12, '0');
        entry.title = title;
        entry.body = body;
        entry.writtenAt = writtenAt;
        entry.editedAt = writtenAt;
        entry.author = UserInfo.getName();
        Integer place = 0;
        // Newest first, and one with no date last.
        while (place < onRecord.size() && (writtenAt == null || onRecord[place].writtenAt > writtenAt)) {
            place++;
        }
        if (place == onRecord.size()) {
            onRecord.add(entry);
        } else {
            onRecord.add(place, entry);
        }
        return entry.documentId;
    }

    /**
     * @description One Salesforce note, with its text as Markdown.
     */
    public class Entry {
        public Id documentId;
        public String title;
        public String body;
        public Datetime writtenAt;
        public Datetime editedAt;
        public String author;
    }

    // Which Salesforce note each unsaved file note made here stands for, for the life of the request.
    private static List<File_Note__c> madeNotes = new List<File_Note__c>();
    private static List<Entry> madeFrom = new List<Entry>();

    /**
     * @description The Salesforce notes attached to a record, newest first.
     * @param recordId The claim, policy or customer
     * @param most How many to return at most
     * @return The notes; empty when there are none or Notes is not in use
     */
    public static List<Entry> notesOn(Id recordId, Integer most) {
        if (standIns == null || actAsOff) {
            return isOn() ? saved(recordId, most) : new List<Entry>();
        }
        List<Entry> entries = new List<Entry>();
        if (standIns.containsKey(recordId)) {
            for (Entry entry : standIns.get(recordId)) {
                if (entries.size() < most) {
                    entries.add(entry);
                }
            }
        }
        return entries;
    }

    /**
     * The notes as the org holds them, newest first. This and the end of create are the only code that
     * needs the ContentNote object, so they are all that goes unrun where Notes is turned off.
     */
    private static List<Entry> saved(Id recordId, Integer most) {
        List<Entry> entries = new List<Entry>();
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId AND ContentDocument.FileType = :FILE_TYPE
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate DESC
            LIMIT :most
        ]) {
            documentIds.add(link.ContentDocumentId);
        }
        if (documentIds.isEmpty()) {
            return entries;
        }
        for (SObject note : Database.queryWithBinds(
            'SELECT Id, Title, Content, CreatedDate, LastModifiedDate, CreatedBy.Name FROM ' + NOTE_OBJECT + ' WHERE Id IN :documentIds ORDER BY CreatedDate DESC',
            new Map<String, Object>{ 'documentIds' => documentIds },
            AccessLevel.USER_MODE
        )) {
            Blob content = (Blob) note.get('Content');
            Entry entry = new Entry();
            entry.documentId = note.Id;
            entry.title = (String) note.get('Title');
            entry.body = toMarkdown(content == null ? '' : content.toString());
            entry.writtenAt = (Datetime) note.get('CreatedDate');
            entry.editedAt = (Datetime) note.get('LastModifiedDate');
            entry.author = (String) note.getSObject('CreatedBy')?.get('Name');
            entries.add(entry);
        }
        return entries;
    }

    /**
     * @description A record's Salesforce notes in the shape of file notes, for code that reads a claim's
     * notes as evidence. They are not saved and have no Id.
     * @param recordId The claim
     * @param most How many to return at most
     * @return One unsaved File_Note__c for each Salesforce note, oldest first
     */
    public static List<File_Note__c> asFileNotes(Id recordId, Integer most) {
        List<File_Note__c> notes = new List<File_Note__c>();
        for (Entry entry : notesOn(recordId, most)) {
            // As evidence the title leads into the text ("Plumber statement: The fitting failed."), so one line of it says what it is.
            String body = withTitle(entry);
            String opening = body.substringBefore('\n');
            String lead = plain(opening);
            if (body.contains('\n') && lead.equalsIgnoreCase(plain(entry.title))) {
                // A title that is already a sentence keeps its own stop: "The shop called back." takes no colon after it.
                body = '**' + lead + (lead.right(1).containsAny('.:!?') ? '' : ':') + '**' + body.substring(opening.length());
            }
            File_Note__c note = new File_Note__c(Note_Type__c = NOTE_TYPE, Note_Date__c = entry.writtenAt, Author_Name__c = entry.author, Body__c = body);
            madeNotes.add(note);
            madeFrom.add(entry);
            // Newest first becomes oldest first, the order a file is read in.
            if (notes.isEmpty()) {
                notes.add(note);
            } else {
                notes.add(0, note);
            }
        }
        return notes;
    }

    /**
     * @description The Salesforce note an unsaved file note from asFileNotes stands for: where its Id
     * and its last edit are, which a file note that was never saved cannot carry.
     * @param note A note from asFileNotes or withFileNotes, the same one and not a copy
     * @return The Salesforce note, or null for a file note of the claim's own
     */
    public static Entry entryOf(File_Note__c note) {
        if (note == null || note.Id != null) {
            return null;
        }
        for (Integer i = 0; i < madeNotes.size(); i++) {
            if (madeNotes[i] === note) {
                return madeFrom[i];
            }
        }
        return null;
    }

    /**
     * @description A record's file notes and its Salesforce notes as one list by date, newest first:
     * the order a prompt reads a file's notes in.
     * @param fileNotes The record's file notes, newest first, with Note_Date__c and CreatedDate
     * @param recordId The claim
     * @param most How many Salesforce notes to read, and how many notes to return, at most
     * @return The notes; the Salesforce notes among them are unsaved (see asFileNotes and entryOf)
     */
    public static List<File_Note__c> withFileNotes(List<File_Note__c> fileNotes, Id recordId, Integer most) {
        List<File_Note__c> own = fileNotes == null ? new List<File_Note__c>() : fileNotes;
        List<File_Note__c> theirs = asFileNotes(recordId, most);
        List<File_Note__c> notes = new List<File_Note__c>();
        Integer next = 0;
        // The Salesforce notes come oldest first, so they are taken from the end.
        Integer last = theirs.size() - 1;
        while (notes.size() < most && (next < own.size() || last >= 0)) {
            Datetime ownDate = next >= own.size() ? null : own[next].Note_Date__c == null ? own[next].CreatedDate : own[next].Note_Date__c;
            Boolean takeTheirs = last >= 0 && (next >= own.size() || ownDate == null || theirs[last].Note_Date__c >= ownDate);
            if (takeTheirs) {
                notes.add(theirs[last]);
                last--;
            } else {
                notes.add(own[next]);
                next++;
            }
        }
        return notes;
    }

    /**
     * @description The type a note is listed under where notes are written out for Claude: a file
     * note's own type, and "Salesforce note" for a note from Salesforce Notes.
     * @param note A note from withFileNotes
     * @return The type, or null for a file note with none
     */
    public static String typeLabel(File_Note__c note) {
        return entryOf(note) == null ? note.Note_Type__c : NOTE_TYPE + ' note';
    }

    /**
     * @description How many of the notes are Salesforce notes. A brief or a coverage check keeps the
     * number with the facts it was written from (under COUNT_KEY), which also marks it as written
     * since Salesforce notes were read as notes.
     * @param notes Notes from withFileNotes
     * @return The number that stand for a Salesforce note
     */
    public static Integer countIn(List<File_Note__c> notes) {
        Integer total = 0;
        for (File_Note__c note : notes) {
            total += entryOf(note) == null ? 0 : 1;
        }
        return total;
    }

    /**
     * @description The number of documents a brief or a coverage check was written with, for comparing
     * with today's. One written before Salesforce notes were read as notes counted each as a document.
     * Reading those as notes now is no document removed, so a count that is higher than today's by no
     * more than the Salesforce notes on the claim reads as today's. The notes themselves show as new.
     * @param before The facts kept with the brief or check
     * @param now The same facts today, with the number of Salesforce notes under COUNT_KEY
     * @param key The name the number of documents is kept under
     * @return The number to compare with today's
     */
    public static Object documentsThen(Map<String, Object> before, Map<String, Object> now, String key) {
        Decimal was = AntsuranceAiClient.toDecimal(before.get(key));
        Decimal isNow = AntsuranceAiClient.toDecimal(now.get(key));
        Decimal notes = AntsuranceAiClient.toDecimal(now.get(COUNT_KEY));
        Boolean countedNotes = !before.containsKey(COUNT_KEY) && was != null && isNow != null && notes != null && was > isNow && was - isNow <= notes;
        return countedNotes ? now.get(key) : before.get(key);
    }

    /**
     * @description A Salesforce note's text for the file: its title in bold above its body, unless the
     * body already opens with the title.
     * @param entry The note
     * @return Markdown
     */
    public static String withTitle(Entry entry) {
        String body = String.isBlank(entry.body) ? '' : entry.body.trim();
        String title = String.isBlank(entry.title) ? '' : entry.title.trim();
        if (String.isBlank(title) || plain(body).startsWithIgnoreCase(title.removeEnd('...'))) {
            return body;
        }
        return String.isBlank(body) ? '**' + title + '**' : '**' + title + '**\n\n' + body;
    }

    /**
     * @description Saves text written here as a Salesforce note on a record, so it also shows in
     * Salesforce's own Notes.
     * @param recordId The claim, policy or customer
     * @param markdown The note as written, which may use Markdown
     * @return The new note's Id
     * @throws NotesOffException when the org has Notes turned off
     */
    public static Id create(Id recordId, String markdown) {
        if (!isOn()) {
            throw new NotesOffException(NOTES_OFF);
        }
        String title = titleOf(markdown);
        Blob content = Blob.valueOf(toHtml(markdown));
        // From here on the ContentNote object is needed.
        SObject note = noteObject().newSObject();
        note.put('Title', title);
        note.put('Content', content);
        Database.insert(note, AccessLevel.USER_MODE);
        insert as user new ContentDocumentLink(ContentDocumentId = note.Id, LinkedEntityId = recordId, ShareType = 'I');
        return note.Id;
    }

    /**
     * @description The HTML of a Salesforce note as Markdown: paragraphs, line breaks, bold, italic,
     * lists, headings and links. Anything else is kept as its words.
     * @param html The note's content
     * @return Markdown
     */
    public static String toMarkdown(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String text = html.replaceAll('\\r', '').replaceAll('\\n', ' ');
        text = text.replaceAll('(?i)<br\\s*/?>', '\n');
        text = text.replaceAll('(?i)<a\\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>', '[$2]($1)');
        text = text.replaceAll('(?i)</?(b|strong)(\\s[^>]*)?>', '**');
        text = text.replaceAll('(?i)</?(i|em)(\\s[^>]*)?>', '*');
        text = text.replaceAll('(?i)<h[1-6](\\s[^>]*)?>', '\n\n**').replaceAll('(?i)</h[1-6]>', '**\n\n');
        text = text.replaceAll('(?i)<li(\\s[^>]*)?>', '\n- ').replaceAll('(?i)</li>', '');
        text = text.replaceAll('(?i)</?(ul|ol)(\\s[^>]*)?>', '\n\n');
        text = text.replaceAll('(?i)<p(\\s[^>]*)?>', '').replaceAll('(?i)</p>', '\n\n');
        text = text.replaceAll('<[^>]+>', '');
        text = text.unescapeHtml4().replace(' ', ' ');
        // An emphasis mark left around nothing ("****") came from an empty tag.
        text = text.replaceAll('\\*\\*\\s*\\*\\*', '').replaceAll('[ \\t]+\\n', '\n').replaceAll('\\n{3,}', '\n\n');
        return text.trim();
    }

    /**
     * @description Markdown as the HTML a Salesforce note stores: paragraphs, lists, bold and italic,
     * with everything else escaped.
     * @param markdown The note as written
     * @return HTML
     */
    public static String toHtml(String markdown) {
        String html = '';
        Boolean inList = false;
        for (String line : (markdown == null ? '' : markdown).replace('\r', '').split('\n')) {
            String words = line.trim();
            Matcher bullet = Pattern.compile('^(?:[-+*]|\\d+[.)])\\s+(.*)$').matcher(words);
            Boolean isItem = bullet.matches();
            if (inList && !isItem) {
                html += '</ul>';
                inList = false;
            }
            if (String.isBlank(words)) {
                continue;
            }
            if (isItem) {
                html += (inList ? '' : '<ul>') + '<li>' + inline(bullet.group(1)) + '</li>';
                inList = true;
            } else {
                html += '<p>' + inline(words.replaceAll('^#{1,6}\\s+', '')) + '</p>';
            }
        }
        return html + (inList ? '</ul>' : '');
    }

    /** One line's words, escaped the way a Salesforce note requires, with bold and italic carried over. */
    private static String inline(String words) {
        String safe = words.escapeHtml4().replace('\'', '&#39;');
        return safe.replaceAll('\\*\\*(.+?)\\*\\*', '<b>$1</b>').replaceAll('(?<![*\\w])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![*\\w])', '<i>$1</i>');
    }

    /** A note's title: its first line as plain words, cut at a whole word. */
    @TestVisible
    private static String titleOf(String markdown) {
        for (String line : (markdown == null ? '' : markdown).split('\n')) {
            String words = plain(line);
            if (String.isNotBlank(words)) {
                return words.length() <= MAX_TITLE ? words : words.left(MAX_TITLE).substringBeforeLast(' ') + '...';
            }
        }
        return UNTITLED;
    }

    /** Markdown with its marks taken off. */
    private static String plain(String markdown) {
        return (markdown == null ? '' : markdown).replaceAll('^\\s*(?:[-+*]|\\d+[.)]|#{1,6})\\s+', '').replaceAll('[*_`]', '').trim();
    }
}
