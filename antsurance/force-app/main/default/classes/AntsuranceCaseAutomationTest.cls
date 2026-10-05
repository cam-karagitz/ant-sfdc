@IsTest
private class AntsuranceCaseAutomationTest {
    private static Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
    private static Id serviceType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId();

    @TestSetup
    static void createPolicies() {
        Account household = new Account(Name = 'Harbor Household');
        insert household;
        Contact insured = new Contact(LastName = 'Harbor', AccountId = household.Id);
        insert insured;
        Date start = Date.today().addDays(-100);
        insert new List<Policy__c>{
            new Policy__c(Name = 'ACTIVE', Account__c = household.Id, Primary_Insured__c = insured.Id, Status__c = 'Active', Effective_Date__c = start, Expiration_Date__c = start.addYears(1)),
            new Policy__c(Name = 'LAPSED', Account__c = household.Id, Primary_Insured__c = insured.Id, Status__c = 'Lapsed', Effective_Date__c = start, Expiration_Date__c = start.addYears(1))
        };
    }

    private static Case claim(String policyName, Integer daysSinceLoss, String severity) {
        return new Case(
            RecordTypeId = claimType, Policy__c = [SELECT Id FROM Policy__c WHERE Name = :policyName].Id, Subject = 'Test claim', Status = 'New',
            Date_of_Loss__c = Date.today().addDays(-daysSinceLoss), Severity__c = severity
        );
    }

    @IsTest
    static void aClaimWithNobodyNamedStillGetsItsFirstCall() {
        Assert.areEqual(AntsuranceCaseAutomation.FIRST_CALL, AntsuranceCaseAutomation.firstCall(null), 'With nobody to name, the task says what to do');
        Assert.areEqual(AntsuranceCaseAutomation.FIRST_CALL, AntsuranceCaseAutomation.firstCall(new Contact()), 'A contact with no name reads the same');
    }

    private static List<String> taskSubjects(Id caseId) {
        List<String> subjects = new List<String>();
        for (Task followUp : [SELECT Subject FROM Task WHERE WhatId = :caseId ORDER BY Subject]) {
            subjects.add(followUp.Subject);
        }
        return subjects;
    }

    @IsTest
    static void aNewClaimIsFilledInCheckedAndFollowedUp() {
        Case record = claim('ACTIVE', 3, 'Catastrophic');

        Test.startTest();
        insert record;
        Test.stopTest();

        Case saved = [SELECT Account.Name, Contact.LastName, Priority, Coverage_Check__c FROM Case WHERE Id = :record.Id];
        Assert.areEqual('Harbor Household', saved.Account.Name, 'The customer comes from the policy');
        Assert.areEqual('Harbor', saved.Contact.LastName, 'The contact is the primary insured');
        Assert.areEqual('High', saved.Priority, 'A catastrophic claim is high priority');
        Assert.areEqual(AntsuranceCaseAutomation.IN_FORCE, saved.Coverage_Check__c, 'The policy covered the date of loss');

        Task followUp = [SELECT Subject, Priority, ActivityDate, WhoId, OwnerId FROM Task WHERE WhatId = :record.Id];
        Assert.areEqual('Call Harbor to confirm the loss', followUp.Subject, 'The adjuster is told who to call');
        Assert.areEqual('High', followUp.Priority, 'A serious claim gets an urgent task');
        Assert.areEqual(AntsuranceCaseAutomation.addBusinessDays(Date.today(), 1), followUp.ActivityDate, 'Due the next working day');
        Assert.areEqual(UserInfo.getUserId(), followUp.OwnerId, 'Assigned to the claim owner');
    }

    @IsTest
    static void lossesTheTermOrALapsedPolicyDoNotCoverAreFlagged() {
        Case beforeTerm = claim('ACTIVE', 200, 'Low');
        Case lapsed = claim('LAPSED', 3, 'Medium');

        Test.startTest();
        insert new List<Case>{ beforeTerm, lapsed };
        Test.stopTest();

        Map<Id, Case> saved = new Map<Id, Case>([SELECT Coverage_Check__c, Priority FROM Case]);
        Assert.areEqual(AntsuranceCaseAutomation.OUTSIDE_TERM, saved.get(beforeTerm.Id).Coverage_Check__c, 'The loss was before the policy started');
        Assert.areEqual(AntsuranceCaseAutomation.NOT_IN_FORCE, saved.get(lapsed.Id).Coverage_Check__c, 'A lapsed policy does not cover the loss');
        Assert.areEqual('Low', saved.get(beforeTerm.Id).Priority, 'Priority follows a low severity');
        Assert.areEqual(
            new List<String>{ 'Call Harbor to confirm the loss', 'Review coverage: policy not in force' },
            taskSubjects(lapsed.Id),
            'A coverage review is added to the usual follow-up'
        );
    }

    @IsTest
    static void changesAfterIntakeAreReflected() {
        Case record = claim('ACTIVE', 3, 'Low');
        insert record;

        Test.startTest();
        record.Severity__c = 'High';
        record.SIU_Referral__c = true;
        record.Date_of_Loss__c = Date.today().addDays(-400);
        update record;
        Test.stopTest();

        Case saved = [SELECT Priority, Coverage_Check__c FROM Case WHERE Id = :record.Id];
        Assert.areEqual('High', saved.Priority, 'Priority follows the new severity');
        Assert.areEqual(AntsuranceCaseAutomation.OUTSIDE_TERM, saved.Coverage_Check__c, 'The coverage check follows the new date of loss');
        Assert.areEqual(
            new List<String>{
                'Call Harbor to confirm the loss',
                'Review coverage: outside policy term',
                'SIU referral: assign an investigator'
            },
            taskSubjects(record.Id),
            'One task for intake, one for coverage and one for the referral'
        );

        update record;
        Assert.areEqual(3, taskSubjects(record.Id).size(), 'Saving again adds no duplicate tasks');
    }

    @IsTest
    static void aServiceRequestGetsTheTaskForItsType() {
        Case request = new Case(
            RecordTypeId = serviceType, Policy__c = [SELECT Id FROM Policy__c WHERE Name = 'ACTIVE'].Id, Subject = 'Add a teen driver',
            Status = 'New', Request_Type__c = 'Add Driver'
        );

        Test.startTest();
        insert request;
        Test.stopTest();

        Case saved = [SELECT AccountId, Coverage_Check__c FROM Case WHERE Id = :request.Id];
        Assert.isNotNull(saved.AccountId, 'The customer comes from the policy');
        Assert.isNull(saved.Coverage_Check__c, 'Only claims get a coverage check');
        Assert.areEqual(new List<String>{ 'Collect the new driver\'s license details' }, taskSubjects(request.Id), 'The task matches the request type');
    }

    @IsTest
    static void paymentsCannotExceedTheReserve() {
        Case record = claim('ACTIVE', 3, 'Low');
        record.Reserve_Amount__c = 1000;
        insert record;

        Test.startTest();
        record.Paid_Amount__c = 1500;
        Database.SaveResult result = Database.update(record, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Paying more than the reserve is blocked');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Raise the reserve first'), 'The message says what to do');
    }

    @IsTest
    static void businessDaysSkipWeekends() {
        Date friday = Date.newInstance(2026, 10, 2);
        Assert.areEqual(Date.newInstance(2026, 10, 5), AntsuranceCaseAutomation.addBusinessDays(friday, 1), 'Friday plus one working day is Monday');
        Assert.areEqual(Date.newInstance(2026, 10, 6), AntsuranceCaseAutomation.addBusinessDays(friday, 2), 'Friday plus two is Tuesday');
        Assert.areEqual(Date.newInstance(2026, 10, 7), AntsuranceCaseAutomation.addBusinessDays(Date.newInstance(2026, 10, 6), 1), 'Tuesday plus one is Wednesday');
    }

    @IsTest
    static void aPolicysIncurredLossesFollowItsClaims() {
        Case first = claim('ACTIVE', 5, 'Medium');
        first.Reserve_Amount__c = 10000;
        first.Paid_Amount__c = 2500;
        Case second = claim('ACTIVE', 9, 'Low');
        second.Reserve_Amount__c = 1000;
        Case request = new Case(RecordTypeId = serviceType, Policy__c = first.Policy__c, Subject = 'Not a claim', Request_Type__c = 'Billing Question');

        Test.startTest();
        insert new List<Case>{ first, second, request };
        Decimal afterInsert = [SELECT Incurred_Losses__c FROM Policy__c WHERE Name = 'ACTIVE'].Incurred_Losses__c;

        // Paid can only rise to the reserve, so raise both: paid now leads on the second claim.
        second.Reserve_Amount__c = 4000;
        second.Paid_Amount__c = 4000;
        update second;
        Decimal afterPayment = [SELECT Incurred_Losses__c FROM Policy__c WHERE Name = 'ACTIVE'].Incurred_Losses__c;

        first.Policy__c = [SELECT Id FROM Policy__c WHERE Name = 'LAPSED'].Id;
        update first;
        Decimal afterMove = [SELECT Incurred_Losses__c FROM Policy__c WHERE Name = 'ACTIVE'].Incurred_Losses__c;
        Decimal movedTo = [SELECT Incurred_Losses__c FROM Policy__c WHERE Name = 'LAPSED'].Incurred_Losses__c;

        delete second;
        Test.stopTest();

        Policy__c active = [SELECT Incurred_Losses__c, Loss_Ratio__c FROM Policy__c WHERE Name = 'ACTIVE'];
        Assert.areEqual(11000, afterInsert, 'Each claim counts its reserve, and a service request counts nothing');
        Assert.areEqual(14000, afterPayment, 'A changed reserve or payment updates the total');
        Assert.areEqual(4000, afterMove, 'A claim moved to another policy leaves this one');
        Assert.areEqual(10000, movedTo, 'And is counted on the policy it moved to');
        Assert.areEqual(0, active.Incurred_Losses__c, 'A deleted claim no longer counts');
    }

    @IsTest
    static void theOwnerIsAlertedToSeriousClaimsAndSiuReferrals() {
        Case minor = claim('ACTIVE', 5, 'Low');
        Case serious = claim('ACTIVE', 5, 'Catastrophic');

        Test.startTest();
        insert new List<Case>{ minor, serious };
        Assert.areEqual(1, AntsuranceCaseAutomation.alertsSent, 'Only the serious claim raises an alert when filed');

        update new Case(Id = minor.Id, SIU_Referral__c = true);
        Assert.areEqual(2, AntsuranceCaseAutomation.alertsSent, 'A referral to SIU raises one');

        update new Case(Id = minor.Id, Severity__c = 'High');
        Assert.areEqual(3, AntsuranceCaseAutomation.alertsSent, 'So does a claim that becomes serious');

        update new Case(Id = serious.Id, Description = 'More detail from the insured.');
        Test.stopTest();
        Assert.areEqual(3, AntsuranceCaseAutomation.alertsSent, 'An ordinary edit raises nothing');
    }

    @IsTest
    static void closingACaseStampsTheDayAndReopeningClearsIt() {
        Case minor = claim('ACTIVE', 5, 'Low');
        insert minor;
        Assert.isNull([SELECT Closed_On__c FROM Case WHERE Id = :minor.Id].Closed_On__c, 'An open claim has no closing day');

        update new Case(Id = minor.Id, Status = 'Closed');
        Assert.areEqual(Date.today(), [SELECT Closed_On__c FROM Case WHERE Id = :minor.Id].Closed_On__c, 'Closing stamps today');

        update new Case(Id = minor.Id, Status = 'Investigation');
        Assert.isNull([SELECT Closed_On__c FROM Case WHERE Id = :minor.Id].Closed_On__c, 'Reopening clears it');
    }
}
