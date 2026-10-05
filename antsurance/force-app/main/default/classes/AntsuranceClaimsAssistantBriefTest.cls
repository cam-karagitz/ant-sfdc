@IsTest
private class AntsuranceClaimsAssistantBriefTest {
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
    static void createClaim() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-1', Account__c = customer.Id, Primary_Insured__c = person.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Insured_Item__c = '12 Quay St, Evanston, IL',
            Coverage_Limit__c = 500000, Deductible__c = 2500
        );
        insert policy;
        insert new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 500000, Deductible_Amount__c = 2500, What_Is_Covered__c = 'Rebuilds the home.');
        insert new Policy_Endorsement__c(Name = 'Earth Movement Exclusion', Policy__c = policy.Id, Type__c = 'Exclusion', Description__c = 'Earthquake is not covered.');
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Case claim = new Case(
            RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Description = 'A supply line burst.', Policy__c = policy.Id, Status = 'New',
            Severity__c = 'High', Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-5), Reported_Date__c = Date.today().addDays(-4),
            Estimated_Loss__c = 48500, Reserve_Amount__c = 45000, Paid_Amount__c = 5000
        );
        insert claim;
        insert new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Reserve', Body__c = '**Reserve set at $45,000**', Note_Date__c = Datetime.now().addDays(-2), Author_Name__c = 'Marcus Lindahl');
        insert new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
            Subject = 'Add a driver', Policy__c = policy.Id, Status = 'New'
        );
    }

    private static Case claim() {
        return [SELECT Id, Claude_Brief__c, Claude_Brief_At__c FROM Case WHERE Subject = 'Burst pipe flooded basement'];
    }

    private static String reply() {
        Map<String, Object> answer = new Map<String, Object>{
            'standing' => 'Drying is done and the file waits on two documents.',
            'coverage' => 'The policy was in force and a burst pipe is covered.',
            'money' => 'The $45,000 reserve is $3,500 under the estimate.',
            'watch' => new List<Object>{
                new Map<String, Object>{ 'label' => 'Subrogation', 'level' => 'high', 'text' => 'A supply line failed at the fitting.' },
                new Map<String, Object>{ 'label' => 'Reserve', 'level' => 'medium', 'text' => 'The reserve may be short.' }
            },
            'next_actions' => new List<Object>{
                new Map<String, Object>{ 'action' => 'Ask the insured to keep the failed supply line', 'reason' => 'It preserves recovery.' },
                new Map<String, Object>{ 'action' => 'Review the mitigation invoice', 'reason' => 'It confirms the drying cost.' }
            },
            'headline' => 'Get the invoice and estimate in, then adjust the reserve.'
        };
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    /** Writes a brief outside the test's own limits, so the test can then change the claim. */
    private static AntsuranceClaimsAssistantBrief.Brief written(Id claimId) {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply()));
        Test.startTest();
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.writeBrief(claimId);
        Test.stopTest();
        return brief;
    }

    @IsTest
    static void aClaimWithNoBriefSaysSo() {
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claim().Id);
        Assert.isFalse(brief.exists, 'No brief has been written yet');
        Assert.isFalse(brief.stale, 'So there is nothing to be out of date');
    }

    @IsTest
    static void writingABriefSendsTheWholeFileAndStoresTheAnswer() {
        Id claimId = claim().Id;
        insert new Task(WhatId = claimId, Subject = 'Review the mitigation invoice', ActivityDate = Date.today().addDays(1));
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.writeBrief(claimId);
        Test.stopTest();

        Assert.isTrue(brief.exists, 'The brief exists');
        Assert.areEqual('Get the invoice and estimate in, then adjust the reserve.', brief.headline, 'The headline is returned');
        Assert.areEqual('The policy was in force and a burst pipe is covered.', brief.coverage, 'The coverage point is returned');
        Assert.areEqual(2, brief.watch.size(), 'Both watch items are returned');
        Assert.areEqual('high', brief.watch[0].level, 'With their level');
        Assert.areEqual(2, brief.nextActions.size(), 'Both next actions are returned');
        Assert.isFalse(brief.nextActions[0].hasTask, 'An action with no task can be added as one');
        Assert.isTrue(brief.nextActions[1].hasTask, 'An action that matches an open task is marked');
        Assert.isFalse(brief.stale, 'A brief just written is current');
        Assert.isNotNull(brief.writtenAt, 'It is dated');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.request.getBody());
        String prompt = (String) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        Assert.isTrue(prompt.contains('Burst pipe flooded basement'), 'The claim is described');
        Assert.isTrue(prompt.contains('Reserve: $45,000, paid to date $5,000, outstanding reserve $40,000'), 'With its money');
        Assert.isTrue(prompt.contains('POLICY T-HOME-1: Homeowners'), 'Its policy');
        Assert.isTrue(prompt.contains('- Dwelling'), 'The policy\'s coverages');
        Assert.isTrue(prompt.contains('Exclusion: Earth Movement Exclusion'), 'Its exclusions');
        Assert.isTrue(prompt.contains('**Reserve set at $45,000**'), 'The file notes');
        Assert.isTrue(prompt.contains('- Review the mitigation invoice (open'), 'And the tasks');
        Assert.isTrue(prompt.contains('Coverage check (policy against date of loss): In force on date of loss'), 'The coverage check is included');
        Assert.isTrue(
            prompt.contains('PAYABLE: $46,000 (the $48,500 estimate less the $2,500 deductible). RESERVE: $45,000, which is $1,000 below the payable amount.'),
            'The reserve is measured against the estimate less the deductible, and the sum is worked out for Claude: ' + prompt
        );
        Assert.isTrue(prompt.contains('The limit and deductible are from the policy.'), 'With where the terms came from');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('HOW TO READ THE RESERVE'), 'The shared reserve rule is part of the instructions');
        Assert.isTrue(sent.contains(AntsuranceClaimRules.AMERICAN_ENGLISH), 'And American English is asked for');
        Assert.isTrue(
            sent.contains('never write today, tonight, tomorrow or yesterday: give the date'),
            'A brief is read on later days, so Claude is told to name the date and not the day'
        );
        Assert.isTrue(sent.indexOf('"standing":{') < sent.indexOf('"headline":{'), 'The headline is asked for last, after the findings');

        Case saved = claim();
        Assert.isNotNull(saved.Claude_Brief_At__c, 'The time is stored on the claim');
        String readable = AntsuranceClaimsAssistantBrief.readable(saved.Claude_Brief__c);
        Assert.isTrue(readable.startsWith('Get the invoice and estimate in'), 'The stored text opens with the headline');
        Assert.isTrue(readable.contains('**Coverage:** The policy was in force'), 'Then labeled points');
        Assert.isTrue(readable.contains('- **Subrogation:** A supply line failed at the fitting.'), 'The watch list');
        Assert.isTrue(readable.contains('1. Ask the insured to keep the failed supply line. It preserves recovery.'), 'And numbered next actions');
        Assert.isFalse(readable.contains('<!--'), 'The readable part leaves out the stored data');
        Assert.isTrue(saved.Claude_Brief__c.contains('<!-- antsurance-brief:v1 '), 'Which is kept after it');
    }

    @IsTest
    static void aStoredBriefIsShownAgainWithoutAskingClaude() {
        Id claimId = claim().Id;
        written(claimId);

        // No mock is set here, so a callout would fail the test.
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claimId);
        Assert.isTrue(brief.exists, 'The stored brief is found');
        Assert.areEqual('Drying is done and the file waits on two documents.', brief.standing, 'With its points');
        Assert.isFalse(brief.stale, 'Nothing has changed since it was written');
    }

    @IsTest
    static void changesToTheClaimMakeTheBriefOutOfDate() {
        Id claimId = claim().Id;
        written(claimId);

        update new Case(Id = claimId, Reserve_Amount__c = 48450, Status = 'Under Investigation');
        insert new File_Note__c(Case__c = claimId, Note_Type__c = 'Investigation', Body__c = 'Estimate received.', Note_Date__c = Datetime.now());
        insert new ContentVersion(Title = 'Rebuild estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('pdf'), FirstPublishLocationId = claimId);

        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claimId);
        Assert.isTrue(brief.stale, 'The brief is out of date');
        Assert.isTrue(brief.changes.contains('Reserve changed'), 'It says the reserve changed: ' + brief.changes);
        Assert.isTrue(brief.changes.contains('Status changed'), 'And the status');
        Assert.isTrue(brief.changes.contains('1 new file note'), 'And that a note was added');
        Assert.isTrue(brief.changes.contains('1 new document'), 'And a document');
        Assert.isFalse(brief.changes.contains('Estimate changed'), 'But not what stayed the same');
    }

    @IsTest
    static void aNoteSavedFromClaudesAnalysisIsNotNewEvidence() {
        Id claimId = claim().Id;
        written(claimId);

        insert new File_Note__c(
            Case__c = claimId, Note_Type__c = 'Investigation', Body__c = AntsuranceClaimRules.ANALYSIS_NOTE_OPENING + ' Coverage hinges on the water source.',
            Note_Date__c = Datetime.now(), Author_Name__c = AntsuranceClaimRules.claudeAuthor()
        );

        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claimId);
        Assert.isFalse(brief.stale, 'Claude\'s own analysis, saved as a note, does not make the brief out of date: ' + brief.changes);
    }

    @IsTest
    static void claudesOwnAnalysisNoteIsNotHandedBackAsEvidence() {
        Id claimId = claim().Id;
        insert new File_Note__c(
            Case__c = claimId, Note_Type__c = 'Investigation', Body__c = AntsuranceClaimRules.ANALYSIS_NOTE_OPENING + ' Coverage hinges on the water source.',
            Note_Date__c = Datetime.now()
        );
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantBrief.writeBrief(claimId);
        Test.stopTest();

        Assert.isFalse(mock.request.getBody().contains('Coverage hinges on the water source'), 'The brief is not written from Claude\'s own earlier report');
        Assert.isTrue(mock.request.getBody().contains('Reserve set at $45,000'), 'The notes people wrote are still sent');
    }

    @IsTest
    static void aReserveEqualToThePayableAmountIsCalledAdequate() {
        Id claimId = claim().Id;
        // The estimate less the deductible is now exactly the reserve.
        update new Case(Id = claimId, Estimated_Loss__c = 47500);
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantBrief.writeBrief(claimId);
        Test.stopTest();

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.request.getBody());
        String prompt = (String) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        Assert.isTrue(
            prompt.contains('PAYABLE: $45,000 (the $47,500 estimate less the $2,500 deductible). RESERVE: $45,000, equal to the payable amount, so the reserve covers it.'),
            'The deductible is not a shortfall: ' + prompt
        );
    }

    @IsTest
    static void addingATaskDoesNotMakeTheBriefOutOfDate() {
        Id claimId = claim().Id;
        AntsuranceClaimsAssistantBrief.Brief brief = written(claimId);

        AntsuranceClaimsAssistantBrief.addTask(claimId, brief.nextActions[0].action);

        // The claim automation adds its own follow-up tasks, so this one is found by its subject.
        Task added = [
            SELECT Subject, OwnerId, ActivityDate, IsClosed, WhoId
            FROM Task
            WHERE WhatId = :claimId AND Subject = 'Ask the insured to keep the failed supply line'
        ];
        Assert.areEqual(UserInfo.getUserId(), added.OwnerId, 'Assigned to whoever clicked');
        Assert.areEqual(Date.today().addDays(2), added.ActivityDate, 'Due in two days');
        Assert.isFalse(added.IsClosed, 'And open');
        Assert.isNotNull(added.WhoId, 'It names the claim\'s contact');

        AntsuranceClaimsAssistantBrief.Brief after = AntsuranceClaimsAssistantBrief.getBrief(claimId);
        Assert.isFalse(after.stale, 'Acting on the brief does not make it stale');
        Assert.isTrue(after.nextActions[0].hasTask, 'The action now shows as on the task list');
    }

    @IsTest
    static void aTaskNeedsASubject() {
        try {
            AntsuranceClaimsAssistantBrief.addTask(claim().Id, '  ');
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantBrief.EMPTY_TASK, e.getMessage(), 'An empty subject is refused');
        }
    }

    @IsTest
    static void aBriefWrittenByHandIsShownAndOfferedForRewrite() {
        Id claimId = claim().Id;
        update new Case(Id = claimId, Claude_Brief__c = 'Typed in by a handler.', Claude_Brief_At__c = Datetime.now());

        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claimId);
        Assert.isTrue(brief.exists, 'The text is shown');
        Assert.areEqual('Typed in by a handler.', brief.headline, 'As it was written');
        Assert.isTrue(brief.stale, 'And a rewrite is offered');
    }

    @IsTest
    static void onlyClaimsGetABrief() {
        Case request = [SELECT Id FROM Case WHERE Subject = 'Add a driver'];
        try {
            AntsuranceClaimsAssistantBrief.getBrief(request.Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantBrief.NOT_A_CLAIM, e.getMessage(), 'A service request is refused');
        }
        try {
            AntsuranceClaimsAssistantBrief.describeClaim(request.Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantBrief.NOT_A_CLAIM, e.getMessage(), 'Its file is not described either');
        }
    }

    @IsTest
    static void anApiFailureLeavesTheClaimUntouched() {
        Id claimId = claim().Id;
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(500, '{"error":{"message":"boom"}}'));

        Test.startTest();
        try {
            AntsuranceClaimsAssistantBrief.writeBrief(claimId);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().startsWith('Claude is temporarily unavailable.'), 'The failure is explained: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isNull(claim().Claude_Brief__c, 'Nothing was stored');
    }

    @IsTest
    static void theReadablePartOfAnEmptyBriefIsNull() {
        Assert.isNull(AntsuranceClaimsAssistantBrief.readable(null), 'No brief reads as nothing');
    }
    @IsTest
    static void theBriefIsToldWhatTheCoverageCheckLeftOpen() {
        Case checked = new Case(
            Coverage_Read__c = JSON.serialize(
                new Map<String, Object>{
                    'check' => new Map<String, Object>{
                        'verdict' => 'Needs review',
                        'summary' => 'Dwelling would cover a burst pipe, but silt in the photos raises doubt about the water source.',
                        'questions' => new List<Object>{ 'Where did the water come from?' },
                        'wouldChange' => new List<Object>{ 'Water from outside would bring the flood exclusion in.' }
                    }
                }
            )
        );

        List<String> lines = AntsuranceClaimsAssistantBrief.coverageCheckLines(checked);

        String block = String.join(lines, '\n');
        Assert.isTrue(block.contains('Verdict: Needs review'), 'The verdict is given: ' + block);
        Assert.isTrue(block.contains('Where did the water come from?'), 'with the open question');
        Assert.isTrue(block.contains('flood exclusion'), 'and what would change it');
        Assert.isTrue(AntsuranceClaimsAssistantBrief.coverageCheckLines(new Case()).isEmpty(), 'A claim with no check adds nothing');
        Assert.isTrue(AntsuranceClaimsAssistantBrief.coverageCheckLines(new Case(Coverage_Read__c = 'not json')).isEmpty(), 'nor does one that cannot be read');
    }

    @IsTest
    static void aNoteWrittenInSalesforceNotesIsReadWithTheFileNotes() {
        Id claimId = claim().Id;
        // A stand-in for the note, so this runs the same where the org has Notes turned off.
        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting behind the wall.', Datetime.now().addDays(-1));
        AntsuranceSalesforceNotes.standIn(claimId, 'Estimate chased', 'Asked the contractor for the estimate again.', Datetime.now().addDays(-3));
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.writeBrief(claimId);
        Test.stopTest();

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.request.getBody());
        String prompt = (String) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        String notes = prompt.substringBetween('FILE NOTES, newest first:', 'TASKS:');
        Assert.isTrue(notes.contains('Salesforce note, ' + UserInfo.getName() + '] **Body shop call:**'), 'The Salesforce note is among the file notes, under its own type and writer: ' + notes);
        Assert.isTrue(notes.contains('The shop found a cracked fitting behind the wall.'), 'With its words');
        Assert.isTrue(
            notes.indexOf('Body shop call') < notes.indexOf('Reserve set at') && notes.indexOf('Reserve set at') < notes.indexOf('Estimate chased'),
            'Each in its place by date: one is newer than the reserve note and one is older'
        );
        Assert.isFalse(brief.stale, 'A brief just written is current');
    }

    @IsTest
    static void aNewSalesforceNoteMakesTheBriefOutOfDateAsANote() {
        Id claimId = claim().Id;
        written(claimId);

        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting.', Datetime.now());
        Assert.areEqual(new List<String>{ '1 new file note' }, AntsuranceClaimsAssistantBrief.getBrief(claimId).changes, 'It is a new note, and no document was added');

        // A brief written before Salesforce notes were read as notes counted this one among the documents.
        String stored = claim().Claude_Brief__c;
        String open = '<!-- antsurance-brief:v1 ';
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(stored.substringAfter(open).substringBeforeLast(' -->'));
        Map<String, Object> facts = (Map<String, Object>) data.get('facts');
        facts.remove(AntsuranceSalesforceNotes.COUNT_KEY);
        facts.put('documents', 1);
        update new Case(Id = claimId, Claude_Brief__c = stored.substringBefore(open) + open + JSON.serialize(data) + ' -->');
        Assert.areEqual(new List<String>{ '1 new file note' }, AntsuranceClaimsAssistantBrief.getBrief(claimId).changes, 'That brief reads out of date once, as a new note and not as a document removed');
    }

    @IsTest
    static void anEditToASalesforceNoteMakesTheBriefOutOfDate() {
        Id claimId = claim().Id;
        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting.', Datetime.now());
        Assert.isFalse(written(claimId).stale, 'A brief written with the note is current');

        AntsuranceSalesforceNotes.standIns.get(claimId)[0].editedAt = Datetime.now().addMinutes(5);
        Assert.areEqual(new List<String>{ 'A file note was edited' }, AntsuranceClaimsAssistantBrief.getBrief(claimId).changes, 'Until the note is edited in Salesforce Notes');
    }
}
