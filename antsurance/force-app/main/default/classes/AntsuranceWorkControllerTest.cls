@IsTest
private class AntsuranceWorkControllerTest {
    @TestSetup
    static void createWork() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Date today = Date.today();
        insert new List<Policy__c>{
            policy(customer, 'SOON', 'Pending Renewal', 10, 1000),
            policy(customer, 'LATER-IN-WINDOW', 'Active', 55, 3000),
            policy(customer, 'OUTSIDE', 'Active', 90, 9000),
            policy(customer, 'LAPSED', 'Lapsed', 20, 7000)
        };
        Opportunity sale = new Opportunity(Name = 'Harbor umbrella', AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = today.addDays(20));
        insert sale;
        insert new List<Quote>{
            new Quote(OpportunityId = sale.Id, Name = 'Old and open', Status = 'Issued', Annual_Premium__c = 500, Issued_Date__c = today.addDays(-30)),
            new Quote(OpportunityId = sale.Id, Name = 'Just stale', Status = 'Presented', Annual_Premium__c = 700, Issued_Date__c = today.addDays(-15)),
            new Quote(OpportunityId = sale.Id, Name = 'Fresh', Status = 'Issued', Annual_Premium__c = 900, Issued_Date__c = today.addDays(-3)),
            new Quote(OpportunityId = sale.Id, Name = 'Old but declined', Status = 'Declined', Annual_Premium__c = 800, Issued_Date__c = today.addDays(-40))
        };
        Case claim = new Case(
            Subject = 'Burst pipe', AccountId = customer.Id, Status = 'Under Investigation',
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId()
        );
        insert claim;
        insert new List<Task>{
            new Task(Subject = 'Overdue call', ActivityDate = today.addDays(-2), Priority = 'Normal', Status = 'Not Started', WhatId = claim.Id),
            new Task(Subject = 'Due today', ActivityDate = today, Priority = 'High', Status = 'Not Started', WhatId = sale.Id),
            new Task(Subject = 'Next week', ActivityDate = today.addDays(7), Priority = 'Normal', Status = 'Not Started'),
            new Task(Subject = 'Already done', ActivityDate = today.addDays(-5), Priority = 'Normal', Status = 'Completed')
        };
    }

    private static Policy__c policy(Account customer, String name, String status, Integer daysToExpiry, Decimal premium) {
        Date expiry = Date.today().addDays(daysToExpiry);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Status__c = status, Line_of_Business__c = 'Homeowners', Annual_Premium__c = premium,
            Effective_Date__c = expiry.addYears(-1), Expiration_Date__c = expiry
        );
    }

    @IsTest
    static void listsOpenTasksSoonestFirstWithWhatTheyAreAbout() {
        Test.startTest();
        AntsuranceWorkController.Work work = AntsuranceWorkController.getMyWork();
        Test.stopTest();

        Assert.areEqual(3, work.openTaskCount, 'Completed tasks are not counted');
        Assert.areEqual(1, work.overdueTaskCount, 'One task is past due');
        Assert.areEqual('Overdue call', work.tasks[0].subject, 'The overdue task comes first');
        Assert.areEqual('Burst pipe', work.tasks[0].relatedName, 'A claim is named by its subject');
        Assert.areEqual('Harbor umbrella', work.tasks[1].relatedName, 'A sale is named by its name');
        Assert.isNull(work.tasks[2].relatedName, 'A task about nothing has no related name');
    }

    @IsTest
    static void listsInForcePoliciesExpiringInTheWindow() {
        Test.startTest();
        AntsuranceWorkController.Work work = AntsuranceWorkController.getMyWork();
        Test.stopTest();

        Assert.areEqual(2, work.renewalCount, 'Only in-force policies inside 60 days count');
        Assert.areEqual(4000, work.renewalPremium, 'Their premium is totaled');
        Assert.areEqual('SOON', work.renewals[0].policyNumber, 'Soonest expiry first');
        Assert.areEqual('Harbor Household', work.renewals[0].accountName, 'Carries the policyholder');
    }

    @IsTest
    static void listsOpenQuotesOutFifteenDaysOrMore() {
        Test.startTest();
        AntsuranceWorkController.Work work = AntsuranceWorkController.getMyWork();
        Test.stopTest();

        Assert.areEqual(2, work.staleQuoteCount, 'Fresh and declined quotes are left out');
        Assert.areEqual(1200, work.staleQuotePremium, 'Their premium is totaled');
        Assert.areEqual('Old and open', work.staleQuotes[0].option, 'Longest waiting first');
        Assert.areEqual('Harbor umbrella', work.staleQuotes[0].saleName, 'Carries the sale');
    }

    @IsTest
    static void completesOnlyAnOpenTask() {
        Task open = [SELECT Id FROM Task WHERE Subject = 'Due today'];
        Task done = [SELECT Id FROM Task WHERE Subject = 'Already done'];

        Test.startTest();
        AntsuranceWorkController.completeTask(open.Id);
        String message;
        try {
            AntsuranceWorkController.completeTask(done.Id);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual('Completed', [SELECT Status FROM Task WHERE Id = :open.Id].Status, 'The open task is completed');
        Assert.isTrue(message.contains('could not be completed'), 'A closed task is rejected');
    }
}
