@IsTest
private class AntsuranceCoverageAgentTest {
    private static final String SESSION = 'sesn_01TestSession1';

    /** Stands in for Managed Agents and the Skills API: answers by method and path, and keeps every request. */
    private class Api implements HttpCalloutMock {
        Map<String, String> bodies = new Map<String, String>();
        Map<String, Integer> statuses = new Map<String, Integer>();
        List<HttpRequest> requests = new List<HttpRequest>();
        String failWith;

        Api answer(String method, String pathPart, String body) {
            return answer(method, pathPart, 200, body);
        }

        Api answer(String method, String pathPart, Integer status, String body) {
            bodies.put(method + ' ' + pathPart, body);
            statuses.put(method + ' ' + pathPart, status);
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            requests.add(request);
            if (failWith != null) {
                throw new CalloutException(failWith);
            }
            String path = request.getEndpoint().substringAfter('callout:Anthropic_API');
            // The longest matching rule wins, so /v1/environments/env_1 is not answered as the list.
            String chosen;
            for (String rule : bodies.keySet()) {
                String part = rule.substringAfter(' ');
                if (rule.startsWith(request.getMethod() + ' ') && path.startsWith(part) && (chosen == null || rule.length() > chosen.length())) {
                    chosen = rule;
                }
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(chosen == null ? 404 : statuses.get(chosen));
            response.setBody(chosen == null ? '{"type":"error","error":{"type":"not_found_error","message":"No rule for ' + request.getMethod() + ' ' + path + '"}}' : bodies.get(chosen));
            return response;
        }

        List<HttpRequest> sent(String method, String pathPart) {
            List<HttpRequest> matches = new List<HttpRequest>();
            for (HttpRequest request : requests) {
                if (request.getMethod() == method && request.getEndpoint().contains(pathPart)) {
                    matches.add(request);
                }
            }
            return matches;
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
        insert new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 500000, Deductible_Amount__c = 2500, What_Is_Covered__c = 'Rebuilds the home after a covered loss.');
        insert new Policy_Endorsement__c(Name = 'Earth Movement Exclusion', Policy__c = policy.Id, Type__c = 'Exclusion', Description__c = 'Earthquake is not covered.');
        insert new Policy_Participant__c(Name = 'Maya Harbor, Named Insured', Policy__c = policy.Id, Contact__c = person.Id, Role__c = 'Named Insured', Status__c = 'Active');
        insert new Policy_Asset__c(Name = '12 Quay St', Policy__c = policy.Id, Asset_Type__c = 'Dwelling', Location__c = '12 Quay St, Evanston, IL', Insured_Value__c = 500000);
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        insert new List<Case>{
            new Case(
                RecordTypeId = claimType, AccountId = customer.Id, Subject = 'Burst pipe flooded basement', Description = 'A supply line burst.', Policy__c = policy.Id, Status = 'New',
                Severity__c = 'High', Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-5), Reported_Date__c = Date.today().addDays(-4),
                Estimated_Loss__c = 48500, Reserve_Amount__c = 45000
            ),
            new Case(
                RecordTypeId = claimType, AccountId = customer.Id, Subject = 'Wind took shingles off the garage', Policy__c = policy.Id, Status = 'New',
                Loss_Type__c = 'Wind or Hail', Date_of_Loss__c = Date.today().addDays(-60), Estimated_Loss__c = 3200
            ),
            new Case(
                RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
                Subject = 'Add a driver', Policy__c = policy.Id, Status = 'New'
            )
        };
        Case claim = [SELECT Id FROM Case WHERE Subject = 'Burst pipe flooded basement'];
        insert new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Coverage', Body__c = 'Inspection found a failed braided supply line.', Note_Date__c = Datetime.now().addDays(-2), Author_Name__c = 'Dana Reyes');
    }

    private static Case claim() {
        return [SELECT Id, Coverage_Read__c, Coverage_Verdict__c, Coverage_Read_At__c FROM Case WHERE Subject = 'Burst pipe flooded basement'];
    }

    private static void setUp() {
        insert new Antsurance_Coverage_Agent__c(SetupOwnerId = UserInfo.getOrganizationId(), Agent_Id__c = 'agent_1', Environment_Id__c = 'env_1', Skill_Id__c = 'skill_1', Session_Budget_Cents__c = 75);
    }

    // ------------------------------------------------------------ events, as Managed Agents lists them

    private static String events(List<String> items) {
        return '{"data":[' + String.join(items, ',') + '],"next_page":null}';
    }

    private static String task(Id caseId) {
        return '{"type":"user.message","id":"sevt_task","processed_at":"2026-10-05T05:40:02.000Z","content":[{"type":"text","text":"Work the coverage question. Claim record: ' + caseId + '."}]}';
    }

    /** The task as start writes it now: the claim, then the keys each record had when the session started. */
    private static String task(Id caseId, String keys) {
        return '{"type":"user.message","id":"sevt_task","processed_at":"2026-10-05T05:40:02.000Z","content":[{"type":"text","text":' +
            JSON.serialize('Work the coverage question. Claim record: ' + caseId + '.\n\n' + AntsuranceCoverageAgent.KEYS_MARKER + '\n' + keys) + '}]}';
    }

    private static String asks(String id, String tool, String input) {
        return '{"type":"agent.custom_tool_use","id":"' + id + '","processed_at":"2026-10-05T05:40:04.000Z","name":"' + tool + '","input":' + input + '}';
    }

    private static String answered(String id, String text) {
        return '{"type":"user.custom_tool_result","id":"res_' + id + '","processed_at":"2026-10-05T05:40:05.000Z","custom_tool_use_id":"' + id + '","content":[{"type":"text","text":"' + text + '"}],"is_error":false}';
    }

    private static String idle(String reason) {
        return '{"type":"session.status_idle","id":"sevt_idle","processed_at":"2026-10-05T05:40:44.000Z","stop_reason":{"type":"' + reason + '"}}';
    }

    private static String finding(String source) {
        return '{"findings":[{"text":"The loss fell inside the policy term.","source":"POLICY"},{"text":"Dwelling pays to rebuild after a burst pipe.","source":"' + source + '"},{"text":"The exclusion is for earthquake, which this is not.","source":"E1"}],' +
            '"responding":"C1","verdict":"Covered","liability_open":false,"summary":"Dwelling responds to a burst supply line.","questions":["When was the line last replaced?"],"would_change":["Water from outside the home."]}';
    }

    // ------------------------------------------------------------ setup

    @IsTest
    static void shouldCreateEnvironmentSkillAndAgent_WhenNothingExists() {
        Api api = new Api()
            .answer('GET', '/v1/environments', '{"data":[],"next_page":null}')
            .answer('POST', '/v1/environments', '{"id":"env_new","metadata":{}}')
            .answer('GET', '/v1/skills', '{"data":[],"next_page":null}')
            .answer('POST', '/v1/skills', '{"id":"skill_new"}')
            .answer('POST', '/v1/agents', '{"id":"agent_new","version":1}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        String report = AntsuranceCoverageAgentSetup.run();
        Test.stopTest();

        Antsurance_Coverage_Agent__c ids = Antsurance_Coverage_Agent__c.getOrgDefaults();
        Assert.areEqual('env_new', ids.Environment_Id__c, 'The environment id is kept');
        Assert.areEqual('skill_new', ids.Skill_Id__c, 'The skill id is kept');
        Assert.areEqual('agent_new', ids.Agent_Id__c, 'The agent id is kept');
        Assert.areEqual(AntsuranceCoverageAgentSetup.BUILT_IN_BUDGET_CENTS, ids.Session_Budget_Cents__c.intValue(), 'A session budget is set');
        Assert.isTrue(AntsuranceCoverageAgent.isReady(), 'The claim page may now offer the agent');
        Assert.isTrue(report.contains('created'), report);

        HttpRequest upload = api.sent('POST', '/v1/skills')[0];
        Assert.isTrue(upload.getHeader('content-type').startsWith('multipart/form-data'), 'The skill goes up as a file');
        Assert.isTrue(upload.getBody().contains('filename="antsurance-coverage/SKILL.md"'), 'Under its folder name');
        Assert.isTrue(upload.getBody().contains('name: antsurance-coverage'), 'With the skill file from the static resource');
        Assert.isNull(upload.getHeader('anthropic-beta'), 'The Skills API takes no beta header');

        HttpRequest agent = api.sent('POST', '/v1/agents')[0];
        Assert.areEqual(AntsuranceCoverageAgentApi.MANAGED_AGENTS_BETA, agent.getHeader('anthropic-beta'), 'Managed Agents needs its beta header');
        Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(agent.getBody());
        Assert.areEqual(AntsuranceCoverageAgentSetup.AGENT_NAME, definition.get('name'), 'The agent is named');
        Assert.areEqual(9, ((List<Object>) definition.get('tools')).size(), 'Eight custom tools and the file reader the skill needs');
        Assert.isTrue(agent.getBody().contains('"skill_id":"skill_new"'), 'The skill is attached');
        Assert.isTrue(agent.getBody().contains('"default_config":{"enabled":false}'), 'No shell, no web: only what is switched on');

        HttpRequest noted = api.sent('POST', '/v1/environments/env_new')[0];
        Assert.isTrue(noted.getBody().contains('agent_new') && noted.getBody().contains('skill_new'), 'The environment notes the ids that go with it');
        for (HttpRequest request : api.requests) {
            Assert.isFalse(request.getEndpoint().contains('archive') || request.getMethod() == 'DELETE', 'Setup never archives or deletes');
        }
    }

    @IsTest
    static void shouldCreateNothing_WhenTheKeptIdsAreLive() {
        setUp();
        Api api = new Api()
            .answer('GET', '/v1/environments/env_1', '{"id":"env_1","archived_at":null,"metadata":{"coverage_skill_id":"skill_1","coverage_agent_id":"agent_1"}}')
            .answer('GET', '/v1/skills/skill_1', '{"id":"skill_1"}')
            .answer('GET', '/v1/agents/agent_1', '{"id":"agent_1","version":3,"archived_at":null}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        String report = AntsuranceCoverageAgentSetup.run();
        Test.stopTest();

        Assert.areEqual(3, api.requests.size(), 'Three looks and nothing else');
        Assert.isTrue(api.sent('POST', '/v1/').isEmpty(), 'Nothing is created or changed on a second run');
        Assert.isTrue(report.contains('already there, at version 3'), report);
    }

    @IsTest
    static void shouldFindTheAgentThroughTheEnvironment_WhenTheOrgLostItsIds() {
        Api api = new Api()
            .answer('GET', '/v1/environments', '{"data":[{"id":"env_9","name":"antsurance-crm-coverage","archived_at":null,"metadata":{"coverage_skill_id":"skill_9","coverage_agent_id":"agent_9"}}],"next_page":null}')
            .answer('GET', '/v1/skills/skill_9', '{"id":"skill_9"}')
            .answer('GET', '/v1/agents/agent_9', '{"id":"agent_9","version":2,"archived_at":null}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgentSetup.run();
        Test.stopTest();

        Assert.areEqual('agent_9', Antsurance_Coverage_Agent__c.getOrgDefaults().Agent_Id__c, 'The agent set up before is used again');
        Assert.isTrue(api.sent('POST', '/v1/').isEmpty(), 'No second agent is made');
    }

    @IsTest
    static void shouldSendNewVersions_WhenRefreshed() {
        setUp();
        Api api = new Api()
            .answer('GET', '/v1/environments/env_1', '{"id":"env_1","archived_at":null,"metadata":{"coverage_skill_id":"skill_1","coverage_agent_id":"agent_1"}}')
            .answer('GET', '/v1/skills/skill_1', '{"id":"skill_1"}')
            .answer('POST', '/v1/skills/skill_1/versions', '{"id":"skill_1","version":"2"}')
            .answer('GET', '/v1/agents/agent_1', '{"id":"agent_1","version":3,"archived_at":null}')
            .answer('POST', '/v1/agents/agent_1', '{"id":"agent_1","version":4}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        String report = AntsuranceCoverageAgentSetup.refresh();
        Test.stopTest();

        Assert.areEqual(1, api.sent('POST', '/v1/skills/skill_1/versions').size(), 'The skill file goes up as a new version');
        Assert.isTrue(report.contains('updated to version 4'), report);
    }

    @IsTest
    static void shouldStopAndSaySo_WhenTheKeyCannotUseManagedAgents() {
        Api api = new Api().answer('GET', '/v1/environments', 403, '{"type":"error","error":{"type":"permission_error","message":"Managed Agents is not enabled for this workspace."}}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgentSetup.run();
            Assert.fail('Setup should stop when the API refuses');
        } catch (AntsuranceCoverageAgentSetup.SetupException e) {
            Assert.isTrue(e.getMessage().contains('cannot use Managed Agents'), e.getMessage());
            Assert.isTrue(e.getMessage().contains('not enabled for this workspace'), 'What the API said is passed on as it came');
        }
        Test.stopTest();

        Assert.areEqual(1, api.requests.size(), 'A refusal is not retried or worked around');
        Assert.isFalse(AntsuranceCoverageAgent.isReady(), 'The claim page does not offer the agent');
        Assert.isFalse(AntsuranceCoverageAgent.getStanding(claim().Id).ready, 'And the card is told so');
    }

    // ------------------------------------------------------------ starting

    @IsTest
    static void shouldOpenASessionForTheClaim_WhenStarted() {
        setUp();
        Api api = new Api().answer('POST', '/v1/sessions', '{"id":"' + SESSION + '","status":"running"}');
        Test.setMock(HttpCalloutMock.class, api);
        Id caseId = claim().Id;

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.start(caseId);
        Test.stopTest();

        Assert.areEqual(SESSION, run.sessionId, 'The page gets the session to poll');
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(api.requests[0].getBody());
        Assert.areEqual('agent_1', sent.get('agent'), 'The agent is the one set up, at its latest version');
        Assert.areEqual('env_1', sent.get('environment_id'), 'In its environment');
        Assert.isTrue(api.requests[0].getBody().contains('"max_list_cost":{"amount":"75","currency":"USD"}'), 'With the session budget from the setting');
        Assert.isTrue(api.requests[0].getBody().contains('Claim record: ' + caseId), 'The task names the claim');
        Id noteId = [SELECT Id FROM File_Note__c WHERE Case__c = :caseId].Id;
        Assert.isTrue(api.requests[0].getBody().contains('N1=' + noteId), 'And carries the key each record has now, so the keys cannot shift while the agent works');
    }

    @IsTest
    static void shouldRefuseToStart_WhenNotSetUp() {
        Api api = new Api();
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.start(claim().Id);
            Assert.fail('Starting needs the agent set up');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.NOT_SET_UP, e.getMessage(), 'Says what is missing');
        }
        Test.stopTest();

        Assert.isTrue(api.requests.isEmpty(), 'Nothing is sent');
    }

    @IsTest
    static void shouldRefuseToStart_WhenTheRecordIsAServiceRequest() {
        setUp();
        Api api = new Api();
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.start([SELECT Id FROM Case WHERE Subject = 'Add a driver'].Id);
            Assert.fail('Coverage is investigated on claims only');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantCoverage.NOT_A_CLAIM, e.getMessage(), 'The same refusal as the coverage check');
        }
        Test.stopTest();

        Assert.isTrue(api.requests.isEmpty(), 'Nothing is sent');
    }

    // ------------------------------------------------------------ the loop

    @IsTest
    static void shouldRunTheToolsInSalesforceAndHandBackTheResults_WhenTheAgentAsks() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
                task(caseId),
                '{"type":"agent.tool_use","id":"sevt_skill","processed_at":"2026-10-05T05:40:03.000Z","name":"read","input":{"file_path":"/workspace/skills/antsurance-coverage/SKILL.md"}}',
                asks('sevt_a', 'read_claim', '{}'),
                asks('sevt_b', 'read_policy', '{}'),
                asks('sevt_c', 'read_file_notes', '{}'),
                asks('sevt_d', 'find_prior_claims', '{}'),
                asks('sevt_e', 'read_photo_assessment', '{}'),
                idle('requires_action')
            }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual('working', run.status, 'The agent has been answered and carries on');
        Assert.areEqual(6, run.steps.size(), 'Opening the skill, then five tools');
        Assert.areEqual('Opened its coverage method', run.steps[0].label, 'The skill shows as a step');
        Assert.areEqual('Read the policy, its coverages and endorsements', run.steps[2].label, 'Steps are in plain words');
        Assert.areEqual('1 coverage, 1 endorsement or exclusion, 1 person and 1 insured item on T-HOME-1', run.steps[2].detail, 'With what was found');
        Assert.areEqual('1 earlier claim by this customer', run.steps[4].detail, 'The wind claim is found');
        for (AntsuranceCoverageAgent.Step step : run.steps) {
            Assert.areEqual('done', step.state, step.label);
        }

        List<HttpRequest> posts = api.sent('POST', '/events');
        Assert.areEqual(1, posts.size(), 'All five results go back in one request');
        String handedBack = posts[0].getBody();
        Assert.areEqual(5, handedBack.countMatches('"type":"user.custom_tool_result"'), 'One result per tool the agent asked for');
        Assert.isTrue(handedBack.contains('"custom_tool_use_id":"sevt_b"'), 'Each answers its own request');
        Assert.isTrue(handedBack.contains('[C1] Dwelling'), 'The policy is handed over with its keys');
        Assert.isTrue(handedBack.contains('[N1]'), 'So are the file notes');
        Assert.isTrue(handedBack.contains('[X1]') && handedBack.contains('Wind took shingles off the garage'), 'And the earlier claim');
        Assert.isNull(claim().Coverage_Read__c, 'Reading stores nothing');
    }

    @IsTest
    static void shouldLeaveADocumentForItsOwnRequest_WhenTheAgentAsksToReadOne() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_doc', 'read_document', '{"document":"D1"}'), idle('requires_action') }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual(1, run.toRead.size(), 'The page is told which document to read');
        Assert.areEqual('sevt_doc', run.toRead[0].toolUseId, 'And which request it answers');
        Assert.areEqual('D1', run.toRead[0].document, 'By its key');
        Assert.areEqual('working', run.status, 'The run is still going');
        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'Nothing is handed back from the poll itself');
    }

    @IsTest
    static void shouldTellTheAgent_WhenTheDocumentIsNotOnTheClaim() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_doc', 'read_document', '{"document":"D7"}'), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.readDocument(caseId, SESSION, 'sevt_doc');
        Test.stopTest();

        String handedBack = api.sent('POST', '/events')[0].getBody();
        Assert.isTrue(handedBack.contains('"is_error":true'), 'The agent is told the tool could not do it');
        Assert.isTrue(handedBack.contains('There is no document with the key D7'), 'And why, so it can try again: the key is the one the session asked for');
    }

    @IsTest
    static void shouldReadNothing_WhenTheAgentDidNotAskOrHasItsAnswer() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
                task(caseId),
                asks('sevt_doc', 'read_document', '{"document":"D1"}'),
                answered('sevt_doc', 'FOUND: An invoice.'),
                asks('sevt_a', 'read_claim', '{}'),
                idle('requires_action')
            }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.readDocument(caseId, SESSION, 'sevt_doc');
        for (String notAReading : new List<String>{ 'sevt_a', 'sevt_made_up' }) {
            try {
                AntsuranceCoverageAgent.readDocument(caseId, SESSION, notAReading);
                Assert.fail('Only a document the agent asked for is read');
            } catch (AuraHandledException e) {
                Assert.areEqual(AntsuranceCoverageAgent.NOT_ASKED, e.getMessage(), 'Says so');
            }
        }
        Test.stopTest();

        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'A reading already handed back is not sent twice, and nothing is sent for a request that was never made');
    }

    @IsTest
    static void shouldSaveTheFindingBeforeTellingTheAgent_WhenTheAgentRecordsIt() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
                task(caseId),
                asks('sevt_a', 'read_claim', '{}'),
                answered('sevt_a', 'FOUND: The claim.'),
                asks('sevt_r', 'record_finding', finding('C1')),
                '{"type":"session.usage","id":"sevt_u","processed_at":"2026-10-05T05:40:40.000Z","usage":{"list_cost":{"currency":"USD","amount":"12"},"active_seconds":14.2}}',
                idle('requires_action')
            }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.isTrue(run.recorded, 'The page is told the finding is on the claim');
        Assert.areEqual('working', run.status, 'The run goes on: the agent has yet to hear');
        Assert.areEqual('Covered, under Dwelling', run.steps[1].detail, 'The step says what was recorded');
        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'The agent is not told "recorded" in the request that saves: that waits until the finding is on the claim');

        Case stored = claim();
        Assert.areEqual('Covered', stored.Coverage_Verdict__c, 'The verdict field the list views use');
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.read(caseId);
        Assert.isTrue(check.exists, 'The coverage card reads it as any other check');
        Assert.isTrue(check.byAgent, 'And knows the agent reached it');
        Assert.areEqual('Dwelling', check.respondingLabel, 'The responding coverage is linked');
        Assert.areEqual(46000, check.payable, 'Payable is worked out by Apex from the record: 48,500 less 2,500');
        Assert.areEqual(3, check.findings.size(), 'Each finding kept');
        Assert.areEqual('Exclusion', check.findings[2].sourceKind, 'With the record it rests on');
        Assert.isFalse(check.stale, 'Nothing has changed since');

        AntsuranceCoverageAgent.Standing standing = AntsuranceCoverageAgent.getStanding(caseId);
        Assert.isTrue(standing.ready, 'The agent is offered');
        Assert.areEqual(SESSION, standing.lastRun.sessionId, 'How it worked is kept beside the check');
        Assert.areEqual(2, standing.lastRun.steps.size(), 'With its steps');
        Assert.isTrue(stored.Coverage_Read__c.contains('"listCostCents":"12"'), 'And what the session cost');
        Assert.isTrue(stored.Coverage_Read__c.contains('"findingUse":"sevt_r"'), 'And which of the agent\'s requests it came from, which is how the next poll knows it is saved');
    }

    /** Puts a finding on the claim the way a poll saves it, as this session's answer to one request of the agent's. */
    private static void storeAsThePollDid(Id caseId, String toolUseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceCoverageAgentTools.facts(caseId);
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.checkFrom((Map<String, Object>) JSON.deserializeUntyped(finding('C1')), facts);
        AntsuranceCoverageAgent.Run earlier = new AntsuranceCoverageAgent.Run();
        earlier.sessionId = SESSION;
        AntsuranceClaimsAssistantCoverage.store(caseId, check, facts, new Map<String, Object>{ 'agent' => new Map<String, Object>{ 'run' => earlier, 'findingUse' => toolUseId } });
    }

    @IsTest
    static void shouldTellTheAgentItIsRecorded_OnceTheFindingIsOnTheClaim() {
        setUp();
        Id caseId = claim().Id;
        storeAsThePollDid(caseId, 'sevt_r');
        Datetime savedAt = claim().Coverage_Read_At__c;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_r', 'record_finding', finding('C1')), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        String handedBack = api.sent('POST', '/events')[0].getBody();
        Assert.isTrue(handedBack.contains('"custom_tool_use_id":"sevt_r"') && handedBack.contains('Recorded on the claim'), 'With the finding on the claim, the agent is told it is recorded');
        Assert.isTrue(handedBack.contains('FOUND: Covered, under Dwelling.'), 'In the words of what was saved');
        Assert.isTrue(run.recorded, 'And the page hears the same');
        Assert.areEqual('done', run.steps[0].state, 'The step is finished');
        Assert.areEqual(savedAt, claim().Coverage_Read_At__c, 'The finding is not saved a second time');
    }

    @IsTest
    static void shouldSayTheFindingWasNotSavedAndSaveItOnALaterPoll_WhenTheClaimCannotBeSaved() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_r', 'record_finding', finding('C1')), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.saveFailsWith = 'Someone else is saving this claim right now. Try again in a moment.';
        try {
            AntsuranceCoverageAgent.poll(caseId, SESSION);
            Assert.fail('A finding that was not saved is never reported as recorded');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.NOT_SAVED + 'Someone else is saving this claim right now. Try again in a moment.', e.getMessage(), 'The person is told it was not saved, and why, in plain words');
        }
        Assert.isNull(claim().Coverage_Read__c, 'Nothing is on the claim');
        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'And the agent has not been told it is recorded, so the session still holds the finding to be saved');

        // The next poll finds the same request waiting and saves it from what the session holds.
        AntsuranceCoverageAgent.saveFailsWith = null;
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.isTrue(run.recorded, 'The later poll saves it');
        Assert.areEqual('Covered', claim().Coverage_Verdict__c, 'On the claim');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.read(caseId).byAgent, 'As the agent\'s finding');
    }

    @IsTest
    static void shouldEndFailed_WhenAnotherCheckHasReplacedTheFinding() {
        setUp();
        Id caseId = claim().Id;
        // The check on the claim is someone else's: a single-call check saved after the agent recorded.
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(caseId);
        AntsuranceClaimsAssistantCoverage.store(caseId, AntsuranceClaimsAssistantCoverage.checkFrom((Map<String, Object>) JSON.deserializeUntyped(finding('C1')), facts), facts, null);
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
            task(caseId),
            asks('sevt_r', 'record_finding', finding('C1')),
            answered('sevt_r', 'FOUND: Covered, under Dwelling.'),
            idle('end_turn')
        }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual('failed', run.status, 'The run does not end as a success when its finding is not the check on the claim');
        Assert.areEqual(AntsuranceCoverageAgent.REPLACED, run.problem, 'And says so in plain words');
        Assert.isFalse(run.recorded, 'So the card is not told the agent wrote what it shows');
        Assert.isFalse(AntsuranceClaimsAssistantCoverage.read(caseId).byAgent, 'The other check is left as it was');
        Assert.isNull(AntsuranceCoverageAgent.getStanding(caseId).lastRun, 'With no agent run beside it');
    }

    @IsTest
    static void shouldKeepOnlyTheLastFinding_WhenTheAgentRecordsTwoAtOnce() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
                task(caseId),
                asks('sevt_r1', 'record_finding', finding('C1')),
                asks('sevt_r2', 'record_finding', finding('POLICY')),
                idle('requires_action')
            }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        String handedBack = api.sent('POST', '/events')[0].getBody();
        Assert.isTrue(handedBack.contains('"custom_tool_use_id":"sevt_r1"') && handedBack.contains('only your last call is kept'), 'The earlier of two is turned away');
        Assert.isFalse(handedBack.contains('"custom_tool_use_id":"sevt_r2"'), 'The last is saved, and answered on the next poll');
        Assert.isTrue(claim().Coverage_Read__c.contains('"findingUse":"sevt_r2"'), 'So one finding is on the claim, and it is the last');
    }

    @IsTest
    static void shouldCutTheStepsToFit_WhenTheRunIsLongerThanTheClaimsFieldHolds() {
        setUp();
        Id caseId = claim().Id;
        List<String> listed = new List<String>{ task(caseId) };
        for (Integer step = 0; step < 150; step++) {
            listed.add(asks('sevt_s' + step, 'read_file_notes', '{}'));
            listed.add(answered('sevt_s' + step, 'FOUND: ' + 'A long line about what this step found. '.repeat(9)));
        }
        listed.add(asks('sevt_r', 'record_finding', finding('C1')));
        listed.add(idle('requires_action'));
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(listed));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual(151, run.steps.size(), 'The page still gets every step');
        Assert.isTrue(run.steps[0].detail.length() > 300, 'In full');
        Case stored = claim();
        Assert.isTrue(stored.Coverage_Read__c.length() <= AntsuranceClaimsAssistantCoverage.maxStored(), 'What is stored fits the field, so a long investigation still saves its finding');
        Assert.areEqual(3, AntsuranceClaimsAssistantCoverage.read(caseId).findings.size(), 'The finding itself is whole');
        Assert.isFalse(AntsuranceCoverageAgent.getStanding(caseId).lastRun.steps.isEmpty(), 'And the steps are kept, cut down');
    }

    @IsTest
    static void shouldSendTheFindingBack_WhenItCitesARecordItWasNotGiven() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_r', 'record_finding', finding('C9')), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        String handedBack = api.sent('POST', '/events')[0].getBody();
        Assert.isTrue(handedBack.contains('"is_error":true'), 'The tool refuses');
        Assert.isTrue(handedBack.contains('The source \\"C9\\" is not a key a tool gave you'), 'And says what to fix');
        Assert.isFalse(run.recorded, 'Nothing is recorded');
        Assert.areEqual('failed', run.steps[0].state, 'The step shows it did not go through');
        Assert.isNull(claim().Coverage_Read__c, 'Nothing is stored');
    }

    @IsTest
    static void shouldFinishOnce_WhenTheAgentEndsItsTurn() {
        setUp();
        Id caseId = claim().Id;
        // The finding as an earlier poll stored it.
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceCoverageAgentTools.facts(caseId);
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.checkFrom((Map<String, Object>) JSON.deserializeUntyped(finding('C1')), facts);
        AntsuranceCoverageAgent.Run earlier = new AntsuranceCoverageAgent.Run();
        earlier.sessionId = SESSION;
        AntsuranceClaimsAssistantCoverage.store(caseId, check, facts, new Map<String, Object>{ 'agent' => new Map<String, Object>{ 'run' => earlier } });
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
            task(caseId),
            asks('sevt_r', 'record_finding', finding('C1')),
            answered('sevt_r', 'FOUND: Covered, under Dwelling.'),
            '{"type":"agent.message","id":"sevt_m","processed_at":"2026-10-05T05:40:43.000Z","content":[{"type":"text","text":"Dwelling responds. Ask when the line was last replaced."}]}',
            '{"type":"session.usage","id":"sevt_u","processed_at":"2026-10-05T05:40:44.000Z","usage":{"list_cost":{"currency":"USD","amount":"19"},"active_seconds":20.5}}',
            idle('end_turn')
        }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual('done', run.status, 'The run is over');
        Assert.areEqual('Dwelling responds. Ask when the line was last replaced.', run.closing, 'With the agent\'s closing words');
        Assert.areEqual(42, run.seconds, 'How long the person waited, first event to last');
        AntsuranceCoverageAgent.Run kept = AntsuranceCoverageAgent.getStanding(caseId).lastRun;
        Assert.isNotNull(kept.finishedAt, 'How it ended is kept beside the check');
        Assert.areEqual('done', kept.status, 'As finished');
        Assert.isTrue(claim().Coverage_Read__c.contains('"listCostCents":"19"'), 'With the final cost');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.read(caseId).exists, 'The check itself still reads as before');
        Assert.isTrue(api.sent('POST', '/v1/').isEmpty(), 'Nothing more is sent to the agent');
    }

    @IsTest
    static void shouldSayTheBudgetWasReached_WhenTheSessionPausesAtItsLimit() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), asks('sevt_a', 'read_claim', '{}'), answered('sevt_a', 'FOUND: The claim.'), idle('budget_reached') }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual('failed', run.status, 'The run stopped');
        Assert.areEqual(AntsuranceCoverageAgent.OVER_BUDGET, run.problem, 'And says why in plain words');
        Assert.isTrue(run.retryable, 'It can be run again');
    }

    @IsTest
    static void shouldSayNoFindingWasRecorded_WhenTheAgentEndsWithoutOne() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api().answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId), idle('end_turn') }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual(AntsuranceCoverageAgent.NO_FINDING, run.problem, 'An empty-handed finish is a failure, not a success');
    }

    @IsTest
    static void shouldRefuseTheSession_WhenItWasStartedForAnotherClaim() {
        setUp();
        Id otherClaim = [SELECT Id FROM Case WHERE Subject = 'Wind took shingles off the garage'].Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(otherClaim), asks('sevt_a', 'read_claim', '{}'), idle('requires_action') }));
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.poll(claim().Id, SESSION);
            Assert.fail('A session answers only for the claim it was started on');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.WRONG_CLAIM, e.getMessage(), 'Says so');
        }
        Test.stopTest();

        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'No tool runs');
    }

    @IsTest
    static void shouldSayItTookTooLong_WhenTheRequestTimesOut() {
        setUp();
        Api api = new Api();
        api.failWith = 'Read timed out';
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.poll(claim().Id, SESSION);
            Assert.fail('A timeout is reported');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgentApi.TOO_SLOW, e.getMessage(), 'In plain words, so the page can offer to try again');
        }
        Test.stopTest();

        Assert.isNull(claim().Coverage_Read__c, 'And nothing on the claim changes');
    }

    @IsTest
    static void shouldSayTheKeyCannotUseManagedAgents_WhenARunIsRefused() {
        setUp();
        Api api = new Api().answer('POST', '/v1/sessions', 403, '{"type":"error","error":{"type":"permission_error","message":"Not allowed."}}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.start(claim().Id);
            Assert.fail('A refusal is reported');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgentApi.NOT_ALLOWED, e.getMessage(), 'And points to the check that still works');
        }
        Test.stopTest();

        Assert.areEqual(1, api.requests.size(), 'A refusal is not retried');
    }

    @IsTest
    static void shouldInterruptTheSession_WhenThePersonStopsIt() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(caseId) }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.stop(caseId, SESSION);
        Test.stopTest();

        Assert.isTrue(api.sent('POST', '/events')[0].getBody().contains('"type":"user.interrupt"'), 'The agent is told to stop');
    }

    @IsTest
    static void shouldLeaveAnotherClaimsSessionAlone_WhenAskedToStopItOrReadIntoIt() {
        setUp();
        Id caseId = claim().Id;
        Id otherClaim = [SELECT Id FROM Case WHERE Subject = 'Wind took shingles off the garage'].Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ task(otherClaim), asks('sevt_doc', 'read_document', '{"document":"D1"}'), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        try {
            AntsuranceCoverageAgent.stop(caseId, SESSION);
            Assert.fail('Only the claim\'s own session can be stopped from the claim');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.WRONG_CLAIM, e.getMessage(), 'Says so');
        }
        try {
            AntsuranceCoverageAgent.readDocument(caseId, SESSION, 'sevt_doc');
            Assert.fail('One claim\'s document is not read into another claim\'s session');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.WRONG_CLAIM, e.getMessage(), 'Says so');
        }
        Test.stopTest();

        Assert.isTrue(api.sent('POST', '/v1/').isEmpty(), 'Nothing is sent to the other claim\'s session');
    }

    @IsTest
    static void shouldSendNothing_WhenTheSessionIdIsNotShapedLikeOne() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api().answer('GET', '/v1/', '{"data":[]}').answer('POST', '/v1/', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        for (String notASession : new List<String>{ 'x/../agents/agent_1/archive?', SESSION + '/../../agents/agent_1', SESSION + '?beta=true', 'sesn_', 'agent_011YTj8jaC8ZtBkGiMX3qaoC', '', null }) {
            for (Integer entryPoint = 0; entryPoint < 3; entryPoint++) {
                try {
                    if (entryPoint == 0) {
                        AntsuranceCoverageAgent.poll(caseId, notASession);
                    } else if (entryPoint == 1) {
                        AntsuranceCoverageAgent.stop(caseId, notASession);
                    } else {
                        AntsuranceCoverageAgent.readDocument(caseId, notASession, 'sevt_doc');
                    }
                    Assert.fail('Refused: ' + notASession);
                } catch (AuraHandledException e) {
                    Assert.areEqual(AntsuranceCoverageAgentApi.NOT_A_SESSION, e.getMessage(), 'In plain words: ' + notASession);
                }
            }
        }
        Test.stopTest();

        Assert.isTrue(api.requests.isEmpty(), 'An id from the page that is not a session id never becomes part of a request');
        Assert.areEqual('/v1/sessions/sesn_011YTj8jaC8ZtBkGiMX3qaoC/events', AntsuranceCoverageAgentApi.eventsPath('sesn_011YTj8jaC8ZtBkGiMX3qaoC'), 'A real one does');
    }

    @IsTest
    static void shouldRunNothing_WhenTheSessionHasNotShownWhichClaimItIsFor() {
        setUp();
        Id caseId = claim().Id;
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{ asks('sevt_a', 'read_claim', '{}'), idle('requires_action') }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        try {
            AntsuranceCoverageAgent.stop(caseId, SESSION);
            Assert.fail('A session with no first message is not known to be this claim\'s');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceCoverageAgent.NOT_STARTED, e.getMessage(), 'Says so');
        }
        Test.stopTest();

        Assert.areEqual('working', run.status, 'The page keeps waiting');
        Assert.isTrue(api.sent('POST', '/events').isEmpty(), 'But no claim is read into a session that does not name it');
    }

    // ------------------------------------------------------------ the tools on their own

    @IsTest
    static void shouldListAttachedFilesWithKeys_WhenAskedWhatIsAttached() {
        Id caseId = claim().Id;
        ContentVersion invoice = new ContentVersion(Title = 'Mitigation invoice', PathOnClient = 'invoice.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'));
        ContentVersion photo = new ContentVersion(Title = 'Basement photo', PathOnClient = 'basement.jpg', VersionData = Blob.valueOf('jpg'));
        insert new List<ContentVersion>{ invoice, photo };
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion version : [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :new List<Id>{ invoice.Id, photo.Id }]) {
            links.add(new ContentDocumentLink(LinkedEntityId = caseId, ContentDocumentId = version.ContentDocumentId, ShareType = 'V'));
        }
        insert links;

        Test.startTest();
        AntsuranceCoverageAgentTools.Result listed = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.LIST_DOCUMENTS, new Map<String, Object>());
        AntsuranceCoverageAgentTools.Result unknown = AntsuranceCoverageAgentTools.run(caseId, 'delete_everything', new Map<String, Object>());
        Test.stopTest();

        Assert.areEqual('2 files attached', listed.found, 'The trace says how many');
        Assert.isTrue(listed.text.contains('Mitigation invoice') && listed.text.contains('Can be read with read_document'), 'A PDF can be read');
        Assert.isTrue(listed.text.contains('A photograph: use read_photo_assessment'), 'A photo is pointed at the photo assessment');
        Assert.isTrue(listed.text.contains('Photo assessment on file: no'), 'And the agent is told none is on file');
        Assert.areEqual('Read Mitigation invoice', AntsuranceCoverageAgentTools.label(AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => listed.text.contains('[D1] Mitigation') ? 'D1' : 'D2' }, caseId), 'A document step is named for the document');
        Assert.isTrue(unknown.isError, 'A tool that does not exist is refused, never guessed at');
    }

    @IsTest
    static void shouldHandOverWhatThePhotosShow_WhenAnAssessmentIsOnFile() {
        Id caseId = claim().Id;
        AntsuranceClaimsAssistantPhotos.Assessment seen = new AntsuranceClaimsAssistantPhotos.Assessment();
        seen.damageSummary = 'Standing water across the basement floor.';
        seen.lossSeen = 'Interior water damage';
        seen.consistency = 'consistent';
        seen.consistencyNote = 'Fits a burst supply line.';
        update new Case(Id = caseId, Photo_Assessment__c = JSON.serialize(seen));

        Test.startTest();
        AntsuranceCoverageAgentTools.Result shown = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_PHOTOS, new Map<String, Object>());
        Test.stopTest();

        Assert.areEqual('The photos point to interior water damage, which fits the loss as reported', shown.found, 'The trace says what the photos add');
        Assert.isTrue(shown.text.contains('[PHOTOS]') && shown.text.contains('Standing water across the basement floor.'), 'The agent gets the assessment under a key it can cite');
        Assert.isFalse(shown.isError, 'Reading it is not a failure');
    }

    @IsTest
    static void shouldKeepEveryKey_WhenAFileAndANoteAreAddedDuringTheRun() {
        setUp();
        Id caseId = claim().Id;
        insert new ContentVersion(Title = 'Mitigation invoice', PathOnClient = 'invoice.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'), FirstPublishLocationId = caseId);
        Id invoice = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Mitigation invoice'].ContentDocumentId;
        Id inspection = [SELECT Id FROM File_Note__c WHERE Case__c = :caseId].Id;
        // The keys as start sends them with the session.
        String keys = AntsuranceCoverageAgentTools.keysFor(caseId);
        Assert.isTrue(keys.contains('D1=' + invoice) && keys.contains('N1=' + inspection), keys);

        // While the agent works, a newer file and a newer note arrive. Numbered afresh, each takes the first key.
        insert new ContentVersion(Title = 'Adjuster call log', PathOnClient = 'log.pdf', VersionData = Blob.valueOf('%PDF-1.4 log'), FirstPublishLocationId = caseId);
        insert new File_Note__c(Case__c = caseId, Note_Type__c = 'Contact', Body__c = 'Called the insured about the sump pump.', Note_Date__c = Datetime.now());
        AntsuranceCoverageAgentTools.holdKeys(null);
        Assert.areEqual('Read Adjuster call log', AntsuranceCoverageAgentTools.label(AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => 'D1' }, caseId), 'Without the session\'s keys, D1 would now be the new file');

        // With them, a step is named from the key the session holds, and without loading the whole claim.
        AntsuranceCoverageAgentTools.holdKeys(keys);
        Integer queriesBefore = Limits.getQueries();
        Assert.areEqual('Read Mitigation invoice', AntsuranceCoverageAgentTools.label(AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => 'D1' }, caseId), 'D1 is still the invoice');
        Assert.areEqual(1, Limits.getQueries() - queriesBefore, 'Naming the step takes one query, not the whole claim again on every poll');

        String cites =
            '{"findings":[{"text":"The invoice shows clean supply water.","source":"D1"},{"text":"The inspection found a failed supply line.","source":"N1"},{"text":"Dwelling pays to rebuild after a burst pipe.","source":"C1"}],' +
            '"responding":"C1","verdict":"Covered","liability_open":false,"summary":"Dwelling responds to a burst supply line.","questions":[],"would_change":[]}';
        Api api = new Api()
            .answer('GET', '/v1/sessions/' + SESSION + '/events', events(new List<String>{
                task(caseId, keys),
                asks('sevt_l', 'list_documents', '{}'),
                asks('sevt_n', 'read_file_notes', '{}'),
                asks('sevt_doc', 'read_document', '{"document":"D1"}'),
                asks('sevt_r', 'record_finding', cites),
                idle('requires_action')
            }))
            .answer('POST', '/v1/sessions/' + SESSION + '/events', '{"data":[]}');
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        AntsuranceCoverageAgent.Run run = AntsuranceCoverageAgent.poll(caseId, SESSION);
        Test.stopTest();

        Assert.areEqual('Read Mitigation invoice', run.toRead[0].label, 'The document the agent asked for by D1 is the one it was shown as D1');
        String handedBack = api.sent('POST', '/events')[0].getBody();
        Assert.isTrue(handedBack.contains('[D1] Mitigation invoice'), 'The invoice keeps its key');
        Assert.isTrue(handedBack.contains('[D2] Adjuster call log'), 'The new file takes the next one');
        Assert.isTrue(handedBack.contains('[N1] ') && handedBack.substringAfter('[N1] ').startsWith('(') && handedBack.substringAfter('[N1] ').contains('Inspection found a failed braided supply line'), 'The inspection note keeps its key');
        Assert.isTrue(handedBack.substringBetween('[N2] ', '[N1] ').contains('Called the insured about the sump pump'), 'The new note takes the next one, and is still listed first as the newest');

        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.read(caseId);
        Assert.areEqual(invoice, check.findings[0].recordId, 'A finding that cites D1 is linked to the invoice, not to the file that arrived later');
        Assert.areEqual(inspection, check.findings[1].recordId, 'And one that cites N1 to the inspection note');
    }

    @IsTest
    static void shouldAnswerNoSuchRecord_WhenAKeyedFileHasGoneSinceTheSessionStarted() {
        Id caseId = claim().Id;
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Mitigation invoice', PathOnClient = 'invoice.pdf', VersionData = Blob.valueOf('%PDF-1.4 a'), FirstPublishLocationId = caseId),
            new ContentVersion(Title = 'Plumber report', PathOnClient = 'report.pdf', VersionData = Blob.valueOf('%PDF-1.4 b'), FirstPublishLocationId = caseId)
        };
        String keys = AntsuranceCoverageAgentTools.keysFor(caseId);
        Id first = (Id) keys.substringBetween('D1=', ' ');
        String survivor = [SELECT Title FROM ContentVersion WHERE ContentDocumentId != :first AND Title IN ('Mitigation invoice', 'Plumber report')].Title;
        delete [SELECT Id FROM ContentDocument WHERE Id = :first];

        AntsuranceCoverageAgentTools.holdKeys(keys);
        AntsuranceCoverageAgentTools.Result listed = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.LIST_DOCUMENTS, new Map<String, Object>());
        AntsuranceCoverageAgentTools.Result gone = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => 'D1' });

        Assert.isTrue(listed.text.contains('[D2] ' + survivor), 'The file that is left keeps its key and does not move up to D1');
        Assert.isFalse(listed.text.contains('[D1]'), 'The key of the file that went stands for nothing');
        Assert.isTrue(gone.isError && gone.text.contains('There is no document with the key D1'), 'And the agent is told so if it asks for it');
    }

    @IsTest
    static void shouldLeaveAnApprovedLetterOutOfTheDocuments_WhenAskedWhatIsAttached() {
        Id caseId = claim().Id;
        File_Note__c letter = new File_Note__c(
            Case__c = caseId, Note_Type__c = 'Coverage', Note_Date__c = Datetime.now(),
            Body__c = AntsuranceClaimLetters.NOTE_OPENING + ' Coverage confirmation, to Maya Harbor. Drafted by Claude, then read, edited and approved by Dana Reyes.'
        );
        insert letter;
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Coverage confirmation, Oct 5, 2026', PathOnClient = 'letter.pdf', VersionData = Blob.valueOf('%PDF-1.4 letter'), Description = AntsuranceClaimLetters.FILE_MARK + letter.Id, FirstPublishLocationId = caseId),
            new ContentVersion(Title = 'Mitigation invoice', PathOnClient = 'invoice.pdf', VersionData = Blob.valueOf('%PDF-1.4 invoice'), FirstPublishLocationId = caseId)
        };

        Test.startTest();
        AntsuranceCoverageAgentTools.Result listed = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.LIST_DOCUMENTS, new Map<String, Object>());
        AntsuranceCoverageAgentTools.Result notes = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_NOTES, new Map<String, Object>());
        Test.stopTest();

        Assert.areEqual('1 file attached', listed.found, 'The letter\'s PDF is what the carrier sent, not a document that came in');
        Assert.isTrue(listed.text.contains('[D1] Mitigation invoice'), 'So the invoice is the first document');
        Assert.isFalse(listed.text.contains('Coverage confirmation'), 'And the letter is not offered to be read');
        Assert.areEqual('1 file note', notes.found, 'Nor is the note the letter left behind');
    }

    @IsTest
    static void shouldDeclareEveryToolTheAgentMayCall_WhenTheDefinitionIsBuilt() {
        List<Object> tools = (List<Object>) JSON.deserializeUntyped(AntsuranceCoverageAgentTools.definitions());

        Assert.areEqual(8, tools.size(), 'Eight custom tools');
        Set<String> names = new Set<String>();
        for (Object item : tools) {
            Map<String, Object> tool = (Map<String, Object>) item;
            names.add((String) tool.get('name'));
            Assert.areEqual('custom', tool.get('type'), 'Each runs in Salesforce, not on the platform');
            Assert.isNotNull(tool.get('input_schema'), 'Each says what it takes');
        }
        Assert.isTrue(names.contains(AntsuranceCoverageAgentTools.RECORD) && names.contains(AntsuranceCoverageAgentTools.READ_DOCUMENT), 'Including the two that take input');
        Assert.isTrue(AntsuranceCoverageAgentTools.isSlow(AntsuranceCoverageAgentTools.READ_DOCUMENT), 'Reading a document gets a request of its own');
        Assert.isFalse(AntsuranceCoverageAgentTools.isSlow(AntsuranceCoverageAgentTools.READ_POLICY), 'A record read does not');
    }

    @IsTest
    static void shouldKeyASalesforceNoteWithTheNotes_AndNeverOfferItAsADocument() {
        Id caseId = claim().Id;
        Id inspection = [SELECT Id FROM File_Note__c WHERE Case__c = :caseId].Id;
        // A stand-in for the note, so this runs the same where the org has Notes turned off.
        Id call = AntsuranceSalesforceNotes.standIn(caseId, 'Body shop call', 'The shop found a cracked fitting behind the wall.', Datetime.now().addHours(-1));
        // The keys as start sends them with the session: the Salesforce note is the newest note, and no document.
        String keys = AntsuranceCoverageAgentTools.keysFor(caseId);
        Assert.isTrue(keys.contains('N1=' + call) && keys.contains('N2=' + inspection), keys);
        Assert.isFalse(keys.contains('D1='), 'A Salesforce note takes no document key: ' + keys);

        // While the agent works, another is written. Numbered afresh it would be N1.
        Id later = AntsuranceSalesforceNotes.standIn(caseId, 'Plumber call', 'The plumber kept the failed part.', Datetime.now());
        AntsuranceCoverageAgentTools.holdKeys(keys);

        Test.startTest();
        AntsuranceCoverageAgentTools.Result notes = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_NOTES, new Map<String, Object>());
        AntsuranceCoverageAgentTools.Result listed = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.LIST_DOCUMENTS, new Map<String, Object>());
        AntsuranceCoverageAgentTools.Result asDocument = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => 'N1' });
        Test.stopTest();

        Assert.areEqual('3 file notes', notes.found, 'Both Salesforce notes are read with the file note');
        Assert.isTrue(notes.text.substringAfter('[N1] ').substringBefore('\n').contains('Salesforce note, ' + UserInfo.getName() + ') **Body shop call:**'), 'The first keeps the key the session knows it by: ' + notes.text);
        Assert.isTrue(notes.text.contains('The shop found a cracked fitting behind the wall.'), 'With its words');
        Assert.isTrue(notes.text.substringAfter('[N2] ').contains('Inspection found a failed braided supply line'), 'So does the file note');
        Assert.isTrue(notes.text.substringBetween('[N3] ', '[N1] ').contains('**Plumber call:**'), 'And the one written since takes the next key, and is still listed first as the newest');
        Assert.areEqual('0 files attached', listed.found, 'Neither is a file the agent is offered to read');
        Assert.isTrue(asDocument.isError, 'And a note\'s key does not open it as a document');
        Assert.areEqual('Read a document', AntsuranceCoverageAgentTools.label(AntsuranceCoverageAgentTools.READ_DOCUMENT, new Map<String, Object>{ 'document' => 'N1' }, caseId), 'Nor name it as one');

        Integer linked = 0;
        for (AntsuranceClaimsAssistantCoverage.Source entry : AntsuranceCoverageAgentTools.facts(caseId).sources) {
            if (entry.key == 'N1' || entry.key == 'N3') {
                linked++;
                Assert.areEqual(entry.key == 'N1' ? call : later, entry.recordId, 'A finding that cites ' + entry.key + ' links to that note');
            }
        }
        Assert.areEqual(2, linked, 'Both can be cited');
    }
}
