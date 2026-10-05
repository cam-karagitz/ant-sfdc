/**
 * @description The claims coverage agent's tools. The agent's loop runs on Claude Managed Agents;
 * when it decides to read something it asks for one of these by name, and this class does the
 * reading here, in Salesforce, as the person who started the investigation. Every query is in user
 * mode, so the agent sees what that person may see and nothing else, and no record leaves through
 * anything but the answer to a tool call.
 *
 * Each record handed to the agent carries a key in square brackets ([C1], [E2], [N3], [D1]); a
 * finding cites one of them, which is how the claim page links each finding to the record it rests on.
 *
 * The agent holds those keys across many requests, so a key has to mean the same record for the
 * whole of an investigation. The keys are fixed when the session starts (keysFor) and travel with
 * the session; every later request hands them back (holdKeys) before any tool runs. A file or a
 * note added while the agent works then gets the next free number, and nothing already keyed moves.
 */
public with sharing class AntsuranceCoverageAgentTools {
    public static final String READ_CLAIM = 'read_claim';
    public static final String READ_POLICY = 'read_policy';
    public static final String READ_NOTES = 'read_file_notes';
    public static final String LIST_DOCUMENTS = 'list_documents';
    public static final String READ_DOCUMENT = 'read_document';
    public static final String READ_PHOTOS = 'read_photo_assessment';
    public static final String PRIOR_CLAIMS = 'find_prior_claims';
    public static final String RECORD = 'record_finding';

    private static final String PHOTOS_KEY = 'PHOTOS';
    private static final String NONE = 'NONE';
    private static final Integer MAX_PRIOR_CLAIMS = 15;
    private static final Integer MAX_FINDINGS = 8;
    private static final Integer MAX_RESULT_CHARS = 12000;
    // A finding is a sentence. This is room for a long one, and keeps what is stored well inside the claim's field.
    private static final Integer MAX_SENTENCE_CHARS = 500;
    private static final Integer MAX_POINTS = 6;
    private static final Integer MAX_LINKED_FILES = 200;
    // A key and the record it stands for, as the session carries them: D2=069...
    private static final Pattern HELD_KEY = Pattern.compile('\\b([A-Z][0-9]{1,3})=([a-zA-Z0-9]{18})\\b');
    private static final Set<String> VERDICTS = new Set<String>{
        AntsuranceClaimsAssistantCoverage.COVERED,
        AntsuranceClaimsAssistantCoverage.NOT_COVERED,
        AntsuranceClaimsAssistantCoverage.NEEDS_REVIEW
    };
    private static final Set<String> PHOTO_TYPES = new Set<String>{ 'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic' };

    // One set of facts per claim per request: the keys must not shift between two tools in one round.
    private static Map<Id, AntsuranceClaimsAssistantCoverage.Facts> factsByClaim = new Map<Id, AntsuranceClaimsAssistantCoverage.Facts>();
    // The keys this session was started with, by record and by key. Null when no session's keys are held.
    private static Map<Id, String> heldByRecord;
    private static Map<String, Id> heldByKey;
    // The titles of the claim's files, for naming a step without loading the whole claim.
    private static Map<Id, Map<Id, String>> titlesByClaim = new Map<Id, Map<Id, String>>();

    /**
     * @description What a tool hands back to the agent.
     */
    public class Result {
        /** What the agent reads. */
        public String text;
        /** True when the tool could not do what was asked; the agent is told so and can try again. */
        public Boolean isError = false;
        /** One plain line saying what was found, for the trace on the claim page. */
        public String found;
        /** Set by record_finding when the finding is fit to store. */
        public AntsuranceClaimsAssistantCoverage.Check check;
    }

    /**
     * @description The custom tools as the agent definition declares them, as JSON text so the
     * order of each tool's fields is kept as written here.
     * @return A JSON array of tool definitions
     */
    public static String definitions() {
        String noInput = '"input_schema":{"type":"object","properties":{},"required":[]}';
        List<String> tools = new List<String>{
            tool(READ_CLAIM, 'Read the claim under investigation: its status, type of loss, date of loss and date reported, where it happened, what was reported, the estimate and the reserve. Call this first.', noInput),
            tool(READ_POLICY, 'Read the policy the claim is on: its term, status and payments, every coverage with its limit and deductible, every endorsement and exclusion with its form number and the date it came onto the policy, who is on the policy and what it insures. Each record has a key in square brackets.', noInput),
            tool(READ_NOTES, 'Read the file notes on the claim, newest first: what the adjuster, the insured and others have said and done. Each note has a key in square brackets.', noInput),
            tool(LIST_DOCUMENTS, 'List the files attached to the claim (invoices, estimates, reports, photographs) with a key for each, and say whether a photo assessment is on file. Use it to decide which documents are worth reading.', noInput),
            tool(
                READ_DOCUMENT,
                'Read one attached document in full and get what it is, who issued it, its date, its key facts and total, and how it compares with the claim. Use it for a document that bears on the cause, the date or the extent of the loss. Takes up to half a minute. For photographs use read_photo_assessment instead.',
                '"input_schema":{"type":"object","properties":{"document":{"type":"string","description":"The key of the document from list_documents, such as D1."}},"required":["document"]}'
            ),
            tool(READ_PHOTOS, 'Read what the photographs on the claim show, from the photo assessment on file: the damage seen, the kind of loss it points to and whether that fits the loss as reported. Cite it as PHOTOS.', noInput),
            tool(PRIOR_CLAIMS, 'Look up earlier claims by the same customer, on this policy or another: what each was, when, and how it ended. Use it when an earlier loss could bear on this one.', noInput),
            tool(
                RECORD,
                'Record your coverage finding on the claim for the adjuster to confirm. Call it exactly once, when you have the answer. It checks what you send and tells you if something needs fixing.',
                '"input_schema":{"type":"object","properties":{' +
                    '"findings":{"type":"array","description":"Three to six findings, most decisive first.","items":{"type":"object","properties":{' +
                    '"text":{"type":"string","description":"One sentence of at most 30 words: what the record shows and what it means for coverage. Names, not keys."},' +
                    '"source":{"type":"string","description":"The key of the one record this finding rests on, exactly as a tool gave it in square brackets: CLAIM, POLICY, or a key such as C1, E2, P1, A1, N3, D1, X2 or PHOTOS."}},"required":["text","source"]}},' +
                    '"responding":{"type":"string","description":"The key of the one coverage or endorsement that would pay for this loss (a C key, or an E key that is not an exclusion), or NONE when nothing on the policy does. Give it for Needs review too when one would respond if the open point is settled."},' +
                    '"verdict":{"type":"string","enum":["Covered","Not covered","Needs review"],"description":"Needs review whenever the file is silent or mixed on something that decides it."},' +
                    '"liability_open":{"type":"boolean","description":"True only when a liability coverage responds and the file does not establish that the insured is legally responsible."},' +
                    '"summary":{"type":"string","description":"One sentence of at most 25 words: the answer and its main reason."},' +
                    '"questions":{"type":"array","description":"Zero to three questions for the insured that the file does not answer and that bear on coverage.","items":{"type":"string"}},' +
                    '"would_change":{"type":"array","description":"Zero to three facts that, if they turned out differently, would change the verdict.","items":{"type":"string"}}' +
                    '},"required":["findings","responding","verdict","liability_open","summary","questions","would_change"]}'
            )
        };
        return '[' + String.join(tools, ',') + ']';
    }

    /**
     * @description Whether a tool is slow enough to need a request of its own. Reading a document
     * asks Claude to read the file, which can take most of the time one request is allowed.
     * @param name The tool's name
     * @return True for a tool the claim page runs on its own
     */
    public static Boolean isSlow(String name) {
        return name == READ_DOCUMENT;
    }

    /**
     * @description What a step is called in the trace on the claim page, in plain words.
     * @param name The tool's name
     * @param input What the agent passed to it
     * @param caseId The claim, to name a document by its title
     * @return The label
     */
    public static String label(String name, Map<String, Object> input, Id caseId) {
        if (name == READ_CLAIM) {
            return 'Read the claim';
        }
        if (name == READ_POLICY) {
            return 'Read the policy, its coverages and endorsements';
        }
        if (name == READ_NOTES) {
            return 'Read the file notes';
        }
        if (name == LIST_DOCUMENTS) {
            return 'Looked at what is attached';
        }
        if (name == READ_DOCUMENT) {
            String title = documentTitle(caseId, String.valueOf(input?.get('document')));
            return title == null ? 'Read a document' : 'Read ' + title;
        }
        if (name == READ_PHOTOS) {
            return 'Read what the photos show';
        }
        if (name == PRIOR_CLAIMS) {
            return 'Checked for earlier claims by this customer';
        }
        if (name == RECORD) {
            return 'Recorded the finding';
        }
        return 'Used ' + name;
    }

    /**
     * @description Runs one tool for the agent.
     * @param caseId The claim under investigation. The agent never chooses the claim; the person did.
     * @param name The tool's name
     * @param input What the agent passed to it
     * @return What to hand back to the agent. Never throws: a failure is a result the agent can read.
     */
    public static Result run(Id caseId, String name, Map<String, Object> input) {
        try {
            if (name == READ_CLAIM) {
                return readClaim(caseId);
            }
            if (name == READ_POLICY) {
                return readPolicy(caseId);
            }
            if (name == READ_NOTES) {
                return readNotes(caseId);
            }
            if (name == LIST_DOCUMENTS) {
                return listDocuments(caseId);
            }
            if (name == READ_DOCUMENT) {
                return readDocument(caseId, String.valueOf(input?.get('document')));
            }
            if (name == READ_PHOTOS) {
                return readPhotos(caseId);
            }
            if (name == PRIOR_CLAIMS) {
                return priorClaims(caseId);
            }
            if (name == RECORD) {
                return check(caseId, input);
            }
            return problem('There is no tool called ' + name + '.');
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            return problem(e.getMessage());
        } catch (AuraHandledException e) {
            return problem(e.getMessage());
        } catch (QueryException e) {
            return problem('That could not be read with this person\'s access.');
        }
    }

    /**
     * @description The claim's keys as they stand now, as text a session can carry: each numbered
     * key with the record it stands for, such as "C1=a0B... N2=a0F... D1=069...". Called once, when
     * an investigation starts.
     * @param caseId The claim
     * @return The keys, or null when no record has one
     * @throws AntsuranceClaimsAssistantCoverage.CoverageException when the record is not a claim, has no policy or cannot be read
     */
    public static String keysFor(Id caseId) {
        List<String> pairs = new List<String>();
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts(caseId).sources) {
            if (entry.recordId != null && isNumbered(entry.key)) {
                pairs.add(entry.key + '=' + String.valueOf(entry.recordId));
            }
        }
        return pairs.isEmpty() ? null : String.join(pairs, ' ');
    }

    /**
     * @description Hands back the keys a session was started with, so that every tool in this
     * request gives each record the key the agent already knows it by. Call it before any tool runs.
     * Text with no keys in it (a session started before keys were kept) leaves the keys to be
     * numbered from the claim as it is now, as before.
     * @param carried The text the session carries, from keysFor, with or without other words around it
     */
    public static void holdKeys(String carried) {
        Map<Id, String> byRecord = new Map<Id, String>();
        Map<String, Id> byKey = new Map<String, Id>();
        Matcher pair = HELD_KEY.matcher(carried == null ? '' : carried);
        while (pair.find()) {
            String key = pair.group(1);
            String record = pair.group(2);
            // Neither a key nor a record is taken twice: the first word on each stands.
            if (record instanceof Id && !byKey.containsKey(key) && !byRecord.containsKey((Id) record)) {
                byKey.put(key, (Id) record);
                byRecord.put((Id) record, key);
            }
        }
        heldByRecord = byKey.isEmpty() ? null : byRecord;
        heldByKey = byKey.isEmpty() ? null : byKey;
        // Facts keyed any other way are no longer the ones to use.
        factsByClaim.clear();
    }

    /**
     * @description Everything a finding may cite for a claim: the records the single-call check
     * keys, plus the attached documents (D keys), earlier claims by the customer (X keys) and the
     * photo assessment (PHOTOS). A note written in Salesforce Notes is a file to the platform and a
     * note to a person: it is keyed with the file notes (N keys) and is never a document. When a
     * session's keys are held, each record keeps the key it had when the session started and a
     * record added since takes the next free number.
     * @param caseId The claim
     * @return The facts
     * @throws AntsuranceClaimsAssistantCoverage.CoverageException when the record is not a claim, has no policy or cannot be read
     */
    public static AntsuranceClaimsAssistantCoverage.Facts facts(Id caseId) {
        if (factsByClaim.containsKey(caseId)) {
            return factsByClaim.get(caseId);
        }
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(caseId);
        Integer index = 0;
        for (AntsuranceClaimsAssistantDocuments.DocumentItem item : AntsuranceClaimsAssistantDocuments.getDocuments(caseId)) {
            // An approved letter's PDF is what the carrier sent, not a document that came in: the agent is not handed it.
            if (facts.ownLetters.contains(item.documentId)) {
                continue;
            }
            index++;
            Boolean isPhoto = PHOTO_TYPES.contains(item.extension);
            String line =
                item.title +
                (String.isBlank(item.extension) ? '' : ' (' + item.extension.toUpperCase() + ', ' + item.sizeLabel + ')') +
                (item.addedAt == null ? '' : ', added ' + item.addedAt.format('MMM d, yyyy')) +
                (isPhoto ? '. A photograph: use read_photo_assessment.' : item.readable == true ? '. Can be read with read_document.' : '. Cannot be read here: ' + item.whyNot);
            facts.sources.add(source('D' + index, isPhoto ? 'Photo' : 'Document', item.title, item.documentId, line));
        }
        index = 0;
        for (Case earlier : earlierClaims(caseId)) {
            index++;
            String line =
                earlier.CaseNumber + ': ' + earlier.Subject +
                '. ' + blankAs(earlier.Loss_Type__c, 'Type of loss not recorded') +
                ', date of loss ' + day(earlier.Date_of_Loss__c) +
                ', status ' + earlier.Status +
                (earlier.Policy__r?.Name == null ? '' : ', on policy ' + earlier.Policy__r.Name) +
                ', estimate ' + money(earlier.Estimated_Loss__c) +
                ', paid ' + money(earlier.Paid_Amount__c) + '.';
            facts.sources.add(source('X' + index, 'Earlier claim', earlier.CaseNumber + ': ' + earlier.Subject, earlier.Id, line));
        }
        AntsuranceClaimsAssistantPhotos.Assessment seen = AntsuranceClaimsAssistantPhotos.stored(caseId);
        if (seen != null && String.isNotBlank(seen.damageSummary)) {
            facts.sources.add(source(PHOTOS_KEY, 'Evidence', 'What the photos show', null, photoLines(seen)));
        }
        keepHeldKeys(facts);
        factsByClaim.put(caseId, facts);
        return facts;
    }

    /**
     * @description What record_finding answers once the finding is on the claim.
     * @param found The finding in a few words: the verdict and what responds
     * @return The result to hand back to the agent
     */
    public static Result acknowledged(String found) {
        Result result = new Result();
        result.found = found;
        result.text =
            'FOUND: ' + found + '.\nRecorded on the claim for the adjuster to confirm. ' +
            'Now tell the adjuster, in two short sentences, what you found and what is still open.';
        return result;
    }

    // ------------------------------------------------------------ the tools

    private static Result readClaim(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        Integer documents = count(facts, 'D');
        List<String> lines = new List<String>(facts.claimLines);
        lines.add('Attached files: ' + (documents == 0 ? 'none' : documents + ' (see list_documents)') + '. Photo assessment on file: ' + (has(facts, PHOTOS_KEY) ? 'yes (see read_photo_assessment)' : 'no') + '.');
        return found(facts.claimLines[0].substringAfter('] ').abbreviate(120), lines);
    }

    private static Result readPolicy(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        List<String> lines = new List<String>{ 'THE POLICY' };
        lines.addAll(facts.policyLines);
        Map<String, String> headings = new Map<String, String>{
            'C' => 'COVERAGES ON THE POLICY',
            'E' => 'ENDORSEMENTS AND EXCLUSIONS',
            'P' => 'WHO IS ON THE POLICY',
            'A' => 'WHAT THE POLICY INSURES'
        };
        for (String prefix : new List<String>{ 'C', 'E', 'P', 'A' }) {
            lines.add('');
            lines.add(headings.get(prefix));
            lines.addAll(keyed(facts, prefix));
        }
        lines.add('');
        lines.add('These are the coverages and endorsements as the system records them, not the wording of the policy forms.');
        return found(
            plural(count(facts, 'C'), 'coverage') + ', ' + plural(count(facts, 'E'), 'endorsement or exclusion', 'endorsements or exclusions') + ', ' + plural(count(facts, 'P'), 'person', 'people') + ' and ' + plural(count(facts, 'A'), 'insured item') + ' on ' + facts.policyLines[0].substringAfter('] ').substringBefore(':'),
            lines
        );
    }

    private static Result readNotes(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        List<String> lines = new List<String>{ 'FILE NOTES, newest first' };
        lines.addAll(keyed(facts, 'N'));
        return found(plural(count(facts, 'N'), 'file note'), lines);
    }

    private static Result listDocuments(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        List<String> lines = new List<String>{ 'FILES ATTACHED TO THE CLAIM' };
        lines.addAll(keyed(facts, 'D'));
        lines.add('');
        lines.add('Photo assessment on file: ' + (has(facts, PHOTOS_KEY) ? 'yes. Read it with read_photo_assessment and cite it as PHOTOS.' : 'no.'));
        return found(plural(count(facts, 'D'), 'file') + ' attached' + (has(facts, PHOTOS_KEY) ? ', and a photo assessment' : ''), lines);
    }

    private static Result readDocument(Id caseId, String key) {
        AntsuranceClaimsAssistantCoverage.Source document = sourceFor(caseId, key);
        if (document == null || !document.key.startsWith('D')) {
            return problem('There is no document with the key ' + key + '. Use a D key from list_documents.');
        }
        if (document.kind == 'Photo') {
            return problem(document.label + ' is a photograph. Use read_photo_assessment for what the photos show.');
        }
        AntsuranceClaimsAssistantDocuments.Reading reading = AntsuranceClaimsAssistantDocuments.readDocument(caseId, document.recordId);
        List<String> lines = new List<String>{ '[' + document.key + '] ' + document.label };
        lines.add('What it is: ' + blankAs(reading.documentType, 'not clear') + (String.isBlank(reading.issuer) ? '' : ', from ' + reading.issuer) + (reading.documentDate == null ? '' : ', dated ' + day(reading.documentDate)) + '.');
        if (String.isNotBlank(reading.summary)) {
            lines.add('Summary: ' + reading.summary);
        }
        for (AntsuranceClaimsAssistantDocuments.KeyFact fact : reading.keyFacts) {
            lines.add(fact.label + ': ' + fact.value);
        }
        if (reading.totalAmount != null) {
            lines.add('Total: ' + money(reading.totalAmount));
        }
        if (String.isNotBlank(reading.matchesClaim) || String.isNotBlank(reading.matchNote)) {
            lines.add('Against this claim: ' + blankAs(reading.matchesClaim, '') + (String.isBlank(reading.matchNote) ? '' : '. ' + reading.matchNote));
        }
        if (String.isNotBlank(reading.comparison)) {
            lines.add('Compared with the file: ' + reading.comparison);
        }
        if (!reading.concerns.isEmpty()) {
            lines.add('Worth a look: ' + String.join(reading.concerns, ' '));
        }
        // The line the trace shows says what the document adds, not just what kind of document it is:
        // the first sentence of the reading, whole, so nothing is cut off mid-thought.
        String gist = String.isBlank(reading.summary)
            ? blankAs(reading.documentType, 'A document') + (String.isBlank(reading.issuer) ? '' : ' from ' + reading.issuer) + (reading.totalAmount == null ? '' : ', total ' + money(reading.totalAmount))
            : firstSentence(reading.summary);
        return found(gist, lines);
    }

    private static Result readPhotos(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        if (!has(facts, PHOTOS_KEY)) {
            Result none = new Result();
            none.text = 'FOUND: No photo assessment is on file for this claim.\nThe photographs have not been assessed, so there is nothing to cite as PHOTOS.';
            none.found = 'No photo assessment is on file';
            return none;
        }
        AntsuranceClaimsAssistantPhotos.Assessment seen = AntsuranceClaimsAssistantPhotos.stored(caseId);
        String fits = seen.consistency == 'consistent' ? 'fits the loss as reported' : seen.consistency == 'check' ? 'raises something to check against the loss as reported' : 'is unclear against the loss as reported';
        return found('The photos point to ' + blankAs(seen.lossSeen, 'damage').uncapitalize() + ', which ' + fits, new List<String>{ '[' + PHOTOS_KEY + '] WHAT THE PHOTOS SHOW (from the photo assessment on file)', photoLines(seen) });
    }

    private static Result priorClaims(Id caseId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        Integer earlier = count(facts, 'X');
        List<String> lines = new List<String>{ 'EARLIER CLAIMS BY THE SAME CUSTOMER' };
        lines.addAll(keyed(facts, 'X'));
        return found(earlier == 0 ? 'No earlier claims by this customer' : plural(earlier, 'earlier claim') + ' by this customer', lines);
    }

    /** Checks the finding the agent wants to record. Stores nothing: the caller saves it, and only then tells the agent it is recorded. */
    private static Result check(Id caseId, Map<String, Object> input) {
        AntsuranceClaimsAssistantCoverage.Facts facts = facts(caseId);
        Map<String, AntsuranceClaimsAssistantCoverage.Source> byKey = new Map<String, AntsuranceClaimsAssistantCoverage.Source>();
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            byKey.put(entry.key, entry);
        }
        List<String> problems = new List<String>();
        if (input == null || !VERDICTS.contains(String.valueOf(input.get('verdict')))) {
            problems.add('verdict must be exactly Covered, Not covered or Needs review.');
        }
        List<Object> findings = input?.get('findings') instanceof List<Object> ? (List<Object>) input.get('findings') : new List<Object>();
        if (findings.isEmpty() || findings.size() > MAX_FINDINGS) {
            problems.add('Give three to six findings.');
        }
        for (Object item : findings) {
            Map<String, Object> finding = item instanceof Map<String, Object> ? (Map<String, Object>) item : new Map<String, Object>();
            String cited = String.valueOf(finding.get('source'));
            if (String.isBlank((String) finding.get('text'))) {
                problems.add('Every finding needs its sentence in "text".');
            } else if (((String) finding.get('text')).length() > MAX_SENTENCE_CHARS) {
                problems.add('A finding is one sentence of at most 30 words. Shorten the one that begins "' + ((String) finding.get('text')).left(40) + '".');
            } else if (!byKey.containsKey(cited)) {
                problems.add('The source "' + cited + '" is not a key a tool gave you. Use one of: ' + String.join(new List<String>(byKey.keySet()), ', ') + '.');
            }
        }
        String responding = String.valueOf(input?.get('responding'));
        AntsuranceClaimsAssistantCoverage.Source responder = byKey.get(responding);
        if (responding != NONE && (responder == null || (responder.kind != 'Coverage' && responder.kind != 'Endorsement'))) {
            problems.add('responding must be the key of a coverage or an endorsement that is not an exclusion, or NONE.');
        }
        if (String.isBlank((String) input?.get('summary'))) {
            problems.add('Give the one-sentence summary.');
        } else if (((String) input.get('summary')).length() > MAX_SENTENCE_CHARS) {
            problems.add('The summary is one sentence of at most 25 words.');
        }
        for (String name : new List<String>{ 'questions', 'would_change' }) {
            List<String> points = AntsuranceAiClient.toStrings(input?.get(name));
            Boolean isLong = points.size() > MAX_POINTS;
            for (String point : points) {
                isLong = isLong || point.length() > MAX_SENTENCE_CHARS;
            }
            if (isLong) {
                problems.add('Give at most three ' + (name == 'questions' ? 'questions' : 'would_change facts') + ', each one short sentence.');
            }
        }
        if (!problems.isEmpty()) {
            return problem('Not recorded. ' + String.join(problems, ' ') + ' Fix it and call record_finding again.');
        }
        // Nothing is saved here and the agent is not told "recorded" here: the caller saves the
        // finding first and hands back acknowledged() only once it is on the claim.
        AntsuranceClaimsAssistantCoverage.Check check = AntsuranceClaimsAssistantCoverage.checkFrom(input, facts);
        Result result = acknowledged(found(check.verdict, check.respondingLabel));
        result.check = check;
        return result;
    }

    /**
     * @description A finding in a few words, for the trace and for the agent.
     * @param verdict Covered, Not covered or Needs review
     * @param respondingLabel The coverage or endorsement that responds. May be null.
     * @return Such as "Covered, under Dwelling"
     */
    public static String found(String verdict, String respondingLabel) {
        return verdict + (String.isBlank(respondingLabel) ? '' : ', under ' + respondingLabel);
    }

    // ------------------------------------------------------------ helpers

    private static List<Case> earlierClaims(Id caseId) {
        List<Case> claims = [SELECT AccountId FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
        if (claims.isEmpty() || claims[0].AccountId == null) {
            return new List<Case>();
        }
        Id customerId = claims[0].AccountId;
        return [
            SELECT Id, CaseNumber, Subject, Status, Loss_Type__c, Date_of_Loss__c, Estimated_Loss__c, Paid_Amount__c, Policy__r.Name
            FROM Case
            WHERE AccountId = :customerId AND Id != :caseId AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Date_of_Loss__c DESC NULLS LAST, CaseNumber DESC
            LIMIT :MAX_PRIOR_CLAIMS
        ];
    }

    private static String photoLines(AntsuranceClaimsAssistantPhotos.Assessment seen) {
        List<String> lines = new List<String>{ 'Damage seen: ' + seen.damageSummary };
        if (String.isNotBlank(seen.lossSeen)) {
            lines.add('The photos point to: ' + seen.lossSeen + '.');
        }
        if (String.isNotBlank(seen.consistencyNote)) {
            lines.add('Against the loss as reported (' + blankAs(seen.consistency, 'unclear') + '): ' + seen.consistencyNote);
        }
        if (seen.signals != null && !seen.signals.isEmpty()) {
            lines.add('Visible signs: ' + String.join(seen.signals, '; ') + '.');
        }
        return String.join(lines, '\n');
    }

    /**
     * Gives each record the key the session knows it by. A record the session has no key for, such
     * as a file added while the agent works, takes the next number after the highest the session
     * holds, in the order the records were created, so it gets the same key on every later request.
     * A record that has gone since simply has no entry: its key answers "no such record", and no
     * other key moves up to take its place.
     */
    private static void keepHeldKeys(AntsuranceClaimsAssistantCoverage.Facts facts) {
        if (heldByRecord == null) {
            return;
        }
        Map<String, Integer> highest = new Map<String, Integer>();
        for (String key : heldByKey.keySet()) {
            Integer held = Integer.valueOf(key.substring(1));
            highest.put(key.left(1), Math.max(held, highest.containsKey(key.left(1)) ? highest.get(key.left(1)) : 0));
        }
        Map<String, AntsuranceClaimsAssistantCoverage.Source> added = new Map<String, AntsuranceClaimsAssistantCoverage.Source>();
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            if (entry.recordId == null || !isNumbered(entry.key)) {
                continue;
            }
            String held = heldByRecord.get(entry.recordId);
            if (held != null && held.left(1) == entry.key.left(1)) {
                entry.key = held;
            } else {
                // Record Ids rise as records are created, so sorting on them puts the newest last. Notes are of two
                // kinds, a file note and a note in Salesforce Notes, whose Ids do not share an order: when each was made goes first.
                String made = entry.madeAt == null ? '' : String.valueOf(entry.madeAt.getTime()).leftPad(15, '0');
                added.put(entry.key.left(1) + made + String.valueOf(entry.recordId), entry);
            }
        }
        List<String> inOrder = new List<String>(added.keySet());
        inOrder.sort();
        for (String name : inOrder) {
            String letter = name.left(1);
            Integer next = (highest.containsKey(letter) ? highest.get(letter) : 0) + 1;
            highest.put(letter, next);
            added.get(name).key = letter + next;
        }
    }

    /** The title of the document a key stands for, without loading the whole claim when the session's keys say which file it is. */
    private static String documentTitle(Id caseId, String key) {
        // Only a D key stands for a document. A note's key, asked for by mistake, is not named as one.
        if (key == null || !key.startsWith('D')) {
            return null;
        }
        if (heldByKey == null || factsByClaim.containsKey(caseId)) {
            return sourceFor(caseId, key)?.label;
        }
        Id documentId = heldByKey.get(key);
        if (documentId == null) {
            // Not a key the session started with: a file added since, which only the claim as it is now can name.
            return sourceFor(caseId, key)?.label;
        }
        if (!titlesByClaim.containsKey(caseId)) {
            Map<Id, String> titles = new Map<Id, String>();
            try {
                // A note in Salesforce Notes is a file to the platform, and is never named as a document here.
                for (ContentDocumentLink link : [
                    SELECT ContentDocumentId, ContentDocument.Title
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :caseId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
                    WITH USER_MODE
                    LIMIT :MAX_LINKED_FILES
                ]) {
                    titles.put(link.ContentDocumentId, link.ContentDocument.Title);
                }
            } catch (QueryException e) {
                // A label is a courtesy; the tool itself reports what could not be read.
                titles.clear();
            }
            titlesByClaim.put(caseId, titles);
        }
        return titlesByClaim.get(caseId).get(documentId);
    }

    /** True for a key that is a letter and a number, such as C1 or D12. CLAIM, POLICY, PHOTOS and EXTRA are not. */
    private static Boolean isNumbered(String key) {
        return key != null && key.length() > 1 && key.substring(1).isNumeric();
    }

    private static AntsuranceClaimsAssistantCoverage.Source sourceFor(Id caseId, String key) {
        try {
            for (AntsuranceClaimsAssistantCoverage.Source entry : facts(caseId).sources) {
                if (entry.key == key) {
                    return entry;
                }
            }
        } catch (Exception e) {
            // A label is a courtesy; the tool itself reports what could not be read.
            return null;
        }
        return null;
    }

    /** The lines for every record whose key is the prefix and a number, each under its key. */
    private static List<String> keyed(AntsuranceClaimsAssistantCoverage.Facts facts, String prefix) {
        List<String> lines = new List<String>();
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            if (entry.text != null && entry.key.startsWith(prefix) && entry.key.substring(1).isNumeric()) {
                lines.add('[' + entry.key + '] ' + entry.text);
            }
        }
        if (lines.isEmpty()) {
            lines.add('none recorded');
        }
        return lines;
    }

    private static Integer count(AntsuranceClaimsAssistantCoverage.Facts facts, String prefix) {
        Integer total = 0;
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            if (entry.key.startsWith(prefix) && entry.key.substring(1).isNumeric()) {
                total++;
            }
        }
        return total;
    }

    private static Boolean has(AntsuranceClaimsAssistantCoverage.Facts facts, String key) {
        for (AntsuranceClaimsAssistantCoverage.Source entry : facts.sources) {
            if (entry.key == key) {
                return true;
            }
        }
        return false;
    }

    /** The first sentence of a passage, without its full stop. A stop inside a figure, such as $9,971.20, does not end it. */
    private static String firstSentence(String passage) {
        Matcher ending = Pattern.compile('\\.\\s+(?=[A-Z])').matcher(passage);
        return (ending.find() ? passage.substring(0, ending.start()) : passage).trim().removeEnd('.');
    }

    private static Result found(String summary, List<String> lines) {
        Result result = new Result();
        result.found = summary;
        result.text = ('FOUND: ' + summary + '.\n' + String.join(lines, '\n')).left(MAX_RESULT_CHARS);
        return result;
    }

    private static Result problem(String message) {
        Result result = new Result();
        result.isError = true;
        result.found = message;
        result.text = message;
        return result;
    }

    private static AntsuranceClaimsAssistantCoverage.Source source(String key, String kind, String label, Id recordId, String text) {
        AntsuranceClaimsAssistantCoverage.Source entry = new AntsuranceClaimsAssistantCoverage.Source();
        entry.key = key;
        entry.kind = kind;
        entry.label = label;
        entry.recordId = recordId;
        entry.text = text;
        return entry;
    }

    private static String tool(String name, String description, String schema) {
        return '{"type":"custom","name":' + JSON.serialize(name) + ',"description":' + JSON.serialize(description) + ',' + schema + '}';
    }

    private static String plural(Integer total, String one) {
        return plural(total, one, one + 's');
    }

    private static String plural(Integer total, String one, String many) {
        return total + ' ' + (total == 1 ? one : many);
    }

    private static String blankAs(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static String day(Date value) {
        return value == null ? 'not recorded' : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    private static String money(Decimal value) {
        return value == null ? 'not set' : '$' + value.setScale(0, RoundingMode.HALF_UP).format();
    }
}
