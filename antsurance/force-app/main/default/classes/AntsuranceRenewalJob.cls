/**
 * @description Daily renewal run. A policy in force that expires within the renewal window is moved to
 * Pending Renewal and, unless one is already open, gets a renewal opportunity at its current premium.
 * Schedule it from Anonymous Apex:
 *     System.schedule('Antsurance renewals', '0 0 6 * * ?', new AntsuranceRenewalJob());
 */
public without sharing class AntsuranceRenewalJob implements Schedulable {
    @TestVisible
    private static final Integer RENEWAL_WINDOW_DAYS = 45;
    private static final Integer MAX_POLICIES = 200;

    /**
     * @description Entry point for the scheduler.
     * @param context Supplied by the platform
     */
    public void execute(SchedulableContext context) {
        flagUpcomingRenewals();
    }

    /**
     * @description Flags policies entering the renewal window and opens their renewal opportunities.
     * @return The number of policies moved to Pending Renewal
     */
    public static Integer flagUpcomingRenewals() {
        Date windowEnd = Date.today().addDays(RENEWAL_WINDOW_DAYS);
        List<Policy__c> due = [
            SELECT Id, Name, Account__c, Account__r.Name, Account__r.OwnerId, Line_of_Business__c, Annual_Premium__c, Expiration_Date__c,
                (SELECT Id FROM Opportunities__r WHERE IsClosed = FALSE AND Type = 'Renewal' LIMIT 1)
            FROM Policy__c
            WHERE Status__c = 'Active' AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :windowEnd
            ORDER BY Expiration_Date__c
            LIMIT :MAX_POLICIES
        ];

        Id saleType = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId();
        List<Opportunity> renewals = new List<Opportunity>();
        // Only the status is written back, so the read-only fields queried above stay out of the update.
        List<Policy__c> flagged = new List<Policy__c>();
        for (Policy__c policy : due) {
            flagged.add(new Policy__c(Id = policy.Id, Status__c = 'Pending Renewal'));
            if (policy.Opportunities__r.isEmpty()) {
                renewals.add(new Opportunity(
                    RecordTypeId = saleType,
                    AccountId = policy.Account__c,
                    OwnerId = policy.Account__r.OwnerId,
                    Name = (policy.Account__r.Name + ' - ' + policy.Line_of_Business__c + ' renewal').left(120),
                    Type = 'Renewal',
                    StageName = 'Submission Received',
                    Line_of_Business__c = policy.Line_of_Business__c,
                    Amount = policy.Annual_Premium__c,
                    CloseDate = policy.Expiration_Date__c,
                    Policy__c = policy.Id
                ));
            }
        }
        update as system flagged;
        insert as system renewals;
        return flagged.size();
    }
}
