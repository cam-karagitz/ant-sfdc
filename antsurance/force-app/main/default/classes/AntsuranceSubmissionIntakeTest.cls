@IsTest
private class AntsuranceSubmissionIntakeTest {
    /** Answers each call with the next canned response and keeps the requests for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        List<String> bodies = new List<String>();
        List<HttpRequest> requests = new List<HttpRequest>();
        Boolean timesOut = false;

        ClaudeMock(String text) {
            add(text);
        }

        ClaudeMock add(String text) {
            bodies.add(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => text } }
                    }
                )
            );
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            if (timesOut) {
                throw new CalloutException('Read timed out');
            }
            Integer index = Math.min(requests.size(), bodies.size() - 1);
            requests.add(request);
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(bodies[index]);
            return response;
        }
    }

    private static final String PDF = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 a small test document'));

    private static Opportunity newSale(String customerName, String lineOfBusiness) {
        Account customer = new Account(Name = customerName, NumberOfEmployees = 22);
        insert customer;
        Opportunity sale = new Opportunity(
            Name = customerName + ' sale',
            AccountId = customer.Id,
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId(),
            StageName = 'Submission Received',
            CloseDate = Date.today().addDays(30),
            Line_of_Business__c = lineOfBusiness
        );
        insert sale;
        return sale;
    }

    private static Id attach(Id recordId, String title, String path, Blob body) {
        ContentVersion version = new ContentVersion(Title = title, PathOnClient = path, VersionData = body, FirstPublishLocationId = recordId);
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    private static String answer(String key, String value, Integer page, String words, String basis) {
        return JSON.serialize(new Map<String, Object>{ 'key' => key, 'value' => value, 'page' => page, 'words' => words, 'basis' => basis, 'note' => basis == 'worked_out' ? 'Placed in its range' : '' });
    }

    private static String document(String kind, List<String> answers, String extra) {
        return '{"kind":"' +
            kind +
            '","title":"A document","pages":2,"summary":"What it says.","answers":[' +
            String.join(answers, ',') +
            '],' +
            extra +
            '"unreadable":""}';
    }

    private static final String NO_EXTRAS = '"facts":[],"losses":[],"problems":[],';

    private static String failureOf(String action, Id recordId, String first, String second, String third) {
        try {
            if (action == 'upload') {
                AntsuranceSubmissionIntake.readUpload(recordId, first, second, third);
            } else if (action == 'file') {
                AntsuranceSubmissionIntake.readRecordFile(recordId, (Id) first);
            } else if (action == 'sample') {
                AntsuranceSubmissionIntake.readSample(recordId, first);
            } else if (action == 'assemble') {
                AntsuranceSubmissionIntake.assemble(recordId, first, second);
            } else if (action == 'advise') {
                AntsuranceSubmissionIntake.advise(recordId, first, second);
            } else {
                AntsuranceSubmissionIntake.getContext(recordId);
            }
            Assert.fail('Expected a refusal');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    /** Two documents that agree on payroll, disagree on the number of claims, and say nothing about a drug-free workplace. */
    private static String twoReadings() {
        AntsuranceSubmissionIntake.Reading application = AntsuranceSubmissionIntake.toReading(
            'Application',
            (Map<String, Object>) JSON.deserializeUntyped(
                document(
                    'application',
                    new List<String>{
                        answer('payroll', '1,530,000', 1, 'Total estimated annual payroll $1,530,000', 'read'),
                        answer('classGroup', 'healthcare', 1, 'General and pediatric dentistry', 'worked_out'),
                        answer('priorClaims', '1to3', 2, 'claims in the past three years 3', 'worked_out'),
                        answer('plan', 'guaranteed', 2, 'Guaranteed cost', 'read'),
                        answer('ownersIncluded', 'Yes', 1, 'owners and officers to be covered Yes', 'read')
                    },
                    NO_EXTRAS
                )
            ),
            questions()
        );
        AntsuranceSubmissionIntake.Reading lossRun = AntsuranceSubmissionIntake.toReading(
            'Loss run',
            (Map<String, Object>) JSON.deserializeUntyped(
                document(
                    'loss_run',
                    new List<String>{ answer('priorClaims', '4plus', 1, 'Three year summary Claims 4', 'worked_out'), answer('payroll', '1530000', 1, 'Estimated payroll $1,530,000', 'read') },
                    '"facts":[],"losses":[{"period":"Dec 1, 2024 to Dec 1, 2025","claims":1,"paid":14300,"reserved":6500,"note":"One claim still open."}],"problems":[],'
                )
            ),
            questions()
        );
        // The loss run comes first here, so the order the documents arrived in is not what puts the application first.
        return JSON.serialize(new List<AntsuranceSubmissionIntake.Reading>{ lossRun, application });
    }

    private static List<AntsuranceQuoteConfigurator.Question> questions() {
        List<AntsuranceQuoteConfigurator.Question> questions = new List<AntsuranceQuoteConfigurator.Question>();
        for (AntsuranceQuoteConfigurator.Section section : AntsuranceQuoteConfigurator.getQuestionnaire('Workers Compensation')) {
            questions.addAll(section.questions);
        }
        return questions;
    }

    private static AntsuranceSubmissionIntake.Row rowFor(AntsuranceSubmissionIntake.Assembly assembly, String key) {
        for (AntsuranceSubmissionIntake.Row row : assembly.rows) {
            if (row.key == key) {
                return row;
            }
        }
        return null;
    }

    @IsTest
    static void theCardKnowsTheLineTheFilesAndWhetherAQuoteCanFollow() {
        Opportunity sale = newSale(AntsuranceSubmissionIntake.SAMPLE_CUSTOMER, AntsuranceSubmissionIntake.SAMPLE_LINE);
        attach(sale.Id, 'Loss runs', 'loss-runs.pdf', Blob.valueOf('%PDF small'));
        attach(sale.Id, 'Notes', 'notes.txt', Blob.valueOf('plain text'));

        AntsuranceSubmissionIntake.Context context = AntsuranceSubmissionIntake.getContext(sale.Id);
        Assert.areEqual('sale', context.recordKind);
        Assert.areEqual('Workers Compensation', context.lineOfBusiness);
        Assert.isTrue(context.canRead, 'The line has quote questions');
        Assert.isTrue(context.canQuote, 'An open sale can take a quote');
        Assert.areEqual(2, context.files.size(), 'Both files on the sale are listed');
        for (AntsuranceSubmissionIntake.FileItem file : context.files) {
            Assert.areEqual(file.extension == 'pdf', file.readable, file.title + ': only the PDF can be read');
            Assert.areEqual(file.extension == 'pdf' ? null : AntsuranceSubmissionIntake.WRONG_KIND, file.whyNot);
        }
        Integer installed = [SELECT COUNT() FROM StaticResource WHERE Name LIKE 'antsuranceSubmission%'];
        Assert.areEqual(Math.min(installed, 3), context.samples.size(), 'The sample is offered on the customer it is about');

        Opportunity other = newSale('Another Business', 'Workers Compensation');
        Assert.isTrue(AntsuranceSubmissionIntake.getContext(other.Id).samples.isEmpty(), 'No sample for a customer it is not about');

        Lead lead = new Lead(LastName = 'Tanaka', Company = 'Lantern Street Pediatrics', Product_Interest__c = 'Workers Compensation');
        insert lead;
        AntsuranceSubmissionIntake.Context onLead = AntsuranceSubmissionIntake.getContext(lead.Id);
        Assert.areEqual('lead', onLead.recordKind);
        Assert.isTrue(onLead.canRead, 'A lead for a line with questions can be read into');
        Assert.isFalse(onLead.canQuote, 'A lead has to be converted before it is quoted');

        Opportunity unknown = newSale('No Line Yet', null);
        AntsuranceSubmissionIntake.Context none = AntsuranceSubmissionIntake.getContext(unknown.Id);
        Assert.isFalse(none.canRead, 'A sale with no line of business has no questions to read into');
        Assert.areEqual(AntsuranceSubmissionIntake.NO_QUESTIONS, none.whyNot);
        Assert.areEqual(AntsuranceSubmissionIntake.NO_ACCESS, failureOf('context', sale.AccountId, null, null, null), 'Only a sale or a lead');
    }

    @IsTest
    static void aDocumentIsReadIntoAnswersTheQuestionsCanTake() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        ClaudeMock mock = new ClaudeMock(
            document(
                'application',
                new List<String>{
                    answer('payroll', '$1,530,000', 1, 'Total estimated annual payroll $1,530,000', 'read'),
                    answer('experienceMod', 'average', 2, 'experience modification factor 0.94', 'worked_out'),
                    answer('safetyProgram', 'Yes', 2, 'written safety program Yes', 'read'),
                    answer('state', 'Illinois', 1, 'Illinois (all employees)', 'read'),
                    answer('classGroup', 'dentistry', 1, 'General and pediatric dentistry', 'read'),
                    answer('payroll', '999', 2, 'a second figure', 'read'),
                    answer('employees', 'about two dozen', 1, 'about two dozen', 'read')
                },
                '"facts":[{"label":"Current carrier","value":"Quillhaven Mutual","page":1},{"label":"","value":"dropped","page":1}],"losses":[{"period":"Dec 1, 2024 to Dec 1, 2025","claims":1,"paid":14300,"reserved":6500,"note":"Open."},{"period":"","claims":2,"paid":0,"reserved":0,"note":""}],"problems":["The drug-free question is not answered."],'
            )
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceSubmissionIntake.Reading reading = AntsuranceSubmissionIntake.readUpload(sale.Id, 'application.pdf', 'application/pdf', PDF);
        Test.stopTest();

        Assert.areEqual('application.pdf', reading.name);
        Assert.areEqual('Application', reading.kindLabel);
        Map<String, AntsuranceSubmissionIntake.Found> found = new Map<String, AntsuranceSubmissionIntake.Found>();
        for (AntsuranceSubmissionIntake.Found item : reading.answers) {
            found.put(item.key, item);
        }
        Assert.areEqual('1530000', found.get('payroll').value, 'An amount is kept as digits, and the first answer to a question wins');
        Assert.areEqual('worked_out', found.get('experienceMod').basis);
        Assert.areEqual('true', found.get('safetyProgram').value, 'Yes becomes the option the question keeps');
        Assert.areEqual('IL', found.get('state').value, 'A label is turned into its option value');
        Assert.isFalse(found.containsKey('classGroup'), 'An answer that is not one of the options is not kept as an answer');
        Assert.isFalse(found.containsKey('employees'), 'Words are not kept as a number');
        Set<String> facts = new Set<String>();
        for (AntsuranceSubmissionIntake.Fact fact : reading.facts) {
            facts.add(fact.label + '=' + fact.value);
        }
        Assert.isTrue(facts.contains('Kind of work=dentistry'), 'What the document said is kept as a fact instead: ' + facts);
        Assert.isTrue(facts.contains('Employees=about two dozen'));
        Assert.isTrue(facts.contains('Current carrier=Quillhaven Mutual'));
        Assert.areEqual(3, reading.facts.size(), 'A fact with no label is dropped, and a second answer to a question is not kept at all');
        Assert.areEqual(1, reading.losses.size(), 'A loss row with no period is dropped');
        Assert.areEqual(6500, reading.losses[0].reserved);
        Assert.areEqual(1, reading.problems.size());
        Assert.isNull(reading.unreadable, 'An empty answer means it could all be read');

        String sent = mock.requests[0].getBody();
        Assert.isTrue(sent.contains('"type":"document"'), 'The PDF goes to Claude as a document');
        Assert.isTrue(sent.contains('experienceMod | Experience mod | choice'), 'Claude is given the questions and their options');
        Assert.isTrue(sent.contains('Never guess'), 'And told not to guess');
    }

    @IsTest
    static void filesClaudeCannotReadHereAreRefusedInPlainWords() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(document('other', new List<String>(), NO_EXTRAS)));
        Assert.areEqual(AntsuranceSubmissionIntake.WRONG_KIND, failureOf('upload', sale.Id, 'notes.docx', 'application/msword', PDF));
        Assert.areEqual(AntsuranceSubmissionIntake.WRONG_KIND, failureOf('upload', sale.Id, 'empty.pdf', 'application/pdf', ''));
        String large = EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(AntsuranceSubmissionIntake.MAX_PDF_BYTES + 1)));
        Assert.areEqual(AntsuranceSubmissionIntake.PDF_TOO_LARGE, failureOf('upload', sale.Id, 'big.pdf', 'application/pdf', large));
        large = EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(AntsuranceSubmissionIntake.MAX_IMAGE_BYTES + 1)));
        Assert.areEqual(AntsuranceSubmissionIntake.IMAGE_TOO_LARGE, failureOf('upload', sale.Id, 'big.png', 'image/png', large));
        Assert.areEqual(AntsuranceSubmissionIntake.NO_SAMPLE, failureOf('sample', sale.Id, 'antsuranceDamageRearQuarter', null, null), 'Only the sample submission can be read this way');

        Opportunity unknown = newSale('No Line Yet', null);
        Assert.areEqual(AntsuranceSubmissionIntake.NO_QUESTIONS, failureOf('upload', unknown.Id, 'a.pdf', 'application/pdf', PDF));
    }

    @IsTest
    static void aFileAlreadyOnTheRecordIsReadAndOneElsewhereIsNot() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        Opportunity other = newSale('Another Business', 'Workers Compensation');
        Id onSale = attach(sale.Id, 'Loss runs', 'loss-runs.pdf', Blob.valueOf('%PDF small'));
        Id text = attach(sale.Id, 'Notes', 'notes.txt', Blob.valueOf('plain text'));
        Id elsewhere = attach(other.Id, 'Their loss runs', 'theirs.pdf', Blob.valueOf('%PDF small'));
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(document('loss_run', new List<String>{ answer('priorClaims', '4plus', 1, 'Claims 4', 'worked_out') }, NO_EXTRAS).replace('"unreadable":""', '"unreadable":"None."')));

        Test.startTest();
        AntsuranceSubmissionIntake.Reading reading = AntsuranceSubmissionIntake.readRecordFile(sale.Id, onSale);
        Test.stopTest();

        Assert.areEqual('Loss runs', reading.name);
        Assert.areEqual('4plus', reading.answers[0].value);
        Assert.isNull(reading.unreadable, '"None." means it could all be read');
        Assert.areEqual(AntsuranceSubmissionIntake.NOT_ON_RECORD, failureOf('file', sale.Id, elsewhere, null, null));
        Assert.areEqual(AntsuranceSubmissionIntake.WRONG_KIND, failureOf('file', sale.Id, text, null, null));
    }

    @IsTest
    static void theSampleSubmissionIsReadWithoutAnUpload() {
        Opportunity sale = newSale(AntsuranceSubmissionIntake.SAMPLE_CUSTOMER, AntsuranceSubmissionIntake.SAMPLE_LINE);
        if ([SELECT COUNT() FROM StaticResource WHERE Name = 'antsuranceSubmissionApplication'] == 0) {
            Assert.areEqual(AntsuranceSubmissionIntake.NO_SAMPLE, failureOf('sample', sale.Id, 'antsuranceSubmissionApplication', null, null));
            return;
        }
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(document('application', new List<String>{ answer('plan', 'guaranteed', 2, 'Guaranteed cost', 'read') }, NO_EXTRAS)));
        Test.startTest();
        AntsuranceSubmissionIntake.Reading reading = AntsuranceSubmissionIntake.readSample(sale.Id, 'antsuranceSubmissionApplication');
        Test.stopTest();
        Assert.areEqual('Application', reading.name);
        Assert.areEqual('guaranteed', reading.answers[0].value);
    }

    @IsTest
    static void documentsThatDisagreeAreShownSideBySideAndNeverChosenBetween() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        AntsuranceSubmissionIntake.Assembly assembly = AntsuranceSubmissionIntake.assemble(sale.Id, twoReadings(), null);

        AntsuranceSubmissionIntake.Row payroll = rowFor(assembly, 'payroll');
        Assert.areEqual('read', payroll.status, 'Two documents that agree settle the answer');
        Assert.areEqual('$1,530,000', payroll.valueLabel);
        Assert.areEqual(2, payroll.sources.size(), 'Both sources are kept');
        Assert.areEqual('worked_out', rowFor(assembly, 'classGroup').status);
        Assert.areEqual('Yes', rowFor(assembly, 'ownersIncluded').valueLabel);

        AntsuranceSubmissionIntake.Row claims = rowFor(assembly, 'priorClaims');
        Assert.areEqual('conflict', claims.status);
        Assert.isNull(claims.value, 'No figure is chosen while the documents disagree');
        Assert.areEqual('Application', payroll.sources[0].document, 'The application is shown first for what it states');
        Assert.areEqual('One to three', claims.sources[0].valueLabel);
        Assert.areEqual('Four or more', claims.sources[1].valueLabel);
        Assert.areEqual('not_found', rowFor(assembly, 'drugFree').status);
        Assert.isNull(rowFor(assembly, 'deductible'), 'A question the plan does not ask is left out');
        Assert.areEqual(1, assembly.conflicts);
        Assert.areEqual(4, assembly.settled, 'Payroll, kind of work, owners and the plan, and nothing else');

        Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped(assembly.answersJson);
        Assert.areEqual(1530000, (Decimal) answers.get('payroll'), 'An amount is handed over as a number');
        Assert.areEqual('true', answers.get('ownersIncluded'));
        Assert.isFalse(answers.containsKey('priorClaims'), 'A disputed answer is not handed over');

        Assert.isTrue(assembly.referrals.isEmpty(), 'Nothing refers on the settled answers');
        Assert.areEqual(1, assembly.conditionals.size(), 'Only the figure that would refer the quote is called out');
        Assert.areEqual('Loss run', assembly.conditionals[0].document);
        Assert.areEqual('Four or more claims in three years', assembly.conditionals[0].reasons[0]);
    }

    @IsTest
    static void thePersonSettlesWhatTheDocumentsCouldNot() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        AntsuranceSubmissionIntake.Assembly assembly = AntsuranceSubmissionIntake.assemble(
            sale.Id,
            twoReadings(),
            '{"priorClaims":"4plus","drugFree":"false","payroll":"1600000","state":"Ohio","plan":"deductible"}'
        );

        Assert.areEqual('changed', rowFor(assembly, 'priorClaims').status);
        Assert.areEqual('Four or more', rowFor(assembly, 'priorClaims').valueLabel);
        Assert.areEqual('No', rowFor(assembly, 'drugFree').valueLabel);
        Assert.areEqual('$1,600,000', rowFor(assembly, 'payroll').valueLabel, 'A correction replaces what the documents said');
        Assert.areEqual('not_found', rowFor(assembly, 'state').status, 'A value the question cannot take is ignored');
        Assert.isNotNull(rowFor(assembly, 'deductible'), 'A deductible plan asks for its deductible');
        Assert.areEqual(0, assembly.conflicts);
        Assert.isTrue(assembly.referrals.contains('Four or more claims in three years'), 'The chosen answer now refers the quote');
        Assert.isTrue(assembly.conditionals.isEmpty());
        Assert.areEqual(AntsuranceSubmissionIntake.NOTHING_READ, failureOf('assemble', sale.Id, '[]', null, null));
        Assert.areEqual(AntsuranceSubmissionIntake.NOTHING_READ, failureOf('assemble', sale.Id, null, null, null));
    }

    @IsTest
    static void claudeListsWhatIsMissingAndDraftsTheReply() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        ClaudeMock mock = new ClaudeMock(
            '{"headline":"A workers compensation submission that is close to quotable.","issues":[' +
                '{"kind":"inconsistent","title":"Claim count","detail":"The application says 3 and the loss run lists 4.","ask":"Confirm the number of claims."},' +
                '{"kind":"something_else","title":"Drug-free workplace","detail":"Not answered.","ask":""},' +
                '{"kind":"missing","title":"","detail":"No title, so dropped.","ask":""}],' +
                '"replySubject":"Lakeshore Dental Group: two things before we quote","replyBody":"Hi Marguerite,\\n\\nThank you for the submission."}'
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceSubmissionIntake.Advice advice = AntsuranceSubmissionIntake.advise(sale.Id, twoReadings(), null);
        Test.stopTest();

        Assert.areEqual('A workers compensation submission that is close to quotable.', advice.headline);
        Assert.areEqual(2, advice.issues.size(), 'An issue with no title is dropped');
        Assert.areEqual('inconsistent', advice.issues[0].kind);
        Assert.areEqual('missing', advice.issues[1].kind, 'An unknown kind falls back to missing');
        Assert.isTrue(advice.replyBody.startsWith('Hi Marguerite,'));
        Assert.isTrue(advice.replyBody.contains('\n'), 'Line breaks in the reply are kept');

        String sent = mock.requests[0].getBody();
        Assert.isTrue(sent.contains('THE DOCUMENTS DISAGREE'), 'Claude is told where the documents disagree');
        Assert.isTrue(sent.contains('Loss run says Four or more'), 'With each document\'s own figure');
        Assert.isTrue(sent.contains('NOT IN ANY DOCUMENT'), 'And what none of them answers');
        Assert.isTrue(sent.contains('If Loss run is right about Claims, past 3 years (Four or more): Four or more claims in three years.'), 'And what each figure would do');
        Assert.isTrue(sent.contains('Employees: 22'), 'And what Antsurance already holds');
        Assert.isTrue(sent.contains(UserInfo.getName()), 'The reply is signed by the person, not by Claude');
        Assert.isFalse(sent.contains('"type":"document"'), 'No file is sent again');
    }

    @IsTest
    static void aStepThatTimesOutSaysSoAndCanBeTriedAgain() {
        Opportunity sale = newSale('Lakeshore Dental Group', 'Workers Compensation');
        ClaudeMock mock = new ClaudeMock(document('application', new List<String>{ answer('plan', 'guaranteed', 2, 'Guaranteed cost', 'read') }, NO_EXTRAS));
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, failureOf('upload', sale.Id, 'application.pdf', 'application/pdf', PDF), 'A slow document says so in plain words');
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, failureOf('advise', sale.Id, twoReadings(), null, null), 'So does a slow review');

        // Nothing was lost: the same request works once Claude answers.
        mock.timesOut = false;
        AntsuranceSubmissionIntake.Reading reading = AntsuranceSubmissionIntake.readUpload(sale.Id, 'application.pdf', 'application/pdf', PDF);
        Assert.areEqual('guaranteed', reading.answers[0].value);
        Test.stopTest();
        Assert.areEqual(1, AntsuranceSubmissionIntake.assemble(sale.Id, JSON.serialize(new List<AntsuranceSubmissionIntake.Reading>{ reading }), null).settled);
    }
}
