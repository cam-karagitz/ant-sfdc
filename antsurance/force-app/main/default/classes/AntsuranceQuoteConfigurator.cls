/**
 * @description The quote configurator: the questions a customer answers to get a quote for each
 * line of business, how those answers price out, and loading and saving a configuration on the
 * standard Quote. The same questions serve a quote taken over the phone, online or by an agent.
 */
public with sharing class AntsuranceQuoteConfigurator {
    // A quote in one of these statuses has been answered by the customer and is no longer edited.
    private static final Set<String> LOCKED_STATUSES = new Set<String>{ 'Accepted', 'Bound', 'Declined', 'Expired' };
    // How long an issued quote stays valid.
    private static final Integer VALID_DAYS = 30;
    private static final String FIRST_STAGE = 'Submission Received';
    private static final String UNDERWRITING_STAGE = 'Underwriting Review';
    private static final Integer CONFIGURATION_VERSION = 1;
    private static final Integer NAME_LENGTH = 255;
    // A tier factor closer to 1 than this is not worth a line of its own in the breakdown.
    private static final Decimal TIER_TOLERANCE = 0.005;
    private static final Decimal MILLION = 1000000;
    private static final String NO_QUESTIONS = 'There are no quote questions for this line of business yet.';
    private static final String LOCKED = 'This quote has been answered by the customer and can no longer be changed.';
    private static final String SALE_CLOSED = 'This sale is closed, so it cannot take another quote.';
    private static final String LOAD_ERROR = 'The record could not be loaded. Check that it exists and that you have access to it.';
    private static final String NOT_A_NEW_DRAFT = 'Only a new quote that has not been saved can be discarded.';
    private static final String TIER_LINE = 'Territory and rating tier';
    // A demo auto quote keeps its known vehicles when that leaves a territory and tier factor in this range.
    private static final Decimal LOWEST_DEMO_TIER = 0.75;
    private static final Decimal HIGHEST_DEMO_TIER = 1.3;
    private static final List<String> DEMO_VEHICLES = new List<String>{
        '2021 Subaru Outback', '2019 Honda CR-V', '2022 Toyota Camry', '2020 Ford Escape', '2018 Mazda CX-5', '2023 Kia Sorento', '2017 Chevrolet Equinox'
    };
    private static final String ROUNDING_LINE = 'Rounding';
    // How many of a customer's earlier quotes to look through for answers to start from.
    private static final Integer EARLIER_QUOTES = 12;
    private static final Set<String> RESIDENCE_LINES = new Set<String>{ 'Homeowners', 'Renters', 'Commercial Property' };

    /**
     * @description One choice a question offers.
     */
    public class Option {
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String label;
        /** What picking this does to the price, for example "+15%" or "+$45". Blank when it does nothing. */
        @AuraEnabled
        public String effect;
        // Rating data stays on the server.
        public Decimal multiplier;
        public Decimal addOn;
        public String referral;
    }

    /**
     * @description One question in the configurator.
     */
    public class Question {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        /** choice, toggle, number, currency or text. */
        @AuraEnabled
        public String type;
        /** How to put the question to a customer on the phone. */
        @AuraEnabled
        public String ask;
        @AuraEnabled
        public String defaultValue;
        @AuraEnabled
        public List<Option> options = new List<Option>();
        /** Another question's key; this one shows only while that one has one of showWhenValues. */
        @AuraEnabled
        public String showWhenKey;
        @AuraEnabled
        public List<String> showWhenValues;
        // limit, deductible or exposure: what the answer feeds on the quote and in rating.
        public String role;
    }

    /**
     * @description A step of the configurator: a group of related questions.
     */
    public class Section {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String intro;
        @AuraEnabled
        public List<Question> questions = new List<Question>();
    }

    /**
     * @description One step in how a premium was built.
     */
    public class PriceLine {
        @AuraEnabled
        public String label;
        /** The step in words, for example "+15%" or "2 vehicles". */
        @AuraEnabled
        public String effect;
        /** What the step added to or took off the premium. */
        @AuraEnabled
        public Decimal amount;
    }

    /**
     * @description The price a set of answers comes to.
     */
    public class Pricing {
        @AuraEnabled
        public Decimal premium;
        @AuraEnabled
        public Decimal limitAmount;
        @AuraEnabled
        public Decimal deductible;
        @AuraEnabled
        public List<PriceLine> lines = new List<PriceLine>();
        /** Reasons the quote needs an underwriter to look at it. */
        @AuraEnabled
        public List<String> referrals = new List<String>();
    }

    /**
     * @description Everything the configurator needs for one quote.
     */
    public class Configuration {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteNumber;
        /** The name of this option, for example "Standard deductible". */
        @AuraEnabled
        public String optionName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String customerName;
        /** Phone, Online, Agent or In Person. */
        @AuraEnabled
        public String channel;
        @AuraEnabled
        public Boolean isLocked;
        @AuraEnabled
        public Boolean isConfigured;
        @AuraEnabled
        public Boolean canIssue;
        @AuraEnabled
        public Date configuredOn;
        /** For a quote nobody has answered yet: where its starting answers came from, in words. */
        @AuraEnabled
        public String prefilledFrom;
        /** The policy sale the quote belongs to. */
        @AuraEnabled
        public Id opportunityId;
        @AuraEnabled
        public List<Section> sections;
        /** The answers as a JSON object keyed by question. */
        @AuraEnabled
        public String answersJson;
        @AuraEnabled
        public Pricing pricing;
        /** Company-side rating factor for territory and tier, carried so a re-price stays consistent. */
        @AuraEnabled
        public Decimal tier;
    }

    // ---------------------------------------------------------------- the questions
    //
    // One list per line of business. Each row is one of:
    //   S|key|title|intro                                   a section
    //   Q|key|label|type|default|how to ask it|role|showWhen a question; showWhen is otherKey=value,value
    //   O|value|label|effect|referral reason                a choice; effect is x1.15 (times) or +45 (dollars)
    // A toggle is a question with the two options true and false.

    private static final Map<String, List<String>> QUESTION_ROWS = new Map<String, List<String>>{
        'Personal Auto' => new List<String>{
            'S|applicant|About the applicant|Who is being insured and their insurance history.',
            'Q|maritalStatus|Marital status|choice|married|Are you married, single, or something else?',
            'O|single|Single', 'O|married|Married or partnered|x0.95', 'O|other|Divorced or widowed',
            'Q|homeowner|Owns their home|toggle|true|Do you own your home?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|priorInsurance|Insured today|choice|3plus|Do you have auto insurance today, and how long have you had it without a gap?',
            'O|3plus|Yes, 3 years or more|x0.92', 'O|under3|Yes, under 3 years', 'O|lapsed|Lapsed in the last 6 months|x1.12',
            'O|none|No prior insurance|x1.20|No prior insurance',
            'Q|priorCarrier|Current carrier|text||Who is your insurance with today?||priorInsurance=3plus,under3',
            'S|drivers|Drivers|Everyone in the household who will drive.',
            'Q|drivers|Licensed drivers|number|2|How many licensed drivers live in the household?',
            'Q|youngestDriver|Youngest driver|choice|25to64|How old is the youngest driver?',
            'O|under21|Under 21|x1.45', 'O|21to24|21 to 24|x1.18', 'O|25to64|25 to 64', 'O|65plus|65 or older|x1.06',
            'Q|violations|Violations, past 3 years|choice|0|Any tickets or moving violations in the last three years?',
            'O|0|None', 'O|1|One|x1.10', 'O|2|Two|x1.25', 'O|3plus|Three or more|x1.50|Three or more moving violations in three years',
            'Q|accidents|At-fault accidents, past 3 years|choice|0|Any accidents where you were at fault in the last three years?',
            'O|0|None|x0.95', 'O|1|One|x1.20', 'O|2plus|Two or more|x1.55|Two or more at-fault accidents in three years',
            'Q|goodStudent|Good student|toggle|false|Is any driver a full-time student with a B average or better?', 'O|true|Yes|x0.93', 'O|false|No',
            'S|vehicles|Vehicles|What is being insured and how it is used.',
            'Q|vehicles|Vehicles to insure|number|1|How many vehicles would you like to insure?|exposure',
            'Q|vehicleList|Year, make and model|text||What is the year, make and model of each one?',
            'Q|use|Main vehicle use|choice|commute|How is the main vehicle used?',
            'O|pleasure|Pleasure|x0.94', 'O|commute|Commute to work or school', 'O|business|Business use|x1.15',
            'Q|mileage|Miles a year|choice|7to12|About how many miles do you drive in a year?',
            'O|under7|Under 7,500|x0.92', 'O|7to12|7,500 to 12,000', 'O|12to20|12,000 to 20,000|x1.08', 'O|over20|Over 20,000|x1.18',
            'Q|ownership|Main vehicle ownership|choice|financed|Is the main vehicle owned outright, financed or leased?',
            'O|owned|Owned', 'O|financed|Financed', 'O|leased|Leased|x1.03',
            'Q|antiTheft|Main vehicle anti-theft|toggle|true|Does the main vehicle have an alarm or tracking device?', 'O|true|Yes|x0.97', 'O|false|No',
            'S|coverage|Coverage|Limits and deductibles.',
            'Q|liability|Liability limits|choice|300000|How much liability cover would you like?|limit',
            'O|50000|25/50/25, state minimum|x0.82', 'O|100000|50/100/50|x0.92', 'O|300000|100/300/100', 'O|500000|250/500/100|x1.14',
            'Q|uninsured|Uninsured motorist|choice|match|Do you want uninsured motorist cover to match your liability limits?',
            'O|match|Match liability|x1.06', 'O|minimum|State minimum|x1.02', 'O|decline|Decline',
            'Q|collision|Collision deductible|choice|500|What deductible would you like if you hit something?|deductible',
            'O|250|$250|x1.08', 'O|500|$500', 'O|1000|$1,000|x0.91', 'O|none|No collision cover|x0.72',
            'Q|comprehensive|Comprehensive deductible|choice|500|And for theft, hail, glass or hitting an animal?',
            'O|100|$100|x1.05', 'O|500|$500', 'O|1000|$1,000|x0.96', 'O|none|No comprehensive cover|x0.88',
            'Q|medical|Medical payments|choice|5000|Would you like medical payments cover for you and your passengers?',
            'O|none|None', 'O|5000|$5,000|+38', 'O|10000|$10,000|+62',
            'Q|rental|Rental reimbursement|toggle|true|Do you want a rental car covered while yours is in the shop?', 'O|true|Yes|+54', 'O|false|No',
            'Q|roadside|Roadside assistance|toggle|true|Would you like towing and roadside help?', 'O|true|Yes|+36', 'O|false|No',
            'S|discounts|Discounts|Ways to bring the price down.',
            'Q|bundle|Bundle with home or renters|toggle|true|Would you like to put your home or renters policy with us too?', 'O|true|Yes|x0.90', 'O|false|No',
            'Q|payInFull|Pay in full|toggle|false|Would you rather pay for the year up front?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|paperless|Paperless and autopay|toggle|true|Are you happy with paperless documents and automatic payments?', 'O|true|Yes|x0.97', 'O|false|No',
            'Q|telematics|Safe driving app|toggle|false|Would you use our driving app for a discount?', 'O|true|Yes|x0.92', 'O|false|No'
        },
        'Homeowners' => new List<String>{
            'S|property|The home|What the house is and how it is built.',
            'Q|address|Property address|text||What is the address of the home?',
            'Q|yearBuilt|Year built|choice|1980to1999|When was the home built?',
            'O|before1950|Before 1950|x1.18', 'O|1950to1979|1950 to 1979|x1.08', 'O|1980to1999|1980 to 1999', 'O|2000plus|2000 or later|x0.94',
            'Q|squareFeet|Square feet|number|2200|About how many square feet is it?',
            'Q|construction|Construction|choice|frame|What is the home built of?',
            'O|frame|Frame', 'O|masonry|Brick or masonry|x0.93', 'O|other|Log, stucco or other|x1.08',
            'Q|roofType|Roof|choice|asphalt|What kind of roof does it have?',
            'O|asphalt|Asphalt shingle', 'O|metal|Metal|x0.95', 'O|tile|Tile or slate|x0.97', 'O|wood|Wood shake|x1.20|Wood shake roof',
            'Q|roofAge|Roof age|choice|10to20|How old is the roof?',
            'O|under10|Under 10 years|x0.95', 'O|10to20|10 to 20 years', 'O|over20|Over 20 years|x1.22|Roof is over 20 years old',
            'Q|occupancy|How it is used|choice|primary|Do you live there all year?',
            'O|primary|Primary home', 'O|secondary|Second or seasonal home|x1.12', 'O|rental|Rented to others|x1.25|Home is rented to others',
            'S|protection|Protection and hazards|What lowers or raises the chance of a claim.',
            'Q|fireProtection|Fire protection|choice|hydrant|Is there a fire hydrant close to the home?',
            'O|hydrant|Hydrant within 1,000 feet', 'O|station|Fire station within 5 miles|x1.08', 'O|rural|Neither|x1.30',
            'Q|alarm|Monitored alarm|toggle|false|Is there a centrally monitored alarm?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|waterShutoff|Automatic water shutoff|toggle|false|Is there a leak sensor that shuts the water off?', 'O|true|Yes|x0.96', 'O|false|No',
            'Q|pool|Swimming pool|toggle|false|Is there a swimming pool?', 'O|true|Yes|x1.06', 'O|false|No',
            'Q|trampoline|Trampoline|toggle|false|Is there a trampoline?', 'O|true|Yes|x1.04', 'O|false|No',
            'Q|dog|Dog in the home|choice|none|Do you have a dog?',
            'O|none|No dog', 'O|yes|Yes', 'O|restricted|Yes, with a bite history|x1.15|Dog with a bite history',
            'Q|priorClaims|Claims, past 5 years|choice|0|Have you made any home insurance claims in the last five years?',
            'O|0|None|x0.94', 'O|1|One|x1.10', 'O|2plus|Two or more|x1.35|Two or more home claims in five years',
            'S|coverage|Coverage|Limits, deductibles and extras.',
            'Q|dwelling|Dwelling limit|currency|400000|What would it cost to rebuild the home?|limit',
            'Q|personalProperty|Personal property|choice|50|How much cover do you want for your belongings?',
            'O|50|50% of dwelling', 'O|70|70% of dwelling|x1.05',
            'Q|valuation|Belongings valued at|choice|replacement|Should belongings be replaced new, or paid at their used value?',
            'O|replacement|Replacement cost|x1.06', 'O|actual|Actual cash value',
            'Q|liability|Personal liability|choice|300000|How much personal liability cover would you like?',
            'O|100000|$100,000', 'O|300000|$300,000|+28', 'O|500000|$500,000|+46',
            'Q|deductible|Deductible|choice|1000|What deductible would you like?|deductible',
            'O|500|$500|x1.10', 'O|1000|$1,000', 'O|1500|$1,500|x0.96', 'O|2000|$2,000|x0.93', 'O|2500|$2,500|x0.90', 'O|5000|$5,000|x0.82',
            'Q|windHail|Wind and hail deductible|choice|same|Would you take a higher deductible for wind and hail to save on premium?',
            'O|same|Same as above', 'O|1pct|1% of dwelling|x0.95', 'O|2pct|2% of dwelling|x0.91',
            'Q|waterBackup|Water backup|choice|none|Would you like cover for a backed-up drain or failed sump pump?',
            'O|none|None', 'O|10000|$10,000|+75', 'O|25000|$25,000|+120',
            'Q|equipment|Equipment breakdown|toggle|false|Would you like the furnace, air conditioning and appliances covered for breakdown?', 'O|true|Yes|+48', 'O|false|No',
            'Q|serviceLine|Service line|toggle|false|Would you like buried water, sewer and power lines covered?', 'O|true|Yes|+36', 'O|false|No',
            'Q|valuables|Scheduled valuables|choice|none|Do you have jewelry, art or collectibles to insure separately?',
            'O|none|None', 'O|10000|Up to $10,000|+140', 'O|25000|Up to $25,000|+320',
            'S|discounts|Discounts|Ways to bring the price down.',
            'Q|bundle|Bundle with auto|toggle|true|Would you like to put your auto policy with us too?', 'O|true|Yes|x0.88', 'O|false|No',
            'Q|newPurchase|Bought in the last 12 months|toggle|false|Did you buy the home in the last year?', 'O|true|Yes|x0.96', 'O|false|No',
            'Q|payInFull|Pay in full|toggle|false|Would you rather pay for the year up front?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|paperless|Paperless and autopay|toggle|true|Are you happy with paperless documents and automatic payments?', 'O|true|Yes|x0.97', 'O|false|No'
        },
        'Renters' => new List<String>{
            'S|home|The rental|Where you live.',
            'Q|address|Address|text||What is the address, including the unit?',
            'Q|buildingType|Building|choice|apartment|What kind of building is it?',
            'O|apartment|Apartment building', 'O|condo|Condo', 'O|house|House or duplex|x1.05',
            'Q|units|Units in the building|choice|5plus|How many units are in the building?', 'O|under5|Fewer than 5|x1.06', 'O|5plus|5 or more',
            'Q|alarm|Alarm or doorman|toggle|false|Is there an alarm, a doorman or a locked entry?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|roommates|Roommates|toggle|false|Do you share with roommates who are not family?', 'O|true|Yes|x1.08', 'O|false|No',
            'Q|dog|Dog in the home|choice|none|Do you have a dog?',
            'O|none|No dog', 'O|yes|Yes', 'O|restricted|Yes, with a bite history|x1.15|Dog with a bite history',
            'S|coverage|Coverage|What your belongings are worth and how they are covered.',
            'Q|contents|Belongings|currency|20000|What would it cost to replace everything you own?|limit',
            'Q|valuation|Valued at|choice|replacement|Should belongings be replaced new, or paid at their used value?',
            'O|replacement|Replacement cost|x1.12', 'O|actual|Actual cash value',
            'Q|liability|Personal liability|choice|100000|How much personal liability cover would you like?',
            'O|100000|$100,000', 'O|300000|$300,000|+18', 'O|500000|$500,000|+30',
            'Q|deductible|Deductible|choice|500|What deductible would you like?|deductible',
            'O|250|$250|x1.06', 'O|500|$500', 'O|1000|$1,000|x0.90',
            'Q|waterBackup|Water backup|toggle|false|Would you like cover for a backed-up drain?', 'O|true|Yes|+30', 'O|false|No',
            'Q|identityTheft|Identity theft|toggle|false|Would you like identity theft cover?', 'O|true|Yes|+25', 'O|false|No',
            'S|discounts|Discounts|Ways to bring the price down.',
            'Q|bundle|Bundle with auto|toggle|true|Would you like to put your auto policy with us too?', 'O|true|Yes|x0.90', 'O|false|No',
            'Q|payInFull|Pay in full|toggle|false|Would you rather pay for the year up front?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|paperless|Paperless and autopay|toggle|true|Are you happy with paperless documents and automatic payments?', 'O|true|Yes|x0.97', 'O|false|No'
        },
        'Umbrella' => new List<String>{
            'S|underlying|Underlying policies|An umbrella sits over other policies, which must carry enough liability.',
            'Q|type|Personal or commercial|choice|personal|Is this for a household or a business?', 'O|personal|Personal', 'O|commercial|Commercial|x4.50',
            'Q|autoLimits|Auto liability underneath|choice|meets|Does the auto policy carry at least 250/500/100?',
            'O|meets|Meets the minimum', 'O|below|Below the minimum|x1.15|Underlying auto liability is below the minimum',
            'Q|homeLimits|Home or general liability underneath|choice|meets|Does the home or liability policy carry at least $300,000?',
            'O|meets|Meets the minimum', 'O|below|Below the minimum|x1.10|Underlying liability is below the minimum',
            'S|exposures|What it sits over|The more there is to protect, the more it costs.',
            'Q|vehicles|Vehicles|number|2|How many vehicles are in the household or business?',
            'Q|properties|Properties|number|1|How many properties do you own or rent?',
            'Q|youthful|Driver under 25|toggle|false|Is any driver under 25?', 'O|true|Yes|x1.25', 'O|false|No',
            'Q|watercraft|Boat or watercraft|toggle|false|Do you own a boat or watercraft?', 'O|true|Yes|+85', 'O|false|No',
            'Q|rentalProperty|Rental property|toggle|false|Do you rent any property to others?', 'O|true|Yes|x1.12', 'O|false|No',
            'Q|violations|Major violations, past 3 years|choice|0|Has any driver had a major violation in the last three years?',
            'O|0|None', 'O|1|One|x1.10', 'O|2plus|Two or more|x1.35|Two or more major violations in three years',
            'S|coverage|Coverage|How much extra liability cover.',
            'Q|limit|Umbrella limit|choice|1000000|How much extra liability cover would you like?|limit',
            'O|500000|$500,000', 'O|1000000|$1 million', 'O|2000000|$2 million', 'O|3000000|$3 million', 'O|5000000|$5 million', 'O|10000000|$10 million',
            'Q|uninsured|Excess uninsured motorist|toggle|false|Would you like the umbrella to cover you when the other driver is uninsured?', 'O|true|Yes|+95', 'O|false|No',
            'S|discounts|Discounts|Ways to bring the price down.',
            'Q|bundle|Other policies with us|toggle|true|Are the policies underneath with us?', 'O|true|Yes|x0.92', 'O|false|No'
        },
        'General Liability' => new List<String>{
            'S|business|The business|Their trade, and how long they have been at it.',
            'Q|description|What the business does|text||Tell me what the business does, in a sentence.',
            'Q|classCode|Class of business|choice|retail|Which of these fits best?',
            'O|office|Office or professional|x0.55', 'O|retail|Retail|x0.85', 'O|restaurant|Restaurant or food service|x1.10',
            'O|habitational|Property owner or manager|x1.05', 'O|manufacturing|Manufacturing|x1.30', 'O|trucking|Trucking and logistics|x1.35',
            'O|contractor|Contractor|x1.45', 'O|roofing|Roofing or other high-hazard work|x2.60|High-hazard contracting class',
            'Q|yearsInBusiness|Years in business|choice|3to10|How long has the business been running?',
            'O|under3|Under 3 years|x1.15', 'O|3to10|3 to 10 years', 'O|over10|Over 10 years|x0.95',
            'Q|employees|Employees|number|12|How many employees are there?',
            'S|size|Size|Liability is rated on how much business is done.',
            'Q|revenue|Annual revenue|currency|1500000|What is the annual revenue?|exposure',
            'Q|subcontractors|Work given to subcontractors|choice|none|How much of the work goes to subcontractors?',
            'O|none|None', 'O|under25|Under 25%|x1.06', 'O|over25|25% or more|x1.18|Heavy use of subcontractors',
            'Q|alcohol|Sells or serves alcohol|toggle|false|Does the business sell or serve alcohol?', 'O|true|Yes|x1.12', 'O|false|No',
            'S|history|History|Past losses and how risk is managed.',
            'Q|priorLosses|Liability losses, past 3 years|choice|0|How many liability claims in the last three years?',
            'O|0|None|x0.95', 'O|1to2|One or two', 'O|3plus|Three or more|x1.30|Three or more liability losses in three years',
            'Q|safetyProgram|Written safety program|toggle|false|Is there a written safety program?', 'O|true|Yes|x0.96', 'O|false|No',
            'S|coverage|Coverage|Limits, deductible and extras.',
            'Q|occurrenceLimit|Limits|choice|1000000|What limits does the business need?|limit',
            'O|1000000|$1M each claim, $2M total', 'O|2000000|$2M each claim, $4M total|x1.22',
            'Q|deductible|Deductible|choice|1000|What deductible would you like?|deductible',
            'O|0|None', 'O|500|$500|x0.985', 'O|1000|$1,000|x0.97', 'O|2500|$2,500|x0.94', 'O|5000|$5,000|x0.91', 'O|10000|$10,000|x0.87',
            'Q|additionalInsureds|Additional insureds|choice|none|Do customers or landlords need to be named on the policy?',
            'O|none|None', 'O|blanket|Blanket additional insured|+250',
            'Q|waiver|Waiver of subrogation|toggle|false|Do any contracts ask for a waiver of subrogation?', 'O|true|Yes|+150', 'O|false|No'
        },
        'Commercial Property' => new List<String>{
            'S|building|The building|What it is and how it is protected.',
            'Q|address|Property address|text||What is the address of the building?',
            'Q|construction|Construction|choice|joisted|How is the building constructed?',
            'O|frame|Frame|x1.25', 'O|joisted|Joisted masonry', 'O|noncombustible|Non-combustible|x0.88', 'O|fireResistive|Fire resistive|x0.78',
            'Q|yearBuilt|Year built|choice|1980to1999|When was it built?',
            'O|before1950|Before 1950|x1.18', 'O|1950to1979|1950 to 1979|x1.08', 'O|1980to1999|1980 to 1999', 'O|2000plus|2000 or later|x0.94',
            'Q|occupancy|What happens there|choice|retail|What is the building used for?',
            'O|office|Office|x0.85', 'O|retail|Retail', 'O|warehouse|Warehouse|x0.95', 'O|habitational|Apartments|x1.05',
            'O|manufacturing|Manufacturing|x1.15', 'O|restaurant|Restaurant|x1.25',
            'Q|sprinklers|Sprinklers|toggle|true|Is the building fully sprinklered?', 'O|true|Yes|x0.80', 'O|false|No',
            'Q|alarm|Alarm|choice|central|What kind of fire and burglar alarm is there?',
            'O|central|Central station|x0.94', 'O|local|Local alarm only', 'O|none|None|x1.08',
            'S|values|Values|What it would cost to put things back.',
            'Q|buildingValue|Building value|currency|1500000|What would it cost to rebuild?|limit',
            'Q|contents|Contents and equipment|currency|250000|What are the contents, stock and equipment worth?|exposure',
            'Q|businessIncome|Business income|choice|none|How much lost income should be covered if the building cannot be used?',
            'O|none|None', 'O|250000|$250,000|+420', 'O|500000|$500,000|+760', 'O|1000000|$1,000,000|+1380',
            'S|coverage|Coverage|Deductible and extras.',
            'Q|deductible|Deductible|choice|5000|What deductible would you like?|deductible',
            'O|1000|$1,000|x1.06', 'O|2500|$2,500|x1.02', 'O|5000|$5,000', 'O|10000|$10,000|x0.95', 'O|25000|$25,000|x0.90', 'O|50000|$50,000|x0.85',
            'Q|valuation|Valued at|choice|replacement|Should a loss be paid at replacement cost or actual cash value?',
            'O|replacement|Replacement cost', 'O|actual|Actual cash value|x0.90',
            'Q|equipment|Equipment breakdown|toggle|true|Would you like boilers, machinery and electrical equipment covered for breakdown?', 'O|true|Yes|+310', 'O|false|No',
            'Q|ordinance|Ordinance or law|toggle|false|Would you like the cost of rebuilding to current code covered?', 'O|true|Yes|+180', 'O|false|No',
            'Q|flood|Flood|toggle|false|Is flood cover needed?', 'O|true|Yes|x1.10|Flood cover requested', 'O|false|No',
            'S|history|History|Past losses.',
            'Q|priorLosses|Property losses, past 3 years|choice|0|How many property claims in the last three years?',
            'O|0|None|x0.95', 'O|1to2|One or two', 'O|3plus|Three or more|x1.30|Three or more property losses in three years'
        },
        'Workers Compensation' => new List<String>{
            'S|business|The business|Where the work is done and what kind it is.',
            'Q|description|What the business does|text||Tell me what the business does, in a sentence.',
            'Q|state|State|choice|IL|Which state are the employees in?',
            'O|IL|Illinois', 'O|WI|Wisconsin|x0.92', 'O|MI|Michigan|x0.95', 'O|IA|Iowa|x0.90', 'O|IN|Indiana|x0.85',
            'Q|classGroup|Kind of work|choice|retail|Which of these describes most of the work?',
            'O|clerical|Clerical and office|x0.12', 'O|retail|Retail and hospitality|x0.70', 'O|healthcare|Healthcare|x0.90',
            'O|restaurant|Restaurant and brewing|x0.95', 'O|manufacturing|Manufacturing and machine shop|x1.60',
            'O|trucking|Trucking|x2.60', 'O|construction|Construction and roofing|x3.40',
            'Q|employees|Employees|number|20|How many employees are there?',
            'S|payroll|Payroll|Workers compensation is rated on payroll.',
            'Q|payroll|Annual payroll|currency|1000000|What is the total annual payroll?|exposure',
            'Q|ownersIncluded|Owners and officers covered|toggle|false|Should owners and officers be covered too?', 'O|true|Yes|x1.04', 'O|false|No',
            'S|experience|Experience|Past claims and how safety is managed.',
            'Q|experienceMod|Experience mod|choice|average|What is the current experience modification factor?',
            'O|credit|Under 0.90|x0.85', 'O|average|0.90 to 1.10', 'O|debit|1.10 to 1.40|x1.20', 'O|high|Over 1.40|x1.45|Experience mod is over 1.40',
            'Q|priorClaims|Claims, past 3 years|choice|1to3|How many workers compensation claims in the last three years?',
            'O|0|None|x0.95', 'O|1to3|One to three', 'O|4plus|Four or more|x1.25|Four or more claims in three years',
            'Q|safetyProgram|Written safety program|toggle|true|Is there a written safety program?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|returnToWork|Return-to-work program|toggle|false|Is there a return-to-work program for injured employees?', 'O|true|Yes|x0.97', 'O|false|No',
            'Q|drugFree|Drug-free workplace|toggle|false|Is the workplace certified drug-free?', 'O|true|Yes|x0.95', 'O|false|No',
            'S|coverage|Coverage|Limits and the pricing plan.',
            'Q|employersLiability|Employers liability|choice|1000000|What employers liability limit is needed?|limit',
            'O|500000|$500,000 each', 'O|1000000|$1,000,000 each|x1.02',
            'Q|plan|Pricing plan|choice|guaranteed|Would you like a fixed price, or a lower one with a deductible on each claim?',
            'O|guaranteed|Guaranteed cost', 'O|deductible|Small deductible plan|x0.93',
            'Q|deductible|Deductible each claim|choice|2500|What deductible on each claim?|deductible|plan=deductible',
            'O|1000|$1,000', 'O|2500|$2,500|x0.97', 'O|5000|$5,000|x0.95'
        },
        'Commercial Auto' => new List<String>{
            'S|fleet|The fleet|What is being insured and how far it goes.',
            'Q|vehicles|Vehicles|number|3|How many vehicles are in the fleet?|exposure',
            'Q|vehicleTypes|Kind of vehicles|choice|ppt|What kind of vehicles are they?',
            'O|ppt|Cars, vans and pickups', 'O|light|Light and medium trucks|x1.25', 'O|mixed|Mixed fleet|x1.40', 'O|heavy|Heavy trucks and tractors|x2.10',
            'Q|radius|How far they travel|choice|local|How far do they usually travel from base?',
            'O|local|Under 50 miles', 'O|intermediate|50 to 200 miles|x1.15', 'O|long|Over 200 miles|x1.40',
            'Q|use|Used for|choice|service|What are they used for?',
            'O|service|Service calls', 'O|delivery|Delivery|x1.15', 'O|hauling|Hauling for others|x1.35',
            'S|drivers|Drivers|Who drives and how they are checked.',
            'Q|drivers|Drivers|number|4|How many employees drive?',
            'Q|mvr|Driving records checked yearly|toggle|true|Do you check each driver\'s record every year?', 'O|true|Yes|x0.95', 'O|false|No',
            'Q|youngDrivers|Driver under 25|toggle|false|Is any driver under 25?', 'O|true|Yes|x1.12', 'O|false|No',
            'Q|violations|Major violations among drivers|choice|clean|Have any drivers had major violations in the last three years?',
            'O|clean|None', 'O|some|One or two|x1.12', 'O|many|Three or more|x1.35|Three or more major violations among drivers',
            'Q|telematics|Telematics or dash cameras|toggle|false|Are the vehicles fitted with telematics or cameras?', 'O|true|Yes|x0.93', 'O|false|No',
            'S|coverage|Coverage|Limits, deductible and extras.',
            'Q|liability|Liability limit|choice|1000000|What liability limit is needed?|limit',
            'O|500000|$500,000|x0.90', 'O|1000000|$1,000,000', 'O|2000000|$2,000,000|x1.18',
            'Q|physicalDamage|Physical damage deductible|choice|1000|What deductible for damage to your own vehicles?|deductible',
            'O|500|$500|x1.06', 'O|1000|$1,000', 'O|2000|$2,000|x0.95', 'O|5000|$5,000|x0.90', 'O|none|Liability only|x0.70',
            'Q|hiredNonOwned|Hired and non-owned autos|toggle|true|Do employees ever rent vehicles or use their own for work?', 'O|true|Yes|+240', 'O|false|No',
            'Q|medical|Medical payments|toggle|false|Would you like medical payments cover?', 'O|true|Yes|+90', 'O|false|No',
            'Q|towing|Towing and rental|toggle|false|Would you like towing and a rental while a vehicle is repaired?', 'O|true|Yes|+60', 'O|false|No',
            'S|history|History|Past losses.',
            'Q|priorLosses|Auto losses, past 3 years|choice|1to2|How many auto claims in the last three years?',
            'O|0|None|x0.95', 'O|1to2|One or two', 'O|3plus|Three or more|x1.30|Three or more auto losses in three years'
        }
    };

    private static Map<String, List<Section>> parsed = new Map<String, List<Section>>();

    /**
     * @description The configurator's sections and questions for a line of business.
     * @param lineOfBusiness For example Personal Auto or Workers Compensation
     * @return The sections in order, or an empty list when the line has no questions
     */
    @AuraEnabled(cacheable=true)
    public static List<Section> getQuestionnaire(String lineOfBusiness) {
        if (parsed.containsKey(lineOfBusiness)) {
            return parsed.get(lineOfBusiness);
        }
        List<Section> sections = new List<Section>();
        List<String> rows = QUESTION_ROWS.get(lineOfBusiness);
        Question question;
        for (String row : rows == null ? new List<String>() : rows) {
            List<String> parts = row.split('\\|');
            switch on parts[0] {
                when 'S' {
                    Section section = new Section();
                    section.key = parts[1];
                    section.title = parts[2];
                    section.intro = at(parts, 3);
                    sections.add(section);
                }
                when 'Q' {
                    question = new Question();
                    question.key = parts[1];
                    question.label = parts[2];
                    question.type = parts[3];
                    question.defaultValue = at(parts, 4);
                    question.ask = at(parts, 5);
                    question.role = at(parts, 6);
                    String showWhen = at(parts, 7);
                    if (showWhen != null) {
                        question.showWhenKey = showWhen.substringBefore('=');
                        question.showWhenValues = showWhen.substringAfter('=').split(',');
                    }
                    sections[sections.size() - 1].questions.add(question);
                }
                when 'O' {
                    question.options.add(parseOption(parts));
                }
            }
        }
        parsed.put(lineOfBusiness, sections);
        return sections;
    }

    private static String at(List<String> parts, Integer index) {
        return parts.size() > index && String.isNotBlank(parts[index]) ? parts[index] : null;
    }

    private static Option parseOption(List<String> parts) {
        Option option = new Option();
        option.value = parts[1];
        option.label = parts[2];
        String effect = at(parts, 3);
        if (effect != null && effect.startsWith('x')) {
            option.multiplier = Decimal.valueOf(effect.substring(1));
            option.effect = percent(option.multiplier);
        } else if (effect != null) {
            option.addOn = Decimal.valueOf(effect.substring(1));
            option.effect = '+' + money(option.addOn);
        }
        option.referral = at(parts, 4);
        return option;
    }

    // ---------------------------------------------------------------- pricing

    /**
     * @description Prices a set of answers. Called as the answers change, so the price is live.
     * @param lineOfBusiness The line the answers are for
     * @param answersJson A JSON object of answers keyed by question
     * @param tier The company-side territory and tier factor to apply; null means 1
     * @return The premium, the limit and deductible the answers ask for, and how the premium was built
     */
    @AuraEnabled
    public static Pricing price(String lineOfBusiness, String answersJson, Decimal tier) {
        return rate(lineOfBusiness, parseAnswers(answersJson), tier);
    }

    private static Map<String, Object> parseAnswers(String answersJson) {
        return String.isBlank(answersJson) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(answersJson);
    }

    @TestVisible
    private static Pricing rate(String lineOfBusiness, Map<String, Object> answers, Decimal tier) {
        List<Section> sections = getQuestionnaire(lineOfBusiness);
        if (sections.isEmpty()) {
            throw handled(NO_QUESTIONS);
        }
        Pricing pricing = new Pricing();
        Decimal running = baseRate(lineOfBusiness, answers, pricing);
        // What the steps shown so far add up to. Each step is the change in the rounded running total, so the
        // steps are whole dollars and always sum to the premium.
        Decimal shown = pricing.lines[0].amount;
        List<PriceLine> addOns = new List<PriceLine>();
        for (Section section : sections) {
            for (Question question : section.questions) {
                if (!isShown(question, answers)) {
                    continue;
                }
                String answer = answerTo(question, answers);
                if (question.role == 'limit') {
                    pricing.limitAmount = toNumber(answer);
                } else if (question.role == 'deductible') {
                    pricing.deductible = toNumber(answer);
                }
                Option chosen = chosenOption(question, answer);
                if (chosen == null) {
                    continue;
                }
                if (chosen.referral != null) {
                    pricing.referrals.add(chosen.referral);
                }
                if (chosen.multiplier != null) {
                    running *= chosen.multiplier;
                    Decimal change = dollars(running) - shown;
                    shown += change;
                    pricing.lines.add(line(question.label + ': ' + chosen.label, chosen.effect, change));
                }
                if (chosen.addOn != null) {
                    addOns.add(line(question.label + ': ' + chosen.label, 'Added cover', chosen.addOn));
                }
            }
        }
        for (PriceLine addOn : addOns) {
            running += addOn.amount;
            addOn.amount = dollars(running) - shown;
            shown += addOn.amount;
            pricing.lines.add(addOn);
        }
        untieredRunning = running;
        // A factor too small to show as a tier still counts, as a rounding step, so a quote reopened with
        // the factor it was saved with comes to the premium it was saved at.
        if (tier != null && tier != 1) {
            running *= tier;
            Decimal change = dollars(running) - shown;
            shown += change;
            if (Math.abs(tier - 1) >= TIER_TOLERANCE) {
                pricing.lines.add(line(TIER_LINE, wholePercent(tier), change));
            } else if (change != 0) {
                pricing.lines.add(line(ROUNDING_LINE, '', change));
            }
        }
        pricing.premium = shown;
        return pricing;
    }

    // The last price worked out, before the tier and before rounding to dollars: what an exact tier is solved from.
    private static Decimal untieredRunning;

    private static Decimal dollars(Decimal amount) {
        return amount.setScale(0, RoundingMode.HALF_UP);
    }

    /**
     * Makes a price come to an exact premium that was agreed some other way, such as a demo quote's.
     * The difference goes on the territory and tier step, or on a rounding step when there is none.
     */
    private static void settle(Pricing pricing, Decimal premium) {
        Decimal difference = dollars(premium) - pricing.premium;
        pricing.premium = dollars(premium);
        if (difference == 0) {
            return;
        }
        for (PriceLine step : pricing.lines) {
            if (step.label == TIER_LINE) {
                step.amount += difference;
                return;
            }
        }
        pricing.lines.add(line(ROUNDING_LINE, '', difference));
    }

    /** The starting premium for a line, from what is being insured, added as the first line of the breakdown. */
    private static Decimal baseRate(String lineOfBusiness, Map<String, Object> answers, Pricing pricing) {
        Decimal base;
        String basis;
        switch on lineOfBusiness {
            when 'Personal Auto' {
                Decimal vehicles = Math.max(1, number(answers, 'vehicles', 1));
                Decimal extraDrivers = Math.max(0, number(answers, 'drivers', 2) - vehicles);
                base = 1450 * vehicles + 150 * extraDrivers;
                basis = count(vehicles, 'vehicle') + (extraDrivers > 0 ? ' and ' + count(extraDrivers, 'extra driver') : '');
            }
            when 'Homeowners' {
                Decimal dwelling = number(answers, 'dwelling', 400000);
                base = dwelling / 1000 * 4.9;
                basis = money(dwelling) + ' to rebuild';
            }
            when 'Renters' {
                Decimal contents = number(answers, 'contents', 20000);
                base = 60 + contents / 1000 * 5.0;
                basis = money(contents) + ' of belongings';
            }
            when 'Umbrella' {
                Decimal millions = number(answers, 'limit', MILLION) / MILLION;
                Decimal vehicles = number(answers, 'vehicles', 2);
                Decimal properties = number(answers, 'properties', 1);
                base = 260 * millions + 55 * vehicles + 40 * properties;
                basis = money(millions * MILLION) + ' over ' + count(vehicles, 'vehicle') + ' and ' + count(properties, 'property', 'properties');
            }
            when 'General Liability' {
                Decimal revenue = number(answers, 'revenue', 1500000);
                base = revenue / 1000 * 4.0;
                basis = money(revenue) + ' of revenue';
            }
            when 'Commercial Property' {
                Decimal insured = number(answers, 'buildingValue', 1500000) + number(answers, 'contents', 250000);
                base = insured / 1000 * 3.6;
                basis = money(insured) + ' of building and contents';
            }
            when 'Workers Compensation' {
                Decimal payroll = number(answers, 'payroll', 1000000);
                base = payroll / 100 * 2.2;
                basis = money(payroll) + ' of payroll';
            }
            when 'Commercial Auto' {
                Decimal vehicles = Math.max(1, number(answers, 'vehicles', 3));
                base = 1850 * vehicles;
                basis = count(vehicles, 'vehicle');
            }
            when else {
                throw handled(NO_QUESTIONS);
            }
        }
        pricing.lines.add(line('Base rate', basis, base));
        return base;
    }

    private static Boolean isShown(Question question, Map<String, Object> answers) {
        if (question.showWhenKey == null) {
            return true;
        }
        Object other = answers.get(question.showWhenKey);
        return other != null && question.showWhenValues.contains(String.valueOf(other));
    }

    /**
     * @description Whether a question is asked at all, given the other answers. A question that depends on
     * another (a deductible that only a deductible plan has) is not asked while that other answer rules it out.
     * @param question The question
     * @param answers The answers so far, keyed by question
     * @return True when the question is shown to the seller
     */
    public static Boolean isAsked(Question question, Map<String, Object> answers) {
        return isShown(question, answers);
    }

    /**
     * @description The answers to keep: every answer except those to questions that are not asked. An answer
     * to a hidden question is left over from an earlier choice, shows nowhere on the page, and would mislead
     * anything that reads the stored answers (the proposal, the policy built at bind, Claude's memo).
     * @param sections The line's questions
     * @param answers The answers as given, keyed by question
     * @return A copy without the answers to questions that are not asked
     */
    public static Map<String, Object> askedAnswers(List<Section> sections, Map<String, Object> answers) {
        Map<String, Object> kept = new Map<String, Object>(answers);
        for (Section section : sections) {
            for (Question question : section.questions) {
                if (!isShown(question, answers)) {
                    kept.remove(question.key);
                }
            }
        }
        return kept;
    }

    /** The answer given, or the question's default. */
    private static String answerTo(Question question, Map<String, Object> answers) {
        Object given = answers.get(question.key);
        return given == null || String.isBlank(String.valueOf(given)) ? question.defaultValue : String.valueOf(given);
    }

    private static Option chosenOption(Question question, String answer) {
        for (Option option : question.options) {
            if (option.value == answer) {
                return option;
            }
        }
        return null;
    }

    private static Decimal number(Map<String, Object> answers, String key, Decimal fallback) {
        Decimal value = toNumber(answers.get(key) == null ? null : String.valueOf(answers.get(key)));
        return value == null || value < 0 ? fallback : value;
    }

    private static Decimal toNumber(String text) {
        try {
            return String.isBlank(text) ? null : Decimal.valueOf(text.replace(',', ''));
        } catch (TypeException e) {
            // "none" and the like are not amounts.
            return null;
        }
    }

    private static PriceLine line(String label, String effect, Decimal amount) {
        PriceLine line = new PriceLine();
        line.label = label;
        line.effect = effect;
        line.amount = dollars(amount);
        return line;
    }

    private static String percent(Decimal multiplier) {
        Decimal points = ((multiplier - 1) * 100).setScale(1, RoundingMode.HALF_UP).stripTrailingZeros();
        return (points >= 0 ? '+' : '-') + points.abs().toPlainString() + '%';
    }

    /** A rating factor as a whole percent. A tier is worked to four places, and "-18.3%" reads as a balancing figure. */
    private static String wholePercent(Decimal multiplier) {
        Decimal points = ((multiplier - 1) * 100).setScale(0, RoundingMode.HALF_UP);
        return points == 0 ? '' : (points > 0 ? '+' : '-') + points.abs().toPlainString() + '%';
    }

    private static String money(Decimal amount) {
        return '$' + amount.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String count(Decimal howMany, String singular) {
        return count(howMany, singular, singular + 's');
    }

    private static String count(Decimal howMany, String singular, String plural) {
        return howMany.intValue() + ' ' + (howMany == 1 ? singular : plural);
    }

    // ---------------------------------------------------------------- loading and saving

    /**
     * @description Loads a quote's configuration: its questions, its answers so far and its price.
     * @param quoteId The quote
     * @return The configuration. A quote that has not been configured comes back with default answers
     * @throws AuraHandledException when the quote cannot be read
     */
    @AuraEnabled
    public static Configuration getConfiguration(Id quoteId) {
        Quote quote = find(quoteId);
        Configuration configuration = new Configuration();
        configuration.quoteId = quote.Id;
        configuration.quoteNumber = quote.QuoteNumber;
        configuration.optionName = quote.Name;
        configuration.status = quote.Status;
        configuration.lineOfBusiness = quote.Opportunity?.Line_of_Business__c;
        configuration.customerName = quote.Opportunity?.Account?.Name;
        configuration.channel = quote.Submission_Channel__c;
        configuration.isLocked = LOCKED_STATUSES.contains(quote.Status);
        configuration.isConfigured = String.isNotBlank(quote.Configuration__c);
        configuration.canIssue = quote.Status == 'Draft' || String.isBlank(quote.Status);
        configuration.opportunityId = quote.OpportunityId;
        configuration.sections = getQuestionnaire(configuration.lineOfBusiness);
        configuration.tier = 1;
        if (configuration.sections.isEmpty()) {
            return configuration;
        }

        Map<String, Object> answers = defaultAnswers(configuration.sections);
        if (!configuration.isConfigured && !configuration.isLocked) {
            prefill(quote, configuration, answers);
        }
        if (configuration.isConfigured) {
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
            answers.putAll((Map<String, Object>) stored.get('answers'));
            configuration.tier = storedTier(stored);
            configuration.configuredOn = stored.get('configuredOn') == null ? null : Date.valueOf((String) stored.get('configuredOn'));
            // The price as it was when the quote was saved, so a later rate change does not rewrite history.
            configuration.pricing = (Pricing) JSON.deserialize(JSON.serialize(stored.get('pricing')), Pricing.class);
        } else {
            configuration.pricing = rate(configuration.lineOfBusiness, answers, configuration.tier);
        }
        configuration.answersJson = JSON.serialize(answers);
        return configuration;
    }

    /**
     * @description Saves a quote's answers, re-prices it on the server and updates the quote's terms.
     * @param quoteId The quote
     * @param answersJson A JSON object of answers keyed by question
     * @param channel How the quote came in: Phone, Online, Agent or In Person
     * @param issue True to also issue a draft quote: it becomes Issued, dated today and valid for 30 days
     * @param optionName What to call this option; blank leaves the quote's name as it is
     * @return The saved configuration
     * @throws AuraHandledException when the quote is locked or its line has no questions
     */
    @AuraEnabled
    public static Configuration saveConfiguration(Id quoteId, String answersJson, String channel, Boolean issue, String optionName) {
        Quote quote = find(quoteId);
        if (LOCKED_STATUSES.contains(quote.Status)) {
            throw handled(LOCKED);
        }
        String lineOfBusiness = quote.Opportunity?.Line_of_Business__c;
        List<Section> sections = getQuestionnaire(lineOfBusiness);
        if (sections.isEmpty()) {
            throw handled(NO_QUESTIONS);
        }
        Map<String, Object> answers = defaultAnswers(sections);
        answers.putAll(parseAnswers(answersJson));
        Decimal tier = String.isBlank(quote.Configuration__c) ? 1 : storedTier((Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c));
        Pricing pricing = rate(lineOfBusiness, answers, tier);
        Boolean isReferred = !pricing.referrals.isEmpty();

        Quote changes = new Quote(
            Id = quote.Id,
            Configuration__c = serialize(askedAnswers(sections, answers), pricing, tier, Date.today()),
            Submission_Channel__c = channel,
            Annual_Premium__c = pricing.premium,
            Coverage_Limit__c = pricing.limitAmount,
            Deductible__c = pricing.deductible,
            Needs_Underwriting_Review__c = isReferred
        );
        if (String.isNotBlank(optionName)) {
            changes.Name = optionName.trim().left(NAME_LENGTH);
        }
        Boolean isDraft = quote.Status == 'Draft' || String.isBlank(quote.Status);
        // A quote with a reason for an underwriter to look at it is never issued from here: it stays a
        // draft and waits for the underwriter's decision, which is what issues it.
        if (issue == true && isDraft && !isReferred) {
            changes.Status = 'Issued';
            changes.Issued_Date__c = Date.today();
            changes.ExpirationDate = Date.today().addDays(VALID_DAYS);
        }
        update as user changes;
        if (issue == true && isDraft && isReferred) {
            sendToUnderwriting(quote.OpportunityId);
        }
        return getConfiguration(quoteId);
    }

    /** A sale whose quote was sent to underwriting moves to that stage, unless it is already there or further on. */
    private static void sendToUnderwriting(Id opportunityId) {
        List<Opportunity> sales = [SELECT Id, StageName FROM Opportunity WHERE Id = :opportunityId AND StageName = :FIRST_STAGE WITH USER_MODE LIMIT 1];
        if (!sales.isEmpty()) {
            update as user new Opportunity(Id = sales[0].Id, StageName = UNDERWRITING_STAGE);
        }
    }

    /**
     * @description Starts a new draft quote on a policy sale, ready to be configured.
     * @param opportunityId The policy sale
     * @return The new quote's Id
     * @throws AuraHandledException when the sale is closed or cannot be read
     */
    @AuraEnabled
    public static Id startQuote(Id opportunityId) {
        List<Opportunity> sales = [SELECT Id, IsClosed, (SELECT Id FROM Quotes) FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1];
        if (sales.isEmpty()) {
            throw handled(LOAD_ERROR);
        }
        if (sales[0].IsClosed) {
            throw handled(SALE_CLOSED);
        }
        Quote quote = new Quote(
            OpportunityId = opportunityId,
            Name = 'Option ' + (sales[0].Quotes.size() + 1),
            Status = 'Draft',
            Underwriter__c = UserInfo.getName()
        );
        insert as user quote;
        return quote.Id;
    }

    /**
     * @description Throws away a new quote that was started but never saved, for when the customer does
     * not go ahead. A quote that has been saved or issued is kept.
     * @param quoteId The draft quote
     * @return The policy sale it was on, to go back to
     * @throws AuraHandledException when the quote has been saved or is no longer a draft
     */
    @AuraEnabled
    public static Id discardDraft(Id quoteId) {
        Quote quote = find(quoteId);
        if (quote.Status != 'Draft' || String.isNotBlank(quote.Configuration__c)) {
            throw handled(NOT_A_NEW_DRAFT);
        }
        Id saleId = quote.OpportunityId;
        delete as user new Quote(Id = quote.Id);
        return saleId;
    }

    /**
     * @description Claude's suggestions for a quote while its questions are being answered: up to three changes
     * the seller could make, each checked against the questions and priced here. See AntsuranceQuoteAdvisor.
     * @param quoteId The quote
     * @param answersJson The answers so far, as a JSON object keyed by question
     * @param tier The territory and tier factor the price is using
     * @param stepIndex The step the seller is on, from zero; the number of steps means Review
     * @return The suggestions, and on Review a sentence to put the option to the customer
     */
    @AuraEnabled
    public static AntsuranceQuoteAdvisor.Advice advise(Id quoteId, String answersJson, Decimal tier, Integer stepIndex) {
        return AntsuranceQuoteAdvisor.advise(quoteId, answersJson, tier, stepIndex);
    }

    /**
     * @description Checks and prices the suggestions on screen again after an answer has changed, without asking Claude.
     * @param lineOfBusiness The line being quoted
     * @param answersJson The answers now
     * @param tier The territory and tier factor the price is using
     * @param stepIndex The step the seller is on
     * @param proposalsJson The suggestions on screen, as a JSON list
     * @return Those that still apply, with the exact change each would make to the premium now
     */
    @AuraEnabled
    public static List<AntsuranceQuoteAdvisor.Suggestion> recheckAdvice(String lineOfBusiness, String answersJson, Decimal tier, Integer stepIndex, String proposalsJson) {
        return AntsuranceQuoteAdvisor.recheck(lineOfBusiness, answersJson, tier, stepIndex, proposalsJson);
    }

    private static Quote find(Id quoteId) {
        List<Quote> quotes = [
            SELECT Id, Name, QuoteNumber, Status, Configuration__c, Submission_Channel__c, OpportunityId,
                Opportunity.Line_of_Business__c, Opportunity.AccountId, Opportunity.Account.Name, Opportunity.Account.Customer_Segment__c,
                Opportunity.Account.Industry, Opportunity.Account.NumberOfEmployees, Opportunity.Account.Description,
                Opportunity.Account.BillingStreet, Opportunity.Account.BillingCity, Opportunity.Account.BillingState,
                Opportunity.Account.BillingPostalCode, Opportunity.Policy__r.Name, Opportunity.Policy__r.Line_of_Business__c,
                Opportunity.Policy__r.Insured_Item__c, Opportunity.Policy__r.Coverage_Limit__c, Opportunity.Policy__r.Deductible__c,
                Opportunity.Policy__r.Annual_Premium__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            throw handled(LOAD_ERROR);
        }
        return quotes[0];
    }

    /** The territory and tier factor kept with a saved configuration. JSON numbers come back as Integer or Decimal. */
    private static Decimal storedTier(Map<String, Object> stored) {
        Decimal tier = stored.get('tier') == null ? null : toNumber(String.valueOf(stored.get('tier')));
        return tier == null || tier <= 0 ? 1 : tier;
    }

    private static Map<String, Object> defaultAnswers(List<Section> sections) {
        Map<String, Object> answers = new Map<String, Object>();
        for (Section section : sections) {
            for (Question question : section.questions) {
                if (question.defaultValue != null) {
                    answers.put(question.key, question.defaultValue);
                }
            }
        }
        return answers;
    }

    /** The JSON kept in Quote.Configuration__c: the answers, the price they came to and when. */
    private static String serialize(Map<String, Object> answers, Pricing pricing, Decimal tier, Date configuredOn) {
        return JSON.serialize(
            new Map<String, Object>{
                'version' => CONFIGURATION_VERSION,
                'configuredOn' => String.valueOf(configuredOn == null ? Date.today() : configuredOn),
                'tier' => tier,
                'answers' => answers,
                'pricing' => pricing
            }
        );
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException handled = new AuraHandledException(message);
        handled.setMessage(message);
        return handled;
    }

    // ---------------------------------------------------------------- what is already known

    // What each industry is in the configurator's terms: general liability class, workers compensation class,
    // what a building is used for, and the kind of vehicles.
    private static final Map<String, String> INDUSTRY_ANSWERS = new Map<String, String>{
        'Manufacturing' => 'manufacturing|manufacturing|manufacturing|light',
        'Construction' => 'contractor|construction|warehouse|light',
        'Food & Beverage' => 'restaurant|restaurant|restaurant|ppt',
        'Hospitality' => 'restaurant|retail|habitational|ppt',
        'Transportation' => 'trucking|trucking|warehouse|heavy',
        'Healthcare' => 'office|healthcare|office|ppt',
        'Retail' => 'retail|retail|retail|ppt',
        'Recreation' => 'retail|retail|retail|ppt',
        'Other' => 'habitational|clerical|habitational|ppt'
    };

    /**
     * @description The quote questions a customer record already answers: who they are, where, what the
     * business does and how big it is, and the vehicles on the policy the sale is about.
     * @param customer The customer, with its address, segment, industry, headcount and description
     * @param linked The policy the sale renews or is about, or null
     * @return Answers keyed by question; keys a line does not ask are ignored when they are applied
     */
    public static Map<String, Object> knownAnswers(Account customer, Policy__c linked) {
        Map<String, Object> known = new Map<String, Object>();
        if (customer == null) {
            return known;
        }
        if (String.isNotBlank(customer.BillingStreet)) {
            known.put('address', customer.BillingStreet + ', ' + customer.BillingCity + ', ' + AntsuranceAddress.state(customer, 'Billing') + ' ' + customer.BillingPostalCode);
        }
        if (customer.Customer_Segment__c != 'Commercial Lines') {
            if (linked != null && linked.Line_of_Business__c == 'Personal Auto' && String.isNotBlank(linked.Insured_Item__c)) {
                known.put('vehicleList', linked.Insured_Item__c);
            }
            known.put('type', 'personal');
            return known;
        }
        List<String> classes = INDUSTRY_ANSWERS.containsKey(customer.Industry) ? INDUSTRY_ANSWERS.get(customer.Industry).split('\\|') : null;
        if (classes != null) {
            known.put('classCode', classes[0]);
            known.put('classGroup', classes[1]);
            known.put('occupancy', classes[2]);
            known.put('vehicleTypes', classes[3]);
        }
        String operations = String.isNotBlank(customer.Description) ? customer.Description : (customer.Industry == 'Other' ? 'Property management' : customer.Industry);
        if (String.isNotBlank(operations)) {
            known.put('description', operations.removeEnd('.'));
        }
        if (customer.NumberOfEmployees != null) {
            known.put('employees', customer.NumberOfEmployees);
        }
        known.put('state', AntsuranceAddress.state(customer, 'Billing'));
        known.put('type', 'commercial');
        // Only a business that feeds or hosts people sells alcohol; a machine shop does not.
        String industry = customer.Industry == null ? '' : customer.Industry;
        known.put('alcohol', industry.contains('Food') || industry.contains('Hospitality') ? 'true' : 'false');
        return known;
    }

    /** True when stored answers carry a reason for an underwriter to look at the quote. */
    public static Boolean needsReview(String configurationJson) {
        if (String.isBlank(configurationJson)) {
            return false;
        }
        Map<String, Object> pricing = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(configurationJson)).get('pricing');
        return pricing != null && pricing.get('referrals') != null && !((List<Object>) pricing.get('referrals')).isEmpty();
    }

    /**
     * Starting answers for a quote nobody has answered yet, so the seller is not asking for what we already
     * hold. In order: what the customer record says; the most recent configured quote for this customer and
     * line, which is how a renewal starts from the expiring terms; failing that, the terms of the policy the
     * sale is about.
     */
    private static void prefill(Quote quote, Configuration configuration, Map<String, Object> answers) {
        Opportunity sale = quote.Opportunity;
        if (sale == null) {
            return;
        }
        String lineOfBusiness = sale.Line_of_Business__c;
        Policy__c linked = sale.Policy__r != null && sale.Policy__r.Line_of_Business__c == lineOfBusiness ? sale.Policy__r : null;
        applyKnown(configuration.sections, answers, knownAnswers(sale.Account, linked));
        applyBook(configuration.sections, answers, sale.AccountId, lineOfBusiness, linked);
        configuration.prefilledFrom = 'what we hold on ' + sale.Account?.Name;

        for (Quote earlier : [
            SELECT QuoteNumber, Configuration__c
            FROM Quote
            WHERE Opportunity.AccountId = :sale.AccountId AND Opportunity.Line_of_Business__c = :lineOfBusiness AND Id != :quote.Id
            WITH USER_MODE
            ORDER BY Issued_Date__c DESC NULLS LAST, QuoteNumber ASC
            LIMIT :EARLIER_QUOTES
        ]) {
            if (String.isBlank(earlier.Configuration__c)) {
                continue;
            }
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(earlier.Configuration__c);
            answers.putAll((Map<String, Object>) stored.get('answers'));
            // The same territory and tier, so the same answers come to the same price.
            configuration.tier = storedTier(stored);
            configuration.prefilledFrom = 'the answers on quote ' + earlier.QuoteNumber;
            return;
        }
        if (linked == null) {
            return;
        }
        Question exposure;
        for (Section section : configuration.sections) {
            for (Question question : section.questions) {
                if (question.role == 'limit' && linked.Coverage_Limit__c != null) {
                    answers.put(question.key, nearest(question, linked.Coverage_Limit__c));
                } else if (question.role == 'deductible') {
                    takeDeductible(configuration.sections, answers, question, linked.Deductible__c);
                } else if (question.role == 'exposure' && !answers.containsKey('vehicleList')) {
                    exposure = question;
                }
            }
        }
        if (exposure != null && linked.Annual_Premium__c != null && linked.Annual_Premium__c > 0) {
            answers.put(exposure.key, solveExposure(lineOfBusiness, answers, exposure, linked.Annual_Premium__c));
        }
        configuration.prefilledFrom = 'policy ' + linked.Name + ' and what we hold on ' + sale.Account?.Name;
    }

    /** Counts taken from the customer's policies in force: how many vehicles and properties there are to insure or sit over. */
    private static void applyBook(List<Section> sections, Map<String, Object> answers, Id accountId, String lineOfBusiness, Policy__c linked) {
        Integer vehicles = 0;
        Integer properties = 0;
        Integer otherPolicies = 0;
        Boolean ownsHome = false;
        for (Policy__c policy : [
            SELECT Line_of_Business__c, Insured_Item__c
            FROM Policy__c
            WHERE Account__c = :accountId AND Status__c IN ('Active', 'Pending Renewal')
            WITH USER_MODE
            LIMIT 50
        ]) {
            if (policy.Line_of_Business__c == 'Personal Auto' && String.isNotBlank(policy.Insured_Item__c)) {
                vehicles += policy.Insured_Item__c.split(' and ').size();
            }
            if (RESIDENCE_LINES.contains(policy.Line_of_Business__c)) {
                properties++;
            }
            ownsHome = ownsHome || policy.Line_of_Business__c == 'Homeowners';
            if (policy.Line_of_Business__c != lineOfBusiness) {
                otherPolicies++;
            }
        }
        Map<String, Object> book = new Map<String, Object>{ 'bundle' => String.valueOf(otherPolicies > 0) };
        if (lineOfBusiness == 'Umbrella') {
            if (vehicles > 0) {
                book.put('vehicles', vehicles);
            }
            book.put('properties', Math.max(properties, 1));
        } else if (lineOfBusiness == 'Personal Auto') {
            book.put('homeowner', String.valueOf(ownsHome));
            if (linked != null && String.isNotBlank(linked.Insured_Item__c)) {
                Integer insured = linked.Insured_Item__c.split(' and ').size();
                answers.put('vehicles', insured);
                answers.put('drivers', Math.max(insured, 1));
            }
        }
        applyKnown(sections, answers, book);
    }

    /**
     * Sets a deductible question from an amount. Where the question only applies under one answer to an
     * earlier question (a deductible plan), that earlier answer is set to match.
     */
    private static void takeDeductible(List<Section> sections, Map<String, Object> answers, Question question, Decimal deductible) {
        Boolean hasDeductible = deductible != null && deductible > 0;
        if (question.showWhenKey == null) {
            answers.put(question.key, nearest(question, hasDeductible ? deductible : 0));
            return;
        }
        if (hasDeductible) {
            answers.put(question.showWhenKey, question.showWhenValues[0]);
            answers.put(question.key, nearest(question, deductible));
            return;
        }
        // No deductible: put the earlier question back on an answer that does not ask for one.
        for (Section section : sections) {
            for (Question other : section.questions) {
                if (other.key == question.showWhenKey && !question.showWhenValues.contains(other.defaultValue)) {
                    answers.put(other.key, other.defaultValue);
                }
            }
        }
    }

    // ---------------------------------------------------------------- demo data

    // How demo answers vary from quote to quote: a question takes its next option on every Nth quote.
    private static final Integer VARY_EVERY = 4;
    private static final Integer SEARCH_STEPS = 40;
    private static final Integer MOST_UNITS = 300;
    private static final Decimal LARGEST_EXPOSURE = 2000000000;
    private static final Decimal COMMERCIAL_UMBRELLA_FROM = 3000;

    /**
     * @description Builds a believable configuration for a demo quote whose premium, limit and deductible
     * are already decided: plausible answers that vary from quote to quote, with the insured amounts
     * worked back so the answers price out to exactly that premium.
     * @param lineOfBusiness The quote's line
     * @param premium The premium the quote carries
     * @param limitAmount The limit the quote carries
     * @param deductible The deductible the quote carries
     * @param sequence Any number; different numbers give different answers
     * @param known Answers already known about the customer, such as their address or class of business
     * @param configuredOn The day the answers were taken, which is never after the quote went out
     * @return JSON for Quote.Configuration__c, or null when the line has no questions
     */
    public static String demoConfiguration(
        String lineOfBusiness, Decimal premium, Decimal limitAmount, Decimal deductible, Integer sequence, Map<String, Object> known, Date configuredOn
    ) {
        List<Section> sections = getQuestionnaire(lineOfBusiness);
        if (sections.isEmpty() || premium == null || premium <= 0) {
            return null;
        }
        Map<String, Object> answers = defaultAnswers(sections);
        Question exposure;
        List<Question> deductibles = new List<Question>();
        Integer position = 0;
        for (Section section : sections) {
            for (Question question : section.questions) {
                position++;
                if (question.role == 'limit') {
                    answers.put(question.key, nearest(question, limitAmount));
                } else if (question.role == 'deductible') {
                    deductibles.add(question);
                } else if (question.role == 'exposure') {
                    exposure = question;
                } else if (!question.options.isEmpty() && Math.mod(sequence + position, VARY_EVERY) == 0) {
                    // Move to the next option, skipping any that would send the quote to underwriting.
                    Integer current = indexOf(question, (String) answers.get(question.key));
                    Option next = question.options[Math.mod(current + 1, question.options.size())];
                    if (next.referral == null) {
                        answers.put(question.key, next.value);
                    }
                }
            }
        }
        if (lineOfBusiness == 'Umbrella') {
            answers.put('type', premium >= COMMERCIAL_UMBRELLA_FROM ? 'commercial' : 'personal');
        }
        applyKnown(sections, answers, known);
        // After the answers have been varied, so a deductible plan always agrees with the quote's deductible.
        for (Question question : deductibles) {
            takeDeductible(sections, answers, question, deductible);
        }
        if (exposure != null) {
            answers.put(exposure.key, solveExposure(lineOfBusiness, answers, exposure, premium));
        }
        if (lineOfBusiness == 'Personal Auto') {
            listVehicles(answers, premium, sequence);
        }
        // Whatever the answers do not explain is the territory and tier the customer rates in.
        // The factor is solved from the unrounded price and kept to eight places, so pricing the same answers
        // with it again gives this premium to the dollar. Four places left a live quote a few dollars off its sale.
        rate(lineOfBusiness, answers, 1);
        Decimal untiered = untieredRunning;
        Decimal tier = untiered > 0 ? (premium / untiered).setScale(8, RoundingMode.HALF_UP) : 1;
        Pricing pricing = rate(lineOfBusiness, answers, tier);
        settle(pricing, premium);
        pricing.limitAmount = limitAmount;
        pricing.deductible = deductible;
        return serialize(askedAnswers(sections, answers), pricing, tier, configuredOn);
    }

    /**
     * Makes a demo auto quote's vehicle count and its list of vehicles agree. The vehicles already known
     * (from the policy the sale is about) set the count when that prices within reach of the premium;
     * otherwise the count that fits the premium stands and the list is cut or filled out to match.
     */
    private static void listVehicles(Map<String, Object> answers, Decimal premium, Integer sequence) {
        List<String> listed = new List<String>();
        String known = (String) answers.get('vehicleList');
        if (String.isNotBlank(known)) {
            for (String vehicle : known.replace(' and ', ',').split(',')) {
                if (String.isNotBlank(vehicle)) {
                    listed.add(vehicle.trim());
                }
            }
        }
        if (!listed.isEmpty()) {
            Map<String, Object> trial = answers.clone();
            trial.put('vehicles', String.valueOf(listed.size()));
            Decimal price = rate('Personal Auto', trial, 1).premium;
            if (price > 0 && premium / price >= LOWEST_DEMO_TIER && premium / price <= HIGHEST_DEMO_TIER) {
                answers.put('vehicles', String.valueOf(listed.size()));
            }
        }
        Integer insured = Integer.valueOf(String.valueOf(answers.get('vehicles')));
        while (listed.size() > insured) {
            listed.remove(listed.size() - 1);
        }
        // One pass over the demo vehicles is enough for a household; a larger count keeps the list it has.
        for (Integer tries = 0; listed.size() < insured && tries < DEMO_VEHICLES.size(); tries++) {
            String vehicle = DEMO_VEHICLES[Math.mod(Math.abs(sequence) + tries, DEMO_VEHICLES.size())];
            if (!listed.contains(vehicle)) {
                listed.add(vehicle);
            }
        }
        if (listed.isEmpty()) {
            return;
        }
        String last = listed.remove(listed.size() - 1);
        answers.put('vehicleList', listed.isEmpty() ? last : String.join(listed, ', ') + ' and ' + last);
    }

    /** Takes what is already known about the customer, where it answers one of the line's questions with a valid choice. */
    private static void applyKnown(List<Section> sections, Map<String, Object> answers, Map<String, Object> known) {
        if (known == null) {
            return;
        }
        for (Section section : sections) {
            for (Question question : section.questions) {
                Object value = known.get(question.key);
                if (value == null || question.role != null) {
                    continue;
                }
                if (question.options.isEmpty() || chosenOption(question, String.valueOf(value)) != null) {
                    answers.put(question.key, value);
                }
            }
        }
    }

    /** The option whose amount is closest to the target, or the target itself for a typed-in amount. */
    private static String nearest(Question question, Decimal target) {
        if (question.options.isEmpty()) {
            return target == null ? question.defaultValue : String.valueOf(target.setScale(0));
        }
        String best = question.defaultValue;
        Decimal bestGap;
        for (Option option : question.options) {
            Decimal amount = toNumber(option.value);
            if (amount == null || target == null) {
                continue;
            }
            Decimal gap = Math.abs(amount - target);
            if (bestGap == null || gap < bestGap) {
                bestGap = gap;
                best = option.value;
            }
        }
        return best;
    }

    private static Integer indexOf(Question question, String value) {
        for (Integer i = 0; i < question.options.size(); i++) {
            if (question.options[i].value == value) {
                return i;
            }
        }
        return 0;
    }

    /** The insured amount or count that brings the price closest to the premium. */
    private static String solveExposure(String lineOfBusiness, Map<String, Object> answers, Question exposure, Decimal premium) {
        Map<String, Object> trial = answers.clone();
        if (exposure.type == 'number') {
            Integer best = 1;
            Decimal bestGap;
            for (Integer howMany = 1; howMany <= MOST_UNITS; howMany++) {
                trial.put(exposure.key, howMany);
                Decimal price = rate(lineOfBusiness, trial, 1).premium;
                // How far off the price is, as a ratio, so twice too much counts the same as half enough.
                Decimal gap = price > premium ? price / premium : premium / price;
                if (bestGap == null || gap < bestGap) {
                    bestGap = gap;
                    best = howMany;
                }
                if (price > premium) {
                    break;
                }
            }
            return String.valueOf(best);
        }
        Decimal low = 0;
        Decimal high = LARGEST_EXPOSURE;
        for (Integer step = 0; step < SEARCH_STEPS; step++) {
            Decimal middle = (low + high) / 2;
            trial.put(exposure.key, middle);
            if (rate(lineOfBusiness, trial, 1).premium > premium) {
                high = middle;
            } else {
                low = middle;
            }
        }
        // Round to the nearest thousand, the way an insured amount is stated.
        return String.valueOf((low / 1000).setScale(0, RoundingMode.HALF_UP) * 1000);
    }
}
