/**
 * The chat's own flow: a step, a lookup, a proposal, a file, a failure. Every record here is a
 * standard object, so these tests run in an org that has Ask Claude and nothing else of ours. Where a
 * test depends on the org's data model it asks for the model that reads any org's schema;
 * AntsuranceClaudeInsuranceTest covers the insurance model.
 */
@IsTest
private class AntsuranceClaudeControllerTest {
    private static final String QUESTION = '{"role":"user","content":"What is going on with my accounts?"}';
    private static final String USER_TURN = '[' + QUESTION + ']';
    private static final String FINAL_ANSWER =
        '{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[' +
        '{"type":"thinking","thinking":"","signature":"sig"},' +
        '{"type":"text","text":"Harbor Mutual is your only account."}]}';

    /** Returns the queued responses in order and records every request. */
    private class ClaudeMock implements HttpCalloutMock {
        private final List<Integer> statuses;
        private final List<String> bodies;
        public List<HttpRequest> requests = new List<HttpRequest>();

        ClaudeMock(Integer status, String body) {
            this(new List<Integer>{ status }, new List<String>{ body });
        }

        ClaudeMock(List<Integer> statuses, List<String> bodies) {
            this.statuses = statuses;
            this.bodies = bodies;
        }

        public HttpResponse respond(HttpRequest request) {
            Integer position = Math.min(requests.size(), bodies.size() - 1);
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statuses[position]);
            response.setBody(bodies[position]);
            requests.add(request);
            return response;
        }
    }

    /** A callout that fails the way Salesforce reports it, without a response. */
    private class FailingMock implements HttpCalloutMock {
        private final String message;
        public Integer attempts = 0;

        FailingMock(String message) {
            this.message = message;
        }

        public HttpResponse respond(HttpRequest request) {
            attempts++;
            CalloutException failure = new CalloutException();
            failure.setMessage(message);
            throw failure;
        }
    }

    private static String toolUse(String soql) {
        return '{"model":"claude-opus-5-5","stop_reason":"tool_use","content":[' +
            '{"type":"tool_use","id":"toolu_1","name":"query_salesforce","input":{"query":' + JSON.serialize(soql) + '}}]}';
    }

    private static String failureMessage(String messagesJson, String model) {
        try {
            AntsuranceClaudeController.sendMessage(messagesJson, model);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    /** The tool_result block a lookup step appended for Claude. */
    private static Map<String, Object> toolResultFrom(AntsuranceClaudeController.ChatReply reply) {
        List<Object> appended = (List<Object>) JSON.deserializeUntyped(reply.appendedJson);
        Map<String, Object> results = (Map<String, Object>) appended[1];
        return (Map<String, Object>) ((List<Object>) results.get('content'))[0];
    }

    private static Map<String, Object> bodyOf(HttpRequest request) {
        return (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
    }

    /** One of the two instruction blocks sent: 0 is the fixed, cached one and 1 changes per request. */
    private static Map<String, Object> systemBlock(HttpRequest request, Integer position) {
        return (Map<String, Object>) ((List<Object>) bodyOf(request).get('system'))[position];
    }

    private static String proposal(String toolName, Map<String, Object> input) {
        return '{"model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},"content":[' +
            '{"type":"tool_use","id":"toolu_p","name":"' + toolName + '","input":' + JSON.serialize(input) + '}]}';
    }

    @TestSetup
    static void createRecords() {
        Account customer = new Account(Name = 'Harbor Mutual', Industry = 'Insurance');
        insert customer;
        insert new Contact(LastName = 'Reyes', AccountId = customer.Id);
    }

    @IsTest
    static void aStepThatRunsOutOfTimeSaysSoAndLosesNothing() {
        FailingMock slow = new FailingMock('Read timed out');
        Test.setMock(HttpCalloutMock.class, slow);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, 'panel');
        Test.stopTest();

        Assert.isTrue(reply.timedOut, 'A timeout is reported on the reply, not thrown as an error');
        Assert.areEqual(AntsuranceClaudeController.TIMED_OUT, reply.timeoutMessage, 'With the words to show in place of the answer');
        Assert.isTrue(reply.timeoutMessage.contains('two-minute limit'), 'Which name the limit');
        Assert.isFalse(reply.done, 'The exchange is not finished, so the same step can be sent again');
        Assert.isNull(reply.appendedJson, 'Nothing is added to the conversation');
        Assert.isNull(reply.text, 'And there is no answer');
    }

    @IsTest
    static void noCalloutStartsWithTooLittleOfTheTransactionLeft() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);
        // As if an earlier callout in this transaction had used all but ten seconds of the budget.
        AntsuranceClaudeController.spentMs = AntsuranceClaudeController.TRANSACTION_BUDGET_MS - 10000;

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(reply.timedOut, 'With under fifteen seconds left the step reports a timeout');
        Assert.areEqual(0, mock.requests.size(), 'Without starting a callout Salesforce would cut off');
    }

    @IsTest
    static void aRetryInTheSameTransactionOnlyGetsTheTimeThatIsLeft() {
        // Fast mode is rate limited, so the same step is tried again at standard speed.
        ClaudeMock mock = new ClaudeMock(new List<Integer>{ 429, 200 }, new List<String>{ '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}', FINAL_ANSWER });
        Test.setMock(HttpCalloutMock.class, mock);
        AntsuranceClaudeController.spentMs = AntsuranceClaudeController.TRANSACTION_BUDGET_MS - AntsuranceClaudeController.SHORTEST_USEFUL_MS - 1000;

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.areEqual(2, mock.requests.size(), 'Both attempts fit in the time that was left');
        Assert.isTrue(reply.done, 'And the second one answers');
        Assert.isTrue(
            AntsuranceClaudeController.spentMs >= AntsuranceClaudeController.TRANSACTION_BUDGET_MS - AntsuranceClaudeController.SHORTEST_USEFUL_MS - 1000,
            'The time both attempts took is counted against the transaction'
        );
    }

    @IsTest
    static void aCalloutThatDoesNotGetThroughIsNotCalledATimeout() {
        Test.setMock(HttpCalloutMock.class, new FailingMock('Unable to tunnel through proxy'));

        Test.startTest();
        String message = failureMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(message.contains('could not be reached'), 'A connection failure keeps its own message');
    }

    @IsTest
    static void answersDirectlyAndSendsTheExpectedRequest() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'An answer ends the exchange');
        Assert.areEqual('Harbor Mutual is your only account.', reply.text, 'Text blocks become the reply');
        Assert.isFalse(reply.refused, 'A normal reply is not a refusal');
        Assert.isTrue(reply.queries.isEmpty(), 'No query was needed');
        List<Object> appended = (List<Object>) JSON.deserializeUntyped(reply.appendedJson);
        Assert.areEqual(1, appended.size(), 'Only the assistant turn is appended');
        Map<String, Object> turn = (Map<String, Object>) appended[0];
        Assert.areEqual(2, ((List<Object>) turn.get('content')).size(), 'Thinking and text blocks are both kept for replay');

        HttpRequest request = mock.requests[0];
        Assert.areEqual('callout:Anthropic_API/v1/messages', request.getEndpoint(), 'Uses the named credential');
        Assert.areEqual('2023-06-01', request.getHeader('anthropic-version'), 'Sends the API version');
        Map<String, Object> sent = bodyOf(request);
        Assert.areEqual(AntsuranceClaudeController.DEFAULT_MODEL, sent.get('model'), 'Uses the default model when none is chosen');
        Assert.isTrue(sent.containsKey('output_config'), 'Sets effort on models that support it');
        Assert.areEqual('default', sent.get('fallbacks'), 'Opts into server-side fallbacks');
        Assert.areEqual('fast', sent.get('speed'), 'Asks for fast mode on the default model');
        Assert.isTrue(request.getHeader('anthropic-beta').contains('fast-mode'), 'Sends the fast mode beta header');
        Assert.isTrue(request.getHeader('anthropic-beta').contains('server-side-fallback'), 'Sends the fallback beta header');
        Assert.isTrue(((String) systemBlock(request, 1).get('text')).contains(UserInfo.getUserId()), 'Tells Claude who is asking');
        Assert.isTrue(systemBlock(request, 0).containsKey('cache_control'), 'The fixed instructions are marked for caching');
        Assert.isTrue(((String) systemBlock(request, 0).get('text')).contains('Write in American English'), 'Claude is asked for American spelling');
        Assert.isFalse(systemBlock(request, 1).containsKey('cache_control'), 'The part that changes per request is not');
        Assert.isFalse(((String) systemBlock(request, 0).get('text')).contains(UserInfo.getUserId()), 'Nothing about the user is in the cached block');
        Assert.areEqual(1, ((List<Object>) sent.get('tools')).size(), 'Offers only the query tool to callers that cannot show a proposal');
    }

    @IsTest
    static void aLookupStepRunsTheQueryAndHandsBackTheResults() {
        String soql = 'SELECT Name, Industry, (SELECT LastName FROM Contacts) FROM Account ORDER BY Name';
        ClaudeMock mock = new ClaudeMock(200, toolUse(soql));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isFalse(reply.done, 'A lookup step is not the end of the exchange');
        Assert.isNull(reply.text, 'There is no answer yet');
        Assert.areEqual(new List<String>{ soql }, reply.queries, 'Reports the query that ran');
        Assert.areEqual(1, mock.requests.size(), 'One step makes one API call');

        List<Object> appended = (List<Object>) JSON.deserializeUntyped(reply.appendedJson);
        Assert.areEqual(2, appended.size(), 'Appends the tool call and its results');
        Map<String, Object> toolResult = toolResultFrom(reply);
        Assert.areEqual('toolu_1', toolResult.get('tool_use_id'), 'Answers the matching tool call');
        Assert.isNull(toolResult.get('is_error'), 'The query succeeded');
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped((String) toolResult.get('content'));
        Assert.areEqual(1, result.get('rowCount'), 'One account matches');
        Map<String, Object> record = (Map<String, Object>) ((List<Object>) result.get('records'))[0];
        Assert.areEqual('Harbor Mutual', record.get('Name'), 'Returns field values');
        Assert.isFalse(record.containsKey('attributes'), 'Drops the attributes wrapper');
        Assert.areEqual(1, ((List<Object>) record.get('Contacts')).size(), 'Includes child records');
    }

    @IsTest
    static void theNextStepSendsTheLookupResultsAndReturnsTheAnswer() {
        String conversation =
            '[' + QUESTION +
            ',{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"query_salesforce","input":{"query":"SELECT Name FROM Account"}}]}' +
            ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"{\\"rowCount\\":1}"}]}]';

        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(conversation, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'The answer ends the exchange');
        Assert.areEqual('Harbor Mutual is your only account.', reply.text, 'Returns the final answer');
        Assert.areEqual(3, ((List<Object>) bodyOf(mock.requests[0]).get('messages')).size(), 'Replays the question, tool call and results');
    }

    @IsTest
    static void countQueriesReturnATotal() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT COUNT() FROM Account')));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped((String) toolResultFrom(reply).get('content'));
        Assert.areEqual(1, result.get('count'), 'Counts the matching rows');
    }

    @IsTest
    static void totalsRunWithoutTheRowLimitThatWouldBreakThem() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT COUNT(Id) total, MAX(Name) latest FROM Account LIMIT 1')));
        AntsuranceClaudeController.ChatReply withLimit = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT COUNT(Id) total FROM Account')));
        AntsuranceClaudeController.ChatReply withoutLimit = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT Industry, COUNT(Id) total FROM Account GROUP BY Industry')));
        AntsuranceClaudeController.ChatReply grouped = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        for (AntsuranceClaudeController.ChatReply reply : new List<AntsuranceClaudeController.ChatReply>{ withLimit, withoutLimit, grouped }) {
            Map<String, Object> toolResult = toolResultFrom(reply);
            Assert.isNull(toolResult.get('is_error'), 'The query ran: ' + toolResult.get('content'));
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped((String) toolResult.get('content'));
            Assert.areEqual(1, ((Map<String, Object>) ((List<Object>) result.get('records'))[0]).get('total'), 'One account is counted');
        }
    }

    @IsTest
    static void groupingByAFieldThatCannotBeGroupedIsExplainedInsteadOfFailing() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT AnnualRevenue, COUNT(Id) total FROM Account GROUP BY AnnualRevenue')));
        AntsuranceClaudeController.ChatReply direct = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT Account.AnnualRevenue, COUNT(Id) total FROM Contact GROUP BY Account.AnnualRevenue ORDER BY COUNT(Id) DESC')));
        AntsuranceClaudeController.ChatReply throughAParent = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        for (AntsuranceClaudeController.ChatReply reply : new List<AntsuranceClaudeController.ChatReply>{ direct, throughAParent }) {
            Assert.areEqual(true, toolResultFrom(reply).get('is_error'), 'The problem goes back to Claude as a tool error');
            Assert.isTrue(((String) toolResultFrom(reply).get('content')).contains('cannot be used in GROUP BY'), 'with the reason');
        }
    }

    @IsTest
    static void invalidAndNonSelectQueriesComeBackAsToolErrors() {
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('DELETE FROM Account')));
        AntsuranceClaudeController.ChatReply notSelect = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT Nope__c FROM Account')));
        AntsuranceClaudeController.ChatReply badField = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.areEqual(true, toolResultFrom(notSelect).get('is_error'), 'A non-SELECT statement is rejected');
        Assert.areEqual(true, toolResultFrom(badField).get('is_error'), 'An invalid field is reported back');
        Assert.isTrue(notSelect.queries.isEmpty() && badField.queries.isEmpty(), 'Failed queries are not reported as run');
        Assert.areEqual(1, [SELECT COUNT() FROM Account], 'Nothing was deleted');
    }

    @IsTest
    static void stopsAskingForLookupsAfterTheRoundLimit() {
        String round =
            ',{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"query_salesforce","input":{"query":"SELECT Name FROM Account"}}]}' +
            ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"{}"}]}';
        String fourRounds = '[' + QUESTION + round + round + round + round + ']';
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT Name FROM Account')));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(fourRounds, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'A fifth lookup is not run');
        Assert.isNull(reply.appendedJson, 'An unfinished exchange is not replayed');
        Assert.isTrue(reply.text.contains('did not return an answer'), 'The user is told there was no answer');
    }

    @IsTest
    static void usesTheChosenModelAndOnlyTheSettingsItSupports() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.sendMessage(USER_TURN, 'claude-haiku-4-5');
        Test.stopTest();

        Map<String, Object> sent = bodyOf(mock.requests[0]);
        Assert.areEqual('claude-haiku-4-5', sent.get('model'), 'Sends the chosen model');
        Assert.isFalse(sent.containsKey('output_config'), 'Haiku does not accept an effort setting');
        Assert.isFalse(sent.containsKey('fallbacks'), 'Haiku does not use server-side fallbacks');
        Assert.isFalse(sent.containsKey('speed'), 'Haiku has no fast mode');
        Assert.isNull(mock.requests[0].getHeader('anthropic-beta'), 'No beta header is needed');
    }

    @IsTest
    static void retriesAtStandardSpeedWhenFastModeIsRateLimited() {
        ClaudeMock mock = new ClaudeMock(new List<Integer>{ 429, 200 }, new List<String>{ '{}', FINAL_ANSWER });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.areEqual('Harbor Mutual is your only account.', reply.text, 'The retry succeeds');
        Assert.areEqual(2, mock.requests.size(), 'One retry is made');
        Assert.isFalse(bodyOf(mock.requests[1]).containsKey('speed'), 'The retry drops fast mode');
        Assert.isFalse(mock.requests[1].getHeader('anthropic-beta').contains('fast-mode'), 'The retry drops the fast mode header');
    }

    @IsTest
    static void theWordsTheComponentsShowComeFromTheModel() {
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();

        Test.startTest();
        AntsuranceClaudeModel.Words words = AntsuranceClaudeController.getWords();
        Test.stopTest();

        Assert.isFalse(words.starters.isEmpty(), 'There are starting points to offer');
        Assert.isFalse(String.isBlank(words.placeholder), 'And words for the empty question box');
    }

    @IsTest
    static void listsModelsAndRejectsUnknownOnes() {
        List<AntsuranceClaudeController.ModelOption> models = AntsuranceClaudeController.getModels();
        Integer defaults = 0;
        for (AntsuranceClaudeController.ModelOption model : models) {
            if (model.isDefault) {
                defaults++;
                Assert.areEqual(AntsuranceClaudeController.DEFAULT_MODEL, model.value, 'The default model is flagged');
            }
        }
        Assert.areEqual(1, defaults, 'Exactly one model is the default');
        Assert.isTrue(failureMessage(USER_TURN, 'not-a-model').contains('not available'), 'Unknown models are rejected');
        Assert.areEqual(0, Limits.getCallouts(), 'No callout is made for an unknown model');
    }

    @IsTest
    static void describesTheRecordOnScreen() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Contact person = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        AntsuranceClaudeController.RecordContext account = AntsuranceClaudeController.getRecordContext(customer.Id);
        AntsuranceClaudeController.RecordContext contact = AntsuranceClaudeController.getRecordContext(person.Id);
        AntsuranceClaudeController.RecordContext none = AntsuranceClaudeController.getRecordContext(null);
        Test.stopTest();

        Assert.areEqual('Account', account.objectApiName, 'Identifies the object from the Id');
        Assert.areEqual('Harbor Mutual', account.name, 'Reads the record name');
        Assert.areEqual(customer.Id, account.recordId, 'Carries the record Id');
        Assert.areEqual('Reyes', contact.name, 'Uses each object\'s own name field');
        Assert.isNull(none, 'No record means no context');
    }

    @IsTest
    static void aCaseIsDescribedByItsNumberAndSubject() {
        Case request = new Case(Subject = 'Printer will not start');
        insert request;
        request = [SELECT CaseNumber FROM Case WHERE Id = :request.Id];

        Test.startTest();
        AntsuranceClaudeController.RecordContext context = AntsuranceClaudeController.getRecordContext(request.Id);
        Test.stopTest();

        Assert.areEqual('Case', context.objectApiName, 'Identifies the object');
        Assert.isFalse(String.isBlank(context.objectLabel), 'Says what kind of record it is');
        Assert.areEqual(request.CaseNumber + ': Printer will not start', context.name, 'Adds the subject to the case number');
    }

    @IsTest
    static void aDeletedRecordHasNoContext() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        delete [SELECT Id FROM Contact];
        delete customer;

        Test.startTest();
        AntsuranceClaudeController.RecordContext context = AntsuranceClaudeController.getRecordContext(customer.Id);
        Test.stopTest();

        Assert.isNull(context, 'A record that cannot be read gives no context');
    }

    @IsTest
    static void theChatStepSendsTheOpenRecordsFactsAndOffersTheProposalTools() {
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();
        Account customer = [SELECT Id FROM Account LIMIT 1];
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, customer.Id, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'An answer ends the exchange');
        Assert.isTrue(reply.proposals.isEmpty(), 'An answer proposes nothing');
        HttpRequest request = mock.requests[0];
        String changing = (String) systemBlock(request, 1).get('text');
        Assert.isTrue(changing.contains('Facts about the open record'), 'The open record\'s facts are sent with the question');
        Assert.isTrue(changing.contains('Harbor Mutual') && changing.contains('Insurance'), 'The facts carry the record and its fields');
        Assert.isTrue(changing.contains('never call show_record for the open record'), 'Claude is told the record is already on screen');
        String fixed = (String) systemBlock(request, 0).get('text');
        Assert.isTrue(fixed.contains('writes nothing') && fixed.contains('Confirm'), 'Claude is told a proposal writes nothing until the user confirms');
        Assert.isTrue(fixed.contains('Data model') && fixed.contains('- Account'), 'Claude is given the org\'s own data model');
        List<Object> tools = (List<Object>) bodyOf(request).get('tools');
        Assert.areEqual(10, tools.size(), 'Offers the query tool, the task proposal and the eight display tools');
        Assert.areEqual('propose_task', ((Map<String, Object>) tools[1]).get('name'), 'A follow-up task is the change any org can take');
        Assert.isTrue(((String) ((Map<String, Object>) tools[1]).get('description')).contains('Nothing is written unless they press Confirm'), 'The proposal tool says it writes nothing');
    }

    @IsTest
    static void aChatStepWithoutARecordSendsNoFacts() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, null);
        Test.stopTest();

        Assert.isFalse(((String) systemBlock(mock.requests[0], 1).get('text')).contains('Facts about the open record'), 'No record means no facts');
    }

    @IsTest
    static void aProposalComesBackAsACardAndWritesNothing() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> input = new Map<String, Object>{
            'subject' => 'Call about the renewal',
            'due_date' => String.valueOf(Date.today().addDays(3)),
            'related_record_id' => customer.Id,
            'priority' => 'Normal'
        };
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, proposal('propose_task', input)));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, customer.Id, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'A step that only proposes ends the exchange');
        Assert.isNull(reply.text, 'The card stands in for an answer');
        Assert.areEqual(1, reply.proposals.size(), 'One card');
        Assert.areEqual('task', reply.proposals[0].kind, 'The card is for a task');
        Assert.areEqual('toolu_p', reply.proposals[0].id, 'The card is keyed by the tool call');
        Map<String, Object> toolResult = toolResultFrom(reply);
        Assert.isNull(toolResult.get('is_error'), 'The proposal was accepted');
        Assert.isTrue(((String) toolResult.get('content')).contains('Nothing has been written'), 'Claude is told nothing was written');
        Assert.areEqual(10, reply.usage.get('input_tokens'), 'Token counts are passed through');
        Assert.areEqual(0, [SELECT COUNT() FROM Task], 'Proposing a task creates no task');
    }

    @IsTest
    static void aProposalThatCannotBeMadeGoesBackToClaude() {
        Map<String, Object> input = new Map<String, Object>{ 'subject' => 'Call about the renewal', 'due_date' => String.valueOf(Date.today()), 'related_record_id' => 'the Reyes file', 'priority' => 'Normal' };
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, proposal('propose_task', input)));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, null);
        Test.stopTest();

        Assert.isFalse(reply.done, 'Claude gets the chance to correct the proposal');
        Assert.isTrue(reply.proposals.isEmpty(), 'No card is shown');
        Assert.areEqual(true, toolResultFrom(reply).get('is_error'), 'The problem is reported as a tool error');
        Assert.isTrue(((String) toolResultFrom(reply).get('content')).contains('not a record Id'), 'With the reason');
        Assert.areEqual(0, [SELECT COUNT() FROM Task], 'Nothing was written');
    }

    @IsTest
    static void aMessageTypedAfterAProposalStartsANewExchange() {
        String round =
            ',{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"query_salesforce","input":{"query":"SELECT Name FROM Account"}}]}' +
            ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"{}"}]}';
        String typedAfterProposal =
            ',{"role":"assistant","content":[{"type":"tool_use","id":"p","name":"propose_task","input":{}}]}' +
            ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"p","content":"Shown"},{"type":"text","text":"Thanks. How many accounts are there?"}]}';
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, toolUse('SELECT COUNT() FROM Account')));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep('[' + QUESTION + round + round + round + round + typedAfterProposal + ']', null, null, null);
        Test.stopTest();

        Assert.isFalse(reply.done, 'The lookup limit counts from the latest typed message');
        Assert.areEqual(1, reply.queries.size(), 'The lookup ran');
    }

    @IsTest
    static void refusalIsReportedWithoutContentToReplay() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, '{"model":"claude-opus-5-5","stop_reason":"refusal","content":[]}'));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(reply.refused, 'The refusal is flagged');
        Assert.isTrue(reply.done, 'A refusal ends the exchange');
        Assert.isNull(reply.appendedJson, 'Nothing is replayed after a refusal');
        Assert.isTrue(reply.text.contains('declined'), 'The user is told Claude declined');
    }

    @IsTest
    static void apiErrorsBecomeReadableMessages() {
        Test.setMock(
            HttpCalloutMock.class,
            new ClaudeMock(401, '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
        );

        Test.startTest();
        String message = failureMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(message.contains('rejected the API key'), 'Explains the authentication failure');
        Assert.isTrue(message.contains('invalid x-api-key'), 'Includes the detail from the API');
    }

    @IsTest
    static void serverErrorsWithoutJsonStillProduceAMessage() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(529, 'overloaded'));

        Test.startTest();
        String message = failureMessage(USER_TURN, null);
        Test.stopTest();

        Assert.isTrue(message.contains('temporarily unavailable'), 'Explains the outage');
    }

    @IsTest
    static void invalidConversationsAreRejectedBeforeAnyCallout() {
        Assert.isTrue(failureMessage('not json', null).contains('could not be read'), 'Rejects malformed JSON');
        Assert.isTrue(failureMessage('[]', null).contains('could not be read'), 'Rejects an empty conversation');
        Assert.isTrue(
            failureMessage('[{"role":"assistant","content":"Hello"}]', null).contains('could not be read'),
            'The last turn must come from the user'
        );
        Assert.isTrue(failureMessage('[{"role":"system","content":"x"}]', null).contains('could not be read'), 'Rejects other roles');
        Assert.areEqual(0, Limits.getCallouts(), 'No callout is made for invalid input');
    }

    private static final String WITH_PHOTO =
        '[{"role":"user","content":[' +
        '{"type":"attachment","id":"f1","name":"roof.jpg","media_type":"image/jpeg"},' +
        '{"type":"attachment","id":"f2","name":"estimate.pdf","media_type":"application/pdf"},' +
        '{"type":"text","text":"Does the estimate match the damage?"}]}]';

    /** The content blocks of the last user turn in a request. */
    private static List<Object> lastUserContent(HttpRequest request) {
        List<Object> messages = (List<Object>) bodyOf(request).get('messages');
        return (List<Object>) ((Map<String, Object>) messages[messages.size() - 1]).get('content');
    }

    @IsTest
    static void filesSentWithAMessageReachClaudeAsImageAndDocumentBlocks() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStepWithFiles(
            WITH_PHOTO,
            null,
            null,
            'page',
            new List<String>{ 'f1', 'f2' },
            new List<String>{ 'image/jpeg', 'application/pdf' },
            new List<String>{ 'QUJD', 'REVG' }
        );
        Test.stopTest();

        Assert.isTrue(reply.done, 'Claude answers about the files');
        Assert.isFalse(reply.appendedJson.contains('QUJD'), 'No file comes back with the turns to replay');
        List<Object> content = lastUserContent(mock.requests[0]);
        Assert.areEqual(5, content.size(), 'A name and a block for each file, then the question');
        Map<String, Object> image = (Map<String, Object>) content[1];
        Assert.areEqual('image', image.get('type'), 'The photo is an image block');
        Assert.areEqual('QUJD', ((Map<String, Object>) image.get('source')).get('data'), 'Holding the photo');
        Map<String, Object> document = (Map<String, Object>) content[3];
        Assert.areEqual('document', document.get('type'), 'The PDF is a document block');
        Assert.areEqual('REVG', ((Map<String, Object>) document.get('source')).get('data'), 'Holding the PDF');
        Assert.areEqual('application/pdf', ((Map<String, Object>) document.get('source')).get('media_type'), 'With its type');
        Assert.isTrue(((String) systemBlock(mock.requests[0], 0).get('text')).contains('attach photos and PDFs'), 'Claude is told a message can carry files');
    }

    @IsTest
    static void aFileFromAnEarlierMessageIsToldToClaudeByNameOnly() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.sendChatStep(WITH_PHOTO, null, null, 'panel');
        Test.stopTest();

        List<Object> content = lastUserContent(mock.requests[0]);
        Assert.areEqual(3, content.size(), 'A note for each file, then the question');
        for (Object item : content) {
            Assert.areEqual('text', ((Map<String, Object>) item).get('type'), 'Only text is sent when the files are not');
        }
        Assert.isTrue(((String) ((Map<String, Object>) content[0]).get('text')).contains('"roof.jpg"'), 'The note names the file');
    }

    @IsTest
    static void filesThatBreakALimitAreRefusedBeforeClaudeIsCalled() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);
        List<String> ids = new List<String>{ 'f1', 'f2', 'f3', 'f4', 'f5' };
        List<String> types = new List<String>{ 'image/jpeg', 'image/jpeg', 'image/jpeg', 'image/jpeg', 'image/jpeg' };
        List<String> data = new List<String>{ 'QUJD', 'QUJD', 'QUJD', 'QUJD', 'QUJD' };

        Test.startTest();
        String message;
        try {
            AntsuranceClaudeController.sendChatStepWithFiles(WITH_PHOTO, null, null, 'page', ids, types, data);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(message.contains('up to 4 files'), 'Says the limit in plain words: ' + message);
        Assert.isTrue(mock.requests.isEmpty(), 'Nothing was sent');
    }

    @IsTest
    static void theLargestMessageAllowedFitsInTheHeap() {
        ClaudeMock mock = new ClaudeMock(200, FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);
        // Two files at the photo limit: together the most one message may carry.
        String photo = 'A'.repeat((AntsuranceClaudeAttachments.MAX_IMAGE_BYTES / 3) * 4);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStepWithFiles(
            WITH_PHOTO,
            null,
            null,
            'page',
            new List<String>{ 'f1', 'f2' },
            new List<String>{ 'image/jpeg', 'image/jpeg' },
            new List<String>{ photo, photo }
        );
        Integer heapUsed = Limits.getHeapSize();
        Test.stopTest();

        Assert.isTrue(reply.done, 'The step finishes');
        Assert.isTrue(mock.requests[0].getBody().length() > 2 * photo.length(), 'Both files are in the request');
        Assert.isTrue(heapUsed < Limits.getLimitHeapSize(), 'With heap to spare: ' + heapUsed);
    }

    @IsTest
    static void theOpenRecordsFilesAreListedAndHandedOver() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        insert new ContentVersion(Title = 'Roof after the storm', PathOnClient = 'roof.jpg', VersionData = Blob.valueOf('photo bytes'), FirstPublishLocationId = customer.Id);

        Test.startTest();
        List<AntsuranceClaudeAttachments.RecordFile> files = AntsuranceClaudeController.getRecordFiles(customer.Id);
        AntsuranceClaudeAttachments.RecordFile file = AntsuranceClaudeController.getRecordFile(customer.Id, files[0].documentId);
        String refused;
        try {
            AntsuranceClaudeController.getRecordFile(null, files[0].documentId);
        } catch (AuraHandledException e) {
            refused = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(1, files.size(), 'The photo on the record is offered');
        Assert.areEqual('photo bytes', EncodingUtil.base64Decode(file.data).toString(), 'And handed over with its contents');
        Assert.isTrue(refused.contains('not on this record'), 'A file asked for without its record is refused: ' + refused);
    }
}
