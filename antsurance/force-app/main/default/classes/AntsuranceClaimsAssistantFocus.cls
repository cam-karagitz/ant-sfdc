/**
 * @description Areas a person marks on a claim's photographs, and a person's corrections to the
 * boxes Claude drew, for the photo viewer on the claim page.
 *
 * A handler draws a box on a photograph, optionally says what they want to know, and asks Claude
 * about just those areas. Claude is given the claim file, the whole photograph, and a closer crop
 * of each area made in the browser, and answers area by area: what is there, how bad, whether it
 * fits the reported loss, and what to do about it. A handler can also move, resize or dismiss a box
 * Claude drew in its own assessment.
 *
 * Where it is kept:
 * - Case.Photo_Marks__c holds the Store class as JSON: the person's areas with Claude's answers, and
 *   each correction to one of Claude's boxes with the box Claude gave. This is the record of who
 *   marked or changed what.
 * - Case.Photo_Assessment__c (AntsuranceClaimsAssistantPhotos.Assessment) is kept in step with it,
 *   so everything that reads the assessment sees the result: an answered area that shows damage is
 *   listed among that photograph's damage with "Marked by" and the person's name in its detail, a
 *   moved box sits where the person put it, and a dismissed finding is taken out. Only fields that
 *   class already has are written, so its own reads and saves keep working.
 *
 * One request makes one call to Claude, and nothing is saved before that call, so a call that fails
 * or runs out of Salesforce's 120 seconds of callout time changes nothing: the boxes were saved by
 * an earlier request and the same question can be asked again.
 */
public with sharing class AntsuranceClaimsAssistantFocus {
    @TestVisible
    private static final Integer MAX_AREAS_PER_PHOTO = 8;
    // The whole photograph and one crop per area are held as base64 in one JSON body, in 6 MB of heap.
    @TestVisible
    private static final Integer MAX_AREAS_PER_ASK = 5;
    @TestVisible
    private static final Integer MAX_CROP_BYTES = 90000;
    @TestVisible
    private static final Integer MAX_PHOTO_BYTES = 700000;
    private static final Integer MAX_NOTE = 160;
    private static final Integer TOKENS_PER_AREA = 280;
    private static final Integer BASE_TOKENS = 200;
    // A box thinner than this in either direction is noise, not an area.
    private static final Decimal MIN_BOX_SIDE = 0.02;
    // Two boxes this close on every side are the same box (they are stored to three places).
    private static final Decimal SAME_BOX = 0.0015;
    private static final Integer PERCENT = 100;
    private static final String LETTERS = 'ABCDEFGH';
    private static final String NO_PANEL = 'none';
    // How a damage entry that came from a person's marked area is told from one Claude found itself.
    @TestVisible
    private static final String MARKED_BY = 'Marked by ';

    private static final List<String> SEVERITIES = new List<String>{ 'none', 'minor', 'moderate', 'severe', 'unclear' };
    private static final Set<String> DAMAGE_SEVERITIES = new Set<String>{ 'minor', 'moderate', 'severe' };
    private static final List<String> FITS = new List<String>{ 'fits', 'check', 'unclear' };
    private static final Map<String, String> IMAGE_TYPES = new Map<String, String>{
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp'
    };
    private static final String CROP_TYPE = 'image/jpeg';

    @TestVisible
    private static final String NO_ACCESS = 'The claim or its photos could not be read or saved. Check your access.';
    @TestVisible
    private static final String NOT_ON_CLAIM = 'That is not a photo on this claim.';
    @TestVisible
    private static final String TOO_MANY_AREAS = 'A photo can hold eight marked areas. Remove one to add another.';
    @TestVisible
    private static final String NOTHING_TO_ASK = 'Mark an area on the photo first.';
    @TestVisible
    private static final String TOO_MANY_AT_ONCE = 'Claude can look at five areas at a time. Ask about the first five, then the rest.';
    @TestVisible
    private static final String PHOTO_TOO_LARGE = 'This photo is too large for Claude to look at here. Add it again through the photos card and it will be made smaller.';
    @TestVisible
    private static final String OUT_OF_DATE = 'The photos were assessed again since this page loaded. Reload the page and try once more.';
    @TestVisible
    private static final String BAD_BOX = 'That box is too small to mean anything. Draw it a little larger.';

    private static final String WHO =
        'You are a claims appraiser at Antsurance, an insurance carrier. A claim handler has marked areas on one photograph attached to a claim and wants your read of each. ' +
        'You are given the claim file as text, then the whole photograph as the first image, then one closer crop of each marked area, in order. ' +
        'Each area is listed with a letter, where it sits in the whole photograph, and the handler\'s note when they left one. ' +
        'Use the whole photograph to see where an area is and what surrounds it, and the crop to see the detail.\n\n' +
        'Describe only what can be seen. Never invent damage, a part, a figure or a cause, and say so when an area does not show enough to judge. ' +
        'You assess what is visible: hidden damage and the true repair cost need an appraiser, and you never decide coverage.\n\n' +
        'areas: one entry for each marked area, in the order given, with its letter.\n' +
        '- area: the part or thing in the marked area, in two to five plain words, such as rear bumper corner, baseboard by the door or ceiling by the outside wall.\n' +
        '- sees: one sentence of at most 25 words on what is visible there. Start with what is visible there. When the handler\'s note asks a question, the sentence must answer it, but never open with Yes or No: the question is not shown beside your answer. ' +
        'Say plainly when nothing in the area is damaged.\n' +
        '- severity: none when the area shows no damage; minor when it is cosmetic and can be repaired in place; moderate when a part needs real repair or replacement ' +
        'but nothing structural or safety related is involved; severe when it is structural, safety related, open to the weather or likely beyond economical repair; ' +
        'unclear when the area is too dark, blurred, small or cut off to judge.\n' +
        '- fits: fits when what is in the area fits the loss as reported; check when something there does not fit it, such as damage that looks older, ' +
        'a different kind of damage or a different place than reported; unclear when it cannot be told from this area.\n' +
        '- fits_note: one sentence of at most 20 words on why. When something does not fit, word it as something to confirm with the insured, never as an accusation.\n' +
        '- action: one sentence of at most 15 words on what the handler should do about this area, starting with a verb, such as include it in the estimate, ' +
        'ask the insured for a closer photo, or have the appraiser check behind the panel.\n\n' +
        'Write in plain words. Write money with a dollar sign and thousands separators. Do not use dashes as punctuation.';

    /**
     * @description What Claude made of one marked area.
     */
    public class Answer {
        /** The part or thing in the area, in plain words. */
        @AuraEnabled
        public String area;
        /** What is visible there; answers the person's note first when it asks something. */
        @AuraEnabled
        public String sees;
        /** none, minor, moderate, severe or unclear. */
        @AuraEnabled
        public String severity;
        /** fits, check or unclear, against the loss as reported. */
        @AuraEnabled
        public String fits;
        @AuraEnabled
        public String fitsNote;
        /** What to do about this area. */
        @AuraEnabled
        public String action;
        @AuraEnabled
        public Datetime askedAt;
        /** True when the box or the note changed after Claude answered. */
        @AuraEnabled
        public Boolean stale = false;
        /** Whether Claude had a closer crop of the area as well as the whole photograph. */
        @AuraEnabled
        public Boolean hadCrop = false;
    }

    /**
     * @description An area a person marked on a photograph.
     */
    public class MarkedArea {
        /** Made by the page when the box is drawn; unique within the photograph. */
        @AuraEnabled
        public String id;
        @AuraEnabled
        public AntsuranceClaimsAssistantPhotos.Box box;
        /** What the person wants to know about it. Optional. */
        @AuraEnabled
        public String note;
        @AuraEnabled
        public String byName;
        @AuraEnabled
        public Id byId;
        @AuraEnabled
        public Datetime at;
        /** Null until Claude has been asked. */
        @AuraEnabled
        public Answer answer;
    }

    /**
     * @description A person's change to a box Claude drew: moved or resized, or the finding dismissed.
     * It keeps what Claude said, so the change can be undone and the record shows both.
     */
    public class Correction {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String area;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public String panel;
        @AuraEnabled
        public String fits;
        /** The box as Claude gave it. Null when Claude gave none. */
        @AuraEnabled
        public AntsuranceClaimsAssistantPhotos.Box claudeBox;
        /** The box as the person left it. Null when the finding was dismissed. */
        @AuraEnabled
        public AntsuranceClaimsAssistantPhotos.Box box;
        @AuraEnabled
        public Boolean dismissed = false;
        /** Where the finding sat in the photograph's list, so a dismissed one goes back in place. */
        @AuraEnabled
        public Integer position;
        @AuraEnabled
        public String byName;
        @AuraEnabled
        public Datetime at;
    }

    /**
     * @description The marks on one photograph, as stored.
     */
    public class PhotoMarks {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public List<MarkedArea> areas = new List<MarkedArea>();
        @AuraEnabled
        public List<Correction> corrections = new List<Correction>();
    }

    /**
     * @description What Case.Photo_Marks__c holds, serialized as JSON.
     */
    public class Store {
        /** The assessment the corrections were made to. A newer assessment has new boxes, so they are dropped then. */
        public Datetime assessedAt;
        public List<PhotoMarks> photos = new List<PhotoMarks>();
    }

    /**
     * @description One of Claude's own findings on a photograph, as it now stands.
     */
    public class Finding {
        /** Its place in the photograph's damage list in the stored assessment. */
        @AuraEnabled
        public Integer index;
        @AuraEnabled
        public String area;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public String severity;
        /** fits, check or unclear, against the loss as reported. */
        @AuraEnabled
        public String fits;
        @AuraEnabled
        public AntsuranceClaimsAssistantPhotos.Box box;
        /** Set when a person moved the box: where Claude had it, who moved it and when. */
        @AuraEnabled
        public AntsuranceClaimsAssistantPhotos.Box claudeBox;
        @AuraEnabled
        public String changedBy;
        @AuraEnabled
        public Datetime changedAt;
        @AuraEnabled
        public String correctionId;
    }

    /**
     * @description Everything the viewer draws on one photograph.
     */
    public class PhotoView {
        @AuraEnabled
        public Id documentId;
        /** The person's areas, lettered in this order from A. */
        @AuraEnabled
        public List<MarkedArea> areas = new List<MarkedArea>();
        /** Claude's own findings, without the entries that mirror a person's area. */
        @AuraEnabled
        public List<Finding> findings = new List<Finding>();
        /** Findings a person dismissed, which can be put back. */
        @AuraEnabled
        public List<Correction> dismissed = new List<Correction>();
    }

    /**
     * @description The marks on every photograph of a claim.
     */
    public class MarksView {
        @AuraEnabled
        public List<PhotoView> photos = new List<PhotoView>();
        @AuraEnabled
        public Integer maxAreas = MAX_AREAS_PER_PHOTO;
        @AuraEnabled
        public Integer maxPerAsk = MAX_AREAS_PER_ASK;
        @AuraEnabled
        public Integer maxCropBytes = MAX_CROP_BYTES;
    }

    /**
     * @description How asking Claude went. A failure is returned, not thrown, so the viewer can show
     * it beside the photograph, keep the boxes, and offer the same question again.
     */
    public class StepResult {
        @AuraEnabled
        public Boolean ok;
        @AuraEnabled
        public MarksView view;
        @AuraEnabled
        public String error;
        /** timeout, unreachable, rate_limited, unavailable, auth or other. */
        @AuraEnabled
        public String errorKind;
        @AuraEnabled
        public Boolean retryable;
    }

    /**
     * @description A photograph's contents, for the page to cut crops from. The page cannot read the
     * pixels of a file it shows by address, so it asks for them here.
     */
    public class PhotoData {
        @AuraEnabled
        public String base64;
        @AuraEnabled
        public String mediaType;
    }

    /** One box and note as the page sends them. */
    private class AreaInput {
        String id;
        AntsuranceClaimsAssistantPhotos.Box box;
        String note;
    }

    /** The claim's two stored pieces, read together and saved together. */
    private class Loaded {
        Store store;
        AntsuranceClaimsAssistantPhotos.Assessment assessment;
        String storeBefore;
        String assessmentBefore;
    }

    /**
     * @description The marks on the claim's photographs. Also brings the stored assessment back in
     * step when it has been made again since an area was answered, so an answered area is never
     * missing from what other features read.
     * @param caseId The claim on screen
     * @return The person's areas, Claude's findings as they stand, and what was dismissed
     * @throws AuraHandledException when the claim cannot be read
     */
    @AuraEnabled
    public static MarksView getMarks(Id caseId) {
        Loaded loaded = load(caseId);
        save(caseId, loaded);
        return toView(loaded);
    }

    /**
     * @description A photograph's contents, base64 encoded, so the page can cut a closer crop of
     * each marked area.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @return The file contents and type
     * @throws AuraHandledException when the file is not a photograph on this claim or is too large
     */
    @AuraEnabled
    public static PhotoData photoData(Id caseId, Id documentId) {
        ContentVersion version = photo(caseId, documentId);
        PhotoData data = new PhotoData();
        data.mediaType = IMAGE_TYPES.get(version.FileExtension.toLowerCase());
        data.base64 = EncodingUtil.base64Encode(version.VersionData);
        return data;
    }

    /**
     * @description Saves the boxes and notes a person has on one photograph: new ones are added
     * under their name, changed ones keep who made them, and ones left out are removed. An answer
     * Claude already gave stays, marked as out of date when its box or note changed.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @param areasJson The areas as a JSON list of id, box (x, y, width, height as fractions) and note
     * @return The marks as they now stand
     * @throws AuraHandledException when the file is not a photograph on this claim, a box is too small, or there are too many
     */
    @AuraEnabled
    public static MarksView saveAreas(Id caseId, Id documentId, String areasJson) {
        List<AreaInput> inputs = String.isBlank(areasJson) ? new List<AreaInput>() : (List<AreaInput>) JSON.deserialize(areasJson, List<AreaInput>.class);
        if (inputs.size() > MAX_AREAS_PER_PHOTO) {
            throw handled(TOO_MANY_AREAS);
        }
        requirePhoto(caseId, documentId);
        Loaded loaded = load(caseId);
        PhotoMarks marks = marksFor(loaded.store, documentId, true);
        Map<String, MarkedArea> existing = new Map<String, MarkedArea>();
        for (MarkedArea area : marks.areas) {
            existing.put(area.id, area);
        }
        List<MarkedArea> kept = new List<MarkedArea>();
        Set<String> seen = new Set<String>();
        for (AreaInput input : inputs) {
            AntsuranceClaimsAssistantPhotos.Box box = tidy(input.box);
            if (box == null || String.isBlank(input.id) || seen.contains(input.id)) {
                throw handled(BAD_BOX);
            }
            seen.add(input.id);
            String note = String.isBlank(input.note) ? null : input.note.trim().left(MAX_NOTE);
            MarkedArea area = existing.get(input.id);
            if (area == null) {
                area = new MarkedArea();
                area.id = input.id.left(40);
                area.byName = UserInfo.getName();
                area.byId = UserInfo.getUserId();
                area.at = Datetime.now();
            } else if (area.answer != null && (!sameBox(area.box, box) || area.note != note)) {
                area.answer.stale = true;
            }
            area.box = box;
            area.note = note;
            kept.add(area);
        }
        marks.areas = kept;
        save(caseId, loaded);
        return toView(loaded);
    }

    /**
     * @description Asks Claude about areas already saved on one photograph, in one call, and stores
     * its answers. A failure, including running out of Salesforce's callout time, is returned rather
     * than thrown and changes nothing.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @param areaIds Which of its saved areas to ask about, at most five
     * @param cropsJson A JSON map from area id to a JPEG crop of that area, base64 encoded; an area with no crop is asked about from the whole photograph alone
     * @param imageWidth The photograph's width in pixels, so each area can be given in pixels too
     * @param imageHeight The photograph's height in pixels
     * @return How it went, with the marks as they now stand
     * @throws AuraHandledException when there is nothing to ask about, too much, or the photograph cannot be used
     */
    @AuraEnabled
    public static StepResult askAboutAreas(Id caseId, Id documentId, List<String> areaIds, String cropsJson, Integer imageWidth, Integer imageHeight) {
        Set<String> wanted = new Set<String>(areaIds == null ? new List<String>() : areaIds);
        if (wanted.size() > MAX_AREAS_PER_ASK) {
            throw handled(TOO_MANY_AT_ONCE);
        }
        Loaded loaded = load(caseId);
        PhotoMarks marks = marksFor(loaded.store, documentId, false);
        List<MarkedArea> asked = new List<MarkedArea>();
        List<String> tags = new List<String>();
        if (marks != null) {
            for (Integer index = 0; index < marks.areas.size(); index++) {
                if (wanted.contains(marks.areas[index].id)) {
                    asked.add(marks.areas[index]);
                    tags.add(LETTERS.mid(index, 1));
                }
            }
        }
        if (asked.isEmpty()) {
            throw handled(NOTHING_TO_ASK);
        }
        ContentVersion version = photo(caseId, documentId);
        Map<String, Object> crops = String.isBlank(cropsJson) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(cropsJson);

        Map<String, Object> answer;
        Set<String> cropped = new Set<String>();
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(WHO, null).returning(answerShape());
            question.attach(IMAGE_TYPES.get(version.FileExtension.toLowerCase()), version.VersionData);
            // The encoded copy is in the question now, so the original can go.
            version.VersionData = null;
            List<String> listing = new List<String>();
            Integer image = 1;
            for (Integer index = 0; index < asked.size(); index++) {
                MarkedArea area = asked[index];
                String line = 'Area ' + tags[index] + ': ' + place(area.box, imageWidth, imageHeight) + '.';
                Object crop = crops.get(area.id);
                if (crop instanceof String && String.isNotBlank((String) crop)) {
                    Blob data = EncodingUtil.base64Decode((String) crop);
                    if (data.size() <= MAX_CROP_BYTES) {
                        question.attach(CROP_TYPE, data);
                        image++;
                        cropped.add(area.id);
                        line += ' Image ' + image + ' is a closer crop of it.';
                    }
                }
                if (cropped.contains(area.id) == false) {
                    line += ' There is no crop of this one: judge it from the whole photograph.';
                }
                line += String.isBlank(area.note) ? ' The handler left no note.' : ' The handler\'s note: "' + area.note + '"';
                listing.add(line);
            }
            crops = null;
            question.prompt =
                AntsuranceClaimsAssistantBrief.describeClaim(caseId) +
                '\n\nThe photograph is "' +
                version.Title +
                '", the first image' +
                (imageWidth != null && imageHeight != null && imageWidth > 0 && imageHeight > 0 ? ', ' + imageWidth + ' pixels wide and ' + imageHeight + ' pixels high' : '') +
                '.' +
                earlierRead(loaded.assessment, documentId) +
                '\n\nThe handler marked ' +
                (asked.size() == 1 ? 'this area' : 'these ' + asked.size() + ' areas') +
                ' on it:\n' +
                String.join(listing, '\n') +
                '\n\nGive your read of each marked area.';
            question.maxTokens = BASE_TOKENS + asked.size() * TOKENS_PER_AREA;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            StepResult failed = new StepResult();
            failed.ok = false;
            failed.error = e.getMessage();
            failed.errorKind = e.kind;
            failed.retryable = e.retryable;
            return failed;
        }

        Map<String, Map<String, Object>> byLetter = new Map<String, Map<String, Object>>();
        if (answer != null && answer.get('areas') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('areas')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                String letter = values.get('letter') == null ? '' : String.valueOf(values.get('letter')).trim().toUpperCase();
                byLetter.put(letter, values);
            }
        }
        Datetime now = Datetime.now();
        for (Integer index = 0; index < asked.size(); index++) {
            Map<String, Object> values = byLetter.get(tags[index]);
            // An area Claude skipped keeps whatever it had, so it can be asked about again.
            if (values == null || String.isBlank((String) values.get('sees'))) {
                continue;
            }
            Answer read = new Answer();
            read.area = (String) values.get('area');
            read.sees = (String) values.get('sees');
            read.severity = SEVERITIES.contains((String) values.get('severity')) ? (String) values.get('severity') : 'unclear';
            read.fits = FITS.contains((String) values.get('fits')) ? (String) values.get('fits') : 'unclear';
            read.fitsNote = (String) values.get('fits_note');
            read.action = (String) values.get('action');
            read.askedAt = now;
            read.hadCrop = cropped.contains(asked[index].id);
            asked[index].answer = read;
        }
        save(caseId, loaded);
        StepResult done = new StepResult();
        done.ok = true;
        done.view = toView(loaded);
        return done;
    }

    /**
     * @description Moves or resizes one of the boxes Claude drew, as the person on screen. The box
     * Claude gave is kept with the change, so it can be undone.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @param index The finding's place in that photograph's damage list, as getMarks gave it
     * @param area The finding's name, to be sure the list has not changed since the page loaded
     * @param boxJson The new box: x, y, width and height as fractions of the image
     * @return The marks as they now stand
     * @throws AuraHandledException when the assessment has changed since the page loaded or the box is too small
     */
    @AuraEnabled
    public static MarksView moveBox(Id caseId, Id documentId, Integer index, String area, String boxJson) {
        AntsuranceClaimsAssistantPhotos.Box box = tidy((AntsuranceClaimsAssistantPhotos.Box) JSON.deserialize(boxJson, AntsuranceClaimsAssistantPhotos.Box.class));
        if (box == null) {
            throw handled(BAD_BOX);
        }
        Loaded loaded = load(caseId);
        AntsuranceClaimsAssistantPhotos.PhotoRead read = readFor(loaded.assessment, documentId);
        AntsuranceClaimsAssistantPhotos.DamageArea finding = findingAt(read, index, area);
        PhotoMarks marks = marksFor(loaded.store, documentId, true);
        Correction correction = correctionFor(marks, finding);
        if (correction == null) {
            correction = startCorrection(finding, index);
            marks.corrections.add(correction);
        }
        correction.box = box;
        correction.byName = UserInfo.getName();
        correction.at = Datetime.now();
        finding.box = box;
        save(caseId, loaded);
        return toView(loaded);
    }

    /**
     * @description Takes one of Claude's findings off a photograph, as the person on screen. What
     * Claude said is kept with the dismissal, so it can be put back.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @param index The finding's place in that photograph's damage list, as getMarks gave it
     * @param area The finding's name, to be sure the list has not changed since the page loaded
     * @return The marks as they now stand
     * @throws AuraHandledException when the assessment has changed since the page loaded
     */
    @AuraEnabled
    public static MarksView dismissFinding(Id caseId, Id documentId, Integer index, String area) {
        Loaded loaded = load(caseId);
        AntsuranceClaimsAssistantPhotos.PhotoRead read = readFor(loaded.assessment, documentId);
        AntsuranceClaimsAssistantPhotos.DamageArea finding = findingAt(read, index, area);
        PhotoMarks marks = marksFor(loaded.store, documentId, true);
        Correction correction = correctionFor(marks, finding);
        if (correction == null) {
            correction = startCorrection(finding, index);
            marks.corrections.add(correction);
        }
        correction.box = null;
        correction.dismissed = true;
        correction.position = index;
        correction.byName = UserInfo.getName();
        correction.at = Datetime.now();
        read.damage.remove(index);
        save(caseId, loaded);
        return toView(loaded);
    }

    /**
     * @description Undoes a correction: a moved box goes back to where Claude had it, and a
     * dismissed finding goes back on the photograph.
     * @param caseId The claim on screen
     * @param documentId The photograph (ContentDocument)
     * @param correctionId The correction to undo
     * @return The marks as they now stand
     * @throws AuraHandledException when the assessment has changed since the page loaded
     */
    @AuraEnabled
    public static MarksView undoCorrection(Id caseId, Id documentId, String correctionId) {
        Loaded loaded = load(caseId);
        AntsuranceClaimsAssistantPhotos.PhotoRead read = readFor(loaded.assessment, documentId);
        PhotoMarks marks = marksFor(loaded.store, documentId, false);
        Integer at = -1;
        for (Integer index = 0; marks != null && index < marks.corrections.size(); index++) {
            if (marks.corrections[index].id == correctionId) {
                at = index;
            }
        }
        if (read == null || at < 0) {
            throw handled(OUT_OF_DATE);
        }
        Correction correction = marks.corrections[at];
        if (correction.dismissed == true) {
            AntsuranceClaimsAssistantPhotos.DamageArea finding = new AntsuranceClaimsAssistantPhotos.DamageArea();
            finding.area = correction.area;
            finding.detail = correction.detail;
            finding.severity = correction.severity;
            finding.panel = correction.panel;
            finding.fits = correction.fits;
            finding.box = correction.claudeBox;
            Integer position = correction.position == null ? read.damage.size() : Math.min(Math.max(correction.position, 0), read.damage.size());
            if (position == read.damage.size()) {
                read.damage.add(finding);
            } else {
                read.damage.add(position, finding);
            }
        } else {
            for (AntsuranceClaimsAssistantPhotos.DamageArea finding : read.damage) {
                if (finding.area == correction.area && sameBox(finding.box, correction.box)) {
                    finding.box = correction.claudeBox;
                    break;
                }
            }
        }
        marks.corrections.remove(at);
        save(caseId, loaded);
        return toView(loaded);
    }

    /**
     * @description The marks stored on the claim, without calling Claude or changing anything.
     * @param caseId The claim
     * @return The stored marks; empty when nothing has been marked
     */
    public static Store stored(Id caseId) {
        List<Case> claims = [SELECT Photo_Marks__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
        return claims.isEmpty() ? new Store() : parse(claims[0].Photo_Marks__c);
    }

    private static Store parse(String text) {
        if (String.isBlank(text)) {
            return new Store();
        }
        try {
            Store store = (Store) JSON.deserialize(text, Store.class);
            return store == null ? new Store() : store;
        } catch (JSONException e) {
            return new Store();
        }
    }

    private static Loaded load(Id caseId) {
        Loaded loaded = new Loaded();
        try {
            Case claim = [SELECT Photo_Marks__c, Photo_Assessment__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
            loaded.store = parse(claim.Photo_Marks__c);
            if (String.isNotBlank(claim.Photo_Assessment__c)) {
                try {
                    loaded.assessment = (AntsuranceClaimsAssistantPhotos.Assessment) JSON.deserialize(claim.Photo_Assessment__c, AntsuranceClaimsAssistantPhotos.Assessment.class);
                } catch (JSONException e) {
                    loaded.assessment = null;
                }
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        loaded.storeBefore = JSON.serialize(loaded.store);
        loaded.assessmentBefore = loaded.assessment == null ? null : JSON.serialize(loaded.assessment);
        // Corrections belong to the assessment they were made to. A newer one has boxes of its own.
        Datetime assessedAt = loaded.assessment == null ? null : loaded.assessment.assessedAt;
        if (loaded.store.assessedAt != assessedAt) {
            for (PhotoMarks marks : loaded.store.photos) {
                marks.corrections.clear();
            }
            loaded.store.assessedAt = assessedAt;
        }
        return loaded;
    }

    /** Brings the assessment in step with the marks and writes whichever of the two changed. */
    private static void save(Id caseId, Loaded loaded) {
        mirror(loaded);
        String storeNow = JSON.serialize(loaded.store);
        String assessmentNow = loaded.assessment == null ? null : JSON.serialize(loaded.assessment);
        Case claim = new Case(Id = caseId);
        Boolean changed = false;
        if (storeNow != loaded.storeBefore) {
            claim.Photo_Marks__c = isEmpty(loaded.store) ? null : storeNow;
            changed = true;
        }
        if (assessmentNow != loaded.assessmentBefore) {
            claim.Photo_Assessment__c = assessmentNow;
            changed = true;
        }
        if (!changed) {
            return;
        }
        try {
            update as user claim;
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
        loaded.storeBefore = storeNow;
        loaded.assessmentBefore = assessmentNow;
    }

    private static Boolean isEmpty(Store store) {
        for (PhotoMarks marks : store.photos) {
            if (!marks.areas.isEmpty() || !marks.corrections.isEmpty()) {
                return false;
            }
        }
        return true;
    }

    /**
     * Lists each answered area that shows damage among its photograph's damage in the assessment,
     * after Claude's own findings, so the claim analysis and anything else that reads the assessment
     * reads it too. Entries from an earlier pass are replaced, so this can be run any number of times.
     */
    private static void mirror(Loaded loaded) {
        if (loaded.assessment == null) {
            return;
        }
        Map<Id, PhotoMarks> byFile = new Map<Id, PhotoMarks>();
        for (PhotoMarks marks : loaded.store.photos) {
            byFile.put(marks.documentId, marks);
        }
        for (AntsuranceClaimsAssistantPhotos.PhotoRead read : loaded.assessment.photos) {
            List<AntsuranceClaimsAssistantPhotos.DamageArea> own = new List<AntsuranceClaimsAssistantPhotos.DamageArea>();
            for (AntsuranceClaimsAssistantPhotos.DamageArea finding : read.damage) {
                if (!isMirror(finding)) {
                    own.add(finding);
                }
            }
            PhotoMarks marks = byFile.get(read.documentId);
            if (marks != null) {
                for (MarkedArea area : marks.areas) {
                    if (area.answer == null || !DAMAGE_SEVERITIES.contains(area.answer.severity)) {
                        continue;
                    }
                    AntsuranceClaimsAssistantPhotos.DamageArea finding = new AntsuranceClaimsAssistantPhotos.DamageArea();
                    finding.area = String.isBlank(area.answer.area) ? 'Marked area' : area.answer.area;
                    finding.detail = mirrorDetail(area);
                    finding.severity = area.answer.severity;
                    finding.panel = NO_PANEL;
                    finding.fits = area.answer.fits;
                    finding.box = area.box;
                    own.add(finding);
                }
            }
            read.damage = own;
        }
    }

    private static String mirrorDetail(MarkedArea area) {
        List<String> parts = new List<String>{ sentence(area.answer.sees) };
        if (area.answer.fits == 'check' && String.isNotBlank(area.answer.fitsNote)) {
            parts.add(sentence(area.answer.fitsNote));
        }
        parts.add(MARKED_BY + area.byName + '.');
        return String.join(parts, ' ');
    }

    private static String sentence(String text) {
        String trimmed = text == null ? '' : text.trim();
        return trimmed.endsWith('.') || trimmed.endsWith('?') || trimmed.endsWith('!') || trimmed == '' ? trimmed : trimmed + '.';
    }

    private static Boolean isMirror(AntsuranceClaimsAssistantPhotos.DamageArea finding) {
        return finding.detail != null && finding.detail.contains(MARKED_BY);
    }

    private static MarksView toView(Loaded loaded) {
        MarksView view = new MarksView();
        Map<Id, PhotoView> byFile = new Map<Id, PhotoView>();
        for (PhotoMarks marks : loaded.store.photos) {
            PhotoView photo = new PhotoView();
            photo.documentId = marks.documentId;
            photo.areas = marks.areas;
            for (Correction correction : marks.corrections) {
                if (correction.dismissed == true) {
                    photo.dismissed.add(correction);
                }
            }
            byFile.put(marks.documentId, photo);
            view.photos.add(photo);
        }
        if (loaded.assessment != null) {
            for (AntsuranceClaimsAssistantPhotos.PhotoRead read : loaded.assessment.photos) {
                PhotoView photo = byFile.get(read.documentId);
                if (photo == null) {
                    photo = new PhotoView();
                    photo.documentId = read.documentId;
                    byFile.put(read.documentId, photo);
                    view.photos.add(photo);
                }
                PhotoMarks marks = marksFor(loaded.store, read.documentId, false);
                for (Integer index = 0; index < read.damage.size(); index++) {
                    AntsuranceClaimsAssistantPhotos.DamageArea damage = read.damage[index];
                    if (isMirror(damage)) {
                        continue;
                    }
                    Finding finding = new Finding();
                    finding.index = index;
                    finding.area = damage.area;
                    finding.detail = damage.detail;
                    finding.severity = damage.severity;
                    finding.fits = damage.fits;
                    finding.box = damage.box;
                    Correction correction = marks == null ? null : correctionFor(marks, damage);
                    if (correction != null) {
                        finding.claudeBox = correction.claudeBox;
                        finding.changedBy = correction.byName;
                        finding.changedAt = correction.at;
                        finding.correctionId = correction.id;
                    }
                    photo.findings.add(finding);
                }
            }
        }
        return view;
    }

    private static PhotoMarks marksFor(Store store, Id documentId, Boolean create) {
        for (PhotoMarks marks : store.photos) {
            if (marks.documentId == documentId) {
                return marks;
            }
        }
        if (!create) {
            return null;
        }
        PhotoMarks marks = new PhotoMarks();
        marks.documentId = documentId;
        store.photos.add(marks);
        return marks;
    }

    private static AntsuranceClaimsAssistantPhotos.PhotoRead readFor(AntsuranceClaimsAssistantPhotos.Assessment assessment, Id documentId) {
        if (assessment != null) {
            for (AntsuranceClaimsAssistantPhotos.PhotoRead read : assessment.photos) {
                if (read.documentId == documentId) {
                    return read;
                }
            }
        }
        return null;
    }

    /** The finding at a place in the list, only when it is still the one the page was showing. */
    private static AntsuranceClaimsAssistantPhotos.DamageArea findingAt(AntsuranceClaimsAssistantPhotos.PhotoRead read, Integer index, String area) {
        if (read == null || index == null || index < 0 || index >= read.damage.size() || read.damage[index].area != area || isMirror(read.damage[index])) {
            throw handled(OUT_OF_DATE);
        }
        return read.damage[index];
    }

    /** The correction already made to a finding, found by its name and where its box now sits. */
    private static Correction correctionFor(PhotoMarks marks, AntsuranceClaimsAssistantPhotos.DamageArea finding) {
        for (Correction correction : marks.corrections) {
            if (correction.dismissed != true && correction.area == finding.area && sameBox(correction.box, finding.box)) {
                return correction;
            }
        }
        return null;
    }

    private static Correction startCorrection(AntsuranceClaimsAssistantPhotos.DamageArea finding, Integer index) {
        Correction correction = new Correction();
        correction.id = 'c' + String.valueOf(Datetime.now().getTime()) + index;
        correction.area = finding.area;
        correction.detail = finding.detail;
        correction.severity = finding.severity;
        correction.panel = finding.panel;
        correction.fits = finding.fits;
        correction.claudeBox = finding.box;
        correction.position = index;
        return correction;
    }

    /** What Claude already said about this photograph, so its read of an area is in keeping with it. */
    private static String earlierRead(AntsuranceClaimsAssistantPhotos.Assessment assessment, Id documentId) {
        AntsuranceClaimsAssistantPhotos.PhotoRead read = readFor(assessment, documentId);
        if (read == null || String.isBlank(read.shows)) {
            return '';
        }
        List<String> found = new List<String>();
        for (AntsuranceClaimsAssistantPhotos.DamageArea damage : read.damage) {
            if (!isMirror(damage)) {
                found.add(damage.area + ' (' + damage.severity + '): ' + damage.detail);
            }
        }
        return '\n\nYour earlier read of the whole photograph: ' +
            read.shows +
            (found.isEmpty() ? ' You listed no damage.' : ' You listed this damage: ' + String.join(found, '; ') + '.') +
            ' Look again at each marked area now, and say so when the closer look changes that read.';
    }

    /** Where a box sits, as percentages and, when the size is known, in pixels. */
    private static String place(AntsuranceClaimsAssistantPhotos.Box box, Integer imageWidth, Integer imageHeight) {
        String placed =
            'it starts ' +
            percent(box.x) +
            ' from the left edge and ' +
            percent(box.y) +
            ' from the top, and is ' +
            percent(box.width) +
            ' of the width and ' +
            percent(box.height) +
            ' of the height';
        if (imageWidth != null && imageHeight != null && imageWidth > 0 && imageHeight > 0) {
            Integer fromLeft = (box.x * imageWidth).intValue();
            Integer fromTop = (box.y * imageHeight).intValue();
            placed +=
                ' (pixels ' +
                fromLeft +
                ' to ' +
                (fromLeft + (box.width * imageWidth).intValue()) +
                ' across, ' +
                fromTop +
                ' to ' +
                (fromTop + (box.height * imageHeight).intValue()) +
                ' down)';
        }
        return placed;
    }

    private static String percent(Decimal fraction) {
        return (fraction * PERCENT).setScale(0, RoundingMode.HALF_UP) + '%';
    }

    private static AntsuranceAiClient.Shape answerShape() {
        AntsuranceAiClient.Shape area = new AntsuranceAiClient.Shape()
            .field('letter', AntsuranceAiClient.text('The area\'s letter, as given.'))
            .field('area', AntsuranceAiClient.text('The part or thing in the area, in plain words.'))
            .field('sees', AntsuranceAiClient.text('One or two sentences that start with what is visible there and answer the handler\'s note, never opening with Yes or No.'))
            .field('severity', AntsuranceAiClient.choice(SEVERITIES, 'How bad what is in the area is.'))
            .field('fits_note', AntsuranceAiClient.text('One sentence on how the area fits the reported loss.'))
            .field('fits', AntsuranceAiClient.choice(FITS, 'Whether what is in the area fits the loss as reported.'))
            .field('action', AntsuranceAiClient.text('One sentence on what the handler should do about this area.'));
        return new AntsuranceAiClient.Shape().field('areas', AntsuranceAiClient.listOf(area.toJson(), 'One entry for each marked area, in order.'));
    }

    /** Keeps a box inside the image, to three places, and refuses one too thin to mean anything. */
    private static AntsuranceClaimsAssistantPhotos.Box tidy(AntsuranceClaimsAssistantPhotos.Box given) {
        if (given == null || given.x == null || given.y == null || given.width == null || given.height == null) {
            return null;
        }
        AntsuranceClaimsAssistantPhotos.Box box = new AntsuranceClaimsAssistantPhotos.Box();
        box.x = Math.min(Math.max(given.x, 0), 1).setScale(3, RoundingMode.HALF_UP);
        box.y = Math.min(Math.max(given.y, 0), 1).setScale(3, RoundingMode.HALF_UP);
        box.width = Math.min(Math.max(given.width, 0), 1 - box.x).setScale(3, RoundingMode.HALF_UP);
        box.height = Math.min(Math.max(given.height, 0), 1 - box.y).setScale(3, RoundingMode.HALF_UP);
        return box.width < MIN_BOX_SIDE || box.height < MIN_BOX_SIDE ? null : box;
    }

    private static Boolean sameBox(AntsuranceClaimsAssistantPhotos.Box one, AntsuranceClaimsAssistantPhotos.Box other) {
        if (one == null || other == null) {
            return one == null && other == null;
        }
        return Math.abs(one.x - other.x) <= SAME_BOX &&
            Math.abs(one.y - other.y) <= SAME_BOX &&
            Math.abs(one.width - other.width) <= SAME_BOX &&
            Math.abs(one.height - other.height) <= SAME_BOX;
    }

    private static void requirePhoto(Id caseId, Id documentId) {
        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.FileExtension
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :caseId AND ContentDocumentId = :documentId
                WITH USER_MODE
                LIMIT 1
            ];
            if (links.isEmpty() || !IMAGE_TYPES.containsKey(links[0].ContentDocument.FileExtension?.toLowerCase())) {
                throw handled(NOT_ON_CLAIM);
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
    }

    /** The photograph's latest version with its contents, once it is known to be an image on this claim. */
    private static ContentVersion photo(Id caseId, Id documentId) {
        requirePhoto(caseId, documentId);
        try {
            ContentVersion version = [
                SELECT Title, FileExtension, ContentSize, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId = :documentId AND IsLatest = TRUE
                WITH USER_MODE
                LIMIT 1
            ];
            if (version.ContentSize > MAX_PHOTO_BYTES) {
                throw handled(PHOTO_TOO_LARGE);
            }
            return version;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
