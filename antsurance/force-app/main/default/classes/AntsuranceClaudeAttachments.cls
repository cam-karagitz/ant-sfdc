/**
 * @description Photos and PDFs attached to a message in the Ask Claude chat.
 *
 * The chat keeps a conversation as text. A file in it is a small reference block
 * ({type: attachment, id, name, media_type}); the file itself travels beside the conversation, base64
 * encoded, only while it belongs to the latest message that carried files. Here the references are
 * turned into what the Messages API takes: an image or document block for a file that came with this
 * request, and a line of text for one that did not, so Claude knows it was there and can ask for it again.
 *
 * Why the file is kept out of the conversation JSON: Apex has 6 MB of heap in a request. Parsing and
 * re-serializing a conversation with a file in it would hold the file four times over. This way it is
 * held twice: once as it arrived and once in the request body, where it is dropped into a placeholder
 * after the rest of the body has been serialized.
 *
 * Nothing here stores a file. A file on a record can be handed to the page (load) so it travels the
 * same way as an uploaded one.
 */
public with sharing class AntsuranceClaudeAttachments {
    /** Files on one message. */
    public static final Integer MAX_FILES = 4;
    /** A photo after the browser has redrawn it at 1,568 pixels on its longest side. */
    public static final Integer MAX_IMAGE_BYTES = 600000;
    public static final Integer MAX_PDF_BYTES = 900000;
    /** Every file on one message together. About 1.6 MB as base64, held twice: 3.2 MB of the 6 MB heap. */
    public static final Integer MAX_TOTAL_BYTES = 1200000;
    /** The largest photo on a record that is handed to the page, which redraws it smaller before sending. */
    public static final Integer MAX_RECORD_PHOTO_BYTES = 2500000;
    private static final Integer MAX_RECORD_FILES = 30;

    private static final String REFERENCE = 'attachment';
    private static final String PDF = 'application/pdf';
    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'image/jpeg', 'image/png', 'image/gif', 'image/webp' };
    private static final Map<String, String> TYPE_BY_EXTENSION = new Map<String, String>{
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'pdf' => PDF
    };
    // Stands where a file's base64 goes until the rest of the request has been serialized.
    private static final String MARK = '@@FILE:';
    private static final String MARK_END = '@@';

    @TestVisible
    private static final String TOO_MANY = 'A message can carry up to ' + MAX_FILES + ' files. Remove one and send again.';
    @TestVisible
    private static final String WRONG_KIND = 'Claude can read photos (JPEG, PNG, WebP, GIF) and PDFs here. That file is something else.';
    @TestVisible
    private static final String PHOTO_TOO_LARGE = 'That photo is too large to send, even after shrinking it. Try a smaller copy.';
    @TestVisible
    private static final String PDF_TOO_LARGE = 'That PDF is too large to send from here. The limit is ' + megabytes(MAX_PDF_BYTES) + '.';
    @TestVisible
    private static final String TOO_MUCH = 'Those files are too large to send together. The limit is ' + megabytes(MAX_TOTAL_BYTES) + ' for one message.';
    @TestVisible
    private static final String UNREADABLE = 'One of the files could not be read. Remove it and attach it again.';
    private static final String NOT_ON_RECORD = 'That file is not on this record, or you do not have access to it.';
    private static final String RECORD_FILE_TOO_LARGE = 'Too large to send from here';

    /** A message the person can act on: which file, and what to do about it. */
    public class AttachmentException extends Exception {
    }

    /**
     * @description The files that came with a request, checked, and where each one goes in the body.
     */
    public class Carried {
        private final List<String> ids;
        private final List<String> types;
        private final List<String> data;
        // The files placed in the conversation, in the order their placeholders appear in it.
        private final List<Integer> placed = new List<Integer>();

        private Carried(List<String> ids, List<String> types, List<String> data) {
            this.ids = ids;
            this.types = types;
            this.data = data;
        }

        /** Whether any file was placed in the conversation and so has to be dropped into the body. */
        public Boolean hasPlaced() {
            return !placed.isEmpty();
        }
    }

    /**
     * @description A photo or PDF on a record, as the chat lists it.
     */
    public class RecordFile {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String mediaType;
        /** 'image' or 'pdf'. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public Integer bytes;
        @AuraEnabled
        public String sizeLabel;
        /** Set when the file is listed but cannot be sent, with why. */
        @AuraEnabled
        public String whyNot;
        /** The file, base64 encoded. Only on a file that was asked for (load). */
        @AuraEnabled
        public String data;
    }

    /**
     * @description Checks the files that came with a request against the limits.
     * @param ids The reference ids, as the conversation names them
     * @param types Each file's MIME type
     * @param data Each file, base64 encoded
     * @return The files, ready to place; never null
     * @throws AttachmentException with what to do when there are too many, one is the wrong kind or one is too large
     */
    public static Carried read(List<String> ids, List<String> types, List<String> data) {
        List<String> fileIds = ids == null ? new List<String>() : ids;
        List<String> fileTypes = types == null ? new List<String>() : types;
        List<String> fileData = data == null ? new List<String>() : data;
        if (fileIds.size() != fileTypes.size() || fileIds.size() != fileData.size()) {
            throw new AttachmentException(UNREADABLE);
        }
        if (fileIds.size() > MAX_FILES) {
            throw new AttachmentException(TOO_MANY);
        }
        Integer total = 0;
        for (Integer index = 0; index < fileIds.size(); index++) {
            String type = fileTypes[index];
            String encoded = fileData[index];
            Boolean isPdf = type == PDF;
            if (!isPdf && !IMAGE_TYPES.contains(type)) {
                throw new AttachmentException(WRONG_KIND);
            }
            // The file is dropped into the request as it is, so it must be base64 and nothing else.
            if (String.isBlank(fileIds[index]) || String.isBlank(encoded) || encoded.contains('"') || encoded.contains('\\') || encoded.contains('\n')) {
                throw new AttachmentException(UNREADABLE);
            }
            Integer bytes = decodedBytes(encoded);
            if (bytes > (isPdf ? MAX_PDF_BYTES : MAX_IMAGE_BYTES)) {
                throw new AttachmentException(isPdf ? PDF_TOO_LARGE : PHOTO_TOO_LARGE);
            }
            total += bytes;
        }
        if (total > MAX_TOTAL_BYTES) {
            throw new AttachmentException(TOO_MUCH);
        }
        return new Carried(fileIds, fileTypes, fileData);
    }

    /**
     * @description Turns the conversation's file references into what the Messages API takes. A file that came
     * with this request becomes its name and an image or document block holding a placeholder; one
     * that did not becomes a line saying it was there. The conversation is changed in place.
     * @param conversation Messages API turns, as parsed from the chat
     * @param carried The files that came with this request, from read
     */
    public static void place(List<Object> conversation, Carried carried) {
        for (Object item : conversation) {
            Map<String, Object> message = (Map<String, Object>) item;
            if (message.get('role') != 'user' || !(message.get('content') instanceof List<Object>)) {
                continue;
            }
            List<Object> placed = new List<Object>();
            Boolean changed = false;
            for (Object part : (List<Object>) message.get('content')) {
                Map<String, Object> block = (Map<String, Object>) part;
                if (block.get('type') != REFERENCE) {
                    placed.add(block);
                    continue;
                }
                changed = true;
                String name = block.get('name') == null ? 'a file' : '"' + block.get('name') + '"';
                Integer position = carried.ids.indexOf((String) block.get('id'));
                if (position < 0) {
                    placed.add(textBlock(
                        '[The user attached ' + name + ' here. The file itself is no longer sent with the conversation, so you cannot look at it again. ' +
                        'If a question needs it, say so and ask them to attach it again.]'
                    ));
                    continue;
                }
                Boolean isPdf = carried.types[position] == PDF;
                placed.add(textBlock('Attached ' + (isPdf ? 'PDF' : 'photo') + ': ' + name));
                placed.add(new Map<String, Object>{
                    'type' => isPdf ? 'document' : 'image',
                    'source' => new Map<String, Object>{
                        'type' => 'base64',
                        'media_type' => carried.types[position],
                        'data' => MARK + carried.placed.size() + MARK_END
                    }
                });
                carried.placed.add(position);
            }
            if (changed) {
                message.put('content', placed);
            }
        }
    }

    /**
     * @description Drops each placed file into the serialized request where its placeholder stands, in one pass, so
     * the request is built once and no file is copied more than that.
     * @param serialized The request body as JSON, placeholders in it
     * @param carried The files, from read, after place
     * @return The request body with the files in it
     */
    public static String withFiles(String serialized, Carried carried) {
        if (carried == null || carried.placed.isEmpty()) {
            return serialized;
        }
        List<String> pieces = new List<String>();
        String rest = serialized;
        for (Integer index = 0; index < carried.placed.size(); index++) {
            // The key and the value together: a user cannot type this pair unescaped into their own message.
            String slot = '"data":"' + MARK + index + MARK_END + '"';
            Integer at = rest.indexOf(slot);
            if (at < 0) {
                continue;
            }
            pieces.add(rest.substring(0, at));
            pieces.add('"data":"');
            pieces.add(carried.data[carried.placed[index]]);
            pieces.add('"');
            rest = rest.substring(at + slot.length());
        }
        pieces.add(rest);
        return String.join(pieces, '');
    }

    /**
     * @description Lists the photos and PDFs on a record that this user can see, newest first.
     * @param recordId The record on screen
     * @return The files Claude could read; one that is too large is listed with why it cannot be sent
     */
    public static List<RecordFile> listFor(Id recordId) {
        List<RecordFile> files = new List<RecordFile>();
        if (recordId == null) {
            return files;
        }
        for (ContentDocumentLink link : linksOn(recordId, null)) {
            RecordFile file = describe(link);
            if (file != null) {
                files.add(file);
            }
        }
        return files;
    }

    /**
     * @description Hands one of a record's files to the page, so it can be attached like an uploaded one.
     * @param recordId The record on screen
     * @param documentId The file (ContentDocument)
     * @return The file with its contents, base64 encoded
     * @throws AttachmentException when the file is not on the record, is not a photo or PDF, or is too large
     */
    public static RecordFile load(Id recordId, Id documentId) {
        List<ContentDocumentLink> links = recordId == null || documentId == null ? new List<ContentDocumentLink>() : linksOn(recordId, documentId);
        RecordFile file = links.isEmpty() ? null : describe(links[0]);
        if (file == null) {
            throw new AttachmentException(NOT_ON_RECORD);
        }
        if (file.whyNot != null) {
            throw new AttachmentException('"' + file.name + '" cannot be sent: ' + file.whyNot.toLowerCase() + '.');
        }
        try {
            Id versionId = links[0].ContentDocument.LatestPublishedVersionId;
            file.data = EncodingUtil.base64Encode([SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1].VersionData);
        } catch (QueryException e) {
            throw new AttachmentException(NOT_ON_RECORD);
        }
        return file;
    }

    private static List<ContentDocumentLink> linksOn(Id recordId, Id documentId) {
        String filter = documentId == null ? '' : ' AND ContentDocumentId = :documentId';
        Map<String, Object> binds = new Map<String, Object>{ 'recordId' => recordId };
        if (documentId != null) {
            binds.put('documentId', documentId);
        }
        try {
            return (List<ContentDocumentLink>) Database.queryWithBinds(
                'SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId ' +
                // A Salesforce note is a file to the platform (type SNOTE) and a note to a person: it is not offered as a file to attach.
                'FROM ContentDocumentLink WHERE LinkedEntityId = :recordId AND ContentDocument.FileType != \'SNOTE\'' + filter +
                ' ORDER BY ContentDocument.CreatedDate DESC LIMIT ' + MAX_RECORD_FILES,
                binds,
                AccessLevel.USER_MODE
            );
        } catch (QueryException e) {
            // No access to files, or to this record: there is nothing to offer.
            return new List<ContentDocumentLink>();
        }
    }

    /** A file as the chat lists it, or null when it is not a photo or a PDF. */
    private static RecordFile describe(ContentDocumentLink link) {
        String extension = link.ContentDocument.FileExtension == null ? '' : link.ContentDocument.FileExtension.toLowerCase();
        String type = TYPE_BY_EXTENSION.get(extension);
        if (type == null) {
            return null;
        }
        RecordFile file = new RecordFile();
        file.documentId = link.ContentDocumentId;
        file.name = link.ContentDocument.Title;
        file.mediaType = type;
        file.kind = type == PDF ? 'pdf' : 'image';
        file.bytes = link.ContentDocument.ContentSize;
        file.sizeLabel = megabytes(file.bytes);
        if (file.bytes > (type == PDF ? MAX_PDF_BYTES : MAX_RECORD_PHOTO_BYTES)) {
            file.whyNot = RECORD_FILE_TOO_LARGE;
        }
        return file;
    }

    private static Map<String, Object> textBlock(String text) {
        return new Map<String, Object>{ 'type' => 'text', 'text' => text };
    }

    /** How many bytes a base64 string decodes to, without decoding it. */
    private static Integer decodedBytes(String encoded) {
        Integer padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
        return (encoded.length() / 4) * 3 - padding;
    }

    private static String megabytes(Integer bytes) {
        if (bytes < 1000000) {
            return Math.max(1, Math.round(bytes / 1000.0)) + ' KB';
        }
        return (Decimal.valueOf(bytes) / 1000000).setScale(1) + ' MB';
    }
}
