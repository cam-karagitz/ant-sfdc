@IsTest
private class AntsuranceClaimLettersTest {
    /** Answers with one canned response, or fails the way a slow call does, and keeps the request. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status;
        String body;
        Boolean timesOut = false;
        HttpRequest request;

        ClaudeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            if (timesOut) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void createClaims() {
        Account household = new Account(Name = 'Harbor Household', BillingStreet = '12 Quay St', BillingCity = 'Evanston', BillingPostalCode = '60201');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        insert household;
        Contact person = new Contact(AccountId = household.Id, FirstName = 'Maya', LastName = 'Harbor');
        insert person;
        Date start = Date.today().addDays(-90);
        Policy__c policy = new Policy__c(
            Name = 'T-HOME-1', Account__c = household.Id, Primary_Insured__c = person.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Deductible__c = 2500, Coverage_Limit__c = 620000
        );
        insert policy;

        AntsuranceClaimsAssistantCoverage.Check check = new AntsuranceClaimsAssistantCoverage.Check();
        check.exists = true;
        check.verdict = AntsuranceClaimsAssistantCoverage.NEEDS_REVIEW;
        check.summary = 'Dwelling would cover a burst supply line, but silt in the photo raises doubt about the water source.';
        check.respondingLabel = 'Dwelling';
        check.deductible = 2500;
        check.limitAmount = 620000;
        check.questions = new List<String>{ 'Where did the water come from, and how high did it rise', 'Was there rain that weekend?' };
        Map<String, Object> analysis = new Map<String, Object>{
            'report' => new Map<String, Object>{
                'gaps' => new List<Object>{
                    new Map<String, Object>{ 'kind' => 'evidence_needed', 'text' => 'A plumber\'s report on the failed fitting.' },
                    new Map<String, Object>{ 'kind' => 'check', 'text' => 'The photo shows silt.' }
                }
            }
        };

        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Id serviceType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId();
        List<Case> cases = new List<Case>{
            new Case(
                RecordTypeId = claimType, Subject = 'Burst pipe flooded basement', Policy__c = policy.Id, AccountId = household.Id, ContactId = person.Id,
                Status = 'Under Investigation', Handled_By__c = 'Marcus Lindahl', Date_of_Loss__c = Date.newInstance(2026, 9, 21),
                Reported_Date__c = Date.newInstance(2026, 9, 22), Estimated_Loss__c = 48921, Reserve_Amount__c = 45000, Paid_Amount__c = 5000,
                Coverage_Read__c = JSON.serialize(new Map<String, Object>{ 'check' => check, 'facts' => new Map<String, Object>() }),
                Claude_Analysis__c = JSON.serialize(analysis)
            ),
            new Case(
                RecordTypeId = claimType, Subject = 'Rear-ended at a red light', Policy__c = policy.Id, AccountId = household.Id, ContactId = person.Id, Status = 'New',
                Handled_By__c = 'Dana Whitaker, Senior Claims Adjuster', Date_of_Loss__c = Date.newInstance(2026, 9, 30), Estimated_Loss__c = 6800,
                Subrogation_Potential__c = true
            ),
            new Case(RecordTypeId = serviceType, Subject = 'Add a driver', Policy__c = policy.Id, AccountId = household.Id, ContactId = person.Id, Status = 'New')
        };
        insert cases;
        insert new File_Note__c(
            Case__c = cases[0].Id, Note_Type__c = 'Reserve', Note_Date__c = Datetime.now().addDays(-3), Author_Name__c = 'Marcus Lindahl, Property Adjuster',
            Body__c = 'Reserve set at $45,000.'
        );
    }

    private static Id caseId(String subject) {
        return [SELECT Id FROM Case WHERE Subject = :subject].Id;
    }

    private static String reply(List<String> paragraphs, List<String> gaps) {
        Map<String, Object> answer = new Map<String, Object>{
            'salutation' => 'Dear Maya Harbor,',
            'paragraphs' => paragraphs,
            'gaps' => gaps,
            'basis' => new List<Object>{ 'The coverage check, which needs review.', 'The $5,000 advance paid Sep 28.' }
        };
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    private static List<String> kinds(AntsuranceClaimLetters.Desk desk) {
        List<String> kinds = new List<String>();
        for (AntsuranceClaimLetters.Option option : desk.options) {
            kinds.add(option.kind);
        }
        return kinds;
    }

    private static String failure(String what, Id caseId, String argument) {
        try {
            if (what == 'draft') {
                AntsuranceClaimLetters.draft(caseId, argument);
            } else if (what == 'approve') {
                AntsuranceClaimLetters.approve(caseId, argument);
            } else if (what == 'letters') {
                AntsuranceClaimLetters.getLetters(caseId);
            } else if (what == 'revise') {
                AntsuranceClaimLetters.revise(caseId, argument, ' ');
            }
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void offersOnlyTheLettersTheClaimSupports() {
        AntsuranceClaimLetters.Desk pipe = AntsuranceClaimLetters.getLetters(caseId('Burst pipe flooded basement'));
        Assert.areEqual(
            new List<String>{ AntsuranceClaimLetters.ACKNOWLEDGMENT, AntsuranceClaimLetters.RESERVATION, AntsuranceClaimLetters.INFORMATION, AntsuranceClaimLetters.PAYMENT },
            kinds(pipe),
            'A claim under review with questions open and a payment made, and no recovery marked'
        );
        Assert.areEqual('To Maya Harbor', pipe.options[1].toWhom, 'A coverage letter goes to the insured');
        Assert.isTrue(pipe.options[1].why.startsWith('The coverage check needs review. Still open: Where did the water come from'), pipe.options[1].why);
        Assert.isTrue(
            pipe.options[2].why.startsWith('3 things are still to ask: 2 from the coverage check and 1 the analysis found missing. First: '),
            'Questions come from the check and from what the analysis says is missing, and the line says how many of each: ' + pipe.options[2].why
        );
        Assert.isTrue(pipe.options[3].why.startsWith('$5,000 has been paid.'), pipe.options[3].why);
        Assert.isNull(pipe.notNow, 'Nothing to explain when the check exists and is not a denial');
        Assert.isTrue(pipe.onFile.isEmpty(), 'No letter is on file yet');

        AntsuranceClaimLetters.Desk rearEnd = AntsuranceClaimLetters.getLetters(caseId('Rear-ended at a red light'));
        Assert.areEqual(new List<String>{ AntsuranceClaimLetters.ACKNOWLEDGMENT, AntsuranceClaimLetters.NOTICE }, kinds(rearEnd), 'A new claim marked for recovery, with no check');
        Assert.areEqual('To the other party\'s carrier', rearEnd.options[1].toWhom, 'The notice goes to the other carrier');
        Assert.isTrue(rearEnd.notNow.contains('needs the coverage check first'), 'And the card says why no coverage letter is offered');

        Assert.areEqual(AntsuranceClaimLetters.NOT_A_CLAIM, failure('letters', caseId('Add a driver'), null), 'A service request has no letters');
        Assert.areEqual(AntsuranceClaimLetters.NOT_OFFERED, failure('draft', caseId('Rear-ended at a red light'), AntsuranceClaimLetters.PAYMENT), 'A letter the claim does not support is refused');
    }

    @IsTest
    static void theRecordSetsTheFrameAndClaudeWritesTheBody() {
        ClaudeMock mock = new ClaudeMock(
            200,
            reply(new List<String>{ 'We are **looking into** your claim — and have not decided.', '  ', 'Antsurance reserves its rights under the policy.' }, new List<String>())
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimLetters.Letter letter = AntsuranceClaimLetters.draft(caseId('Burst pipe flooded basement'), AntsuranceClaimLetters.RESERVATION);
        Test.stopTest();

        Assert.areEqual('Reservation of rights', letter.title, 'The letter is named');
        Assert.areEqual(new List<String>{ 'Maya Harbor', '12 Quay St', 'Evanston, IL 60201' }, letter.addressee, 'Addressed from the record');
        Assert.areEqual(3, letter.reference.size(), 'Claim, policy and date of loss');
        Assert.isTrue(letter.reference[0].startsWith('Re: Claim '), letter.reference[0]);
        Assert.areEqual('Policy number: T-HOME-1', letter.reference[1], 'The policy by its number');
        Assert.areEqual('Date of loss: September 21, 2026', letter.reference[2], 'The date spelled out');
        Assert.areEqual(new List<String>{ 'Marcus Lindahl', 'Property Adjuster', 'Antsurance Insurance Company' }, letter.signer, 'Signed by the handler, with the title the file gives');
        Assert.areEqual('Dear Maya Harbor,', letter.salutation, 'Claude writes the salutation');
        Assert.areEqual('We are looking into your claim, and have not decided.\n\nAntsurance reserves its rights under the policy.', letter.body, 'And the body, with marks and dashes taken out');
        Assert.areEqual(2, letter.basis.size(), 'What the draft rests on comes back for the adjuster');

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('A reservation of rights, to the insured.'), 'Claude is told which letter to write');
        Assert.isTrue(sent.contains('Payable on that estimate, after the deductible: $46,421.'), 'With the payable amount worked out for it');
        Assert.isTrue(sent.contains('Paid so far: $5,000.') && sent.contains('Remaining of what is payable: $41,421.'), 'And what is paid and what remains');
        Assert.isTrue(sent.contains('Verdict: Needs review.'), 'And the coverage check');
        Assert.isTrue(sent.contains('A plumber\'s report on the failed fitting.'), 'And what is still to ask');
        Assert.isTrue(sent.contains('A letter never says coverage is denied.'), 'Under the standing rules');
    }

    @IsTest
    static void aNoticeLeavesGapsAndCannotBeApprovedUntilTheyAreFilled() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply(new List<String>{ 'Our insured was struck by [other driver\'s name].' }, new List<String>{ 'other driver\'s name' })));
        Id rearEnd = caseId('Rear-ended at a red light');

        Test.startTest();
        AntsuranceClaimLetters.Letter letter = AntsuranceClaimLetters.draft(rearEnd, AntsuranceClaimLetters.NOTICE);
        Test.stopTest();

        Assert.areEqual('[other party\'s insurance carrier]', letter.addressee[0], 'The record does not name the other carrier, so the address is a gap');
        Assert.isTrue(letter.reference.contains('Your claim number: [other carrier\'s claim number]'), 'So is their claim number');
        Assert.areEqual(new List<String>{ 'Dana Whitaker', 'Senior Claims Adjuster', 'Antsurance Insurance Company' }, letter.signer, 'A title on the claim itself is used');

        AntsuranceClaimLetters.Sheet sheet = AntsuranceClaimLetters.layout(JSON.serialize(letter));
        Assert.areEqual(
            new List<String>{ 'other party\'s insurance carrier', 'carrier\'s mailing address', 'other driver\'s name', 'other carrier\'s claim number' },
            sheet.gaps,
            'Every gap is listed once, in the order it appears'
        );
        Assert.areEqual(AntsuranceClaimLetters.HAS_GAPS, failure('approve', rearEnd, JSON.serialize(letter)), 'A letter with a gap is not approved');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :rearEnd], 'And nothing is saved');
    }

    @IsTest
    static void theSheetBreaksLinesTheWayThePagePrints() {
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.title = 'Reservation of rights';
        letter.addressee = new List<String>{ 'Maya Harbor', ' ', '12 Quay St' };
        letter.dateLine = 'October 5, 2026';
        letter.reference = new List<String>{ 'Re: Claim 00001' };
        letter.salutation = 'Dear Maya Harbor,';
        letter.body = 'We have received the invoice from the drying vendor and the estimate from the builder, and both are with your adjuster for review this week.\n\n\nShort one.';
        letter.signer = new List<String>{ 'Marcus Lindahl', 'Property Adjuster' };

        AntsuranceClaimLetters.Sheet sheet = AntsuranceClaimLetters.layout(JSON.serialize(letter));
        Assert.areEqual(new List<String>{ 'Maya Harbor', '12 Quay St' }, sheet.addressee, 'Blank lines are dropped');
        Assert.areEqual(2, sheet.paragraphs.size(), 'A blank line, or several, separates paragraphs');
        Assert.areEqual(2, sheet.paragraphs[0].lines.size(), 'A paragraph longer than a line is broken');
        for (String line : sheet.paragraphs[0].lines) {
            Assert.isTrue(line.length() <= 98, 'No line is wider than the page: ' + line);
        }
        Assert.areEqual('Sincerely,', sheet.closing, 'A letter with no closing gets the usual one');
        Assert.areEqual(1, sheet.pages, 'A short letter is one page');
        Assert.isTrue(sheet.gaps.isEmpty(), 'With no gaps');

        // A last line of one word is pulled up by setting the paragraph a little narrower.
        String text = 'aaaa '.repeat(18).trim() + ' end';
        List<String> lines = AntsuranceClaimLetters.fit(text, 88);
        Assert.areEqual(2, lines.size(), 'It still takes two lines');
        Assert.isTrue(lines[1].length() >= 28, 'And the second is not a word on its own: ' + lines[1]);

        letter.body = ('This sentence is repeated to fill the page and a little more. '.repeat(12).trim() + '\n\n').repeat(5);
        Assert.areEqual(2, AntsuranceClaimLetters.layout(JSON.serialize(letter)).pages, 'A long letter says it runs to a second page');
    }

    @IsTest
    static void approvingWritesTheNoteAndThenThePdf() {
        Id pipe = caseId('Burst pipe flooded basement');
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.ACKNOWLEDGMENT;
        letter.addressee = new List<String>{ 'Maya Harbor', '12 Quay St', 'Evanston, IL 60201' };
        letter.dateLine = 'October 5, 2026';
        letter.reference = new List<String>{ 'Re: Claim 00001, Burst pipe flooded basement', 'Policy number: T-HOME-1' };
        letter.salutation = 'Dear Maya Harbor,';
        letter.body = 'We have received your claim.\n\nMarcus Lindahl is handling it.';
        letter.closing = 'Sincerely,';
        letter.signer = new List<String>{ 'Marcus Lindahl', 'Property Adjuster', 'Antsurance Insurance Company' };

        Test.startTest();
        Id noteId = AntsuranceClaimLetters.approve(pipe, JSON.serialize(letter));
        AntsuranceClaimLetters.Saved saved = AntsuranceClaimLetters.savePdf(noteId);
        AntsuranceClaimLetters.Saved again = AntsuranceClaimLetters.savePdf(noteId);
        Test.stopTest();

        File_Note__c note = [SELECT Body__c, Note_Type__c, Author_Name__c, Policy__c, Account__c FROM File_Note__c WHERE Id = :noteId];
        Assert.isTrue(AntsuranceClaimLetters.isLetterNote(note), 'The note is marked as a letter');
        Assert.isFalse(AntsuranceClaimRules.isClaudeNote(note), 'It is the work of the person who approved it, not Claude\'s opinion');
        Assert.areEqual('Contact', note.Note_Type__c, 'An acknowledgment is contact with the insured');
        Assert.isNotNull(note.Policy__c, 'The note also belongs to the policy');
        Assert.isTrue(note.Body__c.startsWith('**Letter approved:** Acknowledgment of claim, to Maya Harbor. Claude drafted it. ' + UserInfo.getName() + ' read, edited and approved it on '), note.Body__c);
        Assert.isTrue(note.Body__c.contains('Nothing is sent from this system.'), 'It says nothing was sent');

        AntsuranceClaimLetters.Letter back = AntsuranceClaimLetters.parse(note.Body__c);
        Assert.areEqual(letter.addressee, back.addressee, 'The note carries the address');
        Assert.areEqual(letter.reference, back.reference, 'The reference lines');
        Assert.areEqual(letter.salutation, back.salutation, 'The salutation');
        Assert.areEqual(letter.body, back.body, 'The body, paragraph for paragraph');
        Assert.areEqual(letter.signer, back.signer, 'And the signature');
        Assert.areEqual(AntsuranceClaimLetters.ACKNOWLEDGMENT, back.kind, 'And which letter it is');

        ContentVersion file = [SELECT Title, Description, FileExtension, ContentDocumentId FROM ContentVersion WHERE ContentDocumentId = :saved.documentId];
        Assert.isTrue(file.Title.startsWith('Acknowledgment of claim, '), 'The file has a title a person would give it: ' + file.Title);
        Assert.areEqual('pdf', file.FileExtension, 'It is a PDF');
        Assert.areEqual(AntsuranceClaimLetters.FILE_MARK + noteId, file.Description, 'And it names the note it was made from');
        Assert.areEqual(saved.documentId, again.documentId, 'Saving again gives the same file back');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pipe], 'One file, on the claim');

        AntsuranceClaimLetters.Desk desk = AntsuranceClaimLetters.getLetters(pipe);
        Assert.areEqual(1, desk.onFile.size(), 'The letter is listed as on file');
        Assert.areEqual(saved.documentId, desk.onFile[0].documentId, 'With its PDF');
        Assert.areEqual('To Maya Harbor', desk.onFile[0].toWhom, 'And who it went to');
        Assert.areEqual(UserInfo.getName(), desk.onFile[0].approvedBy, 'And who approved it');
        Assert.isFalse(kinds(desk).contains(AntsuranceClaimLetters.ACKNOWLEDGMENT), 'An acknowledgment is offered once');
    }

    @IsTest
    static void thePagePrintsTheApprovedLetter() {
        Id pipe = caseId('Burst pipe flooded basement');
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.PAYMENT;
        letter.addressee = new List<String>{ 'Maya Harbor' };
        letter.reference = new List<String>{ 'Re: Claim 00001' };
        letter.salutation = 'Dear Maya Harbor,';
        letter.body = 'First.\n\nSecond.\n\nThird.';
        letter.signer = new List<String>{ 'Marcus Lindahl' };
        Id noteId = AntsuranceClaimLetters.approve(pipe, JSON.serialize(letter));

        Test.setCurrentPage(Page.AntsuranceClaimLetter);
        ApexPages.currentPage().getParameters().put('id', noteId);
        AntsuranceClaimLetterController page = new AntsuranceClaimLetterController();
        Assert.isTrue(page.found, 'The letter is found from its note');
        Assert.areEqual(new List<String>{ 'Maya Harbor' }, page.addressee, 'With its address');
        Assert.areEqual(2, page.opening.size(), 'All but the last paragraph print in order');
        Assert.areEqual('Third.', page.ending[0].lines[0], 'The last paragraph stays with the signature');
        Assert.areEqual('Sincerely,', page.closing, 'Closed the usual way');
        Assert.isTrue(page.documentLabel.startsWith('Payment explanation, claim '), page.documentLabel);

        ApexPages.currentPage().getParameters().put('id', [SELECT Id FROM File_Note__c WHERE Note_Type__c = 'Reserve' LIMIT 1].Id);
        Assert.isFalse(new AntsuranceClaimLetterController().found, 'A note that is not a letter prints the notice');
        ApexPages.currentPage().getParameters().put('id', 'nonsense');
        Assert.isFalse(new AntsuranceClaimLetterController().found, 'So does a bad id');

        try {
            AntsuranceClaimLetters.savePdf([SELECT Id FROM File_Note__c WHERE Note_Type__c = 'Reserve' LIMIT 1].Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimLetters.NOT_A_LETTER, e.getMessage(), 'And no PDF is made from it');
        }
    }

    /** Approves a letter and reads it back from its file note, checking that the page it prints is the page that was previewed. */
    private static AntsuranceClaimLetters.Letter approveAndReadBack(Id caseId, AntsuranceClaimLetters.Letter letter) {
        String previewed = JSON.serialize(AntsuranceClaimLetters.layout(JSON.serialize(letter)));
        Id noteId = AntsuranceClaimLetters.approve(caseId, JSON.serialize(letter));
        AntsuranceClaimLetters.Letter back = AntsuranceClaimLetters.parse([SELECT Body__c FROM File_Note__c WHERE Id = :noteId].Body__c);
        Assert.areEqual(previewed, JSON.serialize(AntsuranceClaimLetters.sheetOf(back)), 'The page prints exactly the sheet the adjuster approved');
        return back;
    }

    @IsTest
    static void aLetterWithItsReferenceClearedAndOneParagraphPrintsAsApproved() {
        Id pipe = caseId('Burst pipe flooded basement');
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.RESERVATION;
        letter.addressee = new List<String>{ 'Maya Harbor', '12 Quay St', 'Evanston, IL 60201' };
        letter.dateLine = 'October 5, 2026';
        // The adjuster deleted the reference lines in the editor, which leaves blank lines behind.
        letter.reference = new List<String>{ '', '  ' };
        letter.salutation = 'Dear Maya Harbor,';
        letter.body = 'Antsurance reserves its rights under the policy.';
        letter.signer = new List<String>{ 'Marcus Lindahl', 'Property Adjuster', 'Antsurance Insurance Company' };

        Test.startTest();
        AntsuranceClaimLetters.Letter back = approveAndReadBack(pipe, letter);
        Test.stopTest();

        Assert.areEqual(letter.addressee, back.addressee, 'The address is still the address');
        Assert.areEqual('October 5, 2026', back.dateLine, 'The date is still the date');
        Assert.isTrue(back.reference.isEmpty(), 'There are no reference lines, and nothing else is taken for them');
        Assert.areEqual('Dear Maya Harbor,', back.salutation, 'The salutation is not printed as a reference line');
        Assert.areEqual('Antsurance reserves its rights under the policy.', back.body, 'The one paragraph is the body, and not the greeting');
        Assert.areEqual('Sincerely,', back.closing, 'Closed the usual way');
        Assert.areEqual(letter.signer, back.signer, 'And signed as it was');
        Assert.areEqual(AntsuranceClaimLetters.RESERVATION, back.kind, 'It is still the letter it was');

        Test.setCurrentPage(Page.AntsuranceClaimLetter);
        ApexPages.currentPage().getParameters().put('id', [SELECT Id FROM File_Note__c WHERE Case__c = :pipe AND Note_Type__c = 'Coverage'].Id);
        AntsuranceClaimLetterController page = new AntsuranceClaimLetterController();
        Assert.isTrue(page.found, 'The PDF finds the letter');
        Assert.areEqual(letter.addressee, page.addressee, 'With its addressee');
        Assert.isFalse(page.hasReference, 'No reference block');
        Assert.areEqual('Dear Maya Harbor,', page.salutation, 'The greeting where the greeting goes');
        Assert.isTrue(page.opening.isEmpty(), 'No paragraph before the last');
        Assert.areEqual('Antsurance reserves its rights under the policy.', page.ending[0].lines[0], 'And the one paragraph above the signature');
    }

    @IsTest
    static void aLetterPrintsAsApprovedWhateverIsLeftEmpty() {
        Id pipe = caseId('Burst pipe flooded basement');
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.INFORMATION;
        letter.addressee = new List<String>{ 'Maya Harbor' };
        letter.dateLine = 'October 5, 2026';
        // No reference lines, a salutation cleared to spaces, nobody signing, and paragraphs that open the way the note marks its parts.
        letter.salutation = '  ';
        letter.body = '**Reference:** is how this paragraph happens to open.\n\n**Signed:** and so does this one.\n\n**Closing:** and this.';

        Test.startTest();
        AntsuranceClaimLetters.Letter back = approveAndReadBack(pipe, letter);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'Maya Harbor' }, back.addressee, 'The address');
        Assert.isTrue(back.reference.isEmpty(), 'No reference lines: the paragraph that opens like them is a paragraph');
        Assert.isNull(back.salutation, 'A salutation the adjuster cleared stays cleared');
        Assert.areEqual(letter.body, back.body, 'Every paragraph is read back as a paragraph, word for word');
        Assert.areEqual('Sincerely,', back.closing, 'The closing is the closing');
        Assert.isTrue(back.signer.isEmpty(), 'And nobody is made to sign');
    }

    @IsTest
    static void aLetterSavedBeforeItsPartsWereMarkedStillReads() {
        String saved = String.join(
            new List<String>{
                AntsuranceClaimLetters.NOTE_OPENING + ' Payment explanation, to Maya Harbor. Drafted by Claude, then read, edited and approved by Dana Whitaker on Oct 5, 2026.',
                '---',
                'Maya Harbor\n12 Quay St',
                'October 5, 2026',
                'Re: Claim 00001',
                'Dear Maya Harbor,',
                'First.',
                'Second.',
                'Sincerely,\nMarcus Lindahl\nProperty Adjuster'
            },
            '\n\n'
        );

        AntsuranceClaimLetters.Letter back = AntsuranceClaimLetters.parse(saved);

        Assert.areEqual(AntsuranceClaimLetters.PAYMENT, back.kind, 'Which letter it is');
        Assert.areEqual(new List<String>{ 'Maya Harbor', '12 Quay St' }, back.addressee, 'The address, by where it stands');
        Assert.areEqual('October 5, 2026', back.dateLine, 'The date');
        Assert.areEqual(new List<String>{ 'Re: Claim 00001' }, back.reference, 'The reference line');
        Assert.areEqual('Dear Maya Harbor,', back.salutation, 'The salutation');
        Assert.areEqual('First.\n\nSecond.', back.body, 'The body');
        Assert.areEqual('Sincerely,', back.closing, 'The closing');
        Assert.areEqual(new List<String>{ 'Marcus Lindahl', 'Property Adjuster' }, back.signer, 'And the signature');
    }

    @IsTest
    static void aChangeAskedForInWordsKeepsTheRestOfTheLetter() {
        ClaudeMock mock = new ClaudeMock(200, reply(new List<String>{ 'Shorter now.' }, new List<String>()));
        Test.setMock(HttpCalloutMock.class, mock);
        Id pipe = caseId('Burst pipe flooded basement');
        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.RESERVATION;
        letter.addressee = new List<String>{ 'Maya Harbor', 'care of her sister' };
        letter.reference = new List<String>{ 'Re: Claim 00001' };
        letter.salutation = 'Dear Maya,';
        letter.body = 'A long paragraph the adjuster wrote.';
        letter.signer = new List<String>{ 'Marcus Lindahl' };

        Test.startTest();
        AntsuranceClaimLetters.Letter revised = AntsuranceClaimLetters.revise(pipe, JSON.serialize(letter), 'Make it shorter');
        Test.stopTest();

        Assert.areEqual('Shorter now.', revised.body, 'Claude returns the changed body');
        Assert.areEqual(new List<String>{ 'Maya Harbor', 'care of her sister' }, revised.addressee, 'The adjuster\'s address stands');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('THE ADJUSTER ASKS') && sent.contains('Make it shorter'), 'The request is passed on in the adjuster\'s words');
        Assert.isTrue(sent.contains('A long paragraph the adjuster wrote.'), 'With the letter as it stands');
        Assert.areEqual(AntsuranceClaimLetters.NO_REQUEST, failure('revise', pipe, JSON.serialize(letter)), 'An empty request is refused before Claude is asked');
    }

    @IsTest
    static void aSlowAnswerIsSaidInPlainWordsAndAnEmptyLetterIsRefused() {
        ClaudeMock mock = new ClaudeMock(200, '');
        mock.timesOut = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Id pipe = caseId('Burst pipe flooded basement');

        Test.startTest();
        String message = failure('draft', pipe, AntsuranceClaimLetters.RESERVATION);
        Test.stopTest();
        Assert.areEqual(AntsuranceAiClient.TOO_SLOW, message, 'A timeout reaches the adjuster in plain words, and the draft can be asked for again');

        AntsuranceClaimLetters.Letter letter = new AntsuranceClaimLetters.Letter();
        letter.kind = AntsuranceClaimLetters.PAYMENT;
        Assert.areEqual(AntsuranceClaimLetters.NO_ADDRESSEE, failure('approve', pipe, JSON.serialize(letter)), 'A letter to nobody is refused');
        letter.addressee = new List<String>{ 'Maya Harbor' };
        Assert.areEqual(AntsuranceClaimLetters.NO_BODY, failure('approve', pipe, JSON.serialize(letter)), 'So is one with no text');
        letter.body = 'x'.repeat(6001);
        Assert.areEqual(AntsuranceClaimLetters.TOO_LONG, failure('approve', pipe, JSON.serialize(letter)), 'And one too long for two pages');
        Assert.areEqual(AntsuranceClaimLetters.NO_BODY, failure('approve', pipe, 'not json'), 'Or one that cannot be read');
        letter.body = 'Fine.';
        Assert.areEqual(AntsuranceClaimLetters.NOT_A_CLAIM, failure('approve', caseId('Add a driver'), JSON.serialize(letter)), 'A service request takes no letter');
    }

    @IsTest
    static void aLetterIsDraftedFromTheNotesWrittenInSalesforceNotesToo() {
        Id claimId = caseId('Burst pipe flooded basement');
        // A stand-in for the note, so this runs the same where the org has Notes turned off.
        AntsuranceSalesforceNotes.standIn(claimId, 'Body shop call', 'The shop found a cracked fitting behind the wall.', Datetime.now());
        ClaudeMock mock = new ClaudeMock(200, reply(new List<String>{ 'We are looking into your claim.' }, new List<String>()));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimLetters.Letter letter = AntsuranceClaimLetters.draft(claimId, AntsuranceClaimLetters.RESERVATION);
        Test.stopTest();

        Assert.areEqual('We are looking into your claim.', letter.body, 'The letter is drafted');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('Reserve set at $45,000.'), 'The draft is written from the file notes, as before');
        Assert.isTrue(sent.contains('Salesforce note, ' + UserInfo.getName() + '] **Body shop call:**'), 'And from the note written in Salesforce Notes, under its own type and writer');
        Assert.isTrue(sent.contains('The shop found a cracked fitting behind the wall.'), 'With its words');
    }
}
