@IsTest
private class AntsuranceFilesControllerTest {
    private static Id fileOn(Id recordId, String title, String fileName) {
        ContentVersion version = new ContentVersion(Title = title, PathOnClient = fileName, VersionData = Blob.valueOf('A saved copy'));
        insert version;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = recordId, ContentDocumentId = documentId, ShareType = 'V');
        return documentId;
    }

    @IsTest
    static void listsARecordsFilesWithTheirTypeSizeAndWhoSavedThem() {
        Account customer = new Account(Name = 'Harbor Household');
        Account other = new Account(Name = 'Quay Household');
        insert new List<Account>{ customer, other };
        Id declarations = fileOn(customer.Id, 'Declarations page', 'declarations.PDF');
        fileOn(customer.Id, 'Kitchen after the fire', 'kitchen.jpg');
        fileOn(other.Id, 'Someone else\'s file', 'other.pdf');

        Test.startTest();
        List<AntsuranceFilesController.FileRow> files = AntsuranceFilesController.getFiles(customer.Id);
        Test.stopTest();

        Assert.areEqual(2, files.size(), 'Only the files on this record are listed');
        AntsuranceFilesController.FileRow saved;
        for (AntsuranceFilesController.FileRow file : files) {
            if (file.contentDocumentId == declarations) {
                saved = file;
            }
        }
        Assert.isNotNull(saved, 'The declarations page is among them');
        Assert.areEqual('Declarations page', saved.title, 'A file is named by its title');
        Assert.areEqual('pdf', saved.extension, 'The type is the extension in lower case');
        Assert.isTrue(saved.size > 0, 'The size is given in bytes');
        Assert.areEqual(UserInfo.getName(), saved.savedBy, 'It says who saved it');
        Assert.isNotNull(saved.savedAt, 'It says when it was saved');
    }

    @IsTest
    static void aRecordWithNoFilesAndNoRecordBothGiveAnEmptyList() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;

        Test.startTest();
        List<AntsuranceFilesController.FileRow> none = AntsuranceFilesController.getFiles(customer.Id);
        List<AntsuranceFilesController.FileRow> noRecord = AntsuranceFilesController.getFiles(null);
        Test.stopTest();

        Assert.isTrue(none.isEmpty(), 'A record with no files lists none');
        Assert.isTrue(noRecord.isEmpty(), 'No record lists none');
    }
}
