/**
 * @description Claude's shift: the routine work Claude finds across the book and prepares on its own.
 * A shift is planned first (what there is to do, capped so it finishes in a couple of minutes) and
 * then prepared one piece at a time, because each piece is its own call to Claude. Every piece is
 * kept as a Claude_Work__c row, which is both the desk's queue and the log of what Claude did.
 *
 * How much Claude may do alone is set per kind of work (Claude_Autonomy__c): do it and report,
 * prepare it for a person, or off. Work that moves money or goes to a customer is always prepared
 * for a person, whatever the setting says.
 */
public with sharing class AntsuranceDeskShift {
    public static final String AUTO = 'auto';
    public static final String APPROVE = 'approve';
    public static final String OFF = 'off';

    public static final String WAITING = 'Waiting';
    public static final String DONE = 'Done by Claude';
    public static final String APPROVED = 'Approved';
    public static final String DISMISSED = 'Dismissed';
    public static final String REPLACED = 'Replaced';
    /** Claude timed out or could not be reached for this piece. The shift moved on; the desk offers to try it again. */
    public static final String FAILED = 'Could not be prepared';

    public static final String BRIEF = 'brief';
    public static final String MEMO = 'memo';
    public static final String OUTREACH = 'outreach';
    public static final String RESERVE = 'reserve';
    public static final String FOLLOW_UP = 'followup';

    /** Only the newest rows are kept, so the log never grows the org's storage. */
    public static final Integer KEEP = 25;
    /** A shift prepares at most this many pieces, so a run finishes in a couple of minutes. */
    @TestVisible
    private static final Integer SHIFT_CAP = 12;
    private static final Integer SMALL_CAP = 3;
    private static final Integer BRIEF_CAP = 6;
    private static final Integer RENEWAL_WINDOW_DAYS = 30;
    private static final Integer STALE_QUOTE_DAYS = 15;
    /** A claim counts as changed since its brief only when it was saved a little after the brief was. */
    private static final Integer BRIEF_TOLERANCE_SECONDS = 10;
    private static final Integer FOLLOW_UP_TOKENS = 900;
    private static final Integer RESERVE_TOKENS = 900;
    // A proposed reserve further than this above the claim's own figures is not believed.
    private static final Decimal RESERVE_CEILING = 1.5;
    private static final Integer MOST_FACTORS = 4;
    private static final Integer MAX_WORK_CHARS = 32000;
    private static final Integer MAX_TEXT = 255;
    private static final Map<String, String> OBJECT_OF_KIND = new Map<String, String>{
        BRIEF => 'Case',
        RESERVE => 'Case',
        MEMO => 'Quote',
        OUTREACH => 'Policy__c',
        FOLLOW_UP => 'Opportunity'
    };
    private static final Set<String> WAITING_ON_CUSTOMER = new Set<String>{ 'Issued', 'Presented' };
    private static final List<String> SEVERITY_ORDER = new List<String>{ 'Catastrophic', 'High', 'Medium', 'Low' };

    // The reserve rule, in the words every Claude feature here uses.
    private static final String RESERVE_RULE = AntsuranceClaimRules.RESERVE_RULE;
    private static final String RESERVE_INSTRUCTIONS = String.join(
        new List<String>{
            'You review claim reserves at Antsurance, a property and casualty insurer. ' + RESERVE_RULE,
            'You are given one open claim: its figures, how long it has been open, and its file (notes, tasks and the names of the documents on it). Propose the reserve the claim should carry now and say why.',
            'Work from the file only. Start from the payable amount given in the figures. Add what the notes or document names show has arrived or is expected and is not in the estimate yet, such as an invoice, a second estimate or a medical bill, and name it. Weigh what has been paid and how long the claim has been open: a claim that has paid most of its reserve early, or has sat open for months, rarely costs less than its estimate.',
            'The reserve is never below the payable amount or below what has been paid. When the file gives no reason to go beyond the payable amount, propose it and say that. Never propose more than the file supports.',
            'Give two to four factors, the weightiest first: a label of two to four words, and one sentence that names the figure, note or document it rests on. Then the figure in whole dollars. Then one or two short sentences, at most 30 words in all, that a claims manager can act on: the sum behind the new figure (such as "$47,500 estimate less the $2,500 deductible is $45,000"), and anything it adds.',
            'Write plainly, in American spelling. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation. ' + AntsuranceClaimRules.LASTING_WORDS
        },
        '\n'
    );
    private static final String FOLLOW_UP_INSTRUCTIONS = String.join(
        new List<String>{
            'You help the sales team at Antsurance, a property and casualty insurer, follow up on quotes a customer has not answered.',
            'Write what the seller needs to chase this one: a task subject, a note on where it stands and what to ask, and a short email to the contact.',
            'Use only the facts in the request. Name the options with their premiums and the date the quote stops being valid. Do not offer a discount, a change of terms or anything else the facts do not support.',
            'The email is plain and warm, at most 90 words, in short paragraphs separated by blank lines. Greet the contact by first name, ask one clear question (which option they prefer, or what is holding them back), and sign off with the sender\'s first name and Antsurance.',
            'Write plainly. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation. ' + AntsuranceClaimRules.LASTING_WORDS
        },
        '\n'
    );

    public class DeskException extends Exception {
        /** True when Claude timed out or could not be reached: the same piece may well work on a second try. */
        public Boolean worthRetrying = false;
    }

    private static DeskException fromClaude(String message) {
        DeskException problem = new DeskException(message);
        problem.worthRetrying = true;
        return problem;
    }

    /**
     * @description One kind of work the shift does, and the rules for it.
     */
    public class Kind {
        public String key;
        /** The Kind__c picklist value. */
        public String label;
        public Schema.SObjectField setting;
        public String defaultMode;
        /** True when this kind may never be done without a person: it moves money or leaves the company. */
        public Boolean locked = false;
        public String lockReason;
        public Integer importance;
        public Integer cap;
        /** "Briefing", for the progress line "Briefing 4 open claims". */
        public String verb;
        public String one;
        public String many;
        /** What the work is, for the panel that sets how much Claude may do. */
        public String what;
        public String whenAuto;
        public String whenApprove;
    }

    private static List<Kind> kinds;

    /**
     * @description The kinds of work, in the order a shift does them.
     * @return The kinds
     */
    public static List<Kind> allKinds() {
        if (kinds == null) {
            kinds = new List<Kind>{
                kind(
                    BRIEF, 'Claim brief', Claude_Autonomy__c.Claim_Brief__c, AUTO, null, 10, BRIEF_CAP, 'Briefing', 'open claim', 'open claims',
                    'A brief on each open claim that has none, or has changed since its brief.',
                    'Claude stores the brief on the claim and lists it here.',
                    'Claude writes the brief and you decide whether it goes on the claim.'
                ),
                kind(
                    OUTREACH, 'Renewal outreach', Claude_Autonomy__c.Renewal_Outreach__c, APPROVE, 'It goes to a customer, so a person always sends it.', 30, SMALL_CAP, 'Drafting',
                    'renewal note', 'renewal notes',
                    'A note to each customer whose policy renews in the next 30 days.',
                    null,
                    'Claude drafts the email and you open it in the composer to send.'
                ),
                kind(
                    MEMO, 'Underwriting memo', Claude_Autonomy__c.Underwriting_Memo__c, AUTO, null, 40, SMALL_CAP, 'Writing', 'underwriting memo', 'underwriting memos',
                    'A memo on each quote waiting on an underwriter with none.',
                    'Claude stores the memo on the quote and lists it here. The underwriter still decides.',
                    'Claude writes the memo and you decide whether it goes on the quote.'
                ),
                kind(
                    RESERVE, 'Reserve review', Claude_Autonomy__c.Reserve_Review__c, APPROVE, 'It changes money set aside on a claim, so a person always approves it.', 50, SMALL_CAP,
                    'Reviewing', 'reserve', 'reserves',
                    'A new reserve, with its sum and reasons, where less is reserved than is payable on the estimate or has been paid.',
                    null,
                    'Claude proposes the figure and you approve the change.'
                ),
                kind(
                    FOLLOW_UP, 'Quote follow-up', Claude_Autonomy__c.Quote_Follow_Up__c, APPROVE, null, 20, SMALL_CAP, 'Drafting', 'quote follow-up', 'quote follow-ups',
                    'A follow-up for each quote a customer has had for 15 days or more.',
                    'Claude adds the follow-up task to your list and lists it here.',
                    'Claude drafts the follow-up and you approve adding the task.'
                )
            };
        }
        return kinds;
    }

    private static Kind kind(
        String key, String label, Schema.SObjectField setting, String defaultMode, String lockReason, Integer importance, Integer cap, String verb, String one, String many,
        String what, String whenAuto, String whenApprove
    ) {
        Kind kind = new Kind();
        kind.key = key;
        kind.label = label;
        kind.setting = setting;
        kind.defaultMode = defaultMode;
        kind.locked = lockReason != null;
        kind.lockReason = lockReason;
        kind.importance = importance;
        kind.cap = cap;
        kind.verb = verb;
        kind.one = one;
        kind.many = many;
        kind.what = what;
        kind.whenAuto = whenAuto;
        kind.whenApprove = whenApprove;
        return kind;
    }

    /**
     * @description Finds a kind by its key or by its picklist label.
     * @param keyOrLabel "brief" or "Claim brief"
     * @return The kind
     * @throws DeskException when there is no such kind
     */
    public static Kind kindOf(String keyOrLabel) {
        for (Kind kind : allKinds()) {
            if (kind.key == keyOrLabel || kind.label == keyOrLabel) {
                return kind;
            }
        }
        throw new DeskException('Claude\'s desk has no such kind of work.');
    }

    /**
     * @description How much Claude may do alone for a kind of work: auto, approve or off. A blank or
     * unknown setting means the kind's default, and a locked kind is never auto.
     * @param kind The kind of work
     * @return auto, approve or off
     */
    public static String modeOf(Kind kind) {
        String stored = (String) Claude_Autonomy__c.getOrgDefaults().get(kind.setting);
        String mode = stored == AUTO || stored == APPROVE || stored == OFF ? stored : kind.defaultMode;
        return kind.locked && mode == AUTO ? APPROVE : mode;
    }

    // ------------------------------------------------------------------ the plan

    /**
     * @description What a shift would do now.
     */
    public class Plan {
        @AuraEnabled
        public List<Step> steps = new List<Step>();
        @AuraEnabled
        public Integer pieceCount = 0;
        /** What there was no room for, in words, or null when the shift covers everything. */
        @AuraEnabled
        public String leftOver;
        /** The kinds that are switched off, by label. */
        @AuraEnabled
        public List<String> switchedOff = new List<String>();
    }

    /**
     * @description One kind of work in a plan.
     */
    public class Step {
        @AuraEnabled
        public String kind;
        /** "Briefing 4 open claims" */
        @AuraEnabled
        public String label;
        @AuraEnabled
        public List<Item> items = new List<Item>();
    }

    /**
     * @description One piece of work to prepare.
     */
    public class Item {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String name;
        public Datetime modified;
    }

    /**
     * @description Looks across the book for routine work and says what this shift will prepare.
     * Nothing is changed and Claude is not called.
     * @return The plan
     */
    public static Plan plan() {
        Map<String, Claude_Work__c> latest = latestByRecord();
        Map<String, List<Item>> found = new Map<String, List<Item>>{
            BRIEF => claimsToBrief(),
            OUTREACH => renewalsToWrite(),
            MEMO => referralsWithoutMemo(),
            RESERVE => reservesToReview(),
            FOLLOW_UP => quotesToChase()
        };
        Plan plan = new Plan();
        List<String> leftOver = new List<String>();
        // The small kinds take their share first; briefs fill what is left of the shift.
        Map<String, List<Item>> chosen = new Map<String, List<Item>>();
        Integer room = SHIFT_CAP;
        for (String key : new List<String>{ RESERVE, MEMO, OUTREACH, FOLLOW_UP, BRIEF }) {
            Kind kind = kindOf(key);
            if (modeOf(kind) == OFF) {
                plan.switchedOff.add(kind.label);
                continue;
            }
            List<Item> todo = new List<Item>();
            for (Item item : found.get(key)) {
                if (!alreadyPrepared(latest.get(kind.label + '|' + item.recordId), item.modified)) {
                    todo.add(item);
                }
            }
            Integer take = Math.min(Math.min(kind.cap, room), todo.size());
            List<Item> taken = new List<Item>();
            for (Integer i = 0; i < take; i++) {
                taken.add(todo[i]);
            }
            chosen.put(key, taken);
            room -= take;
            if (todo.size() > take) {
                Integer rest = todo.size() - take;
                leftOver.add(rest + ' ' + (rest == 1 ? kind.one : kind.many));
            }
        }
        for (Kind kind : allKinds()) {
            List<Item> items = chosen.get(kind.key);
            if (items == null || items.isEmpty()) {
                continue;
            }
            Step step = new Step();
            step.kind = kind.key;
            step.label = kind.verb + ' ' + items.size() + ' ' + (items.size() == 1 ? kind.one : kind.many);
            step.items = items;
            plan.steps.add(step);
            plan.pieceCount += items.size();
        }
        if (!leftOver.isEmpty()) {
            plan.leftOver = 'Left for next time: ' + sentenceList(leftOver) + '.';
        }
        return plan;
    }

    /** The newest piece for each kind and record, so the same work is not prepared twice. */
    private static Map<String, Claude_Work__c> latestByRecord() {
        Map<String, Claude_Work__c> latest = new Map<String, Claude_Work__c>();
        for (Claude_Work__c row : [
            SELECT Kind__c, Record_Id__c, Status__c, Record_Stamp__c
            FROM Claude_Work__c
            WHERE Status__c != :REPLACED
            WITH USER_MODE
            ORDER BY Prepared_At__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 200
        ]) {
            String key = row.Kind__c + '|' + row.Record_Id__c;
            if (!latest.containsKey(key)) {
                latest.put(key, row);
            }
        }
        return latest;
    }

    /** Work is not prepared again while a piece waits for a person, or while the record is as it was when the last piece was prepared. */
    private static Boolean alreadyPrepared(Claude_Work__c row, Datetime modified) {
        // A piece that could not be prepared is tried again by the next shift.
        if (row == null || row.Status__c == FAILED) {
            return false;
        }
        return row.Status__c == WAITING || (row.Record_Stamp__c != null && modified != null && row.Record_Stamp__c >= modified);
    }

    private static List<Item> claimsToBrief() {
        Map<String, List<Item>> bySeverity = new Map<String, List<Item>>();
        for (Case claim : [
            SELECT Id, Subject, CaseNumber, Severity__c, Claude_Brief__c, Claude_Brief_At__c, LastModifiedDate
            FROM Case
            WHERE IsClosed = FALSE AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Reported_Date__c ASC NULLS LAST, CaseNumber
            LIMIT 200
        ]) {
            Boolean hasBrief = String.isNotBlank(claim.Claude_Brief__c);
            Boolean changed = hasBrief && (claim.Claude_Brief_At__c == null || claim.LastModifiedDate > claim.Claude_Brief_At__c.addSeconds(BRIEF_TOLERANCE_SECONDS));
            if (hasBrief && !changed) {
                continue;
            }
            String bucket = SEVERITY_ORDER.contains(claim.Severity__c) ? claim.Severity__c : 'Low';
            if (!bySeverity.containsKey(bucket)) {
                bySeverity.put(bucket, new List<Item>());
            }
            bySeverity.get(bucket).add(item(claim.Id, String.isBlank(claim.Subject) ? claim.CaseNumber : claim.Subject, claim.LastModifiedDate));
        }
        List<Item> items = new List<Item>();
        for (String severity : SEVERITY_ORDER) {
            if (bySeverity.containsKey(severity)) {
                items.addAll(bySeverity.get(severity));
            }
        }
        return items;
    }

    private static List<Item> renewalsToWrite() {
        Date today = Date.today();
        Date until = today.addDays(RENEWAL_WINDOW_DAYS);
        List<Item> items = new List<Item>();
        for (Policy__c policy : [
            SELECT Id, Name, Line_of_Business__c, Account__r.Name, LastModifiedDate
            FROM Policy__c
            WHERE Status__c = 'Pending Renewal' AND Expiration_Date__c >= :today AND Expiration_Date__c <= :until
            WITH USER_MODE
            ORDER BY Expiration_Date__c ASC, Name
            LIMIT 50
        ]) {
            items.add(item(policy.Id, policy.Account__r?.Name + ', ' + policy.Line_of_Business__c, policy.LastModifiedDate));
        }
        return items;
    }

    private static List<Item> referralsWithoutMemo() {
        List<Item> items = new List<Item>();
        for (Quote quote : [
            SELECT Id, Name, Opportunity.Name, Underwriting_Memo__c, LastModifiedDate
            FROM Quote
            WHERE Needs_Underwriting_Review__c = TRUE AND Opportunity.IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Annual_Premium__c DESC NULLS LAST, Name
            LIMIT 50
        ]) {
            if (String.isBlank(quote.Underwriting_Memo__c)) {
                items.add(item(quote.Id, quote.Opportunity?.Name + ', ' + quote.Name, quote.LastModifiedDate));
            }
        }
        return items;
    }

    /** Claims whose reserve is below what is payable on the estimate, or below what has been paid, the largest shortfall first. */
    private static List<Item> reservesToReview() {
        List<Item> items = new List<Item>();
        List<Decimal> shortfalls = new List<Decimal>();
        for (Case claim : [
            SELECT Id, Subject, CaseNumber, Estimated_Loss__c, Reserve_Amount__c, Paid_Amount__c, Policy__r.Deductible__c, LastModifiedDate
            FROM Case
            WHERE IsClosed = FALSE AND RecordType.DeveloperName = 'Claim' AND (Estimated_Loss__c > 0 OR Paid_Amount__c > 0)
            WITH USER_MODE
            ORDER BY Estimated_Loss__c DESC NULLS LAST
            LIMIT 200
        ]) {
            Decimal shortfall = leastReserve(claim) - (claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c);
            if (shortfall <= 0) {
                continue;
            }
            // Kept in order of shortfall as each is added: there are never more than a couple of hundred.
            Integer at = 0;
            while (at < shortfalls.size() && shortfalls[at] >= shortfall) {
                at++;
            }
            Item found = item(claim.Id, String.isBlank(claim.Subject) ? claim.CaseNumber : claim.Subject, claim.LastModifiedDate);
            if (at == items.size()) {
                items.add(found);
                shortfalls.add(shortfall);
            } else {
                items.add(at, found);
                shortfalls.add(at, shortfall);
            }
        }
        return items;
    }

    /** One follow-up for each sale, however many options it has out. */
    private static List<Item> quotesToChase() {
        Date issuedBy = Date.today().addDays(-STALE_QUOTE_DAYS);
        List<Item> items = new List<Item>();
        Set<Id> seen = new Set<Id>();
        for (Quote quote : [
            SELECT OpportunityId, Opportunity.Name, Opportunity.LastModifiedDate
            FROM Quote
            WHERE Status IN :WAITING_ON_CUSTOMER AND Issued_Date__c <= :issuedBy AND Opportunity.IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Issued_Date__c ASC, Annual_Premium__c DESC NULLS LAST
            LIMIT 100
        ]) {
            if (!seen.contains(quote.OpportunityId)) {
                seen.add(quote.OpportunityId);
                items.add(item(quote.OpportunityId, quote.Opportunity.Name, quote.Opportunity.LastModifiedDate));
            }
        }
        return items;
    }

    private static Item item(Id recordId, String name, Datetime modified) {
        Item item = new Item();
        item.recordId = recordId;
        item.name = name;
        item.modified = modified;
        return item;
    }

    // ------------------------------------------------------------------ preparing a piece

    /**
     * @description Prepares one piece of work and keeps it as a row. Under "auto" the work is done
     * (the brief or memo is stored, the follow-up task is added) and the row reports it; under
     * "approve" nothing on the record changes and the row waits for a person.
     * @param kindKey The kind of work
     * @param recordId The claim, policy, quote or policy sale it is for
     * @return The new row
     * @throws DeskException when the kind is switched off, the record does not call for the work, or Claude cannot be reached
     */
    public static Claude_Work__c prepare(String kindKey, Id recordId) {
        Kind kind = kindOf(kindKey);
        String mode = modeOf(kind);
        if (mode == OFF) {
            throw new DeskException(kind.label + ' is switched off under What Claude may do.');
        }
        Claude_Work__c row;
        try {
            if (kind.key == BRIEF) {
                row = prepareBrief(recordId, mode);
            } else if (kind.key == MEMO) {
                row = prepareMemo(recordId, mode);
            } else if (kind.key == OUTREACH) {
                row = prepareOutreach(recordId);
            } else if (kind.key == RESERVE) {
                row = prepareReserve(recordId);
            } else {
                row = prepareFollowUp(recordId, mode);
            }
        } catch (QueryException e) {
            throw new DeskException('That record could not be read.');
        } catch (AuraHandledException e) {
            // The cards' own controllers pass on what Claude's client said went wrong: a timeout, an outage, an answer it could not use.
            throw fromClaude(e.getMessage());
        } catch (AntsuranceAiClient.AiException e) {
            throw fromClaude(e.getMessage());
        }
        row.Kind__c = kind.label;
        row.Record_Id__c = recordId;
        row.Importance__c = kind.importance;
        row.Authority__c = mode;
        row.Prepared_At__c = Datetime.now();
        row.Status__c = mode == AUTO ? DONE : WAITING;
        row.Title__c = row.Title__c.abbreviate(MAX_TEXT);
        row.Record_Name__c = row.Record_Name__c?.abbreviate(MAX_TEXT);
        if (row.Work__c.length() > MAX_WORK_CHARS) {
            throw new DeskException('That piece of work is too long to keep on the desk.');
        }
        try {
            insert as user row;
            // Prepared now, so an earlier failure for the same work has nothing left to say.
            clearFailures(kind, recordId);
        } catch (DmlException e) {
            throw new DeskException('The work could not be kept on the desk: ' + e.getDmlMessage(0));
        }
        trim();
        return row;
    }

    /**
     * @description Records that a piece could not be prepared, with the reason, so the shift can move
     * on and the desk can offer to try that piece again. Claude timing out is the usual cause:
     * Salesforce allows two minutes of callout time in one request.
     * @param kindKey The kind of work
     * @param recordId The record it was for
     * @param recordName What the record is called, as the plan named it
     * @param reason Why, in words a person can act on
     * @return The row that records the failure
     */
    public static Claude_Work__c recordFailure(String kindKey, Id recordId, String recordName, String reason) {
        Kind kind = kindOf(kindKey);
        String name = String.isBlank(recordName) ? 'this record' : recordName;
        Claude_Work__c row = new Claude_Work__c(
            Kind__c = kind.label,
            Status__c = FAILED,
            Record_Id__c = recordId,
            Record_Object__c = OBJECT_OF_KIND.get(kind.key),
            Record_Name__c = name.abbreviate(MAX_TEXT),
            Title__c = (kind.label + ' for ' + name).abbreviate(MAX_TEXT),
            Reason__c = (String.isBlank(reason) ? 'Claude could not be reached.' : reason).abbreviate(MAX_TEXT),
            Work__c = '{}',
            Importance__c = kind.importance,
            Authority__c = modeOf(kind),
            Prepared_At__c = Datetime.now()
        );
        clearFailures(kind, recordId);
        insert as user row;
        trim();
        return row;
    }

    private static void clearFailures(Kind kind, Id recordId) {
        List<Claude_Work__c> failures = [SELECT Id FROM Claude_Work__c WHERE Kind__c = :kind.label AND Record_Id__c = :recordId AND Status__c = :FAILED WITH USER_MODE];
        if (!failures.isEmpty()) {
            delete as user failures;
        }
    }

    private static Claude_Work__c prepareBrief(Id caseId, String mode) {
        Case before = [
            SELECT Subject, CaseNumber, Claude_Brief__c, Claude_Brief_At__c
            FROM Case
            WHERE Id = :caseId AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
        ];
        Boolean hadBrief = String.isNotBlank(before.Claude_Brief__c);
        // The claim page's own brief: it reads the file, asks Claude and stores the answer on the claim.
        AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.writeBrief(caseId);
        List<String> nextActions = new List<String>();
        for (AntsuranceClaimsAssistantBrief.NextAction action : brief.nextActions) {
            nextActions.add(action.action);
        }
        List<Object> watch = new List<Object>();
        for (AntsuranceClaimsAssistantBrief.WatchItem item : brief.watch) {
            watch.add(new Map<String, Object>{ 'label' => item.label, 'text' => item.text });
        }
        Map<String, Object> work = new Map<String, Object>{
            'headline' => brief.headline,
            'standing' => brief.standing,
            'coverage' => brief.coverage,
            'money' => brief.money,
            'nextActions' => nextActions,
            'watch' => watch
        };
        if (mode == APPROVE) {
            // Waiting for a person: keep what Claude wrote on the desk and put the claim back as it was.
            Case written = [SELECT Claude_Brief__c FROM Case WHERE Id = :caseId WITH USER_MODE];
            work.put('stored', written.Claude_Brief__c);
            update as user new Case(Id = caseId, Claude_Brief__c = before.Claude_Brief__c, Claude_Brief_At__c = before.Claude_Brief_At__c);
        }
        String subject = String.isBlank(before.Subject) ? before.CaseNumber : before.Subject;
        return row(
            'Case', subject, 'Brief on ' + subject, hadBrief ? 'The claim has changed since its last brief.' : 'This open claim had no brief.', work,
            [SELECT LastModifiedDate FROM Case WHERE Id = :caseId WITH USER_MODE].LastModifiedDate
        );
    }

    private static Claude_Work__c prepareMemo(Id quoteId, String mode) {
        Quote before = [SELECT Name, Opportunity.Name, Underwriting_Memo__c, Needs_Underwriting_Review__c FROM Quote WHERE Id = :quoteId WITH USER_MODE];
        if (!before.Needs_Underwriting_Review__c) {
            throw new DeskException('That quote is not waiting on an underwriter.');
        }
        AntsuranceUnderwritingController.Memo memo = AntsuranceUnderwritingController.draftMemo(quoteId).memo;
        List<Object> points = new List<Object>();
        for (AntsuranceUnderwritingController.Point point : memo.points) {
            points.add(new Map<String, Object>{ 'label' => point.label, 'detail' => point.detail });
        }
        Map<String, Object> work = new Map<String, Object>{
            'recommendation' => memo.recommendation,
            'headline' => memo.headline,
            'points' => points,
            'conditions' => memo.conditions,
            'questions' => memo.questions
        };
        if (mode == APPROVE) {
            Quote written = [SELECT Underwriting_Memo__c FROM Quote WHERE Id = :quoteId WITH USER_MODE];
            work.put('stored', written.Underwriting_Memo__c);
            update as user new Quote(Id = quoteId, Underwriting_Memo__c = before.Underwriting_Memo__c);
        }
        String name = before.Opportunity?.Name + ', ' + before.Name;
        return row(
            'Quote', name, 'Underwriting memo on ' + before.Opportunity?.Name, 'It was waiting on an underwriter with no memo.', work,
            [SELECT LastModifiedDate FROM Quote WHERE Id = :quoteId WITH USER_MODE].LastModifiedDate
        );
    }

    private static Claude_Work__c prepareOutreach(Id policyId) {
        Policy__c policy = [
            SELECT Name, Line_of_Business__c, Expiration_Date__c, Account__r.Name, LastModifiedDate
            FROM Policy__c
            WHERE Id = :policyId
            WITH USER_MODE
        ];
        AntsuranceRenewalOutreachController.Renewal renewal = AntsuranceRenewalOutreachController.getRenewal(policyId);
        AntsuranceRenewalOutreachController.Outreach outreach = AntsuranceRenewalOutreachController.draft(policyId);
        List<Object> points = new List<Object>();
        for (AntsuranceRenewalOutreachController.Point point : outreach.points) {
            points.add(new Map<String, Object>{ 'label' => point.label, 'detail' => point.detail });
        }
        Map<String, Object> work = new Map<String, Object>{
            'risk' => outreach.risk,
            'riskReason' => outreach.riskReason,
            'points' => points,
            'subject' => outreach.subject,
            'body' => outreach.body,
            'callOpening' => outreach.callOpening,
            'toName' => renewal.insuredName,
            'toEmail' => renewal.insuredEmail,
            'expires' => renewal.expires,
            'currentPremium' => renewal.currentPremium,
            'renewalPremium' => renewal.renewalPremium,
            'policyNumber' => policy.Name
        };
        Integer daysLeft = Date.today().daysBetween(policy.Expiration_Date__c);
        String account = policy.Account__r?.Name;
        return row(
            'Policy__c', policy.Name + ', ' + account, 'Renewal note for ' + account + ', ' + policy.Line_of_Business__c,
            'The policy expires ' + day(policy.Expiration_Date__c) + ', in ' + daysLeft + (daysLeft == 1 ? ' day' : ' days') + ', and ' + renewalStanding(renewal.saleStage) + '.', work,
            policy.LastModifiedDate
        );
    }

    /**
     * Where a renewal stands, in the same words wherever it is shown: an offer is "out" only once the
     * renewal sale has a quote issued, and before that it has not gone out.
     */
    private static String renewalStanding(String saleStage) {
        if (saleStage == 'Bind Requested') {
            return 'the customer has asked to bind the renewal';
        }
        if (saleStage == 'Quote Issued') {
            return 'the renewal offer is out with no answer yet';
        }
        return 'the renewal offer has not gone out';
    }

    /** What is payable on a claim's estimate: the estimate less the policy's deductible. */
    private static Decimal payable(Case claim) {
        Decimal estimate = claim.Estimated_Loss__c == null ? 0 : claim.Estimated_Loss__c;
        Decimal deductible = claim.Policy__r?.Deductible__c == null ? 0 : claim.Policy__r.Deductible__c;
        return Math.max(0, estimate - deductible);
    }

    /** The least a claim's reserve can be: what is payable on its estimate, or what has been paid when that is more. */
    private static Decimal leastReserve(Case claim) {
        return Math.max(payable(claim), claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c);
    }

    /** A claim's subject as the start of a sentence: "Deer strike on Route 20, front-end damage" gives "Deer strike on Route 20". */
    private static String shortSubject(String subject) {
        String lead = subject.substringBefore(',').trim();
        return String.isBlank(lead) ? subject : lead;
    }

    /**
     * One call to Claude, which reads the claim's figures, how long it has been open and its file, and
     * proposes a figure with the reasons for it. The figure is held between the claim's own figures and
     * a ceiling above them; outside that, the proposal falls back to the arithmetic and says so.
     */
    private static Claude_Work__c prepareReserve(Id caseId) {
        Case claim = [
            SELECT Subject, CaseNumber, Estimated_Loss__c, Reserve_Amount__c, Paid_Amount__c, Days_Open__c, Policy__r.Deductible__c, LastModifiedDate
            FROM Case
            WHERE Id = :caseId AND RecordType.DeveloperName = 'Claim' AND IsClosed = FALSE
            WITH USER_MODE
        ];
        Decimal reserve = claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c;
        Decimal estimate = claim.Estimated_Loss__c == null ? 0 : claim.Estimated_Loss__c;
        Decimal paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
        Decimal deductible = claim.Policy__r?.Deductible__c == null ? 0 : claim.Policy__r.Deductible__c;
        Decimal payableAmount = payable(claim);
        Decimal least = leastReserve(claim).setScale(0, System.RoundingMode.CEILING);
        if (least <= reserve) {
            throw new DeskException('The reserve on that claim already covers what is payable on its estimate and what has been paid.');
        }
        Integer daysOpen = claim.Days_Open__c == null ? 0 : claim.Days_Open__c.intValue();
        // The sum behind the payable amount, in the words the claim page uses.
        String sum = deductible > 0
            ? money(estimate) + ' estimate less the ' + money(deductible) + ' deductible is ' + money(payableAmount) + ' payable'
            : money(estimate) + ' estimate with no deductible';

        AntsuranceAiClient.Shape factor = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('Two to four words naming the factor, such as Invoice received, Paid to date or Days open.'))
            .field('detail', AntsuranceAiClient.text('One sentence naming the figure, note or document the factor rests on.'));
        AntsuranceAiClient.Shape shape = new AntsuranceAiClient.Shape()
            .field('factors', AntsuranceAiClient.listOf(factor.toJson(), 'Two to four factors behind the figure, the weightiest first.'))
            .field('new_reserve', AntsuranceAiClient.optionalNumber('The reserve the claim should carry now, in whole dollars. Null only when the file gives nothing to go on.'))
            .field('reason', AntsuranceAiClient.text('One or two short sentences, at most 30 words in all: the sum behind the new figure, and what it adds beyond the payable amount if anything.'));
        String facts = String.join(
            new List<String>{
                'Reserve now: ' + money(reserve) + '. Paid so far: ' + money(paid) + '.',
                'Payable on the estimate: ' + sum + '.',
                'The claim has been open ' + daysOpen + (daysOpen == 1 ? ' day' : ' days') + '. Today is ' + day(Date.today()) + '.',
                '',
                'The claim file:',
                AntsuranceClaimsAssistantBrief.describeClaim(caseId)
            },
            '\n'
        );
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(RESERVE_INSTRUCTIONS, facts).returning(shape);
        question.maxTokens = RESERVE_TOKENS;
        Map<String, Object> answer = AntsuranceAiClient.ask(question).data;

        // The arithmetic alone, for when Claude's figure cannot be used. It shows its sum too.
        String arithmetic = sum + '. ' + (reserve > 0 ? 'The reserve is ' + money(reserve) + ', ' + money(least - reserve) + ' short.' : 'Nothing is reserved yet.');
        if (paid > payableAmount) {
            arithmetic = money(paid) + ' has been paid, more than the ' + money(payableAmount) + ' payable on the estimate. ' +
                (reserve > 0 ? 'The reserve is ' + money(reserve) + '.' : 'Nothing is reserved yet.');
        }
        Decimal proposed = AntsuranceAiClient.toDecimal(answer.get('new_reserve'));
        String reason = answer.get('reason') == null ? null : String.valueOf(answer.get('reason')).trim();
        List<Object> factors = new List<Object>();
        if (answer.get('factors') instanceof List<Object>) {
            for (Object each : (List<Object>) answer.get('factors')) {
                if (each instanceof Map<String, Object> && factors.size() < MOST_FACTORS) {
                    Map<String, Object> given = (Map<String, Object>) each;
                    if (given.get('label') != null && given.get('detail') != null) {
                        factors.add(new Map<String, Object>{ 'label' => String.valueOf(given.get('label')), 'detail' => String.valueOf(given.get('detail')) });
                    }
                }
            }
        }
        // A figure below the claim's own, or far above it, is not one to put in front of a person as Claude's reading.
        Boolean isBelievable = proposed != null && proposed >= least && proposed <= least * RESERVE_CEILING && String.isNotBlank(reason);
        if (!isBelievable) {
            proposed = least;
            reason = arithmetic;
            factors.clear();
        }
        proposed = proposed.setScale(0, System.RoundingMode.CEILING);
        Map<String, Object> work = new Map<String, Object>{
            'oldReserve' => reserve,
            'newReserve' => proposed,
            'estimate' => estimate,
            'deductible' => deductible,
            'payable' => payableAmount,
            'paid' => paid,
            'shortBy' => proposed - reserve,
            'daysOpen' => daysOpen,
            'why' => reason,
            'factors' => factors
        };
        String subject = String.isBlank(claim.Subject) ? claim.CaseNumber : claim.Subject;
        return row('Case', subject, shortSubject(subject) + ': raise the reserve by ' + money(proposed - reserve), reason, work, claim.LastModifiedDate);
    }

    private static Claude_Work__c prepareFollowUp(Id saleId, String mode) {
        Opportunity sale = [
            SELECT
                Name, AccountId, Account.Name, Line_of_Business__c, StageName, LastModifiedDate,
                (
                    SELECT Name, Annual_Premium__c, Issued_Date__c, ExpirationDate, Coverage_Limit__c, Deductible__c
                    FROM Quotes
                    WHERE Status IN :WAITING_ON_CUSTOMER
                    ORDER BY Annual_Premium__c DESC NULLS LAST
                )
            FROM Opportunity
            WHERE Id = :saleId AND IsClosed = FALSE
            WITH USER_MODE
        ];
        if (sale.Quotes.isEmpty()) {
            throw new DeskException('That sale has no quote out with the customer.');
        }
        List<Contact> contacts = [SELECT Id, Name, FirstName, Email FROM Contact WHERE AccountId = :sale.AccountId WITH USER_MODE ORDER BY CreatedDate ASC LIMIT 1];
        Contact contact = contacts.isEmpty() ? null : contacts[0];

        Date issued;
        Date validUntil;
        List<Object> options = new List<Object>();
        List<String> lines = new List<String>{
            'Sale: ' + sale.Name + ' (' + sale.Line_of_Business__c + '), stage ' + sale.StageName + '.',
            'Customer: ' + sale.Account?.Name + '.',
            'Contact: ' + (contact == null ? 'not recorded' : contact.Name + ', first name ' + contact.FirstName) + '.',
            'Sender\'s first name: ' + UserInfo.getFirstName() + '.',
            'Today is ' + day(Date.today()) + '.',
            'Options out with the customer:'
        };
        for (Quote quote : sale.Quotes) {
            issued = issued == null || (quote.Issued_Date__c != null && quote.Issued_Date__c < issued) ? quote.Issued_Date__c : issued;
            validUntil = validUntil == null || (quote.ExpirationDate != null && quote.ExpirationDate < validUntil) ? quote.ExpirationDate : validUntil;
            options.add(new Map<String, Object>{ 'name' => quote.Name, 'premium' => quote.Annual_Premium__c });
            lines.add(
                '- ' + quote.Name + ': ' + money(quote.Annual_Premium__c) + ' a year' +
                (quote.Deductible__c == null ? '' : ', deductible ' + money(quote.Deductible__c)) +
                (quote.ExpirationDate == null ? '' : ', valid until ' + day(quote.ExpirationDate)) + '.'
            );
        }
        Integer daysWaiting = issued == null ? STALE_QUOTE_DAYS : issued.daysBetween(Date.today());
        lines.add('The customer has had the quote for ' + daysWaiting + ' days and has not answered.');

        AntsuranceAiClient.Shape shape = new AntsuranceAiClient.Shape()
            .field('task_subject', AntsuranceAiClient.text('The follow-up as a task subject: starts with a verb, names the customer, at most ten words.'))
            .field('note', AntsuranceAiClient.text('Two sentences for the seller: where it stands, and what to ask.'))
            .field('email_subject', AntsuranceAiClient.text('The email subject, at most 60 characters.'))
            .field('email_body', AntsuranceAiClient.text('The email body as plain text, with paragraphs separated by a blank line.'));
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(FOLLOW_UP_INSTRUCTIONS, String.join(lines, '\n')).returning(shape);
        question.maxTokens = FOLLOW_UP_TOKENS;
        Map<String, Object> answer = AntsuranceAiClient.ask(question).data;

        Map<String, Object> work = new Map<String, Object>{
            'taskSubject' => answer.get('task_subject'),
            'note' => answer.get('note'),
            'emailSubject' => answer.get('email_subject'),
            'emailBody' => answer.get('email_body'),
            'dueDate' => nextWorkingDay(),
            'toName' => contact?.Name,
            'toEmail' => contact?.Email,
            'contactId' => contact?.Id,
            'daysWaiting' => daysWaiting,
            'validUntil' => validUntil,
            'options' => options
        };
        String reason =
            'They have had the quote for ' + daysWaiting + ' days' + (validUntil == null ? '.' : ' and it is valid until ' + day(validUntil) + '.');
        Claude_Work__c row = row('Opportunity', sale.Name, 'Follow up with ' + sale.Account?.Name + ' on the ' + sale.Line_of_Business__c + ' quote', reason, work, sale.LastModifiedDate);
        if (mode == AUTO) {
            addFollowUpTask(saleId, work);
            row.Decision_Note__c = 'Task added to your list, due ' + day(nextWorkingDay()) + '.';
        }
        return row;
    }

    private static Claude_Work__c row(String objectName, String recordName, String title, String reason, Map<String, Object> work, Datetime recordStamp) {
        return new Claude_Work__c(
            Record_Object__c = objectName,
            Record_Name__c = recordName,
            Title__c = title,
            Reason__c = reason.abbreviate(MAX_TEXT),
            Work__c = JSON.serialize(work),
            Record_Stamp__c = recordStamp
        );
    }

    /**
     * @description Adds the follow-up task for a quote the customer has not answered.
     * @param saleId The policy sale
     * @param work The follow-up as prepared (taskSubject, note, emailSubject, emailBody, dueDate, contactId)
     * @return The new task's due date
     */
    public static Date addFollowUpTask(Id saleId, Map<String, Object> work) {
        Date due = work.get('dueDate') instanceof Date ? (Date) work.get('dueDate') : Date.valueOf(String.valueOf(work.get('dueDate')).left(10));
        String description =
            String.valueOf(work.get('note')) + '\n\nDraft email\nSubject: ' + String.valueOf(work.get('emailSubject')) + '\n\n' + String.valueOf(work.get('emailBody')) +
            '\n\nPrepared by Claude on Claude\'s desk.';
        Task task = new Task(
            Subject = String.valueOf(work.get('taskSubject')).abbreviate(MAX_TEXT),
            Description = description,
            WhatId = saleId,
            ActivityDate = due,
            Status = 'Not Started',
            Priority = 'Normal',
            OwnerId = UserInfo.getUserId()
        );
        if (work.get('contactId') != null) {
            task.WhoId = (Id) String.valueOf(work.get('contactId'));
        }
        insert as user task;
        return due;
    }

    /** Keeps the newest rows and removes the rest, so the log never adds to the org's storage. */
    private static void trim() {
        List<Claude_Work__c> old = [SELECT Id FROM Claude_Work__c WITH USER_MODE ORDER BY Prepared_At__c DESC NULLS LAST, CreatedDate DESC LIMIT 200 OFFSET :KEEP];
        if (!old.isEmpty()) {
            delete as user old;
        }
    }

    // ------------------------------------------------------------------ the nightly run

    /**
     * @description Runs a shift without anyone watching: one piece in each job, because each piece
     * is its own call to Claude. AntsuranceDeskNightly starts it on a schedule.
     */
    public class Job implements Queueable, Database.AllowsCallouts {
        private List<String> kindKeys;
        private List<Id> recordIds;
        private List<String> names;

        /**
         * @description A job for the pieces of a plan.
         * @param plan The plan to work through
         */
        public Job(Plan plan) {
            kindKeys = new List<String>();
            recordIds = new List<Id>();
            names = new List<String>();
            for (Step step : plan.steps) {
                for (Item item : step.items) {
                    kindKeys.add(step.kind);
                    recordIds.add(item.recordId);
                    names.add(item.name);
                }
            }
        }

        private Job(List<String> kindKeys, List<Id> recordIds, List<String> names) {
            this.kindKeys = kindKeys;
            this.recordIds = recordIds;
            this.names = names;
        }

        /**
         * @description Whether there is anything to prepare.
         * @return True when the plan was empty
         */
        public Boolean isEmpty() {
            return recordIds.isEmpty();
        }

        /**
         * @description Prepares the first piece and hands the rest to the next job. Each job makes one
         * call to Claude, so no job comes near Salesforce's two minutes of callout time for a
         * transaction, and a piece that times out costs the shift that piece alone.
         * @param context The job's context
         */
        public void execute(QueueableContext context) {
            if (recordIds.isEmpty()) {
                return;
            }
            String kindKey = kindKeys.remove(0);
            Id recordId = recordIds.remove(0);
            String name = names.remove(0);
            try {
                AntsuranceDeskShift.prepare(kindKey, recordId);
            } catch (AntsuranceDeskShift.DeskException e) {
                // The piece is recorded as not prepared, with the reason, and the shift moves on.
                try {
                    if (e.worthRetrying) {
                        AntsuranceDeskShift.recordFailure(kindKey, recordId, name, e.getMessage());
                    }
                } catch (Exception unrecorded) {
                    System.debug(LoggingLevel.WARN, 'Claude\'s shift could not record a failed ' + kindKey + ' for ' + recordId + ': ' + unrecorded.getMessage());
                }
            }
            // A test may not chain jobs, so it runs one piece.
            if (!recordIds.isEmpty() && !Test.isRunningTest()) {
                System.enqueueJob(new Job(kindKeys, recordIds, names));
            }
        }
    }

    // ------------------------------------------------------------------ wording

    /** A date the way the cards show one: Oct 2, 2026. */
    public static String day(Date value) {
        return value == null ? '' : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    /** Whole dollars with separators: $47,500. */
    public static String money(Decimal amount) {
        return '$' + (amount == null ? 0 : amount).setScale(0, System.RoundingMode.HALF_UP).format();
    }

    private static Date nextWorkingDay() {
        Date next = Date.today().addDays(1);
        while (weekday(next) > 5) {
            next = next.addDays(1);
        }
        return next;
    }

    /** 1 for Monday to 7 for Sunday. */
    private static Integer weekday(Date value) {
        return Math.mod(Date.newInstance(1900, 1, 1).daysBetween(value), 7) + 1;
    }

    /** "a, b and c" */
    private static String sentenceList(List<String> parts) {
        if (parts.size() == 1) {
            return parts[0];
        }
        List<String> head = parts.clone();
        String last = head.remove(head.size() - 1);
        return String.join(head, ', ') + ' and ' + last;
    }
}
