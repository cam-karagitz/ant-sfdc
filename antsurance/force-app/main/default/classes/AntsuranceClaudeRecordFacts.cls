/**
 * @description Reads the key facts of the record a user has open, with its most relevant related
 * rows, so the chat can answer "summarize this record" and similar without a lookup round.
 * Everything is read with the user's own access; a record or field they cannot see yields no facts.
 * Which fields and related rows make up a record's facts depends on the org's data model, so the
 * query comes from AntsuranceClaudeModel, which may also add to what it returns.
 */
public with sharing class AntsuranceClaudeRecordFacts {
    // Written notes and descriptions are shortened to whole sentences within this length; Claude can query for the full text.
    private static final Integer MAX_TEXT = 800;
    // Text that is JSON (a quote's stored answers, say) is not prose: it is cut at a length, longer, and marked as cut.
    private static final String JSON_OPENING = '{"';
    private static final Integer MAX_JSON = 1500;
    @TestVisible
    private static final String INTRO =
        'Facts about the open record and its related rows, read just now as this user (JSON; empty fields are left out). ' +
        'Long text is shortened to its opening sentences. Answer from these when they are enough, and query only for what they do not cover.\n';

    // Files on the record, newest first, so the chat knows an estimate or invoice has arrived. Names only: the chat does not read them.
    // A Salesforce note is a file to the platform (type SNOTE) and is left out: it is a note, not a document that arrived.
    private static final String ATTACHED_FILES =
        'SELECT ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.CreatedDate FROM ContentDocumentLink ' +
        'WHERE LinkedEntityId = :recordId AND ContentDocument.FileType != \'SNOTE\' ORDER BY ContentDocument.CreatedDate DESC LIMIT 10';

    /**
     * @description The open record's facts as a short note for Claude.
     * @param recordId The record on screen
     * @return The note, or null when there is no record, the object has no facts query, or the user cannot read it
     */
    public static String describe(Id recordId) {
        if (recordId == null) {
            return null;
        }
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        String soql = model.factsQuery(recordId.getSObjectType().getDescribe().getName());
        if (soql == null) {
            return null;
        }
        try {
            List<SObject> records = Database.queryWithBinds(soql + ' WHERE Id = :recordId LIMIT 1', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
            if (records.isEmpty()) {
                return null;
            }
            Map<String, Object> facts = toPlainMap(records[0]);
            model.addFacts(facts, records[0]);
            addAttachedFiles(facts, recordId);
            return INTRO + JSON.serialize(facts);
        } catch (QueryException e) {
            return null;
        }
    }

    private static void addAttachedFiles(Map<String, Object> facts, Id recordId) {
        List<Object> files = new List<Object>();
        for (ContentDocumentLink link : (List<ContentDocumentLink>) Database.queryWithBinds(ATTACHED_FILES, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE)) {
            files.add(
                new Map<String, Object>{
                    'Title' => link.ContentDocument.Title,
                    'Type' => link.ContentDocument.FileExtension,
                    'AddedOn' => link.ContentDocument.CreatedDate.date()
                }
            );
        }
        if (!files.isEmpty()) {
            facts.put('AttachedFiles', files);
        }
    }

    /**
     * @description Text shortened to whole sentences, with nothing added to show where it stopped, so
     * Claude is never handed half a sentence to remark on.
     * @param text The text
     * @param max The most characters to keep
     * @return The text, or its opening sentences
     */
    public static String excerpt(String text, Integer max) {
        if (text == null || text.length() <= max) {
            return text;
        }
        String cut = text.left(max);
        Integer stop = Math.max(Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('.\n')), cut.lastIndexOf('\n'));
        if (stop > max / 3) {
            return cut.left(stop + 1).trim();
        }
        Integer space = cut.lastIndexOf(' ');
        return (space > 0 ? cut.left(space) : cut).trim();
    }

    /**
     * @description Field values without the attributes wrapper or empty fields, following parent and child relationships.
     * @param record A record as a query returned it
     * @return Its populated fields by name, with long text shortened
     */
    public static Map<String, Object> toPlainMap(SObject record) {
        Map<String, Object> plain = new Map<String, Object>();
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        for (String fieldName : populated.keySet()) {
            Object value = populated.get(fieldName);
            // Check the list first: in Apex a List<SObject> also reports instanceof SObject.
            if (value instanceof List<SObject>) {
                List<Object> children = new List<Object>();
                for (SObject child : (List<SObject>) value) {
                    children.add(toPlainMap(child));
                }
                plain.put(fieldName, children);
            } else if (value instanceof SObject) {
                plain.put(fieldName, toPlainMap((SObject) value));
            } else if (value instanceof String) {
                plain.put(fieldName, ((String) value).startsWith(JSON_OPENING) ? ((String) value).abbreviate(MAX_JSON) : excerpt((String) value, MAX_TEXT));
            } else if (value != null) {
                plain.put(fieldName, value);
            }
        }
        return plain;
    }
}
