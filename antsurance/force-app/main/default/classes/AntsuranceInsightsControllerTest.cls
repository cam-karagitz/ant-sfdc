@IsTest
private class AntsuranceInsightsControllerTest {
    @TestSetup
    static void loadDemoData() {
        AntsuranceDemoData.load();
    }

    @IsTest
    static void summarizesAHouseholdsPoliciesAndClaims() {
        Account household = [SELECT Id FROM Account WHERE Name = 'Okafor Household'];

        Test.startTest();
        AntsuranceInsightsController.CustomerSummary summary = AntsuranceInsightsController.getCustomerSummary(household.Id);
        Test.stopTest();

        Assert.isFalse(summary.isAgency, 'A household is not an agency');
        Assert.areEqual(3, summary.policiesInForce, 'Auto, homeowners and the newly bound umbrella are in force');
        Assert.areEqual(4360, summary.premiumInForce, 'Premium is the sum of in-force policies');
        Assert.areEqual(1, summary.openClaims, 'The burst pipe claim is open');
        Assert.areEqual(1, summary.openRequests, 'The deductible change request is open');
        Assert.areEqual(45000, summary.incurredLosses, 'Incurred is the higher of reserve and paid');
        Assert.areEqual(10.3211, summary.lossRatio, 'Loss ratio is incurred over premium');
        Assert.areEqual('Homeowners', summary.policies[0].lineOfBusiness, 'Largest premium first');
        Assert.areEqual(2, summary.members.size(), 'Both household members are listed');
        Assert.areEqual('Chinedu Okafor', summary.members[0].name, 'The primary member comes first');
        Assert.areEqual('Head of Household', summary.members[0].role, 'With their household role');
        Assert.isNotNull(summary.customerSince, 'Carries the customer-since date');
    }

    @IsTest
    static void listsLapsedPoliciesAfterThoseInForce() {
        Account household = [SELECT Id FROM Account WHERE Name = 'Castellano Household'];

        Test.startTest();
        AntsuranceInsightsController.CustomerSummary summary = AntsuranceInsightsController.getCustomerSummary(household.Id);
        Test.stopTest();

        Assert.areEqual(1, summary.policiesInForce, 'Only the renters policy is in force');
        Assert.areEqual(2, summary.policies.size(), 'Both policies are listed');
        Assert.isTrue(summary.policies[0].inForce, 'In-force policies come first');
        Assert.areEqual('Lapsed', summary.policies[1].status, 'The lapsed policy follows');
    }

    @IsTest
    static void anAgencySeesThePoliciesItProduced() {
        Account agency = [SELECT Id FROM Account WHERE Name = 'Prairie State Insurance Agency'];

        Test.startTest();
        AntsuranceInsightsController.CustomerSummary summary = AntsuranceInsightsController.getCustomerSummary(agency.Id);
        Test.stopTest();

        Assert.isTrue(summary.isAgency, 'Recognized as an agency');
        Integer produced = [SELECT COUNT() FROM Policy__c WHERE Producer__c = :agency.Id];
        Assert.areEqual(Math.min(produced, 50), summary.policies.size(), 'Lists the policies it produced, the first fifty of a longer book');
        Assert.areEqual(produced, summary.policyCount, 'And counts every one of them, so the card and the list beside it give one number');
        Assert.areEqual(
            [SELECT COUNT() FROM Policy__c WHERE Producer__c = :agency.Id AND Status__c IN ('Active', 'Pending Renewal')],
            summary.policiesInForce,
            'In force is counted the same way'
        );
        Assert.isNotNull(summary.policies[0].policyholder, 'Each policy names its policyholder');
    }

    @IsTest
    static void anOpenClaimWithNothingReservedIsStillCounted() {
        Account household = new Account(Name = 'Newly Reported Household', Customer_Since__c = Date.today().addYears(-6));
        insert household;
        Policy__c auto = new Policy__c(
            Name = 'T-AUTO-9', Account__c = household.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active', Annual_Premium__c = 1200,
            Effective_Date__c = Date.today().addDays(-30), Expiration_Date__c = Date.today().addDays(335)
        );
        insert auto;
        insert new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(), Subject = 'Rear-ended at a light', Policy__c = auto.Id,
            Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Collision', Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()
        );

        Test.startTest();
        AntsuranceInsightsController.CustomerSummary summary = AntsuranceInsightsController.getCustomerSummary(household.Id);
        Test.stopTest();

        Assert.areEqual(1, summary.openClaims, 'The new claim is open');
        Assert.areEqual(1, summary.claimCount, 'And is counted as a claim on these policies');
        Assert.areEqual(0, summary.incurredLosses, 'Though nothing is reserved or paid on it yet');
        Assert.areEqual(1, summary.policyCount, 'One policy');
        Assert.areEqual(1200, summary.premiumInForce, 'Its premium is in force');
        Assert.areEqual(6, summary.yearsSince, 'A customer since this day six years ago has been one for six years');
    }

    @IsTest
    static void yearsAreCountedByTheCalendar() {
        Date since = Date.newInstance(2020, 10, 5);
        Assert.areEqual(6, AntsuranceInsightsController.wholeYears(since, Date.newInstance(2026, 10, 5)), 'Six on the sixth anniversary');
        Assert.areEqual(5, AntsuranceInsightsController.wholeYears(since, Date.newInstance(2026, 10, 4)), 'Five the day before it');
        Assert.areEqual(5, AntsuranceInsightsController.wholeYears(since, Date.newInstance(2026, 9, 30)), 'And the month before');
        Assert.areEqual(0, AntsuranceInsightsController.wholeYears(since, Date.newInstance(2021, 3, 1)), 'None in the first year');
        Assert.isNull(AntsuranceInsightsController.wholeYears(null, Date.today()), 'No date, no count');
        Assert.isNull(AntsuranceInsightsController.wholeYears(Date.today().addDays(1), Date.today()), 'Nor for a date still to come');
    }

    @IsTest
    static void anAccountWithNoPoliciesHasAnEmptySummary() {
        Account empty = new Account(Name = 'No Policies Yet');
        insert empty;

        Test.startTest();
        AntsuranceInsightsController.CustomerSummary summary = AntsuranceInsightsController.getCustomerSummary(empty.Id);
        Test.stopTest();

        Assert.areEqual(0, summary.policiesInForce, 'No policies');
        Assert.isNull(summary.lossRatio, 'No loss ratio without premium');
        Assert.isTrue(summary.policies.isEmpty(), 'Nothing to list');
    }
}
