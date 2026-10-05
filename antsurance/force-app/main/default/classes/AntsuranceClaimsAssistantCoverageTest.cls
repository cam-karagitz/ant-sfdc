@IsTest
private class AntsuranceClaimsAssistantCoverageTest {
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
        insert new List<Policy_Coverage__c>{
            new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 500000, Deductible_Amount__c = 2500, What_Is_Covered__c = 'Rebuilds the home after a covered loss.'),
            new Policy_Coverage__c(Name = 'Personal Liability', Policy__c = policy.Id, Limit_Amount__c = 300000, What_Is_Covered__c = 'Injury to others.')
        };
        insert new List<Policy_Endorsement__c>{
            new Policy_Endorsement__c(Name = 'Earth Movement Exclusion', Policy__c = policy.Id, Type__c = 'Exclusion', Description__c = 'Earthquake is not covered.'),
            new Policy_Endorsement__c(Name = 'Water Backup', Policy__c = policy.Id, Type__c = 'Endorsement', Form_Number__c = 'HO 04 95', Limit_Amount__c = 10000, Description__c = 'Sewer and drain backup.')
        };
        insert new Policy_Participant__c(Name = 'Maya Harbor, Named Insured', Policy__c = policy.Id, Contact__c = person.Id, Role__c = 'Named Insured', Status__c = 'Active');
        insert new Policy_Asset__c(Name = '12 Quay St', Policy__c = policy.Id, Asset_Type__c = 'Dwelling', Location__c = '12 Quay St, Evanston, IL', Insured_Value__c = 500000);
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Case claim = new Case(
            RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Description = 'A supply line burst.', Policy__c = policy.Id, Status = 'New',
            Severity__c = 'High', Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-5), Reported_Date__c = Date.today().addDays(-4),
            Estimated_Loss__c = 48500, Reserve_Amount__c = 45000
        );
        insert claim;
        insert new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Coverage', Body__c = 'Inspection found a failed braided supply line.', Note_Date__c = Datetime.now().addDays(-2), Author_Name__c = 'Marcus Lindahl');
        insert new List<Case>{
            new Case(RecordTypeId = claimType, Subject = 'Claim with no policy', Status = 'New', Loss_Type__c = 'Other'),
            new Case(
                RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
                Subject = 'Add a driver', Policy__c = policy.Id, Status = 'New'
            )
        };
    }

    private static Case claim() {
        return [
            SELECT Id, Coverage_Read__c, Coverage_Read_At__c, Coverage_Verdict__c, Coverage_Confirmed_By__c, Coverage_Confirmed_At__c
            FROM Case
            WHERE Subject = 'Burst pipe flooded basement'
        ];
    }

    private static String reply(String verdict, String responding) {
        Map<String, Object> answer = new Map<String, Object>{
            'findings' => new List<Object>{
                new Map<String, Object>{ 'text' => 'The loss fell inside the policy term.', 'source' => 'POLICY' },
                new Map<String, Object>{ 'text' => 'Dwelling pays to rebuild after a burst pipe.', 'source' => 'C1' },
                new Map<String, Object>{ 'text' => 'The exclusion is for earthquake, which this is not.', 'source' => 'E1' },
                new Map<String, Object>{ 'text' => 'This cites a record that was never given.', 'source' => 'C9' }
            },
            'responding' => responding,
            'verdict' => verdict,
            'liability_open' => responding == 'C2',
            'summary' => 'The policy was in force and Dwelling responds to a burst supply line.',
            'questions' => new List<Object>{ 'When did you first see water?' },
            'would_change' => new List<Object>{ 'Evidence the leak was gradual would change this.' }
        };
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    /** Runs a check outside the test's own limits, so the test can then change the claim. */
    private static AntsuranceClaimsAssistantCoverage.Check written(Id claimId) {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('Covered', 'C1')));
        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
        Test.stopTest();
        return check;
    }

    @IsTest
    static void aClaimNotYetCheckedSaysSo() {
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.getCheck(claim().Id);
        Assert.isFalse(check.exists, 'Coverage has not been checked yet');
        Assert.isFalse(check.stale, 'So there is nothing to be out of date');
    }

    @IsTest
    static void checkingSendsEveryRecordUnderItsKeyAndStoresTheAnswer() {
        Id claimId = claim().Id;
        ClaudeMock mock = new ClaudeMock(200, reply('Covered', 'C1'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
        Test.stopTest();

        Assert.isTrue(check.exists, 'The check exists');
        Assert.areEqual('Covered', check.verdict, 'The verdict is returned');
        Assert.areEqual('Dwelling', check.respondingLabel, 'The responding coverage is named from its record');
        Assert.areEqual(500000, check.limitAmount, 'Its limit is read from the coverage, not from Claude');
        Assert.areEqual(2500, check.deductible, 'So is its deductible');
        Assert.areEqual(46000, check.payable, 'Payable is the estimate less the deductible');
        Assert.isFalse(check.cappedByLimit, 'Which is under the limit');
        Assert.isFalse(check.liabilityOpen, 'A loss to the insured\'s own home does not turn on liability');
        Assert.areEqual(4, check.findings.size(), 'Every finding is kept');
        Assert.areEqual('Policy', check.findings[0].sourceKind, 'A finding says what kind of record it rests on');
        Assert.isNotNull(check.findings[1].recordId, 'And links to it');
        Assert.areEqual('Earth Movement Exclusion', check.findings[2].sourceLabel, 'An exclusion is named');
        Assert.isNull(check.findings[3].recordId, 'A record that was never given cannot be linked');
        Assert.areEqual(1, check.questions.size(), 'The open question is returned');

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('[C1] Dwelling'), 'The coverage goes under its key');
        Assert.isTrue(sent.contains('Claim status: New'), 'The claim\'s status is sent, so a denial can be weighed');
        Assert.isTrue(sent.contains('[E1] Exclusion: Earth Movement Exclusion'), 'So does the exclusion');
        Assert.isTrue(sent.contains('form HO 04 95'), 'An endorsement carries its form number');
        Assert.isTrue(sent.contains('Maya Harbor, Named Insured: role Named Insured'), 'The people on the policy are sent');
        Assert.isTrue(sent.contains('Dwelling: 12 Quay St'), 'So is what it insures');
        Assert.isTrue(sent.contains('failed braided supply line'), 'And the file notes');
        Assert.isTrue(sent.contains('"enum":["CLAIM","POLICY","C1","C2","E1","E2","P1","A1","N1"]'), 'Claude may cite only the records it was given');
        Assert.isTrue(sent.contains('"enum":["C1","C2","E2","NONE"]'), 'And only a coverage or an endorsement can respond, never an exclusion');

        Case saved = claim();
        Assert.areEqual('Covered', saved.Coverage_Verdict__c, 'The verdict is stored for lists and reports');
        Assert.isNotNull(saved.Coverage_Read_At__c, 'With the time it was written');
        AntsuranceClaimsAssistantCoverage.Check again = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.areEqual(46000, again.payable, 'The stored check reads back');
        Assert.isFalse(again.stale, 'And is current');
    }

    @IsTest
    static void aLossAboveTheLimitIsCappedAndOneNotCoveredPaysNothing() {
        Assert.areEqual(10000, AntsuranceClaimsAssistantCoverage.payableOn(48500, 10000, 2500, 'Covered', true), 'The limit caps what is payable');
        Assert.areEqual(0, AntsuranceClaimsAssistantCoverage.payableOn(48500, 500000, 2500, 'Not covered', true), 'Nothing is payable on a loss that is not covered');
        Assert.areEqual(0, AntsuranceClaimsAssistantCoverage.payableOn(1800, 500000, 2500, 'Covered', true), 'Nor on a loss under the deductible');
        Assert.isNull(AntsuranceClaimsAssistantCoverage.payableOn(null, 500000, 2500, 'Covered', true), 'With no estimate the figure is unknown');
        Assert.isNull(AntsuranceClaimsAssistantCoverage.payableOn(48500, null, null, 'Needs review', false), 'As it is when no coverage responds yet');
        Assert.areEqual(46000, AntsuranceClaimsAssistantCoverage.payableOn(48500, null, 2500, 'Covered', true), 'A coverage with no stated limit pays the loss less the deductible');
    }

    @IsTest
    static void anEndorsementThatRespondsBringsItsOwnLimitAndThePolicyDeductible() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('Covered', 'E2')));
        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claim().Id);
        Test.stopTest();

        Assert.areEqual('Water Backup', check.respondingLabel, 'The endorsement responds');
        Assert.areEqual('Endorsement', check.respondingKind, 'And is shown as one');
        Assert.areEqual(10000, check.limitAmount, 'With its own limit');
        Assert.areEqual(10000, check.payable, 'Which caps what is payable');
        Assert.isTrue(check.cappedByLimit, 'And the card can say so');
    }

    @IsTest
    static void aLiabilityLossSaysWhenResponsibilityIsStillOpen() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('Covered', 'C2')));
        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claim().Id);
        Test.stopTest();

        Assert.areEqual('Personal Liability', check.respondingLabel, 'The liability coverage responds');
        Assert.isTrue(check.liabilityOpen, 'And the card can say payment turns on responsibility');
        Assert.areEqual(48500, check.payable, 'A coverage with no deductible pays the whole estimate, if it pays');
    }

    @IsTest
    static void aLossNotCoveredNamesNoCoverageAndPaysNothing() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('Not covered', 'NONE')));
        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claim().Id);
        Test.stopTest();

        Assert.areEqual('Not covered', check.verdict, 'The verdict is returned');
        Assert.isNull(check.respondingLabel, 'No coverage responds');
        Assert.areEqual(0, check.payable, 'And nothing is payable');
    }

    @IsTest
    static void aVerdictThatIsNotOneOfTheThreeBecomesNeedsReview() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('Probably', 'C1')));
        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.writeCheck(claim().Id);
        Test.stopTest();
        Assert.areEqual('Needs review', check.verdict, 'An unknown verdict is never shown as an answer');
    }

    @IsTest
    static void aChangeToTheClaimOrThePolicyMakesTheCheckStale() {
        Id claimId = claim().Id;
        written(claimId);

        update new Case(Id = claimId, Estimated_Loss__c = 61000);
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'T-HOME-1'];
        insert new Policy_Endorsement__c(Name = 'Scheduled Jewelry', Policy__c = policy.Id, Type__c = 'Endorsement');
        update new Policy__c(Id = policy.Id, Status__c = 'Cancelled');

        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isTrue(check.stale, 'The check is out of date');
        Assert.isTrue(check.changes.contains('Estimate changed'), 'It says the estimate changed');
        Assert.isTrue(check.changes.contains('Endorsements added or removed'), 'And the endorsements');
        Assert.isTrue(check.changes.contains('Policy status changed'), 'And the policy status');
    }

    @IsTest
    static void aNoteSavedFromClaudesAnalysisDoesNotMakeTheCheckStale() {
        Id claimId = claim().Id;
        written(claimId);

        insert new File_Note__c(
            Case__c = claimId, Note_Type__c = 'Investigation', Body__c = AntsuranceClaimRules.ANALYSIS_NOTE_OPENING + ' Coverage hinges on the water source.',
            Note_Date__c = Datetime.now(), Author_Name__c = AntsuranceClaimRules.claudeAuthor()
        );
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.getCheck(claimId).stale, 'Claude\'s own saved report is not new evidence');

        insert new File_Note__c(Case__c = claimId, Note_Type__c = 'Investigation', Body__c = 'The plumber found a failed supply line.', Note_Date__c = Datetime.now());
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isTrue(check.stale, 'A note a person wrote still is');
        Assert.isTrue(check.changes.contains('New file notes'), 'And the check says so: ' + check.changes);
    }

    @IsTest
    static void anApprovedLetterDoesNotMakeTheCheckStale() {
        Id claimId = claim().Id;
        written(claimId);

        // Approving a letter leaves a file note and a PDF on the claim. Both are the carrier's own word, written from this check.
        File_Note__c letter = new File_Note__c(
            Case__c = claimId, Note_Type__c = 'Coverage', Note_Date__c = Datetime.now(),
            Body__c = AntsuranceClaimLetters.NOTE_OPENING + ' Coverage confirmation, to Maya Harbor. Drafted by Claude, then read, edited and approved by Marcus Lindahl.'
        );
        insert letter;
        insert new ContentVersion(
            Title = 'Coverage confirmation, Oct 5, 2026', PathOnClient = 'letter.pdf', VersionData = Blob.valueOf('%PDF-1.4 letter'),
            Description = AntsuranceClaimLetters.FILE_MARK + letter.Id, FirstPublishLocationId = claimId
        );
        Assert.isTrue(AntsuranceClaimLetters.isLetterNote(letter), 'The note is one the letters class knows as its own');
        AntsuranceClaimsAssistantCoverage.Check afterLetter = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isFalse(afterLetter.stale, 'So the check can still be confirmed after a letter is approved: ' + afterLetter.changes);
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(claimId);
        Assert.isTrue(facts.documents.isEmpty(), 'The letter is not among the documents Claude is told are attached');
        Assert.areEqual(1, facts.ownLetters.size(), 'It is set aside as the carrier\'s own');

        insert new ContentVersion(Title = 'Plumber report', PathOnClient = 'report.pdf', VersionData = Blob.valueOf('%PDF-1.4 report'), FirstPublishLocationId = claimId);
        AntsuranceClaimsAssistantCoverage.Check afterEvidence = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isTrue(afterEvidence.stale, 'A document that came in still makes it out of date');
        Assert.areEqual(new List<String>{ 'Documents added or removed' }, afterEvidence.changes, 'And only that is named');
    }

    @IsTest
    static void theAgentsCheckStandsUntilTheClaimOrThePhotoAssessmentChanges() {
        Id claimId = claim().Id;
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(claimId);
        AntsuranceClaimsAssistantCoverage.withExtra(facts, 'Mitigation invoice: Category 2 water from the supply line.');
        AntsuranceClaimsAssistantCoverage.Check finding = AntsuranceClaimsAssistantCoverage.checkFrom(
            new Map<String, Object>{ 'findings' => new List<Object>(), 'responding' => 'C1', 'verdict' => 'Covered', 'summary' => 'Dwelling responds.' },
            facts
        );
        AntsuranceClaimsAssistantCoverage.store(claimId, finding, facts, new Map<String, Object>{ AntsuranceClaimsAssistantCoverage.AGENT_PART => new Map<String, Object>{ 'harness' => 'Claude Managed Agents' } });
        AntsuranceClaimsAssistantCoverage.confirm(claimId);
        String analysisEvidence = 'Photographs (3): soaked furniture. Rebuild estimate "Rebuild estimate", total $27,450: a contractor estimate.';

        AntsuranceClaimsAssistantCoverage.Check agents = AntsuranceClaimsAssistantCoverage.read(claimId);
        Assert.isTrue(agents.byAgent, 'The check knows the agent reached it');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.stands(agents, analysisEvidence, agents.writtenAt.addMinutes(-10)), 'It stands though its evidence is worded differently: the agent read the file itself');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.stands(agents, analysisEvidence, null), 'And when the caller has no photo assessment');
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.stands(agents, analysisEvidence, agents.writtenAt.addMinutes(10)), 'Not once the photographs are assessed again after it');
        // No mock is set: asking Claude here would fail the test.
        Assert.areEqual(agents.writtenAt, AntsuranceClaimsAssistantCoverage.readOrRun(claimId, analysisEvidence).writtenAt, 'Other Apex gets the agent\'s check as stored');
        Assert.isNotNull(claim().Coverage_Confirmed_At__c, 'And the adjuster\'s confirmation is still on it');

        agents.byAgent = false;
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.stands(agents, analysisEvidence, null), 'A single-call check must have been given the same evidence');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.stands(agents, 'Mitigation invoice: Category 2 water from the supply line.', null), 'As this one was');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.stands(agents, null, null), 'Or be asked for with none');

        update new Case(Id = claimId, Estimated_Loss__c = 61000);
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.stands(AntsuranceClaimsAssistantCoverage.read(claimId), analysisEvidence, null), 'A change to the claim ends it for the agent\'s check too');
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.stands(new AntsuranceClaimsAssistantCoverage.Check(), null, null), 'And no check never stands');
    }

    @IsTest
    static void theCheckCarriesTheSharedReserveRule() {
        Id claimId = claim().Id;
        ClaudeMock mock = new ClaudeMock(200, reply('Covered', 'C1'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
        Test.stopTest();

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('HOW TO READ THE RESERVE'), 'The rule every writer shares');
        Assert.isTrue(sent.contains('never call it short because it is below the gross estimate'), 'With what it means for this check');
        Assert.isTrue(sent.contains(AntsuranceClaimRules.AMERICAN_ENGLISH), 'In American English');
    }

    @IsTest
    static void confirmingRecordsWhoAndWhen() {
        Id claimId = claim().Id;
        written(claimId);

        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.confirm(claimId);
        Assert.areEqual(UserInfo.getName(), check.confirmedBy, 'The adjuster is named');
        Assert.isNotNull(check.confirmedAt, 'With the time');
        Case saved = claim();
        Assert.areEqual(UserInfo.getName(), saved.Coverage_Confirmed_By__c, 'And it is stored on the claim');
    }

    @IsTest
    static void checkingAgainClearsAnEarlierConfirmation() {
        Id claimId = claim().Id;
        Case before = new Case(Id = claimId, Coverage_Read__c = '{"check":{"exists":true,"verdict":"Covered"},"facts":{}}', Coverage_Confirmed_By__c = 'Someone Else', Coverage_Confirmed_At__c = Datetime.now());
        update before;

        written(claimId);

        Case saved = claim();
        Assert.isNull(saved.Coverage_Confirmed_By__c, 'A new read has not been confirmed by anyone');
        Assert.isNull(saved.Coverage_Confirmed_At__c, 'So the time is cleared too');
    }

    @IsTest
    static void thereMustBeACheckToConfirm() {
        try {
            AntsuranceClaimsAssistantCoverage.confirm(claim().Id);
            Assert.fail('Nothing has been checked');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NOTHING_TO_CONFIRM, e.getMessage(), 'It says so');
        }
    }

    @IsTest
    static void aServiceRequestIsRefused() {
        Id requestId = [SELECT Id FROM Case WHERE Subject = 'Add a driver'].Id;
        try {
            AntsuranceClaimsAssistantCoverage.writeCheck(requestId);
            Assert.fail('A service request is not a claim');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NOT_A_CLAIM, e.getMessage(), 'It says why');
        }
        try {
            AntsuranceClaimsAssistantCoverage.getCheck(requestId);
            Assert.fail('Nor can one be read');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NOT_A_CLAIM, e.getMessage(), 'For the same reason');
        }
    }

    @IsTest
    static void aClaimWithNoPolicyIsNotSentToClaude() {
        Id claimId = [SELECT Id FROM Case WHERE Subject = 'Claim with no policy'].Id;
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.getCheck(claimId).exists, 'It reads as not yet checked');
        try {
            AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
            Assert.fail('There is no policy to check against');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NO_POLICY, e.getMessage(), 'It says so');
        }
    }

    @IsTest
    static void aFailureFromClaudeIsReportedAndNothingIsStored() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(500, '{"type":"error","error":{"type":"api_error","message":"Internal error"}}'));
        Test.startTest();
        try {
            AntsuranceClaimsAssistantCoverage.writeCheck(claim().Id);
            Assert.fail('The call failed');
        } catch (AuraHandledException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'The person is told');
        }
        Test.stopTest();
        Assert.isNull(claim().Coverage_Read__c, 'Nothing is stored');
    }

    @IsTest
    static void otherApexCanRunTheCheckWithFactsFromTheEvidence() {
        Id claimId = claim().Id;
        Map<String, Object> answer = new Map<String, Object>{
            'findings' => new List<Object>{
                new Map<String, Object>{ 'text' => 'The photos show water staining only below the supply line.', 'source' => 'EXTRA' },
                new Map<String, Object>{ 'text' => 'Dwelling pays to rebuild after a burst pipe.', 'source' => 'C1' },
                new Map<String, Object>{ 'text' => 'The loss fell inside the policy term.', 'source' => 'POLICY' }
            },
            'responding' => 'C1',
            'verdict' => 'Covered',
            'summary' => 'Covered under Dwelling.',
            'questions' => new List<Object>(),
            'would_change' => new List<Object>()
        };
        ClaudeMock mock = new ClaudeMock(
            200,
            JSON.serialize(
                new Map<String, Object>{
                    'model' => 'claude-opus-5-5',
                    'stop_reason' => 'end_turn',
                    'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
                }
            )
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantCoverage.Check shown = AntsuranceClaimsAssistantCoverage.preview(claimId, 'Photo 1 shows staining below the supply line.');
        Assert.isNull(claim().Coverage_Read__c, 'A preview stores nothing');
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.readOrRun(claimId, 'Photo 1 shows staining below the supply line.');
        Test.stopTest();

        Assert.areEqual('Covered', shown.verdict, 'The preview is a full check');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('[EXTRA] Photo 1 shows staining below the supply line.'), 'The extra facts are sent under their own key');
        Assert.isTrue(sent.contains('"N1","EXTRA"]'), 'And can be cited');
        Assert.areEqual('Evidence', check.findings[0].sourceKind, 'A finding can rest on the evidence');
        Assert.isNull(check.findings[0].recordId, 'Which is not a record to open');
        Assert.areEqual('Photo 1 shows staining below the supply line.', check.extraFacts, 'The check says what else it was reasoned against');

        AntsuranceClaimsAssistantCoverage.Check kept = AntsuranceClaimsAssistantCoverage.read(claimId);
        Assert.isTrue(kept.exists, 'Running it stored it');
        Assert.areEqual(check.extraFacts, kept.extraFacts, 'With the extra facts');
        // No mock response is needed for this: a current check with the same facts is returned as stored.
        Assert.areEqual(kept.writtenAt, AntsuranceClaimsAssistantCoverage.readOrRun(claimId, 'Photo 1 shows staining below the supply line.').writtenAt, 'A current check is not run again');
    }

    @IsTest
    static void otherApexIsToldPlainlyWhenThereIsNothingToCheck() {
        try {
            AntsuranceClaimsAssistantCoverage.read([SELECT Id FROM Case WHERE Subject = 'Add a driver'].Id);
            Assert.fail('A service request is not a claim');
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NOT_A_CLAIM, e.getMessage(), 'It says why, as an exception any Apex can catch');
        }
        try {
            AntsuranceClaimsAssistantCoverage.run([SELECT Id FROM Case WHERE Subject = 'Claim with no policy'].Id, null);
            Assert.fail('There is no policy to check against');
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NO_POLICY, e.getMessage(), 'It says so');
        }
    }

    /** A callout that never answers, as when Claude takes longer than the transaction allows. */
    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    @IsTest
    static void aCheckThatTimesOutSaysSoAndLeavesTheStoredCheckAlone() {
        Id claimId = claim().Id;
        update new Case(
            Id = claimId,
            Coverage_Read__c = '{"check":{"exists":true,"verdict":"Covered","summary":"Covered under Dwelling.","findings":[],"questions":[],"wouldChange":[]},"facts":{}}',
            Coverage_Read_At__c = Datetime.now().addHours(-2),
            Coverage_Verdict__c = 'Covered'
        );
        Test.setMock(HttpCalloutMock.class, new TimeoutMock());

        Test.startTest();
        String told;
        try {
            AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
            Assert.fail('The call timed out');
        } catch (AuraHandledException e) {
            told = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(told), 'The person is told what happened, in words');
        Assert.isFalse(told.containsIgnoreCase('CalloutException'), 'Not shown the platform error');
        AntsuranceClaimsAssistantCoverage.Check kept = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isTrue(kept.exists, 'The check from before is still there');
        Assert.areEqual('Covered', kept.verdict, 'Unchanged');
        Assert.areEqual('Covered', claim().Coverage_Verdict__c, 'And so is what is stored on the claim');
    }

    @IsTest
    static void aStoredValueThisCardDidNotWriteReadsAsNotChecked() {
        Id claimId = claim().Id;
        update new Case(Id = claimId, Coverage_Read__c = 'typed by hand');
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.getCheck(claimId).exists, 'So the card offers a fresh check');
    }

    @IsTest
    static void aNoteWrittenInSalesforceNotesIsReadAsANote() {
        Id claimId = claim().Id;
        // A stand-in for the note, so this runs the same where the org has Notes turned off.
        Datetime calledAt = Datetime.now().addDays(-1);
        Id noteId = AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting behind the wall.', calledAt);
        ClaudeMock mock = new ClaudeMock(200, reply('Covered', 'C1'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantCoverage.writeCheck(claimId);
        Test.stopTest();

        String sent = mock.request.getBody();
        Assert.isTrue(
            sent.substringBetween('[N1] ', '[N2] ').contains('Salesforce note, ' + UserInfo.getName() + ') **Body shop call:**'),
            'The Salesforce note is the newer of the two notes, under its own type and writer'
        );
        Assert.isTrue(sent.contains('The shop found a cracked fitting behind the wall.'), 'With its words');
        Assert.isTrue(sent.substringAfter('[N2] ').contains('failed braided supply line'), 'The file note follows it, by date');
        Assert.isTrue(sent.contains('"N1","N2"]'), 'And Claude may cite it by its N key');

        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(claimId);
        Assert.areEqual(2, facts.snapshot.get('notes'), 'It is counted among the notes');
        Assert.areEqual(0, facts.snapshot.get('documents'), 'And not among the documents');
        Integer linked = 0;
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            if (entry.key == 'N1') {
                linked++;
                Assert.areEqual('File note', entry.kind, 'A finding that rests on it rests on a note');
                Assert.areEqual('Salesforce note, ' + calledAt.format('MMM d'), entry.label, 'Named as a Salesforce note with its date');
                Assert.areEqual(noteId, entry.recordId, 'And links to the note itself');
            }
        }
        Assert.areEqual(1, linked, 'It is one of the records a finding can cite');
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.getCheck(claimId).stale, 'The check just written is current');
    }

    @IsTest
    static void aNewSalesforceNoteMakesTheCheckStaleAsANote() {
        Id claimId = claim().Id;
        written(claimId);

        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting.', Datetime.now());
        Assert.areEqual(new List<String>{ 'New file notes' }, AntsuranceClaimsAssistantCoverage.getCheck(claimId).changes, 'It is a new note, and no document was added or removed');

        // A check written before Salesforce notes were read as notes counted this one among the documents.
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(claim().Coverage_Read__c);
        Map<String, Object> facts = (Map<String, Object>) data.get('facts');
        facts.remove(AntsuranceSalesforceNotes.COUNT_KEY);
        facts.put('documents', 1);
        update new Case(Id = claimId, Coverage_Read__c = JSON.serialize(data));
        Assert.areEqual(new List<String>{ 'New file notes' }, AntsuranceClaimsAssistantCoverage.getCheck(claimId).changes, 'That check reads out of date once, in the same true words');
    }

    /** A letter as the adjuster approves it. */
    private static String letterToApprove() {
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.ACKNOWLEDGMENT;
        letter.addressee = new List<String>{ 'Maya Harbor', '12 Quay St', 'Evanston, IL 60201' };
        letter.reference = new List<String>{ 'Re: Claim 00001, Burst pipe flooded basement', 'Policy number: T-HOME-1' };
        letter.salutation = 'Dear Maya Harbor,';
        letter.body = 'We have received your claim.\n\nMarcus Lindahl is handling it.';
        letter.signer = new List<String>{ 'Marcus Lindahl', 'Property Adjuster', 'Antsurance Insurance Company' };
        return JSON.serialize(letter);
    }

    @IsTest
    static void approvingALetterLeavesASingleCallCheckAndAnAgentsCheckCurrent() {
        Id claimId = claim().Id;
        // The claim this was reported on carried a Salesforce note as well, so one is on the claim throughout.
        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting.', Datetime.now().addHours(-1));

        // The single-call check, then a letter approved the way the page does it: the note, then its PDF.
        written(claimId);
        Id firstLetter = AntsuranceClaimLetters.approve(claimId, letterToApprove());
        AntsuranceClaimLetters.savePdf(firstLetter);
        AntsuranceClaimsAssistantCoverage.Check single = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isFalse(single.byAgent, 'This check is the single call\'s');
        Assert.isFalse(single.stale, 'An approved letter does not make it out of date, so it can still be confirmed: ' + single.changes);

        // The coverage agent's check, stored from the agent's own facts as the agent stores it, then a second letter.
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceCoverageAgentTools.facts(claimId);
        AntsuranceClaimsAssistantCoverage.Check finding = AntsuranceClaimsAssistantCoverage.checkFrom(
            new Map<String, Object>{ 'findings' => new List<Object>(), 'responding' => 'C1', 'verdict' => 'Covered', 'summary' => 'Dwelling responds.' },
            facts
        );
        AntsuranceClaimsAssistantCoverage.store(claimId, finding, facts, new Map<String, Object>{ AntsuranceClaimsAssistantCoverage.AGENT_PART => new Map<String, Object>{ 'harness' => 'Claude Managed Agents' } });
        Id secondLetter = AntsuranceClaimLetters.approve(claimId, letterToApprove());
        AntsuranceClaimLetters.savePdf(secondLetter);
        AntsuranceClaimsAssistantCoverage.Check agents = AntsuranceClaimsAssistantCoverage.getCheck(claimId);
        Assert.isTrue(agents.byAgent, 'This check is the agent\'s');
        Assert.isFalse(agents.stale, 'Nor does a letter make the agent\'s check out of date: ' + agents.changes);

        AntsuranceClaimsAssistantCoverage.Facts now = AntsuranceClaimsAssistantCoverage.factsFor(claimId);
        Assert.areEqual(2, [SELECT COUNT() FROM File_Note__c WHERE Id IN :new List<Id>{ firstLetter, secondLetter }], 'Both letters left their note on the claim');
        Assert.areEqual(2, now.ownLetters.size(), 'And their PDF, set aside as the carrier\'s own');
        Assert.areEqual(2, now.snapshot.get('notes'), 'The notes counted are the inspection note and the Salesforce note, not the letters\'');
        Assert.areEqual(0, now.snapshot.get('documents'), 'And no document is counted');
    }
}
