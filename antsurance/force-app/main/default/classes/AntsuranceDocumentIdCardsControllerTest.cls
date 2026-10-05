@IsTest
private class AntsuranceDocumentIdCardsControllerTest {
    private static Policy__c policy(Account customer, Contact insured, String name, String line) {
        Date start = Date.newInstance(2026, 5, 13);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = line, Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Annual_Premium__c = 2380
        );
    }

    @TestSetup
    static void createPolicies() {
        Account household = new Account(Name = 'Reyes Household', BillingStreet = '524 W Spring Ave', BillingCity = 'Naperville', BillingPostalCode = '60540');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        Account agency = new Account(Name = 'Prairie State Insurance Agency', Phone = '(217) 555-0142');
        Account business = new Account(
            Name = 'Sagebrush Freight Lines',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Business').getRecordTypeId()
        );
        AntsuranceAddress.put(business, 'Billing', 'WI', 'US');
        insert new List<Account>{ household, agency, business };
        Contact maria = new Contact(FirstName = 'Maria', LastName = 'Reyes', AccountId = household.Id);
        Contact daniel = new Contact(FirstName = 'Daniel', LastName = 'Reyes', AccountId = household.Id);
        Contact lena = new Contact(FirstName = 'Lena', LastName = 'Fischer', AccountId = business.Id);
        insert new List<Contact>{ maria, daniel, lena };

        Policy__c auto = policy(household, maria, 'ANT-PA-1', 'Personal Auto');
        auto.Producer__c = agency.Id;
        Policy__c fleet = policy(business, lena, 'ANT-CA-2', 'Commercial Auto');
        Policy__c home = policy(household, maria, 'ANT-HO-3', 'Homeowners');
        Policy__c empty = policy(household, maria, 'ANT-PA-4', 'Personal Auto');
        insert new List<Policy__c>{ auto, fleet, home, empty };

        insert new List<Policy_Asset__c>{
            new Policy_Asset__c(Policy__c = auto.Id, Name = '2022 Toyota RAV4', Asset_Type__c = 'Vehicle', Identifier__c = '2T3P1RFV8NC123456'),
            new Policy_Asset__c(Policy__c = auto.Id, Name = '2019 Honda Accord', Asset_Type__c = 'Vehicle', Identifier__c = '1HGBW40G4K5395405'),
            new Policy_Asset__c(Policy__c = fleet.Id, Name = 'Fleet of 46 tractors and 71 trailers', Asset_Type__c = 'Fleet', Identifier__c = 'SCHEDULE ON FILE'),
            new Policy_Asset__c(Policy__c = fleet.Id, Name = 'Terminal building', Asset_Type__c = 'Commercial Building')
        };
        insert new List<Policy_Participant__c>{
            new Policy_Participant__c(Policy__c = auto.Id, Name = 'Maria Reyes, Named Insured', Contact__c = maria.Id, Role__c = 'Named Insured', Is_Primary__c = true),
            new Policy_Participant__c(Policy__c = auto.Id, Name = 'Daniel Reyes, Named Insured', Contact__c = daniel.Id, Role__c = 'Named Insured'),
            new Policy_Participant__c(Policy__c = auto.Id, Name = 'Daniel Reyes, Driver', Contact__c = daniel.Id, Role__c = 'Driver')
        };
        insert new List<Policy_Coverage__c>{
            new Policy_Coverage__c(Policy__c = auto.Id, Name = 'Bodily Injury Liability', Category__c = 'Liability', Limit_Amount__c = 300000, Limit_Type__c = 'Per Person'),
            new Policy_Coverage__c(Policy__c = auto.Id, Name = 'Collision', Category__c = 'Collision', Deductible_Amount__c = 500),
            new Policy_Coverage__c(Policy__c = auto.Id, Name = 'Roadside', Category__c = 'Other'),
            new Policy_Coverage__c(Policy__c = auto.Id, Name = 'Dropped', Category__c = 'Other', Status__c = 'Removed')
        };
    }

    private static AntsuranceDocumentIdCardsController open(String recordId, Boolean download) {
        PageReference page = Page.AntsuranceDocumentIdCards;
        if (recordId != null) {
            page.getParameters().put('id', recordId);
        }
        if (download) {
            page.getParameters().put('download', '1');
        }
        Test.setCurrentPage(page);
        return new AntsuranceDocumentIdCardsController();
    }

    @IsTest
    static void anAutoPolicyGetsTwoCardsForEachVehicle() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-1'];

        Test.startTest();
        AntsuranceDocumentIdCardsController page = open(policy.Id, false);
        Test.stopTest();

        Assert.isTrue(page.found, 'The policy has cards');
        Assert.areEqual('ANT-PA-1', page.policyNumber, 'Policy number');
        Assert.areEqual('May 13, 2026', page.effective, 'Effective date names the month');
        Assert.areEqual('May 13, 2027', page.expires, 'So does the expiration date');
        Assert.areEqual('Maria Reyes and Daniel Reyes', page.insured, 'Every named insured is on the card, once');
        Assert.areEqual('Illinois', page.state, 'The state is spelled out');
        Assert.areEqual('(217) 555-0142', page.agentPhone, 'The agency phone');
        Assert.areEqual(2, page.cards.size(), 'One card row per vehicle');
        Assert.areEqual('2022 Toyota RAV4', page.cards[0].vehicle, 'Vehicle');
        Assert.areEqual('2T3P1RFV8NC123456', page.cards[0].vin, 'VIN');
        Assert.areEqual(2, page.cards[0].copies.size(), 'Each row prints the card twice');
        Assert.areEqual('cards', page.cards[1].rowClass, 'Two rows fit the first page');
        Assert.isTrue(page.showSteps, 'The accident steps fit under two rows of cards');
        Assert.isFalse(page.showCoverages, 'The coverage summary is left out rather than given a page of its own');
        Assert.areEqual(3, page.coverages.size(), 'Removed coverages are left out');
        Assert.areEqual('$300,000 per person', page.coverages[0].limitText, 'A limit with how it applies');
        Assert.areEqual('Actual cash value', page.coverages[1].limitText, 'Collision has no dollar limit');
        Assert.areEqual('$500', page.coverages[1].deductible, 'Deductible in whole dollars');
        Assert.areEqual('Included', page.coverages[2].limitText, 'A coverage without a limit is included');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('inline; filename=ID-Cards-ANT-PA-1.pdf'), 'Named for viewing in the browser');
    }

    @IsTest
    static void aFleetGetsOneCardThatPointsToTheSchedule() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-CA-2'];

        Test.startTest();
        AntsuranceDocumentIdCardsController page = open(policy.Id, true);
        Test.stopTest();

        Assert.isTrue(page.found, 'A commercial auto policy has cards');
        Assert.areEqual('Sagebrush Freight Lines', page.insured, 'The business is the insured');
        Assert.areEqual(1, page.cards.size(), 'Buildings on the policy get no card');
        Assert.areEqual('Any vehicle on the schedule', page.cards[0].vin, 'A fleet has no single VIN');
        Assert.areEqual('Wisconsin', page.state, 'State from the insured address');
        Assert.areEqual('1-800-555-0100', page.agentPhone, 'Direct business gives the service line');
        Assert.isTrue(page.showSteps, 'The accident steps fit under one row of cards');
        Assert.isFalse(page.showCoverages, 'No coverages, no summary');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('attachment;'), 'Download saves the file');
    }

    @IsTest
    static void manyVehiclesRunOnToMorePages() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-1'];
        List<Policy_Asset__c> more = new List<Policy_Asset__c>();
        for (Integer index = 0; index < 3; index++) {
            more.add(new Policy_Asset__c(Policy__c = policy.Id, Name = '2020 Ford Transit ' + index, Asset_Type__c = 'Vehicle', Identifier__c = '1FTBR1C80LKA0000' + index));
        }
        insert more;

        Test.startTest();
        AntsuranceDocumentIdCardsController page = open(policy.Id, false);
        Test.stopTest();

        Assert.areEqual(5, page.cards.size(), 'Five vehicles');
        Assert.areEqual('cards', page.cards[2].rowClass, 'Three rows fit the first page');
        Assert.areEqual('cards new-page', page.cards[3].rowClass, 'The fourth starts the next');
        Assert.areEqual('cards', page.cards[4].rowClass, 'And the fifth follows it');
    }

    @IsTest
    static void otherPoliciesGetANoticeInstead() {
        Policy__c home = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-3'];
        Policy__c empty = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-4'];
        Account other = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        AntsuranceDocumentIdCardsController forHome = open(home.Id, false);
        AntsuranceDocumentIdCardsController forEmpty = open(empty.Id, false);
        AntsuranceDocumentIdCardsController withoutId = open(null, false);
        AntsuranceDocumentIdCardsController withNonsense = open('not-an-id', false);
        AntsuranceDocumentIdCardsController withAnotherObject = open(other.Id, false);
        Test.stopTest();

        Assert.isFalse(forHome.found, 'A homeowners policy has no ID cards');
        Assert.areEqual('ID cards are issued for auto policies only.', forHome.notice, 'And says why');
        Assert.isFalse(forEmpty.found, 'An auto policy without vehicles has none either');
        Assert.areEqual('This policy has no vehicles to issue ID cards for.', forEmpty.notice, 'And says why');
        Assert.isFalse(withoutId.found || withNonsense.found || withAnotherObject.found, 'A missing, malformed or wrong id finds nothing');
        Assert.areEqual('This policy could not be found.', withoutId.notice, 'And says so');
    }
}
