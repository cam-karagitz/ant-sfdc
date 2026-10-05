@IsTest
private class AntsuranceAiTrialTest {
    private class ClaudeMock implements HttpCalloutMock {
        HttpRequest request;
        Integer calls = 0;

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            calls++;
            if (calls == 2) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => 'A dented door.' } }
                    }
                )
            );
            return response;
        }
    }

    private static void send(Object body) {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(body instanceof String ? (String) body : JSON.serialize(body));
        RestContext.response = new RestResponse();
        AntsuranceAiTrial.ask();
    }

    private static Map<String, Object> ask(String name) {
        return new Map<String, Object>{ 'name' => name, 'instructions' => 'You are an appraiser.', 'prompt' => 'What is damaged?', 'maxTokens' => 300, 'images' => new List<Object>{ 'plain' } };
    }

    @IsTest
    static void eachAskIsPutToClaudeAndAFailureIsReportedInPlace() {
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);
        AntsuranceAiTrial.mayAuthorForTest = true;

        Test.startTest();
        send(
            new Map<String, Object>{
                'images' => new Map<String, Object>{ 'plain' => EncodingUtil.base64Encode(Blob.valueOf('jpeg')) },
                'asks' => new List<Object>{ ask('first'), ask('second') }
            }
        );
        Test.stopTest();

        List<Object> answers = (List<Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        Assert.areEqual(2, answers.size());
        Map<String, Object> first = (Map<String, Object>) answers[0];
        Assert.areEqual('first', first.get('name'));
        Assert.areEqual('A dented door.', first.get('text'));
        Map<String, Object> second = (Map<String, Object>) answers[1];
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, second.get('error'), 'A call that runs out of time is reported for its ask, and the others stand');
        Assert.isTrue(mock.request.getBody().contains('"type":"image"'), 'The named image goes with the ask');
    }

    @IsTest
    static void someoneWhoMayNotAuthorApexIsRefused() {
        AntsuranceAiTrial.mayAuthorForTest = false;
        send(new Map<String, Object>{ 'asks' => new List<Object>{ ask('first') } });
        Assert.areEqual(403, RestContext.response.statusCode);
        Assert.isTrue(RestContext.response.responseBody.toString().contains(AntsuranceAiTrial.NOT_ALLOWED));
    }

    @IsTest
    static void aRequestWithNoAsksIsRefused() {
        AntsuranceAiTrial.mayAuthorForTest = true;
        send('not json');
        Assert.areEqual(400, RestContext.response.statusCode);
        send(new Map<String, Object>{ 'asks' => new List<Object>() });
        Assert.areEqual(400, RestContext.response.statusCode);
        // The real check reads the running user's profile.
        AntsuranceAiTrial.mayAuthorForTest = null;
        send(new Map<String, Object>{ 'asks' => new List<Object>() });
        Assert.isNotNull(RestContext.response.statusCode);
    }
}
