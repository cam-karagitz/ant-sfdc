@IsTest
private class AntsuranceClaudeActionsTest {
    private static Id recordTypeId(String developerName) {
        return Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    private static Case claim() {
        return [SELECT Id, CaseNumber, AccountId, Policy__c FROM Case WHERE Subject = 'Burst pipe in basement'];
    }

    private static Case request() {
        return [SELECT Id, CaseNumber, Status FROM Case WHERE Subject = 'Add a driver'];
    }

    private static AntsuranceClaudeActions.Proposal propose(String toolName, Map<String, Object> input) {
        return AntsuranceClaudeActions.propose(toolName, 'toolu_1', input);
    }

    private static String rejection(String toolName, Map<String, Object> input) {
        try {
            propose(toolName, input);
            Assert.fail('Expected the proposal to be rejected');
        } catch (IllegalArgumentException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String confirmFailure(String payloadJson) {
        try {
            AntsuranceClaudeActions.confirm(payloadJson);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String detail(AntsuranceClaudeActions.Proposal proposal, String label) {
        for (AntsuranceClaudeActions.Detail detail : proposal.details) {
            if (detail.label == label) {
                return detail.value;
            }
        }
        return null;
    }

    @TestSetup
    static void createRecords() {
        Account household = new Account(Name = 'Okafor Household');
        insert household;
        Contact insured = new Contact(FirstName = 'Ada', LastName = 'Okafor', AccountId = household.Id);
        insert insured;
        Date start = Date.today().addMonths(-2);
        Policy__c policy = new Policy__c(Name = 'ANT-HO-1', Account__c = household.Id, Status__c = 'Active', Effective_Date__c = start, Expiration_Date__c = start.addYears(1));
        insert policy;
        insert new List<Case>{
            new Case(Subject = 'Burst pipe in basement', RecordTypeId = recordTypeId('Claim'), AccountId = household.Id, Policy__c = policy.Id, Status = 'New'),
            new Case(Subject = 'Add a driver', RecordTypeId = recordTypeId('Policy_Service'), AccountId = household.Id, Policy__c = policy.Id, Status = 'New')
        };
    }

    @IsTest
    static void aTaskIsProposedThenCreatedOnlyOnConfirm() {
        Case claim = claim();
        Contact insured = [SELECT Id FROM Contact LIMIT 1];
        Date due = Date.today().addDays(3);
        // Opening a claim creates its own first task, so count from there.
        Integer tasksBefore = [SELECT COUNT() FROM Task];

        Test.startTest();
        AntsuranceClaudeActions.Proposal proposal = propose(
            AntsuranceClaudeActions.TASK_TOOL,
            new Map<String, Object>{
                'subject' => 'Call Ada about the contractor estimate',
                'due_date' => String.valueOf(due),
                'related_record_id' => claim.Id,
                'contact_id' => insured.Id,
                'priority' => 'High',
                'notes' => 'Estimate arrives Monday.'
            }
        );
        Integer tasksAfterProposal = [SELECT COUNT() FROM Task];
        AntsuranceClaudeActions.Outcome outcome = AntsuranceClaudeActions.confirm(proposal.payloadJson);
        Test.stopTest();

        Assert.areEqual(tasksBefore, tasksAfterProposal, 'Proposing writes nothing');
        Assert.areEqual('task', proposal.kind, 'The card is for a task');
        Assert.areEqual('toolu_1', proposal.id, 'The card is keyed by the tool call');
        Assert.areEqual('Call Ada about the contractor estimate', detail(proposal, 'Subject'), 'The card shows the subject');
        Assert.isTrue(detail(proposal, 'Related to').contains(claim.CaseNumber), 'The card names the claim');
        Assert.areEqual('Ada Okafor', detail(proposal, 'Contact'), 'The card names the contact');
        Assert.areEqual(UserInfo.getName(), detail(proposal, 'Assigned to'), 'The card says who gets the task');
        Assert.areEqual('Estimate arrives Monday.', proposal.body, 'The comments are shown');

        Task created = [SELECT Subject, ActivityDate, WhatId, WhoId, Priority, Description, OwnerId, IsClosed FROM Task WHERE Subject = 'Call Ada about the contractor estimate'];
        Assert.areEqual(created.Id, outcome.recordId, 'The result links to the new task');
        Assert.areEqual('Call Ada about the contractor estimate', created.Subject, 'The subject is saved');
        Assert.areEqual(due, created.ActivityDate, 'The due date is saved');
        Assert.areEqual(claim.Id, created.WhatId, 'The task is related to the claim');
        Assert.areEqual(insured.Id, created.WhoId, 'The task names the contact');
        Assert.areEqual('High', created.Priority, 'The priority is saved');
        Assert.areEqual('Estimate arrives Monday.', created.Description, 'The comments are saved');
        Assert.areEqual(UserInfo.getUserId(), created.OwnerId, 'The task is assigned to the user');
        Assert.isFalse(created.IsClosed, 'The task is open');
        Assert.isTrue(outcome.message.startsWith('Task created'), 'The result says what happened');
        Assert.areEqual(new List<Id>{ claim.Id }, outcome.touchedIds, 'The claim page is refreshed');
    }

    @IsTest
    static void aNoteOnAClaimAlsoBelongsToItsPolicyAndCustomer() {
        Case claim = claim();

        Test.startTest();
        AntsuranceClaudeActions.Proposal proposal = propose(
            AntsuranceClaudeInsurance.NOTE_TOOL,
            new Map<String, Object>{ 'record_id' => claim.Id, 'note_type' => 'Contact', 'body' => 'Spoke with the insured. Contractor estimate arrives Monday.' }
        );
        Integer notesAfterProposal = [SELECT COUNT() FROM File_Note__c];
        AntsuranceClaudeActions.Outcome outcome = AntsuranceClaudeActions.confirm(proposal.payloadJson);
        Test.stopTest();

        Assert.areEqual(0, notesAfterProposal, 'Proposing writes nothing');
        Assert.areEqual('file_note', proposal.kind, 'The card is for a note');
        Assert.areEqual('Contact', detail(proposal, 'Type'), 'The card shows the note type');
        Assert.isTrue(proposal.body.startsWith('Spoke with the insured'), 'The card shows the note text');

        File_Note__c note = [SELECT Case__c, Policy__c, Account__c, Note_Type__c, Body__c, Note_Date__c FROM File_Note__c];
        Assert.areEqual(claim.Id, note.Case__c, 'The note is on the claim');
        Assert.areEqual(claim.Policy__c, note.Policy__c, 'and on its policy');
        Assert.areEqual(claim.AccountId, note.Account__c, 'and on its customer');
        Assert.areEqual('Contact', note.Note_Type__c, 'The type is saved');
        Assert.isNotNull(note.Note_Date__c, 'The note is dated');
        Assert.areEqual(claim.Id, outcome.recordId, 'The result links to the file the note is on');
        Assert.areEqual('Open claim', outcome.linkLabel, 'The link says where it goes');
        Assert.areEqual('Contact note added.', outcome.message, 'The result says what happened');
    }

    @IsTest
    static void aNoteCanGoOnAPolicyOrACustomer() {
        Policy__c policy = [SELECT Id, Account__c FROM Policy__c];

        Test.startTest();
        AntsuranceClaudeActions.confirm(propose(AntsuranceClaudeInsurance.NOTE_TOOL, new Map<String, Object>{ 'record_id' => policy.Id, 'note_type' => 'Underwriting', 'body' => 'Roof replaced in 2024.' }).payloadJson);
        AntsuranceClaudeActions.confirm(propose(AntsuranceClaudeInsurance.NOTE_TOOL, new Map<String, Object>{ 'record_id' => policy.Account__c, 'note_type' => 'Not a type', 'body' => 'Prefers email.' }).payloadJson);
        Test.stopTest();

        File_Note__c onPolicy = [SELECT Policy__c, Account__c, Case__c FROM File_Note__c WHERE Note_Type__c = 'Underwriting'];
        Assert.areEqual(policy.Id, onPolicy.Policy__c, 'The note is on the policy');
        Assert.areEqual(policy.Account__c, onPolicy.Account__c, 'and on its customer');
        Assert.isNull(onPolicy.Case__c, 'but on no case');
        File_Note__c onCustomer = [SELECT Policy__c, Account__c FROM File_Note__c WHERE Note_Type__c = 'General'];
        Assert.areEqual(policy.Account__c, onCustomer.Account__c, 'An unknown type is saved as General on the customer');
        Assert.isNull(onCustomer.Policy__c, 'A customer note is on no policy');
    }

    @IsTest
    static void aStatusChangeIsProposedThenMadeOnlyOnConfirm() {
        Case request = request();

        Test.startTest();
        AntsuranceClaudeActions.Proposal proposal = propose(AntsuranceClaudeInsurance.STATUS_TOOL, new Map<String, Object>{ 'case_id' => request.Id, 'new_status' => 'Waiting on Customer' });
        String statusAfterProposal = request().Status;
        AntsuranceClaudeActions.Outcome outcome = AntsuranceClaudeActions.confirm(proposal.payloadJson);
        Test.stopTest();

        Assert.areEqual('New', statusAfterProposal, 'Proposing changes nothing');
        Assert.areEqual('case_status', proposal.kind, 'The card is for a status change');
        Assert.areEqual('Change the status', proposal.title, 'The card says what it will do');
        Assert.areEqual('New', detail(proposal, 'From'), 'The card shows the current status');
        Assert.areEqual('Waiting on Customer', detail(proposal, 'To'), 'and the new one');
        Assert.areEqual('Waiting on Customer', request().Status, 'Confirming moves the request');
        Assert.areEqual(request.Id, outcome.recordId, 'The result links to the request');
        Assert.areEqual('Status changed to Waiting on Customer.', outcome.message, 'The result says what changed');
        Assert.areEqual(request.CaseNumber + ': Add a driver', detail(proposal, 'Service request'), 'The card names the request once');
    }

    @IsTest
    static void proposalsThatCannotBeMadeAreExplainedToClaude() {
        Case claim = claim();
        Case request = request();
        Contact insured = [SELECT Id FROM Contact LIMIT 1];
        Map<String, Object> task = new Map<String, Object>{ 'subject' => 'Call', 'due_date' => '2026-10-05', 'related_record_id' => claim.Id, 'priority' => 'Normal' };
        Integer tasksBefore = [SELECT COUNT() FROM Task];

        Map<String, Object> noSubject = task.clone();
        noSubject.put('subject', ' ');
        Map<String, Object> badDate = task.clone();
        badDate.put('due_date', 'next Friday');
        Map<String, Object> notAnId = task.clone();
        notAnId.put('related_record_id', 'the claim');
        Map<String, Object> onAContact = task.clone();
        onAContact.put('related_record_id', insured.Id);
        Map<String, Object> contactIsNotAContact = task.clone();
        contactIsNotAContact.put('contact_id', claim.Id);

        Assert.isTrue(rejection(AntsuranceClaudeActions.TASK_TOOL, noSubject).contains('subject is required'), 'A task needs a subject');
        Assert.isTrue(rejection(AntsuranceClaudeActions.TASK_TOOL, badDate).contains('YYYY-MM-DD'), 'A due date must be a date');
        Assert.isTrue(rejection(AntsuranceClaudeActions.TASK_TOOL, notAnId).contains('not a record Id'), 'A name is not an Id');
        Assert.isTrue(rejection(AntsuranceClaudeActions.TASK_TOOL, onAContact).contains('can be related to'), 'A task is not related to a contact');
        Assert.isTrue(rejection(AntsuranceClaudeActions.TASK_TOOL, contactIsNotAContact).contains('Id of a Contact'), 'The contact must be a contact');
        Assert.isTrue(
            rejection(AntsuranceClaudeInsurance.NOTE_TOOL, new Map<String, Object>{ 'record_id' => insured.Id, 'note_type' => 'General', 'body' => 'x' }).contains('can be added to'),
            'A note does not go on a contact'
        );
        Assert.isTrue(
            rejection(AntsuranceClaudeInsurance.NOTE_TOOL, new Map<String, Object>{ 'record_id' => claim.Id, 'note_type' => 'General', 'body' => '' }).contains('body is required'),
            'A note needs text'
        );
        Assert.isTrue(
            rejection(AntsuranceClaudeInsurance.STATUS_TOOL, new Map<String, Object>{ 'case_id' => claim.Id, 'new_status' => 'In Progress' }).contains('Its statuses are'),
            'A claim does not take a service request status'
        );
        Assert.isTrue(
            rejection(AntsuranceClaudeInsurance.STATUS_TOOL, new Map<String, Object>{ 'case_id' => request.Id, 'new_status' => 'New' }).contains('already New'),
            'There is nothing to change when the status is the same'
        );
        Assert.isTrue(rejection('propose_refund', new Map<String, Object>()).contains('no such tool'), 'Unknown tools are rejected');

        delete request;
        Assert.isTrue(
            rejection(AntsuranceClaudeInsurance.STATUS_TOOL, new Map<String, Object>{ 'case_id' => request.Id, 'new_status' => 'Closed' }).contains('is visible'),
            'A record that cannot be read is reported'
        );
        Assert.areEqual(tasksBefore, [SELECT COUNT() FROM Task], 'No task was written');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'No note was written');
    }

    @IsTest
    static void confirmRejectsWhatItDoesNotRecognise() {
        Case claim = claim();
        Integer tasksBefore = [SELECT COUNT() FROM Task];

        Assert.isTrue(confirmFailure('not json').contains('could not be read'), 'Malformed payloads are rejected');
        Assert.isTrue(confirmFailure('{"kind":"refund"}').contains('could not be read'), 'Unknown kinds are rejected');
        Assert.isTrue(
            confirmFailure(JSON.serialize(new Map<String, Object>{ 'kind' => 'case_status', 'caseId' => claim.Id, 'status' => 'In Progress' })).contains('could not be read'),
            'A status the case cannot take is rejected even when sent straight to confirm'
        );
        Assert.isTrue(
            confirmFailure(JSON.serialize(new Map<String, Object>{ 'kind' => 'task', 'subject' => '', 'dueDate' => '2026-10-05', 'relatedId' => claim.Id })).contains('subject is required'),
            'A task still needs a subject'
        );
        Assert.areEqual(tasksBefore, [SELECT COUNT() FROM Task], 'Nothing was written');
    }

    @IsTest
    static void aChangeThatCannotBeSavedIsExplainedToTheUser() {
        Case claim = claim();

        Test.startTest();
        String message = confirmFailure(JSON.serialize(new Map<String, Object>{ 'kind' => 'file_note', 'recordId' => claim.Id, 'noteType' => 'General', 'body' => 'x'.repeat(40000) }));
        Test.stopTest();

        Assert.isTrue(message.contains('too long'), 'The user is told why the change was not made');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'Nothing was written');
    }

    @IsTest
    static void theToolsMatchTheOrg() {
        List<Object> tools = AntsuranceClaudeActions.toolDefinitions();
        Assert.areEqual(3, tools.size(), 'Three proposal tools');
        for (Object item : tools) {
            Map<String, Object> tool = (Map<String, Object>) item;
            Assert.isTrue(AntsuranceClaudeActions.isActionTool((String) tool.get('name')), 'Each tool is recognized as a proposal');
            Assert.areEqual(true, tool.get('strict'), 'Each tool has a strict schema');
            Assert.isTrue(((String) tool.get('description')).contains('Nothing is written unless they press Confirm'), 'Each description says it writes nothing');
        }
        Assert.isFalse(AntsuranceClaudeActions.isActionTool('query_salesforce'), 'The query tool is not a proposal');

        Set<String> noteTypes = new Set<String>();
        for (Schema.PicklistEntry entry : File_Note__c.Note_Type__c.getDescribe().getPicklistValues()) {
            noteTypes.add(entry.getValue());
        }
        Assert.areEqual(noteTypes, new Set<String>(AntsuranceClaudeInsurance.NOTE_TYPES), 'The note types offered are the picklist\'s values');

        Set<String> caseStatuses = new Set<String>();
        for (Schema.PicklistEntry entry : Case.Status.getDescribe().getPicklistValues()) {
            caseStatuses.add(entry.getValue());
        }
        for (List<String> offered : AntsuranceClaudeInsurance.STATUSES.values()) {
            Assert.isTrue(caseStatuses.containsAll(offered), 'Every status offered exists on Case: ' + offered);
        }
    }
}
