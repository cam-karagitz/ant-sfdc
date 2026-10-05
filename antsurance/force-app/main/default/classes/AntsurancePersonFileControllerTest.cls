@IsTest
private class AntsurancePersonFileControllerTest {
    @TestSetup
    static void createAHouseholdWithTwoPolicies() {
        Account household = new Account(Name = 'Harbor Household');
        insert household;
        Contact mina = new Contact(FirstName = 'Mina', LastName = 'Harbor', AccountId = household.Id);
        Contact joel = new Contact(FirstName = 'Joel', LastName = 'Harbor', AccountId = household.Id);
        insert new List<Contact>{ mina, joel };
        Date today = Date.today();
        Policy__c auto = new Policy__c(
            Name = 'ANT-PA-1', Account__c = household.Id, Status__c = 'Active', Line_of_Business__c = 'Personal Auto', Annual_Premium__c = 1800,
            Effective_Date__c = today.addMonths(-6), Expiration_Date__c = today.addMonths(6)
        );
        Policy__c home = new Policy__c(
            Name = 'ANT-HO-1', Account__c = household.Id, Status__c = 'Active', Line_of_Business__c = 'Homeowners', Annual_Premium__c = 1400,
            Effective_Date__c = today.addMonths(-6), Expiration_Date__c = today.addMonths(6)
        );
        insert new List<Policy__c>{ auto, home };
        insert new List<Policy_Participant__c>{
            new Policy_Participant__c(Name = 'Mina Harbor, Named Insured', Policy__c = auto.Id, Contact__c = mina.Id, Role__c = 'Named Insured', Status__c = 'Active', Is_Primary__c = true),
            new Policy_Participant__c(Name = 'Mina Harbor, Driver', Policy__c = auto.Id, Contact__c = mina.Id, Role__c = 'Driver', Status__c = 'Active'),
            new Policy_Participant__c(Name = 'Joel Harbor, Driver', Policy__c = auto.Id, Contact__c = joel.Id, Role__c = 'Driver', Status__c = 'Active', Relationship_to_Insured__c = 'Spouse or Partner'),
            new Policy_Participant__c(Name = 'Mina Harbor, Named Insured', Policy__c = home.Id, Contact__c = mina.Id, Role__c = 'Named Insured', Status__c = 'Active', Is_Primary__c = true),
            new Policy_Participant__c(Name = 'First Prairie Bank, Lienholder', Policy__c = home.Id, Role__c = 'Lienholder', Status__c = 'Active')
        };
        Map<String, Schema.RecordTypeInfo> caseTypes = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName();
        insert new List<Case>{
            new Case(
                Subject = 'Rear-ended at a light', AccountId = household.Id, ContactId = mina.Id, Policy__c = auto.Id, Status = 'Under Investigation',
                RecordTypeId = caseTypes.get('Claim').getRecordTypeId(), Date_of_Loss__c = today.addDays(-9), Paid_Amount__c = 1200, Reserve_Amount__c = 5000
            ),
            new Case(
                Subject = 'Change the mailing address', AccountId = household.Id, ContactId = mina.Id, Policy__c = home.Id, Status = 'New',
                RecordTypeId = caseTypes.get('Policy_Service').getRecordTypeId(), Reported_Date__c = today.addDays(-2)
            ),
            new Case(
                Subject = 'Windshield chip', AccountId = household.Id, ContactId = joel.Id, Policy__c = auto.Id, Status = 'New',
                RecordTypeId = caseTypes.get('Claim').getRecordTypeId(), Date_of_Loss__c = today.addDays(-1)
            )
        };
    }

    private static Id participant(String name, String policyName) {
        return [SELECT Id FROM Policy_Participant__c WHERE Name = :name AND Policy__r.Name = :policyName LIMIT 1].Id;
    }

    @IsTest
    static void gathersEveryPolicyAndRoleTheCasesThatNameThemAndWhoElseIsOnThePolicy() {
        Id minaDriving = participant('Mina Harbor, Driver', 'ANT-PA-1');

        Test.startTest();
        AntsurancePersonFileController.PersonFile file = AntsurancePersonFileController.getFile(minaDriving);
        Test.stopTest();

        Assert.areEqual('Mina Harbor', file.personName, 'The person is named from the contact');
        Assert.areEqual('Mina', file.firstName, 'And has a first name to speak of them by');
        Assert.areEqual(2, file.policies.size(), 'Both of her policies are listed, once each');
        Assert.isTrue(file.policies[0].isThisPolicy, 'The policy being viewed comes first');
        Assert.areEqual('ANT-PA-1', file.policies[0].policyName, 'It is the auto policy');
        Assert.areEqual(new List<String>{ 'Named Insured', 'Driver' }, file.policies[0].roles, 'Her two roles on it are one row, the primary one first');
        Assert.areEqual('Homeowners', file.policies[1].line, 'The other policy says its line');
        Assert.isFalse(file.policies[1].isThisPolicy, 'And is not marked as this one');

        Assert.areEqual(2, file.caseCount, 'Only the cases that name her are counted');
        Assert.areEqual(1, file.openClaimCount, 'One of them is an open claim');
        Assert.areEqual(2, file.cases.size(), 'Both are listed');
        Set<String> kinds = new Set<String>();
        for (AntsurancePersonFileController.CaseRow row : file.cases) {
            kinds.add(row.kind);
            if (row.kind == 'Claim') {
                Assert.areEqual(Date.today().addDays(-9), row.happenedOn, 'A claim is dated by its loss');
                Assert.isNotNull(row.incurred, 'A claim with money on it says how much');
                Assert.areEqual('ANT-PA-1', row.policyName, 'And names its policy');
            } else {
                Assert.areEqual(Date.today().addDays(-2), row.happenedOn, 'A request is dated by the day it was reported');
                Assert.isNull(row.incurred, 'A request has no money on it');
            }
        }
        Assert.areEqual(new Set<String>{ 'Claim', 'Service request' }, kinds, 'A claim and a service request');

        Assert.areEqual(1, file.others.size(), 'Her own other role is not someone else');
        Assert.areEqual('Joel Harbor', file.others[0].name, 'The other driver is');
        Assert.areEqual('Driver', file.others[0].role, 'With his role');
        Assert.areEqual('Spouse or Partner', file.others[0].relationship, 'And his relationship to the insured');
    }

    @IsTest
    static void aParticipantWithNoContactStillShowsWhoElseIsOnThePolicy() {
        Id bank = participant('First Prairie Bank, Lienholder', 'ANT-HO-1');

        Test.startTest();
        AntsurancePersonFileController.PersonFile file = AntsurancePersonFileController.getFile(bank);
        Test.stopTest();

        Assert.isNull(file.contactId, 'There is no contact to look across');
        Assert.areEqual('First Prairie Bank', file.personName, 'The name comes from the participant');
        Assert.isTrue(file.policies.isEmpty(), 'So no policies are gathered');
        Assert.isTrue(file.cases.isEmpty(), 'And no cases');
        Assert.areEqual(1, file.others.size(), 'The named insured is still listed');
        Assert.areEqual('Mina Harbor', file.others[0].name, 'By name');
    }

    @IsTest
    static void aParticipantThatIsGoneGivesAMessageForThePerson() {
        Id gone = participant('Joel Harbor, Driver', 'ANT-PA-1');
        delete [SELECT Id FROM Policy_Participant__c WHERE Id = :gone];

        Test.startTest();
        String message;
        try {
            AntsurancePersonFileController.getFile(gone);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'A missing participant is reported, not thrown raw');
        Assert.isTrue(message.contains('could not be loaded'), 'In words for the person');
    }
}
