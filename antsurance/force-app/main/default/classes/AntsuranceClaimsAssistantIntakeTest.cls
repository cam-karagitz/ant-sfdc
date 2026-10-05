@IsTest
private class AntsuranceClaimsAssistantIntakeTest {
    private static final String MESSAGE = 'Hi, I was rear-ended at a red light on Saturday. The body shop says about $4,200.';

    /** Answers with one canned response and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status;
        String body;
        HttpRequest request;

        ClaudeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    @TestSetup
    static void createCustomer() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        insert new Contact(AccountId = customer.Id, FirstName = 'Maya', LastName = 'Harbor');
        Date start = Date.today().addDays(-90);
        insert new List<Policy__c>{
            new Policy__c(
                Name = 'T-AUTO-1', Account__c = customer.Id, Line_of_Business__c = 'Personal Auto', Status__c = 'Active',
                Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Insured_Item__c = '2022 Toyota RAV4 and 2019 Honda Accord', Deductible__c = 500
            ),
            new Policy__c(
                Name = 'T-HOME-1', Account__c = customer.Id, Line_of_Business__c = 'Homeowners', Status__c = 'Lapsed',
                Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Insured_Item__c = '12 Quay St, Evanston, IL'
            ),
            new Policy__c(Name = 'T-QUOTE-1', Account__c = customer.Id, Line_of_Business__c = 'Renters', Status__c = 'Quoted')
        };
    }

    private static Account customer() {
        return [SELECT Id FROM Account WHERE Name = 'Harbor Household'];
    }

    private static Policy__c policy(String policyNumber) {
        return [SELECT Id FROM Policy__c WHERE Name = :policyNumber];
    }

    /** A Messages API reply whose text is the given answer as JSON. */
    private static String reply(Map<String, Object> answer) {
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    private static Map<String, Object> claimAnswer() {
        return new Map<String, Object>{
            'is_claim' => true,
            'not_claim_reason' => '',
            'policy_reason' => 'The RAV4 is on the auto policy.',
            'policy_number' => 'T-AUTO-1',
            'date_of_loss' => String.valueOf(Date.today().addDays(-3)),
            'loss_type' => 'Collision',
            'loss_location' => 'Ogden Ave and Washington St, Naperville, IL',
            'estimated_loss' => 4200,
            'severity' => 'Low',
            'subject' => 'Rear-ended at a red light',
            'description' => 'Maya Harbor was rear-ended while stopped at a red light.',
            'reported_by' => 'Maya Harbor',
            'origin' => 'Email',
            'missing' => new List<Object>{ 'What is the other driver\'s name?' },
            'watch' => new List<Object>{ 'The other driver admitted fault.' }
        };
    }

    private static String failureOfRead(Id recordId, String message) {
        try {
            AntsuranceClaimsAssistantIntake.readMessage(recordId, message);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String failureOfCreate(String claimJson) {
        try {
            AntsuranceClaimsAssistantIntake.createClaim(claimJson);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void theFormLoadsTheCustomersPoliciesContactsAndSamples() {
        Test.startTest();
        AntsuranceClaimsAssistantIntake.IntakeContext context = AntsuranceClaimsAssistantIntake.getContext(customer().Id);
        Test.stopTest();

        Assert.areEqual('Harbor Household', context.customerName, 'The customer is named');
        Assert.isNull(context.fromPolicyId, 'Opened from a customer, no policy is preselected');
        Assert.areEqual(2, context.policies.size(), 'A quoted policy cannot take a claim, so it is left out');
        Assert.areEqual(1, context.contacts.size(), 'The customer\'s contacts are offered');
        Assert.isTrue(context.lossTypes.contains('Water Damage'), 'Loss types come from the org\'s picklist');
        Assert.isTrue(context.severities.contains('Catastrophic'), 'Severities come from the org\'s picklist');
        Assert.isTrue(context.origins.contains('Email'), 'Origins come from the org\'s picklist');

        Map<String, AntsuranceClaimsAssistantIntake.Sample> samples = new Map<String, AntsuranceClaimsAssistantIntake.Sample>();
        for (AntsuranceClaimsAssistantIntake.Sample sample : context.samples) {
            samples.put(sample.key, sample);
        }
        Assert.areEqual(new Set<String>{ 'auto-email', 'home-web', 'auto-call', 'not-a-claim' }, samples.keySet(), 'Samples fit the lines this customer holds');
        Assert.isTrue(samples.get('auto-email').text.contains('2022 Toyota RAV4'), 'The auto sample names the customer\'s own vehicle');
        Assert.isFalse(samples.get('auto-email').text.contains('Honda Accord'), 'Only the first vehicle is named');
        Assert.isTrue(samples.get('home-web').text.contains('12 Quay St'), 'The home sample uses the customer\'s address');
        Assert.isTrue(samples.get('auto-email').text.contains('Maya Harbor'), 'Samples are signed by the customer\'s contact');
    }

    @IsTest
    static void openedFromAPolicyThatPolicyIsRememberedAndItsSampleComesFirst() {
        Id homeId = policy('T-HOME-1').Id;

        Test.startTest();
        AntsuranceClaimsAssistantIntake.IntakeContext context = AntsuranceClaimsAssistantIntake.getContext(homeId);
        Test.stopTest();

        Assert.areEqual(homeId, context.fromPolicyId, 'The policy the form was opened from is kept');
        Assert.areEqual(customer().Id, context.accountId, 'The customer is found from the policy');
        Assert.areEqual('home-web', context.samples[0].key, 'The first sample fits that policy');
    }

    @IsTest
    static void otherRecordsAreTurnedAway() {
        Contact person = [SELECT Id FROM Contact LIMIT 1];
        try {
            AntsuranceClaimsAssistantIntake.getContext(person.Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceClaimsAssistantIntake.WRONG_RECORD, e.getMessage(), 'Only customers and policies are accepted');
        }
    }

    @IsTest
    static void claudesReadingBecomesADraftClaim() {
        ClaudeMock mock = new ClaudeMock(200, reply(claimAnswer()));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantIntake.Draft draft = AntsuranceClaimsAssistantIntake.readMessage(customer().Id, MESSAGE);
        Test.stopTest();

        Assert.isTrue(draft.isClaim, 'The message is a claim');
        Assert.areEqual(policy('T-AUTO-1').Id, draft.policyId, 'The policy number Claude chose is matched to the policy');
        Assert.areEqual('The RAV4 is on the auto policy.', draft.policyReason, 'The reason is kept');
        Assert.areEqual(Date.today().addDays(-3), draft.dateOfLoss, 'The date is parsed');
        Assert.areEqual('Collision', draft.lossType, 'The loss type is kept');
        Assert.areEqual('Low', draft.severity, 'The severity is kept');
        Assert.areEqual(4200, draft.estimatedLoss, 'The estimate is kept');
        Assert.areEqual('Rear-ended at a red light', draft.subject, 'The subject is kept');
        Assert.areEqual([SELECT Id FROM Contact].Id, draft.contactId, 'The reporter is matched to the contact');
        Assert.areEqual('Email', draft.origin, 'The origin is kept');
        Assert.areEqual(1, draft.missing.size(), 'Questions for the customer are kept');
        Assert.areEqual(1, draft.watch.size(), 'Things to notice are kept');

        String sent = mock.request.getBody();
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(sent);
        String prompt = (String) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        Assert.isTrue(prompt.contains('Today is '), 'Claude is told today\'s date so it can work out relative dates');
        Assert.isTrue(prompt.contains('T-AUTO-1 | Personal Auto | Active'), 'Each policy is described');
        Assert.isTrue(prompt.contains('insures 2022 Toyota RAV4 and 2019 Honda Accord'), 'With what it insures');
        Assert.isTrue(prompt.contains('Contacts: Maya Harbor'), 'The contacts are listed');
        Assert.isTrue(prompt.contains('<message>\n' + MESSAGE + '\n</message>'), 'The message is passed whole');
        Assert.isFalse(prompt.contains('The handler opened this from policy'), 'No policy is favored when opened from the customer');

        Map<String, Object> schema = (Map<String, Object>) ((Map<String, Object>) ((Map<String, Object>) body.get('output_config')).get('format')).get('schema');
        Map<String, Object> properties = (Map<String, Object>) schema.get('properties');
        Assert.areEqual(
            new List<Object>{ '', 'T-AUTO-1', 'T-HOME-1' },
            (List<Object>) ((Map<String, Object>) properties.get('policy_number')).get('enum'),
            'Claude can only choose one of this customer\'s policies, or none'
        );
        Assert.isTrue(
            ((List<Object>) ((Map<String, Object>) properties.get('loss_type')).get('enum')).contains('Wind or Hail'),
            'Loss types are limited to the org\'s values'
        );
        Assert.isTrue(sent.indexOf('"is_claim":{') < sent.indexOf('"policy_number":{'), 'Claude decides whether it is a claim before anything else');
    }

    @IsTest
    static void openedFromAPolicyClaudeIsToldToFavorIt() {
        ClaudeMock mock = new ClaudeMock(200, reply(claimAnswer()));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceClaimsAssistantIntake.readMessage(policy('T-AUTO-1').Id, MESSAGE);
        Test.stopTest();

        Assert.isTrue(mock.request.getBody().contains('The handler opened this from policy T-AUTO-1'), 'The prompt names the policy the form was opened from');
    }

    @IsTest
    static void aMessageThatIsNotAClaimComesBackWithTheReason() {
        Map<String, Object> answer = claimAnswer();
        answer.put('is_claim', false);
        answer.put('not_claim_reason', 'This is a billing question. Open a service request instead.');
        answer.put('policy_number', '');
        answer.put('date_of_loss', 'unknown');
        answer.put('estimated_loss', null);
        answer.put('reported_by', '');
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(200, reply(answer)));

        Test.startTest();
        AntsuranceClaimsAssistantIntake.Draft draft = AntsuranceClaimsAssistantIntake.readMessage(customer().Id, 'My payment went up by $14 this month. Why?');
        Test.stopTest();

        Assert.isFalse(draft.isClaim, 'The message is not a claim');
        Assert.areEqual('This is a billing question. Open a service request instead.', draft.notClaimReason, 'The reason is passed on');
        Assert.isNull(draft.policyId, 'No policy is chosen');
        Assert.isNull(draft.dateOfLoss, 'A date that cannot be parsed is left empty');
        Assert.isNull(draft.estimatedLoss, 'No figure is left empty');
        Assert.isNull(draft.contactId, 'No reporter is left empty');
    }

    @IsTest
    static void aMessageHasToBeWorthReading() {
        Id customerId = customer().Id;
        Assert.areEqual(AntsuranceClaimsAssistantIntake.TOO_SHORT, failureOfRead(customerId, '  hi  '), 'A few characters are not a message');
        Assert.areEqual(AntsuranceClaimsAssistantIntake.TOO_SHORT, failureOfRead(customerId, null), 'Nor is nothing');
        Assert.areEqual(AntsuranceClaimsAssistantIntake.TOO_LONG, failureOfRead(customerId, 'x'.repeat(12001)), 'There is an upper limit');

        Account empty = new Account(Name = 'No Policies Household');
        insert empty;
        Assert.areEqual(AntsuranceClaimsAssistantIntake.NO_POLICIES, failureOfRead(empty.Id, MESSAGE), 'A customer with no policies cannot have a claim');
    }

    @IsTest
    static void anApiFailureIsShownToTheHandler() {
        Test.setMock(HttpCalloutMock.class, new ClaudeMock(529, '{"error":{"message":"Overloaded"}}'));

        Test.startTest();
        String message = failureOfRead(customer().Id, MESSAGE);
        Test.stopTest();

        Assert.isTrue(message.startsWith('Claude is temporarily unavailable.'), 'The failure is explained: ' + message);
    }

    @IsTest
    static void theReviewedClaimIsOpenedWithTheCustomersWordsOnFile() {
        Id customerId = customer().Id;
        Id policyId = policy('T-AUTO-1').Id;
        Id contactId = [SELECT Id FROM Contact].Id;
        Map<String, Object> input = new Map<String, Object>{
            'accountId' => customerId,
            'policyId' => policyId,
            'contactId' => contactId,
            'dateOfLoss' => String.valueOf(Date.today().addDays(-3)),
            'lossType' => 'Collision',
            'severity' => 'High',
            'lossLocation' => 'Ogden Ave and Washington St, Naperville, IL',
            'estimatedLoss' => 4200.50,
            'subject' => '  Rear-ended at a red light  ',
            'description' => 'Maya Harbor was rear-ended.',
            'origin' => 'Email',
            'message' => 'Hi,\nI was rear-ended.',
            'missing' => new List<String>{ 'What is the other driver\'s name?' }
        };

        Test.startTest();
        AntsuranceClaimsAssistantIntake.CreatedClaim created = AntsuranceClaimsAssistantIntake.createClaim(JSON.serialize(input));
        Test.stopTest();

        Case claim = [
            SELECT CaseNumber, RecordType.DeveloperName, AccountId, ContactId, Policy__c, Subject, Description, Date_of_Loss__c, Reported_Date__c,
                Loss_Type__c, Severity__c, Loss_Location__c, Estimated_Loss__c, Origin, Status, Priority, Coverage_Check__c
            FROM Case
            WHERE Id = :created.caseId
        ];
        Assert.areEqual('Claim', claim.RecordType.DeveloperName, 'It is a claim');
        Assert.areEqual(claim.CaseNumber, created.caseNumber, 'The claim number is returned');
        Assert.areEqual(customerId, claim.AccountId, 'On the customer');
        Assert.areEqual(policyId, claim.Policy__c, 'Under the chosen policy');
        Assert.areEqual(contactId, claim.ContactId, 'Reported by the chosen contact');
        Assert.areEqual('Rear-ended at a red light', claim.Subject, 'The subject is trimmed');
        Assert.areEqual(Date.today().addDays(-3), claim.Date_of_Loss__c, 'The date of loss is saved');
        Assert.areEqual(Date.today(), claim.Reported_Date__c, 'It is reported today');
        Assert.areEqual(4200.50, claim.Estimated_Loss__c, 'The estimate is saved');
        Assert.areEqual('Email', claim.Origin, 'The origin is saved');
        Assert.areEqual('New', claim.Status, 'It starts as new');
        // The claim automation ran because the claim was inserted the normal way.
        Assert.areEqual('High', claim.Priority, 'The automation set the priority from the severity');
        Assert.areEqual('In force on date of loss', claim.Coverage_Check__c, 'The automation checked the policy against the date of loss');
        Assert.areEqual(claim.Coverage_Check__c, created.coverageCheck, 'The coverage check is returned for the confirmation');

        File_Note__c note = [SELECT Note_Type__c, Body__c, Policy__c, Account__c FROM File_Note__c WHERE Case__c = :created.caseId];
        Assert.areEqual('Contact', note.Note_Type__c, 'The first notice is a contact note');
        Assert.isTrue(note.Body__c.startsWith('**First notice:** Filed from the customer\'s email'), 'It says how the notice arrived: ' + note.Body__c);
        Assert.isTrue(note.Body__c.contains('> Hi,\n> I was rear-ended.'), 'The customer\'s words are quoted line by line');
        Assert.isTrue(note.Body__c.contains('**Still to ask:**\n- What is the other driver\'s name?'), 'The open questions are listed');
        Assert.areEqual(policyId, note.Policy__c, 'The note also sits on the policy');
    }

    @IsTest
    static void aClaimNeedsAPolicyOfThisCustomerAndASubject() {
        Id customerId = customer().Id;
        Account other = new Account(Name = 'Other Household');
        insert other;
        Policy__c othersPolicy = new Policy__c(Name = 'T-OTHER-1', Account__c = other.Id, Status__c = 'Active');
        insert othersPolicy;

        Assert.areEqual(AntsuranceClaimsAssistantIntake.INVALID_CLAIM, failureOfCreate('not json'), 'Unreadable input is refused');
        Assert.areEqual(AntsuranceClaimsAssistantIntake.INVALID_CLAIM, failureOfCreate('{"subject":"x"}'), 'A claim needs a customer');
        Assert.areEqual(
            AntsuranceClaimsAssistantIntake.NEEDS_POLICY,
            failureOfCreate(JSON.serialize(new Map<String, Object>{ 'accountId' => customerId, 'subject' => 'x' })),
            'A claim needs a policy'
        );
        Assert.areEqual(
            AntsuranceClaimsAssistantIntake.NEEDS_SUBJECT,
            failureOfCreate(JSON.serialize(new Map<String, Object>{ 'accountId' => customerId, 'policyId' => policy('T-AUTO-1').Id, 'subject' => ' ' })),
            'A claim needs a subject'
        );
        Assert.areEqual(
            AntsuranceClaimsAssistantIntake.WRONG_POLICY,
            failureOfCreate(JSON.serialize(new Map<String, Object>{ 'accountId' => customerId, 'policyId' => othersPolicy.Id, 'subject' => 'x' })),
            'The policy has to belong to the customer'
        );
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Nothing was created');
    }

    @IsTest
    static void aClaimWithNoMessageGetsNoFirstNotice() {
        Map<String, Object> input = new Map<String, Object>{
            'accountId' => customer().Id,
            'policyId' => policy('T-HOME-1').Id,
            'subject' => 'Kitchen fire',
            'lossType' => 'Fire',
            'severity' => 'Medium',
            'dateOfLoss' => String.valueOf(Date.today().addDays(-1))
        };

        Test.startTest();
        AntsuranceClaimsAssistantIntake.CreatedClaim created = AntsuranceClaimsAssistantIntake.createClaim(JSON.serialize(input));
        Test.stopTest();

        Assert.areEqual('Policy not in force', created.coverageCheck, 'A lapsed policy is flagged by the automation');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c WHERE Case__c = :created.caseId], 'No note is written without a message');
    }
}
