"""Cases for the quote advisor: a line, the answers so far, the step the seller is on, what we hold on the
customer, and the one suggestion a good adviser would make. `expect` is (kind, question key, acceptable values).

The facts are written the way AntsuranceQuoteAdvisor.customerFacts writes them from the org's records."""

CASES = [
    {
        'id': 'auto-teen-good-student',
        'line': 'Personal Auto', 'step': 'drivers',
        'answers': {'drivers': 3, 'vehicles': 2, 'youngestDriver': 'under21', 'goodStudent': 'false'},
        'facts': "Customer: Reyes Household, Personal Lines, a customer since 2020.\n"
                 "Notes on the customer: Sofia has just passed her road test. She is a junior on the honor roll with a 3.7 grade average.\n"
                 "People: Daniel Reyes (Spouse or Partner, age 46, licensed driver); Maria Reyes (Head of Household, age 44, licensed driver); Sofia Reyes (Dependent, age 17, licensed driver).\n"
                 "Policies in force with us:\n- Homeowners ANT-HO-204534 (Active): premium $1,890, limit $485,000, deductible $1,000\n"
                 "Claims in the past 3 years: none.",
        'expect': ('change', 'goodStudent', ['true']),
    },
    {
        'id': 'home-basement-water-backup',
        'line': 'Homeowners', 'step': 'coverage',
        'answers': {'waterBackup': 'none', 'dwelling': 420000, 'priorClaims': '1'},
        'facts': "Customer: Okafor Household, Personal Lines, a customer since 2019.\n"
                 "People: Amara Okafor (Head of Household, age 39); Chinedu Okafor (Spouse or Partner, age 41).\n"
                 "Policies in force with us:\n- Personal Auto ANT-PA-204602 (Active): premium $1,640, limit $300,000, deductible $500, insures 2021 Subaru Outback\n"
                 "Claims in the past 3 years:\n- 2025-11-02, Homeowners, Water Damage: Sump pump failed and flooded the finished basement (Closed, paid $0, reserved $0)\n"
                 "Notes on the customer: The 2025 sump pump claim was not paid because the old policy had no water backup cover.",
        'expect': ('change', 'waterBackup', ['10000', '25000']),
    },
    {
        'id': 'auto-has-home-policy',
        'line': 'Personal Auto', 'step': 'review',
        'answers': {'homeowner': 'false', 'bundle': 'false', 'vehicles': 1, 'drivers': 1},
        'facts': "Customer: Whitfield Household, Personal Lines, a customer since 2017.\n"
                 "People: Marcus Whitfield (Head of Household, age 52, licensed driver).\n"
                 "Policies in force with us:\n- Homeowners ANT-HO-204806 (Active): premium $1,730, limit $390,000, deductible $1,000, insures 88 Elm St, Wheaton, IL\n"
                 "Claims in the past 3 years: none.",
        'expect': ('change', None, None),
        'any_of': [('bundle', ['true']), ('homeowner', ['true'])],
    },
    {
        'id': 'gl-subcontractor-share',
        'line': 'General Liability', 'step': 'size',
        'answers': {'classCode': 'contractor', 'subcontractors': 'over25', 'revenue': 4200000, 'employees': 31},
        'facts': "Customer: Bluestem Builders, Commercial Lines, a customer since 2021.\n"
                 "Business: Construction, 31 employees, revenue $4,200,000.\n"
                 "What they do: Commercial tenant fit-outs and light remodels.\n"
                 "Notes on the customer: Last year's premium audit found 18% of work was subcontracted, all to insured subcontractors with certificates on file.\n"
                 "Policies in force with us:\n- Workers Compensation ANT-WC-205201 (Active): premium $61,300, limit $1,000,000, deductible none\n"
                 "Claims in the past 3 years: none.",
        'expect': ('change', 'subcontractors', ['under25']),
    },
    {
        'id': 'auto-under-an-umbrella',
        'line': 'Personal Auto', 'step': 'coverage',
        'answers': {'liability': '300000', 'vehicles': 2, 'drivers': 2},
        'facts': "Customer: Alvarez Household, Personal Lines, a customer since 2016.\n"
                 "People: Elena Alvarez (Head of Household, age 48, licensed driver); Tomas Alvarez (Spouse or Partner, age 50, licensed driver).\n"
                 "Policies in force with us:\n- Homeowners ANT-HO-204711 (Active): premium $2,240, limit $610,000, deductible $2,500\n"
                 "- Umbrella ANT-UM-204728 (Active): premium $440, limit $1,000,000, deductible none\n"
                 "Claims in the past 3 years: none.",
        'expect': ('change', 'liability', ['500000']),
    },
    {
        'id': 'home-wants-a-lower-bill',
        'line': 'Homeowners', 'step': 'coverage',
        'answers': {'deductible': '500', 'priorClaims': '0', 'dwelling': 380000},
        'facts': "Customer: Schmidt Household, Personal Lines, a customer since 2014.\n"
                 "Notes on the customer: Asked twice this year for ways to lower the bill. Comfortable carrying more of a small loss themselves. No claims in nine years.\n"
                 "People: Greta Schmidt (Head of Household, age 61).\n"
                 "Policies in force with us:\n- Personal Auto ANT-PA-204388 (Active): premium $1,210, limit $300,000, deductible $1,000\n"
                 "Claims in the past 3 years: none.",
        'expect': ('change', 'deductible', ['1000', '1500', '2000', '2500', '5000']),
    },
    {
        'id': 'wc-return-to-work',
        'line': 'Workers Compensation', 'step': 'experience',
        'answers': {'classGroup': 'manufacturing', 'payroll': 6400000, 'employees': 112, 'returnToWork': 'false', 'safetyProgram': 'true'},
        'facts': "Customer: Ironwood Machine Works, Commercial Lines, a customer since 2018.\n"
                 "Business: Manufacturing, 112 employees, revenue $7,860,000.\n"
                 "This sale: Renewal of policy ANT-WC-205146.\n"
                 "Policies in force with us:\n- Workers Compensation ANT-WC-205146 (Pending Renewal): premium $149,500, limit $1,000,000, deductible none. "
                 "Underwriting notes: Formal return-to-work program in place since 2024, with light-duty roles documented for every department.\n"
                 "Claims in the past 3 years:\n- 2026-03-14, Workers Compensation, Bodily Injury: Lathe operator lacerated hand (Closed, paid $18,400, reserved $18,400)",
        'expect': ('change', 'returnToWork', ['true']),
    },
    {
        'id': 'fleet-dash-cameras',
        'line': 'Commercial Auto', 'step': 'drivers',
        'answers': {'vehicles': 14, 'drivers': 16, 'vehicleTypes': 'light', 'use': 'delivery', 'telematics': 'false'},
        'facts': "Customer: Sagebrush Freight Lines, Commercial Lines, a customer since 2022.\n"
                 "Business: Transportation, 38 employees, revenue $9,100,000.\n"
                 "What they do: Regional parcel and pallet delivery.\n"
                 "Notes on the customer: Every van was fitted with dash cameras and GPS telematics in March 2026 after two disputed collisions.\n"
                 "Policies in force with us: none.\nClaims in the past 3 years: none.",
        'expect': ('change', 'telematics', ['true']),
    },
    {
        # What not to do: a customer under an umbrella who wants the price down must not be taken below the umbrella's minimum.
        'id': 'auto-umbrella-wants-cheaper',
        'line': 'Personal Auto', 'step': 'coverage',
        'answers': {'liability': '500000', 'vehicles': 2, 'drivers': 2, 'collision': '500'},
        'facts': "Customer: Alvarez Household, Personal Lines, a customer since 2016.\n"
                 "Notes on the customer: Tomas asked for the cheapest auto cover we can write and suggested dropping the liability limits.\n"
                 "People: Elena Alvarez (Head of Household, age 48, licensed driver); Tomas Alvarez (Spouse or Partner, age 50, licensed driver).\n"
                 "Policies in force with us:\n- Umbrella ANT-UM-204728 (Active): premium $440, limit $1,000,000, deductible none\n"
                 "Claims in the past 3 years: none.",
        'expect': ('avoid', 'liability', ['50000', '100000', '300000']),
    },
]
