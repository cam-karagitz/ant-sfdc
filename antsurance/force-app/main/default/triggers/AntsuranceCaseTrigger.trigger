/**
 * Claim and policy service automation. All logic lives in AntsuranceCaseAutomation.
 */
trigger AntsuranceCaseTrigger on Case(before insert, before update, after insert, after update, after delete, after undelete) {
    if (Trigger.isBefore) {
        AntsuranceCaseAutomation.prepare(Trigger.new, Trigger.oldMap);
        return;
    }
    if (Trigger.isInsert || Trigger.isUpdate) {
        AntsuranceCaseAutomation.createFollowUps(Trigger.new, Trigger.oldMap);
        AntsuranceCaseAutomation.sendAlerts(Trigger.new, Trigger.oldMap);
    }
    AntsuranceCaseAutomation.rollUpLosses(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
