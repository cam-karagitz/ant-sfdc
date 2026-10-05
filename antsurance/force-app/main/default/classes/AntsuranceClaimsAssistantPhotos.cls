/**
 * @description Looks at the photographs attached to a claim, for the photos card on the claim page.
 * Claude is given the claim file and the photographs together and reports, photo by photo, what is
 * damaged, how badly and roughly where in the frame, then whether what it sees fits the reported
 * loss, what else to photograph, what to do next and a rough order of magnitude for the repair.
 *
 * The assessment is stored on the claim as JSON (the Assessment class, serialized) so the page opens
 * with it and other features can read it without calling Claude: use stored() or assessment().
 * Nothing else on the claim changes until the handler confirms a suggestion.
 *
 * One request makes one call to Claude. Salesforce allows a transaction 120 seconds of callout time
 * and 6 MB of heap, so a claim with more photographs than fit in one call is assessed in batches:
 * the card asks for each batch in its own request (assessBatch), what each batch found is saved on
 * the claim as it lands, and a last short call with no images writes the overall read from those
 * findings (finishAssessment). A batch that fails or runs out of time changes nothing, so what is
 * already done is kept and only that batch need be asked for again.
 */
public with sharing class AntsuranceClaimsAssistantPhotos {
    private static final Integer MAX_FILES = 60;
    // The request holds every photo as base64 inside one JSON body, and a synchronous transaction
    // has 6 MB of heap, so the photos sent in one go are capped in number and in total size.
    @TestVisible
    private static final Integer MAX_PHOTOS_PER_CALL = 4;
    @TestVisible
    private static final Integer MAX_PHOTO_BYTES = 450000;
    private static final Integer MAX_CALL_BYTES = 1000000;
    // Past this many, the rest are left out and the card says so.
    @TestVisible
    private static final Integer MAX_PHOTOS = 24;
    // The card shrinks a photo in the browser before saving it, so anything larger did not come from it.
    @TestVisible
    private static final Integer MAX_UPLOAD_BYTES = 700000;
    // Output is what takes the time, so each call is allowed only what its answer needs. These were
    // 450 and 1,300 at first, and one photo with a long overall read was cut short, so they have headroom.
    // The per-photo figure went from 650 to 900 when a single photo with four findings was cut short in a trial.
    private static final Integer TOKENS_PER_PHOTO = 900;
    private static final Integer OVERALL_TOKENS = 1900;
    private static final Integer MAX_TITLE = 80;
    private static final Integer BYTES_PER_KB = 1024;
    // A box thinner than this in either direction is noise, not an area.
    private static final Decimal MIN_BOX_SIDE = 0.02;
    private static final String DOWNLOAD_PATH = '/sfc/servlet.shepherd/version/download/';
    // Claude sees a photograph larger than this on its long edge scaled down, so pixel boxes are asked for only up to it.
    private static final Integer MAX_PIXEL_EDGE = 1568;
    // The markers of a JPEG's frame segment, which holds the picture's height and width.
    private static final Set<String> JPEG_FRAMES = new Set<String>{ 'c0', 'c1', 'c2', 'c3', 'c5', 'c6', 'c7', 'c9', 'ca', 'cb', 'cd', 'ce', 'cf' };

    private static final Map<String, String> IMAGE_TYPES = new Map<String, String>{
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp'
    };
    private static final Set<String> VIDEO_TYPES = new Set<String>{ 'mp4', 'mov', 'm4v', 'webm', 'avi' };

    private static final List<String> SEVERITIES = new List<String>{ 'minor', 'moderate', 'severe' };
    @TestVisible
    private static final String NO_PANEL = 'none';
    // The panels of a car seen from above, front at the top. Left is the driver's side.
    private static final List<String> PANELS = new List<String>{
        'front_bumper',
        'hood',
        'windshield',
        'roof',
        'rear_window',
        'trunk',
        'rear_bumper',
        'front_left_fender',
        'front_right_fender',
        'front_left_door',
        'front_right_door',
        'rear_left_door',
        'rear_right_door',
        'rear_left_quarter',
        'rear_right_quarter',
        NO_PANEL
    };
    private static final List<String> CONSISTENCIES = new List<String>{ 'consistent', 'check', 'unclear' };
    private static final List<String> DAMAGE_FITS = new List<String>{ 'fits', 'check', 'unclear' };
    private static final List<String> NEXT_STEPS = new List<String>{ 'photo_estimate', 'field_appraiser', 'call_insured' };

    @TestVisible
    private static final String SET_RESERVE = 'set_reserve';
    @TestVisible
    private static final String ADD_TASK = 'add_task';
    private static final List<String> SUGGESTION_KINDS = new List<String>{ SET_RESERVE, ADD_TASK };

    @TestVisible
    private static final String NO_ACCESS = 'The claim or its photos could not be read or saved. Check your access.';
    @TestVisible
    private static final String NO_PHOTOS = 'There are no photos on this claim that Claude can look at. Add one first.';
    @TestVisible
    private static final String NOT_A_PHOTO = 'Add a photo as a JPEG, PNG, GIF or WebP file.';
    @TestVisible
    private static final String PHOTO_TOO_LARGE = 'That photo is too large to save here. Add it again and it will be made smaller.';
    @TestVisible
    private static final String UNKNOWN_SUGGESTION = 'That suggestion cannot be applied.';
    @TestVisible
    private static final String NOT_ON_CLAIM = 'Those are not photos on this claim that Claude can look at.';
    @TestVisible
    private static final String TOO_MANY_AT_ONCE = 'That is more than Claude can look at in one go. Assess the photos in the batches the card offers.';
    @TestVisible
    private static final String NOTHING_TO_FINISH = 'There are no assessed photos on this claim to write up.';
    private static final String TOO_LARGE_FOR_CLAUDE = 'Too large for Claude to look at here. Add it again through this card and it will be made smaller.';
    private static final String VIDEO_NOT_ASSESSED = 'Video is not assessed yet.';

    // The demo claims that carry sample photographs, found by subject, and what goes on each.
    private static final String SCRAPE_CLAIM = 'Parking lot scrape, rear quarter panel';
    private static final String PIPE_CLAIM = 'Burst pipe flooded finished basement';
    private static final String REAR_END_CLAIM = 'Rear-ended at a red light on Harlem Ave';
    private static final String DEER_CLAIM = 'Deer strike on Route 20, front-end damage';
    private static final List<List<String>> SAMPLES = new List<List<String>>{
        new List<String>{ SCRAPE_CLAIM, 'antsuranceDamageRearQuarter', 'Rear quarter panel, passenger side' },
        new List<String>{ PIPE_CLAIM, 'antsuranceDamageFloodedRoom', 'Basement family room after the water' },
        // On purpose, a photo that does not fit its claim: a sedan's rear quarter on a claim for a Honda CR-V
        // struck from behind. It is the demo's moment where Claude says the photo is something to check.
        // The title names the side, as the scrape claim's does: left to itself Claude calls this picture the left side.
        new List<String>{ REAR_END_CLAIM, 'antsuranceDamageRearQuarter', 'Right rear quarter damage, insured\'s photo' },
        new List<String>{ DEER_CLAIM, 'antsuranceDamageDeerStrike', 'Front right corner after the deer strike' }
    };

    private static final String WHO =
        'You are a claims appraiser at Antsurance, an insurance carrier, looking at the photographs attached to a claim. ' +
        'You are given the claim file as text and the photographs in order: the first image is Photo 1, the second is Photo 2, and so on. ' +
        'Look closely at every photograph, then report for the claim handler.\n\n' +
        'Describe only what can be seen. Never invent damage, a part, a figure or a cause. Say so when a photograph does not show enough to judge. ' +
        'You assess what is visible: hidden damage and the true repair cost need an appraiser, and you never decide coverage.\n\n';
    private static final String WHO_FROM_NOTES =
        'You are a claims appraiser at Antsurance, an insurance carrier, writing the overall read of a claim\'s photographs for the claim handler. ' +
        'You are given the claim file as text and your own notes on each photograph: what it shows, whether it was usable, and each damaged area with its severity. ' +
        'You do not have the photographs themselves now, so rely on the notes and add nothing to them.\n\n' +
        'Never invent damage, a part, a figure or a cause. You assess what was visible: hidden damage and the true repair cost need an appraiser, and you never decide coverage.\n\n';
    private static final String PER_PHOTO =
        'photos: one entry for each photograph, in order. number is its position, starting at 1.\n' +
        '- shows: one line on what the photograph shows.\n' +
        '- usable: false when it is too dark, too blurred, too far away or too tightly cropped to judge damage from. unusable_reason says why in a few words, and is empty when usable.\n' +
        '- damage: each damaged area you can see, at most five, most serious first, and empty when the photograph is unusable or shows no damage. ' +
        'area names the part in plain words, such as rear bumper, left rear quarter panel, rear window, ceiling by the outside wall or roof ridge. ' +
        'detail says what is wrong in a short phrase, such as creased and pushed in, glass shattered or stained and peeling. ' +
        'severity is minor when it is cosmetic and can be repaired in place, moderate when a part needs real repair or replacement but nothing structural or safety related is involved, ' +
        'and severe when it is structural, safety related, open to the weather or likely beyond economical repair. ' +
        'panel is, for a vehicle, the closest panel from the list, where left is the driver\'s side as you would sit in the car; use none for anything that is not a vehicle panel. ' +
        'fits is fits when that damage fits the loss as reported, check when something about it does not, such as damage that looks older than the loss or sits where the report does not put it, ' +
        'and unclear when it cannot be told from the photograph. ' +
        'box is the smallest rectangle that contains that damaged area in this photograph: x and y are the top left corner measured from the left edge and the top edge, ' +
        'and width and height are the size. When the photograph is listed with its size in pixels, give all four in pixels of that photograph. ' +
        'When no size is listed for it, give them as fractions of the image between 0 and 1. Place it on the damage itself, not on the whole object, ' +
        'and check its top and bottom edges against where the damage sits in the frame before you give it.\n\n';
    private static final String OVERALL =
        'damage_summary: two sentences on the damage across all the photographs, in the order a handler would want it.\n\n' +
        'loss_seen: the kind of loss the photographs point to, in two to four words, such as rear impact, hail, water damage or wind damage to the roof.\n\n' +
        'consistency: consistent when the kind of damage, where it is and how bad it is fit the loss as reported; check when something visible does not fit it; ' +
        'unclear only when the photographs are unusable or show nothing that bears on the reported loss. ' +
        'Views that are missing belong in photos_needed: they do not make a set that fits the report unclear. ' +
        'Judge it on the damage against the reported loss. Raise the identity of the vehicle or the property only when a photograph plainly shows a different kind of thing, ' +
        'such as a pickup where the claim is for a sedan; do not comment on make, model, color or surroundings otherwise. ' +
        'consistency_note: one sentence. When something does not fit, word it as something to confirm with the insured, never as an accusation.\n\n' +
        'signals: zero to four things visible in the photographs that change how the claim is handled, each in a few words: airbags deployed, fluid leaking, frame or structural damage, ' +
        'wheel or suspension damage, broken glass, standing water, mold, exposed wiring, roof open to the weather. Only what can be seen.\n\n' +
        'likely_total_loss: true only when the visible damage plainly approaches the value of the vehicle or the structure.\n\n' +
        'photos_needed: up to four more photographs that would let the damage be judged properly, each a short phrase, such as the VIN plate, the odometer, a wider shot of the rear left ' +
        'or the ceiling above the stain. Empty when the set is enough.\n\n' +
        'next_step: photo_estimate when the damage is limited and the photographs are enough to write an estimate from; field_appraiser when damage is severe, structural, possibly hidden ' +
        'or the photographs are not enough; call_insured when the photographs do not fit the reported loss or are unusable. next_step_reason: one sentence.\n\n' +
        'repair_low and repair_high: a rough range for the repair in whole dollars, from what is visible, or null for both when the photographs do not support one. ' +
        'This is a rough order of magnitude, not an estimate. repair_basis: one sentence saying what the range assumes, such as which parts are replaced and which repaired.\n\n' +
        'suggestions: zero to three things the handler could do right now, each of one kind:\n' +
        '- set_reserve only when the claim is open and the rough range sits clearly away from the current reserve. amount is the new total reserve in whole dollars. ' +
        'Say in the reason that it rests on photographs alone.\n' +
        '- add_task for a concrete follow-up, such as asking the insured for the missing photographs or assigning a field appraiser. ' +
        'Put the task subject in title: it starts with a verb and is at most twelve words. amount is null.\n' +
        'For each, title is a short label for a button and reason is one sentence. Do not suggest what the file shows is already done or already true.\n\n' +
        'note_type and note: a file note recording what the photographs show, at most 80 words, written as two or three labeled points, each on its own paragraph, ' +
        'in the form **Label:** text. For example **Photos:**, **Damage:** and **Next:**.\n\n';
    private static final String STYLE =
        'Write in plain words. Write money with a dollar sign and thousands separators, and dates month first, like Sep 28. Do not use dashes as punctuation. ' +
        AntsuranceClaimRules.LASTING_WORDS;

    /**
     * @description A photograph or video attached to the claim.
     */
    public class PhotoItem {
        @AuraEnabled
        public Id documentId;
        @AuraEnabled
        public Id versionId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String extension;
        /** image or video. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String sizeLabel;
        @AuraEnabled
        public Datetime addedAt;
        /** Where the browser can load the file from. */
        @AuraEnabled
        public String url;
        /** False when Claude cannot look at this file here; whyNot says why. */
        @AuraEnabled
        public Boolean assessable;
        @AuraEnabled
        public String whyNot;
        /** The file's size, for planning how many fit one call. Not sent to the page. */
        public Integer bytes;
    }

    /**
     * @description A rectangle on a photograph, as fractions of its width and height from the top left.
     */
    public class Box {
        @AuraEnabled
        public Decimal x;
        @AuraEnabled
        public Decimal y;
        @AuraEnabled
        public Decimal width;
        @AuraEnabled
        public Decimal height;
    }

    /**
     * @description One damaged area seen in a photograph.
     */
    public class DamageArea {
        /** The part, in plain words. */
        @AuraEnabled
        public String area;
        /** What is wrong with it. */
        @AuraEnabled
        public String detail;
        /** minor, moderate or severe. */
        @AuraEnabled
        public String severity;
        /** For a vehicle, the panel on the top-down diagram; none otherwise. */
        @AuraEnabled
        public String panel;
        /** Roughly where it is in the photograph. Null when Claude gave no usable box. */
        @AuraEnabled
        public Box box;
        /** fits, check or unclear, against the loss as reported. Null on assessments made before this was asked for. */
        @AuraEnabled
        public String fits;
    }

    /**
     * @description What Claude saw in one photograph.
     */
    public class PhotoRead {
        /** The file (ContentDocument). Null when the assessment was run on sample images rather than a claim's files. */
        @AuraEnabled
        public Id documentId;
        /** Its position in the set Claude was shown, from 1. */
        @AuraEnabled
        public Integer photoNumber;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String shows;
        @AuraEnabled
        public Boolean usable;
        @AuraEnabled
        public String unusableReason;
        @AuraEnabled
        public List<DamageArea> damage = new List<DamageArea>();
    }

    /**
     * @description Something the handler could do after the assessment. Applied only on confirmation.
     */
    public class Suggestion {
        /** set_reserve or add_task. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public Decimal amount;
        @AuraEnabled
        public String reason;
    }

    /**
     * @description Claude's assessment of a claim's photographs. This class, serialized as JSON, is
     * what Case.Photo_Assessment__c holds.
     */
    public class Assessment {
        @AuraEnabled
        public Datetime assessedAt;
        /**
         * False while a claim with several batches of photographs is part way through: the photos
         * hold what has been assessed so far and the overall fields below are still empty.
         */
        @AuraEnabled
        public Boolean complete = true;
        @AuraEnabled
        public List<PhotoRead> photos = new List<PhotoRead>();
        /** Photographs on the claim that were left out because of the limit on how many fit in one request. */
        @AuraEnabled
        public Integer photosLeftOut = 0;
        @AuraEnabled
        public String damageSummary;
        /** The kind of loss the photographs point to. */
        @AuraEnabled
        public String lossSeen;
        /** consistent, check or unclear, against the loss as reported. */
        @AuraEnabled
        public String consistency;
        @AuraEnabled
        public String consistencyNote;
        /** Visible signs that change how the claim is handled. */
        @AuraEnabled
        public List<String> signals = new List<String>();
        @AuraEnabled
        public Boolean likelyTotalLoss;
        @AuraEnabled
        public List<String> photosNeeded = new List<String>();
        /** photo_estimate, field_appraiser or call_insured. */
        @AuraEnabled
        public String nextStep;
        @AuraEnabled
        public String nextStepReason;
        /** A rough order of magnitude in dollars, not an estimate. Both null when the photographs do not support one. */
        @AuraEnabled
        public Decimal repairLow;
        @AuraEnabled
        public Decimal repairHigh;
        @AuraEnabled
        public String repairBasis;
        @AuraEnabled
        public List<Suggestion> suggestions = new List<Suggestion>();
        @AuraEnabled
        public String noteType;
        @AuraEnabled
        public String note;
    }

    /**
     * @description Everything the photos card shows when it opens.
     */
    public class View {
        @AuraEnabled
        public List<PhotoItem> photos = new List<PhotoItem>();
        /** The stored assessment, or null when the photos have not been assessed. */
        @AuraEnabled
        public Assessment assessment;
        /** Photographs Claude could look at that were added after the stored assessment was made. */
        @AuraEnabled
        public Integer addedSince = 0;
        /**
         * The photographs Claude can look at, split into the groups that each fit one call, as file
         * Ids. One group means one call does everything; more means assessBatch for each group and
         * then finishAssessment.
         */
        @AuraEnabled
        public List<List<Id>> batches = new List<List<Id>>();
        @AuraEnabled
        public Integer maxPhotos = MAX_PHOTOS;
    }

    /**
     * @description How one step of an assessment went. A failure is returned, not thrown, so the
     * card can show it in place, keep what earlier steps found, and offer that step again.
     */
    public class StepResult {
        @AuraEnabled
        public Boolean ok;
        /** The assessment as it now stands on the claim. Set when ok. */
        @AuraEnabled
        public Assessment assessment;
        /** What went wrong, in words for the person on screen. Set when not ok. */
        @AuraEnabled
        public String error;
        /** timeout, unreachable, rate_limited, unavailable, auth or other. */
        @AuraEnabled
        public String errorKind;
        /** Whether asking again, unchanged, has a fair chance of working. */
        @AuraEnabled
        public Boolean retryable;
    }

    /** One photograph ready to send: its file, the bytes when it is to be attached, and its size in pixels when that could be read. */
    private class Shot {
        Id documentId;
        String title;
        String mediaType;
        Blob data;
        Integer width;
        Integer height;
    }

    /**
     * @description The claim's photographs and videos, newest last, with the stored assessment.
     * @param caseId The claim on screen
     * @return The files and what Claude last made of them
     * @throws AuraHandledException when the files cannot be read
     */
    @AuraEnabled
    public static View getPhotos(Id caseId) {
        View view = new View();
        try {
            view.photos = listPhotos(caseId);
            view.assessment = stored(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        view.batches = plan(view.photos);
        if (view.assessment != null) {
            Set<Id> seen = new Set<Id>();
            for (PhotoRead read : view.assessment.photos) {
                seen.add(read.documentId);
            }
            for (PhotoItem item : view.photos) {
                if (item.assessable && !seen.contains(item.documentId) && item.addedAt > view.assessment.assessedAt) {
                    view.addedSince++;
                }
            }
        }
        return view;
    }

    /**
     * @description Saves a photograph on the claim. The card shrinks it in the browser first.
     * @param caseId The claim on screen
     * @param fileName The file's name, with its extension
     * @param base64Data The file contents, base64 encoded
     * @return The saved photograph
     * @throws AuraHandledException when the file is not an image, is too large, or cannot be saved
     */
    @AuraEnabled
    public static PhotoItem savePhoto(Id caseId, String fileName, String base64Data) {
        String extension = String.isBlank(fileName) ? '' : fileName.substringAfterLast('.').toLowerCase();
        if (!IMAGE_TYPES.containsKey(extension) || String.isBlank(base64Data)) {
            throw handled(NOT_A_PHOTO);
        }
        Blob data = EncodingUtil.base64Decode(base64Data);
        if (data.size() > MAX_UPLOAD_BYTES) {
            throw handled(PHOTO_TOO_LARGE);
        }
        try {
            // Reading the claim first means a user who cannot see it cannot attach to it.
            Case claim = [SELECT Id FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
            ContentVersion version = new ContentVersion(
                Title = photoTitle(fileName).left(MAX_TITLE),
                PathOnClient = fileName,
                VersionData = data,
                FirstPublishLocationId = claim.Id
            );
            insert as user version;
            for (PhotoItem item : listPhotos(caseId)) {
                if (item.versionId == version.Id) {
                    return item;
                }
            }
            return null;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    /**
     * What an uploaded photo is called. A file name somebody wrote as words is kept; a camera or
     * system name (IMG_2041, antsuranceDamageRearQuarter) says nothing to an adjuster, so the photo is
     * named for when it was added.
     */
    @TestVisible
    private static String photoTitle(String fileName) {
        String base = String.isBlank(fileName) ? '' : fileName.substringBeforeLast('.').trim();
        Boolean isWords = base.containsWhitespace() && !Pattern.compile('(?i)^(img|dsc|pxl|image|photo|screenshot)[\\s_-]*\\d').matcher(base).find();
        return isWords ? base : 'Photo added ' + Datetime.now().format('MMM d, h:mm a');
    }

    /**
     * @description Has Claude assess the claim's photographs in one call and stores the result on
     * the claim. For a claim with more photographs than fit one call, this looks at the first group
     * and says how many were left out; the card uses assessBatch and finishAssessment instead.
     * @param caseId The claim on screen
     * @return The assessment
     * @throws AuraHandledException when there is nothing to look at or Claude cannot be reached
     */
    @AuraEnabled
    public static Assessment assessPhotos(Id caseId) {
        try {
            return assessment(caseId, true);
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
    }

    /**
     * @description The claim's photo assessment, for code that composes it with other reads of the
     * claim. Returns the stored assessment when a finished one is there, unless a fresh one is asked
     * for. A fresh one is made with a single call to Claude, so it covers the first group of
     * photographs only (see View.batches) and reports the rest in photosLeftOut.
     * @param caseId The claim
     * @param refresh True to have Claude look again even when an assessment is stored
     * @return The assessment
     * @throws AuraHandledException when there is nothing to look at or the claim cannot be read or saved
     * @throws AntsuranceAiClient.AiException when Claude cannot be reached or runs out of time; its kind and retryable say which
     */
    public static Assessment assessment(Id caseId, Boolean refresh) {
        List<PhotoItem> items;
        try {
            if (refresh != true) {
                Assessment existing = stored(caseId);
                if (existing != null && existing.complete != false) {
                    return existing;
                }
            }
            items = listPhotos(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        List<List<Id>> batches = plan(items);
        if (batches.isEmpty()) {
            throw handled(NO_PHOTOS);
        }
        Assessment result = lookAt(caseId, items, batches[0], true);
        result.complete = true;
        result.photosLeftOut = assessableCount(items) - result.photos.size();
        save(caseId, result);
        return result;
    }

    /**
     * @description Has Claude assess one group of the claim's photographs, in one call, and saves
     * what it found on the claim. A failure, including running out of Salesforce's callout time,
     * is returned rather than thrown and leaves the claim as it was.
     * @param caseId The claim on screen
     * @param documentIds The photographs to look at: one of the groups in View.batches
     * @param fresh True for the first group of a new assessment, which replaces what was stored;
     * false to add this group's findings to what is stored
     * @param only True when this group is every photograph on the claim, so the same call also
     * writes the overall read and the assessment is finished
     * @return How it went, with the assessment as it now stands
     * @throws AuraHandledException when the files are not photographs on this claim, or are too many for one call
     */
    @AuraEnabled
    public static StepResult assessBatch(Id caseId, List<Id> documentIds, Boolean fresh, Boolean only) {
        List<PhotoItem> items;
        Assessment standing;
        try {
            items = listPhotos(caseId);
            standing = fresh == true ? null : stored(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        Set<Id> wanted = new Set<Id>(documentIds == null ? new List<Id>() : documentIds);
        Integer matched = 0;
        Integer bytes = 0;
        for (PhotoItem item : items) {
            if (wanted.contains(item.documentId) && item.assessable) {
                matched++;
                bytes += item.bytes;
            }
        }
        if (wanted.isEmpty() || matched != wanted.size()) {
            throw handled(NOT_ON_CLAIM);
        }
        if (matched > MAX_PHOTOS_PER_CALL || bytes > MAX_CALL_BYTES) {
            throw handled(TOO_MANY_AT_ONCE);
        }

        Assessment found;
        try {
            found = lookAt(caseId, items, new List<Id>(wanted), only == true);
        } catch (AntsuranceAiClient.AiException e) {
            return failed(e);
        }
        Assessment result;
        if (only == true) {
            result = found;
            result.complete = true;
        } else {
            // This group's findings join the others; the overall read waits for finishAssessment.
            result = new Assessment();
            result.complete = false;
            result.assessedAt = found.assessedAt;
            Map<Id, PhotoRead> byFile = new Map<Id, PhotoRead>();
            if (standing != null) {
                for (PhotoRead read : standing.photos) {
                    byFile.put(read.documentId, read);
                }
            }
            for (PhotoRead read : found.photos) {
                byFile.put(read.documentId, read);
            }
            result.photos = inListingOrder(items, byFile);
        }
        result.photosLeftOut = assessableCount(items) - result.photos.size();
        save(caseId, result);
        return succeeded(result);
    }

    /**
     * @description Writes the overall read for a claim whose photographs were assessed in groups:
     * one short call with no images, from what each group found. A failure is returned rather than
     * thrown and leaves the per-photo findings in place.
     * @param caseId The claim on screen
     * @return How it went, with the finished assessment
     * @throws AuraHandledException when no assessed photographs are stored on the claim
     */
    @AuraEnabled
    public static StepResult finishAssessment(Id caseId) {
        Assessment standing;
        List<PhotoItem> items;
        try {
            standing = stored(caseId);
            items = listPhotos(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        if (standing == null || standing.photos.isEmpty()) {
            throw handled(NOTHING_TO_FINISH);
        }
        List<String> notes = new List<String>();
        for (PhotoRead read : standing.photos) {
            List<String> areas = new List<String>();
            for (DamageArea area : read.damage) {
                areas.add(area.area + ' (' + area.severity + (area.panel == NO_PANEL ? '' : ', panel ' + area.panel) + '): ' + area.detail);
            }
            notes.add(
                'Photo ' +
                    read.photoNumber +
                    ' "' +
                    read.title +
                    '": ' +
                    read.shows +
                    (read.usable ? '' : ' NOT USABLE: ' + read.unusableReason + '.') +
                    (areas.isEmpty() ? (read.usable ? ' No damage seen.' : '') : ' Damage: ' + String.join(areas, '; ') + '.')
            );
        }
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(
                    WHO_FROM_NOTES + OVERALL + STYLE,
                    AntsuranceClaimsAssistantBrief.describeClaim(caseId) +
                        '\n\nYour notes on the ' +
                        standing.photos.size() +
                        ' photographs attached to this claim:\n' +
                        String.join(notes, '\n') +
                        '\n\nWrite the overall read for this claim.'
                )
                .returning(overallFields(new AntsuranceAiClient.Shape()));
            question.maxTokens = OVERALL_TOKENS;
            readOverall(AntsuranceAiClient.ask(question).data, standing);
        } catch (AntsuranceAiClient.AiException e) {
            return failed(e);
        }
        standing.complete = true;
        standing.assessedAt = Datetime.now();
        standing.photosLeftOut = assessableCount(items) - standing.photos.size();
        save(caseId, standing);
        return succeeded(standing);
    }

    /**
     * @description The assessment stored on the claim, without calling Claude.
     * @param caseId The claim
     * @return The stored assessment, or null when the photos have not been assessed
     */
    public static Assessment stored(Id caseId) {
        List<Case> claims = [SELECT Photo_Assessment__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
        if (claims.isEmpty() || String.isBlank(claims[0].Photo_Assessment__c)) {
            return null;
        }
        try {
            return (Assessment) JSON.deserialize(claims[0].Photo_Assessment__c, Assessment.class);
        } catch (JSONException e) {
            return null;
        }
    }

    /**
     * @description Assesses sample photographs held as static resources against a claim described in
     * words. Nothing is read from or written to a claim record: this is for measuring the assessment.
     * @param claimFile The claim as text: what was reported, when, and what is insured
     * @param resourceNames The static resources to show Claude, in order
     * @return The assessment
     * @throws AntsuranceAiClient.AiException when Claude cannot be reached or its answer cannot be used
     */
    public static Assessment assessResources(String claimFile, List<String> resourceNames) {
        Map<String, StaticResource> byName = new Map<String, StaticResource>();
        for (StaticResource resource : [SELECT Name, ContentType, Body FROM StaticResource WHERE Name IN :resourceNames]) {
            byName.put(resource.Name, resource);
        }
        List<Shot> shots = new List<Shot>();
        for (String name : resourceNames) {
            StaticResource resource = byName.get(name);
            if (resource != null) {
                Shot shot = new Shot();
                shot.title = name;
                shot.mediaType = resource.ContentType;
                shot.data = resource.Body;
                measure(shot);
                shots.add(shot);
            }
        }
        return ask(claimFile, shots, true);
    }

    /**
     * @description Applies one suggestion the handler confirmed, as that user: a new reserve, with
     * the reason recorded in a file note, or a follow-up task.
     * @param caseId The claim on screen
     * @param kind set_reserve or add_task
     * @param amount The new reserve, for set_reserve
     * @param title The task subject, for add_task
     * @param reason Claude's reason
     * @return A short confirmation of what was done
     * @throws AuraHandledException when the kind is unknown, an amount is missing, or the save fails
     */
    @AuraEnabled
    public static String applySuggestion(Id caseId, String kind, Decimal amount, String title, String reason) {
        if (!SUGGESTION_KINDS.contains(kind)) {
            throw handled(UNKNOWN_SUGGESTION);
        }
        return AntsuranceClaimsAssistantDocuments.applySuggestion(caseId, kind, amount, title, reason, 'the claim photos');
    }

    /**
     * @description Adds Claude's note on the photographs to the claim's file notes.
     * @param caseId The claim on screen
     * @param noteType One of the file note types
     * @param body The note text, in Markdown
     * @throws AuraHandledException when the note is empty or cannot be saved
     */
    @AuraEnabled
    public static void addNote(Id caseId, String noteType, String body) {
        AntsuranceNotesController.addNote(caseId, noteType, body);
    }

    /**
     * @description Attaches the sample photographs to their demo claims, found by subject. A photo
     * already on its claim is left alone, so running this twice adds nothing. scripts/prepare_demo.sh
     * runs it after the demo data is loaded.
     * @return A line saying how many photographs were attached and how many were already there
     */
    public static String attachSamplePhotos() {
        Set<String> subjects = new Set<String>();
        Set<String> resourceNames = new Set<String>();
        for (List<String> sample : SAMPLES) {
            subjects.add(sample[0]);
            resourceNames.add(sample[1]);
        }
        Map<String, Id> claimBySubject = new Map<String, Id>();
        for (Case claim : [SELECT Subject FROM Case WHERE Subject IN :subjects AND RecordType.DeveloperName = 'Claim' ORDER BY CreatedDate]) {
            if (!claimBySubject.containsKey(claim.Subject)) {
                claimBySubject.put(claim.Subject, claim.Id);
            }
        }
        Map<String, StaticResource> resources = new Map<String, StaticResource>();
        for (StaticResource resource : [SELECT Name, Body FROM StaticResource WHERE Name IN :resourceNames]) {
            resources.put(resource.Name, resource);
        }
        Set<String> alreadyThere = new Set<String>();
        if (!claimBySubject.isEmpty()) {
            for (ContentDocumentLink link : [SELECT LinkedEntityId, ContentDocument.Title FROM ContentDocumentLink WHERE LinkedEntityId IN :claimBySubject.values()]) {
                alreadyThere.add(link.LinkedEntityId + '|' + link.ContentDocument.Title);
            }
        }

        List<ContentVersion> versions = new List<ContentVersion>();
        Integer skipped = 0;
        for (List<String> sample : SAMPLES) {
            Id claimId = claimBySubject.get(sample[0]);
            StaticResource resource = resources.get(sample[1]);
            if (claimId == null || resource == null) {
                continue;
            }
            if (alreadyThere.contains(claimId + '|' + sample[2])) {
                skipped++;
                continue;
            }
            versions.add(new ContentVersion(Title = sample[2], PathOnClient = sample[1] + '.jpg', VersionData = resource.Body, FirstPublishLocationId = claimId));
        }
        insert versions;
        return versions.size() + ' sample photos attached, ' + skipped + ' already there.';
    }

    /** The claim's image and video files, oldest first, so a photo keeps its place as more are added. */
    private static List<PhotoItem> listPhotos(Id caseId) {
        List<PhotoItem> items = new List<PhotoItem>();
        for (ContentDocumentLink link : [
            SELECT
                ContentDocumentId,
                ContentDocument.Title,
                ContentDocument.FileExtension,
                ContentDocument.ContentSize,
                ContentDocument.CreatedDate,
                ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate, ContentDocument.Title
            LIMIT :MAX_FILES
        ]) {
            String extension = link.ContentDocument.FileExtension?.toLowerCase();
            Boolean isImage = IMAGE_TYPES.containsKey(extension);
            if (!isImage && !VIDEO_TYPES.contains(extension)) {
                continue;
            }
            PhotoItem item = new PhotoItem();
            item.documentId = link.ContentDocumentId;
            item.versionId = link.ContentDocument.LatestPublishedVersionId;
            item.title = link.ContentDocument.Title;
            item.extension = extension;
            item.kind = isImage ? 'image' : 'video';
            item.sizeLabel = sizeLabel(link.ContentDocument.ContentSize);
            item.bytes = link.ContentDocument.ContentSize;
            item.addedAt = link.ContentDocument.CreatedDate;
            item.url = DOWNLOAD_PATH + item.versionId;
            item.whyNot = !isImage ? VIDEO_NOT_ASSESSED : link.ContentDocument.ContentSize > MAX_PHOTO_BYTES ? TOO_LARGE_FOR_CLAUDE : null;
            item.assessable = item.whyNot == null;
            items.add(item);
        }
        return items;
    }

    /**
     * Splits the photographs Claude can look at into groups that each fit one call: a few photos,
     * and no more bytes than the heap can hold three times over. Past MAX_PHOTOS the rest are left out.
     */
    @TestVisible
    private static List<List<Id>> plan(List<PhotoItem> items) {
        List<List<Id>> batches = new List<List<Id>>();
        List<Id> current = new List<Id>();
        Integer bytes = 0;
        Integer planned = 0;
        for (PhotoItem item : items) {
            if (!item.assessable) {
                continue;
            }
            if (planned == MAX_PHOTOS) {
                break;
            }
            if (!current.isEmpty() && (current.size() == MAX_PHOTOS_PER_CALL || bytes + item.bytes > MAX_CALL_BYTES)) {
                batches.add(current);
                current = new List<Id>();
                bytes = 0;
            }
            current.add(item.documentId);
            bytes += item.bytes;
            planned++;
        }
        if (!current.isEmpty()) {
            batches.add(current);
        }
        return batches;
    }

    private static Integer assessableCount(List<PhotoItem> items) {
        Integer count = 0;
        for (PhotoItem item : items) {
            if (item.assessable) {
                count++;
            }
        }
        return count;
    }

    /** One call to Claude over some of the claim's photographs, in the order they are listed. */
    private static Assessment lookAt(Id caseId, List<PhotoItem> items, List<Id> documentIds, Boolean withOverall) {
        Set<Id> wanted = new Set<Id>(documentIds);
        List<Shot> shots = new List<Shot>();
        String claimFile;
        try {
            for (PhotoItem item : items) {
                if (!wanted.contains(item.documentId)) {
                    continue;
                }
                // One file body at a time: loading them in a single query would hold every photo in
                // the heap twice over while they are encoded.
                Shot shot = new Shot();
                shot.documentId = item.documentId;
                shot.title = item.title;
                shot.mediaType = IMAGE_TYPES.get(item.extension);
                shot.data = [SELECT VersionData FROM ContentVersion WHERE Id = :item.versionId WITH USER_MODE LIMIT 1].VersionData;
                measure(shot);
                shots.add(shot);
            }
            claimFile = AntsuranceClaimsAssistantBrief.describeClaim(caseId);
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        Assessment result = ask(claimFile, shots, withOverall);
        // A photo keeps the number it has on the card, whichever group it was assessed in.
        Map<Id, PhotoRead> byFile = new Map<Id, PhotoRead>();
        for (PhotoRead read : result.photos) {
            byFile.put(read.documentId, read);
        }
        result.photos = inListingOrder(items, byFile);
        return result;
    }

    /** The reads in the order the photographs are listed, each numbered by its place among the claim's photographs. */
    private static List<PhotoRead> inListingOrder(List<PhotoItem> items, Map<Id, PhotoRead> byFile) {
        List<PhotoRead> ordered = new List<PhotoRead>();
        Integer position = 0;
        for (PhotoItem item : items) {
            if (item.kind != 'image') {
                continue;
            }
            position++;
            PhotoRead read = byFile.get(item.documentId);
            if (read != null) {
                read.photoNumber = position;
                ordered.add(read);
            }
        }
        return ordered;
    }

    private static void save(Id caseId, Assessment result) {
        try {
            update as user new Case(Id = caseId, Photo_Assessment__c = JSON.serialize(result), Photo_Assessment_At__c = result.assessedAt);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
    }

    private static StepResult succeeded(Assessment result) {
        StepResult step = new StepResult();
        step.ok = true;
        step.assessment = result;
        return step;
    }

    private static StepResult failed(AntsuranceAiClient.AiException e) {
        StepResult step = new StepResult();
        step.ok = false;
        step.error = e.getMessage();
        step.errorKind = e.kind;
        step.retryable = e.retryable;
        return step;
    }

    /** Sends the photographs with the claim file. With the overall read, the same call judges the set as a whole. */
    private static Assessment ask(String claimFile, List<Shot> shots, Boolean withOverall) {
        List<String> listing = new List<String>();
        AntsuranceAiClient.Shape shape = new AntsuranceAiClient.Shape().field('photos', photosField());
        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(WHO + PER_PHOTO + (withOverall ? OVERALL : '') + STYLE, null)
            .returning(withOverall ? overallFields(shape) : shape);
        for (Integer index = 0; index < shots.size(); index++) {
            // Claude places a box better in pixels than in fractions, so it is told each photo's size when that is known.
            listing.add(
                'Photo ' +
                    (index + 1) +
                    ': "' +
                    shots[index].title +
                    '"' +
                    (shots[index].width == null ? '' : ' (' + shots[index].width + ' pixels wide, ' + shots[index].height + ' pixels high)')
            );
            question.attach(shots[index].mediaType, shots[index].data);
            // The encoded copy is in the question now, so the original can go.
            shots[index].data = null;
        }
        question.prompt =
            claimFile +
            '\n\nThe ' +
            (shots.size() == 1 ? 'photograph attached to this claim is' : shots.size() + ' photographs attached to this claim are') +
            ':\n' +
            String.join(listing, '\n') +
            (withOverall
                ? '\n\nAssess them for this claim.'
                : '\n\nThese are some of the claim\'s photographs; the others are looked at separately. Report on each of these photographs only.');
        question.maxTokens = shots.size() * TOKENS_PER_PHOTO + (withOverall ? OVERALL_TOKENS : 0);
        Map<String, Object> answer = AntsuranceAiClient.ask(question).data;
        Assessment result = new Assessment();
        result.assessedAt = Datetime.now();
        result.photos = readPhotos(answer, shots);
        if (withOverall) {
            readOverall(answer, result);
        }
        return result;
    }

    private static String photosField() {
        String unit = '{"type":"number","description":"In pixels of the photograph when its size is listed, otherwise a fraction of the image from 0 to 1."}';
        AntsuranceAiClient.Shape box = new AntsuranceAiClient.Shape().field('x', unit).field('y', unit).field('width', unit).field('height', unit);
        AntsuranceAiClient.Shape damage = new AntsuranceAiClient.Shape()
            .field('area', AntsuranceAiClient.text('The damaged part, in plain words.'))
            .field('detail', AntsuranceAiClient.text('What is wrong with it, in a short phrase.'))
            .field('severity', AntsuranceAiClient.choice(SEVERITIES, 'How bad it is.'))
            .field('panel', AntsuranceAiClient.choice(PANELS, 'For a vehicle, the closest panel, left being the driver\'s side; none otherwise.'))
            .field('fits', AntsuranceAiClient.choice(DAMAGE_FITS, 'Whether this damage fits the loss as reported.'))
            .field('box', box.toJson());
        AntsuranceAiClient.Shape photo = new AntsuranceAiClient.Shape()
            .field('number', '{"type":"integer","description":"The photograph\'s position, starting at 1."}')
            .field('shows', AntsuranceAiClient.text('One line on what the photograph shows.'))
            .field('usable', AntsuranceAiClient.flag('True when damage can be judged from it.'))
            .field('unusable_reason', AntsuranceAiClient.text('Why it cannot be used, or empty.'))
            .field('damage', AntsuranceAiClient.listOf(damage.toJson(), 'The damaged areas visible, most serious first, at most five.'));
        return AntsuranceAiClient.listOf(photo.toJson(), 'One entry for each photograph, in order.');
    }

    /** Adds the fields of the overall read to a shape, after whatever it already holds. */
    @TestVisible
    private static AntsuranceAiClient.Shape overallFields(AntsuranceAiClient.Shape shape) {
        List<String> noteTypes = new List<String>();
        for (Schema.PicklistEntry entry : File_Note__c.Note_Type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                noteTypes.add(entry.getValue());
            }
        }
        AntsuranceAiClient.Shape suggestion = new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(SUGGESTION_KINDS, 'What applying it does.'))
            .field('reason', AntsuranceAiClient.text('One sentence on why.'))
            .field('amount', AntsuranceAiClient.optionalNumber('The new total reserve for set_reserve, otherwise null.'))
            .field('title', AntsuranceAiClient.text('A short button label, or the task subject for add_task.'));
        return shape
            .field('damage_summary', AntsuranceAiClient.text('Two sentences on the damage across the photographs.'))
            .field('loss_seen', AntsuranceAiClient.text('The kind of loss the photographs point to, in two to four words.'))
            .field('consistency_note', AntsuranceAiClient.text('One sentence on how the photographs fit the reported loss.'))
            .field('consistency', AntsuranceAiClient.choice(CONSISTENCIES, 'Whether the damage fits the loss as reported.'))
            .field('signals', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A visible sign that changes handling.'), 'Zero to four signs.'))
            .field('likely_total_loss', AntsuranceAiClient.flag('True when the visible damage plainly approaches the value of the vehicle or structure.'))
            .field('photos_needed', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A photograph still needed.'), 'Up to four.'))
            .field('next_step_reason', AntsuranceAiClient.text('One sentence on why that is the next step.'))
            .field('next_step', AntsuranceAiClient.choice(NEXT_STEPS, 'What to do next.'))
            .field('repair_basis', AntsuranceAiClient.text('One sentence on what the rough range assumes.'))
            .field('repair_low', AntsuranceAiClient.optionalNumber('The low end of a rough repair range in whole dollars, or null.'))
            .field('repair_high', AntsuranceAiClient.optionalNumber('The high end of a rough repair range in whole dollars, or null.'))
            .field('suggestions', AntsuranceAiClient.listOf(suggestion.toJson(), 'Zero to three things the handler could do now.'))
            .field('note_type', AntsuranceAiClient.choice(noteTypes, 'The kind of file note this is.'))
            .field('note', AntsuranceAiClient.text('A file note recording what the photographs show, as labeled points.'));
    }

    private static void readOverall(Map<String, Object> answer, Assessment result) {
        result.damageSummary = (String) answer.get('damage_summary');
        result.lossSeen = (String) answer.get('loss_seen');
        result.consistency = (String) answer.get('consistency');
        result.consistencyNote = (String) answer.get('consistency_note');
        result.signals = AntsuranceAiClient.toStrings(answer.get('signals'));
        result.likelyTotalLoss = answer.get('likely_total_loss') == true;
        result.photosNeeded = AntsuranceAiClient.toStrings(answer.get('photos_needed'));
        result.nextStep = (String) answer.get('next_step');
        result.nextStepReason = (String) answer.get('next_step_reason');
        result.repairBasis = (String) answer.get('repair_basis');
        result.noteType = (String) answer.get('note_type');
        result.note = (String) answer.get('note');
        Decimal low = AntsuranceAiClient.toDecimal(answer.get('repair_low'));
        Decimal high = AntsuranceAiClient.toDecimal(answer.get('repair_high'));
        result.repairLow = null;
        result.repairHigh = null;
        // A range needs both ends, in order.
        if (low != null && high != null && low >= 0 && high >= low) {
            result.repairLow = low.setScale(0, RoundingMode.HALF_UP);
            result.repairHigh = high.setScale(0, RoundingMode.HALF_UP);
        }
        result.suggestions = new List<Suggestion>();
        if (answer.get('suggestions') instanceof List<Object>) {
            for (Object entry : (List<Object>) answer.get('suggestions')) {
                Map<String, Object> values = (Map<String, Object>) entry;
                Suggestion suggestion = new Suggestion();
                suggestion.kind = (String) values.get('kind');
                suggestion.title = (String) values.get('title');
                suggestion.amount = AntsuranceAiClient.toDecimal(values.get('amount'));
                suggestion.reason = (String) values.get('reason');
                // A reserve change with no figure cannot be applied, so it is not offered.
                if (SUGGESTION_KINDS.contains(suggestion.kind) && String.isNotBlank(suggestion.title) && (suggestion.kind != SET_RESERVE || suggestion.amount != null)) {
                    result.suggestions.add(suggestion);
                }
            }
        }
    }

    private static List<PhotoRead> readPhotos(Map<String, Object> answer, List<Shot> shots) {
        List<PhotoRead> reads = new List<PhotoRead>();
        if (!(answer.get('photos') instanceof List<Object>)) {
            return reads;
        }
        Set<Integer> seen = new Set<Integer>();
        for (Object entry : (List<Object>) answer.get('photos')) {
            Map<String, Object> values = (Map<String, Object>) entry;
            Decimal position = AntsuranceAiClient.toDecimal(values.get('number'));
            Integer photoNumber = position == null ? null : position.intValue();
            // An entry for a photograph that was not sent, or sent twice, is dropped.
            if (photoNumber == null || photoNumber < 1 || photoNumber > shots.size() || seen.contains(photoNumber)) {
                continue;
            }
            seen.add(photoNumber);
            PhotoRead read = new PhotoRead();
            read.photoNumber = photoNumber;
            read.documentId = shots[photoNumber - 1].documentId;
            read.title = shots[photoNumber - 1].title;
            read.shows = (String) values.get('shows');
            read.usable = values.get('usable') != false;
            read.unusableReason = read.usable ? null : (String) values.get('unusable_reason');
            if (values.get('damage') instanceof List<Object>) {
                for (Object item : (List<Object>) values.get('damage')) {
                    DamageArea area = toDamage((Map<String, Object>) item, shots[photoNumber - 1]);
                    if (area != null) {
                        read.damage.add(area);
                    }
                }
            }
            reads.add(read);
        }
        return reads;
    }

    private static DamageArea toDamage(Map<String, Object> values, Shot shot) {
        DamageArea area = new DamageArea();
        area.area = (String) values.get('area');
        area.detail = (String) values.get('detail');
        area.severity = (String) values.get('severity');
        area.panel = (String) values.get('panel');
        if (String.isBlank(area.area) || !SEVERITIES.contains(area.severity)) {
            return null;
        }
        if (!PANELS.contains(area.panel)) {
            area.panel = NO_PANEL;
        }
        String fits = (String) values.get('fits');
        area.fits = DAMAGE_FITS.contains(fits) ? fits : null;
        if (values.get('box') instanceof Map<String, Object>) {
            area.box = toBox((Map<String, Object>) values.get('box'), shot);
        }
        return area;
    }

    /**
     * Turns the box Claude gave into fractions of the image, keeps it inside the image, and drops one
     * that is missing a side or too thin to mean anything. Claude gives pixels for a photograph whose
     * size it was told and fractions otherwise; a box with a side past 1 is in pixels.
     */
    private static Box toBox(Map<String, Object> values, Shot shot) {
        Decimal x = AntsuranceAiClient.toDecimal(values.get('x'));
        Decimal y = AntsuranceAiClient.toDecimal(values.get('y'));
        Decimal width = AntsuranceAiClient.toDecimal(values.get('width'));
        Decimal height = AntsuranceAiClient.toDecimal(values.get('height'));
        if (x == null || y == null || width == null || height == null) {
            return null;
        }
        if (x > 1 || y > 1 || width > 1 || height > 1) {
            // Pixels cannot be placed without the photograph's size.
            if (shot.width == null || shot.height == null) {
                return null;
            }
            x = x / shot.width;
            width = width / shot.width;
            y = y / shot.height;
            height = height / shot.height;
        }
        Box box = new Box();
        box.x = Math.min(Math.max(x, 0), 1).setScale(3, RoundingMode.HALF_UP);
        box.y = Math.min(Math.max(y, 0), 1).setScale(3, RoundingMode.HALF_UP);
        box.width = Math.min(Math.max(width, 0), 1 - box.x).setScale(3, RoundingMode.HALF_UP);
        box.height = Math.min(Math.max(height, 0), 1 - box.y).setScale(3, RoundingMode.HALF_UP);
        return box.width < MIN_BOX_SIDE || box.height < MIN_BOX_SIDE ? null : box;
    }

    /** Reads the photograph's size in pixels from its file header. Left empty when it cannot be read, and Claude then answers in fractions. */
    private static void measure(Shot shot) {
        List<Integer> size = pixelSize(shot.data, shot.mediaType);
        // Claude is shown a photograph past this size scaled down, so its pixels would not be the file's.
        if (size != null && size[0] > 0 && size[1] > 0 && Math.max(size[0], size[1]) <= MAX_PIXEL_EDGE) {
            shot.width = size[0];
            shot.height = size[1];
        }
    }

    /**
     * The width and height recorded in a JPEG, PNG or GIF file's header, or null when they are not
     * found. A JPEG keeps them in its frame segment, reached by stepping from one segment to the next.
     */
    @TestVisible
    private static List<Integer> pixelSize(Blob data, String mediaType) {
        if (data == null) {
            return null;
        }
        String hex = EncodingUtil.convertToHex(data).toLowerCase();
        if (mediaType == 'image/png') {
            return hex.length() < 48 ? null : new List<Integer>{ hexValue(hex.substring(32, 40)), hexValue(hex.substring(40, 48)) };
        }
        if (mediaType == 'image/gif') {
            // Low byte first.
            return hex.length() < 20
                ? null
                : new List<Integer>{ hexValue(hex.substring(14, 16) + hex.substring(12, 14)), hexValue(hex.substring(18, 20) + hex.substring(16, 18)) };
        }
        if (mediaType != 'image/jpeg' || !hex.startsWith('ffd8')) {
            return null;
        }
        Integer at = 4;
        while (at + 18 <= hex.length()) {
            if (hex.substring(at, at + 2) != 'ff') {
                return null;
            }
            String marker = hex.substring(at + 2, at + 4);
            if (marker == 'ff') {
                at += 2;
            } else if (JPEG_FRAMES.contains(marker)) {
                return new List<Integer>{ hexValue(hex.substring(at + 14, at + 18)), hexValue(hex.substring(at + 10, at + 14)) };
            } else if (marker == 'da' || marker == 'd9') {
                // The picture data starts, or the file ends, with no frame segment before it.
                return null;
            } else {
                at += 4 + hexValue(hex.substring(at + 4, at + 8)) * 2;
            }
        }
        return null;
    }

    private static Integer hexValue(String hex) {
        Integer value = 0;
        for (Integer index = 0; index < hex.length(); index++) {
            value = value * 16 + '0123456789abcdef'.indexOf(hex.substring(index, index + 1));
        }
        return value;
    }

    private static String sizeLabel(Integer bytes) {
        if (bytes == null) {
            return '';
        }
        Decimal kilobytes = Decimal.valueOf(bytes) / BYTES_PER_KB;
        return kilobytes < BYTES_PER_KB
            ? Math.max(1, kilobytes.round(RoundingMode.HALF_UP)) + ' KB'
            : (kilobytes / BYTES_PER_KB).setScale(1, RoundingMode.HALF_UP) + ' MB';
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
