@IsTest
private class AntsuranceClaimsAssistantDocumentsTest {
    /** Answers with one canned response and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status;
        String body;
        HttpRequest request;

        ClaudeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void createClaimWithFiles() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-1', Account__c = customer.Id, Primary_Insured__c = person.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1)
        );
        insert policy;
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        List<Case> claims = new List<Case>{
            new Case(
                RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Policy__c = policy.Id, Status = 'New', Severity__c = 'High',
                Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-5), Estimated_Loss__c = 48500, Reserve_Amount__c = 45000, Paid_Amount__c = 5000
            ),
            new Case(RecordTypeId = claimType, Subject = 'Another claim', Policy__c = policy.Id, Status = 'New')
        };
        insert claims;
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Rebuild estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('%PDF pretend'), FirstPublishLocationId = claims[0].Id),
            new ContentVersion(Title = 'Adjuster worksheet', PathOnClient = 'worksheet.xlsx', VersionData = Blob.valueOf('cells'), FirstPublishLocationId = claims[0].Id),
            new ContentVersion(Title = 'Unrelated photo', PathOnClient = 'photo.JPG', VersionData = Blob.valueOf('jpeg'), FirstPublishLocationId = claims[1].Id)
        };
    }

    private static Id claimId() {
        return [SELECT Id FROM Case WHERE Subject = 'Burst pipe flooded basement'].Id;
    }

    private static Id documentId(String title) {
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Title = :title].ContentDocumentId;
    }

    private static String reply() {
        Map<String, Object> answer = new Map<String, Object>{
            'document_type' => 'Rebuild estimate',
            'issuer' => 'Northshore Renovation Co.',
            'document_date' => '2026-09-30',
            'match_note' => 'The name, address and date of loss match the claim.',
            'matches_claim' => 'yes',
            'key_facts' => new List<Object>{
                new Map<String, Object>{ 'label' => 'Total', 'value' => '$27,450' },
                new Map<String, Object>{ 'label' => '', 'value' => 'dropped because it has no label' }
            },
            'total_amount' => 27450,
            'summary' => 'A contractor estimate to rebuild the basement.',
            'comparison' => 'The estimate is $3,450 over the $24,000 rebuild line.',
            'concerns' => new List<Object>{ 'The furnace is excluded.' },
            'suggestions' => new List<Object>{
                new Map<String, Object>{ 'kind' => 'set_reserve', 'reason' => 'Rebuild line rises by $3,450.', 'amount' => 48450, 'title' => 'Set reserve to $48,450' },
                new Map<String, Object>{ 'kind' => 'set_estimate', 'reason' => 'No figure given.', 'amount' => null, 'title' => 'Set the estimate' },
                new Map<String, Object>{ 'kind' => 'add_task', 'reason' => 'It is excluded here.', 'amount' => null, 'title' => 'Request the furnace quote' }
            },
            'note_type' => 'Reserve',
            'note' => '**Document:** Rebuild estimate.\n\n**Amount:** $27,450.'
        };
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    private static String failureOfRead(Id caseId, Id documentId) {
        try {
            AntsuranceClaimsAssistantDocuments.readDocument(caseId, documentId);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String failureOfApply(String kind, Decimal amount, String title) {
        try {
            AntsuranceClaimsAssistantDocuments.applySuggestion(claimId(), kind, amount, title, null, null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void theClaimsFilesAreListedWithWhatClaudeCanRead() {
        List<AntsuranceClaimsAssistantDocuments.DocumentItem> items = AntsuranceClaimsAssistantDocuments.getDocuments(claimId());

        Assert.areEqual(2, items.size(), 'Only this claim\'s files are listed');
        Map<String, AntsuranceClaimsAssistantDocuments.DocumentItem> byTitle = new Map<String, AntsuranceClaimsAssistantDocuments.DocumentItem>();
        for (AntsuranceClaimsAssistantDocuments.DocumentItem item : items) {
            byTitle.put(item.title, item);
        }
        AntsuranceClaimsAssistantDocuments.DocumentItem estimate = byTitle.get('Rebuild estimate');
        Assert.isTrue(estimate.readable, 'A PDF can be read');
        Assert.areEqual('pdf', estimate.extension, 'Its type is given');
        Assert.areEqual('1 KB', estimate.sizeLabel, 'And its size, never less than 1 KB');
        Assert.isNull(estimate.whyNot, 'With no reason not to read it');
        AntsuranceClaimsAssistantDocuments.DocumentItem worksheet = byTitle.get('Adjuster worksheet');
        Assert.isFalse(worksheet.readable, 'A spreadsheet cannot');
        Assert.areEqual(AntsuranceClaimsAssistantDocuments.WRONG_TYPE, worksheet.whyNot, 'And the card says why');
    }

    @IsTest
    static void claudeReadsTheDocumentAgainstTheClaim() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id documentId = documentId('Rebuild estimate');

        Test.startTest();
        AntsuranceClaimsAssistantDocuments.Reading reading = AntsuranceClaimsAssistantDocuments.readDocument(claimId(), documentId);
        Test.stopTest();

        Assert.areEqual(documentId, reading.documentId, 'The reading names its document');
        Assert.areEqual('Rebuild estimate', reading.title, 'By title');
        Assert.areEqual('Rebuild estimate', reading.documentType, 'What the document is');
        Assert.areEqual('Northshore Renovation Co.', reading.issuer, 'Who issued it');
        Assert.areEqual(Date.newInstance(2026, 9, 30), reading.documentDate, 'Its date');
        Assert.areEqual('yes', reading.matchesClaim, 'Whether it belongs to the claim');
        Assert.areEqual(27450, reading.totalAmount, 'Its total');
        Assert.areEqual(1, reading.keyFacts.size(), 'Facts without a label are dropped');
        Assert.areEqual(1, reading.concerns.size(), 'Concerns are kept');
        Assert.areEqual(2, reading.suggestions.size(), 'A figure change with no figure is not offered');
        Assert.areEqual(48450, reading.suggestions[0].amount, 'The reserve suggestion carries its figure');
        Assert.areEqual('Reserve', reading.noteType, 'The file note has a type');
        Assert.isTrue(reading.note.startsWith('**Document:**'), 'And text');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.request.getBody());
        List<Object> content = (List<Object>) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        Map<String, Object> document = (Map<String, Object>) content[0];
        Assert.areEqual('document', document.get('type'), 'The PDF is sent as a document');
        Assert.areEqual(
            EncodingUtil.base64Encode(Blob.valueOf('%PDF pretend')),
            ((Map<String, Object>) document.get('source')).get('data'),
            'With the file\'s own contents'
        );
        String prompt = (String) ((Map<String, Object>) content[1]).get('text');
        Assert.isTrue(prompt.contains('Reserve: $45,000'), 'The claim file goes with it');
        Assert.isTrue(prompt.contains('titled "Rebuild estimate"'), 'And the document\'s title');
    }

    @IsTest
    static void filesClaudeCannotReadAreTurnedAwayBeforeAnyCall() {
        // No mock is set, so a callout would fail the test.
        Assert.areEqual(
            AntsuranceClaimsAssistantDocuments.WRONG_TYPE,
            failureOfRead(claimId(), documentId('Adjuster worksheet')),
            'A spreadsheet is refused'
        );
        Assert.areEqual(
            AntsuranceClaimsAssistantDocuments.NOT_ON_CLAIM,
            failureOfRead(claimId(), documentId('Unrelated photo')),
            'A file on another claim is refused'
        );
    }

    @IsTest
    static void anApiFailureIsShownToTheHandler() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(529, '{"error":{"message":"Overloaded"}}'));

        Test.startTest();
        String message = failureOfRead(claimId(), documentId('Rebuild estimate'));
        Test.stopTest();

        Assert.isTrue(message.startsWith('Claude is temporarily unavailable.'), 'The failure is explained: ' + message);
    }

    @IsTest
    static void aConfirmedReserveChangeIsMadeAndExplainedOnTheFile() {
        Id claimId = claimId();

        Test.startTest();
        String done = AntsuranceClaimsAssistantDocuments.applySuggestion(
            claimId, AntsuranceClaimsAssistantDocuments.SET_RESERVE, 48450, 'Set reserve to $48,450', 'Rebuild line rises by $3,450.', 'Rebuild estimate'
        );
        Test.stopTest();

        Assert.areEqual('Reserve set to $48,450.', done, 'The confirmation names the new figure');
        Assert.areEqual(48450, [SELECT Reserve_Amount__c FROM Case WHERE Id = :claimId].Reserve_Amount__c, 'The reserve is changed');
        File_Note__c note = [SELECT Note_Type__c, Body__c FROM File_Note__c WHERE Case__c = :claimId];
        Assert.areEqual('Reserve', note.Note_Type__c, 'A reserve note is added');
        Assert.areEqual(
            '**Reserve changed:** From $45,000 to $48,450 after reading Rebuild estimate.\n\n**Why:** Rebuild line rises by $3,450.',
            note.Body__c,
            'It says what changed and why'
        );
    }

    @IsTest
    static void aConfirmedEstimateChangeKeepsItsCents() {
        Id claimId = claimId();

        Test.startTest();
        String done = AntsuranceClaimsAssistantDocuments.applySuggestion(claimId, AntsuranceClaimsAssistantDocuments.SET_ESTIMATE, 9971.2, null, null, null);
        Test.stopTest();

        Assert.areEqual('Estimate set to $9,971.20.', done, 'Cents are shown when there are some');
        Assert.areEqual(9971.20, [SELECT Estimated_Loss__c FROM Case WHERE Id = :claimId].Estimated_Loss__c, 'The estimate is changed');
        Assert.areEqual(
            '**Estimate changed:** From $48,500 to $9,971.20.',
            [SELECT Body__c FROM File_Note__c WHERE Case__c = :claimId].Body__c,
            'The note stands without a document or a reason'
        );
    }

    @IsTest
    static void aReserveBelowWhatHasBeenPaidIsRefusedByTheClaimsOwnRule() {
        String message = failureOfApply(AntsuranceClaimsAssistantDocuments.SET_RESERVE, 1000, 'Set reserve to $1,000');
        Assert.isTrue(message.contains('Paid to date cannot be more than the reserve'), 'The validation rule\'s message is shown: ' + message);
        Assert.areEqual(45000, [SELECT Reserve_Amount__c FROM Case WHERE Id = :claimId()].Reserve_Amount__c, 'The reserve is unchanged');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'And no note was written');
    }

    @IsTest
    static void confirmedFlagsAndTasksAreApplied() {
        Id claimId = claimId();

        Test.startTest();
        String subrogation = AntsuranceClaimsAssistantDocuments.applySuggestion(claimId, AntsuranceClaimsAssistantDocuments.FLAG_SUBROGATION, null, 'Flag', null, null);
        String fraud = AntsuranceClaimsAssistantDocuments.applySuggestion(claimId, AntsuranceClaimsAssistantDocuments.FLAG_FRAUD, null, 'Flag', null, null);
        String task = AntsuranceClaimsAssistantDocuments.applySuggestion(
            claimId, AntsuranceClaimsAssistantDocuments.ADD_TASK, null, ' Request the furnace quote ', 'It is excluded here.', 'Rebuild estimate'
        );
        Test.stopTest();

        Case claim = [SELECT Subrogation_Potential__c, SIU_Referral__c FROM Case WHERE Id = :claimId];
        Assert.isTrue(claim.Subrogation_Potential__c, 'The subrogation flag is set');
        Assert.isTrue(claim.SIU_Referral__c, 'The fraud flag is set');
        Assert.areEqual('Flagged for subrogation.', subrogation, 'Each is confirmed');
        Assert.areEqual('Flagged for possible fraud.', fraud, 'In plain words');
        Assert.areEqual('Task added.', task, 'Including the task');
        Task added = [SELECT Subject, Description, OwnerId, ActivityDate FROM Task WHERE WhatId = :claimId AND Subject = 'Request the furnace quote'];
        Assert.areEqual('It is excluded here.', added.Description, 'The task carries Claude\'s reason');
        Assert.areEqual(UserInfo.getUserId(), added.OwnerId, 'It is assigned to whoever confirmed');
    }

    @IsTest
    static void suggestionsThatCannotBeAppliedAreRefused() {
        Assert.areEqual(AntsuranceClaimsAssistantDocuments.UNKNOWN_SUGGESTION, failureOfApply('delete_claim', null, 'x'), 'An unknown kind is refused');
        Assert.areEqual(AntsuranceClaimsAssistantDocuments.NEEDS_AMOUNT, failureOfApply(AntsuranceClaimsAssistantDocuments.SET_RESERVE, null, 'x'), 'A reserve change needs a figure');
        Assert.areEqual(AntsuranceClaimsAssistantDocuments.NEEDS_AMOUNT, failureOfApply(AntsuranceClaimsAssistantDocuments.SET_ESTIMATE, -5, 'x'), 'And not a negative one');
        Assert.areEqual(AntsuranceClaimsAssistantDocuments.UNKNOWN_SUGGESTION, failureOfApply(AntsuranceClaimsAssistantDocuments.ADD_TASK, null, ' '), 'A task needs a subject');
    }

    @IsTest
    static void claudesNoteCanBeAddedToTheFile() {
        Id claimId = claimId();
        AntsuranceClaimsAssistantDocuments.addNote(claimId, 'Reserve', '**Document:** Rebuild estimate.');
        File_Note__c note = [SELECT Note_Type__c, Body__c FROM File_Note__c WHERE Case__c = :claimId];
        Assert.areEqual('Reserve', note.Note_Type__c, 'The note keeps its type');
        Assert.areEqual('**Document:** Rebuild estimate.', note.Body__c, 'And its text');
    }

    @IsTest
    static void moneyIsWrittenTheWayPeopleReadIt() {
        Assert.areEqual('$48,450', AntsuranceClaimsAssistantDocuments.money(48450), 'Whole dollars have no cents');
        Assert.areEqual('$9,971.20', AntsuranceClaimsAssistantDocuments.money(9971.2), 'Cents keep two digits');
        Assert.areEqual('$0.05', AntsuranceClaimsAssistantDocuments.money(0.05), 'Small amounts keep their leading zero');
        Assert.areEqual('not set', AntsuranceClaimsAssistantDocuments.money(null), 'No figure says so');
    }
}
