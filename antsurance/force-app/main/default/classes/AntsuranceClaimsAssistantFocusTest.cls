@IsTest
private class AntsuranceClaimsAssistantFocusTest {
    /** Answers with one canned response and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        String body;
        HttpRequest request;
        Integer calls = 0;

        ClaudeMock(String body) {
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(body);
            return response;
        }
    }

    /** Stands in for a call that Salesforce cut off. */
    private class SlowMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    private static final String CLAIM = 'Parking lot scrape, rear quarter panel';
    private static final Datetime ASSESSED = Datetime.newInstanceGmt(2026, 10, 4, 15, 0, 0);

    @TestSetup
    static void createClaimWithAnAssessedPhoto() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-AUTO-1', Account__c = customer.Id, Primary_Insured__c = person.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Insured_Item__c = '2019 Honda Accord'
        );
        insert policy;
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Case claim = new Case(
            RecordTypeId = claimType, Subject = CLAIM, Policy__c = policy.Id, ContactId = person.Id, Status = 'New', Severity__c = 'Low',
            Loss_Type__c = 'Collision', Date_of_Loss__c = Date.today().addDays(-3), Estimated_Loss__c = 2350, Reserve_Amount__c = 1850
        );
        insert claim;
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Rear quarter', PathOnClient = 'rear.jpg', VersionData = Blob.valueOf('jpeg one'), FirstPublishLocationId = claim.Id),
            new ContentVersion(Title = 'Repair estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('%PDF'), FirstPublishLocationId = claim.Id)
        };
        store(claim.Id, assessment(photoId(claim.Id), ASSESSED));
    }

    private static Id claimId() {
        return [SELECT Id FROM Case WHERE Subject = :CLAIM].Id;
    }

    private static Id photoId(Id caseId) {
        return [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :caseId AND ContentDocument.FileExtension = 'jpg'].ContentDocumentId;
    }

    private static AntsuranceClaimsAssistantPhotos.Box box(Decimal x, Decimal y, Decimal width, Decimal height) {
        AntsuranceClaimsAssistantPhotos.Box box = new AntsuranceClaimsAssistantPhotos.Box();
        box.x = x;
        box.y = y;
        box.width = width;
        box.height = height;
        return box;
    }

    private static AntsuranceClaimsAssistantPhotos.DamageArea damage(String area, String severity, AntsuranceClaimsAssistantPhotos.Box place) {
        AntsuranceClaimsAssistantPhotos.DamageArea damage = new AntsuranceClaimsAssistantPhotos.DamageArea();
        damage.area = area;
        damage.detail = 'creased and pushed in';
        damage.severity = severity;
        damage.panel = 'rear_left_quarter';
        damage.fits = 'fits';
        damage.box = place;
        return damage;
    }

    /** Claude's own read of the one photograph: two findings with boxes. */
    private static AntsuranceClaimsAssistantPhotos.Assessment assessment(Id documentId, Datetime assessedAt) {
        AntsuranceClaimsAssistantPhotos.PhotoRead read = new AntsuranceClaimsAssistantPhotos.PhotoRead();
        read.documentId = documentId;
        read.photoNumber = 1;
        read.title = 'Rear quarter';
        read.shows = 'The rear left of a white sedan.';
        read.usable = true;
        read.damage.add(damage('Left rear quarter panel', 'moderate', box(0.1, 0.3, 0.3, 0.3)));
        read.damage.add(damage('Rear bumper', 'minor', box(0.5, 0.6, 0.2, 0.2)));
        AntsuranceClaimsAssistantPhotos.Assessment result = new AntsuranceClaimsAssistantPhotos.Assessment();
        result.assessedAt = assessedAt;
        result.photos.add(read);
        result.damageSummary = 'The left rear quarter panel is creased and the bumper is scuffed.';
        result.consistency = 'consistent';
        return result;
    }

    private static void store(Id caseId, AntsuranceClaimsAssistantPhotos.Assessment result) {
        update new Case(Id = caseId, Photo_Assessment__c = JSON.serialize(result), Photo_Assessment_At__c = result.assessedAt);
    }

    private static String areas(List<Map<String, Object>> inputs) {
        return JSON.serialize(inputs);
    }

    private static Map<String, Object> area(String id, Decimal x, Decimal y, Decimal width, Decimal height, String note) {
        return new Map<String, Object>{ 'id' => id, 'note' => note, 'box' => new Map<String, Object>{ 'x' => x, 'y' => y, 'width' => width, 'height' => height } };
    }

    private static String twoAreas() {
        return areas(new List<Map<String, Object>>{ area('a1', 0.2, 0.5, 0.25, 0.2, 'Is this old damage?'), area('a2', 0.7, 0.1, 0.2, 0.2, null) });
    }

    private static Map<String, Object> read(String letter, String name, String severity, String fits) {
        return new Map<String, Object>{
            'letter' => letter,
            'area' => name,
            'sees' => 'Rust along the lower edge that looks older than this loss',
            'severity' => severity,
            'fits_note' => 'Confirm with the insured whether the rust was there before.',
            'fits' => fits,
            'action' => 'Leave it out of the estimate until the insured confirms.'
        };
    }

    private static String reply(List<Object> reads) {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(new Map<String, Object>{ 'areas' => reads }) } }
            }
        );
    }

    private static AntsuranceClaimsAssistantFocus.PhotoView photoView(AntsuranceClaimsAssistantFocus.MarksView view, Id documentId) {
        for (AntsuranceClaimsAssistantFocus.PhotoView photo : view.photos) {
            if (photo.documentId == documentId) {
                return photo;
            }
        }
        return null;
    }

    @IsTest
    static void aDrawnAreaIsSavedUnderThePersonsName() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);

        Test.startTest();
        AntsuranceClaimsAssistantFocus.MarksView view = AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, twoAreas());
        Test.stopTest();

        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(view, documentId);
        Assert.areEqual(2, photo.areas.size());
        Assert.areEqual('Is this old damage?', photo.areas[0].note);
        Assert.areEqual(UserInfo.getName(), photo.areas[0].byName, 'Whose box it is goes on the record');
        Assert.isNull(photo.areas[0].answer, 'Claude has not been asked yet');
        Assert.areEqual(2, photo.findings.size(), 'Claude\'s own findings are listed apart from the person\'s areas');
        Assert.areEqual(1, AntsuranceClaimsAssistantFocus.getMarks(caseId).photos.size(), 'And it comes back when the page is opened again');
        Assert.areEqual(2, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage.size(), 'An unanswered area adds nothing to the assessment');
    }

    @IsTest
    static void aBoxThatIsTooSmallOrOneTooManyIsRefused() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        try {
            AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, areas(new List<Map<String, Object>>{ area('a1', 0.2, 0.5, 0.005, 0.2, null) }));
            Assert.fail('A sliver is not an area');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.BAD_BOX, e.getMessage());
        }
        List<Map<String, Object>> many = new List<Map<String, Object>>();
        for (Integer index = 0; index <= AntsuranceClaimsAssistantFocus.MAX_AREAS_PER_PHOTO; index++) {
            many.add(area('a' + index, 0.1, 0.1, 0.2, 0.2, null));
        }
        try {
            AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, areas(many));
            Assert.fail('Nine areas is one too many');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.TOO_MANY_AREAS, e.getMessage());
        }
        Id pdf = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :caseId AND ContentDocument.FileExtension = 'pdf'].ContentDocumentId;
        try {
            AntsuranceClaimsAssistantFocus.saveAreas(caseId, pdf, twoAreas());
            Assert.fail('A PDF is not a photo');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.NOT_ON_CLAIM, e.getMessage());
        }
    }

    @IsTest
    static void claudeAnswersEachAreaAndTheAssessmentCarriesTheDamage() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, twoAreas());
        ClaudeMock mock = new ClaudeMock(reply(new List<Object>{ read('A', 'Lower quarter panel', 'moderate', 'check'), read('B', 'Roof', 'none', 'fits') }));
        Test.setMock(HttpCalloutMock.class, mock);
        // One crop that fits and one that is far too large: the large one is left out, not sent.
        String crops = JSON.serialize(
            new Map<String, Object>{ 'a1' => EncodingUtil.base64Encode(Blob.valueOf('crop')), 'a2' => EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(AntsuranceClaimsAssistantFocus.MAX_CROP_BYTES + 1))) }
        );

        Test.startTest();
        AntsuranceClaimsAssistantFocus.StepResult step = AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1', 'a2' }, crops, 1280, 960);
        Test.stopTest();

        Assert.isTrue(step.ok, 'The step went through: ' + step.error);
        Assert.areEqual(1, mock.calls, 'One request makes one call');
        String sent = mock.request.getBody();
        Assert.areEqual(2, sent.countMatches('"type":"image"'), 'The whole photograph and the one crop that fits');
        Assert.isTrue(sent.contains('Area A: it starts 20% from the left edge and 50% from the top'), 'Each area is placed in words');
        Assert.isTrue(sent.contains('pixels 256 to 576 across, 480 to 672 down'), 'And in pixels');
        Assert.isTrue(sent.contains('Is this old damage?'), 'The person\'s note goes with it');
        Assert.isTrue(sent.contains('There is no crop of this one'), 'Claude is told which area has no crop');
        Assert.isTrue(sent.contains('Left rear quarter panel (moderate)'), 'Claude sees what it said about the photograph before');

        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(step.view, documentId);
        Assert.areEqual('Lower quarter panel', photo.areas[0].answer.area);
        Assert.areEqual('check', photo.areas[0].answer.fits);
        Assert.isTrue(photo.areas[0].answer.hadCrop);
        Assert.areEqual('none', photo.areas[1].answer.severity);
        Assert.isFalse(photo.areas[1].answer.hadCrop);
        Assert.areEqual(2, photo.findings.size(), 'Claude\'s own findings are still listed apart');

        // What the claim analysis reads: the assessment's damage, photo by photo.
        AntsuranceClaimsAssistantPhotos.PhotoRead stored = AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0];
        Assert.areEqual(3, stored.damage.size(), 'The area that shows damage joins the photograph\'s damage; the one that shows none does not');
        Assert.areEqual('Lower quarter panel', stored.damage[2].area);
        Assert.areEqual('moderate', stored.damage[2].severity);
        Assert.areEqual('check', stored.damage[2].fits);
        Assert.isTrue(stored.damage[2].detail.startsWith('Rust along the lower edge that looks older than this loss.'), stored.damage[2].detail);
        Assert.isTrue(stored.damage[2].detail.contains('Confirm with the insured'), 'What does not fit the loss is said');
        Assert.isTrue(stored.damage[2].detail.endsWith(AntsuranceClaimsAssistantFocus.MARKED_BY + UserInfo.getName() + '.'), 'And whose area it was');
        Assert.areEqual(0.2, stored.damage[2].box.x);
    }

    @IsTest
    static void aCallThatRunsOutOfTimeKeepsTheBoxesAndCanBeAskedAgain() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, twoAreas());
        Test.setMock(HttpCalloutMock.class, new SlowMock());

        Test.startTest();
        AntsuranceClaimsAssistantFocus.StepResult step = AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1', 'a2' }, null, 1280, 960);
        Test.stopTest();

        Assert.isFalse(step.ok, 'The failure is returned, not thrown, so the viewer can show it beside the photo');
        Assert.areEqual('timeout', step.errorKind);
        Assert.isTrue(step.retryable, 'And the same question can be asked again');
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, step.error, 'In words for the person on screen');
        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(AntsuranceClaimsAssistantFocus.getMarks(caseId), documentId);
        Assert.areEqual(2, photo.areas.size(), 'The boxes are still there');
        Assert.isNull(photo.areas[0].answer);
        Assert.areEqual(2, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage.size(), 'And the assessment is untouched');
    }

    @IsTest
    static void askingNeedsSavedAreasAndNoMoreThanFive() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        try {
            AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1' }, null, null, null);
            Assert.fail('Nothing is marked');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.NOTHING_TO_ASK, e.getMessage());
        }
        try {
            AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1', 'a2', 'a3', 'a4', 'a5', 'a6' }, null, null, null);
            Assert.fail('Six is more than one call holds');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.TOO_MANY_AT_ONCE, e.getMessage());
        }
    }

    @IsTest
    static void movingAnAnsweredAreaMarksTheAnswerOutOfDateAndRemovingItTakesItOffTheAssessment() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, twoAreas());
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(reply(new List<Object>{ read('A', 'Lower quarter panel', 'severe', 'fits') })));
        Test.startTest();
        AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1' }, null, 1280, 960);
        Test.stopTest();

        AntsuranceClaimsAssistantFocus.MarksView moved = AntsuranceClaimsAssistantFocus.saveAreas(
            caseId,
            documentId,
            areas(new List<Map<String, Object>>{ area('a1', 0.3, 0.5, 0.25, 0.2, 'Is this old damage?') })
        );
        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(moved, documentId);
        Assert.areEqual(1, photo.areas.size(), 'The area left out is gone');
        Assert.isTrue(photo.areas[0].answer.stale, 'Claude answered about where the box was');
        AntsuranceClaimsAssistantPhotos.PhotoRead stored = AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0];
        Assert.areEqual(3, stored.damage.size());
        Assert.areEqual(0.3, stored.damage[2].box.x, 'The assessment follows the box');
        Assert.isFalse(stored.damage[2].detail.contains('Confirm with the insured'), 'An area that fits the loss carries no caution');

        AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, '[]');
        Assert.areEqual(2, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage.size(), 'Removing the area takes its damage off the assessment');
        Assert.isNull([SELECT Photo_Marks__c FROM Case WHERE Id = :caseId].Photo_Marks__c, 'And nothing is left stored');
    }

    @IsTest
    static void aMovedClaudeBoxKeepsWhereClaudePutIt() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);

        Test.startTest();
        AntsuranceClaimsAssistantFocus.MarksView view = AntsuranceClaimsAssistantFocus.moveBox(caseId, documentId, 1, 'Rear bumper', JSON.serialize(box(0.55, 0.65, 0.2, 0.2)));
        // A second nudge is the same correction, not a new one.
        view = AntsuranceClaimsAssistantFocus.moveBox(caseId, documentId, 1, 'Rear bumper', JSON.serialize(box(0.56, 0.66, 0.2, 0.2)));
        Test.stopTest();

        AntsuranceClaimsAssistantFocus.Finding finding = photoView(view, documentId).findings[1];
        Assert.areEqual(0.56, finding.box.x, 'The box sits where the person put it');
        Assert.areEqual(0.5, finding.claudeBox.x, 'And the record keeps where Claude had it');
        Assert.areEqual(UserInfo.getName(), finding.changedBy);
        Assert.isNull(photoView(view, documentId).findings[0].claudeBox, 'The other finding is as Claude left it');
        Assert.areEqual(0.56, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage[1].box.x, 'Everything that reads the assessment sees the moved box');
        Assert.areEqual(1, AntsuranceClaimsAssistantFocus.stored(caseId).photos[0].corrections.size());

        view = AntsuranceClaimsAssistantFocus.undoCorrection(caseId, documentId, finding.correctionId);
        Assert.areEqual(0.5, photoView(view, documentId).findings[1].box.x, 'Undoing it puts Claude\'s box back');
        Assert.isNull(photoView(view, documentId).findings[1].claudeBox);
    }

    @IsTest
    static void aDismissedFindingLeavesTheAssessmentAndCanBePutBack() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);

        Test.startTest();
        AntsuranceClaimsAssistantFocus.MarksView view = AntsuranceClaimsAssistantFocus.dismissFinding(caseId, documentId, 0, 'Left rear quarter panel');
        Test.stopTest();

        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(view, documentId);
        Assert.areEqual(1, photo.findings.size());
        Assert.areEqual('Rear bumper', photo.findings[0].area);
        Assert.areEqual(1, photo.dismissed.size());
        Assert.areEqual('Left rear quarter panel', photo.dismissed[0].area, 'What Claude said is kept with the dismissal');
        Assert.areEqual(UserInfo.getName(), photo.dismissed[0].byName);
        Assert.areEqual(1, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage.size(), 'The claim analysis no longer reads it');

        view = AntsuranceClaimsAssistantFocus.undoCorrection(caseId, documentId, photo.dismissed[0].id);
        photo = photoView(view, documentId);
        Assert.areEqual(0, photo.dismissed.size());
        Assert.areEqual('Left rear quarter panel', photo.findings[0].area, 'It goes back where it was in the list');
        Assert.areEqual(0.1, photo.findings[0].box.x);
        Assert.areEqual('rear_left_quarter', AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage[0].panel);
        Assert.areEqual('fits', photo.findings[0].fits, 'With whether it fits the loss');
    }

    @IsTest
    static void aChangeToAListThatHasMovedOnIsRefused() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        try {
            AntsuranceClaimsAssistantFocus.moveBox(caseId, documentId, 1, 'Left rear quarter panel', JSON.serialize(box(0.5, 0.5, 0.2, 0.2)));
            Assert.fail('That is not the finding at that place');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.OUT_OF_DATE, e.getMessage());
        }
        try {
            AntsuranceClaimsAssistantFocus.dismissFinding(caseId, documentId, 5, 'Rear bumper');
            Assert.fail('There is no sixth finding');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.OUT_OF_DATE, e.getMessage());
        }
        try {
            AntsuranceClaimsAssistantFocus.moveBox(caseId, documentId, 1, 'Rear bumper', JSON.serialize(box(0.5, 0.5, 0.001, 0.2)));
            Assert.fail('A sliver is not a box');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.BAD_BOX, e.getMessage());
        }
        try {
            AntsuranceClaimsAssistantFocus.undoCorrection(caseId, documentId, 'nothing');
            Assert.fail('There is no such correction');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantFocus.OUT_OF_DATE, e.getMessage());
        }
    }

    @IsTest
    static void aNewAssessmentKeepsThePersonsAreasAndDropsCorrectionsToTheOldOne() {
        Id caseId = claimId();
        Id documentId = photoId(caseId);
        AntsuranceClaimsAssistantFocus.saveAreas(caseId, documentId, twoAreas());
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(reply(new List<Object>{ read('A', 'Lower quarter panel', 'moderate', 'check') })));
        Test.startTest();
        AntsuranceClaimsAssistantFocus.askAboutAreas(caseId, documentId, new List<String>{ 'a1' }, null, 1280, 960);
        Test.stopTest();
        AntsuranceClaimsAssistantFocus.moveBox(caseId, documentId, 1, 'Rear bumper', JSON.serialize(box(0.55, 0.65, 0.2, 0.2)));

        // The photos card has Claude assess again: its save holds only Claude's own findings.
        store(caseId, assessment(documentId, ASSESSED.addHours(1)));
        Assert.areEqual(2, AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage.size());

        AntsuranceClaimsAssistantFocus.PhotoView photo = photoView(AntsuranceClaimsAssistantFocus.getMarks(caseId), documentId);
        Assert.areEqual(2, photo.areas.size(), 'The person\'s areas and Claude\'s answer are kept');
        Assert.areEqual('Lower quarter panel', photo.areas[0].answer.area);
        Assert.isNull(photo.findings[1].claudeBox, 'The correction was to a box the new assessment no longer has');
        AntsuranceClaimsAssistantPhotos.PhotoRead stored = AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0];
        Assert.areEqual(3, stored.damage.size(), 'Opening the photos puts the answered area back on the assessment');
        Assert.areEqual('Lower quarter panel', stored.damage[2].area);
        Assert.areEqual(0, AntsuranceClaimsAssistantFocus.stored(caseId).photos[0].corrections.size());
    }

    /** The start of a real JPEG file, 1,272 pixels wide and 912 high: a JFIF segment, then the frame segment. */
    private static Blob jpegHeader() {
        return EncodingUtil.convertFromHex('ffd8' + 'ffe000104a46494600010100000100010000' + 'ffc00011080390' + '04f8' + '03012200021101031101' + 'ffd9');
    }

    @IsTest
    static void aPhotosPixelSizeIsReadFromItsHeader() {
        List<Integer> jpeg = AntsuranceClaimsAssistantPhotos.pixelSize(jpegHeader(), 'image/jpeg');
        Assert.areEqual(1272, jpeg[0]);
        Assert.areEqual(912, jpeg[1]);
        // A PNG keeps its size at a fixed place: 640 by 480.
        List<Integer> png = AntsuranceClaimsAssistantPhotos.pixelSize(EncodingUtil.convertFromHex('89504e470d0a1a0a0000000d49484452' + '00000280' + '000001e0' + '08060000'), 'image/png');
        Assert.areEqual(640, png[0]);
        Assert.areEqual(480, png[1]);
        // A GIF writes the low byte first: 320 by 200.
        List<Integer> gif = AntsuranceClaimsAssistantPhotos.pixelSize(EncodingUtil.convertFromHex('474946383961' + '4001' + 'c800' + 'f70000'), 'image/gif');
        Assert.areEqual(320, gif[0]);
        Assert.areEqual(200, gif[1]);
        Assert.isNull(AntsuranceClaimsAssistantPhotos.pixelSize(Blob.valueOf('not a picture'), 'image/jpeg'), 'A file with no header is left unmeasured');
        Assert.isNull(AntsuranceClaimsAssistantPhotos.pixelSize(Blob.valueOf('tiny'), 'image/png'));
        Assert.isNull(AntsuranceClaimsAssistantPhotos.pixelSize(Blob.valueOf('RIFF and the rest'), 'image/webp'));
    }

    @IsTest
    static void claudeIsToldAPhotosSizeAndItsPixelBoxIsStoredAsFractions() {
        Id caseId = claimId();
        ContentVersion sized = new ContentVersion(Title = 'Sized photo', PathOnClient = 'sized.jpg', VersionData = jpegHeader(), FirstPublishLocationId = caseId);
        insert sized;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :sized.Id].ContentDocumentId;
        Map<String, Object> place = new Map<String, Object>{ 'x' => 127.2, 'y' => 91.2, 'width' => 254.4, 'height' => 182.4 };
        Map<String, Object> answer = new Map<String, Object>{
            'photos' => new List<Object>{
                new Map<String, Object>{
                    'number' => 1,
                    'shows' => 'The rear left of a white sedan.',
                    'usable' => true,
                    'unusable_reason' => '',
                    'damage' => new List<Object>{
                        new Map<String, Object>{ 'area' => 'Rear bumper', 'detail' => 'scuffed', 'severity' => 'minor', 'panel' => 'rear_bumper', 'fits' => 'check', 'box' => place }
                    }
                }
            }
        };
        ClaudeMock mock = new ClaudeMock(
            JSON.serialize(
                new Map<String, Object>{
                    'model' => 'claude-opus-5-5',
                    'stop_reason' => 'end_turn',
                    'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
                }
            )
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.StepResult step = AntsuranceClaimsAssistantPhotos.assessBatch(caseId, new List<Id>{ documentId }, true, false);
        Test.stopTest();

        Assert.isTrue(step.ok, 'The step went through: ' + step.error);
        Assert.isTrue(mock.request.getBody().contains('Photo 1: \\"Sized photo\\" (1272 pixels wide, 912 pixels high)'), 'Claude is told the size it should answer in');
        AntsuranceClaimsAssistantPhotos.Box box = step.assessment.photos[0].damage[0].box;
        Assert.areEqual(0.1, box.x, 'A pixel box is stored as fractions of the image, as before');
        Assert.areEqual(0.1, box.y);
        Assert.areEqual(0.2, box.width);
        Assert.areEqual(0.2, box.height);
        Assert.areEqual('check', step.assessment.photos[0].damage[0].fits, 'Each finding says whether it fits the reported loss');
    }

    @IsTest
    static void thePageCanFetchAPhotoToCutCropsFrom() {
        Id caseId = claimId();
        AntsuranceClaimsAssistantFocus.PhotoData data = AntsuranceClaimsAssistantFocus.photoData(caseId, photoId(caseId));
        Assert.areEqual('image/jpeg', data.mediaType);
        Assert.areEqual('jpeg one', EncodingUtil.base64Decode(data.base64).toString());
    }

    @IsTest
    static void aClaimWithNothingMarkedReadsAsEmpty() {
        Id caseId = claimId();
        update new Case(Id = caseId, Photo_Assessment__c = null, Photo_Marks__c = 'not json');
        AntsuranceClaimsAssistantFocus.MarksView view = AntsuranceClaimsAssistantFocus.getMarks(caseId);
        Assert.areEqual(0, view.photos.size());
        Assert.areEqual(AntsuranceClaimsAssistantFocus.MAX_AREAS_PER_PHOTO, view.maxAreas);
        Assert.areEqual(0, AntsuranceClaimsAssistantFocus.stored(caseId).photos.size());
    }
}
