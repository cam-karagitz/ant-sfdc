@IsTest
private class AntsuranceDeskControllerTest {
    private static Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
    private static Id saleType = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId();

    /**
     * Answers every request with one canned reply that carries the fields of each kind of work
     * (a brief, a memo, a renewal note, a reserve review, a follow-up), and counts the calls.
     */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        Integer calls = 0;
        /** When set, Claude does not answer in time. */
        Boolean timesOut = false;
        /** The reserve Claude proposes in a reserve review. */
        Decimal reserveFromClaude = 49200;

        public HttpResponse respond(HttpRequest request) {
            calls++;
            if (timesOut) {
                CalloutException slow = new CalloutException();
                slow.setMessage('Read timed out');
                throw slow;
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            List<Object> points = new List<Object>{ new Map<String, Object>{ 'label' => 'Premium change', 'detail' => 'Up $90 to $1,820.' } };
            String reply = JSON.serialize(
                new Map<String, Object>{
                    // a brief
                    'standing' => 'The basement is drying and the estimate is in.',
                    'coverage' => 'The homeowners policy responds to a sudden burst.',
                    'money' => 'The estimate is above the reserve.',
                    'watch' => new List<Object>{ new Map<String, Object>{ 'label' => 'Reserve', 'level' => 'high', 'text' => 'The reserve is short of the estimate.' } },
                    'next_actions' => new List<Object>{ new Map<String, Object>{ 'action' => 'Review the rebuild estimate', 'reason' => 'It sets the reserve.' } },
                    'headline' => 'Review the estimate and lift the reserve.',
                    // a memo
                    'recommendation' => 'Approve with conditions',
                    'points' => points,
                    'conditions' => new List<Object>{ 'Roof inspection within 30 days' },
                    'questions' => new List<Object>(),
                    // a renewal note
                    'risk' => 'Medium',
                    'riskReason' => 'A small increase after a paid claim.',
                    'subject' => 'Your home insurance renews soon',
                    'body' => 'Hi Hana,\n\nYour policy renews soon.\n\nSam\nAntsurance',
                    'callOpening' => 'Hi Hana, I am calling about your renewal.',
                    // a reserve review
                    'factors' => new List<Object>{
                        new Map<String, Object>{ 'label' => 'Invoice received', 'detail' => 'The mitigation invoice of $4,200 is on the file and is not in the estimate.' },
                        new Map<String, Object>{ 'label' => 'Paid to date', 'detail' => '$5,000 has gone out as an advance.' }
                    },
                    'new_reserve' => reserveFromClaude,
                    'reason' => 'The estimate and the mitigation invoice together come to more than the reserve.',
                    // a follow-up
                    'task_subject' => 'Call the Quays about their auto quote',
                    'note' => 'Two options have been out for 20 days. Ask which they prefer.',
                    'email_subject' => 'Your auto quote',
                    'email_body' => 'Hi Maya,\n\nWhich option suits you?\n\nSam\nAntsurance'
                }
            );
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => reply } }
                    }
                )
            );
            return response;
        }
    }

    /** One of everything a shift looks for: a claim with no brief and a short reserve, a renewal, a referred quote, and a quote left waiting. */
    @TestSetup
    static void createTheBook() {
        // The desk reads and writes its rows as the user, so the user needs the desk's permission set.
        PermissionSet desk = [SELECT Id FROM PermissionSet WHERE Name = 'Antsurance_Desk'];
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :desk.Id] == 0) {
            System.runAs(new User(Id = UserInfo.getUserId())) {
                insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = desk.Id);
            }
        }
        Account household = new Account(Name = 'Quay Household', Customer_Segment__c = 'Personal Lines');
        insert household;
        Contact insured = new Contact(FirstName = 'Maya', LastName = 'Quay', AccountId = household.Id, Email = 'maya@example.com', Preferred_Contact_Method__c = 'Email');
        insert insured;
        Date today = Date.today();
        Policy__c home = new Policy__c(
            Name = 'T-HOME-1', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Pending Renewal',
            Effective_Date__c = today.addDays(-345), Expiration_Date__c = today.addDays(20), Annual_Premium__c = 1730, Coverage_Limit__c = 500000, Deductible__c = 2500,
            Insured_Item__c = '12 Quay St, Evanston, IL', Billing_Frequency__c = 'Annual', Payment_Status__c = 'Paid in Full'
        );
        Policy__c auto = new Policy__c(
            Name = 'T-AUTO-1', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
            Effective_Date__c = today.addDays(-100), Expiration_Date__c = today.addDays(265), Annual_Premium__c = 1800
        );
        insert new List<Policy__c>{ home, auto };
        insert new Policy_Coverage__c(Policy__c = home.Id, Name = 'Dwelling', Category__c = 'Dwelling', Premium_Amount__c = 1730, Status__c = 'Active', Limit_Amount__c = 500000);

        insert new Case(
            RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Description = 'A supply line burst.', AccountId = household.Id, Policy__c = home.Id, Status = 'New',
            Severity__c = 'High', Loss_Type__c = 'Water Damage', Date_of_Loss__c = today.addDays(-5), Reported_Date__c = today.addDays(-4), Estimated_Loss__c = 48500,
            Reserve_Amount__c = 45000, Paid_Amount__c = 5000
        );

        Opportunity renewal = new Opportunity(
            Name = 'Quay Household - Homeowners renewal', AccountId = household.Id, Policy__c = home.Id, Type = 'Renewal', StageName = 'Quote Issued', Amount = 1820,
            CloseDate = today.addDays(15), Line_of_Business__c = 'Homeowners', RecordTypeId = saleType
        );
        Opportunity waiting = new Opportunity(
            Name = 'Quay Household - Umbrella', AccountId = household.Id, Type = 'Cross-Sell', StageName = 'Quote Issued', Amount = 440, CloseDate = today.addDays(10),
            Line_of_Business__c = 'Umbrella', RecordTypeId = saleType
        );
        Opportunity referred = new Opportunity(
            Name = 'Quay Household - Second home', AccountId = household.Id, Type = 'Cross-Sell', StageName = 'Underwriting Review', CloseDate = today.addDays(20),
            Line_of_Business__c = 'Homeowners', RecordTypeId = saleType
        );
        insert new List<Opportunity>{ renewal, waiting, referred };
        Quote draft = new Quote(Name = 'Standard deductible', OpportunityId = referred.Id, Status = 'Draft');
        insert new List<Quote>{
            new Quote(Name = 'Standard limit', OpportunityId = waiting.Id, Status = 'Presented', Annual_Premium__c = 440, Issued_Date__c = today.addDays(-20), ExpirationDate = today.addDays(10)),
            new Quote(Name = 'Lower limit', OpportunityId = waiting.Id, Status = 'Presented', Annual_Premium__c = 308, Issued_Date__c = today.addDays(-20), ExpirationDate = today.addDays(10)),
            draft
        };
        // An old roof sends the draft to underwriting.
        AntsuranceQuoteConfigurator.saveConfiguration(draft.Id, '{"roofAge":"over20"}', 'Phone', false, null);
    }

    private static Case claim() {
        return [SELECT Id, Claude_Brief__c, Claude_Brief_At__c, Reserve_Amount__c FROM Case WHERE RecordTypeId = :claimType LIMIT 1];
    }

    private static void setAutonomy(Schema.SObjectField field, String mode) {
        Claude_Autonomy__c setting = new Claude_Autonomy__c(SetupOwnerId = UserInfo.getOrganizationId());
        setting.put(field, mode);
        insert setting;
    }

    private static AntsuranceDeskShift.Step step(AntsuranceDeskShift.Plan plan, String kind) {
        for (AntsuranceDeskShift.Step step : plan.steps) {
            if (step.kind == kind) {
                return step;
            }
        }
        return null;
    }

    @IsTest
    static void aShiftFindsOneOfEachKindOfWork() {
        Test.startTest();
        AntsuranceDeskShift.Plan plan = AntsuranceDeskController.planShift();
        Test.stopTest();

        Assert.areEqual(5, plan.pieceCount, 'A brief, a renewal note, a memo, a reserve and a follow-up');
        Assert.areEqual('Briefing 1 open claim', step(plan, AntsuranceDeskShift.BRIEF).label, 'The step says what it is doing');
        Assert.areEqual('Drafting 1 renewal note', step(plan, AntsuranceDeskShift.OUTREACH).label, 'The pending renewal inside 30 days');
        Assert.areEqual('Writing 1 underwriting memo', step(plan, AntsuranceDeskShift.MEMO).label, 'The referred quote with no memo');
        Assert.areEqual('Reviewing 1 reserve', step(plan, AntsuranceDeskShift.RESERVE).label, 'The estimate is above the reserve');
        AntsuranceDeskShift.Step followUp = step(plan, AntsuranceDeskShift.FOLLOW_UP);
        Assert.areEqual(1, followUp.items.size(), 'Two options on one sale make one follow-up');
        Assert.areEqual('Quay Household - Umbrella', followUp.items[0].name, 'It is for the sale');
        Assert.isNull(plan.leftOver, 'Everything fits in one shift');
    }

    @IsTest
    static void aKindSwitchedOffIsLeftOutOfTheShift() {
        setAutonomy(Claude_Autonomy__c.Quote_Follow_Up__c, AntsuranceDeskShift.OFF);

        Test.startTest();
        AntsuranceDeskShift.Plan plan = AntsuranceDeskController.planShift();
        Test.stopTest();

        Assert.isNull(step(plan, AntsuranceDeskShift.FOLLOW_UP), 'No follow-ups are prepared');
        Assert.areEqual(new List<String>{ 'Quote follow-up' }, plan.switchedOff, 'The plan says which kind is off');
        Assert.areEqual(4, plan.pieceCount, 'The rest of the shift goes ahead');
        try {
            AntsuranceDeskController.preparePiece(AntsuranceDeskShift.FOLLOW_UP, [SELECT Id FROM Opportunity WHERE Name = 'Quay Household - Umbrella'].Id, 'Quay Household - Umbrella');
            Assert.fail('A switched-off kind cannot be prepared');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('switched off'), 'The error says why');
        }
    }

    @IsTest
    static void aBriefIsStoredOnTheClaimAndReported() {
        ClaudeMock claude = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, claude);

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.BRIEF, claim().Id, 'the record');
        Test.stopTest();

        Assert.areEqual(1, claude.calls, 'One call to Claude for one piece');
        Assert.areEqual(AntsuranceDeskShift.DONE, piece.status, 'A brief advises and changes nothing, so Claude does it and reports');
        Assert.areEqual('Brief on Burst pipe flooded basement', piece.title, 'The title says what was done');
        Assert.areEqual('This open claim had no brief.', piece.reason, 'And why');
        Assert.isTrue(String.isNotBlank(claim().Claude_Brief__c), 'The brief is on the claim');
        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(piece.work);
        Assert.areEqual('Review the estimate and lift the reserve.', work.get('headline'), 'The desk shows the headline');
        Assert.areEqual(new List<Object>{ 'Review the rebuild estimate' }, (List<Object>) work.get('nextActions'), 'And the next steps');

        AntsuranceDeskController.Desk desk = AntsuranceDeskController.getDesk();
        Assert.isTrue(desk.waiting.isEmpty(), 'Nothing waits for a person');
        Assert.areEqual(1, desk.log.size(), 'The log shows what Claude did');
        // The claim is as it was when the brief was written, so the next shift leaves it alone.
        Assert.isNull(step(AntsuranceDeskShift.plan(), AntsuranceDeskShift.BRIEF), 'It is not briefed again until it changes');
    }

    @IsTest
    static void aBriefPreparedForApprovalLeavesTheClaimAloneUntilApproved() {
        setAutonomy(Claude_Autonomy__c.Claim_Brief__c, AntsuranceDeskShift.APPROVE);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.BRIEF, claim().Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.WAITING, piece.status, 'It waits for a person');
        Assert.isTrue(String.isBlank(claim().Claude_Brief__c), 'The claim has no brief yet');
        Assert.areEqual(1, AntsuranceDeskController.summary().waiting, 'Home counts it');
        Assert.areEqual('Brief on Burst pipe flooded basement', AntsuranceDeskController.summary().topTitle, 'And names it');

        AntsuranceDeskController.Desk desk = AntsuranceDeskController.approve(piece.workId, null);

        Assert.isTrue(claim().Claude_Brief__c.contains('Review the estimate and lift the reserve.'), 'Approving stores the brief on the claim');
        Assert.isTrue(desk.waiting.isEmpty(), 'Nothing waits any more');
        Assert.areEqual(AntsuranceDeskShift.APPROVED, desk.log[0].status, 'The log shows the approval');
        Assert.areEqual('Brief stored on the claim.', desk.log[0].note, 'And what it did');
        Assert.areEqual(UserInfo.getName(), desk.log[0].decidedBy, 'And who decided');
        try {
            AntsuranceDeskController.approve(piece.workId, null);
            Assert.fail('A piece is decided once');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already been decided'), 'The error says so');
        }
    }

    @IsTest
    static void aMemoIsStoredOnTheReferredQuote() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Quote referred = [SELECT Id FROM Quote WHERE Needs_Underwriting_Review__c = TRUE];

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.MEMO, referred.Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.DONE, piece.status, 'A memo advises; the underwriter still decides');
        Assert.areEqual('Underwriting memo on Quay Household - Second home', piece.title, 'It names the sale');
        Assert.isTrue([SELECT Underwriting_Memo__c FROM Quote WHERE Id = :referred.Id].Underwriting_Memo__c.contains('Approve with conditions'), 'The memo is on the quote');
        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(piece.work);
        Assert.areEqual('Approve with conditions', work.get('recommendation'), 'The desk shows the recommendation');
    }

    @IsTest
    static void aRenewalNoteWaitsAndKeepsThePersonsEdits() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Policy__c renewing = [SELECT Id FROM Policy__c WHERE Name = 'T-HOME-1'];

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.OUTREACH, renewing.Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.WAITING, piece.status, 'Anything that goes to a customer waits for a person');
        Assert.areEqual('Renewal note for Quay Household, Homeowners', piece.title, 'It names the customer and the line');
        Assert.isTrue(piece.reason.endsWith('and the renewal offer is out with no answer yet.'), 'A quote issued on the renewal sale means the offer is out: ' + piece.reason);
        Assert.isTrue(piece.reason.contains('in 20 days'), 'The reason gives the days left: ' + piece.reason);
        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(piece.work);
        Assert.areEqual('maya@example.com', work.get('toEmail'), 'The email goes to the named insured');
        Assert.areEqual(1820, AntsuranceAiClient.toDecimal(work.get('renewalPremium')).intValue(), 'With the renewal premium');

        AntsuranceDeskController.Desk desk = AntsuranceDeskController.approve(piece.workId, '{"subject":"Your renewal, Maya"}');

        Assert.areEqual('Opened in the email composer. Nothing is sent until you send it.', desk.log[0].note, 'Approving records that the composer was opened');
        Assert.areEqual('Your renewal, Maya', ((Map<String, Object>) JSON.deserializeUntyped(desk.log[0].work)).get('subject'), 'The edit is kept');
    }

    /**
     * A reserve review waiting on the desk, as an earlier shift left it. Tests that go on to change
     * records start from this row: a test cannot save and then call Claude in the same transaction.
     */
    private static Id waitingReserveReview() {
        Case found = [SELECT Id, Subject, LastModifiedDate FROM Case WHERE RecordTypeId = :claimType LIMIT 1];
        Claude_Work__c row = new Claude_Work__c(
            Kind__c = 'Reserve review', Status__c = AntsuranceDeskShift.WAITING, Authority__c = AntsuranceDeskShift.APPROVE, Record_Object__c = 'Case',
            Record_Id__c = found.Id, Record_Name__c = found.Subject, Title__c = found.Subject + ': raise the reserve by $1,000',
            Reason__c = '$48,500 estimate less the $2,500 deductible is $46,000 payable. The reserve is $45,000, $1,000 short.',
            Work__c = JSON.serialize(
                new Map<String, Object>{ 'oldReserve' => 45000, 'newReserve' => 46000, 'estimate' => 48500, 'deductible' => 2500, 'payable' => 46000, 'paid' => 5000, 'shortBy' => 1000 }
            ),
            Record_Stamp__c = found.LastModifiedDate, Prepared_At__c = Datetime.now()
        );
        insert row;
        return row.Id;
    }

    @IsTest
    static void aReserveReviewGivesAFigureWithItsReasonsAndChangesNothingUntilApproved() {
        ClaudeMock claude = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, claude);
        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.RESERVE, claim().Id, 'the record');
        Test.stopTest();

        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(piece.work);
        Assert.areEqual(1, claude.calls, 'One call to Claude for one review');
        Assert.areEqual(AntsuranceDeskShift.WAITING, piece.status, 'Money always waits for a person');
        Assert.areEqual(49200, AntsuranceAiClient.toDecimal(work.get('newReserve')).intValue(), 'The figure is the one Claude worked out from the file');
        Assert.areEqual('Burst pipe flooded basement: raise the reserve by $4,200', piece.title, 'The row leads with the claim and says by how much');
        Assert.areEqual(46000, AntsuranceAiClient.toDecimal(work.get('payable')).intValue(), 'What is payable is the estimate less the deductible');
        Assert.areEqual('The estimate and the mitigation invoice together come to more than the reserve.', piece.reason, 'With the reason in a sentence');
        Assert.areEqual(2, ((List<Object>) work.get('factors')).size(), 'And the factors behind it');
        Assert.areEqual(5000, AntsuranceAiClient.toDecimal(work.get('paid')).intValue(), 'What has been paid is shown beside it');
        Assert.isNotNull(work.get('daysOpen'), 'And how long the claim has been open');
        Assert.areEqual(45000, claim().Reserve_Amount__c, 'The reserve is untouched');
        Assert.isFalse(AntsuranceDeskController.getDesk().waiting[0].changedSince, 'The claim is as it was');
        update new Case(Id = claim().Id, Reported_Date__c = Date.today().addDays(-2));
        Assert.areEqual(2, AntsuranceDeskController.getDesk().waiting[0].daysOpen, 'How long the claim has been open is read from the claim, not from what was stored');

        try {
            AntsuranceDeskController.approve(piece.workId, '{"newReserve":4000}');
            Assert.fail('A reserve cannot go below what has been paid');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('$5,000 already paid'), 'The error gives the figure: ' + e.getMessage());
        }
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.approve(piece.workId, '{"newReserve":49000}');

        Assert.areEqual(49000, claim().Reserve_Amount__c, 'Approving changes the reserve to the figure the person settled on');
        Assert.areEqual('Reserve changed from $45,000 to $49,000.', desk.log[0].note, 'The log says what changed');
        Assert.isNull(step(AntsuranceDeskShift.plan(), AntsuranceDeskShift.RESERVE), 'The reserve now covers the estimate');
    }

    @IsTest
    static void aReserveEqualToWhatIsPayableIsAdequate() {
        // $48,500 estimate less the $2,500 deductible: $46,000 is what the claim is expected to pay.
        update new Case(Id = claim().Id, Reserve_Amount__c = 46000);

        Test.startTest();
        AntsuranceDeskShift.Plan plan = AntsuranceDeskShift.plan();
        Test.stopTest();

        Assert.isNull(step(plan, AntsuranceDeskShift.RESERVE), 'The gap to the gross estimate is the deductible, not a shortfall');
    }

    @IsTest
    static void aReserveFigureOutsideTheClaimsOwnFiguresFallsBackToTheArithmetic() {
        ClaudeMock claude = new ClaudeMock();
        claude.reserveFromClaude = 400000;
        Test.setMock(HttpCalloutMock.class, claude);
        Test.startTest();
        AntsuranceDeskController.Piece tooHigh = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.RESERVE, claim().Id, 'the record');
        Test.stopTest();

        Map<String, Object> work = (Map<String, Object>) JSON.deserializeUntyped(tooHigh.work);
        Assert.areEqual(46000, AntsuranceAiClient.toDecimal(work.get('newReserve')).intValue(), 'A figure far above the claim is not passed on: what is payable is proposed');
        Assert.areEqual('$48,500 estimate less the $2,500 deductible is $46,000 payable. The reserve is $45,000, $1,000 short.', tooHigh.reason, 'And the reason is the sum');
        Assert.areEqual('Burst pipe flooded basement: raise the reserve by $1,000', tooHigh.title, 'The row says by how much');
        Assert.isTrue(((List<Object>) work.get('factors')).isEmpty(), 'With no factors that argue for another figure');
    }

    @IsTest
    static void aFollowUpAddsItsTaskOnlyWhenApproved() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Quay Household - Umbrella'];

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.FOLLOW_UP, sale.Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.WAITING, piece.status, 'A follow-up waits by default');
        Assert.isTrue(piece.reason.startsWith('They have had the quote for 20 days'), 'The reason says how long: ' + piece.reason);
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE WhatId = :sale.Id], 'No task yet');

        AntsuranceDeskController.approve(piece.workId, '{"taskSubject":"Call Maya about the umbrella quote"}');

        Task added = [SELECT Subject, Description, WhoId, ActivityDate, OwnerId FROM Task WHERE WhatId = :sale.Id];
        Assert.areEqual('Call Maya about the umbrella quote', added.Subject, 'The task carries the edited subject');
        Assert.isTrue(added.Description.contains('Which option suits you?'), 'And the drafted email');
        Assert.areEqual(UserInfo.getUserId(), added.OwnerId, 'It is the approver\'s task');
        Assert.isTrue(added.ActivityDate > Date.today(), 'Due on the next working day');
    }

    @IsTest
    static void aFollowUpLeftToClaudeAddsTheTaskItself() {
        setAutonomy(Claude_Autonomy__c.Quote_Follow_Up__c, AntsuranceDeskShift.AUTO);
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Quay Household - Umbrella'];

        Test.startTest();
        AntsuranceDeskController.Piece piece = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.FOLLOW_UP, sale.Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.DONE, piece.status, 'Claude did it and reports');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :sale.Id AND Subject = 'Call the Quays about their auto quote'], 'The task is on the list');
        Assert.isTrue(piece.note.startsWith('Task added to your list'), 'The log says so');
    }

    @IsTest
    static void dismissingNeedsAReasonAndChangesNothing() {
        Id workId = waitingReserveReview();

        Test.startTest();
        try {
            AntsuranceDeskController.dismiss(workId, ' ');
            Assert.fail('A dismissal needs a reason');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('why'), 'The error asks for one');
        }
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.dismiss(workId, 'The estimate is being disputed.');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.DISMISSED, desk.log[0].status, 'It is dismissed');
        Assert.areEqual('The estimate is being disputed.', desk.log[0].note, 'With the reason');
        Assert.areEqual(45000, claim().Reserve_Amount__c, 'The reserve is untouched');
        Assert.isNull(step(AntsuranceDeskShift.plan(), AntsuranceDeskShift.RESERVE), 'It is not proposed again while the claim is unchanged');
    }

    @IsTest
    static void aPieceWhoseRecordHasChangedSaysSoAndCanBePreparedAgain() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Id workId = waitingReserveReview();
        // A save that leaves the reserve and the estimate alone, such as a new brief, does not put a reserve review out of date.
        update new Claude_Work__c(Id = workId, Record_Stamp__c = Datetime.now().addDays(-1));
        update new Case(Id = claim().Id, Description = 'The plumber has been.');
        Assert.isFalse(AntsuranceDeskController.getDesk().waiting[0].changedSince, 'The figures it rests on are as they were');
        update new Case(Id = claim().Id, Estimated_Loss__c = 52000);

        Test.startTest();
        Assert.isTrue(AntsuranceDeskController.getDesk().waiting[0].changedSince, 'The desk says the claim has changed');
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.prepareAgain(workId);
        Test.stopTest();

        Assert.areEqual(1, desk.waiting.size(), 'One piece waits: the new one');
        Assert.areEqual(
            49500, AntsuranceAiClient.toDecimal(((Map<String, Object>) JSON.deserializeUntyped(desk.waiting[0].work)).get('newReserve')).intValue(),
            'It uses the new estimate, less the deductible'
        );
        Assert.areEqual(AntsuranceDeskShift.REPLACED, [SELECT Status__c FROM Claude_Work__c WHERE Id = :workId].Status__c, 'The old one is retired');
    }

    @IsTest
    static void onlyTheNewestRowsAreKept() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        List<Claude_Work__c> rows = new List<Claude_Work__c>();
        for (Integer i = 0; i < AntsuranceDeskShift.KEEP + 3; i++) {
            rows.add(
                new Claude_Work__c(
                    Kind__c = 'Claim brief', Status__c = AntsuranceDeskShift.DONE, Title__c = 'Old brief ' + i, Work__c = '{}', Record_Id__c = claim().Id,
                    Record_Object__c = 'Case', Prepared_At__c = Datetime.now().addDays(-10 - i)
                )
            );
        }
        insert rows;

        Test.startTest();
        AntsuranceDeskController.preparePiece(AntsuranceDeskShift.RESERVE, claim().Id, 'the record');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.KEEP, [SELECT COUNT() FROM Claude_Work__c], 'The log holds its newest rows and no more');
        Assert.areEqual(1, [SELECT COUNT() FROM Claude_Work__c WHERE Kind__c = 'Reserve review'], 'The new piece is among them');
    }

    @IsTest
    static void moneyAndCustomerContactCanNeverBeLeftToClaudeAlone() {
        Test.startTest();
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.saveAutonomy('{"brief":"approve","followup":"off"}');
        try {
            AntsuranceDeskController.saveAutonomy('{"reserve":"auto"}');
            Assert.fail('A reserve change always needs a person');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('cannot be left to Claude alone'), 'The error says so: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(desk.canManage, 'The desk permission set carries the manager permission');
        Map<String, AntsuranceDeskController.Setting> byKey = new Map<String, AntsuranceDeskController.Setting>();
        for (AntsuranceDeskController.Setting setting : desk.settings) {
            byKey.put(setting.key, setting);
        }
        Assert.areEqual(AntsuranceDeskShift.APPROVE, byKey.get('brief').mode, 'The brief setting was saved');
        Assert.areEqual(AntsuranceDeskShift.OFF, byKey.get('followup').mode, 'And the follow-up setting');
        Assert.areEqual(AntsuranceDeskShift.AUTO, byKey.get('memo').mode, 'A kind not mentioned keeps its default');
        Assert.isTrue(byKey.get('reserve').locked && byKey.get('outreach').locked, 'Money and customer contact are locked');
        // Even a stored value cannot unlock them.
        Claude_Autonomy__c stored = Claude_Autonomy__c.getOrgDefaults();
        stored.Reserve_Review__c = AntsuranceDeskShift.AUTO;
        update stored;
        Assert.areEqual(AntsuranceDeskShift.APPROVE, AntsuranceDeskShift.modeOf(AntsuranceDeskShift.kindOf('reserve')), 'Apex holds the line whatever is stored');
    }

    @IsTest
    static void theNightlyRunPreparesAPieceWithoutAnyoneWatching() {
        ClaudeMock claude = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, claude);

        Test.startTest();
        new AntsuranceDeskNightly().execute(null);
        Test.stopTest();

        // A test runs one job of the chain: the first piece of the plan.
        Assert.areEqual(1, [SELECT COUNT() FROM Claude_Work__c], 'The first piece is prepared');
        Assert.areEqual(AntsuranceDeskShift.DONE, [SELECT Status__c FROM Claude_Work__c].Status__c, 'The plan starts with a brief, which Claude does and reports');
    }

    @IsTest
    static void aPieceThatTimesOutIsRecordedAndTheShiftMovesOn() {
        ClaudeMock claude = new ClaudeMock();
        claude.timesOut = true;
        Test.setMock(HttpCalloutMock.class, claude);
        // A piece the shift had already prepared: each piece is its own request, so one that fails takes nothing with it.
        waitingReserveReview();

        Test.startTest();
        // The next piece: Claude does not answer inside Salesforce's two minutes.
        AntsuranceDeskController.Piece slow = AntsuranceDeskController.preparePiece(AntsuranceDeskShift.BRIEF, claim().Id, 'Burst pipe flooded basement');
        Test.stopTest();

        Assert.areEqual(AntsuranceDeskShift.FAILED, slow.status, 'The piece is recorded as not prepared, not thrown away');
        Assert.areEqual('Claim brief for Burst pipe flooded basement', slow.title, 'It says which piece');
        Assert.isTrue(slow.reason.contains('two-minute limit'), 'And why, in words for the person: ' + slow.reason);
        Assert.isTrue(String.isBlank(claim().Claude_Brief__c), 'The claim that timed out is untouched');

        AntsuranceDeskController.Desk desk = AntsuranceDeskController.getDesk();
        Assert.areEqual(1, desk.failed.size(), 'The desk lists the piece to try again');
        Assert.areEqual(1, desk.waiting.size(), 'Beside the piece that was prepared');
        Assert.areEqual(1, AntsuranceDeskController.summary().waiting, 'A failed piece is not counted as waiting for approval');
        Assert.isNotNull(step(AntsuranceDeskShift.plan(), AntsuranceDeskShift.BRIEF), 'The next shift tries the brief again');
    }

    @IsTest
    static void tryingAgainPreparesThatPieceAloneAndClearsTheFailure() {
        Claude_Work__c failure = AntsuranceDeskShift.recordFailure(AntsuranceDeskShift.BRIEF, claim().Id, 'Burst pipe flooded basement', 'Claude was still working.');
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());

        Test.startTest();
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.tryAgain(failure.Id);
        Test.stopTest();

        Assert.isTrue(desk.failed.isEmpty(), 'Nothing is left to try again');
        Assert.areEqual(1, desk.log.size(), 'The failure is replaced by the prepared piece');
        Assert.areEqual(AntsuranceDeskShift.DONE, desk.log[0].status, 'Which Claude did and reports');
        Assert.isTrue(String.isNotBlank(claim().Claude_Brief__c), 'The brief is on the claim');
    }

    @IsTest
    static void aSecondFailureKeepsThePieceWithItsLatestReason() {
        Claude_Work__c failure = AntsuranceDeskShift.recordFailure(AntsuranceDeskShift.BRIEF, claim().Id, 'Burst pipe flooded basement', 'An earlier reason.');
        ClaudeMock claude = new ClaudeMock();
        claude.status = 500;
        Test.setMock(HttpCalloutMock.class, claude);

        Test.startTest();
        AntsuranceDeskController.Desk desk = AntsuranceDeskController.tryAgain(failure.Id);
        Test.stopTest();

        Assert.areEqual(1, desk.failed.size(), 'The piece is still there to try again');
        Assert.areNotEqual('An earlier reason.', desk.failed[0].reason, 'With the reason from this attempt');
        Assert.isTrue(String.isBlank(claim().Claude_Brief__c), 'And the claim is untouched');

        Assert.isTrue(AntsuranceDeskController.discard(failure.Id).failed.isEmpty(), 'The note can be removed');
        try {
            AntsuranceDeskController.tryAgain(failure.Id);
            Assert.fail('There is nothing left to try');
        } catch (AuraHandledException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'The error says so');
        }
    }

    @IsTest
    static void theNightlyRunRecordsAPieceThatTimesOut() {
        ClaudeMock claude = new ClaudeMock();
        claude.timesOut = true;
        Test.setMock(HttpCalloutMock.class, claude);

        Test.startTest();
        new AntsuranceDeskNightly().execute(null);
        Test.stopTest();

        Claude_Work__c row = [SELECT Status__c, Reason__c, Record_Name__c FROM Claude_Work__c];
        Assert.areEqual(AntsuranceDeskShift.FAILED, row.Status__c, 'The job records the piece instead of failing');
        Assert.areEqual('Burst pipe flooded basement', row.Record_Name__c, 'With the record it was for');
        Assert.isTrue(row.Reason__c.contains('two-minute limit'), 'And the reason');
    }
}
