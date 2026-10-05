/**
 * @description What happens automatically when a claim or policy service request is saved:
 * the customer and contact are filled in from the policy, a claim's priority follows its severity,
 * the policy is checked against the date of loss, follow-up tasks are created for the owner, and the
 * policy's incurred losses are kept in step with its claims.
 * Runs in system mode from AntsuranceCaseTrigger so it works whoever saves the case.
 * Only claims and policy service requests are touched: in an org that has cases of its own, those pass
 * through this class unread and unchanged.
 */
public without sharing class AntsuranceCaseAutomation {
    @TestVisible
    private static final String IN_FORCE = 'In force on date of loss';
    @TestVisible
    private static final String OUTSIDE_TERM = 'Outside policy term';
    /** The first task on a new claim when nobody is named on it. */
    @TestVisible
    private static final String FIRST_CALL = 'Contact the insured and confirm the loss';
    @TestVisible
    private static final String NOT_IN_FORCE = 'Policy not in force';
    private static final Set<String> SERIOUS = new Set<String>{ 'High', 'Catastrophic' };
    // A lapsed or cancelled policy does not respond to a loss even inside its original term.
    private static final Set<String> NOT_COVERING = new Set<String>{ 'Quoted', 'Lapsed', 'Cancelled' };
    private static final Map<String, String> REQUEST_TASKS = new Map<String, String>{
        'Add Driver' => 'Collect the new driver\'s license details',
        'Remove Driver' => 'Confirm the driver no longer has access to the vehicles',
        'Add Vehicle' => 'Collect VIN, garaging address and lienholder for the new vehicle',
        'Change Address' => 'Confirm the new address and the date it takes effect',
        'Change Coverage' => 'Quote the coverage change and confirm the premium difference',
        'Billing Question' => 'Review the billing history and reply to the policyholder',
        'Certificate of Insurance' => 'Issue the certificate and send it to the certificate holder',
        'Policy Document Request' => 'Send the requested policy documents',
        'Cancel Policy' => 'Confirm the cancellation date and any refund due'
    };

    private static Id claimType {
        get {
            if (claimType == null) {
                claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim')?.getRecordTypeId();
            }
            return claimType;
        }
        set;
    }

    private static Set<String> closedStatuses {
        get {
            if (closedStatuses == null) {
                closedStatuses = new Set<String>();
                for (CaseStatus status : [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = TRUE]) {
                    closedStatuses.add(status.MasterLabel);
                }
            }
            return closedStatuses;
        }
        set;
    }

    private static Id serviceType {
        get {
            if (serviceType == null) {
                serviceType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service')?.getRecordTypeId();
            }
            return serviceType;
        }
        set;
    }

    /**
     * @description The cases this automation owns: claims and policy service requests. A case of any other
     * record type, or of none, belongs to the rest of the org and is left out of everything below.
     * @param records The cases in the trigger
     * @return The ones that are ours, in the same order
     */
    @TestVisible
    private static List<Case> ours(List<Case> records) {
        List<Case> mine = new List<Case>();
        for (Case record : records) {
            if (record.RecordTypeId != null && (record.RecordTypeId == claimType || record.RecordTypeId == serviceType)) {
                mine.add(record);
            }
        }
        return mine;
    }

    /**
     * @description Before save: fills in the customer from the policy, aligns priority with severity
     * and records whether the policy covered the date of loss.
     * @param records The cases being saved
     * @param oldRecords Their previous values, or null on insert
     */
    public static void prepare(List<Case> records, Map<Id, Case> oldRecords) {
        records = ours(records);
        if (records.isEmpty()) {
            return;
        }
        Set<Id> policyIds = new Set<Id>();
        for (Case record : records) {
            if (record.Policy__c != null) {
                policyIds.add(record.Policy__c);
            }
        }
        Map<Id, Policy__c> policies = policyIds.isEmpty()
            ? new Map<Id, Policy__c>()
            : new Map<Id, Policy__c>(
                  [SELECT Account__c, Primary_Insured__c, Status__c, Effective_Date__c, Expiration_Date__c FROM Policy__c WHERE Id IN :policyIds]
              );

        for (Case record : records) {
            // Days open stops counting on the day a case closes, and starts again if it is reopened.
            if (!closedStatuses.contains(record.Status)) {
                record.Closed_On__c = null;
            } else if (record.Closed_On__c == null) {
                record.Closed_On__c = Date.today();
            }
            Case old = oldRecords?.get(record.Id);
            Policy__c policy = policies.get(record.Policy__c);
            if (policy != null) {
                if (record.AccountId == null) {
                    record.AccountId = policy.Account__c;
                }
                if (record.ContactId == null) {
                    record.ContactId = policy.Primary_Insured__c;
                }
            }
            if (record.RecordTypeId != claimType) {
                continue;
            }
            if (record.Severity__c != null && (old == null || old.Severity__c != record.Severity__c)) {
                record.Priority = SERIOUS.contains(record.Severity__c) ? 'High' : record.Severity__c;
            }
            record.Coverage_Check__c = coverageCheck(policy, record.Date_of_Loss__c);
        }
    }

    private static String coverageCheck(Policy__c policy, Date dateOfLoss) {
        if (policy == null || dateOfLoss == null) {
            return null;
        }
        if (dateOfLoss < policy.Effective_Date__c || dateOfLoss > policy.Expiration_Date__c) {
            return OUTSIDE_TERM;
        }
        return NOT_COVERING.contains(policy.Status__c) ? NOT_IN_FORCE : IN_FORCE;
    }

    /**
     * @description After save: creates the follow-up task a new claim or request needs, a coverage
     * review when the policy did not cover the loss, and an investigator task when a claim is referred to SIU.
     * @param records The saved cases
     * @param oldRecords Their previous values, or null on insert
     */
    public static void createFollowUps(List<Case> records, Map<Id, Case> oldRecords) {
        List<Task> tasks = new List<Task>();
        // The first call on a new claim names who to call, so four new claims are four different tasks in a list.
        Set<Id> callers = new Set<Id>();
        for (Case record : ours(records)) {
            if (record.RecordTypeId == claimType && oldRecords?.get(record.Id) == null && record.Status == 'New' && record.ContactId != null) {
                callers.add(record.ContactId);
            }
        }
        Map<Id, Contact> people = callers.isEmpty()
            ? new Map<Id, Contact>()
            : new Map<Id, Contact>([SELECT Name FROM Contact WHERE Id IN :callers WITH SYSTEM_MODE]);
        for (Case record : ours(records)) {
            Case old = oldRecords?.get(record.Id);
            Boolean isNew = old == null;
            if (record.RecordTypeId == claimType) {
                if (isNew && record.Status == 'New') {
                    tasks.add(task(record, firstCall(people.get(record.ContactId)), 1, SERIOUS.contains(record.Severity__c)));
                }
                Boolean coverageProblem = record.Coverage_Check__c == OUTSIDE_TERM || record.Coverage_Check__c == NOT_IN_FORCE;
                if (coverageProblem && (isNew || old.Coverage_Check__c != record.Coverage_Check__c)) {
                    tasks.add(task(record, 'Review coverage: ' + record.Coverage_Check__c.toLowerCase(), 1, true));
                }
                if (record.SIU_Referral__c && (isNew || !old.SIU_Referral__c)) {
                    tasks.add(task(record, 'SIU referral: assign an investigator', 2, true));
                }
            } else if (record.RecordTypeId == serviceType && isNew && record.Status == 'New' && REQUEST_TASKS.containsKey(record.Request_Type__c)) {
                tasks.add(task(record, REQUEST_TASKS.get(record.Request_Type__c), 2, record.Priority == 'High'));
            }
        }
        if (!tasks.isEmpty()) {
            insert tasks;
        }
    }

    /** The first task on a new claim, short enough to read whole in the Activity panel. */
    @TestVisible
    private static String firstCall(Contact person) {
        return person?.Name == null ? FIRST_CALL : ('Call ' + person.Name + ' to confirm the loss').left(80);
    }

    private static Task task(Case record, String subject, Integer businessDays, Boolean isUrgent) {
        Task followUp = new Task(
            WhatId = record.Id,
            WhoId = record.ContactId,
            Subject = subject,
            ActivityDate = addBusinessDays(Date.today(), businessDays),
            Priority = isUrgent ? 'High' : 'Normal',
            Status = 'Not Started'
        );
        // A queue cannot own a task, so those fall to whoever saved the case.
        if (record.OwnerId.getSObjectType() == User.SObjectType) {
            followUp.OwnerId = record.OwnerId;
        }
        return followUp;
    }

    /** The date a number of working days after a start date, skipping weekends. */
    @TestVisible
    private static Date addBusinessDays(Date start, Integer businessDays) {
        Date result = start;
        Integer remaining = businessDays;
        // 1 January 1900 was a Monday, so days since then modulo 7 gives 5 for Saturday and 6 for Sunday.
        Date monday = Date.newInstance(1900, 1, 1);
        while (remaining > 0) {
            result = result.addDays(1);
            if (Math.mod(monday.daysBetween(result), 7) < 5) {
                remaining--;
            }
        }
        return result;
    }

    /**
     * @description After a claim is saved, deleted or restored: brings Incurred_Losses__c on its policy up to
     * date. Incurred is the higher of reserve and paid for each claim, added up across the policy's claims.
     * @param records The claims that changed
     * @param oldRecords Their previous values on update, otherwise null
     */
    public static void rollUpLosses(List<Case> records, Map<Id, Case> oldRecords) {
        Set<Id> policyIds = new Set<Id>();
        for (Case record : records) {
            Case old = oldRecords?.get(record.Id);
            Boolean changed =
                old == null ||
                old.Policy__c != record.Policy__c ||
                old.Reserve_Amount__c != record.Reserve_Amount__c ||
                old.Paid_Amount__c != record.Paid_Amount__c ||
                old.RecordTypeId != record.RecordTypeId;
            // A case that is not a claim now and was not one before is none of ours, whatever else changed on it.
            Boolean isOrWasClaim = claimType != null && (record.RecordTypeId == claimType || old?.RecordTypeId == claimType);
            if (!changed || !isOrWasClaim) {
                continue;
            }
            if (record.Policy__c != null) {
                policyIds.add(record.Policy__c);
            }
            // A claim moved to another policy changes the total on the one it left as well.
            if (old?.Policy__c != null) {
                policyIds.add(old.Policy__c);
            }
        }
        if (policyIds.isEmpty()) {
            return;
        }

        Map<Id, Decimal> incurredByPolicy = new Map<Id, Decimal>();
        for (Id policyId : policyIds) {
            incurredByPolicy.put(policyId, 0);
        }
        for (Case claim : [SELECT Policy__c, Reserve_Amount__c, Paid_Amount__c FROM Case WHERE Policy__c IN :policyIds AND RecordTypeId = :claimType]) {
            Decimal reserve = claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c;
            Decimal paid = claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c;
            incurredByPolicy.put(claim.Policy__c, incurredByPolicy.get(claim.Policy__c) + Math.max(reserve, paid));
        }
        List<Policy__c> policies = new List<Policy__c>();
        for (Id policyId : incurredByPolicy.keySet()) {
            policies.add(new Policy__c(Id = policyId, Incurred_Losses__c = incurredByPolicy.get(policyId)));
        }
        update policies;
    }

    // Counts the alerts sent in this transaction, so a test can check them without reading the bell.
    @TestVisible
    private static Integer alertsSent = 0;

    /**
     * @description After save: sends a bell notification to a claim's owner when a serious claim comes in,
     * when a claim becomes serious, or when it is referred to the Special Investigations Unit.
     * A failed notification never blocks the save.
     * @param records The saved cases
     * @param oldRecords Their previous values, or null on insert
     */
    public static void sendAlerts(List<Case> records, Map<Id, Case> oldRecords) {
        Map<Id, String> titles = new Map<Id, String>();
        for (Case record : records) {
            // A queue cannot receive a bell notification, only a person.
            if (claimType == null || record.RecordTypeId != claimType || record.OwnerId.getSObjectType() != User.SObjectType) {
                continue;
            }
            Case old = oldRecords?.get(record.Id);
            if (SERIOUS.contains(record.Severity__c) && (old == null || !SERIOUS.contains(old.Severity__c))) {
                titles.put(record.Id, record.Severity__c + ' severity claim ' + (old == null ? 'filed' : 'upgraded'));
            } else if (record.SIU_Referral__c && (old == null || !old.SIU_Referral__c)) {
                titles.put(record.Id, 'Claim referred to SIU');
            }
        }
        if (titles.isEmpty()) {
            return;
        }
        List<CustomNotificationType> alertTypes = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'Antsurance_Claim_Alert' LIMIT 1];
        if (alertTypes.isEmpty()) {
            return;
        }
        for (Case claim : [SELECT Id, Subject, OwnerId, Account.Name, Policy__r.Name, Estimated_Loss__c FROM Case WHERE Id IN :titles.keySet()]) {
            String body = claim.Subject + '. ' + claim.Account.Name + ', policy ' + claim.Policy__r.Name;
            if (claim.Estimated_Loss__c != null) {
                body += ', estimated at $' + claim.Estimated_Loss__c.setScale(0).format();
            }
            Messaging.CustomNotification alert = new Messaging.CustomNotification();
            alert.setNotificationTypeId(alertTypes[0].Id);
            alert.setTitle(titles.get(claim.Id));
            alert.setBody(body + '.');
            alert.setTargetId(claim.Id);
            try {
                alert.send(new Set<String>{ claim.OwnerId });
                alertsSent++;
            } catch (Exception problem) {
                // The claim is saved either way; the alert is a courtesy.
                System.debug(LoggingLevel.WARN, 'Claim alert not sent: ' + problem.getMessage());
            }
        }
    }
}
