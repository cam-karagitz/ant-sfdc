/**
 * @description Policy automation, called from AntsurancePolicyTrigger. Runs in system mode so it behaves
 * the same whoever saves the policy.
 */
public without sharing class AntsurancePolicyAutomation {
    /**
     * @description Before save: copies the policyholder's name onto the policy as text. Search matches a
     * record's own text, not the name of the customer it belongs to, so this is what lets a search for
     * "Reyes" find the Reyes policies. A policy cannot move to another customer, so the name is read
     * once, when the policy is created or while the field is still empty.
     * @param policies The policies being saved
     */
    public static void stampPolicyholder(List<Policy__c> policies) {
        Set<Id> customerIds = new Set<Id>();
        for (Policy__c policy : policies) {
            if (String.isBlank(policy.Policyholder_Name__c) && policy.Account__c != null) {
                customerIds.add(policy.Account__c);
            }
        }
        if (customerIds.isEmpty()) {
            return;
        }
        Map<Id, Account> customers = new Map<Id, Account>([SELECT Name FROM Account WHERE Id IN :customerIds]);
        for (Policy__c policy : policies) {
            if (String.isBlank(policy.Policyholder_Name__c) && customers.containsKey(policy.Account__c)) {
                policy.Policyholder_Name__c = customers.get(policy.Account__c).Name;
            }
        }
    }
}
