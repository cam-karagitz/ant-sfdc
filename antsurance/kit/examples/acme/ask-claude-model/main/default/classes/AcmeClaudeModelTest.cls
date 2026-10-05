/**
 * The Acme model for the chat: that the chat uses it once the AI setting names it, what it adds for
 * an Acme policy, and that it leaves every other object to the model that reads the org's schema.
 * Each test chooses the model itself, so it passes whatever else the org holds.
 */
@IsTest
private class AcmeClaudeModelTest {
    private static Acme_Policy__c policy(String status, Integer startsInDays, Integer endsInDays) {
        Account customer = new Account(Name = 'Reyes Household');
        insert customer;
        Acme_Policy__c policy = new Acme_Policy__c(
            Customer__c = customer.Id,
            Customer_Name__c = customer.Name,
            Policy_Status__c = status,
            Start_Date__c = Date.today().addDays(startsInDays),
            End_Date__c = Date.today().addDays(endsInDays),
            Region__c = 'East'
        );
        insert policy;
        return policy;
    }

    @IsTest
    static void theChatUsesTheClassTheSettingNames() {
        AntsuranceClaudeModel.standIn = null;
        AntsuranceClaudeModel.found = null;
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Chat_Model_Class__c = 'AcmeClaudeModel');

        Assert.isTrue(AntsuranceClaudeModel.current() instanceof AcmeClaudeModel, 'With its name in Chat Model Class, the chat finds the org\'s own model');
        Assert.areEqual('policy', AntsuranceClaudeModel.current().wordFor('Acme_Policy__c'), 'And asks it what a record is called');
    }

    @IsTest
    static void theChatIsToldWhatASchemaCannotSay() {
        Acme_Policy__c policy = policy('In Force', -30, 45);
        AntsuranceClaudeModel.standIn = new AcmeClaudeModel();

        Test.startTest();
        String told = AntsuranceClaudeRecordFacts.describe(policy.Id);
        Test.stopTest();

        Assert.isTrue(AntsuranceClaudeModel.current() instanceof AcmeClaudeModel, 'The chat is using the Acme model');
        Assert.isNotNull(told, 'An Acme policy has facts');
        Assert.isTrue(told.contains('"inForceToday":true'), 'Claude is told the policy is in force today: ' + told);
        Assert.isTrue(told.contains('"daysUntilEnd":45'), 'And how many days it still runs: ' + told);
        Assert.isTrue(told.contains('Reyes Household'), 'And whose it is: ' + told);
        Assert.areEqual('policy', AntsuranceClaudeModel.current().wordFor('Acme_Policy__c'), 'A policy is called a policy');
    }

    @IsTest
    static void aPolicyThatHasEndedIsNotInForce() {
        Acme_Policy__c policy = policy('In Force', -400, -35);
        AntsuranceClaudeModel.standIn = new AcmeClaudeModel();

        String told = AntsuranceClaudeRecordFacts.describe(policy.Id);

        Assert.isTrue(told.contains('"inForceToday":false'), 'Past its end date it is not in force, whatever its status says: ' + told);
        Assert.isTrue(told.contains('"daysUntilEnd":-35'), told);
    }

    @IsTest
    static void aDraftWithNoEndDateIsNotInForceAndHasNoCountdown() {
        Account customer = new Account(Name = 'Okafor Household');
        insert customer;
        Acme_Policy__c draft = new Acme_Policy__c(Customer__c = customer.Id, Policy_Status__c = 'Draft', Region__c = 'West');
        insert draft;
        AntsuranceClaudeModel.standIn = new AcmeClaudeModel();

        String told = AntsuranceClaudeRecordFacts.describe(draft.Id);

        Assert.isTrue(told.contains('"inForceToday":false'), told);
        Assert.isFalse(told.contains('daysUntilEnd'), 'No end date, no countdown: ' + told);
    }

    @IsTest
    static void everythingElseIsLeftToTheSchema() {
        Account customer = new Account(Name = 'Reyes Household');
        insert customer;
        AcmeClaudeModel acme = new AcmeClaudeModel();
        AntsuranceClaudeModel plain = new AntsuranceClaudeModel();

        Assert.areEqual(plain.factsQuery('Account'), acme.factsQuery('Account'), 'An account is read exactly as the schema model reads it');
        Assert.areEqual(plain.wordFor('Account'), acme.wordFor('Account'), 'And called what its label says');
        Map<String, Object> facts = new Map<String, Object>();
        acme.addFacts(facts, customer);
        Assert.isTrue(facts.isEmpty(), 'Nothing is added to a record that is not an Acme policy');
    }

    @IsTest
    static void theStartingPointsIncludeThePolicies() {
        AntsuranceClaudeModel.Words words = new AcmeClaudeModel().words();

        Assert.areEqual('Policies ending soon', words.starters[0].title, 'The first starting point is about policies');
        Assert.areEqual(2, words.recordStarters.get('Acme_Policy__c').size(), 'A policy page has its own two');
        Assert.areEqual('policies', words.objectWords.get('Acme_Policy__c'), 'And the object has a word');
        Assert.isTrue(words.starters.size() > 1, 'The starting points the schema model offers are still there');
    }
}
