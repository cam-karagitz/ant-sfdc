/**
 * @description The Tasks tab: every open task the running user owns, each named for who and what it
 * is about. A claim or a service request is named by its subject, a quote by its policy sale and
 * option, and a policy by its number and policyholder, because a bare number says nothing.
 * Everything is limited to what the running user can see.
 */
public with sharing class AntsuranceTasksController {
    @TestVisible
    private static final Integer MOST_SHOWN = 200;
    private static final String LOAD_ERROR = 'Your tasks could not be loaded. Check your access to tasks.';
    private static final String SERVICE_RECORD_TYPE = 'Policy_Service';

    /**
     * @description The open tasks with their totals.
     */
    public class Board {
        @AuraEnabled
        public List<Row> tasks = new List<Row>();
        @AuraEnabled
        public Integer openCount = 0;
        @AuraEnabled
        public Integer overdueCount = 0;
        /** The day the groups are measured from, so the page and the server agree on "today". */
        @AuraEnabled
        public Date today = Date.today();
    }

    /**
     * @description One open task.
     */
    public class Row {
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
        /** What the task is about, in words: a claim's subject, a sale's name, a policy number and policyholder. */
        @AuraEnabled
        public String relatedName;
        /** The kind of record it is about: Claim, Service request, Policy sale, Quote, Policy, Customer. */
        @AuraEnabled
        public String relatedKind;
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String contactName;
    }

    /**
     * @description The running user's open tasks, soonest due first, undated ones last.
     * @return Up to 200 tasks with the full open and overdue counts
     * @throws AuraHandledException when the user cannot read tasks or what they are about
     */
    @AuraEnabled(cacheable=true)
    public static Board getMyOpenTasks() {
        try {
            return load();
        } catch (QueryException e) {
            AuraHandledException handled = new AuraHandledException(LOAD_ERROR);
            handled.setMessage(LOAD_ERROR);
            throw handled;
        }
    }

    private static Board load() {
        Id me = UserInfo.getUserId();
        Board board = new Board();
        board.openCount = [SELECT COUNT() FROM Task WHERE OwnerId = :me AND IsClosed = FALSE WITH USER_MODE];
        board.overdueCount = [SELECT COUNT() FROM Task WHERE OwnerId = :me AND IsClosed = FALSE AND ActivityDate < TODAY WITH USER_MODE];

        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, Priority, WhatId, What.Name, WhoId, Who.Name
            FROM Task
            WHERE OwnerId = :me AND IsClosed = FALSE
            WITH USER_MODE
            ORDER BY ActivityDate ASC NULLS LAST, Priority ASC, Subject
            LIMIT :MOST_SHOWN
        ];
        Map<SObjectType, Set<Id>> aboutByType = new Map<SObjectType, Set<Id>>();
        for (Task item : tasks) {
            if (item.WhatId != null) {
                SObjectType kind = item.WhatId.getSObjectType();
                if (!aboutByType.containsKey(kind)) {
                    aboutByType.put(kind, new Set<Id>());
                }
                aboutByType.get(kind).add(item.WhatId);
            }
        }
        Map<Id, Case> cases = new Map<Id, Case>();
        if (aboutByType.containsKey(Case.SObjectType)) {
            Set<Id> ids = aboutByType.get(Case.SObjectType);
            cases = new Map<Id, Case>([SELECT Subject, CaseNumber, RecordType.DeveloperName FROM Case WHERE Id IN :ids WITH USER_MODE]);
        }
        Map<Id, Quote> quotes = new Map<Id, Quote>();
        if (aboutByType.containsKey(Quote.SObjectType)) {
            Set<Id> ids = aboutByType.get(Quote.SObjectType);
            quotes = new Map<Id, Quote>([SELECT Name, Opportunity.Name FROM Quote WHERE Id IN :ids WITH USER_MODE]);
        }
        Map<Id, Policy__c> policies = new Map<Id, Policy__c>();
        if (aboutByType.containsKey(Policy__c.SObjectType)) {
            Set<Id> ids = aboutByType.get(Policy__c.SObjectType);
            policies = new Map<Id, Policy__c>([SELECT Name, Account__r.Name FROM Policy__c WHERE Id IN :ids WITH USER_MODE]);
        }

        for (Task item : tasks) {
            Row row = new Row();
            row.recordId = item.Id;
            row.subject = item.Subject;
            row.dueDate = item.ActivityDate;
            row.priority = item.Priority;
            row.relatedId = item.WhatId;
            row.contactId = item.WhoId;
            row.contactName = item.Who?.Name;
            if (cases.containsKey(item.WhatId)) {
                Case about = cases.get(item.WhatId);
                row.relatedName = String.isBlank(about.Subject) ? about.CaseNumber : about.Subject;
                row.relatedKind = about.RecordType?.DeveloperName == SERVICE_RECORD_TYPE ? 'Service request' : 'Claim';
            } else if (quotes.containsKey(item.WhatId)) {
                Quote about = quotes.get(item.WhatId);
                row.relatedName = about.Opportunity?.Name == null ? about.Name : about.Opportunity.Name + ', ' + about.Name;
                row.relatedKind = 'Quote';
            } else if (policies.containsKey(item.WhatId)) {
                Policy__c about = policies.get(item.WhatId);
                row.relatedName = about.Account__r?.Name == null ? about.Name : about.Name + ', ' + about.Account__r.Name;
                row.relatedKind = 'Policy';
            } else if (item.WhatId != null) {
                row.relatedName = item.What?.Name;
                SObjectType kind = item.WhatId.getSObjectType();
                row.relatedKind = kind == Opportunity.SObjectType ? 'Policy sale' : kind == Account.SObjectType ? 'Customer' : kind.getDescribe().getLabel();
            }
            board.tasks.add(row);
        }
        return board;
    }
}
