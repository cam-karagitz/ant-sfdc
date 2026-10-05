/**
 * @description What a policy contains. Holds the catalogue of coverages each line of business carries,
 * and builds the contents of a newly bound policy (coverages, the insured asset and endorsements)
 * from the policy's terms and the answers on the quote it was bound from.
 * Runs in system mode from AntsuranceOpportunityTrigger, so it works whoever binds the sale.
 */
public without sharing class AntsurancePolicyContents {
    // How each coverage's limit applies and what it pays for, by coverage name.
    private static final Map<String, String> COVERAGE_TERMS = new Map<String, String>{
        'Bodily Injury Liability' => 'Per Person|Pays for injuries to other people when an insured driver is at fault, including legal defense.',
        'Property Damage Liability' => 'Per Occurrence|Pays for damage an insured driver causes to someone else\'s vehicle or property.',
        'Collision' => 'Actual Cash Value|Repairs or replaces an insured vehicle after a crash with another vehicle or object, less the deductible.',
        'Comprehensive' => 'Actual Cash Value|Covers theft, fire, hail, glass, vandalism and animal strikes, less the deductible.',
        'Uninsured Motorist' => 'Per Person|Pays for the insured\'s injuries when the at-fault driver has no insurance or too little.',
        'Medical Payments' => 'Per Person|Pays medical bills for the driver and passengers, whoever is at fault.',
        'Dwelling' => 'Replacement Cost|Rebuilds or repairs the home and attached structures after a covered loss. **Flood and earth movement are excluded.**',
        'Personal Property' => 'Replacement Cost|Covers belongings at home and away, with lower limits for jewelry, cash and firearms.',
        'Loss of Use' => 'Per Occurrence|Pays extra living costs while the home cannot be lived in after a covered loss.',
        'Personal Liability' => 'Per Occurrence|Covers injury or damage to others that a household member is legally responsible for.',
        'Excess Liability' => 'Per Occurrence|Adds liability protection above the limits of the underlying policies.',
        'Building' => 'Replacement Cost|Covers the buildings at the scheduled locations, including permanently installed fixtures and equipment.',
        'Business Personal Property' => 'Replacement Cost|Covers stock, furniture, machinery and tenant improvements at the scheduled locations.',
        'Business Income' => 'Per Occurrence|Replaces lost net income and continuing expenses while a covered loss shuts operations down.',
        'Each Occurrence' => 'Per Occurrence|Covers bodily injury and property damage claims arising from the premises and operations.',
        'Products and Completed Operations' => 'Aggregate|Covers claims from products sold or work finished and handed over.',
        'Medical Expense' => 'Per Person|Pays small medical bills for people hurt on the premises, whoever is at fault.',
        'Workers Compensation (statutory)' => 'Statutory|Pays medical care and lost wages for employees hurt on the job, as state law requires.',
        'Employers Liability' => 'Per Occurrence|Covers lawsuits by injured employees that fall outside the workers compensation statute.',
        'Combined Single Limit Liability' => 'Per Occurrence|One limit for injury and property damage caused by any scheduled vehicle.'
    };


    // Quote answers that become an endorsement on the policy: question key => form title | form number | type.
    private static final Map<String, String> ANSWER_ENDORSEMENTS = new Map<String, String>{
        'rental' => 'Rental Reimbursement|ANT PA 03 20|Benefit',
        'roadside' => 'Roadside Assistance|ANT PA 03 12|Benefit',
        'waterBackup' => 'Water Backup and Sump Overflow|ANT HO 04 95|Endorsement',
        'equipment' => 'Equipment Breakdown|ANT HO 04 51|Endorsement',
        'serviceLine' => 'Service Line|ANT HO 04 53|Endorsement',
        'valuables' => 'Scheduled Personal Property|ANT HO 04 61|Endorsement',
        'identityTheft' => 'Identity Theft Expense|ANT HO 04 55|Endorsement',
        'uninsured' => 'Excess Uninsured Motorist|ANT UM 02 10|Endorsement',
        'additionalInsureds' => 'Blanket Additional Insured|ANT GL 20 10|Endorsement',
        'waiver' => 'Waiver of Subrogation|ANT GL 24 04|Endorsement',
        'ordinance' => 'Ordinance or Law|ANT CP 04 05|Endorsement',
        'hiredNonOwned' => 'Hired and Non-Owned Autos|ANT CA 20 54|Endorsement',
        'towing' => 'Towing and Rental|ANT CA 99 10|Benefit',
        'bundle' => 'Multi-Policy Discount|ANT IL 09 01|Discount',
        'payInFull' => 'Paid in Full Discount|ANT IL 09 04|Discount',
        'paperless' => 'Paperless and Autopay Discount|ANT IL 09 06|Discount',
        'telematics' => 'Safe Driving Program Discount|ANT IL 09 10|Discount',
        'goodStudent' => 'Good Student Discount|ANT PA 09 12|Discount'
    };
    // Answers that mean "not taken", so no endorsement is added.
    private static final Set<String> NOT_TAKEN = new Set<String>{ 'false', 'none', 'decline', 'match', 'minimum' };
    private static final Map<String, String> ASSET_TYPES = new Map<String, String>{
        'Personal Auto' => 'Vehicle', 'Homeowners' => 'Dwelling', 'Renters' => 'Rented Residence', 'Commercial Property' => 'Commercial Building',
        'Commercial Auto' => 'Fleet'
    };
    private static final String OTHER_ASSET_TYPE = 'Operations';

    /** The coverages a policy of this line normally carries, with the premium split across them. */
    public static List<Policy_Coverage__c> coveragesFor(Policy__c policy) {
        Decimal coverageLimit = policy.Coverage_Limit__c;
        Decimal deductible = policy.Deductible__c;
        List<Policy_Coverage__c> coverages = new List<Policy_Coverage__c>();
        switch on policy.Line_of_Business__c {
            when 'Personal Auto' {
                coverages.add(coverage(policy, 'Bodily Injury Liability', 'Liability', coverageLimit, null, 35));
                coverages.add(coverage(policy, 'Property Damage Liability', 'Liability', 100000, null, 15));
                coverages.add(coverage(policy, 'Collision', 'Collision', null, deductible, 28));
                coverages.add(coverage(policy, 'Comprehensive', 'Comprehensive', null, deductible, 12));
                coverages.add(coverage(policy, 'Uninsured Motorist', 'Uninsured Motorist', coverageLimit, null, 6));
                coverages.add(coverage(policy, 'Medical Payments', 'Medical Payments', 5000, null, 4));
            }
            when 'Homeowners' {
                coverages.add(coverage(policy, 'Dwelling', 'Dwelling', coverageLimit, deductible, 58));
                coverages.add(coverage(policy, 'Personal Property', 'Personal Property', coverageLimit * 0.5, deductible, 20));
                coverages.add(coverage(policy, 'Loss of Use', 'Loss of Use', coverageLimit * 0.2, null, 6));
                coverages.add(coverage(policy, 'Personal Liability', 'Liability', 300000, null, 16));
            }
            when 'Renters' {
                coverages.add(coverage(policy, 'Personal Property', 'Personal Property', coverageLimit, deductible, 60));
                coverages.add(coverage(policy, 'Loss of Use', 'Loss of Use', coverageLimit * 0.3, null, 12));
                coverages.add(coverage(policy, 'Personal Liability', 'Liability', 100000, null, 28));
            }
            when 'Umbrella' {
                coverages.add(coverage(policy, 'Excess Liability', 'Liability', coverageLimit, null, 100));
            }
            when 'Commercial Property' {
                coverages.add(coverage(policy, 'Building', 'Business Property', coverageLimit, deductible, 62));
                coverages.add(coverage(policy, 'Business Personal Property', 'Business Property', coverageLimit * 0.25, deductible, 22));
                coverages.add(coverage(policy, 'Business Income', 'Business Income', coverageLimit * 0.1, null, 16));
            }
            when 'General Liability' {
                coverages.add(coverage(policy, 'Each Occurrence', 'Liability', coverageLimit, deductible, 68));
                coverages.add(coverage(policy, 'Products and Completed Operations', 'Liability', coverageLimit * 2, null, 22));
                coverages.add(coverage(policy, 'Medical Expense', 'Medical Payments', 10000, null, 10));
            }
            when 'Workers Compensation' {
                coverages.add(coverage(policy, 'Workers Compensation (statutory)', 'Workers Compensation', null, null, 86));
                coverages.add(coverage(policy, 'Employers Liability', 'Liability', coverageLimit, null, 14));
            }
            when 'Commercial Auto' {
                coverages.add(coverage(policy, 'Combined Single Limit Liability', 'Liability', coverageLimit, null, 56));
                coverages.add(coverage(policy, 'Collision', 'Collision', null, deductible, 30));
                coverages.add(coverage(policy, 'Comprehensive', 'Comprehensive', null, deductible, 14));
            }
        }
        settle(coverages, policy.Annual_Premium__c);
        return coverages;
    }

    /** Coverage premiums are whole dollars. Whatever rounding leaves over goes on the largest, so they add up to the policy premium exactly. */
    private static void settle(List<Policy_Coverage__c> coverages, Decimal premium) {
        if (coverages.isEmpty() || premium == null) {
            return;
        }
        Decimal total = 0;
        Policy_Coverage__c largest = coverages[0];
        for (Policy_Coverage__c coverage : coverages) {
            total += coverage.Premium_Amount__c;
            if (coverage.Premium_Amount__c > largest.Premium_Amount__c) {
                largest = coverage;
            }
        }
        largest.Premium_Amount__c += premium - total;
    }

    private static Policy_Coverage__c coverage(Policy__c policy, String name, String category, Decimal coverageLimit, Decimal deductible, Integer premiumPercent) {
        List<String> terms = COVERAGE_TERMS.get(name).split('\\|');
        return new Policy_Coverage__c(
            Policy__c = policy.Id, Name = name, Category__c = category, Limit_Amount__c = coverageLimit,
            Deductible_Amount__c = deductible, Premium_Amount__c = (policy.Annual_Premium__c * premiumPercent / 100).setScale(0, RoundingMode.HALF_UP),
            Status__c = 'Active', Limit_Type__c = terms[0], Effective_Date__c = policy.Effective_Date__c, What_Is_Covered__c = terms[1]
        );
    }

    /**
     * @description Fills in policies that have just been bound and have no coverages yet: the coverages
     * their line carries, what they insure, and an endorsement for each extra or discount the customer
     * chose on the quote.
     * @param policyIds The newly bound policies
     */
    public static void buildFor(Set<Id> policyIds) {
        List<Policy__c> policies = [
            SELECT Id, Name, Line_of_Business__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Effective_Date__c, Insured_Item__c, Account__c,
                Account__r.BillingStreet, Account__r.BillingCity, Account__r.BillingState, Account__r.BillingPostalCode,
                (SELECT Id FROM Coverages__r LIMIT 1), (SELECT Id FROM Assets__r LIMIT 1)
            FROM Policy__c
            WHERE Id IN :policyIds
        ];
        // The quote each policy was bound from, for the customer's answers.
        Map<Id, Quote> quotesByPolicy = new Map<Id, Quote>();
        for (Quote quote : [
            SELECT Configuration__c, Opportunity.Policy__c
            FROM Quote
            WHERE Opportunity.Policy__c IN :policyIds AND Status IN ('Accepted', 'Bound')
            ORDER BY LastModifiedDate
        ]) {
            // A long text field cannot be filtered on in the query, so unconfigured quotes are skipped here.
            if (String.isNotBlank(quote.Configuration__c)) {
                quotesByPolicy.put(quote.Opportunity.Policy__c, quote);
            }
        }

        List<SObject> contents = new List<SObject>();
        for (Policy__c policy : policies) {
            if (!policy.Coverages__r.isEmpty() || policy.Annual_Premium__c == null) {
                continue;
            }
            contents.addAll(coveragesFor(policy));
            if (policy.Assets__r.isEmpty() && String.isNotBlank(policy.Insured_Item__c)) {
                contents.add(assetFor(policy));
            }
            if (quotesByPolicy.containsKey(policy.Id)) {
                contents.addAll(endorsementsFor(policy, quotesByPolicy.get(policy.Id)));
            }
        }
        // Coverages first, then assets, then endorsements, so one insert handles all three.
        contents.sort();
        insert contents;
    }

    private static Policy_Asset__c assetFor(Policy__c policy) {
        String assetType = ASSET_TYPES.containsKey(policy.Line_of_Business__c) ? ASSET_TYPES.get(policy.Line_of_Business__c) : OTHER_ASSET_TYPE;
        Account customer = policy.Account__r;
        String address = String.isBlank(customer.BillingStreet)
            ? null
            : customer.BillingStreet + ', ' + customer.BillingCity + ', ' + AntsuranceAddress.state(customer, 'Billing') + ' ' + customer.BillingPostalCode;
        return new Policy_Asset__c(
            Policy__c = policy.Id,
            Name = policy.Insured_Item__c.left(80),
            Asset_Type__c = assetType,
            Location__c = address?.left(255),
            // A building is insured for the policy's limit; a vehicle or an operation has no single insured value.
            Insured_Value__c = assetType == 'Dwelling' || assetType == 'Commercial Building' || assetType == 'Rented Residence' ? policy.Coverage_Limit__c : null
        );
    }

    /** One endorsement for each extra cover or discount the customer chose, priced as the quote priced it. */
    private static List<Policy_Endorsement__c> endorsementsFor(Policy__c policy, Quote quote) {
        Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
        Map<String, Object> answers = (Map<String, Object>) stored.get('answers');
        Map<String, Object> pricing = (Map<String, Object>) stored.get('pricing');
        // What each answered question did to the premium, by the question's label.
        Map<String, Decimal> changesByLabel = new Map<String, Decimal>();
        for (Object line : (List<Object>) pricing.get('lines')) {
            Map<String, Object> step = (Map<String, Object>) line;
            changesByLabel.put(((String) step.get('label')).substringBefore(':'), Decimal.valueOf(String.valueOf(step.get('amount'))));
        }
        List<Policy_Endorsement__c> endorsements = new List<Policy_Endorsement__c>();
        for (AntsuranceQuoteConfigurator.Section section : AntsuranceQuoteConfigurator.getQuestionnaire(policy.Line_of_Business__c)) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                String answer = answers.get(question.key) == null ? null : String.valueOf(answers.get(question.key));
                if (!ANSWER_ENDORSEMENTS.containsKey(question.key) || answer == null || NOT_TAKEN.contains(answer)) {
                    continue;
                }
                List<String> form = ANSWER_ENDORSEMENTS.get(question.key).split('\\|');
                endorsements.add(
                    new Policy_Endorsement__c(
                        Policy__c = policy.Id,
                        Name = form[0],
                        Form_Number__c = form[1],
                        Type__c = form[2],
                        Status__c = 'Active',
                        Effective_Date__c = policy.Effective_Date__c,
                        Premium_Change__c = changesByLabel.get(question.label)?.setScale(2),
                        Description__c = 'Chosen on the quote: ' + question.label + '.'
                    )
                );
            }
        }
        return endorsements;
    }
}
