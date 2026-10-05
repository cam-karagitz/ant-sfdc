/**
 * @description Gives every open claim a coverage check that is up to date, in the background.
 * Salesforce allows one Claude call in a transaction, so this runs as a batch of one claim at a
 * time: start it with a batch size of 1, as AntsuranceDemoPrep.checkCoverageEverywhere() does.
 *
 * A claim whose check still stands is left alone and Claude is not asked. A check that fails, for
 * a timeout say, leaves the claim as it was; AntsuranceDemoPrep.outOfDate() then lists the claim
 * as not checked, and running the job again tries it once more.
 *
 * It refuses to run in a production org, as the rest of the demo prep does.
 */
public with sharing class AntsuranceDemoPrepCoverage implements Database.Batchable<SObject>, Database.AllowsCallouts {
    /**
     * @description The open claims that have a policy to be read against, most serious and most recent first.
     * @param context The job
     * @return The claims
     * @throws AntsuranceDemoPrep.PrepException in a production org
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        AntsuranceDemoPrep.guard();
        return Database.getQueryLocator(
            [
                SELECT Id
                FROM Case
                WHERE RecordType.DeveloperName = 'Claim' AND Status NOT IN ('Closed', 'Denied') AND Policy__c != NULL
                ORDER BY Severity__c DESC, Reported_Date__c DESC
            ]
        );
    }

    /**
     * @description Checks coverage on the claim it is given, unless the stored check still stands.
     * @param context The job
     * @param claims One claim: the job is started with a batch size of 1
     */
    public void execute(Database.BatchableContext context, List<Case> claims) {
        // Only the first is taken: a second Claude call in the same transaction would share its 120 seconds.
        if (!claims.isEmpty()) {
            AntsuranceClaimsAssistantAnalysis.checkCoverageStep(claims[0].Id, false);
        }
    }

    /**
     * @description Nothing to tidy up: each check is stored on its claim as it is written.
     * @param context The job
     */
    public void finish(Database.BatchableContext context) {
        return;
    }
}
