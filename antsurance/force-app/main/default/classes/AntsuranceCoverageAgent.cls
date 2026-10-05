/**
 * @description The claims coverage agent, as the claim page drives it. This is the one feature in
 * the org that is an agent with a harness: the loop, the context management and the compaction run
 * on Claude Managed Agents, the method is a skill attached to the agent, and the agent decides for
 * itself what to read next. Everything else Claude does here is a single call or a fixed pipeline.
 *
 * How one investigation runs:
 * - start() opens a session for the claim and gives the agent its task. One short request.
 * - The claim page then calls poll() every couple of seconds. Each poll is its own short request:
 *   it fetches the session's events (a plain list that returns at once, not a long poll), runs any
 *   tool the agent has asked for, here in Salesforce as the signed-in user, and hands the results
 *   back. Reading a document is slow, so the page runs that one through readDocument(), a request
 *   of its own.
 * - When the agent records its finding, the claim is saved first and the agent is told
 *   "recorded" only afterwards. A callout cannot follow a save in one transaction, so the two are
 *   two polls: the poll that sees the finding saves it and leaves the tool unanswered, and the
 *   next poll, finding it on the claim, answers the tool. If the save fails the person is told why
 *   and the tool stays unanswered, so every later poll tries the save again from what the session
 *   holds; the agent is never told a finding is recorded that is not. The finding is stored in
 *   the same shape as the single-call coverage check, so the brief, the letters and the analysis
 *   read it unchanged, with how the agent worked kept beside it.
 *
 * Nothing here holds state between requests: the session on Managed Agents is the state, and the
 * page keeps only its id. A session is bound to the claim it was started for, and its first
 * message carries two things every later request reads back: which claim it is for, and the key
 * each record had when it started, so D2 is the same file from the first step to the last. Every
 * entry point that takes a session id checks both that it is shaped like one and that the session
 * is this claim's before anything is read, run or sent.
 */
public with sharing class AntsuranceCoverageAgent {
    private static final String WORKING = 'working';
    private static final String DONE = 'done';
    private static final String FAILED = 'failed';
    private static final Integer MAX_EVENT_PAGES = 5;
    // Long enough that a step's one-sentence finding is never cut.
    private static final Integer MAX_DETAIL = 400;
    private static final Integer MAX_EVIDENCE_LINE = 420;
    private static final String CLAIM_MARKER = 'Claim record: ';
    @TestVisible
    private static final String KEYS_MARKER = 'Record keys for this investigation, kept by the system that runs your tools so that a key means the same record from start to finish (nothing here for you to act on):';
    private static final String AGENT_PART = AntsuranceClaimsAssistantCoverage.AGENT_PART;
    /** Kept beside the run: which of the agent's requests the finding on the claim came from. */
    private static final String FINDING_USE = 'findingUse';
    // Enough to hold a session's first message, which is all that says whose session it is.
    private static final Integer FIRST_EVENTS = 20;
    // Reading a document is itself a long call to Claude, so the look at the session before it is kept short.
    private static final Integer QUICK_LOOK_MS = 5000;
    // Left free in the claim's field for what is added to the check as it is stored.
    private static final Integer ROOM_MARGIN = 200;
    private static final List<Integer> DETAIL_CUTS = new List<Integer>{ 160, 60, 0 };
    private static final Integer STEPS_DROPPED_AT_A_TIME = 10;

    @TestVisible
    private static final String NOT_SET_UP = 'The coverage agent is not set up in this org yet. Ask an administrator to run its setup step.';
    @TestVisible
    private static final String WRONG_CLAIM = 'That investigation was started for another claim.';
    @TestVisible
    private static final String NO_FINDING = 'The coverage agent finished without recording a finding. Run it again.';
    @TestVisible
    private static final String OVER_BUDGET = 'The coverage agent reached the spending limit for one investigation before it finished. Run it again, or use "Check coverage".';
    @TestVisible
    private static final String GAVE_UP = 'The coverage agent stopped before it finished. Run it again.';
    @TestVisible
    private static final String NOT_STARTED = 'That investigation has not started yet. Try again in a moment.';
    @TestVisible
    private static final String NOT_ASKED = 'The coverage agent did not ask for that document in this investigation.';
    @TestVisible
    private static final String NOT_SAVED = 'The coverage agent reached a finding, but it could not be saved on this claim. ';
    @TestVisible
    private static final String CHECK_ACCESS = 'Check that you can edit this claim.';
    @TestVisible
    private static final String REPLACED = 'The coverage agent finished, but its finding is not the check on this claim: another check was saved after it. Run the agent again to have it look afresh.';
    @TestVisible
    private static final String ENDING_NOT_SAVED = 'The finding is on the claim, but how the agent finished could not be saved with it. ';
    private static final String SUPERSEDED = 'Not recorded. You called record_finding more than once at the same time; only your last call is kept.';

    /**
     * Stands in, in a test, for a claim that cannot be saved: no edit access, a validation rule, a
     * locked row. A test cannot arrange any of those for real, and what happens next is the point.
     */
    @TestVisible
    private static String saveFailsWith;

    /**
     * @description One thing the agent did, in plain words.
     */
    public class Step {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        /** What it found there. Blank while the step is still running. */
        @AuraEnabled
        public String detail;
        /** done, working or failed. */
        @AuraEnabled
        public String state = WORKING;
    }

    /**
     * @description A document the agent has asked to read, which the page runs in a request of its own.
     */
    public class Reading {
        @AuraEnabled
        public String toolUseId;
        @AuraEnabled
        public String document;
        @AuraEnabled
        public String label;
    }

    /**
     * @description Where one investigation stands.
     */
    public class Run {
        @AuraEnabled
        public String sessionId;
        /** working, done or failed. */
        @AuraEnabled
        public String status = WORKING;
        /** What the agent last said it is doing, in its own words. */
        @AuraEnabled
        public String saying;
        @AuraEnabled
        public List<Step> steps = new List<Step>();
        /** Documents waiting to be read; the page calls readDocument for each. */
        @AuraEnabled
        public List<Reading> toRead = new List<Reading>();
        /** True once the finding is stored on the claim. Never true for a finding that was not saved. */
        @AuraEnabled
        public Boolean recorded = false;
        /** The agent's closing words to the adjuster. */
        @AuraEnabled
        public String closing;
        /** Why it stopped, for the person, when status is failed. */
        @AuraEnabled
        public String problem;
        @AuraEnabled
        public Boolean retryable = false;
        @AuraEnabled
        public Integer seconds;
        @AuraEnabled
        public Datetime finishedAt;
    }

    /**
     * @description What the claim page needs before anyone presses anything.
     */
    public class Standing {
        /** True when the agent is set up in this org. The page hides it otherwise. */
        @AuraEnabled
        public Boolean ready = false;
        /** How the agent worked, when the coverage check now on the claim is the agent's. */
        @AuraEnabled
        public Run lastRun;
    }

    /**
     * @description Whether the agent can be offered on this claim, and how it worked last time if
     * the check on the claim is its own.
     * @param caseId The claim on screen
     * @return Whether it is set up, and the last run when there is one
     */
    @AuraEnabled
    public static Standing getStanding(Id caseId) {
        Standing standing = new Standing();
        standing.ready = isReady();
        try {
            Map<String, Object> part = agentPart(storedOn(caseId));
            if (part != null) {
                standing.lastRun = (Run) JSON.deserialize(JSON.serialize(part.get('run')), Run.class);
            }
        } catch (Exception e) {
            // An older or unreadable record just means there is no last run to show.
            standing.lastRun = null;
        }
        return standing;
    }

    /**
     * @description Starts an investigation of the claim's coverage question.
     * @param caseId The claim on screen
     * @return The run, with the session to poll
     * @throws AuraHandledException when the agent is not set up, the record is not a claim with a
     * policy, or Managed Agents cannot be reached
     */
    @AuraEnabled
    public static Run start(Id caseId) {
        try {
            Antsurance_Coverage_Agent__c ids = Antsurance_Coverage_Agent__c.getOrgDefaults();
            if (!isReady()) {
                throw handled(NOT_SET_UP);
            }
            // Reads the claim as this person, and refuses a service request or a claim with no policy before anything is sent.
            AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceCoverageAgentTools.facts(caseId);
            String claimLine = facts.claimLines[0].substringAfter('] ');
            // The keys as they stand now go with the session, so a file or a note added while the agent works cannot renumber them.
            String keys = AntsuranceCoverageAgentTools.keysFor(caseId);
            Integer budget = ids.Session_Budget_Cents__c == null ? AntsuranceCoverageAgentSetup.BUILT_IN_BUDGET_CENTS : ids.Session_Budget_Cents__c.intValue();
            String task =
                'Work the coverage question on claim ' + claimLine + '. ' + CLAIM_MARKER + caseId + '. Today is ' + Datetime.now().format('EEEE, MMM d, yyyy') + '.\n\n' +
                'Does the policy respond to this loss? Use your tools to read the file: start with the claim and the policy, then read whatever else bears on the answer. ' +
                'Follow your coverage method. When you have the answer, call record_finding once, then tell the adjuster in two short sentences what you found and what is still open.' +
                (keys == null ? '' : '\n\n' + KEYS_MARKER + '\n' + keys);
            Map<String, Object> session = AntsuranceCoverageAgentApi.post(
                '/v1/sessions',
                '{"agent":' + JSON.serialize(ids.Agent_Id__c) +
                    ',"environment_id":' + JSON.serialize(ids.Environment_Id__c) +
                    ',"title":' + JSON.serialize(('Coverage on claim ' + claimLine).left(200)) +
                    ',"metadata":{"app":"antsurance-crm","record":' + JSON.serialize(String.valueOf(caseId)) + '}' +
                    ',"budget":{"type":"limit","max_list_cost":{"amount":' + JSON.serialize(String.valueOf(budget)) + ',"currency":"USD"}}' +
                    ',"initial_events":[{"type":"user.message","content":[{"type":"text","text":' + JSON.serialize(task) + '}]}]}'
            );
            Run run = new Run();
            run.sessionId = (String) session.get('id');
            return run;
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            throw handled(e.getMessage());
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Moves an investigation along: reads what the agent has done, runs the tools it
     * is waiting on, and stores its finding when it records one. The finding is saved before the
     * agent is told it is recorded, and the telling waits for the next poll.
     * @param caseId The claim on screen
     * @param sessionId The session start returned
     * @return Where the investigation stands now
     * @throws AuraHandledException when the session is not this claim's, Managed Agents cannot be
     * reached, or the finding could not be saved (in which case the next poll tries again)
     */
    @AuraEnabled
    public static Run poll(Id caseId, String sessionId) {
        try {
            Trace trace = read(caseId, sessionId, null);
            Run run = trace.run;
            if (!trace.isBound) {
                // Nothing is run for a session that has not yet shown which claim it is for.
                return run;
            }

            // Every callout first: answer the tools the agent is waiting on.
            List<String> answers = new List<String>();
            ToolUse recording = trace.lastWaiting(AntsuranceCoverageAgentTools.RECORD);
            Map<String, Object> kept = recording == null ? null : keptFor(caseId, sessionId, recording.id);
            AntsuranceCoverageAgentTools.Result toSave;
            for (ToolUse waiting : trace.waiting) {
                if (AntsuranceCoverageAgentTools.isSlow(waiting.name)) {
                    Reading reading = new Reading();
                    reading.toolUseId = waiting.id;
                    reading.document = String.valueOf(waiting.input.get('document'));
                    reading.label = waiting.step.label;
                    run.toRead.add(reading);
                    continue;
                }
                AntsuranceCoverageAgentTools.Result result;
                if (waiting.name == AntsuranceCoverageAgentTools.RECORD && waiting !== recording) {
                    // Two findings asked for at once cannot both be the one on the claim.
                    result = new AntsuranceCoverageAgentTools.Result();
                    result.isError = true;
                    result.found = SUPERSEDED;
                    result.text = SUPERSEDED;
                } else if (waiting === recording && kept != null) {
                    // An earlier poll saved this finding. Only now, with it on the claim, is the agent told so.
                    result = AntsuranceCoverageAgentTools.acknowledged(foundIn(kept));
                    run.recorded = true;
                } else {
                    result = AntsuranceCoverageAgentTools.run(caseId, waiting.name, waiting.input);
                    if (result.check != null) {
                        // A finding fit to store. It is saved below and the agent is left waiting: it hears
                        // "recorded" on the next poll, once that is true.
                        toSave = result;
                        continue;
                    }
                }
                answers.add(answer(waiting.id, result));
                settle(waiting.step, result);
            }
            if (!answers.isEmpty()) {
                AntsuranceCoverageAgentApi.post(AntsuranceCoverageAgentApi.eventsPath(sessionId), '{"events":[' + String.join(answers, ',') + ']}');
            }

            // Saves last: a callout cannot follow a save in one transaction.
            if (toSave != null) {
                settle(recording.step, toSave);
                save(caseId, run, trace, toSave.check, recording.id);
                run.recorded = true;
            } else if (run.status == DONE && !finish(caseId, run, trace.usage)) {
                // The agent was told its finding was recorded, and it was, but the check on the claim
                // now is not that finding. Saying "done" would put the agent's name on someone else's check.
                run.status = FAILED;
                run.recorded = false;
                run.retryable = true;
                run.problem = REPLACED;
                run.closing = null;
            }
            if (!answers.isEmpty() || !run.toRead.isEmpty() || toSave != null) {
                run.status = WORKING;
            }
            return run;
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            throw handled(e.getMessage());
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Reads one document the agent asked for and hands it back. A request of its own,
     * because reading a file is itself a call to Claude and can take most of the time one request
     * is allowed. Which document is read is what the session says the agent asked for, never what
     * the page says, and only for a session that is this claim's.
     * @param caseId The claim on screen
     * @param sessionId The session
     * @param toolUseId The agent's request, from Run.toRead
     * @throws AuraHandledException when the session is not this claim's, the agent made no such
     * request, or the result cannot be handed back
     */
    @AuraEnabled
    public static void readDocument(Id caseId, String sessionId, String toolUseId) {
        try {
            // A short look at the session first, so the reading still has nearly all of this request's callout time.
            Trace trace = read(caseId, sessionId, QUICK_LOOK_MS);
            if (!trace.isBound) {
                throw handled(NOT_STARTED);
            }
            ToolUse asked = trace.usesById.get(toolUseId);
            if (asked == null || asked.name != AntsuranceCoverageAgentTools.READ_DOCUMENT) {
                throw handled(NOT_ASKED);
            }
            if (asked.isAnswered) {
                // Another tab got there first. There is nothing left to hand back.
                return;
            }
            AntsuranceCoverageAgentTools.Result result = AntsuranceCoverageAgentTools.run(caseId, AntsuranceCoverageAgentTools.READ_DOCUMENT, asked.input);
            AntsuranceCoverageAgentApi.post(AntsuranceCoverageAgentApi.eventsPath(sessionId), '{"events":[' + answer(toolUseId, result) + ']}');
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Stops an investigation the person has cancelled. Only the claim's own session
     * can be stopped from the claim.
     * @param caseId The claim on screen
     * @param sessionId The session
     * @throws AuraHandledException when the session is not this claim's or cannot be reached
     */
    @AuraEnabled
    public static void stop(Id caseId, String sessionId) {
        try {
            String path = AntsuranceCoverageAgentApi.eventsPath(sessionId);
            Map<String, Object> listed = AntsuranceCoverageAgentApi.get(path + '?limit=' + FIRST_EVENTS + '&order=asc');
            if (!bind(caseId, listed.get('data') instanceof List<Object> ? (List<Object>) listed.get('data') : new List<Object>())) {
                throw handled(NOT_STARTED);
            }
            AntsuranceCoverageAgentApi.post(path, '{"events":[{"type":"user.interrupt"}]}');
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Whether the agent is set up in this org.
     * @return True when the setup step has stored an agent and an environment
     */
    public static Boolean isReady() {
        Antsurance_Coverage_Agent__c ids = Antsurance_Coverage_Agent__c.getOrgDefaults();
        return String.isNotBlank(ids?.Agent_Id__c) && String.isNotBlank(ids?.Environment_Id__c);
    }

    // ------------------------------------------------------------ reading a session

    /** A tool the agent has asked for. */
    private class ToolUse {
        String id;
        String name;
        Map<String, Object> input;
        Step step;
        String resultText;
        Boolean isAnswered = false;
    }

    /** One session's events, read into what the page shows and what is still to do. */
    private class Trace {
        Run run = new Run();
        List<ToolUse> uses = new List<ToolUse>();
        List<ToolUse> waiting = new List<ToolUse>();
        Map<String, ToolUse> usesById = new Map<String, ToolUse>();
        /** True once the session's first message has been read and names this claim. */
        Boolean isBound = false;
        /** What the session has used so far, from its latest usage event: tokens, list cost and active seconds. */
        Map<String, Object> usage;

        /** The newest request for a tool that is still unanswered, or null. */
        ToolUse lastWaiting(String name) {
            ToolUse last;
            for (ToolUse use : waiting) {
                if (use.name == name) {
                    last = use;
                }
            }
            return last;
        }

        /** What the agent read beyond the record, one line each, for the check's "also taken into account". */
        String evidence() {
            List<String> lines = new List<String>();
            for (ToolUse use : uses) {
                Boolean isEvidence = use.name == AntsuranceCoverageAgentTools.READ_DOCUMENT || use.name == AntsuranceCoverageAgentTools.READ_PHOTOS;
                if (isEvidence && use.isAnswered && use.step.state == DONE && String.isNotBlank(use.step.detail)) {
                    lines.add((use.step.label.removeStart('Read ').capitalize() + ': ' + use.step.detail).abbreviate(MAX_EVIDENCE_LINE));
                }
            }
            return lines.isEmpty() ? null : String.join(lines, '\n');
        }
    }

    /**
     * Whether these events open with a message that names this claim. That message also carries the
     * keys the session was started with, which are handed to the tools here, before any of them runs.
     * False when no message is listed yet; a message that names another claim is refused outright.
     */
    private static Boolean bind(Id caseId, List<Object> listed) {
        for (Object item : listed) {
            Map<String, Object> event = (Map<String, Object>) item;
            if (event.get('type') == 'user.message') {
                // The first message carries the claim the person started this for.
                String task = text(event);
                if (!task.contains(CLAIM_MARKER + caseId)) {
                    throw handled(WRONG_CLAIM);
                }
                AntsuranceCoverageAgentTools.holdKeys(task.substringAfter(KEYS_MARKER));
                return true;
            }
        }
        return false;
    }

    private static Trace read(Id caseId, String sessionId, Integer timeoutMs) {
        List<Object> listed = events(sessionId, timeoutMs);
        Trace trace = new Trace();
        trace.run.sessionId = sessionId;
        // Whose session this is comes first: no step is named and no tool is run for another claim's session.
        trace.isBound = bind(caseId, listed);
        Map<String, ToolUse> usesById = trace.usesById;
        String lastStop;
        Boolean isRunning = true;
        String lastMessage;
        Integer builtIn = 0;
        Datetime firstAt;
        Datetime lastAt;

        for (Object item : listed) {
            Map<String, Object> event = (Map<String, Object>) item;
            String type = (String) event.get('type');
            Datetime at = moment(event.get('processed_at'));
            firstAt = firstAt ?? at;
            lastAt = at ?? lastAt;
            if (type == 'session.usage' && event.get('usage') instanceof Map<String, Object>) {
                trace.usage = (Map<String, Object>) event.get('usage');
            }
            if (type == 'agent.custom_tool_use') {
                ToolUse use = new ToolUse();
                use.id = (String) event.get('id');
                use.name = (String) event.get('name');
                use.input = event.get('input') instanceof Map<String, Object> ? (Map<String, Object>) event.get('input') : new Map<String, Object>();
                use.step = new Step();
                use.step.key = use.id;
                use.step.label = AntsuranceCoverageAgentTools.label(use.name, use.input, caseId);
                usesById.put(use.id, use);
                trace.uses.add(use);
                trace.run.steps.add(use.step);
            } else if (type == 'user.custom_tool_result') {
                ToolUse use = usesById.get((String) event.get('custom_tool_use_id'));
                if (use != null) {
                    use.isAnswered = true;
                    use.resultText = text(event);
                    Boolean isError = event.get('is_error') == true;
                    use.step.state = isError ? FAILED : DONE;
                    use.step.detail = found(use.resultText);
                    if (use.name == AntsuranceCoverageAgentTools.RECORD && !isError) {
                        trace.run.recorded = true;
                    }
                }
            } else if (type == 'agent.tool_use') {
                // The only built-in tool that is on is the file reader, which is how the agent opens its skill.
                builtIn++;
                if (builtIn == 1) {
                    Step step = new Step();
                    step.key = (String) event.get('id');
                    step.label = 'Opened its coverage method';
                    step.detail = 'The antsurance-coverage skill';
                    step.state = DONE;
                    trace.run.steps.add(step);
                }
            } else if (type == 'agent.thread_context_compacted') {
                Step step = new Step();
                step.key = (String) event.get('id');
                step.label = 'Condensed what it had read so far';
                step.detail = 'Managed Agents compacted the context to make room';
                step.state = DONE;
                trace.run.steps.add(step);
            } else if (type == 'agent.message') {
                lastMessage = text(event);
            } else if (type == 'session.status_running' || type == 'session.status_rescheduled') {
                isRunning = true;
                lastStop = null;
            } else if (type == 'session.status_idle') {
                isRunning = false;
                Object reason = event.get('stop_reason');
                lastStop = reason instanceof Map<String, Object> ? (String) ((Map<String, Object>) reason).get('type') : null;
            } else if (type == 'session.status_terminated') {
                isRunning = false;
                lastStop = 'terminated';
            }
        }

        for (ToolUse use : trace.uses) {
            if (!use.isAnswered) {
                trace.waiting.add(use);
            }
        }
        Run run = trace.run;
        // How long the person waited, start to finish, not how long the model was busy.
        run.seconds = firstAt == null || lastAt == null ? null : ((lastAt.getTime() - firstAt.getTime()) / 1000).intValue();
        run.saying = String.isBlank(lastMessage) ? null : lastMessage.abbreviate(600);
        if (!trace.waiting.isEmpty() || isRunning || lastStop == null || lastStop == 'requires_action') {
            run.status = WORKING;
        } else if (lastStop == 'end_turn' && run.recorded) {
            run.status = DONE;
            run.closing = run.saying;
        } else {
            run.status = FAILED;
            run.retryable = true;
            run.problem = lastStop == 'end_turn' ? NO_FINDING : lastStop == 'budget_reached' ? OVER_BUDGET : GAVE_UP;
        }
        return trace;
    }

    /** Every event of the session, oldest first. A timeout, when given, is how long each page may take. */
    private static List<Object> events(String sessionId, Integer timeoutMs) {
        List<Object> all = new List<Object>();
        String path = AntsuranceCoverageAgentApi.eventsPath(sessionId);
        String page;
        for (Integer turn = 0; turn < MAX_EVENT_PAGES; turn++) {
            String query = path + '?limit=1000&order=asc' + (page == null ? '' : '&page=' + EncodingUtil.urlEncode(page, 'UTF-8'));
            Map<String, Object> listed = timeoutMs == null ? AntsuranceCoverageAgentApi.get(query) : AntsuranceCoverageAgentApi.get(query, timeoutMs);
            if (listed.get('data') instanceof List<Object>) {
                all.addAll((List<Object>) listed.get('data'));
            }
            page = (String) listed.get('next_page');
            if (String.isBlank(page)) {
                break;
            }
        }
        return all;
    }

    // ------------------------------------------------------------ storing

    /**
     * Saves the finding on the claim, with how the agent worked beside it. The agent has not been
     * told anything yet: if this fails the person is told why, the tool stays unanswered, and the
     * next poll comes back here with the same finding from the session.
     */
    private static void save(Id caseId, Run run, Trace trace, AntsuranceClaimsAssistantCoverage.Check finding, String toolUseId) {
        try {
            if (Test.isRunningTest() && saveFailsWith != null) {
                throw new AntsuranceClaimsAssistantCoverage.CoverageException(saveFailsWith);
            }
            AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceCoverageAgentTools.facts(caseId);
            AntsuranceClaimsAssistantCoverage.withExtra(facts, trace.evidence());
            finding.extraFacts = facts.extraFacts;
            Integer space = room(new Map<String, Object>{ 'check' => finding, 'facts' => facts.snapshot });
            AntsuranceClaimsAssistantCoverage.store(caseId, finding, facts, new Map<String, Object>{ AGENT_PART => fitted(part(run, trace.usage, toolUseId), space) });
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            throw handled(NOT_SAVED + e.getMessage());
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            // Whatever else stopped the save, the person hears that it did not happen, never a quiet success.
            throw handled(NOT_SAVED + CHECK_ACCESS);
        }
    }

    /**
     * Adds how the run ended to what is stored beside the finding, once.
     * Returns false when the check on the claim is not this session's finding, so the caller can say so.
     */
    private static Boolean finish(Id caseId, Run run, Map<String, Object> usage) {
        Map<String, Object> stored = storedOn(caseId);
        Map<String, Object> before = agentPart(stored);
        Map<String, Object> ranBefore = before?.get('run') instanceof Map<String, Object> ? (Map<String, Object>) before.get('run') : null;
        // Only the session that wrote the check on the claim may add to it.
        if (ranBefore == null || ranBefore.get('sessionId') != run.sessionId) {
            return false;
        }
        // And only once.
        if (ranBefore.get('finishedAt') != null) {
            return true;
        }
        run.finishedAt = Datetime.now();
        stored.remove(AGENT_PART);
        stored.put(AGENT_PART, fitted(part(run, usage, (String) before.get(FINDING_USE)), room(stored)));
        try {
            update as user new Case(Id = caseId, Coverage_Read__c = JSON.serialize(stored));
        } catch (Exception e) {
            run.finishedAt = null;
            throw handled(ENDING_NOT_SAVED + (e instanceof DmlException ? ((DmlException) e).getDmlMessage(0) : CHECK_ACCESS));
        }
        return true;
    }

    /** What is kept beside the finding: how the agent worked, what the session cost, and which request the finding came from. */
    private static Map<String, Object> part(Run run, Map<String, Object> usage, String toolUseId) {
        Map<String, Object> part = new Map<String, Object>{ 'run' => run, 'harness' => 'Claude Managed Agents', 'skill' => 'antsurance-coverage', 'model' => AntsuranceAiSettings.model() };
        if (toolUseId != null) {
            part.put(FINDING_USE, toolUseId);
        }
        Object cost = usage?.get('list_cost');
        if (cost instanceof Map<String, Object>) {
            part.put('listCostCents', ((Map<String, Object>) cost).get('amount'));
        }
        if (usage != null) {
            part.put('activeSeconds', usage.get('active_seconds'));
        }
        return part;
    }

    /** How many characters the claim's field has left for the agent's part, beside what else is stored there. */
    private static Integer room(Map<String, Object> beside) {
        return AntsuranceClaimsAssistantCoverage.maxStored() - JSON.serialize(beside).length() - ROOM_MARGIN;
    }

    /**
     * The agent's part, cut to fit the room it has. A long investigation has more steps than the
     * claim's field can hold in full: what each step found is shortened, then dropped, and only
     * then do the oldest steps go. The run handed back to the page is left whole.
     */
    private static Map<String, Object> fitted(Map<String, Object> part, Integer space) {
        if (JSON.serialize(part).length() <= space) {
            return part;
        }
        Run kept = (Run) JSON.deserialize(JSON.serialize(part.get('run')), Run.class);
        part.put('run', kept);
        for (Integer cut : DETAIL_CUTS) {
            for (Step step : kept.steps) {
                step.detail = cut == 0 ? null : step.detail?.abbreviate(cut);
            }
            if (JSON.serialize(part).length() <= space) {
                return part;
            }
        }
        while (kept.steps.size() > STEPS_DROPPED_AT_A_TIME && JSON.serialize(part).length() > space) {
            for (Integer dropped = 0; dropped < STEPS_DROPPED_AT_A_TIME; dropped++) {
                kept.steps.remove(0);
            }
        }
        return part;
    }

    /** What the claim's coverage field holds, as a map, or null when it is empty or was not written here. */
    private static Map<String, Object> storedOn(Id caseId) {
        List<Case> claims = [SELECT Coverage_Read__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
        if (claims.isEmpty() || String.isBlank(claims[0].Coverage_Read__c)) {
            return null;
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(claims[0].Coverage_Read__c);
        } catch (Exception e) {
            return null;
        }
    }

    /** The agent's part of what is stored on the claim, when the check there is the agent's. */
    private static Map<String, Object> agentPart(Map<String, Object> stored) {
        Object part = stored?.get(AGENT_PART);
        return part instanceof Map<String, Object> ? (Map<String, Object>) part : null;
    }

    /** What is stored on the claim, when it is the finding this session saved from this request of the agent's. Null otherwise. */
    private static Map<String, Object> keptFor(Id caseId, String sessionId, String toolUseId) {
        Map<String, Object> stored = storedOn(caseId);
        Map<String, Object> part = agentPart(stored);
        Map<String, Object> ran = part?.get('run') instanceof Map<String, Object> ? (Map<String, Object>) part.get('run') : null;
        return ran != null && ran.get('sessionId') == sessionId && part.get(FINDING_USE) == toolUseId ? stored : null;
    }

    /** The stored finding in a few words, as the agent is told it. */
    private static String foundIn(Map<String, Object> stored) {
        Map<String, Object> check = stored.get('check') instanceof Map<String, Object> ? (Map<String, Object>) stored.get('check') : new Map<String, Object>();
        return AntsuranceCoverageAgentTools.found((String) check.get('verdict'), (String) check.get('respondingLabel'));
    }

    // ------------------------------------------------------------ helpers

    private static String answer(String toolUseId, AntsuranceCoverageAgentTools.Result result) {
        return '{"type":"user.custom_tool_result","custom_tool_use_id":' + JSON.serialize(toolUseId) +
            ',"content":[{"type":"text","text":' + JSON.serialize(result.text) + '}]' +
            ',"is_error":' + (result.isError == true ? 'true' : 'false') + '}';
    }

    private static void settle(Step step, AntsuranceCoverageAgentTools.Result result) {
        step.state = result.isError == true ? FAILED : DONE;
        step.detail = result.found?.abbreviate(MAX_DETAIL);
    }

    /** The plain line a tool result opens with. */
    private static String found(String resultText) {
        if (String.isBlank(resultText)) {
            return null;
        }
        String first = resultText.substringBefore('\n').removeStart('FOUND: ').removeEnd('.');
        return first.abbreviate(MAX_DETAIL);
    }

    /** When an event happened, from its ISO timestamp. Null when it carries none yet. */
    private static Datetime moment(Object stamp) {
        if (!(stamp instanceof String) || String.isBlank((String) stamp)) {
            return null;
        }
        try {
            // The API stamps to the microsecond; Apex reads to the millisecond.
            return (Datetime) JSON.deserialize(JSON.serialize(((String) stamp).replaceFirst('(\\.\\d{3})\\d*Z$', '$1Z')), Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }

    /** The text of an event's content. */
    private static String text(Map<String, Object> event) {
        List<String> parts = new List<String>();
        if (event.get('content') instanceof List<Object>) {
            for (Object block : (List<Object>) event.get('content')) {
                if (block instanceof Map<String, Object> && ((Map<String, Object>) block).get('text') != null) {
                    parts.add(String.valueOf(((Map<String, Object>) block).get('text')));
                }
            }
        }
        return String.join(parts, '\n');
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
