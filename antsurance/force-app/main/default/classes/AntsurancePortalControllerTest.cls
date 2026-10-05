/**
 * @description The portal's boundary, tested as a real portal user: a customer reaches their own
 * household's records and nobody else's, staff are not customers, what a customer sends lands on
 * their own account, and whatever Claude returns is checked before the site sees it.
 */
@IsTest
private class AntsurancePortalControllerTest {
    private static final String STAMP = String.valueOf(Crypto.getRandomInteger()).replace('-', '');

    @TestSetup
    static void households() {
        User setupUser = new User(Id = UserInfo.getUserId());
        User owner;
        // A portal account must be owned by someone with a role.
        System.runAs(setupUser) {
            UserRole role = new UserRole(Name = 'Portal Test Owner ' + STAMP, DeveloperName = 'Portal_Test_Owner_' + STAMP);
            insert role;
            owner = person('owner', [SELECT Id FROM Profile WHERE Name = 'System Administrator'].Id, null);
            owner.UserRoleId = role.Id;
            insert owner;
        }

        // The households are loaded by the person running the test and owned by the owner with a role.
        Contact maria;
        Contact chinedu;
        {
            Account reyes = new Account(Name = 'Reyes Test Household', OwnerId = owner.Id);
            Account okafor = new Account(Name = 'Okafor Test Household', OwnerId = owner.Id);
            insert new List<Account>{ reyes, okafor };
            maria = new Contact(AccountId = reyes.Id, FirstName = 'Maria', LastName = 'Reyes', Email = 'maria@antsurance.test');
            Contact sofia = new Contact(AccountId = reyes.Id, FirstName = 'Sofia', LastName = 'Reyes');
            chinedu = new Contact(AccountId = okafor.Id, FirstName = 'Chinedu', LastName = 'Okafor', Email = 'chinedu@antsurance.test');
            insert new List<Contact>{ maria, sofia, chinedu };

            Policy__c reyesAuto = policy(reyes, maria, 'ANT-PA-TEST1', 'Personal Auto', 2380);
            Policy__c okaforHome = policy(okafor, chinedu, 'ANT-HO-TEST2', 'Homeowners', 1900);
            insert new List<Policy__c>{ reyesAuto, okaforHome };
            insert new Policy_Coverage__c(Policy__c = reyesAuto.Id, Name = 'Collision', Deductible_Amount__c = 500, Premium_Amount__c = 666, What_Is_Covered__c = 'Repairs to your car after a crash.');

            Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
            insert new Case(RecordTypeId = claimType, AccountId = okafor.Id, ContactId = chinedu.Id, Policy__c = okaforHome.Id, Subject = 'Burst pipe test',
                Status = 'Under Investigation', Date_of_Loss__c = Date.today().addDays(-10), Reported_Date__c = Date.today().addDays(-9), Loss_Type__c = 'Water Damage');
        }

        System.runAs(setupUser) {
            Id portalProfile = [SELECT Id FROM Profile WHERE Name = 'Antsurance Customer'].Id;
            User mariaUser = person('maria', portalProfile, maria.Id);
            User chineduUser = person('chinedu', portalProfile, chinedu.Id);
            insert new List<User>{ mariaUser, chineduUser };
        }
    }

    @IsTest
    static void aCustomerSeesTheirOwnHouseholdAndNothingElse() {
        System.runAs(portalUser('maria')) {
            AntsurancePortalController.Home home = AntsurancePortalController.getHome();
            Assert.areEqual('Maria', home.firstName, 'Greets the customer by name');
            Assert.areEqual(1, home.policies.size(), 'Only the Reyes policy');
            Assert.areEqual('ANT-PA-TEST1', home.policies[0].policyNumber, 'Their own policy');
            Assert.areEqual('$2,380', home.policies[0].premiumText, 'Whole dollars');
            Assert.areEqual(0, home.claims.size(), 'The Okafor claim is not theirs');
            Assert.areEqual(6, home.suggestions.size(), 'Six things to ask, with no open claim to ask about');
            Assert.isFalse(home.suggestions.contains('Where does my claim stand?'), 'A claim is only offered when one is open');
            Assert.isTrue(home.suggestions.contains('What does my auto policy cover?'), 'What the main policy covers');
            Assert.areEqual(new Set<String>(home.suggestions).size(), home.suggestions.size(), 'No suggestion twice');
            Assert.areEqual('What do I pay, and when?', home.suggestions[0], 'The first is one the record can answer');
            Assert.isTrue(home.suggestions[1].contains('Sofia'), 'Offers to add the household member who is not yet a driver');

            AntsurancePortalController.Policy detail = AntsurancePortalController.getPolicy(home.policies[0].id);
            Assert.areEqual(1, detail.coverages.size(), 'With its coverages');
            Assert.areEqual('Repairs to your car after a crash.', detail.coverages[0].plainWords, 'In plain words');
        }
    }

    @IsTest
    static void anotherHouseholdsPolicyAndClaimAreRefused() {
        Id othersPolicy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-TEST2'].Id;
        Id othersClaim = [SELECT Id FROM Case WHERE Subject = 'Burst pipe test'].Id;
        System.runAs(portalUser('maria')) {
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, messageFrom('policy', othersPolicy), 'Cannot read another household\'s policy');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, messageFrom('claim', othersClaim), 'Cannot read another household\'s claim');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, messageFrom('fileClaim', othersPolicy), 'Cannot file a claim on another household\'s policy');
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, messageFrom('request', othersPolicy), 'Cannot send a request on another household\'s policy');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'Nothing was created');

        // The owner of that policy can read it, so the refusal above is about whose it is.
        System.runAs(portalUser('chinedu')) {
            Assert.areEqual('ANT-HO-TEST2', AntsurancePortalController.getPolicy(othersPolicy).policyNumber, 'Its own household reads it');
            Assert.areEqual('Being reviewed', AntsurancePortalController.getClaim(othersClaim).statusWord, 'With the claim in the customer\'s words');
        }
    }

    @IsTest
    static void staffAreNotCustomers() {
        Assert.areEqual(AntsurancePortalController.NOT_A_CUSTOMER, messageFrom('home', null), 'An internal user has no portal home');
    }

    @IsTest
    static void whatACustomerSendsLandsOnTheirOwnAccount() {
        Account reyes = [SELECT Id, OwnerId FROM Account WHERE Name = 'Reyes Test Household'];
        Id auto = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-TEST1'].Id;
        User maria = portalUser('maria');
        Test.startTest();
        System.runAs(maria) {
            AntsurancePortalController.Receipt request = AntsurancePortalController.submitRequest(
                'driver',
                JSON.serialize(new Map<String, String>{ 'policyId' => auto, 'firstName' => 'Sofia', 'lastName' => 'Reyes', 'relationship' => 'Child', 'licenseState' => 'IL' })
            );
            Assert.isNotNull(request.sentAt, 'The customer is told it was sent');
            Assert.isNotNull(request.message, 'And what happens next');
            AntsurancePortalController.submitClaim(
                JSON.serialize(new Map<String, String>{ 'policyId' => auto, 'dateOfLoss' => String.valueOf(Date.today().addDays(-1)), 'lossType' => 'Collision',
                    'whatHappened' => 'Someone backed into my car in a parking lot.', 'estimate' => '$2,800' })
            );
            Assert.areEqual('Tell us what happened.', messageFromClaim(new Map<String, String>{ 'policyId' => auto, 'dateOfLoss' => String.valueOf(Date.today()) }), 'A claim needs an account of what happened');
            Assert.areEqual('The date it happened cannot be in the future.',
                messageFromClaim(new Map<String, String>{ 'policyId' => auto, 'dateOfLoss' => String.valueOf(Date.today().addDays(3)), 'whatHappened' => 'x' }), 'Not in the future');
        }
        // The forms are filed by the event's trigger.
        Test.getEventBus().deliver();
        Test.stopTest();

        Case request = [SELECT AccountId, ContactId, OwnerId, Policy__c, Request_Type__c, Subject, Origin, RecordType.DeveloperName FROM Case WHERE Request_Type__c = 'Add Driver'];
        Assert.areEqual(reyes.Id, request.AccountId, 'On the customer\'s account');
        Assert.areEqual(reyes.OwnerId, request.OwnerId, 'Owned by the person who looks after the account, not the customer');
        Assert.areEqual('Policy_Service', request.RecordType.DeveloperName, 'As a service request');
        Assert.areEqual('Add Sofia Reyes as a driver', request.Subject, 'Named for what was asked');
        Assert.areEqual('Web', request.Origin, 'From the web');

        Case claim = [SELECT AccountId, Policy__c, Loss_Type__c, Estimated_Loss__c, Date_of_Loss__c, CaseNumber FROM Case WHERE RecordType.DeveloperName = 'Claim' AND AccountId = :reyes.Id];
        Assert.areEqual(auto, claim.Policy__c, 'The claim is on their policy');
        Assert.areEqual(2800, claim.Estimated_Loss__c, 'With the estimate they gave');
        Assert.areEqual('Collision', claim.Loss_Type__c, 'And the kind of loss');

        System.runAs(maria) {
            Assert.areEqual(claim.CaseNumber, AntsurancePortalController.findReceipt('claim', System.currentTimeMillis() - 600000).referenceNumber, 'The customer can then see its number');
        }
    }

    @IsTest
    static void aFormIsFiledForWhoeverSentItNotWhoeverItNames() {
        // The filing step takes the customer from the user who sent the form. A form that names another household's policy is refused there too.
        Id others = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-TEST2'].Id;
        User maria = portalUser('maria');
        String refused;
        try {
            AntsurancePortalSubmissions.file(maria.Id, 'request', JSON.serialize(new Map<String, String>{ 'policyId' => others, 'details' => 'x' }));
        } catch (AuraHandledException e) {
            refused = e.getMessage();
        }
        Assert.areEqual(AntsurancePortalController.NOT_YOURS, refused, 'Checked again when it is filed');

        Case filed = AntsurancePortalSubmissions.file(maria.Id, 'request', JSON.serialize(new Map<String, String>{ 'topic' => 'Billing Question', 'details' => 'Why did my bill go up?' }));
        Assert.areEqual([SELECT AccountId FROM Contact WHERE FirstName = 'Maria' AND LastName = 'Reyes'].AccountId, [SELECT AccountId FROM Case WHERE Id = :filed.Id].AccountId, 'Filed on the sender\'s own account');
    }

    @IsTest
    static void aRequestOpensForItsOwnerTakesTheirNoteAndCanBeWithdrawn() {
        User maria = portalUser('maria');
        Id auto = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-TEST1'].Id;
        Case filed = AntsurancePortalSubmissions.file(
            maria.Id,
            'driver',
            JSON.serialize(new Map<String, String>{ 'policyId' => auto, 'firstName' => 'Sofia', 'lastName' => 'Reyes', 'relationship' => 'Child', 'licenseState' => 'IL' })
        );
        // A staff note on the same request, which the customer must never see.
        insert new File_Note__c(Case__c = filed.Id, Author_Name__c = 'Lydia Osei', Note_Date__c = System.now(), Body__c = 'Internal: check the motor vehicle record first.');
        // A request the team opened for her by phone, described in the team's own words about her.
        Case byPhone = new Case(
            AccountId = [SELECT AccountId FROM Contact WHERE FirstName = 'Maria' AND LastName = 'Reyes'].AccountId,
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
            Subject = 'Change the mailing address',
            Description = 'Maria called. She wants statements sent to her office and sounded unhappy about the last bill.',
            Handled_By__c = 'Bridget Castillo',
            Status = 'New'
        );
        insert as system byPhone;

        Test.startTest();
        System.runAs(maria) {
            AntsurancePortalController.Request request = AntsurancePortalController.getRequest(filed.Id);
            Assert.areEqual('Add Sofia Reyes as a driver', request.title, 'What was asked');
            Assert.areEqual('Received', request.statusWord, 'In the customer\'s words');
            Assert.areEqual('current', request.steps[0].state, 'On its first step');
            Assert.isTrue(request.canWithdraw, 'Still only received, so it can be withdrawn');
            Assert.areEqual('Relationship', request.facts[1].label, 'With the details they sent');
            Assert.areEqual('Child', request.facts[1].value, 'As they sent them');
            Assert.isTrue(request.notes.isEmpty(), 'A staff note is not shown to the customer');
            Assert.isFalse(request.takenForYou, 'A request sent from the portal carries their own words');
            AntsurancePortalController.Request taken = AntsurancePortalController.getRequest(byPhone.Id);
            Assert.isTrue(taken.takenForYou, 'A request the team opened for them is marked as such');
            Assert.isTrue(String.isBlank(taken.asked), 'The team\'s wording about the customer is not shown to the customer');
            Assert.isTrue(taken.facts.isEmpty(), 'Nor split into facts');
            Assert.isTrue(taken.lastUpdate.contains('Bridget Castillo'), 'One line says who will pick it up');
            Assert.isNull(taken.handler, 'And it is not said a second time');
            AntsurancePortalController.addRequestNote(filed.Id, 'Her license number is R200-1234-5678.');
        }
        Test.getEventBus().deliver();
        System.runAs(maria) {
            Assert.areEqual(1, AntsurancePortalController.getRequest(filed.Id).notes.size(), 'Their own note is shown back to them');
            AntsurancePortalController.withdrawRequest(filed.Id);
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual('Closed', [SELECT Status FROM Case WHERE Id = :filed.Id].Status, 'Withdrawing closes the request');
        Assert.areEqual(3, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :filed.Id], 'The note and the withdrawal are in the file for staff');

        System.runAs(portalUser('chinedu')) {
            String refused;
            try {
                AntsurancePortalController.getRequest(filed.Id);
            } catch (AuraHandledException e) {
                refused = e.getMessage();
            }
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refused, 'Another household cannot open it');
            refused = null;
            try {
                AntsurancePortalController.addRequestNote(filed.Id, 'x');
            } catch (AuraHandledException e) {
                refused = e.getMessage();
            }
            Assert.areEqual(AntsurancePortalController.NOT_YOURS, refused, 'Or write on it');
        }
    }

    @IsTest
    static void coverageLimitsAreSaidInPlainWords() {
        Id auto = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-TEST1'].Id;
        insert new Policy_Coverage__c(Policy__c = auto, Name = 'Bodily Injury Liability', Limit_Amount__c = 300000, Limit_Type__c = 'Per Person', Premium_Amount__c = 833);
        update new Policy_Coverage__c(Id = [SELECT Id FROM Policy_Coverage__c WHERE Name = 'Collision'].Id, Limit_Type__c = 'Actual Cash Value');
        System.runAs(portalUser('maria')) {
            AntsurancePortalController.Policy policy = AntsurancePortalController.getPolicy(auto);
            Assert.areEqual('Auto policy', policy.plainName, 'Named for what it is');
            Assert.areEqual('about $198 a month', policy.monthlyText, 'With the monthly figure');
            Map<String, AntsurancePortalController.Coverage> byName = new Map<String, AntsurancePortalController.Coverage>();
            for (AntsurancePortalController.Coverage coverage : policy.coverages) {
                byName.put(coverage.name, coverage);
            }
            Assert.areEqual('Up to $300,000 for each person', byName.get('Bodily Injury Liability').limitWords, 'A limit as a person would say it');
            Assert.areEqual('The vehicle\'s value at the time, less your $500 deductible', byName.get('Collision').limitWords, 'No insurance shorthand');
            Assert.areEqual('You pay the first $500', byName.get('Collision').deductibleWords, 'And the deductible in plain words');
        }
    }

    @IsTest
    static void aSlowAnswerLeavesACalmLineNotAnError() {
        Test.setMock(HttpCalloutMock.class, new TimingOut());
        AntsurancePortalClaude.Reply reply;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            reply = AntsurancePortalClaude.ask(JSON.serialize(new List<Object>{ new Map<String, String>{ 'role' => 'customer', 'text' => 'Why did my bill go up?' } }), '{"page":"home"}');
        }
        Test.stopTest();
        Assert.isTrue(reply.failed, 'The turn is marked as failed, not thrown');
        Assert.areEqual('timeout', reply.failureKind, 'With why');
        Assert.areEqual(AntsurancePortalClaude.TOOK_TOO_LONG, reply.text, 'And a calm line for the customer');
        Assert.isFalse(reply.text.containsIgnoreCase('exception') || reply.text.containsIgnoreCase('timed out'), 'Never the raw error');
        Assert.isTrue(reply.actions.isEmpty(), 'Nothing for the site to do');
    }

    @IsTest
    static void claudeGetsOnlyThisCustomersRecordsAndItsAnswerIsChecked() {
        Id own = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-TEST1'].Id;
        Id others = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-TEST2'].Id;
        Id othersClaim = [SELECT Id FROM Case WHERE Subject = 'Burst pipe test'].Id;
        // Claude's answer tries everything the site must refuse, beside things it should allow.
        Map<String, Object> answer = new Map<String, Object>{
            'reply' => 'Here is your auto policy.',
            'blocks' => new List<Object>{ block('price', others, null, ''), block('coverage', others, null, ''), block('claim', othersClaim, null, ''), block('note', othersClaim, null, '') },
            'actions' => new List<Object>{
                action('navigate', 'policy', others, null, ''),
                action('navigate', 'claim', othersClaim, null, ''),
                action('navigate', 'policy', own, null, ''),
                action('fill', 'addDriver', '', new Map<String, String>{ 'firstName' => 'Sofia', 'policyId' => others, 'ownerId' => '005000000000000' }, ''),
                action('highlight', 'none', '', null, 'licenseNumber'),
                action('navigate', 'setup', '', null, '')
            },
            'suggestions' => new List<Object>{ 'What does collision cover?' }
        };
        Answering mock = new Answering(JSON.serialize(answer));
        Test.setMock(HttpCalloutMock.class, mock);

        AntsurancePortalClaude.Reply reply;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            reply = AntsurancePortalClaude.ask(
                JSON.serialize(new List<Object>{ new Map<String, String>{ 'role' => 'customer', 'text' => 'Show me my auto policy' } }),
                '{"page":"home"}'
            );
        }
        Test.stopTest();

        Assert.isTrue(mock.sent.contains('ANT-PA-TEST1'), 'Claude is given the customer\'s own policy');
        Assert.isFalse(mock.sent.contains('ANT-HO-TEST2'), 'And never another household\'s');
        Assert.isFalse(mock.sent.contains('Burst pipe test'), 'Nor its claims');

        Assert.isTrue(reply.blocks.isEmpty(), 'A block about someone else\'s policy or claim is dropped');
        Assert.areEqual(3, reply.actions.size(), 'Only the actions that are safe survive');
        Assert.areEqual('navigate', reply.actions[0].type, 'Going to their own policy');
        Assert.areEqual(own, reply.actions[0].recordId, 'By its Id');
        Assert.areEqual('Claude is taking you to your personal auto policy.', reply.actions[0].say, 'Said in words');
        Assert.areEqual('fill', reply.actions[1].type, 'Filling the form');
        Assert.areEqual(1, reply.actions[1].fields.size(), 'Without the other household\'s policy or a field the form does not have');
        Assert.areEqual('firstName', reply.actions[1].fields[0].name, 'Only the driver\'s name');
        Assert.areEqual('highlight', reply.actions[2].type, 'And pointing at a field');
    }

    @IsTest
    static void anAnswersBlocksAreBuiltFromTheCustomersOwnRecords() {
        Policy__c auto = [SELECT Id, Account__c, Effective_Date__c FROM Policy__c WHERE Name = 'ANT-PA-TEST1'];
        Id others = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-TEST2'].Id;
        Id othersClaim = [SELECT Id FROM Case WHERE Subject = 'Burst pipe test'].Id;
        insert new List<Policy_Endorsement__c>{
            new Policy_Endorsement__c(Policy__c = auto.Id, Name = 'Multi-Policy Discount', Status__c = 'Active', Effective_Date__c = auto.Effective_Date__c, Premium_Change__c = -190),
            new Policy_Endorsement__c(Policy__c = auto.Id, Name = 'Roadside Assistance', Status__c = 'Active', Effective_Date__c = auto.Effective_Date__c.addMonths(2), Premium_Change__c = 36)
        };
        insert new Policy_Coverage__c(Policy__c = auto.Id, Name = 'Bodily Injury Liability', Limit_Amount__c = 300000, Limit_Type__c = 'Per Person', Premium_Amount__c = 833);
        Id maria = [SELECT Id FROM Contact WHERE FirstName = 'Maria' AND LastName = 'Reyes'].Id;
        Case ownClaim = new Case(RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(), AccountId = auto.Account__c, ContactId = maria,
            Policy__c = auto.Id, Subject = 'Scrape in a parking lot', Status = 'Under Investigation', Date_of_Loss__c = Date.today().addDays(-6), Reported_Date__c = Date.today().addDays(-5),
            Loss_Type__c = 'Collision', Handled_By__c = 'Lydia Osei');
        Case ownRequest = new Case(RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(), AccountId = auto.Account__c, ContactId = maria,
            Policy__c = auto.Id, Subject = 'Add Sofia Reyes as a driver', Request_Type__c = 'Add Driver', Status = 'New');
        Case othersRequest = new Case(RecordTypeId = ownRequest.RecordTypeId, AccountId = [SELECT AccountId FROM Contact WHERE LastName = 'Okafor'].AccountId, Subject = 'Okafor mailing address', Status = 'New');
        List<Case> cases = new List<Case>{ ownClaim, ownRequest, othersRequest };
        insert as system cases;

        // Claude names blocks and records. Beside what it may show, this answer tries another household's records, a block the
        // site does not draw, and figures of its own; and it names a fourth good block, one more than an answer may hold.
        Map<String, Object> first = new Map<String, Object>{
            'reply' => 'Which **bill** do you mean?',
            'blocks' => new List<Object>{
                block('choices', '', new List<Object>{ option(auto.Id, 'Auto, only $99 a year'), option(others, 'Their home'), option('', 'Something else'), option('', 'The $5 plan'), option(auto.Id, 'Auto again') }, ''),
                block('price', others, null, ''),
                block('price', auto.Id, null, 'It went up by $400 because of a rate change.'),
                block('video', auto.Id, null, ''),
                block('claim', othersClaim, null, ''),
                block('claim', ownClaim.Id, null, ''),
                block('policies', '', null, '')
            },
            'actions' => new List<Object>(),
            'suggestions' => new List<Object>()
        };
        Map<String, Object> second = new Map<String, Object>{
            'reply' => 'Here is what I can see. It is all on your record. A third sentence is one too many.',
            'blocks' => new List<Object>{
                block('note', othersRequest.Id, null, ''),
                block('note', ownRequest.Id, null, 'A made up note'),
                block('coverage', auto.Id, new List<Object>{ option('', 'collision'), option('', 'Flood'), option('', 'Roadside Assistance') }, ''),
                block('coverage', auto.Id, null, ''),
                block('text', '', null, 'A **deductible** is what you pay first.\n- It applies to each claim.')
            },
            'actions' => new List<Object>(),
            'suggestions' => new List<Object>()
        };
        Map<String, Object> third = new Map<String, Object>{
            'reply' => 'Here they are.',
            'blocks' => new List<Object>{ block('policies', '', null, ''), block('choices', '', new List<Object>{ option(auto.Id, '') }, ''), block('text', '', null, ' '), block('renewal', others, null, ''), block('renewal', auto.Id, null, '') }
        };

        AntsurancePortalClaude.Reply asked;
        AntsurancePortalClaude.Reply seen;
        AntsurancePortalClaude.Reply listed;
        Test.startTest();
        System.runAs(portalUser('maria')) {
            String conversation = JSON.serialize(new List<Object>{ new Map<String, String>{ 'role' => 'customer', 'text' => 'Why did my bill increase?' } });
            Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(first)));
            asked = AntsurancePortalClaude.ask(conversation, '{"page":"home"}');
            Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(second)));
            seen = AntsurancePortalClaude.ask(conversation, '{"page":"home"}');
            Test.setMock(HttpCalloutMock.class, new Answering(JSON.serialize(third)));
            listed = AntsurancePortalClaude.ask(conversation, '{"page":"home"}');
        }
        Test.stopTest();

        Assert.areEqual('Which bill do you mean?', asked.text, 'The lead is plain text');
        Assert.areEqual(3, asked.blocks.size(), 'Another household\'s blocks and the unknown one are dropped, and an answer holds three at most');

        AntsurancePortalClaude.Block choices = asked.blocks[0];
        Assert.areEqual('choices', choices.type, 'The choices come first, as Claude ordered them');
        Assert.areEqual(2, choices.rows.size(), 'Their own policy and the plain option: not the other household\'s, not one with an amount in it, not the same one twice');
        Assert.areEqual('Auto', choices.rows[0].label, 'A record\'s option is labeled from the record');
        Assert.areEqual('ANT-PA-TEST1', choices.rows[0].tag, 'With its number');
        Assert.areEqual('$2,380 a year, billed monthly', choices.rows[0].sub, 'Its fact is the record\'s figure, not the one Claude wrote');
        Assert.areEqual('My auto policy, ANT-PA-TEST1', choices.rows[0].say, 'Pressing it says which one');
        Assert.areEqual('Something else', choices.rows[1].label, 'An option that is not a record keeps Claude\'s few words');

        AntsurancePortalClaude.Block price = asked.blocks[1];
        Assert.areEqual('price', price.type, 'Then the price of their own policy');
        Assert.areEqual(auto.Id, price.recordId, 'Theirs');
        Assert.areEqual(3, price.rows.size(), 'The price before extras, then each extra');
        Assert.areEqual('$2,534', price.rows[0].figure, 'The base is the yearly price less what the extras add and save');
        Assert.areEqual('-$190', price.rows[1].figure, 'A discount is a signed line');
        Assert.areEqual('minus', price.rows[1].kind, 'Marked as taking from the price');
        Assert.isNull(price.rows[1].sub, 'In place since the term began, so it carries no date');
        Assert.areEqual('+$36', price.rows[2].figure, 'And so is an extra');
        Assert.isTrue(price.rows[2].sub.startsWith('Added '), 'An extra that came after the term began says when it was added');
        Assert.areEqual('$2,380', price.totalText, 'The total is the policy\'s yearly price');
        Assert.areEqual('Each month', price.facts[0].label, 'Billed monthly, so the monthly amount is shown');
        Assert.areEqual('About $198', price.facts[0].figure, 'Worked out from the record');
        Assert.areEqual('Next payment', price.facts[1].label, 'With when the next one falls');
        Assert.isNull(price.text, 'Claude\'s own words are not part of a price');
        Assert.isTrue(price.footnote.contains('Roadside Assistance'), 'What changed the price this term is the extra on record');
        Assert.isFalse((price.footnote + price.summary).contains('rate change'), 'A reason Claude wrote reaches nothing in the block');

        AntsurancePortalClaude.Block claim = asked.blocks[2];
        Assert.areEqual('claim', claim.type, 'Then their own claim');
        Assert.areEqual('Being reviewed', claim.chip, 'Where it stands, in the customer\'s words');
        Assert.areEqual(5, claim.steps.size(), 'With its steps');
        Assert.isNotNull(claim.next, 'And what happens next');
        Assert.areEqual('Lydia Osei', claim.facts[1].figure, 'And who has it');

        Assert.areEqual('Here is what I can see. It is all on your record.', seen.text, 'The lead is two sentences at most');
        Assert.areEqual(3, seen.blocks.size(), 'A note on another household\'s request is dropped, and the same block about the same policy is drawn once');
        AntsurancePortalClaude.Block note = seen.blocks[0];
        Assert.areEqual('note', note.type, 'The note');
        Assert.areEqual('Add Sofia Reyes as a driver', note.title, 'Says what the record says');
        Assert.areEqual('Open request', note.kind, 'It is still open');
        Assert.areEqual('request', note.page, 'And links to the request');
        Assert.isNull(note.text, 'Not what Claude wrote');
        AntsurancePortalClaude.Block coverage = seen.blocks[1];
        Assert.areEqual(2, coverage.rows.size(), 'Only what the policy has: Collision and the extra, not Flood');
        Assert.areEqual('Collision', coverage.rows[0].label, 'By the record\'s own name');
        Assert.areEqual('$500', coverage.rows[0].figure, 'With the deductible from the record');
        Assert.areEqual('deductible', coverage.rows[0].figureSub, 'Said as what it is');
        Assert.areEqual('text', seen.blocks[2].type, 'Words of Claude\'s own go in a text block');
        Assert.isTrue(seen.blocks[2].text.contains('**deductible**') && seen.blocks[2].text.contains('\n- '), 'Which keeps its bold and its list');

        Assert.areEqual(2, listed.blocks.size(), 'One option is not a choice, an empty text is nothing, and another household\'s renewal is dropped');
        AntsurancePortalClaude.Block renewal = listed.blocks[1];
        Assert.areEqual('renewal', renewal.type, 'When their own policy renews');
        Assert.isTrue(renewal.sub.endsWith(String.valueOf(Date.today().addMonths(8).year())), 'The date is the policy\'s own end of term');
        Assert.areEqual('$2,380 a year', renewal.facts[0].figure, 'With this term\'s price');
        Assert.areEqual('No offer yet', renewal.facts[1].figure, 'And it says so when no renewal offer is on record');
        AntsurancePortalClaude.Block policies = listed.blocks[0];
        Assert.areEqual(1, policies.rows.size(), 'Their one policy');
        Assert.areEqual('$2,380', policies.rows[0].figure, 'With its yearly price');
        Assert.areEqual('Billed monthly', policies.rows[0].sub, 'How it is billed');
        Assert.isTrue(policies.rows[0].note.startsWith('Renews '), 'And when it renews');
        Assert.areEqual('policy', policies.rows[0].page, 'A row opens the policy');
        Assert.areEqual('Next payment', policies.facts[0].label, 'Then the next payment due');
        Assert.areEqual('About $198', policies.facts[0].figure, 'From the record');
    }

    // ------------------------------------------------------------------------------- helpers

    private static Map<String, Object> block(String type, String recordId, List<Object> options, String text) {
        return new Map<String, Object>{ 'type' => type, 'record_id' => recordId, 'options' => options == null ? new List<Object>() : options, 'text' => text };
    }

    private static Map<String, Object> option(String recordId, String label) {
        return new Map<String, Object>{ 'record_id' => recordId, 'label' => label };
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

    /** The message a refused call gives, or null when it went through. */
    private static String messageFrom(String what, Id recordId) {
        try {
            if (what == 'policy') {
                AntsurancePortalController.getPolicy(recordId);
            } else if (what == 'claim') {
                AntsurancePortalController.getClaim(recordId);
            } else if (what == 'home') {
                AntsurancePortalController.getHome();
            } else if (what == 'fileClaim') {
                AntsurancePortalController.submitClaim(JSON.serialize(new Map<String, String>{ 'policyId' => recordId, 'dateOfLoss' => String.valueOf(Date.today()), 'whatHappened' => 'x' }));
            } else {
                AntsurancePortalController.submitRequest('request', JSON.serialize(new Map<String, String>{ 'policyId' => recordId, 'details' => 'x' }));
            }
            return null;
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
    }

    private static String messageFromClaim(Map<String, String> fields) {
        try {
            AntsurancePortalController.submitClaim(JSON.serialize(fields));
            return null;
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
    }

    private static User portalUser(String who) {
        return [SELECT Id FROM User WHERE Alias = :who.left(8) AND Username LIKE '%@portal.antsurance.test' LIMIT 1];
    }

    private static User person(String who, Id profileId, Id contactId) {
        return new User(
            ProfileId = profileId,
            ContactId = contactId,
            Username = who + STAMP + '@portal.antsurance.test',
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

    /** Answers the Claude call with a fixed reply and keeps what was sent. */
    private class Answering implements HttpCalloutMock {
        String answerJson;
        String sent;

        Answering(String answerJson) {
            this.answerJson = answerJson;
        }

        public HttpResponse respond(HttpRequest request) {
            sent = request.getBody();
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
