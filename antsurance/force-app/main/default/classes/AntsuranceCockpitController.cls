/**
 * @description The Home cockpit: the book in six figures, the running user's day, the claims,
 * renewals, pipeline and underwriting referrals that need someone, and a briefing Claude writes
 * from exactly those lists. The briefing is stored on the user, so Home opens with it at once and
 * says when it was written. Everything is limited to what the running user can see.
 */
public with sharing class AntsuranceCockpitController {
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Set<String> WAITING_ON_CUSTOMER = new Set<String>{ 'Issued', 'Presented' };
    private static final Set<String> SERIOUS = new Set<String>{ 'Catastrophic', 'High' };
    // Most serious first. Claims without a severity come last.
    private static final List<String> SEVERITY_ORDER = new List<String>{ 'Catastrophic', 'High', 'Medium', 'Low', null };
    // The order a sale moves through, for the stage bar.
    private static final List<String> STAGE_ORDER = new List<String>{ 'Submission Received', 'Underwriting Review', 'Quote Issued', 'Bind Requested' };
    private static final Map<String, String> DASHBOARDS = new Map<String, String>{
        'book' => 'Book_of_Business',
        'claims' => 'Claims_Operations',
        'executive' => 'Executive_Overview'
    };
    private static final Integer MAX_OPEN_CLAIMS = 200;
    private static final Integer MAX_OPEN_SALES = 500;
    private static final Integer CLAIMS_SHOWN = 8;
    // Home pages the renewals six at a time, so the list can hold every policy the count above it names.
    private static final Integer RENEWALS_SHOWN = 40;
    private static final Integer QUOTES_SHOWN = 8;
    private static final Integer SALES_PER_STAGE = 5;
    private static final Integer UPCOMING_TASKS = 4;
    private static final Integer DUE_TASKS_SHOWN = 30;
    // The loss ratio trend covers this many days back from today, one entry a day.
    @TestVisible
    private static final Integer TREND_DAYS = 365;
    private static final Integer MAX_TREND_CLAIMS = 5000;
    @TestVisible
    private static final Integer RENEWAL_WINDOW_DAYS = 60;
    private static final Integer RENEWAL_SOON_DAYS = 30;
    @TestVisible
    private static final Integer STALE_QUOTE_DAYS = 15;
    private static final Integer BRIEFING_TOKENS = 1500;
    private static final Integer MAX_PRIORITIES = 5;
    private static final Integer MAX_WATCH = 3;
    private static final String NO_RECORD = 'none';
    private static final String BRIEF_DATA_OPEN = '<!-- antsurance-brief:v1 ';

    private static final String LOAD_ERROR = 'Home could not be loaded. Check your access to policies, cases, tasks, quotes and policy sales.';
    private static final String SAVE_ERROR = 'The briefing was written but could not be saved. Try again.';

    private static final String INSTRUCTIONS = String.join(
        new List<String>{
            'You write the morning briefing on the Home page of Antsurance, a property and casualty insurer. The reader works the book: their own tasks, open claims, renewals, quotes and referrals. They know insurance and they know these records; do not explain basics.',
            'From the lists in the request, say what matters today and where to start. Rank by consequence and by the clock: money at risk, a customer waiting, a deadline about to pass, something overdue.',
            'Use only the facts in the request. Quote figures exactly, in whole dollars. Dates as Oct 2. Never invent a record, a name or a number.',
            'Each priority is about exactly one record from the lists, named by its id. Do not write the id in the text. Do not give two priorities for the same record. Spread the priorities across kinds of work when the facts support it, rather than listing five tasks.',
            'Write plainly, in short sentences, the way a sharp colleague would say it. No dashes used as punctuation. No exclamation marks. ' + AntsuranceClaimRules.AMERICAN_ENGLISH,
            // A claim's reserve reads the same here as on the claim: never short because it is below the gross estimate.
            AntsuranceClaimRules.RESERVE_RULE +
            ' Each claim comes with where its reserve stands against what is payable, worked out from the claim as it is now. That line decides: ' +
            'say a reserve is short or needs lifting only when the request says it is below what is payable, and when a brief on file says otherwise about the reserve, the brief is out of date, so leave that part of it out.'
        },
        '\n'
    );

    // ------------------------------------------------------------------ what the page shows

    /**
     * @description Everything Home shows.
     */
    public class Cockpit {
        @AuraEnabled
        public String firstName;
        /** The day the lists are measured from, so the page and the server agree on "today". */
        @AuraEnabled
        public Date today = Date.today();
        @AuraEnabled
        public Figures figures = new Figures();
        @AuraEnabled
        public LossTrend lossTrend = new LossTrend();
        @AuraEnabled
        public Briefing briefing;
        @AuraEnabled
        public List<TaskRow> tasks = new List<TaskRow>();
        @AuraEnabled
        public Integer openTaskCount = 0;
        @AuraEnabled
        public Integer overdueTaskCount = 0;
        @AuraEnabled
        public Integer todayTaskCount = 0;
        @AuraEnabled
        public List<ClaimRow> claims = new List<ClaimRow>();
        @AuraEnabled
        public List<RenewalRow> renewals = new List<RenewalRow>();
        @AuraEnabled
        public Integer renewalCount = 0;
        @AuraEnabled
        public Decimal renewalPremium = 0;
        @AuraEnabled
        public List<Stage> stages = new List<Stage>();
        @AuraEnabled
        public Integer openSaleCount = 0;
        @AuraEnabled
        public Decimal openSaleAmount = 0;
        @AuraEnabled
        public List<QuoteRow> staleQuotes = new List<QuoteRow>();
        @AuraEnabled
        public Integer staleQuoteCount = 0;
        @AuraEnabled
        public List<ReferralRow> referrals = new List<ReferralRow>();
        /** Dashboard record ids by key (book, claims, executive), for the figures that open one. */
        @AuraEnabled
        public Map<String, Id> dashboards = new Map<String, Id>();
        /** How much prepared work waits on Claude's desk, and which piece matters most. */
        @AuraEnabled
        public AntsuranceDeskController.Summary desk;
    }

    /**
     * @description The six figures across the top.
     */
    public class Figures {
        @AuraEnabled
        public Integer policiesInForce = 0;
        @AuraEnabled
        public Integer customerCount = 0;
        @AuraEnabled
        public Decimal premiumInForce = 0;
        @AuraEnabled
        public Integer openClaimCount = 0;
        @AuraEnabled
        public Integer seriousClaimCount = 0;
        @AuraEnabled
        public Decimal outstandingReserve = 0;
        /** Incurred losses over a year of premium on policies in force, as a whole percentage. */
        @AuraEnabled
        public Integer lossRatio;
        @AuraEnabled
        public Integer renewalsSoonCount = 0;
        @AuraEnabled
        public Decimal renewalsSoonPremium = 0;
    }

    /**
     * @description How the loss ratio built over the last year: what had been incurred by each day, by date
     * of loss and at today's reserves, on the policies in force today. Over the premium in force, its last
     * day is the loss ratio among the figures.
     */
    public class LossTrend {
        /** The day the first entry of each list is about. Each list has one entry a day and ends today. */
        @AuraEnabled
        public Date startDate;
        @AuraEnabled
        public List<Decimal> incurred = new List<Decimal>();
        /** How many claims had a date of loss on or before each day. */
        @AuraEnabled
        public List<Integer> claims = new List<Integer>();
    }

    /**
     * @description One of the running user's open tasks.
     */
    public class TaskRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public Date dueDate;
        @AuraEnabled
        public String priority;
        @AuraEnabled
        public Id relatedId;
        @AuraEnabled
        public String relatedName;
        @AuraEnabled
        public String relatedKind;
        @AuraEnabled
        public String contactName;
    }

    /**
     * @description One open claim that needs attention.
     */
    public class ClaimRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String caseNumber;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public String handledBy;
        @AuraEnabled
        public Decimal reserve;
        @AuraEnabled
        public Decimal paid;
        @AuraEnabled
        public Decimal outstanding;
        @AuraEnabled
        public Date reportedDate;
        /** The headline of the stored Claude brief, when one has been written. */
        @AuraEnabled
        public String briefHeadline;
        /** The estimate less the deductible, and no more than the limit. Null without an estimate. */
        @AuraEnabled
        public Decimal payable;
        /** Where the reserve stands against that: adequate, short, above or unknown (AntsuranceClaimRules). */
        @AuraEnabled
        public String reserveStanding;
        /** The reserve less the payable amount: negative when short. */
        @AuraEnabled
        public Decimal reserveDifference;
    }

    /**
     * @description One policy coming up for renewal.
     */
    public class RenewalRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String policyNumber;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String paymentStatus;
        @AuraEnabled
        public String soldThrough;
        @AuraEnabled
        public Decimal premium;
        /** The premium on the renewal sale, when the renewal has been priced. */
        @AuraEnabled
        public Decimal renewalPremium;
        @AuraEnabled
        public Id renewalSaleId;
        @AuraEnabled
        public String renewalStage;
        @AuraEnabled
        public Date expirationDate;
    }

    /**
     * @description Open sales in one stage, largest first.
     */
    public class Stage {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Integer saleCount = 0;
        @AuraEnabled
        public Decimal amount = 0;
        @AuraEnabled
        public List<SaleRow> sales = new List<SaleRow>();
    }

    /**
     * @description One open policy sale.
     */
    public class SaleRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal amount;
        @AuraEnabled
        public Date closeDate;
        /** Who it is for, what line and what is next, for the row opened in place on Home. */
        @AuraEnabled
        public String customerName;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String nextStep;
    }

    /**
     * @description One quote the customer has had for 15 days or more.
     */
    public class QuoteRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public Id saleId;
        @AuraEnabled
        public String saleName;
        @AuraEnabled
        public String option;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public Date issuedDate;
        @AuraEnabled
        public Date validUntil;
    }

    /**
     * @description One quote waiting on an underwriter.
     */
    public class ReferralRow {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public Id saleId;
        @AuraEnabled
        public String saleName;
        @AuraEnabled
        public String option;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public List<String> reasons = new List<String>();
        /** What Claude's stored memo recommends, when one has been drafted. */
        @AuraEnabled
        public String memoRecommendation;
        @AuraEnabled
        public String memoHeadline;
    }

    /**
     * @description Claude's briefing, as stored on the user.
     */
    public class Briefing {
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public List<Priority> priorities = new List<Priority>();
        @AuraEnabled
        public List<Watch> watch = new List<Watch>();
        @AuraEnabled
        public Datetime writtenAt;
        /** True when it was written on an earlier day. Worked out on read, not stored. */
        @AuraEnabled
        public Boolean isStale = false;
        /** True when Home should have a new one written as it loads: this one is from an earlier day and the reader can reach Claude. Worked out on read, not stored. */
        @AuraEnabled
        public Boolean writeOnLoad = false;
    }

    /**
     * @description One thing to do first, about one record.
     */
    public class Priority {
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String why;
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String recordName;
        /** Task, Claim, Renewal, Quote, Referral or Policy sale. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String objectApiName;
        @AuraEnabled
        public String actionLabel;
        /** True when the work has been done since the briefing was written. Worked out on read, not stored. */
        @AuraEnabled
        public Boolean isDone = false;
    }

    /**
     * @description Something to keep an eye on.
     */
    public class Watch {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String recordName;
        @AuraEnabled
        public String objectApiName;
    }

    /** A record Claude may name, with what the page needs to link to it. */
    private class Candidate {
        Id recordId;
        String name;
        String kind;
        String objectApiName;
        String actionLabel;
        String facts;

        Candidate(Id recordId, String name, String kind, String objectApiName, String actionLabel, String facts) {
            this.recordId = recordId;
            this.name = name;
            this.kind = kind;
            this.objectApiName = objectApiName;
            this.actionLabel = actionLabel;
            this.facts = facts;
        }
    }

    // ------------------------------------------------------------------ entry points

    /**
     * @description Everything Home shows, with the stored briefing if there is one.
     * @return The cockpit for the running user
     * @throws AuraHandledException when the user cannot read one of the objects
     */
    @AuraEnabled(cacheable=true)
    public static Cockpit getCockpit() {
        try {
            Cockpit cockpit = build();
            cockpit.briefing = storedBriefing(cockpit);
            if (cockpit.briefing != null) {
                cockpit.briefing.writeOnLoad = cockpit.briefing.isStale && canReachClaude();
            }
            cockpit.desk = AntsuranceDeskController.summary();
            return cockpit;
        } catch (QueryException e) {
            throw error(LOAD_ERROR);
        }
    }

    /**
     * @description Has Claude write today's briefing from the lists Home shows, and stores it on the user.
     * @return The new briefing
     * @throws AuraHandledException when the lists cannot be read, Claude cannot be reached or the briefing cannot be saved
     */
    @AuraEnabled
    public static Briefing briefMe() {
        Cockpit cockpit;
        try {
            cockpit = build();
        } catch (QueryException e) {
            throw error(LOAD_ERROR);
        }
        Map<Id, Candidate> candidates = candidatesOf(cockpit);
        Briefing briefing;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, describe(cockpit, candidates)).returning(briefingShape(candidates));
            question.maxTokens = BRIEFING_TOKENS;
            briefing = toBriefing(AntsuranceAiClient.ask(question).data, candidates);
        } catch (AntsuranceAiClient.AiException e) {
            throw error(e.getMessage());
        }
        briefing.writtenAt = Datetime.now();
        try {
            // The briefing is the user's own note to themselves, so it is saved whatever their access to the User object.
            update new User(Id = UserInfo.getUserId(), Claude_Briefing__c = JSON.serialize(briefing), Claude_Briefing_At__c = briefing.writtenAt);
        } catch (DmlException e) {
            throw error(SAVE_ERROR);
        }
        return briefing;
    }

    /**
     * @description Today's briefing for a Home that has just loaded with one from an earlier day: has Claude
     * write a new one, unless one was written today meanwhile (another tab, a cached page) or the reader
     * cannot reach Claude. Home asks once per load; pressing the button is briefMe.
     * @return Today's briefing, or the stored one unchanged when no new one was written
     * @throws AuraHandledException when the lists cannot be read, Claude cannot be reached or the briefing cannot be saved
     */
    @AuraEnabled
    public static Briefing briefMeForToday() {
        Briefing stored = storedBriefing(null);
        if (stored == null || !stored.isStale || !canReachClaude()) {
            return stored;
        }
        return briefMe();
    }

    /** Stands in for the reader's access to Claude in a test, where nothing is written unasked unless the test says so. */
    @TestVisible
    private static Boolean claudeAccess;

    /** True when one of the reader's permission sets grants a principal on an external credential, which is what a call to Claude runs as. */
    private static Boolean canReachClaude() {
        Integer held = [
            SELECT COUNT()
            FROM SetupEntityAccess
            WHERE SetupEntityType = 'ExternalCredentialParameter' AND ParentId IN (SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId())
            LIMIT 1
        ];
        return Test.isRunningTest() ? claudeAccess == true : held > 0;
    }

    // ------------------------------------------------------------------ the lists

    private static Cockpit build() {
        Cockpit cockpit = new Cockpit();
        cockpit.firstName = UserInfo.getFirstName();
        loadFigures(cockpit);
        loadLossTrend(cockpit);
        loadTasks(cockpit);
        loadClaims(cockpit);
        loadRenewals(cockpit);
        loadPipeline(cockpit);
        loadStaleQuotes(cockpit);
        loadReferrals(cockpit);
        for (Dashboard dashboard : [SELECT Id, DeveloperName FROM Dashboard WHERE DeveloperName IN :DASHBOARDS.values() WITH USER_MODE]) {
            for (String key : DASHBOARDS.keySet()) {
                if (DASHBOARDS.get(key) == dashboard.DeveloperName) {
                    cockpit.dashboards.put(key, dashboard.Id);
                }
            }
        }
        return cockpit;
    }

    private static void loadFigures(Cockpit cockpit) {
        Figures figures = cockpit.figures;
        figures.customerCount = [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName != 'Agency' WITH USER_MODE];
        AggregateResult book = [
            SELECT COUNT(Id) policies, SUM(Annual_Premium__c) premium, SUM(Incurred_Losses__c) incurred
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE
            WITH USER_MODE
        ];
        figures.policiesInForce = (Integer) book.get('policies');
        figures.premiumInForce = book.get('premium') == null ? 0 : (Decimal) book.get('premium');
        Decimal incurred = book.get('incurred') == null ? 0 : (Decimal) book.get('incurred');
        figures.lossRatio = figures.premiumInForce > 0 ? (incurred / figures.premiumInForce * 100).setScale(0, RoundingMode.HALF_UP).intValue() : null;

        Date soon = Date.today().addDays(RENEWAL_SOON_DAYS);
        AggregateResult renewals = [
            SELECT COUNT(Id) policies, SUM(Annual_Premium__c) premium
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :soon
            WITH USER_MODE
        ];
        figures.renewalsSoonCount = (Integer) renewals.get('policies');
        figures.renewalsSoonPremium = renewals.get('premium') == null ? 0 : (Decimal) renewals.get('premium');
    }

    /** Each day first gets the losses that happened on it; then the lists become running totals. */
    private static void loadLossTrend(Cockpit cockpit) {
        LossTrend trend = cockpit.lossTrend;
        trend.startDate = Date.today().addDays(-TREND_DAYS);
        for (Integer day = 0; day <= TREND_DAYS; day++) {
            trend.incurred.add(0);
            trend.claims.add(0);
        }
        for (Case claim : [
            SELECT Date_of_Loss__c, Reported_Date__c, CreatedDate, Reserve_Amount__c, Paid_Amount__c
            FROM Case
            WHERE RecordType.DeveloperName = 'Claim' AND Policy__r.Status__c IN :IN_FORCE
            WITH USER_MODE
            ORDER BY Date_of_Loss__c DESC NULLS LAST
            LIMIT :MAX_TREND_CLAIMS
        ]) {
            Integer day = trendDay(trend.startDate, claim.Date_of_Loss__c ?? claim.Reported_Date__c ?? claim.CreatedDate.date());
            // Incurred the way the policy's own total counts it: the higher of reserve and paid.
            Decimal reserve = claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c;
            Decimal paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
            trend.incurred[day] += Math.max(reserve, paid);
            trend.claims[day] += 1;
        }
        for (Integer day = 1; day <= TREND_DAYS; day++) {
            trend.incurred[day] += trend.incurred[day - 1];
            trend.claims[day] += trend.claims[day - 1];
        }
    }

    /** Where a date falls in the trend's lists. Anything before the first day counts on it; a date still to come counts today. */
    private static Integer trendDay(Date startDate, Date day) {
        return day == null ? 0 : Math.min(Math.max(startDate.daysBetween(day), 0), TREND_DAYS);
    }

    /** Overdue and due today in full, then the next few, each named for what it is about. */
    private static void loadTasks(Cockpit cockpit) {
        AntsuranceTasksController.Board board = AntsuranceTasksController.getMyOpenTasks();
        cockpit.openTaskCount = board.openCount;
        cockpit.overdueTaskCount = board.overdueCount;
        Integer upcoming = 0;
        for (AntsuranceTasksController.Row source : board.tasks) {
            Boolean isDue = source.dueDate != null && source.dueDate <= cockpit.today;
            if (isDue && source.dueDate == cockpit.today) {
                cockpit.todayTaskCount++;
            }
            if ((isDue && cockpit.tasks.size() - upcoming >= DUE_TASKS_SHOWN) || (!isDue && (source.dueDate == null || upcoming >= UPCOMING_TASKS))) {
                continue;
            }
            if (!isDue) {
                upcoming++;
            }
            TaskRow row = new TaskRow();
            row.recordId = source.recordId;
            row.subject = source.subject;
            row.dueDate = source.dueDate;
            row.priority = source.priority;
            row.relatedId = source.relatedId;
            row.relatedName = source.relatedName;
            row.relatedKind = source.relatedKind;
            row.contactName = source.contactName;
            cockpit.tasks.add(row);
        }
    }

    /** Every open claim is counted; the most serious that have waited longest are listed. */
    private static void loadClaims(Cockpit cockpit) {
        Map<String, List<ClaimRow>> bySeverity = new Map<String, List<ClaimRow>>();
        for (Case claim : [
            SELECT
                Id, CaseNumber, Subject, AccountId, Account.Name, Status, Severity__c, Handled_By__c, Reserve_Amount__c, Paid_Amount__c, Reported_Date__c,
                Estimated_Loss__c, Coverage_Read__c, Policy__r.Deductible__c, Policy__r.Coverage_Limit__c, Claude_Brief__c
            FROM Case
            WHERE IsClosed = FALSE AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Reported_Date__c ASC NULLS LAST, CaseNumber
            LIMIT :MAX_OPEN_CLAIMS
        ]) {
            ClaimRow row = new ClaimRow();
            row.recordId = claim.Id;
            row.caseNumber = claim.CaseNumber;
            row.subject = String.isBlank(claim.Subject) ? claim.CaseNumber : claim.Subject;
            row.accountId = claim.AccountId;
            row.accountName = claim.Account?.Name;
            row.status = claim.Status;
            row.severity = claim.Severity__c;
            row.handledBy = claim.Handled_By__c;
            row.reserve = claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c;
            row.paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
            row.outstanding = row.reserve - row.paid;
            row.reportedDate = claim.Reported_Date__c;
            row.briefHeadline = briefHeadline(claim.Claude_Brief__c);
            // Where the reserve stands against what is payable, by the rule every writer shares.
            AntsuranceClaimRules.Terms terms = AntsuranceClaimRules.termsFor(claim);
            AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(row.reserve, claim.Estimated_Loss__c, terms.deductible, terms.limitAmount);
            row.payable = at.payable;
            row.reserveStanding = at.standing;
            row.reserveDifference = at.difference;

            cockpit.figures.openClaimCount++;
            cockpit.figures.outstandingReserve += row.outstanding;
            if (SERIOUS.contains(claim.Severity__c)) {
                cockpit.figures.seriousClaimCount++;
            }
            String bucket = SEVERITY_ORDER.contains(claim.Severity__c) ? claim.Severity__c : null;
            if (!bySeverity.containsKey(bucket)) {
                bySeverity.put(bucket, new List<ClaimRow>());
            }
            bySeverity.get(bucket).add(row);
        }
        for (String severity : SEVERITY_ORDER) {
            for (ClaimRow row : bySeverity.containsKey(severity) ? bySeverity.get(severity) : new List<ClaimRow>()) {
                if (cockpit.claims.size() < CLAIMS_SHOWN) {
                    cockpit.claims.add(row);
                }
            }
        }
    }

    /** The headline Claude gave a claim, read from the data stored after the brief's Markdown. */
    private static String briefHeadline(String stored) {
        if (String.isBlank(stored) || !stored.contains(BRIEF_DATA_OPEN)) {
            return null;
        }
        try {
            String raw = stored.substringAfter(BRIEF_DATA_OPEN).substringBeforeLast(' -->').replace('--&gt;', '-->');
            Map<String, Object> brief = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(raw)).get('brief');
            return brief == null ? null : (String) brief.get('headline');
        } catch (Exception e) {
            // A brief edited by hand has no headline to show; the claim page still shows it in full.
            return null;
        }
    }

    private static void loadRenewals(Cockpit cockpit) {
        Date windowEnd = Date.today().addDays(RENEWAL_WINDOW_DAYS);
        AggregateResult totals = [
            SELECT COUNT(Id) policies, SUM(Annual_Premium__c) premium
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :windowEnd
            WITH USER_MODE
        ];
        cockpit.renewalCount = (Integer) totals.get('policies');
        cockpit.renewalPremium = totals.get('premium') == null ? 0 : (Decimal) totals.get('premium');

        Map<Id, RenewalRow> byPolicy = new Map<Id, RenewalRow>();
        for (Policy__c policy : [
            SELECT Id, Name, Account__c, Account__r.Name, Line_of_Business__c, Status__c, Payment_Status__c, Sold_Through__c, Annual_Premium__c, Expiration_Date__c
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :windowEnd
            WITH USER_MODE
            ORDER BY Expiration_Date__c ASC, Annual_Premium__c DESC NULLS LAST
            LIMIT :RENEWALS_SHOWN
        ]) {
            RenewalRow row = new RenewalRow();
            row.recordId = policy.Id;
            row.policyNumber = policy.Name;
            row.accountId = policy.Account__c;
            row.accountName = policy.Account__r?.Name;
            row.lineOfBusiness = policy.Line_of_Business__c;
            row.status = policy.Status__c;
            row.paymentStatus = policy.Payment_Status__c;
            row.soldThrough = policy.Sold_Through__c;
            row.premium = policy.Annual_Premium__c;
            row.expirationDate = policy.Expiration_Date__c;
            cockpit.renewals.add(row);
            byPolicy.put(policy.Id, row);
        }
        // The renewal sale carries the premium on offer. An open sale wins over a closed one.
        for (Opportunity sale : [
            SELECT Id, Policy__c, StageName, Amount
            FROM Opportunity
            WHERE Policy__c IN :byPolicy.keySet() AND Type = 'Renewal'
            WITH USER_MODE
            ORDER BY IsClosed DESC, CreatedDate ASC
        ]) {
            RenewalRow row = byPolicy.get(sale.Policy__c);
            row.renewalSaleId = sale.Id;
            row.renewalStage = sale.StageName;
            row.renewalPremium = sale.Amount;
        }
    }

    private static void loadPipeline(Cockpit cockpit) {
        Map<String, Stage> byName = new Map<String, Stage>();
        for (String name : STAGE_ORDER) {
            Stage stage = new Stage();
            stage.name = name;
            byName.put(name, stage);
            cockpit.stages.add(stage);
        }
        for (Opportunity sale : [
            SELECT Id, Name, StageName, Amount, CloseDate, Account.Name, Line_of_Business__c, NextStep
            FROM Opportunity
            WHERE IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Amount DESC NULLS LAST, Name
            LIMIT :MAX_OPEN_SALES
        ]) {
            Stage stage = byName.get(sale.StageName);
            if (stage == null) {
                // A stage outside the usual path still counts; it is drawn after the others.
                stage = new Stage();
                stage.name = sale.StageName;
                byName.put(sale.StageName, stage);
                cockpit.stages.add(stage);
            }
            Decimal amount = sale.Amount == null ? 0 : sale.Amount;
            stage.saleCount++;
            stage.amount += amount;
            cockpit.openSaleCount++;
            cockpit.openSaleAmount += amount;
            if (stage.sales.size() < SALES_PER_STAGE) {
                SaleRow row = new SaleRow();
                row.recordId = sale.Id;
                row.name = sale.Name;
                row.amount = amount;
                row.closeDate = sale.CloseDate;
                row.customerName = sale.Account?.Name;
                row.lineOfBusiness = sale.Line_of_Business__c;
                row.nextStep = sale.NextStep;
                stage.sales.add(row);
            }
        }
    }

    private static void loadStaleQuotes(Cockpit cockpit) {
        Date issuedBy = Date.today().addDays(-STALE_QUOTE_DAYS);
        cockpit.staleQuoteCount = [SELECT COUNT() FROM Quote WHERE Status IN :WAITING_ON_CUSTOMER AND Issued_Date__c <= :issuedBy WITH USER_MODE];
        for (Quote quote : [
            SELECT Id, Name, OpportunityId, Opportunity.Name, Opportunity.Account.Name, Annual_Premium__c, Issued_Date__c, ExpirationDate
            FROM Quote
            WHERE Status IN :WAITING_ON_CUSTOMER AND Issued_Date__c <= :issuedBy
            WITH USER_MODE
            ORDER BY Issued_Date__c ASC, Annual_Premium__c DESC NULLS LAST
            LIMIT :QUOTES_SHOWN
        ]) {
            QuoteRow row = new QuoteRow();
            row.recordId = quote.Id;
            row.saleId = quote.OpportunityId;
            row.saleName = quote.Opportunity?.Name;
            row.option = quote.Name;
            row.accountName = quote.Opportunity?.Account?.Name;
            row.premium = quote.Annual_Premium__c;
            row.issuedDate = quote.Issued_Date__c;
            row.validUntil = quote.ExpirationDate;
            cockpit.staleQuotes.add(row);
        }
    }

    private static void loadReferrals(Cockpit cockpit) {
        for (Quote quote : [
            SELECT
                Id, Name, OpportunityId, Opportunity.Name, Opportunity.Account.Name, Opportunity.Line_of_Business__c, Annual_Premium__c, Configuration__c,
                Underwriting_Memo__c
            FROM Quote
            WHERE Needs_Underwriting_Review__c = TRUE AND Opportunity.IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Annual_Premium__c DESC NULLS LAST, Name
            LIMIT :QUOTES_SHOWN
        ]) {
            ReferralRow row = new ReferralRow();
            row.recordId = quote.Id;
            row.saleId = quote.OpportunityId;
            row.saleName = quote.Opportunity?.Name;
            row.option = quote.Name;
            row.accountName = quote.Opportunity?.Account?.Name;
            row.lineOfBusiness = quote.Opportunity?.Line_of_Business__c;
            row.premium = quote.Annual_Premium__c;
            row.reasons = referralReasons(quote.Configuration__c);
            if (String.isNotBlank(quote.Underwriting_Memo__c)) {
                try {
                    Map<String, Object> memo = (Map<String, Object>) JSON.deserializeUntyped(quote.Underwriting_Memo__c);
                    row.memoRecommendation = (String) memo.get('recommendation');
                    row.memoHeadline = (String) memo.get('headline');
                } catch (Exception e) {
                    // An unreadable memo is treated as none; the quote page can redraft it.
                    row.memoRecommendation = null;
                }
            }
            cockpit.referrals.add(row);
        }
    }

    /** The reasons the configurator recorded when it priced the quote. */
    private static List<String> referralReasons(String configuration) {
        List<String> reasons = new List<String>();
        if (String.isBlank(configuration)) {
            return reasons;
        }
        try {
            Map<String, Object> pricing = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(configuration)).get('pricing');
            if (pricing != null && pricing.get('referrals') instanceof List<Object>) {
                for (Object reason : (List<Object>) pricing.get('referrals')) {
                    reasons.add(String.valueOf(reason));
                }
            }
        } catch (Exception e) {
            // A configuration that cannot be read has no reasons to show.
            reasons.clear();
        }
        return reasons;
    }

    // ------------------------------------------------------------------ the briefing

    /** The stored briefing, marked stale when it is from an earlier day and with finished work ticked off. */
    private static Briefing storedBriefing(Cockpit cockpit) {
        // The user's own note to themselves, read whatever their access to the User object.
        User me = [SELECT Claude_Briefing__c, Claude_Briefing_At__c FROM User WHERE Id = :UserInfo.getUserId()];
        if (String.isBlank(me.Claude_Briefing__c)) {
            return null;
        }
        Briefing briefing;
        try {
            briefing = (Briefing) JSON.deserialize(me.Claude_Briefing__c, Briefing.class);
        } catch (JSONException e) {
            // A briefing edited into something unreadable is treated as none; it can be written again.
            return null;
        }
        briefing.writtenAt = me.Claude_Briefing_At__c == null ? briefing.writtenAt : me.Claude_Briefing_At__c;
        briefing.isStale = briefing.writtenAt == null || briefing.writtenAt.date() < Date.today();
        markDone(briefing);
        return briefing;
    }

    /** A priority is done when its task or claim has closed, or its referral has been decided, since the briefing was written. */
    private static void markDone(Briefing briefing) {
        Set<Id> taskIds = new Set<Id>();
        Set<Id> caseIds = new Set<Id>();
        Set<Id> quoteIds = new Set<Id>();
        for (Priority priority : briefing.priorities) {
            if (priority.recordId == null) {
                continue;
            }
            SObjectType type = priority.recordId.getSObjectType();
            if (type == Task.SObjectType) {
                taskIds.add(priority.recordId);
            } else if (type == Case.SObjectType) {
                caseIds.add(priority.recordId);
            } else if (type == Quote.SObjectType && priority.kind == 'Referral') {
                quoteIds.add(priority.recordId);
            }
        }
        Set<Id> open = new Set<Id>();
        if (!taskIds.isEmpty()) {
            open.addAll(new Map<Id, Task>([SELECT Id FROM Task WHERE Id IN :taskIds AND IsClosed = FALSE WITH USER_MODE]).keySet());
        }
        if (!caseIds.isEmpty()) {
            open.addAll(new Map<Id, Case>([SELECT Id FROM Case WHERE Id IN :caseIds AND IsClosed = FALSE WITH USER_MODE]).keySet());
        }
        if (!quoteIds.isEmpty()) {
            open.addAll(new Map<Id, Quote>([SELECT Id FROM Quote WHERE Id IN :quoteIds AND Needs_Underwriting_Review__c = TRUE WITH USER_MODE]).keySet());
        }
        for (Priority priority : briefing.priorities) {
            Boolean tracked = taskIds.contains(priority.recordId) || caseIds.contains(priority.recordId) || quoteIds.contains(priority.recordId);
            priority.isDone = tracked && !open.contains(priority.recordId);
        }
    }

    /** Where a claim's reserve stands against what is payable, as the words the briefing is given. */
    @TestVisible
    private static String reserveStanding(ClaimRow claim) {
        if (claim.reserveStanding == AntsuranceClaimRules.ADEQUATE) {
            return ', the reserve covers what is payable (' + money(claim.payable) + ')';
        }
        if (claim.reserveStanding == AntsuranceClaimRules.SHORT_OF) {
            return ', the reserve is ' + money(Math.abs(claim.reserveDifference)) + ' below what is payable (' + money(claim.payable) + ')';
        }
        if (claim.reserveStanding == AntsuranceClaimRules.ABOVE) {
            return ', the reserve is ' + money(claim.reserveDifference) + ' above what is payable (' + money(claim.payable) + ')';
        }
        return ', no estimate yet to measure the reserve against';
    }

    /** Every record Claude may name, by id, with the facts it is given about each. */
    private static Map<Id, Candidate> candidatesOf(Cockpit cockpit) {
        Map<Id, Candidate> candidates = new Map<Id, Candidate>();
        for (TaskRow task : cockpit.tasks) {
            Integer days = task.dueDate == null ? null : task.dueDate.daysBetween(cockpit.today);
            String due = days == null ? 'no due date' : days > 0 ? days + (days == 1 ? ' day overdue' : ' days overdue') : days == 0 ? 'due today' : 'due ' + day(task.dueDate);
            String about = String.isBlank(task.relatedName) ? '' : ', about the ' + (task.relatedKind == null ? 'record' : task.relatedKind.toLowerCase()) + ' "' + task.relatedName + '"';
            String who = String.isBlank(task.contactName) ? '' : ', with ' + task.contactName;
            candidates.put(
                task.recordId,
                new Candidate(task.recordId, task.subject, 'Task', 'Task', 'Open task', '"' + task.subject + '", ' + due + ', ' + (task.priority == null ? 'Normal' : task.priority) + ' priority' + about + who)
            );
        }
        for (ClaimRow claim : cockpit.claims) {
            Integer daysOpen = claim.reportedDate == null ? null : claim.reportedDate.daysBetween(cockpit.today);
            candidates.put(
                claim.recordId,
                new Candidate(
                    claim.recordId,
                    claim.subject,
                    'Claim',
                    'Case',
                    'Open claim',
                    '"' + claim.subject + '" for ' + claim.accountName + ': ' + (claim.severity == null ? 'no' : claim.severity) + ' severity, status ' + claim.status +
                        ', reserve ' + money(claim.reserve) + ', paid ' + money(claim.paid) + ', outstanding ' + money(claim.outstanding) + reserveStanding(claim) +
                        (daysOpen == null ? '' : ', open ' + daysOpen + ' days') + (String.isBlank(claim.handledBy) ? '' : ', handled by ' + claim.handledBy) +
                        (String.isBlank(claim.briefHeadline) ? '' : '. Brief on file: ' + claim.briefHeadline)
                )
            );
        }
        for (RenewalRow renewal : cockpit.renewals) {
            Integer daysLeft = cockpit.today.daysBetween(renewal.expirationDate);
            String offer = 'not priced yet';
            if (renewal.renewalPremium != null && renewal.premium != null) {
                Decimal change = renewal.renewalPremium - renewal.premium;
                offer = 'renewal priced at ' + money(renewal.renewalPremium) + ' (' + (change >= 0 ? 'up ' : 'down ') + money(Math.abs(change)) + '), sale at ' + renewal.renewalStage;
            }
            candidates.put(
                renewal.recordId,
                new Candidate(
                    renewal.recordId,
                    renewal.policyNumber + ', ' + renewal.accountName,
                    'Renewal',
                    'Policy__c',
                    'Open policy',
                    renewal.lineOfBusiness + ' policy ' + renewal.policyNumber + ' for ' + renewal.accountName + ': expires ' + day(renewal.expirationDate) + ' (' + daysLeft +
                        ' days), premium ' + money(renewal.premium) + ', ' + offer + ', status ' + renewal.status +
                        (String.isBlank(renewal.paymentStatus) ? '' : ', payments ' + renewal.paymentStatus) + ', sold through ' + renewal.soldThrough
                )
            );
        }
        for (ReferralRow referral : cockpit.referrals) {
            candidates.put(
                referral.recordId,
                new Candidate(
                    referral.recordId,
                    referral.saleName + ', ' + referral.option,
                    'Referral',
                    'Quote',
                    'Review quote',
                    'Quote "' + referral.option + '" on ' + referral.saleName + ', ' + money(referral.premium) + ' a year, waiting on an underwriter because: ' +
                        (referral.reasons.isEmpty() ? 'not recorded' : String.join(referral.reasons, '; ')) +
                        (referral.memoRecommendation == null ? '. No memo drafted yet' : '. Memo on file recommends: ' + referral.memoRecommendation)
                )
            );
        }
        for (QuoteRow quote : cockpit.staleQuotes) {
            if (candidates.containsKey(quote.recordId)) {
                continue;
            }
            Integer waited = quote.issuedDate.daysBetween(cockpit.today);
            candidates.put(
                quote.recordId,
                new Candidate(
                    quote.recordId,
                    quote.saleName + ', ' + quote.option,
                    'Quote',
                    'Quote',
                    'Open quote',
                    'Quote "' + quote.option + '" on ' + quote.saleName + ', ' + money(quote.premium) + ' a year, with the customer ' + waited + ' days' +
                        (quote.validUntil == null ? '' : ', valid until ' + day(quote.validUntil))
                )
            );
        }
        return candidates;
    }

    /** Everything Claude gets: the figures, then each list with one line per record, led by its id. */
    private static String describe(Cockpit cockpit, Map<Id, Candidate> candidates) {
        Figures figures = cockpit.figures;
        List<String> lines = new List<String>{
            'Today is ' + Datetime.now().format('EEEE, MMM d, yyyy') + '. The reader is ' + UserInfo.getName() + '.',
            '',
            'The book: ' + figures.policiesInForce + ' policies in force, ' + money(figures.premiumInForce) + ' premium in force, loss ratio ' +
                (figures.lossRatio == null ? 'not known' : figures.lossRatio + '%') + '. ' + figures.openClaimCount + ' open claims (' + figures.seriousClaimCount +
                ' high or catastrophic) with ' + money(figures.outstandingReserve) + ' outstanding reserve. ' + cockpit.renewalCount + ' policies renew in the next ' +
                RENEWAL_WINDOW_DAYS + ' days (' + money(cockpit.renewalPremium) + ' premium), ' + figures.renewalsSoonCount + ' of them within ' + RENEWAL_SOON_DAYS + ' days.',
            'The reader has ' + cockpit.openTaskCount + ' open tasks: ' + cockpit.overdueTaskCount + ' overdue and ' + cockpit.todayTaskCount + ' due today.',
            'Open pipeline: ' + cockpit.openSaleCount + ' policy sales worth ' + money(cockpit.openSaleAmount) + '.'
        };
        for (Stage stage : cockpit.stages) {
            lines.add('- ' + stage.name + ': ' + stage.saleCount + ' sales, ' + money(stage.amount));
        }
        lines.add(cockpit.staleQuoteCount + ' quotes have been with a customer ' + STALE_QUOTE_DAYS + ' days or more. ' + cockpit.referrals.size() + ' quotes wait on an underwriter.');
        for (String kind : new List<String>{ 'Task', 'Claim', 'Renewal', 'Referral', 'Quote' }) {
            List<String> rows = new List<String>();
            for (Candidate candidate : candidates.values()) {
                if (candidate.kind == kind) {
                    rows.add('- id ' + candidate.recordId + ': ' + candidate.facts);
                }
            }
            if (!rows.isEmpty()) {
                lines.add('');
                lines.add(headingFor(kind));
                lines.addAll(rows);
            }
        }
        return String.join(lines, '\n');
    }

    private static String headingFor(String kind) {
        switch on kind {
            when 'Task' {
                return 'The reader\'s tasks that are overdue, due today or coming up:';
            }
            when 'Claim' {
                return 'Open claims that most need attention, most serious first:';
            }
            when 'Renewal' {
                return 'Policies renewing in the next ' + RENEWAL_WINDOW_DAYS + ' days, soonest first:';
            }
            when 'Referral' {
                return 'Quotes waiting on an underwriter:';
            }
            when else {
                return 'Quotes the customer has had ' + STALE_QUOTE_DAYS + ' days or more:';
            }
        }
    }

    private static AntsuranceAiClient.Shape briefingShape(Map<Id, Candidate> candidates) {
        List<String> ids = new List<String>();
        for (Id recordId : candidates.keySet()) {
            ids.add(recordId);
        }
        List<String> idsOrNone = new List<String>(ids);
        idsOrNone.add(NO_RECORD);
        AntsuranceAiClient.Shape priority = new AntsuranceAiClient.Shape()
            .field('recordId', AntsuranceAiClient.choice(ids, 'The id of the one record this is about, copied from the lists.'))
            .field('title', AntsuranceAiClient.text('What to do, as an instruction of at most nine words that names the customer or the subject, such as Chase the Sagebrush loss runs.'))
            .field('why', AntsuranceAiClient.text('One sentence of at most 22 words: the fact that makes this matter today, with its figure or date.'));
        AntsuranceAiClient.Shape watch = new AntsuranceAiClient.Shape()
            .field('recordId', AntsuranceAiClient.choice(idsOrNone, 'The id of the record this is about, or none when it is about the book as a whole.'))
            .field('label', AntsuranceAiClient.text('Two to four words naming it, such as Workers comp loss ratio.'))
            .field('detail', AntsuranceAiClient.text('One sentence of at most 22 words saying what to keep an eye on and why.'));
        return new AntsuranceAiClient.Shape()
            .field('priorities', AntsuranceAiClient.listOf(priority.toJson(), 'Three to five things to do first today, most important first, each about a different record.'))
            .field('watch', AntsuranceAiClient.listOf(watch.toJson(), 'Two or three things that need no action today but could turn into one. Not a repeat of a priority.'))
            .field('headline', AntsuranceAiClient.text('One sentence of at most 24 words that sums up the day: what is at stake and where to start.'));
    }

    /** Turns Claude's answer into a briefing, keeping only records it was given and filling in what the page links to. */
    private static Briefing toBriefing(Map<String, Object> answer, Map<Id, Candidate> candidates) {
        Briefing briefing = new Briefing();
        briefing.headline = (String) answer.get('headline');
        Set<Id> used = new Set<Id>();
        if (answer.get('priorities') instanceof List<Object>) {
            for (Object item : (List<Object>) answer.get('priorities')) {
                Map<String, Object> source = (Map<String, Object>) item;
                Candidate candidate = candidateFor(source.get('recordId'), candidates);
                if (candidate == null || used.contains(candidate.recordId) || briefing.priorities.size() >= MAX_PRIORITIES) {
                    continue;
                }
                used.add(candidate.recordId);
                Priority priority = new Priority();
                priority.title = (String) source.get('title');
                priority.why = (String) source.get('why');
                priority.recordId = candidate.recordId;
                priority.recordName = candidate.name;
                priority.kind = candidate.kind;
                priority.objectApiName = candidate.objectApiName;
                priority.actionLabel = candidate.actionLabel;
                briefing.priorities.add(priority);
            }
        }
        if (answer.get('watch') instanceof List<Object>) {
            for (Object item : (List<Object>) answer.get('watch')) {
                if (briefing.watch.size() >= MAX_WATCH) {
                    break;
                }
                Map<String, Object> source = (Map<String, Object>) item;
                Watch watch = new Watch();
                watch.label = (String) source.get('label');
                watch.detail = (String) source.get('detail');
                Candidate candidate = candidateFor(source.get('recordId'), candidates);
                if (candidate != null) {
                    watch.recordId = candidate.recordId;
                    watch.recordName = candidate.name;
                    watch.objectApiName = candidate.objectApiName;
                }
                briefing.watch.add(watch);
            }
        }
        return briefing;
    }

    private static Candidate candidateFor(Object value, Map<Id, Candidate> candidates) {
        String text = value == null ? null : String.valueOf(value);
        if (String.isBlank(text) || text == NO_RECORD || !(text instanceof Id)) {
            return null;
        }
        return candidates.get((Id) text);
    }

    // ------------------------------------------------------------------ helpers

    /** A date the way the cards show one, Oct 2, so Claude repeats it in that form. */
    private static String day(Date value) {
        return Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d');
    }

    private static String money(Decimal amount) {
        return amount == null ? 'none' : '$' + amount.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static AuraHandledException error(String message) {
        AuraHandledException problem = new AuraHandledException(message);
        problem.setMessage(message);
        return problem;
    }
}
