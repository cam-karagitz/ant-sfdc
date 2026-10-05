@IsTest
private class AntsuranceClaudeRecordFactsTest {
    private static Id recordTypeId(String developerName) {
        return Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    @TestSetup
    static void createRecords() {
        Account household = new Account(Name = 'Okafor Household');
        insert household;
        Contact insured = new Contact(FirstName = 'Ada', LastName = 'Okafor', AccountId = household.Id);
        insert insured;
        Date start = Date.today().addMonths(-2);
        Policy__c policy = new Policy__c(
            Name = 'ANT-HO-1',
            Account__c = household.Id,
            Primary_Insured__c = insured.Id,
            Line_of_Business__c = 'Homeowners',
            Status__c = 'Active',
            Annual_Premium__c = 2240,
            Effective_Date__c = start,
            Expiration_Date__c = start.addYears(1)
        );
        insert policy;
        insert new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 400000);
        Case claim = new Case(
            Subject = 'Burst pipe in basement',
            RecordTypeId = recordTypeId('Claim'),
            AccountId = household.Id,
            Policy__c = policy.Id,
            Status = 'Under Investigation',
            Reserve_Amount__c = 45000,
            Paid_Amount__c = 5000,
            Handled_By__c = 'Marcus Lindahl'
        );
        insert claim;
        insert new File_Note__c(Case__c = claim.Id, Policy__c = policy.Id, Account__c = household.Id, Note_Type__c = 'Investigation', Note_Date__c = Datetime.now(), Body__c = 'Plumber found a failed supply line. ' + 'x'.repeat(900));
        insert new List<Task>{
            new Task(Subject = 'Call the plumber', WhatId = claim.Id, ActivityDate = Date.today().addDays(2)),
            new Task(Subject = 'Finished already', WhatId = claim.Id, Status = 'Completed')
        };
    }

    @IsTest
    static void everyFactsQueryRuns() {
        for (String objectName : AntsuranceClaudeInsurance.QUERIES.keySet()) {
            try {
                Database.query(AntsuranceClaudeInsurance.QUERIES.get(objectName) + ' LIMIT 1');
            } catch (QueryException e) {
                Assert.fail('The facts query for ' + objectName + ' is not valid: ' + e.getMessage());
            }
        }
    }

    @IsTest
    static void aClaimComesWithItsPolicyNotesAndOpenTasks() {
        Case claim = [SELECT Id, CaseNumber FROM Case];

        Test.startTest();
        String facts = AntsuranceClaudeRecordFacts.describe(claim.Id);
        Test.stopTest();

        Assert.isTrue(facts.startsWith(AntsuranceClaudeRecordFacts.INTRO), 'The note says what it is');
        Map<String, Object> record = (Map<String, Object>) JSON.deserializeUntyped(facts.substringAfter(AntsuranceClaudeRecordFacts.INTRO));
        Assert.areEqual(claim.CaseNumber, record.get('CaseNumber'), 'The claim\'s own fields are there');
        Assert.areEqual('Marcus Lindahl', record.get('Handled_By__c'), 'including who is handling it');
        Assert.areEqual('Claim', ((Map<String, Object>) record.get('RecordType')).get('Name'), 'and what kind of case it is');
        Assert.areEqual('ANT-HO-1', ((Map<String, Object>) record.get('Policy__r')).get('Name'), 'The policy is named');
        Assert.areEqual('Okafor Household', ((Map<String, Object>) record.get('Account')).get('Name'), 'The customer is named');
        Assert.isFalse(record.containsKey('Loss_Type__c'), 'Empty fields are left out');

        List<Object> notes = (List<Object>) record.get('File_Notes__r');
        Assert.areEqual(1, notes.size(), 'Recent notes are included');
        String body = (String) ((Map<String, Object>) notes[0]).get('Body__c');
        Assert.isTrue(body.startsWith('Plumber found') && body.length() <= 800, 'Long notes are cut short');
        Assert.isFalse(body.endsWith('...'), 'and nothing is added to show where they stop');
        List<Object> tasks = (List<Object>) record.get('Tasks');
        Assert.areEqual(1, tasks.size(), 'Only open tasks are included');
        Assert.areEqual('Call the plumber', ((Map<String, Object>) tasks[0]).get('Subject'), 'The open task is the one listed');
    }

    @IsTest
    static void aClaimSaysWhereItsReserveStandsAndSetsClaudesOwnNotesApart() {
        Case claim = [SELECT Id, Policy__c, AccountId FROM Case];
        update new Case(
            Id = claim.Id,
            Estimated_Loss__c = 47500,
            Coverage_Read__c = JSON.serialize(new Map<String, Object>{ 'check' => new Map<String, Object>{ 'verdict' => 'Needs review', 'summary' => 'It hinges on the water source.' } })
        );
        update new Policy__c(Id = claim.Policy__c, Deductible__c = 2500, Coverage_Limit__c = 400000);
        insert new File_Note__c(
            Case__c = claim.Id,
            Policy__c = claim.Policy__c,
            Account__c = claim.AccountId,
            Note_Type__c = 'Investigation',
            Note_Date__c = Datetime.now(),
            Body__c = AntsuranceClaimRules.ANALYSIS_NOTE_OPENING + ' Raise the reserve to $48,921.'
        );

        Test.startTest();
        String facts = AntsuranceClaudeRecordFacts.describe(claim.Id);
        Test.stopTest();

        Map<String, Object> record = (Map<String, Object>) JSON.deserializeUntyped(facts.substringAfter(AntsuranceClaudeRecordFacts.INTRO));
        String position = (String) record.get('ReservePosition');
        Assert.isTrue(position.contains('$45,000') && position.contains('covers it'), 'The reserve is read against the estimate less the deductible: ' + position);
        Assert.isTrue(((String) record.get('CoverageCheckOnThePage')).startsWith('Verdict: Needs review.'), 'The coverage check card\'s verdict is given');
        Assert.areEqual(1, ((List<Object>) record.get('File_Notes__r')).size(), 'Only the note a person wrote is listed as a file note');
        List<Object> earlier = (List<Object>) record.get('EarlierWritingByClaude');
        Assert.areEqual(1, earlier.size(), 'Claude\'s own saved analysis is listed apart');
        Assert.isTrue(((String) ((Map<String, Object>) earlier[0]).get('Standing')).contains('not evidence'), 'and marked as an earlier opinion');
    }

    @IsTest
    static void longTextIsShortenedToWholeSentences() {
        String text = 'First sentence here. Second sentence follows it. Third one is the long tail that will not fit in the space allowed.';
        Assert.areEqual('First sentence here. Second sentence follows it.', AntsuranceClaudeRecordFacts.excerpt(text, 60), 'It stops at the end of a sentence');
        Assert.areEqual('Short.', AntsuranceClaudeRecordFacts.excerpt('Short.', 60), 'Short text is left alone');
        Assert.areEqual('One two three', AntsuranceClaudeRecordFacts.excerpt('One two three four five six', 15), 'With no sentence end it stops at a word');
    }

    @IsTest
    static void aPolicyAndACustomerComeWithTheirRelatedRows() {
        Policy__c policy = [SELECT Id, Account__c FROM Policy__c];

        Test.startTest();
        String policyFacts = AntsuranceClaudeRecordFacts.describe(policy.Id);
        String customerFacts = AntsuranceClaudeRecordFacts.describe(policy.Account__c);
        Test.stopTest();

        Assert.isTrue(policyFacts.contains('"Coverages__r"') && policyFacts.contains('Dwelling'), 'A policy lists its coverages');
        Assert.isTrue(policyFacts.contains('"Cases__r"') && policyFacts.contains('Burst pipe in basement'), 'and its claims');
        Assert.isTrue(customerFacts.contains('"Policies__r"') && customerFacts.contains('ANT-HO-1'), 'A customer lists its policies');
        Assert.isTrue(customerFacts.contains('"Contacts"') && customerFacts.contains('Ada Okafor'), 'its people');
        Assert.isTrue(customerFacts.contains('"Cases"') && customerFacts.contains('Burst pipe in basement'), 'and its claims');
    }

    @IsTest
    static void aQuoteComesWithTheOtherOptionsOnItsSale() {
        Account household = [SELECT Id FROM Account];
        Opportunity sale = new Opportunity(Name = 'Okafor Household - Umbrella', AccountId = household.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(30));
        insert sale;
        List<Quote> quotes = new List<Quote>{
            new Quote(Name = 'Standard limits', OpportunityId = sale.Id, Annual_Premium__c = 600),
            new Quote(Name = 'Higher limits', OpportunityId = sale.Id, Annual_Premium__c = 900)
        };
        insert quotes;

        Test.startTest();
        String quoteFacts = AntsuranceClaudeRecordFacts.describe(quotes[0].Id);
        String saleFacts = AntsuranceClaudeRecordFacts.describe(sale.Id);
        Test.stopTest();

        Map<String, Object> record = (Map<String, Object>) JSON.deserializeUntyped(quoteFacts.substringAfter(AntsuranceClaudeRecordFacts.INTRO));
        Assert.areEqual('Standard limits', record.get('Name'), 'The quote\'s own fields are there');
        List<Object> others = (List<Object>) record.get('OtherQuotesOnThisSale');
        Assert.areEqual(1, others.size(), 'The other option is listed');
        Assert.areEqual('Higher limits', ((Map<String, Object>) others[0]).get('Name'), 'by name');
        Assert.isTrue(saleFacts.contains('Standard limits') && saleFacts.contains('Higher limits'), 'A sale lists its quotes');
    }

    @IsTest
    static void aContactAndALeadHaveFactsToo() {
        Contact insured = [SELECT Id FROM Contact];
        Lead prospect = new Lead(LastName = 'Haddad', Company = 'Haddad Household', Product_Interest__c = 'Homeowners');
        insert prospect;

        Assert.isTrue(AntsuranceClaudeRecordFacts.describe(insured.Id).contains('Okafor Household'), 'A contact names its household');
        Assert.isTrue(AntsuranceClaudeRecordFacts.describe(prospect.Id).contains('Homeowners'), 'A lead says what it is interested in');
    }

    @IsTest
    static void thereAreNoFactsWithoutAReadableSupportedRecord() {
        Case claim = [SELECT Id FROM Case];
        delete claim;

        Assert.isNull(AntsuranceClaudeRecordFacts.describe(null), 'No record, no facts');
        Assert.isNull(AntsuranceClaudeRecordFacts.describe(UserInfo.getUserId()), 'Objects without a facts query give none');
        Assert.isNull(AntsuranceClaudeRecordFacts.describe(claim.Id), 'A record that cannot be read gives none');
    }

    @IsTest
    static void aRecordComesWithTheNamesOfItsAttachedFiles() {
        Case claim = [SELECT Id FROM Case];
        Assert.isFalse(AntsuranceClaudeRecordFacts.describe(claim.Id).contains('AttachedFiles'), 'A record with no files says nothing about files');
        ContentVersion estimate = new ContentVersion(Title = 'Rebuild estimate', PathOnClient = 'rebuild-estimate.pdf', VersionData = Blob.valueOf('estimate'));
        insert estimate;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :estimate.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = claim.Id, ContentDocumentId = documentId, ShareType = 'V');

        Test.startTest();
        String facts = AntsuranceClaudeRecordFacts.describe(claim.Id);
        Test.stopTest();

        Assert.isTrue(facts.contains('"AttachedFiles"'), 'The files on the record are listed');
        Assert.isTrue(facts.contains('Rebuild estimate'), 'By title, so the chat knows the estimate has arrived');
    }
}
