/**
 * @description One-shot calls to the Claude Messages API, for features that need a single answer
 * rather than a conversation: plain text, or JSON that is guaranteed to match a schema, optionally
 * about an attached PDF or image. Authentication comes from the Anthropic_API named credential,
 * so no key is held in code.
 *
 * Callers build a Question, call ask, and read the Answer. Failures surface as AiException with a
 * message that is safe to show to the person who clicked.
 */
public inherited sharing class AntsuranceAiClient {
    // The model and fast mode are settings, not code: AntsuranceAiSettings reads them from Antsurance_AI_Setting__mdt.
    private static final String ENDPOINT = 'callout:Anthropic_API/v1/messages';
    private static final String API_VERSION = '2023-06-01';
    // Lets the API re-run a request on another model when a safety classifier declines it.
    private static final String FALLBACK_BETA = 'server-side-fallback-2026-07-01';
    private static final Integer DEFAULT_MAX_TOKENS = 4096;
    private static final Integer TIMEOUT_MS = 110000;
    // Salesforce allows 120 seconds of callout time in one transaction, across every callout in it, and enforces it
    // with a limit error no code can catch. Stop short of that, so running out of time is a failure this class reports
    // in plain words. A second attempt in the same transaction (the rate-limit retry) gets only what the first left.
    @TestVisible
    private static final Integer TRANSACTION_BUDGET_MS = 115000;
    @TestVisible
    private static final Integer SHORTEST_USEFUL_MS = 15000;
    /** Callout time already used in this transaction, in milliseconds. */
    @TestVisible
    private static Integer spentMs = 0;
    private static final Integer RATE_LIMITED = 429;
    private static final Integer MAX_ERROR_DETAIL = 200;
    // Stands in for the answer schema while the rest of the request is serialized.
    private static final String SCHEMA_SLOT = '__ANSWER_SCHEMA__';
    // The request is held in memory three times over (file, base64, JSON body), so keep files small.
    @TestVisible
    private static final Integer MAX_ATTACHMENT_BYTES = 1500000;

    // Added to every caller's instructions, here and nowhere else, so everything Claude writes for the org reads alike.
    @TestVisible
    private static final String HOUSE_STYLE = 'Write in American English.';

    private static final String PDF = 'application/pdf';
    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'image/png', 'image/jpeg', 'image/gif', 'image/webp' };

    @TestVisible
    private static final String UNREACHABLE = 'Claude could not be reached. Try again in a moment.';
    @TestVisible
    private static final String TOO_SLOW = 'Claude was still working when Salesforce\'s two-minute limit for one request ran out. Try again. If it happens again, ask for less at once: fewer files or a shorter answer.';
    @TestVisible
    private static final String REFUSED = 'Claude declined to answer that request.';
    @TestVisible
    private static final String NO_ANSWER = 'Claude did not return an answer. Try again.';
    @TestVisible
    private static final String CUT_SHORT = 'Claude\'s answer was cut short. Try again.';
    @TestVisible
    private static final String UNREADABLE = 'Claude\'s answer could not be read. Try again.';
    @TestVisible
    private static final String WRONG_FILE_TYPE = 'Claude can read PDF, PNG, JPEG, GIF and WebP files.';
    @TestVisible
    private static final String FILE_TOO_LARGE = 'That file is too large for Claude to read here. The limit is 1.5 MB.';

    /**
     * @description Thrown when a question cannot be sent or Claude's answer cannot be used.
     * The message is written for the person on screen.
     */
    public class AiException extends Exception {
        /** What went wrong, for code that wants to react: timeout, unreachable, rate_limited, unavailable, auth or other. */
        public String kind = 'other';
        /** Whether asking again, unchanged, has a fair chance of working. */
        public Boolean retryable = false;
    }

    private static AiException failure(String kind, String message, Boolean retryable) {
        AiException e = new AiException(message);
        e.kind = kind;
        e.retryable = retryable;
        return e;
    }

    /**
     * @description What to ask Claude. Set a schema to get JSON back instead of prose.
     */
    public class Question {
        /** The standing instructions: who Claude is here and how to answer. */
        public String instructions;
        /** The request itself, including any record data Claude needs. */
        public String prompt;
        /** A JSON schema for the answer, as text. Build it with Shape so the fields keep their order. */
        public String schema;
        /** How hard Claude should think: low, medium or high. */
        public String effort = 'low';
        public Integer maxTokens = DEFAULT_MAX_TOKENS;
        private List<Object> attachments = new List<Object>();

        /**
         * @description Starts a question.
         * @param instructions The standing instructions (system prompt)
         * @param prompt The request, with any data Claude needs
         */
        public Question(String instructions, String prompt) {
            this.instructions = instructions;
            this.prompt = prompt;
        }

        /**
         * @description Asks for JSON matching a schema instead of prose.
         * @param shape The shape of the answer
         * @return This question, for chaining
         */
        public Question returning(Shape shape) {
            this.schema = shape.toJson();
            return this;
        }

        /**
         * @description Attaches a PDF or image for Claude to read alongside the prompt.
         * @param mediaType The file's MIME type, such as application/pdf or image/png
         * @param data The file contents
         * @return This question, for chaining
         * @throws AiException when the type is not one Claude can read or the file is too large
         */
        public Question attach(String mediaType, Blob data) {
            String type = mediaType == null ? '' : mediaType.toLowerCase();
            Boolean isPdf = type == PDF;
            if (!isPdf && !IMAGE_TYPES.contains(type)) {
                throw new AiException(WRONG_FILE_TYPE);
            }
            if (data == null || data.size() > MAX_ATTACHMENT_BYTES) {
                throw new AiException(FILE_TOO_LARGE);
            }
            attachments.add(
                new Map<String, Object>{
                    'type' => isPdf ? 'document' : 'image',
                    'source' => new Map<String, Object>{ 'type' => 'base64', 'media_type' => type, 'data' => EncodingUtil.base64Encode(data) }
                }
            );
            return this;
        }
    }

    /**
     * @description Claude's reply to a Question.
     */
    public class Answer {
        /** The reply as written. For a schema question this is the JSON text. */
        public String text;
        /** The parsed reply, when the question had a schema. */
        public Map<String, Object> data;
        /** The model that wrote the reply. */
        public String model;
    }

    /**
     * @description Sends one question and waits for the answer.
     * @param question What to ask
     * @return Claude's answer: text, plus parsed data when a schema was set
     * @throws AiException when the call fails, Claude declines, or the answer is empty or cut short
     */
    public static Answer ask(Question question) {
        Map<String, Object> body = new Map<String, Object>{
            'model' => AntsuranceAiSettings.model(),
            'max_tokens' => question.maxTokens,
            'system' => String.isBlank(question.instructions) ? HOUSE_STYLE : question.instructions + '\n\n' + HOUSE_STYLE,
            'messages' => new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => userContent(question) } },
            'fallbacks' => 'default'
        };
        // Fast mode: the same model with quicker output, at a higher price. Not every model or account has it.
        Boolean fast = AntsuranceAiSettings.useFastMode();
        if (fast) {
            body.put('speed', 'fast');
        }
        Map<String, Object> outputConfig = new Map<String, Object>{ 'effort' => question.effort };
        if (question.schema != null) {
            outputConfig.put('format', new Map<String, Object>{ 'type' => 'json_schema', 'schema' => SCHEMA_SLOT });
        }
        body.put('output_config', outputConfig);

        HttpResponse response = post(body, question.schema, fast ? new List<String>{ FALLBACK_BETA, AntsuranceAiSettings.fastModeBeta() } : new List<String>{ FALLBACK_BETA });
        if (fast && response.getStatusCode() == RATE_LIMITED) {
            // Fast mode has its own rate limit, so fall back to standard speed once.
            body.remove('speed');
            response = post(body, question.schema, new List<String>{ FALLBACK_BETA });
        }
        if (response.getStatusCode() != 200) {
            Integer status = response.getStatusCode();
            throw failure(status == RATE_LIMITED ? 'rate_limited' : status >= 500 ? 'unavailable' : status == 401 ? 'auth' : 'other', describeFailure(response), status == RATE_LIMITED || status >= 500);
        }
        return readAnswer(response.getBody(), question.schema != null);
    }

    /**
     * @description An object in an answer schema, in the form structured outputs need: every field
     * required and no others allowed. Fields are written in the order they are added, and Claude
     * fills them in that order, so put the fields it should reason about first at the top.
     * (A Map cannot be used for this: Apex does not serialize map keys in the order they were put.)
     */
    public class Shape {
        private List<String> names = new List<String>();
        private List<String> definitions = new List<String>();

        /**
         * @description Adds a field.
         * @param name The field's key in the answer
         * @param definition The field's definition, from text, choice, flag, optionalNumber, listOf or another Shape's toJson
         * @return This shape, for chaining
         */
        public Shape field(String name, String definition) {
            names.add(name);
            definitions.add(definition);
            return this;
        }

        /**
         * @description The object definition as JSON schema text.
         * @return The schema
         */
        public String toJson() {
            List<String> properties = new List<String>();
            for (Integer index = 0; index < names.size(); index++) {
                properties.add(JSON.serialize(names[index]) + ':' + definitions[index]);
            }
            return '{"type":"object","properties":{' +
                String.join(properties, ',') +
                '},"required":' +
                JSON.serialize(names) +
                ',"additionalProperties":false}';
        }
    }

    /**
     * @description A string field, with a note telling Claude what belongs in it.
     * @param description What the value should hold
     * @return The field definition
     */
    public static String text(String description) {
        return '{"type":"string","description":' + JSON.serialize(description) + '}';
    }

    /**
     * @description A string field limited to a fixed set of values.
     * @param options The allowed values
     * @param description What the value means and how to choose
     * @return The field definition
     */
    public static String choice(List<String> options, String description) {
        return '{"type":"string","enum":' + JSON.serialize(options) + ',"description":' + JSON.serialize(description) + '}';
    }

    /**
     * @description A number field that may be null when the source gives no figure.
     * @param description What the number measures
     * @return The field definition
     */
    public static String optionalNumber(String description) {
        return '{"anyOf":[{"type":"number"},{"type":"null"}],"description":' + JSON.serialize(description) + '}';
    }

    /**
     * @description A true or false field.
     * @param description What true means
     * @return The field definition
     */
    public static String flag(String description) {
        return '{"type":"boolean","description":' + JSON.serialize(description) + '}';
    }

    /**
     * @description A list field.
     * @param items The definition of each entry
     * @param description What the list holds
     * @return The field definition
     */
    public static String listOf(String items, String description) {
        return '{"type":"array","items":' + items + ',"description":' + JSON.serialize(description) + '}';
    }

    /**
     * @description Reads a number out of parsed JSON, where it may arrive as an Integer, Long or Decimal.
     * @param value The parsed value
     * @return The number, or null when there is none
     */
    public static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (TypeException e) {
            return null;
        }
    }

    /**
     * @description Reads a list of strings out of parsed JSON, skipping blanks.
     * @param value The parsed value
     * @return The strings, empty when there are none
     */
    public static List<String> toStrings(Object value) {
        List<String> strings = new List<String>();
        if (value instanceof List<Object>) {
            for (Object item : (List<Object>) value) {
                String text = item == null ? null : String.valueOf(item).trim();
                if (String.isNotBlank(text)) {
                    strings.add(text);
                }
            }
        }
        return strings;
    }

    /** Files go before the text, which is where Claude reads them best. */
    private static Object userContent(Question question) {
        if (question.attachments.isEmpty()) {
            return question.prompt;
        }
        List<Object> content = new List<Object>(question.attachments);
        content.add(new Map<String, Object>{ 'type' => 'text', 'text' => question.prompt });
        return content;
    }

    /** The schema is dropped into the serialized body as text, which keeps its fields in order. */
    private static HttpResponse post(Map<String, Object> body, String schema, List<String> betas) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('content-type', 'application/json');
        request.setHeader('anthropic-version', API_VERSION);
        request.setHeader('anthropic-beta', String.join(betas, ','));
        Integer remainingMs = TRANSACTION_BUDGET_MS - spentMs;
        if (remainingMs < SHORTEST_USEFUL_MS) {
            // Not enough of the transaction's callout time is left for an answer; say so rather than hit the platform limit.
            throw failure('timeout', TOO_SLOW, true);
        }
        request.setTimeout(Math.min(TIMEOUT_MS, remainingMs));
        String payload = JSON.serialize(body);
        request.setBody(schema == null ? payload : payload.replace(JSON.serialize(SCHEMA_SLOT), schema));
        Long startedAt = System.currentTimeMillis();
        try {
            return new Http().send(request);
        } catch (CalloutException e) {
            Boolean timedOut = e.getMessage() != null && e.getMessage().containsIgnoreCase('timed out');
            throw timedOut ? failure('timeout', TOO_SLOW, true) : failure('unreachable', UNREACHABLE, true);
        } finally {
            spentMs += (Integer) (System.currentTimeMillis() - startedAt);
        }
    }

    private static Answer readAnswer(String responseBody, Boolean expectsJson) {
        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        } catch (Exception e) {
            throw new AiException(UNREADABLE);
        }
        String stopReason = (String) payload.get('stop_reason');
        if (stopReason == 'refusal') {
            throw new AiException(REFUSED);
        }
        if (stopReason == 'max_tokens') {
            throw new AiException(CUT_SHORT);
        }

        Answer answer = new Answer();
        answer.model = (String) payload.get('model');
        answer.text = collectText((List<Object>) payload.get('content'));
        if (String.isBlank(answer.text)) {
            throw new AiException(NO_ANSWER);
        }
        if (expectsJson) {
            try {
                answer.data = (Map<String, Object>) JSON.deserializeUntyped(answer.text);
            } catch (Exception e) {
                throw new AiException(UNREADABLE);
            }
        }
        return answer;
    }

    private static String collectText(List<Object> content) {
        List<String> parts = new List<String>();
        if (content != null) {
            for (Object item : content) {
                Map<String, Object> block = (Map<String, Object>) item;
                if (block.get('type') == 'text') {
                    parts.add((String) block.get('text'));
                }
            }
        }
        return String.join(parts, '').trim();
    }

    private static String describeFailure(HttpResponse response) {
        Integer status = response.getStatusCode();
        String summary;
        if (status == 401) {
            summary = 'Claude rejected the API key stored in the Anthropic credential.';
        } else if (status == RATE_LIMITED) {
            summary = 'Claude is rate limiting this API key. Wait a moment and try again.';
        } else if (status >= 500) {
            summary = 'Claude is temporarily unavailable. Try again in a moment.';
        } else {
            summary = 'Claude could not process the request (HTTP ' + status + ').';
        }
        String detail;
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            detail = (String) ((Map<String, Object>) payload.get('error')).get('message');
        } catch (Exception e) {
            detail = null;
        }
        return String.isBlank(detail) ? summary : summary + ' ' + detail.abbreviate(MAX_ERROR_DETAIL);
    }
}
