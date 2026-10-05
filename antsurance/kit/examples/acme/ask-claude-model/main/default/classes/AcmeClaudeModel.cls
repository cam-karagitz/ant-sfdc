/**
 * @description The smallest model of an org's own data for the Ask Claude chat: one invented object,
 * Acme_Policy__c. The chat already reads any org's schema by itself (AntsuranceClaudeModel). A class
 * like this one adds what a schema cannot say: what a record is called, the facts worth working out
 * for Claude, and the starting points to offer. It extends AntsuranceClaudeModel the way the full
 * app's own insurance model does, and overrides only what it has something to say about.
 */
public with sharing class AcmeClaudeModel extends AntsuranceClaudeModel {
    private static final String POLICY = 'Acme_Policy__c';

    /**
     * @description What a record of this object is called in a sentence.
     * @param objectName The object's API name
     * @return "policy" for an Acme policy; the object's own label for anything else
     */
    public override String wordFor(String objectName) {
        return objectName == POLICY ? 'policy' : super.wordFor(objectName);
    }

    /**
     * @description The query that reads a record's facts, without its WHERE clause.
     * @param objectName The record's object
     * @return For an Acme policy, the fields Claude should see; for anything else, what the schema gives
     */
    public override String factsQuery(String objectName) {
        if (objectName != POLICY) {
            return super.factsQuery(objectName);
        }
        return 'SELECT Name, Customer__r.Name, Customer_Name__c, Policy_Status__c, Start_Date__c, End_Date__c, Region__c FROM Acme_Policy__c';
    }

    /**
     * @description Adds what a plain read of the record does not carry: whether the policy is in force
     * today and how many days it still runs.
     * @param facts The record's facts so far, to add to
     * @param record The record as the facts query returned it
     */
    public override void addFacts(Map<String, Object> facts, SObject record) {
        super.addFacts(facts, record);
        if (!(record instanceof Acme_Policy__c)) {
            return;
        }
        Acme_Policy__c policy = (Acme_Policy__c) record;
        Date today = Date.today();
        Boolean running = policy.Policy_Status__c == 'In Force' && (policy.Start_Date__c == null || policy.Start_Date__c <= today) && (policy.End_Date__c == null || policy.End_Date__c >= today);
        facts.put('inForceToday', running);
        if (policy.End_Date__c != null) {
            facts.put('daysUntilEnd', today.daysBetween(policy.End_Date__c));
        }
    }

    /**
     * @description The starting points the chat's components show, with two about Acme policies.
     * @return The words
     */
    public override AntsuranceClaudeModel.Words words() {
        AntsuranceClaudeModel.Words words = super.words();
        if (Schema.SObjectType.Acme_Policy__c.isAccessible()) {
            AntsuranceClaudeModel.Starter ending = new AntsuranceClaudeModel.Starter(
                'utility:date_time',
                'Policies ending soon',
                'In force and ending within 60 days',
                'Which Acme policies in force end within the next 60 days? Show them as a list, soonest first.'
            );
            if (words.starters.isEmpty()) {
                words.starters.add(ending);
            } else {
                words.starters.add(0, ending);
            }
            words.recordStarters.put(
                POLICY,
                new List<AntsuranceClaudeModel.Starter>{
                    AntsuranceClaudeModel.summarize(),
                    new AntsuranceClaudeModel.Starter('utility:date_time', 'Renewal', 'When it ends and what to do first', 'When does this policy end, and what should happen before then?')
                }
            );
            words.objectWords.put(POLICY, 'policies');
        }
        return words;
    }
}
