/**
 * @description Puts the showcase claims back into their demo state after the demo data is loaded.
 * A reload brings back the first estimate on the burst pipe claim, drops every photo and document,
 * and loses everything Claude wrote. This class attaches the sample files again, raises that
 * estimate to what its documents add up to, and has Claude redo its work one step at a time.
 *
 * It is driven by scripts/prepare_demo.sh, one Anonymous Apex run per step, because Salesforce
 * allows one Claude call per transaction and a callout cannot follow a save. Every part is safe to
 * run twice: a file already on its claim is left alone, an estimate already raised is left alone,
 * and a step whose work is on the claim is skipped unless it is asked for again.
 *
 * It also looks past the showcase claims. checkCoverageEverywhere() gives every open claim a
 * coverage check, so a claim off the demo's path is not three empty cards, and outOfDate() lists
 * every stored piece of Claude's work, on any open claim, that no longer matches its claim.
 *
 * It never clears or reloads data, and refuses to run in a production org.
 */
public with sharing class AntsuranceDemoPrep {
    @TestVisible
    private static final String PIPE_CLAIM = 'Burst pipe flooded finished basement';
    @TestVisible
    private static final String SCRAPE_CLAIM = 'Parking lot scrape, rear quarter panel';
    @TestVisible
    private static final String REAR_END_CLAIM = 'Rear-ended at a red light on Harlem Ave';
    @TestVisible
    private static final String ROOF_CLAIM = 'Installer fell from second-story roof';
    @TestVisible
    private static final String DEER_CLAIM = 'Deer strike on Route 20, front-end damage';

    // The burst pipe claim is seeded with its first estimate. Its two documents then come in higher:
    // mitigation $9,971 and rebuild $27,450, with the furnace at $5,500 and contents at $6,000.
    @TestVisible
    private static final Decimal PIPE_FIRST_ESTIMATE = 47500;
    @TestVisible
    private static final Decimal PIPE_DOCUMENTS_TOTAL = 48921;
    private static final List<String> PIPE_DOCUMENTS = new List<String>{ 'Mitigation invoice, Lakeshore Restoration', 'Rebuild estimate, Northshore Renovation' };
    @TestVisible
    private static final String ESTIMATE_NOTE =
        '**Estimate raised:** Estimate raised to $48,921 after the mitigation invoice and rebuild estimate came in: ' +
        'mitigation $9,971, rebuild $27,450, furnace $5,500 and contents $6,000. The reserve has not been changed.';

    @TestVisible
    private static final String NOT_HERE = 'Demo prep does not run in a production org. Use a scratch org, a sandbox, a trial or a Developer Edition org.';
    private static final String UNKNOWN_STEP = 'That is not a step of the demo prep.';

    private static final String KIND_PHOTOS = 'photos';
    private static final String KIND_PHOTOS_FINISH = 'photos-finish';
    private static final String KIND_DOCUMENT = 'document';
    private static final String KIND_COVERAGE = 'coverage';
    private static final String KIND_REPORT = 'report';
    private static final String KIND_BRIEF = 'brief';

    // A claim in one of these is finished: nobody opens it to work it, so its stored work is left as it is.
    private static final Set<String> SETTLED = new Set<String>{ 'Closed', 'Denied' };
    // One page of outOfDate() stops taking claims once it has spent this many queries. Reading the
    // brief, the coverage check, the analysis and the photos of one claim spends up to 26, and a
    // transaction has 100.
    private static final Integer SWEEP_QUERY_ROOM = 68;
    // Words that are only true on the day they were written.
    // Words that are only true on the day they were written: the day itself, and a count of days.
    // A count as digits or as a word: "13 days old" and "nine days old" go stale the same way.
    private static final String COUNT = '(?:\\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty)';
    private static final Pattern DAY_WORDS = Pattern.compile(
        '(?i)\\b(today|tonight|tomorrow|yesterday|' + COUNT + ' days? (?:old|ago)|(?:open|sat open|been open) (?:for )?' + COUNT + ' days?|in ' + COUNT + ' days?|' + COUNT + ' days? (?:left|overdue|out))\\b'
    );
    /**
     * The day the check reads as. Today, unless someone asks how things will read on a later day:
     * set it to tomorrow before a demo and the check lists what will be stale by then.
     */
    public static Date asOf = Date.today();
    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'jpg', 'jpeg', 'png', 'gif', 'webp' };
    // Roughly how long one coverage check takes in the background job, for the line that says how long it
    // will run. Measured on Oct 5: 21 checks in 92 seconds.
    private static final Integer SECONDS_A_CHECK = 6;

    /** Lets a test stand in for a production org. */
    @TestVisible
    private static Boolean treatAsProduction = false;

    /** Raised when the prep is run where it must not be. */
    public class PrepException extends Exception {
    }

    /**
     * One showcase claim and which of Claude's work it carries in the demo. Every one carries a
     * brief: a claim opened in front of a room does not show the invitation to write one.
     */
    private class Showcase {
        String subject;
        Boolean photos;
        Boolean analysis;
        Boolean brief;
        /** The sample files the claim should carry, by title. Mirrors the two sample lists; a test holds them together. */
        List<String> files;

        Showcase(String subject, Boolean photos, Boolean analysis, Boolean brief, List<String> files) {
            this.subject = subject;
            this.photos = photos;
            this.analysis = analysis;
            this.brief = brief;
            this.files = files;
        }
    }

    private static final List<Showcase> SHOWCASE = new List<Showcase>{
        new Showcase(
            PIPE_CLAIM,
            true,
            true,
            true,
            new List<String>{ 'Mitigation invoice, Lakeshore Restoration', 'Rebuild estimate, Northshore Renovation', 'Basement family room after the water' }
        ),
        new Showcase(SCRAPE_CLAIM, true, true, true, new List<String>{ 'Rear quarter panel, passenger side' }),
        new Showcase(
            REAR_END_CLAIM,
            true,
            false,
            true,
            new List<String>{ 'Crash report, Oak Park Police', 'Repair estimate, phone photo', 'Right rear quarter damage, insured\'s photo' }
        ),
        new Showcase(
            ROOF_CLAIM,
            false,
            true,
            true,
            new List<String>{ 'Employer\'s first report of injury, Ridgeline', 'Interim hospital bill, Prairie Path Medical Center' }
        ),
        new Showcase(DEER_CLAIM, true, true, true, new List<String>{ 'Front right corner after the deer strike' })
    };

    /** One piece of Claude's work on one showcase claim. */
    public class Step {
        /** What scripts/prepare_demo.sh passes back to run(): the claim, the kind of step and, for some, a file. */
        public String key;
        public String caseNumber;
        public String claim;
        public String label;
        /** True when the claim already carries this work. */
        public Boolean done = false;
    }

    /** How one step went. A failure is returned, not thrown, so the script can retry it. */
    public class Outcome {
        public String key;
        public String label;
        public Boolean ok = true;
        /** True when the work was already on the claim and Claude was not asked. */
        public Boolean skipped = false;
        public String line;
        public String error;
        public Boolean retryable = false;
    }

    /** One page of the look for stored work that is out of date. See outOfDate. */
    public class Sweep {
        /** One line for each piece of Claude's work that is missing or no longer matches its claim. */
        public List<String> lines = new List<String>();
        /** How many open claims there are, and how many this page looked at. */
        public Integer openClaims = 0;
        public Integer looked = 0;
        /** Where the next page starts. Null when every open claim has been looked at. */
        public Integer next;
    }

    /** The background job that checks coverage on every open claim, and how far it has got. */
    public class CoverageJob {
        public Id jobId;
        /** Open claims with no coverage check when the job was started: one Claude call each. */
        public Integer calls = 0;
        public Boolean finished = false;
        public Integer failed = 0;
        public String line;
    }

    // ------------------------------------------------------------------ what the script calls

    /**
     * @description Says what the prep would do, and changes nothing.
     * @return One line for each thing checked
     * @throws PrepException in a production org
     */
    public static List<String> check() {
        guard();
        List<String> lines = new List<String>();
        Map<String, Case> claims = claims();
        Map<Id, Set<String>> titles = fileTitles(claims.values());
        for (Showcase show : SHOWCASE) {
            Case claim = claims.get(show.subject);
            if (claim == null) {
                lines.add('MISSING: the claim "' + show.subject + '" is not in the org. Load the demo data first.');
                continue;
            }
            String name = claim.CaseNumber + ' ' + show.subject;
            List<String> absent = new List<String>();
            List<String> absentDocuments = new List<String>();
            for (String title : show.files) {
                if (!titles.get(claim.Id).contains(title)) {
                    absent.add(title);
                    if (PIPE_DOCUMENTS.contains(title)) {
                        absentDocuments.add(title);
                    }
                }
            }
            if (!show.files.isEmpty()) {
                lines.add(
                    absent.isEmpty()
                        ? name + (show.files.size() == 1 ? ': its sample file is on the claim.' : ': all ' + show.files.size() + ' sample files are on the claim.')
                        : name + ': would attach ' + String.join(absent, '; ') + '.'
                );
            }
            if (show.subject == PIPE_CLAIM) {
                lines.add(name + ': ' + estimatePlan(claim, absentDocuments));
            }
        }
        for (Step step : steps()) {
            lines.add(step.caseNumber + ' ' + step.claim + ': ' + (step.done ? 'has ' : 'would ask Claude for ') + step.label + '.');
        }
        return lines;
    }

    /**
     * @description Attaches the sample documents and photographs to their claims. A file already
     * on its claim is left alone.
     * @return What was attached and what was already there
     * @throws PrepException in a production org
     */
    public static String attach() {
        guard();
        return 'Documents: ' +
            AntsuranceClaimsAssistantDemo.attachSampleDocuments() +
            ' Photos: ' +
            AntsuranceClaimsAssistantPhotos.attachSamplePhotos();
    }

    /**
     * @description Raises the burst pipe claim's estimate from its first figure to what its two
     * documents add up to, once both are on the claim, and says so in a file note from the
     * adjuster. An estimate that is already there, or that someone has set to another figure, is
     * left alone.
     * @return What was done, in one line
     * @throws PrepException in a production org
     */
    public static String settle() {
        guard();
        Case claim = claims().get(PIPE_CLAIM);
        if (claim == null) {
            return 'The burst pipe claim is not in the org, so no estimate was changed.';
        }
        Set<String> titles = fileTitles(new List<Case>{ claim }).get(claim.Id);
        List<String> absent = new List<String>();
        for (String title : PIPE_DOCUMENTS) {
            if (!titles.contains(title)) {
                absent.add(title);
            }
        }
        String plan = estimatePlan(claim, absent);
        if (claim.Estimated_Loss__c != PIPE_FIRST_ESTIMATE || !absent.isEmpty()) {
            return plan;
        }
        update as user new Case(Id = claim.Id, Estimated_Loss__c = PIPE_DOCUMENTS_TOTAL);
        insert as user new File_Note__c(
            Case__c = claim.Id,
            Policy__c = claim.Policy__c,
            Account__c = claim.AccountId,
            Note_Type__c = 'Reserve',
            Body__c = ESTIMATE_NOTE,
            Note_Date__c = Datetime.now(),
            Author_Name__c = claim.Handled_By__c
        );
        return 'Estimate raised from ' + money(PIPE_FIRST_ESTIMATE) + ' to ' + money(PIPE_DOCUMENTS_TOTAL) + ' and a file note added.';
    }

    /**
     * @description Claude's work on the showcase claims, in the order to do it, each marked done
     * when the claim already carries it.
     * @return The steps
     * @throws PrepException in a production org
     */
    public static List<Step> steps() {
        guard();
        List<Step> steps = new List<Step>();
        Map<String, Case> claims = claims();
        for (Showcase show : SHOWCASE) {
            Case claim = claims.get(show.subject);
            if (claim != null) {
                steps.addAll(stepsFor(show, claim));
            }
        }
        return steps;
    }

    /**
     * @description Does one step: one Claude call at most. A step whose work is on the claim is
     * skipped unless it is asked for again.
     * @param key The step's key, from steps()
     * @param refresh True to ask Claude even when the work is already there
     * @return How it went
     * @throws PrepException in a production org, or when the key is not a step
     */
    public static Outcome run(String key, Boolean refresh) {
        guard();
        List<String> parts = key == null ? new List<String>() : key.split(':');
        if (parts.size() < 2) {
            throw new PrepException(UNKNOWN_STEP);
        }
        Id caseId;
        try {
            caseId = Id.valueOf(parts[0]);
        } catch (StringException e) {
            throw new PrepException(UNKNOWN_STEP);
        }
        Step wanted;
        Map<String, Case> claims = claims();
        for (Showcase show : SHOWCASE) {
            Case claim = claims.get(show.subject);
            if (claim != null && claim.Id == caseId) {
                for (Step step : stepsFor(show, claim)) {
                    if (step.key == key) {
                        wanted = step;
                    }
                }
            }
        }
        if (wanted == null) {
            throw new PrepException(UNKNOWN_STEP);
        }
        Outcome outcome = new Outcome();
        outcome.key = key;
        outcome.label = wanted.label;
        if (wanted.done && refresh != true) {
            outcome.skipped = true;
            outcome.line = 'Already on the claim.';
            return outcome;
        }
        try {
            perform(outcome, caseId, parts, refresh == true);
        } catch (AuraHandledException e) {
            // The brief and the plain coverage check throw what the page would show. Asking again is worth a try.
            outcome.ok = false;
            outcome.error = e.getMessage();
            outcome.retryable = true;
        }
        return outcome;
    }

    /**
     * @description What each showcase claim now says, one line per claim.
     * @return A few lines for each claim
     * @throws PrepException in a production org
     */
    public static List<String> summary() {
        guard();
        List<String> lines = new List<String>();
        Map<String, Case> claims = claims();
        for (Showcase show : SHOWCASE) {
            Case claim = claims.get(show.subject);
            if (claim == null) {
                continue;
            }
            lines.add(claim.CaseNumber + ' ' + show.subject);
            AntsuranceClaimRules.Terms terms = AntsuranceClaimRules.termsFor(claim);
            AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(claim.Reserve_Amount__c, claim.Estimated_Loss__c, terms.deductible, terms.limitAmount);
            lines.add(
                '  Estimate ' +
                    money(claim.Estimated_Loss__c) +
                    ', deductible ' +
                    money(at.deductible) +
                    ', payable ' +
                    (at.payable == null ? 'unknown' : money(at.payable)) +
                    ', ' +
                    (at.reserve == 0 ? 'no reserve set yet' : 'reserve ' + money(at.reserve) + ' (' + standing(at) + ')') +
                    ', paid ' +
                    money(claim.Paid_Amount__c) +
                    '.'
            );
            if (show.photos) {
                AntsuranceClaimsAssistantPhotos.Assessment photos = AntsuranceClaimsAssistantPhotos.stored(claim.Id);
                lines.add(
                    '  Photos: ' +
                        (photos == null
                            ? 'not assessed.'
                            : firstSentence(photos.damageSummary) +
                              (photos.consistency == 'consistent' || String.isBlank(photos.consistencyNote) ? '' : ' Something to check: ' + photos.consistencyNote))
                );
            }
            if (show.analysis) {
                lines.add('  Coverage check: ' + storedVerdictLine(claim));
                AntsuranceClaimsAssistantAnalysis.Report report = AntsuranceClaimsAssistantAnalysis.getDocket(claim.Id).report;
                lines.add('  Analysis: ' + (report == null ? 'not written.' : report.headline));
            }
            if (show.brief) {
                AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claim.Id);
                lines.add('  Brief: ' + (brief.exists ? brief.headline : 'not written.'));
            }
        }
        return lines;
    }

    // ------------------------------------------------------------------ every open claim

    /**
     * @description Starts a coverage check on every open claim that has none, or whose check is
     * out of date. Each is one Claude call in a transaction of its own, so the work is done in the
     * background, a claim at a time, most serious first. A check that still stands is left alone.
     * @return The job, how many Claude calls it will make and about how long that takes
     * @throws PrepException in a production org
     */
    public static CoverageJob checkCoverageEverywhere() {
        guard();
        CoverageJob job = new CoverageJob();
        Integer open = 0;
        for (Case claim : openClaims()) {
            if (claim.Policy__c == null) {
                continue;
            }
            open++;
            if (String.isBlank(claim.Coverage_Read__c)) {
                job.calls++;
            }
        }
        job.jobId = Database.executeBatch(new AntsuranceDemoPrepCoverage(), 1);
        job.line = job.calls == 0
            ? 'Every one of the ' + open + ' open claims has a coverage check. Any that is out of date is being checked again.'
            : job.calls + ' of ' + open + ' open claims have no coverage check. Checking them now, one Claude call each, about ' +
              minutes(job.calls * SECONDS_A_CHECK) + ' in all.';
        return job;
    }

    /**
     * @description How far the job that checkCoverageEverywhere started has got.
     * @param jobId The job
     * @return Whether it has finished, and a line to print
     * @throws PrepException in a production org
     */
    public static CoverageJob coverageProgress(Id jobId) {
        guard();
        CoverageJob job = new CoverageJob();
        job.jobId = jobId;
        List<AsyncApexJob> found = [SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        if (found.isEmpty()) {
            job.finished = true;
            job.failed = 1;
            job.line = 'The coverage job cannot be found.';
            return job;
        }
        AsyncApexJob row = found[0];
        job.finished = row.Status == 'Completed' || row.Status == 'Failed' || row.Status == 'Aborted';
        job.failed = row.NumberOfErrors == null ? 0 : row.NumberOfErrors;
        if (job.finished && row.Status != 'Completed') {
            job.failed = Math.max(job.failed, 1);
        }
        job.line = job.finished
            ? 'Coverage checked on ' + row.JobItemsProcessed + ' open claims' + (job.failed == 0 ? '.' : ', and ' + job.failed + ' could not be done.')
            : row.JobItemsProcessed + ' of ' + row.TotalJobItems + ' open claims done so far.';
        return job;
    }

    /**
     * @description Looks at Claude's stored work on every open claim, showcase or not, and lists
     * what is missing or no longer matches its claim: a brief whose claim has moved on, a coverage
     * check or an analysis marked out of date, photos added since they were assessed, and anything
     * written on an earlier day that speaks of "today". Nothing is changed and Claude is not asked.
     *
     * Reading one claim's work spends up to 26 queries, so a page stops when the transaction is
     * running short and says where the next page starts.
     * @param startAt How many open claims earlier pages have looked at. Null or 0 for the first page.
     * @return The lines for this page, and where the next page starts
     * @throws PrepException in a production org
     */
    /**
     * @description The same sweep, read as a later day: what will be out of date by then. For the
     * evening before a demo (`scripts/prepare_demo.sh --check --tomorrow`).
     * @param startAt Where this page starts
     * @param daysAhead How many days on to read as: 1 for tomorrow
     * @return The page, as outOfDate(startAt) gives it
     */
    public static Sweep outOfDate(Integer startAt, Integer daysAhead) {
        asOf = Date.today().addDays(daysAhead == null ? 0 : daysAhead);
        return outOfDate(startAt);
    }

    public static Sweep outOfDate(Integer startAt) {
        guard();
        Sweep sweep = new Sweep();
        List<Case> open = openClaims();
        sweep.openClaims = open.size();
        Set<Id> withPhotos = claimsWithPhotos(open);
        Integer at = startAt == null || startAt < 0 ? 0 : startAt;
        while (at < open.size()) {
            if (Limits.getQueries() > SWEEP_QUERY_ROOM) {
                sweep.next = at;
                break;
            }
            sweep.lines.addAll(outOfDateOn(open[at], withPhotos.contains(open[at].Id)));
            sweep.looked++;
            at++;
        }
        return sweep;
    }

    /** What is missing or out of date among Claude's work on one open claim. */
    private static List<String> outOfDateOn(Case claim, Boolean hasPhotos) {
        List<String> lines = new List<String>();
        String name = claim.CaseNumber + ' ' + claim.Subject + ': ';
        if (String.isNotBlank(claim.Claude_Brief__c)) {
            AntsuranceClaimsAssistantBrief.Brief brief = AntsuranceClaimsAssistantBrief.getBrief(claim.Id);
            if (brief.stale) {
                lines.add(name + 'the brief is out of date (' + String.join(brief.changes, ', ') + '). Press Rewrite on the brief.');
            } else {
                addEarlierDay(lines, name + 'the brief', brief.writtenAt, JSON.serialize(brief));
            }
        }
        if (String.isBlank(claim.Coverage_Read__c)) {
            if (claim.Policy__c != null) {
                lines.add(name + 'coverage has not been checked. Run scripts/prepare_demo.sh, or press the button on its coverage check.');
            }
        } else {
            AntsuranceClaimsAssistantCoverage.Check check = coverage(claim.Id);
            if (check == null) {
                lines.add(name + 'the coverage check cannot be read. Check coverage again.');
            } else if (check.stale) {
                lines.add(name + 'the coverage check is out of date (' + String.join(check.changes, ', ') + '). Check coverage again.');
            } else {
                addEarlierDay(lines, name + 'the coverage check', check.writtenAt, JSON.serialize(check));
            }
        }
        if (String.isNotBlank(claim.Claude_Analysis__c)) {
            AntsuranceClaimsAssistantAnalysis.Report report = AntsuranceClaimsAssistantAnalysis.getDocket(claim.Id).report;
            if (report != null && report.stale) {
                lines.add(name + 'the analysis is out of date (' + String.join(report.changes, ', ') + '). Press Analyze again.');
            } else if (report != null) {
                addEarlierDay(lines, name + 'the analysis', claim.Claude_Analysis_At__c, JSON.serialize(report));
            }
        }
        if (hasPhotos) {
            AntsuranceClaimsAssistantPhotos.View view = AntsuranceClaimsAssistantPhotos.getPhotos(claim.Id);
            if (view.assessment == null) {
                if (!view.batches.isEmpty()) {
                    lines.add(name + 'its photos have not been assessed. Press Assess on the photos.');
                }
            } else if (view.assessment.complete == false) {
                lines.add(name + 'the photo assessment was left part way. Press Assess again.');
            } else if (view.addedSince > 0) {
                lines.add(name + view.addedSince + (view.addedSince == 1 ? ' photo was' : ' photos were') + ' added since the photos were assessed. Press Assess again.');
            }
        }
        return lines;
    }

    /** Adds a line when something written on an earlier day speaks of today, tomorrow or yesterday. */
    private static void addEarlierDay(List<String> lines, String what, Datetime writtenAt, String text) {
        if (writtenAt == null || writtenAt.date() >= asOf || String.isBlank(text)) {
            return;
        }
        // The text arrives as JSON, where a line break is written out as two characters.
        String flat = text.replace('\\n', ' ');
        Matcher found = DAY_WORDS.matcher(flat);
        if (!found.find()) {
            return;
        }
        // A few words either side, so the reader can find the sentence on the card.
        String around = flat.substring(Math.max(found.start() - 40, 0), Math.min(found.end() + 12, flat.length())).replaceAll('[\\\\"{}\\[\\]]', ' ').normalizeSpace();
        lines.add(what + ' was written on ' + writtenAt.format('MMM d') + ' and says "... ' + around + ' ...". Write it again so it reads as today\'s.');
    }

    // ------------------------------------------------------------------ the steps of one claim

    /**
     * The steps for one claim, in order: photos, documents, coverage, the report, the brief. A brief
     * is written from the coverage check, and a check made after it would mark it out of date, so a
     * claim that carries a brief and no analysis still gets its coverage checked first.
     */
    private static List<Step> stepsFor(Showcase show, Case claim) {
        List<Step> steps = new List<Step>();
        if (show.photos) {
            AntsuranceClaimsAssistantPhotos.View view = AntsuranceClaimsAssistantPhotos.getPhotos(claim.Id);
            Set<Id> looked = new Set<Id>();
            if (view.assessment != null) {
                for (AntsuranceClaimsAssistantPhotos.PhotoRead read : view.assessment.photos) {
                    looked.add(read.documentId);
                }
            }
            Boolean finished = view.assessment != null && view.assessment.complete != false;
            Boolean everyBatch = !view.batches.isEmpty();
            for (Integer i = 0; i < view.batches.size(); i++) {
                Boolean seen = looked.containsAll(view.batches[i]);
                everyBatch = everyBatch && seen;
                Boolean only = view.batches.size() == 1;
                steps.add(
                    step(claim, show, KIND_PHOTOS + ':' + i, only ? 'the photo assessment' : 'the photo assessment, group ' + (i + 1) + ' of ' + view.batches.size(), seen && (finished || !only))
                );
            }
            if (view.batches.size() > 1) {
                steps.add(step(claim, show, KIND_PHOTOS_FINISH, 'the overall read of the photos', everyBatch && finished));
            }
        }
        if (show.analysis) {
            AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claim.Id);
            for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
                if (item.kind == KIND_DOCUMENT && item.readable != false) {
                    steps.add(step(claim, show, KIND_DOCUMENT + ':' + item.documentId, 'a reading of "' + item.title + '"', item.looked == true));
                }
            }
            steps.add(step(claim, show, KIND_COVERAGE, 'the coverage check', String.isNotBlank(claim.Coverage_Read__c)));
            steps.add(step(claim, show, KIND_REPORT, 'the claim analysis', docket.report != null));
        } else if (show.brief) {
            steps.add(step(claim, show, KIND_COVERAGE, 'the coverage check', String.isNotBlank(claim.Coverage_Read__c)));
        }
        if (show.brief) {
            steps.add(step(claim, show, KIND_BRIEF, 'the claim brief', String.isNotBlank(claim.Claude_Brief__c)));
        }
        return steps;
    }

    private static Step step(Case claim, Showcase show, String rest, String label, Boolean done) {
        Step step = new Step();
        step.key = claim.Id + ':' + rest;
        step.caseNumber = claim.CaseNumber;
        step.claim = show.subject;
        step.label = label;
        step.done = done;
        return step;
    }

    /** Does the work of one step and writes how it went onto the outcome. */
    private static void perform(Outcome outcome, Id caseId, List<String> parts, Boolean refresh) {
        String kind = parts[1];
        if (kind == KIND_PHOTOS) {
            List<List<Id>> batches = AntsuranceClaimsAssistantPhotos.getPhotos(caseId).batches;
            Integer position = parts.size() > 2 ? Integer.valueOf(parts[2]) : 0;
            if (position >= batches.size()) {
                throw new PrepException(UNKNOWN_STEP);
            }
            photoOutcome(outcome, AntsuranceClaimsAssistantPhotos.assessBatch(caseId, batches[position], position == 0, batches.size() == 1));
        } else if (kind == KIND_PHOTOS_FINISH) {
            photoOutcome(outcome, AntsuranceClaimsAssistantPhotos.finishAssessment(caseId));
        } else if (kind == KIND_DOCUMENT && parts.size() > 2) {
            analysisOutcome(outcome, AntsuranceClaimsAssistantAnalysis.readDocumentStep(caseId, Id.valueOf(parts[2]), refresh));
        } else if (kind == KIND_COVERAGE) {
            analysisOutcome(outcome, AntsuranceClaimsAssistantAnalysis.checkCoverageStep(caseId, refresh));
        } else if (kind == KIND_REPORT) {
            analysisOutcome(outcome, AntsuranceClaimsAssistantAnalysis.writeReportStep(caseId));
        } else if (kind == KIND_BRIEF) {
            outcome.line = AntsuranceClaimsAssistantBrief.writeBrief(caseId).headline;
        } else {
            throw new PrepException(UNKNOWN_STEP);
        }
    }

    private static void photoOutcome(Outcome outcome, AntsuranceClaimsAssistantPhotos.StepResult result) {
        outcome.ok = result.ok == true;
        outcome.error = result.error;
        outcome.retryable = result.retryable == true;
        if (outcome.ok && result.assessment != null) {
            outcome.line = result.assessment.complete == false
                ? result.assessment.photos.size() + ' photos looked at so far.'
                : firstSentence(result.assessment.damageSummary);
        }
    }

    private static void analysisOutcome(Outcome outcome, AntsuranceClaimsAssistantAnalysis.StepResult result) {
        outcome.ok = result.ok == true;
        outcome.error = result.error;
        outcome.retryable = result.retryable == true;
        outcome.line = result.line;
    }

    // ------------------------------------------------------------------ reading the org

    /**
     * @description Stops the prep in a production org. A scratch org, a sandbox, a trial and a
     * Developer Edition org are all fine. Public so the background coverage job can ask too.
     * @throws PrepException in a production org
     */
    public static void guard() {
        Organization org = [SELECT IsSandbox, OrganizationType, TrialExpirationDate FROM Organization LIMIT 1];
        Boolean isProduction = !org.IsSandbox && org.OrganizationType != 'Developer Edition' && org.TrialExpirationDate == null;
        if (treatAsProduction || isProduction) {
            throw new PrepException(NOT_HERE);
        }
    }

    /** The showcase claims in the org, by subject. The oldest wins when a subject is there twice. */
    private static Map<String, Case> claims() {
        Set<String> subjects = new Set<String>();
        for (Showcase show : SHOWCASE) {
            subjects.add(show.subject);
        }
        Map<String, Case> claims = new Map<String, Case>();
        for (Case claim : [
            SELECT
                CaseNumber,
                Subject,
                AccountId,
                Policy__c,
                Handled_By__c,
                Estimated_Loss__c,
                Reserve_Amount__c,
                Paid_Amount__c,
                Coverage_Read__c,
                Claude_Brief__c,
                Policy__r.Deductible__c,
                Policy__r.Coverage_Limit__c
            FROM Case
            WHERE Subject IN :subjects AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            if (!claims.containsKey(claim.Subject)) {
                claims.put(claim.Subject, claim);
            }
        }
        return claims;
    }

    /** The titles of the files on each claim. */
    private static Map<Id, Set<String>> fileTitles(List<Case> claims) {
        Map<Id, Set<String>> titles = new Map<Id, Set<String>>();
        for (Case claim : claims) {
            titles.put(claim.Id, new Set<String>());
        }
        if (titles.isEmpty()) {
            return titles;
        }
        Set<Id> claimIds = titles.keySet();
        for (ContentDocumentLink link : [SELECT LinkedEntityId, ContentDocument.Title FROM ContentDocumentLink WHERE LinkedEntityId IN :claimIds]) {
            titles.get(link.LinkedEntityId).add(link.ContentDocument.Title);
        }
        return titles;
    }

    /** Every claim that is still being worked, with what Claude has stored on it. */
    private static List<Case> openClaims() {
        return [
            SELECT
                CaseNumber,
                Subject,
                Policy__c,
                Claude_Brief__c,
                Coverage_Read__c,
                Claude_Analysis__c,
                Claude_Analysis_At__c,
                Photo_Assessment__c
            FROM Case
            WHERE RecordType.DeveloperName = 'Claim' AND Status NOT IN :SETTLED
            WITH USER_MODE
            ORDER BY CaseNumber
        ];
    }

    /** Which of these claims carry at least one image file. */
    private static Set<Id> claimsWithPhotos(List<Case> claims) {
        Set<Id> withPhotos = new Set<Id>();
        if (claims.isEmpty()) {
            return withPhotos;
        }
        Set<Id> claimIds = new Map<Id, Case>(claims).keySet();
        for (ContentDocumentLink link : [SELECT LinkedEntityId, ContentDocument.FileExtension FROM ContentDocumentLink WHERE LinkedEntityId IN :claimIds]) {
            if (IMAGE_TYPES.contains(link.ContentDocument.FileExtension?.toLowerCase())) {
                withPhotos.add(link.LinkedEntityId);
            }
        }
        return withPhotos;
    }

    /** The stored coverage check, or null when there is none or it cannot be read. */
    private static AntsuranceClaimsAssistantCoverage.Check coverage(Id caseId) {
        try {
            AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.getCheck(caseId);
            return check != null && check.exists ? check : null;
        } catch (AuraHandledException e) {
            return null;
        }
    }

    /** What settle() does, or would do, about the burst pipe claim's estimate. */
    private static String estimatePlan(Case claim, List<String> absentDocuments) {
        if (claim.Estimated_Loss__c == PIPE_DOCUMENTS_TOTAL) {
            return 'the estimate is already ' + money(PIPE_DOCUMENTS_TOTAL) + ', the total of its documents.';
        }
        if (claim.Estimated_Loss__c != PIPE_FIRST_ESTIMATE) {
            return 'the estimate is ' +
                money(claim.Estimated_Loss__c) +
                ', which is neither the first estimate nor the total of its documents, so it is left alone.';
        }
        if (!absentDocuments.isEmpty()) {
            return 'the estimate stays at ' + money(PIPE_FIRST_ESTIMATE) + ' until its documents are attached, then goes to ' + money(PIPE_DOCUMENTS_TOTAL) + '.';
        }
        return 'would raise the estimate from ' + money(PIPE_FIRST_ESTIMATE) + ' to ' + money(PIPE_DOCUMENTS_TOTAL) + ' and add a file note.';
    }

    // ------------------------------------------------------------------ words

    private static String standing(AntsuranceClaimRules.Position at) {
        if (at.standing == AntsuranceClaimRules.SHORT_OF) {
            return money(Math.abs(at.difference)) + ' short';
        }
        if (at.standing == AntsuranceClaimRules.ABOVE) {
            return money(at.difference) + ' above what is payable';
        }
        return at.standing == AntsuranceClaimRules.ADEQUATE ? 'covers it' : 'no estimate to measure against';
    }

    /** The verdict and its one-line reason from the check stored on the claim, without reading the policy again. */
    private static String storedVerdictLine(Case claim) {
        if (String.isBlank(claim.Coverage_Read__c)) {
            return 'not run.';
        }
        try {
            Map<String, Object> check = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(claim.Coverage_Read__c)).get('check');
            String verdict = (String) check.get('verdict');
            String reason = firstSentence((String) check.get('summary'));
            // The verdict is not said twice when the reason opens with it.
            return String.isNotBlank(verdict) && reason.startsWithIgnoreCase(verdict) ? reason : verdict + '. ' + reason;
        } catch (Exception e) {
            return 'stored, but it cannot be read.';
        }
    }

    private static String minutes(Integer seconds) {
        Integer whole = Math.max((seconds + 59) / 60, 1);
        return whole + (whole == 1 ? ' minute' : ' minutes');
    }

    private static String money(Decimal amount) {
        return '$' + (amount == null ? 0 : amount).setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String firstSentence(String text) {
        if (String.isBlank(text)) {
            return '';
        }
        Integer stop = text.indexOf('. ');
        return stop < 0 ? text.trim() : text.substring(0, stop + 1);
    }
}
