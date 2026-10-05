@IsTest
private class AntsuranceDocumentCertificateTest {
    private static Policy__c policy(Account customer, String name, String line, String status) {
        Date start = Date.newInstance(2026, 6, 1);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Line_of_Business__c = line, Status__c = status, Effective_Date__c = start,
            Expiration_Date__c = start.addYears(1), Annual_Premium__c = 10000
        );
    }

    @TestSetup
    static void createCustomer() {
        Id businessType = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Business').getRecordTypeId();
        Account roofer = new Account(
            Name = 'Ridgeline Roofing & Solar', RecordTypeId = businessType, BillingStreet = '480 Industrial Pkwy', BillingCity = 'Aurora', BillingPostalCode = '60506'
        );
        AntsuranceAddress.put(roofer, 'Billing', 'IL', 'US');
        Account bistro = new Account(Name = 'Halsted Street Bistro', RecordTypeId = businessType);
        Account agency = new Account(Name = 'Lakefront Brokerage Partners', Phone = '(312) 555-0188', BillingCity = 'Chicago');
        AntsuranceAddress.put(agency, 'Billing', 'IL', 'US');
        insert new List<Account>{ roofer, bistro, agency };

        Policy__c workers = policy(roofer, 'ANT-WC-3', 'Workers Compensation', 'Active');
        Policy__c liability = policy(roofer, 'ANT-GL-1', 'General Liability', 'Active');
        liability.Producer__c = agency.Id;
        liability.Insured_Item__c = 'Roofing and solar installation contractor';
        Policy__c fleet = policy(roofer, 'ANT-CA-2', 'Commercial Auto', 'Pending Renewal');
        Policy__c lapsed = policy(roofer, 'ANT-UM-4', 'Umbrella', 'Lapsed');
        Policy__c property = policy(roofer, 'ANT-CP-5', 'Commercial Property', 'Active');
        Policy__c direct = policy(bistro, 'ANT-GL-6', 'General Liability', 'Active');
        Policy__c propertyOnly = policy(agency, 'ANT-CP-7', 'Commercial Property', 'Active');
        insert new List<Policy__c>{ workers, liability, fleet, lapsed, property, direct, propertyOnly };

        insert new List<Policy_Coverage__c>{
            new Policy_Coverage__c(Policy__c = liability.Id, Name = 'Each Occurrence', Category__c = 'Liability', Limit_Amount__c = 2000000, Limit_Type__c = 'Per Occurrence'),
            new Policy_Coverage__c(Policy__c = liability.Id, Name = 'Products and Completed Operations', Category__c = 'Liability', Limit_Amount__c = 4000000, Limit_Type__c = 'Aggregate'),
            new Policy_Coverage__c(Policy__c = liability.Id, Name = 'Dropped', Category__c = 'Liability', Limit_Amount__c = 1, Status__c = 'Removed'),
            new Policy_Coverage__c(Policy__c = fleet.Id, Name = 'Combined Single Limit Liability', Category__c = 'Liability', Limit_Amount__c = 1000000),
            new Policy_Coverage__c(Policy__c = fleet.Id, Name = 'Collision', Category__c = 'Collision', Deductible_Amount__c = 2000),
            new Policy_Coverage__c(Policy__c = workers.Id, Name = 'Workers Compensation (statutory)', Category__c = 'Workers Compensation', Limit_Type__c = 'Statutory'),
            new Policy_Coverage__c(Policy__c = workers.Id, Name = 'Employers Liability', Category__c = 'Liability', Limit_Amount__c = 1000000, Limit_Type__c = 'Per Occurrence')
        };
    }

    private static AntsuranceDocumentCertificateController open(String recordId, Map<String, String> more) {
        PageReference page = Page.AntsuranceDocumentCertificate;
        if (recordId != null) {
            page.getParameters().put('id', recordId);
        }
        page.getParameters().putAll(more);
        Test.setCurrentPage(page);
        return new AntsuranceDocumentCertificateController();
    }

    @IsTest
    static void aCertificateListsEveryLiabilityPolicyInForce() {
        Policy__c fleet = [SELECT Id FROM Policy__c WHERE Name = 'ANT-CA-2'];

        Test.startTest();
        AntsuranceDocumentCertificateController page = open(
            fleet.Id,
            new Map<String, String>{ 'holder' => ' City of  Naperville ', 'holderAddress' => 'Department of Public Works, 400 S Eagle St, Naperville, IL 60540' }
        );
        Test.stopTest();

        Assert.isTrue(page.found, 'The customer has a certificate');
        Assert.areEqual('Ridgeline Roofing & Solar', page.insuredName, 'The insured is the customer, whichever policy it was opened from');
        Assert.areEqual(new List<String>{ '480 Industrial Pkwy', 'Aurora, IL 60506' }, page.insuredLines, 'With its address');
        Assert.areEqual('Lakefront Brokerage Partners', page.producerName, 'The producer is the agency');
        Assert.areEqual(new List<String>{ 'Chicago, IL', '(312) 555-0188' }, page.producerLines, 'With where it is and its phone');
        Assert.isTrue(page.certificateNumber.startsWith('COI-1-'), 'Numbered from the first policy and the day of issue');
        Assert.areEqual('Roofing and solar installation contractor', page.operations, 'Operations as the liability policy describes them');

        Assert.areEqual(3, page.policies.size(), 'Lapsed policies and property policies are left out');
        Assert.areEqual('Commercial general liability', page.policies[0].insuranceType, 'General liability first');
        Assert.areEqual('ANT-GL-1', page.policies[0].policyNumber, 'With its number');
        Assert.areEqual('Jun 1, 2026 to Jun 1, 2027', page.policies[0].period, 'And period');
        Assert.areEqual(2, page.policies[0].limits.size(), 'Removed coverages are left out');
        Assert.areEqual('$2,000,000', page.policies[0].limits[0].amount, 'A limit in dollars');
        Assert.areEqual('Each occurrence', page.policies[0].limits[0].basis, 'With how it applies');
        Assert.areEqual('Aggregate', page.policies[0].limits[1].basis, 'An aggregate limit says so');
        Assert.areEqual('Business auto liability', page.policies[1].insuranceType, 'Then auto');
        Assert.areEqual(1, page.policies[1].limits.size(), 'Cover for the insured\'s own vehicles is not liability');
        Assert.areEqual('', page.policies[1].limits[0].basis, 'A limit with no basis recorded leaves it blank');
        Assert.areEqual('Workers compensation and employers liability', page.policies[2].insuranceType, 'Then workers compensation');
        Assert.areEqual('Workers Compensation', page.policies[2].limits[0].label, 'Named without the bracket');
        Assert.areEqual('Statutory', page.policies[2].limits[0].amount, 'Its limit is statutory');
        Assert.areEqual('As state law requires', page.policies[2].limits[0].basis, 'Which is explained');
        Assert.areEqual('policy', page.policies[2].blockClass, 'Three policies fit one page');
        Assert.areEqual('ending', page.endingClass, 'With the holder and signature under them');

        Assert.areEqual('City of Naperville', page.holderName, 'The holder is the one passed in, tidied');
        Assert.areEqual(new List<String>{ 'Department of Public Works', '400 S Eagle St, Naperville, IL 60540' }, page.holderLines, 'A long address breaks at its first comma');
        Assert.isFalse(page.statementLines.isEmpty() || page.cancellationLines.isEmpty(), 'The wording is laid out in lines');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('inline; filename=Certificate-Ridgeline-Roofing-Solar.pdf'), 'Named for the customer');
    }

    @IsTest
    static void withoutAHolderItIsMadeOutForInformation() {
        Account bistro = [SELECT Id FROM Account WHERE Name = 'Halsted Street Bistro'];

        Test.startTest();
        AntsuranceDocumentCertificateController page = open(bistro.Id, new Map<String, String>{ 'download' => '1' });
        AntsuranceDocumentCertificateController named = open(bistro.Id, new Map<String, String>{ 'holder' => 'Lakeview Chamber', 'holderAddress' => '3355 N Clark St' });
        Test.stopTest();

        Assert.isTrue(page.found, 'A customer account opens its certificate directly');
        Assert.areEqual('To whom it may concern', page.holderName, 'The default holder');
        Assert.areEqual(new List<String>{ 'Issued for information only' }, page.holderLines, 'With what the certificate is for');
        Assert.areEqual('Antsurance Direct', page.producerName, 'No producer means direct business');
        Assert.areEqual('All operations of the insured', page.operations, 'With no description, all operations');
        Assert.isTrue(page.insuredLines.isEmpty(), 'An insured without an address prints none');
        Assert.areEqual(new List<String>{ '3355 N Clark St' }, named.holderLines, 'A short address stays on one line');
    }

    @IsTest
    static void manyPoliciesRunOnToASecondPage() {
        Account roofer = [SELECT Id FROM Account WHERE Name = 'Ridgeline Roofing & Solar'];
        List<Policy__c> more = new List<Policy__c>();
        for (Integer index = 0; index < 12; index++) {
            more.add(policy(roofer, 'ANT-UM-9' + index, 'Umbrella', 'Active'));
        }
        insert more;
        List<Policy_Coverage__c> limits = new List<Policy_Coverage__c>();
        for (Policy__c umbrella : more) {
            limits.add(new Policy_Coverage__c(Policy__c = umbrella.Id, Name = 'Excess Liability', Category__c = 'Liability', Limit_Amount__c = 5000000, Limit_Type__c = 'Per Occurrence'));
        }
        insert limits;

        Test.startTest();
        AntsuranceDocumentCertificateController page = open(roofer.Id, new Map<String, String>());
        Test.stopTest();

        Integer onNewPage = 0;
        for (AntsuranceDocumentCertificateController.PolicyBlock block : page.policies) {
            onNewPage += block.blockClass == 'policy new-page' ? 1 : 0;
        }
        Assert.areEqual(15, page.policies.size(), 'Every policy in force is listed');
        Assert.areEqual(1, onNewPage, 'And one of them starts the second page');
    }

    @IsTest
    static void customersWithNothingToCertifyGetANotice() {
        Account agency = [SELECT Id FROM Account WHERE Name = 'Lakefront Brokerage Partners'];
        Account roofer = [SELECT Id FROM Account WHERE Name = 'Ridgeline Roofing & Solar'];
        Contact someone = new Contact(LastName = 'Raman', AccountId = agency.Id);
        insert someone;

        Test.startTest();
        AntsuranceDocumentCertificateController propertyOnly = open(agency.Id, new Map<String, String>());
        AntsuranceDocumentCertificateController withoutId = open(null, new Map<String, String>());
        AntsuranceDocumentCertificateController withNonsense = open('not-an-id', new Map<String, String>());
        AntsuranceDocumentCertificateController withAnotherObject = open(someone.Id, new Map<String, String>());
        Test.stopTest();

        Assert.isFalse(propertyOnly.found, 'Property cover alone is not certified');
        Assert.areEqual('This customer has no liability policy in force to certify.', propertyOnly.notice, 'And the page says why');
        Assert.isFalse(withoutId.found || withNonsense.found || withAnotherObject.found, 'A missing, malformed or wrong id finds nothing');
        Assert.areEqual('This customer could not be found.', withoutId.notice, 'And says so');
        Assert.isTrue(AntsuranceDocumentCertificateController.isAvailableFor(roofer.Id), 'A customer with liability cover can have a certificate');
        Assert.isFalse(AntsuranceDocumentCertificateController.isAvailableFor(agency.Id), 'One without cannot');
        Assert.isFalse(AntsuranceDocumentCertificateController.isAvailableFor(null), 'Nor can no customer at all');
    }
}
