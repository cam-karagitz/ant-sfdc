/**
 * @description Read-only data for the Antsurance home page: the book of business in numbers,
 * the open claims that most need attention and the open sales pipeline by stage, limited to
 * what the running user can see.
 */
public with sharing class AntsuranceHomeController {
    private static final Integer MAX_OPPORTUNITIES = 500;
    private static final Integer MAX_OPEN_CLAIMS = 200;
    private static final Integer CLAIMS_SHOWN = 7;
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    // Most serious first. Claims without a severity come last.
    private static final List<String> SEVERITY_ORDER = new List<String>{ 'Catastrophic', 'High', 'Medium', 'Low', null };
    private static final String LOAD_ERROR = 'The CRM snapshot could not be loaded. Check your access to accounts, policies, cases, leads and opportunities.';

    /**
     * @description Headline numbers for the running user.
     */
    public class Snapshot {
        @AuraEnabled
        public String firstName;
        @AuraEnabled
        public Integer customerCount;
        @AuraEnabled
        public Integer policiesInForce;
        @AuraEnabled
        public Decimal premiumInForce;
        @AuraEnabled
        public Integer openClaimCount;
        @AuraEnabled
        public Integer openRequestCount;
        @AuraEnabled
        public List<ClaimLine> claims;
        @AuraEnabled
        public Integer openCaseCount;
        @AuraEnabled
        public Integer openLeadCount;
        @AuraEnabled
        public Integer openOpportunityCount;
        @AuraEnabled
        public Decimal openPipelineAmount;
        @AuraEnabled
        public List<StageSummary> stages;
    }

    /**
     * @description One open claim in the attention list.
     */
    public class ClaimLine {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String caseNumber;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public Decimal outstandingReserve;
        @AuraEnabled
        public Decimal paidAmount;
        @AuraEnabled
        public Date reportedDate;
    }

    /**
     * @description Open opportunities in one sales stage, largest first.
     */
    public class StageSummary {
        @AuraEnabled
        public String stageName;
        @AuraEnabled
        public Integer opportunityCount = 0;
        @AuraEnabled
        public Decimal amount = 0;
        @AuraEnabled
        public List<OpportunityLink> opportunities = new List<OpportunityLink>();
    }

    /**
     * @description The fields needed to list and link to one opportunity.
     */
    public class OpportunityLink {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal amount;
    }

    /**
     * @description Returns the snapshot shown in the home page banner and pipeline card.
     * @return Counts of customers, open cases and open leads, plus open pipeline by stage
     * @throws AuraHandledException when the user cannot read one of the objects
     */
    @AuraEnabled(cacheable=true)
    public static Snapshot getSnapshot() {
        try {
            return buildSnapshot();
        } catch (QueryException e) {
            AuraHandledException handled = new AuraHandledException(LOAD_ERROR);
            handled.setMessage(LOAD_ERROR);
            throw handled;
        }
    }

    /**
     * @description Builds the snapshot. Separate from getSnapshot so other Apex can reuse it.
     * @return The snapshot for the running user
     */
    public static Snapshot buildSnapshot() {
        Snapshot snapshot = new Snapshot();
        snapshot.firstName = UserInfo.getFirstName();
        snapshot.customerCount = [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName != 'Agency' WITH USER_MODE];
        snapshot.openCaseCount = [SELECT COUNT() FROM Case WHERE IsClosed = FALSE WITH USER_MODE];
        snapshot.openRequestCount = [SELECT COUNT() FROM Case WHERE IsClosed = FALSE AND RecordType.DeveloperName = 'Policy_Service' WITH USER_MODE];

        AggregateResult inForce = [SELECT COUNT(Id) policies, SUM(Annual_Premium__c) premium FROM Policy__c WHERE Status__c IN :IN_FORCE WITH USER_MODE];
        snapshot.policiesInForce = (Integer) inForce.get('policies');
        snapshot.premiumInForce = inForce.get('premium') == null ? 0 : (Decimal) inForce.get('premium');

        // Oldest first within each severity, so the claims shown are the serious ones that have waited longest.
        Map<String, List<ClaimLine>> claimsBySeverity = new Map<String, List<ClaimLine>>();
        snapshot.openClaimCount = 0;
        for (Case claim : [
            SELECT Id, CaseNumber, Subject, Account.Name, Status, Severity__c, Outstanding_Reserve__c, Paid_Amount__c, Reported_Date__c
            FROM Case
            WHERE IsClosed = FALSE AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Reported_Date__c ASC NULLS LAST, CaseNumber
            LIMIT :MAX_OPEN_CLAIMS
        ]) {
            ClaimLine line = new ClaimLine();
            line.recordId = claim.Id;
            line.caseNumber = claim.CaseNumber;
            line.subject = claim.Subject;
            line.accountName = claim.Account?.Name;
            line.status = claim.Status;
            line.severity = claim.Severity__c;
            line.outstandingReserve = claim.Outstanding_Reserve__c;
            line.paidAmount = claim.Paid_Amount__c;
            line.reportedDate = claim.Reported_Date__c;
            String bucket = SEVERITY_ORDER.contains(claim.Severity__c) ? claim.Severity__c : null;
            if (!claimsBySeverity.containsKey(bucket)) {
                claimsBySeverity.put(bucket, new List<ClaimLine>());
            }
            claimsBySeverity.get(bucket).add(line);
            snapshot.openClaimCount++;
        }
        snapshot.claims = new List<ClaimLine>();
        for (String severity : SEVERITY_ORDER) {
            for (ClaimLine line : claimsBySeverity.containsKey(severity) ? claimsBySeverity.get(severity) : new List<ClaimLine>()) {
                if (snapshot.claims.size() < CLAIMS_SHOWN) {
                    snapshot.claims.add(line);
                }
            }
        }
        snapshot.openLeadCount = [SELECT COUNT() FROM Lead WHERE IsConverted = FALSE WITH USER_MODE];
        snapshot.openOpportunityCount = 0;
        snapshot.openPipelineAmount = 0;

        // Largest opportunities first, so each stage lists its biggest deals at the top.
        Map<String, StageSummary> stagesByName = new Map<String, StageSummary>();
        for (Opportunity opportunity : [
            SELECT Id, Name, StageName, Amount
            FROM Opportunity
            WHERE IsClosed = FALSE
            WITH USER_MODE
            ORDER BY Amount DESC NULLS LAST, Name
            LIMIT :MAX_OPPORTUNITIES
        ]) {
            StageSummary summary = stagesByName.get(opportunity.StageName);
            if (summary == null) {
                summary = new StageSummary();
                summary.stageName = opportunity.StageName;
                stagesByName.put(opportunity.StageName, summary);
            }
            OpportunityLink link = new OpportunityLink();
            link.recordId = opportunity.Id;
            link.name = opportunity.Name;
            link.amount = opportunity.Amount == null ? 0 : opportunity.Amount;
            summary.opportunities.add(link);
            summary.opportunityCount++;
            summary.amount += link.amount;
            snapshot.openOpportunityCount++;
            snapshot.openPipelineAmount += link.amount;
        }
        snapshot.stages = sortByAmount(stagesByName.values());
        return snapshot;
    }

    /** Stages ordered by total amount, largest first. */
    private static List<StageSummary> sortByAmount(List<StageSummary> stages) {
        List<StageSummary> sorted = new List<StageSummary>();
        for (StageSummary stage : stages) {
            Integer position = 0;
            while (position < sorted.size() && sorted[position].amount >= stage.amount) {
                position++;
            }
            if (position == sorted.size()) {
                sorted.add(stage);
            } else {
                sorted.add(position, stage);
            }
        }
        return sorted;
    }
}
