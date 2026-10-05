/**
 * @description The "Claude at work" page: the Claude work in this org as one job per row, each with
 * its own reading and its own tools: it reads, works something out, prepares it, and a person decides.
 *
 * The page says how each job really runs, because most of them are not agents. A job is an agent
 * only where a harness runs it (a tool loop, context management and Skills run by Claude Managed
 * Agents). The chat is a tool loop built here on the Messages API. Everything else is a single call
 * or a fixed pipeline of calls that returns a structured answer.
 *
 * What a job is, reads and may do is written here from the classes that do the work, so the page
 * and the code can be checked against each other. What it may do alone comes from the desk's own
 * settings where the desk has them. What it did is counted from records only: the desk's work rows
 * and the dates the claim features stamp when they run. A job whose runs leave no record shows no
 * count. How it scored comes from Antsurance_Agent_Eval__mdt, one record per test on file.
 *
 * The page reads. It creates and changes nothing.
 */
public with sharing class AntsuranceAgentsController {
    private static final Integer WEEK_DAYS = 7;
    private static final Integer MAX_ROWS = 500;
    private static final Integer MAX_RECENT = 15;
    private static final String ALONE = 'alone';
    private static final String PERSON = 'person';
    private static final String OFF = 'off';
    private static final String PORTAL_CLASS = 'AntsurancePortalClaude';
    private static final String COVERAGE_AGENT_CLASS = 'AntsuranceCoverageAgent';
    // How a job runs. Only MANAGED is an agent: a harness runs its loop.
    private static final String MANAGED = 'managed';
    private static final String TOOL_LOOP = 'loop';
    private static final String PIPELINE = 'pipeline';
    private static final String SINGLE = 'single';
    private static final Map<String, String> RUN_LABELS = new Map<String, String>{
        MANAGED => 'Agent on Claude Managed Agents',
        TOOL_LOOP => 'Tool loop built here',
        PIPELINE => 'Pipeline',
        SINGLE => 'Single call'
    };
    private static final Integer TRACES_TO_SCAN = 20;

    // Set by a test to stand in for the stored eval records, so no test depends on what an org holds.
    @TestVisible
    private static List<Antsurance_Agent_Eval__mdt> evalStandIn;
    @TestVisible
    private static Boolean pretendPortalInstalled;
    /** Set by a test to stand in for the org: ready, built or absent. */
    @TestVisible
    private static String coverageAgentStandIn;
    private static final String READY = 'ready';
    private static final String BUILT = 'built';
    private static final String ABSENT = 'absent';
    private static final String COVERAGE_AGENT_SETTING = 'Antsurance_Coverage_Agent__c';

    public class Roster {
        @AuraEnabled
        public List<Agent> agents = new List<Agent>();
        @AuraEnabled
        public String model;
        @AuraEnabled
        public Boolean fastMode;
        /** Pieces of work on record today and in the last seven days, across the agents that leave a record. */
        @AuraEnabled
        public Integer today = 0;
        @AuraEnabled
        public Integer week = 0;
        @AuraEnabled
        public Integer waiting = 0;
        @AuraEnabled
        public Integer tested = 0;
        /** How many jobs run on an agent harness. */
        @AuraEnabled
        public Integer harnessed = 0;
    }

    public class Agent {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String job;
        @AuraEnabled
        public String icon;
        @AuraEnabled
        public String tint;
        @AuraEnabled
        public List<String> reads = new List<String>();
        @AuraEnabled
        public List<String> tools = new List<String>();
        @AuraEnabled
        public List<String> prepares = new List<String>();
        /** Read, work out, prepare, person: the loop in this agent's own words. */
        @AuraEnabled
        public List<String> steps = new List<String>();
        @AuraEnabled
        public List<Rule> rules = new List<Rule>();
        @AuraEnabled
        public List<Place> places = new List<Place>();
        /** How a person sets this job going, and a record to try it on now. */
        @AuraEnabled
        public Start start;
        /** False when this agent's runs leave nothing on a record to count. */
        @AuraEnabled
        public Boolean isCounted = false;
        @AuraEnabled
        public String notCountedWhy;
        @AuraEnabled
        public Integer today = 0;
        @AuraEnabled
        public Integer week = 0;
        @AuraEnabled
        public Integer waiting = 0;
        /** Pieces a person decided in the last seven days: null where the desk does not record a decision. */
        @AuraEnabled
        public Integer approved;
        @AuraEnabled
        public Integer dismissed;
        @AuraEnabled
        public List<Recent> recent = new List<Recent>();
        @AuraEnabled
        public List<Eval> tests = new List<Eval>();
        /** managed, loop, pipeline or single: how the job really runs. Only managed is an agent. */
        @AuraEnabled
        public String runs;
        @AuraEnabled
        public String runsLabel;
        @AuraEnabled
        public String runsLine;
        /** For a job with no harness: what moving it to one would add. A candidate, not a plan. */
        @AuraEnabled
        public String harnessLine;
        /** For a job on a harness: the Skill that holds its method, and the tools the harness may call. */
        @AuraEnabled
        public String skill;
        @AuraEnabled
        public List<String> harnessTools = new List<String>();
        /** The newest run by the agent that is on record, with its steps; null when none is. */
        @AuraEnabled
        public Recent traceOf;
        @AuraEnabled
        public List<String> trace = new List<String>();
    }

    public class Rule {
        @AuraEnabled
        public String what;
        /** alone, person or off. */
        @AuraEnabled
        public String mode;
        @AuraEnabled
        public String detail;
        /** True when the setting can be changed on Claude's desk. */
        @AuraEnabled
        public Boolean isSetting = false;
    }

    public class Place {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String url;
    }

    /** How a job is started. Nothing here starts it: the button only goes to where a person does. */
    public class Start {
        /** Who presses what, and where. */
        @AuraEnabled
        public String how;
        /** The button: names the record or page it opens. Null with nowhere to go. */
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String url;
        /** What to press once there. */
        @AuraEnabled
        public String onceThere;
    }

    public class Recent implements Comparable {
        @AuraEnabled
        public String what;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String url;
        @AuraEnabled
        public Datetime happenedAt;
        @AuraEnabled
        public String outcome;

        public Integer compareTo(Object other) {
            Datetime theirs = ((Recent) other).happenedAt;
            return happenedAt == theirs ? 0 : happenedAt > theirs ? -1 : 1;
        }
    }

    public class Eval {
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String result;
        @AuraEnabled
        public String measured;
        @AuraEnabled
        public String caveat;
        @AuraEnabled
        public Date runOn;
        @AuraEnabled
        public String source;
    }

    /**
     * @description The agents, what each may do, what each did and how each scored.
     * @return The roster
     */
    @AuraEnabled
    public static Roster getRoster() {
        Roster roster = new Roster();
        roster.model = AntsuranceAiSettings.model();
        roster.fastMode = AntsuranceAiSettings.useFastMode();
        roster.agents = agents();
        Map<String, Agent> byKey = new Map<String, Agent>();
        for (Agent agent : roster.agents) {
            byKey.put(agent.key, agent);
        }
        countDeskWork(byKey);
        countClaimWork(byKey);
        findCoverageAgentTrace(byKey.get('coverage'));
        // After the trace is found: the coverage job is tried on the claim the agent last investigated.
        addStarts(byKey);
        addTests(byKey);
        for (Agent agent : roster.agents) {
            agent.recent.sort();
            while (agent.recent.size() > MAX_RECENT) {
                agent.recent.remove(agent.recent.size() - 1);
            }
            if (agent.isCounted) {
                roster.today += agent.today;
                roster.week += agent.week;
            }
            roster.waiting += agent.waiting;
            agent.runsLabel = RUN_LABELS.get(agent.runs);
            roster.harnessed += agent.runs == MANAGED ? 1 : 0;
            roster.tested += agent.tests.isEmpty() ? 0 : 1;
        }
        return roster;
    }

    // ------------------------------------------------------------------ who the agents are

    private static List<Agent> agents() {
        List<Agent> all = new List<Agent>();

        Agent intake = agent('intake', 'First notice of loss', 'Turns what a customer said into a claim that is ready to file.', 'utility:incoming_call', 'clay');
        intake.reads = new List<String>{ 'The email, web message or call notes a handler pastes in', 'The customer\'s policies, and who and what is on them' };
        intake.tools = new List<String>{ 'Looks up the customer\'s policies and contacts', 'Matches the loss to the policy that would respond' };
        intake.prepares = new List<String>{ 'A draft claim: policy, date and type of loss, severity, location and estimate', 'A list of what is still missing' };
        intake.steps = new List<String>{ 'Reads the message', 'Finds the policy and the facts of the loss', 'Fills in the claim', 'The handler checks it and files it' };
        intake.rules.add(rule('Filing the claim', PERSON, 'It only drafts. The handler reviews the draft, and the claim is created as that person.'));
        intake.places.add(place('Policies: File a Claim with Claude', '/lightning/o/Policy__c/list'));
        intake.notCountedWhy = 'A claim filed from a draft looks like any other claim, so its runs cannot be counted from the records.';
        how(intake, SINGLE, 'One call. It is handed the message and the customer\'s policies and returns a draft claim as structured data.', 'It could look up prior claims and the policy\'s own wording before drafting, instead of being handed them.');
        all.add(intake);

        Agent coverage = agent('coverage', 'Claims coverage', 'Reads a claim against its policy and says whether the policy responds.', 'utility:shield', 'amber');
        coverage.reads = new List<String>{
            'The claim, its file notes and what the photos and documents showed',
            'The policy term, coverages, endorsements and exclusions',
            'Who and what is insured on the policy'
        };
        coverage.tools = new List<String>{ 'Checks the date of loss against the policy term', 'Works out what is payable: the estimate less the deductible, within the limit' };
        coverage.prepares = new List<String>{ 'A verdict with the coverage that responds', 'What each finding rests on, what to ask, and what would change it' };
        coverage.steps = new List<String>{ 'Reads the claim and the policy', 'Tests the loss against each coverage and exclusion', 'Writes its read with the reasons', 'The adjuster confirms coverage' };
        coverage.rules.add(rule('Storing its read on the claim', ALONE, 'When an adjuster asks for a coverage check, the read is kept on the claim with its date.'));
        coverage.rules.add(rule('Confirming coverage', PERSON, 'The adjuster decides. The claim records who confirmed and when.'));
        coverage.places.add(place('Claims: Coverage check', '/lightning/o/Case/list'));
        coverage.isCounted = true;
        String coverageAgent = coverageAgentState();
        if (coverageAgent == READY) {
            how(
                coverage,
                MANAGED,
                'Claude Managed Agents runs the tool loop, the context and the compaction. Its tools run in Salesforce as the signed-in user. The quick check beside it is still a single call.',
                null
            );
            coverage.skill = 'antsurance-coverage: the method an adjuster follows on a coverage question, with no policy wording in it.';
            coverage.harnessTools = new List<String>{
                'read_claim', 'read_policy', 'read_file_notes', 'list_documents', 'read_document', 'read_photo_assessment', 'find_prior_claims', 'record_finding'
            };
            coverage.rules.add(rule('Recording the agent\'s finding', ALONE, 'The agent may read, and record its finding with its steps. It never confirms coverage, changes a reserve or sends anything.'));
        } else {
            how(
                coverage,
                SINGLE,
                'One call. It is handed the claim and the policy as text and returns a verdict as structured data. ' +
                    (coverageAgent == BUILT
                        ? 'The coverage agent is built but not set up in this org: it needs Claude Managed Agents on the org\'s API key.'
                        : 'The coverage agent is not set up in this org.'),
                'The first job built as a real agent: a harness that fetches the notes, documents and prior claims it decides it needs, with the method held in a Skill.'
            );
        }
        all.add(coverage);

        Agent photos = agent('photos', 'Photo appraisal', 'Looks at the photos on a claim and says what they show.', 'utility:photo', 'olive');
        photos.reads = new List<String>{ 'Up to 24 photos on the claim, four at a time', 'The claim as reported, to test the photos against it', 'Areas a person marks on a photo, with their note' };
        photos.tools = new List<String>{ 'Draws a box around each piece of damage', 'Reads a marked area from a closer crop' };
        photos.prepares = new List<String>{ 'What each photo shows, how severe, and whether it fits the reported loss', 'A rough repair range for what is visible', 'An answer for each marked area' };
        photos.steps = new List<String>{ 'Looks at each photo', 'Finds the damage and tests it against the loss', 'Writes the assessment and draws the boxes', 'The adjuster corrects a box or adds an area' };
        photos.rules.add(rule('Storing the assessment on the claim', ALONE, 'When an adjuster asks for it. It describes only what can be seen.'));
        photos.rules.add(rule('Moving or dismissing a box', PERSON, 'A person\'s correction is kept and marked as theirs.'));
        photos.rules.add(rule('Repair cost and coverage', PERSON, 'It never decides either. Hidden damage and the true cost need an appraiser.'));
        photos.places.add(place('Claims: Documents, Photos', '/lightning/o/Case/list'));
        photos.isCounted = true;
        how(photos, PIPELINE, 'A fixed pipeline: one call for each batch of four photos, then one to write the overall read. A marked area is one more call.', 'It could decide for itself which photos need a closer look and go back for them.');
        all.add(photos);

        Agent analysis = agent('analysis', 'Claim analysis', 'Goes through all the evidence on a claim and writes the adjuster\'s report.', 'utility:summarydetail', 'sand');
        analysis.reads = new List<String>{ 'Every photo, document and video on the claim', 'The file notes and the insured\'s statement', 'The photo appraisal and the coverage read' };
        analysis.tools = new List<String>{ 'Reads invoices and estimates', 'Samples frames from a video', 'Runs the photo appraisal and the coverage check as steps' };
        analysis.prepares = new List<String>{ 'One report: summary, evidence, damage, coverage, flags, reserve and next steps', 'Tasks and a reserve figure for the adjuster to accept' };
        analysis.steps = new List<String>{ 'Reads the evidence, one step at a time', 'Compares what each piece says', 'Writes the report', 'The adjuster adds tasks or changes the reserve' };
        analysis.rules.add(rule('Storing the report on the claim', ALONE, 'When an adjuster runs the analysis. Nothing else on the claim changes.'));
        analysis.rules.add(rule('Adding tasks, a file note or a new reserve', PERSON, 'Each is a button the adjuster presses.'));
        analysis.places.add(place('Claims: Analysis', '/lightning/o/Case/list'));
        analysis.isCounted = true;
        how(analysis, PIPELINE, 'A fixed pipeline the page drives step by step: each document, the video, the photos, the coverage check, then the report. One call a step.', 'A natural candidate: a long evidence file needs many steps and compaction, which the fixed steps stand in for today.');
        all.add(analysis);

        Agent desk = agent('desk', 'Claims desk', 'Keeps every open claim briefed and its reserve in line with what is payable.', 'utility:case', 'clay');
        desk.reads = new List<String>{ 'Each open claim with its notes, tasks and documents', 'The estimate, the deductible, the reserve and what has been paid' };
        desk.tools = new List<String>{ 'Finds claims with no brief, or changed since their brief', 'Finds reserves below what is payable or paid' };
        desk.prepares = new List<String>{ 'A brief: where the claim stands, coverage, the money, what to watch, next steps', 'A new reserve with its sum and reasons' };
        desk.steps = new List<String>{ 'Reads the open claims on a shift', 'Picks the ones that need work', 'Writes the brief or the reserve proposal', 'A person approves anything that moves money' };
        desk.rules.add(deskRule(AntsuranceDeskShift.BRIEF));
        desk.rules.add(deskRule(AntsuranceDeskShift.RESERVE));
        desk.places.add(place('Home: Claude\'s desk', DESK_URL));
        desk.isCounted = true;
        how(desk, PIPELINE, 'A fixed pipeline: a shift finds the claims that need work in code, then makes one call for each piece, up to a cap.', 'Long-running work across the whole book, with compaction, instead of one capped call for each claim.');
        all.add(desk);

        Agent underwriting = agent('underwriting', 'Underwriting', 'Suggests better answers on a quote and writes the memo on a referred one.', 'utility:edit_form', 'amber');
        underwriting.reads = new List<String>{ 'The quote\'s answers and how its price is built', 'The customer\'s policies and loss history', 'Why the quote was referred' };
        underwriting.tools = new List<String>{ 'Prices each change through the quote configurator', 'Looks up prior claims on the account' };
        underwriting.prepares = new List<String>{ 'Up to three suggestions a step, each with its exact price effect', 'A memo with a recommendation: approve, approve with conditions, or decline' };
        underwriting.steps = new List<String>{ 'Reads the quote and the account', 'Weighs the risk against the answers', 'Writes the suggestion or the memo', 'The underwriter decides' };
        underwriting.rules.add(rule('Applying a suggestion to a quote', PERSON, 'The seller chooses. The price comes from the pricing code, never from Claude.'));
        underwriting.rules.add(deskRule(AntsuranceDeskShift.MEMO));
        underwriting.rules.add(rule('Approving or declining a quote', PERSON, 'The underwriter decides, with or without the memo.'));
        underwriting.places.add(place('Quotes', '/lightning/o/Quote/list'));
        underwriting.isCounted = true;
        how(underwriting, SINGLE, 'One call for a set of suggestions and one call for a memo. Each returns structured data that the code checks and prices.', 'A Skill for each line of business, so the method for a workers\' compensation referral is not the method for a home.');
        all.add(underwriting);

        Agent renewals = agent('renewals', 'Renewals and follow-up', 'Drafts the note for each policy coming up for renewal and each quote left waiting.', 'utility:refresh', 'olive');
        renewals.reads = new List<String>{ 'Policies renewing in the next 30 days', 'Quotes a customer has had for 15 days or more', 'The customer\'s claims and payments this term' };
        renewals.tools = new List<String>{ 'Finds the renewals and quotes that are due', 'Rates how likely the customer is to stay' };
        renewals.prepares = new List<String>{ 'A renewal email and a call opening, with what to know first', 'A follow-up task for a waiting quote' };
        renewals.steps = new List<String>{ 'Reads what is due', 'Decides what to say to this customer', 'Drafts the note or the task', 'A person sends it' };
        renewals.rules.add(deskRule(AntsuranceDeskShift.OUTREACH));
        renewals.rules.add(deskRule(AntsuranceDeskShift.FOLLOW_UP));
        renewals.places.add(place('Home: Claude\'s desk', DESK_URL));
        renewals.isCounted = true;
        how(renewals, SINGLE, 'One call for each draft. The shift picks the policies and quotes in code.', 'It could check what happened after the last outreach before drafting the next.');
        all.add(renewals);

        Agent assistant = agent('assistant', 'Staff assistant', 'Answers a question about the book from the live records, and prepares a change when asked.', 'utility:chat', 'sand');
        assistant.reads = new List<String>{ 'Any record the person asking may see', 'The record page the chat is opened on', 'Photos and PDFs a person attaches' };
        assistant.tools = new List<String>{
            'Queries Salesforce with the asker\'s own access',
            'Draws the answer: a record card, figures, a chart, a list, a comparison or a timeline',
            'Opens a real form or an email draft, filled in'
        };
        assistant.prepares = new List<String>{ 'A follow-up task, a file note, or a status change on a claim or request' };
        assistant.steps = new List<String>{ 'Reads the question and the page', 'Looks up the records it needs', 'Answers, or prepares the change as a card', 'The person presses Confirm' };
        assistant.rules.add(rule('Answering from the records', ALONE, 'Read only, and only what the person asking is allowed to see.'));
        assistant.rules.add(rule('Any change to a record', PERSON, 'It proposes a card. Nothing is written until the person confirms, and the write runs as them.'));
        assistant.places.add(place('Ask Claude', '/lightning/n/Antsurance_Claude'));
        assistant.notCountedWhy = 'A conversation is not stored, so its answers cannot be counted from the records.';
        how(assistant, TOOL_LOOP, 'A tool loop built here on the Messages API: Claude asks for a lookup, the code runs it as the user and feeds the result back, up to four rounds a question. No compaction, no Skills.', 'Compaction for long conversations and Skills for each team\'s way of working. Today the loop is ours and capped.');
        all.add(assistant);

        if (isPortalInstalled()) {
            Agent portal = agent('portal', 'Customer assistant', 'Helps a signed-in customer with their own policies, claims and requests.', 'utility:people', 'clay');
            portal.reads = new List<String>{ 'Only the signed-in customer\'s own household', 'What is on their screen', 'Photos they add to a claim' };
            portal.tools = new List<String>{ 'Goes to the right page', 'Fills in the form on screen from what the customer says', 'Checks each claim photo and says what is still missing' };
            portal.prepares = new List<String>{ 'A request, a claim or a quote, filled in and ready for the customer to send' };
            portal.steps = new List<String>{ 'Reads the question and the customer\'s records', 'Finds the answer or the right form', 'Answers, or fills the form in view', 'The customer sends it, and our team picks it up' };
            portal.rules.add(rule('Answering about the customer\'s own records', ALONE, 'Anything from another household is dropped before it can reach the answer.'));
            portal.rules.add(rule('Sending a request, a claim or a quote', PERSON, 'It never submits. The customer sees the form, can change it, and presses send.'));
            portal.notCountedWhy = 'A conversation is not stored, so its answers cannot be counted from the records.';
            how(
                portal,
                SINGLE,
                'One call a turn. Claude returns what to say and actions for the site to carry out, and the server checks every one before the site sees it.',
                'Tools the customer\'s assistant could run for itself, each checked on the server, instead of one call a turn.'
            );
            all.add(portal);
            intake.places.add(place('Customer portal: File a claim', null));
        }
        return all;
    }

    // ------------------------------------------------------------------ how each job is started

    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'JPG', 'JPEG', 'PNG', 'GIF', 'WEBP' };
    private static final Integer CLAIMS_TO_LOOK_AT = 50;
    // The policy status that puts the renewal outreach card on a policy's page. The same value AntsuranceRenewalOutreachController shows the card for.
    private static final String PENDING_RENEWAL = 'Pending Renewal';
    /** Home with Claude's desk brought into view: the app's own Home, which reads this parameter. */
    @TestVisible
    private static final String DESK_URL = '/lightning/page/home?c__show=desk';

    /** Stands in for the contact who has a portal login, in a test, where users are real and their contacts are not. */
    @TestVisible
    private static Contact portalContactStandIn;

    /** An open claim and what it carries, so each job can be sent to the claim that shows it best. */
    private class ClaimPick {
        Case claim;
        Integer photos = 0;
        Integer files = 0;

        ClaimPick(Case claim) {
            this.claim = claim;
        }
    }

    /**
     * Says how a person starts each job and picks a record to try it on, a different one for each job
     * where the org has them: for the analysis, the open claim with a report and the fullest file; for
     * coverage, the claim the agent last investigated, or else an open claim not checked yet; for
     * photos, a claim whose photos are assessed; a customer with a policy in force; a policy pending
     * renewal, which is the only kind whose page shows the outreach card; a quote; and the contact who
     * has a portal login. Read as the person, so a button never opens something they cannot see. With
     * nothing to open, a job still says how it is started and simply has no button.
     */
    private static void addStarts(Map<String, Agent> byKey) {
        List<ClaimPick> picks = new List<ClaimPick>();
        Policy__c pending;
        Policy__c inForce;
        Policy__c personal;
        Quote quote;
        Set<String> inForceOrPending = new Set<String>{ 'Active', PENDING_RENEWAL };
        try {
            Map<Id, ClaimPick> byId = new Map<Id, ClaimPick>();
            for (Case claim : [
                SELECT Id, CaseNumber, Subject, Policy__c, Photo_Assessment_At__c, Claude_Analysis_At__c, Coverage_Read_At__c
                FROM Case
                WHERE RecordType.DeveloperName = 'Claim' AND IsClosed = FALSE
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :CLAIMS_TO_LOOK_AT
            ]) {
                ClaimPick pick = new ClaimPick(claim);
                picks.add(pick);
                byId.put(claim.Id, pick);
            }
            if (!picks.isEmpty()) {
                Set<Id> claimIds = byId.keySet();
                for (ContentDocumentLink link : [SELECT LinkedEntityId, ContentDocument.FileType FROM ContentDocumentLink WHERE LinkedEntityId IN :claimIds WITH USER_MODE LIMIT 500]) {
                    ClaimPick pick = byId.get(link.LinkedEntityId);
                    pick.files++;
                    if (IMAGE_TYPES.contains(link.ContentDocument.FileType)) {
                        pick.photos++;
                    }
                }
            }
            for (Policy__c policy : [
                SELECT Id, Name, Line_of_Business__c, Status__c, Account__c, Account__r.Name
                FROM Policy__c
                WHERE Status__c IN :inForceOrPending AND Expiration_Date__c >= TODAY
                WITH USER_MODE
                ORDER BY Expiration_Date__c
                LIMIT 100
            ]) {
                if (policy.Status__c == PENDING_RENEWAL) {
                    pending = pending ?? policy;
                    continue;
                }
                inForce = inForce ?? policy;
                if (personal == null && (policy.Line_of_Business__c == 'Personal Auto' || policy.Line_of_Business__c == 'Homeowners')) {
                    personal = policy;
                }
            }
            for (Quote found : [SELECT Id, QuoteNumber, Needs_Underwriting_Review__c FROM Quote WITH USER_MODE ORDER BY Needs_Underwriting_Review__c DESC, LastModifiedDate DESC LIMIT 1]) {
                quote = found;
            }
        } catch (QueryException e) {
            // Without access to one of these there is nothing to open; each job still says how it is started.
            System.debug(LoggingLevel.WARN, 'Claude at Work could not pick records to try a job on: ' + e.getMessage());
        }
        Policy__c customerPolicy = personal ?? inForce ?? pending;

        // Each job takes the claim that shows it best, and a claim one job has taken is left for it where another will do.
        Set<Id> taken = new Set<Id>();
        ClaimPick analyzed = bestClaim(picks, 'analysis', taken, byKey.get('coverage'));
        ClaimPick covered = bestClaim(picks, 'coverage', taken, byKey.get('coverage'));
        ClaimPick pictured = bestClaim(picks, 'photos', taken, byKey.get('coverage'));

        start(
            byKey.get('intake'),
            'A handler opens a customer or a policy, presses File a Claim with Claude and pastes in what the customer said.',
            customerPolicy == null ? null : 'Try it on ' + customerPolicy.Account__r.Name,
            customerPolicy == null ? null : quickActionUrl('Account', 'File_Claim_With_Claude', customerPolicy.Account__c),
            'Paste an email or call notes. Claude fills in the claim for you to check and file.'
        );
        start(
            byKey.get('coverage'),
            'On a claim, in the Coverage check card: Check coverage for the quick read, or Investigate with the coverage agent for the step-by-step run.',
            covered == null ? null : 'Open claim ' + covered.claim.CaseNumber,
            covered == null ? null : recordUrl('Case', covered.claim.Id),
            covered == null
                ? 'The Coverage check card is at the top of a claim, above its tabs. A run takes under a minute.'
                : named(covered.claim) +
                  ' The Coverage check card is at the top of the claim, above its tabs' +
                  (covered.claim.Coverage_Read_At__c == null ? '. This claim has not been checked yet.' : ', with a read already on it.')
        );
        start(
            byKey.get('photos'),
            'On a claim, open the Documents tab. Add photos to the Photos card, then press Assess the photos with Claude.',
            pictured == null ? null : 'Open claim ' + pictured.claim.CaseNumber,
            pictured == null ? null : recordUrl('Case', pictured.claim.Id),
            pictured == null
                ? 'The Photos card is on a claim\'s Documents tab.'
                : named(pictured.claim) +
                  ' Open its Documents tab, which opens on Photos: ' +
                  (pictured.photos == 0
                      ? 'this claim has no photo yet, so add one first.'
                      : countOf(pictured.photos, 'photo', 'photos') +
                        (pictured.claim.Photo_Assessment_At__c == null ? ', not assessed yet.' : ', already assessed. Assess again runs it afresh.'))
        );
        start(
            byKey.get('analysis'),
            'On a claim, open the Analysis tab and press Analyze the evidence.',
            analyzed == null ? null : 'Open claim ' + analyzed.claim.CaseNumber,
            analyzed == null ? null : recordUrl('Case', analyzed.claim.Id),
            analyzed == null
                ? 'The report is on a claim\'s Analysis tab. A run takes about a minute.'
                : named(analyzed.claim) +
                  ' Open its Analysis tab: ' +
                  (analyzed.claim.Claude_Analysis_At__c == null
                      ? 'no report yet, and ' + countOf(analyzed.files, 'file', 'files') + ' and the notes to write one from. It takes about a minute.'
                      : 'the report is there, written from ' + countOf(analyzed.files, 'file', 'files') + ' and the notes.')
        );
        start(
            byKey.get('desk'),
            'It works a shift across every open claim. On Home, open Claude\'s desk and press Run Claude\'s shift, or approve what is already waiting there.',
            'Open Claude\'s desk',
            DESK_URL,
            'This opens Home with Claude\'s desk in view. A shift takes a few minutes.'
        );
        start(
            byKey.get('underwriting'),
            'On a policy sale, Generate Quote shows what Claude suggests beside each answer. On a quote that was referred, the underwriting review carries Claude\'s memo.',
            quote == null ? null : 'Open quote ' + quote.QuoteNumber,
            quote == null ? null : recordUrl('Quote', quote.Id),
            quote != null && quote.Needs_Underwriting_Review__c == true ? 'This quote was referred: the underwriting review is on its page.' : 'The Configuration tab and the underwriting review are on the quote\'s page.'
        );
        start(
            byKey.get('renewals'),
            'It drafts during Claude\'s shift, and on demand: on a policy that is pending renewal, press Draft outreach with Claude.',
            pending == null ? null : 'Open policy ' + pending.Name,
            pending == null ? null : recordUrl('Policy__c', pending.Id),
            pending == null
                ? 'No policy is pending renewal right now. The Renewal outreach card shows on a policy\'s page only while its status is Pending Renewal.'
                : pending.Account__r.Name + ', pending renewal. The Renewal outreach card is at the top of the policy\'s page, above its tabs.'
        );
        start(
            byKey.get('assistant'),
            'Ask from the Ask Claude tab, or from the Ask Claude bar at the bottom of any page, where it knows the record you are on.',
            'Open Ask Claude',
            '/lightning/n/Antsurance_Claude',
            'Pick a starter or type a question.'
        );
        if (byKey.containsKey('portal')) {
            Contact customer = portalContact();
            start(
                byKey.get('portal'),
                'A customer signs in to the portal and types what they need. Nobody on staff starts it.',
                customer == null ? null : 'Open ' + customer.Name,
                customer == null ? null : recordUrl('Contact', customer.Id),
                customer == null
                    ? 'To see it as a customer: open a contact who has a portal login and choose Log in to Experience as User.'
                    : 'This contact has a portal login. On the contact\'s page, press Log in to Experience as User: the portal opens as that customer, with the assistant on every page.'
            );
        }
    }

    /** "Parking lot scrape, rear quarter panel." so the line under a button says which claim it opens. */
    private static String named(Case claim) {
        return String.isBlank(claim.Subject) ? '' : claim.Subject.removeEnd('.') + '.';
    }

    private static String countOf(Integer count, String one, String many) {
        return count + ' ' + (count == 1 ? one : many);
    }

    /**
     * The open claim that shows a job best, by a score, the most recently touched winning a tie. A claim
     * another job has taken counts only when nothing else scores, so three buttons open three claims.
     */
    private static ClaimPick bestClaim(List<ClaimPick> picks, String job, Set<Id> taken, Agent coverage) {
        ClaimPick best;
        Integer bestScore = -1;
        for (Boolean fresh : new List<Boolean>{ true, false }) {
            for (ClaimPick pick : picks) {
                if (fresh == taken.contains(pick.claim.Id)) {
                    continue;
                }
                Integer score = scoreFor(pick, job, coverage);
                if (score > bestScore) {
                    best = pick;
                    bestScore = score;
                }
            }
            // Any claim will do for the quick coverage check; the others need something on the claim to show.
            if (best != null && (bestScore > 0 || !fresh)) {
                break;
            }
        }
        if (best != null) {
            taken.add(best.claim.Id);
        }
        return best;
    }

    private static Integer scoreFor(ClaimPick pick, String job, Agent coverage) {
        Case claim = pick.claim;
        if (job == 'analysis') {
            // A report on a full file first; without a report, the fullest file to run one on.
            return (claim.Claude_Analysis_At__c == null ? 0 : 1000) + Math.min(pick.files, 999);
        }
        if (job == 'photos') {
            // Photos Claude has assessed, on a claim it has also analyzed: the one worked furthest shows the most.
            if (pick.photos == 0) {
                return 0;
            }
            return (claim.Photo_Assessment_At__c == null ? 0 : 200) + (claim.Claude_Analysis_At__c == null ? 0 : 100) + Math.min(pick.photos, 99);
        }
        // Coverage: the claim the agent last investigated, where its steps can be read. Otherwise a claim on a
        // policy with no check yet, where pressing the button is the whole demonstration.
        if (coverage?.traceOf?.url != null && coverage.traceOf.url.contains(String.valueOf(claim.Id))) {
            return 3;
        }
        return claim.Policy__c == null ? 0 : claim.Coverage_Read_At__c == null ? 2 : 1;
    }

    /** The contact behind an active portal login, most recently signed in first; null when nobody has one or users cannot be read. */
    private static Contact portalContact() {
        Contact found;
        try {
            for (User login : [
                SELECT Contact.Id, Contact.Name
                FROM User
                WHERE IsActive = TRUE AND IsPortalEnabled = TRUE AND ContactId != NULL
                WITH USER_MODE
                ORDER BY LastLoginDate DESC NULLS LAST
                LIMIT 1
            ]) {
                // Null when the person cannot see that contact, and then there is no button.
                found = login.Contact;
            }
        } catch (QueryException e) {
            found = null;
        }
        return Test.isRunningTest() ? portalContactStandIn : found;
    }

    private static void start(Agent agent, String how, String label, String url, String onceThere) {
        if (agent == null) {
            return;
        }
        agent.start = new Start();
        agent.start.how = how;
        agent.start.label = label;
        agent.start.url = url;
        agent.start.onceThere = onceThere;
    }

    private static String recordUrl(String objectName, Id recordId) {
        return '/lightning/r/' + objectName + '/' + recordId + '/view';
    }

    /** A record's quick action, opened over its page. */
    private static String quickActionUrl(String objectName, String action, Id recordId) {
        return '/lightning/action/quick/' + objectName + '.' + action + '?objectApiName=' + objectName + '&context=RECORD_DETAIL&recordId=' + recordId +
            '&backgroundContext=' + EncodingUtil.urlEncode(recordUrl(objectName, recordId), 'UTF-8');
    }

    private static Agent agent(String key, String name, String job, String icon, String tint) {
        Agent agent = new Agent();
        agent.key = key;
        agent.name = name;
        agent.job = job;
        agent.icon = icon;
        agent.tint = tint;
        return agent;
    }

    private static Rule rule(String what, String mode, String detail) {
        Rule rule = new Rule();
        rule.what = what;
        rule.mode = mode;
        rule.detail = detail;
        return rule;
    }

    private static Place place(String label, String url) {
        Place place = new Place();
        place.label = label;
        place.url = url;
        return place;
    }

    /** A kind of desk work as a rule, in the mode the desk is set to now. */
    private static Rule deskRule(String kindKey) {
        AntsuranceDeskShift.Kind kind = AntsuranceDeskShift.kindOf(kindKey);
        String mode = AntsuranceDeskShift.modeOf(kind);
        Rule rule = new Rule();
        rule.what = kind.label;
        rule.isSetting = true;
        if (mode == AntsuranceDeskShift.AUTO) {
            rule.mode = ALONE;
            rule.detail = kind.whenAuto;
        } else if (mode == AntsuranceDeskShift.OFF) {
            rule.mode = OFF;
            rule.detail = 'Switched off on Claude\'s desk. ' + kind.what;
        } else {
            rule.mode = PERSON;
            rule.detail = kind.locked ? kind.lockReason : kind.whenApprove;
        }
        return rule;
    }

    private static void how(Agent agent, String runs, String line, String harnessLine) {
        agent.runs = runs;
        agent.runsLine = line;
        agent.harnessLine = harnessLine;
    }

    private static Boolean isPortalInstalled() {
        return pretendPortalInstalled != null ? pretendPortalInstalled : Type.forName(PORTAL_CLASS) != null;
    }

    /**
     * Whether the coverage agent can run here. Its code may be in the org without the agent being set up:
     * setup keeps the agent's and the environment's ids in a custom setting, and both must be there.
     * Read by name so this page still compiles in an org that does not have the agent.
     */
    private static String coverageAgentState() {
        if (coverageAgentStandIn != null) {
            return coverageAgentStandIn;
        }
        if (Type.forName(COVERAGE_AGENT_CLASS) == null || Schema.getGlobalDescribe().get(COVERAGE_AGENT_SETTING) == null) {
            return ABSENT;
        }
        try {
            Id orgId = UserInfo.getOrganizationId();
            List<SObject> rows = Database.query('SELECT Agent_Id__c, Environment_Id__c FROM ' + COVERAGE_AGENT_SETTING + ' WHERE SetupOwnerId = :orgId LIMIT 1', AccessLevel.SYSTEM_MODE);
            Boolean isReady = !rows.isEmpty() && String.isNotBlank((String) rows[0].get('Agent_Id__c')) && String.isNotBlank((String) rows[0].get('Environment_Id__c'));
            return isReady ? READY : BUILT;
        } catch (QueryException e) {
            return BUILT;
        }
    }

    // ------------------------------------------------------------------ what they did

    /** Which agent does each kind of desk work. */
    private static final Map<String, String> AGENT_OF_KIND = new Map<String, String>{
        AntsuranceDeskShift.BRIEF => 'desk',
        AntsuranceDeskShift.RESERVE => 'desk',
        AntsuranceDeskShift.MEMO => 'underwriting',
        AntsuranceDeskShift.OUTREACH => 'renewals',
        AntsuranceDeskShift.FOLLOW_UP => 'renewals'
    };

    private static void countDeskWork(Map<String, Agent> byKey) {
        if (!Schema.sObjectType.Claude_Work__c.isAccessible()) {
            for (String key : new Set<String>(AGENT_OF_KIND.values())) {
                byKey.get(key).isCounted = false;
                byKey.get(key).notCountedWhy = 'You do not have access to Claude\'s desk, so its work is not counted here.';
            }
            return;
        }
        Datetime weekStart = weekStart();
        Datetime dayStart = dayStart();
        for (Claude_Work__c row : [
            SELECT Kind__c, Status__c, Title__c, Record_Id__c, Record_Object__c, Prepared_At__c, Decided_At__c
            FROM Claude_Work__c
            WHERE Prepared_At__c >= :weekStart OR Decided_At__c >= :weekStart OR Status__c = :AntsuranceDeskShift.WAITING
            ORDER BY Prepared_At__c DESC NULLS LAST
            LIMIT :MAX_ROWS
        ]) {
            Agent agent = byKey.get(agentOfKindLabel(row.Kind__c));
            if (agent == null) {
                continue;
            }
            Boolean wasPrepared = row.Status__c != AntsuranceDeskShift.FAILED && row.Status__c != AntsuranceDeskShift.REPLACED;
            if (row.Status__c == AntsuranceDeskShift.WAITING) {
                agent.waiting++;
            }
            if (wasPrepared && row.Prepared_At__c >= weekStart) {
                agent.week++;
                agent.today += row.Prepared_At__c >= dayStart ? 1 : 0;
                agent.recent.add(recent(row.Kind__c, row.Title__c, linkTo(row.Record_Object__c, row.Record_Id__c), row.Prepared_At__c, row.Status__c));
            }
            if (row.Decided_At__c >= weekStart && (row.Status__c == AntsuranceDeskShift.APPROVED || row.Status__c == AntsuranceDeskShift.DISMISSED)) {
                agent.approved = (agent.approved == null ? 0 : agent.approved) + (row.Status__c == AntsuranceDeskShift.APPROVED ? 1 : 0);
                agent.dismissed = (agent.dismissed == null ? 0 : agent.dismissed) + (row.Status__c == AntsuranceDeskShift.DISMISSED ? 1 : 0);
            }
        }
    }

    private static String agentOfKindLabel(String label) {
        for (AntsuranceDeskShift.Kind kind : AntsuranceDeskShift.allKinds()) {
            if (kind.label == label) {
                return AGENT_OF_KIND.get(kind.key);
            }
        }
        return null;
    }

    /** The claim features stamp a date on the claim when they run: those dates are the count. */
    private static void countClaimWork(Map<String, Agent> byKey) {
        Datetime weekStart = weekStart();
        Datetime dayStart = dayStart();
        for (Case claim : [
            SELECT Subject, CaseNumber, Coverage_Read_At__c, Coverage_Verdict__c, Coverage_Confirmed_At__c, Photo_Assessment_At__c, Claude_Analysis_At__c
            FROM Case
            WHERE Coverage_Read_At__c >= :weekStart OR Coverage_Confirmed_At__c >= :weekStart OR Photo_Assessment_At__c >= :weekStart OR Claude_Analysis_At__c >= :weekStart
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_ROWS
        ]) {
            String title = String.isBlank(claim.Subject) ? 'Claim ' + claim.CaseNumber : claim.Subject;
            String url = linkTo('Case', claim.Id);
            stamp(byKey.get('coverage'), 'Coverage check', title, url, claim.Coverage_Read_At__c, claim.Coverage_Verdict__c, weekStart, dayStart);
            stamp(byKey.get('photos'), 'Photo assessment', title, url, claim.Photo_Assessment_At__c, null, weekStart, dayStart);
            stamp(byKey.get('analysis'), 'Claim analysis', title, url, claim.Claude_Analysis_At__c, null, weekStart, dayStart);
            if (claim.Coverage_Confirmed_At__c >= weekStart) {
                Agent coverage = byKey.get('coverage');
                coverage.approved = (coverage.approved == null ? 0 : coverage.approved) + 1;
            }
        }
    }

    /**
     * The newest coverage read on record that the agent wrote, with the steps it took. The agent stores its
     * read where the quick check stores its own, with an "agent" part beside the finding: the run and its steps.
     */
    private static void findCoverageAgentTrace(Agent coverage) {
        if (coverage == null || coverage.runs != MANAGED) {
            return;
        }
        for (Case claim : [
            SELECT Subject, CaseNumber, Coverage_Read__c, Coverage_Read_At__c, Coverage_Verdict__c
            FROM Case
            WHERE Coverage_Read_At__c != NULL
            ORDER BY Coverage_Read_At__c DESC
            LIMIT :TRACES_TO_SCAN
        ]) {
            Map<String, Object> read = asMap(claim.Coverage_Read__c);
            if (read == null || !(read.get('agent') instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> part = (Map<String, Object>) read.get('agent');
            coverage.traceOf = recent(
                'Coverage agent',
                String.isBlank(claim.Subject) ? 'Claim ' + claim.CaseNumber : claim.Subject,
                linkTo('Case', claim.Id),
                claim.Coverage_Read_At__c,
                claim.Coverage_Verdict__c
            );
            Object steps = part.get('run') instanceof Map<String, Object> ? ((Map<String, Object>) part.get('run')).get('steps') : null;
            if (steps instanceof List<Object>) {
                for (Object step : (List<Object>) steps) {
                    String words = stepWords(step);
                    if (String.isNotBlank(words)) {
                        coverage.trace.add(words);
                    }
                }
            }
            return;
        }
    }

    private static Map<String, Object> asMap(String text) {
        if (String.isBlank(text) || !text.trim().startsWith('{')) {
            return null;
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(text);
        } catch (JSONException e) {
            return null;
        }
    }

    /** A step of a trace as one line, whether it was stored as words or as a named tool call. */
    private static String stepWords(Object step) {
        if (step instanceof String) {
            return (String) step;
        }
        if (!(step instanceof Map<String, Object>)) {
            return null;
        }
        Map<String, Object> parts = (Map<String, Object>) step;
        String name;
        for (String key : new List<String>{ 'label', 'tool', 'name' }) {
            if (name == null && parts.get(key) instanceof String) {
                name = (String) parts.get(key);
            }
        }
        String detail;
        for (String key : new List<String>{ 'detail', 'summary', 'text' }) {
            if (detail == null && parts.get(key) instanceof String) {
                detail = (String) parts.get(key);
            }
        }
        if (name == null) {
            return detail;
        }
        return String.isBlank(detail) ? name : name + ': ' + detail;
    }

    private static void stamp(Agent agent, String what, String title, String url, Datetime happenedAt, String outcome, Datetime weekStart, Datetime dayStart) {
        if (happenedAt == null || happenedAt < weekStart) {
            return;
        }
        agent.week++;
        agent.today += happenedAt >= dayStart ? 1 : 0;
        agent.recent.add(recent(what, title, url, happenedAt, outcome));
    }

    private static Recent recent(String what, String title, String url, Datetime happenedAt, String outcome) {
        Recent recent = new Recent();
        recent.what = what;
        recent.title = title;
        recent.url = url;
        recent.happenedAt = happenedAt;
        recent.outcome = outcome;
        return recent;
    }

    private static String linkTo(String objectName, String recordId) {
        return String.isBlank(objectName) || String.isBlank(recordId) ? null : '/lightning/r/' + objectName + '/' + recordId + '/view';
    }

    private static Datetime dayStart() {
        return Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
    }

    private static Datetime weekStart() {
        return dayStart().addDays(1 - WEEK_DAYS);
    }

    // ------------------------------------------------------------------ how they scored

    private static void addTests(Map<String, Agent> byKey) {
        List<Antsurance_Agent_Eval__mdt> records = evalStandIn != null ? evalStandIn : Antsurance_Agent_Eval__mdt.getAll().values();
        List<EvalRow> rows = new List<EvalRow>();
        for (Antsurance_Agent_Eval__mdt record : records) {
            rows.add(new EvalRow(record));
        }
        rows.sort();
        for (EvalRow row : rows) {
            Agent agent = byKey.get(row.record.Agent__c);
            if (agent == null) {
                continue;
            }
            Eval eval = new Eval();
            eval.title = row.record.MasterLabel;
            eval.result = row.record.Result__c;
            eval.measured = row.record.Measured__c;
            eval.caveat = row.record.Caveat__c;
            eval.runOn = row.record.Run_On__c;
            eval.source = row.record.Source__c;
            agent.tests.add(eval);
        }
    }

    private class EvalRow implements Comparable {
        Antsurance_Agent_Eval__mdt record;

        EvalRow(Antsurance_Agent_Eval__mdt record) {
            this.record = record;
        }

        public Integer compareTo(Object other) {
            Decimal mine = record.Order__c == null ? 99 : record.Order__c;
            Decimal theirs = ((EvalRow) other).record.Order__c == null ? 99 : ((EvalRow) other).record.Order__c;
            return mine == theirs ? 0 : mine < theirs ? -1 : 1;
        }
    }
}
