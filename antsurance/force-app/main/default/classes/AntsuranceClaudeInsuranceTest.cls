/**
 * The chat with the insurance model: what Claude is told here, the cards, facts and forms of the
 * insurance records, and the changes only this model offers. These tests need the full app's objects,
 * so they ship with it and not with Ask Claude alone. AntsuranceClaudeRecordFactsTest and
 * AntsuranceClaudeActionsTest cover the open record's facts and the file note and status proposals.
 */
@IsTest
private class AntsuranceClaudeInsuranceTest {
    private static final String QUESTION = '{"role":"user","content":"What is going on with my accounts?"}';
    private static final String USER_TURN = '[' + QUESTION + ']';
    private static final String FINAL_ANSWER =
        '{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[' +
        '{"type":"thinking","thinking":"","signature":"sig"},' +
        '{"type":"text","text":"Harbor Mutual is your only account."}]}';
    // The chat panel's fixed instructions as the eval in scripts/eval was last run against them, with the
    // shared reserve rule left out because it belongs to AntsuranceClaimRules and changes with it.
    private static final String INSTRUCTIONS_DIGEST = '1bb4307f2f6d1486925a10ae8d831091bbfa2cd1803f8a477420e46e17aced38';
    private static final String RESERVE_RULE_STANDS_IN = '<AntsuranceClaimRules.RESERVE_RULE>';

    private class ClaudeMock implements HttpCalloutMock {
        private final String body;
        public HttpRequest request;

        ClaudeMock(String body) {
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(body);
            return response;
        }
    }

    private static Id recordTypeId(String developerName) {
        return Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    private static String proposal(String toolName, Map<String, Object> input) {
        return '{"model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},"content":[' +
            '{"type":"tool_use","id":"toolu_p","name":"' + toolName + '","input":' + JSON.serialize(input) + '}]}';
    }

    /** The tool_result block a step appended for Claude. */
    private static Map<String, Object> toolResultFrom(AntsuranceClaudeController.ChatReply reply) {
        List<Object> appended = (List<Object>) JSON.deserializeUntyped(reply.appendedJson);
        Map<String, Object> results = (Map<String, Object>) appended[1];
        return (Map<String, Object>) ((List<Object>) results.get('content'))[0];
    }

    private static Map<String, Object> bodyOf(HttpRequest request) {
        return (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
    }

    /** One of the two instruction blocks sent: 0 is the fixed, cached one and 1 changes per request. */
    private static Map<String, Object> systemBlock(HttpRequest request, Integer position) {
        return (Map<String, Object>) ((List<Object>) bodyOf(request).get('system'))[position];
    }

    private static Map<String, Object> input(String inputJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(inputJson);
    }

    private static Map<String, Object> draw(String toolName, String inputJson) {
        return draw(toolName, inputJson, null);
    }

    private static Map<String, Object> draw(String toolName, String inputJson, Id openRecordId) {
        AntsuranceClaudeDisplay.Block block = AntsuranceClaudeDisplay.build(toolName, 'toolu_d', input(inputJson), openRecordId);
        return (Map<String, Object>) JSON.deserializeUntyped(block.specJson);
    }

    private static String refusal(String toolName, String inputJson) {
        return refusal(toolName, inputJson, null);
    }

    private static String refusal(String toolName, String inputJson, Id openRecordId) {
        try {
            AntsuranceClaudeDisplay.build(toolName, 'toolu_d', input(inputJson), openRecordId);
            Assert.fail('Expected the call to be refused');
        } catch (IllegalArgumentException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String formJson(String mode, String objectName, String recordId, String recordType, Map<String, String> fields) {
        List<Object> entries = new List<Object>();
        for (String name : fields.keySet()) {
            entries.add(new Map<String, Object>{ 'name' => name, 'value' => fields.get(name) });
        }
        return JSON.serialize(new Map<String, Object>{ 'mode' => mode, 'object' => objectName, 'record_id' => recordId, 'record_type' => recordType, 'fields' => entries });
    }

    private static Map<String, Object> fieldNamed(Map<String, Object> spec, String name) {
        for (Object item : (List<Object>) spec.get('fields')) {
            if (((Map<String, Object>) item).get('name') == name) {
                return (Map<String, Object>) item;
            }
        }
        return null;
    }

    /** A tool's input schema as its property names and types, in order, without the words. */
    private static String shapeOf(Object node) {
        Map<String, Object> schema = (Map<String, Object>) node;
        String shape = String.valueOf(schema.get('type'));
        if (schema.containsKey('properties')) {
            Map<String, Object> properties = (Map<String, Object>) schema.get('properties');
            List<String> parts = new List<String>();
            for (Object name : (List<Object>) schema.get('required')) {
                parts.add(name + ':' + shapeOf(properties.get((String) name)));
            }
            shape += '{' + String.join(parts, ',') + '}';
        }
        if (schema.containsKey('items')) {
            shape += '[' + shapeOf(schema.get('items')) + ']';
        }
        return shape;
    }

    @TestSetup
    static void createRecords() {
        Account customer = new Account(Name = 'Harbor Mutual', Industry = 'Insurance');
        insert customer;
        Contact person = new Contact(FirstName = 'Maria', LastName = 'Reyes', AccountId = customer.Id);
        insert person;
        insert new Opportunity(Name = 'Harbor Mutual - Property', AccountId = customer.Id, StageName = 'Submission Received', CloseDate = Date.today().addDays(20), Amount = 18400);
        insert new Lead(LastName = 'Okafor', Company = 'Okafor Bakery');
        insert new Task(Subject = 'Call about the renewal', ActivityDate = Date.today().addDays(-3), WhatId = customer.Id, WhoId = person.Id);
    }

    @IsTest
    static void theFullAppsModelIsTheOneTheChatUses() {
        Assert.isTrue(AntsuranceClaudeModel.current() instanceof AntsuranceClaudeInsurance, 'With the insurance model in the org, the chat finds it by name');
    }

    /**
     * The chat's eval is a measure of these exact instructions. This fails when they change, on purpose
     * or not, so a change is never silent: put the new digest above and run the eval again.
     */
    @IsTest
    static void theInstructionsHaveNotChangedByAccident() {
        String instructions = AntsuranceClaudeController.fixedInstructions(true).replace(AntsuranceClaimRules.RESERVE_RULE, RESERVE_RULE_STANDS_IN);
        String digest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(instructions)));

        Assert.areEqual(
            INSTRUCTIONS_DIGEST,
            digest,
            'The chat\'s instructions changed (' + instructions.length() + ' characters now). If that was meant, set INSTRUCTIONS_DIGEST to ' + digest + ' and run the eval in scripts/eval again.'
        );
        Assert.isTrue(AntsuranceClaudeController.fixedInstructions(false).contains('Data model, with the API names to use in SOQL'), 'Other callers get the insurance data model too');
    }

    /** Compiles only while every field named in the data model note exists. */
    @IsTest
    static void theDataModelNoteNamesRealFields() {
        List<Account> accounts = [SELECT Customer_Segment__c, Customer_Since__c, Active_Policies__c, Premium_in_Force__c, Customer_Brief__c FROM Account LIMIT 1];
        List<Contact> people = [SELECT Household_Role__c, Primary_Member__c, Licensed_Driver__c, Preferred_Contact_Method__c FROM Contact LIMIT 1];
        List<Policy__c> policies = [
            SELECT Name, Account__r.Name, Primary_Insured__c, Producer__c, Line_of_Business__c, Status__c, Effective_Date__c, Expiration_Date__c,
                Days_to_Renewal__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Billing_Frequency__c, Payment_Status__c, Insured_Item__c, Underwriting_Notes__c,
                Incurred_Losses__c, Loss_Ratio__c,
                (SELECT Name, Category__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, Premium_Amount__c, What_Is_Covered__c FROM Coverages__r),
                (SELECT Name, Contact__c, Role__c, Status__c, Relationship_to_Insured__c, License_State__c, Years_Licensed__c, Driver_Rating__c,
                    Violations_Past_3_Years__c, Accidents_Past_3_Years__c FROM Participants__r),
                (SELECT Name, Asset_Type__c, Identifier__c, Model_Year__c, Location__c, Use__c, Details__c, Insured_Value__c, Lienholder__c FROM Assets__r),
                (SELECT Name, Form_Number__c, Type__c, Status__c, Effective_Date__c, Premium_Change__c, Limit_Amount__c, Description__c FROM Endorsements__r),
                (SELECT Id FROM Cases__r),
                (SELECT Id FROM File_Notes__r)
            FROM Policy__c
            LIMIT 1
        ];
        List<Case> cases = [
            SELECT Policy__c, Reported_Date__c, Date_of_Loss__c, Loss_Type__c, Loss_Location__c, Severity__c, Estimated_Loss__c, Reserve_Amount__c,
                Paid_Amount__c, Outstanding_Reserve__c, Coverage_Check__c, SIU_Referral__c, Subrogation_Potential__c, Request_Type__c,
                Handled_By__c, Days_Open__c, Claude_Brief__c, Claude_Brief_At__c
            FROM Case
            LIMIT 1
        ];
        List<File_Note__c> notes = [SELECT Case__c, Policy__c, Account__c, Note_Type__c, Note_Date__c, Author_Name__c, Body__c FROM File_Note__c LIMIT 1];
        List<Opportunity> sales = [
            SELECT Line_of_Business__c, Type, Policy__c, Amount,
                (SELECT Name, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Issued_Date__c, Days_Since_Issued__c, ExpirationDate, Description,
                    Underwriter__c, Submission_Channel__c, Needs_Underwriting_Review__c, Configuration__c FROM Quotes)
            FROM Opportunity
            LIMIT 1
        ];
        List<Lead> leads = [SELECT Product_Interest__c FROM Lead LIMIT 1];
        List<Task> tasks = [SELECT OwnerId, Subject, ActivityDate, Status, Priority, IsClosed, WhatId, WhoId FROM Task LIMIT 1];

        Assert.isTrue(AntsuranceClaudeInsurance.DATA_MODEL.contains('Policy__c'), 'The note describes policies');
        for (String field : new List<String>{ 'Incurred_Losses__c', 'Loss_Ratio__c', 'Handled_By__c', 'Days_Open__c', 'Claude_Brief__c', 'Submission_Channel__c', 'Policy_Asset__c', 'Policy_Endorsement__c' }) {
            Assert.isTrue(AntsuranceClaudeInsurance.DATA_MODEL.contains(field), 'The note covers ' + field);
        }
        Assert.areEqual(1, accounts.size(), 'The setup account is readable with its insurance fields');
        Assert.areEqual(1, people.size(), 'The setup contact is readable with its household fields');
        Assert.isTrue(policies.isEmpty() && cases.isEmpty() && notes.isEmpty(), 'No policy data in this test');
        Assert.isTrue(sales.size() == 1 && leads.size() == 1 && tasks.size() == 1, 'The setup sale, lead and task are readable with their insurance fields');
    }

    @IsTest
    static void aCaseIsDescribedByItsTypeAndSubject() {
        Case claim = new Case(
            Subject = 'Burst pipe in basement',
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId()
        );
        insert claim;
        claim = [SELECT CaseNumber FROM Case WHERE Id = :claim.Id];

        Test.startTest();
        AntsuranceClaudeController.RecordContext context = AntsuranceClaudeController.getRecordContext(claim.Id);
        Test.stopTest();

        Assert.areEqual('Case', context.objectApiName, 'Still identifies the object');
        Assert.areEqual('Claim', context.objectLabel, 'Uses the record type as the label');
        Assert.areEqual(claim.CaseNumber + ': Burst pipe in basement', context.name, 'Adds the subject to the case number');
    }

    @IsTest
    static void theChatStepSendsTheOpenRecordsFactsAndOffersTheProposalTools() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        ClaudeMock mock = new ClaudeMock(FINAL_ANSWER);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, customer.Id, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'An answer ends the exchange');
        Assert.isTrue(reply.proposals.isEmpty(), 'An answer proposes nothing');
        HttpRequest request = mock.request;
        String changing = (String) systemBlock(request, 1).get('text');
        Assert.isTrue(changing.contains('Facts about the open record'), 'The open record\'s facts are sent with the question');
        Assert.isTrue(changing.contains('Harbor Mutual') && changing.contains('Reyes'), 'The facts carry the record and its related rows');
        String fixed = (String) systemBlock(request, 0).get('text');
        Assert.isTrue(fixed.contains('writes nothing') && fixed.contains('Confirm'), 'Claude is told a proposal writes nothing until the user confirms');
        List<Object> tools = (List<Object>) bodyOf(request).get('tools');
        Assert.areEqual(12, tools.size(), 'Offers the query tool, the three proposal tools and the eight display tools');
        for (Integer index = 1; index < 4; index++) {
            String description = (String) ((Map<String, Object>) tools[index]).get('description');
            Assert.isTrue(description.contains('Nothing is written unless they press Confirm'), 'Each proposal tool says it writes nothing');
        }
    }

    @IsTest
    static void aFileNoteThatCannotBeMadeGoesBackToClaude() {
        Map<String, Object> input = new Map<String, Object>{ 'record_id' => 'the Reyes file', 'note_type' => 'General', 'body' => 'Called the insured.' };
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(proposal('propose_file_note', input)));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, null);
        Test.stopTest();

        Assert.isFalse(reply.done, 'Claude gets the chance to correct the proposal');
        Assert.isTrue(reply.proposals.isEmpty(), 'No card is shown');
        Assert.areEqual(true, toolResultFrom(reply).get('is_error'), 'The problem is reported as a tool error');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'Nothing was written');
    }

    @IsTest
    static void aRecordCardIsTheRecordsOwnCardOrACompactOne() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Opportunity sale = [SELECT Id FROM Opportunity LIMIT 1];
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        Task task = [SELECT Id FROM Task LIMIT 1];

        Map<String, Object> customerCard = draw('show_record', '{"record_id":"' + customer.Id + '"}');
        Assert.areEqual('customer', customerCard.get('card'), 'A customer gets its page card where there is room');
        Assert.areEqual('Harbor Mutual', customerCard.get('name'), 'The card is named');
        Assert.areEqual('utility:company', customerCard.get('icon'), 'And its object\'s icon');
        Assert.areEqual('contact', draw('show_record', '{"record_id":"' + [SELECT Id FROM Contact LIMIT 1].Id + '"}').get('card'), 'A contact gets its page card');

        Map<String, Object> saleCard = draw('show_record', '{"record_id":"' + sale.Id + '"}');
        Assert.areEqual('compact', saleCard.get('card'), 'A sale gets the compact card');
        Assert.areEqual('$18,400', saleCard.get('figure'), 'The premium is its headline figure');
        Assert.isFalse(((List<Object>) saleCard.get('facts')).isEmpty(), 'The card carries the sale\'s facts');
        List<Object> saleKeyFacts = (List<Object>) saleCard.get('keyFacts');
        Assert.isTrue(saleKeyFacts.size() > 0 && saleKeyFacts.size() <= 3, 'The narrow panel gets at most three facts to show');
        Assert.areEqual('$18,400', ((Map<String, Object>) saleKeyFacts[0]).get('value'), 'A sale leads with its premium');
        List<Object> customerKeyFacts = (List<Object>) customerCard.get('keyFacts');
        Assert.areEqual('Open claims', ((Map<String, Object>) customerKeyFacts[customerKeyFacts.size() - 1]).get('label'), 'A customer\'s open claims are counted for the panel');

        Assert.areEqual('Okafor Bakery', ((Map<String, Object>) ((List<Object>) draw('show_record', '{"record_id":"' + lead.Id + '"}').get('facts'))[0]).get('value'), 'A lead leads with its company');
        Map<String, Object> taskCard = draw('show_record', '{"record_id":"' + task.Id + '"}');
        Assert.areEqual('Overdue', taskCard.get('status'), 'A task past its due date says so');
        Assert.areEqual('alert', taskCard.get('tone'), 'An overdue task is an alert');

        Assert.isTrue(refusal('show_record', '{"record_id":"' + customer.Id + '"}', customer.Id).contains('already open'), 'The open record is not drawn again');
        Assert.isTrue(refusal('show_record', '{"record_id":"' + UserInfo.getUserId() + '"}').contains('show_record can show'), 'Other objects are refused');
        Assert.isTrue(refusal('show_record', '{"record_id":"the Reyes claim"}').contains('must be a record Id'), 'Text that is not an Id is refused');
        delete lead;
        Assert.isTrue(refusal('show_record', '{"record_id":"' + lead.Id + '"}').contains('No record'), 'A record that cannot be read is refused');
    }

    @IsTest
    static void aClaimAPolicyAndAQuoteGetTheirPageCards() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Opportunity sale = [SELECT Id FROM Opportunity LIMIT 1];
        Date start = Date.today().addMonths(-2);
        Policy__c policy = new Policy__c(Name = 'ANT-HO-1', Account__c = customer.Id, Status__c = 'Active', Annual_Premium__c = 2240, Effective_Date__c = start, Expiration_Date__c = start.addYears(1));
        insert policy;
        Case claim = new Case(Subject = 'Burst pipe in basement', RecordTypeId = recordTypeId('Claim'), AccountId = customer.Id, Policy__c = policy.Id, Status = 'New', Severity__c = 'High', Reserve_Amount__c = 45000, Paid_Amount__c = 5000);
        Case request = new Case(Subject = 'Add a driver', RecordTypeId = recordTypeId('Policy_Service'), AccountId = customer.Id, Policy__c = policy.Id, Status = 'New');
        insert new List<Case>{ claim, request };
        Quote option = new Quote(Name = 'Standard', OpportunityId = sale.Id);
        insert option;

        Map<String, Object> claimCard = draw('show_record', '{"record_id":"' + claim.Id + '"}');
        Assert.areEqual('case', claimCard.get('card'), 'A claim gets its page card');
        Assert.areEqual('Burst pipe in basement', claimCard.get('name'), 'Named by its subject');
        Assert.areEqual('alert', claimCard.get('tone'), 'A severe open claim is an alert');
        Assert.areEqual('$40,000', claimCard.get('figure'), 'Its outstanding reserve is its headline figure');
        Assert.areEqual('watch', draw('show_record', '{"record_id":"' + request.Id + '"}').get('tone'), 'An open service request is one to watch');
        Map<String, Object> policyCard = draw('show_record', '{"record_id":"' + policy.Id + '"}');
        Assert.areEqual('policy', policyCard.get('card'), 'A policy gets its page card');
        Assert.areEqual('utility:shield', policyCard.get('icon'), 'And its icon');
        Assert.areEqual('$2,240', policyCard.get('figure'), 'Its premium is its headline figure');
        Assert.areEqual('quote', draw('show_record', '{"record_id":"' + option.Id + '"}').get('card'), 'A quote gets its page card');
    }

    @IsTest
    static void aNewCustomerFormTakesItsRecordTypeAndState() {
        Map<String, Object> household = draw('show_form', formJson('create', 'Account', '', 'Household', new Map<String, String>{ 'Name' => 'Whitfield Household', 'BillingState' => 'IL' }));
        Assert.isNotNull(household.get('recordTypeId'), 'The record type is resolved');
        if (Account.SObjectType.getDescribe().fields.getMap().containsKey('billingstatecode')) {
            // This org has state and country picklists, so the form uses the code fields and puts the country first.
            Assert.areEqual('IL', fieldNamed(household, 'BillingStateCode').get('value'), 'A state is set through its code field');
            Assert.areEqual('US', fieldNamed(household, 'BillingCountryCode').get('value'), 'A state brings its country with it');
            Assert.isNull(fieldNamed(household, 'BillingState'), 'The text field is not on the form');
        }
        List<String> offered = AntsuranceClaudeModel.current().formObjects();
        Assert.isTrue(offered.contains('Policy__c') && offered.contains('File_Note__c'), 'A form may create or edit the insurance objects');
    }

    @IsTest
    static void theComponentsShowTheInsuranceWords() {
        Test.startTest();
        AntsuranceClaudeModel.Words words = AntsuranceClaudeController.getWords();
        Test.stopTest();

        Assert.areEqual(6, words.starters.size(), 'Six starting points with no record open');
        Assert.areEqual('Chart premium in force by line of business', words.starters[0].prompt, 'Starting with the book');
        Assert.areEqual(3, words.recordStarters.get('Policy__c').size(), 'Three starting points on a policy');
        Assert.areEqual('summarize', words.recordStarters.get('Case')[0].key, 'A claim starts with its summary, which the chat words from the record');
        Assert.areEqual(3, words.anyRecordStarters.size(), 'And three on any other record');
        Assert.areEqual(5, words.questions.size(), 'Five questions to try on the Ask Claude tab');
        Assert.areEqual('policies', words.objectWords.get('Policy__c'), 'An object is named in plain words while Claude reads it');
        Assert.isTrue(words.placeholder.contains('policies'), 'The question box says what to ask about');
    }

    /**
     * The two models word the display tools differently, and the chat's components draw what either
     * sends, so the tools must keep the same names and the same properties in the same order.
     */
    @IsTest
    static void bothModelsOfferTheSameDisplayToolsInTheirOwnWords() {
        List<Object> insurance = (List<Object>) JSON.deserializeUntyped('[' + new AntsuranceClaudeInsurance().displayTools() + ']');
        List<Object> anyOrg = (List<Object>) JSON.deserializeUntyped('[' + new AntsuranceClaudeModel().displayTools() + ']');

        Assert.areEqual(8, insurance.size(), 'Eight display tools');
        Assert.areEqual(insurance.size(), anyOrg.size(), 'The same number in any org');
        for (Integer index = 0; index < insurance.size(); index++) {
            Map<String, Object> ours = (Map<String, Object>) insurance[index];
            Map<String, Object> theirs = (Map<String, Object>) anyOrg[index];
            Assert.areEqual(ours.get('name'), theirs.get('name'), 'The same tool in the same place');
            Assert.areEqual(shapeOf(ours.get('input_schema')), shapeOf(theirs.get('input_schema')), ours.get('name') + ' takes the same input in both');
        }
        Assert.areEqual(3, new AntsuranceClaudeInsurance().actionTools().size(), 'The insurance model offers a task, a file note and a status change');
        Assert.areEqual(1, new AntsuranceClaudeModel().actionTools().size(), 'Any org is offered the task');
    }
}
