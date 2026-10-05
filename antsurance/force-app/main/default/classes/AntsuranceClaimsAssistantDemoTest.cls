@IsTest
private class AntsuranceClaimsAssistantDemoTest {
    private static final String PIPE_CLAIM = 'Burst pipe flooded finished basement';
    private static final String REAR_END_CLAIM = 'Rear-ended at a red light on Harlem Ave';
    private static final String ROOF_CLAIM = 'Installer fell from second-story roof';

    private static void createDemoClaims() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Policy__c policy = new Policy__c(Name = 'T-HOME-1', Account__c = customer.Id, Status__c = 'Active');
        insert policy;
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        insert new List<Case>{
            new Case(RecordTypeId = claimType, Subject = PIPE_CLAIM, Policy__c = policy.Id, Status = 'New'),
            new Case(RecordTypeId = claimType, Subject = REAR_END_CLAIM, Policy__c = policy.Id, Status = 'New'),
            new Case(RecordTypeId = claimType, Subject = ROOF_CLAIM, Policy__c = policy.Id, Status = 'New')
        };
    }

    private static Map<String, List<ContentDocumentLink>> filesByClaim() {
        Map<Id, String> subjects = new Map<Id, String>();
        for (Case claim : [SELECT Subject FROM Case]) {
            subjects.put(claim.Id, claim.Subject);
        }
        Map<String, List<ContentDocumentLink>> files = new Map<String, List<ContentDocumentLink>>{
            PIPE_CLAIM => new List<ContentDocumentLink>(),
            REAR_END_CLAIM => new List<ContentDocumentLink>(),
            ROOF_CLAIM => new List<ContentDocumentLink>()
        };
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :subjects.keySet()
        ]) {
            files.get(subjects.get(link.LinkedEntityId)).add(link);
        }
        return files;
    }

    @IsTest
    static void theSampleDocumentsAreAttachedToTheirClaimsOnce() {
        createDemoClaims();

        Test.startTest();
        String first = AntsuranceClaimsAssistantDemo.attachSampleDocuments();
        String second = AntsuranceClaimsAssistantDemo.attachSampleDocuments();
        Test.stopTest();

        Assert.areEqual('6 attached, 0 already there.', first, 'The first run attaches all six');
        Assert.areEqual('0 attached, 6 already there.', second, 'A second run adds nothing');

        Map<String, List<ContentDocumentLink>> files = filesByClaim();
        Assert.areEqual(2, files.get(PIPE_CLAIM).size(), 'The burst pipe claim has its invoice and estimate');
        Assert.areEqual(2, files.get(REAR_END_CLAIM).size(), 'The rear-end claim has its crash report and repair estimate');
        Assert.areEqual(2, files.get(ROOF_CLAIM).size(), 'The roof fall claim has the employer\'s first report and the hospital bill');
        Set<String> kinds = new Set<String>();
        for (List<ContentDocumentLink> links : files.values()) {
            for (ContentDocumentLink link : links) {
                kinds.add(link.ContentDocument.FileExtension);
                Assert.isTrue(link.ContentDocument.ContentSize > 10000, link.ContentDocument.Title + ' is a real file, not a placeholder');
            }
        }
        Assert.areEqual(new Set<String>{ 'pdf', 'jpg' }, kinds, 'The set includes PDFs and an image');
        Assert.isTrue(
            AntsuranceClaimsAssistantDocuments.getDocuments(files.get(PIPE_CLAIM)[0].LinkedEntityId)[0].readable,
            'Claude can read what was attached'
        );
    }

    @IsTest
    static void withNoDemoClaimsNothingIsAttached() {
        Test.startTest();
        String result = AntsuranceClaimsAssistantDemo.attachSampleDocuments();
        Test.stopTest();

        Assert.areEqual('0 attached, 0 already there, 6 skipped because the claim or the file was not found.', result, 'The result says what was skipped');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'No files were created');
    }
}
