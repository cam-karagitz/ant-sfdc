@IsTest
private class AntsuranceDocumentProposalTest {
    private static final String ANSWERS =
        '{"version":1,"answers":{"maritalStatus":"married","homeowner":"false","priorInsurance":"none","priorCarrier":"Hidden Mutual","drivers":"1200",' +
        '"vehicleList":"2020 Hyundai Kona and 2018 Ford Escape","telematics":"true","liability":"100000","medical":"not-an-option"}}';

    private static Opportunity sale(Account customer, String name, String line) {
        return new Opportunity(
            Name = name, AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = Date.today().addDays(30), Line_of_Business__c = line, Type = 'Cross-Sell',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId()
        );
    }

    @TestSetup
    static void createSales() {
        Account household = new Account(Name = 'Dubois Household', BillingStreet = '2620 Central Park Ave', BillingCity = 'Evanston', BillingPostalCode = '60201');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        insert household;
        Opportunity auto = sale(household, 'Dubois Household - Personal Auto', 'Personal Auto');
        Opportunity home = sale(household, 'Dubois Household - Homeowners', 'Homeowners');
        Opportunity empty = sale(household, 'Dubois Household - Umbrella', 'Umbrella');
        Opportunity drafted = sale(household, 'Dubois Household - Renters', 'Renters');
        Opportunity lapsed = sale(household, 'Dubois Household - Commercial Auto', 'Commercial Auto');
        insert new List<Opportunity>{ auto, home, empty, drafted, lapsed };
        insert new Quote(Name = 'Being priced', OpportunityId = drafted.Id, Status = 'Draft', Annual_Premium__c = 240);
        insert new Quote(Name = 'Turned down', OpportunityId = drafted.Id, Status = 'Declined', Annual_Premium__c = 300);

        Date issued = Date.newInstance(2026, 9, 1);
        insert new Quote(
            Name = 'Standard deductible', OpportunityId = auto.Id, Status = 'Presented', Annual_Premium__c = 1560, Coverage_Limit__c = 100000, Deductible__c = 1000,
            Issued_Date__c = issued, ExpirationDate = issued.addDays(45), Underwriter__c = 'Lydia Osei', Configuration__c = ANSWERS,
            Description = '**Includes:** Liability, collision, comprehensive and uninsured motorist.\n\n**Position:** The recommended option, and the one the sale amount is based on.'
        );
        insert new Quote(
            Name = 'Higher deductible, lower premium', OpportunityId = auto.Id, Status = 'Presented', Annual_Premium__c = 1435.5, Coverage_Limit__c = 100000,
            Deductible__c = 2000, Issued_Date__c = issued, ExpirationDate = issued.addDays(40),
            Description = '**Includes:** The same coverages as the lead option.\n\n**Difference:** A $2,000 deductible, which takes about 8 percent off the premium.'
        );
        insert new Quote(Name = 'Withdrawn', OpportunityId = auto.Id, Status = 'Declined', Annual_Premium__c = 9999);
        insert new Quote(Name = 'Not sent yet', OpportunityId = auto.Id, Status = 'Draft');

        insert new Quote(Name = 'First', OpportunityId = home.Id, Status = 'Declined', Description = 'Plain words with no label.', Configuration__c = 'not json');
        insert new Quote(Name = 'Higher deductible, lower premium', OpportunityId = home.Id, Status = 'Declined', Annual_Premium__c = 1800, Deductible__c = 0);
        insert new Quote(Name = 'Third', OpportunityId = home.Id, Status = 'Expired');
        insert new Quote(Name = 'Fourth', OpportunityId = home.Id, Status = 'Expired');

        insert new Quote(Name = 'Ran out', OpportunityId = lapsed.Id, Status = 'Expired', Annual_Premium__c = 4200, ExpirationDate = Date.today().addDays(-12));
        insert new Quote(Name = 'Closed early', OpportunityId = lapsed.Id, Status = 'Declined', Annual_Premium__c = 3900, ExpirationDate = Date.today().addDays(20));
    }

    private static AntsuranceDocumentProposalController open(String recordId, Boolean download) {
        PageReference page = Page.AntsuranceDocumentProposal;
        if (recordId != null) {
            page.getParameters().put('id', recordId);
        }
        if (download) {
            page.getParameters().put('download', '1');
        }
        Test.setCurrentPage(page);
        return new AntsuranceDocumentProposalController();
    }

    @IsTest
    static void aProposalSetsTheOpenOptionsSideBySide() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Dubois Household - Personal Auto'];

        Test.startTest();
        AntsuranceDocumentProposalController page = open(sale.Id, false);
        Test.stopTest();

        Assert.isTrue(page.found, 'The sale has a proposal');
        Assert.areEqual('Personal Auto', page.lineOfBusiness, 'Line of business');
        Assert.areEqual('Dubois Household', page.customerName, 'Prepared for the customer');
        Assert.areEqual(new List<String>{ '2620 Central Park Ave', 'Evanston, IL 60201' }, page.addressLines, 'With their address');
        Assert.areEqual('Sep 1, 2026', page.proposalDate, 'Dated when the quote was issued');
        Assert.areEqual('Oct 11, 2026', page.validUntil, 'Valid until the first option runs out');
        Assert.areEqual('Cross-Sell', page.saleType, 'Type of sale');
        Assert.areEqual('Lydia Osei', page.underwriter, 'Underwriter');
        Assert.isTrue(String.join(page.introLines, ' ').contains('the two options we priced for your personal auto insurance, side by side'), 'The opening counts the options');

        Assert.areEqual(2, page.options.size(), 'A declined option and a draft are left out while others are with the customer');
        AntsuranceDocumentProposalController.Option lead = page.options[0];
        Assert.isTrue(lead.isRecommended, 'The option written up as recommended leads');
        Assert.areEqual('Recommended', lead.tag, 'And is tagged');
        Assert.areEqual('Your options', page.optionsHeading, 'Several options are headed as options');
        Assert.areEqual('Choose an option', page.firstStep, 'And the first step is to choose');
        Assert.isFalse(page.isClosed, 'Options the customer can still take are an offer');
        Assert.areEqual('We put the cover in place', page.lastStep, 'So the last step is the cover');
        Assert.areEqual(new List<String>{ 'You get your policy and', 'declarations page by email.' }, page.lastStepLines, 'And what arrives');
        Assert.isTrue(page.documentLabel.startsWith('Proposal, quote '), 'The footer names the quote');
        Assert.areEqual(new List<String>{ 'Standard deductible' }, lead.nameLines, 'Named on one line when it fits');
        Assert.areEqual('option lead-option', lead.cellClass, 'And tinted');
        Assert.areEqual('$1,560', lead.premium, 'A whole-dollar premium has no cents');
        Assert.areEqual('a year, or about $130 a month', lead.monthly, 'With what it comes to a month');
        Assert.areEqual('$100,000', lead.limitText, 'Limit');
        Assert.areEqual('$1,000', lead.deductible, 'Deductible');
        Assert.areEqual('Liability, collision, comprehensive and uninsured motorist.', String.join(lead.includes, ' '), 'What it includes, without the Markdown');
        Assert.areEqual('This is the option we recommend for you.', String.join(lead.differs, ' '), 'The internal note on position is not printed');
        Assert.isTrue(lead.reference.startsWith('Quote ') && lead.reference.endsWith(', valid until Oct 16, 2026'), 'The quote number and how long it holds');
        Assert.areEqual('Say yes by Oct 11, 2026', page.acceptBy, 'The next steps give the date to answer by');
        Assert.isTrue(page.replyTo.startsWith('to ') && page.replyTo.endsWith('.'), 'And who to answer');
        Assert.isTrue(page.answersIntro.startsWith('We priced the Standard deductible option'), 'The answers are introduced by the option they priced');
        Assert.isTrue(lead.gaps.isEmpty(), 'No gap before the first column');
        AntsuranceDocumentProposalController.Option other = page.options[1];
        Assert.areEqual('Alternative', other.tag, 'The other option is an alternative');
        Assert.areEqual('option', other.cellClass, 'Untinted');
        Assert.areEqual('$1,435.50', other.premium, 'A premium with cents keeps them');
        Assert.areEqual('A $2,000 deductible, which takes about 8 percent off the premium.', String.join(other.differs, ' '), 'How it differs');
        Assert.areEqual(new List<String>{ '21pt' }, other.gaps, 'A gap before the second column');
        Assert.areEqual('228pt', other.width, 'Two columns share the page');
        for (String line : other.differs) {
            Assert.isTrue(line.length() <= 52, 'Lines are broken to fit the column');
        }

        Assert.isTrue(page.hasAnswers, 'The recommended quote carries the customer\'s answers');
        Assert.areEqual('Standard deductible', page.recommendedName, 'Which is named');
        Assert.areEqual('About the applicant', page.answerSections[0].title, 'Answers are grouped as they were asked');
        AntsuranceDocumentProposalController.AnswerRow first = page.answerSections[0].rows[0];
        Assert.areEqual('Marital status', first.firstQuestion, 'A question by its label');
        Assert.areEqual('Married or partnered', first.firstAnswer, 'A choice by its label, not its stored value');
        Assert.areEqual('Owns their home', first.secondQuestion, 'Two short answers share a row');
        Assert.areEqual('No', first.secondAnswer, 'A toggle reads yes or no');
        Assert.isTrue(first.isPair, 'Printed as a pair');
        String everything = JSON.serialize(page.answerSections);
        Assert.isFalse(everything.contains('Hidden Mutual'), 'A question that was not asked is not printed');
        Assert.isTrue(everything.contains('2020 Hyundai Kona and 2018 Ford Escape'), 'Text answers are printed as given');
        Assert.isTrue(everything.contains('not-an-option'), 'A value the configurator no longer offers is printed as stored');
        Assert.isTrue(everything.contains('"1,200"'), 'A count is printed with separators');
        Boolean hasWide = false;
        for (AntsuranceDocumentProposalController.AnswerSection section : page.answerSections) {
            Assert.areEqual('answers', section.sectionClass, 'The answers fit one page');
            for (AntsuranceDocumentProposalController.AnswerRow row : section.rows) {
                hasWide = hasWide || row.isWide;
            }
        }
        Assert.isTrue(hasWide, 'A long answer takes a row of its own');
        Assert.areEqual('section', page.stepsClass, 'What happens next shares the first page with the options');
        Assert.areEqual('section new-page', page.answersClass, 'The answers start the second page');
        Assert.areEqual('closing', page.closingClass, 'And the closing note follows them');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('inline; filename=Proposal-Dubois-Household-Personal-Auto.pdf'), 'Named for the sale');
        Assert.isTrue(AntsuranceDocumentProposalController.isAvailableFor(sale.Id), 'A sale with quotes can have a proposal');
    }

    @IsTest
    static void aSaleWithOnlyClosedQuotesStillPrintsThem() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Dubois Household - Homeowners'];

        Test.startTest();
        AntsuranceDocumentProposalController page = open(sale.Id, true);
        Test.stopTest();

        Assert.isTrue(page.found, 'Closed quotes are printed when nothing is open');
        Assert.areEqual(3, page.options.size(), 'Up to three, which is what fits side by side');
        Assert.isTrue(page.isClosed, 'Nothing here can be accepted any more');
        Assert.areEqual('No longer on offer', page.options[0].tag, 'A declined quote is tagged in the customer\'s words, which do not say who declined');
        Assert.areEqual('This is the option we recommended.', String.join(page.options[0].differs, ' '), 'The lead option is spoken of as past');
        Assert.isTrue(page.options[0].isRecommended, 'With no recommendation written, the first leads');
        Assert.areEqual('On request', page.options[0].premium, 'A missing premium is a word');
        Assert.areEqual('Ask us for the price', page.options[0].monthly, 'And so is its monthly figure');
        Assert.areEqual('As described', page.options[0].limitText, 'A missing limit is a word');
        Assert.areEqual('Plain words with no label.', String.join(page.options[0].includes, ' '), 'A description with no labels is what the option includes');
        Assert.areEqual(new List<String>{ 'Higher deductible,', 'lower premium' }, page.options[1].nameLines, 'A long name takes two even lines in a narrow column');
        Assert.areEqual('$0', page.options[1].deductible, 'No deductible reads as zero dollars, as it does on the quote board');
        Assert.areEqual('As set out in the quote.', String.join(page.options[1].includes, ' '), 'No description points to the quote');
        Assert.areEqual('Ask us how this compares.', String.join(page.options[1].differs, ' '), 'And invites the question');
        Assert.areEqual('Offer expired', page.options[2].tag, 'An expired quote says so, as an offer that ran out');
        Assert.areEqual('143pt', page.options[2].width, 'Three columns share the page');
        Assert.areEqual(new List<String>{ 'Third' }, page.options[2].nameLines, 'Each named');
        Assert.areEqual('Offer closed', page.validUntil, 'No expiration dates on closed quotes: the customer is told the offer is closed, not that a date is to come');
        String opening = String.join(page.introLines, ' ');
        Assert.isFalse(opening.contains('until the date shown') || opening.contains('holds'), 'The opening does not say a closed price still holds');
        Assert.isTrue(opening.contains('These offers have closed, so their premiums are shown for reference. Ask us and we will price them again.'), opening);
        Assert.areEqual('Ask for a fresh quote', page.firstStep, 'The steps are how to get a quote that can be accepted');
        Assert.areEqual(new List<String>{ 'These offers have closed.', 'We can price them again.' }, page.firstStepLines, 'Said of several');
        Assert.areEqual('Tell us what has changed', page.acceptBy, 'Nobody is asked to say yes to a closed offer');
        Assert.areEqual('We send you new options', page.lastStep, 'And what follows is a new quote, not cover');
        Assert.isFalse(page.options[0].reference.contains('valid'), 'Nor one on the quote');
        Assert.isFalse(page.hasAnswers, 'Answers that cannot be read are not printed');
        Assert.areEqual('section', page.answersClass, 'So nothing starts a second page');
        Assert.isTrue(ApexPages.currentPage().getHeaders().get('content-disposition').startsWith('attachment;'), 'Download saves the file');
    }

    @IsTest
    static void aClosedOptionKeepsOnlyADateThatHasPassed() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Dubois Household - Commercial Auto'];

        Test.startTest();
        AntsuranceDocumentProposalController page = open(sale.Id, false);
        Test.stopTest();

        String ended = AntsuranceDocumentFormat.longDate(Date.today().addDays(-12));
        Assert.isTrue(page.isClosed, 'An expired quote and a declined one: nothing is open');
        Assert.areEqual(ended, page.validUntil, 'A date that has passed says when the offer ended');
        Assert.areEqual('Offer expired', page.options[0].tag, 'The quote that ran out');
        Assert.isTrue(page.options[0].reference.endsWith(', valid until ' + ended), 'Keeps its date');
        Assert.areEqual('No longer on offer', page.options[1].tag, 'The quote closed before its date');
        Assert.isFalse(page.options[1].reference.contains('valid'), 'Does not print a date still to come, which would read as an open offer');
        Assert.areEqual('Tell us what has changed', page.acceptBy, 'And there is no date to say yes by');
    }

    @IsTest
    static void aSaleStillBeingQuotedPrintsItsDraft() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Dubois Household - Renters'];

        Test.startTest();
        AntsuranceDocumentProposalController page = open(sale.Id, false);
        Test.stopTest();

        Assert.areEqual(1, page.options.size(), 'With nothing sent yet, the draft is printed and the declined quote is not');
        Assert.areEqual(new List<String>{ 'Being priced' }, page.options[0].nameLines, 'The draft');
        Assert.areEqual('501pt', page.options[0].width, 'One option takes the full width');
        Assert.isTrue(String.join(page.introLines, ' ').contains('Below is the option we priced for your renters insurance. The premium is'), 'And the opening speaks of one option');
        Assert.areEqual('Your quote', page.optionsHeading, 'So does the heading');
        Assert.areEqual('Check the details', page.firstStep, 'And the first step');
        Assert.areEqual('section', page.stepsClass, 'With no answers, the next steps and the closing note share the first page');
        Assert.areEqual('closing', page.closingClass, 'Together');
    }

    @IsTest
    static void salesWithNothingToProposeGetANotice() {
        Opportunity empty = [SELECT Id, AccountId FROM Opportunity WHERE Name = 'Dubois Household - Umbrella'];

        Test.startTest();
        AntsuranceDocumentProposalController withoutQuotes = open(empty.Id, false);
        AntsuranceDocumentProposalController withoutId = open(null, false);
        AntsuranceDocumentProposalController withNonsense = open('not-an-id', false);
        AntsuranceDocumentProposalController withAnotherObject = open(empty.AccountId, false);
        Test.stopTest();

        Assert.isFalse(withoutQuotes.found, 'No quotes, no proposal');
        Assert.areEqual('This policy sale has no quotes to propose yet.', withoutQuotes.notice, 'And the page says why');
        Assert.isFalse(withoutId.found || withNonsense.found || withAnotherObject.found, 'A missing, malformed or wrong id finds nothing');
        Assert.areEqual('This policy sale could not be found.', withoutId.notice, 'And says so');
        Assert.isFalse(AntsuranceDocumentProposalController.isAvailableFor(empty.Id), 'A sale without quotes cannot have a proposal');
        Assert.isFalse(AntsuranceDocumentProposalController.isAvailableFor(null), 'Nor can no sale at all');
    }

    @IsTest
    static void descriptionsAreReadByTheirLabels() {
        Map<String, String> parts = AntsuranceDocumentProposalController.describedParts('**Includes:** One thing.\n\nA loose line.\n\n**Includes:** And another.\n\n   ');
        Assert.areEqual('One thing. And another.', parts.get('includes'), 'Paragraphs with the same label are joined');
        Assert.areEqual('A loose line.', parts.get(''), 'Text with no label is kept under no label');
        Assert.isTrue(AntsuranceDocumentProposalController.describedParts(null).isEmpty(), 'No description, no parts');
    }

    @IsTest
    static void aRenewalIsGreetedAsARenewal() {
        Opportunity sale = [SELECT Id FROM Opportunity WHERE Name = 'Dubois Household - Renters'];
        update new Opportunity(Id = sale.Id, Type = 'Renewal');

        Test.startTest();
        AntsuranceDocumentProposalController page = open(sale.Id, false);
        Test.stopTest();

        String opening = String.join(page.introLines, ' ');
        Assert.isTrue(opening.startsWith('Your renters insurance with Antsurance is coming up for renewal.'), 'A renewing customer did not ask for a quote');
        Assert.isFalse(opening.contains('Thank you for asking'), 'So is not thanked for asking');
    }
}
