/**
 * @description Claude's read of a claim file, for the brief card on the claim page. On request it
 * reads the claim, its policy, coverages and endorsements, the file notes (with any written in
 * Salesforce Notes, which are notes here and not documents), open tasks and attached
 * documents, and writes where the claim stands, how coverage applies, what the money says, what to
 * watch and what to do next. The brief is stored on the claim (Claude_Brief__c, as Markdown) with
 * the time it was written, and later visits show the stored copy.
 *
 * The stored text ends with an HTML comment holding the brief in structured form and a snapshot
 * of the facts it was written from. Comparing that snapshot with the claim today is how the card
 * knows the brief is out of date and can say what changed. Use readable() to show the field
 * anywhere else.
 */
public with sharing class AntsuranceClaimsAssistantBrief {
    private static final Integer MAX_NOTES = 30;
    private static final Integer MAX_NOTE_CHARS = 1500;
    private static final Integer MAX_TASKS = 20;
    private static final Integer MAX_FILES = 20;
    private static final Integer MAX_TASK_SUBJECT = 255;
    private static final Integer TASK_DUE_IN_DAYS = 2;
    private static final Integer MAX_BRIEF_TOKENS = 2048;
    private static final String DATA_OPEN = '<!-- antsurance-brief:v1 ';
    private static final String DATA_CLOSE = ' -->';
    private static final List<String> WATCH_LEVELS = new List<String>{ 'high', 'medium' };

    @TestVisible
    private static final String NOT_A_CLAIM = 'Claude writes briefs for claims only.';
    @TestVisible
    private static final String NO_ACCESS = 'This claim could not be read or saved. Check your access to claims.';
    @TestVisible
    private static final String EMPTY_TASK = 'Give the task a subject.';

    private static final String INSTRUCTIONS =
        'You are a senior claims examiner at Antsurance, an insurance carrier, reviewing a claim file for the handler who owns it. ' +
        'You are given the claim, its policy with coverages and endorsements, the file notes (newest first), the tasks and the names of attached documents. ' +
        'Write a brief the handler can take in within twenty seconds before picking up the phone.\n\n' +
        'Base every statement on the file. Interpret the facts instead of listing field values the handler can already see. ' +
        'A document named under ATTACHED DOCUMENTS has been received: every part of the brief treats it as in the file, so never say an invoice, estimate or report is awaited or pending when it is attached. ' +
        'You see only its name, so where its figures matter and no file note gives them, say the document is attached and has yet to be reviewed. ' +
        'When the file does not say something that matters, say that it is missing. Never invent a fact, a figure or a name.\n\n' +
        'headline: the single most important thing about this claim today, in one sentence of at most 20 words.\n\n' +
        'standing: what has happened so far, what stage the claim is at and who is waiting on whom. One or two sentences. ' +
        'The person working the claim is the one named as Handler: when Antsurance has the next move, say the claim is waiting on the handler by name, whoever a task is assigned to.\n\n' +
        'coverage: whether the policy responds. Say whether it was in force on the date of loss, which coverage applies with its limit and deductible, ' +
        'and any exclusion, endorsement or condition that bears on this loss. One or two sentences.\n\n' +
        'money: what the figures mean. Measure the reserve against the payable amount as the rule below says, and against costs named in the notes or documents, ' +
        'say what has been paid and what is left, and say whether the reserve is short, covers the claim or is heavy, and why. One or two sentences.\n\n' +
        'watch: zero to four things that could change the outcome, most serious first. Include only what the file supports: ' +
        'a coverage problem (policy lapsed or outside its term, an exclusion, a condition not met); ' +
        'a fraud indicator (the possible fraud flag, late reporting, a loss soon after the policy started or changed, inconsistent accounts); ' +
        'subrogation (another party at fault, a failed product or a contractor\'s work); ' +
        'a stale file (no note for more than seven days on an open claim, or overdue tasks); a reserve that is short by the rule below; an injury that could develop; a deadline. ' +
        'Each has a label of one to three words naming the concern (Coverage, Fraud indicator, Subrogation, Stale file, Reserve, Injury or Deadline where one fits, otherwise the thing itself, such as Furnace; never Other), ' +
        'a level (high when it could change whether or how much the claim pays, otherwise medium) and one sentence saying what it is and why it matters. ' +
        'Return an empty list when nothing qualifies.\n\n' +
        'next_actions: two to four things the handler should do next, most urgent first. Each action starts with a verb, is at most twelve words, ' +
        'and is concrete enough to do today. Give one short sentence of reason for each. When an open task already covers an action, word the action the way the task does.\n\n' +
        'Write in plain words and complete sentences. Write money with a dollar sign and thousands separators, and dates month first, like Sep 28. ' +
        AntsuranceClaimRules.LASTING_WORDS +
        'Refer to people by the names in the file. Do not use dashes as punctuation, and do not use Markdown. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH +
        '\n\n' +
        AntsuranceClaimRules.RESERVE_RULE +
        ' The headline, the money line, the watch list and the next actions must all agree with it: ' +
        'when the reserve covers the claim, none of them says to raise it or calls it short.' +
        '\n\nWhen the file carries CLAUDE\'S COVERAGE CHECK, the brief must agree with it. ' +
        'If its verdict is Needs review or Not covered, coverage is not settled: say in the coverage line what it hinges on, ' +
        'do not say an exclusion does not apply or that coverage is confirmed when the check leaves that open, ' +
        'make its open question the first item in the watch list with the label Coverage and level high, ' +
        'and word a next action so that it settles that question. If its verdict is Covered, do not raise doubts the check did not.';

    /**
     * @description Something on the file that could change the outcome.
     */
    public class WatchItem {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String level;
        @AuraEnabled
        public String text;
    }

    /**
     * @description Something the handler should do next.
     */
    public class NextAction {
        @AuraEnabled
        public String action;
        @AuraEnabled
        public String reason;
        /** True when an open task on the claim already has this subject. */
        @AuraEnabled
        public Boolean hasTask = false;
    }

    /**
     * @description The brief as the card shows it.
     */
    public class Brief {
        /** False when no brief has been written for this claim yet. */
        @AuraEnabled
        public Boolean exists = false;
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public String standing;
        @AuraEnabled
        public String coverage;
        @AuraEnabled
        public String money;
        @AuraEnabled
        public List<WatchItem> watch = new List<WatchItem>();
        @AuraEnabled
        public List<NextAction> nextActions = new List<NextAction>();
        @AuraEnabled
        public Datetime writtenAt;
        /** True when the claim or its file has changed since the brief was written. */
        @AuraEnabled
        public Boolean stale = false;
        /** What changed, in a few words each, such as "Reserve changed" or "2 new file notes". */
        @AuraEnabled
        public List<String> changes = new List<String>();
    }

    /** Everything read from the file for one claim. */
    private class ClaimFile {
        Case claim;
        List<Policy_Coverage__c> coverages = new List<Policy_Coverage__c>();
        List<Policy_Endorsement__c> endorsements = new List<Policy_Endorsement__c>();
        List<File_Note__c> notes = new List<File_Note__c>();
        List<Task> tasks = new List<Task>();
        List<String> documents = new List<String>();
    }

    /**
     * @description Loads the stored brief for a claim, and checks whether it is still current.
     * @param caseId The claim on screen
     * @return The stored brief, or exists = false when none has been written
     * @throws AuraHandledException when the record is not a claim or cannot be read
     */
    @AuraEnabled
    public static Brief getBrief(Id caseId) {
        try {
            return toBrief(loadFile(caseId));
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
    }

    /**
     * @description Has Claude read the claim file and write a new brief, and stores it on the claim.
     * @param caseId The claim on screen
     * @return The new brief
     * @throws AuraHandledException when the record is not a claim, cannot be read or saved, or
     * Claude cannot be reached
     */
    @AuraEnabled
    public static Brief writeBrief(Id caseId) {
        ClaimFile file;
        try {
            file = loadFile(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, describeFile(file)).returning(briefSchema());
            question.maxTokens = MAX_BRIEF_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }

        Datetime now = Datetime.now();
        Map<String, Object> stored = new Map<String, Object>{ 'brief' => answer, 'facts' => factsOf(file) };
        String text = toMarkdown(answer) + '\n\n' + DATA_OPEN + JSON.serialize(stored).replace('-->', '--&gt;') + DATA_CLOSE;
        try {
            update as user new Case(Id = caseId, Claude_Brief__c = text, Claude_Brief_At__c = now);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
        file.claim.Claude_Brief__c = text;
        file.claim.Claude_Brief_At__c = now;
        return toBrief(file);
    }

    /**
     * @description Adds one of the brief's next actions to the claim as a task for the current user.
     * @param caseId The claim on screen
     * @param subject The task subject
     * @throws AuraHandledException when the subject is empty or the task cannot be saved
     */
    @AuraEnabled
    public static void addTask(Id caseId, String subject) {
        if (String.isBlank(subject)) {
            throw handled(EMPTY_TASK);
        }
        try {
            Case claim = [SELECT ContactId FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
            insert as user new Task(
                WhatId = caseId,
                WhoId = claim.ContactId,
                OwnerId = UserInfo.getUserId(),
                Subject = subject.trim().left(MAX_TASK_SUBJECT),
                ActivityDate = Date.today().addDays(TASK_DUE_IN_DAYS),
                Status = 'Not Started',
                Priority = 'Normal'
            );
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    /**
     * @description The claim file written out as text for Claude: the claim, its policy, coverages
     * and endorsements, file notes, tasks and document names. Shared with the document reader so
     * both work from the same picture of the claim.
     * @param caseId The claim
     * @return The file as plain text
     * @throws AuraHandledException when the record is not a claim or cannot be read
     */
    public static String describeClaim(Id caseId) {
        try {
            return describeFile(loadFile(caseId));
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
    }

    /**
     * @description The brief as plain Markdown, without the structured data stored after it.
     * Use this to show Claude_Brief__c anywhere other than the brief card.
     * @param stored The value of Claude_Brief__c
     * @return The readable part of the brief
     */
    public static String readable(String stored) {
        return stored == null ? null : stored.substringBefore(DATA_OPEN).trim();
    }

    private static ClaimFile loadFile(Id caseId) {
        ClaimFile file = new ClaimFile();
        List<Case> claims = [
            SELECT
                Id,
                CaseNumber,
                Subject,
                Description,
                Status,
                Priority,
                Origin,
                IsClosed,
                RecordType.DeveloperName,
                Account.Name,
                Contact.Name,
                Owner.Name,
                Handled_By__c,
                Severity__c,
                Loss_Type__c,
                Date_of_Loss__c,
                Reported_Date__c,
                Days_Open__c,
                Loss_Location__c,
                Estimated_Loss__c,
                Reserve_Amount__c,
                Paid_Amount__c,
                Outstanding_Reserve__c,
                Coverage_Check__c,
                Coverage_Read__c,
                SIU_Referral__c,
                Subrogation_Potential__c,
                Claude_Brief__c,
                Claude_Brief_At__c,
                Policy__c,
                Policy__r.Name,
                Policy__r.Line_of_Business__c,
                Policy__r.Status__c,
                Policy__r.Effective_Date__c,
                Policy__r.Expiration_Date__c,
                Policy__r.Coverage_Limit__c,
                Policy__r.Deductible__c,
                Policy__r.Insured_Item__c,
                Policy__r.Payment_Status__c,
                Policy__r.Underwriting_Notes__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        if (claims.isEmpty() || claims[0].RecordType?.DeveloperName != 'Claim') {
            throw handled(NOT_A_CLAIM);
        }
        file.claim = claims[0];
        if (file.claim.Policy__c != null) {
            Id policyId = file.claim.Policy__c;
            file.coverages = [
                SELECT Name, Category__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, What_Is_Covered__c
                FROM Policy_Coverage__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ];
            file.endorsements = [
                SELECT Name, Type__c, Form_Number__c, Description__c
                FROM Policy_Endorsement__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ];
        }
        // A note saved from Claude's own claim analysis is not evidence, and does not make the brief out of date.
        // A note written in Salesforce Notes is read with the file notes, by date.
        file.notes = AntsuranceClaimRules.withoutClaudeNotes(
            AntsuranceSalesforceNotes.withFileNotes(
                [
                    SELECT Note_Type__c, Note_Date__c, Author_Name__c, Body__c, CreatedDate, LastModifiedDate
                    FROM File_Note__c
                    WHERE Case__c = :caseId
                    WITH USER_MODE
                    ORDER BY Note_Date__c DESC NULLS LAST, CreatedDate DESC
                    LIMIT :MAX_NOTES
                ],
                caseId,
                MAX_NOTES
            )
        );
        file.tasks = [
            SELECT Subject, ActivityDate, Status, Priority, IsClosed, OwnerId, Owner.Name
            FROM Task
            WHERE WhatId = :caseId
            WITH USER_MODE
            ORDER BY IsClosed, ActivityDate NULLS LAST
            LIMIT :MAX_TASKS
        ];
        for (ContentDocumentLink link : [
            SELECT ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
            WITH USER_MODE
            ORDER BY ContentDocument.Title
            LIMIT :MAX_FILES
        ]) {
            file.documents.add(link.ContentDocument.Title + (String.isBlank(link.ContentDocument.FileExtension) ? '' : '.' + link.ContentDocument.FileExtension));
        }
        return file;
    }

    /** The claim file written out for Claude. */
    @TestVisible
    private static String describeFile(ClaimFile file) {
        Case claim = file.claim;
        List<String> lines = new List<String>{
            'Today is ' + Datetime.now().format('EEEE, MMM d, yyyy') + '.',
            '',
            'CLAIM ' + claim.CaseNumber + ': ' + claim.Subject,
            'Customer: ' + claim.Account?.Name + (claim.Contact?.Name == null ? '' : ', contact ' + claim.Contact.Name),
            'Handler: ' + (String.isBlank(claim.Handled_By__c) ? claim.Owner?.Name : claim.Handled_By__c),
            'Status: ' + claim.Status + (claim.IsClosed ? ' (closed)' : '') + ', priority ' + claim.Priority + ', severity ' + claim.Severity__c,
            'Loss type: ' + claim.Loss_Type__c,
            'Date of loss: ' + day(claim.Date_of_Loss__c) + ', reported ' + day(claim.Reported_Date__c) + ' by ' + claim.Origin + ', open ' + claim.Days_Open__c + ' days',
            'Location: ' + claim.Loss_Location__c,
            'Description: ' + claim.Description,
            'Estimated loss: ' + money(claim.Estimated_Loss__c),
            'Reserve: ' + money(claim.Reserve_Amount__c) + ', paid to date ' + money(claim.Paid_Amount__c) + ', outstanding reserve ' + money(claim.Outstanding_Reserve__c),
            payableLine(claim),
            'Coverage check (policy against date of loss): ' + claim.Coverage_Check__c,
            'Possible fraud flag: ' + (claim.SIU_Referral__c ? 'set' : 'not set') + '. Subrogation potential flag: ' + (claim.Subrogation_Potential__c ? 'set' : 'not set') + '.',
            ''
        };
        lines.addAll(coverageCheckLines(claim));
        if (claim.Policy__r == null) {
            lines.add('POLICY: none linked to this claim.');
        } else {
            Policy__c policy = claim.Policy__r;
            lines.add('POLICY ' + policy.Name + ': ' + policy.Line_of_Business__c + ', status ' + policy.Status__c + ', payments ' + policy.Payment_Status__c);
            lines.add('Term: ' + day(policy.Effective_Date__c) + ' to ' + day(policy.Expiration_Date__c));
            lines.add('Insures: ' + policy.Insured_Item__c);
            lines.add('Overall limit ' + money(policy.Coverage_Limit__c) + ', deductible ' + money(policy.Deductible__c));
            if (String.isNotBlank(policy.Underwriting_Notes__c)) {
                lines.add('Underwriting notes: ' + policy.Underwriting_Notes__c);
            }
            lines.add('Coverages:');
            for (Policy_Coverage__c coverage : file.coverages) {
                lines.add(
                    '- ' +
                        coverage.Name +
                        ' (' +
                        coverage.Category__c +
                        '): limit ' +
                        money(coverage.Limit_Amount__c) +
                        (String.isBlank(coverage.Limit_Type__c) ? '' : ' ' + coverage.Limit_Type__c) +
                        ', deductible ' +
                        money(coverage.Deductible_Amount__c) +
                        (String.isBlank(coverage.What_Is_Covered__c) ? '' : '. ' + coverage.What_Is_Covered__c)
                );
            }
            if (file.coverages.isEmpty()) {
                lines.add('- none listed');
            }
            if (!file.endorsements.isEmpty()) {
                lines.add('Endorsements and exclusions:');
                for (Policy_Endorsement__c endorsement : file.endorsements) {
                    lines.add('- ' + endorsement.Type__c + ': ' + endorsement.Name + (String.isBlank(endorsement.Description__c) ? '' : '. ' + endorsement.Description__c));
                }
            }
        }
        lines.add('');
        lines.add('FILE NOTES, newest first:');
        for (File_Note__c note : file.notes) {
            Datetime written = note.Note_Date__c == null ? note.CreatedDate : note.Note_Date__c;
            lines.add('[' + written.format('MMM d, yyyy') + ', ' + AntsuranceSalesforceNotes.typeLabel(note) + ', ' + note.Author_Name__c + '] ' + note.Body__c?.abbreviate(MAX_NOTE_CHARS));
        }
        if (file.notes.isEmpty()) {
            lines.add('none');
        }
        lines.add('');
        lines.add('TASKS:');
        // A claim's tasks are its handler's work. In this org they are often assigned to whoever is signed in,
        // so that name is not passed on: Claude would report the person looking at the file as the hold-up.
        String handler = String.isBlank(claim.Handled_By__c) ? claim.Owner?.Name : claim.Handled_By__c;
        for (Task item : file.tasks) {
            lines.add(
                '- ' +
                    item.Subject +
                    ' (' +
                    (item.IsClosed ? 'done' : 'open') +
                    ', due ' +
                    day(item.ActivityDate) +
                    ', ' +
                    item.Priority +
                    ' priority, ' +
                    (item.OwnerId == UserInfo.getUserId() ? handler : item.Owner?.Name) +
                    ')'
            );
        }
        if (file.tasks.isEmpty()) {
            lines.add('none');
        }
        lines.add('');
        lines.add('ATTACHED DOCUMENTS: ' + (file.documents.isEmpty() ? 'none' : String.join(file.documents, '; ')));
        return String.join(lines, '\n');
    }

    private static String day(Date value) {
        return value == null ? 'not recorded' : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    private static String money(Decimal value) {
        return value == null ? 'not set' : '$' + value.setScale(0, RoundingMode.HALF_UP).format();
    }

    @TestVisible
    private static AntsuranceAiClient.Shape briefSchema() {
        AntsuranceAiClient.Shape watchItem = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('One to three words naming the concern, such as Coverage, Subrogation or Furnace. Never Other.'))
            .field('level', AntsuranceAiClient.choice(WATCH_LEVELS, 'high when it could change whether or how much the claim pays.'))
            .field('text', AntsuranceAiClient.text('One sentence: what it is and why it matters.'));
        AntsuranceAiClient.Shape nextAction = new AntsuranceAiClient.Shape()
            .field('action', AntsuranceAiClient.text('What to do, starting with a verb, at most twelve words.'))
            .field('reason', AntsuranceAiClient.text('One short sentence on why.'));
        // The findings come first so the headline is written with them in mind.
        return new AntsuranceAiClient.Shape()
            .field('standing', AntsuranceAiClient.text('Where the claim stands. One or two sentences.'))
            .field('coverage', AntsuranceAiClient.text('Whether and how the policy responds. One or two sentences.'))
            .field('money', AntsuranceAiClient.text('What the estimate, reserve and payments mean. One or two sentences.'))
            .field('watch', AntsuranceAiClient.listOf(watchItem.toJson(), 'Zero to four things to watch, most serious first.'))
            .field('next_actions', AntsuranceAiClient.listOf(nextAction.toJson(), 'Two to four next actions, most urgent first.'))
            .field('headline', AntsuranceAiClient.text('The most important thing about this claim today, in one sentence.'));
    }

    /**
     * The facts a brief depends on. Tasks are left out on purpose: adding one of the brief's own
     * next actions as a task should not make the brief out of date.
     */
    private static Map<String, Object> factsOf(ClaimFile file) {
        Case claim = file.claim;
        Long lastNoteEdit = 0;
        for (File_Note__c note : file.notes) {
            // A Salesforce note read in with the file notes was never saved as one: its own last edit stands in.
            AntsuranceSalesforceNotes.Entry own = AntsuranceSalesforceNotes.entryOf(note);
            Datetime edited = own == null ? note.LastModifiedDate : own.editedAt;
            lastNoteEdit = edited == null ? lastNoteEdit : Math.max(lastNoteEdit, edited.getTime());
        }
        return new Map<String, Object>{
            'status' => claim.Status,
            'severity' => claim.Severity__c,
            'lossType' => claim.Loss_Type__c,
            'dateOfLoss' => String.valueOf(claim.Date_of_Loss__c),
            'estimate' => claim.Estimated_Loss__c,
            'reserve' => claim.Reserve_Amount__c,
            'paid' => claim.Paid_Amount__c,
            'coverageCheck' => claim.Coverage_Check__c,
            'siu' => claim.SIU_Referral__c,
            'subrogation' => claim.Subrogation_Potential__c,
            'policy' => claim.Policy__c,
            'policyStatus' => claim.Policy__r?.Status__c,
            'description' => claim.Description == null ? 0 : claim.Description.hashCode(),
            'notes' => file.notes.size(),
            'lastNoteEdit' => lastNoteEdit,
            AntsuranceSalesforceNotes.COUNT_KEY => AntsuranceSalesforceNotes.countIn(file.notes),
            'documents' => file.documents.size()
        };
    }

    /** Claude's stored coverage check in a few lines, so the brief cannot contradict the card above it. */
    @TestVisible
    private static List<String> coverageCheckLines(Case claim) {
        List<String> lines = new List<String>();
        if (String.isBlank(claim.Coverage_Read__c)) {
            return lines;
        }
        try {
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(claim.Coverage_Read__c);
            Map<String, Object> check = (Map<String, Object>) data.get('check');
            if (check == null || String.isBlank((String) check.get('verdict'))) {
                return lines;
            }
            lines.add('CLAUDE\'S COVERAGE CHECK (the card above the brief on the claim page). Verdict: ' + check.get('verdict') + '.');
            if (String.isNotBlank((String) check.get('summary'))) {
                lines.add('What it says: ' + check.get('summary'));
            }
            addList(lines, 'Still to ask: ', check.get('questions'));
            addList(lines, 'What would change it: ', check.get('wouldChange'));
            lines.add('');
        } catch (Exception e) {
            // A check this class cannot read is the same as no check.
            lines.clear();
        }
        return lines;
    }

    private static void addList(List<String> lines, String label, Object items) {
        if (!(items instanceof List<Object>)) {
            return;
        }
        List<String> texts = new List<String>();
        for (Object item : (List<Object>) items) {
            if (item != null && String.isNotBlank(String.valueOf(item))) {
                texts.add(String.valueOf(item));
            }
        }
        if (!texts.isEmpty()) {
            lines.add(label + String.join(texts, ' | '));
        }
    }

    /**
     * Where the reserve stands against what is payable, worked out here so the brief does not do the
     * arithmetic itself. The terms are the responding coverage's when the coverage check named one.
     */
    @TestVisible
    private static String payableLine(Case claim) {
        AntsuranceClaimRules.Terms terms = AntsuranceClaimRules.termsFor(claim);
        AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(claim.Reserve_Amount__c, claim.Estimated_Loss__c, terms.deductible, terms.limitAmount);
        return AntsuranceClaimRules.payableLine(at) + (at.payable == null ? '' : ' The limit and deductible are from ' + terms.source + '.');
    }

    /** What differs between the facts a brief was written from and the claim today. */
    @TestVisible
    private static List<String> changesSince(Map<String, Object> before, Map<String, Object> now) {
        List<String> changes = new List<String>();
        Map<String, String> labels = new Map<String, String>{
            'status' => 'Status changed',
            'severity' => 'Severity changed',
            'lossType' => 'Loss type changed',
            'dateOfLoss' => 'Date of loss changed',
            'estimate' => 'Estimate changed',
            'reserve' => 'Reserve changed',
            'paid' => 'Payments changed',
            'coverageCheck' => 'Coverage check changed',
            'siu' => 'Fraud flag changed',
            'subrogation' => 'Subrogation flag changed',
            'policy' => 'Policy changed',
            'policyStatus' => 'Policy status changed',
            'description' => 'Description edited'
        };
        for (String key : labels.keySet()) {
            if (!same(before.get(key), now.get(key))) {
                changes.add(labels.get(key));
            }
        }
        changes.addAll(countChange(before.get('notes'), now.get('notes'), 'file note'));
        if (same(before.get('notes'), now.get('notes')) && !same(before.get('lastNoteEdit'), now.get('lastNoteEdit'))) {
            changes.add('A file note was edited');
        }
        changes.addAll(countChange(AntsuranceSalesforceNotes.documentsThen(before, now, 'documents'), now.get('documents'), 'document'));
        return changes;
    }

    private static List<String> countChange(Object before, Object now, String noun) {
        Decimal was = AntsuranceAiClient.toDecimal(before);
        Decimal isNow = AntsuranceAiClient.toDecimal(now);
        Integer difference = (was == null || isNow == null) ? 0 : (isNow - was).intValue();
        if (difference > 0) {
            return new List<String>{ difference + ' new ' + noun + (difference == 1 ? '' : 's') };
        }
        return difference < 0 ? new List<String>{ 'A ' + noun + ' was removed' } : new List<String>();
    }

    /** Compares two values that may have been through JSON, where numbers change type. */
    private static Boolean same(Object left, Object right) {
        if (left == null || right == null) {
            return left == null && right == null;
        }
        Decimal leftNumber = left instanceof String ? null : AntsuranceAiClient.toDecimal(left);
        Decimal rightNumber = right instanceof String ? null : AntsuranceAiClient.toDecimal(right);
        if (leftNumber != null && rightNumber != null) {
            return leftNumber == rightNumber;
        }
        return String.valueOf(left) == String.valueOf(right);
    }

    private static Brief toBrief(ClaimFile file) {
        Brief brief = new Brief();
        String stored = file.claim.Claude_Brief__c;
        if (String.isBlank(stored)) {
            return brief;
        }
        brief.exists = true;
        brief.writtenAt = file.claim.Claude_Brief_At__c;

        Map<String, Object> data;
        try {
            String raw = stored.substringAfter(DATA_OPEN).substringBeforeLast(DATA_CLOSE).replace('--&gt;', '-->');
            data = (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            data = null;
        }
        Map<String, Object> answer = data == null ? null : (Map<String, Object>) data.get('brief');
        if (answer == null) {
            // Written by hand or by something else: show it as it is, and offer a rewrite.
            brief.headline = readable(stored);
            brief.stale = true;
            brief.changes.add('Not written by this card');
            return brief;
        }
        brief.headline = (String) answer.get('headline');
        brief.standing = (String) answer.get('standing');
        brief.coverage = (String) answer.get('coverage');
        brief.money = (String) answer.get('money');
        if (answer.get('watch') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('watch')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                WatchItem item = new WatchItem();
                item.label = (String) values.get('label');
                item.level = (String) values.get('level');
                item.text = (String) values.get('text');
                brief.watch.add(item);
            }
        }
        Set<String> openTasks = new Set<String>();
        for (Task item : file.tasks) {
            if (!item.IsClosed && item.Subject != null) {
                openTasks.add(item.Subject.toLowerCase());
            }
        }
        if (answer.get('next_actions') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('next_actions')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                NextAction action = new NextAction();
                action.action = (String) values.get('action');
                action.reason = (String) values.get('reason');
                action.hasTask = action.action != null && openTasks.contains(action.action.left(MAX_TASK_SUBJECT).toLowerCase());
                brief.nextActions.add(action);
            }
        }
        if (data.get('facts') instanceof Map<String, Object>) {
            brief.changes = changesSince((Map<String, Object>) data.get('facts'), factsOf(file));
            brief.stale = !brief.changes.isEmpty();
        }
        return brief;
    }

    /** The brief as Markdown with labelled points, readable wherever the field is shown. */
    private static String toMarkdown(Map<String, Object> answer) {
        List<String> blocks = new List<String>{
            (String) answer.get('headline'),
            '**Where it stands:** ' + answer.get('standing'),
            '**Coverage:** ' + answer.get('coverage'),
            '**The money:** ' + answer.get('money')
        };
        List<String> watch = new List<String>();
        if (answer.get('watch') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('watch')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                watch.add('- **' + values.get('label') + ':** ' + values.get('text'));
            }
        }
        if (!watch.isEmpty()) {
            blocks.add('**Watch:**\n' + String.join(watch, '\n'));
        }
        List<String> next = new List<String>();
        if (answer.get('next_actions') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('next_actions')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                next.add((next.size() + 1) + '. ' + values.get('action') + '. ' + values.get('reason'));
            }
        }
        if (!next.isEmpty()) {
            blocks.add('**Next:**\n' + String.join(next, '\n'));
        }
        return String.join(blocks, '\n\n');
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
