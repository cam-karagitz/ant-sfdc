@IsTest
private class AntsurancePolicyAutomationTest {
    private static Policy__c policyFor(Account customer, String name) {
        Date start = Date.today().addDays(-30);
        return new Policy__c(Name = name, Account__c = customer.Id, Status__c = 'Active', Effective_Date__c = start, Expiration_Date__c = start.addYears(1));
    }

    @IsTest
    static void aNewPolicyCarriesItsPolicyholdersName() {
        Account reyes = new Account(Name = 'Reyes Household');
        Account okafor = new Account(Name = 'Okafor Household');
        insert new List<Account>{ reyes, okafor };

        Test.startTest();
        insert new List<Policy__c>{ policyFor(reyes, 'ANT-PA-1'), policyFor(reyes, 'ANT-HO-1'), policyFor(okafor, 'ANT-PA-2') };
        Test.stopTest();

        Map<String, String> holders = new Map<String, String>();
        for (Policy__c policy : [SELECT Name, Policyholder_Name__c FROM Policy__c]) {
            holders.put(policy.Name, policy.Policyholder_Name__c);
        }
        Assert.areEqual('Reyes Household', holders.get('ANT-PA-1'), 'Each policy carries the name of the customer it belongs to');
        Assert.areEqual('Reyes Household', holders.get('ANT-HO-1'), 'Including a second policy for the same customer');
        Assert.areEqual('Okafor Household', holders.get('ANT-PA-2'), 'And a policy for another customer carries that customer\'s name');
    }

    @IsTest
    static void anEmptyNameIsFilledAgainOnTheNextSave() {
        Account reyes = new Account(Name = 'Reyes Household');
        insert reyes;
        Policy__c policy = policyFor(reyes, 'ANT-PA-1');
        insert policy;

        Test.startTest();
        update new Policy__c(Id = policy.Id, Policyholder_Name__c = null);
        Test.stopTest();

        Assert.areEqual('Reyes Household', [SELECT Policyholder_Name__c FROM Policy__c WHERE Id = :policy.Id].Policyholder_Name__c, 'A cleared name comes back on save');
    }
}
