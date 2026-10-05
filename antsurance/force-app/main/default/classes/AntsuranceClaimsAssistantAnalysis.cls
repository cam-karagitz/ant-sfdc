/**
 * @description The claim analysis: one run over everything submitted as evidence on a claim, ending
 * in a single adjuster's report. It composes the parts that already exist (the photo assessment,
 * the document read, the coverage check) and adds two of its own: reading a video from frames the
 * browser samples, and writing the report.
 *
 * Salesforce allows 120 seconds of callout time in one request, so every method here makes at most
 * one call to Claude. The component drives the run step by step. A step that fails returns its
 * failure instead of throwing, leaves everything already done in place, and can be run again alone.
 *
 * Nothing on the claim changes except the stored analysis until the adjuster confirms an action.
 */
public with sharing class AntsuranceClaimsAssistantAnalysis {
    private static final Integer MAX_FILES = 60;
    private static final Integer MAX_NOTES = 30;
    private static final Integer MAX_FRAMES = 6;
    // Frames arrive as base64 and are held again inside the request body, so they are kept small.
    private static final Integer MAX_FRAME_BYTES = 200000;
    private static final Integer MAX_FRAMES_BYTES = 900000;
    // A video is handed to the page as base64 for it to take frames from, so the file, its base64 copy and the response must fit the heap.
    @TestVisible
    private static final Integer MAX_VIDEO_BYTES = 2500000;
    private static final Integer VIDEO_TOKENS = 700;
    private static final Integer REPORT_TOKENS = 2600;
    private static final Integer MAX_EXTRA_FACTS = 5500;
    private static final Integer MAX_TASK_SUBJECT = 255;
    private static final Integer MAX_TASKS = 8;
    private static final Integer TASK_DUE_IN_DAYS = 2;
    private static final Integer BYTES_PER_KB = 1024;
    private static final String DOWNLOAD_PATH = '/sfc/servlet.shepherd/version/download/';

    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'webp' };
    private static final Set<String> VIDEO_TYPES = new Set<String>{ 'mp4', 'mov', 'm4v', 'webm', 'avi' };
    private static final String KIND_PHOTO = 'photo';
    private static final String KIND_VIDEO = 'video';
    private static final String KIND_DOCUMENT = 'document';
    private static final String KIND_NOTE = 'note';
    private static final String KIND_STATEMENT = 'statement';

    private static final List<String> CONSISTENCY = new List<String>{ 'consistent', 'check', 'unclear' };
    private static final List<String> GAP_KINDS = new List<String>{ 'evidence_needed', 'check' };

    @TestVisible
    private static final String NO_ACCESS = 'This claim or its files could not be read or saved. Check your access to claims.';
    @TestVisible
    private static final String NOT_A_CLAIM = 'Evidence is analyzed on claims only. This is a service request.';
    @TestVisible
    private static final String NOT_ON_CLAIM = 'That file is not attached to this claim.';
    @TestVisible
    private static final String NOT_A_VIDEO = 'That file is not a video.';
    @TestVisible
    private static final String VIDEO_TOO_LARGE = 'That video is larger than 2.5 MB, which is the most this page can take frames from. Trim it, or add stills from it as photos.';
    @TestVisible
    private static final String NO_FRAMES = 'No frames could be taken from that video, so Claude has nothing to look at.';
    @TestVisible
    private static final String FRAMES_TOO_LARGE = 'The frames from that video are too large to send in one request.';
    @TestVisible
    private static final String NO_REPORT = 'There is no analysis on this claim yet. Run it first.';
    @TestVisible
    private static final String NO_RESERVE_FIGURE = 'The analysis did not recommend a reserve, so there is nothing to set.';
    @TestVisible
    private static final String NO_TASKS = 'Choose at least one step to add as a task.';
    @TestVisible
    private static final String ALREADY_TASKS = 'Those steps are already on the task list.';
    private static final String TIMEOUT_MARK = 'two-minute limit';

    private static final String STYLE =
        'Write in plain words, for an experienced adjuster. Write money with a dollar sign and thousands separators, whole dollars unless the cents matter, ' +
        'and dates month first, like Sep 28. Do not use dashes as punctuation: use a comma, a colon or the word to. ' +
        AntsuranceClaimRules.LASTING_WORDS +
        'Every word you write is read by the adjuster: never write notes to yourself or show working that is not asked for. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH;

    private static final String VIDEO_INSTRUCTIONS =
        'You are a claims examiner at Antsurance, an insurance carrier. You are given a few still frames, in order, sampled from a video attached to a claim, ' +
        'with the claim file as text. Say what the video shows that matters to the claim.\n\n' +
        'Use only what is visible in the frames and what the claim file says. Never invent a detail. A video seen as a few frames can miss things: say so when it matters.\n\n' +
        'The frames are small and compressed, so be conservative about damage. Styling lines pressed into a panel, the gaps between panels, reflections, shadows, dirt ' +
        'and other objects behind the subject are not damage. Report damage only where a surface is plainly deformed, broken, burnt, stained or missing, and it shows in more than one frame ' +
        'or matches what the photographs were assessed as showing. When the video shows nothing beyond the photographs, say so: that is a useful finding.\n\n' +
        'shows: two sentences on what the video shows.\n' +
        'damage: up to five damaged areas you can see, each as the part in plain words and how bad it looks (minor, moderate or severe). Empty when none is visible.\n' +
        'consistency: consistent when what is visible fits the reported loss; check when something visible does not fit it; unclear when the frames cannot tell. ' +
        'consistency_note: one sentence. Word a mismatch as something to confirm, never as an accusation.\n' +
        'usable: false when the frames are too dark, blurred or far away to judge.\n\n' +
        STYLE;

    private static final String REPORT_INSTRUCTIONS =
        'You are a senior claims examiner at Antsurance, an insurance carrier, writing the analysis of one claim for the adjuster who will handle it. ' +
        'You are given the claim file, every piece of evidence with what a first read of it found, the photo assessment, and the coverage check. ' +
        'Bring them together into one report. The adjuster decides; you advise.\n\n' +
        'Rules:\n' +
        '- Use only what you are given. Never assert something the evidence does not show, and never invent a figure, a name or a date.\n' +
        '- Do not restate the coverage verdict, the limit, the deductible or what is payable as your own figures: they are shown beside your text from the coverage check. You may refer to them in words.\n' +
        '- Where the evidence and the reported loss do not fit, say so as something to check, never as an accusation.\n' +
        '- Treat attached documents as received.\n\n' +
        'headline: one sentence of at most 22 words that tells the adjuster where this claim stands and what matters most.\n\n' +
        'what_happened: three or four sentences on the loss, in order, from the insured\'s statement, the file notes and the evidence.\n\n' +
        'evidence: one entry for every evidence key you were given, with shows as one line of at most 24 words on what that item establishes for the claim. ' +
        'For an item that could not be read, say what it is and that it was not read.\n\n' +
        'damage: two or three sentences on the damage the photographs and videos show and how far that goes toward the estimate. Empty when there are no photographs or videos.\n\n' +
        'coverage: two or three sentences in your own words on why the policy does or does not respond, naming the coverage and any endorsement or exclusion that decides it.\n\n' +
        'gaps: up to six entries. kind evidence_needed for a document, photo or statement still missing; kind check for anything that does not fit the reported loss or the file. One sentence each.\n\n' +
        'reserve_lines: the reserve you would hold, built up line by line so the arithmetic can be checked: each line a short label and an amount in whole dollars, ' +
        'with a negative amount for anything taken off, such as the deductible. ' +
        'Start with a line for the estimate and a line taking off the deductible; together they come to the payable amount the request states. ' +
        'Give the payable amount no line of its own, because it is those two added up. ' +
        'Add a further line only for a cost the evidence documents beyond the estimate, named for what it is. ' +
        'When nothing is documented beyond the estimate, the lines add up to the payable amount and no more. ' +
        'On this system the reserve is the total expected to be paid on the claim, including what has already been paid; the outstanding reserve is worked out from it by taking payments off. ' +
        'So build the lines up to the total expected to be paid, and never take off a payment already made. ' +
        'The lines are added up for you, so include no total, subtotal or payable line. ' +
        'An earlier reserve breakdown in the notes is not the estimate: do not rebuild the reserve from its lines, and do not add the amount by which a document exceeds one of its lines. ' +
        'The only addition is one line for the amount by which the documented cost of the whole loss is above the estimate, when it is. ' +
        'Leave the list empty when the evidence does not support a figure, or when the claim is closed or denied.\n' +
        'reserve_reason: one or two sentences on why that figure, and how it compares with the reserve now. ' +
        'When your figure equals the reserve now, say the reserve covers the claim and why.\n\n' +
        AntsuranceClaimRules.RESERVE_RULE +
        '\n\n' +
        'steps: three to six things for the adjuster to do next, in the order to do them. subject is a task subject that starts with a verb and is at most twelve words; ' +
        'why is one sentence. Do not repeat a step an open task in the file already covers.\n\n' +
        STYLE;

    /** One piece of evidence, as the docket shows it. */
    public class Item {
        /** E1, E2 and so on: how the report refers to it. */
        @AuraEnabled
        public String key;
        /** photo, video, document, note or statement. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public Id versionId;
        /** The file note, for a note. */
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String title;
        /** JPEG photo, PDF document, MP4 video, Coverage note. */
        @AuraEnabled
        public String kindLabel;
        @AuraEnabled
        public String sizeLabel;
        @AuraEnabled
        public Datetime addedAt;
        /** Where the browser can load a photo or a video from. */
        @AuraEnabled
        public String url;
        /** Whether Claude has looked at this item as it now stands. */
        @AuraEnabled
        public Boolean looked = false;
        /** What Claude found, in one line. */
        @AuraEnabled
        public String lookedLine;
        /** False when Claude cannot read this file here; whyNot says why. */
        @AuraEnabled
        public Boolean readable = true;
        @AuraEnabled
        public String whyNot;
        /** How many frames a video was read from. */
        @AuraEnabled
        public Integer frames;
        /** Who wrote a file note. */
        @AuraEnabled
        public String author;
    }

    /** What Claude made of one document or video. Kept with the analysis so a later run does not pay for it again. */
    public class Reading {
        public Id documentId;
        public Id versionId;
        public String kind;
        public String title;
        public String documentType;
        public String issuer;
        public String summary;
        public Decimal totalAmount;
        public String comparison;
        public List<String> concerns = new List<String>();
        public String matchesClaim;
        public String consistency;
        public Integer frames;
        public Datetime readAt;
    }

    /** One line of the report's evidence table. */
    public class EvidenceLine {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String kindLabel;
        @AuraEnabled
        public String shows;
        @AuraEnabled
        public Boolean readable = true;
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public Id recordId;
    }

    /** One damaged area, taken from the photo assessment when the report was written. */
    public class DamageLine {
        @AuraEnabled
        public String area;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public Integer photoNumber;
    }

    /** One line of the reserve build-up. */
    public class ReserveLine {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Decimal amount;
    }

    /** Something still missing, or something that does not fit. */
    public class Gap {
        /** evidence_needed or check. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String text;
    }

    /** One thing for the adjuster to do next. */
    public class NextStep {
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String why;
    }

    /** The adjuster's report. This class, inside Stored, is what Case.Claude_Analysis__c holds. */
    public class Report {
        @AuraEnabled
        public Datetime writtenAt;
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public String whatHappened;
        @AuraEnabled
        public List<EvidenceLine> evidence = new List<EvidenceLine>();
        @AuraEnabled
        public String damage;
        @AuraEnabled
        public List<DamageLine> damageAreas = new List<DamageLine>();
        /** consistent, check or unclear, from the photo assessment. Null when no photos were assessed. */
        @AuraEnabled
        public String consistency;
        @AuraEnabled
        public String consistencyNote;
        @AuraEnabled
        public List<String> signals = new List<String>();
        @AuraEnabled
        public Decimal repairLow;
        @AuraEnabled
        public Decimal repairHigh;
        @AuraEnabled
        public String repairBasis;
        /** The photographs the damage section shows, as file Ids. */
        @AuraEnabled
        public List<Id> photoIds = new List<Id>();
        @AuraEnabled
        public String coverage;
        /** The coverage check as it stood when the report was written. */
        @AuraEnabled
        public AntsuranceClaimsAssistantCoverage.Check check;
        @AuraEnabled
        public List<Gap> gaps = new List<Gap>();
        @AuraEnabled
        public Decimal reserveNow;
        @AuraEnabled
        public Decimal paid;
        @AuraEnabled
        public Decimal estimate;
        /** The reserve lines added up. Null when Claude recommended none. */
        @AuraEnabled
        public Decimal reserveRecommended;
        @AuraEnabled
        public List<ReserveLine> reserveLines = new List<ReserveLine>();
        @AuraEnabled
        public String reserveReason;
        @AuraEnabled
        public List<NextStep> steps = new List<NextStep>();
        /** Worked out on every read: whether the claim or its evidence has changed since. */
        @AuraEnabled
        public Boolean stale = false;
        @AuraEnabled
        public List<String> changes = new List<String>();
    }

    /** What Case.Claude_Analysis__c holds, as JSON. */
    public class Stored {
        public Report report;
        public List<Reading> readings = new List<Reading>();
        /** What the report depended on, to tell later whether anything has changed. Text, because typed JSON cannot hold a map of anything. */
        public Map<String, String> snapshot = new Map<String, String>();
    }

    /** Everything the Analysis tab shows when it opens. */
    public class Docket {
        @AuraEnabled
        public String caseNumber;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String customerName;
        @AuraEnabled
        public Id customerId;
        @AuraEnabled
        public String policyName;
        @AuraEnabled
        public Id policyId;
        @AuraEnabled
        public String lossType;
        @AuraEnabled
        public Date dateOfLoss;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String handledBy;
        @AuraEnabled
        public List<Item> items = new List<Item>();
        /** The photographs Claude can look at, in the groups that each fit one call. */
        @AuraEnabled
        public List<List<Id>> photoBatches = new List<List<Id>>();
        /** True when a finished photo assessment covers every photograph now on the claim. */
        @AuraEnabled
        public Boolean photosFresh = false;
        @AuraEnabled
        public String photosLine;
        /** The subjects of the claim's open tasks, in lower case, so a next step that is already a task can say so. */
        @AuraEnabled
        public List<String> openTasks = new List<String>();
        @AuraEnabled
        public Report report;
    }

    /** How one step of the run went. A failure is returned, not thrown, so the page can show it in place. */
    public class StepResult {
        @AuraEnabled
        public Boolean ok = true;
        /** What the step found, in one line. */
        @AuraEnabled
        public String line;
        /** True when an earlier result was still good and Claude was not asked again. */
        @AuraEnabled
        public Boolean reused = false;
        @AuraEnabled
        public String error;
        /** timeout or other. */
        @AuraEnabled
        public String errorKind;
        @AuraEnabled
        public Boolean retryable = false;
        @AuraEnabled
        public Report report;
    }

    /** The claim and its evidence, loaded once for a request. */
    private class Loaded {
        Case claim;
        List<ContentDocumentLink> files = new List<ContentDocumentLink>();
        List<File_Note__c> notes = new List<File_Note__c>();
        Stored stored = new Stored();
        AntsuranceClaimsAssistantPhotos.Assessment photos;
    }

    // ------------------------------------------------------------------ the docket

    /**
     * @description The claim's evidence docket, with what Claude has already looked at and the stored report.
     * @param caseId The claim on screen
     * @return The docket
     * @throws AuraHandledException when the record is not a claim or cannot be read
     */
    @AuraEnabled
    public static Docket getDocket(Id caseId) {
        Loaded loaded = load(caseId);
        Case claim = loaded.claim;
        Docket docket = new Docket();
        docket.caseNumber = claim.CaseNumber;
        docket.subject = claim.Subject;
        docket.customerName = claim.Account?.Name;
        docket.customerId = claim.AccountId;
        docket.policyName = claim.Policy__r?.Name;
        docket.policyId = claim.Policy__c;
        docket.lossType = claim.Loss_Type__c;
        docket.dateOfLoss = claim.Date_of_Loss__c;
        docket.status = claim.Status;
        docket.handledBy = claim.Handled_By__c;
        docket.items = items(loaded);

        try {
            AntsuranceClaimsAssistantPhotos.View view = AntsuranceClaimsAssistantPhotos.getPhotos(caseId);
            docket.photoBatches = view.batches;
            Integer assessable = 0;
            for (List<Id> batch : view.batches) {
                assessable += batch.size();
            }
            docket.photosFresh = view.assessment != null && view.assessment.complete != false && view.addedSince == 0 && assessable > 0 && view.assessment.photos.size() >= assessable;
            docket.photosLine = view.assessment == null ? null : firstSentence(view.assessment.damageSummary);
        } catch (AuraHandledException e) {
            // The photo list is the same files this class has already read, so this is not expected; the run will say so if it matters.
            docket.photosFresh = false;
        }

        docket.report = loaded.stored.report;
        if (docket.report != null) {
            markChanges(docket.report, loaded);
            docket.openTasks = new List<String>(openTaskSubjects(caseId));
        }
        return docket;
    }

    /** The subjects of the claim's open tasks, in lower case. */
    private static Set<String> openTaskSubjects(Id caseId) {
        Set<String> subjects = new Set<String>();
        for (Task item : [SELECT Subject FROM Task WHERE WhatId = :caseId AND IsClosed = FALSE WITH USER_MODE LIMIT 200]) {
            if (item.Subject != null) {
                subjects.add(item.Subject.toLowerCase());
            }
        }
        return subjects;
    }

    // ------------------------------------------------------------------ the steps of a run

    /**
     * @description Step: has Claude read one document on the claim, unless it has already read this version of it.
     * @param caseId The claim on screen
     * @param documentId The file to read
     * @param again True to read it even when a reading of this version is stored
     * @return How the step went, with what the document is in one line
     */
    @AuraEnabled
    public static StepResult readDocumentStep(Id caseId, Id documentId, Boolean again) {
        StepResult result = new StepResult();
        Loaded loaded = load(caseId);
        ContentDocumentLink file = fileOn(loaded, documentId);
        if (file == null) {
            return failed(NOT_ON_CLAIM, false);
        }
        Reading existing = readingOf(loaded.stored, documentId);
        if (again != true && existing != null && existing.versionId == file.ContentDocument.LatestPublishedVersionId) {
            result.reused = true;
            result.line = documentLine(existing);
            return result;
        }
        AntsuranceClaimsAssistantDocuments.Reading read;
        try {
            read = AntsuranceClaimsAssistantDocuments.readDocument(caseId, documentId);
        } catch (AuraHandledException e) {
            return failed(e.getMessage(), isTimeout(e.getMessage()));
        }
        Reading reading = new Reading();
        reading.documentId = documentId;
        reading.versionId = file.ContentDocument.LatestPublishedVersionId;
        reading.kind = KIND_DOCUMENT;
        reading.title = file.ContentDocument.Title;
        reading.documentType = read.documentType;
        reading.issuer = read.issuer;
        reading.summary = read.summary;
        reading.totalAmount = read.totalAmount;
        reading.comparison = read.comparison;
        reading.concerns = read.concerns;
        reading.matchesClaim = read.matchesClaim;
        reading.readAt = Datetime.now();
        keep(caseId, loaded.stored, reading);
        result.line = documentLine(reading);
        return result;
    }

    /**
     * @description A video's contents, for the page to play out of sight and take still frames from.
     * The file is served from another domain, where a page cannot read frames back, so it comes through here.
     * @param caseId The claim on screen
     * @param documentId The video file
     * @return The file, base64 encoded
     * @throws AuraHandledException when the file is not a video on this claim or is too large
     */
    @AuraEnabled
    public static String videoData(Id caseId, Id documentId) {
        Loaded loaded = load(caseId);
        ContentDocumentLink file = fileOn(loaded, documentId);
        if (file == null) {
            throw handled(NOT_ON_CLAIM);
        }
        if (!VIDEO_TYPES.contains(extensionOf(file))) {
            throw handled(NOT_A_VIDEO);
        }
        if (file.ContentDocument.ContentSize > MAX_VIDEO_BYTES) {
            throw handled(VIDEO_TOO_LARGE);
        }
        try {
            Id versionId = file.ContentDocument.LatestPublishedVersionId;
            return EncodingUtil.base64Encode([SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1].VersionData);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
    }

    /**
     * @description Step: has Claude read a video from still frames the browser sampled from it.
     * The API takes images, not video, so the page draws a few frames and sends those.
     * @param caseId The claim on screen
     * @param documentId The video file
     * @param frames JPEG frames in order, base64 encoded, six at most
     * @return How the step went, with what the video shows in one line
     */
    @AuraEnabled
    public static StepResult readVideoStep(Id caseId, Id documentId, List<String> frames) {
        // Always asks Claude: the page decides whether a stored reading of this version can be used instead.
        Loaded loaded = load(caseId);
        ContentDocumentLink file = fileOn(loaded, documentId);
        if (file == null) {
            return failed(NOT_ON_CLAIM, false);
        }
        if (!VIDEO_TYPES.contains(extensionOf(file))) {
            return failed(NOT_A_VIDEO, false);
        }
        List<Blob> stills = new List<Blob>();
        Integer total = 0;
        for (String frame : frames == null ? new List<String>() : frames) {
            if (String.isBlank(frame) || stills.size() == MAX_FRAMES) {
                continue;
            }
            Blob still = EncodingUtil.base64Decode(frame.substringAfter('base64,') == '' ? frame : frame.substringAfter('base64,'));
            if (still.size() > MAX_FRAME_BYTES) {
                continue;
            }
            total += still.size();
            stills.add(still);
        }
        if (stills.isEmpty()) {
            return failed(NO_FRAMES, false);
        }
        if (total > MAX_FRAMES_BYTES) {
            return failed(FRAMES_TOO_LARGE, false);
        }

        String seen = '';
        if (loaded.photos != null && loaded.photos.complete != false && String.isNotBlank(loaded.photos.damageSummary)) {
            seen = '\n\nThe photographs on the claim were assessed as showing: ' + clean(loaded.photos.damageSummary);
        }
        String prompt =
            claimText(caseId) +
            seen +
            '\n\nThe video is titled "' +
            file.ContentDocument.Title +
            '". The ' +
            stills.size() +
            ' attached images are frames taken from it at even intervals, first to last.';
        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(VIDEO_INSTRUCTIONS, prompt).returning(videoSchema());
            for (Blob still : stills) {
                question.attach('image/jpeg', still);
            }
            question.maxTokens = VIDEO_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            StepResult failure = failed(e.getMessage(), e.retryable);
            failure.errorKind = e.kind;
            return failure;
        }

        Reading reading = new Reading();
        reading.documentId = documentId;
        reading.versionId = file.ContentDocument.LatestPublishedVersionId;
        reading.kind = KIND_VIDEO;
        reading.title = file.ContentDocument.Title;
        reading.documentType = 'Video';
        reading.summary = (String) answer.get('shows');
        reading.consistency = (String) answer.get('consistency');
        reading.frames = stills.size();
        reading.readAt = Datetime.now();
        List<String> areas = new List<String>();
        if (answer.get('damage') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('damage')) {
                Map<String, Object> area = (Map<String, Object>) entry;
                if (String.isNotBlank((String) area.get('area'))) {
                    areas.add(area.get('area') + ' (' + area.get('severity') + ')');
                }
            }
        }
        if (!areas.isEmpty()) {
            reading.comparison = 'Damage visible: ' + String.join(areas, ', ') + '.';
        }
        if (answer.get('usable') == false) {
            reading.concerns.add('The frames were too dark, blurred or far away to judge.');
        }
        String note = (String) answer.get('consistency_note');
        if (String.isNotBlank(note) && reading.consistency != 'consistent') {
            reading.concerns.add(note);
        }
        keep(caseId, loaded.stored, reading);

        StepResult result = new StepResult();
        result.line = 'Read from ' + stills.size() + (stills.size() == 1 ? ' frame: ' : ' frames: ') + firstSentence(reading.summary);
        return result;
    }

    /**
     * @description Step: checks coverage with what the photographs, videos and documents showed
     * passed in as facts. A stored check that still stands is used as it is: one from a single call
     * while it is current and was reasoned against the same facts, and the coverage agent's while it
     * is current and the photographs have not been assessed again since (the agent reads the
     * documents itself, so its evidence never matches this text word for word). Replacing a check
     * clears the adjuster's confirmation of it, and the step's line says so when that happens.
     * @param caseId The claim on screen
     * @param again True to ask Claude even when a stored check still stands
     * @return How the step went, with the verdict in one line
     */
    @AuraEnabled
    public static StepResult checkCoverageStep(Id caseId, Boolean again) {
        Loaded loaded = load(caseId);
        String extra = evidenceFacts(loaded);
        AntsuranceClaimsAssistantCoverage.Check check;
        StepResult result = new StepResult();
        String replaced = '';
        try {
            AntsuranceClaimsAssistantCoverage.Check existing = AntsuranceClaimsAssistantCoverage.read(caseId);
            if (again != true && AntsuranceClaimsAssistantCoverage.stands(existing, extra, photosAssessedAt(loaded))) {
                check = existing;
                result.reused = true;
            } else {
                check = AntsuranceClaimsAssistantCoverage.run(caseId, extra);
                if (existing.exists && existing.confirmedAt != null) {
                    replaced = ' This replaces the check ' + (String.isBlank(existing.confirmedBy) ? 'an adjuster' : existing.confirmedBy) + ' confirmed, so it needs confirming again.';
                }
            }
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            return failed(e.getMessage(), isTimeout(e.getMessage()));
        }
        result.line = coverageLine(check) + replaced;
        return result;
    }

    /** When the photo assessment that evidenceFacts passes on was made. Null when there is none to pass on. */
    private static Datetime photosAssessedAt(Loaded loaded) {
        AntsuranceClaimsAssistantPhotos.Assessment photos = loaded.photos;
        if (photos == null || photos.complete == false) {
            return null;
        }
        return photos.assessedAt ?? loaded.claim.Photo_Assessment_At__c;
    }

    /**
     * @description Step: writes the report from everything the earlier steps found, and stores it on the claim.
     * @param caseId The claim on screen
     * @return How the step went, with the report
     */
    @AuraEnabled
    public static StepResult writeReportStep(Id caseId) {
        Loaded loaded = load(caseId);
        AntsuranceClaimsAssistantCoverage.Check check;
        try {
            check = AntsuranceClaimsAssistantCoverage.read(caseId);
        } catch (AntsuranceClaimsAssistantCoverage.CoverageException e) {
            check = new AntsuranceClaimsAssistantCoverage.Check();
        }
        List<Item> docket = items(loaded);

        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(REPORT_INSTRUCTIONS, reportPrompt(caseId, loaded, docket, check)).returning(reportSchema(docket));
            question.maxTokens = REPORT_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            StepResult failure = failed(e.getMessage(), e.retryable);
            failure.errorKind = e.kind;
            return failure;
        }

        Report report = toReport(answer, loaded, docket, check);
        loaded.stored.report = report;
        loaded.stored.snapshot = snapshot(loaded);
        save(caseId, loaded.stored, report.writtenAt);

        StepResult result = new StepResult();
        result.line = report.headline;
        result.report = report;
        return result;
    }

    // ------------------------------------------------------------------ acting on the report, each on a press

    /**
     * @description Adds the chosen next steps as tasks on the claim, for the person who pressed.
     * @param caseId The claim on screen
     * @param subjects The task subjects, as the report worded them
     * @return A short confirmation
     * @throws AuraHandledException when none was chosen or the save fails
     */
    @AuraEnabled
    public static String addTasks(Id caseId, List<String> subjects) {
        Loaded loaded = load(caseId);
        Map<String, String> whys = new Map<String, String>();
        if (loaded.stored.report != null) {
            for (NextStep step : loaded.stored.report.steps) {
                whys.put(step.subject, step.why);
            }
        }
        // A step that is already an open task on the claim is not added a second time.
        Set<String> onList = openTaskSubjects(caseId);
        Integer already = 0;
        List<Task> tasks = new List<Task>();
        for (String subject : subjects == null ? new List<String>() : subjects) {
            if (String.isBlank(subject) || tasks.size() == MAX_TASKS) {
                continue;
            }
            if (onList.contains(subject.trim().left(MAX_TASK_SUBJECT).toLowerCase())) {
                already++;
                continue;
            }
            onList.add(subject.trim().left(MAX_TASK_SUBJECT).toLowerCase());
            tasks.add(
                new Task(
                    WhatId = caseId,
                    WhoId = loaded.claim.ContactId,
                    OwnerId = UserInfo.getUserId(),
                    Subject = subject.trim().left(MAX_TASK_SUBJECT),
                    Description = whys.get(subject),
                    ActivityDate = Date.today().addDays(TASK_DUE_IN_DAYS),
                    Status = 'Not Started',
                    Priority = 'Normal'
                )
            );
        }
        if (tasks.isEmpty()) {
            throw handled(already > 0 ? ALREADY_TASKS : NO_TASKS);
        }
        try {
            insert as user tasks;
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
        return tasks.size() == 1 ? 'Task added.' : tasks.size() + ' tasks added.';
    }

    /**
     * @description Sets the claim's reserve to the figure the report recommended, and records why in a file note.
     * @param caseId The claim on screen
     * @return A short confirmation
     * @throws AuraHandledException when there is no recommendation or the save fails
     */
    @AuraEnabled
    public static String setReserve(Id caseId) {
        Loaded loaded = load(caseId);
        Report report = loaded.stored.report;
        if (report == null) {
            throw handled(NO_REPORT);
        }
        if (report.reserveRecommended == null) {
            throw handled(NO_RESERVE_FIGURE);
        }
        String done = AntsuranceClaimsAssistantDocuments.applySuggestion(caseId, 'set_reserve', report.reserveRecommended, null, report.reserveReason, 'the claim analysis');
        // The change came from the report, so it does not make the report out of date.
        report.reserveNow = report.reserveRecommended;
        loaded.stored.snapshot.put('reserve', amount(report.reserveRecommended));
        loaded.stored.snapshot.put('notes', String.valueOf(loaded.notes.size() + 1));
        save(caseId, loaded.stored, report.writtenAt);
        return done;
    }

    /**
     * @description Adds the report to the claim's file notes, as labeled points.
     * @param caseId The claim on screen
     * @return A short confirmation
     * @throws AuraHandledException when there is no report or the note cannot be saved
     */
    @AuraEnabled
    public static String addToNotes(Id caseId) {
        Loaded loaded = load(caseId);
        Report report = loaded.stored.report;
        if (report == null) {
            throw handled(NO_REPORT);
        }
        Boolean replaced = saveAsNote(loaded.claim, noteFor(report));
        // The note is the report's own work, so it is not counted as evidence and nothing goes out of date.
        save(caseId, loaded.stored, report.writtenAt);
        return replaced ? 'The earlier analysis note was replaced with this one.' : 'Added to the file notes.';
    }

    /**
     * The report as a file note on the claim, attributed to Claude and to the person who chose to keep
     * it, so the file shows whose work it is and the brief and the coverage check do not treat it as
     * something new to read.
     */
    private static Boolean saveAsNote(Case claim, String body) {
        try {
            // One analysis note per claim: a newer report takes the place of the one saved before, so the
            // file never carries two of Claude's conclusions that disagree.
            for (File_Note__c earlier : [SELECT Id, Body__c FROM File_Note__c WHERE Case__c = :claim.Id WITH USER_MODE ORDER BY Note_Date__c DESC LIMIT 100]) {
                if (String.isNotBlank(earlier.Body__c) && earlier.Body__c.trim().startsWith(AntsuranceClaimRules.ANALYSIS_NOTE_OPENING)) {
                    update as user new File_Note__c(Id = earlier.Id, Note_Date__c = Datetime.now(), Author_Name__c = AntsuranceClaimRules.claudeAuthor(), Body__c = body.trim());
                    return true;
                }
            }
            insert as user
                new File_Note__c(
                    Case__c = claim.Id,
                    Policy__c = claim.Policy__c,
                    Account__c = claim.AccountId,
                    Note_Type__c = 'Investigation',
                    Note_Date__c = Datetime.now(),
                    Author_Name__c = AntsuranceClaimRules.claudeAuthor(),
                    Body__c = body.trim()
                );
            return false;
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        } catch (SecurityException e) {
            throw handled(NO_ACCESS);
        }
    }

    // ------------------------------------------------------------------ reading the claim

    private static Loaded load(Id caseId) {
        Loaded loaded = new Loaded();
        try {
            List<Case> claims = [
                SELECT
                    Id,
                    CaseNumber,
                    Subject,
                    Description,
                    Status,
                    IsClosed,
                    RecordType.DeveloperName,
                    AccountId,
                    Account.Name,
                    ContactId,
                    Contact.Name,
                    Policy__c,
                    Policy__r.Name,
                    Handled_By__c,
                    Loss_Type__c,
                    Date_of_Loss__c,
                    Reported_Date__c,
                    Estimated_Loss__c,
                    Reserve_Amount__c,
                    Paid_Amount__c,
                    Claude_Analysis__c,
                    Claude_Analysis_At__c,
                    Coverage_Read_At__c,
                    Photo_Assessment_At__c
                FROM Case
                WHERE Id = :caseId
                WITH USER_MODE
                LIMIT 1
            ];
            if (claims.isEmpty()) {
                throw handled(NO_ACCESS);
            }
            loaded.claim = claims[0];
            if (loaded.claim.RecordType?.DeveloperName != 'Claim') {
                throw handled(NOT_A_CLAIM);
            }
            loaded.files = [
                SELECT
                    ContentDocumentId,
                    ContentDocument.Title,
                    ContentDocument.FileExtension,
                    ContentDocument.ContentSize,
                    ContentDocument.CreatedDate,
                    ContentDocument.LatestPublishedVersionId,
                    ContentDocument.LatestPublishedVersion.Description
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate, ContentDocument.Title
                LIMIT :MAX_FILES
            ];
            // A letter we approved is our own outgoing paper, not evidence about the loss: neither its PDF nor its note is read.
            for (Integer at = loaded.files.size() - 1; at >= 0; at--) {
                String description = loaded.files[at].ContentDocument.LatestPublishedVersion?.Description;
                if (String.isNotBlank(description) && description.startsWith(AntsuranceClaimLetters.FILE_MARK)) {
                    loaded.files.remove(at);
                }
            }
            // A note saved from an earlier analysis is this report's own work, not evidence to read again.
            loaded.notes = AntsuranceClaimRules.withoutClaudeNotes(
                [
                    SELECT Id, Name, Note_Type__c, Note_Date__c, Author_Name__c, Body__c, CreatedDate
                    FROM File_Note__c
                    WHERE Case__c = :caseId
                    WITH USER_MODE
                    ORDER BY Note_Date__c, CreatedDate
                    LIMIT :MAX_NOTES
                ]
            );
            for (Integer at = loaded.notes.size() - 1; at >= 0; at--) {
                if (AntsuranceClaimLetters.isLetterNote(loaded.notes[at])) {
                    loaded.notes.remove(at);
                }
            }
            // A Salesforce note is a file to the platform and a note to a person: it is read with the notes, not listed as a document.
            loaded.notes.addAll(AntsuranceSalesforceNotes.asFileNotes(caseId, MAX_NOTES));
            loaded.photos = AntsuranceClaimsAssistantPhotos.stored(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        if (String.isNotBlank(loaded.claim.Claude_Analysis__c)) {
            try {
                loaded.stored = (Stored) JSON.deserialize(loaded.claim.Claude_Analysis__c, Stored.class);
            } catch (Exception e) {
                // An analysis this code can no longer read is treated as none, so the page offers to run it again.
                loaded.stored = new Stored();
            }
        }
        if (loaded.stored.readings == null) {
            loaded.stored.readings = new List<Reading>();
        }
        if (loaded.stored.snapshot == null) {
            loaded.stored.snapshot = new Map<String, String>();
        }
        return loaded;
    }

    /** The docket: files in the order they were added, then the file notes, then the insured's own statement. */
    private static List<Item> items(Loaded loaded) {
        List<Item> items = new List<Item>();
        Map<Id, AntsuranceClaimsAssistantPhotos.PhotoRead> looks = new Map<Id, AntsuranceClaimsAssistantPhotos.PhotoRead>();
        if (loaded.photos != null) {
            for (AntsuranceClaimsAssistantPhotos.PhotoRead read : loaded.photos.photos) {
                looks.put(read.documentId, read);
            }
        }
        Datetime reportAt = loaded.stored.report?.writtenAt;
        for (ContentDocumentLink file : loaded.files) {
            String extension = extensionOf(file);
            Item item = new Item();
            item.documentId = file.ContentDocumentId;
            item.versionId = file.ContentDocument.LatestPublishedVersionId;
            item.title = file.ContentDocument.Title;
            item.sizeLabel = sizeLabel(file.ContentDocument.ContentSize);
            item.addedAt = file.ContentDocument.CreatedDate;
            String type = String.isBlank(extension) ? 'File' : extension.toUpperCase().replace('JPEG', 'JPG');
            if (IMAGE_TYPES.contains(extension)) {
                item.kind = KIND_PHOTO;
                item.kindLabel = type + ' photo';
                item.url = DOWNLOAD_PATH + item.versionId;
                AntsuranceClaimsAssistantPhotos.PhotoRead look = looks.get(item.documentId);
                item.looked = look != null;
                item.lookedLine = look == null ? null : (look.usable == false ? 'Not usable: ' + look.unusableReason : look.shows);
            } else if (VIDEO_TYPES.contains(extension)) {
                item.kind = KIND_VIDEO;
                item.kindLabel = type + ' video';
                item.url = DOWNLOAD_PATH + item.versionId;
                Reading reading = readingOf(loaded.stored, item.documentId);
                item.looked = reading != null && reading.versionId == item.versionId;
                item.lookedLine = item.looked ? firstSentence(reading.summary) : null;
                item.frames = item.looked ? reading.frames : null;
            } else {
                item.kind = KIND_DOCUMENT;
                item.kindLabel = type + ' document';
                item.readable = extension == 'pdf';
                item.whyNot = item.readable ? null : 'Claude reads PDFs, photos and videos here. Open this file to read it yourself.';
                Reading reading = readingOf(loaded.stored, item.documentId);
                item.looked = reading != null && reading.versionId == item.versionId;
                item.lookedLine = item.looked ? documentLine(reading) : null;
            }
            items.add(item);
        }
        for (File_Note__c note : loaded.notes) {
            Item item = new Item();
            item.kind = KIND_NOTE;
            item.recordId = note.Id;
            item.kindLabel = 'File note';
            item.author = note.Author_Name__c;
            item.addedAt = note.Note_Date__c == null ? note.CreatedDate : note.Note_Date__c;
            // Two notes of one type are told apart by their date: "Investigation note, Sep 25".
            item.title = (String.isBlank(note.Note_Type__c) ? 'File' : note.Note_Type__c) + ' note' + (item.addedAt == null ? '' : ', ' + item.addedAt.format('MMM d'));
            item.lookedLine = firstSentence(plain(note.Body__c));
            // A Salesforce note read in with the file notes was never saved as one, so its own date stands in for when it was made.
            Datetime madeAt = note.CreatedDate ?? note.Note_Date__c;
            item.looked = reportAt != null && madeAt != null && madeAt <= reportAt;
            items.add(item);
        }
        if (String.isNotBlank(loaded.claim.Description)) {
            Item item = new Item();
            item.kind = KIND_STATEMENT;
            item.title = 'The insured\'s statement';
            item.kindLabel = 'As reported';
            item.addedAt = loaded.claim.Reported_Date__c == null ? null : Datetime.newInstance(loaded.claim.Reported_Date__c, Time.newInstance(12, 0, 0, 0));
            item.lookedLine = firstSentence(plain(loaded.claim.Description));
            item.looked = reportAt != null;
            items.add(item);
        }
        Integer position = 1;
        for (Item item : items) {
            item.key = 'E' + position++;
        }
        return items;
    }

    private static ContentDocumentLink fileOn(Loaded loaded, Id documentId) {
        for (ContentDocumentLink file : loaded.files) {
            if (file.ContentDocumentId == documentId) {
                return file;
            }
        }
        return null;
    }

    private static String extensionOf(ContentDocumentLink file) {
        return file.ContentDocument.FileExtension == null ? '' : file.ContentDocument.FileExtension.toLowerCase();
    }

    private static Reading readingOf(Stored stored, Id documentId) {
        for (Reading reading : stored.readings) {
            if (reading.documentId == documentId) {
                return reading;
            }
        }
        return null;
    }

    /** Keeps one reading with the stored analysis, replacing an older reading of the same file. */
    private static void keep(Id caseId, Stored stored, Reading reading) {
        for (Integer i = stored.readings.size() - 1; i >= 0; i--) {
            if (stored.readings[i].documentId == reading.documentId) {
                stored.readings.remove(i);
            }
        }
        stored.readings.add(reading);
        save(caseId, stored, stored.report?.writtenAt);
    }

    private static void save(Id caseId, Stored stored, Datetime writtenAt) {
        // Stale and changes are worked out on every read, so they are not kept.
        if (stored.report != null) {
            stored.report.stale = false;
            stored.report.changes = new List<String>();
        }
        try {
            update as user new Case(Id = caseId, Claude_Analysis__c = JSON.serialize(stored, true), Claude_Analysis_At__c = writtenAt);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    // ------------------------------------------------------------------ what goes to Claude

    private static String claimText(Id caseId) {
        return AntsuranceClaimsAssistantBrief.describeClaim(caseId);
    }

    /** What the photographs, videos and documents showed, as text for the coverage check to reason against. */
    @TestVisible
    private static String evidenceFacts(Loaded loaded) {
        List<String> lines = new List<String>();
        AntsuranceClaimsAssistantPhotos.Assessment photos = loaded.photos;
        if (photos != null && photos.complete != false) {
            lines.add('Photographs (' + photos.photos.size() + '): ' + clean(photos.damageSummary));
            if (String.isNotBlank(photos.lossSeen)) {
                lines.add('The photographs point to: ' + clean(photos.lossSeen));
            }
            if (String.isNotBlank(photos.consistencyNote)) {
                lines.add('Against the reported loss: ' + clean(photos.consistencyNote));
            }
            if (photos.signals != null && !photos.signals.isEmpty()) {
                lines.add('Visible signs: ' + String.join(photos.signals, '; '));
            }
        }
        for (Reading reading : current(loaded)) {
            String line = (reading.kind == KIND_VIDEO ? 'Video' : clean(reading.documentType)) + ' "' + reading.title + '"';
            if (String.isNotBlank(reading.issuer)) {
                line += ' from ' + reading.issuer;
            }
            if (reading.totalAmount != null) {
                line += ', total ' + money(reading.totalAmount);
            }
            line += ': ' + clean(reading.summary);
            if (reading.concerns != null && !reading.concerns.isEmpty()) {
                line += ' Concerns: ' + String.join(reading.concerns, ' ');
            }
            lines.add(line);
        }
        String facts = String.join(lines, '\n');
        return facts.length() > MAX_EXTRA_FACTS ? facts.left(MAX_EXTRA_FACTS) : facts;
    }

    /** The readings of files that are still on the claim at the version that was read. */
    private static List<Reading> current(Loaded loaded) {
        List<Reading> readings = new List<Reading>();
        for (Reading reading : loaded.stored.readings) {
            ContentDocumentLink file = fileOn(loaded, reading.documentId);
            if (file != null && file.ContentDocument.LatestPublishedVersionId == reading.versionId) {
                readings.add(reading);
            }
        }
        return readings;
    }

    private static String reportPrompt(Id caseId, Loaded loaded, List<Item> docket, AntsuranceClaimsAssistantCoverage.Check check) {
        List<String> parts = new List<String>{ claimText(caseId) };

        List<String> evidence = new List<String>{ 'EVIDENCE ON THE CLAIM, each under its key:' };
        for (Item item : docket) {
            String line = '[' + item.key + '] ' + item.kindLabel + ' "' + item.title + '"' + (String.isBlank(item.author) ? '' : ' by ' + item.author);
            if (item.kind == KIND_DOCUMENT || item.kind == KIND_VIDEO) {
                Reading reading = item.looked ? readingOf(loaded.stored, item.documentId) : null;
                if (reading == null) {
                    line += item.readable ? ': not read.' : ': a file type Claude cannot read here, so it was not read.';
                } else {
                    line += ': ' + (reading.kind == KIND_VIDEO ? 'read from ' + reading.frames + ' frames. ' : clean(reading.documentType) + (String.isBlank(reading.issuer) ? '' : ' from ' + reading.issuer) + (reading.totalAmount == null ? '. ' : ', total ' + money(reading.totalAmount) + '. '));
                    line += clean(reading.summary);
                    if (String.isNotBlank(reading.comparison)) {
                        line += ' ' + clean(reading.comparison);
                    }
                    if (reading.concerns != null && !reading.concerns.isEmpty()) {
                        line += ' Concerns: ' + String.join(reading.concerns, ' ');
                    }
                }
            } else if (item.kind == KIND_PHOTO) {
                line += item.looked ? ': ' + clean(item.lookedLine) : ': not assessed.';
            } else {
                line += ': ' + clean(item.lookedLine);
            }
            evidence.add(line);
        }
        parts.add(String.join(evidence, '\n'));

        AntsuranceClaimsAssistantPhotos.Assessment photos = loaded.photos;
        if (photos != null && photos.complete != false) {
            List<String> seen = new List<String>{ 'KIND_PHOTO ASSESSMENT:' };
            seen.add('Summary: ' + clean(photos.damageSummary));
            for (AntsuranceClaimsAssistantPhotos.PhotoRead read : photos.photos) {
                for (AntsuranceClaimsAssistantPhotos.DamageArea area : read.damage) {
                    seen.add('- Photo ' + read.photoNumber + ', ' + area.area + ' (' + area.severity + '): ' + clean(area.detail));
                }
            }
            seen.add('Against the reported loss: ' + photos.consistency + '. ' + clean(photos.consistencyNote));
            if (photos.signals != null && !photos.signals.isEmpty()) {
                seen.add('Visible signs: ' + String.join(photos.signals, '; '));
            }
            if (photos.repairLow != null && photos.repairHigh != null) {
                seen.add('Rough range for the damage visible in the photos only, not an estimate of the claim: ' + money(photos.repairLow) + ' to ' + money(photos.repairHigh) + '. ' + clean(photos.repairBasis));
            }
            if (photos.photosNeeded != null && !photos.photosNeeded.isEmpty()) {
                seen.add('Photographs still needed: ' + String.join(photos.photosNeeded, '; '));
            }
            parts.add(String.join(seen, '\n'));
        }

        List<String> coverage = new List<String>{ 'COVERAGE CHECK:' };
        if (check == null || check.exists != true) {
            coverage.add('Coverage has not been checked on this claim.');
        } else {
            coverage.add('Verdict: ' + check.verdict + '. ' + clean(check.summary));
            if (String.isNotBlank(check.respondingLabel)) {
                coverage.add(
                    'Responds: ' +
                        check.respondingLabel +
                        ' (' +
                        check.respondingKind +
                        '), limit ' +
                        (check.limitAmount == null ? 'not stated' : money(check.limitAmount)) +
                        (String.isBlank(check.limitBasis) ? '' : ' ' + check.limitBasis) +
                        ', deductible ' +
                        money(check.deductible == null ? 0 : check.deductible) +
                        '.'
                );
            }
            coverage.add(
                'Payable on the estimate: ' +
                    (check.payable == null ? 'cannot be worked out' : money(check.payable)) +
                    (check.liabilityOpen == true ? ', if the insured is found legally responsible' : '') +
                    (check.cappedByLimit == true ? ', capped by the limit' : '') +
                    '.'
            );
            for (AntsuranceClaimsAssistantCoverage.Finding finding : check.findings) {
                coverage.add('- ' + clean(finding.text) + ' (' + finding.sourceKind + ': ' + finding.sourceLabel + ')');
            }
            if (!check.questions.isEmpty()) {
                coverage.add('Still to ask the insured: ' + String.join(check.questions, ' '));
            }
            if (!check.wouldChange.isEmpty()) {
                coverage.add('Would change the answer: ' + String.join(check.wouldChange, ' '));
            }
        }
        parts.add(String.join(coverage, '\n'));

        Case claim = loaded.claim;
        Decimal paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
        parts.add(
            'FIGURES ON THE CLAIM NOW: estimate ' +
                money(claim.Estimated_Loss__c) +
                ', reserve (the total expected to be paid, including payments made) ' +
                money(claim.Reserve_Amount__c) +
                ', paid so far ' +
                money(paid) +
                ', outstanding reserve ' +
                money((claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c) - paid) +
                '. Status ' +
                claim.Status +
                (claim.IsClosed ? ' (closed).' : '.')
        );
        parts.add(payableLine(claim, check));
        parts.add('Write the analysis of this claim.');
        return String.join(parts, '\n\n');
    }

    @TestVisible
    private static AntsuranceAiClient.Shape videoSchema() {
        AntsuranceAiClient.Shape area = new AntsuranceAiClient.Shape()
            .field('area', AntsuranceAiClient.text('The damaged part, in plain words.'))
            .field('severity', AntsuranceAiClient.choice(new List<String>{ 'minor', 'moderate', 'severe' }, 'How bad it looks.'));
        return new AntsuranceAiClient.Shape()
            .field('shows', AntsuranceAiClient.text('Two sentences on what the video shows.'))
            .field('damage', AntsuranceAiClient.listOf(area.toJson(), 'Up to five damaged areas visible.'))
            .field('consistency', AntsuranceAiClient.choice(CONSISTENCY, 'Against the reported loss.'))
            .field('consistency_note', AntsuranceAiClient.text('One sentence on how it fits the reported loss.'))
            .field('usable', AntsuranceAiClient.flag('False when the frames are too poor to judge.'));
    }

    @TestVisible
    private static AntsuranceAiClient.Shape reportSchema(List<Item> docket) {
        List<String> keys = new List<String>();
        for (Item item : docket) {
            keys.add(item.key);
        }
        if (keys.isEmpty()) {
            keys.add('NONE');
        }
        AntsuranceAiClient.Shape evidence = new AntsuranceAiClient.Shape()
            .field('key', AntsuranceAiClient.choice(keys, 'The evidence key, exactly as given.'))
            .field('shows', AntsuranceAiClient.text('One line on what this item establishes for the claim.'));
        AntsuranceAiClient.Shape gap = new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(GAP_KINDS, 'Missing evidence, or something that does not fit.'))
            .field('text', AntsuranceAiClient.text('One sentence.'));
        AntsuranceAiClient.Shape reserveLine = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('A short label for this part of the reserve.'))
            .field('amount', AntsuranceAiClient.optionalNumber('Whole dollars; negative for something taken off.'));
        AntsuranceAiClient.Shape step = new AntsuranceAiClient.Shape()
            .field('subject', AntsuranceAiClient.text('A task subject that starts with a verb, at most twelve words.'))
            .field('why', AntsuranceAiClient.text('One sentence on why.'));
        return new AntsuranceAiClient.Shape()
            .field('what_happened', AntsuranceAiClient.text('Three or four sentences on the loss, in order.'))
            .field('evidence', AntsuranceAiClient.listOf(evidence.toJson(), 'One entry for every evidence key.'))
            .field('damage', AntsuranceAiClient.text('Two or three sentences on the damage the photographs and videos show. Empty when there are none.'))
            .field('coverage', AntsuranceAiClient.text('Two or three sentences on why the policy does or does not respond.'))
            .field('gaps', AntsuranceAiClient.listOf(gap.toJson(), 'Up to six gaps or things to check.'))
            .field('reserve_lines', AntsuranceAiClient.listOf(reserveLine.toJson(), 'The reserve built up line by line, without a total. Empty when no figure is supported.'))
            .field('reserve_reason', AntsuranceAiClient.text('One or two sentences on why that figure.'))
            .field('steps', AntsuranceAiClient.listOf(step.toJson(), 'Three to six next steps, in order.'))
            .field('headline', AntsuranceAiClient.text('One sentence, at most 22 words, on where the claim stands.'));
    }

    // ------------------------------------------------------------------ building the report

    @TestVisible
    private static Report toReport(Map<String, Object> answer, Loaded loaded, List<Item> docket, AntsuranceClaimsAssistantCoverage.Check check) {
        Report report = new Report();
        report.writtenAt = Datetime.now();
        report.headline = (String) answer.get('headline');
        report.whatHappened = (String) answer.get('what_happened');
        report.damage = (String) answer.get('damage');
        report.coverage = (String) answer.get('coverage');
        report.reserveReason = (String) answer.get('reserve_reason');
        report.check = check != null && check.exists == true ? check : null;
        report.reserveNow = loaded.claim.Reserve_Amount__c;
        report.paid = loaded.claim.Paid_Amount__c;
        report.estimate = loaded.claim.Estimated_Loss__c;

        // Evidence: every item on the docket appears once, with Claude's line when it gave one.
        Map<String, String> shows = new Map<String, String>();
        if (answer.get('evidence') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('evidence')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                if (String.isNotBlank((String) values.get('shows'))) {
                    shows.put((String) values.get('key'), (String) values.get('shows'));
                }
            }
        }
        for (Item item : docket) {
            EvidenceLine line = new EvidenceLine();
            line.key = item.key;
            line.kind = item.kind;
            line.title = item.title;
            line.kindLabel = item.kindLabel;
            line.documentId = item.documentId;
            line.recordId = item.recordId;
            line.readable = item.kind == KIND_NOTE || item.kind == KIND_STATEMENT || item.looked == true;
            line.shows = shows.containsKey(item.key) ? shows.get(item.key) : (line.readable ? item.lookedLine : (item.readable ? 'Not read in this run.' : 'Not read: Claude cannot read this file type here.'));
            report.evidence.add(line);
        }

        AntsuranceClaimsAssistantPhotos.Assessment photos = loaded.photos;
        if (photos != null && photos.complete != false) {
            report.consistency = photos.consistency;
            report.consistencyNote = photos.consistencyNote;
            report.signals = photos.signals == null ? new List<String>() : photos.signals;
            report.repairLow = photos.repairLow;
            report.repairHigh = photos.repairHigh;
            report.repairBasis = photos.repairBasis;
            for (AntsuranceClaimsAssistantPhotos.PhotoRead read : photos.photos) {
                report.photoIds.add(read.documentId);
                for (AntsuranceClaimsAssistantPhotos.DamageArea area : read.damage) {
                    DamageLine line = new DamageLine();
                    line.area = area.area;
                    line.detail = area.detail;
                    line.severity = area.severity;
                    line.photoNumber = read.photoNumber;
                    report.damageAreas.add(line);
                }
            }
        }

        if (answer.get('gaps') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('gaps')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                Gap gap = new Gap();
                gap.kind = GAP_KINDS.contains((String) values.get('kind')) ? (String) values.get('kind') : 'check';
                gap.text = (String) values.get('text');
                if (String.isNotBlank(gap.text)) {
                    report.gaps.add(gap);
                }
            }
        }

        // The recommendation is the lines added up here, so the arithmetic on the page always holds.
        Decimal total = 0;
        if (answer.get('reserve_lines') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('reserve_lines')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                Decimal amount = AntsuranceAiClient.toDecimal(values.get('amount'));
                if (amount == null || String.isBlank((String) values.get('label'))) {
                    continue;
                }
                ReserveLine line = new ReserveLine();
                line.label = (String) values.get('label');
                line.amount = amount.setScale(0, RoundingMode.HALF_UP);
                if (restatesTotal(line, total, report.reserveLines.size())) {
                    continue;
                }
                total += line.amount;
                report.reserveLines.add(line);
            }
        }
        report.reserveRecommended = report.reserveLines.isEmpty() ? null : Math.max(0, total);

        if (answer.get('steps') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('steps')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                NextStep step = new NextStep();
                step.subject = (String) values.get('subject');
                step.why = (String) values.get('why');
                if (String.isNotBlank(step.subject)) {
                    report.steps.add(step);
                }
            }
        }
        return report;
    }

    /** What the report depended on. Compared with the claim as it stands to say whether the report is out of date. */
    private static Map<String, String> snapshot(Loaded loaded) {
        List<String> files = new List<String>();
        for (ContentDocumentLink file : loaded.files) {
            files.add(file.ContentDocumentId + ':' + file.ContentDocument.LatestPublishedVersionId);
        }
        Case claim = loaded.claim;
        return new Map<String, String>{
            'files' => String.join(files, ','),
            'notes' => String.valueOf(loaded.notes.size()),
            'status' => claim.Status == null ? '' : claim.Status,
            'estimate' => amount(claim.Estimated_Loss__c),
            'reserve' => amount(claim.Reserve_Amount__c),
            'paid' => amount(claim.Paid_Amount__c),
            'lossType' => claim.Loss_Type__c == null ? '' : claim.Loss_Type__c,
            'dateOfLoss' => claim.Date_of_Loss__c == null ? '' : String.valueOf(claim.Date_of_Loss__c),
            'description' => String.isBlank(claim.Description) ? '' : String.valueOf(claim.Description.hashCode()),
            'policy' => claim.Policy__c == null ? '' : String.valueOf(claim.Policy__c)
        };
    }

    private static Boolean isMore(String now, String was) {
        try {
            return Integer.valueOf(now) > Integer.valueOf(was);
        } catch (Exception e) {
            return now != was;
        }
    }

    /** A sum as text that compares equal whatever scale it was stored at; nothing is the same as zero. */
    private static String amount(Decimal value) {
        return String.valueOf((value == null ? 0 : value).setScale(2, RoundingMode.HALF_UP));
    }

    private static void markChanges(Report report, Loaded loaded) {
        Map<String, String> was = loaded.stored.snapshot;
        Map<String, String> now = snapshot(loaded);
        Map<String, String> wording = new Map<String, String>{
            'files' => 'Evidence was added, replaced or removed',
            'notes' => 'A file note was added',
            'status' => 'The status changed',
            'estimate' => 'The estimate changed',
            'reserve' => 'The reserve changed',
            'paid' => 'A payment was recorded',
            'lossType' => 'The type of loss changed',
            'dateOfLoss' => 'The date of loss changed',
            'description' => 'The description of the loss changed',
            'policy' => 'The policy on the claim changed'
        };
        report.changes = new List<String>();
        for (String key : wording.keySet()) {
            // A key missing from an older analysis is not reported as a change.
            if (key == 'notes' && was.containsKey(key) && !isMore(now.get(key), was.get(key))) {
                // Fewer notes than before means the earlier count included Claude's own saved report, which no longer counts.
                continue;
            }
            if (was.containsKey(key) && was.get(key) != now.get(key)) {
                report.changes.add(wording.get(key));
            }
        }
        report.stale = !report.changes.isEmpty();
    }

    /**
     * Where the reserve stands against what is payable, from the coverage check's own limit and
     * deductible when it named the coverage that responds, so the report starts from the same sum the
     * check shows beside it.
     */
    @TestVisible
    private static String payableLine(Case claim, AntsuranceClaimsAssistantCoverage.Check check) {
        if (check == null || check.exists != true) {
            AntsuranceClaimRules.Position unchecked = AntsuranceClaimRules.position(claim.Reserve_Amount__c, claim.Estimated_Loss__c, null, null);
            return AntsuranceClaimRules.payableLine(unchecked) + (unchecked.payable == null ? '' : ' Coverage has not been checked, so no deductible or limit has been applied.');
        }
        if (check.payable == null) {
            // The check could not work out a figure, so the report must not invent one.
            return 'PAYABLE: the coverage check does not give a payable amount. RESERVE: ' + money(claim.Reserve_Amount__c) + '. Recommend a different reserve only where the evidence documents why.';
        }
        if (check.payable == 0) {
            return 'PAYABLE: $0 on the coverage check as it stands (' + check.verdict + '). RESERVE: ' + money(claim.Reserve_Amount__c) + '.';
        }
        return AntsuranceClaimRules.payableLine(AntsuranceClaimRules.position(claim.Reserve_Amount__c, claim.Estimated_Loss__c, check.deductible, check.limitAmount));
    }

    /** The report as a file note: labeled points, each on its own paragraph. */
    @TestVisible
    private static String noteFor(Report report) {
        List<String> points = new List<String>{ '**Claim analysis:** ' + report.headline };
        if (report.check != null) {
            String coverage = report.check.verdict;
            if (String.isNotBlank(report.check.respondingLabel)) {
                coverage += ' under ' + report.check.respondingLabel;
            }
            if (report.check.payable != null) {
                coverage += ', ' + money(report.check.payable) + ' payable on the estimate';
            }
            points.add('**Coverage:** ' + coverage + '.');
        }
        if (report.reserveRecommended != null) {
            points.add('**Reserve:** ' + money(report.reserveRecommended) + ' recommended against ' + money(report.reserveNow) + ' now. ' + clean(report.reserveReason));
        }
        List<String> checks = new List<String>();
        for (Gap gap : report.gaps) {
            checks.add(clean(gap.text));
        }
        if (!checks.isEmpty()) {
            points.add('**Gaps and flags:** ' + String.join(checks, ' '));
        }
        List<String> next = new List<String>();
        for (NextStep step : report.steps) {
            next.add(step.subject);
        }
        if (!next.isEmpty()) {
            points.add('**Where to start:** ' + String.join(next, '; ') + '.');
        }
        return String.join(points, '\n\n');
    }

    // ------------------------------------------------------------------ small helpers

    private static String documentLine(Reading reading) {
        String line = String.isBlank(reading.documentType) ? 'Read' : reading.documentType;
        if (reading.totalAmount != null) {
            line += ', ' + money(reading.totalAmount);
        }
        return line + ': ' + firstSentence(reading.summary);
    }

    private static String coverageLine(AntsuranceClaimsAssistantCoverage.Check check) {
        String line = check.verdict;
        if (String.isNotBlank(check.respondingLabel)) {
            line += ' under ' + check.respondingLabel;
        }
        if (check.payable != null) {
            line += ', ' + money(check.payable) + ' payable' + (check.liabilityOpen == true ? ' if the insured is liable' : '');
        }
        return line + '.';
    }

    private static String firstSentence(String text) {
        if (String.isBlank(text)) {
            return '';
        }
        String cleaned = clean(text);
        Integer stop = cleaned.indexOf('. ');
        return stop > 0 ? cleaned.left(stop + 1) : cleaned;
    }

    private static String clean(String text) {
        return text == null ? '' : text.replaceAll('\\s+', ' ').trim();
    }

    /** Markdown marks and line breaks out, for a one-line preview. */
    /** A note as one plain line: its formatting marks dropped, and a list read as a list ("Reserve: a, b, c") instead of a run of dashes. */
    @TestVisible
    private static String plain(String text) {
        if (text == null) {
            return '';
        }
        String unmarked = text.replace('**', '').replace('__', '').replace('#', '');
        // The first item follows the colon or line that introduces the list; the rest follow commas.
        unmarked = unmarked.replaceAll(':\\s*\\n\\s*[-*\u2022]\\s+', ': ').replaceAll('\\n\\s*[-*\u2022]\\s+', ', ');
        return clean(unmarked);
    }

    /**
     * Whether a reserve line only restates the lines before it: a "PAYABLE" or "Total" row carrying their
     * sum. Claude is told to leave such a row out and sometimes writes one anyway; added in, it doubles
     * the recommended reserve.
     */
    private static Boolean restatesTotal(ReserveLine line, Decimal totalSoFar, Integer linesSoFar) {
        if (linesSoFar == 0 || line.amount != totalSoFar) {
            return false;
        }
        Boolean namedAsTotal = Pattern.compile('(?i)\\b(payable|total|subtotal|sum)\\b').matcher(line.label).find();
        // After two or more lines, a line equal to their sum is a total whatever it is called.
        return namedAsTotal || linesSoFar >= 2;
    }

    private static String sizeLabel(Integer bytes) {
        if (bytes == null) {
            return '';
        }
        Decimal kilobytes = Decimal.valueOf(bytes) / BYTES_PER_KB;
        return kilobytes < BYTES_PER_KB ? Math.max(1, kilobytes.round(RoundingMode.HALF_UP)) + ' KB' : (kilobytes / BYTES_PER_KB).setScale(1, RoundingMode.HALF_UP) + ' MB';
    }

    @TestVisible
    private static String money(Decimal value) {
        if (value == null) {
            return 'not set';
        }
        Decimal rounded = value.setScale(0, RoundingMode.HALF_UP);
        return (rounded < 0 ? '-$' : '$') + rounded.abs().format();
    }

    private static Boolean isTimeout(String message) {
        return message != null && message.contains(TIMEOUT_MARK);
    }

    private static StepResult failed(String message, Boolean retryable) {
        StepResult result = new StepResult();
        result.ok = false;
        result.error = message;
        result.errorKind = isTimeout(message) ? 'timeout' : 'other';
        result.retryable = retryable == true;
        return result;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
