/**
 * Policy automation. All logic lives in AntsurancePolicyAutomation.
 */
trigger AntsurancePolicyTrigger on Policy__c(before insert, before update) {
    AntsurancePolicyAutomation.stampPolicyholder(Trigger.new);
}
