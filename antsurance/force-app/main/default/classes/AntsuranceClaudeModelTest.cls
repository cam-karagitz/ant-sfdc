/**
 * The chat in an org that has nothing else of ours: the data model note built from the org's own
 * schema, a record's facts, the task Claude may propose, and the words the components show. Every
 * test asks for the model that reads any org's schema and uses standard objects only, so the class
 * passes with Ask Claude installed alone as well as inside the full app.
 */
@IsTest
private class AntsuranceClaudeModelTest {
    private static AntsuranceClaudeModel anyOrg() {
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();
        return AntsuranceClaudeModel.current();
    }

    private static String openStage() {
        return [SELECT ApiName FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = FALSE ORDER BY SortOrder LIMIT 1].ApiName;
    }

    private static AntsuranceClaudeActions.Proposal propose(Map<String, Object> input) {
        return AntsuranceClaudeActions.propose('propose_task', 'toolu_1', input);
    }

    private static Map<String, Object> task(String subject, String relatedId, String contactId) {
        return new Map<String, Object>{
            'subject' => subject,
            'due_date' => String.valueOf(Date.today().addDays(2)),
            'related_record_id' => relatedId,
            'contact_id' => contactId,
            'priority' => 'High',
            'notes' => 'Asked for a call back.'
        };
    }

    private static String rejection(String toolName, Map<String, Object> input) {
        try {
            AntsuranceClaudeActions.propose(toolName, 'toolu_1', input);
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
        Account customer = new Account(Name = 'Harbor Mutual', Industry = 'Insurance', Phone = '312 555 0100');
        insert customer;
        Contact person = new Contact(FirstName = 'Maria', LastName = 'Reyes', AccountId = customer.Id);
        insert person;
        Opportunity sale = new Opportunity(Name = 'Harbor Mutual - Property', AccountId = customer.Id, StageName = openStage(), CloseDate = Date.today().addDays(20), Amount = 18400);
        insert sale;
        insert new Lead(LastName = 'Okafor', Company = 'Okafor Bakery');
        insert new List<Task>{
            new Task(Subject = 'Send the proposal', WhatId = sale.Id, ActivityDate = Date.today().addDays(2)),
            new Task(Subject = 'Finished already', WhatId = sale.Id, Status = 'Completed')
        };
    }

    @IsTest
    static void theDataModelNoteIsBuiltFromThisOrgsOwnSchema() {
        AntsuranceClaudeModel model = anyOrg();

        Test.startTest();
        String note = model.dataModel();
        String instructions = AntsuranceClaudeController.fixedInstructions(true);
        Test.stopTest();

        for (String objectName : new List<String>{ 'Account', 'Contact', 'Lead', 'Opportunity', 'Case', 'Task' }) {
            Assert.isTrue(note.contains('- ' + objectName), 'The note describes ' + objectName);
        }
        Assert.isTrue(note.contains('StageName (') && note.contains(openStage()), 'A picklist is listed with this org\'s own values');
        Assert.isTrue(note.contains('WhatId (the record it is about)'), 'And says how a task points at its record');
        Assert.isTrue(note.length() < 14000, 'The note stays small enough to send with every request: ' + note.length());
        for (Schema.SObjectType token : Schema.getGlobalDescribe().values()) {
            String name = String.valueOf(token);
            if (name.endsWith('__c') && !note.contains(name)) {
                Schema.DescribeSObjectResult description = token.getDescribe();
                Assert.isTrue(
                    !description.isAccessible() || !description.isQueryable() || description.isCustomSetting() || note.contains('Also readable'),
                    'A custom object this user can read is described or at least named: ' + name
                );
            }
        }
        Assert.isTrue(instructions.contains(UserInfo.getOrganizationName()), 'Claude is told which org it is in');
        Assert.isTrue(instructions.contains(note), 'And is given the note');
        Assert.isTrue(instructions.contains('propose_task') && !instructions.contains('propose_file_note'), 'It is offered the task, and nothing that needs another object');
        Assert.isFalse((model.intro() + model.actionsPrompt()).contains('—'), 'No em dashes in what we tell Claude');
    }

    @IsTest
    static void aRecordsFactsAreItsKeyFieldsAndItsOpenTasks() {
        anyOrg();
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Opportunity sale = [SELECT Id, StageName FROM Opportunity LIMIT 1];
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        Task todo = [SELECT Id FROM Task WHERE Subject = 'Send the proposal'];
        Product2 product = new Product2(Name = 'Widget', ProductCode = 'W-100');
        insert product;
        insert new ContentVersion(Title = 'Signed proposal', PathOnClient = 'proposal.pdf', VersionData = Blob.valueOf('pdf bytes'), FirstPublishLocationId = customer.Id);

        Test.startTest();
        String saleFacts = AntsuranceClaudeRecordFacts.describe(sale.Id);
        String customerFacts = AntsuranceClaudeRecordFacts.describe(customer.Id);
        String leadFacts = AntsuranceClaudeRecordFacts.describe(lead.Id);
        String taskFacts = AntsuranceClaudeRecordFacts.describe(todo.Id);
        String productFacts = AntsuranceClaudeRecordFacts.describe(product.Id);
        Test.stopTest();

        Assert.isTrue(saleFacts.startsWith(AntsuranceClaudeRecordFacts.INTRO), 'The note says what it is');
        Map<String, Object> record = (Map<String, Object>) JSON.deserializeUntyped(saleFacts.substringAfter(AntsuranceClaudeRecordFacts.INTRO));
        Assert.areEqual('Harbor Mutual - Property', record.get('Name'), 'The record is named');
        Assert.areEqual(sale.StageName, record.get('StageName'), 'With where it stands');
        Assert.areEqual(18400, Decimal.valueOf(String.valueOf(record.get('Amount'))).intValue(), 'And its amount');
        Assert.areEqual('Harbor Mutual', ((Map<String, Object>) record.get('Account')).get('Name'), 'A lookup comes with the name of what it points at');
        List<Object> tasks = (List<Object>) record.get('Tasks');
        Assert.areEqual(1, tasks.size(), 'Only the open task is listed');
        Assert.areEqual('Send the proposal', ((Map<String, Object>) tasks[0]).get('Subject'), 'By its subject');
        Assert.isFalse(record.containsKey('attributes'), 'Without the attributes wrapper');

        Assert.isTrue(customerFacts.contains('"Industry":"Insurance"'), 'An account comes with its key fields');
        Assert.isTrue(customerFacts.contains('Signed proposal'), 'And the names of the files attached to it');
        Assert.isTrue(leadFacts.contains('Okafor Bakery'), 'A lead has facts too');
        Assert.isTrue(taskFacts.contains('Send the proposal') && taskFacts.contains('Harbor Mutual - Property'), 'A task says what it is about');
        Assert.isTrue(productFacts.contains('Widget') && productFacts.contains('W-100'), 'An object with no list of its own gives its own fields');
        Assert.isNull(AntsuranceClaudeRecordFacts.describe(null), 'No record, no facts');
        delete lead;
        Assert.isNull(AntsuranceClaudeRecordFacts.describe(lead.Id), 'A record that cannot be read has no facts');
        Assert.areEqual('First sentence here. Second sentence follows it.', AntsuranceClaudeRecordFacts.excerpt('First sentence here. Second sentence follows it. Third is cut.', 60), 'Long text stops at the end of a sentence');
        Assert.areEqual('One two three', AntsuranceClaudeRecordFacts.excerpt('One two three four five six', 15), 'With no sentence end it stops at a word');
    }

    @IsTest
    static void aTaskIsProposedThenCreatedOnlyOnConfirm() {
        anyOrg();
        Opportunity sale = [SELECT Id FROM Opportunity LIMIT 1];
        Contact person = [SELECT Id FROM Contact LIMIT 1];
        Integer before = [SELECT COUNT() FROM Task];

        Test.startTest();
        AntsuranceClaudeActions.Proposal proposal = propose(task('Call Maria Reyes about the proposal', sale.Id, person.Id));
        Integer afterProposing = [SELECT COUNT() FROM Task];
        AntsuranceClaudeActions.Outcome outcome = AntsuranceClaudeActions.confirm(proposal.payloadJson);
        Test.stopTest();

        Assert.areEqual('task', proposal.kind, 'The card is for a task');
        Assert.areEqual('toolu_1', proposal.id, 'Keyed by the tool call');
        Assert.areEqual('Harbor Mutual - Property', detail(proposal, 'Related to'), 'It says what the task is about');
        Assert.areEqual('Maria Reyes', detail(proposal, 'Contact'), 'And whom');
        Assert.areEqual('High', detail(proposal, 'Priority'), 'With the priority asked for');
        Assert.areEqual(UserInfo.getName(), detail(proposal, 'Assigned to'), 'Assigned to the person asking');
        Assert.areEqual('Asked for a call back.', proposal.body, 'The notes are shown');
        Assert.areEqual(before, afterProposing, 'Proposing a task creates none');
        Task created = [SELECT Subject, WhatId, WhoId, Priority, ActivityDate, OwnerId, Description FROM Task WHERE Id = :outcome.recordId];
        Assert.areEqual('Call Maria Reyes about the proposal', created.Subject, 'Confirm creates the task as proposed');
        Assert.areEqual(sale.Id, created.WhatId, 'On the record it is about');
        Assert.areEqual(person.Id, created.WhoId, 'With its contact');
        Assert.areEqual(Date.today().addDays(2), created.ActivityDate, 'Due when asked');
        Assert.areEqual(UserInfo.getUserId(), created.OwnerId, 'Owned by the person who confirmed');
        Assert.isTrue(outcome.message.contains('Task created'), 'The card says what happened');
        Assert.areEqual(new List<Id>{ sale.Id }, outcome.touchedIds, 'And the record\'s page is refreshed');
    }

    @IsTest
    static void aTaskCanBeAboutAPersonACaseOrNothingAtAll() {
        anyOrg();
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        Case request = new Case(Subject = 'Printer will not start');
        insert request;
        request = [SELECT Id, CaseNumber FROM Case WHERE Id = :request.Id];

        Test.startTest();
        AntsuranceClaudeActions.Proposal aboutLead = propose(task('Call Okafor back', lead.Id, null));
        AntsuranceClaudeActions.Outcome leadTask = AntsuranceClaudeActions.confirm(aboutLead.payloadJson);
        AntsuranceClaudeActions.Proposal aboutCase = propose(task('Order the part', request.Id, null));
        AntsuranceClaudeActions.Proposal alone = propose(task('Review my open work', null, null));
        AntsuranceClaudeActions.Outcome standalone = AntsuranceClaudeActions.confirm(alone.payloadJson);
        Test.stopTest();

        Assert.areEqual('Okafor', detail(aboutLead, 'Related to'), 'A task can be about a lead');
        Task forLead = [SELECT WhoId, WhatId FROM Task WHERE Id = :leadTask.recordId];
        Assert.areEqual(lead.Id, forLead.WhoId, 'Who then becomes the task\'s person');
        Assert.isNull(forLead.WhatId, 'With nothing else related');
        Assert.areEqual('Case ' + request.CaseNumber + ': Printer will not start', detail(aboutCase, 'Related to'), 'A case is named by its number and subject');
        Assert.isNull(detail(alone, 'Related to'), 'A reminder can be about no record');
        Task reminder = [SELECT WhoId, WhatId, Subject FROM Task WHERE Id = :standalone.recordId];
        Assert.isTrue(reminder.WhoId == null && reminder.WhatId == null, 'And is saved that way');
        Assert.isTrue(standalone.touchedIds.isEmpty(), 'With no page to refresh');
    }

    @IsTest
    static void proposalsThatCannotBeMadeAreExplained() {
        AntsuranceClaudeModel model = anyOrg();
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        Assert.isTrue(rejection('propose_task', task('Call', UserInfo.getUserId(), null)).contains('A task can be related to'), 'A task cannot be about a user');
        Assert.isTrue(rejection('propose_task', task('Call', 'the Reyes file', null)).contains('not a record Id'), 'Text that is not an Id is refused');
        Assert.isTrue(rejection('propose_task', task('Call', customer.Id, customer.Id)).contains('contact_id must be the Id of a Contact'), 'The contact must be a contact');
        Assert.isTrue(rejection('propose_task', task('', customer.Id, null)).contains('subject is required'), 'A task needs a subject');
        Assert.isTrue(rejection('propose_task', task('x'.repeat(300), customer.Id, null)).contains('too long'), 'That fits its field');
        Map<String, Object> undated = task('Call', customer.Id, null);
        undated.put('due_date', 'soon');
        Assert.isTrue(rejection('propose_task', undated).contains('YYYY-MM-DD'), 'And a real due date');
        Assert.isTrue(rejection('propose_file_note', new Map<String, Object>{ 'record_id' => customer.Id }).contains('no such tool'), 'A change this org\'s model does not offer is refused');

        String payload = propose(task('Call Okafor back', lead.Id, null)).payloadJson;
        delete lead;
        Assert.isTrue(confirmFailure(payload).contains('No record'), 'A task about a record that has gone is not created');
        Assert.isTrue(confirmFailure('not json').contains('could not be read'), 'A payload that is not JSON is refused');
        Assert.isTrue(confirmFailure('{"kind":"file_note","recordId":"' + customer.Id + '"}').contains('could not be read'), 'So is a kind of change this org does not have');
        Assert.isNull(model.confirm('file_note', new Map<String, Object>()), 'The model for any org makes no change of its own');

        Assert.isTrue(AntsuranceClaudeActions.isActionTool('propose_task'), 'A propose tool is a proposal');
        Assert.isFalse(AntsuranceClaudeActions.isActionTool('show_chart') || AntsuranceClaudeActions.isActionTool(null), 'Nothing else is');
        List<Object> tools = AntsuranceClaudeActions.toolDefinitions();
        Assert.areEqual(1, tools.size(), 'One proposal tool in any org');
        Map<String, Object> tool = (Map<String, Object>) tools[0];
        Assert.areEqual(true, tool.get('strict'), 'With a strict schema');
        Assert.isTrue(((String) tool.get('description')).contains('Nothing is written unless they press Confirm'), 'That says it writes nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Subject = 'Call'], 'Nothing was created along the way');
    }

    @IsTest
    static void theWordsSuitAnyOrg() {
        AntsuranceClaudeModel model = anyOrg();

        Test.startTest();
        AntsuranceClaudeModel.Words words = model.words();
        Test.stopTest();

        Assert.isTrue(words.starters.size() >= 3 && words.starters.size() <= 6, 'A handful of starting points: ' + words.starters.size());
        List<AntsuranceClaudeModel.Starter> everything = new List<AntsuranceClaudeModel.Starter>(words.starters);
        everything.addAll(words.questions);
        for (List<AntsuranceClaudeModel.Starter> onARecord : words.recordStarters.values()) {
            Assert.areEqual(3, onARecord.size(), 'Three starting points on a record page');
            everything.addAll(onARecord);
        }
        for (AntsuranceClaudeModel.Starter starter : everything) {
            Assert.isFalse(String.isBlank(starter.title) || String.isBlank(starter.detail), 'Each has its words');
            Assert.isTrue(starter.key != null || !String.isBlank(starter.prompt), 'And a question, unless the chat words it from the open record');
            String said = (starter.title + ' ' + starter.detail + ' ' + starter.prompt).toLowerCase();
            Assert.isFalse(said.contains('claim') || said.contains('polic') || said.contains('premium'), 'None of them assumes an insurer: ' + said);
        }
        Assert.areEqual('summarize', words.anyRecordStarters[0].key, 'Any record can be summarized');
        Assert.areEqual('next_step', words.anyRecordStarters[2].key, 'And asked for its next step');
        Assert.isTrue(words.recordStarters.containsKey('Account') && words.recordStarters.containsKey('Case'), 'The standard objects have their own');
        Assert.isFalse(words.questions.isEmpty(), 'The Ask Claude tab has questions to try');
        Assert.areEqual(Schema.SObjectType.Account.getLabelPlural().toLowerCase(), words.objectWords.get('Account'), 'An object is called what this org calls it');
        Assert.areEqual('files', words.objectWords.get('ContentVersion'), 'And a file is a file');
        Assert.isFalse(String.isBlank(words.placeholder), 'The question box has its words');
    }

    @IsTest
    static void whatClaudeIsToldAndMayDoNamesNothingOfOurs() {
        AntsuranceClaudeModel model = anyOrg();
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Product2 product = new Product2(Name = 'Widget', ProductCode = 'W-100');
        insert product;

        Assert.isTrue(model.intro().contains(UserInfo.getOrganizationName()), 'Claude is introduced to this org');
        Assert.areEqual('', model.recordNamingRule() + model.rules() + model.snapshot(), 'With no rules or numbers that belong to another business');
        Assert.isTrue(model.queryExample().startsWith('SELECT ') && model.queryTopics().contains('accounts'), 'The query tool is described in standard objects');
        Assert.isTrue(model.actionsPrompt().contains('propose_task') && model.workToActOn().contains('Tasks'), 'A task is the change on offer');
        Assert.isTrue(model.mineExamples().contains('my accounts'), 'And "my records" is explained by example');
        Assert.isTrue(model.openRecordPage().contains('never call show_record') && model.alreadyOpen().contains('already open'), 'The open record is not drawn again');

        List<String> forms = model.formObjects();
        Assert.isTrue(forms.contains('Task') && forms.contains('Account') && forms.contains('Opportunity'), 'A form may create or edit the standard objects this user can');
        Assert.isTrue(model.emailObjects().contains('Contact'), 'An email can be opened on a contact');
        String country = model.defaultCountry();
        Assert.isTrue(country == null || country.length() == 2, 'A new address starts in the user\'s own country, when their locale gives one');
        Assert.isFalse(model.taskNeedsARecord(), 'A task can stand alone');
        Assert.isTrue(model.taskCanBeAbout('Account') && model.taskCanBeAbout('Lead') && !model.taskCanBeAbout('User'), 'Or be about anything that keeps activities, or a person');
        Assert.isTrue(model.isPerson('Lead') && !model.isPerson('Account'), 'A lead is a person');
        Assert.areEqual(Schema.SObjectType.Account.getLabel().toLowerCase(), model.wordFor('Account'), 'A record is called what this org calls it');
        Assert.areEqual('record', model.wordFor('No_Such_Object'), 'Or a record');
        Assert.areEqual('case', model.caseKind(null), 'A case is a case');
        Assert.areEqual('CaseNumber', AntsuranceClaudeModel.nameFieldOf(Schema.SObjectType.Case), 'A case is named by its number');
        Assert.isNull(model.factsQuery('No_Such_Object'), 'An object that is not here has no facts');

        AntsuranceClaudeDisplay.Block card = AntsuranceClaudeDisplay.build('show_record', 'toolu_d', new Map<String, Object>{ 'record_id' => String.valueOf(product.Id) }, null);
        Map<String, Object> spec = (Map<String, Object>) JSON.deserializeUntyped(card.specJson);
        Assert.areEqual('Widget', spec.get('name'), 'Any record can be drawn as a card');
        Assert.areEqual('utility:record', spec.get('icon'), 'With a plain icon when its object has none of its own');
        Assert.isFalse(((List<Object>) spec.get('facts')).isEmpty(), 'And its own fields as facts');

        AntsuranceClaudeModel.standIn = null;
        Assert.isNotNull(AntsuranceClaudeModel.current(), 'Left alone, the chat finds the model for the org it is in');
    }

    /** An org's own model: what a customer writes to tell the chat about their records. */
    public class OrgsOwnModel extends AntsuranceClaudeModel {
        public override String intro() {
            return 'You help the people at Acme with their policies.\n\n';
        }
    }

    @IsTest
    static void anOrgCanNameItsOwnModel() {
        AntsuranceClaudeModel.standIn = null;

        AntsuranceClaudeModel.found = null;
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Chat_Model_Class__c = ' AntsuranceClaudeModelTest.OrgsOwnModel ');
        Assert.isTrue(AntsuranceClaudeModel.current() instanceof OrgsOwnModel, 'The class named in the setting is the one the chat uses');
        Assert.isTrue(AntsuranceClaudeModel.current().intro().contains('Acme'), 'And it speaks for that org');

        AntsuranceClaudeModel.found = null;
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Chat_Model_Class__c = 'No_Such_Class_Here');
        Assert.isFalse(AntsuranceClaudeModel.current() instanceof OrgsOwnModel, 'A name that is not a class is passed over');
        Assert.isNotNull(AntsuranceClaudeModel.current(), 'And the chat still has a model');

        AntsuranceClaudeModel.found = null;
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Chat_Model_Class__c = 'AntsuranceAiSettings');
        Assert.isNotNull(AntsuranceClaudeModel.current(), 'A class that is not a model is passed over too');

        AntsuranceClaudeModel.found = null;
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Chat_Model_Class__c = null);
        Assert.isFalse(AntsuranceClaudeModel.current() instanceof OrgsOwnModel, 'With no name the built-in one is used');
    }
}
