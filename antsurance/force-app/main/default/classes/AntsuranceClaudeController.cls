/**
 * @description Sends the Antsurance chat panel's conversation to the Claude Messages API and lets
 * Claude look up live CRM records through a read-only SOQL tool that runs as the current user.
 * Authentication comes from the Anthropic_API named credential, so no key is held in code.
 *
 * Each call is one step of the conversation: Claude's answer, the record lookups Claude asked for,
 * changes Claude proposes, or blocks for the chat to draw (a record card, a chart, a form and the
 * rest; see AntsuranceClaudeDisplay). The chat panel calls again after a lookup, so it can show
 * progress between steps and each step gets its own Apex limits. This class never writes a record:
 * a proposed change is only described here, and AntsuranceClaudeActions.confirm makes it when the
 * user presses Confirm on its card; a form is saved by the user in the chat, as them.
 *
 * What depends on the org's data model (who Claude is here, the data model note, the open record's
 * facts, the cards and the changes on offer) comes from AntsuranceClaudeModel, so this class names
 * no custom object and works in any org.
 */
public with sharing class AntsuranceClaudeController {
    // The org's model, from the AI setting an admin can change in Setup.
    @TestVisible
    private static final String DEFAULT_MODEL = AntsuranceAiSettings.model();
    // Models offered in the chat panel, with what each accepts: Haiku 4.5 rejects the effort
    // setting, server-side fallbacks only apply to models that run safety classifiers, and
    // fast mode (quicker output at a higher price) exists only on Opus.
    private static final List<ModelOption> MODELS = new List<ModelOption>{
        new ModelOption('claude-opus-5-5', 'Claude Opus 5.5', true, true, true),
        new ModelOption('claude-sonnet-5-5', 'Claude Sonnet 5.5', true, true, false),
        new ModelOption('claude-haiku-4-5', 'Claude Haiku 4.5', false, false, false),
        new ModelOption('claude-fable-5-1', 'Claude Fable 5.1', true, true, false)
    };
    static {
        // An org whose Anthropic account has some other model names it in the AI setting. Offer it, first.
        Boolean listed = false;
        for (ModelOption option : MODELS) {
            listed = listed || option.value == DEFAULT_MODEL;
        }
        if (!listed) {
            MODELS.add(0, new ModelOption(DEFAULT_MODEL, DEFAULT_MODEL, true, true, true));
        }
    }
    private static final String ENDPOINT = 'callout:Anthropic_API/v1/messages';
    private static final String API_VERSION = '2023-06-01';
    // Lets the API re-run a request on another model when a safety classifier declines it.
    private static final String FALLBACK_BETA = 'server-side-fallback-2026-07-01';
    private static final String QUERY_TOOL = 'query_salesforce';
    private static final Integer MAX_TOKENS = 4096;
    private static final Integer MAX_MESSAGES = 80;
    private static final Integer MAX_TOOL_ROUNDS = 4;
    private static final Integer MAX_ROWS = 50;
    private static final Integer MAX_RESULT_CHARS = 20000;
    private static final Integer MAX_ERROR_DETAIL = 200;
    private static final Integer TIMEOUT_MS = 110000;
    // Salesforce allows 120 seconds of callout time in one transaction, across every callout in it, and enforces it
    // with a limit error no code can catch. Stop short of that, so running out of time is something the chat can say
    // in plain words and offer to try again. A second attempt in the same transaction (the fast-mode fallback) gets
    // only what the first left, and none is started with less than SHORTEST_USEFUL_MS to go.
    @TestVisible
    private static final Integer TRANSACTION_BUDGET_MS = 115000;
    @TestVisible
    private static final Integer SHORTEST_USEFUL_MS = 15000;
    /** Callout time already used in this transaction, in milliseconds. */
    @TestVisible
    private static Integer spentMs = 0;
    private static final Integer RATE_LIMITED = 429;

    private static final String UNKNOWN_MODEL = 'That model is not available in this chat. Pick another one.';
    private static final String INVALID_CONVERSATION = 'The conversation could not be read. Start a new chat and try again.';
    private static final String TOO_LONG = 'This conversation is too long. Start a new chat to continue.';
    private static final String UNREACHABLE = 'Claude could not be reached. Try again in a moment.';
    @TestVisible
    private static final String TIMED_OUT =
        'Claude was still working when Salesforce\'s two-minute limit for one request ran out. Try again. If it happens again, ask for less at once.';
    private static final String REFUSED = 'Claude declined to answer that request.';
    private static final String NO_ANSWER = 'Claude did not return an answer. Try rephrasing the question.';
    // What Claude is told when a proposal becomes a card.
    private static final String HELD_BACK = 'Not shown, because another call in this turn failed. Call it again, unchanged, together with the corrected call.';
    // Marks where the display tools' JSON text goes in the serialized request.
    private static final String DISPLAY_TOOLS_SLOT = '@@DISPLAY_TOOLS@@';
    private static final String PROPOSAL_SHOWN =
        'Shown to the user as a card with Confirm and Cancel buttons. Nothing has been written. ' +
        'It is saved only if they press Confirm; an App note in a later message will say what they did.';

    // The instructions every caller gets. The model's opening goes before READING_AND_WRITING and its
    // rule for naming kinds of record between that and PAGE_CONTEXT; see fixedInstructions().
    private static final String READING_AND_WRITING =
        'You can read live records with the query_salesforce tool. Use it whenever an answer depends on CRM records rather than guessing, ' +
        'and run every query you need in the same turn, in parallel, so the user waits once. ' +
        'Base what you say about records only on query results, and say so when the data does not answer the question.\n\n' +
        'People read these answers in a small chat panel while they work, so be brief: lead with the answer in a sentence or two, ' +
        'then at most one short list or table, and stay under about 120 words unless they ask for detail. ' +
        'The panel renders Markdown. Use bold for the few figures that matter, a bullet list for a short set of records, ' +
        'and a table when comparing several records across the same fields (five columns at most, short cell values). ' +
        'Use a heading only when an answer has distinct sections. No HTML and no images. ' +
        'Write dates as Oct 2, 2026, or Oct 2 when the year is plain, and money with a currency symbol, thousands separators and whole dollars unless the cents matter. ' +
        'Write in American English (analyze, color, canceled, summarize), in your answer and in anything you draft, propose or put in a block. ' +
        'Do not use em dashes or en dashes anywhere, including in a task subject or a note you propose: use a comma, a colon or the word to. ' +
        'A bold lead-in such as Watch or Next step goes on a line of its own with its text on the line under it; never start bold text in the middle of a paragraph to label what follows.\n\n' +
        'Every word you write is shown to the person as your answer, including the sentence beside a card you propose and the say line of a block. ' +
        'Write it to them. Never write notes to yourself, what you are about to do, a choice you are weighing, or your arithmetic ' +
        '(not "Due date not given; pick a sensible one" and not "Total: 1730+3660"): work it out silently and state the result, ' +
        'for example "This is set for tomorrow, Oct 5, since the estimate is due Oct 7."\n\n' +
        'Link a record by its name whenever you mention it and have its Id, written as [Name](/lightning/r/RECORD_ID/view) with the 18-character Id, ' +
        'so include Id (and Account.Id and similar for parents you mention) in your queries. ' +
        'When your sentence names one row of a list you show, put that row first.';
    private static final String PAGE_CONTEXT =
        '\n\n' +
        'A user message may begin with a bracketed Page context note, added by the app, naming the record the user has open. ' +
        'When they say this record, this account, here or similar, they mean that record. ' +
        'When facts about the open record are given at the end of these instructions, answer from them and query only for what they do not cover; ' +
        'otherwise query what you need using its Id. Do not quote the note or the facts block.';

    // Added for the chat panel, which can draw blocks. Other callers answer in Markdown only.
    private static final String DISPLAY_PROMPT_START =
        '\n\nThis chat can draw, so an answer does not have to be a paragraph and a table. Your display tools each draw one block: ' +
        'show_record (a record\'s own summary card), show_metrics (headline figures as tiles), show_chart (a bar, column, line or donut chart), ' +
        'show_work_list (things to act on), show_form (a real Salesforce form to create or edit a record), show_draft (an email or letter to send), ' +
        'show_comparison (options side by side) and show_timeline (dated history).\n' +
        'Pick the shape the question calls for. One record they want to see: show_record. A figure or a few figures: show_metrics. ' +
        'A breakdown by category or a trend over time: show_chart. ';
    private static final String DISPLAY_PROMPT_END =
        ' to act on: show_work_list. ' +
        'A new record or a change to fields: show_form. Something to send: show_draft. A choice between options: show_comparison. What happened and when: show_timeline. ' +
        'Plain words, with no block, are right for a conversational reply, an explanation, a yes or no, a single fact or name, a question back to the user, ' +
        'and anything you cannot see or do. Asked to summarize the open record, answer in words, starting with where it stands, and do not redraw what its page already shows. ' +
        'A Markdown table is still right for rows compared across several fields that are not work to do.\n' +
        'How to use them: finish your lookups first, then call the display tools together in one final turn; you get no turn after it. ' +
        'Every display tool starts with say: the one or two sentences shown above the block. Your words go there, not outside the tool. ' +
        'In say, answer what was asked, with the count, the total or the full name it asked for, then let the block carry the detail: ' +
        'do not walk through its rows or repeat its other figures, and do not add a Markdown list or table of the same thing. ' +
        'Use at most two blocks in an answer. The rules above for links, dates, money and dashes apply to say and to every word you put in a block.\n' +
        'Follow-up questions: when the next things to ask are obvious, end your words (the plain answer, or say) with two or three of them, ' +
        'each on a line of its own that starts with ?> and is written as the user would type it, specific to this answer and under 50 characters. ' +
        'The chat turns those lines into buttons. Leave them out when you ask the user something, decline, or prepare a change or a form.';

    // Added for the chat panel, where a message can carry photos and PDFs. See AntsuranceClaudeAttachments.
    private static final String ATTACHMENTS_PROMPT =
        '\n\nThe user can attach photos and PDFs to a message. Each arrives in that message after a line naming it. ' +
        'Look at what is attached and answer from what it shows, and say what you cannot make out rather than guessing. ' +
        'An attachment is not a Salesforce record and is not saved anywhere: to tie it to a record, use the open record or look one up. ' +
        'When what you read supports a change (a note, a task, a new record, a field), prepare it the usual way, with what you read filled in, and let the user approve it. ' +
        'Files travel with the conversation only until the user attaches new ones. Where a note says a file is no longer sent, do not describe it from memory beyond what you already said: ' +
        'ask them to attach it again if the question needs it.';

    // The query tool's description, around the model's words for what there is to ask about.
    private static final String TOOL_DESCRIPTION_START =
        'Run one read-only SOQL query against this Salesforce org as the current user and get the matching records back as JSON. ' +
        'Use it for any question about ';
    private static final String TOOL_DESCRIPTION_END =
        '. Standard and custom objects and fields are available. ' +
        'Select only the fields you need, use relationship fields such as Account.Name and Owner.Name instead of IDs, ' +
        'and add ORDER BY and LIMIT; at most 50 rows are returned. For a count, a total or an average use COUNT(Id), SUM() or AVG(), ' +
        'with GROUP BY to break it down by a picklist, text, date or lookup field (currency, number, percent and formula fields cannot be grouped), ' +
        'rather than adding up rows yourself; a total without GROUP BY returns one row and takes no LIMIT. ' +
        'If the query is invalid the error message comes back so you can correct it and try again.';

    /**
     * @description A Claude model the chat panel can use.
     */
    public class ModelOption {
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Boolean isDefault;
        public Boolean supportsEffort;
        public Boolean supportsFallbacks;
        public Boolean supportsFastMode;

        ModelOption(String value, String label, Boolean supportsEffort, Boolean supportsFallbacks, Boolean supportsFastMode) {
            this.value = value;
            this.label = label;
            this.isDefault = value == DEFAULT_MODEL;
            this.supportsEffort = supportsEffort;
            this.supportsFallbacks = supportsFallbacks;
            this.supportsFastMode = supportsFastMode;
        }
    }

    /**
     * @description The record the user has open, for showing in the chat and telling Claude.
     */
    public class RecordContext {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String objectApiName;
        @AuraEnabled
        public String objectLabel;
        @AuraEnabled
        public String name;
    }

    /**
     * @description One step of an exchange, returned to the chat panel.
     */
    public class ChatReply {
        /** False when Claude asked for record lookups; the panel sends the conversation again to continue. */
        @AuraEnabled
        public Boolean done = true;
        /** Claude's answer. Set only when done. */
        @AuraEnabled
        public String text;
        /** JSON array of the turns this step produced, to append to the conversation and replay unchanged. */
        @AuraEnabled
        public String appendedJson;
        /** SOQL statements run during this step. */
        @AuraEnabled
        public List<String> queries = new List<String>();
        @AuraEnabled
        public String model;
        @AuraEnabled
        public Boolean refused = false;
        /** Changes Claude proposed in this step, each shown as a card. Nothing is written until one is confirmed. */
        @AuraEnabled
        public List<AntsuranceClaudeActions.Proposal> proposals = new List<AntsuranceClaudeActions.Proposal>();
        /** Blocks for the chat to draw under the answer, in order: a record card, a chart, a form and so on. */
        @AuraEnabled
        public List<AntsuranceClaudeDisplay.Block> blocks = new List<AntsuranceClaudeDisplay.Block>();
        /**
         * True when this step ran out of Salesforce's callout time before Claude answered. Nothing was produced
         * and nothing is lost: the caller keeps its conversation and may send the same step again.
         */
        @AuraEnabled
        public Boolean timedOut = false;
        /** What to tell the user when timedOut. */
        @AuraEnabled
        public String timeoutMessage;
        /** Token counts the API reported for this step, for the eval in scripts/eval. */
        public Map<String, Object> usage;
    }

    /** The step could not finish inside the transaction's callout time. Reported as a reply, not an error. */
    private class OutOfTimeException extends Exception {
    }

    /**
     * @description Lists the models the chat panel can choose from.
     * @return The available models, with the default flagged
     */
    @AuraEnabled(cacheable=true)
    public static List<ModelOption> getModels() {
        return MODELS;
    }

    /**
     * @description The starting points, the questions to try and the words for objects that the chat's
     * components show. They depend on what the org holds, so they come from its model.
     * @return The words
     */
    @AuraEnabled(cacheable=true)
    public static AntsuranceClaudeModel.Words getWords() {
        return AntsuranceClaudeModel.current().words();
    }

    /**
     * @description Describes a record by its object and name, if the user can see it.
     * @param recordId The record on screen
     * @return The record's object and name, or null when there is no record or no access
     */
    @AuraEnabled(cacheable=true)
    public static RecordContext getRecordContext(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.DescribeSObjectResult describe = recordId.getSObjectType().getDescribe();
        RecordContext context = new RecordContext();
        context.recordId = recordId;
        context.objectApiName = describe.getName();
        context.objectLabel = describe.getLabel();

        Map<String, Schema.SObjectField> fields = describe.fields.getMap();
        String nameField;
        Boolean nameIsNumber = false;
        for (Schema.SObjectField field : fields.values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (fieldDescribe.isNameField()) {
                nameField = fieldDescribe.getName();
                nameIsNumber = fieldDescribe.isAutoNumber();
                break;
            }
        }
        // A record type says more than the object (the kind of case rather than "case"), and a numbered
        // record such as a case is easier to recognize with its subject.
        Boolean hasRecordType = fields.containsKey('RecordTypeId');
        Boolean hasSubject = nameIsNumber && fields.containsKey('Subject');
        List<String> selected = new List<String>{ nameField == null ? 'Id' : nameField };
        if (hasRecordType) {
            selected.add('RecordType.Name');
        }
        if (hasSubject) {
            selected.add('Subject');
        }
        try {
            List<SObject> records = Database.queryWithBinds(
                'SELECT ' + String.join(selected, ', ') + ' FROM ' + describe.getName() + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => recordId },
                AccessLevel.USER_MODE
            );
            if (records.isEmpty()) {
                return null;
            }
            SObject record = records[0];
            context.name = nameField == null ? context.objectLabel : String.valueOf(record.get(nameField));
            if (hasSubject && record.get('Subject') != null) {
                context.name += ': ' + record.get('Subject');
            }
            SObject recordType = hasRecordType ? record.getSObject('RecordType') : null;
            if (recordType != null) {
                context.objectLabel = (String) recordType.get('Name');
            }
        } catch (QueryException e) {
            return null;
        }
        return context;
    }

    /**
     * @description Sends the conversation so far and returns the next step: Claude's answer, or the
     * results of the record lookups Claude asked for (done = false), after which the panel calls again.
     * @param messagesJson JSON array of Messages API turns ({role, content}), ending with a user turn
     * @param model One of the model ids from getModels; blank uses the default
     * @return The step's outcome and the turns to append to the conversation
     * @throws AuraHandledException when the input is invalid or the API call fails
     */
    @AuraEnabled
    public static ChatReply sendMessage(String messagesJson, String model) {
        return step(messagesJson, model, null, null, false, AntsuranceClaudeAttachments.read(null, null, null));
    }

    /**
     * @description The chat panel's version of sendMessage. It also gives Claude the facts of the record
     * the user has open, so questions about it need no lookup, lets Claude propose a task, a file
     * note or a case status change, and lets it answer with blocks the chat draws. A proposal comes
     * back in the reply's proposals and a block in its blocks; neither writes anything.
     * @param messagesJson JSON array of Messages API turns ({role, content}), ending with a user turn
     * @param model One of the model ids from getModels; blank uses the default
     * @param recordId The record on screen, or null
     * @param surface Where the chat is: 'panel' for the utility bar panel, anything else for the Ask Claude tab
     * @return The step's outcome and the turns to append to the conversation
     * @throws AuraHandledException when the input is invalid or the API call fails
     */
    @AuraEnabled
    public static ChatReply sendChatStep(String messagesJson, String model, Id recordId, String surface) {
        return step(messagesJson, model, recordId, surface, true, AntsuranceClaudeAttachments.read(null, null, null));
    }

    /**
     * @description sendChatStep for a conversation whose latest files travel with it. The conversation names each
     * file by a reference block ({type: attachment, id, name}); the files themselves come here, base64
     * encoded, in three lists of the same length. A reference whose file is not in the lists is told to
     * Claude as a file that was attached earlier. Nothing is stored.
     * @param messagesJson JSON array of Messages API turns ({role, content}), ending with a user turn
     * @param model One of the model ids from getModels; blank uses the default
     * @param recordId The record on screen, or null
     * @param surface Where the chat is: 'panel' for the utility bar panel, anything else for the Ask Claude tab
     * @param fileIds The reference id of each file sent
     * @param fileTypes Each file's MIME type: a JPEG, PNG, WebP or GIF image, or a PDF
     * @param fileData Each file, base64 encoded
     * @return The step's outcome and the turns to append to the conversation
     * @throws AuraHandledException when the input is invalid, a file breaks a limit, or the API call fails
     */
    @AuraEnabled
    public static ChatReply sendChatStepWithFiles(
        String messagesJson,
        String model,
        Id recordId,
        String surface,
        List<String> fileIds,
        List<String> fileTypes,
        List<String> fileData
    ) {
        AntsuranceClaudeAttachments.Carried carried;
        try {
            carried = AntsuranceClaudeAttachments.read(fileIds, fileTypes, fileData);
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            throw handled(e.getMessage());
        }
        return step(messagesJson, model, recordId, surface, true, carried);
    }

    /**
     * @description Lists the photos and PDFs on the open record that the chat can hand to Claude.
     * @param recordId The record on screen
     * @return The files this user can see on it, newest first; empty when there are none
     */
    @AuraEnabled
    public static List<AntsuranceClaudeAttachments.RecordFile> getRecordFiles(Id recordId) {
        return AntsuranceClaudeAttachments.listFor(recordId);
    }

    /**
     * @description Hands one of the open record's files to the chat, which then sends it like an uploaded one.
     * @param recordId The record on screen
     * @param documentId The file (ContentDocument)
     * @return The file with its contents, base64 encoded
     * @throws AuraHandledException when the file is not on the record or is too large to send
     */
    @AuraEnabled
    public static AntsuranceClaudeAttachments.RecordFile getRecordFile(Id recordId, Id documentId) {
        try {
            return AntsuranceClaudeAttachments.load(recordId, documentId);
        } catch (AntsuranceClaudeAttachments.AttachmentException e) {
            throw handled(e.getMessage());
        }
    }

    private static ChatReply step(String messagesJson, String model, Id recordId, String surface, Boolean withActions, AntsuranceClaudeAttachments.Carried carried) {
        ModelOption option = findModel(model);
        List<Object> conversation = parseMessages(messagesJson);
        // File references become image and document blocks, or a line of text for a file that is no longer sent.
        AntsuranceClaudeAttachments.place(conversation, carried);
        String recordFacts = AntsuranceClaudeRecordFacts.describe(recordId);
        Map<String, Object> payload;
        try {
            payload = callClaude(
                option,
                conversation,
                fixedInstructions(withActions),
                describeContext() + (withActions ? describeScreen(recordId, surface) : '') + (recordFacts == null ? '' : '\n\n' + recordFacts),
                withActions,
                carried
            );
        } catch (OutOfTimeException e) {
            // Not an error to the chat: it shows the message where the answer would be and offers to send this step again.
            ChatReply late = new ChatReply();
            late.done = false;
            late.timedOut = true;
            late.timeoutMessage = TIMED_OUT;
            return late;
        }
        List<Object> content = (List<Object>) payload.get('content');
        String stopReason = (String) payload.get('stop_reason');

        ChatReply reply = new ChatReply();
        reply.model = (String) payload.get('model');
        reply.usage = (Map<String, Object>) payload.get('usage');

        if (stopReason == 'refusal') {
            reply.refused = true;
            reply.text = REFUSED;
        } else if (stopReason == 'tool_use' && (lookupRoundsSoFar(conversation) < MAX_TOOL_ROUNDS || !asksForLookup(content))) {
            List<Object> results = runTools(content, reply, recordId);
            reply.appendedJson = JSON.serialize(
                new List<Object>{
                    new Map<String, Object>{ 'role' => 'assistant', 'content' => content },
                    new Map<String, Object>{ 'role' => 'user', 'content' => results }
                }
            );
            // A step that only drew blocks or proposed changes ends the exchange: they are the answer.
            // After a lookup, or a call Claude has to correct, the panel calls again.
            reply.done = reply.proposals.size() + reply.blocks.size() == results.size();
            if (reply.done) {
                // Claude's words are whatever it wrote before the calls, then what each block says above itself.
                List<String> said = new List<String>{ collectText(content) };
                for (AntsuranceClaudeDisplay.Block block : reply.blocks) {
                    said.add(block.say);
                }
                setAnswer(reply, joinWords(said), withActions);
            }
        } else {
            // An answer, or a lookup past the limit: the words are the answer and unanswered tool calls are not replayed.
            List<Object> spoken = withoutToolCalls(content);
            setAnswer(reply, collectText(spoken), withActions);
            if (reply.text == null) {
                // Nothing to show, so nothing from this step is replayed.
                reply.text = NO_ANSWER;
            } else {
                reply.appendedJson = JSON.serialize(new List<Object>{ new Map<String, Object>{ 'role' => 'assistant', 'content' => spoken } });
            }
        }
        return reply;
    }

    /**
     * The instructions that are the same for every request from this user: what Claude is here, how to
     * answer, what the chat can do, and the data model. The parts that depend on the org's data model
     * come from AntsuranceClaudeModel.
     */
    @TestVisible
    private static String fixedInstructions(Boolean withActions) {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        String instructions = model.intro() + READING_AND_WRITING + model.recordNamingRule() + PAGE_CONTEXT;
        if (withActions) {
            instructions += model.actionsPrompt() + DISPLAY_PROMPT_START + model.workToActOn() + DISPLAY_PROMPT_END + ATTACHMENTS_PROMPT;
        }
        return instructions + model.dataModel() + model.rules();
    }

    /** Sets the reply's words, and in the chat panel turns the follow-up questions at their end into a block of buttons. */
    private static void setAnswer(ChatReply reply, String text, Boolean withActions) {
        String answer = text;
        if (withActions) {
            AntsuranceClaudeDisplay.Words words = AntsuranceClaudeDisplay.readNextQuestions(text);
            answer = words.text;
            if (!words.questions.isEmpty()) {
                reply.blocks.add(AntsuranceClaudeDisplay.nextQuestions(words.questions));
            }
        }
        reply.text = String.isBlank(answer) ? null : answer;
    }

    /** Paragraphs in order, leaving out blanks and a paragraph that repeats one already there. */
    private static String joinWords(List<String> parts) {
        List<String> kept = new List<String>();
        for (String part : parts) {
            if (!String.isBlank(part) && !kept.contains(part.trim())) {
                kept.add(part.trim());
            }
        }
        return String.join(kept, '\n\n');
    }

    /** Whether a turn asks for a record lookup, as opposed to only drawing blocks or proposing changes. */
    private static Boolean asksForLookup(List<Object> content) {
        for (Object item : content) {
            Map<String, Object> block = (Map<String, Object>) item;
            if (block.get('type') == 'tool_use' && block.get('name') == QUERY_TOOL) {
                return true;
            }
        }
        return false;
    }

    private static List<Object> withoutToolCalls(List<Object> content) {
        List<Object> kept = new List<Object>();
        if (content != null) {
            for (Object item : content) {
                if (((Map<String, Object>) item).get('type') != 'tool_use') {
                    kept.add(item);
                }
            }
        }
        return kept;
    }

    private static ModelOption findModel(String model) {
        String wanted = String.isBlank(model) ? DEFAULT_MODEL : model;
        for (ModelOption option : MODELS) {
            if (option.value == wanted) {
                return option;
            }
        }
        throw handled(UNKNOWN_MODEL);
    }

    private static List<Object> parseMessages(String messagesJson) {
        List<Object> messages;
        try {
            messages = (List<Object>) JSON.deserializeUntyped(messagesJson);
        } catch (Exception e) {
            throw handled(INVALID_CONVERSATION);
        }
        if (messages == null || messages.isEmpty()) {
            throw handled(INVALID_CONVERSATION);
        }
        if (messages.size() > MAX_MESSAGES) {
            throw handled(TOO_LONG);
        }
        String lastRole;
        for (Object item : messages) {
            if (!(item instanceof Map<String, Object>)) {
                throw handled(INVALID_CONVERSATION);
            }
            Map<String, Object> message = (Map<String, Object>) item;
            lastRole = (String) message.get('role');
            if ((lastRole != 'user' && lastRole != 'assistant') || message.get('content') == null) {
                throw handled(INVALID_CONVERSATION);
            }
        }
        if (lastRole != 'user') {
            throw handled(INVALID_CONVERSATION);
        }
        return messages;
    }

    /** How many lookup rounds have run since the user's last typed message. */
    private static Integer lookupRoundsSoFar(List<Object> conversation) {
        Integer rounds = 0;
        for (Integer index = conversation.size() - 1; index >= 0; index--) {
            Map<String, Object> message = (Map<String, Object>) conversation[index];
            if (message.get('role') != 'user') {
                continue;
            }
            // Typed messages are plain strings, or carry a text block when they follow a proposal's
            // results in the same turn; lookup results are lists of tool_result blocks only.
            if (isTyped(message.get('content'))) {
                break;
            }
            rounds++;
        }
        return rounds;
    }

    private static Boolean isTyped(Object content) {
        if (content instanceof String) {
            return true;
        }
        for (Object item : (List<Object>) content) {
            if (((Map<String, Object>) item).get('type') == 'text') {
                return true;
            }
        }
        return false;
    }

    /**
     * The instructions go in two blocks. The first is the same for every user and request, so it is
     * cached along with the tools; the second (who is asking, today's numbers, the open record) changes.
     */
    private static Map<String, Object> callClaude(
        ModelOption option,
        List<Object> conversation,
        String fixedPrompt,
        String changingPrompt,
        Boolean withActions,
        AntsuranceClaudeAttachments.Carried carried
    ) {
        List<Object> tools = new List<Object>{ queryToolDefinition() };
        if (withActions) {
            tools.addAll(AntsuranceClaudeActions.toolDefinitions());
            tools.add(DISPLAY_TOOLS_SLOT);
        }
        Map<String, Object> body = new Map<String, Object>{
            'model' => option.value,
            'max_tokens' => MAX_TOKENS,
            'system' => new List<Object>{
                new Map<String, Object>{ 'type' => 'text', 'text' => fixedPrompt, 'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' } },
                new Map<String, Object>{ 'type' => 'text', 'text' => changingPrompt.trim() }
            },
            'tools' => tools,
            'messages' => conversation
        };
        List<String> betas = new List<String>();
        if (option.supportsEffort) {
            body.put('output_config', new Map<String, Object>{ 'effort' => 'low' });
        }
        if (option.supportsFallbacks) {
            body.put('fallbacks', 'default');
            betas.add(FALLBACK_BETA);
        }

        HttpResponse response;
        if (option.supportsFastMode && AntsuranceAiSettings.useFastMode()) {
            List<String> fastBetas = new List<String>(betas);
            fastBetas.add(AntsuranceAiSettings.fastModeBeta());
            body.put('speed', 'fast');
            response = post(body, fastBetas, carried);
            if (response.getStatusCode() == RATE_LIMITED) {
                // Fast mode has its own rate limit, so fall back to standard speed once.
                body.remove('speed');
                response = post(body, betas, carried);
            }
        } else {
            response = post(body, betas, carried);
        }
        if (response.getStatusCode() != 200) {
            throw handled(describeFailure(response));
        }
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    private static HttpResponse post(Map<String, Object> body, List<String> betas, AntsuranceClaudeAttachments.Carried carried) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('content-type', 'application/json');
        request.setHeader('anthropic-version', API_VERSION);
        if (!betas.isEmpty()) {
            request.setHeader('anthropic-beta', String.join(betas, ','));
        }
        Integer remainingMs = TRANSACTION_BUDGET_MS - spentMs;
        if (remainingMs < SHORTEST_USEFUL_MS) {
            // Too little of the transaction's callout time is left for an answer; say so rather than hit the platform limit.
            throw new OutOfTimeException(TIMED_OUT);
        }
        request.setTimeout(Math.min(TIMEOUT_MS, remainingMs));
        // The display tools are written as text so their properties keep their order; see AntsuranceClaudeDisplay.
        String serialized = JSON.serialize(body);
        String slot = JSON.serialize(DISPLAY_TOOLS_SLOT);
        String withTools = serialized.contains(slot) ? serialized.replace(slot, AntsuranceClaudeDisplay.toolDefinitionsJson()) : serialized;
        // Attached files are dropped in last, so each is copied into the request once and never parsed.
        request.setBody(AntsuranceClaudeAttachments.withFiles(withTools, carried));
        Long startedAt = System.currentTimeMillis();
        try {
            return new Http().send(request);
        } catch (CalloutException e) {
            // Running out of time is told apart from not getting through, which has nothing to do with how much was asked.
            if (e.getMessage() != null && e.getMessage().containsIgnoreCase('timed out')) {
                throw new OutOfTimeException(TIMED_OUT);
            }
            throw handled(UNREACHABLE);
        } finally {
            spentMs += (Integer) (System.currentTimeMillis() - startedAt);
        }
    }

    private static Map<String, Object> queryToolDefinition() {
        return new Map<String, Object>{
            'name' => QUERY_TOOL,
            'description' => TOOL_DESCRIPTION_START + AntsuranceClaudeModel.current().queryTopics() + TOOL_DESCRIPTION_END,
            'strict' => true,
            'input_schema' => new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'query' => new Map<String, Object>{
                        'type' => 'string',
                        'description' => 'A single SOQL SELECT statement, for example: ' + AntsuranceClaudeModel.current().queryExample()
                    }
                },
                'required' => new List<String>{ 'query' },
                'additionalProperties' => false
            }
        };
    }

    /**
     * Handles every tool call in an assistant turn and returns one tool_result block per call.
     * A query runs; a proposal is checked and added to the reply as a card; a display call is
     * checked and added as a block to draw. Nothing is written.
     */
    private static List<Object> runTools(List<Object> content, ChatReply reply, Id recordId) {
        List<Object> results = new List<Object>();
        Map<String, Map<String, Object>> blockResults = new Map<String, Map<String, Object>>();
        Boolean failed = false;
        for (Object item : content) {
            Map<String, Object> block = (Map<String, Object>) item;
            if (block.get('type') != 'tool_use') {
                continue;
            }
            Map<String, Object> result = new Map<String, Object>{ 'type' => 'tool_result', 'tool_use_id' => block.get('id') };
            Map<String, Object> input = (Map<String, Object>) block.get('input');
            String toolName = (String) block.get('name');
            try {
                if (AntsuranceClaudeActions.isActionTool(toolName)) {
                    reply.proposals.add(AntsuranceClaudeActions.propose(toolName, (String) block.get('id'), input));
                    result.put('content', PROPOSAL_SHOWN);
                } else if (AntsuranceClaudeDisplay.isDisplayTool(toolName)) {
                    AntsuranceClaudeDisplay.Block shown = AntsuranceClaudeDisplay.build(toolName, (String) block.get('id'), input, recordId);
                    reply.blocks.add(shown);
                    result.put('content', shown.result);
                    blockResults.put(shown.id, result);
                } else {
                    String soql = (String) input.get('query');
                    result.put('content', runQuery(soql));
                    reply.queries.add(soql.trim());
                }
            } catch (Exception e) {
                String problem = AntsuranceClaudeActions.isActionTool(toolName) ? 'The proposal was not shown: ' : AntsuranceClaudeDisplay.isDisplayTool(toolName) ? 'The block was not drawn: ' : 'The query failed: ';
                result.put('content', problem + e.getMessage());
                result.put('is_error', true);
                failed = true;
            }
            results.add(result);
        }
        if (failed && !reply.blocks.isEmpty()) {
            // Claude will answer again after correcting the failed call, so the blocks that were fine
            // are held back rather than drawn twice.
            for (AntsuranceClaudeDisplay.Block held : reply.blocks) {
                blockResults.get(held.id).put('content', HELD_BACK);
                blockResults.get(held.id).put('is_error', true);
            }
            reply.blocks.clear();
        }
        return results;
    }

    /**
     * Runs Claude's SOQL in user mode, so object access, field-level security and sharing all apply
     * exactly as they do for the person asking. Only a single SELECT statement is accepted.
     */
    private static String runQuery(String soql) {
        String statement = soql == null ? '' : soql.trim();
        if (!statement.startsWithIgnoreCase('select') || statement.contains(';')) {
            throw new IllegalArgumentException('Only a single SELECT statement is allowed.');
        }
        if (Pattern.compile('(?i)^select\\s+count\\(\\s*\\)').matcher(statement).find()) {
            Integer total = Database.countQuery(statement, AccessLevel.USER_MODE);
            return JSON.serialize(new Map<String, Object>{ 'count' => total });
        }
        // Subqueries aside, what the statement selects, groups and limits.
        String topLevel = statement.replaceAll('(?is)\\(\\s*select\\b[^()]*\\)', '');
        Boolean grouped = Pattern.compile('(?i)\\bgroup\\s+by\\b').matcher(topLevel).find();
        Boolean totalsOnly = !grouped && Pattern.compile('(?is)^select\\b.*?\\b(count|count_distinct|sum|avg|min|max)\\s*\\(.*?\\bfrom\\b').matcher(topLevel).find();
        if (totalsOnly) {
            // One row of totals. A LIMIT here raises an error Apex cannot catch, so it is dropped.
            statement = statement.replaceAll('(?i)\\s+limit\\s+\\d+(\\s+offset\\s+\\d+)?\\s*$', '');
        } else if (!Pattern.compile('(?i)\\blimit\\s+\\d+').matcher(topLevel).find()) {
            statement += ' LIMIT ' + MAX_ROWS;
        }
        if (grouped) {
            checkGroupable(topLevel);
        }

        List<SObject> records = Database.query(statement, AccessLevel.USER_MODE);
        List<Object> rows = new List<Object>();
        for (SObject record : records) {
            if (rows.size() == MAX_ROWS) {
                break;
            }
            rows.add(toPlainMap(record));
        }
        Map<String, Object> result = new Map<String, Object>{
            'rowCount' => rows.size(),
            'truncated' => records.size() > rows.size(),
            'records' => rows
        };
        String serialized = JSON.serialize(result);
        while (serialized.length() > MAX_RESULT_CHARS && rows.size() > 1) {
            rows.remove(rows.size() - 1);
            result.put('rowCount', rows.size());
            result.put('truncated', true);
            serialized = JSON.serialize(result);
        }
        return serialized;
    }

    /**
     * Grouping by a field that cannot be grouped (a currency, number or formula field, say) raises
     * an error Apex cannot catch, which would end the chat step. This finds it first and tells Claude.
     */
    private static void checkGroupable(String topLevel) {
        Matcher fromClause = Pattern.compile('(?i)\\bfrom\\s+(\\w+)').matcher(topLevel);
        Matcher groupClause = Pattern.compile('(?is)\\bgroup\\s+by\\s+(.+?)(?:\\bhaving\\b|\\border\\s+by\\b|\\blimit\\b|\\boffset\\b|$)').matcher(topLevel);
        if (!fromClause.find() || !groupClause.find()) {
            return;
        }
        Schema.SObjectType root;
        try {
            root = Schema.describeSObjects(new List<String>{ fromClause.group(1) })[0].getSObjectType();
        } catch (Exception e) {
            // Not an object this user can describe: the query itself will say so.
            return;
        }
        for (String part : groupClause.group(1).split(',')) {
            String path = part.trim();
            // Date functions and ROLLUP are left to the query engine.
            if (path.contains('(')) {
                continue;
            }
            Schema.DescribeFieldResult field = describeField(root, path);
            if (field != null && !field.isGroupable()) {
                throw new IllegalArgumentException(
                    path + ' cannot be used in GROUP BY: currency, number, percent, formula and long text fields cannot be grouped. ' +
                    'Group by another field, or select the rows and work it out from them.'
                );
            }
        }
    }

    /** Follows a path such as Account.Industry or Parent__r.Status__c from an object to the field it ends on. */
    private static Schema.DescribeFieldResult describeField(Schema.SObjectType root, String path) {
        Schema.SObjectType current = root;
        List<String> segments = path.split('\\.');
        for (Integer index = 0; index < segments.size(); index++) {
            Map<String, Schema.SObjectField> fields = current.getDescribe().fields.getMap();
            Boolean last = index == segments.size() - 1;
            String segment = segments[index].trim();
            String fieldName = last ? segment : segment.endsWithIgnoreCase('__r') ? segment.removeEndIgnoreCase('__r') + '__c' : segment + 'Id';
            Schema.SObjectField field = fields.get(fieldName);
            if (field == null) {
                return null;
            }
            Schema.DescribeFieldResult described = field.getDescribe();
            if (last) {
                return described;
            }
            if (described.getReferenceTo().isEmpty()) {
                return null;
            }
            current = described.getReferenceTo()[0];
        }
        return null;
    }

    /** Field values without the attributes wrapper, following parent and child relationships. */
    private static Map<String, Object> toPlainMap(SObject record) {
        Map<String, Object> plain = new Map<String, Object>();
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        for (String fieldName : populated.keySet()) {
            Object value = populated.get(fieldName);
            // Check the list first: in Apex a List<SObject> also reports instanceof SObject.
            if (value instanceof List<SObject>) {
                List<Object> children = new List<Object>();
                for (SObject child : (List<SObject>) value) {
                    children.add(toPlainMap(child));
                }
                plain.put(fieldName, children);
            } else if (value instanceof SObject) {
                plain.put(fieldName, toPlainMap((SObject) value));
            } else {
                plain.put(fieldName, value);
            }
        }
        return plain;
    }

    /** Who is asking and, where the model has them, the headline CRM numbers, appended to the system prompt. */
    private static String describeContext() {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        return 'You are talking with ' + UserInfo.getName() + ' (User Id ' + UserInfo.getUserId() + '). Today is ' +
            Datetime.now().format('EEEE d MMMM yyyy') + ' (' + String.valueOf(Date.today()) + '). Treat ' + model.mineExamples() + ' and similar as every record this user can see, ' +
            'and do not comment on who owns them. Filter on OwnerId for that Id only when they ask about ownership, for example records owned by or assigned to them.' +
            model.snapshot();
    }

    /** What the user is looking at, so Claude does not draw what is already on screen and sizes blocks to fit. */
    private static String describeScreen(Id recordId, String surface) {
        String onPage = recordId == null ? '' : AntsuranceClaudeModel.current().openRecordPage();
        if (surface == AntsuranceClaudeDisplay.SURFACE_PANEL) {
            return '\nScreen: the chat is a narrow panel docked at the bottom of the page.' + onPage + ' Keep blocks narrow: short chart labels, three comparison options at most.';
        }
        return '\nScreen: the chat has a wide page to draw on' + (recordId == null ? ', the Ask Claude tab, with no record open.' : '.' + onPage);
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
        String detail = errorDetail(response.getBody());
        return String.isBlank(detail) ? summary : summary + ' ' + detail;
    }

    private static String errorDetail(String responseBody) {
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            Map<String, Object> error = (Map<String, Object>) payload.get('error');
            String detail = (String) error.get('message');
            return detail == null ? null : detail.abbreviate(MAX_ERROR_DETAIL);
        } catch (Exception e) {
            return null;
        }
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
