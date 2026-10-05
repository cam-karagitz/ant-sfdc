/**
 * @description A way to put trial questions to Claude from a script, for measuring a prompt before it
 * is built into a feature: scripts/eval/boxes uses it to compare ways of asking for damage boxes on
 * photographs that are not stored in the org. No page calls it and it saves nothing.
 *
 * POST /services/apexrest/antsurance/ai-trial with
 * { "images": { "name": "<base64 JPEG>" }, "asks": [ { "name", "instructions", "prompt", "schema", "maxTokens", "images": ["name"] } ] }
 * and it answers [ { "name", "ms", "text" } or { "name", "error" } ], one for each ask, in order.
 * Each ask is one call to Claude, and all of them share the request's 120 seconds of callout time,
 * so keep a request to a few short asks.
 *
 * Only someone who may already run Apex of their own in the org (the Author Apex permission) can use
 * it: it reaches nothing they could not reach with anonymous Apex.
 */
@RestResource(urlMapping='/antsurance/ai-trial')
global with sharing class AntsuranceAiTrial {
    @TestVisible
    private static final String NOT_ALLOWED = 'Trial questions are for people who may author Apex in this org.';
    private static final Integer MAX_ASKS = 6;
    private static final Integer FORBIDDEN = 403;
    private static final Integer BAD_REQUEST = 400;
    @TestVisible
    private static Boolean mayAuthorForTest;

    /**
     * @description Puts each ask to Claude in turn and answers with what came back.
     */
    @HttpPost
    global static void ask() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        if (!mayAuthor()) {
            response.statusCode = FORBIDDEN;
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => NOT_ALLOWED }));
            return;
        }
        Map<String, Object> body;
        List<Object> asks;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            asks = (List<Object>) body.get('asks');
        } catch (Exception e) {
            asks = null;
        }
        if (asks == null || asks.isEmpty() || asks.size() > MAX_ASKS) {
            response.statusCode = BAD_REQUEST;
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => 'Send one to six asks.' }));
            return;
        }
        Map<String, Object> images = body.get('images') instanceof Map<String, Object> ? (Map<String, Object>) body.get('images') : new Map<String, Object>();
        List<Object> answers = new List<Object>();
        for (Object entry : asks) {
            Map<String, Object> wanted = (Map<String, Object>) entry;
            Map<String, Object> answer = new Map<String, Object>{ 'name' => wanted.get('name') };
            try {
                AntsuranceAiClient.Question question = new AntsuranceAiClient.Question((String) wanted.get('instructions'), (String) wanted.get('prompt'));
                question.schema = (String) wanted.get('schema');
                if (wanted.get('maxTokens') != null) {
                    question.maxTokens = Integer.valueOf(wanted.get('maxTokens'));
                }
                if (wanted.get('images') instanceof List<Object>) {
                    for (Object name : (List<Object>) wanted.get('images')) {
                        question.attach('image/jpeg', EncodingUtil.base64Decode((String) images.get((String) name)));
                    }
                }
                Long started = System.currentTimeMillis();
                answer.put('text', AntsuranceAiClient.ask(question).text);
                answer.put('ms', System.currentTimeMillis() - started);
            } catch (Exception e) {
                answer.put('error', e.getMessage());
            }
            answers.add(answer);
        }
        response.responseBody = Blob.valueOf(JSON.serialize(answers));
    }

    private static Boolean mayAuthor() {
        if (mayAuthorForTest != null) {
            return mayAuthorForTest;
        }
        return [SELECT PermissionsAuthorApex FROM Profile WHERE Id = :UserInfo.getProfileId()].PermissionsAuthorApex;
    }
}
