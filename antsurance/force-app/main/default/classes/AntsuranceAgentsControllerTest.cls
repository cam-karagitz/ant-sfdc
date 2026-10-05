@IsTest
private class AntsuranceAgentsControllerTest {
    @TestSetup
    static void createWork() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-1', Account__c = customer.Id, Primary_Insured__c = person.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Coverage_Limit__c = 500000, Deductible__c = 2500
        );
        insert policy;
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Datetime now = Datetime.now();
        List<Case> claims = new List<Case>{
            new Case(
                RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Policy__c = policy.Id, Status = 'New', Severity__c = 'High',
                Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-5), Reported_Date__c = Date.today().addDays(-4),
                Coverage_Read_At__c = now, Coverage_Verdict__c = 'Needs review', Coverage_Confirmed_At__c = now, Photo_Assessment_At__c = now.addDays(-2), Claude_Analysis_At__c = now.addDays(-3)
            ),
            new Case(
                RecordTypeId = claimType, Subject = 'Old hail claim', Policy__c = policy.Id, Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Wind or Hail',
                Date_of_Loss__c = Date.today().addDays(-40), Reported_Date__c = Date.today().addDays(-39), Coverage_Read_At__c = now.addDays(-20)
            )
        };
        insert claims;
        Id claimId = claims[0].Id;
        insert new List<Claude_Work__c>{
            work('Claim brief', AntsuranceDeskShift.DONE, claimId, now, null),
            work('Reserve review', AntsuranceDeskShift.WAITING, claimId, now.addDays(-1), null),
            work('Reserve review', AntsuranceDeskShift.REPLACED, claimId, now.addDays(-1), now.addDays(-1)),
            work('Reserve review', AntsuranceDeskShift.APPROVED, claimId, now.addDays(-2), now),
            work('Reserve review', AntsuranceDeskShift.DISMISSED, claimId, now.addDays(-3), now),
            work('Renewal outreach', AntsuranceDeskShift.WAITING, policy.Id, now.addDays(-30), null),
            work('Underwriting memo', AntsuranceDeskShift.DONE, claimId, now.addDays(-20), null)
        };
    }

    private static Claude_Work__c work(String kind, String status, Id recordId, Datetime preparedAt, Datetime decidedAt) {
        return new Claude_Work__c(
            Kind__c = kind, Status__c = status, Authority__c = AntsuranceDeskShift.APPROVE, Record_Object__c = recordId.getSObjectType().getDescribe().getName(),
            Record_Id__c = recordId, Record_Name__c = 'A record', Title__c = kind + ' for a record', Work__c = '{}', Prepared_At__c = preparedAt, Decided_At__c = decidedAt
        );
    }

    private static AntsuranceAgentsController.Agent agent(AntsuranceAgentsController.Roster roster, String key) {
        for (AntsuranceAgentsController.Agent agent : roster.agents) {
            if (agent.key == key) {
                return agent;
            }
        }
        return null;
    }

    private static Antsurance_Agent_Eval__mdt eval(String agentKey, String label, String result, Integer order) {
        return new Antsurance_Agent_Eval__mdt(
            MasterLabel = label, Agent__c = agentKey, Result__c = result, Measured__c = 'How it was measured.', Caveat__c = 'What it does not show.',
            Run_On__c = Date.newInstance(2026, 10, 4), Source__c = 'scripts/eval', Order__c = order
        );
    }

    private static AntsuranceAgentsController.Roster rosterWith(List<Antsurance_Agent_Eval__mdt> evals, Boolean portal) {
        AntsuranceAgentsController.evalStandIn = evals;
        AntsuranceAgentsController.pretendPortalInstalled = portal;
        if (AntsuranceAgentsController.coverageAgentStandIn == null) {
            AntsuranceAgentsController.coverageAgentStandIn = 'absent';
        }
        return AntsuranceAgentsController.getRoster();
    }

    @IsTest
    static void everyAgentHasOneJobAndSaysWhatWaitsForAPerson() {
        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        Assert.areEqual(8, roster.agents.size(), 'Eight agents without the portal');
        Assert.areEqual(AntsuranceAiSettings.model(), roster.model, 'The model comes from the configuration');
        Set<String> keys = new Set<String>();
        for (AntsuranceAgentsController.Agent agent : roster.agents) {
            Assert.isTrue(keys.add(agent.key), 'No agent is listed twice: ' + agent.key);
            Assert.isTrue(String.isNotBlank(agent.job), agent.key + ' says its job');
            Assert.areEqual(4, agent.steps.size(), agent.key + ' has four steps: read, work out, prepare, person');
            Assert.isFalse(agent.reads.isEmpty() || agent.tools.isEmpty() || agent.prepares.isEmpty(), agent.key + ' says what it reads, uses and prepares');
            Boolean waits = false;
            for (AntsuranceAgentsController.Rule rule : agent.rules) {
                waits = waits || rule.mode == 'person';
            }
            Assert.isTrue(waits, agent.key + ' leaves at least one thing to a person');
            Assert.isTrue(agent.isCounted || String.isNotBlank(agent.notCountedWhy), agent.key + ' is counted or says why not');
            Assert.isTrue(String.isNotBlank(agent.runsLabel) && String.isNotBlank(agent.runsLine), agent.key + ' says how it really runs');
            Assert.areNotEqual('managed', agent.runs, agent.key + ' is not called an agent: nothing here has a harness');
            Assert.isTrue(String.isNotBlank(agent.harnessLine), agent.key + ' says what a harness would add');
        }
        Assert.areEqual(0, roster.harnessed, 'No job runs on a harness where the coverage agent is not set up');
        Assert.areEqual('loop', agent(roster, 'assistant').runs, 'The chat is a tool loop built here');
        Assert.areEqual('Single call', agent(roster, 'coverage').runsLabel, 'The coverage check is a single call');
        Assert.isTrue(agent(roster, 'coverage').runsLine.contains('not set up in this org'), 'And the page says the agent is not set up');
        Assert.areEqual('pipeline', agent(roster, 'analysis').runs, 'The analysis is a fixed pipeline');
    }

    @IsTest
    static void theCoverageAgentIsTheOneJobOnAHarnessAndShowsItsNewestRun() {
        Case claim = [SELECT Id FROM Case WHERE Subject = 'Burst pipe flooded basement'];
        update new Case(
            Id = claim.Id,
            Coverage_Read__c = JSON.serialize(
                new Map<String, Object>{
                    'agent' => new Map<String, Object>{
                        'harness' => 'Claude Managed Agents',
                        'run' => new Map<String, Object>{
                            'steps' => new List<Object>{
                                new Map<String, Object>{ 'key' => 's1', 'label' => 'Read the claim', 'state' => 'done' },
                                new Map<String, Object>{ 'key' => 's2', 'label' => 'Read the policy', 'detail' => 'Homeowners, in force on the date of loss.', 'state' => 'done' },
                                42
                            }
                        }
                    }
                }
            )
        );
        update new Case(Id = [SELECT Id FROM Case WHERE Subject = 'Old hail claim'].Id, Coverage_Read__c = 'A read from before the agent, kept as text.');
        AntsuranceAgentsController.coverageAgentStandIn = 'ready';

        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        AntsuranceAgentsController.Agent coverage = agent(roster, 'coverage');
        Assert.areEqual(1, roster.harnessed, 'One job runs on a harness');
        Assert.areEqual('managed', coverage.runs, 'It is the coverage agent');
        Assert.areEqual('Agent on Claude Managed Agents', coverage.runsLabel, 'And is named for its harness');
        Assert.areEqual(8, coverage.harnessTools.size(), 'With its eight tools');
        Assert.isTrue(String.isNotBlank(coverage.skill), 'And its Skill');
        Assert.isNull(coverage.harnessLine, 'It is not a candidate: it is on a harness');
        Assert.isNotNull(coverage.traceOf, 'The newest run by the agent is found');
        Assert.areEqual('Burst pipe flooded basement', coverage.traceOf.title, 'On its claim');
        Assert.areEqual(new List<String>{ 'Read the claim', 'Read the policy: Homeowners, in force on the date of loss.' }, coverage.trace, 'With its steps as lines, and anything else left out');
    }

    @IsTest
    static void anAgentWithNoRunOnRecordShowsNoTrace() {
        AntsuranceAgentsController.coverageAgentStandIn = 'ready';

        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        Assert.isNull(agent(roster, 'coverage').traceOf, 'Nothing is shown that is not on record');
        Assert.isTrue(agent(roster, 'coverage').trace.isEmpty(), 'And no steps are invented');
    }

    @IsTest
    static void anAgentThatIsBuiltButNotSetUpIsNotCalledAnAgent() {
        AntsuranceAgentsController.coverageAgentStandIn = 'built';

        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        Assert.areEqual(0, roster.harnessed, 'Nothing runs on a harness until the agent is set up');
        Assert.areEqual('single', agent(roster, 'coverage').runs, 'The coverage check is still a single call');
        Assert.isTrue(agent(roster, 'coverage').runsLine.contains('built but not set up'), 'And the page says why');
    }

    @IsTest
    static void everyJobSaysHowItIsStartedAndWhereToTryIt() {
        // Three open claims, each the best for one job: a report on a full file, photos that are assessed, and one nobody has checked.
        Id policyId = [SELECT Id FROM Policy__c WHERE Name = 'T-HOME-1'].Id;
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Id reportId = [SELECT Id FROM Case WHERE Subject = 'Burst pipe flooded basement' LIMIT 1].Id;
        Case scrape = new Case(
            RecordTypeId = claimType, Subject = 'Parking lot scrape', Policy__c = policyId, Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Collision',
            Date_of_Loss__c = Date.today().addDays(-3), Reported_Date__c = Date.today().addDays(-2), Photo_Assessment_At__c = Datetime.now(), Coverage_Read_At__c = Datetime.now()
        );
        Case unchecked = new Case(
            RecordTypeId = claimType, Subject = 'Fence blown down', Policy__c = policyId, Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Wind or Hail',
            Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()
        );
        insert new List<Case>{ scrape, unchecked };
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Basement', PathOnClient = 'basement.jpg', VersionData = Blob.valueOf('photo'), FirstPublishLocationId = reportId),
            new ContentVersion(Title = 'Estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('estimate'), FirstPublishLocationId = reportId),
            new ContentVersion(Title = 'Invoice', PathOnClient = 'invoice.pdf', VersionData = Blob.valueOf('invoice'), FirstPublishLocationId = reportId),
            new ContentVersion(Title = 'Quarter panel', PathOnClient = 'panel.jpg', VersionData = Blob.valueOf('photo'), FirstPublishLocationId = scrape.Id)
        };
        // A second policy that is waiting on its renewal: the only kind whose page shows the outreach card.
        Policy__c inForce = [SELECT Account__c, Primary_Insured__c FROM Policy__c WHERE Id = :policyId];
        insert new Policy__c(
            Name = 'T-HOME-2', Account__c = inForce.Account__c, Primary_Insured__c = inForce.Primary_Insured__c, Line_of_Business__c = 'Homeowners', Status__c = 'Pending Renewal',
            Effective_Date__c = Date.today().addDays(-340), Expiration_Date__c = Date.today().addDays(25), Coverage_Limit__c = 400000, Deductible__c = 1000
        );
        AntsuranceAgentsController.portalContactStandIn = [SELECT Id, Name FROM Contact WHERE LastName = 'Harbor' LIMIT 1];

        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), true);
        Test.stopTest();

        Set<String> opened = new Set<String>();
        for (AntsuranceAgentsController.Agent each : roster.agents) {
            Assert.isNotNull(each.start, each.name + ' says how it is started');
            Assert.isTrue(String.isNotBlank(each.start.how) && String.isNotBlank(each.start.onceThere), each.name + ' says who presses what, and what to press there');
            Assert.areEqual(each.start.label == null, each.start.url == null, each.name + ' has a button only with somewhere to go');
            Assert.isFalse(each.start.url != null && each.start.url.contains('Antsurance_Home'), each.name + ' never opens the second Home tab');
            if (each.start.url != null) {
                Assert.isFalse(opened.contains(each.start.url), each.name + ' opens somewhere no other job does');
                opened.add(each.start.url);
            }
        }
        AntsuranceAgentsController.Start analysis = agent(roster, 'analysis').start;
        Assert.areEqual('/lightning/r/Case/' + reportId + '/view', analysis.url, 'The analysis opens the claim with a report and the fullest file');
        Assert.isTrue(analysis.onceThere.contains('Open its Analysis tab') && analysis.onceThere.contains('3 files'), 'And says which tab, and what the report was written from: ' + analysis.onceThere);
        AntsuranceAgentsController.Start photos = agent(roster, 'photos').start;
        Assert.areEqual('/lightning/r/Case/' + scrape.Id + '/view', photos.url, 'The photo job opens another claim, one whose photo is assessed');
        Assert.isTrue(photos.onceThere.contains('Open its Documents tab') && photos.onceThere.contains('1 photo, already assessed'), 'And says which tab: ' + photos.onceThere);
        AntsuranceAgentsController.Start coverage = agent(roster, 'coverage').start;
        Assert.areEqual('/lightning/r/Case/' + unchecked.Id + '/view', coverage.url, 'The coverage job opens an open claim nobody has checked');
        Assert.isTrue(coverage.label.startsWith('Open claim '), 'By its number');
        Assert.isTrue(coverage.onceThere.contains('Fence blown down.') && coverage.onceThere.contains('has not been checked yet'), 'And says so: ' + coverage.onceThere);
        Assert.isTrue(agent(roster, 'intake').start.url.startsWith('/lightning/action/quick/Account.File_Claim_With_Claude'), 'First notice opens the claim intake on a customer');
        Assert.areEqual('Try it on Harbor Household', agent(roster, 'intake').start.label, 'Named for the customer');
        Assert.areEqual('Open policy T-HOME-2', agent(roster, 'renewals').start.label, 'Renewals opens the policy that is pending renewal, whose page shows the outreach card');
        Assert.areEqual(AntsuranceAgentsController.DESK_URL, agent(roster, 'desk').start.url, 'The desk opens on the app\'s own Home');
        Assert.isNull(agent(roster, 'underwriting').start.url, 'With no quote there is nothing to open, and it still says how');
        Assert.areEqual('Open Maya Harbor', agent(roster, 'portal').start.label, 'The customer assistant opens the contact who has a portal login');
        Assert.isTrue(agent(roster, 'portal').start.onceThere.contains('Log in to Experience as User'), 'And says what to press there');
    }

    @IsTest
    static void aJobWithNothingToShowItStillSaysHowItIsStarted() {
        // Only the claims from setup: no file on any, no policy pending renewal, nobody with a portal login.
        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), true);
        Test.stopTest();

        Assert.isNull(agent(roster, 'renewals').start.url, 'No policy shows the outreach card, so there is no button');
        Assert.isTrue(agent(roster, 'renewals').start.onceThere.contains('No policy is pending renewal'), 'And the line says why');
        Assert.isNull(agent(roster, 'portal').start.url, 'Nobody has a portal login, so there is no button');
        Assert.isTrue(agent(roster, 'photos').start.onceThere.contains('no photo yet'), 'A claim with no photo says to add one first');
        Assert.isTrue(agent(roster, 'analysis').start.onceThere.contains('Open its Analysis tab'), 'The analysis still names its tab');
        Assert.isTrue(agent(roster, 'coverage').start.onceThere.contains('with a read already on it'), 'The coverage job says the claim it opens has been checked');
        Set<String> claimsOpened = new Set<String>{ agent(roster, 'analysis').start.url, agent(roster, 'photos').start.url, agent(roster, 'coverage').start.url };
        Assert.isTrue(claimsOpened.size() >= 2, 'With two open claims the three jobs do not all open the same one');
    }

    @IsTest
    static void theRealOrgIsReadWithoutAStandIn() {
        AntsuranceAgentsController.evalStandIn = new List<Antsurance_Agent_Eval__mdt>();
        AntsuranceAgentsController.pretendPortalInstalled = false;

        Test.startTest();
        AntsuranceAgentsController.Roster roster = AntsuranceAgentsController.getRoster();
        Test.stopTest();

        // A test sees no custom setting record, so whatever is deployed, the agent is not ready here.
        Assert.areNotEqual('managed', agent(roster, 'coverage').runs, 'With no ids kept, the coverage check is not called an agent');
    }

    @IsTest
    static void thePortalAgentShowsOnlyWhereThePortalIsInstalled() {
        Test.startTest();
        AntsuranceAgentsController.Roster withPortal = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), true);
        Test.stopTest();

        Assert.areEqual(9, withPortal.agents.size(), 'The customer assistant joins the roster');
        Assert.isNotNull(agent(withPortal, 'portal'), 'It is there');
        Assert.areEqual(2, agent(withPortal, 'intake').places.size(), 'First notice says it also runs on the portal');
        Assert.isFalse(agent(withPortal, 'portal').isCounted, 'A conversation leaves no record to count');
    }

    @IsTest
    static void workIsCountedFromTheDeskAndFromTheDatesTheFeaturesStamp() {
        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        AntsuranceAgentsController.Agent coverage = agent(roster, 'coverage');
        Assert.areEqual(1, coverage.today, 'One coverage check today');
        Assert.areEqual(1, coverage.week, 'The check of 20 days ago is outside the week');
        Assert.areEqual(1, coverage.approved, 'One was confirmed by an adjuster this week');
        Assert.areEqual('Needs review', coverage.recent[0].outcome, 'The latest work carries its verdict');
        Assert.isTrue(coverage.recent[0].url.startsWith('/lightning/r/Case/'), 'And links to its claim');

        Assert.areEqual(0, agent(roster, 'photos').today, 'The photo assessment was two days ago');
        Assert.areEqual(1, agent(roster, 'photos').week, 'It counts in the week');
        Assert.areEqual(1, agent(roster, 'analysis').week, 'So does the analysis');

        AntsuranceAgentsController.Agent desk = agent(roster, 'desk');
        Assert.areEqual(1, desk.today, 'One brief today');
        Assert.areEqual(4, desk.week, 'A brief and three reserve reviews this week; the replaced one is not counted');
        Assert.areEqual(1, desk.waiting, 'One waits for a person');
        Assert.areEqual(1, desk.approved, 'One was approved this week');
        Assert.areEqual(1, desk.dismissed, 'One was dismissed this week');

        AntsuranceAgentsController.Agent renewals = agent(roster, 'renewals');
        Assert.areEqual(0, renewals.week, 'Its piece was prepared a month ago');
        Assert.areEqual(1, renewals.waiting, 'But it still waits');
        Assert.areEqual(0, agent(roster, 'underwriting').week, 'The memo of 20 days ago is outside the week');

        Assert.isFalse(agent(roster, 'assistant').isCounted, 'The chat leaves no record to count');
        Assert.areEqual(2, roster.today, 'A coverage check and a brief today');
        Assert.areEqual(7, roster.week, 'Seven pieces on record this week');
        Assert.areEqual(2, roster.waiting, 'Two wait for a person');
    }

    @IsTest
    static void testsComeFromTheEvalRecordsInTheirOrder() {
        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(
            new List<Antsurance_Agent_Eval__mdt>{ eval('photos', 'Where the boxes land', '0.69 overlap', 2), eval('photos', 'Photo assessments', '8 of 9', 1), eval('nobody', 'Unknown', '1 of 1', 1) },
            false
        );
        Test.stopTest();

        AntsuranceAgentsController.Agent photos = agent(roster, 'photos');
        Assert.areEqual(2, photos.tests.size(), 'Both photo tests show');
        Assert.areEqual('8 of 9', photos.tests[0].result, 'In their order');
        Assert.areEqual('What it does not show.', photos.tests[0].caveat, 'Each with its caveat');
        Assert.isTrue(agent(roster, 'analysis').tests.isEmpty(), 'An agent with no eval has none, and the page says not tested yet');
        Assert.areEqual(1, roster.tested, 'One agent has been tested');
    }

    @IsTest
    static void aDeskRuleFollowsTheDeskSetting() {
        insert new Claude_Autonomy__c(SetupOwnerId = UserInfo.getOrganizationId(), Claim_Brief__c = AntsuranceDeskShift.OFF, Reserve_Review__c = AntsuranceDeskShift.AUTO);

        Test.startTest();
        AntsuranceAgentsController.Roster roster = rosterWith(new List<Antsurance_Agent_Eval__mdt>(), false);
        Test.stopTest();

        List<AntsuranceAgentsController.Rule> rules = agent(roster, 'desk').rules;
        Assert.areEqual('off', rules[0].mode, 'The brief is switched off on the desk');
        Assert.areEqual('person', rules[1].mode, 'A reserve change is locked: a person always approves it');
        Assert.isTrue(rules[1].isSetting, 'It is a desk setting');
        Assert.isTrue(rules[1].detail.contains('money'), 'And says why');
    }
}
