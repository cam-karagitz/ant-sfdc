/**
 * @description The portal's second round, tested as real portal users in two households: a guided quote
 * that prices with the configurator and is filed on the sender's own account, photos on a customer's own
 * claim, copies of their own policy documents, and their bill. Every read and write is tried by the other
 * household too, and refused.
 */
@IsTest
private class AntsurancePortalNextTest {
    private static final String STAMP = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    // The first bytes of a JPEG, enough for the portal to take it as one.
    private static final String JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==';

    @TestSetup
    static void households() {
        User setupUser = new User(Id = UserInfo.getUserId());
        User owner;
        // A portal account must be owned by someone with a role.
        System.runAs(setupUser) {
            UserRole role = new UserRole(Name = 'Portal Next Owner ' + STAMP, DeveloperName = 'Portal_Next_Owner_' + STAMP);
            insert role;
            owner = person('owner', [SELECT Id FROM Profile WHERE Name = 'System Administrator'].Id, null);
            owner.UserRoleId = role.Id;
            insert owner;
            // The owner also stands in for the internal user who files what the portal sends, so they work
            // with the same access as the people who use the internal app: every staff permission set of ours
            // this org holds, which is the whole app's, or the smaller ones a partial install brings.
            List<PermissionSetAssignment> access = new List<PermissionSetAssignment>();
            for (PermissionSet ours : [SELECT Id, Name FROM PermissionSet WHERE Name LIKE 'Antsurance%' AND IsOwnedByProfile = FALSE AND NamespacePrefix = NULL]) {
                if (ours.Name.startsWith('Antsurance_') && ours.Name != 'Antsurance_Portal') {
                    access.add(new PermissionSetAssignment(AssigneeId = owner.Id, PermissionSetId = ours.Id));
                }
            }
            Assert.isFalse(access.isEmpty(), 'This org holds at least one of our staff permission sets');
            insert access;
        }

        Contact maria;
        Contact chinedu;
        {
            Account reyes = new Account(Name = 'Reyes Next Household', OwnerId = owner.Id);
            Account okafor = new Account(Name = 'Okafor Next Household', OwnerId = owner.Id);
            insert new List<Account>{ reyes, okafor };
            maria = new Contact(AccountId = reyes.Id, FirstName = 'Maria', LastName = 'Reyes', Email = 'maria@antsurance.test', Licensed_Driver__c = true);
            Contact daniel = new Contact(AccountId = reyes.Id, FirstName = 'Daniel', LastName = 'Reyes', Licensed_Driver__c = true);
            chinedu = new Contact(AccountId = okafor.Id, FirstName = 'Chinedu', LastName = 'Okafor', Email = 'chinedu@antsurance.test');
            insert new List<Contact>{ maria, daniel, chinedu };

            Policy__c reyesAuto = policy(reyes, maria, 'ANT-PA-NEXT1', 'Personal Auto', 2380);
            reyesAuto.Insured_Item__c = '2022 Toyota RAV4 and 2019 Honda Accord';
            Policy__c okaforHome = policy(okafor, chinedu, 'ANT-HO-NEXT2', 'Homeowners', 1900);
            insert new List<Policy__c>{ reyesAuto, okaforHome };
            insert new Policy_Asset__c(Policy__c = reyesAuto.Id, Name = '2022 Toyota RAV4', Asset_Type__c = 'Vehicle');
            insert new Policy_Endorsement__c(Policy__c = reyesAuto.Id, Name = 'Rental Reimbursement', Status__c = 'Active', Effective_Date__c = reyesAuto.Effective_Date__c, Premium_Change__c = 54);

            Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
            insert new Case(RecordTypeId = claimType, AccountId = reyes.Id, ContactId = maria.Id, Policy__c = reyesAuto.Id, Subject = 'Scrape test',
                Status = 'New', Date_of_Loss__c = Date.today().addDays(-2), Reported_Date__c = Date.today().addDays(-1), Loss_Type__c = 'Collision');
        }

        System.runAs(setupUser) {
            Id portalProfile = [SELECT Id FROM Profile WHERE Name = 'Antsurance Customer'].Id;
            insert new List<User>{ person('maria', portalProfile, maria.Id), person('chinedu', portalProfile, chinedu.Id) };
        }
    }

    // ------------------------------------------------------------------------------- the guided quote

    @IsTest
    static void aQuoteStartsFromTheirRecordsAndPricesWithTheConfigurator() {
        System.runAs(portalUser('maria')) {
            List<AntsurancePortalQuote.Offer> offers = AntsurancePortalQuote.getOffers();
            Assert.areEqual(4, offers.size(), 'Four lines a household can ask about');
            Assert.areEqual('auto', offers[3].slug, 'The line they already have comes last');
            Assert.isTrue(offers[3].held, 'And says they have it');

            AntsurancePortalQuote.QuoteForm renters = AntsurancePortalQuote.start('renters');
            Assert.areEqual('Renters', renters.line, 'The line');
            Assert.isFalse(renters.steps.isEmpty(), 'With the configurator\'s own steps');
            Assert.isTrue(renters.fromRecords.contains('bundle'), 'Knows they already have a policy with us');
            Assert.areEqual(AntsuranceQuoteConfigurator.price('Renters', renters.answersJson, 1).premium, renters.price.premium, 'The same price an agent would see');
            Assert.isNotNull(renters.price.monthlyText, 'With a monthly figure');

            Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped(renters.answersJson);
            answers.put('contents', '60000');
            AntsurancePortalQuote.Price more = AntsurancePortalQuote.price('renters', JSON.serialize(answers));
            Assert.isTrue(more.premium > renters.price.premium, 'More to insure costs more');

            AntsurancePortalQuote.QuoteForm auto = AntsurancePortalQuote.start('auto');
            Map<String, Object> autoAnswers = (Map<String, Object>) JSON.deserializeUntyped(auto.answersJson);
            Assert.areEqual('2', String.valueOf(autoAnswers.get('drivers')), 'The two licensed drivers in the household');
            Assert.areEqual('2', String.valueOf(autoAnswers.get('vehicles')), 'And the two vehicles they insure');

            Assert.areEqual(AntsurancePortalQuote.UNKNOWN_LINE, refusal('start', 'workers'), 'Only the household lines');
        }
        Assert.areEqual(AntsurancePortalController.NOT_A_CUSTOMER, refusal('start', 'renters'), 'Staff are not customers');
    }

    @IsTest
    static void aQuoteIsFiledOnTheSendersOwnAccountAndOnlyTheySeeIt() {
        Account reyes = [SELECT Id, OwnerId FROM Account WHERE Name = 'Reyes Next Household'];
        User maria = portalUser('maria');
        Test.startTest();
        System.runAs(maria) {
            // What a form could send: a real answer, an answer that is not one of the choices, and a field that is not a question.
            AntsurancePortalController.Receipt sent = AntsurancePortalQuote.send(
                'renters',
                JSON.serialize(new Map<String, Object>{ 'contents' => '30000', 'deductible' => 'free', 'ownerId' => '005000000000000', 'accountId' => 'x' })
            );
            Assert.isNotNull(sent.sentAt, 'The customer is told it was sent');
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        Quote quote = [SELECT Id, QuoteNumber, Status, Submission_Channel__c, Configuration__c, Annual_Premium__c, ContactId, Opportunity.AccountId, Opportunity.OwnerId, Opportunity.Line_of_Business__c, Opportunity.StageName FROM Quote];
        Assert.areEqual(reyes.Id, quote.Opportunity.AccountId, 'On the sender\'s own account');
        Assert.areEqual(reyes.OwnerId, quote.Opportunity.OwnerId, 'Owned by the person who looks after the account');
        Assert.areEqual('Renters', quote.Opportunity.Line_of_Business__c, 'For the line they asked about');
        Assert.areEqual('Online', quote.Submission_Channel__c, 'Marked as asked for online');
        Assert.areEqual('Draft', quote.Status, 'A draft for an agent to confirm, never issued by the customer');
        Map<String, Object> answers = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c)).get('answers');
        Assert.areEqual('30000', String.valueOf(answers.get('contents')), 'With the answer they gave');
        Assert.areEqual('500', String.valueOf(answers.get('deductible')), 'An answer that is not one of the choices falls back to the default');
        Assert.isFalse(answers.containsKey('ownerId') || answers.containsKey('accountId'), 'And nothing that is not a question is kept');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :quote.OpportunityId], 'An agent is asked to confirm it');

        System.runAs(maria) {
            Assert.areEqual(quote.QuoteNumber, AntsurancePortalController.findReceipt('quote', System.currentTimeMillis() - 600000).referenceNumber, 'The customer can then see its number');
            Assert.areEqual(1, AntsurancePortalController.getHome().quotes.size(), 'And it is on their home page');
            AntsurancePortalQuote.QuoteForm seen = AntsurancePortalQuote.getSent(quote.Id);
            Assert.areEqual('With our team', seen.statusWord, 'In the customer\'s words');
            Assert.areEqual(quote.Annual_Premium__c, seen.price.premium, 'At the price it was sent at');
        }
        System.runAs(portalUser('chinedu')) {
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('sent', quote.Id), 'Another household cannot open it');
            Assert.isTrue(AntsurancePortalController.getHome().quotes.isEmpty(), 'Or see it listed');
        }
    }

    @IsTest
    static void claudeMayStartAQuoteAndFillItsQuestionsAndNothingElse() {
        Map<String, Object> answer = new Map<String, Object>{
            'reply' => 'I have started a renters quote.',
            'show' => 'none',
            'show_record_id' => '',
            'actions' => new List<Object>{
                action('navigate', 'newQuote', '', null, 'renters'),
                action('navigate', 'newQuote', '', null, 'pets'),
                action('fill', 'newQuote', '', new Map<String, String>{ 'deductible' => '1000', 'ownerId' => '005000000000000' }, ''),
                action('navigate', 'quote', '0Q0000000000000AAA', null, '')
            },
            'suggestions' => new List<Object>()
        };
        Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(answer)));
        AntsurancePortalClaude.Reply reply;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            reply = AntsurancePortalClaude.ask(JSON.serialize(new List<Object>{ new Map<String, String>{ 'role' => 'customer', 'text' => 'I need renters insurance' } }), '{"page":"home"}');
        }
        Test.stopTest();
        Assert.areEqual(3, reply.actions.size(), 'A quote that is not theirs is dropped');
        Assert.areEqual('renters', reply.actions[0].target, 'Starts the line they asked for');
        Assert.areEqual('quotes', reply.actions[1].page, 'A line we do not offer goes to the choices instead');
        Assert.areEqual(1, reply.actions[2].fields.size(), 'Only a real question is filled');
        Assert.areEqual('deductible', reply.actions[2].fields[0].name, 'The deductible');
    }

    @IsTest
    static void claudeExplainsAQuestionAndASlowAnswerIsCalm() {
        AntsurancePortalQuote.Explanation explained;
        AntsurancePortalQuote.Explanation slow;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(new Map<String, Object>{ 'explanation' => 'The deductible is what you pay first.', 'suggest' => '1000', 'why' => 'You chose it on your auto policy.' })));
            explained = AntsurancePortalQuote.explain('renters', 'deductible', '{}');
            Test.setMock(HttpCalloutMock.class, new TimingOut());
            slow = AntsurancePortalQuote.explain('renters', 'deductible', '{}');
        }
        Test.stopTest();
        Assert.areEqual('The deductible is what you pay first.', explained.text, 'Claude\'s words');
        Assert.areEqual('1000', explained.suggestValue, 'A choice the question really has');
        Assert.areEqual('$1,000', explained.suggestLabel, 'By its label');
        Assert.isTrue(slow.failed, 'A slow answer is marked, not thrown');
        Assert.areEqual(AntsurancePortalQuote.COULD_NOT_EXPLAIN, slow.text, 'With a calm line');
    }

    // ------------------------------------------------------------------------------- claim photos

    @IsTest
    static void aCustomerAddsPhotosToTheirOwnClaimAndNobodyElseCan() {
        Id claimId = [SELECT Id FROM Case WHERE Subject = 'Scrape test'].Id;
        User maria = portalUser('maria');
        User chinedu = portalUser('chinedu');
        // No site is running in a test, so the portal's site is named for it.
        AntsurancePortalPhotos.siteForTests = [SELECT Id FROM Network WHERE Name = 'Antsurance' LIMIT 1].Id;
        Id photoId;
        Test.startTest();
        System.runAs(maria) {
            photoId = AntsurancePortalPhotos.add(claimId, 'data:image/jpeg;base64,' + JPEG, 'rear bumper, close up', 'Clear shot of the rear bumper.').id;
            Assert.areEqual(1, AntsurancePortalPhotos.getPhotos(claimId).size(), 'Their photo is theirs to see straight away');
            Assert.areEqual('Rear bumper, close up', AntsurancePortalPhotos.getPhotos(claimId)[0].name, 'Named for what it shows');
            Assert.areEqual('Clear shot of the rear bumper.', AntsurancePortalPhotos.getPhotos(claimId)[0].note, 'With what Claude said about it');
            Assert.areEqual(JPEG, AntsurancePortalPhotos.view(claimId, photoId), 'And they can see it again');
            Assert.areEqual(AntsurancePortalPhotos.NOT_A_PHOTO, refusal('photo', claimId, EncodingUtil.base64Encode(Blob.valueOf('<script>alert(1)</script>'))), 'Only a photo is taken');
            for (Integer more = 0; more < AntsurancePortalPhotos.MAX_PHOTOS - 1; more++) {
                AntsurancePortalPhotos.add(claimId, JPEG, null, null);
            }
            Assert.areEqual(AntsurancePortalPhotos.TOO_MANY, refusal('photo', claimId, JPEG), 'Five photos a claim');
        }
        // Each photo is attached to the claim by the event's trigger, as an internal user.
        Test.getEventBus().deliver();
        Test.stopTest();

        // Internal users find them on the claim, where the adjuster and the photo assessment look.
        Assert.areEqual(AntsurancePortalPhotos.MAX_PHOTOS, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :claimId], 'The photos are files on the claim');

        System.runAs(chinedu) {
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('photo', claimId, JPEG), 'Another household cannot add to it');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('photos', claimId, null), 'Or list its photos');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('view', claimId, photoId), 'Or see one');
        }
        // And a hand-over that names someone else's claim or photo attaches nothing.
        Id othersPolicy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-NEXT2'].Id;
        Case othersClaim = new Case(RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(), AccountId = [SELECT Account__c FROM Policy__c WHERE Id = :othersPolicy].Account__c,
            Policy__c = othersPolicy, Subject = 'Okafor test claim', Status = 'New', Date_of_Loss__c = Date.today(), Reported_Date__c = Date.today(), Loss_Type__c = 'Water Damage');
        insert othersClaim;
        try {
            AntsurancePortalSubmissions.file(chinedu.Id, 'photo', JSON.serialize(new Map<String, String>{ 'claimId' => claimId, 'photoId' => photoId }));
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, e.getMessage(), 'Refused when it is filed too');
        }
        AntsurancePortalSubmissions.file(chinedu.Id, 'photo', JSON.serialize(new Map<String, String>{ 'claimId' => othersClaim.Id, 'photoId' => photoId }));
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :othersClaim.Id], 'Someone else\'s photo is not attached to their claim');
    }

    @IsTest
    static void claudeChecksAPhotoAndASlowCheckIsCalm() {
        AntsurancePortalPhotos.Check dark;
        AntsurancePortalPhotos.Check slow;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(new Map<String, Object>{ 'shows' => 'dark car park', 'usable' => false, 'line' => 'Too dark to see the damage. Try again in daylight.', 'still_needed' => 'Add one of the whole car.' })));
            dark = AntsurancePortalPhotos.check(JPEG, 'Collision', 'Someone scraped my car.', new List<String>());
            Test.setMock(HttpCalloutMock.class, new TimingOut());
            slow = AntsurancePortalPhotos.check(JPEG, 'Collision', 'Someone scraped my car.', new List<String>{ 'dark car park' });
        }
        Test.stopTest();
        Assert.isFalse(dark.usable, 'Claude says when a photo will not do');
        Assert.areEqual('Too dark to see the damage. Try again in daylight.', dark.line, 'In one plain line');
        Assert.areEqual('Add one of the whole car.', dark.stillNeeded, 'With what is still missing');
        Assert.isTrue(slow.failed, 'A slow check is marked, not thrown');
        Assert.areEqual(AntsurancePortalPhotos.COULD_NOT_LOOK, slow.line, 'And the photo can still be sent');
    }

    // ------------------------------------------------------------------------------- documents

    @IsTest
    static void aCustomerGetsACopyOfTheirOwnDocumentsAndNobodyElseDoes() {
        Id auto = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-NEXT1'].Id;
        User maria = portalUser('maria');
        User chinedu = portalUser('chinedu');
        Test.startTest();
        System.runAs(maria) {
            List<AntsurancePortalDocuments.Doc> documents = AntsurancePortalDocuments.getDocuments(auto);
            Assert.areEqual(2, documents.size(), 'A declarations page, and ID cards for an auto policy');
            Assert.isFalse(documents[0].ready, 'No copy yet');
            Assert.isNotNull(AntsurancePortalDocuments.request(auto, 'declarations').sentAt, 'Asking for one hands the request over');
            Assert.areEqual(AntsurancePortalDocuments.UNKNOWN_DOCUMENT, refusal('document', auto, 'certificate'), 'Only the documents a customer has');
        }
        Test.getEventBus().deliver();
        Test.stopTest();
        // The request starts a job that prints the copy as an internal user who is a member of the portal's site.
        // A test's trigger is not one, so the job is run here as it would be, as the internal user this test
        // made. Whoever runs the tests may not be a member yet: in an org the portal has only just been installed
        // in, people who were there before the site are added to it afterwards, in the background.
        System.runAs(portalUser('owner')) {
            new AntsurancePortalDocumentJob(auto, 'declarations', maria.Id, 'Declarations ANT-PA-NEXT1').execute(null);
        }

        System.runAs(maria) {
            AntsurancePortalDocuments.Doc declarations = AntsurancePortalDocuments.getDocument(auto, 'declarations');
            Assert.isTrue(declarations.ready, 'The copy is ready for them');
            Assert.isNotNull(declarations.documentId, 'As a file');
            Assert.areEqual(1, declarations.pages, 'With its page count');
            Assert.areEqual('Declarations ANT-PA-NEXT1.pdf', declarations.fileName, 'Named for the policy');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :maria.Id], 'Shared with the customer who asked');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :chinedu.Id], 'And with nobody else');

        System.runAs(chinedu) {
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('documents', auto, null), 'Another household cannot list them');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refusal('document', auto, 'declarations'), 'Or ask for a copy');
        }
    }

    // ------------------------------------------------------------------------------- the bill

    @IsTest
    static void aBillIsWorkedOutFromThePolicy() {
        Id auto = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-NEXT1'].Id;
        System.runAs(portalUser('maria')) {
            AntsurancePortalController.Bill bill = AntsurancePortalController.getPolicy(auto).bill;
            Assert.areEqual('$2,380 for the year', bill.headline, 'The yearly price');
            Assert.areEqual('12 payments of about $198, one each month', bill.schedule, 'How it is billed');
            Assert.areEqual('Up to date', bill.standing, 'Where they stand');
            Assert.areEqual('5 of 12 payments, about $992', bill.paidSoFar, 'What has been paid, from the term so far');
            Assert.isTrue(bill.nextDue.startsWith('About $198 on '), 'What is due next and when');
            Assert.areEqual(1, bill.changes.size(), 'What has changed the price');
            Assert.areEqual('+$54 a year', bill.changes[0].amountText, 'By how much');
            Assert.isTrue(bill.basis.contains('Worked out'), 'And says how it was arrived at');
        }
    }

    // ------------------------------------------------------------------------------- helpers

    /** The message a refused call gives, or null when it went through. */
    private static String refusal(String what, Object first) {
        return refusal(what, first, null);
    }

    private static String refusal(String what, Object first, Object second) {
        try {
            if (what == 'start') {
                AntsurancePortalQuote.start((String) first);
            } else if (what == 'sent') {
                AntsurancePortalQuote.getSent((Id) first);
            } else if (what == 'photo') {
                AntsurancePortalPhotos.add((Id) first, (String) second, null, null);
            } else if (what == 'photos') {
                AntsurancePortalPhotos.getPhotos((Id) first);
            } else if (what == 'view') {
                AntsurancePortalPhotos.view((Id) first, (Id) second);
            } else if (what == 'documents') {
                AntsurancePortalDocuments.getDocuments((Id) first);
            } else if (what == 'document') {
                AntsurancePortalDocuments.request((Id) first, (String) second);
            }
            return null;
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
    }

    private static Map<String, Object> action(String type, String page, String recordId, Map<String, String> fields, String target) {
        List<Object> pairs = new List<Object>();
        if (fields != null) {
            for (String name : fields.keySet()) {
                pairs.add(new Map<String, Object>{ 'name' => name, 'value' => fields.get(name) });
            }
        }
        return new Map<String, Object>{ 'type' => type, 'page' => page, 'record_id' => recordId, 'fields' => pairs, 'target' => target };
    }

    private static User portalUser(String who) {
        return [SELECT Id FROM User WHERE Alias = :who.left(8) AND Username LIKE '%@portalnext.antsurance.test' LIMIT 1];
    }

    private static User person(String who, Id profileId, Id contactId) {
        return new User(
            ProfileId = profileId,
            ContactId = contactId,
            Username = who + STAMP + '@portalnext.antsurance.test',
            Email = who + '@antsurance.test',
            FirstName = who,
            LastName = 'Test',
            Alias = who.left(8),
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Chicago'
        );
    }

    private static Policy__c policy(Account account, Contact insured, String policyNumber, String line, Decimal premium) {
        return new Policy__c(
            Name = policyNumber,
            Account__c = account.Id,
            Primary_Insured__c = insured.Id,
            Line_of_Business__c = line,
            Status__c = 'Active',
            Annual_Premium__c = premium,
            Coverage_Limit__c = 300000,
            Effective_Date__c = Date.today().addMonths(-4),
            Expiration_Date__c = Date.today().addMonths(8),
            Billing_Frequency__c = 'Monthly',
            Payment_Status__c = 'Current'
        );
    }

    /** A Claude call that never comes back in time. */
    private class TimingOut implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            CalloutException slow = new CalloutException();
            slow.setMessage('Read timed out');
            throw slow;
        }
    }

    /** Answers the Claude call with a fixed reply. */
    private class Answering implements HttpCalloutMock {
        String answerJson;

        Answering(String answerJson) {
            this.answerJson = answerJson;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-test',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => answerJson } }
                    }
                )
            );
            return response;
        }
    }
}
