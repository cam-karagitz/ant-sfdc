/**
 * @description Claude's read of whether the policy responds to a claim, for the coverage check on
 * the claim page. On request it reads the claim against the policy as the record shows it (term,
 * coverages, endorsements and exclusions, who and what is on it, the file notes) and answers:
 * covered, not covered or needs review; which coverage responds; and what is still unknown.
 *
 * Every finding names the one record it rests on. Claude can only choose from the records it was
 * given, because the answer schema lists them, so a finding can never cite something that is not
 * in the file. The limit, the deductible and what is payable are then read and worked out here
 * from the record Claude chose, not taken from Claude's own arithmetic.
 *
 * The org holds a policy's coverages and endorsements, not the wording of its forms. The prompt
 * says so, and the card repeats it, so the check is read as advice for the adjuster to confirm.
 * The check is stored on the claim (Coverage_Read__c, as JSON) with the facts it was written
 * from, which is how the card knows when the claim or the policy has changed since.
 *
 * To use the check from other Apex, call read (the stored check, Claude is never asked), run
 * (ask Claude and store), readOrRun (the stored check while it still stands, otherwise run) or
 * preview (ask Claude, store nothing). stands says whether a stored check can be used as it is. Each takes the claim's Id, returns a Check and throws
 * CoverageException with a message fit to show. run, readOrRun and preview take optional extra
 * facts as text, such as what the claim's photos show, and reason coverage against them too.
 * They call out, so call them before any DML in the same transaction. The @AuraEnabled methods
 * are the same calls for the card.
 */
public with sharing class AntsuranceClaimsAssistantCoverage {
    public static final String COVERED = 'Covered';
    public static final String NOT_COVERED = 'Not covered';
    public static final String NEEDS_REVIEW = 'Needs review';
    private static final List<String> VERDICTS = new List<String>{ COVERED, NOT_COVERED, NEEDS_REVIEW };
    private static final String NONE = 'NONE';
    private static final String CLAIM_KEY = 'CLAIM';
    private static final String POLICY_KEY = 'POLICY';
    private static final String EXTRA_KEY = 'EXTRA';
    private static final Integer MAX_EXTRA_CHARS = 6000;
    private static final Integer MAX_NOTES = 20;
    private static final Integer MAX_NOTE_CHARS = 1200;
    private static final Integer MAX_FILES = 20;
    // Read past the limits above before leaving out Claude's own notes and approved letters, so
    // leaving one out never pushes a real note or file off the end of what is counted.
    private static final Integer MAX_NOTES_READ = 60;
    private static final Integer MAX_FILES_READ = 200;
    /** The name of the part the coverage agent keeps beside a check it reached: how it worked. */
    public static final String AGENT_PART = 'agent';
    private static final Integer MAX_TOKENS = 2048;
    private static final Integer MAX_NAME = 80;

    @TestVisible
    private static final String NOT_A_CLAIM = 'Coverage is checked on claims only. This is a service request.';
    @TestVisible
    private static final String NO_POLICY = 'This claim has no policy linked, so there is nothing to check it against. Link the policy first.';
    @TestVisible
    private static final String NO_ACCESS = 'This claim could not be read or saved. Check your access to claims.';
    @TestVisible
    private static final String NOTHING_TO_CONFIRM = 'There is no coverage check on this claim to confirm.';
    @TestVisible
    private static final String CLAIM_BUSY = 'Someone else is saving this claim right now. Try again in a moment.';
    @TestVisible
    private static final String CANNOT_EDIT = 'You can read this claim but not change it, so the check cannot be saved on it.';
    @TestVisible
    private static final String TOO_LONG = 'The check is too long to save on the claim.';

    private static final String INSTRUCTIONS =
        'You are a senior coverage examiner at Antsurance, an insurance carrier. An adjuster has a claim open and asks one question: does this policy respond to this loss? ' +
        'You are given the claim, its policy, the coverages on the policy, its endorsements and exclusions, who and what is on the policy, the file notes and the names of attached documents. ' +
        'Each record has a key in square brackets, such as [C2] or [E1]. The adjuster decides; you advise, and you show what each statement rests on.\n\n' +
        'Work through the questions an examiner asks, in this order.\n' +
        '1. Was the policy in force on the date of loss? The date of loss must fall within the term. A policy shown as cancelled or lapsed, or with payments past due, needs a look at when that happened. ' +
        'If there is no date of loss, that is unknown.\n' +
        '2. Is the loss the kind of thing a coverage on this policy pays for? Match the type and the description of the loss to one coverage or endorsement, using what each one says it covers. ' +
        'A coverage, endorsement or person added after the date of loss was not on the policy at the time.\n' +
        '3. Does an exclusion or condition take it away? Read every exclusion against the cause of the loss.\n' +
        '4. Is the person or the thing involved on the policy? For a vehicle loss, check the driver and the vehicle against who and what is listed. ' +
        'An excluded driver is not covered. A driver or a vehicle that is not listed is a question to settle, not an answer.\n' +
        '5. Do the limit and deductible leave anything to pay? An estimate above the limit is still a covered loss; say that the limit caps it.\n\n' +
        'verdict: "Covered" when the policy was in force, a coverage on it plainly responds and nothing given takes it away. ' +
        '"Not covered" when the record shows why not: the loss fell outside the term, no coverage or endorsement on the policy responds to this kind of loss, an exclusion applies, or the driver is excluded. ' +
        '"Needs review" when the record is silent or mixed on something that decides it. Never guess: when you cannot tell from what you were given, the verdict is "Needs review".\n\n' +
        'responding: the key of the one coverage or endorsement that would pay for this loss, or NONE when nothing on the policy does. ' +
        'Give it for "Needs review" too when one coverage would respond if the open point is settled.\n\n' +
        'Coverage and liability are separate questions. When the loss is someone else\'s injury or damage (a liability claim), say whether the policy would respond if the insured is legally responsible. ' +
        'Do not decide responsibility yourself, and do not let a doubt about responsibility change a coverage verdict. ' +
        'liability_open: true only when the coverage that responds is a liability coverage and the file does not establish that the insured is responsible, or says they are not. ' +
        'False for a loss to the insured\'s own property and when responsibility is established.\n\n' +
        'When the claim has already been denied or closed, one finding says whether the reason in the file is a coverage reason or something else, such as no liability or no proof of loss, ' +
        'and whether your read of coverage agrees with it. The summary then says so too.\n\n' +
        'findings: three to six, most decisive first. Each is one sentence of at most 30 words that says what the record shows and what that means for coverage, ' +
        'and names in "source" the key of the one record it rests on. Use CLAIM for facts of the loss and POLICY for the term and status. Do not repeat a finding.\n\n' +
        'summary: one sentence of at most 25 words giving the answer and its main reason.\n\n' +
        'questions: zero to three things to ask the insured that the file does not answer and that bear on coverage. Each is a question of at most 20 words.\n\n' +
        'would_change: zero to three facts that, if they turned out differently, would change the verdict. Each is one short sentence.\n\n' +
        'You have the coverages and endorsements as they are recorded, not the wording of the policy forms. Reason from what the record shows. ' +
        'Where the form wording would decide the point (how a peril is defined, what counts as sudden, who is an insured), say so in a finding or in would_change rather than assuming the wording. ' +
        'Never state a fact, a figure or a name that is not in what you were given.\n\n' +
        'When ADDITIONAL FACTS FROM THE EVIDENCE are given, they describe what the claim\'s photos or documents show. Treat them as facts of the loss alongside the claim, ' +
        'say so in a finding where they differ from the description, and cite them as EXTRA.\n\n' +
        'Write in plain words and complete sentences. Write money with a dollar sign and thousands separators, and dates month first, like Sep 28, 2026. ' +
        AntsuranceClaimRules.LASTING_WORDS +
        'Refer to coverages and people by their names, not their keys. Do not use dashes as punctuation, and do not use Markdown. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH +
        '\n\n' +
        AntsuranceClaimRules.RESERVE_RULE +
        ' This check answers whether the policy responds, not how much to reserve: mention the reserve only where it bears on coverage, and never call it short because it is below the gross estimate.';

    /**
     * @description Thrown when a check cannot be read, run or saved. The message is fit to show.
     */
    public class CoverageException extends Exception {
    }

    /**
     * @description One record the check can rest on, as Claude sees it and as the card links to it.
     */
    public class Source {
        public String key;
        /** Claim, Policy, Coverage, Endorsement, Exclusion, Participant, Insured item or File note. */
        public String kind;
        public String label;
        public Id recordId;
        /** The line Claude reads. */
        public String text;
        public Decimal limitAmount;
        public String limitBasis;
        public Decimal deductible;
        /** When a note was made, so notes of both kinds added later can be put in the order they came. */
        public Datetime madeAt;
    }

    /**
     * @description Everything the check reads about one claim.
     */
    public class Facts {
        public List<String> claimLines = new List<String>();
        public List<String> policyLines = new List<String>();
        public List<Source> sources = new List<Source>();
        public List<String> documents = new List<String>();
        /**
         * Files on the claim that are approved letters: what the carrier sent, not evidence that came
         * in. They are not among the documents, so approving a letter does not make a check out of date.
         */
        public Set<Id> ownLetters = new Set<Id>();
        /** Facts from outside the record, such as what the claim's photos show. Optional. */
        public String extraFacts;
        public Decimal estimate;
        public Decimal policyDeductible;
        /** What the check depends on, kept with it to tell later whether anything has changed. */
        public Map<String, Object> snapshot = new Map<String, Object>();
    }

    /**
     * @description One thing the record shows, and the record it rests on.
     */
    public class Finding {
        @AuraEnabled
        public String text;
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String sourceLabel;
        @AuraEnabled
        public String sourceKind;
    }

    /**
     * @description The coverage check as the card shows it.
     */
    public class Check {
        /** False when coverage has not been checked on this claim yet. */
        @AuraEnabled
        public Boolean exists = false;
        @AuraEnabled
        public String verdict;
        @AuraEnabled
        public String summary;
        /** The coverage or endorsement that responds. Blank when none does. */
        @AuraEnabled
        public String respondingLabel;
        @AuraEnabled
        public String respondingKind;
        @AuraEnabled
        public Id respondingId;
        @AuraEnabled
        public Decimal limitAmount;
        @AuraEnabled
        public String limitBasis;
        @AuraEnabled
        public Decimal deductible;
        @AuraEnabled
        public Decimal estimate;
        /** What the limit and deductible leave payable against the estimate. Null when there is no estimate. */
        @AuraEnabled
        public Decimal payable;
        /** True when the estimate, less the deductible, is more than the limit. */
        @AuraEnabled
        public Boolean cappedByLimit = false;
        /** True when a liability coverage responds but the file does not show the insured is legally responsible, so nothing is payable until that is settled. */
        @AuraEnabled
        public Boolean liabilityOpen = false;
        @AuraEnabled
        public List<Finding> findings = new List<Finding>();
        @AuraEnabled
        public List<String> questions = new List<String>();
        @AuraEnabled
        public List<String> wouldChange = new List<String>();
        /** Facts from outside the record that this check was also reasoned against. Blank when there were none. */
        @AuraEnabled
        public String extraFacts;
        @AuraEnabled
        public Datetime writtenAt;
        /** True when the claim or its policy has changed since the check was written. */
        @AuraEnabled
        public Boolean stale = false;
        @AuraEnabled
        public List<String> changes = new List<String>();
        @AuraEnabled
        public String confirmedBy;
        @AuraEnabled
        public Datetime confirmedAt;
        /** True when the coverage agent reached this check by working the file itself, rather than one call given the evidence as text. */
        @AuraEnabled
        public Boolean byAgent = false;
    }

    /**
     * @description The stored coverage check for a claim, for the card. See read.
     * @param caseId The claim on screen
     * @return The stored check, or exists = false when coverage has not been checked
     * @throws AuraHandledException when the record is not a claim or cannot be read
     */
    @AuraEnabled
    public static Check getCheck(Id caseId) {
        try {
            return read(caseId);
        } catch (CoverageException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Has Claude check coverage and stores the answer, for the card. See run.
     * @param caseId The claim on screen
     * @return The new check
     * @throws AuraHandledException when the record is not a claim, has no policy, cannot be read
     * or saved, or Claude cannot be reached
     */
    @AuraEnabled
    public static Check writeCheck(Id caseId) {
        try {
            return run(caseId, null);
        } catch (CoverageException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description Records that the adjuster has read the check and agrees with it. Claude advises;
     * this is the adjuster's decision, kept with their name and the time.
     * @param caseId The claim on screen
     * @return The check, now confirmed
     * @throws AuraHandledException when there is no check to confirm or the claim cannot be saved
     */
    @AuraEnabled
    public static Check confirm(Id caseId) {
        try {
            Case claim = loadClaim(caseId);
            if (String.isBlank(claim.Coverage_Read__c)) {
                throw handled(NOTHING_TO_CONFIRM);
            }
            Datetime now = Datetime.now();
            String name = UserInfo.getName().left(MAX_NAME);
            update as user new Case(Id = caseId, Coverage_Confirmed_By__c = name, Coverage_Confirmed_At__c = now);
            claim.Coverage_Confirmed_By__c = name;
            claim.Coverage_Confirmed_At__c = now;
            return stored(claim, claim.Policy__c == null ? null : loadFacts(claim, null));
        } catch (CoverageException e) {
            throw handled(e.getMessage());
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    /**
     * @description The stored coverage check for a claim, with whether it is still current and
     * who has confirmed it. Claude is never asked.
     * @param caseId The claim
     * @return The stored check, or exists = false when coverage has not been checked
     * @throws CoverageException when the record is not a claim or cannot be read
     */
    public static Check read(Id caseId) {
        try {
            Case claim = loadClaim(caseId);
            if (String.isBlank(claim.Coverage_Read__c)) {
                return new Check();
            }
            return stored(claim, claim.Policy__c == null ? null : loadFacts(claim, null));
        } catch (QueryException e) {
            throw new CoverageException(NO_ACCESS);
        }
    }

    /**
     * @description Has Claude read the claim against its policy, and stores the answer on the
     * claim. Any earlier confirmation is cleared, because it was given for a different read.
     * Calls out and then saves, so call it before any DML of your own.
     * @param caseId The claim
     * @param extraFacts Facts from outside the record to reason against as well, such as what
     * the claim's photos show. May be null.
     * @return The new check
     * @throws CoverageException when the record is not a claim, has no policy, cannot be read
     * or saved, or Claude cannot be reached
     */
    public static Check run(Id caseId, String extraFacts) {
        Outcome outcome = ask(caseId, extraFacts);
        Check check = outcome.check;
        try {
            update as user
                new Case(
                    Id = caseId,
                    Coverage_Read__c = outcome.storable,
                    Coverage_Read_At__c = check.writtenAt,
                    Coverage_Verdict__c = check.verdict,
                    Coverage_Confirmed_By__c = null,
                    Coverage_Confirmed_At__c = null
                );
        } catch (DmlException e) {
            throw new CoverageException(saveProblem(e));
        }
        return check;
    }

    /**
     * @description The stored check while it still stands for these extra facts (see stands);
     * otherwise a new one, run and stored.
     * @param caseId The claim
     * @param extraFacts Facts from outside the record to reason against as well. May be null.
     * @return The check
     * @throws CoverageException as read and run do
     */
    public static Check readOrRun(Id caseId, String extraFacts) {
        Check existing = read(caseId);
        return stands(existing, extraFacts, null) ? existing : run(caseId, extraFacts);
    }

    /**
     * @description Whether a stored check still stands for a caller that has evidence of its own
     * to reason against, or has to be run again.
     *
     * A check from one call stands while the claim and policy are as they were and it was given
     * the same evidence. The coverage agent's check is different: the agent read the documents for
     * itself, so what it took into account is never word for word the caller's, and comparing the
     * two as text would always replace the agent's finding and clear the adjuster's confirmation
     * of it. Its check stands while the claim and policy are as they were and nothing it could only
     * take as written, which is the photo assessment, has been redone since.
     * @param existing The stored check, from read
     * @param extraFacts The caller's evidence as text. May be blank.
     * @param evidenceChangedAt When the photo assessment the caller holds was made. Null when
     * there is none or it is not known.
     * @return True when the stored check can be used as it is
     */
    public static Boolean stands(Check existing, String extraFacts, Datetime evidenceChangedAt) {
        if (existing == null || existing.exists != true || existing.stale == true) {
            return false;
        }
        if (String.isBlank(extraFacts) || clip(extraFacts) == existing.extraFacts) {
            return true;
        }
        return existing.byAgent == true && (evidenceChangedAt == null || existing.writtenAt == null || evidenceChangedAt <= existing.writtenAt);
    }

    /**
     * @description Has Claude read the claim against its policy and returns the answer without
     * storing it.
     * @param caseId The claim
     * @param extraFacts Facts from outside the record to reason against as well. May be null.
     * @return The check, not stored
     * @throws CoverageException when the record is not a claim, has no policy, cannot be read,
     * or Claude cannot be reached
     */
    public static Check preview(Id caseId, String extraFacts) {
        return ask(caseId, extraFacts).check;
    }

    /**
     * @description The facts of a claim as the check reads them, each record under its key. Claude
     * is not asked and nothing is saved. For the coverage agent, whose tools hand these to Claude a
     * part at a time and whose finding cites the same keys.
     * @param caseId The claim
     * @return The facts
     * @throws CoverageException when the record is not a claim, has no policy or cannot be read
     */
    public static Facts factsFor(Id caseId) {
        try {
            Case claim = loadClaim(caseId);
            if (claim.Policy__c == null) {
                throw new CoverageException(NO_POLICY);
            }
            return loadFacts(claim, null);
        } catch (QueryException e) {
            throw new CoverageException(NO_ACCESS);
        }
    }

    /**
     * @description Turns an answer in the check's own answer shape (findings with a source key,
     * responding, verdict, liability_open, summary, questions, would_change) into a check, reading
     * the limit, deductible and payable amount from the record it names. Nothing is saved.
     * @param answer The answer, however it was reached
     * @param facts The facts it was reached from; a key that is not among them is not linked
     * @return The check, not stored
     */
    public static Check checkFrom(Map<String, Object> answer, Facts facts) {
        Check check = toCheck(answer, facts);
        check.extraFacts = facts.extraFacts;
        return check;
    }

    /**
     * @description Stores a check reached outside this class the way run stores its own, clearing
     * any earlier confirmation. Other parts can be kept beside it in the same field; read and
     * getCheck ignore them, so everything that reads a stored check keeps working.
     * @param caseId The claim
     * @param check The check, from checkFrom
     * @param facts The facts it was reached from, kept to tell later whether anything has changed
     * @param extras Other parts to keep beside the check, by name. May be null.
     * @return The check as stored
     * @throws CoverageException when the claim cannot be saved, in words fit to show
     */
    public static Check store(Id caseId, Check check, Facts facts, Map<String, Object> extras) {
        check.exists = true;
        check.writtenAt = Datetime.now();
        Map<String, Object> storable = new Map<String, Object>{ 'check' => check, 'facts' => facts.snapshot };
        if (extras != null) {
            for (String name : extras.keySet()) {
                if (name != 'check' && name != 'facts') {
                    storable.put(name, extras.get(name));
                }
            }
        }
        check.byAgent = storable.get(AGENT_PART) != null;
        String stored = JSON.serialize(storable);
        if (stored.length() > maxStored()) {
            throw new CoverageException(TOO_LONG);
        }
        try {
            update as user
                new Case(
                    Id = caseId,
                    Coverage_Read__c = stored,
                    Coverage_Read_At__c = check.writtenAt,
                    Coverage_Verdict__c = check.verdict,
                    Coverage_Confirmed_By__c = null,
                    Coverage_Confirmed_At__c = null
                );
        } catch (DmlException e) {
            throw new CoverageException(saveProblem(e));
        }
        return check;
    }

    /**
     * @description How much text the claim's field for the check holds, in characters. For a caller
     * that keeps a part of its own beside the check and has to cut it to fit.
     * @return The length of Case.Coverage_Read__c
     */
    public static Integer maxStored() {
        return Case.Coverage_Read__c.getDescribe().getLength();
    }

    /** Why a check could not be saved, in words for the person rather than the platform's. */
    private static String saveProblem(DmlException e) {
        StatusCode why = e.getDmlType(0);
        if (why == StatusCode.UNABLE_TO_LOCK_ROW) {
            return CLAIM_BUSY;
        }
        if (why == StatusCode.INSUFFICIENT_ACCESS_OR_READONLY || why == StatusCode.INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY) {
            return CANNOT_EDIT;
        }
        if (why == StatusCode.STRING_TOO_LONG) {
            return TOO_LONG;
        }
        // A validation rule's own message is already written for the person.
        return e.getDmlMessage(0);
    }

    /** A check Claude has just made, and the text to store for it: the check with the facts it was written from. */
    private class Outcome {
        Check check;
        String storable;
    }

    private static Outcome ask(Id caseId, String extraFacts) {
        Facts facts;
        try {
            Case claim = loadClaim(caseId);
            if (claim.Policy__c == null) {
                throw new CoverageException(NO_POLICY);
            }
            facts = loadFacts(claim, extraFacts);
        } catch (QueryException e) {
            throw new CoverageException(NO_ACCESS);
        }
        Check check;
        try {
            check = assess(facts);
        } catch (AntsuranceAiClient.AiException e) {
            throw new CoverageException(e.getMessage());
        }
        check.writtenAt = Datetime.now();
        Outcome outcome = new Outcome();
        outcome.check = check;
        outcome.storable = JSON.serialize(new Map<String, Object>{ 'check' => check, 'facts' => facts.snapshot });
        return outcome;
    }

    /**
     * @description Asks Claude the coverage question for one set of facts and works out the figures.
     * Nothing is saved. The claim page reaches this through writeCheck; the accuracy cases in
     * scripts/eval/coverage call it directly with facts built in memory.
     * @param facts The claim, its policy and the records the check may rest on
     * @return The check, not yet stored
     * @throws AntsuranceAiClient.AiException when Claude cannot be reached or gives no usable answer
     */
    public static Check assess(Facts facts) {
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, describe(facts)).returning(schema(facts));
        question.maxTokens = MAX_TOKENS;
        Check check = toCheck(AntsuranceAiClient.ask(question).data, facts);
        check.extraFacts = facts.extraFacts;
        return check;
    }

    /**
     * @description Adds facts from outside the record to a set of facts, as something the check
     * may cite. Used for what a claim's photos or documents show.
     * @param facts The facts built from the records
     * @param extraFacts The extra facts as text. Blank adds nothing.
     * @return The same facts, for chaining
     */
    public static Facts withExtra(Facts facts, String extraFacts) {
        if (String.isNotBlank(extraFacts)) {
            facts.extraFacts = clip(extraFacts);
            facts.sources.add(source(EXTRA_KEY, 'Evidence', 'Photos and documents on the claim', null, null));
        }
        return facts;
    }

    private static String clip(String extraFacts) {
        return String.isBlank(extraFacts) ? null : extraFacts.trim().left(MAX_EXTRA_CHARS);
    }

    /**
     * @description Builds the facts for a claim from its records. The claim page passes what it
     * queried; the accuracy cases pass records built in memory, so both are written out for Claude
     * the same way.
     * @param claim The claim
     * @param policy The claim's policy
     * @param coverages The coverages on the policy
     * @param endorsements The endorsements and exclusions on the policy
     * @param participants The people and organisations on the policy
     * @param assets What the policy insures
     * @param notes The claim's file notes, newest first, with any Salesforce notes among them (see AntsuranceSalesforceNotes.withFileNotes)
     * @param documents The names of files attached to the claim
     * @return The facts, with a key for every record the check may cite
     */
    public static Facts factsFrom(
        Case claim,
        Policy__c policy,
        List<Policy_Coverage__c> coverages,
        List<Policy_Endorsement__c> endorsements,
        List<Policy_Participant__c> participants,
        List<Policy_Asset__c> assets,
        List<File_Note__c> notes,
        List<String> documents
    ) {
        Facts facts = new Facts();
        facts.estimate = claim.Estimated_Loss__c;
        facts.policyDeductible = policy.Deductible__c;
        facts.documents = documents == null ? new List<String>() : documents;

        facts.claimLines = new List<String>{
            '[' + CLAIM_KEY + '] ' + (claim.CaseNumber == null ? '' : claim.CaseNumber + ': ') + claim.Subject,
            'Claim status: ' + blankAs(claim.Status, 'not recorded') + (claim.IsClosed == true ? ' (closed)' : ''),
            'Type of loss: ' + blankAs(claim.Loss_Type__c, 'not recorded'),
            'Date of loss: ' + day(claim.Date_of_Loss__c) + '. Reported: ' + day(claim.Reported_Date__c) + '.',
            'Where: ' + blankAs(claim.Loss_Location__c, 'not recorded'),
            'What happened: ' + blankAs(claim.Description, 'not recorded'),
            'Estimated loss: ' + money(claim.Estimated_Loss__c) + '. Reserve: ' + money(claim.Reserve_Amount__c) + '.'
        };
        facts.sources.add(source(CLAIM_KEY, 'Claim', blankAs(claim.Subject, 'This claim'), claim.Id, null));

        facts.policyLines = new List<String>{
            '[' + POLICY_KEY + '] ' + policy.Name + ': ' + policy.Line_of_Business__c + ', status today ' + policy.Status__c + ', payments ' + blankAs(policy.Payment_Status__c, 'not recorded'),
            'Term: ' + day(policy.Effective_Date__c) + ' to ' + day(policy.Expiration_Date__c),
            'Insures: ' + blankAs(policy.Insured_Item__c, 'not recorded'),
            'Policy limit ' + money(policy.Coverage_Limit__c) + ', policy deductible ' + money(policy.Deductible__c)
        };
        facts.sources.add(source(POLICY_KEY, 'Policy', policy.Name, policy.Id, null));

        Integer index = 0;
        for (Policy_Coverage__c coverage : coverages) {
            index++;
            Source entry = source(
                'C' + index,
                'Coverage',
                coverage.Name,
                coverage.Id,
                coverage.Name +
                    (String.isBlank(coverage.Category__c) ? '' : ' (' + coverage.Category__c + ')') +
                    ': limit ' +
                    money(coverage.Limit_Amount__c) +
                    (String.isBlank(coverage.Limit_Type__c) ? '' : ' ' + coverage.Limit_Type__c) +
                    ', deductible ' +
                    (coverage.Deductible_Amount__c == null ? 'none' : money(coverage.Deductible_Amount__c)) +
                    since(coverage.Effective_Date__c) +
                    status(coverage.Status__c) +
                    (String.isBlank(coverage.What_Is_Covered__c) ? '' : '. Covers: ' + coverage.What_Is_Covered__c)
            );
            entry.limitAmount = coverage.Limit_Amount__c;
            entry.limitBasis = coverage.Limit_Type__c;
            entry.deductible = coverage.Deductible_Amount__c == null ? 0 : coverage.Deductible_Amount__c;
            facts.sources.add(entry);
        }
        index = 0;
        for (Policy_Endorsement__c endorsement : endorsements) {
            index++;
            Boolean isExclusion = endorsement.Type__c == 'Exclusion';
            Source entry = source(
                'E' + index,
                isExclusion ? 'Exclusion' : 'Endorsement',
                endorsement.Name,
                endorsement.Id,
                blankAs(endorsement.Type__c, 'Endorsement') +
                    (String.isBlank(endorsement.Form_Number__c) ? '' : ', form ' + endorsement.Form_Number__c) +
                    ': ' +
                    endorsement.Name +
                    (endorsement.Limit_Amount__c == null ? '' : ', limit ' + money(endorsement.Limit_Amount__c)) +
                    since(endorsement.Effective_Date__c) +
                    status(endorsement.Status__c) +
                    (String.isBlank(endorsement.Description__c) ? '' : '. ' + endorsement.Description__c)
            );
            entry.limitAmount = endorsement.Limit_Amount__c;
            // An endorsement carries no deductible of its own in this model, so the policy's applies.
            entry.deductible = policy.Deductible__c == null ? 0 : policy.Deductible__c;
            facts.sources.add(entry);
        }
        index = 0;
        for (Policy_Participant__c participant : participants) {
            index++;
            facts.sources.add(
                source(
                    'P' + index,
                    'Participant',
                    participant.Name,
                    participant.Id,
                    participant.Name +
                        ': role ' +
                        blankAs(participant.Role__c, 'not recorded') +
                        (String.isBlank(participant.Relationship_to_Insured__c) ? '' : ', ' + participant.Relationship_to_Insured__c) +
                        since(participant.Effective_Date__c) +
                        (participant.Expiration_Date__c == null ? '' : ', until ' + day(participant.Expiration_Date__c)) +
                        status(participant.Status__c) +
                        (String.isBlank(participant.Primary_Vehicle__c) ? '' : ', mainly drives ' + participant.Primary_Vehicle__c)
                )
            );
        }
        index = 0;
        for (Policy_Asset__c asset : assets) {
            index++;
            facts.sources.add(
                source(
                    'A' + index,
                    'Insured item',
                    asset.Name,
                    asset.Id,
                    blankAs(asset.Asset_Type__c, 'Item') +
                        ': ' +
                        asset.Name +
                        (String.isBlank(asset.Identifier__c) ? '' : ', ' + asset.Identifier__c) +
                        (String.isBlank(asset.Location__c) ? '' : ', at ' + asset.Location__c) +
                        (String.isBlank(asset.Use__c) ? '' : ', use ' + asset.Use__c) +
                        (asset.Insured_Value__c == null ? '' : ', insured for ' + money(asset.Insured_Value__c))
                )
            );
        }
        index = 0;
        for (File_Note__c note : notes) {
            index++;
            Datetime written = note.Note_Date__c == null ? note.CreatedDate : note.Note_Date__c;
            String heading = (written == null ? '' : written.format('MMM d, yyyy') + ', ') + blankAs(AntsuranceSalesforceNotes.typeLabel(note), 'Note') + (String.isBlank(note.Author_Name__c) ? '' : ', ' + note.Author_Name__c);
            // A note written in Salesforce Notes is a note like any other here. It has no file note behind it, so a finding links to the note itself.
            AntsuranceSalesforceNotes.Entry own = AntsuranceSalesforceNotes.entryOf(note);
            Source entry = source(
                'N' + index,
                'File note',
                blankAs(note.Note_Type__c, 'File') + ' note' + (written == null ? '' : ', ' + written.format('MMM d')),
                own == null ? note.Id : own.documentId,
                '(' + heading + ') ' + note.Body__c?.abbreviate(MAX_NOTE_CHARS)
            );
            entry.madeAt = note.CreatedDate == null ? written : note.CreatedDate;
            facts.sources.add(entry);
        }

        Decimal terms = 0;
        for (Policy_Coverage__c coverage : coverages) {
            terms += (coverage.Limit_Amount__c == null ? 0 : coverage.Limit_Amount__c) + (coverage.Deductible_Amount__c == null ? 0 : coverage.Deductible_Amount__c);
        }
        facts.snapshot = new Map<String, Object>{
            // Moving an open claim along does not bear on coverage; closing, denying or reopening it does.
            'closedAs' => claim.IsClosed == true ? claim.Status : 'open',
            'lossType' => claim.Loss_Type__c,
            'dateOfLoss' => String.valueOf(claim.Date_of_Loss__c),
            'estimate' => claim.Estimated_Loss__c,
            'description' => claim.Description == null ? 0 : claim.Description.hashCode(),
            'policy' => policy.Id,
            'policyStatus' => policy.Status__c,
            'policyTerm' => String.valueOf(policy.Effective_Date__c) + ' ' + String.valueOf(policy.Expiration_Date__c),
            'coverages' => coverages.size(),
            'coverageTerms' => terms,
            'endorsements' => endorsements.size(),
            'participants' => participants.size(),
            'assets' => assets.size(),
            'notes' => notes.size(),
            AntsuranceSalesforceNotes.COUNT_KEY => AntsuranceSalesforceNotes.countIn(notes),
            'documents' => facts.documents.size()
        };
        return facts;
    }

    /** The facts written out for Claude, each record under its key. */
    @TestVisible
    private static String describe(Facts facts) {
        List<String> lines = new List<String>{ 'Today is ' + Datetime.now().format('EEEE, MMM d, yyyy') + '.', '', 'THE CLAIM' };
        lines.addAll(facts.claimLines);
        lines.add('');
        lines.add('THE POLICY');
        lines.addAll(facts.policyLines);
        Map<String, String> headings = new Map<String, String>{
            'C' => 'COVERAGES ON THE POLICY',
            'E' => 'ENDORSEMENTS AND EXCLUSIONS',
            'P' => 'WHO IS ON THE POLICY',
            'A' => 'WHAT THE POLICY INSURES',
            'N' => 'FILE NOTES, newest first'
        };
        for (String prefix : new List<String>{ 'C', 'E', 'P', 'A', 'N' }) {
            lines.add('');
            lines.add(headings.get(prefix));
            Boolean found = false;
            for (Source entry : facts.sources) {
                // C1, E2, P1: a letter and a number. CLAIM, POLICY and EXTRA are written out on their own.
                if (entry.text != null && entry.key.startsWith(prefix) && entry.key.substring(1).isNumeric()) {
                    lines.add('[' + entry.key + '] ' + entry.text);
                    found = true;
                }
            }
            if (!found) {
                lines.add('none recorded');
            }
        }
        lines.add('');
        lines.add('ATTACHED DOCUMENTS (names only): ' + (facts.documents.isEmpty() ? 'none' : String.join(facts.documents, '; ')));
        if (String.isNotBlank(facts.extraFacts)) {
            lines.add('');
            lines.add('ADDITIONAL FACTS FROM THE EVIDENCE (from an analysis of the claim\'s photos or documents, not from the policy record)');
            lines.add('[' + EXTRA_KEY + '] ' + facts.extraFacts);
        }
        return String.join(lines, '\n');
    }

    /** The answer schema. The keys Claude may cite are the records it was given and nothing else. */
    @TestVisible
    private static AntsuranceAiClient.Shape schema(Facts facts) {
        List<String> keys = new List<String>();
        List<String> responders = new List<String>();
        for (Source entry : facts.sources) {
            keys.add(entry.key);
            if (entry.kind == 'Coverage' || entry.kind == 'Endorsement') {
                responders.add(entry.key);
            }
        }
        responders.add(NONE);
        AntsuranceAiClient.Shape finding = new AntsuranceAiClient.Shape()
            .field('text', AntsuranceAiClient.text('One sentence of at most 30 words: what the record shows and what it means for coverage.'))
            .field('source', AntsuranceAiClient.choice(keys, 'The key of the one record this finding rests on.'));
        // The findings come first so the verdict is reached from them, not the other way round.
        return new AntsuranceAiClient.Shape()
            .field('findings', AntsuranceAiClient.listOf(finding.toJson(), 'Three to six findings, most decisive first.'))
            .field('responding', AntsuranceAiClient.choice(responders, 'The key of the coverage or endorsement that would pay for this loss, or NONE.'))
            .field('verdict', AntsuranceAiClient.choice(VERDICTS, 'Needs review whenever the record is silent or mixed on something that decides it.'))
            .field('liability_open', AntsuranceAiClient.flag('True only when a liability coverage responds and the file does not establish that the insured is legally responsible.'))
            .field('summary', AntsuranceAiClient.text('One sentence of at most 25 words: the answer and its main reason.'))
            .field('questions', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A question for the insured, at most 20 words.'), 'Zero to three open questions that bear on coverage.'))
            .field('would_change', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One short sentence.'), 'Zero to three facts that would change the verdict.'));
    }

    /** Turns Claude's answer into the check, reading the figures from the record it chose. */
    @TestVisible
    private static Check toCheck(Map<String, Object> answer, Facts facts) {
        Map<String, Source> byKey = new Map<String, Source>();
        for (Source entry : facts.sources) {
            byKey.put(entry.key, entry);
        }
        Check check = new Check();
        check.exists = true;
        String verdict = (String) answer.get('verdict');
        check.verdict = VERDICTS.contains(verdict) ? verdict : NEEDS_REVIEW;
        check.summary = (String) answer.get('summary');
        check.estimate = facts.estimate;
        check.questions = AntsuranceAiClient.toStrings(answer.get('questions'));
        check.wouldChange = AntsuranceAiClient.toStrings(answer.get('would_change'));

        if (answer.get('findings') instanceof List<Object>) {
            for (Object item : (List<Object>) answer.get('findings')) {
                Map<String, Object> values = (Map<String, Object>) item;
                if (String.isBlank((String) values.get('text'))) {
                    continue;
                }
                Finding finding = new Finding();
                finding.text = (String) values.get('text');
                // A key that was never given cannot be linked. The schema rules it out; this is the backstop.
                Source cited = byKey.get((String) values.get('source'));
                if (cited != null) {
                    finding.recordId = cited.recordId;
                    finding.sourceLabel = cited.label;
                    finding.sourceKind = cited.kind;
                }
                check.findings.add(finding);
            }
        }

        Source responding = byKey.get((String) answer.get('responding'));
        if (responding != null && (responding.kind == 'Coverage' || responding.kind == 'Endorsement') && check.verdict != NOT_COVERED) {
            check.respondingLabel = responding.label;
            check.respondingKind = responding.kind;
            check.respondingId = responding.recordId;
            check.limitAmount = responding.limitAmount;
            check.limitBasis = responding.limitBasis;
            check.deductible = responding.deductible;
        }
        check.liabilityOpen = answer.get('liability_open') == true && check.respondingLabel != null;
        check.payable = payableOn(check.estimate, check.limitAmount, check.deductible, check.verdict, check.respondingLabel != null);
        check.cappedByLimit =
            check.payable != null &&
            check.limitAmount != null &&
            check.estimate != null &&
            check.verdict != NOT_COVERED &&
            check.estimate - (check.deductible == null ? 0 : check.deductible) > check.limitAmount;
        return check;
    }

    /**
     * What the limit and deductible leave payable against the estimate: the estimate less the
     * deductible, and no more than the limit. Nothing when the loss is not covered, and unknown
     * when there is no estimate or no coverage to take the terms from.
     */
    @TestVisible
    private static Decimal payableOn(Decimal estimate, Decimal limitAmount, Decimal deductible, String verdict, Boolean hasCoverage) {
        if (verdict == NOT_COVERED) {
            return 0;
        }
        if (estimate == null || !hasCoverage) {
            return null;
        }
        Decimal net = Math.max(0, estimate - (deductible == null ? 0 : deductible));
        return limitAmount == null ? net : Math.min(net, limitAmount);
    }

    private static Case loadClaim(Id caseId) {
        List<Case> claims = [
            SELECT
                Id,
                CaseNumber,
                Subject,
                Description,
                Status,
                IsClosed,
                RecordType.DeveloperName,
                Loss_Type__c,
                Date_of_Loss__c,
                Reported_Date__c,
                Loss_Location__c,
                Estimated_Loss__c,
                Reserve_Amount__c,
                Policy__c,
                Coverage_Read__c,
                Coverage_Read_At__c,
                Coverage_Confirmed_By__c,
                Coverage_Confirmed_At__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        if (claims.isEmpty() || claims[0].RecordType?.DeveloperName != 'Claim') {
            throw new CoverageException(NOT_A_CLAIM);
        }
        return claims[0];
    }

    private static Facts loadFacts(Case claim, String extraFacts) {
        Id policyId = claim.Policy__c;
        Id caseId = claim.Id;
        Policy__c policy = [
            SELECT Id, Name, Line_of_Business__c, Status__c, Payment_Status__c, Effective_Date__c, Expiration_Date__c, Insured_Item__c, Coverage_Limit__c, Deductible__c
            FROM Policy__c
            WHERE Id = :policyId
            WITH USER_MODE
            LIMIT 1
        ];
        List<String> documents = new List<String>();
        Set<Id> ownLetters = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.LatestPublishedVersion.Description
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
            WITH USER_MODE
            ORDER BY ContentDocument.Title
            LIMIT :MAX_FILES_READ
        ]) {
            // The PDF of an approved letter is what the carrier sent, not evidence that came in. It is
            // not counted, so approving a letter does not make the check it was written from out of date.
            String description = link.ContentDocument?.LatestPublishedVersion?.Description;
            if (String.isNotBlank(description) && description.startsWith(AntsuranceClaimLetters.FILE_MARK)) {
                ownLetters.add(link.ContentDocumentId);
            } else if (documents.size() < MAX_FILES) {
                documents.add(link.ContentDocument.Title + (String.isBlank(link.ContentDocument.FileExtension) ? '' : '.' + link.ContentDocument.FileExtension));
            }
        }
        Facts facts = withExtra(
            factsFrom(
            claim,
            policy,
            [
                SELECT Id, Name, Category__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, What_Is_Covered__c, Status__c, Effective_Date__c
                FROM Policy_Coverage__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ],
            [
                SELECT Id, Name, Type__c, Form_Number__c, Description__c, Limit_Amount__c, Status__c, Effective_Date__c
                FROM Policy_Endorsement__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ],
            [
                SELECT Id, Name, Role__c, Relationship_to_Insured__c, Status__c, Effective_Date__c, Expiration_Date__c, Primary_Vehicle__c
                FROM Policy_Participant__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ],
            [
                SELECT Id, Name, Asset_Type__c, Identifier__c, Location__c, Use__c, Insured_Value__c
                FROM Policy_Asset__c
                WHERE Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Name
                LIMIT 30
            ],
            evidenceNotes(
                [
                    SELECT Id, Note_Type__c, Note_Date__c, Author_Name__c, Body__c, CreatedDate
                    FROM File_Note__c
                    WHERE Case__c = :caseId
                    WITH USER_MODE
                    ORDER BY Note_Date__c DESC NULLS LAST, CreatedDate DESC
                    LIMIT :MAX_NOTES_READ
                ],
                caseId
            ),
            documents
            ),
            extraFacts
        );
        facts.ownLetters = ownLetters;
        return facts;
    }

    /**
     * The notes that are evidence, newest first, up to the number the check reads: the claim's file
     * notes and, by date among them, the notes written on it in Salesforce Notes, which are notes
     * and never documents. A note saved from Claude's own claim analysis is not evidence, and
     * neither is the note an approved letter leaves behind: the letter was written from the check,
     * so it cannot make the check out of date.
     */
    private static List<File_Note__c> evidenceNotes(List<File_Note__c> fileNotes, Id caseId) {
        List<File_Note__c> kept = new List<File_Note__c>();
        for (File_Note__c note : AntsuranceClaimRules.withoutClaudeNotes(AntsuranceSalesforceNotes.withFileNotes(fileNotes, caseId, MAX_NOTES_READ))) {
            if (kept.size() < MAX_NOTES && !AntsuranceClaimLetters.isLetterNote(note)) {
                kept.add(note);
            }
        }
        return kept;
    }

    /** The stored check, with whether it is still current and who has confirmed it. */
    private static Check stored(Case claim, Facts factsNow) {
        Check check;
        Map<String, Object> before;
        try {
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(claim.Coverage_Read__c);
            check = (Check) JSON.deserialize(JSON.serialize(data.get('check')), Check.class);
            before = (Map<String, Object>) data.get('facts');
            if (check != null) {
                check.byAgent = data.get(AGENT_PART) instanceof Map<String, Object>;
            }
        } catch (Exception e) {
            check = null;
        }
        if (check == null) {
            // Not written by this card: offer a fresh check rather than show something unreadable.
            return new Check();
        }
        check.exists = true;
        check.writtenAt = claim.Coverage_Read_At__c;
        check.confirmedBy = claim.Coverage_Confirmed_By__c;
        check.confirmedAt = claim.Coverage_Confirmed_At__c;
        check.changes = factsNow == null ? new List<String>{ 'Policy removed from the claim' } : changesSince(before, factsNow.snapshot);
        check.stale = !check.changes.isEmpty();
        return check;
    }

    /** What differs between the facts a check was written from and the claim and policy today. */
    @TestVisible
    private static List<String> changesSince(Map<String, Object> before, Map<String, Object> now) {
        List<String> changes = new List<String>();
        if (before == null) {
            return changes;
        }
        Map<String, String> labels = new Map<String, String>{
            'closedAs' => 'Claim closed, denied or reopened',
            'lossType' => 'Type of loss changed',
            'dateOfLoss' => 'Date of loss changed',
            'estimate' => 'Estimate changed',
            'description' => 'Description edited',
            'policy' => 'Policy changed',
            'policyStatus' => 'Policy status changed',
            'policyTerm' => 'Policy term changed',
            'coverages' => 'Coverages added or removed',
            'coverageTerms' => 'A limit or deductible changed',
            'endorsements' => 'Endorsements added or removed',
            'participants' => 'People on the policy changed',
            'assets' => 'Insured items changed',
            'notes' => 'New file notes',
            'documents' => 'Documents added or removed'
        };
        for (String key : labels.keySet()) {
            // A check written before Salesforce notes were read as notes counted each as a document: that is a new note, not a document gone.
            Object was = key == 'documents' ? AntsuranceSalesforceNotes.documentsThen(before, now, key) : before.get(key);
            // A fact the check was written before we kept cannot be said to have changed.
            if (before.containsKey(key) && !same(was, now.get(key))) {
                changes.add(labels.get(key));
            }
        }
        return changes;
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

    private static Source source(String key, String kind, String label, Id recordId, String text) {
        Source entry = new Source();
        entry.key = key;
        entry.kind = kind;
        entry.label = label;
        entry.recordId = recordId;
        entry.text = text;
        return entry;
    }

    private static String since(Date value) {
        return value == null ? '' : ', on the policy since ' + day(value);
    }

    private static String status(String value) {
        return String.isBlank(value) || value == 'Active' ? '' : ', status ' + value;
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

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
