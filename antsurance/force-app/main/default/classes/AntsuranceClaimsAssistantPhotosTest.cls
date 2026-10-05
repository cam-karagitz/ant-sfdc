@IsTest
private class AntsuranceClaimsAssistantPhotosTest {
    /** Answers with one canned response and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status;
        String body;
        HttpRequest request;
        Integer calls = 0;

        ClaudeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            calls++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
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

    @TestSetup
    static void createClaimWithPhotos() {
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
        List<Case> claims = new List<Case>{
            new Case(
                RecordTypeId = claimType, Subject = CLAIM, Policy__c = policy.Id, ContactId = person.Id, Status = 'New', Severity__c = 'Low',
                Loss_Type__c = 'Collision', Date_of_Loss__c = Date.today().addDays(-3), Estimated_Loss__c = 2350, Reserve_Amount__c = 1850
            ),
            new Case(RecordTypeId = claimType, Subject = 'A claim with no photos', Policy__c = policy.Id, Status = 'New')
        };
        insert claims;
        // Files made in the same moment list by title, so "Rear quarter" is Photo 1 and "Wide shot" is Photo 2.
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Rear quarter', PathOnClient = 'rear.jpg', VersionData = Blob.valueOf('jpeg one'), FirstPublishLocationId = claims[0].Id),
            new ContentVersion(Title = 'Wide shot', PathOnClient = 'wide.PNG', VersionData = Blob.valueOf('png two'), FirstPublishLocationId = claims[0].Id),
            new ContentVersion(Title = 'Walk-around', PathOnClient = 'walk.mp4', VersionData = Blob.valueOf('video'), FirstPublishLocationId = claims[0].Id),
            new ContentVersion(Title = 'Repair estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('%PDF'), FirstPublishLocationId = claims[0].Id)
        };
    }

    private static Id claimId() {
        return [SELECT Id FROM Case WHERE Subject = :CLAIM].Id;
    }

    private static Map<String, Object> box(Decimal x, Decimal y, Decimal width, Decimal height) {
        return new Map<String, Object>{ 'x' => x, 'y' => y, 'width' => width, 'height' => height };
    }

    private static Map<String, Object> damage(String area, String severity, String panel, Map<String, Object> place) {
        return new Map<String, Object>{ 'area' => area, 'detail' => 'creased and pushed in', 'severity' => severity, 'panel' => panel, 'box' => place };
    }

    private static Map<String, Object> answer() {
        return new Map<String, Object>{
            'photos' => new List<Object>{
                new Map<String, Object>{
                    'number' => 1,
                    'shows' => 'The rear left of a white sedan.',
                    'usable' => true,
                    'unusable_reason' => '',
                    'damage' => new List<Object>{
                        damage('Left rear quarter panel', 'moderate', 'rear_left_quarter', box(0.1, 0.3, 0.3, 0.3)),
                        // Runs off the right and bottom edges: kept, and cut to fit.
                        damage('Rear bumper', 'minor', 'rear_bumper', box(0.8, 0.9, 0.5, 0.5)),
                        // Too thin to be an area: listed without a box.
                        damage('Tail lamp', 'minor', 'a panel that does not exist', box(0.2, 0.2, 0.001, 0.2)),
                        // No severity Claude may use: dropped.
                        damage('Wheel', 'catastrophic', 'none', box(0.4, 0.6, 0.2, 0.2))
                    }
                },
                new Map<String, Object>{ 'number' => 2, 'shows' => 'A dark frame.', 'usable' => false, 'unusable_reason' => 'Too dark', 'damage' => new List<Object>() },
                // A photograph that was never sent.
                new Map<String, Object>{ 'number' => 7, 'shows' => 'Nothing.', 'usable' => true, 'unusable_reason' => '', 'damage' => new List<Object>() }
            },
            'damage_summary' => 'The left rear quarter panel is creased and the bumper is scuffed.',
            'loss_seen' => 'low speed side scrape',
            'consistency_note' => 'A crease at the rear quarter fits a scrape against a bollard.',
            'consistency' => 'consistent',
            'signals' => new List<Object>{ 'none of concern', '' },
            'likely_total_loss' => false,
            'photos_needed' => new List<Object>{ 'the VIN plate', 'the odometer' },
            'next_step_reason' => 'The damage is limited and well shown.',
            'next_step' => 'photo_estimate',
            'repair_basis' => 'Repair and refinish the quarter panel and bumper cover.',
            'repair_low' => 1800,
            'repair_high' => 2600.4,
            'suggestions' => new List<Object>{
                new Map<String, Object>{ 'kind' => 'add_task', 'reason' => 'They are missing.', 'amount' => null, 'title' => 'Ask Maya for the VIN plate and odometer photos' },
                new Map<String, Object>{ 'kind' => 'set_reserve', 'reason' => 'No figure.', 'amount' => null, 'title' => 'Set the reserve' },
                new Map<String, Object>{ 'kind' => 'flag_fraud', 'reason' => 'Not a kind this card offers.', 'amount' => null, 'title' => 'Flag it' }
            },
            'note_type' => 'General',
            'note' => '**Photos:** Two on file.\n\n**Damage:** Quarter panel creased.'
        };
    }

    private static String reply() {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer()) } }
            }
        );
    }

    /** Four more photographs on the claim, so that it has six: more than fit one call. */
    private static void addFourMorePhotos(Id caseId) {
        List<ContentVersion> more = new List<ContentVersion>();
        for (String name : new List<String>{ 'Xa', 'Xb', 'Xc', 'Xd' }) {
            more.add(new ContentVersion(Title = name, PathOnClient = name + '.jpg', VersionData = Blob.valueOf('jpeg ' + name), FirstPublishLocationId = caseId));
        }
        insert more;
    }

    /** Leaves the claim part way through an assessment: one photograph looked at, no overall read. */
    private static void storePartial(Id caseId, String title) {
        AntsuranceClaimsAssistantPhotos.PhotoRead read = new AntsuranceClaimsAssistantPhotos.PhotoRead();
        read.documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = :title].ContentDocumentId;
        read.photoNumber = 1;
        read.title = title;
        read.shows = 'Kept from an earlier batch.';
        read.usable = true;
        AntsuranceClaimsAssistantPhotos.Assessment partial = new AntsuranceClaimsAssistantPhotos.Assessment();
        partial.complete = false;
        partial.assessedAt = Datetime.now().addMinutes(-5);
        partial.photos.add(read);
        update new Case(Id = caseId, Photo_Assessment__c = JSON.serialize(partial), Photo_Assessment_At__c = partial.assessedAt);
    }

    private static String failure(String what, Id caseId) {
        try {
            if (what == 'assess') {
                AntsuranceClaimsAssistantPhotos.assessPhotos(caseId);
            } else if (what == 'finish') {
                AntsuranceClaimsAssistantPhotos.finishAssessment(caseId);
            } else if (what == 'batch with a file that is not a photo') {
                AntsuranceClaimsAssistantPhotos.assessBatch(caseId, new List<Id>{ [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Repair estimate'].ContentDocumentId }, true, true);
            } else if (what == 'batch too big') {
                List<Id> all = new List<Id>();
                for (List<Id> batch : AntsuranceClaimsAssistantPhotos.getPhotos(caseId).batches) {
                    all.addAll(batch);
                }
                AntsuranceClaimsAssistantPhotos.assessBatch(caseId, all, true, true);
            } else if (what == 'save a pdf') {
                AntsuranceClaimsAssistantPhotos.savePhoto(caseId, 'estimate.pdf', EncodingUtil.base64Encode(Blob.valueOf('x')));
            } else if (what == 'save too much') {
                AntsuranceClaimsAssistantPhotos.savePhoto(caseId, 'big.jpg', EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(AntsuranceClaimsAssistantPhotos.MAX_UPLOAD_BYTES + 1))));
            } else {
                AntsuranceClaimsAssistantPhotos.applySuggestion(caseId, what, null, 'A task', null);
            }
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void photosAndVideosAreListedAndOtherFilesAreNot() {
        AntsuranceClaimsAssistantPhotos.View view = AntsuranceClaimsAssistantPhotos.getPhotos(claimId());

        Assert.areEqual(3, view.photos.size(), 'Two photographs and a video; the PDF belongs to the documents list');
        Map<String, AntsuranceClaimsAssistantPhotos.PhotoItem> byTitle = new Map<String, AntsuranceClaimsAssistantPhotos.PhotoItem>();
        for (AntsuranceClaimsAssistantPhotos.PhotoItem item : view.photos) {
            byTitle.put(item.title, item);
        }
        AntsuranceClaimsAssistantPhotos.PhotoItem photo = byTitle.get('Rear quarter');
        Assert.areEqual('image', photo.kind);
        Assert.isTrue(photo.assessable, 'A small JPEG can be assessed');
        Assert.isTrue(photo.url.endsWith(String.valueOf(photo.versionId)), 'The browser loads the file by its version');
        Assert.areEqual('png', byTitle.get('Wide shot').extension, 'Extensions are compared in lower case');
        AntsuranceClaimsAssistantPhotos.PhotoItem video = byTitle.get('Walk-around');
        Assert.areEqual('video', video.kind);
        Assert.isFalse(video.assessable, 'Video is shown but not assessed');
        Assert.isTrue(video.whyNot.contains('not assessed yet'), 'And the tile says so');
        Assert.isNull(view.assessment, 'Nothing has been assessed yet');
        Assert.areEqual(0, view.addedSince);
        Assert.areEqual(1, view.batches.size(), 'Two photographs fit one call');
        Assert.areEqual(2, view.batches[0].size(), 'And the video is not in it');
    }

    @IsTest
    static void moreThanOneCallOfPhotosIsSplitIntoBatches() {
        Id caseId = claimId();
        addFourMorePhotos(caseId);

        List<List<Id>> batches = AntsuranceClaimsAssistantPhotos.getPhotos(caseId).batches;

        Assert.areEqual(2, batches.size(), 'Six photographs are two calls');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.MAX_PHOTOS_PER_CALL, batches[0].size(), 'The first is as many as fit');
        Assert.areEqual(2, batches[1].size(), 'The second is the rest');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.TOO_MANY_AT_ONCE, failure('batch too big', caseId), 'All six cannot be sent at once');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.NOT_ON_CLAIM, failure('batch with a file that is not a photo', caseId), 'A file that is not a photo on the claim is refused');
    }

    @IsTest
    static void aBatchAddsItsFindingsToWhatIsAlreadyDone() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id caseId = claimId();
        addFourMorePhotos(caseId);
        storePartial(caseId, 'Xd');
        List<Id> first = AntsuranceClaimsAssistantPhotos.getPhotos(caseId).batches[0];

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.StepResult step = AntsuranceClaimsAssistantPhotos.assessBatch(caseId, first, false, false);
        Test.stopTest();

        Assert.isTrue(step.ok);
        Assert.areEqual(4, mock.request.getBody().countMatches('"type":"image"'), 'One call carries the four photographs of this batch');
        Assert.isFalse(mock.request.getBody().contains('damage_summary'), 'A batch is asked about its photographs only, which keeps the answer short');
        Assert.isFalse(step.assessment.complete, 'The overall read waits until every batch is done');
        Assert.areEqual(3, step.assessment.photos.size(), 'The two photographs Claude reported on join the one kept from before');
        Assert.areEqual('Rear quarter', step.assessment.photos[0].title, 'In the order the photographs are listed');
        Assert.areEqual('Xd', step.assessment.photos[2].title);
        Assert.areEqual(6, step.assessment.photos[2].photoNumber, 'Each numbered by its place on the claim');
        Assert.areEqual(3, step.assessment.photosLeftOut, 'Three are still to do');
        Assert.isNull(step.assessment.damageSummary);
        Assert.isFalse(AntsuranceClaimsAssistantPhotos.stored(caseId).complete, 'And that is what the claim now holds');
    }

    @IsTest
    static void aBatchThatRunsOutOfTimeKeepsWhatIsDone() {
        Test.setMock(HttpCalloutMock.class, new SlowMock());
        Id caseId = claimId();
        addFourMorePhotos(caseId);
        storePartial(caseId, 'Xd');
        List<Id> first = AntsuranceClaimsAssistantPhotos.getPhotos(caseId).batches[0];

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.StepResult step = AntsuranceClaimsAssistantPhotos.assessBatch(caseId, first, false, false);
        Test.stopTest();

        Assert.isFalse(step.ok, 'The failure is returned, not thrown, so the card can show it in place');
        Assert.areEqual('timeout', step.errorKind);
        Assert.isTrue(step.retryable, 'And the same batch can be asked for again');
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, step.error, 'In words for the person on screen');
        AntsuranceClaimsAssistantPhotos.Assessment kept = AntsuranceClaimsAssistantPhotos.stored(caseId);
        Assert.areEqual(1, kept.photos.size(), 'What the earlier batch found is untouched');
        Assert.areEqual('Xd', kept.photos[0].title);
    }

    @IsTest
    static void theOverallReadIsWrittenFromTheBatchesWithoutThePhotos() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id caseId = claimId();
        storePartial(caseId, 'Rear quarter');

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.StepResult step = AntsuranceClaimsAssistantPhotos.finishAssessment(caseId);
        Test.stopTest();

        String sent = mock.request.getBody();
        Assert.areEqual(0, sent.countMatches('"type":"image"'), 'No photographs are sent again');
        Assert.isTrue(sent.contains('Kept from an earlier batch.'), 'Claude writes from what each batch found');
        Assert.isTrue(step.ok);
        Assert.isTrue(step.assessment.complete, 'The assessment is finished');
        Assert.areEqual('consistent', step.assessment.consistency);
        Assert.areEqual(1, step.assessment.photos.size(), 'The per-photo findings are kept as they were');
        Assert.areEqual(1, step.assessment.photosLeftOut, 'And the photo not yet looked at is counted');
    }

    @IsTest
    static void aFinishThatRunsOutOfTimeLeavesTheFindingsInPlace() {
        Test.setMock(HttpCalloutMock.class, new SlowMock());
        Id caseId = claimId();
        storePartial(caseId, 'Rear quarter');

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.StepResult step = AntsuranceClaimsAssistantPhotos.finishAssessment(caseId);
        Test.stopTest();

        Assert.isFalse(step.ok);
        Assert.areEqual('timeout', step.errorKind);
        Assert.isFalse(AntsuranceClaimsAssistantPhotos.stored(caseId).complete, 'Still part way, ready to be finished again');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.NOTHING_TO_FINISH, failure('finish', [SELECT Id FROM Case WHERE Subject = 'A claim with no photos'].Id));
    }

    @IsTest
    static void assessingSendsThePhotosAndStoresWhatClaudeSaw() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id caseId = claimId();

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.Assessment result = AntsuranceClaimsAssistantPhotos.assessPhotos(caseId);
        Test.stopTest();

        String sent = mock.request.getBody();
        Assert.areEqual(2, sent.countMatches('"type":"image"'), 'Both photographs are sent, and the video and the PDF are not');
        Assert.isTrue(sent.contains('Photo 1: \\"Rear quarter\\"'), 'Claude is told which photograph is which');
        Assert.isTrue(sent.contains(CLAIM), 'With the claim file');
        Assert.isTrue(sent.contains('"json_schema"'), 'And asked for a typed answer');

        Assert.areEqual(2, result.photos.size(), 'The entry for a photograph that was never sent is dropped');
        AntsuranceClaimsAssistantPhotos.PhotoRead first = result.photos[0];
        Assert.areEqual([SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Rear quarter'].ContentDocumentId, first.documentId, 'Each read is tied to its file');
        Assert.areEqual(3, first.damage.size(), 'An area with a severity Claude may not use is dropped');
        Assert.isTrue(first.damage[0].box.width == 0.3, 'A box inside the image is kept as given');
        Assert.isTrue(first.damage[1].box.width == 0.2, 'A box running off the edge is cut to fit: ' + first.damage[1].box.width);
        Assert.isTrue(first.damage[1].box.height == 0.1, 'In both directions: ' + first.damage[1].box.height);
        Assert.isNull(first.damage[2].box, 'A box too thin to mean anything is dropped, and the area stays');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.NO_PANEL, first.damage[2].panel, 'An unknown panel becomes none');
        Assert.isFalse(result.photos[1].usable);
        Assert.areEqual('Too dark', result.photos[1].unusableReason);
        Assert.areEqual(1, result.signals.size(), 'Blank entries are dropped');
        Assert.areEqual(2600, result.repairHigh.intValue(), 'The rough range is in whole dollars');
        Assert.areEqual(0, result.repairHigh.scale());
        Assert.areEqual(1, result.suggestions.size(), 'A reserve change with no figure, and a kind this card does not offer, are not shown');
        Assert.areEqual(0, result.photosLeftOut);

        Case claim = [SELECT Photo_Assessment__c, Photo_Assessment_At__c FROM Case WHERE Id = :caseId];
        Assert.isNotNull(claim.Photo_Assessment_At__c, 'The claim records when its photos were assessed');
        Assert.isTrue(claim.Photo_Assessment__c.contains('"consistency":"consistent"'), 'And holds the assessment as JSON');
    }

    @IsTest
    static void aStoredAssessmentIsReturnedWithoutAskingClaudeAgain() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id caseId = claimId();
        Assert.isNull(AntsuranceClaimsAssistantPhotos.stored(caseId), 'Nothing is stored before the first assessment');

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.assessment(caseId, false);
        AntsuranceClaimsAssistantPhotos.Assessment again = AntsuranceClaimsAssistantPhotos.assessment(caseId, false);
        Test.stopTest();

        Assert.areEqual(1, mock.calls, 'The second read comes from the claim');
        Assert.areEqual('photo_estimate', again.nextStep);
        Assert.areEqual('Left rear quarter panel', AntsuranceClaimsAssistantPhotos.stored(caseId).photos[0].damage[0].area, 'Stored in full');

        insert new ContentVersion(Title = 'Later photo', PathOnClient = 'later.jpg', VersionData = Blob.valueOf('jpeg three'), FirstPublishLocationId = caseId);
        // The assessment is stamped a moment ago, so move it back to make the new photo plainly later.
        update new Case(Id = caseId, Photo_Assessment__c = JSON.serialize(backdated(again)));
        AntsuranceClaimsAssistantPhotos.View view = AntsuranceClaimsAssistantPhotos.getPhotos(caseId);
        Assert.areEqual(1, view.addedSince, 'The card can say a photo was added since the assessment');
    }

    private static AntsuranceClaimsAssistantPhotos.Assessment backdated(AntsuranceClaimsAssistantPhotos.Assessment assessment) {
        assessment.assessedAt = Datetime.now().addDays(-1);
        return assessment;
    }

    @IsTest
    static void aClaimWithNoPhotosIsNotSentToClaude() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);
        Id empty = [SELECT Id FROM Case WHERE Subject = 'A claim with no photos'].Id;

        Assert.areEqual(AntsuranceClaimsAssistantPhotos.NO_PHOTOS, failure('assess', empty));
        Assert.areEqual(0, mock.calls);
    }

    @IsTest
    static void aFailureFromClaudeIsShownInWords() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(529, '{"error":{"message":"Overloaded"}}'));

        Test.startTest();
        String message = failure('assess', claimId());
        Test.stopTest();

        Assert.isTrue(message.contains('temporarily unavailable'), 'The handler is told what happened: ' + message);
        Assert.isNull([SELECT Photo_Assessment__c FROM Case WHERE Id = :claimId()].Photo_Assessment__c, 'And nothing is stored');
    }

    @IsTest
    static void aPhotoIsSavedOnTheClaimAndOtherFilesAreRefused() {
        Id caseId = claimId();

        AntsuranceClaimsAssistantPhotos.PhotoItem saved = AntsuranceClaimsAssistantPhotos.savePhoto(caseId, 'Bumper close up.jpg', EncodingUtil.base64Encode(Blob.valueOf('jpeg')));

        Assert.areEqual('Bumper close up', saved.title, 'Titled by its file name');
        Assert.isTrue(saved.assessable);
        Assert.areEqual(4, AntsuranceClaimsAssistantPhotos.getPhotos(caseId).photos.size(), 'It is on the claim');
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.NOT_A_PHOTO, failure('save a pdf', caseId));
        Assert.areEqual(AntsuranceClaimsAssistantPhotos.PHOTO_TOO_LARGE, failure('save too much', caseId));
    }

    @IsTest
    static void aPhotoTooLargeForClaudeIsListedButNotSent() {
        Id caseId = claimId();
        insert new ContentVersion(
            Title = 'Straight from a camera', PathOnClient = 'camera.jpg', FirstPublishLocationId = caseId,
            VersionData = Blob.valueOf('x'.repeat(AntsuranceClaimsAssistantPhotos.MAX_PHOTO_BYTES + 1))
        );

        AntsuranceClaimsAssistantPhotos.PhotoItem large;
        for (AntsuranceClaimsAssistantPhotos.PhotoItem item : AntsuranceClaimsAssistantPhotos.getPhotos(caseId).photos) {
            if (item.title == 'Straight from a camera') {
                large = item;
            }
        }
        Assert.isFalse(large.assessable, 'It is shown');
        Assert.isTrue(large.whyNot.contains('Too large'), 'With the reason it will not be assessed');
    }

    @IsTest
    static void aConfirmedSuggestionIsApplied() {
        Id caseId = claimId();

        String done = AntsuranceClaimsAssistantPhotos.applySuggestion(caseId, AntsuranceClaimsAssistantPhotos.ADD_TASK, null, 'Ask Maya for the VIN plate photo', 'It is missing.');
        Assert.areEqual('Task added.', done);
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :caseId AND Subject = 'Ask Maya for the VIN plate photo']);

        AntsuranceClaimsAssistantPhotos.applySuggestion(caseId, AntsuranceClaimsAssistantPhotos.SET_RESERVE, 2600, null, 'The photos show more than was reserved.');
        Assert.areEqual(2600, [SELECT Reserve_Amount__c FROM Case WHERE Id = :caseId].Reserve_Amount__c.intValue(), 'The reserve moves only on confirmation');
        Assert.isTrue([SELECT Body__c FROM File_Note__c WHERE Case__c = :caseId].Body__c.contains('the claim photos'), 'And a file note says where the figure came from');

        Assert.areEqual(AntsuranceClaimsAssistantPhotos.UNKNOWN_SUGGESTION, failure('flag_fraud', caseId), 'Only the kinds this card offers can be applied');

        AntsuranceClaimsAssistantPhotos.addNote(caseId, 'General', '**Photos:** Two on file.');
        Assert.areEqual(2, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :caseId], 'The note on the photos joins the file');
    }

    @IsTest
    static void samplePhotosCanBeAssessedWithoutAClaim() {
        ClaudeMock mock = new ClaudeMock(200, reply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantPhotos.Assessment result = AntsuranceClaimsAssistantPhotos.assessResources(
            'A parking lot scrape on a 2019 Honda Accord.',
            new List<String>{ 'antsuranceDamageRearQuarter', 'antsuranceDamageHailGlass', 'no such resource' }
        );
        Test.stopTest();

        Assert.areEqual(2, mock.request.getBody().countMatches('"type":"image"'), 'The resources that exist are sent');
        Assert.areEqual(2, result.photos.size());
        Assert.isNull(result.photos[0].documentId, 'No claim file stands behind a sample');
        Assert.areEqual('antsuranceDamageRearQuarter', result.photos[0].title);
    }

    @IsTest
    static void samplePhotosAreAttachedToTheirDemoClaimsOnce() {
        Id caseId = claimId();

        String first = AntsuranceClaimsAssistantPhotos.attachSamplePhotos();
        String second = AntsuranceClaimsAssistantPhotos.attachSamplePhotos();

        Assert.isTrue(first.startsWith('1 sample photos attached'), 'Only the claim that exists here gets its photo: ' + first);
        Assert.isTrue(second.startsWith('0 sample photos attached, 1 already there'), 'Running it again adds nothing: ' + second);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :caseId AND ContentDocument.Title = 'Rear quarter panel, passenger side']);
    }
    @IsTest
    static void anUploadedPhotoGetsATitleAPersonCanRead() {
        Assert.areEqual('Rear bumper after the crash', AntsuranceClaimsAssistantPhotos.photoTitle('Rear bumper after the crash.jpg'), 'Words somebody wrote are kept');
        Assert.isTrue(AntsuranceClaimsAssistantPhotos.photoTitle('antsuranceDamageRearQuarter.jpg').startsWith('Photo added '), 'A system name is replaced');
        Assert.isTrue(AntsuranceClaimsAssistantPhotos.photoTitle('IMG 2041.jpg').startsWith('Photo added '), 'and so is a camera name');
    }
}
