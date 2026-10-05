
{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Personal Auto');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'drivers') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"drivers": 3, "vehicles": 2, "youngestDriver": "under21", "goodStudent": "false"}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'auto-teen-good-student', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', JSON.serialize(answers), 1, step, 'Customer: Reyes Household, Personal Lines, a customer since 2020.\nNotes on the customer: Sofia has just passed her road test. She is a junior on the honor roll with a 3.7 grade average.\nPeople: Daniel Reyes (Spouse or Partner, age 46, licensed driver); Maria Reyes (Head of Household, age 44, licensed driver); Sofia Reyes (Dependent, age 17, licensed driver).\nPolicies in force with us:\n- Homeowners ANT-HO-204534 (Active): premium $1,890, limit $485,000, deductible $1,000\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Homeowners');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'coverage') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"waterBackup": "none", "dwelling": 420000, "priorClaims": "1"}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'home-basement-water-backup', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Homeowners', JSON.serialize(answers), 1, step, 'Customer: Okafor Household, Personal Lines, a customer since 2019.\nPeople: Amara Okafor (Head of Household, age 39); Chinedu Okafor (Spouse or Partner, age 41).\nPolicies in force with us:\n- Personal Auto ANT-PA-204602 (Active): premium $1,640, limit $300,000, deductible $500, insures 2021 Subaru Outback\nClaims in the past 3 years:\n- 2025-11-02, Homeowners, Water Damage: Sump pump failed and flooded the finished basement (Closed, paid $0, reserved $0)\nNotes on the customer: The 2025 sump pump claim was not paid because the old policy had no water backup cover.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Personal Auto');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'review') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"homeowner": "false", "bundle": "false", "vehicles": 1, "drivers": 1}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'auto-has-home-policy', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', JSON.serialize(answers), 1, step, 'Customer: Whitfield Household, Personal Lines, a customer since 2017.\nPeople: Marcus Whitfield (Head of Household, age 52, licensed driver).\nPolicies in force with us:\n- Homeowners ANT-HO-204806 (Active): premium $1,730, limit $390,000, deductible $1,000, insures 88 Elm St, Wheaton, IL\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('General Liability');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'size') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"classCode": "contractor", "subcontractors": "over25", "revenue": 4200000, "employees": 31}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'gl-subcontractor-share', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('General Liability', JSON.serialize(answers), 1, step, 'Customer: Bluestem Builders, Commercial Lines, a customer since 2021.\nBusiness: Construction, 31 employees, revenue $4,200,000.\nWhat they do: Commercial tenant fit-outs and light remodels.\nNotes on the customer: Last year\'s premium audit found 18% of work was subcontracted, all to insured subcontractors with certificates on file.\nPolicies in force with us:\n- Workers Compensation ANT-WC-205201 (Active): premium $61,300, limit $1,000,000, deductible none\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Personal Auto');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'coverage') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"liability": "300000", "vehicles": 2, "drivers": 2}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'auto-under-an-umbrella', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', JSON.serialize(answers), 1, step, 'Customer: Alvarez Household, Personal Lines, a customer since 2016.\nPeople: Elena Alvarez (Head of Household, age 48, licensed driver); Tomas Alvarez (Spouse or Partner, age 50, licensed driver).\nPolicies in force with us:\n- Homeowners ANT-HO-204711 (Active): premium $2,240, limit $610,000, deductible $2,500\n- Umbrella ANT-UM-204728 (Active): premium $440, limit $1,000,000, deductible none\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}