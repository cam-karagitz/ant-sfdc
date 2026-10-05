
{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Homeowners');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'coverage') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"deductible": "500", "priorClaims": "0", "dwelling": 380000}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'home-wants-a-lower-bill', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Homeowners', JSON.serialize(answers), 1, step, 'Customer: Schmidt Household, Personal Lines, a customer since 2014.\nNotes on the customer: Asked twice this year for ways to lower the bill. Comfortable carrying more of a small loss themselves. No claims in nine years.\nPeople: Greta Schmidt (Head of Household, age 61).\nPolicies in force with us:\n- Personal Auto ANT-PA-204388 (Active): premium $1,210, limit $300,000, deductible $1,000\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Workers Compensation');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'experience') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"classGroup": "manufacturing", "payroll": 6400000, "employees": 112, "returnToWork": "false", "safetyProgram": "true"}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'wc-return-to-work', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Workers Compensation', JSON.serialize(answers), 1, step, 'Customer: Ironwood Machine Works, Commercial Lines, a customer since 2018.\nBusiness: Manufacturing, 112 employees, revenue $7,860,000.\nThis sale: Renewal of policy ANT-WC-205146.\nPolicies in force with us:\n- Workers Compensation ANT-WC-205146 (Pending Renewal): premium $149,500, limit $1,000,000, deductible none. Underwriting notes: Formal return-to-work program in place since 2024, with light-duty roles documented for every department.\nClaims in the past 3 years:\n- 2026-03-14, Workers Compensation, Bodily Injury: Lathe operator lacerated hand (Closed, paid $18,400, reserved $18,400)');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Commercial Auto');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'drivers') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"vehicles": 14, "drivers": 16, "vehicleTypes": "light", "use": "delivery", "telematics": "false"}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'fleet-dash-cameras', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Commercial Auto', JSON.serialize(answers), 1, step, 'Customer: Sagebrush Freight Lines, Commercial Lines, a customer since 2022.\nBusiness: Transportation, 38 employees, revenue $9,100,000.\nWhat they do: Regional parcel and pallet delivery.\nNotes on the customer: Every van was fitted with dash cameras and GPS telematics in March 2026 after two disputed collisions.\nPolicies in force with us: none.\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}

{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire('Personal Auto');
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) { if (sections[i].key == 'coverage') { step = i; } }
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped('{"liability": "500000", "vehicles": 2, "drivers": 2, "collision": "500"}');
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) { for (AntsuranceQuoteConfigurator.Question q : s.questions) {
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) { values.add(o.value); }
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) });
    } }
    Map<String, Object> row = new Map<String, Object>{ 'id' => 'auto-umbrella-wants-cheaper', 'options' => options };
    Long started = System.currentTimeMillis();
    try {
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest('Personal Auto', JSON.serialize(answers), 1, step, 'Customer: Alvarez Household, Personal Lines, a customer since 2016.\nNotes on the customer: Tomas asked for the cheapest auto cover we can write and suggested dropping the liability limits.\nPeople: Elena Alvarez (Head of Household, age 48, licensed driver); Tomas Alvarez (Spouse or Partner, age 50, licensed driver).\nPolicies in force with us:\n- Umbrella ANT-UM-204728 (Active): premium $440, limit $1,000,000, deductible none\nClaims in the past 3 years: none.');
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    } catch (Exception e) { row.put('error', e.getMessage()); }
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}