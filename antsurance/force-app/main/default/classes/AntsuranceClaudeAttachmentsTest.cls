@IsTest
private class AntsuranceClaudeAttachmentsTest {
    private static final String JPEG = 'image/jpeg';
    private static final String PDF = 'application/pdf';
    // Four base64 characters hold three bytes.
    private static final String SMALL = 'QUJD';

    private static String encodedOfBytes(Integer bytes) {
        return 'A'.repeat((bytes / 3) * 4);
    }

    private static String refusal(List<String> ids, List<String> types, List<String> data) {
        try {
            AntsuranceClaudeAttachments.read(ids, types, data);
            Assert.fail('Expected the files to be refused');
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            return e.getMessage();
        }
        return null;
    }

    private static List<Object> conversationWith(List<Object> content) {
        return new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } };
    }

    private static Map<String, Object> reference(String id, String name) {
        return new Map<String, Object>{ 'type' => 'attachment', 'id' => id, 'name' => name, 'media_type' => JPEG };
    }

    private static Map<String, Object> typed(String text) {
        return new Map<String, Object>{ 'type' => 'text', 'text' => text };
    }

    @TestSetup
    static void createRecordWithFiles() {
        Account customer = new Account(Name = 'Harbor Mutual');
        insert customer;
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Roof after the storm', PathOnClient = 'roof.JPG', VersionData = Blob.valueOf('photo bytes'), FirstPublishLocationId = customer.Id),
            new ContentVersion(Title = 'Repair estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('pdf bytes'), FirstPublishLocationId = customer.Id),
            new ContentVersion(Title = 'Adjuster notes', PathOnClient = 'notes.txt', VersionData = Blob.valueOf('plain text'), FirstPublishLocationId = customer.Id)
        };
    }

    @IsTest
    static void aRequestWithNoFilesCarriesNothing() {
        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(null, null, null);

        Assert.isFalse(carried.hasPlaced(), 'Nothing is placed when nothing came');
        Assert.areEqual('{"a":1}', AntsuranceClaudeAttachments.withFiles('{"a":1}', carried), 'The request is left as it is');
    }

    @IsTest
    static void moreFilesThanTheLimitAreRefused() {
        List<String> ids = new List<String>();
        List<String> types = new List<String>();
        List<String> data = new List<String>();
        for (Integer index = 0; index <= AntsuranceClaudeAttachments.MAX_FILES; index++) {
            ids.add('f' + index);
            types.add(JPEG);
            data.add(SMALL);
        }

        Assert.areEqual(AntsuranceClaudeAttachments.TOO_MANY, refusal(ids, types, data), 'Says how many a message can carry');
    }

    @IsTest
    static void aFileThatIsNotAPhotoOrPdfIsRefused() {
        String message = refusal(new List<String>{ 'f1' }, new List<String>{ 'video/mp4' }, new List<String>{ SMALL });

        Assert.areEqual(AntsuranceClaudeAttachments.WRONG_KIND, message, 'Says which kinds of file can be read');
    }

    @IsTest
    static void aPhotoOverItsLimitIsRefused() {
        String tooLarge = encodedOfBytes(AntsuranceClaudeAttachments.MAX_IMAGE_BYTES + 3);

        Assert.areEqual(
            AntsuranceClaudeAttachments.PHOTO_TOO_LARGE,
            refusal(new List<String>{ 'f1' }, new List<String>{ JPEG }, new List<String>{ tooLarge }),
            'A photo larger than the limit is not sent'
        );
    }

    @IsTest
    static void aPdfOverItsLimitIsRefused() {
        String tooLarge = encodedOfBytes(AntsuranceClaudeAttachments.MAX_PDF_BYTES + 3);

        Assert.areEqual(
            AntsuranceClaudeAttachments.PDF_TOO_LARGE,
            refusal(new List<String>{ 'f1' }, new List<String>{ PDF }, new List<String>{ tooLarge }),
            'A PDF larger than the limit is not sent'
        );
    }

    @IsTest
    static void filesThatAreTooLargeTogetherAreRefused() {
        // Each is within its own limit; together they pass the limit for one message.
        // Apex names ignore case, so this cannot be called pdf beside the PDF constant.
        String large = encodedOfBytes(AntsuranceClaudeAttachments.MAX_PDF_BYTES - 90000);

        Assert.areEqual(
            AntsuranceClaudeAttachments.TOO_MUCH,
            refusal(new List<String>{ 'f1', 'f2' }, new List<String>{ PDF, PDF }, new List<String>{ large, large }),
            'The total for one message is checked as well as each file'
        );
    }

    @IsTest
    static void aFileAtItsLimitIsAccepted() {
        String atLimit = encodedOfBytes(AntsuranceClaudeAttachments.MAX_IMAGE_BYTES);

        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(new List<String>{ 'f1' }, new List<String>{ JPEG }, new List<String>{ atLimit });

        Assert.isNotNull(carried, 'A photo exactly at the limit is sent');
    }

    @IsTest
    static void listsOfDifferentLengthsAreRefused() {
        Assert.areEqual(
            AntsuranceClaudeAttachments.UNREADABLE,
            refusal(new List<String>{ 'f1', 'f2' }, new List<String>{ JPEG }, new List<String>{ SMALL }),
            'Each file needs its id, its type and its contents'
        );
    }

    @IsTest
    static void contentsThatAreNotBase64AreRefused() {
        Assert.areEqual(
            AntsuranceClaudeAttachments.UNREADABLE,
            refusal(new List<String>{ 'f1' }, new List<String>{ JPEG }, new List<String>{ 'QUJD","type":"text' }),
            'Nothing but base64 may be dropped into the request'
        );
    }

    @IsTest
    static void aFileThatCameIsPlacedWhereItsReferenceStood() {
        List<Object> conversation = conversationWith(new List<Object>{ reference('f1', 'roof.jpg'), typed('What happened here?') });
        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(new List<String>{ 'f1' }, new List<String>{ JPEG }, new List<String>{ SMALL });

        Test.startTest();
        AntsuranceClaudeAttachments.place(conversation, carried);
        String body = AntsuranceClaudeAttachments.withFiles(JSON.serialize(conversation), carried);
        Test.stopTest();

        Assert.isTrue(carried.hasPlaced(), 'The file was placed');
        List<Object> content = (List<Object>) ((Map<String, Object>) ((List<Object>) JSON.deserializeUntyped(body))[0]).get('content');
        Assert.areEqual(3, content.size(), 'Its name, the photo, then the question');
        Assert.areEqual('Attached photo: "roof.jpg"', ((Map<String, Object>) content[0]).get('text'), 'Claude is told the file\'s name');
        Map<String, Object> image = (Map<String, Object>) content[1];
        Assert.areEqual('image', image.get('type'), 'A photo is an image block');
        Map<String, Object> source = (Map<String, Object>) image.get('source');
        Assert.areEqual('base64', source.get('type'), 'Sent as base64');
        Assert.areEqual(JPEG, source.get('media_type'), 'With its type');
        Assert.areEqual(SMALL, source.get('data'), 'The file is dropped in where its placeholder stood');
        Assert.areEqual('What happened here?', ((Map<String, Object>) content[2]).get('text'), 'The question follows the file');
    }

    @IsTest
    static void aPdfIsPlacedAsADocument() {
        List<Object> conversation = conversationWith(new List<Object>{ reference('f1', 'estimate.pdf'), typed('Total?') });
        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(new List<String>{ 'f1' }, new List<String>{ PDF }, new List<String>{ SMALL });

        AntsuranceClaudeAttachments.place(conversation, carried);

        List<Object> content = (List<Object>) ((Map<String, Object>) conversation[0]).get('content');
        Assert.areEqual('Attached PDF: "estimate.pdf"', ((Map<String, Object>) content[0]).get('text'), 'Named as a PDF');
        Assert.areEqual('document', ((Map<String, Object>) content[1]).get('type'), 'A PDF is a document block');
    }

    @IsTest
    static void aFileThatDidNotComeIsToldByName() {
        List<Object> conversation = conversationWith(new List<Object>{ reference('old', 'roof.jpg'), typed('And the gutters?') });
        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(null, null, null);

        AntsuranceClaudeAttachments.place(conversation, carried);

        List<Object> content = (List<Object>) ((Map<String, Object>) conversation[0]).get('content');
        Assert.areEqual(2, content.size(), 'A note in place of the file, then the question');
        String note = (String) ((Map<String, Object>) content[0]).get('text');
        Assert.areEqual('text', ((Map<String, Object>) content[0]).get('type'), 'The reference becomes text the API accepts');
        Assert.isTrue(note.contains('"roof.jpg"') && note.contains('no longer sent'), 'Claude is told which file was there and that it cannot see it: ' + note);
        Assert.isFalse(carried.hasPlaced(), 'Nothing was placed');
    }

    @IsTest
    static void typedTextThatLooksLikeAPlaceholderIsLeftAlone() {
        String lookalike = 'Here is "data":"@@FILE:0@@" in my message';
        List<Object> conversation = conversationWith(new List<Object>{ typed(lookalike), reference('f1', 'roof.jpg') });
        AntsuranceClaudeAttachments.Carried carried = AntsuranceClaudeAttachments.read(new List<String>{ 'f1' }, new List<String>{ JPEG }, new List<String>{ SMALL });

        AntsuranceClaudeAttachments.place(conversation, carried);
        String body = AntsuranceClaudeAttachments.withFiles(JSON.serialize(conversation), carried);

        List<Object> content = (List<Object>) ((Map<String, Object>) ((List<Object>) JSON.deserializeUntyped(body))[0]).get('content');
        Assert.areEqual(lookalike, ((Map<String, Object>) content[0]).get('text'), 'What the user typed is not replaced');
        Map<String, Object> source = (Map<String, Object>) ((Map<String, Object>) content[2]).get('source');
        Assert.areEqual(SMALL, source.get('data'), 'Only the real placeholder is');
    }

    @IsTest
    static void aRecordsPhotosAndPdfsAreListed() {
        Account customer = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<AntsuranceClaudeAttachments.RecordFile> files = AntsuranceClaudeAttachments.listFor(customer.Id);
        Test.stopTest();

        Assert.areEqual(2, files.size(), 'The photo and the PDF, not the text file');
        Map<String, AntsuranceClaudeAttachments.RecordFile> byName = new Map<String, AntsuranceClaudeAttachments.RecordFile>();
        for (AntsuranceClaudeAttachments.RecordFile file : files) {
            byName.put(file.name, file);
            Assert.isNull(file.data, 'A listing carries no contents');
            Assert.isNull(file.whyNot, 'Small files can be sent');
        }
        Assert.areEqual('image', byName.get('Roof after the storm').kind, 'An upper-case extension is still a photo');
        Assert.areEqual(JPEG, byName.get('Roof after the storm').mediaType, 'With its type');
        Assert.areEqual('pdf', byName.get('Repair estimate').kind, 'The PDF is listed as one');
        Assert.areEqual('1 KB', byName.get('Repair estimate').sizeLabel, 'With a size to show');
    }

    @IsTest
    static void noRecordMeansNoFiles() {
        Assert.isTrue(AntsuranceClaudeAttachments.listFor(null).isEmpty(), 'Nothing to offer without a record');
    }

    @IsTest
    static void aRecordsFileIsHandedOverWithItsContents() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Repair estimate' LIMIT 1].ContentDocumentId;

        Test.startTest();
        AntsuranceClaudeAttachments.RecordFile file = AntsuranceClaudeAttachments.load(customer.Id, documentId);
        Test.stopTest();

        Assert.areEqual(PDF, file.mediaType, 'The file\'s type comes with it');
        Assert.areEqual('pdf bytes', EncodingUtil.base64Decode(file.data).toString(), 'With its contents, base64 encoded');
    }

    @IsTest
    static void aFileThatIsNotOnTheRecordIsNotHandedOver() {
        Account other = new Account(Name = 'Ridgeline Supply');
        insert other;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Repair estimate' LIMIT 1].ContentDocumentId;

        try {
            AntsuranceClaudeAttachments.load(other.Id, documentId);
            Assert.fail('Expected the file to be refused');
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            Assert.isTrue(e.getMessage().contains('not on this record'), 'Says why: ' + e.getMessage());
        }
    }

    @IsTest
    static void aFileOfAnotherKindIsNotHandedOver() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Adjuster notes' LIMIT 1].ContentDocumentId;

        try {
            AntsuranceClaudeAttachments.load(customer.Id, documentId);
            Assert.fail('Expected the file to be refused');
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            Assert.isTrue(e.getMessage().contains('not on this record'), 'A text file is not offered: ' + e.getMessage());
        }
    }

    @IsTest
    static void aRecordsPdfOverTheLimitIsListedButNotSent() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        insert new ContentVersion(
            Title = 'Full policy wording',
            PathOnClient = 'wording.pdf',
            VersionData = Blob.valueOf('x'.repeat(AntsuranceClaudeAttachments.MAX_PDF_BYTES + 1)),
            FirstPublishLocationId = customer.Id
        );
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Full policy wording' LIMIT 1].ContentDocumentId;

        Test.startTest();
        AntsuranceClaudeAttachments.RecordFile listed;
        for (AntsuranceClaudeAttachments.RecordFile file : AntsuranceClaudeAttachments.listFor(customer.Id)) {
            if (file.documentId == documentId) {
                listed = file;
            }
        }
        String refusal;
        try {
            AntsuranceClaudeAttachments.load(customer.Id, documentId);
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            refusal = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual('Too large to send from here', listed.whyNot, 'The file is listed with why it cannot be sent');
        Assert.areEqual('"Full policy wording" cannot be sent: too large to send from here.', refusal, 'And asking for it says the same');
    }
}
