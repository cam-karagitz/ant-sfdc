/**
 * @description Read-only summaries for record pages: a customer's book of policies with their
 * claims experience, limited to what the running user can see.
 */
public with sharing class AntsuranceInsightsController {
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Integer MAX_POLICIES = 50;
    private static final Integer MAX_MEMBERS = 12;
    private static final String LOAD_ERROR = 'The customer summary could not be loaded. Check your access to policies and cases.';

    /**
     * @description A customer's policies and claims at a glance.
     */
    public class CustomerSummary {
        /** True for an agency, where the policies are the ones it produced rather than holds. */
        @AuraEnabled
        public Boolean isAgency = false;
        /** Every policy the account holds, or the agency produced, in any status. Counted, so it is right however long the list is. */
        @AuraEnabled
        public Integer policyCount = 0;
        @AuraEnabled
        public Integer policiesInForce = 0;
        @AuraEnabled
        public Decimal premiumInForce = 0;
        @AuraEnabled
        public Integer openClaims = 0;
        /** Every claim on these policies, open or closed. */
        @AuraEnabled
        public Integer claimCount = 0;
        @AuraEnabled
        public Integer openRequests = 0;
        /** Reserved or paid, whichever is higher, across every claim on these policies. */
        @AuraEnabled
        public Decimal incurredLosses = 0;
        /** Incurred losses as a share of premium in force, or null when there is no premium. */
        @AuraEnabled
        public Decimal lossRatio;
        @AuraEnabled
        public List<PolicyLine> policies = new List<PolicyLine>();
        @AuraEnabled
        public Date customerSince;
        /** Whole years since then, counted by the calendar: six on the sixth anniversary, not five. Null with no date. */
        @AuraEnabled
        public Integer yearsSince;
        /** The customer's main phone number, shown on the card so the page header need not repeat it. */
        @AuraEnabled
        public String phone;
        /** The household's members, or a business's contacts, with the primary one first. */
        @AuraEnabled
        public List<Member> members = new List<Member>();
    }

    /**
     * @description One person on the account.
     */
    public class Member {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String name;
        /** Household role for a member, job title for a business contact. */
        @AuraEnabled
        public String role;
    }

    /**
     * @description One policy in the customer's list.
     */
    public class PolicyLine {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public Date expirationDate;
        @AuraEnabled
        public Boolean inForce;
        @AuraEnabled
        public String policyholder;
    }

    /**
     * @description Summarizes the policies an account holds, or for an agency the policies it produced.
     * @param accountId The account on screen
     * @return Counts, premium, losses and the policy list, in-force policies first
     * @throws AuraHandledException when the user cannot read policies or cases
     */
    @AuraEnabled(cacheable=true)
    public static CustomerSummary getCustomerSummary(Id accountId) {
        try {
            return buildCustomerSummary(accountId);
        } catch (QueryException e) {
            AuraHandledException handled = new AuraHandledException(LOAD_ERROR);
            handled.setMessage(LOAD_ERROR);
            throw handled;
        }
    }

    private static CustomerSummary buildCustomerSummary(Id accountId) {
        CustomerSummary summary = new CustomerSummary();
        List<Account> account = [SELECT RecordType.DeveloperName, Customer_Since__c, Phone FROM Account WHERE Id = :accountId WITH USER_MODE LIMIT 1];
        summary.isAgency = !account.isEmpty() && account[0].RecordType?.DeveloperName == 'Agency';
        summary.customerSince = account.isEmpty() ? null : account[0].Customer_Since__c;
        summary.yearsSince = wholeYears(summary.customerSince, Date.today());
        summary.phone = account.isEmpty() ? null : account[0].Phone;
        for (Contact person : [
            SELECT Id, Name, Household_Role__c, Title
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY Primary_Member__c DESC, Birthdate ASC NULLS LAST, Name
            LIMIT :MAX_MEMBERS
        ]) {
            Member member = new Member();
            member.recordId = person.Id;
            member.name = person.Name;
            member.role = String.isBlank(person.Household_Role__c) ? person.Title : person.Household_Role__c;
            summary.members.add(member);
        }

        List<Policy__c> policies = summary.isAgency
            ? [
                  SELECT Id, Name, Line_of_Business__c, Status__c, Annual_Premium__c, Expiration_Date__c, Account__r.Name
                  FROM Policy__c
                  WHERE Producer__c = :accountId
                  WITH USER_MODE
                  ORDER BY Annual_Premium__c DESC NULLS LAST
                  LIMIT :MAX_POLICIES
              ]
            : [
                  SELECT Id, Name, Line_of_Business__c, Status__c, Annual_Premium__c, Expiration_Date__c, Account__r.Name
                  FROM Policy__c
                  WHERE Account__c = :accountId
                  WITH USER_MODE
                  ORDER BY Annual_Premium__c DESC NULLS LAST
                  LIMIT :MAX_POLICIES
              ];

        // The counts and the premium come from every policy, not from the list, which stops at the first fifty.
        for (AggregateResult row : summary.isAgency
            ? [SELECT Status__c status, COUNT(Id) held, SUM(Annual_Premium__c) premium FROM Policy__c WHERE Producer__c = :accountId WITH USER_MODE GROUP BY Status__c]
            : [SELECT Status__c status, COUNT(Id) held, SUM(Annual_Premium__c) premium FROM Policy__c WHERE Account__c = :accountId WITH USER_MODE GROUP BY Status__c]) {
            Integer held = (Integer) row.get('held');
            summary.policyCount += held;
            if (IN_FORCE.contains((String) row.get('status'))) {
                summary.policiesInForce += held;
                summary.premiumInForce += row.get('premium') == null ? 0 : (Decimal) row.get('premium');
            }
        }

        List<PolicyLine> notInForce = new List<PolicyLine>();
        for (Policy__c policy : policies) {
            PolicyLine line = new PolicyLine();
            line.recordId = policy.Id;
            line.name = policy.Name;
            line.lineOfBusiness = policy.Line_of_Business__c;
            line.status = policy.Status__c;
            line.premium = policy.Annual_Premium__c == null ? 0 : policy.Annual_Premium__c;
            line.expirationDate = policy.Expiration_Date__c;
            line.inForce = IN_FORCE.contains(policy.Status__c);
            line.policyholder = policy.Account__r.Name;
            if (line.inForce) {
                summary.policies.add(line);
            } else {
                notInForce.add(line);
            }
        }
        summary.policies.addAll(notInForce);

        for (Case record : summary.isAgency
            ? [
                  SELECT IsClosed, RecordType.DeveloperName, Reserve_Amount__c, Paid_Amount__c
                  FROM Case
                  WHERE Policy__c IN (SELECT Id FROM Policy__c WHERE Producer__c = :accountId)
                  WITH USER_MODE
              ]
            : [
                  SELECT IsClosed, RecordType.DeveloperName, Reserve_Amount__c, Paid_Amount__c
                  FROM Case
                  WHERE Policy__c IN (SELECT Id FROM Policy__c WHERE Account__c = :accountId)
                  WITH USER_MODE
              ]) {
            if (record.RecordType?.DeveloperName == 'Claim') {
                summary.claimCount++;
                Decimal reserve = record.Reserve_Amount__c == null ? 0 : record.Reserve_Amount__c;
                Decimal paid = record.Paid_Amount__c == null ? 0 : record.Paid_Amount__c;
                summary.incurredLosses += Math.max(reserve, paid);
                if (!record.IsClosed) {
                    summary.openClaims++;
                }
            } else if (!record.IsClosed) {
                summary.openRequests++;
            }
        }
        if (summary.premiumInForce > 0) {
            summary.lossRatio = (summary.incurredLosses / summary.premiumInForce).setScale(4);
        }
        return summary;
    }

    /** Whole years from one date to another by the calendar; null with no start, or one still to come. */
    @TestVisible
    private static Integer wholeYears(Date since, Date today) {
        if (since == null || since > today) {
            return null;
        }
        Integer years = today.year() - since.year();
        Boolean beforeAnniversary = today.month() < since.month() || (today.month() == since.month() && today.day() < since.day());
        return beforeAnniversary ? years - 1 : years;
    }
}
