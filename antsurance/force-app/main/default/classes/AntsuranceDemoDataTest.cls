@IsTest
private class AntsuranceDemoDataTest {
    @IsTest
    static void loadsAConnectedBookOfBusiness() {
        Test.startTest();
        AntsuranceDemoData.load();
        Integer dmlStatements = Limits.getDmlStatements();
        Test.stopTest();

        Assert.isTrue(dmlStatements < 40, 'The load stays far inside the DML statement limit, used ' + dmlStatements);
        Assert.areEqual(68, [SELECT COUNT() FROM Account], 'Agencies, households and businesses');
        Assert.areEqual(3, [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'Agency'], 'Three agencies');
        Assert.areEqual(45, [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'Household'], 'Forty-five households');
        Assert.areEqual(20, [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'Business'], 'Twenty businesses');
        Assert.areEqual(149, [SELECT COUNT() FROM Policy__c], 'Every policy is loaded');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy__c WHERE Primary_Insured__c = NULL], 'Every policy has a named insured');
        Assert.areEqual(46, [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim'], 'Claims');
        Assert.areEqual(38, [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Policy_Service'], 'Service requests');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE Policy__c = NULL], 'Every case points at a policy');
        // 34 sales in play, plus one bound a month for a household and one for a business over the last six months.
        Integer boundHistory = [SELECT COUNT() FROM Opportunity WHERE IsWon = TRUE AND CloseDate < :Date.today().addDays(-25)];
        Assert.isTrue(boundHistory >= 9 && boundHistory <= 12, 'Bound sales over the last six months, found ' + boundHistory);
        Assert.areEqual(34 + boundHistory, [SELECT COUNT() FROM Opportunity], 'Policy sales');
        Assert.isTrue(
            [SELECT COUNT() FROM Opportunity WHERE IsWon = TRUE AND CloseDate < :Date.today().addDays(-120)] >= 2,
            'Some of them bound more than four months ago'
        );
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE IsClosed = FALSE AND CloseDate < TODAY], 'No open sale is overdue');
        Assert.areEqual(25, [SELECT COUNT() FROM Lead], 'Leads');
        Set<String> leadPhones = new Set<String>();
        for (Lead prospect : [SELECT Phone FROM Lead]) {
            Assert.isTrue(Pattern.matches('\\(\\d{3}\\) 555-01\\d{2}', prospect.Phone), 'A lead phone number is written like every other, found ' + prospect.Phone);
            leadPhones.add(prospect.Phone);
        }
        Assert.areEqual(25, leadPhones.size(), 'No two leads share a phone number');

        // A real personal lines book has many customers with a single policy, and each is a cross-sell lead.
        List<Account> onePolicy = [SELECT Name, Customer_Brief__c FROM Account WHERE RecordType.DeveloperName = 'Household' AND Active_Policies__c = 1];
        Assert.isTrue(onePolicy.size() >= 15 && onePolicy.size() <= 22, 'About two households in five hold one policy, found ' + onePolicy.size() + ' of 45');
        for (Account household : onePolicy) {
            Assert.isTrue(household.Customer_Brief__c.contains('**Watch:**'), household.Name + ' still has something to watch for in its brief');
        }
    }

    @IsTest
    static void theHandWrittenStoriesAreIntact() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Policy__c auto = [
            SELECT Annual_Premium__c, (SELECT Premium_Amount__c FROM Coverages__r), (SELECT Name, Role__c FROM Participants__r ORDER BY Name)
            FROM Policy__c
            WHERE Account__r.Name = 'Reyes Household' AND Line_of_Business__c = 'Personal Auto'
        ];
        Assert.areEqual(3, auto.Participants__r.size(), 'Named insured plus the two adult drivers');
        Assert.areEqual('Daniel Reyes, Driver', auto.Participants__r[0].Name, 'A participant is named for the person and the role');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Participant__c WHERE Contact__r.FirstName = 'Sofia'], 'Sofia is not on a policy until the request is worked');

        Account household = [SELECT Active_Policies__c, Premium_in_Force__c FROM Account WHERE Name = 'Reyes Household'];
        Assert.areEqual(3, household.Active_Policies__c, 'Policies roll up to the household');
        Assert.areEqual(4680, household.Premium_in_Force__c, 'Premium rolls up to the household');

        Assert.areEqual(
            'Policy not in force',
            [SELECT Coverage_Check__c FROM Case WHERE Subject = 'Hit a parked car in a grocery store lot'].Coverage_Check__c,
            'The claim on the lapsed policy is flagged'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Coverage_Check__c != 'In force on date of loss'],
            'Every other claim falls inside its policy term'
        );
        Assert.areEqual(
            5,
            [SELECT COUNT() FROM File_Note__c WHERE Case__r.Subject = 'Burst pipe flooded finished basement'],
            'The burst pipe claim has its timeline of notes'
        );
    }

    @IsTest
    static void everyPolicyIsFilledOut() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Map<Id, Policy__c> policies = new Map<Id, Policy__c>([SELECT Annual_Premium__c, Line_of_Business__c FROM Policy__c]);
        Integer summed = 0;
        for (AggregateResult total : [SELECT Policy__c policy, SUM(Premium_Amount__c) premium FROM Policy_Coverage__c GROUP BY Policy__c]) {
            Assert.areEqual(policies.get((Id) total.get('policy')).Annual_Premium__c, (Decimal) total.get('premium'), 'Coverage premiums add up to the policy premium');
            summed++;
        }
        Assert.areEqual(policies.size(), summed, 'Every policy has coverages');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy__c WHERE Id NOT IN (SELECT Policy__c FROM Policy_Asset__c)], 'Every policy insures at least one asset');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy__c WHERE Id NOT IN (SELECT Policy__c FROM Policy_Endorsement__c)], 'Every policy has at least one endorsement');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy__c WHERE Id NOT IN (SELECT Policy__c FROM Policy_Participant__c)], 'Every policy has a participant');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Coverage__c WHERE Limit_Type__c = NULL OR Status__c = NULL], 'Coverages say how their limit applies');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Policy_Participant__c WHERE Role__c = 'Driver' AND (License_Number__c = NULL OR Driver_Rating__c = NULL OR Date_Licensed__c = NULL)],
            'Every driver has a license and a rating'
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Policy_Asset__c WHERE Asset_Type__c = 'Vehicle' AND Identifier__c = NULL],
            'Every vehicle has a VIN'
        );

        for (Account customer : [SELECT Name, Customer_Brief__c FROM Account WHERE RecordType.DeveloperName != 'Agency']) {
            Assert.isTrue(String.isNotBlank(customer.Customer_Brief__c), customer.Name + ' has a customer brief');
        }
        for (Policy__c policy : [SELECT Name, Underwriting_Notes__c FROM Policy__c WHERE Account__r.RecordType.DeveloperName = 'Business']) {
            Assert.isTrue(String.isNotBlank(policy.Underwriting_Notes__c), policy.Name + ' has underwriting notes');
        }
    }

    @IsTest
    static void theLossPayableClauseNamesTheFinancedVehicle() {
        Assert.areEqual('2022 Ford F-150', AntsuranceDemoData.financedVehicle('2022 Ford F-150 and 2013 Ford Expedition'), 'On a two-car policy the newest vehicle is the financed one');
        Assert.areEqual('2023 Subaru Outback', AntsuranceDemoData.financedVehicle('2023 Subaru Outback'), 'One vehicle is itself');
        Assert.areEqual('Fleet of 12 vans', AntsuranceDemoData.financedVehicle('Fleet of 12 vans'), 'With no model year the item is named as it is');
    }

    @IsTest
    static void claimsCarryFileNotes() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Set<String> handWrittenOpen = new Set<String>{ 'Burst pipe flooded finished basement', 'Kitchen fire spread to three apartments', 'Hit a parked car in a grocery store lot' };
        for (Case claim : [SELECT Subject, IsClosed, (SELECT Policy__c, Account__c, Note_Date__c FROM File_Notes__r) FROM Case WHERE RecordType.DeveloperName = 'Claim']) {
            Assert.isFalse(claim.File_Notes__r.isEmpty(), claim.Subject + ' has at least one file note');
            if (handWrittenOpen.contains(claim.Subject)) {
                Assert.isTrue(claim.File_Notes__r.size() >= 3, claim.Subject + ' has a timeline of notes');
            }
            for (File_Note__c note : claim.File_Notes__r) {
                Assert.isNotNull(note.Policy__c, 'A claim note also points at the policy');
                Assert.isNotNull(note.Account__c, 'A claim note also points at the customer');
                Assert.isTrue(note.Note_Date__c <= Datetime.now(), 'No note is dated in the future');
            }
        }
        Assert.isTrue([SELECT COUNT() FROM File_Note__c WHERE Case__c = NULL AND Policy__c != NULL] >= 8, 'Some notes sit on the policy alone');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND IsClosed = TRUE AND Status = 'Closed' AND Paid_Amount__c = NULL], 'Closed claims record what was paid');
    }

    @IsTest
    static void salesCarryQuotesThatMatchTheirStage() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        // A sale bound some time ago keeps only its bound quote.
        Integer boundHistory = [SELECT COUNT() FROM Opportunity WHERE IsWon = TRUE AND CloseDate < :Date.today().addDays(-25)];
        Assert.areEqual(49 + boundHistory, [SELECT COUNT() FROM Quote], 'Quotes');
        Set<String> openStatuses = new Set<String>{ 'Issued', 'Presented' };
        Date today = Date.today();
        Assert.areEqual(
            13,
            [SELECT COUNT() FROM Quote WHERE Status IN :openStatuses AND Issued_Date__c <= :today.addDays(-16) AND Issued_Date__c >= :today.addDays(-40)],
            'Open quotes that have been out more than two weeks'
        );
        Assert.areEqual(14, [SELECT COUNT() FROM Quote WHERE Status IN :openStatuses AND Issued_Date__c >= :today.addDays(-14)], 'Open quotes issued in the last two weeks');
        Assert.areEqual(0, [SELECT COUNT() FROM Quote WHERE Status IN :openStatuses AND ExpirationDate < TODAY], 'No open quote is past its valid-until date');

        for (Opportunity sale : [SELECT Name, StageName, Amount, (SELECT Status, Annual_Premium__c FROM Quotes) FROM Opportunity]) {
            Map<String, Integer> byStatus = new Map<String, Integer>();
            Boolean amountMatches = false;
            for (Quote option : sale.Quotes) {
                byStatus.put(option.Status, (byStatus.containsKey(option.Status) ? byStatus.get(option.Status) : 0) + 1);
                amountMatches = amountMatches || option.Annual_Premium__c == sale.Amount;
            }
            Integer count = sale.Quotes.size();
            switch on sale.StageName {
                when 'Quote Issued' {
                    Assert.isTrue(count >= 2 && count <= 3, sale.Name + ' has two or three options');
                    Assert.isTrue(amountMatches, sale.Name + ' is priced at its lead option');
                }
                when 'Bind Requested' {
                    Assert.areEqual(1, byStatus.get('Accepted'), sale.Name + ' has exactly one accepted quote');
                    Assert.isTrue(amountMatches, sale.Name + ' is priced at its accepted option');
                }
                when 'Bound' {
                    Assert.areEqual(1, byStatus.get('Bound'), sale.Name + ' has one bound quote');
                    Assert.areEqual(count - 1, byStatus.containsKey('Declined') ? byStatus.get('Declined') : 0, sale.Name + ' declined the rest');
                }
                when 'Declined' {
                    Assert.isTrue(count >= 1 && !byStatus.containsKey('Issued') && !byStatus.containsKey('Accepted'), sale.Name + ' has only closed quotes');
                }
                when else {
                    Assert.isTrue(count == 0 || (count == 1 && byStatus.containsKey('Draft')), sale.Name + ' has at most a draft');
                }
            }
        }
        Quote accepted = [SELECT Name, Annual_Premium__c, Coverage_Limit__c, ExpirationDate FROM Quote WHERE Opportunity.Name = 'Copperfield - Two buildings added to schedule' AND Status = 'Accepted'];
        Assert.areEqual(27400, accepted.Annual_Premium__c, 'The Copperfield sale has the accepted quote the bind flow reads');
        Assert.isNotNull(accepted.Coverage_Limit__c, 'With a limit to issue the policy at');
        Assert.areEqual('Standard deductible', accepted.Name, 'A quote is named for its option');
        Assert.areEqual(1, [SELECT COUNT() FROM Quote WHERE Opportunity.Name = 'Nakamura Household - Homeowners renewal' AND Status = 'Accepted'], 'The Nakamura renewal has its accepted quote too');
    }

    @IsTest
    static void thereIsAWorkingTaskListAndRenewalsDue() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Id me = UserInfo.getUserId();
        Assert.isTrue([SELECT COUNT() FROM Task WHERE IsClosed = FALSE AND OwnerId = :me] >= 33, 'Open tasks for the running user');
        Integer overdue = [SELECT COUNT() FROM Task WHERE IsClosed = FALSE AND OwnerId = :me AND ActivityDate < TODAY AND ActivityDate >= :Date.today().addDays(-5)];
        Assert.isTrue(overdue >= 5, 'Some tasks are a few days overdue, found ' + overdue);
        Assert.isTrue([SELECT COUNT() FROM Task WHERE IsClosed = FALSE AND OwnerId = :me AND ActivityDate = TODAY] >= 4, 'Some tasks are due today');
        Assert.isTrue([SELECT COUNT() FROM Task WHERE IsClosed = TRUE AND WhatId != NULL] >= 10, 'Finished tasks for history');
        // The timeline dates a finished task as today, so none sits on a file that closed earlier.
        Set<Id> closedFiles = new Map<Id, Case>([SELECT Id FROM Case WHERE IsClosed = TRUE]).keySet().clone();
        closedFiles.addAll(new Map<Id, Opportunity>([SELECT Id FROM Opportunity WHERE IsClosed = TRUE]).keySet());
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE IsClosed = TRUE AND WhatId IN :closedFiles], 'No finished task on a closed claim, request or sale');
        Task invoiceReview = [SELECT Description FROM Task WHERE Subject = 'Review the drying vendor invoice'];
        Assert.isTrue(invoiceReview.Description.contains('Marcus Lindahl'), 'A task on a claim says which adjuster it is with');
        Integer contacted = [SELECT COUNT() FROM Lead WHERE Status = 'Working - Contacted'];
        Assert.areEqual(contacted, [SELECT COUNT() FROM Task WHERE IsClosed = TRUE AND TaskSubtype = 'Call' AND Who.Type = 'Lead'], 'Every contacted lead has a logged call');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE What.Type = 'Quote'], 'A quote follow-up hangs off its sale, so the sale shows it under Activity');
        Assert.isTrue([SELECT COUNT() FROM Task WHERE IsClosed = FALSE AND What.Type = 'Opportunity'] >= 10, 'Tasks sit on policy sales, quote follow-ups among them');
        // The Activity panel on a record page shows one line of a subject and cuts it after about 35 characters
        // at laptop width. Tasks on claims and requests also include the ones the claim automation writes, and
        // a past due policy gets one from the Policy_Past_Due_Follow_Up flow: those are not the load's to shorten.
        for (Task item : [SELECT Subject FROM Task WHERE What.Type IN ('Policy__c', 'Opportunity', 'Quote') AND (NOT Subject LIKE 'Call about past due premium on %')]) {
            Assert.isTrue(item.Subject.length() <= 34, 'A task subject fits on one line, found ' + item.Subject.length() + ' characters: ' + item.Subject);
        }
        Assert.areEqual('Approved', [SELECT Status FROM Case WHERE Subject = 'Installer fell from second-story roof'].Status, 'A claim that is accepted, reserved and part paid is past investigation');

        Set<String> inForce = new Set<String>{ 'Active', 'Pending Renewal' };
        Integer renewing = [SELECT COUNT() FROM Policy__c WHERE Status__c IN :inForce AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= :Date.today().addDays(60)];
        Assert.isTrue(renewing >= 8 && renewing <= 12, 'Between 8 and 12 policies in force expire within 60 days, found ' + renewing);
        Assert.isTrue(
            [SELECT COUNT() FROM Policy__c WHERE Status__c = 'Pending Renewal' AND Account__r.RecordType.DeveloperName = 'Household'] >= 4 &&
            [SELECT COUNT() FROM Policy__c WHERE Status__c = 'Pending Renewal' AND Account__r.RecordType.DeveloperName = 'Business'] >= 4,
            'Renewals are spread across households and businesses'
        );
    }

    @IsTest
    static void resetReplacesExistingRecords() {
        Account old = new Account(Name = 'Old Generator Customer');
        insert old;
        insert new Lead(LastName = 'Stale', Company = 'Old Lead Co');
        insert new File_Note__c(Account__c = old.Id, Body__c = 'An old note');

        Test.startTest();
        AntsuranceDemoData.reset();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Old Generator Customer'], 'Earlier accounts are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE LastName = 'Stale'], 'Earlier leads are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM File_Note__c WHERE Account__c = NULL AND Policy__c = NULL], 'Earlier notes are removed');
        Assert.areEqual(68, [SELECT COUNT() FROM Account], 'The demo accounts are loaded');
    }

    @IsTest
    static void everyAssetCanBeShownOnAMap() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Assert.isTrue([SELECT COUNT() FROM Policy_Asset__c] > 0, 'Assets are loaded');
        Assert.areEqual(0, [SELECT COUNT() FROM Policy_Asset__c WHERE Latitude__c = NULL OR Longitude__c = NULL], 'Every asset has map coordinates');
    }

    @IsTest
    static void aBoundSaleLinksToThePolicyItBecame() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        List<Opportunity> bound = [SELECT Name, Line_of_Business__c, Policy__r.Line_of_Business__c, Policy__r.Status__c FROM Opportunity WHERE IsWon = TRUE];
        Assert.isFalse(bound.isEmpty(), 'Some sales are bound');
        for (Opportunity sale : bound) {
            Assert.areEqual('Active', sale.Policy__r.Status__c, sale.Name + ' became a policy that is in force');
            Assert.areEqual(sale.Line_of_Business__c, sale.Policy__r.Line_of_Business__c, sale.Name + ' is linked to a policy of the same line');
        }
    }

    @IsTest
    static void everyQuoteCarriesItsConfiguration() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Quote WHERE Submission_Channel__c = NULL], 'Every quote says how it came in');
        for (Quote quote : [SELECT Name, Configuration__c, Annual_Premium__c, Opportunity.Line_of_Business__c FROM Quote]) {
            Assert.isNotNull(quote.Configuration__c, quote.Name + ' has its configurator answers');
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
            Map<String, Object> pricing = (Map<String, Object>) stored.get('pricing');
            Assert.areEqual(quote.Annual_Premium__c, Decimal.valueOf(String.valueOf(pricing.get('premium'))), quote.Name + ' prices to its premium');
            // A quote reopened in the configurator is priced again from what is stored. It must still agree with its sale.
            Assert.areEqual(
                quote.Annual_Premium__c,
                AntsuranceQuoteConfigurator.price(
                    quote.Opportunity.Line_of_Business__c, JSON.serialize(stored.get('answers')), Decimal.valueOf(String.valueOf(stored.get('tier')))
                ).premium,
                quote.Name + ' comes to the same premium when it is priced again'
            );
            // An answer to a question the chosen plan hides would be read by Claude and printed, though the screen never shows it.
            Map<String, Object> answers = (Map<String, Object>) stored.get('answers');
            Map<String, Object> asked = AntsuranceQuoteConfigurator.askedAnswers(AntsuranceQuoteConfigurator.getQuestionnaire(quote.Opportunity.Line_of_Business__c), answers);
            Assert.areEqual(asked.keySet(), answers.keySet(), quote.Name + ' stores answers only to questions that were asked');
        }
    }

    @IsTest
    static void householdsLiveAtAddressesWithExactCoordinates() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        Policy_Asset__c home = [SELECT Location__c, Latitude__c, Longitude__c FROM Policy_Asset__c WHERE Asset_Type__c = 'Dwelling' AND Policy__r.Account__r.Name = 'Reyes Household'];
        Assert.areEqual('524 W Spring Ave, Naperville, IL 60540', home.Location__c, 'The home is at its real address');
        Assert.areEqual(41.77831, home.Latitude__c, 'With its own latitude');
        Assert.areEqual(-88.15699, home.Longitude__c, 'And longitude');
    }

    @IsTest
    static void theLoadLeavesTheOrgRoomToWork() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        // A Developer Edition org stores about 2,500 records. The load must leave a few hundred free,
        // or creating a claim or a task in a demo fails with a storage error.
        Integer loaded =
            [SELECT COUNT() FROM Account] + [SELECT COUNT() FROM Contact] + [SELECT COUNT() FROM Policy__c] + [SELECT COUNT() FROM Policy_Coverage__c] +
            [SELECT COUNT() FROM Policy_Participant__c] + [SELECT COUNT() FROM Policy_Asset__c] + [SELECT COUNT() FROM Policy_Endorsement__c] +
            [SELECT COUNT() FROM Case] + [SELECT COUNT() FROM File_Note__c] + [SELECT COUNT() FROM Opportunity] + [SELECT COUNT() FROM Quote] +
            [SELECT COUNT() FROM Task] + [SELECT COUNT() FROM Lead];
        Assert.isTrue(loaded <= 2150, 'The demo data stays within its storage budget of 2,150 records, found ' + loaded);
    }

    @IsTest
    static void theBookReadsLikeARealOne() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        // Loss ratio by line for policies in force: what the claims on them have cost against a year of premium.
        Decimal premium = 0;
        Decimal incurred = 0;
        for (AggregateResult line : [
            SELECT Line_of_Business__c line, SUM(Annual_Premium__c) premium, SUM(Incurred_Losses__c) incurred
            FROM Policy__c
            WHERE Status__c IN ('Active', 'Pending Renewal')
            GROUP BY Line_of_Business__c
        ]) {
            Decimal linePremium = (Decimal) line.get('premium');
            Decimal lineIncurred = line.get('incurred') == null ? 0 : (Decimal) line.get('incurred');
            Assert.isTrue(lineIncurred <= linePremium * 1.1, line.get('line') + ' runs at a loss ratio no worse than 110 percent, found ' + (lineIncurred / linePremium * 100).setScale(0));
            premium += linePremium;
            incurred += lineIncurred;
        }
        Decimal ratio = incurred / premium * 100;
        Assert.isTrue(ratio >= 55 && ratio <= 80, 'The whole book runs between 55 and 80 percent, found ' + ratio.setScale(0));

        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE IsClosed = TRUE AND Closed_On__c = NULL], 'Every closed claim and request says when it closed');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE IsClosed = FALSE AND Closed_On__c != NULL], 'And no open one does');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE Status = 'Denied' AND Reserve_Amount__c > 0], 'A denied claim holds no reserve');
        for (Case claim : [
            SELECT Subject, Estimated_Loss__c, Reserve_Amount__c, Policy__r.Deductible__c, Reported_Date__c, Closed_On__c
            FROM Case
            WHERE RecordType.DeveloperName = 'Claim' AND Reserve_Amount__c > 0 AND Loss_Type__c NOT IN ('Glass', 'Theft')
        ]) {
            Decimal deductible = claim.Policy__r.Deductible__c == null ? 0 : claim.Policy__r.Deductible__c;
            // The stolen BMW is reserved at its cash value, which is not an estimate less a deductible.
            Assert.isTrue(
                claim.Reserve_Amount__c == claim.Estimated_Loss__c - deductible || deductible == 0,
                claim.Subject + ': the reserve is the estimate less the deductible'
            );
        }
        for (Case closed : [SELECT Subject, Reported_Date__c, Closed_On__c FROM Case WHERE Closed_On__c != NULL]) {
            Assert.isTrue(closed.Closed_On__c >= closed.Reported_Date__c && closed.Closed_On__c <= Date.today(), closed.Subject + ' closed after it was reported and not in the future');
        }

        // Claims and requests are spread over time: no chart of them by month or by week is one tall bar.
        Date today = Date.today();
        Integer claims = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim'];
        Integer lastThirtyDays = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Reported_Date__c >= :today.addDays(-30)];
        Integer overThreeMonths = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Reported_Date__c < :today.addDays(-90)];
        Integer overSixMonths = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Reported_Date__c < :today.addDays(-180)];
        Assert.isTrue(lastThirtyDays * 2 < claims, 'Fewer than half the claims were reported in the last 30 days, found ' + lastThirtyDays + ' of ' + claims);
        Assert.isTrue(overThreeMonths >= 10, 'Claims reach back more than three months, found ' + overThreeMonths);
        Assert.isTrue(overSixMonths >= 4, 'And some more than six, found ' + overSixMonths);
        Integer openClaimsPastAMonth = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND IsClosed = FALSE AND Reported_Date__c < :today.addDays(-30)];
        Assert.isTrue(openClaimsPastAMonth >= 6, 'Open claims are of different ages, found ' + openClaimsPastAMonth + ' open more than a month');
        Integer openRequests = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Policy_Service' AND IsClosed = FALSE];
        Integer openRequestsPastAWeek = [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Policy_Service' AND IsClosed = FALSE AND Reported_Date__c < :today.addDays(-7)];
        Assert.isTrue(openRequestsPastAWeek * 3 >= openRequests, 'A third or more of the open requests came in over a week ago, found ' + openRequestsPastAWeek + ' of ' + openRequests);

        Account lakefront = [SELECT Customer_Brief__c, Customer_Since__c FROM Account WHERE Name = 'Lakefront Brokerage Partners'];
        Assert.isTrue(lakefront.Customer_Brief__c.contains('**Watch:**'), 'Each agency has a brief');
        Assert.isNotNull(lakefront.Customer_Since__c, 'And the day it was appointed');
        for (Account business : [SELECT Name, Website, AnnualRevenue, Description FROM Account WHERE RecordType.DeveloperName = 'Business']) {
            Assert.isTrue(business.Website != null && business.AnnualRevenue != null && String.isNotBlank(business.Description), business.Name + ' has a website, revenue and a description');
        }

        Policy_Participant__c insured = [
            SELECT Name, Role__c, Contact__r.Name, Relationship_to_Insured__c
            FROM Policy_Participant__c
            WHERE Policy__r.Account__r.Name = 'Ironwood Machine Works' AND Policy__r.Line_of_Business__c = 'Workers Compensation'
        ];
        Assert.areEqual('Sam Okonkwo, Policy Contact', insured.Name, 'On a commercial policy the person we deal with is its policy contact');
        Assert.areEqual('Policy Contact', insured.Role__c, 'The business is the named insured through the policy, so no person holds that role');
        Assert.areEqual('Employee', insured.Relationship_to_Insured__c, 'And is an employee of the insured, not the insured');
        Assert.areEqual('Sam Okonkwo', insured.Contact__r.Name, 'The participant is the contact');

        Assert.isNotNull([SELECT Underwriting_Notes__c FROM Policy__c WHERE Account__r.Name = 'Reyes Household' AND Line_of_Business__c = 'Personal Auto'].Underwriting_Notes__c, 'The flagship auto policy has underwriting notes');

        for (Policy__c policy : [SELECT Name, Annual_Premium__c, (SELECT Premium_Amount__c FROM Coverages__r) FROM Policy__c]) {
            Decimal coverages = 0;
            for (Policy_Coverage__c coverage : policy.Coverages__r) {
                Assert.areEqual(coverage.Premium_Amount__c.setScale(0), coverage.Premium_Amount__c, policy.Name + ': coverage premiums are whole dollars');
                coverages += coverage.Premium_Amount__c;
            }
            Assert.areEqual(policy.Annual_Premium__c, coverages, policy.Name + ': coverage premiums add up to the policy premium');
        }
    }

    @IsTest
    static void threeDraftQuotesWaitOnAnUnderwriter() {
        Test.startTest();
        AntsuranceDemoData.load();
        Test.stopTest();

        List<Quote> referred = [
            SELECT Status, Configuration__c, Opportunity.StageName, Opportunity.Line_of_Business__c
            FROM Quote
            WHERE Needs_Underwriting_Review__c = TRUE
        ];
        Set<String> lines = new Set<String>();
        for (Quote quote : referred) {
            lines.add(quote.Opportunity.Line_of_Business__c);
            Assert.areEqual('Draft', quote.Status, 'A referred quote is not released yet');
            Assert.areEqual('Underwriting Review', quote.Opportunity.StageName, 'And its sale is with underwriting');
            Assert.isTrue(AntsuranceQuoteConfigurator.needsReview(quote.Configuration__c), 'Its answers carry the reason');
        }
        Assert.areEqual(3, referred.size(), 'Three quotes are waiting on an underwriter');
        Assert.areEqual(3, lines.size(), 'On three different lines of business');

        for (Quote quote : [SELECT Issued_Date__c, Configuration__c FROM Quote WHERE Issued_Date__c != NULL]) {
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
            Assert.isTrue(Date.valueOf((String) stored.get('configuredOn')) <= quote.Issued_Date__c, 'Answers are taken on or before the day the quote goes out');
        }
    }
}
