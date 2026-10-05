/**
 * When a policy sale is bound to a new policy, fills that policy in. All logic lives in AntsurancePolicyContents.
 * Opportunities of any other record type are not ours and are skipped.
 */
trigger AntsuranceOpportunityTrigger on Opportunity(after update) {
    // Only policy sales are ours. Any other opportunity in the org passes through untouched.
    Id policySale = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale')?.getRecordTypeId();
    Set<Id> boundPolicies = new Set<Id>();
    for (Opportunity sale : Trigger.new) {
        if (policySale == null || sale.RecordTypeId != policySale) {
            continue;
        }
        Opportunity before = Trigger.oldMap.get(sale.Id);
        if (sale.IsWon && sale.Policy__c != null && (!before.IsWon || before.Policy__c != sale.Policy__c)) {
            boundPolicies.add(sale.Policy__c);
        }
    }
    if (!boundPolicies.isEmpty()) {
        AntsurancePolicyContents.buildFor(boundPolicies);
    }
}
