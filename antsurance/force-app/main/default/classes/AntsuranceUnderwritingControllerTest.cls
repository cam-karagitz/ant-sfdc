@IsTest
private class AntsuranceUnderwritingControllerTest {
    /** Answers the memo request with a canned memo and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        HttpRequest request;

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            String memo = JSON.serialize(
                new Map<String, Object>{
                    'recommendation' => 'Approve with conditions',
                    'headline' => 'A clean five-year history outweighs one roof concern.',
                    'points' => new List<Object>{ new Map<String, Object>{ 'label' => 'Roof', 'detail' => 'Over 20 years old and never inspected.' } },
                    'conditions' => new List<Object>{ 'Roof inspection within 30 days' },
                    'questions' => new List<Object>()
                }
            );
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => memo } }
                    }
                )
            );
            return response;
        }
    }

    /** A homeowners sale in underwriting review with a draft quote referred for an old roof. */
    private static Quote createReferredQuote() {
        Account household = new Account(Name = 'Gable Household', BillingCity = 'Naperville', Customer_Segment__c = 'Personal Lines');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        insert household;
        Contact insured = new Contact(FirstName = 'Greta', LastName = 'Gable', AccountId = household.Id);
        insert insured;
        insert new Policy__c(
            Name = 'ANT-PA-GABLE', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
            Effective_Date__c = Date.today().addDays(-200), Expiration_Date__c = Date.today().addDays(165), Annual_Premium__c = 1800
        );
        Opportunity sale = new Opportunity(
            Name = 'Gable Household - Homeowners', AccountId = household.Id, StageName = 'Underwriting Review', CloseDate = Date.today().addDays(20),
            Line_of_Business__c = 'Homeowners', Type = 'Cross-Sell',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId()
        );
        insert sale;
        Quote quote = new Quote(Name = 'Standard deductible', OpportunityId = sale.Id, Status = 'Draft');
        insert quote;
        AntsuranceQuoteConfigurator.saveConfiguration(quote.Id, '{"roofAge":"over20"}', 'Phone', false, null);
        return [SELECT Id, OpportunityId, Needs_Underwriting_Review__c FROM Quote WHERE Id = :quote.Id];
    }

    @IsTest
    static void aReferredQuoteShowsWhyItWasReferred() {
        Quote quote = createReferredQuote();
        Assert.isTrue(quote.Needs_Underwriting_Review__c, 'An old roof sends the quote to underwriting');

        AntsuranceUnderwritingController.Review review = AntsuranceUnderwritingController.getReview(quote.Id);

        Assert.isTrue(review.needsReview, 'The review says so');
        Assert.isTrue(review.canDecide, 'And it can be decided');
        Assert.areEqual(new List<String>{ 'Roof is over 20 years old' }, review.reasons, 'With the reason the configurator recorded');
        Assert.isNull(review.memo, 'No memo has been drafted yet');
    }

    @IsTest
    static void draftingAMemoSendsTheFileToClaudeAndStoresTheAnswer() {
        Quote quote = createReferredQuote();
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceUnderwritingController.Review review = AntsuranceUnderwritingController.draftMemo(quote.Id);
        Test.stopTest();

        Assert.areEqual('Approve with conditions', review.memo.recommendation, 'The memo carries the recommendation');
        Assert.areEqual('Roof', review.memo.points[0].label, 'Its points');
        Assert.areEqual('Roof inspection within 30 days', review.memo.conditions[0], 'And its conditions');
        Assert.isNotNull(review.memo.writtenAt, 'It is stamped with when it was written');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('Roof is over 20 years old'), 'Claude is told why the quote was referred');
        Assert.isTrue(sent.contains('ANT-PA-GABLE'), 'And what the customer already insures with us');
        Assert.isTrue(String.isNotBlank([SELECT Underwriting_Memo__c FROM Quote WHERE Id = :quote.Id].Underwriting_Memo__c), 'The memo is stored on the quote');
    }

    @IsTest
    static void aFailedDraftIsReportedPlainly() {
        Quote quote = createReferredQuote();
        ClaudeMock mock = new ClaudeMock();
        mock.status = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            AntsuranceUnderwritingController.draftMemo(quote.Id);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'The card gets a message it can show');
        }
        Test.stopTest();
    }

    @IsTest
    static void approvingIssuesTheQuoteAndMovesTheSaleOn() {
        Quote quote = createReferredQuote();

        Test.startTest();
        AntsuranceUnderwritingController.Review review = AntsuranceUnderwritingController.decide(quote.Id, 'Approved with Conditions');
        Test.stopTest();

        Assert.isFalse(review.needsReview, 'The quote no longer waits on underwriting');
        Assert.areEqual('Approved with Conditions', review.decision, 'The decision is recorded');
        Quote decided = [SELECT Status, Issued_Date__c, ExpirationDate, Opportunity.StageName FROM Quote WHERE Id = :quote.Id];
        Assert.areEqual('Issued', decided.Status, 'An approved draft is issued');
        Assert.areEqual(Date.today(), decided.Issued_Date__c, 'Dated today');
        Assert.areEqual(Date.today().addDays(30), decided.ExpirationDate, 'And valid for 30 days');
        Assert.areEqual('Quote Issued', decided.Opportunity.StageName, 'The sale leaves underwriting review');
    }

    @IsTest
    static void decliningClosesTheQuoteAndLeavesTheSaleWhereItIs() {
        Quote quote = createReferredQuote();

        Test.startTest();
        AntsuranceUnderwritingController.decide(quote.Id, 'Declined');
        Test.stopTest();

        Quote decided = [SELECT Status, Underwriting_Decision__c, Opportunity.StageName FROM Quote WHERE Id = :quote.Id];
        Assert.areEqual('Declined', decided.Status, 'A declined quote is closed');
        Assert.areEqual('Declined', decided.Underwriting_Decision__c, 'With the decision recorded');
        Assert.areEqual('Underwriting Review', decided.Opportunity.StageName, 'Another option may still be offered, so the sale stays put');
    }

    @IsTest
    static void anUnknownDecisionIsRefused() {
        Quote quote = createReferredQuote();
        try {
            AntsuranceUnderwritingController.decide(quote.Id, 'Maybe');
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Approved'), 'The message says what can be chosen');
        }
    }
}
