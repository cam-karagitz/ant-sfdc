@IsTest
private class AntsuranceQuoteAdvisorTest {
    /** Answers the advisor's request with canned proposals and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        HttpRequest request;
        List<Object> proposals = new List<Object>();
        String pitch = '';

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            String advice = JSON.serialize(new Map<String, Object>{ 'suggestions' => proposals, 'pitch' => pitch });
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => advice } }
                    }
                )
            );
            return response;
        }
    }

    /** A call that never comes back in time. */
    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    private static Map<String, Object> proposal(String kind, String key, String value) {
        return new Map<String, Object>{ 'kind' => kind, 'questionKey' => key, 'value' => value, 'title' => 'Change ' + key, 'why' => 'Because of what we hold on them.' };
    }

    /** The step index of a section, by its key. */
    private static Integer stepOf(String lineOfBusiness, String sectionKey) {
        List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire(lineOfBusiness);
        for (Integer index = 0; index < sections.size(); index++) {
            if (sections[index].key == sectionKey) {
                return index;
            }
        }
        return null;
    }

    private static final Integer REVIEW = 99;

    /** A household with a home policy and a water claim, and a draft auto quote on a new sale. */
    private static Quote createQuote() {
        Account household = new Account(Name = 'Larch Household', Customer_Segment__c = 'Personal Lines', Customer_Brief__c = '**Watch:** Price sensitive.');
        insert household;
        Contact insured = new Contact(FirstName = 'Lena', LastName = 'Larch', AccountId = household.Id, Household_Role__c = 'Head of Household', Licensed_Driver__c = true);
        insert insured;
        Policy__c home = new Policy__c(
            Name = 'ANT-HO-LARCH', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Active',
            Effective_Date__c = Date.today().addDays(-200), Expiration_Date__c = Date.today().addDays(165), Annual_Premium__c = 1900,
            Coverage_Limit__c = 420000, Deductible__c = 1000
        );
        insert home;
        insert new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(),
            Subject = 'Sump pump failed and flooded the basement', AccountId = household.Id, Policy__c = home.Id, Status = 'New',
            Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-120), Reported_Date__c = Date.today().addDays(-119), Reserve_Amount__c = 9000
        );
        Opportunity sale = new Opportunity(
            Name = 'Larch Household - Personal Auto', AccountId = household.Id, StageName = 'Submission Received', CloseDate = Date.today().addDays(20),
            Line_of_Business__c = 'Personal Auto', Type = 'Cross-Sell',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId()
        );
        insert sale;
        Quote quote = new Quote(Name = 'Option 1', OpportunityId = sale.Id, Status = 'Draft');
        insert quote;
        return quote;
    }

    @IsTest
    static void aSuggestionIsCheckedAgainstTheQuestionsAndPricedByTheConfigurator() {
        ClaudeMock mock = new ClaudeMock();
        mock.proposals = new List<Object>{
            proposal('change', 'collision', '2000'), // not one of the question's options
            proposal('change', 'towTruck', 'true'), // not a question
            proposal('change', 'collision', '500'), // already the answer
            proposal('change', 'vehicles', '3'), // a figure, not a choice
            proposal('change', 'collision', '1000'),
            proposal('change', 'collision', '250'), // a second for the same question
            proposal('change', 'rental', 'false')
        };
        Test.setMock(HttpCalloutMock.class, mock);
        String answers = '{"collision":"500","vehicles":2}';

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', answers, 1, REVIEW, 'Customer: Larch Household.');
        Test.stopTest();

        Assert.areEqual(7, advice.proposed, 'Claude made seven proposals');
        Assert.areEqual(2, advice.suggestions.size(), 'Only the two that name a real question and a different, real option are kept');
        AntsuranceQuoteAdvisor.Suggestion first = advice.suggestions[0];
        Assert.areEqual('collision', first.questionKey, 'In the order Claude gave them');
        Assert.areEqual('Collision deductible', first.questionLabel, 'With the question in words');
        Assert.areEqual('$500', first.fromLabel, 'The answer now');
        Assert.areEqual('$1,000', first.toLabel, 'And the answer proposed');
        Decimal before = AntsuranceQuoteConfigurator.price('Personal Auto', answers, 1).premium;
        Decimal after = AntsuranceQuoteConfigurator.price('Personal Auto', '{"collision":"1000","vehicles":2}', 1).premium;
        Assert.areEqual(after - before, first.premiumChange, 'The change in premium is the configurator\'s, to the dollar');
        Assert.isTrue(first.premiumChange < 0, 'A higher deductible saves money');
        Assert.areEqual(after, first.newPremium, 'With the premium it would come to');
        Assert.areEqual(-54, advice.suggestions[1].premiumChange, 'Dropping rental reimbursement takes off what it added');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('collision | Collision deductible | current: 500'), 'Claude is given each question with its answer');
        Assert.isTrue(sent.contains('Customer: Larch Household.'), 'And what we hold on the customer');
        Assert.isFalse(sent.contains('"towTruck"'), 'The answer schema offers only real question keys');
    }

    @IsTest
    static void onlyQuestionsTheSellerHasReachedAreSuggested() {
        ClaudeMock mock = new ClaudeMock();
        mock.proposals = new List<Object>{ proposal('change', 'collision', '1000'), proposal('change', 'homeowner', 'false') };
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', '{}', 1, stepOf('Personal Auto', 'applicant'), '');
        Test.stopTest();

        Assert.areEqual(1, advice.suggestions.size(), 'The coverage step has not been reached, so its question is not suggested');
        Assert.areEqual('homeowner', advice.suggestions[0].questionKey, 'A question on the first step is');
        Assert.isFalse(mock.request.getBody().contains('Collision deductible'), 'Claude is not shown questions the seller has not reached');
        Assert.isNull(advice.pitch, 'There is no line for the customer before Review');
    }

    @IsTest
    static void aChangeThatWouldSendTheQuoteToUnderwritingSaysSo() {
        ClaudeMock mock = new ClaudeMock();
        mock.proposals = new List<Object>{ proposal('avoid', 'violations', '3plus') };
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', '{}', 1, REVIEW, '');
        Test.stopTest();

        AntsuranceQuoteAdvisor.Suggestion warning = advice.suggestions[0];
        Assert.areEqual('avoid', warning.kind, 'It is a warning, not a change to make');
        Assert.areEqual(new List<String>{ 'Three or more moving violations in three years' }, warning.referrals, 'It names the reason an underwriter would be needed');
        Assert.isTrue(warning.premiumChange > 0, 'And what it would do to the price');
    }

    @IsTest
    static void aHiddenQuestionIsNeverSuggested() {
        ClaudeMock mock = new ClaudeMock();
        mock.proposals = new List<Object>{ proposal('change', 'deductible', '5000'), proposal('change', 'plan', 'deductible') };
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Workers Compensation', '{"plan":"guaranteed"}', 1, REVIEW, '');
        Test.stopTest();

        Assert.areEqual(1, advice.suggestions.size(), 'The deductible is only asked under a deductible plan');
        Assert.areEqual('plan', advice.suggestions[0].questionKey, 'The plan itself can be suggested');
    }

    @IsTest
    static void theLineForTheCustomerIsShownOnlyWithFiguresTheQuoteHas() {
        AntsuranceQuoteConfigurator.Pricing pricing = AntsuranceQuoteConfigurator.price('Personal Auto', '{}', 1);
        String premium = '$' + pricing.premium.format();

        Assert.isNotNull(AntsuranceQuoteAdvisor.soundPitch('This covers both cars for ' + premium + ' a year with a $500 deductible.', pricing), 'The real premium and deductible may be said');
        Assert.isNotNull(AntsuranceQuoteAdvisor.soundPitch('It protects you up to $300,000 if you hurt someone.', pricing), 'So may the limit');
        Assert.isNull(AntsuranceQuoteAdvisor.soundPitch('It saves you $31,299 a year.', pricing), 'A figure that is not on the quote is Claude\'s arithmetic and is not shown');
        Assert.isNull(AntsuranceQuoteAdvisor.soundPitch('  ', pricing), 'A blank line is nothing');
        Assert.areEqual('Cover for both cars, in one policy.', AntsuranceQuoteAdvisor.soundPitch('Cover for both cars — in one policy.', pricing), 'Long dashes never reach the screen');
    }

    @IsTest
    static void onReviewTheAnswerCarriesALineForTheCustomer() {
        ClaudeMock mock = new ClaudeMock();
        mock.pitch = 'This keeps both cars and both of you covered, with help on the road if you break down.';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', '{}', 1, REVIEW, '');
        Test.stopTest();

        Assert.areEqual(mock.pitch, advice.pitch, 'The line is passed through');
        Assert.isTrue(advice.suggestions.isEmpty(), 'With no suggestions when Claude has none');
        Assert.isTrue(mock.request.getBody().contains('THE SELLER IS ON: Review'), 'Claude is told the seller is on Review');
    }

    @IsTest
    static void theQuotesCustomerIsDescribedFromWhatWeHold() {
        Quote quote = createQuote();
        ClaudeMock mock = new ClaudeMock();
        mock.proposals = new List<Object>{ proposal('change', 'homeowner', 'false') };
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteConfigurator.advise(quote.Id, '{}', 1, 0);
        Test.stopTest();

        Assert.isFalse(advice.failed, 'Claude was asked');
        Assert.areEqual(1, advice.suggestions.size(), 'And its suggestion came back checked');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('Larch Household'), 'Claude is told who the customer is');
        Assert.isTrue(sent.contains('ANT-HO-LARCH'), 'What they insure with us');
        Assert.isTrue(sent.contains('Sump pump failed and flooded the basement'), 'What they have claimed for');
        Assert.isTrue(sent.contains('Lena Larch (Head of Household, licensed driver)'), 'Who is in the household');
        Assert.isTrue(sent.contains('Price sensitive'), 'And what the notes say about them');
    }

    @IsTest
    static void whenClaudeCannotBeReachedTheStripSaysNothing() {
        Quote quote = createQuote();
        ClaudeMock mock = new ClaudeMock();
        mock.status = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteConfigurator.advise(quote.Id, '{}', 1, 0);
        Test.stopTest();

        Assert.isTrue(advice.failed, 'The failure is flagged for the page');
        Assert.isTrue(advice.suggestions.isEmpty(), 'And there is nothing to show');
    }

    @IsTest
    static void aCallThatTimesOutIsQuietAndCanBeTriedAgain() {
        Quote quote = createQuote();
        Test.setMock(HttpCalloutMock.class, new TimeoutMock());

        Test.startTest();
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteConfigurator.advise(quote.Id, '{}', 1, 0);
        // The quote itself is untouched by the failure: it still prices and still loads.
        AntsuranceQuoteConfigurator.Pricing pricing = AntsuranceQuoteConfigurator.price('Personal Auto', '{}', 1);
        Test.stopTest();

        Assert.isTrue(advice.failed, 'A timeout is a quiet failure, not an exception');
        Assert.isTrue(advice.retryable, 'And one worth trying again');
        Assert.isTrue(advice.suggestions.isEmpty(), 'With nothing to show');
        Assert.isNull(advice.pitch, 'And no line for the customer');
        Assert.isTrue(pricing.premium > 0, 'The price does not depend on Claude');
    }

    @IsTest
    static void suggestionsAreRepricedWhenTheAnswersChange() {
        List<Object> onScreen = new List<Object>{ proposal('change', 'collision', '1000'), proposal('change', 'rental', 'false') };

        List<AntsuranceQuoteAdvisor.Suggestion> same = AntsuranceQuoteConfigurator.recheckAdvice('Personal Auto', '{"vehicles":1}', 1, REVIEW, JSON.serialize(onScreen));
        List<AntsuranceQuoteAdvisor.Suggestion> more = AntsuranceQuoteConfigurator.recheckAdvice('Personal Auto', '{"vehicles":3}', 1, REVIEW, JSON.serialize(onScreen));
        List<AntsuranceQuoteAdvisor.Suggestion> taken = AntsuranceQuoteConfigurator.recheckAdvice('Personal Auto', '{"vehicles":1,"collision":"1000"}', 1, REVIEW, JSON.serialize(onScreen));

        Assert.areEqual(2, same.size(), 'Both still apply');
        Assert.isTrue(more[0].premiumChange < same[0].premiumChange, 'The saving is worked out again on the larger premium');
        Assert.areEqual(1, taken.size(), 'A suggestion the seller has taken is gone');
        Assert.areEqual('rental', taken[0].questionKey, 'The other stays');
        Assert.isTrue(AntsuranceQuoteConfigurator.recheckAdvice('Personal Auto', '{}', 1, REVIEW, null).isEmpty(), 'Nothing on screen, nothing to check');
    }
}
