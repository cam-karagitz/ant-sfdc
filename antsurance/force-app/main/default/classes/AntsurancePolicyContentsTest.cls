@IsTest
private class AntsurancePolicyContentsTest {
    private static Opportunity sale;
    private static Policy__c policy;

    /** An open auto sale with an accepted, configured quote, and the policy about to be bound from it. */
    private static void createSale(String answersJson) {
        Account household = new Account(Name = 'Binder Household', BillingStreet = '12 Test St', BillingCity = 'Naperville', BillingPostalCode = '60540');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        insert household;
        Contact insured = new Contact(FirstName = 'Bea', LastName = 'Binder', AccountId = household.Id);
        insert insured;
        sale = new Opportunity(
            Name = 'Binder Household - Personal Auto', AccountId = household.Id, StageName = 'Bind Requested', CloseDate = Date.today(), Line_of_Business__c = 'Personal Auto',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId()
        );
        insert sale;
        Quote quote = new Quote(Name = 'Standard', OpportunityId = sale.Id, Status = 'Draft');
        insert quote;
        if (answersJson != null) {
            AntsuranceQuoteConfigurator.saveConfiguration(quote.Id, answersJson, 'Phone', true, null);
            update new Quote(Id = quote.Id, Status = 'Accepted');
        }
        policy = new Policy__c(
            Name = 'ANT-PA-TEST', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
            Effective_Date__c = Date.today(), Expiration_Date__c = Date.today().addYears(1), Annual_Premium__c = 1500, Coverage_Limit__c = 300000, Deductible__c = 500,
            Insured_Item__c = '2023 Honda Civic'
        );
        insert policy;
    }

    @IsTest
    static void bindingASaleFillsInTheNewPolicy() {
        createSale('{"roadside":"true","rental":"false","bundle":"true","paperless":"false","payInFull":"false"}');

        Test.startTest();
        update new Opportunity(Id = sale.Id, StageName = 'Bound', Policy__c = policy.Id);
        Test.stopTest();

        List<Policy_Coverage__c> coverages = [SELECT Name, Premium_Amount__c, Limit_Amount__c FROM Policy_Coverage__c WHERE Policy__c = :policy.Id];
        Decimal total = 0;
        for (Policy_Coverage__c coverage : coverages) {
            total += coverage.Premium_Amount__c;
        }
        Assert.areEqual(6, coverages.size(), 'A personal auto policy carries six coverages');
        Assert.areEqual(1500, total, 'Their premiums add up to the policy premium');

        Policy_Asset__c vehicle = [SELECT Name, Asset_Type__c, Location__c FROM Policy_Asset__c WHERE Policy__c = :policy.Id];
        Assert.areEqual('2023 Honda Civic', vehicle.Name, 'The insured item becomes an asset');
        Assert.areEqual('Vehicle', vehicle.Asset_Type__c, 'Of the type its line insures');
        Assert.areEqual('12 Test St, Naperville, IL 60540', vehicle.Location__c, 'Kept at the customer address');

        Map<String, Policy_Endorsement__c> endorsements = new Map<String, Policy_Endorsement__c>();
        for (Policy_Endorsement__c endorsement : [SELECT Name, Type__c, Premium_Change__c FROM Policy_Endorsement__c WHERE Policy__c = :policy.Id]) {
            endorsements.put(endorsement.Name, endorsement);
        }
        Assert.areEqual(new Set<String>{ 'Roadside Assistance', 'Multi-Policy Discount' }, endorsements.keySet(), 'Only what the customer chose is endorsed');
        Assert.areEqual(36, endorsements.get('Roadside Assistance').Premium_Change__c, 'An extra carries what it added to the premium');
        Assert.isTrue(endorsements.get('Multi-Policy Discount').Premium_Change__c < 0, 'A discount carries what it took off');
        Assert.areEqual('Discount', endorsements.get('Multi-Policy Discount').Type__c, 'And is typed as a discount');
    }

    @IsTest
    static void aPolicyThatAlreadyHasCoveragesIsLeftAlone() {
        createSale(null);
        insert new Policy_Coverage__c(Policy__c = policy.Id, Name = 'Collision', Category__c = 'Collision', Premium_Amount__c = 1500, Status__c = 'Active');

        Test.startTest();
        update new Opportunity(Id = sale.Id, StageName = 'Bound', Policy__c = policy.Id);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Policy_Coverage__c WHERE Policy__c = :policy.Id], 'A renewal keeps the coverages it had');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Endorsement__c WHERE Policy__c = :policy.Id], 'And gains no endorsements');
    }

    @IsTest
    static void aSaleBoundWithoutAQuoteStillGetsCoverages() {
        createSale(null);

        Test.startTest();
        update new Opportunity(Id = sale.Id, StageName = 'Bound', Policy__c = policy.Id);
        Test.stopTest();

        Assert.areEqual(6, [SELECT COUNT() FROM Policy_Coverage__c WHERE Policy__c = :policy.Id], 'The coverages come from the policy terms');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Endorsement__c WHERE Policy__c = :policy.Id], 'With no quote there is nothing to endorse');
    }
}
