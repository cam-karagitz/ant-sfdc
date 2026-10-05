@IsTest
private class AntsuranceCockpitControllerTest {
    private static Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();

    /** Answers the briefing request with a canned briefing and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        HttpRequest request;
        List<Object> priorities = new List<Object>();
        List<Object> watch = new List<Object>();

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            String briefing = JSON.serialize(
                new Map<String, Object>{ 'priorities' => priorities, 'watch' => watch, 'headline' => 'Start with the kitchen fire, then the overdue call.' }
            );
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => briefing } }
                    }
                )
            );
            return response;
        }
    }

    @TestSetup
    static void createTheBook() {
        // A test sees real users, and whoever runs it may have a briefing stored. Each test starts without one.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Claude_Briefing__c = null, Claude_Briefing_At__c = null);
        }
        Account customer = new Account(Name = 'Harbor Household');
        Account agency = new Account(
            Name = 'Dockside Agency',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Agency').getRecordTypeId()
        );
        insert new List<Account>{ customer, agency };
        Date today = Date.today();
        Policy__c renewing = policy(customer, 'RENEWS-SOON', 'Pending Renewal', 10, 1000);
        renewing.Incurred_Losses__c = 900;
        insert new List<Policy__c>{
            renewing,
            policy(customer, 'RENEWS-LATER', 'Active', 55, 2000),
            policy(customer, 'FAR-OFF', 'Active', 200, 3000),
            policy(customer, 'LAPSED', 'Lapsed', 20, 7000)
        };
        Opportunity renewal = new Opportunity(
            Name = 'Harbor renewal', AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = today.addDays(10), Amount = 1150, Type = 'Renewal',
            Policy__c = renewing.Id, Line_of_Business__c = 'Homeowners'
        );
        Opportunity fresh = new Opportunity(Name = 'Harbor umbrella', AccountId = customer.Id, StageName = 'Submission Received', CloseDate = today.addDays(30), Amount = 400);
        Opportunity won = new Opportunity(Name = 'Harbor auto', AccountId = customer.Id, StageName = 'Bound', CloseDate = today, Amount = 9000);
        insert new List<Opportunity>{ renewal, fresh, won };
        insert new List<Quote>{
            new Quote(OpportunityId = renewal.Id, Name = 'Old and open', Status = 'Issued', Annual_Premium__c = 1150, Issued_Date__c = today.addDays(-30)),
            new Quote(OpportunityId = renewal.Id, Name = 'Fresh', Status = 'Issued', Annual_Premium__c = 900, Issued_Date__c = today.addDays(-3)),
            new Quote(
                OpportunityId = fresh.Id, Name = 'Referred', Status = 'Draft', Annual_Premium__c = 400, Needs_Underwriting_Review__c = true,
                Configuration__c = '{"pricing":{"referrals":["Roof is over 20 years old"]}}',
                Underwriting_Memo__c = '{"recommendation":"Approve with conditions","headline":"A clean history outweighs the roof."}'
            )
        };
        insert new List<Case>{
            // Not New: a new claim gets a follow-up task from the claim automation, which would join the task counts below.
            claim(customer, 'Fender bender', 'Under Investigation', 'Low', 2, 0, 0),
            claim(customer, 'Kitchen fire', 'Appraisal', 'Catastrophic', 5, 90000, 10000),
            claim(customer, 'Settled glass claim', 'Closed', 'Low', 40, 500, 500)
        };
        Case fire = [SELECT Id FROM Case WHERE Subject = 'Kitchen fire'];
        insert new List<Task>{
            new Task(Subject = 'Overdue call', ActivityDate = today.addDays(-2), Priority = 'High', Status = 'Not Started', WhatId = fire.Id),
            new Task(Subject = 'Due today', ActivityDate = today, Priority = 'Normal', Status = 'Not Started', WhatId = renewal.Id),
            new Task(Subject = 'Next week', ActivityDate = today.addDays(7), Priority = 'Normal', Status = 'Not Started'),
            new Task(Subject = 'No date', Priority = 'Normal', Status = 'Not Started'),
            new Task(Subject = 'Already done', ActivityDate = today.addDays(-5), Priority = 'Normal', Status = 'Completed')
        };
    }

    private static Policy__c policy(Account customer, String name, String status, Integer daysToExpiry, Decimal premium) {
        Date expiry = Date.today().addDays(daysToExpiry);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Status__c = status, Line_of_Business__c = 'Homeowners', Annual_Premium__c = premium,
            Effective_Date__c = expiry.addYears(-1), Expiration_Date__c = expiry
        );
    }

    private static Case claim(Account customer, String subject, String status, String severity, Integer daysSinceReported, Decimal reserve, Decimal paid) {
        return new Case(
            Subject = subject, AccountId = customer.Id, Status = status, Severity__c = severity, RecordTypeId = claimType,
            Reported_Date__c = Date.today().addDays(-daysSinceReported), Reserve_Amount__c = reserve, Paid_Amount__c = paid
        );
    }

    @IsTest
    static void theFiguresSumUpTheBook() {
        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        AntsuranceCockpitController.Figures figures = cockpit.figures;
        Assert.areEqual(1, figures.customerCount, 'Agencies are not customers');
        Assert.areEqual(3, figures.policiesInForce, 'Active and pending renewal policies are in force');
        Assert.areEqual(6000, figures.premiumInForce, 'Lapsed premium is left out');
        Assert.areEqual(15, figures.lossRatio, 'Incurred losses over premium in force, as a whole percentage');
        Assert.areEqual(2, figures.openClaimCount, 'The closed claim is left out');
        Assert.areEqual(1, figures.seriousClaimCount, 'One claim is catastrophic');
        Assert.areEqual(80000, figures.outstandingReserve, 'Reserve less what has been paid, on open claims');
        Assert.areEqual(1, figures.renewalsSoonCount, 'One policy renews within 30 days');
        Assert.areEqual(1000, figures.renewalsSoonPremium, 'With its premium');
        Assert.isNull(cockpit.briefing, 'No briefing has been written yet');
    }

    @IsTest
    static void theLossTrendBuildsDayByDayToTheLossRatioFigure() {
        // Claims on two policies in force and one on the lapsed policy. The claim automation totals them on their policies.
        Map<String, Policy__c> policies = new Map<String, Policy__c>();
        for (Policy__c policy : [SELECT Id, Name, Account__c FROM Policy__c]) {
            policies.put(policy.Name, policy);
        }
        Account customer = new Account(Id = policies.get('FAR-OFF').Account__c);
        Case old = claim(customer, 'Hail on the roof', 'Closed', 'Low', 88, 600, 600);
        old.Policy__c = policies.get('RENEWS-SOON').Id;
        old.Date_of_Loss__c = Date.today().addDays(-90);
        Case recent = claim(customer, 'Burst pipe', 'Appraisal', 'Medium', 8, 1500, 200);
        recent.Policy__c = policies.get('FAR-OFF').Id;
        recent.Date_of_Loss__c = Date.today().addDays(-10);
        Case lapsed = claim(customer, 'Loss on a lapsed policy', 'Appraisal', 'Low', 3, 4000, 0);
        lapsed.Policy__c = policies.get('LAPSED').Id;
        lapsed.Date_of_Loss__c = Date.today().addDays(-5);
        insert new List<Case>{ old, recent, lapsed };

        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        AntsuranceCockpitController.LossTrend trend = cockpit.lossTrend;
        Integer last = AntsuranceCockpitController.TREND_DAYS;
        Assert.areEqual(Date.today().addDays(-last), trend.startDate, 'The trend starts a year back');
        Assert.areEqual(last + 1, trend.incurred.size(), 'One entry a day, ending today');
        Assert.areEqual(last + 1, trend.claims.size(), 'And so does the count of claims');

        Assert.areEqual(0, trend.incurred[last - 91], 'Nothing was incurred before the first loss');
        Assert.areEqual(600, trend.incurred[last - 90], 'A loss counts from its date of loss');
        Assert.areEqual(1, trend.claims[last - 90], 'As one claim');
        Assert.areEqual(600, trend.incurred[last - 11], 'And nothing is added until the next one');
        Assert.areEqual(2100, trend.incurred[last], 'The higher of reserve and paid, on policies in force only');
        Assert.areEqual(2, trend.claims[last], 'The claim on the lapsed policy is left out');

        Assert.areEqual(
            cockpit.figures.lossRatio,
            (trend.incurred[last] / cockpit.figures.premiumInForce * 100).setScale(0, RoundingMode.HALF_UP).intValue(),
            'Over the premium in force, the last day is the loss ratio among the figures'
        );
    }

    @IsTest
    static void myDayShowsOverdueAndTodayThenWhatIsNext() {
        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        Assert.areEqual(4, cockpit.openTaskCount, 'Completed tasks are not counted');
        Assert.areEqual(1, cockpit.overdueTaskCount, 'One task is past due');
        Assert.areEqual(1, cockpit.todayTaskCount, 'One is due today');
        List<String> subjects = new List<String>();
        for (AntsuranceCockpitController.TaskRow row : cockpit.tasks) {
            subjects.add(row.subject);
        }
        Assert.areEqual(new List<String>{ 'Overdue call', 'Due today', 'Next week' }, subjects, 'Soonest first, and a task with no date is left to the Tasks tab');
        Assert.areEqual('Kitchen fire', cockpit.tasks[0].relatedName, 'A claim is named by its subject');
        Assert.areEqual('Claim', cockpit.tasks[0].relatedKind, 'And called a claim');
    }

    @IsTest
    static void theWorkspaceListsWhatNeedsSomeone() {
        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        Assert.areEqual('Kitchen fire', cockpit.claims[0].subject, 'The most serious claim comes first');
        Assert.areEqual(80000, cockpit.claims[0].outstanding, 'With what is still reserved');

        Assert.areEqual(2, cockpit.renewalCount, 'Two policies renew within 60 days');
        Assert.areEqual('RENEWS-SOON', cockpit.renewals[0].policyNumber, 'Soonest first');
        Assert.areEqual(1150, cockpit.renewals[0].renewalPremium, 'The renewal sale carries the premium on offer');
        Assert.areEqual('Quote Issued', cockpit.renewals[0].renewalStage, 'And where the renewal stands');
        Assert.isNull(cockpit.renewals[1].renewalPremium, 'A renewal that has not been priced has none');

        Assert.areEqual(2, cockpit.openSaleCount, 'The bound sale is not open');
        Assert.areEqual(1550, cockpit.openSaleAmount, 'Open pipeline in premium');
        Assert.areEqual('Submission Received', cockpit.stages[0].name, 'Stages run in the order a sale moves through them');
        Assert.areEqual(1, cockpit.stages[0].saleCount, 'One sale has just come in');
        Assert.areEqual(1, cockpit.stages[2].saleCount, 'One has a quote out');
        Assert.areEqual('Homeowners', cockpit.stages[2].sales[0].lineOfBusiness, 'A sale carries its line, for the row opened in place');
        Assert.isNotNull(cockpit.stages[2].sales[0].customerName, 'And who it is for');

        Assert.areEqual(1, cockpit.staleQuoteCount, 'One quote has waited 15 days or more');
        Assert.areEqual('Old and open', cockpit.staleQuotes[0].option, 'The stale quote');

        Assert.areEqual(1, cockpit.referrals.size(), 'One quote waits on an underwriter');
        Assert.areEqual(new List<String>{ 'Roof is over 20 years old' }, cockpit.referrals[0].reasons, 'With why it was referred');
        Assert.areEqual('Approve with conditions', cockpit.referrals[0].memoRecommendation, 'And what the stored memo recommends');
    }

    @IsTest
    static void aClaimShowsItsStoredBriefHeadline() {
        Case fire = [SELECT Id FROM Case WHERE Subject = 'Kitchen fire'];
        fire.Claude_Brief__c = '**The estimate is in.**\n\n<!-- antsurance-brief:v1 {"brief":{"headline":"The estimate is in; approve the rebuild."}} -->';
        update fire;

        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        Assert.areEqual('The estimate is in; approve the rebuild.', cockpit.claims[0].briefHeadline, 'The headline comes from the brief stored on the claim');
        Assert.isNull(cockpit.claims[1].briefHeadline, 'A claim with no brief has none');
    }

    @IsTest
    static void eachClaimSaysWhereItsReserveStandsAgainstWhatIsPayable() {
        Policy__c policy = [SELECT Id FROM Policy__c LIMIT 1];
        update new Policy__c(Id = policy.Id, Deductible__c = 2500);
        Case fire = [SELECT Id FROM Case WHERE Subject = 'Kitchen fire'];
        // A $92,500 estimate less the $2,500 deductible is the $90,000 reserve: nothing short.
        update new Case(Id = fire.Id, Policy__c = policy.Id, Estimated_Loss__c = 92500);
        Case bender = [SELECT Id FROM Case WHERE Subject = 'Fender bender'];
        update new Case(Id = bender.Id, Estimated_Loss__c = 4000);

        Test.startTest();
        AntsuranceCockpitController.Cockpit cockpit = AntsuranceCockpitController.getCockpit();
        Test.stopTest();

        Map<String, AntsuranceCockpitController.ClaimRow> bySubject = new Map<String, AntsuranceCockpitController.ClaimRow>();
        for (AntsuranceCockpitController.ClaimRow row : cockpit.claims) {
            bySubject.put(row.subject, row);
        }
        AntsuranceCockpitController.ClaimRow covered = bySubject.get('Kitchen fire');
        Assert.areEqual(90000, covered.payable, 'The estimate less the deductible');
        Assert.areEqual(AntsuranceClaimRules.ADEQUATE, covered.reserveStanding, 'A reserve equal to that is not short');
        Assert.areEqual(', the reserve covers what is payable ($90,000)', AntsuranceCockpitController.reserveStanding(covered), 'And the briefing is told so');

        AntsuranceCockpitController.ClaimRow isShort = bySubject.get('Fender bender');
        Assert.areEqual(AntsuranceClaimRules.SHORT_OF, isShort.reserveStanding, 'No reserve against a $4,000 estimate is short');
        Assert.areEqual(', the reserve is $4,000 below what is payable ($4,000)', AntsuranceCockpitController.reserveStanding(isShort), 'By the payable amount');

        AntsuranceCockpitController.ClaimRow none = new AntsuranceCockpitController.ClaimRow();
        none.reserveStanding = AntsuranceClaimRules.UNKNOWN;
        Assert.areEqual(', no estimate yet to measure the reserve against', AntsuranceCockpitController.reserveStanding(none), 'No estimate, no judgment');
    }

    @IsTest
    static void theBriefingNamesOnlyRecordsItWasGivenAndIsStoredOnTheUser() {
        Task overdue = [SELECT Id FROM Task WHERE Subject = 'Overdue call'];
        Case fire = [SELECT Id FROM Case WHERE Subject = 'Kitchen fire'];
        Account stranger = [SELECT Id FROM Account WHERE Name = 'Dockside Agency'];
        ClaudeMock mock = new ClaudeMock();
        mock.priorities = new List<Object>{
            new Map<String, Object>{ 'recordId' => fire.Id, 'title' => 'Approve the kitchen fire estimate', 'why' => '$80,000 is still reserved.' },
            new Map<String, Object>{ 'recordId' => stranger.Id, 'title' => 'Call the agency', 'why' => 'Not a record it was given.' },
            new Map<String, Object>{ 'recordId' => fire.Id, 'title' => 'The fire again', 'why' => 'A second priority for the same record.' },
            new Map<String, Object>{ 'recordId' => overdue.Id, 'title' => 'Make the overdue call', 'why' => 'Two days late.' }
        };
        mock.watch = new List<Object>{
            new Map<String, Object>{ 'recordId' => 'none', 'label' => 'Loss ratio', 'detail' => 'The book runs at 15 percent.' },
            new Map<String, Object>{ 'recordId' => fire.Id, 'label' => 'Fire reserve', 'detail' => 'May need to rise.' }
        };
        Test.setMock(HttpCalloutMock.class, mock);

        AntsuranceCockpitController.Briefing briefing;
        AntsuranceCockpitController.Cockpit cockpit;
        // Saving to the user record alongside the test's own records needs a context of its own.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            briefing = AntsuranceCockpitController.briefMe();
            Test.stopTest();
            cockpit = AntsuranceCockpitController.getCockpit();
        }

        Assert.areEqual('Start with the kitchen fire, then the overdue call.', briefing.headline, 'The headline is Claude\'s');
        Assert.areEqual(2, briefing.priorities.size(), 'A record it was not given and a repeat are both dropped');
        Assert.areEqual(fire.Id, briefing.priorities[0].recordId, 'The claim first');
        Assert.areEqual('Kitchen fire', briefing.priorities[0].recordName, 'Named from the record, not from Claude');
        Assert.areEqual('Case', briefing.priorities[0].objectApiName, 'With what the page needs to open it');
        Assert.areEqual('Open claim', briefing.priorities[0].actionLabel, 'And one action');
        Assert.areEqual('Task', briefing.priorities[1].kind, 'Then the task');
        Assert.areEqual(2, briefing.watch.size(), 'Two things to watch');
        Assert.isNull(briefing.watch[0].recordId, 'One about the book as a whole');
        Assert.areEqual(fire.Id, briefing.watch[1].recordId, 'One about a record');

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains(String.valueOf(overdue.Id)), 'Claude is given each record by its id');
        Assert.isTrue(sent.contains('2 days overdue'), 'With the facts about it');
        Assert.isTrue(sent.contains('HOW TO READ THE RESERVE'), 'And the reserve rule every writer shares');
        Assert.isTrue(sent.contains(AntsuranceClaimRules.AMERICAN_ENGLISH), 'In American English');
        Assert.isTrue(sent.contains('Roof is over 20 years old'), 'Including why a quote was referred');

        Assert.isNotNull(cockpit.briefing, 'The briefing is stored and comes back with Home');
        Assert.isFalse(cockpit.briefing.isStale, 'Written today, it is current');
        Assert.isFalse(cockpit.briefing.priorities[1].isDone, 'The task is still open');
    }

    @IsTest
    static void aStoredBriefingTicksOffFinishedWorkAndGoesStaleOvernight() {
        Task overdue = [SELECT Id FROM Task WHERE Subject = 'Overdue call'];
        AntsuranceCockpitController.Briefing stored = new AntsuranceCockpitController.Briefing();
        stored.headline = 'Make the call.';
        AntsuranceCockpitController.Priority priority = new AntsuranceCockpitController.Priority();
        priority.title = 'Make the overdue call';
        priority.recordId = overdue.Id;
        priority.kind = 'Task';
        stored.priorities.add(priority);

        AntsuranceCockpitController.Cockpit cockpit;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Claude_Briefing__c = JSON.serialize(stored), Claude_Briefing_At__c = Datetime.now().addDays(-1));
            overdue.Status = 'Completed';
            update overdue;
            Test.startTest();
            cockpit = AntsuranceCockpitController.getCockpit();
            Test.stopTest();
        }

        Assert.isTrue(cockpit.briefing.isStale, 'A briefing from yesterday is stale');
        Assert.isTrue(cockpit.briefing.priorities[0].isDone, 'A priority whose task has been completed is ticked off');
    }

    /** Stores a one-line briefing for the running user, written so many days ago. */
    private static void storeBriefing(Integer daysAgo) {
        AntsuranceCockpitController.Briefing stored = new AntsuranceCockpitController.Briefing();
        stored.headline = 'Make the call.';
        update new User(Id = UserInfo.getUserId(), Claude_Briefing__c = JSON.serialize(stored), Claude_Briefing_At__c = Datetime.now().addDays(-daysAgo));
    }

    @IsTest
    static void aBriefingFromAnEarlierDayIsWrittenAgainAsHomeLoadsAndOnlyOnce() {
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);
        AntsuranceCockpitController.claudeAccess = true;

        AntsuranceCockpitController.Cockpit before;
        AntsuranceCockpitController.Briefing written;
        AntsuranceCockpitController.Briefing again;
        AntsuranceCockpitController.Cockpit after;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            storeBriefing(1);
            before = AntsuranceCockpitController.getCockpit();
            Test.startTest();
            written = AntsuranceCockpitController.briefMeForToday();
            Test.stopTest();
            mock.request = null;
            again = AntsuranceCockpitController.briefMeForToday();
            after = AntsuranceCockpitController.getCockpit();
        }

        Assert.isTrue(before.briefing.writeOnLoad, 'Home is told to have yesterday\'s briefing written again');
        Assert.areEqual('Start with the kitchen fire, then the overdue call.', written.headline, 'Claude writes a new one');
        Assert.areEqual(Date.today(), written.writtenAt.date(), 'Dated today');
        Assert.isNull(mock.request, 'A second load on the same day does not ask Claude again');
        Assert.areEqual(written.headline, again.headline, 'It gets the one written today');
        Assert.isFalse(after.briefing.isStale, 'Home now holds today\'s briefing');
        Assert.isFalse(after.briefing.writeOnLoad, 'And is not told to write another');
    }

    @IsTest
    static void nothingIsWrittenUnaskedForSomeoneWhoCannotReachClaude() {
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);
        AntsuranceCockpitController.claudeAccess = false;

        AntsuranceCockpitController.Cockpit cockpit;
        AntsuranceCockpitController.Briefing briefing;
        AntsuranceCockpitController.Briefing none;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            none = AntsuranceCockpitController.briefMeForToday();
            storeBriefing(1);
            cockpit = AntsuranceCockpitController.getCockpit();
            Test.startTest();
            briefing = AntsuranceCockpitController.briefMeForToday();
            Test.stopTest();
        }

        Assert.isNull(none, 'With no briefing stored there is nothing to bring up to date');
        Assert.isTrue(cockpit.briefing.isStale, 'Yesterday\'s briefing is stale');
        Assert.isFalse(cockpit.briefing.writeOnLoad, 'But Home is not told to write a new one');
        Assert.isNull(mock.request, 'And asking anyway does not reach Claude');
        Assert.areEqual('Make the call.', briefing.headline, 'The stored one comes back unchanged');
        Assert.isTrue(briefing.isStale, 'Still marked as from an earlier day');
    }

    @IsTest
    static void aFailedCallSaysSoAndStoresNothing() {
        ClaudeMock mock = new ClaudeMock();
        mock.status = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        String message;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            try {
                AntsuranceCockpitController.briefMe();
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
            Test.stopTest();
        }

        Assert.isNotNull(message, 'The person is told Claude could not be reached');
        Assert.isNull([SELECT Claude_Briefing__c FROM User WHERE Id = :UserInfo.getUserId()].Claude_Briefing__c, 'And nothing is stored');
    }
}
