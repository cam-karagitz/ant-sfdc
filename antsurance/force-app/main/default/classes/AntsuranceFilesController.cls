/**
 * @description The files saved on a record, for the Documents tab: what each one is, how big it is,
 * when it was saved and by whom. A note written in Salesforce Notes is a file to the platform and a
 * note to a person, so it is not listed. Everything is limited to what the running user can see.
 */
public with sharing class AntsuranceFilesController {
    @TestVisible
    private static final Integer MOST_SHOWN = 50;
    private static final String LOAD_ERROR = 'The files on this record could not be loaded. Check your access to files.';

    /**
     * @description One saved file.
     */
    public class FileRow {
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public String title;
        /** The file's type as its extension, in lower case: pdf, jpg, docx. */
        @AuraEnabled
        public String extension;
        /** Size in bytes. */
        @AuraEnabled
        public Integer size;
        @AuraEnabled
        public Datetime savedAt;
        @AuraEnabled
        public String savedBy;
    }

    /**
     * @description The files attached to a record, newest first.
     * @param recordId The policy, policy sale, customer or any other record with files
     * @return Up to 50 files; an empty list when there are none or no record is given
     * @throws AuraHandledException when the user cannot read files
     */
    @AuraEnabled(cacheable=true)
    public static List<FileRow> getFiles(Id recordId) {
        List<FileRow> rows = new List<FileRow>();
        if (recordId == null) {
            return rows;
        }
        try {
            for (ContentDocumentLink link : [
                SELECT
                    ContentDocumentId,
                    ContentDocument.Title,
                    ContentDocument.FileExtension,
                    ContentDocument.ContentSize,
                    ContentDocument.CreatedDate,
                    ContentDocument.CreatedBy.Name
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT :MOST_SHOWN
            ]) {
                FileRow row = new FileRow();
                row.contentDocumentId = link.ContentDocumentId;
                row.title = link.ContentDocument.Title;
                row.extension = link.ContentDocument.FileExtension?.toLowerCase();
                row.size = link.ContentDocument.ContentSize;
                row.savedAt = link.ContentDocument.CreatedDate;
                row.savedBy = link.ContentDocument.CreatedBy.Name;
                rows.add(row);
            }
        } catch (QueryException e) {
            AuraHandledException handled = new AuraHandledException(LOAD_ERROR);
            handled.setMessage(LOAD_ERROR);
            throw handled;
        }
        return rows;
    }
}
