@IsTest
private class AntsuranceDocumentControllerTest {
    private static Policy__c policy(Account customer, String name, String line) {
        Date start = Date.newInstance(2026, 5, 13);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Line_of_Business__c = line, Status__c = 'Active', Effective_Date__c = start,
            Expiration_Date__c = start.addYears(1), Annual_Premium__c = 2380
        );
    }

    @TestSetup
    static void createRecords() {
        Account household = new Account(Name = 'Reyes Household');
        Account roofer = new Account(Name = 'Ridgeline Roofing & Solar', RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Business').getRecordTypeId());
        insert new List<Account>{ household, roofer };

        Policy__c auto = policy(household, 'ANT-PA-1', 'Personal Auto');
        Policy__c home = policy(household, 'ANT-HO-2', 'Homeowners');
        Policy__c fleet = policy(roofer, 'ANT-CA-3', 'Commercial Auto');
        Policy__c lapsed = policy(household, 'ANT-UM-4', 'Umbrella');
        lapsed.Status__c = 'Lapsed';
        insert new List<Policy__c>{ auto, home, fleet, lapsed };
        insert new List<Policy_Asset__c>{
            new Policy_Asset__c(Policy__c = auto.Id, Name = '2022 Toyota RAV4', Asset_Type__c = 'Vehicle', Identifier__c = '2T3P1RFV8NC123456'),
            new Policy_Asset__c(Policy__c = home.Id, Name = '524 W Spring Ave', Asset_Type__c = 'Dwelling')
        };

        Id saleType = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId();
        Opportunity quoted = new Opportunity(Name = 'Reyes Household - Umbrella', AccountId = household.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(30), RecordTypeId = saleType);
        Opportunity unquoted = new Opportunity(Name = 'Reyes Household - Renters', AccountId = household.Id, StageName = 'Submission Received', CloseDate = Date.today().addDays(30), RecordTypeId = saleType);
        insert new List<Opportunity>{ quoted, unquoted };
        insert new Quote(Name = 'Standard', OpportunityId = quoted.Id, Status = 'Issued');
    }

    private static List<String> keys(List<AntsuranceDocumentController.DocumentOption> documents) {
        List<String> keys = new List<String>();
        for (AntsuranceDocumentController.DocumentOption document : documents) {
            keys.add(document.key);
        }
        return keys;
    }

    @IsTest
    static void aPolicyOffersTheDocumentsItsLineCalls() {
        Map<String, Id> policyIds = new Map<String, Id>();
        for (Policy__c policy : [SELECT Name FROM Policy__c]) {
            policyIds.put(policy.Name, policy.Id);
        }

        Test.startTest();
        List<AntsuranceDocumentController.DocumentOption> forAuto = AntsuranceDocumentController.getDocuments(policyIds.get('ANT-PA-1'));
        List<AntsuranceDocumentController.DocumentOption> forHome = AntsuranceDocumentController.getDocuments(policyIds.get('ANT-HO-2'));
        List<AntsuranceDocumentController.DocumentOption> forFleet = AntsuranceDocumentController.getDocuments(policyIds.get('ANT-CA-3'));
        List<AntsuranceDocumentController.DocumentOption> forLapsed = AntsuranceDocumentController.getDocuments(policyIds.get('ANT-UM-4'));
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'declarations', 'idCards' }, keys(forAuto), 'An auto policy with a vehicle has declarations and ID cards');
        Assert.areEqual('/apex/AntsuranceDecPage?id=' + policyIds.get('ANT-PA-1'), forAuto[0].url, 'Each with the page that prints it');
        Assert.areEqual('Declarations ANT-PA-1', forAuto[0].title, 'And the name it is saved under');
        Assert.isFalse(forAuto[1].takesHolder, 'Only a certificate takes a holder');
        Assert.areEqual(new List<String>{ 'declarations' }, keys(forHome), 'A homeowners policy has declarations only');
        Assert.areEqual(new List<String>{ 'declarations', 'certificate' }, keys(forFleet), 'A commercial auto policy with no vehicle listed has declarations and a certificate');
        Assert.isTrue(forFleet[1].takesHolder, 'The certificate takes a holder');
        Assert.areEqual(new List<String>{ 'declarations' }, keys(forLapsed), 'A liability policy that is not in force has no certificate');
    }

    @IsTest
    static void salesAndCustomersOfferTheirs() {
        Opportunity quoted = [SELECT Id FROM Opportunity WHERE Name = 'Reyes Household - Umbrella'];
        Opportunity unquoted = [SELECT Id FROM Opportunity WHERE Name = 'Reyes Household - Renters'];
        Account roofer = [SELECT Id FROM Account WHERE Name = 'Ridgeline Roofing & Solar'];
        Account household = [SELECT Id FROM Account WHERE Name = 'Reyes Household'];
        Contact someone = new Contact(LastName = 'Reyes', AccountId = household.Id);
        insert someone;

        Test.startTest();
        List<AntsuranceDocumentController.DocumentOption> forQuoted = AntsuranceDocumentController.getDocuments(quoted.Id);
        List<AntsuranceDocumentController.DocumentOption> forUnquoted = AntsuranceDocumentController.getDocuments(unquoted.Id);
        List<AntsuranceDocumentController.DocumentOption> forRoofer = AntsuranceDocumentController.getDocuments(roofer.Id);
        List<AntsuranceDocumentController.DocumentOption> forHousehold = AntsuranceDocumentController.getDocuments(household.Id);
        List<AntsuranceDocumentController.DocumentOption> forContact = AntsuranceDocumentController.getDocuments(someone.Id);
        List<AntsuranceDocumentController.DocumentOption> forNothing = AntsuranceDocumentController.getDocuments(null);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'proposal' }, keys(forQuoted), 'A sale with a quote has a proposal');
        Assert.areEqual('Proposal Reyes Household - Umbrella', forQuoted[0].title, 'Named for the sale');
        Assert.isTrue(forUnquoted.isEmpty(), 'A sale without a quote has nothing yet');
        Assert.areEqual(new List<String>{ 'certificate' }, keys(forRoofer), 'A customer with liability cover has a certificate');
        Assert.areEqual('Certificate Ridgeline Roofing & Solar', forRoofer[0].title, 'Named for the customer');
        Assert.isTrue(forHousehold.isEmpty(), 'A household without liability cover in force has none');
        Assert.isTrue(forContact.isEmpty() && forNothing.isEmpty(), 'Other records, and no record, have no documents');
    }

    @IsTest
    static void aDocumentIsSavedToTheRecordsFiles() {
        Policy__c fleet = [SELECT Id FROM Policy__c WHERE Name = 'ANT-CA-3'];

        Test.startTest();
        AntsuranceDocumentController.SavedFile declarations = AntsuranceDocumentController.saveToFiles(fleet.Id, 'declarations', 'Ignored', null);
        AntsuranceDocumentController.SavedFile certificate = AntsuranceDocumentController.saveToFiles(fleet.Id, 'certificate', ' City of  Naperville ', '400 S Eagle St, Naperville, IL 60540');
        Test.stopTest();

        Assert.areEqual('Declarations ANT-CA-3', declarations.title, 'A holder is ignored for anything but a certificate');
        Assert.areEqual('Certificate ANT-CA-3 for City of Naperville', certificate.title, 'A certificate is named for its holder');
        List<ContentDocumentLink> links = [SELECT ContentDocument.Title, ContentDocument.FileExtension FROM ContentDocumentLink WHERE LinkedEntityId = :fleet.Id ORDER BY ContentDocument.Title];
        Assert.areEqual(2, links.size(), 'Both files are on the policy');
        Assert.areEqual(certificate.contentDocumentId, links[0].ContentDocumentId, 'The saved file is the one returned');
        Assert.areEqual('pdf', links[0].ContentDocument.FileExtension, 'Saved as a PDF');
    }

    @IsTest
    static void thePagesOfADocumentAreCounted() {
        Policy__c fleet = [SELECT Id FROM Policy__c WHERE Name = 'ANT-CA-3'];

        Test.startTest();
        Integer pages = AntsuranceDocumentController.countPages(fleet.Id, 'certificate', 'City of Naperville', '400 S Eagle St, Naperville, IL 60540');
        Test.stopTest();

        Assert.areEqual(2, pages, 'The count comes from the rendered PDF');
        Assert.areEqual(3, AntsuranceDocumentController.pagesIn(Blob.valueOf('1 0 obj << /Type /Pages /Count 3 /Kids [2 0 R] >> endobj')), 'Read from the page tree');
        Assert.areEqual(12, AntsuranceDocumentController.pagesIn(Blob.valueOf('<< /Count 10 >> << /Count 2 >> << /Type/Pages/Count 12 >>')), 'A nested page tree gives its total at the root');
        Assert.isNull(AntsuranceDocumentController.pagesIn(Blob.valueOf('not a PDF /Count')), 'A file with no count gives none, and the preview stays one page tall');
    }

    @IsTest
    static void aDocumentTheRecordDoesNotOfferIsRefused() {
        Policy__c home = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-2'];
        Id missingPolicy = home.Id;
        List<String> messages = new List<String>();

        Test.startTest();
        try {
            AntsuranceDocumentController.saveToFiles(home.Id, 'idCards', null, null);
        } catch (AuraHandledException e) {
            messages.add(e.getMessage());
        }
        delete [SELECT Id FROM Opportunity];
        delete home;
        try {
            AntsuranceDocumentController.getDocuments(missingPolicy);
        } catch (AuraHandledException e) {
            messages.add(e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(2, messages.size(), 'Both calls are refused');
        Assert.areEqual('That document is not available for this record.', messages[0], 'A homeowners policy has no ID cards to save');
        Assert.areEqual('The record could not be loaded. Check that it exists and that you have access to it.', messages[1], 'A deleted policy cannot be loaded');
    }

    @IsTest
    static void aDeletedSaleOrCustomerCannotBeLoaded() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Reyes Household - Renters'];
        Account roofer = [SELECT Id FROM Account WHERE Name = 'Ridgeline Roofing & Solar'];
        Id saleId = sale.Id;
        Id rooferId = roofer.Id;
        delete sale;
        delete [SELECT Id FROM Policy__c WHERE Account__c = :rooferId];
        delete roofer;
        Integer refused = 0;

        Test.startTest();
        for (Id recordId : new List<Id>{ saleId, rooferId }) {
            try {
                AntsuranceDocumentController.getDocuments(recordId);
            } catch (AuraHandledException e) {
                refused++;
            }
        }
        Test.stopTest();

        Assert.areEqual(2, refused, 'Neither a deleted sale nor a deleted customer can be loaded');
    }
}
