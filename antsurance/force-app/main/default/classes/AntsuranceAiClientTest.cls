@IsTest
private class AntsuranceAiClientTest {
    /** Answers each call with the next canned response and keeps the requests for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        List<Integer> statuses = new List<Integer>();
        List<String> bodies = new List<String>();
        List<HttpRequest> requests = new List<HttpRequest>();
        Boolean failToConnect = false;
        /** With failToConnect: the connection opened but no answer came back in time. */
        Boolean timesOut = false;

        ClaudeMock(Integer status, String body) {
            add(status, body);
        }

        ClaudeMock add(Integer status, String body) {
            statuses.add(status);
            bodies.add(body);
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            if (failToConnect) {
                throw new CalloutException(timesOut ? 'Read timed out' : 'Connection refused');
            }
            Integer index = Math.min(requests.size(), statuses.size() - 1);
            requests.add(request);
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statuses[index]);
            response.setBody(bodies[index]);
            return response;
        }
    }

    private static String reply(String text) {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => text } }
            }
        );
    }

    private static String failureOf(AntsuranceAiClient.Question question) {
        try {
            AntsuranceAiClient.ask(question);
            Assert.fail('Expected an AiException');
        } catch (AntsuranceAiClient.AiException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void theModelAndFastModeComeFromTheSetting() {
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Model__c = 'claude-sonnet-5-5', Fast_Mode__c = false);
        ClaudeMock mock = new ClaudeMock(429, '{"type":"error","error":{"type":"rate_limit_error","message":"Slow down."}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Be brief.', 'Is it covered?'));
            Assert.fail('A rate limit is reported');
        } catch (AntsuranceAiClient.AiException problem) {
            Assert.areEqual('rate_limited', problem.kind, 'As a rate limit');
        }
        Test.stopTest();

        Assert.areEqual(1, mock.requests.size(), 'With fast mode off there is no second, slower attempt to fall back to');
        HttpRequest request = mock.requests[0];
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
        Assert.areEqual('claude-sonnet-5-5', body.get('model'), 'The configured model is sent');
        Assert.isFalse(body.containsKey('speed'), 'Fast output is not asked for');
        Assert.isFalse(request.getHeader('anthropic-beta').contains('fast-mode'), 'And its beta header is left off');
    }

    @IsTest
    static void aPlainQuestionGetsTextBackAndIsSentInFastMode() {
        ClaudeMock mock = new ClaudeMock(200, reply('  The claim is covered.  '));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAiClient.Answer answer = AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Be brief.', 'Is it covered?'));
        Test.stopTest();

        Assert.areEqual('The claim is covered.', answer.text, 'The text comes back trimmed');
        Assert.isNull(answer.data, 'There is no parsed data without a schema');
        Assert.areEqual('claude-opus-5-5', answer.model, 'The model that answered is reported');

        HttpRequest request = mock.requests[0];
        Assert.areEqual('callout:Anthropic_API/v1/messages', request.getEndpoint(), 'The call goes through the named credential');
        Assert.isTrue(request.getHeader('anthropic-beta').contains('fast-mode-2026-02-01'), 'Fast mode is switched on');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
        Assert.areEqual(AntsuranceAiSettings.BUILT_IN_MODEL, body.get('model'), 'The default model is used');
        Assert.areEqual('fast', body.get('speed'), 'The request asks for fast output');
        Assert.areEqual('default', body.get('fallbacks'), 'A refusal can be retried on another model');
        String instructions = (String) body.get('system');
        Assert.isTrue(instructions.startsWith('Be brief.'), 'The instructions are the system prompt');
        Assert.isTrue(instructions.endsWith('Write in American English.'), 'Every caller\'s instructions end with the house style: ' + instructions);
        Assert.areEqual('Write in American English.', AntsuranceAiClient.HOUSE_STYLE, 'The house style asks for American spelling');
        Map<String, Object> message = (Map<String, Object>) ((List<Object>) body.get('messages'))[0];
        Assert.areEqual('Is it covered?', message.get('content'), 'Without a file the prompt is sent as plain text');
        Assert.isFalse(((Map<String, Object>) body.get('output_config')).containsKey('format'), 'No answer format is set without a schema');
    }

    @IsTest
    static void aSchemaQuestionGetsParsedJsonAndKeepsItsFieldOrder() {
        ClaudeMock mock = new ClaudeMock(200, reply('{"reason":"Water damage","amount":4200.5,"tags":["a","b"]}'));
        Test.setMock(HttpCalloutMock.class, mock);
        AntsuranceAiClient.Shape shape = new AntsuranceAiClient.Shape()
            .field('reason', AntsuranceAiClient.text('Why'))
            .field('kind', AntsuranceAiClient.choice(new List<String>{ 'Fire', 'Theft' }, 'Which'))
            .field('amount', AntsuranceAiClient.optionalNumber('How much'))
            .field('urgent', AntsuranceAiClient.flag('Whether urgent'))
            .field('tags', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A tag'), 'Tags'));

        Test.startTest();
        AntsuranceAiClient.Answer answer = AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Extract.', 'Message').returning(shape));
        Test.stopTest();

        Assert.areEqual('Water damage', answer.data.get('reason'), 'The answer is parsed');
        Assert.areEqual(4200.5, AntsuranceAiClient.toDecimal(answer.data.get('amount')), 'Numbers are read as decimals');
        Assert.areEqual(new List<String>{ 'a', 'b' }, AntsuranceAiClient.toStrings(answer.data.get('tags')), 'Lists are read as strings');

        String sent = mock.requests[0].getBody();
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(sent);
        Map<String, Object> format = (Map<String, Object>) ((Map<String, Object>) body.get('output_config')).get('format');
        Assert.areEqual('json_schema', format.get('type'), 'The answer is constrained to the schema');
        Map<String, Object> schema = (Map<String, Object>) format.get('schema');
        Assert.areEqual(false, schema.get('additionalProperties'), 'No extra keys are allowed');
        Assert.areEqual(5, ((List<Object>) schema.get('required')).size(), 'Every field is required');
        Map<String, Object> kind = (Map<String, Object>) ((Map<String, Object>) schema.get('properties')).get('kind');
        Assert.areEqual(new List<Object>{ 'Fire', 'Theft' }, (List<Object>) kind.get('enum'), 'Choices are limited to the values given');
        // Claude fills fields in the order they are written, so the order has to survive serialization.
        Assert.isTrue(
            sent.indexOf('"reason":{') < sent.indexOf('"kind":{') && sent.indexOf('"kind":{') < sent.indexOf('"tags":{'),
            'Fields are sent in the order they were added'
        );
    }

    @IsTest
    static void anAttachedFileIsSentBeforeThePrompt() {
        ClaudeMock mock = new ClaudeMock(200, reply('Read it.'));
        Test.setMock(HttpCalloutMock.class, mock);
        Blob pdf = Blob.valueOf('%PDF-1.7 pretend');

        Test.startTest();
        AntsuranceAiClient.ask(
            new AntsuranceAiClient.Question('Read.', 'What is this?').attach('application/pdf', pdf).attach('IMAGE/PNG', Blob.valueOf('png'))
        );
        Test.stopTest();

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.requests[0].getBody());
        List<Object> content = (List<Object>) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        Assert.areEqual(3, content.size(), 'Two files and the prompt are sent');
        Map<String, Object> document = (Map<String, Object>) content[0];
        Assert.areEqual('document', document.get('type'), 'A PDF goes as a document block');
        Map<String, Object> source = (Map<String, Object>) document.get('source');
        Assert.areEqual(EncodingUtil.base64Encode(pdf), source.get('data'), 'The file is sent as base64');
        Assert.areEqual('image', ((Map<String, Object>) content[1]).get('type'), 'An image goes as an image block');
        Assert.areEqual('What is this?', ((Map<String, Object>) content[2]).get('text'), 'The prompt comes after the files');
    }

    @IsTest
    static void filesClaudeCannotReadAreTurnedAway() {
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question('Read.', 'What is this?');
        try {
            question.attach('application/zip', Blob.valueOf('zip'));
            Assert.fail('Expected an AiException');
        } catch (AntsuranceAiClient.AiException e) {
            Assert.areEqual(AntsuranceAiClient.WRONG_FILE_TYPE, e.getMessage(), 'Other file types are refused');
        }
        try {
            question.attach('application/pdf', Blob.valueOf('x'.repeat(AntsuranceAiClient.MAX_ATTACHMENT_BYTES + 1)));
            Assert.fail('Expected an AiException');
        } catch (AntsuranceAiClient.AiException e) {
            Assert.areEqual(AntsuranceAiClient.FILE_TOO_LARGE, e.getMessage(), 'Large files are refused');
        }
    }

    @IsTest
    static void aFastModeRateLimitIsRetriedAtStandardSpeed() {
        ClaudeMock mock = new ClaudeMock(429, '{"error":{"message":"fast mode rate limit"}}').add(200, reply('Done.'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAiClient.Answer answer = AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Be brief.', 'Hello'));
        Test.stopTest();

        Assert.areEqual('Done.', answer.text, 'The second attempt answers');
        Assert.areEqual(2, mock.requests.size(), 'The request was sent twice');
        Assert.isFalse(mock.requests[1].getBody().contains('"speed"'), 'The retry drops fast mode');
        Assert.isFalse(mock.requests[1].getHeader('anthropic-beta').contains('fast-mode'), 'And its beta header');
    }

    @IsTest
    static void failuresAreExplainedInPlainWords() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(529, '{"error":{"message":"Overloaded"}}'));
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question('Be brief.', 'Hello');
        Assert.isTrue(failureOf(question).startsWith('Claude is temporarily unavailable.'), 'A server error says to try again');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(401, 'nope'));
        Assert.isTrue(failureOf(question).contains('API key'), 'A rejected key is named');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(400, '{"error":{"message":"bad schema"}}'));
        Assert.areEqual('Claude could not process the request (HTTP 400). bad schema', failureOf(question), 'The API\'s own message is passed on');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(429, '{}'));
        Assert.isTrue(failureOf(question).contains('rate limiting'), 'A rate limit on both attempts is reported');

        ClaudeMock unreachable = new ClaudeMock(200, '');
        unreachable.failToConnect = true;
        Test.setMock(HttpCalloutMock.class, unreachable);
        Assert.areEqual(AntsuranceAiClient.UNREACHABLE, failureOf(question), 'A failed connection is reported');
    }

    @IsTest
    static void aCalloutThatRunsOutOfTimeSaysSoAndCanBeRetried() {
        ClaudeMock mock = new ClaudeMock(200, reply('unused'));
        mock.failToConnect = true;
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Be brief.', 'Summarize this very long file.'));
            Assert.fail('Expected an AiException');
        } catch (AntsuranceAiClient.AiException e) {
            Assert.areEqual(AntsuranceAiClient.TOO_SLOW, e.getMessage(), 'A timeout is named as one, in plain words');
            Assert.areEqual('timeout', e.kind, 'Code can tell a timeout from other failures');
            Assert.isTrue(e.retryable, 'And knows asking again may work');
        }
        Test.stopTest();
    }

    @IsTest
    static void aSecondCallIsNotStartedWhenTheTransactionHasNoTimeLeft() {
        ClaudeMock mock = new ClaudeMock(200, reply('unused'));
        Test.setMock(HttpCalloutMock.class, mock);
        // As if an earlier callout in this transaction had used nearly all of Salesforce's 120 seconds.
        AntsuranceAiClient.spentMs = AntsuranceAiClient.TRANSACTION_BUDGET_MS - AntsuranceAiClient.SHORTEST_USEFUL_MS + 1;

        Test.startTest();
        try {
            AntsuranceAiClient.ask(new AntsuranceAiClient.Question('Be brief.', 'One more thing.'));
            Assert.fail('Expected an AiException');
        } catch (AntsuranceAiClient.AiException e) {
            Assert.areEqual('timeout', e.kind, 'Running out of transaction time is reported as a timeout');
        }
        Test.stopTest();

        Assert.areEqual(0, mock.requests.size(), 'No callout is attempted, so the platform limit is never hit');
    }

    @IsTest
    static void answersThatCannotBeUsedAreReported() {
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question('Extract.', 'Message')
            .returning(new AntsuranceAiClient.Shape().field('reason', AntsuranceAiClient.text('Why')));

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, '{"stop_reason":"refusal","content":[]}'));
        Assert.areEqual(AntsuranceAiClient.REFUSED, failureOf(question), 'A refusal is reported');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, '{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\\"reason\\":"}]}'));
        Assert.areEqual(AntsuranceAiClient.CUT_SHORT, failureOf(question), 'A truncated answer is reported');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, '{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""}]}'));
        Assert.areEqual(AntsuranceAiClient.NO_ANSWER, failureOf(question), 'An empty answer is reported');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply('not json')));
        Assert.areEqual(AntsuranceAiClient.UNREADABLE, failureOf(question), 'Text that is not JSON is reported');

        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, '<html>gateway</html>'));
        Assert.areEqual(AntsuranceAiClient.UNREADABLE, failureOf(question), 'A response that is not JSON is reported');
    }

    @IsTest
    static void parsedValuesAreReadSafely() {
        Assert.areEqual(12, AntsuranceAiClient.toDecimal(12), 'An integer becomes a decimal');
        Assert.areEqual(12.5, AntsuranceAiClient.toDecimal('12.5'), 'A numeric string becomes a decimal');
        Assert.isNull(AntsuranceAiClient.toDecimal(null), 'Null stays null');
        Assert.isNull(AntsuranceAiClient.toDecimal('about ten'), 'Words are not a number');
        Assert.areEqual(
            new List<String>{ 'one', 'two' },
            AntsuranceAiClient.toStrings(new List<Object>{ ' one ', '', null, 'two' }),
            'Blank entries are dropped and the rest trimmed'
        );
        Assert.isTrue(AntsuranceAiClient.toStrings('not a list').isEmpty(), 'Anything but a list reads as empty');
    }
}
