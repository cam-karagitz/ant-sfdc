@IsTest
private class AntsuranceQuoteConfiguratorTest {
    private static final List<String> LINES = new List<String>{
        'Personal Auto', 'Homeowners', 'Renters', 'Umbrella', 'General Liability', 'Commercial Property', 'Workers Compensation', 'Commercial Auto'
    };

    private static Quote newQuote(String lineOfBusiness, String status) {
        Account customer = new Account(Name = 'Configurator Test Household');
        insert customer;
        Opportunity sale = new Opportunity(
            Name = 'Configurator test sale',
            AccountId = customer.Id,
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId(),
            StageName = 'Submission Received',
            CloseDate = Date.today().addDays(30),
            Line_of_Business__c = lineOfBusiness
        );
        insert sale;
        Quote quote = new Quote(Name = 'Option 1', OpportunityId = sale.Id, Status = status);
        insert quote;
        return quote;
    }

    @IsTest
    static void everyLineHasQuestionsWithUsableDefaults() {
        for (String line : LINES) {
            List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire(line);
            Assert.isTrue(sections.size() >= 3, line + ' has several sections');
            Set<String> keys = new Set<String>();
            for (AntsuranceQuoteConfigurator.Section section : sections) {
                Assert.isFalse(section.questions.isEmpty(), line + ': ' + section.title + ' has questions');
                for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                    Assert.isTrue(keys.add(question.key), line + ': ' + question.key + ' is used once');
                    Assert.isNotNull(question.ask, line + ': ' + question.key + ' has a way to ask it');
                    if (question.options.isEmpty()) {
                        continue;
                    }
                    Set<String> values = new Set<String>();
                    for (AntsuranceQuoteConfigurator.Option option : question.options) {
                        values.add(option.value);
                    }
                    Assert.isTrue(values.contains(question.defaultValue), line + ': ' + question.key + ' defaults to one of its options');
                }
            }
            AntsuranceQuoteConfigurator.Pricing pricing = AntsuranceQuoteConfigurator.price(line, '{}', null);
            Assert.isTrue(pricing.premium > 0, line + ' prices its default answers');
            Assert.isNotNull(pricing.limitAmount, line + ' has a limit');
            Assert.isTrue(pricing.referrals.isEmpty(), line + ' defaults need no underwriting review');
            Assert.areEqual('Base rate', pricing.lines[0].label, line + ' starts from a base rate');
        }
        Assert.isTrue(AntsuranceQuoteConfigurator.getQuestionnaire('Pet').isEmpty(), 'An unknown line has no questions');
    }

    @IsTest
    static void answersMoveThePriceAndCanCallForReview() {
        AntsuranceQuoteConfigurator.Pricing standard = AntsuranceQuoteConfigurator.price('Personal Auto', '{}', null);
        AntsuranceQuoteConfigurator.Pricing risky = AntsuranceQuoteConfigurator.price(
            'Personal Auto',
            '{"violations":"3plus","vehicles":2,"collision":"none","roadside":false}',
            null
        );
        AntsuranceQuoteConfigurator.Pricing tiered = AntsuranceQuoteConfigurator.price('Personal Auto', '{}', 1.1);

        Assert.isTrue(risky.premium > standard.premium, 'Two vehicles and three violations cost more');
        Assert.areEqual(1, risky.referrals.size(), 'Three violations call for underwriting review');
        Assert.isNull(risky.deductible, 'No collision cover means no deductible');
        Assert.areEqual(500, standard.deductible, 'The default collision deductible');
        Assert.areEqual(300000, standard.limitAmount, 'The default liability limit');
        Assert.isTrue(Math.abs(tiered.premium - standard.premium * 1.1) <= 1, 'The tier factor scales the whole premium');
        Assert.areEqual('Territory and rating tier', tiered.lines[tiered.lines.size() - 1].label, 'And shows as the last step');

        Decimal total = 0;
        for (AntsuranceQuoteConfigurator.PriceLine line : standard.lines) {
            total += line.amount;
        }
        Assert.areEqual(standard.premium, total, 'The steps are whole dollars that add up to the premium exactly');
    }

    @IsTest
    static void anUnconfiguredQuoteLoadsWithDefaults() {
        Quote quote = newQuote('Homeowners', 'Draft');

        Test.startTest();
        AntsuranceQuoteConfigurator.Configuration configuration = AntsuranceQuoteConfigurator.getConfiguration(quote.Id);
        Test.stopTest();

        Assert.isFalse(configuration.isConfigured, 'Nothing has been saved yet');
        Assert.isFalse(configuration.isLocked, 'A draft can be configured');
        Assert.isTrue(configuration.canIssue, 'A draft can be issued');
        Assert.areEqual('Homeowners', configuration.lineOfBusiness, 'The line comes from the sale');
        Assert.areEqual('Configurator Test Household', configuration.customerName, 'With the customer');
        Assert.isTrue(configuration.answersJson.contains('"dwelling":"400000"'), 'Answers start at the defaults');
        Assert.isTrue(configuration.pricing.premium > 0, 'And are priced');
    }

    @IsTest
    static void aQuoteWithNothingToReferIsIssued() {
        Quote quote = newQuote('Homeowners', 'Draft');

        Test.startTest();
        AntsuranceQuoteConfigurator.saveConfiguration(quote.Id, '{"dwelling":650000,"deductible":"2500"}', 'Phone', true, null);
        Test.stopTest();

        Quote stored = [SELECT Status, Issued_Date__c, ExpirationDate, Needs_Underwriting_Review__c, Opportunity.StageName FROM Quote WHERE Id = :quote.Id];
        Assert.areEqual('Issued', stored.Status, 'The draft was issued');
        Assert.areEqual(Date.today(), stored.Issued_Date__c, 'Dated today');
        Assert.areEqual(Date.today().addDays(30), stored.ExpirationDate, 'Valid for 30 days');
        Assert.isFalse(stored.Needs_Underwriting_Review__c, 'Nothing for an underwriter');
        Assert.areEqual('Submission Received', stored.Opportunity.StageName, 'The sale stays where it was');
    }

    @IsTest
    static void answersToHiddenQuestionsAreNotKept() {
        // A question that depends on another is only asked while that other answer calls for it.
        AntsuranceQuoteConfigurator.Question dependent;
        List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Workers Compensation');
        for (AntsuranceQuoteConfigurator.Section section : sections) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                if (question.showWhenKey != null) {
                    dependent = question;
                }
            }
        }
        Assert.isNotNull(dependent, 'Workers compensation has a question that depends on another');
        Map<String, Object> hidden = new Map<String, Object>{ dependent.showWhenKey => 'guaranteed', dependent.key => '2500', 'payroll' => 500000 };
        Map<String, Object> shown = new Map<String, Object>{ dependent.showWhenKey => dependent.showWhenValues[0], dependent.key => '2500' };

        Assert.isFalse(AntsuranceQuoteConfigurator.isAsked(dependent, hidden), 'Not asked while the other answer rules it out');
        Assert.isTrue(AntsuranceQuoteConfigurator.isAsked(dependent, shown), 'Asked once it calls for it');
        Map<String, Object> kept = AntsuranceQuoteConfigurator.askedAnswers(sections, hidden);
        Assert.isFalse(kept.containsKey(dependent.key), 'The leftover answer is dropped');
        Assert.areEqual(500000, kept.get('payroll'), 'The other answers stay');
        Assert.isTrue(AntsuranceQuoteConfigurator.askedAnswers(sections, shown).containsKey(dependent.key), 'A shown answer is kept');

        Quote quote = newQuote('Workers Compensation', 'Draft');
        Test.startTest();
        AntsuranceQuoteConfigurator.saveConfiguration(quote.Id, JSON.serialize(hidden), 'Phone', false, null);
        Test.stopTest();
        Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped([SELECT Configuration__c FROM Quote WHERE Id = :quote.Id].Configuration__c);
        Assert.isFalse(((Map<String, Object>) stored.get('answers')).containsKey(dependent.key), 'And it is not stored on the quote');
    }

    @IsTest
    static void savingStoresTheAnswersAndUpdatesTheQuote() {
        Quote quote = newQuote('Homeowners', 'Draft');

        Test.startTest();
        AntsuranceQuoteConfigurator.Configuration saved = AntsuranceQuoteConfigurator.saveConfiguration(
            quote.Id,
            '{"dwelling":650000,"deductible":"2500","roofAge":"over20"}',
            'Phone',
            true,
            'Higher deductible'
        );
        Test.stopTest();

        Quote stored = [
            SELECT Name, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Submission_Channel__c, Needs_Underwriting_Review__c, Issued_Date__c, ExpirationDate, Configuration__c
            FROM Quote
            WHERE Id = :quote.Id
        ];
        Assert.areEqual('Higher deductible', stored.Name, 'The option was named');
        Assert.areEqual('Draft', stored.Status, 'A quote that needs an underwriter is not issued from the questions');
        Assert.isNull(stored.Issued_Date__c, 'So it has no issue date');
        Assert.areEqual(650000, stored.Coverage_Limit__c, 'The limit is the dwelling amount');
        Assert.areEqual(2500, stored.Deductible__c, 'The deductible chosen');
        Assert.areEqual('Phone', stored.Submission_Channel__c, 'How it came in');
        Assert.isTrue(stored.Needs_Underwriting_Review__c, 'An old roof calls for review');
        Assert.areEqual(
            'Underwriting Review',
            [SELECT StageName FROM Opportunity WHERE Id IN (SELECT OpportunityId FROM Quote WHERE Id = :quote.Id)].StageName,
            'And the sale moves to underwriting'
        );
        Assert.areEqual(saved.pricing.premium, stored.Annual_Premium__c, 'The premium is what the answers price to');
        Assert.isTrue(saved.isConfigured, 'The quote is now configured');
        Assert.areEqual(Date.today(), saved.configuredOn, 'With the date it was configured');
        Assert.isTrue(saved.answersJson.contains('"roofAge":"over20"'), 'The answers come back');
        Assert.isTrue(saved.answersJson.contains('"construction":"frame"'), 'With defaults for what was not answered');
    }

    @IsTest
    static void aQuoteTheCustomerAnsweredCannotBeChanged() {
        Quote quote = newQuote('Renters', 'Accepted');

        Test.startTest();
        AntsuranceQuoteConfigurator.Configuration configuration = AntsuranceQuoteConfigurator.getConfiguration(quote.Id);
        String message;
        try {
            AntsuranceQuoteConfigurator.saveConfiguration(quote.Id, '{}', 'Online', false, null);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(configuration.isLocked, 'An accepted quote is locked');
        Assert.isTrue(message.contains('no longer be changed'), 'Saving is refused');
    }

    @IsTest
    static void demoConfigurationsPriceToTheGivenPremium() {
        Map<String, List<Decimal>> terms = new Map<String, List<Decimal>>{
            'Personal Auto' => new List<Decimal>{ 1560, 100000, 1000 },
            'Homeowners' => new List<Decimal>{ 1820, 400000, 1500 },
            'Renters' => new List<Decimal>{ 217, 30000, 500 },
            'Umbrella' => new List<Decimal>{ 420, 1000000, 0 },
            'General Liability' => new List<Decimal>{ 46200, 2000000, 10000 },
            'Commercial Property' => new List<Decimal>{ 27400, 9100000, 5000 },
            'Workers Compensation' => new List<Decimal>{ 149500, 1000000, 0 },
            'Commercial Auto' => new List<Decimal>{ 3400, 1000000, 1000 }
        };
        Integer sequence = 0;
        for (String line : terms.keySet()) {
            List<Decimal> term = terms.get(line);
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(
                AntsuranceQuoteConfigurator.demoConfiguration(line, term[0], term[1], term[2], sequence++, null, Date.today().addDays(-9))
            );
            Map<String, Object> pricing = (Map<String, Object>) stored.get('pricing');
            Decimal tier = Decimal.valueOf(String.valueOf(stored.get('tier')));
            Assert.areEqual(term[0], Decimal.valueOf(String.valueOf(pricing.get('premium'))), line + ' prices to the premium given');
            Assert.isTrue(tier > 0.6 && tier < 1.6, line + ' needs only a modest tier factor to get there, found ' + tier);
            // Opening the quote again prices the stored answers with the stored factor: that must not move the premium.
            Assert.areEqual(
                term[0], AntsuranceQuoteConfigurator.price(line, JSON.serialize(stored.get('answers')), tier).premium,
                line + ' comes to the same premium when its stored answers are priced again'
            );
            Assert.isTrue(((List<Object>) pricing.get('referrals')).isEmpty(), line + ' demo answers need no review');
            Assert.isFalse(((Map<String, Object>) stored.get('answers')).isEmpty(), line + ' has answers');
            Assert.areEqual(String.valueOf(Date.today().addDays(-9)), stored.get('configuredOn'), line + ' answers carry the day they were taken');
            Decimal steps = 0;
            for (Object step : (List<Object>) pricing.get('lines')) {
                steps += Decimal.valueOf(String.valueOf(((Map<String, Object>) step).get('amount')));
            }
            Assert.areEqual(term[0], steps, line + ' steps add up to the premium given');
        }
        Assert.isNull(AntsuranceQuoteConfigurator.demoConfiguration('Pet', 100, 1000, 0, 1, null, null), 'A line without questions has no configuration');

        Map<String, Object> known = new Map<String, Object>{ 'classGroup' => 'manufacturing', 'employees' => 112, 'state' => 'Nowhere', 'payroll' => 5 };
        Map<String, Object> withKnown = (Map<String, Object>) JSON.deserializeUntyped(
            AntsuranceQuoteConfigurator.demoConfiguration('Workers Compensation', 149500, 1000000, 0, 3, known, null)
        );
        Map<String, Object> answers = (Map<String, Object>) withKnown.get('answers');
        Assert.areEqual('manufacturing', answers.get('classGroup'), 'A known class of business is used');
        Assert.areEqual(112, answers.get('employees'), 'So is a known headcount');
        Assert.areEqual('IL', answers.get('state'), 'A value that is not one of the choices is ignored');
        Assert.areNotEqual('5', String.valueOf(answers.get('payroll')), 'The amount the premium is worked back from is not overridden');
        Assert.areEqual('guaranteed', answers.get('plan'), 'With no deductible the plan is guaranteed cost');
        Assert.areEqual(String.valueOf(Date.today()), withKnown.get('configuredOn'), 'With no date given the answers are dated today');

        String onADeductible = AntsuranceQuoteConfigurator.demoConfiguration('Workers Compensation', 139000, 1000000, 2500, 3, known, null);
        Map<String, Object> deductibleAnswers = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(onADeductible)).get('answers');
        Assert.areEqual('deductible', deductibleAnswers.get('plan'), 'A quote with a deductible is on the deductible plan');
        Assert.areEqual('2500', deductibleAnswers.get('deductible'), 'At that deductible');
        Assert.isFalse(AntsuranceQuoteConfigurator.needsReview(onADeductible), 'Ordinary answers need no underwriter');

        known.put('experienceMod', 'high');
        String referred = AntsuranceQuoteConfigurator.demoConfiguration('Workers Compensation', 149500, 1000000, 0, 3, known, null);
        Assert.isTrue(AntsuranceQuoteConfigurator.needsReview(referred), 'An answer with a referral reason sends the quote to an underwriter');
        Assert.isFalse(AntsuranceQuoteConfigurator.needsReview(null), 'A quote with no answers has nothing to review');
    }

    @IsTest
    static void theDeductibleQuestionOnlyAppliesOnADeductiblePlan() {
        AntsuranceQuoteConfigurator.Pricing guaranteed = AntsuranceQuoteConfigurator.price('Workers Compensation', '{"plan":"guaranteed","deductible":"5000"}', null);
        AntsuranceQuoteConfigurator.Pricing onADeductible = AntsuranceQuoteConfigurator.price('Workers Compensation', '{"plan":"deductible","deductible":"5000"}', null);

        Assert.isNull(guaranteed.deductible, 'A guaranteed cost plan has no deductible, whatever was left in the answer');
        Assert.areEqual(5000, onADeductible.deductible, 'The deductible plan takes the deductible chosen');
        Assert.isTrue(onADeductible.premium < guaranteed.premium, 'And costs less');
    }

    /** A business with a renewing workers compensation policy, and a sale to renew it. */
    private static Opportunity renewalSale() {
        Account business = new Account(
            Name = 'Prefill Machine Works', RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Business').getRecordTypeId(),
            Customer_Segment__c = 'Commercial Lines', Industry = 'Manufacturing', NumberOfEmployees = 112, Description = 'Precision machine shop running two shifts.',
            BillingStreet = '9000 Harrison Ave', BillingCity = 'Rockford', BillingPostalCode = '61109'
        );
        AntsuranceAddress.put(business, 'Billing', 'IL', 'US');
        insert business;
        Contact controller = new Contact(FirstName = 'Sam', LastName = 'Prefill', AccountId = business.Id);
        insert controller;
        Policy__c expiring = new Policy__c(
            Name = 'ANT-WC-PREFILL', Account__c = business.Id, Primary_Insured__c = controller.Id, Line_of_Business__c = 'Workers Compensation', Status__c = 'Pending Renewal',
            Effective_Date__c = Date.today().addDays(-340), Expiration_Date__c = Date.today().addDays(25), Annual_Premium__c = 142000, Coverage_Limit__c = 1000000, Deductible__c = 0
        );
        insert expiring;
        Opportunity sale = new Opportunity(
            Name = 'Prefill Machine Works - Workers Comp renewal', AccountId = business.Id, Policy__c = expiring.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(25),
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId(),
            Line_of_Business__c = 'Workers Compensation', Type = 'Renewal'
        );
        insert sale;
        return sale;
    }

    @IsTest
    static void aRenewalStartsFromTheCustomerAndTheExpiringPolicy() {
        Opportunity sale = renewalSale();

        Test.startTest();
        AntsuranceQuoteConfigurator.Configuration first = AntsuranceQuoteConfigurator.getConfiguration(AntsuranceQuoteConfigurator.startQuote(sale.Id));
        Test.stopTest();

        Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped(first.answersJson);
        Assert.areEqual('manufacturing', answers.get('classGroup'), 'The kind of work comes from the customer\'s industry');
        Assert.areEqual(112, answers.get('employees'), 'So does the headcount');
        Assert.areEqual('Precision machine shop running two shifts', answers.get('description'), 'And what the business does');
        Assert.areEqual('guaranteed', answers.get('plan'), 'The expiring policy has no deductible');
        Assert.isTrue(Math.abs(first.pricing.premium - 142000) < 1500, 'Payroll is worked back so the price starts near the expiring premium, found ' + first.pricing.premium);
        Assert.isTrue(first.prefilledFrom.contains('ANT-WC-PREFILL'), 'And the page can say where the answers came from');
        Assert.areEqual(sale.Id, first.opportunityId, 'The configuration knows its sale');
    }

    @IsTest
    static void aSecondOptionStartsFromTheFirst() {
        Opportunity sale = renewalSale();
        Id firstId = AntsuranceQuoteConfigurator.startQuote(sale.Id);
        AntsuranceQuoteConfigurator.Configuration saved = AntsuranceQuoteConfigurator.saveConfiguration(
            firstId, '{"classGroup":"manufacturing","payroll":4400000,"safetyProgram":"true","drugFree":"true"}', 'Agent', true, 'Guaranteed cost'
        );

        Test.startTest();
        AntsuranceQuoteConfigurator.Configuration second = AntsuranceQuoteConfigurator.getConfiguration(AntsuranceQuoteConfigurator.startQuote(sale.Id));
        Test.stopTest();

        Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped(second.answersJson);
        Assert.areEqual(4400000, Decimal.valueOf(String.valueOf(answers.get('payroll'))), 'The payroll already given is not asked for again');
        Assert.areEqual('true', String.valueOf(answers.get('drugFree')), 'Nor are the other answers');
        Assert.areEqual(saved.pricing.premium, second.pricing.premium, 'So the new option starts at the same price');
        Assert.isTrue(second.prefilledFrom.contains([SELECT QuoteNumber FROM Quote WHERE Id = :firstId].QuoteNumber), 'And says which quote it started from');
    }

    @IsTest
    static void aNewQuoteThatWasNeverSavedCanBeDiscarded() {
        Opportunity sale = renewalSale();
        Id unsaved = AntsuranceQuoteConfigurator.startQuote(sale.Id);
        Id kept = AntsuranceQuoteConfigurator.startQuote(sale.Id);
        AntsuranceQuoteConfigurator.saveConfiguration(kept, '{}', 'Phone', false, null);

        Test.startTest();
        Id returned = AntsuranceQuoteConfigurator.discardDraft(unsaved);
        String message;
        try {
            AntsuranceQuoteConfigurator.discardDraft(kept);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(sale.Id, returned, 'Discarding hands back the sale to return to');
        Assert.areEqual(0, [SELECT COUNT() FROM Quote WHERE Id = :unsaved], 'The unsaved draft is gone');
        Assert.areEqual(1, [SELECT COUNT() FROM Quote WHERE Id = :kept], 'A saved draft is kept');
        Assert.isTrue(message.contains('has not been saved'), 'And the refusal says why');
    }

    @IsTest
    static void aHouseholdRecordAnswersWhatItCan() {
        Account household = new Account(
            Name = 'Known Household', Customer_Segment__c = 'Personal Lines',
            BillingStreet = '12 Test St', BillingCity = 'Naperville', BillingPostalCode = '60540'
        );
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        Policy__c auto = new Policy__c(Line_of_Business__c = 'Personal Auto', Insured_Item__c = '2022 Toyota RAV4 and 2019 Honda Accord');

        Map<String, Object> known = AntsuranceQuoteConfigurator.knownAnswers(household, auto);

        Assert.areEqual('12 Test St, Naperville, IL 60540', known.get('address'), 'The address');
        Assert.areEqual('2022 Toyota RAV4 and 2019 Honda Accord', known.get('vehicleList'), 'The vehicles on the policy the sale is about');
        Assert.areEqual('personal', known.get('type'), 'And that it is a household');
        Assert.isTrue(AntsuranceQuoteConfigurator.knownAnswers(null, null).isEmpty(), 'No customer, nothing known');
    }

    @IsTest
    static void generatingAQuoteStartsADraftOnAnOpenSale() {
        Quote first = newQuote('Personal Auto', 'Draft');
        Id saleId = [SELECT OpportunityId FROM Quote WHERE Id = :first.Id].OpportunityId;

        Test.startTest();
        Id quoteId = AntsuranceQuoteConfigurator.startQuote(saleId);
        update new Opportunity(Id = saleId, StageName = 'Declined');
        String message;
        try {
            AntsuranceQuoteConfigurator.startQuote(saleId);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Quote started = [SELECT Name, Status, OpportunityId FROM Quote WHERE Id = :quoteId];
        Assert.areEqual('Option 2', started.Name, 'Named as the next option on the sale');
        Assert.areEqual('Draft', started.Status, 'It starts as a draft');
        Assert.areEqual(saleId, started.OpportunityId, 'On the sale it was started from');
        Assert.isTrue(message.contains('closed'), 'A closed sale takes no more quotes');
    }
}
