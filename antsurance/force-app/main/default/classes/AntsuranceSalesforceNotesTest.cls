/**
 * An org can have Salesforce Notes turned off, and then no ContentNote can be made. So every test here
 * but one works from a stand-in for the note (AntsuranceSalesforceNotes.standIn) and runs the same in
 * either kind of org. The one that saves a real note says what it expects where Notes is off, too.
 */
@IsTest
private class AntsuranceSalesforceNotesTest {
    @TestSetup
    static void createFile() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Date start = Date.today().addDays(-30);
        Policy__c policy = new Policy__c(Name = 'P-1', Account__c = customer.Id, Status__c = 'Active', Effective_Date__c = start, Expiration_Date__c = start.addYears(1));
        insert policy;
        insert new Case(
            Subject = 'Burst pipe', Policy__c = policy.Id, Status = 'Under Investigation',
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId()
        );
    }

    private static AntsuranceSalesforceNotes.Entry entry(String title, String body) {
        AntsuranceSalesforceNotes.Entry made = new AntsuranceSalesforceNotes.Entry();
        made.title = title;
        made.body = body;
        return made;
    }

    @IsTest
    static void aSalesforceNotesHtmlReadsAsMarkdown() {
        String markdown = AntsuranceSalesforceNotes.toMarkdown(
            '<p>Spoke with <b>Chinedu</b> &amp; his <i>plumber</i>.</p><ul><li>Line failed at the fitting</li><li>Water ran two days</li></ul>' +
            '<p>See <a href="https://example.com/report" target="_blank">the report</a>.<br>Call back Friday.</p>'
        );

        Assert.areEqual(
            'Spoke with **Chinedu** & his *plumber*.\n\n- Line failed at the fitting\n- Water ran two days\n\nSee [the report](https://example.com/report).\nCall back Friday.',
            markdown,
            'Paragraphs, bold, italic, a list, a link and a line break come through; the escaped ampersand reads as itself'
        );
        Assert.areEqual('**Findings**\n\nThe fitting failed.', AntsuranceSalesforceNotes.toMarkdown('<h2>Findings</h2><p>The fitting failed.</p><p><b></b></p>'), 'A heading reads as a bold line, and an empty tag leaves nothing behind');
        Assert.areEqual('', AntsuranceSalesforceNotes.toMarkdown(null), 'An empty note is empty');
    }

    @IsTest
    static void aNoteWrittenHereIsStoredAsTheHtmlSalesforceNotesKeeps() {
        String written = '# Plumber\'s report is in\n\nThe **supply line** failed at the *fitting* <behind the wall>.\n\n- Water ran two days\n1. No sign of outside water\n\nCall back Friday.';

        String html = AntsuranceSalesforceNotes.toHtml(written);

        Assert.areEqual(
            '<p>Plumber&#39;s report is in</p><p>The <b>supply line</b> failed at the <i>fitting</i> &lt;behind the wall&gt;.</p>' +
            '<ul><li>Water ran two days</li><li>No sign of outside water</li></ul><p>Call back Friday.</p>',
            html,
            'Paragraphs, a list, bold and italic are kept; a heading mark is dropped and everything else is escaped'
        );
        Assert.areEqual('<ul><li>Only a list</li></ul>', AntsuranceSalesforceNotes.toHtml('- Only a list'), 'A list that ends the note is closed');
        Assert.areEqual('', AntsuranceSalesforceNotes.toHtml(null), 'Nothing written is nothing stored');
        Assert.areEqual(
            'Plumber\'s report is in\n\nThe **supply line** failed at the *fitting* <behind the wall>.\n\n- Water ran two days\n- No sign of outside water\n\nCall back Friday.',
            AntsuranceSalesforceNotes.toMarkdown(html),
            'And it reads back as it was written, apostrophe and all'
        );
    }

    @IsTest
    static void aNotesTitleIsItsFirstLineInPlainWords() {
        Assert.areEqual('Plumber\'s report is in', AntsuranceSalesforceNotes.titleOf('\n**Plumber\'s report is in**\n\nThe supply line failed.'), 'The first line with words on it, without its marks');
        Assert.areEqual('Called the insured', AntsuranceSalesforceNotes.titleOf('- Called the insured\n- Left a voicemail'), 'A list item gives its words');
        String title = AntsuranceSalesforceNotes.titleOf('Spoke with the insured and the plumber about the failed supply line behind the upstairs bathroom wall today');
        Assert.areEqual('Spoke with the insured and the plumber about the failed supply line behind the...', title, 'A long line is cut at a whole word');
        Assert.areEqual('Note', AntsuranceSalesforceNotes.titleOf('   '), 'A note with no words still has a title');
        Assert.areEqual('Note', AntsuranceSalesforceNotes.titleOf(null), 'So does no note at all');
    }

    @IsTest
    static void aNotesTitleLeadsItsTextUnlessTheTextAlreadyOpensWithIt() {
        Assert.areEqual('**Adjuster call**\n\nLeft a voicemail.', AntsuranceSalesforceNotes.withTitle(entry('Adjuster call', ' Left a voicemail. ')), 'The title stands in bold above the text');
        Assert.areEqual('Adjuster call: left a voicemail.', AntsuranceSalesforceNotes.withTitle(entry('Adjuster call', 'Adjuster call: left a voicemail.')), 'A text that opens with the title does not get it twice');
        Assert.areEqual(
            'Spoke with the insured and the plumber about the supply line today.',
            AntsuranceSalesforceNotes.withTitle(entry('Spoke with the insured and the plumber...', 'Spoke with the insured and the plumber about the supply line today.')),
            'Nor one whose title is its own opening, cut short'
        );
        Assert.areEqual('**Adjuster call**', AntsuranceSalesforceNotes.withTitle(entry('Adjuster call', null)), 'A note with only a title is its title');
        Assert.areEqual('Left a voicemail.', AntsuranceSalesforceNotes.withTitle(entry(null, 'Left a voicemail.')), 'And one with no title is its text');
    }

    @IsTest
    static void salesforceNotesReadAsFileNotesOldestFirstWithTheTitleLeadingIn() {
        Case claim = [SELECT Id FROM Case];
        Datetime now = Datetime.now();
        Id later = AntsuranceSalesforceNotes.standIn(claim.Id, 'Plumber statement', 'The fitting failed. No outside water.', now);
        Id earlier = AntsuranceSalesforceNotes.standIn(claim.Id, 'Called the insured', 'Called the insured, who was out.', now.addDays(-1));
        AntsuranceSalesforceNotes.standIn(claim.Id, 'The shop called back.', 'The shop called back.\n\nEstimate due tomorrow.', now.addDays(-2));

        Test.startTest();
        List<File_Note__c> notes = AntsuranceSalesforceNotes.asFileNotes(claim.Id, 10);
        List<File_Note__c> one = AntsuranceSalesforceNotes.asFileNotes(claim.Id, 1);
        Test.stopTest();

        Assert.areEqual(3, notes.size(), 'One unsaved file note for each Salesforce note');
        Assert.areEqual('**The shop called back.**\n\nEstimate due tomorrow.', notes[0].Body__c, 'Oldest first, the order a file is read in; a first line that is the title is set in bold, and a sentence keeps its own stop');
        Assert.areEqual('Called the insured, who was out.', notes[1].Body__c, 'A one-line text that opens with its title is left as it is');
        Assert.areEqual('**Plumber statement:**\n\nThe fitting failed. No outside water.', notes[2].Body__c, 'A title leads into the text, so one line says what the note is');
        Assert.areEqual(AntsuranceSalesforceNotes.NOTE_TYPE, notes[2].Note_Type__c, 'Typed as a Salesforce note');
        Assert.areEqual(now, notes[2].Note_Date__c, 'Dated when it was written');
        Assert.areEqual(UserInfo.getName(), notes[2].Author_Name__c, 'Under whoever wrote it');
        Assert.isNull(notes[2].Id, 'It is not saved');
        Assert.areEqual(later, AntsuranceSalesforceNotes.entryOf(notes[2]).documentId, 'And it knows which Salesforce note it stands for');
        Assert.areEqual(earlier, AntsuranceSalesforceNotes.entryOf(notes[1]).documentId, 'As does the other');
        Assert.isNull(AntsuranceSalesforceNotes.entryOf(notes[2].clone()), 'A copy stands for none');
        Assert.isNull(AntsuranceSalesforceNotes.entryOf(null), 'Nor does nothing');
        Assert.areEqual(1, one.size(), 'Asked for one, the newest comes back');
        Assert.areEqual(later, AntsuranceSalesforceNotes.entryOf(one[0]).documentId, 'Which is the plumber\'s');
        Assert.isTrue(AntsuranceSalesforceNotes.notesOn([SELECT Id FROM Policy__c].Id, 10).isEmpty(), 'A record with no Salesforce notes has none');
    }

    @IsTest
    static void bothKindsOfNoteReadAsOneListByDate() {
        Case claim = [SELECT Id FROM Case];
        insert new List<File_Note__c>{
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Contact', Note_Date__c = Datetime.now().addDays(-2), Body__c = 'An older file note.'),
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Reserve', Note_Date__c = Datetime.now(), Body__c = 'The newest file note.')
        };
        List<File_Note__c> fileNotes = [SELECT Id, Note_Type__c, Note_Date__c, Author_Name__c, Body__c, CreatedDate FROM File_Note__c ORDER BY Note_Date__c DESC NULLS LAST];
        Assert.areEqual(2, AntsuranceSalesforceNotes.withFileNotes(fileNotes, claim.Id, 10).size(), 'With no Salesforce notes the file notes are read as they are');
        Id noteId = AntsuranceSalesforceNotes.standIn(claim.Id, 'Adjuster call', 'Left a voicemail.', Datetime.now().addDays(-1));

        Test.startTest();
        List<File_Note__c> notes = AntsuranceSalesforceNotes.withFileNotes(fileNotes, claim.Id, 10);
        List<File_Note__c> newestTwo = AntsuranceSalesforceNotes.withFileNotes(fileNotes, claim.Id, 2);
        List<File_Note__c> alone = AntsuranceSalesforceNotes.withFileNotes(null, claim.Id, 10);
        Test.stopTest();

        Assert.areEqual(3, notes.size(), 'The two file notes and the Salesforce note');
        Assert.areEqual('The newest file note.', notes[0].Body__c, 'Newest first');
        Assert.areEqual('**Adjuster call:**\n\nLeft a voicemail.', notes[1].Body__c, 'The Salesforce note falls between them by its date');
        Assert.areEqual('An older file note.', notes[2].Body__c, 'Then the older file note');
        Assert.areEqual(noteId, AntsuranceSalesforceNotes.entryOf(notes[1]).documentId, 'It knows which Salesforce note it stands for');
        Assert.isNotNull(AntsuranceSalesforceNotes.entryOf(notes[1]).editedAt, 'And when that was last edited');
        Assert.isNull(AntsuranceSalesforceNotes.entryOf(notes[0]), 'A file note stands for none');
        Assert.areEqual('Salesforce note', AntsuranceSalesforceNotes.typeLabel(notes[1]), 'It is listed as a Salesforce note');
        Assert.areEqual('Contact', AntsuranceSalesforceNotes.typeLabel(notes[2]), 'And a file note under its own type');
        Assert.areEqual(1, AntsuranceSalesforceNotes.countIn(notes), 'One of the three is a Salesforce note');
        Assert.isFalse(AntsuranceClaimRules.isClaudeNote(notes[1]), 'A note a person wrote in Salesforce Notes is evidence, not Claude\'s own work');
        Assert.areEqual(2, newestTwo.size(), 'Asked for two, the newest two come back');
        Assert.areEqual(notes[1].Body__c, newestTwo[1].Body__c, 'The Salesforce note among them');
        Assert.areEqual(1, alone.size(), 'With no file notes the Salesforce note is read alone');
    }

    @IsTest
    static void aNoteOnceCountedAsADocumentIsNotADocumentRemoved() {
        String key = 'documents';
        Map<String, Object> now = new Map<String, Object>{ key => 2, AntsuranceSalesforceNotes.COUNT_KEY => 1 };

        Assert.areEqual(2, AntsuranceSalesforceNotes.documentsThen(new Map<String, Object>{ key => 3 }, now, key), 'Three kept before notes were read as notes, one of them the note: the same two documents as today');
        Assert.areEqual(5, AntsuranceSalesforceNotes.documentsThen(new Map<String, Object>{ key => 5 }, now, key), 'More gone than there are notes is a document removed');
        Assert.areEqual(1, AntsuranceSalesforceNotes.documentsThen(new Map<String, Object>{ key => 1 }, now, key), 'A document added since still shows');
        Assert.areEqual(3, AntsuranceSalesforceNotes.documentsThen(new Map<String, Object>{ key => 3, AntsuranceSalesforceNotes.COUNT_KEY => 1 }, now, key), 'A number kept since notes were read as notes is taken as it stands');
        Assert.areEqual(3, AntsuranceSalesforceNotes.documentsThen(new Map<String, Object>{ key => 3 }, new Map<String, Object>{ key => 2 }, key), 'So is one compared with facts that carry no count of notes');
    }

    @IsTest
    static void aSalesforceNoteIsEvidenceTheClaimAnalysisReads() {
        Case claim = [SELECT Id FROM Case];
        AntsuranceSalesforceNotes.standIn(claim.Id, 'Plumber statement', 'The fitting failed. No outside water.', Datetime.now());

        Test.startTest();
        AntsuranceClaimsAssistantAnalysis.Docket docket = AntsuranceClaimsAssistantAnalysis.getDocket(claim.Id);
        Test.stopTest();

        Integer asNote = 0;
        for (AntsuranceClaimsAssistantAnalysis.Item item : docket.items) {
            if (item.title.startsWith('Salesforce note')) {
                asNote++;
                Assert.areEqual('note', item.kind, 'It is listed with the file notes');
                Assert.areEqual('Plumber statement: The fitting failed.', item.lookedLine, 'With its title and opening sentence');
                Assert.isNull(item.documentId, 'And not as a file to open');
            }
        }
        Assert.areEqual(1, asNote, 'The Salesforce note is in the docket once');
    }

    @IsTest
    static void whereNotesIsOffNothingIsReadAndSavingSaysWhy() {
        Case claim = [SELECT Id FROM Case];
        AntsuranceSalesforceNotes.standIn(claim.Id, 'Adjuster call', 'Left a voicemail.', Datetime.now());
        AntsuranceSalesforceNotes.actAsOff = true;

        Assert.isFalse(AntsuranceSalesforceNotes.isOn(), 'Notes reads as off');
        Assert.isTrue(AntsuranceSalesforceNotes.notesOn(claim.Id, 10).isEmpty(), 'There is nothing to read');
        Assert.isTrue(AntsuranceSalesforceNotes.asFileNotes(claim.Id, 10).isEmpty(), 'So nothing is read as evidence');
        try {
            AntsuranceSalesforceNotes.create(claim.Id, 'A note.');
            Assert.fail('Expected a refusal');
        } catch (AntsuranceSalesforceNotes.NotesOffException e) {
            Assert.isTrue(e.getMessage().contains('turned off') && e.getMessage().contains('save this as a file note'), 'Saving says why, and what to do instead: ' + e.getMessage());
        }
    }

    /**
     * The one test that needs the real thing: a note saved to Salesforce Notes, read back from it, and
     * then looked for in every list of a claim's documents, where a real note is a file to the platform.
     * Where the org has Notes turned off no such note can be made, and the test holds the org to that.
     */
    @IsTest
    static void aNoteSavedToSalesforceNotesReadsBackTheSameAndIsADocumentNowhere() {
        Case claim = [SELECT Id FROM Case];
        String written = 'Plumber\'s report is in\n\nThe **supply line** failed at the fitting.\n\n- Water ran two days\n- No sign of outside water';
        if (!AntsuranceSalesforceNotes.isOn()) {
            Assert.isFalse(AntsuranceNotesController.salesforceNotesOn(), 'The composer is told Notes is off, so it does not offer the type');
            try {
                AntsuranceNotesController.addNote(claim.Id, AntsuranceNotesController.SALESFORCE_NOTE, written);
                Assert.fail('Expected a refusal');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('turned off'), e.getMessage());
            }
            Assert.isTrue(AntsuranceSalesforceNotes.notesOn(claim.Id, 10).isEmpty(), 'With Notes off there is nothing to read');
            Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'And no file note is quietly saved in its place');
            return;
        }

        Test.startTest();
        AntsuranceNotesController.addNote(claim.Id, AntsuranceNotesController.SALESFORCE_NOTE, written);
        Test.stopTest();

        Assert.isTrue(AntsuranceNotesController.salesforceNotesOn(), 'The composer is told Notes is on');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'No file note is made: the note lives in Salesforce Notes');
        List<AntsuranceSalesforceNotes.Entry> entries = AntsuranceSalesforceNotes.notesOn(claim.Id, 10);
        Assert.areEqual(1, entries.size(), 'It is attached to the claim');
        Assert.areEqual('Plumber\'s report is in', entries[0].title, 'The first line is the title');
        Assert.areEqual(written, entries[0].body, 'And reads back as it was written, apostrophe and all');
        Assert.areEqual(written, AntsuranceSalesforceNotes.withTitle(entries[0]), 'A body that opens with the title does not get it twice');
        Assert.areEqual(UserInfo.getName(), entries[0].author, 'Under whoever wrote it');
        Assert.isNotNull(entries[0].writtenAt, 'Dated when it was written');
        Assert.isNotNull(entries[0].editedAt, 'And when it was last edited');
        List<AntsuranceNotesController.Note> timeline = AntsuranceNotesController.getNotes(claim.Id);
        Assert.areEqual(entries[0].documentId, timeline[0].documentId, 'The timeline shows it, and can open it in Notes');

        // To the platform the note is a file on the claim. Nowhere is it listed as a document.
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :claim.Id], 'The note is the one file on the claim');
        Assert.isTrue(AntsuranceFilesController.getFiles(claim.Id).isEmpty(), 'The Documents tab does not list it');
        Assert.isTrue(AntsuranceClaimsAssistantDocuments.getDocuments(claim.Id).isEmpty(), 'Nor does the list of documents Claude reads');
        Assert.isTrue(AntsuranceClaimsAssistantBrief.describeClaim(claim.Id).contains('ATTACHED DOCUMENTS: none'), 'The brief and the letters are not told it is an attached document');
        Assert.isTrue(AntsuranceClaimsAssistantCoverage.factsFor(claim.Id).documents.isEmpty(), 'Nor is the coverage check');
        Assert.areEqual('0 files attached', AntsuranceCoverageAgentTools.run(claim.Id, AntsuranceCoverageAgentTools.LIST_DOCUMENTS, new Map<String, Object>()).found, 'The coverage agent is not offered it to read');
        String keys = AntsuranceCoverageAgentTools.keysFor(claim.Id);
        Assert.isTrue(keys.contains('N1=' + entries[0].documentId) && !keys.contains('D1='), 'It has a note\'s key and no document\'s: ' + keys);
        for (AntsuranceClaimsAssistantAnalysis.Item item : AntsuranceClaimsAssistantAnalysis.getDocket(claim.Id).items) {
            Assert.isNull(item.documentId, 'And the claim analysis lists no file: ' + item.title);
        }
    }
}
