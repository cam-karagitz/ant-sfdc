@IsTest
private class AntsuranceRenewalJobTest {
    private static Policy__c policy(Account customer, String name, String status, Integer daysToExpiry) {
        Date expiry = Date.today().addDays(daysToExpiry);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Status__c = status, Line_of_Business__c = 'Homeowners', Annual_Premium__c = 1500,
            Effective_Date__c = expiry.addYears(-1), Expiration_Date__c = expiry
        );
    }

    @TestSetup
    static void createPolicies() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        insert new List<Policy__c>{
            policy(customer, 'DUE', 'Active', 30),
            policy(customer, 'DUE-HAS-OPP', 'Active', 10),
            policy(customer, 'LATER', 'Active', 120),
            policy(customer, 'LAPSED', 'Lapsed', 20)
        };
        insert new Opportunity(
            Name = 'Existing renewal', AccountId = customer.Id, Type = 'Renewal', StageName = 'Quote Issued', CloseDate = Date.today().addDays(10),
            Policy__c = [SELECT Id FROM Policy__c WHERE Name = 'DUE-HAS-OPP'].Id
        );
    }

    @IsTest
    static void flagsPoliciesInTheWindowAndOpensTheirRenewals() {
        Test.startTest();
        Integer flagged = AntsuranceRenewalJob.flagUpcomingRenewals();
        Test.stopTest();

        Assert.areEqual(2, flagged, 'Both policies expiring within the window are flagged');
        Map<String, String> statusByName = new Map<String, String>();
        for (Policy__c saved : [SELECT Name, Status__c FROM Policy__c]) {
            statusByName.put(saved.Name, saved.Status__c);
        }
        Assert.areEqual('Pending Renewal', statusByName.get('DUE'), 'A policy expiring soon is pending renewal');
        Assert.areEqual('Pending Renewal', statusByName.get('DUE-HAS-OPP'), 'So is one that already has a renewal open');
        Assert.areEqual('Active', statusByName.get('LATER'), 'A policy outside the window is left alone');
        Assert.areEqual('Lapsed', statusByName.get('LAPSED'), 'A policy not in force is left alone');

        Opportunity renewal = [SELECT Name, Amount, CloseDate, StageName, Line_of_Business__c FROM Opportunity WHERE Policy__r.Name = 'DUE'];
        Assert.areEqual('Harbor Household - Homeowners renewal', renewal.Name, 'Named for the customer and line');
        Assert.areEqual(1500, renewal.Amount, 'Starts at the current premium');
        Assert.areEqual(Date.today().addDays(30), renewal.CloseDate, 'Closes on the expiration date');
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE Policy__r.Name = 'DUE-HAS-OPP'], 'No duplicate renewal is opened');
    }

    @IsTest
    static void runsOnASchedule() {
        Test.startTest();
        System.schedule('Antsurance renewals test', '0 0 6 * * ?', new AntsuranceRenewalJob());
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Policy__c WHERE Status__c = 'Pending Renewal'], 'The scheduled run flags the same policies');
    }
}
