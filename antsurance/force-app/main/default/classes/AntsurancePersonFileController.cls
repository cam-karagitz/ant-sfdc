/**
 * @description What an adjuster or underwriter wants to know about a person on a policy, beyond the
 * one role the participant record holds: every policy the person is on and in what roles, the claims
 * and service requests that name them, and who else is on this policy. Everything is limited to what
 * the running user can see.
 */
public with sharing class AntsurancePersonFileController {
    @TestVisible
    private static final Integer MOST_CASES = 6;
    private static final Integer MOST_POLICIES = 20;
    private static final Integer MOST_OTHERS = 12;
    private static final String LOAD_ERROR = 'This person\'s policies and claims could not be loaded. Check your access to policies and cases.';

    /**
     * @description The person's file as the participant page shows it.
     */
    public class PersonFile {
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String personName;
        @AuraEnabled
        public String firstName;
        /** Every policy the person is on, this one first. */
        @AuraEnabled
        public List<PolicyRow> policies = new List<PolicyRow>();
        /** The claims and service requests that name the person, open ones first, newest first. */
        @AuraEnabled
        public List<CaseRow> cases = new List<CaseRow>();
        /** How many claims and requests name the person in all; the list holds the first few. */
        @AuraEnabled
        public Integer caseCount = 0;
        @AuraEnabled
        public Integer openClaimCount = 0;
        /** The other people on this policy. */
        @AuraEnabled
        public List<PersonRow> others = new List<PersonRow>();
    }

    /**
     * @description One policy the person is on, with every role they hold on it.
     */
    public class PolicyRow {
        @AuraEnabled
        public Id policyId;
        @AuraEnabled
        public String policyName;
        @AuraEnabled
        public String line;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String insuredItem;
        @AuraEnabled
        public List<String> roles = new List<String>();
        @AuraEnabled
        public Boolean isThisPolicy = false;
    }

    /**
     * @description One claim or service request that names the person.
     */
    public class CaseRow {
        @AuraEnabled
        public Id caseId;
        @AuraEnabled
        public String caseNumber;
        @AuraEnabled
        public String subject;
        /** "Claim" or "Service request". */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Boolean isClosed;
        /** The day of the loss for a claim, the day it was reported otherwise. */
        @AuraEnabled
        public Date happenedOn;
        @AuraEnabled
        public String policyName;
        /** Paid plus what is still reserved, for a claim with either. */
        @AuraEnabled
        public Decimal incurred;
    }

    /**
     * @description Someone else on the same policy.
     */
    public class PersonRow {
        @AuraEnabled
        public Id participantId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String role;
        @AuraEnabled
        public String relationship;
    }

    /**
     * @description The file of the person a participant record stands for.
     * @param participantId The policy participant being viewed
     * @return The person's policies and roles, the cases that name them and the others on this policy
     * @throws AuraHandledException when the participant, its policies or its cases cannot be read
     */
    @AuraEnabled(cacheable=true)
    public static PersonFile getFile(Id participantId) {
        try {
            return load(participantId);
        } catch (QueryException e) {
            AuraHandledException handled = new AuraHandledException(LOAD_ERROR);
            handled.setMessage(LOAD_ERROR);
            throw handled;
        }
    }

    private static PersonFile load(Id participantId) {
        Policy_Participant__c viewed = [
            SELECT Id, Name, Policy__c, Contact__c, Contact__r.Name, Contact__r.FirstName
            FROM Policy_Participant__c
            WHERE Id = :participantId
            WITH USER_MODE
        ];
        PersonFile file = new PersonFile();
        file.contactId = viewed.Contact__c;
        // A participant with no contact is named for the person and the role: "Daniel Reyes, Driver".
        file.personName = viewed.Contact__c != null ? viewed.Contact__r.Name : viewed.Name.substringBefore(',');
        file.firstName = viewed.Contact__c != null && String.isNotBlank(viewed.Contact__r.FirstName) ? viewed.Contact__r.FirstName : file.personName.substringBefore(' ');

        for (Policy_Participant__c other : [
            SELECT Id, Name, Role__c, Relationship_to_Insured__c, Contact__c, Contact__r.Name
            FROM Policy_Participant__c
            WHERE Policy__c = :viewed.Policy__c AND Id != :viewed.Id
            WITH USER_MODE
            ORDER BY Is_Primary__c DESC, Name
            LIMIT :MOST_OTHERS
        ]) {
            // The same person in another role is part of their own row, not someone else.
            if (viewed.Contact__c != null && other.Contact__c == viewed.Contact__c) {
                continue;
            }
            PersonRow row = new PersonRow();
            row.participantId = other.Id;
            row.name = other.Contact__c != null ? other.Contact__r.Name : other.Name.substringBefore(',');
            row.role = other.Role__c;
            row.relationship = other.Relationship_to_Insured__c;
            file.others.add(row);
        }
        if (viewed.Contact__c == null) {
            return file;
        }

        Map<Id, PolicyRow> byPolicy = new Map<Id, PolicyRow>();
        List<PolicyRow> elsewhere = new List<PolicyRow>();
        for (Policy_Participant__c role : [
            SELECT Role__c, Policy__c, Policy__r.Name, Policy__r.Line_of_Business__c, Policy__r.Status__c, Policy__r.Insured_Item__c
            FROM Policy_Participant__c
            WHERE Contact__c = :viewed.Contact__c
            WITH USER_MODE
            ORDER BY Policy__r.Name, Is_Primary__c DESC, Role__c
            LIMIT 200
        ]) {
            PolicyRow row = byPolicy.get(role.Policy__c);
            if (row == null) {
                if (byPolicy.size() == MOST_POLICIES) {
                    continue;
                }
                row = new PolicyRow();
                row.policyId = role.Policy__c;
                row.policyName = role.Policy__r.Name;
                row.line = role.Policy__r.Line_of_Business__c;
                row.status = role.Policy__r.Status__c;
                row.insuredItem = role.Policy__r.Insured_Item__c;
                row.isThisPolicy = role.Policy__c == viewed.Policy__c;
                byPolicy.put(role.Policy__c, row);
                if (row.isThisPolicy) {
                    file.policies.add(row);
                } else {
                    elsewhere.add(row);
                }
            }
            if (String.isNotBlank(role.Role__c) && !row.roles.contains(role.Role__c)) {
                row.roles.add(role.Role__c);
            }
        }
        file.policies.addAll(elsewhere);

        file.caseCount = [SELECT COUNT() FROM Case WHERE ContactId = :viewed.Contact__c WITH USER_MODE];
        file.openClaimCount = [SELECT COUNT() FROM Case WHERE ContactId = :viewed.Contact__c AND IsClosed = FALSE AND RecordType.DeveloperName = 'Claim' WITH USER_MODE];
        for (Case named : [
            SELECT Id, CaseNumber, Subject, Kind__c, Status, IsClosed, Date_of_Loss__c, Reported_Date__c, CreatedDate, Policy__r.Name, Paid_Amount__c, Outstanding_Reserve__c
            FROM Case
            WHERE ContactId = :viewed.Contact__c
            WITH USER_MODE
            ORDER BY IsClosed, CreatedDate DESC
            LIMIT :MOST_CASES
        ]) {
            CaseRow row = new CaseRow();
            row.caseId = named.Id;
            row.caseNumber = named.CaseNumber;
            row.subject = named.Subject;
            row.kind = named.Kind__c;
            row.status = named.Status;
            row.isClosed = named.IsClosed;
            row.happenedOn = named.Date_of_Loss__c != null ? named.Date_of_Loss__c : (named.Reported_Date__c != null ? named.Reported_Date__c : named.CreatedDate.date());
            row.policyName = named.Policy__r?.Name;
            Decimal incurred = (named.Paid_Amount__c == null ? 0 : named.Paid_Amount__c) + (named.Outstanding_Reserve__c == null ? 0 : named.Outstanding_Reserve__c);
            row.incurred = incurred > 0 ? incurred : null;
            file.cases.add(row);
        }
        return file;
    }
}
