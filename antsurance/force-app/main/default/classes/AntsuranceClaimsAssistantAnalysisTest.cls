@IsTest
private class AntsuranceClaimsAssistantAnalysisTest {
    /** Answers with one canned response, or fails the way a slow call does, and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        String body;
        Boolean timesOut = false;
        HttpRequest request;
        Integer calls = 0;

        ClaudeMock(String body) {
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            calls++;
            this.request = request;
            if (timesOut) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void createClaim() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-1',
            Account__c = customer.Id,
            Primary_Insured__c = person.Id,
            Line_of_Business__c = 'Homeowners',
            Status__c = 'Active',
            Effective_Date__c = start,
            Expiration_Date__c = start.addYears(1),
            Insured_Item__c = '12 Quay St, Evanston, IL',
            Coverage_Limit__c = 500000,
            Deductible__c = 2500
        );
        insert policy;
        insert new Policy_Coverage__c(Name = 'Dwelling', Policy__c = policy.Id, Limit_Amount__c = 500000, Deductible_Amount__c = 2500, What_Is_Covered__c = 'Rebuilds the home after a covered loss.');
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Case claim = new Case(
            RecordTypeId = claimType,
            Subject = 'Burst pipe flooded basement',
            Description = 'A supply line burst while we were away and flooded the finished basement.',
            AccountId = customer.Id,
            ContactId = person.Id,
            Policy__c = policy.Id,
            Status = 'New',
            Severity__c = 'High',
            Loss_Type__c = 'Water Damage',
            Date_of_Loss__c = Date.today().addDays(-5),
            Reported_Date__c = Date.today().addDays(-4),
            Estimated_Loss__c = 48500,
            Reserve_Amount__c = 45000,
            Paid_Amount__c = 5000
        );
        insert claim;
        insert new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Investigation', Body__c = '**Inspection:** A braided supply line failed at the fitting.', Note_Date__c = Datetime.now().addDays(-2), Author_Name__c = 'Marcus Lindahl');
        insert new List<ContentVersion>{
            new ContentVersion(Title = 'Basement after the water', PathOnClient = 'basement.jpg', VersionData = Blob.valueOf('photo'), FirstPublishLocationId = claim.Id),
            new ContentVersion(Title = 'Rebuild estimate', PathOnClient = 'estimate.pdf', VersionData = Blob.valueOf('%PDF-1.4 estimate'), FirstPublishLocationId = claim.Id),
            new ContentVersion(Title = 'Walkthrough', PathOnClient = 'walkthrough.mp4', VersionData = Blob.valueOf('video'), FirstPublishLocationId = claim.Id),
            new ContentVersion(Title = 'Contents list', PathOnClient = 'contents.xlsx', VersionData = Blob.valueOf('sheet'), FirstPublishLocationId = claim.Id)
        };
        insert new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
            Subject = 'Add a driver',
            Policy__c = policy.Id,
            Status = 'New'
        );
    }

    private static Case claim() {
        return [SELECT Id, Reserve_Amount__c, Claude_Analysis__c, Claude_Analysis_At__c FROM Case WHERE Subject = 'Burst pipe flooded basement'];
    }

    private static Id fileNamed(String title) {
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Title = :title LIMIT 1].ContentDocumentId;
    }

    private static Id versionNamed(String title) {
        return [SELECT Id FROM ContentVersion WHERE Title = :title AND IsLatest = TRUE LIMIT 1].Id;
    }

    private static String wrap(Map<String, Object> answer) {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    private static String readingReply() {
        return wrap(
            new Map<String, Object>{
                'document_type' => 'Rebuild estimate',
                'issuer' => 'Northshore Renovation Co.',
                'document_date' => '2026-09-30',
                'match_note' => 'The name and address match the claim.',
                'matches_claim' => 'yes',
                'key_facts' => new List<Object>{ new Map<String, Object>{ 'label' => 'Scope', 'value' => 'Drywall and flooring' } },
                'total_amount' => 27450,
                'summary' => 'A contractor estimate to rebuild the basement. It covers drywall and flooring.',
                'comparison' => 'The estimate is $3,450 over the rebuild line in the reserve.',
                'concerns' => new List<Object>{ 'The furnace is left out.' },
                'suggestions' => new List<Object>(),
                'note_type' => 'Investigation',
                'note' => '**Document:** Rebuild estimate.'
            }
        );
    }

    private static String videoReply() {
        return wrap(
            new Map<String, Object>{
                'shows' => 'A walk through the basement with standing water across the floor. The furniture is soaked.',
                'damage' => new List<Object>{ new Map<String, Object>{ 'area' => 'Carpet', 'severity' => 'severe' } },
                'consistency' => 'check',
                'consistency_note' => 'Silt on the floor is worth confirming against a clean supply line.',
                'usable' => true
            }
        );
    }

    private static String coverageReply() {
        return wrap(
            new Map<String, Object>{
                'findings' => new List<Object>{ new Map<String, Object>{ 'text' => 'Dwelling pays to rebuild after a burst pipe.', 'source' => 'C1' } },
                'responding' => 'C1',
                'verdict' => 'Covered',
                'liability_open' => false,
                'summary' => 'The policy was in force and Dwelling responds.',
                'questions' => new List<Object>{ 'When did you first see water?' },
                'would_change' => new List<Object>()
            }
        );
    }

    private static String reportReply() {
        return wrap(
            new Map<String, Object>{
                'what_happened' => 'A supply line burst on the day of loss. The basement flooded.',
                'evidence' => new List<Object>{
                    new Map<String, Object>{ 'key' => 'E1', 'shows' => 'The basement with soaked furniture.' },
                    new Map<String, Object>{ 'key' => 'E3', 'shows' => 'A $27,450 estimate to rebuild.' }
                },
                'damage' => 'The photo shows soaked furniture and a water line on the wall.',
                'coverage' => 'Dwelling responds to a sudden burst of a supply line.',
                'gaps' => new List<Object>{
                    new Map<String, Object>{ 'kind' => 'evidence_needed', 'text' => 'A photo of the failed fitting is missing.' },
                    new Map<String, Object>{ 'kind' => 'check', 'text' => 'Silt in the photo is worth confirming against a clean supply line.' },
                    new Map<String, Object>{ 'kind' => 'something else', 'text' => 'An unknown kind is treated as a thing to check.' }
                },
                'reserve_lines' => new List<Object>{
                    new Map<String, Object>{ 'label' => 'Mitigation', 'amount' => 9500 },
                    new Map<String, Object>{ 'label' => 'Rebuild estimate', 'amount' => 27450 },
                    new Map<String, Object>{ 'label' => 'Contents', 'amount' => 11500 },
                    new Map<String, Object>{ 'label' => 'A line with no figure', 'amount' => null },
                    // Claude is told to leave a total out and sometimes writes one. Added in, it would double the reserve.
                    new Map<String, Object>{ 'label' => 'PAYABLE', 'amount' => 48450 }
                },
                'reserve_reason' => 'The rebuild estimate is in and is $3,450 over its line.',
                'steps' => new List<Object>{
                    new Map<String, Object>{ 'subject' => 'Approve the rebuild estimate', 'why' => 'It is in and within the limit.' },
                    new Map<String, Object>{ 'subject' => 'Ask for a photo of the failed fitting', 'why' => 'It settles the cause.' }
                },
                'headline' => 'Covered under Dwelling; the estimate is in and the reserve is $3,450 short.'
            }
        );
    }

    /** Puts a photo assessment, a coverage check and one document reading on the claim, as earlier steps would have. */
    private static void storeEarlierSteps(Id claimId) {
        AntsuranceClaimsAssistantPhotos.Assessment photos = new AntsuranceClaimsAssistantPhotos.Assessment();
        photos.assessedAt = Datetime.now();
        photos.damageSummary = 'Soaked furniture and a water line on the wall. The floor is covered in silt.';
        photos.lossSeen = 'Water damage';
        photos.consistency = 'check';
        photos.consistencyNote = 'Silt is worth confirming against a clean supply line.';
        photos.signals = new List<String>{ 'Standing water' };
        photos.repairLow = 3000;
        photos.repairHigh = 8000;
        photos.repairBasis = 'Visible contents only.';
        AntsuranceClaimsAssistantPhotos.PhotoRead read = new AntsuranceClaimsAssistantPhotos.PhotoRead();
        read.documentId = fileNamed('Basement after the water');
        read.photoNumber = 1;
        read.shows = 'A basement room after water.';
        read.usable = true;
        AntsuranceClaimsAssistantPhotos.DamageArea area = new AntsuranceClaimsAssistantPhotos.DamageArea();
        area.area = 'Sofa';
        area.detail = 'Soaked and coated in silt.';
        area.severity = 'severe';
        read.damage.add(area);
        photos.photos.add(read);

        AntsuranceClaimsAssistantCoverage.Check check = new AntsuranceClaimsAssistantCoverage.Check();
        check.exists = true;
        check.verdict = 'Covered';
        check.summary = 'Dwelling responds.';
        check.respondingLabel = 'Dwelling';
        check.respondingKind = 'Coverage';
        check.limitAmount = 500000;
        check.deductible = 2500;
        check.estimate = 48500;
        check.payable = 46000;
        check.writtenAt = Datetime.now();

        AntsuranceClaimsAssistantAnalysis.Stored stored = new AntsuranceClaimsAssistantAnalysis.Stored();
        AntsuranceClaimsAssistantAnalysis.Reading reading = new AntsuranceClaimsAssistantAnalysis.Reading();
        reading.documentId = fileNamed('Rebuild estimate');
        reading.versionId = versionNamed('Rebuild estimate');
        reading.kind = 'document';
        reading.title = 'Rebuild estimate';
        reading.documentType = 'Rebuild estimate';
        reading.issuer = 'Northshore Renovation Co.';
        reading.summary = 'A contractor estimate to rebuild the basement.';
        reading.totalAmount = 27450;
        reading.readAt = Datetime.now();
        stored.readings.add(reading);

        update new Case(
            Id = claimId,
            Photo_Assessment__c = JSON.serialize(photos),
            Photo_Assessment_At__c = photos.assessedAt,
            Coverage_Read__c = JSON.serialize(new Map<String, Object>{ 'check' => check, 'facts' => new Map<String, Object>() }),
            Coverage_Read_At__c = check.writtenAt,
            Coverage_Verdict__c = 'Covered',
            Claude_Analysis__c = JSON.serialize(stored, true)
        );
    }

    @IsTest
    static void theDocketListsEveryKindOfEvidenceAndWhatClaudeCanRead() {
        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claim().Id);

        Assert.areEqual('Harbor Household', docket.customerName, 'The docket names the customer');
        Assert.areEqual('T-HOME-1', docket.policyName, 'And the policy');
        Assert.isNull(docket.report, 'There is no report before a run');
        Map<String, AntsuranceClaimsAssistantAnalysis.Item> byKind = new Map<String, AntsuranceClaimsAssistantAnalysis.Item>();
        Map<String, AntsuranceClaimsAssistantAnalysis.Item> byTitle = new Map<String, AntsuranceClaimsAssistantAnalysis.Item>();
        for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
            byKind.put(item.kind, item);
            byTitle.put(item.title, item);
            Assert.isTrue(item.key.startsWith('E'), 'Every item has a key the report can cite');
        }
        Assert.areEqual(6, docket.items.size(), 'Four files, one file note and the statement');
        Assert.areEqual('photo', byTitle.get('Basement after the water').kind, 'An image is a photo');
        Assert.isNotNull(byTitle.get('Basement after the water').url, 'With somewhere to load it from');
        Assert.areEqual('video', byTitle.get('Walkthrough').kind, 'An mp4 is a video');
        Assert.areEqual('document', byTitle.get('Rebuild estimate').kind, 'A PDF is a document');
        Assert.isTrue(byTitle.get('Rebuild estimate').readable, 'That Claude can read');
        Assert.isFalse(byTitle.get('Contents list').readable, 'A spreadsheet is listed, and said to be unreadable here');
        Assert.isFalse(byTitle.get('Rebuild estimate').looked, 'Nothing has been looked at yet');
        Assert.isTrue(byKind.get('note').lookedLine.startsWith('Inspection: A braided supply line'), 'A file note shows its opening, without Markdown marks');
        Assert.isTrue(byKind.get('statement').lookedLine.contains('supply line burst'), 'The insured\'s statement is evidence too');
        Assert.areEqual(1, docket.photoBatches.size(), 'The photo fits one call');
        Assert.isFalse(docket.photosFresh, 'And has not been assessed');
    }

    @IsTest
    static void aLetterWeApprovedIsNotEvidence() {
        Id claimId = claim().Id;
        Integer before = AntsuranceClaimsAssistantAnalysis.getDocket(claimId).items.size();
        // An approved letter leaves a PDF and a file note on the claim, each marked as the letter's own.
        File_Note__c letterNote = new File_Note__c(Case__c = claimId, Note_Type__c = 'Contact', Note_Date__c = Datetime.now(), Body__c = AntsuranceClaimLetters.NOTE_OPENING + ' Acknowledgment of claim.');
        insert letterNote;
        insert new ContentVersion(
            Title = 'Acknowledgment of claim', PathOnClient = 'letter.pdf', VersionData = Blob.valueOf('%PDF-1.4 letter'), FirstPublishLocationId = claimId,
            Description = AntsuranceClaimLetters.FILE_MARK + letterNote.Id
        );

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claimId);
        Test.stopTest();

        Assert.areEqual(before, docket.items.size(), 'The letter adds nothing to the evidence: it is what we sent, not what came in');
        for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
            Assert.areNotEqual('Acknowledgment of claim', item.title, 'Its PDF is not a document to read');
        }
    }

    @IsTest
    static void aServiceRequestIsRefused() {
        Id requestId = [SELECT Id FROM Case WHERE Subject = 'Add a driver'].Id;
        try {
            AntsuranceClaimsAssistantAnalysis.getDocket(requestId);
            Assert.fail('Expected a refusal');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantAnalysis.NOT_A_CLAIM, e.getMessage(), 'Evidence is analyzed on claims only');
        }
    }

    @IsTest
    static void aDocumentIsReadOnceAndItsReadingKept() {
        Id claimId = claim().Id;
        Id estimate = fileNamed('Rebuild estimate');
        ClaudeMock mock = new ClaudeMock(readingReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult first = AntsuranceClaimsAssistantAnalysis.readDocumentStep(claimId, estimate, false);
        Test.stopTest();

        Assert.isTrue(first.ok, 'The document was read');
        Assert.isFalse(first.reused, 'By asking Claude');
        Assert.areEqual('Rebuild estimate, $27,450: A contractor estimate to rebuild the basement.', first.line, 'The step says what it found in one line');

        // A second run does not pay for the same version of the file again.
        AntsuranceClaimsAssistantAnalysis.StepResult second = AntsuranceClaimsAssistantAnalysis.readDocumentStep(claimId, estimate, false);
        Assert.isTrue(second.reused, 'The stored reading is used');
        Assert.areEqual(1, mock.calls, 'So Claude was asked once');

        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claimId);
        for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
            if (item.documentId == estimate) {
                Assert.isTrue(item.looked, 'The tile says Claude has looked');
                Assert.isTrue(item.lookedLine.startsWith('Rebuild estimate, $27,450'), 'With what it found');
            }
        }
    }

    @IsTest
    static void aVideoIsReadFromFramesSentAsImages() {
        Id claimId = claim().Id;
        Id video = fileNamed('Walkthrough');
        ClaudeMock mock = new ClaudeMock(videoReply());
        Test.setMock(HttpCalloutMock.class, mock);
        String frame = EncodingUtil.base64Encode(Blob.valueOf('a small jpeg'));

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.readVideoStep(claimId, video, new List<String>{ frame, 'data:image/jpeg;base64,' + frame, '' });
        Test.stopTest();

        Assert.isTrue(result.ok, 'The video was read');
        Assert.isTrue(result.line.startsWith('Read from 2 frames: A walk through the basement'), 'The step says how many frames it was read from');
        String sent = mock.request.getBody();
        Assert.areEqual(2, sent.countMatches('"media_type":"image/jpeg"'), 'Each usable frame goes as an image');
        Assert.isTrue(sent.contains('titled \\"Walkthrough\\"'), 'With the video named');

        AntsuranceClaimsAssistantAnalysis.Stored stored = (AntsuranceClaimsAssistantAnalysis.Stored) JSON.deserialize(claim().Claude_Analysis__c, AntsuranceClaimsAssistantAnalysis.Stored.class);
        Assert.areEqual(1, stored.readings.size(), 'The reading is kept with the analysis');
        Assert.areEqual(2, stored.readings[0].frames, 'With its frame count');
        Assert.areEqual('Damage visible: Carpet (severe).', stored.readings[0].comparison, 'And the damage seen');
        Assert.areEqual(1, stored.readings[0].concerns.size(), 'A mismatch is kept as something to check');
    }

    @IsTest
    static void aVideoStepTurnsAwayWhatItCannotUse() {
        Id claimId = claim().Id;
        String frame = EncodingUtil.base64Encode(Blob.valueOf('a small jpeg'));
        Assert.areEqual(
            AntsuranceClaimsAssistantAnalysis.NOT_A_VIDEO,
            AntsuranceClaimsAssistantAnalysis.readVideoStep(claimId, fileNamed('Rebuild estimate'), new List<String>{ frame }).error,
            'A PDF is not a video'
        );
        AntsuranceClaimsAssistantAnalysis.StepResult none = AntsuranceClaimsAssistantAnalysis.readVideoStep(claimId, fileNamed('Walkthrough'), new List<String>());
        Assert.isFalse(none.ok, 'No frames, nothing to look at');
        Assert.areEqual(AntsuranceClaimsAssistantAnalysis.NO_FRAMES, none.error, 'And it says so');
        Assert.areEqual(EncodingUtil.base64Encode(Blob.valueOf('video')), AntsuranceClaimsAssistantAnalysis.videoData(claimId, fileNamed('Walkthrough')), 'The page gets the video to take frames from');
        try {
            AntsuranceClaimsAssistantAnalysis.videoData(claimId, fileNamed('Rebuild estimate'));
            Assert.fail('Expected a refusal');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantAnalysis.NOT_A_VIDEO, e.getMessage(), 'Only a video is handed over');
        }
    }

    @IsTest
    static void coverageIsCheckedAgainstWhatTheEvidenceShowed() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        // The stored check was written before the evidence was read, so it is checked again with the evidence.
        ClaudeMock mock = new ClaudeMock(coverageReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.checkCoverageStep(claimId, false);
        Test.stopTest();

        Assert.isTrue(result.ok, 'Coverage was checked');
        Assert.areEqual('Covered under Dwelling, $46,000 payable.', result.line, 'The step gives the verdict in one line');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('Soaked furniture and a water line on the wall'), 'What the photos showed goes in as facts');
        Assert.isTrue(sent.contains('Rebuild estimate \\"Rebuild estimate\\" from Northshore Renovation Co., total $27,450'), 'So does each document read');
    }

    /** Replaces the check on the claim with one the coverage agent reached, written now and confirmed by the adjuster. */
    private static void storeAgentFindingAndConfirm(Id claimId) {
        AntsuranceClaimsAssistantCoverage.Facts facts = AntsuranceClaimsAssistantCoverage.factsFor(claimId);
        // What the agent took into account, in its own words: never the text the analysis builds from its own readings.
        AntsuranceClaimsAssistantCoverage.withExtra(facts, 'Rebuild estimate: a contractor estimate for drywall and flooring.\nWhat the photos show: soaked furniture coated in silt.');
        AntsuranceClaimsAssistantCoverage.Check finding = AntsuranceClaimsAssistantCoverage.checkFrom(
            new Map<String, Object>{
                'findings' => new List<Object>{ new Map<String, Object>{ 'text' => 'The silt points to outside water.', 'source' => 'EXTRA' } },
                'responding' => 'C1',
                'verdict' => 'Needs review',
                'summary' => 'Dwelling would respond once the source of the water is settled.'
            },
            facts
        );
        AntsuranceClaimsAssistantCoverage.store(
            claimId,
            finding,
            facts,
            new Map<String, Object>{ AntsuranceClaimsAssistantCoverage.AGENT_PART => new Map<String, Object>{ 'harness' => 'Claude Managed Agents', 'run' => new Map<String, Object>{ 'sessionId' => 'sesn_01TestSession1' } } }
        );
        AntsuranceClaimsAssistantCoverage.confirm(claimId);
    }

    /** Moves the stored photo assessment to another moment, as if the photographs had been assessed then. */
    private static void assessPhotosAt(Id claimId, Datetime moment) {
        AntsuranceClaimsAssistantPhotos.Assessment photos = AntsuranceClaimsAssistantPhotos.stored(claimId);
        photos.assessedAt = moment;
        update new Case(Id = claimId, Photo_Assessment__c = JSON.serialize(photos), Photo_Assessment_At__c = moment);
    }

    @IsTest
    static void theAnalysisKeepsTheAgentsConfirmedFinding() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        // The photographs were assessed before the agent ran, so the agent had what they show.
        assessPhotosAt(claimId, Datetime.now().addMinutes(-30));
        storeAgentFindingAndConfirm(claimId);
        ClaudeMock mock = new ClaudeMock(coverageReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.checkCoverageStep(claimId, false);
        Test.stopTest();

        Assert.isTrue(result.ok, 'The step went through');
        Assert.isTrue(result.reused, 'With the agent\'s finding, as it stands');
        Assert.areEqual(0, mock.calls, 'Claude was not asked again, though the analysis words its evidence differently');
        Assert.areEqual('Needs review under Dwelling, $46,000 payable.', result.line, 'The line is the agent\'s verdict');
        Case kept = [SELECT Coverage_Read__c, Coverage_Verdict__c, Coverage_Confirmed_By__c, Coverage_Confirmed_At__c FROM Case WHERE Id = :claimId];
        Assert.areEqual('Needs review', kept.Coverage_Verdict__c, 'The finding is still on the claim');
        Assert.isNotNull(kept.Coverage_Confirmed_At__c, 'With the adjuster\'s confirmation');
        Assert.areEqual(UserInfo.getName(), kept.Coverage_Confirmed_By__c, 'And their name');
        Assert.isTrue(kept.Coverage_Read__c.contains('"sessionId":"sesn_01TestSession1"'), 'And how the agent worked beside it');
    }

    @IsTest
    static void theAnalysisSaysSoWhenItReplacesAConfirmedCheck() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        storeAgentFindingAndConfirm(claimId);
        // The photographs are assessed again after the agent ran: evidence its finding never had.
        assessPhotosAt(claimId, Datetime.now().addMinutes(30));
        ClaudeMock mock = new ClaudeMock(coverageReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.checkCoverageStep(claimId, false);
        Test.stopTest();

        Assert.isFalse(result.reused, 'New photographs are evidence the agent\'s finding never had, so coverage is checked again');
        Assert.areEqual(1, mock.calls, 'By asking Claude once');
        Assert.areEqual('Covered under Dwelling, $46,000 payable. This replaces the check ' + UserInfo.getName() + ' confirmed, so it needs confirming again.', result.line, 'And the person is told the confirmation went with it');
        Assert.isNull([SELECT Coverage_Confirmed_At__c FROM Case WHERE Id = :claimId].Coverage_Confirmed_At__c, 'Which it did');
    }

    @IsTest
    static void theReportBringsThePartsTogetherAndItsArithmeticHolds() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        ClaudeMock mock = new ClaudeMock(reportReply());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.writeReportStep(claimId);
        Test.stopTest();

        Assert.isTrue(result.ok, 'The report was written');
        AntsuranceClaimsAssistantAnalysis.Report report = result.report;
        Assert.areEqual(result.line, report.headline, 'The step shows the headline');
        Assert.areEqual(48450, report.reserveRecommended, 'The recommended reserve is the lines added up here, not a figure from Claude');
        Assert.areEqual(3, report.reserveLines.size(), 'A line with no figure is dropped, and so is a line that only restates the total');
        Assert.areEqual(45000, report.reserveNow, 'Beside the reserve now');
        Assert.areEqual('Covered', report.check.verdict, 'The coverage check is carried in the report');
        Assert.areEqual(46000, report.check.payable, 'With what is payable');
        Assert.areEqual(6, report.evidence.size(), 'Every item on the docket is listed');
        Assert.areEqual('The basement with soaked furniture.', report.evidence[0].shows, 'With Claude\'s line where it gave one');
        Boolean unreadableSaid = false;
        for (AntsuranceClaimsAssistantAnalysis.EvidenceLine line : report.evidence) {
            if (line.title == 'Contents list') {
                unreadableSaid = !line.readable && line.shows.startsWith('Not read');
            }
        }
        Assert.isTrue(unreadableSaid, 'And what could not be read is said plainly');
        Assert.areEqual(1, report.damageAreas.size(), 'The damage comes from the photo assessment');
        Assert.areEqual('check', report.consistency, 'So does whether it fits the reported loss');
        Assert.areEqual(3, report.gaps.size(), 'The gaps are kept');
        Assert.areEqual('check', report.gaps[2].kind, 'An unknown kind of gap is a thing to check');
        Assert.areEqual(2, report.steps.size(), 'And the next steps');

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('[E1] JPG photo'), 'Each piece of evidence goes under its key');
        Assert.isTrue(sent.contains('Rebuild estimate from Northshore Renovation Co., total $27,450'), 'With what its reading found');
        Assert.isTrue(sent.contains('Verdict: Covered'), 'The coverage check goes in');
        Assert.isTrue(
            sent.contains('PAYABLE: $46,000 (the $48,500 estimate less the $2,500 deductible). RESERVE: $45,000, which is $1,000 below the payable amount.'),
            'The reserve is measured against the estimate less the deductible, with the sum worked out'
        );
        Assert.isTrue(sent.contains('HOW TO READ THE RESERVE'), 'Under the reserve rule every writer shares');
        Assert.isTrue(sent.contains(AntsuranceClaimRules.AMERICAN_ENGLISH), 'In American English');
        Assert.isTrue(sent.contains('"enum":["E1","E2","E3","E4","E5","E6"]'), 'And Claude may cite only the evidence it was given');

        Case saved = claim();
        Assert.isNotNull(saved.Claude_Analysis_At__c, 'The report is stored with when it was written');
        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claimId);
        Assert.isFalse(docket.report.stale, 'A report just written is current');

        update new Case(Id = claimId, Estimated_Loss__c = 52000);
        insert new File_Note__c(Case__c = claimId, Note_Type__c = 'Contact', Body__c = 'Called the insured.', Note_Date__c = Datetime.now());
        docket = AntsuranceClaimsAssistantAnalysis.getDocket(claimId);
        Assert.isTrue(docket.report.stale, 'It is out of date once the claim changes');
        Assert.isTrue(docket.report.changes.contains('The estimate changed'), 'And says what changed');
        Assert.isTrue(docket.report.changes.contains('A file note was added'), 'Including new evidence');
    }

    @IsTest
    static void aStepThatTimesOutKeepsWhatIsDoneAndCanBeTriedAgain() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        ClaudeMock mock = new ClaudeMock(reportReply());
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.writeReportStep(claimId);
        Test.stopTest();

        Assert.isFalse(result.ok, 'The step did not finish');
        Assert.areEqual('timeout', result.errorKind, 'Because it ran out of time');
        Assert.isTrue(result.retryable, 'So it can be tried again');
        Assert.isTrue(result.error.contains('two-minute limit'), 'And the message is the plain one');
        AntsuranceClaimsAssistantAnalysis.Stored stored = (AntsuranceClaimsAssistantAnalysis.Stored) JSON.deserialize(claim().Claude_Analysis__c, AntsuranceClaimsAssistantAnalysis.Stored.class);
        Assert.areEqual(1, stored.readings.size(), 'The reading from an earlier step is still there');
        Assert.isNull(stored.report, 'And no half-written report was stored');
    }

    @IsTest
    static void aDocumentReadThatTimesOutIsReportedInPlace() {
        Id claimId = claim().Id;
        ClaudeMock mock = new ClaudeMock(readingReply());
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.StepResult result = AntsuranceClaimsAssistantAnalysis.readDocumentStep(claimId, fileNamed('Rebuild estimate'), false);
        Test.stopTest();

        Assert.isFalse(result.ok, 'The read did not finish');
        Assert.areEqual('timeout', result.errorKind, 'It is told apart as a timeout');
        Assert.isTrue(result.retryable, 'And can be tried again');
        Assert.isNull(claim().Claude_Analysis__c, 'Nothing was stored');
    }

    @IsTest
    static void actingOnTheReportHappensOnlyOnAPress() {
        Id claimId = claim().Id;
        storeEarlierSteps(claimId);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(reportReply()));
        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.writeReportStep(claimId);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE WhatId = :claimId AND Subject = 'Approve the rebuild estimate'], 'Writing the report adds no tasks');
        Assert.areEqual(45000, claim().Reserve_Amount__c, 'And leaves the reserve alone');

        Assert.areEqual('Task added.', AntsuranceClaimsAssistantAnalysis.addTasks(claimId, new List<String>{ 'Approve the rebuild estimate', '' }), 'One chosen step becomes one task');
        Task added = [SELECT Subject, Description, ActivityDate, OwnerId FROM Task WHERE WhatId = :claimId AND Subject = 'Approve the rebuild estimate'];
        Assert.areEqual('It is in and within the limit.', added.Description, 'And why as its description');
        Assert.areEqual(UserInfo.getUserId(), added.OwnerId, 'Assigned to the person who pressed');
        Assert.isTrue(AntsuranceClaimsAssistantAnalysis.getDocket(claimId).openTasks.contains('approve the rebuild estimate'), 'The docket says the step is now on the task list');
        try {
            AntsuranceClaimsAssistantAnalysis.addTasks(claimId, new List<String>{ 'Approve the rebuild estimate' });
            Assert.fail('Expected a refusal');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantAnalysis.ALREADY_TASKS, e.getMessage(), 'A step that is already a task is not added twice');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :claimId AND Subject = 'Approve the rebuild estimate'], 'Still one task');
        try {
            AntsuranceClaimsAssistantAnalysis.addTasks(claimId, new List<String>());
            Assert.fail('Expected a refusal');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantAnalysis.NO_TASKS, e.getMessage(), 'Nothing chosen, nothing added');
        }

        Assert.areEqual('Reserve set to $48,450.', AntsuranceClaimsAssistantAnalysis.setReserve(claimId), 'The reserve is set to the recommendation');
        Assert.areEqual(48450, claim().Reserve_Amount__c, 'On the claim');
        Integer notes = [SELECT COUNT() FROM File_Note__c WHERE Case__c = :claimId];
        Assert.areEqual(2, notes, 'With a file note saying why');

        Assert.areEqual('Added to the file notes.', AntsuranceClaimsAssistantAnalysis.addToNotes(claimId), 'The report goes into the file notes');
        Boolean found = false;
        for (File_Note__c note : [SELECT Body__c FROM File_Note__c WHERE Case__c = :claimId]) {
            found = found || (note.Body__c.startsWith('**Claim analysis:**') && note.Body__c.contains('**Coverage:** Covered under Dwelling, $46,000 payable on the estimate.'));
        }
        Assert.isTrue(found, 'As labeled points');
        File_Note__c kept = [SELECT Author_Name__c, Note_Type__c, Policy__c, Account__c FROM File_Note__c WHERE Case__c = :claimId AND Author_Name__c LIKE 'Claude%'];
        Assert.isTrue(kept.Author_Name__c.startsWith('Claude, saved by '), 'The note says it is Claude\'s analysis and who kept it');
        Integer before = [SELECT COUNT() FROM File_Note__c WHERE Case__c = :claimId];
        Assert.areEqual('The earlier analysis note was replaced with this one.', AntsuranceClaimsAssistantAnalysis.addToNotes(claimId), 'Saving again replaces the earlier analysis note');
        Assert.areEqual(before, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :claimId], 'so the file never holds two of Claude\'s conclusions');
        Assert.isNotNull(kept.Policy__c, 'It is filed under the policy too');
        Assert.isNotNull(kept.Account__c, 'And the customer');

        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claimId);
        for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
            Assert.isFalse(item.lookedLine != null && item.lookedLine.startsWith('Claim analysis'), 'Claude\'s own saved report is not listed as evidence');
        }
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.read(claimId).stale != true, 'And it does not make the coverage check out of date');
        Assert.isFalse(docket.report.stale, 'Changes made from the report do not make it out of date');
        Assert.areEqual(48450, docket.report.reserveNow, 'And the report shows the reserve as it now is');
    }

    @IsTest
    static void theReportAsAFileNoteIsLabelledPoints() {
        AntsuranceClaimsAssistantAnalysis.Report report = new AntsuranceClaimsAssistantAnalysis.Report();
        report.headline = 'Covered; the reserve is short.';
        report.reserveRecommended = 48450;
        report.reserveNow = 45000;
        report.reserveReason = 'The estimate is in.';
        AntsuranceClaimsAssistantAnalysis.NextStep step = new AntsuranceClaimsAssistantAnalysis.NextStep();
        step.subject = 'Approve the rebuild estimate';
        report.steps.add(step);
        String note = AntsuranceClaimsAssistantAnalysis.noteFor(report);
        Assert.isTrue(note.startsWith('**Claim analysis:** Covered; the reserve is short.'), 'The headline leads');
        Assert.isTrue(note.contains('**Reserve:** $48,450 recommended against $45,000 now. The estimate is in.'), 'The reserve is a point of its own');
        Assert.isTrue(note.contains('**Where to start:** Approve the rebuild estimate.'), 'So are the next steps');
        Assert.areEqual('-$2,500', AntsuranceClaimsAssistantAnalysis.money(-2500), 'A sum taken off reads as one');
    }

    @IsTest
    static void aNoteWithAListReadsAsOneLine() {
        String body = '**Reserve set at $45,000:**\n- Mitigation and drying $9,500\n- Rebuild $24,000\n- Furnace $5,500';
        Assert.areEqual(
            'Reserve set at $45,000: Mitigation and drying $9,500, Rebuild $24,000, Furnace $5,500',
            AntsuranceClaimsAssistantAnalysis.plain(body),
            'The list reads as a list, with no dashes left in the line'
        );
        Assert.areEqual('First notice: Chinedu called.', AntsuranceClaimsAssistantAnalysis.plain('**First notice:** Chinedu called.'), 'A plain note is only unmarked');
        Assert.areEqual('', AntsuranceClaimsAssistantAnalysis.plain(null), 'Nothing in, nothing out');
    }

    @IsTest
    static void thePayableLineComesFromTheCoverageCheck() {
        Case claim = new Case(Estimated_Loss__c = 47500, Reserve_Amount__c = 45000);
        Assert.isTrue(
            AntsuranceClaimsAssistantAnalysis.payableLine(claim, null).contains('Coverage has not been checked'),
            'Without a check, no deductible is assumed'
        );

        AntsuranceClaimsAssistantCoverage.Check check = new AntsuranceClaimsAssistantCoverage.Check();
        check.exists = true;
        check.verdict = 'Covered';
        check.respondingLabel = 'Dwelling';
        check.estimate = 47500;
        check.deductible = 2500;
        check.limitAmount = 485000;
        check.payable = 45000;
        String covered = AntsuranceClaimsAssistantAnalysis.payableLine(claim, check);
        Assert.isTrue(covered.contains('PAYABLE: $45,000 (the $47,500 estimate less the $2,500 deductible)'), covered);
        Assert.isTrue(covered.contains('equal to the payable amount, so the reserve covers it'), 'The deductible is not a shortfall: ' + covered);

        check.verdict = 'Not covered';
        check.payable = 0;
        Assert.isTrue(AntsuranceClaimsAssistantAnalysis.payableLine(claim, check).startsWith('PAYABLE: $0 on the coverage check as it stands (Not covered)'), 'Nothing payable is said as nothing');

        check.payable = null;
        Assert.isTrue(AntsuranceClaimsAssistantAnalysis.payableLine(claim, check).contains('does not give a payable amount'), 'A figure the check withheld is not worked out here');
    }
}
