@IsTest
private class AntsuranceNotesControllerTest {
    @TestSetup
    static void createFile() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Date start = Date.today().addDays(-30);
        Policy__c policy = new Policy__c(Name = 'P-1', Account__c = customer.Id, Status__c = 'Active', Effective_Date__c = start, Expiration_Date__c = start.addYears(1));
        insert policy;
        insert new Case(
            Subject = 'Burst pipe', Policy__c = policy.Id, Status = 'New',
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId()
        );
    }

    private static String failureMessage(Id recordId, String body) {
        try {
            AntsuranceNotesController.addNote(recordId, 'Contact', body);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void aNoteSavedFromClaudesAnalysisIsShownAsClaudes() {
        Case claim = [SELECT Id FROM Case];
        insert new List<File_Note__c>{
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Investigation', Note_Date__c = Datetime.now(), Author_Name__c = 'Dana Whitaker, Adjuster', Body__c = AntsuranceClaimRules.ANALYSIS_NOTE_OPENING + ' An older one.'),
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Investigation', Note_Date__c = Datetime.now().addMinutes(1), Author_Name__c = 'Claude, saved by Dana Whitaker', Body__c = 'A newer one.')
        };

        Test.startTest();
        List<AntsuranceNotesController.Note> notes = AntsuranceNotesController.getNotes(claim.Id);
        Test.stopTest();

        Assert.areEqual(2, notes.size(), 'Both notes are listed');
        for (AntsuranceNotesController.Note note : notes) {
            Assert.isTrue(note.byClaude, 'Each is marked as Claude\'s');
            Assert.areEqual('Claude', note.author, 'and shown under Claude\'s name');
            Assert.areEqual('Dana Whitaker', note.savedBy, 'with the person who kept it');
        }
    }

    @IsTest
    static void aNoteOnAClaimShowsOnItsPolicyAndCustomer() {
        Case claim = [SELECT Id, CaseNumber, Policy__c, AccountId FROM Case];

        Test.startTest();
        AntsuranceNotesController.addNote(claim.Id, 'Contact', '  Spoke with the **insured**.  ');
        Test.stopTest();

        List<AntsuranceNotesController.Note> onClaim = AntsuranceNotesController.getNotes(claim.Id);
        Assert.areEqual(1, onClaim.size(), 'The note is on the claim');
        Assert.areEqual('Spoke with the **insured**.', onClaim[0].body, 'The text is trimmed and otherwise kept as written');
        Assert.areEqual('Contact', onClaim[0].noteType, 'The type is kept');
        Assert.areEqual(UserInfo.getName(), onClaim[0].author, 'The author defaults to whoever wrote it');
        Assert.isNotNull(onClaim[0].noteDate, 'The note is dated');
        Assert.isNull(onClaim[0].caseLabel, 'The claim is not repeated on its own timeline');

        List<AntsuranceNotesController.Note> onPolicy = AntsuranceNotesController.getNotes(claim.Policy__c);
        Assert.areEqual(1, onPolicy.size(), 'The note also shows on the policy');
        Assert.areEqual(claim.CaseNumber + ': Burst pipe', onPolicy[0].caseLabel, 'There it names the claim it came from');
        Assert.areEqual(1, AntsuranceNotesController.getNotes(claim.AccountId).size(), 'And on the customer');
    }

    @IsTest
    static void notesAreListedNewestFirstWithTheirNamedAuthor() {
        Policy__c policy = [SELECT Id, Account__c FROM Policy__c];
        insert new List<File_Note__c>{
            new File_Note__c(Policy__c = policy.Id, Body__c = 'Older', Note_Date__c = Datetime.now().addDays(-5), Author_Name__c = 'Dana Whitaker, Underwriter'),
            new File_Note__c(Policy__c = policy.Id, Body__c = 'Newer', Note_Date__c = Datetime.now().addDays(-1))
        };

        Test.startTest();
        AntsuranceNotesController.addNote(policy.Id, null, 'Newest');
        List<AntsuranceNotesController.Note> notes = AntsuranceNotesController.getNotes(policy.Id);
        Test.stopTest();

        Assert.areEqual(3, notes.size(), 'All three notes are listed');
        Assert.areEqual('Newest', notes[0].body, 'Newest first');
        Assert.areEqual('General', notes[0].noteType, 'A blank type is saved as General');
        Assert.areEqual('Older', notes[2].body, 'Oldest last');
        Assert.areEqual('Dana Whitaker, Underwriter', notes[2].author, 'A named author is shown as written');
        Assert.areEqual(policy.Account__c, [SELECT Account__c FROM File_Note__c ORDER BY Note_Date__c DESC LIMIT 1].Account__c, 'A policy note also belongs to the customer');
    }

    @IsTest
    static void emptyOversizedAndMisplacedNotesAreRejected() {
        Case claim = [SELECT Id FROM Case];
        Contact person = new Contact(LastName = 'Harbor');
        insert person;

        Assert.isTrue(failureMessage(claim.Id, '   ').contains('Write something'), 'An empty note is rejected');
        Assert.isTrue(failureMessage(claim.Id, 'x'.repeat(32001)).contains('too long'), 'An oversized note is rejected');
        Assert.isTrue(failureMessage(person.Id, 'Hello').contains('claims, service requests'), 'Notes do not apply to contacts');
        Assert.isTrue(AntsuranceNotesController.getNotes(person.Id).isEmpty(), 'A contact has no timeline');
        Assert.isTrue(AntsuranceNotesController.getNotes(null).isEmpty(), 'No record means no notes');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'Nothing was saved');
    }

    @IsTest
    static void salesforceNotesShowInTheSameTimelineNewestFirst() {
        Case claim = [SELECT Id FROM Case];
        insert new List<File_Note__c>{
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Contact', Note_Date__c = Datetime.now().addDays(-2), Body__c = 'An older file note.'),
            new File_Note__c(Case__c = claim.Id, Note_Type__c = 'Reserve', Note_Date__c = Datetime.now(), Body__c = 'The newest file note.')
        };
        // A stand-in for the note, so this runs the same where the org has Notes turned off.
        Id noteId = AntsuranceSalesforceNotes.standIn(claim.Id, 'Adjuster call', 'Left a voicemail.', Datetime.now().addDays(-1));
        Id undated = AntsuranceSalesforceNotes.standIn(claim.Id, 'Adjuster call', 'Adjuster call back.', null);

        Test.startTest();
        List<AntsuranceNotesController.Note> notes = AntsuranceNotesController.getNotes(claim.Id);
        Test.stopTest();

        Assert.areEqual(4, notes.size(), 'The file notes and the Salesforce notes are all listed');
        Assert.areEqual('The newest file note.', notes[0].body, 'Newest first, whichever kind each is');
        Assert.areEqual(AntsuranceNotesController.SALESFORCE_NOTE, notes[1].noteType, 'The Salesforce note falls between the file notes by its date');
        Assert.areEqual('**Adjuster call**\n\nLeft a voicemail.', notes[1].body, 'Its title leads its text');
        Assert.areEqual(noteId, notes[1].documentId, 'And it can be opened in Notes');
        Assert.areEqual(UserInfo.getName(), notes[1].author, 'Under whoever wrote it');
        Assert.isFalse(notes[1].byClaude, 'It is a person\'s note');
        Assert.areEqual('An older file note.', notes[2].body, 'Then the older file note');
        Assert.isNull(notes[2].documentId, 'A file note is not a file');
        Assert.areEqual(undated, notes[3].documentId, 'A note with no date goes last');
        Assert.areEqual('Adjuster call back.', notes[3].body, 'And a text that opens with its title is shown as it is');
    }

    @IsTest
    static void whereNotesIsOffTheComposerIsToldAndSavingToNotesSaysWhy() {
        Case claim = [SELECT Id FROM Case];
        AntsuranceSalesforceNotes.actAsOff = true;

        Assert.isFalse(AntsuranceNotesController.salesforceNotesOn(), 'The composer does not offer the Salesforce note type');
        try {
            AntsuranceNotesController.addNote(claim.Id, AntsuranceNotesController.SALESFORCE_NOTE, 'A note.');
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('turned off') && e.getMessage().contains('save this as a file note'), 'A note sent there anyway is refused with the reason: ' + e.getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c], 'And nothing is saved in its place');
        Assert.isTrue(AntsuranceNotesController.getNotes(claim.Id).isEmpty(), 'The timeline reads no Salesforce notes');
    }
}
