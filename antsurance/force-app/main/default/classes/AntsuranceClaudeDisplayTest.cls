/**
 * What Claude may draw: each block's checks, and a turn of blocks through the chat. Every record here
 * is a standard object, so these tests run in an org that has Ask Claude and nothing else of ours.
 * Where a test depends on the org's data model it asks for the model that reads any org's schema;
 * AntsuranceClaudeInsuranceTest covers the insurance model's cards and forms.
 */
@IsTest
private class AntsuranceClaudeDisplayTest {
    private static final String USER_TURN = '[{"role":"user","content":"How is the book doing?"}]';

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

    @TestSetup
    static void createRecords() {
        Account customer = new Account(Name = 'Harbor Mutual');
        insert customer;
        Contact person = new Contact(FirstName = 'Maria', LastName = 'Reyes', AccountId = customer.Id);
        insert person;
        String stage = [SELECT ApiName FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = FALSE ORDER BY SortOrder LIMIT 1].ApiName;
        insert new Opportunity(Name = 'Harbor Mutual - Property', AccountId = customer.Id, StageName = stage, CloseDate = Date.today().addDays(20), Amount = 18400);
        insert new Lead(LastName = 'Okafor', Company = 'Okafor Bakery');
        insert new Task(Subject = 'Call about the renewal', ActivityDate = Date.today().addDays(-3), WhatId = customer.Id, WhoId = person.Id);
    }

    private static Map<String, Object> input(String inputJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(inputJson);
    }

    private static Map<String, Object> draw(String toolName, String inputJson) {
        return draw(toolName, inputJson, null);
    }

    private static Map<String, Object> draw(String toolName, String inputJson, Id openRecordId) {
        AntsuranceClaudeDisplay.Block block = AntsuranceClaudeDisplay.build(toolName, 'toolu_d', input(inputJson), openRecordId);
        Assert.areEqual('toolu_d', block.id, 'The block is keyed by the tool call');
        Assert.isFalse(String.isBlank(block.result), 'Claude is told what happened');
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

    private static List<Object> fieldsOf(Map<String, Object> spec) {
        return (List<Object>) spec.get('fields');
    }

    private static Map<String, Object> fieldNamed(Map<String, Object> spec, String name) {
        for (Object item : fieldsOf(spec)) {
            if (((Map<String, Object>) item).get('name') == name) {
                return (Map<String, Object>) item;
            }
        }
        return null;
    }

    @IsTest
    static void everyDisplayToolRequiresAllItsPropertiesAndNoOthers() {
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();
        List<Object> tools = (List<Object>) JSON.deserializeUntyped('[' + AntsuranceClaudeDisplay.toolDefinitionsJson() + ']');

        Assert.areEqual(8, tools.size(), 'Eight display tools');
        for (Object item : tools) {
            Map<String, Object> tool = (Map<String, Object>) item;
            Assert.isTrue(AntsuranceClaudeDisplay.isDisplayTool((String) tool.get('name')), tool.get('name') + ' is a display tool');
            Assert.isNull(tool.get('strict'), 'Not a strict tool: together they make the request\'s grammar too large');
            Map<String, Object> schema = (Map<String, Object>) tool.get('input_schema');
            Assert.areEqual(((Map<String, Object>) schema.get('properties')).size(), ((List<Object>) schema.get('required')).size(), 'Every property is required');
            Assert.areEqual(false, schema.get('additionalProperties'), 'No other properties are accepted');
            Assert.areEqual('say', ((List<Object>) schema.get('required'))[0], 'Each tool starts with the words to show above its block');
        }
        Assert.isFalse(AntsuranceClaudeDisplay.isDisplayTool('query_salesforce'), 'The query tool is not a display tool');
        Assert.isFalse(AntsuranceClaudeDisplay.toolDefinitionsJson().contains('—'), 'No em dashes in what Claude reads');
    }

    @IsTest
    static void figuresAreDrawnAsUpToFourTiles() {
        Map<String, Object> spec = draw('show_metrics', '{"tiles":[{"label":"Open claims","value":"28","note":"","tone":"watch"},{"label":"Reserve","value":"$1,077,075","note":"across 28 claims","tone":"loud"}]}');
        List<Object> tiles = (List<Object>) spec.get('tiles');

        Assert.areEqual(2, tiles.size(), 'Both tiles are drawn');
        Assert.isNull(((Map<String, Object>) tiles[0]).get('note'), 'An empty note is left out');
        Assert.areEqual('neutral', ((Map<String, Object>) tiles[1]).get('tone'), 'An unknown tone falls back to neutral');
        String tile = '{"label":"A","value":"1","note":"","tone":"neutral"}';
        Assert.isTrue(refusal('show_metrics', '{"tiles":[' + tile + ',' + tile + ',' + tile + ',' + tile + ',' + tile + ']}').contains('At most 4'), 'A fifth tile is refused');
        Assert.isTrue(refusal('show_metrics', '{"tiles":[]}').contains('at least 1'), 'No tiles is refused');
        Assert.isTrue(refusal('show_metrics', '{"tiles":[{"label":"","value":"1","note":"","tone":"neutral"}]}').contains('label'), 'A tile needs its label');
    }

    @IsTest
    static void aChartKeepsItsPointsAndDropsAHighlightThatNamesNone() {
        String points = '"points":[{"label":"Homeowners","value":184250},{"label":"Personal Auto","value":96400.5}]';
        Map<String, Object> spec = draw('show_chart', '{"title":"Premium by line","chart_type":"bar","unit":"dollars",' + points + ',"highlight_label":"Homeowners","caption":"Policies in force"}');

        Assert.areEqual('bar', spec.get('chartType'), 'The chart type is kept');
        Assert.areEqual('Homeowners', spec.get('highlight'), 'The highlight names a point');
        Assert.areEqual(2, ((List<Object>) spec.get('points')).size(), 'Both points are kept');
        Assert.isNull(draw('show_chart', '{"title":"T","chart_type":"line","unit":"count",' + points + ',"highlight_label":"Umbrella","caption":""}').get('highlight'), 'A highlight that names no point is dropped');

        String slice = '{"label":"A","value":1}';
        String seven = slice + ',' + slice + ',' + slice + ',' + slice + ',' + slice + ',' + slice + ',' + slice;
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"donut","unit":"count","points":[' + seven + '],"highlight_label":"","caption":""}').contains('At most 6'), 'A donut takes six slices');
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"bar","unit":"count","points":[{"label":"A","value":"lots"},' + slice + '],"highlight_label":"","caption":""}').contains('must be a number'), 'A value must be a number');
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"bar","unit":"count","points":[{"label":"A","value":-4},' + slice + '],"highlight_label":"","caption":""}').contains('negative'), 'A bar cannot be negative');
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"pie","unit":"count","points":[' + slice + ',' + slice + '],"highlight_label":"","caption":""}').contains('chart_type'), 'An unknown chart type is refused');
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"bar","unit":"euros","points":[' + slice + ',' + slice + '],"highlight_label":"","caption":""}').contains('unit'), 'An unknown unit is refused');
        Assert.isTrue(refusal('show_chart', '{"title":"T","chart_type":"donut","unit":"count","points":[{"label":"A","value":0},{"label":"B","value":0}],"highlight_label":"","caption":""}').contains('more than zero'), 'An empty donut is refused');
    }

    @IsTest
    static void aWorkListKeepsThreeChipsARowAndDropsABadLink() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        String chips = '[{"label":"Due Oct 1","tone":"alert"},{"label":"High","tone":"watch"},{"label":"New","tone":"neutral"},{"label":"Extra","tone":"neutral"},{"label":"","tone":"neutral"}]';
        Map<String, Object> spec = draw(
            'show_work_list',
            '{"title":"Overdue tasks","items":[{"title":"Call Maria","subtitle":"Harbor Mutual","record_id":"' + customer.Id + '","amount":"$400","chips":' + chips + '},' +
            '{"title":"Send ID cards","subtitle":"","record_id":"the task","amount":"","chips":[]}]}'
        );
        List<Object> items = (List<Object>) spec.get('items');

        Assert.areEqual(3, ((List<Object>) ((Map<String, Object>) items[0]).get('chips')).size(), 'Three chips at most');
        Assert.areEqual(String.valueOf(customer.Id), (String) ((Map<String, Object>) items[0]).get('recordId'), 'A real Id becomes the row\'s link');
        Assert.isNull(((Map<String, Object>) items[1]).get('recordId'), 'Text that is not an Id is no link');
        Assert.isTrue(refusal('show_work_list', '{"title":"","items":[{"title":"A","subtitle":"","record_id":"","amount":"","chips":[]}]}').contains('title'), 'The list needs a title');
    }

    @IsTest
    static void draftsComparisonsTimelinesAndNextQuestionsAreChecked() {
        Map<String, Object> draft = draw('show_draft', '{"say":"Here is the email.","format":"memo","to_name":"Maria Reyes","to_email":"","subject":"Your claim","body":"Hello Maria.","related_record_id":""}');
        Assert.areEqual('email', draft.get('format'), 'Anything but a letter is an email');
        Assert.isNull(draft.get('toEmail'), 'A missing address is left out');
        Assert.isTrue(refusal('show_draft', '{"format":"email","to_name":"","to_email":"","subject":"S","body":"","related_record_id":""}').contains('body'), 'A draft needs a body');
        Assert.isNull(draft.get('emailRecordId'), 'A draft about no record has nothing to open the composer on');
        Id customerId = [SELECT Id FROM Account LIMIT 1].Id;
        Id taskId = [SELECT Id FROM Task LIMIT 1].Id;
        Assert.areEqual(String.valueOf(customerId), (String) draw('show_draft', '{"format":"email","subject":"S","body":"B","related_record_id":"' + customerId + '"}').get('emailRecordId'), 'An email about a customer opens on the customer');
        Assert.isNull(draw('show_draft', '{"format":"email","subject":"S","body":"B","related_record_id":"' + taskId + '"}').get('emailRecordId'), 'The composer does not open on a task');

        String columns = '"columns":[{"name":"Basic","record_id":"","recommended":true},{"name":"Plus","record_id":"","recommended":true}]';
        Map<String, Object> comparison = draw('show_comparison', '{"title":"Options",' + columns + ',"rows":[{"label":"Premium","values":["$1,200",""]}],"reason":"Lower deductible"}');
        List<Object> options = (List<Object>) comparison.get('columns');
        Assert.areEqual(true, ((Map<String, Object>) options[0]).get('recommended'), 'The first option flagged is recommended');
        Assert.areEqual(false, ((Map<String, Object>) options[1]).get('recommended'), 'Only one option is recommended');
        Assert.areEqual('None', ((List<Object>) ((Map<String, Object>) ((List<Object>) comparison.get('rows'))[0]).get('values'))[1], 'An empty cell says None');
        Assert.isTrue(refusal('show_comparison', '{"title":"Options",' + columns + ',"rows":[{"label":"Premium","values":["$1,200"]}],"reason":""}').contains('one value per option'), 'A row needs a value for every option');
        Assert.isTrue(refusal('show_comparison', '{"title":"Options","columns":[{"name":"Basic","record_id":"","recommended":false}],"rows":[],"reason":""}').contains('at least 2'), 'One option is not a comparison');

        Map<String, Object> timeline = draw('show_timeline', '{"title":"Claim so far","events":[{"date":"2026-09-01","title":"Reported","detail":"","tone":"neutral"},{"date":"2026-09-04T10:00:00Z","title":"Reserve set","detail":"$40,000","tone":"good"}]}');
        Assert.areEqual('2026-09-04', ((Map<String, Object>) ((List<Object>) timeline.get('events'))[1]).get('date'), 'A date and time keeps its date');
        Assert.isTrue(refusal('show_timeline', '{"title":"T","events":[{"date":"last week","title":"Reported","detail":"","tone":"neutral"},{"date":"2026-09-04","title":"B","detail":"","tone":"neutral"}]}').contains('YYYY-MM-DD'), 'A date must be a date');

        Assert.isTrue(refusal('show_everything', '{}').contains('no such tool'), 'An unknown tool is refused');
        Assert.areEqual('Here is the email.', AntsuranceClaudeDisplay.build('show_draft', 'toolu_d', input('{"say":" Here is the email. ","format":"email","subject":"S","body":"B"}'), null).say, 'The words for above the block come with it');
    }

    @IsTest
    static void followUpQuestionsAreReadOffTheEndOfTheWords() {
        AntsuranceClaudeDisplay.Words words = AntsuranceClaudeDisplay.readNextQuestions(
            'There are **28** open claims.\n\n- Is 5 > 3?\n\n?> Which are overdue?\n?>Who handles them?\n\n ?> Any SIU referrals? \n?> A fourth?\n'
        );

        Assert.areEqual('There are **28** open claims.\n\n- Is 5 > 3?', words.text, 'The answer loses only the question lines at its end');
        Assert.areEqual(new List<String>{ 'Which are overdue?', 'Who handles them?', 'Any SIU referrals?' }, words.questions, 'Three questions at most, in order');
        AntsuranceClaudeDisplay.Words plain = AntsuranceClaudeDisplay.readNextQuestions('?> not at the end\nJust an answer.');
        Assert.areEqual('?> not at the end\nJust an answer.', plain.text, 'A line that is not at the end is left alone');
        Assert.isTrue(plain.questions.isEmpty(), 'No questions');
        Assert.isTrue(AntsuranceClaudeDisplay.readNextQuestions(null).questions.isEmpty(), 'No words, no questions');
        Assert.areEqual('next_questions', AntsuranceClaudeDisplay.nextQuestions(words.questions).kind, 'The questions become a block of buttons');
    }

    @IsTest
    static void aRecordCardIsDrawnFromWhateverTheRecordHolds() {
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Opportunity sale = [SELECT Id, StageName FROM Opportunity LIMIT 1];
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        Task task = [SELECT Id FROM Task LIMIT 1];

        Map<String, Object> customerCard = draw('show_record', '{"record_id":"' + customer.Id + '"}');
        Assert.areEqual('compact', customerCard.get('card'), 'The card is drawn from the facts sent with it');
        Assert.areEqual('Harbor Mutual', customerCard.get('name'), 'The card is named');
        Assert.areEqual('utility:company', customerCard.get('icon'), 'And carries its object\'s icon');

        Map<String, Object> saleCard = draw('show_record', '{"record_id":"' + sale.Id + '"}');
        Assert.areEqual(sale.StageName, saleCard.get('status'), 'A record with a stage says where it stands');
        Assert.areEqual('$18,400', saleCard.get('figure'), 'Its first amount is its headline figure');
        Assert.areEqual('watch', saleCard.get('tone'), 'An open record is one to watch');
        List<Object> saleFacts = (List<Object>) saleCard.get('facts');
        Assert.isFalse(saleFacts.isEmpty(), 'The card carries the record\'s facts');
        Boolean namesItsAccount = false;
        for (Object fact : saleFacts) {
            namesItsAccount = namesItsAccount || ((Map<String, Object>) fact).get('value') == 'Harbor Mutual';
        }
        Assert.isTrue(namesItsAccount, 'A lookup is shown by the name of what it points at');
        List<Object> saleKeyFacts = (List<Object>) saleCard.get('keyFacts');
        Assert.isTrue(saleKeyFacts.size() > 0 && saleKeyFacts.size() <= 3, 'The narrow panel gets at most three facts to show');
        Assert.areEqual('$18,400', ((Map<String, Object>) saleKeyFacts[0]).get('value'), 'Led by the headline figure');

        Assert.areEqual('Okafor', draw('show_record', '{"record_id":"' + lead.Id + '"}').get('name'), 'A lead is named');
        Map<String, Object> taskCard = draw('show_record', '{"record_id":"' + task.Id + '"}');
        Assert.areEqual('Call about the renewal', taskCard.get('name'), 'A task is named by its subject');
        Assert.areEqual('Overdue', taskCard.get('status'), 'A task past its due date says so');
        Assert.areEqual('alert', taskCard.get('tone'), 'An overdue task is an alert');

        Case request = new Case(Subject = 'Printer will not start');
        insert request;
        Map<String, Object> caseCard = draw('show_record', '{"record_id":"' + request.Id + '"}');
        Assert.areEqual('Printer will not start', caseCard.get('name'), 'A numbered record is named by its subject');
        Assert.isTrue(((String) caseCard.get('eyebrow')).contains([SELECT CaseNumber FROM Case WHERE Id = :request.Id].CaseNumber), 'With its number above');

        Assert.isTrue(refusal('show_record', '{"record_id":"' + customer.Id + '"}', customer.Id).contains('already open'), 'The open record is not drawn again');
        Assert.isTrue(refusal('show_record', '{"record_id":"the Reyes claim"}').contains('must be a record Id'), 'Text that is not an Id is refused');
        delete lead;
        Assert.isTrue(refusal('show_record', '{"record_id":"' + lead.Id + '"}').contains('No record'), 'A record that cannot be read is refused');
    }

    @IsTest
    static void aCreateFormCarriesSuggestionsAndTheFieldsARecordNeeds() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        String status = Lead.Status.getDescribe().getPicklistValues()[0].getValue();
        AntsuranceClaudeDisplay.Block block = AntsuranceClaudeDisplay.build(
            'show_form',
            'toolu_f',
            input(formJson('create', 'Lead', '', '', new Map<String, String>{ 'FirstName' => 'Dana', 'LastName' => 'Whitfield', 'Status' => status.toUpperCase(), 'Email' => '' })),
            null
        );
        Map<String, Object> spec = (Map<String, Object>) JSON.deserializeUntyped(block.specJson);

        Assert.areEqual('form', block.kind, 'The block is a form');
        Assert.areEqual('create', spec.get('mode'), 'It creates');
        Assert.areEqual('New lead', spec.get('title'), 'The title says what it makes');
        Assert.areEqual('Whitfield', fieldNamed(spec, 'LastName').get('value'), 'A suggestion is carried');
        Assert.areEqual(true, fieldNamed(spec, 'LastName').get('suggested'), 'A suggestion is marked');
        Assert.areEqual(status, fieldNamed(spec, 'Status').get('value'), 'A picklist value is matched whatever its case');
        Assert.areEqual(false, fieldNamed(spec, 'Email').get('suggested'), 'An empty value is left for the user');
        Assert.isNotNull(fieldNamed(spec, 'Company'), 'A required field Claude left out is added');
        Assert.isTrue(block.result.contains('Nothing has been written') && block.result.contains('Company'), 'Claude is told nothing was written and what was added');
        Assert.isNull(spec.get('note'), 'The note for Claude is not sent to the page');
        Assert.areEqual(1, [SELECT COUNT() FROM Lead], 'Drawing a form creates nothing');

        Map<String, Object> reminder = draw('show_form', formJson('create', 'Task', '', '', new Map<String, String>{ 'Subject' => 'Call Dana', 'IsReminderSet' => 'yes' }));
        Assert.areEqual(true, fieldNamed(reminder, 'IsReminderSet').get('value'), 'A checkbox takes yes');
        Map<String, Object> sale = draw(
            'show_form',
            formJson('create', 'Opportunity', '', '', new Map<String, String>{ 'Name' => 'Harbor Mutual - Umbrella', 'AccountId' => customer.Id, 'Amount' => '$1,250', 'CloseDate' => '2026-11-15' })
        );
        Assert.areEqual('1250', String.valueOf(fieldNamed(sale, 'Amount').get('value')), 'A number loses its symbols');
        Assert.isNotNull(fieldNamed(sale, 'StageName'), 'The stage is required on a sale');
    }

    @IsTest
    static void aFormThatCannotBeDrawnSaysWhy() {
        Account customer = [SELECT Id FROM Account LIMIT 1];
        Contact person = [SELECT Id FROM Contact LIMIT 1];

        Assert.isTrue(refusal('show_form', formJson('create', 'User', '', '', new Map<String, String>{ 'LastName' => 'X' })).contains('can create or edit only'), 'Only listed objects');
        Assert.isTrue(refusal('show_form', formJson('create', 'Lead', '', '', new Map<String, String>{ 'Favourite_Colour__c' => 'Clay' })).contains('no field'), 'An unknown field is refused');
        Assert.isTrue(refusal('show_form', formJson('create', 'Lead', '', '', new Map<String, String>{ 'Status' => 'Thinking about it' })).contains('Its values are'), 'A picklist value must exist');
        Assert.isTrue(refusal('show_form', formJson('create', 'Contact', '', '', new Map<String, String>{ 'Name' => 'Dana Whitfield' })).contains('FirstName and LastName'), 'A person is named in two fields');
        Assert.isTrue(refusal('show_form', formJson('create', 'Contact', '', '', new Map<String, String>{ 'LastName' => 'W', 'AccountId' => person.Id })).contains('cannot point at'), 'A lookup must point at the right object');
        Assert.isTrue(refusal('show_form', formJson('create', 'Contact', '', '', new Map<String, String>{ 'LastName' => 'W', 'AccountId' => 'Harbor Mutual' })).contains('lookup'), 'A lookup takes an Id');
        Assert.isTrue(refusal('show_form', formJson('create', 'Contact', '', '', new Map<String, String>{ 'LastName' => 'W', 'Birthdate' => 'next spring' })).contains('YYYY-MM-DD'), 'A date must be a date');
        Assert.isTrue(refusal('show_form', formJson('create', 'Task', '', '', new Map<String, String>{ 'Subject' => 'Call Dana', 'IsReminderSet' => 'maybe' })).contains('true or false'), 'A checkbox is true or false');
        Assert.isTrue(refusal('show_form', formJson('create', 'Opportunity', '', '', new Map<String, String>{ 'Amount' => 'a lot' })).contains('number'), 'A number must be a number');
        Assert.isTrue(refusal('show_form', formJson('create', 'Account', '', 'Franchise', new Map<String, String>{ 'Name' => 'X' })).contains('record type'), 'A record type must exist');
        Assert.isTrue(refusal('show_form', formJson('create', 'Lead', '', 'Hot', new Map<String, String>{ 'LastName' => 'X' })).contains('record type'), 'An object without record types takes none');
        Assert.isTrue(refusal('show_form', formJson('edit', 'Contact', customer.Id, '', new Map<String, String>{ 'LastName' => 'W' })).contains('not the Id of a Contact'), 'The record must be of that object');
        Assert.isTrue(refusal('show_form', formJson('edit', 'Contact', '', '', new Map<String, String>{ 'LastName' => 'W' })).contains('must be a record Id'), 'Editing needs a record');
        Assert.isTrue(refusal('show_form', formJson('edit', 'Contact', person.Id, '', new Map<String, String>{ 'CreatedDate' => '2026-01-01' })).contains('cannot set any'), 'A form of fields nobody can set is refused');
        Assert.isTrue(refusal('show_form', formJson('create', 'Lead', '', '', new Map<String, String>{ 'LastName' => 'X'.repeat(90) })).contains('at most'), 'Text must fit its field');
    }

    @IsTest
    static void anEditFormShowsWhatEachSuggestionReplaces() {
        Opportunity sale = [SELECT Id FROM Opportunity LIMIT 1];
        AntsuranceClaudeDisplay.Block block = AntsuranceClaudeDisplay.build(
            'show_form',
            'toolu_f',
            input(formJson('edit', 'Opportunity', sale.Id, '', new Map<String, String>{ 'Amount' => '19000', 'CloseDate' => '2026-12-01', 'NextStep' => 'Send the quote', 'Description' => '', 'CreatedDate' => '2026-01-01', 'Id' => sale.Id })),
            null
        );
        Map<String, Object> spec = (Map<String, Object>) JSON.deserializeUntyped(block.specJson);

        Assert.areEqual('Edit Harbor Mutual - Property', spec.get('title'), 'The title names the record');
        Assert.areEqual(String.valueOf(sale.Id), (String) spec.get('recordId'), 'The form edits that record');
        Assert.areEqual('$18,400', fieldNamed(spec, 'Amount').get('current'), 'The current amount is shown beside the suggestion');
        Assert.areEqual('empty', fieldNamed(spec, 'NextStep').get('current'), 'An empty field says so');
        Assert.isNull(fieldNamed(spec, 'Description').get('current'), 'A field with no suggestion shows only its own value');
        Assert.isNull(fieldNamed(spec, 'CreatedDate'), 'A field nobody can set is left off');
        Assert.isTrue(block.result.contains('CreatedDate'), 'Claude is told what was left off');
        Assert.isTrue([SELECT Amount FROM Opportunity WHERE Id = :sale.Id].Amount == 18400, 'Drawing a form changes nothing');
    }

    @IsTest
    static void aTurnOfBlocksEndsTheExchangeAndWritesNothing() {
        String turn =
            '{"model":"claude-opus-5-5","stop_reason":"tool_use","content":[' +
            '{"type":"tool_use","id":"toolu_m","name":"show_metrics","input":{"say":"Most of the reserve sits on three claims.\\n\\n?> Which three claims?\\n?> Who handles them?",' +
            '"tiles":[{"label":"Reserve","value":"$1,077,075","note":"","tone":"watch"}]}},' +
            '{"type":"tool_use","id":"toolu_c","name":"show_chart","input":{"say":"","title":"Reserve by severity","chart_type":"bar","unit":"dollars",' +
            '"points":[{"label":"High","value":700000},{"label":"Low","value":377075}],"highlight_label":"","caption":"Open claims"}}]}';
        AntsuranceClaudeModel.standIn = new AntsuranceClaudeModel();
        ClaudeMock mock = new ClaudeMock(turn);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, 'panel');
        Test.stopTest();

        Assert.isTrue(reply.done, 'A turn that only draws ends the exchange');
        Assert.areEqual('Most of the reserve sits on three claims.', reply.text, 'Claude\'s words come from the first block, without the follow-up lines');
        Assert.areEqual(3, reply.blocks.size(), 'Both blocks are returned, in order, then the follow-up questions');
        Assert.areEqual('metrics', reply.blocks[0].kind, 'The figures come first');
        Assert.areEqual('chart', reply.blocks[1].kind, 'Then the chart');
        Assert.areEqual('next_questions', reply.blocks[2].kind, 'The follow-ups come last');
        Assert.isTrue(reply.blocks[2].specJson.contains('Who handles them?'), 'The follow-up questions were read from the words');
        List<Object> appended = (List<Object>) JSON.deserializeUntyped(reply.appendedJson);
        List<Object> results = (List<Object>) ((Map<String, Object>) appended[1]).get('content');
        Assert.areEqual(2, results.size(), 'Each display call gets its result, so the conversation can be replayed');
        Assert.isNull(((Map<String, Object>) results[0]).get('is_error'), 'The block was accepted');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.request.getBody());
        Assert.areEqual(10, ((List<Object>) body.get('tools')).size(), 'The display tools are offered with the query tool and the task proposal');
        List<Object> instructions = (List<Object>) body.get('system');
        Assert.isTrue(((String) ((Map<String, Object>) instructions[0]).get('text')).contains('show_chart'), 'Claude is told what it can draw');
        Assert.isTrue(((String) ((Map<String, Object>) instructions[1]).get('text')).contains('narrow panel'), 'Claude is told what is on screen');
    }

    @IsTest
    static void ablockThatFailsHoldsTheOthersBackForClaudeToCorrect() {
        String turn =
            '{"model":"claude-opus-5-5","stop_reason":"tool_use","content":[' +
            '{"type":"tool_use","id":"toolu_m","name":"show_metrics","input":{"tiles":[{"label":"Reserve","value":"$1,077,075","note":"","tone":"watch"}]}},' +
            '{"type":"tool_use","id":"toolu_r","name":"show_record","input":{"record_id":"the largest claim"}}]}';
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(turn));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, null);
        Test.stopTest();

        Assert.isFalse(reply.done, 'Claude gets the chance to correct the call');
        Assert.isTrue(reply.blocks.isEmpty(), 'Nothing is drawn until the turn is right');
        List<Object> results = (List<Object>) ((Map<String, Object>) ((List<Object>) JSON.deserializeUntyped(reply.appendedJson))[1]).get('content');
        Assert.isTrue(((String) ((Map<String, Object>) results[0]).get('content')).contains('Call it again'), 'The good block is held back');
        Assert.isTrue(((String) ((Map<String, Object>) results[1]).get('content')).contains('was not drawn'), 'The bad block says why');
    }

    @IsTest
    static void blocksAreStillDrawnPastTheLookupLimit() {
        String round =
            ',{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"query_salesforce","input":{"query":"SELECT Name FROM Account"}}]}' +
            ',{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"{}"}]}';
        String fourRounds = '[{"role":"user","content":"How is the book doing?"}' + round + round + round + round + ']';
        String turn =
            '{"model":"claude-opus-5-5","stop_reason":"tool_use","content":[' +
            '{"type":"tool_use","id":"toolu_m","name":"show_metrics","input":{"say":"One figure.","tiles":[{"label":"Reserve","value":"$1,077,075","note":"","tone":"watch"}]}}]}';
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(turn));

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(fourRounds, null, null, null);
        Test.stopTest();

        Assert.isTrue(reply.done, 'Drawing is not a lookup');
        Assert.areEqual(1, reply.blocks.size(), 'The block is drawn');
    }

    @IsTest
    static void aPlainAnswerCanEndWithFollowUpQuestions() {
        Test.setMock(
            HttpCalloutMock.class,
            new ClaudeMock('{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Marcus Lindahl is handling it.\\n\\n?> What is the reserve?\\n?> Show the file notes"}]}')
        );

        Test.startTest();
        AntsuranceClaudeController.ChatReply reply = AntsuranceClaudeController.sendChatStep(USER_TURN, null, null, null);
        AntsuranceClaudeController.ChatReply plain = AntsuranceClaudeController.sendMessage(USER_TURN, null);
        Test.stopTest();

        Assert.areEqual('Marcus Lindahl is handling it.', reply.text, 'The answer is shown without the question lines');
        Assert.areEqual(1, reply.blocks.size(), 'The questions become buttons');
        Assert.isTrue(reply.appendedJson.contains('?> What is the reserve?'), 'The conversation replays what Claude wrote, unchanged');
        Assert.isTrue(plain.text.contains('?>') && plain.blocks.isEmpty(), 'A caller that draws nothing gets the words as written');
    }
}
