@IsTest
private class AntsuranceDecPageControllerTest {
    private static Policy__c policy(Account customer, Contact insured, String name, String line) {
        Date start = Date.newInstance(2026, 5, 13);
        return new Policy__c(
            Name = name, Account__c = customer.Id, Primary_Insured__c = insured.Id, Line_of_Business__c = line, Status__c = 'Active',
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1), Annual_Premium__c = 2380, Coverage_Limit__c = 300000, Deductible__c = 500,
            Billing_Frequency__c = 'Monthly', Payment_Status__c = 'Current', Insured_Item__c = '2022 Toyota RAV4 and 2019 Honda Accord'
        );
    }

    @TestSetup
    static void createPolicies() {
        Account household = new Account(Name = 'Reyes Household', BillingStreet = '524 W Spring Ave', BillingCity = 'Naperville', BillingPostalCode = '60540');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        Account agency = new Account(Name = 'Prairie State Insurance Agency', Phone = '(217) 555-0142');
        insert new List<Account>{ household, agency };
        Contact maria = new Contact(FirstName = 'Maria', LastName = 'Reyes', AccountId = household.Id);
        Contact daniel = new Contact(FirstName = 'Daniel', LastName = 'Reyes', AccountId = household.Id);
        insert new List<Contact>{ maria, daniel };

        Policy__c full = policy(household, maria, 'ANT-PA-1', 'Personal Auto');
        full.Producer__c = agency.Id;
        Policy__c bare = policy(household, maria, 'ANT-HO-2', 'Homeowners');
        bare.Billing_Frequency__c = null;
        bare.Insured_Item__c = null;
        insert new List<Policy__c>{ full, bare };

        insert new List<Policy_Asset__c>{
            new Policy_Asset__c(Policy__c = full.Id, Name = '2022 Toyota RAV4', Asset_Type__c = 'Vehicle', Identifier__c = '2T3P1RFV8NC123456', Location__c = 'Naperville, IL 60540', Use__c = 'Commute', Details__c = 'AWD, anti-theft', Lienholder__c = 'Lakeshore Credit Union')
        };
        insert new List<Policy_Participant__c>{
            new Policy_Participant__c(Policy__c = full.Id, Name = 'Maria Reyes, Named Insured', Contact__c = maria.Id, Role__c = 'Named Insured', Is_Primary__c = true),
            new Policy_Participant__c(Policy__c = full.Id, Name = 'Daniel Reyes, Named Insured', Contact__c = daniel.Id, Role__c = 'Named Insured'),
            new Policy_Participant__c(Policy__c = full.Id, Name = 'Maria Reyes, Driver', Contact__c = maria.Id, Role__c = 'Driver', Relationship_to_Insured__c = 'Self', License_State__c = 'IL', Date_Licensed__c = Date.today().addYears(-20), Driver_Rating__c = 'Preferred', Violations_Past_3_Years__c = 0, Accidents_Past_3_Years__c = 0),
            new Policy_Participant__c(Policy__c = full.Id, Name = 'Daniel Reyes, Driver', Contact__c = daniel.Id, Role__c = 'Driver', Violations_Past_3_Years__c = 1, Accidents_Past_3_Years__c = 2),
            new Policy_Participant__c(Policy__c = full.Id, Name = 'Gone, Driver', Contact__c = daniel.Id, Role__c = 'Driver', Status__c = 'Removed')
        };
        insert new List<Policy_Coverage__c>{
            new Policy_Coverage__c(Policy__c = full.Id, Name = 'Bodily Injury Liability', Category__c = 'Liability', Limit_Amount__c = 300000, Limit_Type__c = 'Per Occurrence', Premium_Amount__c = 1500.5),
            new Policy_Coverage__c(Policy__c = full.Id, Name = 'Collision', Category__c = 'Collision', Deductible_Amount__c = 500, Premium_Amount__c = 879.5),
            new Policy_Coverage__c(Policy__c = full.Id, Name = 'Roadside', Category__c = 'Other'),
            new Policy_Coverage__c(Policy__c = full.Id, Name = 'Dropped', Category__c = 'Other', Status__c = 'Removed', Premium_Amount__c = 999)
        };
        insert new List<Policy_Endorsement__c>{
            new Policy_Endorsement__c(Policy__c = full.Id, Name = 'Roadside Assistance', Form_Number__c = 'ANT PA 03 10', Type__c = 'Benefit', Limit_Amount__c = 150, Premium_Change__c = 48),
            new Policy_Endorsement__c(Policy__c = full.Id, Name = 'Multi-Policy Discount', Form_Number__c = 'ANT PA 09 01', Type__c = 'Discount', Premium_Change__c = -212.4),
            new Policy_Endorsement__c(Policy__c = full.Id, Name = 'Additional Insured: Managers or Lessors of Premises', Type__c = 'Lienholder or Mortgagee')
        };
    }

    private static AntsuranceDecPageController open(String recordId, Boolean download) {
        PageReference page = Page.AntsuranceDecPage;
        if (recordId != null) {
            page.getParameters().put('id', recordId);
        }
        if (download) {
            page.getParameters().put('download', '1');
        }
        Test.setCurrentPage(page);
        return new AntsuranceDecPageController();
    }

    @IsTest
    static void aFullAutoPolicyPrintsEverySection() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-1'];

        Test.startTest();
        AntsuranceDecPageController page = open(policy.Id, false);
        Test.stopTest();

        Assert.isTrue(page.found, 'The policy is found');
        Assert.areEqual('ANT-PA-1', page.policyNumber, 'Policy number');
        Assert.areEqual('May 13, 2026 to May 13, 2027', page.policyPeriod, 'Dates name the month and are never split');
        Assert.areEqual('12 months', page.term, 'Term');
        Assert.areEqual('Maria Reyes', page.namedInsured, 'A household is named for its primary insured');
        Assert.areEqual('and Daniel Reyes', page.insuredNote, 'Other named insureds follow');
        Assert.areEqual(new List<String>{ '524 W Spring Ave', 'Naperville, IL 60540' }, page.addressLines, 'Mailing address on two lines');
        Assert.areEqual('Prairie State Insurance Agency', page.agentName, 'The producer is the agent');
        Assert.areEqual('(217) 555-0142', page.agentDetail, 'With its phone number');
        Assert.areEqual('$2,380.00', page.annualPremium, 'Premium with cents');
        Assert.areEqual('$300,000', page.policyLimit, 'Limit in whole dollars');
        Assert.areEqual('12 payments of $198.33', page.installments, 'Installments from the billing plan');

        Assert.areEqual('Insured vehicles', page.assetHeading, 'Auto policies list vehicles');
        Assert.areEqual(1, page.assets.size(), 'One vehicle');
        Assert.areEqual('2T3P1RFV8NC123456', page.assets[0].second, 'VIN');
        Assert.isFalse(page.assetHasFourth, 'Vehicles print in three columns, so a full address fits');
        Assert.isTrue(page.assetFourthColumn.isEmpty() && page.assets[0].fourthCell.isEmpty(), 'With no fourth heading or cell');
        Assert.areEqual(new List<String>{ 'Commute. AWD, anti-theft', 'Lienholder: Lakeshore Credit Union' }, page.assets[0].details, 'Use and details share a line, and the lienholder gets its own');
        Assert.areEqual(2, page.assets[0].detailLineCount, 'Two short lines');
        Assert.isFalse(page.hasInsuredItemOnly, 'The free-text item is not repeated when assets are listed');

        Assert.areEqual(2, page.drivers.size(), 'Removed drivers are left out');
        Assert.areEqual('IL', page.drivers[0].licensed, 'The state that licensed them');
        Assert.areEqual('Covered driver', page.drivers[0].standing, 'A driver is listed as covered');
        // The customer's document does not print the insurer's working view of them.
        String printed = JSON.serialize(page.drivers) + page.installments + page.billingPlan;
        Assert.isFalse(printed.containsIgnoreCase('violation') || printed.containsIgnoreCase('accident') || printed.contains('Clean'), 'No driving record: ' + printed);
        Assert.isFalse(printed.contains('Preferred') || printed.contains('Standard') || printed.contains('years'), 'No rating class or years licensed: ' + printed);
        Assert.isFalse(printed.contains('Past Due') || printed.contains('Current'), 'No payment status: ' + printed);

        Assert.areEqual(3, page.coverages.size(), 'Removed coverages are left out');
        Assert.areEqual('$300,000', page.coverages[0].limitText, 'A limit in dollars');
        Assert.areEqual('per occurrence', page.coverages[0].limitNote, 'With how it applies');
        Assert.areEqual('None', page.coverages[0].deductible, 'No deductible is a word');
        Assert.areEqual('Actual cash value', page.coverages[1].limitText, 'Collision has no dollar limit');
        Assert.areEqual('$500', page.coverages[1].deductible, 'Deductible in whole dollars');
        Assert.areEqual('Included', page.coverages[2].limitText, 'A coverage without a limit is included');
        Assert.areEqual('Included', page.coverages[2].premium, 'A coverage without a premium is included');
        Assert.areEqual('$2,380.00', page.coverageTotal, 'Removed coverages are not totaled');
        Assert.areEqual(1, page.coverageGroups.size(), 'A coverage table that fits prints in one part');
        Assert.isTrue(page.coverageGroups[0].isFirst && page.coverageGroups[0].isLast, 'Which carries both the heading and the total');
        Assert.isFalse(page.coverageGroups[0].isContinued, 'And is not marked as continued');
        Assert.areEqual('section', page.coverageGroups[0].sectionClass, 'On the first page');
        Assert.areEqual(3, page.formGroups[0].forms.size(), 'Forms are laid out the same way');
        Assert.areEqual('section', page.assetsClass, 'Vehicles follow the policy facts');
        Assert.areEqual('section', page.driversClass, 'Drivers follow the vehicles');
        Assert.areEqual('section new-page', page.formGroups[0].sectionClass, 'Forms that no longer fit start a new page under their heading');
        Assert.areEqual('ending', page.endingClass, 'The premium summary follows them');
        Assert.areEqual('Declarations ANT-PA-1', page.documentLabel, 'The footer names the document');
        Assert.isTrue(page.printedLine.startsWith('Printed ') && page.printedLine.endsWith(', page '), 'And says when it was printed');
        Assert.areNotEqual(page.printedOn, page.issueDate, 'Issued is the day cover began, not the day of printing');

        Assert.areEqual(3, page.forms.size(), 'Every form is listed');
        Assert.areEqual('+$48.00', page.forms[0].premiumEffect, 'A charge is marked plus');
        Assert.areEqual('-$212.40', page.forms[1].premiumEffect, 'A discount is marked minus');
        Assert.areEqual('Included', page.forms[2].premiumEffect, 'No charge is a word');
        Assert.areEqual('Not recorded', page.forms[2].formNumber, 'A missing form number is a word');
        Assert.areEqual(new List<String>{ 'Roadside Assistance' }, page.forms[0].titleLines, 'A title that fits its column stays on one line');
        Assert.areEqual(new List<String>{ 'Additional Insured: Managers', 'or Lessors of Premises' }, page.forms[2].titleLines, 'A long title takes two even lines instead of being cut short');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('inline; filename=Declarations-ANT-PA-1.pdf'), 'Named for viewing in the browser');
    }

    @IsTest
    static void aPolicyWithNothingAttachedStillPrints() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-HO-2'];

        Test.startTest();
        AntsuranceDecPageController page = open(policy.Id, true);
        Test.stopTest();

        Assert.isTrue(page.found, 'The policy is found');
        Assert.areEqual('Insured property', page.assetHeading, 'Homeowners policies list property');
        Assert.isFalse(page.hasAssets || page.hasInsuredItemOnly || page.hasDrivers || page.hasCoverages || page.hasForms, 'Empty sections are left out');
        Assert.areEqual('Antsurance Direct', page.agentName, 'No producer means direct business');
        Assert.areEqual('Not recorded', page.billingPlan, 'A missing billing plan is a word');
        Assert.areEqual('Not recorded', page.installments, 'No installments without a plan');
        Assert.isFalse(page.hasInsuredNote, 'No other named insureds');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('attachment;'), 'Download saves the file');
    }

    @IsTest
    static void aBusinessIsItsOwnNamedInsuredAndAnnualPlansPayOnce() {
        Account business = new Account(
            Name = 'Bluestem Brewing Company',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Business').getRecordTypeId()
        );
        insert business;
        Contact owner = new Contact(LastName = 'Raman', AccountId = business.Id);
        insert owner;
        Policy__c policy = policy(business, owner, 'ANT-GL-3', 'General Liability');
        policy.Billing_Frequency__c = 'Annual';
        insert policy;
        insert new Policy_Asset__c(Policy__c = policy.Id, Name = 'Brewery and taproom', Asset_Type__c = 'Operations', Location__c = 'Chicago, IL', Insured_Value__c = 2000000);
        insert new Policy_Coverage__c(Policy__c = policy.Id, Name = 'Workers Compensation (statutory)', Category__c = 'Workers Compensation', Premium_Amount__c = 10);

        Test.startTest();
        AntsuranceDecPageController page = open(policy.Id, false);
        Test.stopTest();

        Assert.areEqual('Bluestem Brewing Company', page.namedInsured, 'The business is the named insured');
        Assert.areEqual('Attention: Raman', page.insuredNote, 'With its contact on the next line');
        Assert.isFalse(page.assets[0].hasDetail, 'An asset with nothing more to say has no detail lines');
        Assert.areEqual('Insured operations', page.assetHeading, 'Liability policies list operations');
        Assert.areEqual('$2,000,000', page.assets[0].fourth, 'Insured value with separators');
        Assert.areEqual('right', page.assetFourthAlign, 'Money is right-aligned');
        Assert.areEqual(4, page.assetColumnCount, 'Operations print a fourth column for the insured value');
        Assert.areEqual(new List<String>{ 'Insured value' }, page.assetFourthColumn, 'With its heading');
        Assert.areEqual('71pt', page.assetFourthWidth, 'And width');
        Assert.areEqual(new List<String>{ '$2,000,000' }, page.assets[0].fourthCell, 'And a cell in each row');
        Assert.areEqual('Statutory', page.coverages[0].limitText, 'Workers compensation limits are statutory');
        Assert.areEqual('1 payment of $2,380.00', page.installments, 'An annual plan is one payment');
        Assert.isFalse(page.hasDrivers, 'Only auto policies list drivers');
    }

    @IsTest
    static void aMissingOrWrongIdPrintsANotice() {
        Account other = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Boolean withoutId = open(null, false).found;
        Boolean withNonsense = open('not-an-id', false).found;
        Boolean withAnotherObject = open(other.Id, false).found;
        Test.stopTest();

        Assert.isFalse(withoutId, 'No id, no document');
        Assert.isFalse(withNonsense, 'A malformed id is not queried');
        Assert.isFalse(withAnotherObject, 'An id for another object is not a policy');
    }

    @IsTest
    static void aLongCoverageTableIsCutAtThePageEndAndRepeatsItsHeads() {
        Policy__c policy = [SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-1'];
        List<Policy_Coverage__c> more = new List<Policy_Coverage__c>();
        for (Integer index = 0; index < 30; index++) {
            more.add(new Policy_Coverage__c(Policy__c = policy.Id, Name = 'Extra cover ' + index, Category__c = 'Other', Premium_Amount__c = 1));
        }
        insert more;

        Test.startTest();
        AntsuranceDecPageController page = open(policy.Id, false);
        Test.stopTest();

        Assert.areEqual(33, page.coverages.size(), 'Every coverage is printed');
        Assert.isTrue(page.coverageGroups.size() > 1, 'In more than one part');
        Integer printed = 0;
        for (AntsuranceDecPageController.RowGroup part : page.coverageGroups) {
            printed += part.coverages.size();
            Assert.isTrue(part.coverages.size() >= 2, 'No part is a single stranded row');
            Assert.areEqual(part.isContinued ? 'section new-page' : 'section', part.sectionClass, 'Each later part starts a page and says it is continued');
        }
        Assert.areEqual(33, printed, 'No row is dropped or repeated');
        Assert.isTrue(page.coverageGroups[page.coverageGroups.size() - 1].isLast, 'The last part carries the total');
    }

    @IsTest
    static void moneyKeepsItsCentsAndSeparators() {
        Assert.areEqual('$1,234,567.05', AntsuranceDocumentFormat.money(1234567.049, 2, ''), 'Rounds to cents and pads them');
        Assert.areEqual('$1,000', AntsuranceDocumentFormat.money(999.5, 0, ''), 'Rounds whole dollars up');
        Assert.areEqual('None', AntsuranceDocumentFormat.money(null, 0, 'None'), 'Blank becomes the stand-in');
        Assert.areEqual('Jan 5, 2027', AntsuranceDocumentFormat.longDate(Date.newInstance(2027, 1, 5)), 'Dates name the month');
    }
}
