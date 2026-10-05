@IsTest
private class AntsuranceRenewalOutreachControllerTest {
    /** Answers the draft request with a canned draft and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status = 200;
        HttpRequest request;

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            String draft = JSON.serialize(
                new Map<String, Object>{
                    'risk' => 'Medium',
                    'riskReason' => 'A 5 percent increase after a paid claim.',
                    'points' => new List<Object>{ new Map<String, Object>{ 'label' => 'Premium change', 'detail' => 'Up $135 to $2,810.' } },
                    'subject' => 'Your home insurance renews Oct 29',
                    'body' => 'Hi Hana,\n\nYour policy renews soon.\n\nJordan\nAntsurance',
                    'callOpening' => 'Hi Hana, I am calling about your renewal.'
                }
            );
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'model' => 'claude-opus-5-5',
                        'stop_reason' => 'end_turn',
                        'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => draft } }
                    }
                )
            );
            return response;
        }
    }

    /** A homeowners policy with its renewal sale and one quoted option. */
    private static Policy__c createPolicy(String status) {
        Account household = new Account(Name = 'Harrow Household', Customer_Segment__c = 'Personal Lines');
        insert household;
        Contact insured = new Contact(FirstName = 'Hana', LastName = 'Harrow', AccountId = household.Id, Email = 'hana@example.com', Preferred_Contact_Method__c = 'Email');
        insert insured;
        Policy__c policy = new Policy__c(
            Name = 'ANT-HO-HARROW', Account__c = household.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = 'Homeowners', Status__c = status,
            Effective_Date__c = Date.today().addDays(-340), Expiration_Date__c = Date.today().addDays(25), Annual_Premium__c = 2675, Coverage_Limit__c = 520000,
            Deductible__c = 1500, Insured_Item__c = '12 Elm St, Naperville, IL', Billing_Frequency__c = 'Annual', Payment_Status__c = 'Paid in Full'
        );
        insert policy;
        insert new Policy_Coverage__c(Policy__c = policy.Id, Name = 'Dwelling', Category__c = 'Dwelling', Premium_Amount__c = 2675, Status__c = 'Active');
        Opportunity sale = new Opportunity(
            Name = 'Harrow Household - Homeowners renewal', AccountId = household.Id, Policy__c = policy.Id, Type = 'Renewal', StageName = 'Quote Issued',
            Amount = 2810, CloseDate = Date.today().addDays(20), Line_of_Business__c = 'Homeowners',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId()
        );
        insert sale;
        insert new Quote(Name = 'Higher deductible, lower premium', OpportunityId = sale.Id, Status = 'Issued', Annual_Premium__c = 2590, Deductible__c = 3000);
        return policy;
    }

    @IsTest
    static void aPolicyPendingRenewalShowsItsRenewal() {
        Policy__c policy = createPolicy('Pending Renewal');

        AntsuranceRenewalOutreachController.Renewal renewal = AntsuranceRenewalOutreachController.getRenewal(policy.Id);

        Assert.isTrue(renewal.isRenewing, 'The policy is waiting on its renewal');
        Assert.areEqual(2675, renewal.currentPremium, 'With what it costs now');
        Assert.areEqual(2810, renewal.renewalPremium, 'And what the renewal costs');
        Assert.areEqual('Hana Harrow', renewal.insuredName, 'Who to contact');
        Assert.areEqual('Email', renewal.preferredContact, 'And how they like to be reached');
    }

    @IsTest
    static void anActivePolicyIsNotRenewing() {
        Policy__c policy = createPolicy('Active');

        Assert.isFalse(AntsuranceRenewalOutreachController.getRenewal(policy.Id).isRenewing, 'An active policy shows no renewal card');
        try {
            AntsuranceRenewalOutreachController.draft(policy.Id);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not waiting'), 'And no draft is written for it');
        }
    }

    @IsTest
    static void theDraftIsWrittenFromThePolicyTheRenewalAndTheOptions() {
        Policy__c policy = createPolicy('Pending Renewal');
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceRenewalOutreachController.Outreach outreach = AntsuranceRenewalOutreachController.draft(policy.Id);
        Test.stopTest();

        Assert.areEqual('Medium', outreach.risk, 'The draft carries the retention risk');
        Assert.areEqual('Your home insurance renews Oct 29', outreach.subject, 'An email subject');
        Assert.isTrue(outreach.body.startsWith('Hi Hana'), 'An email body');
        Assert.areEqual('Premium change', outreach.points[0].label, 'And what to know first');
        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('ANT-HO-HARROW'), 'Claude is given the policy');
        Assert.isTrue(sent.contains('$2,810'), 'The renewal premium');
        Assert.isTrue(sent.contains('Higher deductible, lower premium'), 'And the options quoted');
    }

    @IsTest
    static void aFailedDraftIsReportedPlainly() {
        Policy__c policy = createPolicy('Pending Renewal');
        ClaudeMock mock = new ClaudeMock();
        mock.status = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            AntsuranceRenewalOutreachController.draft(policy.Id);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'The card gets a message it can show');
        }
        Test.stopTest();
    }
}
