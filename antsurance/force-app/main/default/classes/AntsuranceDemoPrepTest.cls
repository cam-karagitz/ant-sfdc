@IsTest
private class AntsuranceDemoPrepTest {
    /** Answers with one canned response, or fails the way a slow call does, and counts the calls. */
    private class ClaudeMock implements HttpCalloutMock {
        String body;
        Boolean timesOut = false;
        Integer calls = 0;

        ClaudeMock(String body) {
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            if (timesOut) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void createShowcaseClaims() {
        Account customer = new Account(Name = 'Okafor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Chinedu', LastName = 'Okafor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-9',
            Account__c = customer.Id,
            Primary_Insured__c = person.Id,
            Line_of_Business__c = 'Homeowners',
            Status__c = 'Active',
            Effective_Date__c = start,
            Expiration_Date__c = start.addYears(1),
            Insured_Item__c = '12 Quay St, Evanston, IL',
            Coverage_Limit__c = 620000,
            Deductible__c = 2500
        );
        insert policy;
        insert new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 620000, Deductible_Amount__c = 2500, What_Is_Covered__c = 'Rebuilds the home after a covered loss.');
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        List<Case> claims = new List<Case>();
        for (String subject : new List<String>{
            AntsuranceDemoPrep.PIPE_CLAIM,
            AntsuranceDemoPrep.SCRAPE_CLAIM,
            AntsuranceDemoPrep.REAR_END_CLAIM,
            AntsuranceDemoPrep.ROOF_CLAIM
        }) {
            Boolean isPipe = subject == AntsuranceDemoPrep.PIPE_CLAIM;
            claims.add(
                new Case(
                    RecordTypeId = claimType,
                    Subject = subject,
                    Description = 'What happened, as the insured told it.',
                    AccountId = customer.Id,
                    ContactId = person.Id,
                    Policy__c = policy.Id,
                    Status = 'New',
                    Severity__c = 'High',
                    Loss_Type__c = 'Water Damage',
                    Date_of_Loss__c = Date.today().addDays(-5),
                    Reported_Date__c = Date.today().addDays(-4),
                    Handled_By__c = 'Marcus Lindahl',
                    Estimated_Loss__c = isPipe ? AntsuranceDemoPrep.PIPE_FIRST_ESTIMATE : 6800,
                    Reserve_Amount__c = isPipe ? 45000 : 0,
                    Paid_Amount__c = isPipe ? 5000 : 0
                )
            );
        }
        insert claims;
    }

    private static Case claim(String subject) {
        return [SELECT Id, CaseNumber, Estimated_Loss__c, Claude_Brief_At__c FROM Case WHERE Subject = :subject];
    }

    private static Set<String> titlesOn(Id claimId) {
        Set<String> titles = new Set<String>();
        for (ContentDocumentLink link : [SELECT ContentDocument.Title FROM ContentDocumentLink WHERE LinkedEntityId = :claimId]) {
            titles.add(link.ContentDocument.Title);
        }
        return titles;
    }

    private static String keyFor(String subject, String kind) {
        for (AntsuranceDemoPrep.Step step : AntsuranceDemoPrep.steps()) {
            if (step.claim == subject && step.key.contains(':' + kind)) {
                return step.key;
            }
        }
        return null;
    }

    private static String briefReply() {
        return briefReply('Drying is done and the file waits on two documents.');
    }

    private static String briefReply(String standing) {
        Map<String, Object> answer = new Map<String, Object>{
            'standing' => standing,
            'coverage' => 'The policy was in force and a burst pipe is covered.',
            'money' => 'The reserve is short of what is payable.',
            'watch' => new List<Object>{ new Map<String, Object>{ 'label' => 'Subrogation', 'level' => 'high', 'text' => 'A supply line failed at the fitting.' } },
            'next_actions' => new List<Object>{ new Map<String, Object>{ 'action' => 'Review the mitigation invoice', 'reason' => 'It confirms the drying cost.' } },
            'headline' => 'Review the two documents, then settle the reserve.'
        };
        return wrapped(answer);
    }

    private static String coverageReply() {
        return wrapped(
            new Map<String, Object>{
                'findings' => new List<Object>{ new Map<String, Object>{ 'text' => 'Dwelling pays to rebuild after a burst pipe.', 'source' => 'C1' } },
                'responding' => 'C1',
                'verdict' => 'Covered',
                'liability_open' => false,
                'summary' => 'The policy was in force and Dwelling responds to a burst supply line.',
                'questions' => new List<Object>{ 'When did you first see water?' },
                'would_change' => new List<Object>{ 'Evidence the leak was gradual would change this.' }
            }
        );
    }

    private static String wrapped(Map<String, Object> answer) {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    @IsTest
    static void attachingPutsEverySampleFileOnItsClaimOnce() {
        String first = AntsuranceDemoPrep.attach();
        Integer filesAfterFirst = [SELECT COUNT() FROM ContentVersion];
        String second = AntsuranceDemoPrep.attach();

        Assert.areEqual(filesAfterFirst, [SELECT COUNT() FROM ContentVersion], 'Running it again adds nothing: ' + second);
        Assert.isTrue(first.contains('6 attached') && first.contains('3 sample photos attached'), 'Six documents and three photos go on: ' + first);
        Set<String> pipe = titlesOn(claim(AntsuranceDemoPrep.PIPE_CLAIM).Id);
        Assert.isTrue(
            pipe.contains('Mitigation invoice, Lakeshore Restoration') && pipe.contains('Rebuild estimate, Northshore Renovation') && pipe.contains('Basement family room after the water'),
            'The burst pipe claim carries its two documents and its photo: ' + pipe
        );
        Set<String> rearEnd = titlesOn(claim(AntsuranceDemoPrep.REAR_END_CLAIM).Id);
        Assert.isTrue(rearEnd.contains('Right rear quarter damage, insured\'s photo'), 'The photo that does not fit its claim is part of the demo: ' + rearEnd);
        Set<String> roof = titlesOn(claim(AntsuranceDemoPrep.ROOF_CLAIM).Id);
        Assert.isTrue(
            roof.contains('Employer\'s first report of injury, Ridgeline') && roof.contains('Interim hospital bill, Prairie Path Medical Center'),
            'The roof fall claim carries the two documents its notes speak of: ' + roof
        );
        // The check reads the same titles, so a title that drifted from the sample lists would show here as still to attach.
        for (String line : AntsuranceDemoPrep.check()) {
            Assert.isFalse(line.contains('would attach'), 'Nothing is left to attach: ' + line);
        }
    }

    @IsTest
    static void theEstimateIsRaisedOnceItsDocumentsAreOn() {
        Id pipe = claim(AntsuranceDemoPrep.PIPE_CLAIM).Id;
        String early = AntsuranceDemoPrep.settle();
        Assert.areEqual(AntsuranceDemoPrep.PIPE_FIRST_ESTIMATE, claim(AntsuranceDemoPrep.PIPE_CLAIM).Estimated_Loss__c, 'Without its documents the first estimate stands: ' + early);

        AntsuranceDemoPrep.attach();
        String raised = AntsuranceDemoPrep.settle();
        String again = AntsuranceDemoPrep.settle();

        Assert.areEqual(AntsuranceDemoPrep.PIPE_DOCUMENTS_TOTAL, claim(AntsuranceDemoPrep.PIPE_CLAIM).Estimated_Loss__c, raised);
        List<File_Note__c> notes = [SELECT Body__c, Author_Name__c, Note_Type__c FROM File_Note__c WHERE Case__c = :pipe];
        Assert.areEqual(1, notes.size(), 'One note says why, and a second run adds none: ' + again);
        Assert.areEqual(AntsuranceDemoPrep.ESTIMATE_NOTE, notes[0].Body__c, 'The note says what the estimate went to and why');
        Assert.areEqual('Marcus Lindahl', notes[0].Author_Name__c, 'The note is the adjuster\'s');
        Assert.isTrue(again.contains('already'), 'The second run says the estimate is already there: ' + again);
    }

    @IsTest
    static void anEstimateSomeoneChangedIsLeftAlone() {
        Id pipe = claim(AntsuranceDemoPrep.PIPE_CLAIM).Id;
        AntsuranceDemoPrep.attach();
        update new Case(Id = pipe, Estimated_Loss__c = 52000);

        String line = AntsuranceDemoPrep.settle();

        Assert.areEqual(52000, claim(AntsuranceDemoPrep.PIPE_CLAIM).Estimated_Loss__c, line);
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :pipe], 'No note is written for a change that was not made');
    }

    @IsTest
    static void checkingSaysWhatWouldHappenAndChangesNothing() {
        List<String> lines = AntsuranceDemoPrep.check();
        String all = String.join(lines, '\n');

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'No file is attached by a check');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'No note is written by a check');
        Assert.areEqual(AntsuranceDemoPrep.PIPE_FIRST_ESTIMATE, claim(AntsuranceDemoPrep.PIPE_CLAIM).Estimated_Loss__c, 'The estimate is not touched by a check');
        Assert.isTrue(all.contains('would attach Mitigation invoice, Lakeshore Restoration'), all);
        Assert.isTrue(all.contains('until its documents are attached'), all);
        Assert.isTrue(all.contains('would ask Claude for the claim brief'), all);
    }

    @IsTest
    static void theStepsCoverEachClaimsWorkInOrder() {
        AntsuranceDemoPrep.attach();

        List<String> pipeKinds = new List<String>();
        List<String> roofKinds = new List<String>();
        List<String> rearEndKinds = new List<String>();
        Integer briefs = 0;
        for (AntsuranceDemoPrep.Step step : AntsuranceDemoPrep.steps()) {
            Assert.isFalse(step.done, 'Nothing is done on claims Claude has not seen: ' + step.label);
            briefs += step.key.split(':')[1] == 'brief' ? 1 : 0;
            if (step.claim == AntsuranceDemoPrep.PIPE_CLAIM) {
                pipeKinds.add(step.key.split(':')[1]);
            } else if (step.claim == AntsuranceDemoPrep.REAR_END_CLAIM) {
                rearEndKinds.add(step.key.split(':')[1]);
            } else if (step.claim == AntsuranceDemoPrep.ROOF_CLAIM) {
                roofKinds.add(step.key.split(':')[1]);
            }
        }
        Assert.areEqual(new List<String>{ 'photos', 'document', 'document', 'coverage', 'report', 'brief' }, pipeKinds, 'Photos, then each document, then coverage, the analysis and the brief');
        Assert.areEqual(
            new List<String>{ 'photos', 'coverage', 'brief' },
            rearEndKinds,
            'The rear-ended claim carries no analysis: its photo, then the coverage check its brief is written from, then the brief'
        );
        Assert.areEqual(4, briefs, 'Each of the four showcase claims here carries a brief, so none opens on the invitation to write one');
        Assert.areEqual(new List<String>{ 'document', 'document', 'coverage', 'report', 'brief' }, roofKinds, 'The roof fall claim has no photos: its two documents, then coverage, the analysis and the brief');
    }

    @IsTest
    static void aStepAsksClaudeOnceAndIsSkippedAfterThat() {
        String key = keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief');
        ClaudeMock mock = new ClaudeMock(briefReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceDemoPrep.Outcome first = AntsuranceDemoPrep.run(key, false);
        Test.stopTest();
        AntsuranceDemoPrep.Outcome second = AntsuranceDemoPrep.run(key, false);

        Assert.isTrue(first.ok && !first.skipped, 'The first run writes the brief: ' + first.error);
        Assert.areEqual('Review the two documents, then settle the reserve.', first.line, 'The outcome carries the brief\'s headline');
        Assert.isNotNull(claim(AntsuranceDemoPrep.ROOF_CLAIM).Claude_Brief_At__c, 'The brief is stored on the claim');
        Assert.isTrue(second.ok && second.skipped, 'The second run finds it there');
        Assert.areEqual(1, mock.calls, 'Claude is asked once');
        Boolean saysSo = false;
        for (String line : AntsuranceDemoPrep.summary()) {
            saysSo = saysSo || line.contains('Brief: Review the two documents, then settle the reserve.');
        }
        Assert.isTrue(saysSo, 'The summary reads the headline back');
    }

    @IsTest
    static void aStepThatTimesOutSaysSoAndCanBeTriedAgain() {
        AntsuranceDemoPrep.attach();
        String brief = keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief');
        String photos = keyFor(AntsuranceDemoPrep.REAR_END_CLAIM, 'photos');
        ClaudeMock mock = new ClaudeMock(null);
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceDemoPrep.Outcome slowBrief = AntsuranceDemoPrep.run(brief, false);
        AntsuranceDemoPrep.Outcome slowPhotos = AntsuranceDemoPrep.run(photos, false);
        Test.stopTest();

        Assert.isFalse(slowBrief.ok, 'A brief that timed out is not reported as written');
        Assert.isTrue(slowBrief.retryable && String.isNotBlank(slowBrief.error), 'It can be tried again, and says what went wrong');
        Assert.isFalse(slowPhotos.ok, 'A photo assessment that timed out is not reported as done');
        Assert.isTrue(slowPhotos.retryable && String.isNotBlank(slowPhotos.error), 'It can be tried again, and says what went wrong');
        Assert.isNull(claim(AntsuranceDemoPrep.ROOF_CLAIM).Claude_Brief_At__c, 'Nothing is stored for a step that failed');
    }

    @IsTest
    static void theSummaryReadsTheReserveAgainstWhatIsPayable() {
        AntsuranceDemoPrep.attach();
        AntsuranceDemoPrep.settle();

        String all = String.join(AntsuranceDemoPrep.summary(), '\n');

        Assert.isTrue(all.contains('Estimate $48,921, deductible $2,500, payable $46,421, reserve $45,000 ($1,421 short), paid $5,000.'), all);
        Assert.isTrue(all.contains('Analysis: not written.') && all.contains('Brief: not written.'), all);
    }

    @IsTest
    static void aBriefWhoseClaimMovedOnIsListedAsOutOfDate() {
        Id roof = claim(AntsuranceDemoPrep.ROOF_CLAIM).Id;
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(briefReply()));
        Test.startTest();
        AntsuranceDemoPrep.run(keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief'), false);
        Test.stopTest();
        AntsuranceDemoPrep.Sweep fresh = AntsuranceDemoPrep.outOfDate(null);
        update new Case(Id = roof, Description = 'The insured now says something else happened.');

        AntsuranceDemoPrep.Sweep moved = AntsuranceDemoPrep.outOfDate(0);

        Assert.areEqual(4, moved.openClaims, 'Every open claim is counted');
        Assert.areEqual(4, moved.looked, 'And every one was looked at');
        Assert.isNull(moved.next, 'So there is no next page');
        String before = String.join(fresh.lines, '\n');
        String after = String.join(moved.lines, '\n');
        Assert.isFalse(before.contains('the brief'), 'A brief written a moment ago is current: ' + before);
        Assert.isTrue(after.contains('Installer fell from second-story roof: the brief is out of date (') && after.contains('Press Rewrite'), after);
        Assert.areEqual(4, after.countMatches('coverage has not been checked'), 'Each open claim with no coverage check is listed: ' + after);
        Assert.isFalse(after.contains('photos'), 'A claim with no photos has none to assess: ' + after);
    }

    @IsTest
    static void aBriefFromAnEarlierDayThatSpeaksOfTodayIsListed() {
        Id roof = claim(AntsuranceDemoPrep.ROOF_CLAIM).Id;
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(briefReply('The call to the nurse case manager is due today.')));
        Test.startTest();
        AntsuranceDemoPrep.run(keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief'), false);
        Test.stopTest();
        String sameDay = String.join(AntsuranceDemoPrep.outOfDate(0).lines, '\n');
        update new Case(Id = roof, Claude_Brief_At__c = Datetime.now().addDays(-1));

        String nextDay = String.join(AntsuranceDemoPrep.outOfDate(0).lines, '\n');

        Assert.isFalse(sameDay.contains('the brief'), 'On the day it was written, "due today" is true: ' + sameDay);
        Assert.isTrue(nextDay.contains('the brief was written on') && nextDay.contains('nurse case manager is due today'), 'A day later it is not, and the line quotes the words: ' + nextDay);
    }

    @IsTest
    static void aCountOfDaysIsListedWhenTheCheckReadsAsALaterDay() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(briefReply('The claim has sat open for 13 days with no reserve.')));
        Test.startTest();
        AntsuranceDemoPrep.run(keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief'), false);
        Test.stopTest();

        String asToday = String.join(AntsuranceDemoPrep.outOfDate(0).lines, '\n');
        String asTomorrow = String.join(AntsuranceDemoPrep.outOfDate(0, 1).lines, '\n');

        Assert.isFalse(asToday.contains('the brief was written on'), 'On the day it was written the count is true: ' + asToday);
        Assert.isTrue(asTomorrow.contains('the brief was written on') && asTomorrow.contains('open for 13 days'), 'Read as tomorrow, a count of days is listed with its words: ' + asTomorrow);
    }

    @IsTest
    static void aCountWrittenAsAWordIsListedToo() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(briefReply('The injury report is nine days old and nobody has called.')));
        Test.startTest();
        AntsuranceDemoPrep.run(keyFor(AntsuranceDemoPrep.ROOF_CLAIM, 'brief'), false);
        Test.stopTest();

        String asTomorrow = String.join(AntsuranceDemoPrep.outOfDate(0, 1).lines, '\n');

        Assert.isTrue(asTomorrow.contains('nine days old'), 'A count spelled out goes stale the same way: ' + asTomorrow);
    }

    @IsTest
    static void photosNobodyHasAssessedAreListed() {
        AntsuranceDemoPrep.attach();

        String notAssessed = String.join(AntsuranceDemoPrep.outOfDate(0).lines, '\n');

        Assert.isTrue(notAssessed.contains('Parking lot scrape, rear quarter panel: its photos have not been assessed'), notAssessed);
        Assert.isTrue(notAssessed.contains('Burst pipe flooded finished basement: its photos have not been assessed'), notAssessed);
        Assert.isFalse(notAssessed.contains('Installer fell from second-story roof: its photos'), 'Two PDFs are not photos: ' + notAssessed);
    }

    @IsTest
    static void everyOpenClaimGetsACoverageCheckInTheBackground() {
        // A test may run one batch of a job, so only the burst pipe claim keeps its policy here.
        Id pipe = claim(AntsuranceDemoPrep.PIPE_CLAIM).Id;
        List<Case> others = [SELECT Id FROM Case WHERE Id != :pipe];
        for (Case other : others) {
            other.Policy__c = null;
        }
        update others;
        ClaudeMock mock = new ClaudeMock(coverageReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceDemoPrep.CoverageJob started = AntsuranceDemoPrep.checkCoverageEverywhere();
        Test.stopTest();
        AntsuranceDemoPrep.CoverageJob ended = AntsuranceDemoPrep.coverageProgress(started.jobId);

        Assert.areEqual(1, started.calls, 'One open claim with a policy had no coverage check: ' + started.line);
        Assert.isTrue(started.line.contains('1 of 1 open claims have no coverage check') && started.line.contains('1 minute'), started.line);
        Assert.areEqual(1, mock.calls, 'Claude is asked once');
        Assert.isTrue(ended.finished && ended.failed == 0, ended.line);
        Assert.isNotNull([SELECT Coverage_Read_At__c FROM Case WHERE Id = :pipe].Coverage_Read_At__c, 'The check is stored on the claim');
        String swept = String.join(AntsuranceDemoPrep.outOfDate(0).lines, '\n');
        Assert.isFalse(swept.contains('coverage'), 'Nothing is left to check, and a claim with no policy is not asked for: ' + swept);
        String summary = String.join(AntsuranceDemoPrep.summary(), '\n');
        Assert.isTrue(summary.contains('Coverage check: Covered. The policy was in force and Dwelling responds to a burst supply line.'), summary);
        Assert.isTrue(AntsuranceDemoPrep.coverageProgress(null).finished, 'A job that cannot be found is not waited for');
    }

    @IsTest
    static void aProductionOrgIsRefused() {
        AntsuranceDemoPrep.treatAsProduction = true;
        try {
            AntsuranceDemoPrep.check();
            Assert.fail('The prep ran in a production org');
        } catch (AntsuranceDemoPrep.PrepException e) {
            Assert.areEqual(AntsuranceDemoPrep.NOT_HERE, e.getMessage(), 'It says why');
        }
        try {
            AntsuranceDemoPrep.attach();
            Assert.fail('Files were attached in a production org');
        } catch (AntsuranceDemoPrep.PrepException e) {
            Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'Nothing was attached');
        }
    }

    @IsTest
    static void aKeyThatIsNotAStepIsRefused() {
        for (String key : new List<String>{ null, 'nonsense', claim(AntsuranceDemoPrep.ROOF_CLAIM).Id + ':photos:0', claim(AntsuranceDemoPrep.ROOF_CLAIM).Id + ':sing' }) {
            try {
                AntsuranceDemoPrep.run(key, false);
                Assert.fail('Ran a step that does not exist: ' + key);
            } catch (AntsuranceDemoPrep.PrepException e) {
                Assert.isTrue(e.getMessage().contains('not a step'), e.getMessage());
            }
        }
    }
}
