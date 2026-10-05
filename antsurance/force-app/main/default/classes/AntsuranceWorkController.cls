/**
 * @description The Home page workbench: the running user's open tasks, the in-force policies that
 * expire soon, and the quotes that have been with a customer too long without being bound.
 * Everything is limited to what the running user can see.
 */
public with sharing class AntsuranceWorkController {
    private static final Integer ROWS_SHOWN = 6;
    @TestVisible
    private static final Integer RENEWAL_WINDOW_DAYS = 60;
    @TestVisible
    private static final Integer STALE_QUOTE_DAYS = 15;
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Set<String> WAITING_ON_CUSTOMER = new Set<String>{ 'Issued', 'Presented' };
    private static final String LOAD_ERROR = 'Your work could not be loaded. Check your access to tasks, policies and quotes.';
    private static final String TASK_ERROR = 'That task could not be completed. It may belong to someone else or already be closed.';

    /**
     * @description The three work lists with their totals.
     */
    public class Work {
        @AuraEnabled
        public List<TaskLine> tasks = new List<TaskLine>();
        @AuraEnabled
        public Integer openTaskCount = 0;
        @AuraEnabled
        public Integer overdueTaskCount = 0;
        @AuraEnabled
        public List<RenewalLine> renewals = new List<RenewalLine>();
        @AuraEnabled
        public Integer renewalCount = 0;
        @AuraEnabled
        public Decimal renewalPremium = 0;
        @AuraEnabled
        public List<QuoteLine> staleQuotes = new List<QuoteLine>();
        @AuraEnabled
        public Integer staleQuoteCount = 0;
        @AuraEnabled
        public Decimal staleQuotePremium = 0;
    }

    /**
     * @description One open task.
     */
    public class TaskLine {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public Date dueDate;
        @AuraEnabled
        public String priority;
        @AuraEnabled
        public Id relatedId;
        /** The claim subject, policy number, sale or customer the task is about. */
        @AuraEnabled
        public String relatedName;
        @AuraEnabled
        public String contactName;
    }

    /**
     * @description One policy coming up for renewal.
     */
    public class RenewalLine {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String policyNumber;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public Date expirationDate;
    }

    /**
     * @description One quote still waiting on the customer.
     */
    public class QuoteLine {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public Id saleId;
        @AuraEnabled
        public String saleName;
        @AuraEnabled
        public String option;
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public Date issuedDate;
    }

    /**
     * @description The running user's open tasks (soonest due first), in-force policies expiring in the next
     * 60 days (soonest first) and quotes issued 15 or more days ago that are still open (oldest first).
     * @return Up to six rows of each, with the full counts and premium totals
     * @throws AuraHandledException when the user cannot read one of the objects
     */
    @AuraEnabled(cacheable=true)
    public static Work getMyWork() {
        try {
            Work work = new Work();
            loadTasks(work);
            loadRenewals(work);
            loadStaleQuotes(work);
            return work;
        } catch (QueryException e) {
            throw handled(LOAD_ERROR);
        }
    }

    /**
     * @description Marks one of the running user's own tasks as completed.
     * @param taskId The task to complete
     * @throws AuraHandledException when the task is not the user's, is already closed or cannot be saved
     */
    @AuraEnabled
    public static void completeTask(Id taskId) {
        List<Task> mine = [SELECT Id FROM Task WHERE Id = :taskId AND OwnerId = :UserInfo.getUserId() AND IsClosed = FALSE WITH USER_MODE LIMIT 1];
        if (mine.isEmpty()) {
            throw handled(TASK_ERROR);
        }
        try {
            mine[0].Status = 'Completed';
            update as user mine;
        } catch (DmlException e) {
            throw handled(TASK_ERROR);
        }
    }

    private static void loadTasks(Work work) {
        Id me = UserInfo.getUserId();
        work.openTaskCount = [SELECT COUNT() FROM Task WHERE OwnerId = :me AND IsClosed = FALSE WITH USER_MODE];
        work.overdueTaskCount = [SELECT COUNT() FROM Task WHERE OwnerId = :me AND IsClosed = FALSE AND ActivityDate < TODAY WITH USER_MODE];

        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, Priority, WhatId, What.Name, Who.Name
            FROM Task
            WHERE OwnerId = :me AND IsClosed = FALSE
            WITH USER_MODE
            ORDER BY ActivityDate ASC NULLS LAST, Priority ASC, Subject
            LIMIT :ROWS_SHOWN
        ];
        // A case's name is only its number, so its subject is fetched to say what the task is about.
        Set<Id> caseIds = new Set<Id>();
        for (Task item : tasks) {
            if (item.WhatId != null && item.WhatId.getSObjectType() == Case.SObjectType) {
                caseIds.add(item.WhatId);
            }
        }
        Map<Id, Case> cases = caseIds.isEmpty() ? new Map<Id, Case>() : new Map<Id, Case>([SELECT Subject FROM Case WHERE Id IN :caseIds WITH USER_MODE]);
        for (Task item : tasks) {
            TaskLine line = new TaskLine();
            line.recordId = item.Id;
            line.subject = item.Subject;
            line.dueDate = item.ActivityDate;
            line.priority = item.Priority;
            line.relatedId = item.WhatId;
            line.relatedName = cases.containsKey(item.WhatId) ? cases.get(item.WhatId).Subject : item.What?.Name;
            line.contactName = item.Who?.Name;
            work.tasks.add(line);
        }
    }

    private static void loadRenewals(Work work) {
        Date windowEnd = Date.today().addDays(RENEWAL_WINDOW_DAYS);
        AggregateResult totals = [
            SELECT COUNT(Id) policies, SUM(Annual_Premium__c) premium
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :windowEnd
            WITH USER_MODE
        ];
        work.renewalCount = (Integer) totals.get('policies');
        work.renewalPremium = totals.get('premium') == null ? 0 : (Decimal) totals.get('premium');
        for (Policy__c policy : [
            SELECT Id, Name, Account__r.Name, Line_of_Business__c, Annual_Premium__c, Expiration_Date__c
            FROM Policy__c
            WHERE Status__c IN :IN_FORCE AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :windowEnd
            WITH USER_MODE
            ORDER BY Expiration_Date__c ASC, Annual_Premium__c DESC NULLS LAST
            LIMIT :ROWS_SHOWN
        ]) {
            RenewalLine line = new RenewalLine();
            line.recordId = policy.Id;
            line.policyNumber = policy.Name;
            line.accountName = policy.Account__r.Name;
            line.lineOfBusiness = policy.Line_of_Business__c;
            line.premium = policy.Annual_Premium__c;
            line.expirationDate = policy.Expiration_Date__c;
            work.renewals.add(line);
        }
    }

    private static void loadStaleQuotes(Work work) {
        Date issuedBy = Date.today().addDays(-STALE_QUOTE_DAYS);
        AggregateResult totals = [
            SELECT COUNT(Id) quotes, SUM(Annual_Premium__c) premium
            FROM Quote
            WHERE Status IN :WAITING_ON_CUSTOMER AND Issued_Date__c <= :issuedBy
            WITH USER_MODE
        ];
        work.staleQuoteCount = (Integer) totals.get('quotes');
        work.staleQuotePremium = totals.get('premium') == null ? 0 : (Decimal) totals.get('premium');
        for (Quote quote : [
            SELECT Id, OpportunityId, Opportunity.Name, Name, Annual_Premium__c, Issued_Date__c
            FROM Quote
            WHERE Status IN :WAITING_ON_CUSTOMER AND Issued_Date__c <= :issuedBy
            WITH USER_MODE
            ORDER BY Issued_Date__c ASC, Annual_Premium__c DESC NULLS LAST
            LIMIT :ROWS_SHOWN
        ]) {
            QuoteLine line = new QuoteLine();
            line.recordId = quote.Id;
            line.saleId = quote.OpportunityId;
            line.saleName = quote.Opportunity.Name;
            line.option = quote.Name;
            line.premium = quote.Annual_Premium__c;
            line.issuedDate = quote.Issued_Date__c;
            work.staleQuotes.add(line);
        }
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
