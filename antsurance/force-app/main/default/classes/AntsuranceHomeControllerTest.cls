@IsTest
private class AntsuranceHomeControllerTest {
    private static Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
    private static Id serviceType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId();

    @TestSetup
    static void createRecords() {
        Account customer = new Account(Name = 'Harbor Household');
        Account agency = new Account(
            Name = 'Dockside Agency',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Agency').getRecordTypeId()
        );
        insert new List<Account>{ customer, agency };
        Date start = Date.today().addDays(-30);
        insert new List<Policy__c>{
            new Policy__c(Name = 'P-1', Account__c = customer.Id, Status__c = 'Active', Annual_Premium__c = 1200, Effective_Date__c = start, Expiration_Date__c = start.addYears(1)),
            new Policy__c(Name = 'P-2', Account__c = customer.Id, Status__c = 'Pending Renewal', Annual_Premium__c = 800, Effective_Date__c = start, Expiration_Date__c = start.addYears(1)),
            new Policy__c(Name = 'P-3', Account__c = customer.Id, Status__c = 'Lapsed', Annual_Premium__c = 5000, Effective_Date__c = start, Expiration_Date__c = start.addYears(1))
        };
        insert new List<Opportunity>{
            new Opportunity(Name = 'Fleet policy', AccountId = customer.Id, StageName = 'Submission Received', CloseDate = Date.today().addDays(30), Amount = 1000),
            new Opportunity(Name = 'Property policy', AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(30), Amount = 5000),
            new Opportunity(Name = 'Umbrella policy', AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(30), Amount = 2500),
            new Opportunity(Name = 'Won policy', AccountId = customer.Id, StageName = 'Bound', CloseDate = Date.today(), Amount = 9000)
        };
        insert new List<Case>{
            claim(customer, 'Fender bender', 'New', 'Low', 2, 0, 0),
            claim(customer, 'Kitchen fire', 'Appraisal', 'Catastrophic', 5, 90000, 10000),
            claim(customer, 'Older hail claim', 'Under Investigation', 'High', 20, 30000, 0),
            claim(customer, 'Newer theft claim', 'Under Investigation', 'High', 3, 12000, 0),
            claim(customer, 'Settled glass claim', 'Closed', 'Low', 40, 500, 500),
            new Case(Subject = 'Add a driver', AccountId = customer.Id, Status = 'New', RecordTypeId = serviceType)
        };
        insert new Lead(LastName = 'Okafor', Company = 'Okafor Logistics');
    }

    private static Case claim(Account customer, String subject, String status, String severity, Integer daysSinceReported, Decimal reserve, Decimal paid) {
        return new Case(
            Subject = subject, AccountId = customer.Id, Status = status, Severity__c = severity, RecordTypeId = claimType,
            Reported_Date__c = Date.today().addDays(-daysSinceReported), Reserve_Amount__c = reserve, Paid_Amount__c = paid
        );
    }

    @IsTest
    static void snapshotCountsTheBookOfBusiness() {
        Test.startTest();
        AntsuranceHomeController.Snapshot snapshot = AntsuranceHomeController.getSnapshot();
        Test.stopTest();

        Assert.areEqual(1, snapshot.customerCount, 'Agencies are not counted as customers');
        Assert.areEqual(2, snapshot.policiesInForce, 'Active and pending renewal policies are in force');
        Assert.areEqual(2000, snapshot.premiumInForce, 'Lapsed premium is excluded');
        Assert.areEqual(4, snapshot.openClaimCount, 'The closed claim is excluded');
        Assert.areEqual(1, snapshot.openRequestCount, 'One open service request');
        Assert.areEqual(5, snapshot.openCaseCount, 'Open claims and requests together');
        Assert.areEqual(1, snapshot.openLeadCount, 'One unconverted lead was created');
        Assert.areEqual(UserInfo.getFirstName(), snapshot.firstName, 'First name is the running user');
    }

    @IsTest
    static void claimsAreListedMostSeriousThenOldestFirst() {
        Test.startTest();
        AntsuranceHomeController.Snapshot snapshot = AntsuranceHomeController.getSnapshot();
        Test.stopTest();

        List<String> subjects = new List<String>();
        for (AntsuranceHomeController.ClaimLine line : snapshot.claims) {
            subjects.add(line.subject);
        }
        Assert.areEqual(new List<String>{ 'Kitchen fire', 'Older hail claim', 'Newer theft claim', 'Fender bender' }, subjects, 'Severity first, then age');
        Assert.areEqual(80000, snapshot.claims[0].outstandingReserve, 'Carries the outstanding reserve');
        Assert.areEqual('Harbor Household', snapshot.claims[0].accountName, 'Carries the customer name');
    }

    @IsTest
    static void pipelineIsGroupedByStage() {
        Test.startTest();
        AntsuranceHomeController.Snapshot snapshot = AntsuranceHomeController.getSnapshot();
        Test.stopTest();

        Assert.areEqual(3, snapshot.openOpportunityCount, 'Closed opportunities are excluded');
        Assert.areEqual(8500, snapshot.openPipelineAmount, 'Open amounts are summed');
        Assert.areEqual(2, snapshot.stages.size(), 'Open opportunities span two stages');
        Assert.areEqual('Quote Issued', snapshot.stages[0].stageName, 'Largest stage comes first');
        Assert.areEqual(2, snapshot.stages[0].opportunityCount, 'Two opportunities are quoted');
        Assert.areEqual(7500, snapshot.stages[0].amount, 'Stage amounts are summed');
        Assert.areEqual('Property policy', snapshot.stages[0].opportunities[0].name, 'Largest opportunity in the stage comes first');
        Assert.isNotNull(snapshot.stages[0].opportunities[0].recordId, 'Each opportunity carries its record Id for linking');
        Assert.areEqual('Submission Received', snapshot.stages[1].stageName, 'Smaller stage comes second');
    }

    @IsTest
    static void snapshotIsEmptyWhenThereIsNoData() {
        delete [SELECT Id FROM Opportunity];
        delete [SELECT Id FROM Case];
        delete [SELECT Id FROM Policy__c];

        Test.startTest();
        AntsuranceHomeController.Snapshot snapshot = AntsuranceHomeController.getSnapshot();
        Test.stopTest();

        Assert.areEqual(0, snapshot.openOpportunityCount, 'No opportunities remain');
        Assert.areEqual(0, snapshot.openPipelineAmount, 'Pipeline amount defaults to zero');
        Assert.isTrue(snapshot.stages.isEmpty(), 'No stages are returned');
        Assert.areEqual(0, snapshot.policiesInForce, 'No policies remain');
        Assert.areEqual(0, snapshot.premiumInForce, 'Premium defaults to zero');
        Assert.isTrue(snapshot.claims.isEmpty(), 'No claims are listed');
    }
}
