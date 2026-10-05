/**
 * @description Proof that Antsurance leaves the rest of an org alone. A case or an opportunity that is not
 * one of our record types is saved by a person who has none of our access, and nothing of ours touches it.
 */
@IsTest
private class AntsuranceCoexistenceTest {
    private static Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();

    /**
     * Someone in the org with no Antsurance permission set, so their records get no record type of ours.
     * They cannot see our fields either, so the saves below run in system mode to put values in them anyway:
     * the point is that even a case carrying our fields is left alone when it is not our record type.
     */
    private static User outsider() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'outsider' + Crypto.getRandomInteger() + '@antsurance.example.com';
        return new User(
            ProfileId = standard.Id, Username = unique, Email = unique, LastName = 'Outsider', Alias = 'outsidr',
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
    }

    @IsTest
    static void aPlainCaseIsSavedUntouched() {
        Account household = new Account(Name = 'Plain Household');
        insert household;
        Policy__c policy = new Policy__c(
            Name = 'PLAIN', Account__c = household.Id, Status__c = 'Active', Effective_Date__c = Date.today().addDays(-10), Expiration_Date__c = Date.today().addYears(1)
        );
        insert policy;
        Case plain;

        Test.startTest();
        System.runAs(outsider()) {
            // Everything our automation would act on for a claim: a policy, a serious severity, a closed status.
            plain = new Case(Subject = 'Printer is jammed', Status = 'Closed', Policy__c = policy.Id, Severity__c = 'Catastrophic', Reserve_Amount__c = 9000, SIU_Referral__c = true);
            insert as system plain;
            update as system new Case(Id = plain.Id, Description = 'Still jammed.', Reserve_Amount__c = 12000);
        }
        Test.stopTest();

        Case saved = [SELECT RecordTypeId, AccountId, ContactId, Priority, Closed_On__c, Coverage_Check__c FROM Case WHERE Id = :plain.Id];
        Assert.areNotEqual(claimType, saved.RecordTypeId, 'The case is not a claim');
        Assert.isNull(saved.AccountId, 'The customer is not filled in from the policy');
        Assert.isNull(saved.Closed_On__c, 'No closing day is stamped');
        Assert.isNull(saved.Coverage_Check__c, 'No coverage check is written');
        Assert.areNotEqual('High', saved.Priority, 'Priority is left as the org set it');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE WhatId = :plain.Id], 'No follow-up task is created');
        Assert.areEqual(0, AntsuranceCaseAutomation.alertsSent, 'No alert is sent');
        Decimal incurred = [SELECT Incurred_Losses__c FROM Policy__c WHERE Id = :policy.Id].Incurred_Losses__c;
        Assert.isTrue(incurred == null || incurred == 0, 'Nothing is added to the policy\'s losses');
    }

    @IsTest
    static void onlyOurRecordTypesAreSelected() {
        Id serviceType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId();
        List<Case> mixed = new List<Case>{ new Case(Subject = 'Plain'), new Case(Subject = 'Claim', RecordTypeId = claimType), new Case(Subject = 'Request', RecordTypeId = serviceType) };

        List<Case> ours = AntsuranceCaseAutomation.ours(mixed);

        Assert.areEqual(2, ours.size(), 'The case with no record type is left out');
        Assert.areEqual('Claim', ours[0].Subject, 'Claims are ours');
        Assert.areEqual('Request', ours[1].Subject, 'Policy service requests are ours');

        // The before-save step leaves a case that is not ours exactly as it was handed over.
        Case plain = new Case(Subject = 'Plain', Status = 'Closed', Severity__c = 'High');
        AntsuranceCaseAutomation.prepare(new List<Case>{ plain }, null);
        Assert.isNull(plain.Closed_On__c, 'Not stamped');
        Assert.isNull(plain.Priority, 'Not prioritized');
    }

    @IsTest
    static void aPlainOpportunityIsSavedUntouched() {
        Account household = new Account(Name = 'Plain Household');
        insert household;
        Policy__c policy = new Policy__c(
            Name = 'PLAIN', Account__c = household.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
            Effective_Date__c = Date.today(), Expiration_Date__c = Date.today().addYears(1), Annual_Premium__c = 1200
        );
        insert policy;
        Opportunity plain;

        Test.startTest();
        System.runAs(outsider()) {
            plain = new Opportunity(Name = 'Printer contract', AccountId = household.Id, StageName = 'Prospecting', CloseDate = Date.today());
            insert as system plain;
            // Won, and pointing at a policy: what binding a policy sale looks like, on an opportunity that is not one.
            update as system new Opportunity(Id = plain.Id, StageName = 'Closed Won', Policy__c = policy.Id);
        }
        Test.stopTest();

        Opportunity saved = [SELECT RecordType.DeveloperName, IsWon FROM Opportunity WHERE Id = :plain.Id];
        Assert.areNotEqual('Policy_Sale', saved.RecordType?.DeveloperName, 'The opportunity is not a policy sale');
        Assert.isTrue(saved.IsWon, 'It was won');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Coverage__c WHERE Policy__c = :policy.Id], 'The policy is not filled in from it');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Participant__c WHERE Policy__c = :policy.Id], 'No participants are added');
    }
}
