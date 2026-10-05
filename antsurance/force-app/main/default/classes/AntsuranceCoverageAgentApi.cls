/**
 * @description Talks to Claude Managed Agents over plain HTTPS, through the same Named Credential
 * the rest of the org uses for Claude (callout:Anthropic_API), so the API key never leaves the
 * External Credential and is never read here.
 *
 * Managed Agents is where the claims coverage agent's loop runs: Anthropic keeps the conversation,
 * manages its context and decides which tool to call next. This class only sends and fetches. A
 * request is short: the list of a session's events returns at once and is not a long poll, so every
 * call fits well inside the callout time one Salesforce transaction allows.
 */
public inherited sharing class AntsuranceCoverageAgentApi {
    private static final String BASE = 'callout:Anthropic_API';
    private static final String API_VERSION = '2023-06-01';
    @TestVisible
    private static final String MANAGED_AGENTS_BETA = 'managed-agents-2026-04-01';
    private static final Integer TIMEOUT_MS = 30000;
    private static final Integer MAX_ERROR_DETAIL = 300;
    private static final String BOUNDARY = '----AntsuranceCoverageSkill7f3a91';

    @TestVisible
    private static final String UNREACHABLE = 'The coverage agent could not be reached. Try again in a moment.';
    @TestVisible
    private static final String TOO_SLOW = 'The coverage agent took too long to answer. Try again.';
    @TestVisible
    private static final String NOT_ALLOWED = 'This Claude API key cannot use Managed Agents, so the coverage agent is not available. Check coverage with "Check coverage" instead.';
    @TestVisible
    private static final String BUSY = 'Claude is busy right now. Try again in a moment.';
    @TestVisible
    private static final String NOT_A_SESSION = 'That is not an investigation the coverage agent started. Run the coverage agent again.';
    // A session id as Managed Agents issues it: the prefix, then letters and digits and nothing else.
    // Anything with a slash, a dot or a question mark in it would change which endpoint the request reaches.
    private static final Pattern SESSION_ID = Pattern.compile('^sesn_[A-Za-z0-9]{8,64}$');

    /**
     * @description Thrown when a request cannot be sent or is refused. The message is written for
     * the person on screen; status and detail are for the record.
     */
    public class ApiException extends Exception {
        /** The HTTP status, or 0 when no answer came back. */
        public Integer status = 0;
        /** timeout, unreachable, not_allowed, not_found, not_a_session, busy or other. */
        public String kind = 'other';
        public Boolean retryable = false;
        /** What the API said, trimmed. Never shown to the person as is. */
        public String detail;
    }

    /**
     * @description Reads from a Managed Agents endpoint.
     * @param path The path and query, starting with /v1/
     * @return The JSON answer
     * @throws ApiException when the request fails or is refused
     */
    public static Map<String, Object> get(String path) {
        return send('GET', path, null, true);
    }

    /**
     * @description Reads from a Managed Agents endpoint, giving up sooner than usual. For a request
     * that has slower work to do afterwards and must leave it the time.
     * @param path The path and query, starting with /v1/
     * @param timeoutMs How long to wait for the answer, in milliseconds
     * @return The JSON answer
     * @throws ApiException when the request fails, is refused or takes longer than that
     */
    public static Map<String, Object> get(String path, Integer timeoutMs) {
        HttpRequest request = build('GET', path, null, true);
        request.setTimeout(timeoutMs);
        return parsed(fetch(request));
    }

    /**
     * @description The path of one session's events. Every request about a session is built from
     * this, so an id that is not shaped like a session id never reaches the API: the id comes from
     * the page, and anything else in its place could send the org's API key to another endpoint.
     * @param sessionId The session id, as start returned it
     * @return /v1/sessions/{id}/events
     * @throws ApiException when the id is not a session id
     */
    public static String eventsPath(String sessionId) {
        if (sessionId == null || !SESSION_ID.matcher(sessionId).matches()) {
            throw failure(0, 'not_a_session', NOT_A_SESSION, false, 'The session id was not one.');
        }
        return '/v1/sessions/' + sessionId + '/events';
    }

    /**
     * @description Reads a list page as text, without parsing it. A page of agents carries every
     * agent's whole instructions, so a busy workspace is searched as text and only the page that
     * holds the match is parsed.
     * @param path The path and query, starting with /v1/
     * @param isManagedAgents False for the Skills API, which takes no beta header
     * @return The body as it came
     * @throws ApiException when the request fails or is refused
     */
    public static String getText(String path, Boolean isManagedAgents) {
        return fetch(build('GET', path, null, isManagedAgents));
    }

    /**
     * @description Sends JSON to a Managed Agents endpoint.
     * @param path The path, starting with /v1/
     * @param body The body, already serialized, so the order of a tool's fields is kept as written
     * @return The JSON answer
     * @throws ApiException when the request fails or is refused
     */
    public static Map<String, Object> post(String path, String body) {
        return send('POST', path, body, true);
    }

    /**
     * @description Reads from the Skills API, which is out of beta and takes no beta header.
     * @param path The path and query, starting with /v1/skills
     * @return The JSON answer
     * @throws ApiException when the request fails or is refused
     */
    public static Map<String, Object> getSkills(String path) {
        return send('GET', path, null, false);
    }

    /**
     * @description Uploads a skill made of one SKILL.md, as a new skill or as a new version of one.
     * @param path /v1/skills for a new skill, /v1/skills/{id}/versions for a new version
     * @param folder The skill's folder name, which the upload needs in front of the file name
     * @param skillFile The text of SKILL.md
     * @return The JSON answer, with the skill's id
     * @throws ApiException when the upload fails or is refused
     */
    public static Map<String, Object> uploadSkill(String path, String folder, String skillFile) {
        String form =
            '--' + BOUNDARY + '\r\n' +
            'Content-Disposition: form-data; name="files[]"; filename="' + folder + '/SKILL.md"\r\n' +
            'Content-Type: text/markdown\r\n\r\n' +
            skillFile + '\r\n' +
            '--' + BOUNDARY + '--\r\n';
        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE + path);
        request.setMethod('POST');
        request.setHeader('anthropic-version', API_VERSION);
        request.setHeader('content-type', 'multipart/form-data; boundary=' + BOUNDARY);
        request.setTimeout(TIMEOUT_MS);
        request.setBody(form);
        return parsed(fetch(request));
    }

    private static Map<String, Object> send(String method, String path, String body, Boolean isManagedAgents) {
        return parsed(fetch(build(method, path, body, isManagedAgents)));
    }

    private static HttpRequest build(String method, String path, String body, Boolean isManagedAgents) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE + path);
        request.setMethod(method);
        request.setHeader('anthropic-version', API_VERSION);
        if (isManagedAgents) {
            request.setHeader('anthropic-beta', MANAGED_AGENTS_BETA);
        }
        request.setTimeout(TIMEOUT_MS);
        if (body != null) {
            request.setHeader('content-type', 'application/json');
            request.setBody(body);
        }
        return request;
    }

    private static Map<String, Object> parsed(String text) {
        if (String.isBlank(text)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(text);
        } catch (Exception e) {
            throw failure(200, 'other', UNREACHABLE, true, 'The answer was not JSON.');
        }
    }

    /** Sends the request and returns the body of a successful answer; anything else is thrown in plain words. */
    private static String fetch(HttpRequest request) {
        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            Boolean timedOut = e.getMessage() != null && e.getMessage().containsIgnoreCase('timed out');
            throw failure(0, timedOut ? 'timeout' : 'unreachable', timedOut ? TOO_SLOW : UNREACHABLE, true, e.getMessage());
        }
        Integer status = response.getStatusCode();
        String text = response.getBody();
        if (status >= 200 && status < 300) {
            return text;
        }
        String detail = text?.left(MAX_ERROR_DETAIL);
        if (status == 401 || status == 403) {
            throw failure(status, 'not_allowed', NOT_ALLOWED, false, detail);
        }
        if (status == 404) {
            throw failure(status, 'not_found', UNREACHABLE, false, detail);
        }
        if (status == 429 || status == 529 || status >= 500) {
            throw failure(status, 'busy', BUSY, true, detail);
        }
        throw failure(status, 'other', UNREACHABLE, false, detail);
    }

    private static ApiException failure(Integer status, String kind, String message, Boolean retryable, String detail) {
        ApiException error = new ApiException(message);
        error.status = status;
        error.kind = kind;
        error.retryable = retryable;
        error.detail = detail;
        return error;
    }
}
