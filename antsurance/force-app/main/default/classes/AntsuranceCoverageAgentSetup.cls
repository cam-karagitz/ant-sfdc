/**
 * @description Sets the claims coverage agent up on Claude Managed Agents, once per Claude
 * workspace: an environment for its sessions, the antsurance-coverage skill, and the agent itself
 * with its tools and instructions. Run it from Anonymous Apex after the Claude API key is in:
 *
 *     System.debug(AntsuranceCoverageAgentSetup.run());
 *
 * It is safe to run again. It looks for what it made before, by the ids it kept and then by the
 * environment's name (the environment notes the ids of the skill and the agent that go with it),
 * and only creates what is missing. refresh() also sends the current skill and agent definition,
 * for after either has changed. Nothing is ever archived or deleted here: on Managed Agents an
 * archived agent cannot be brought back.
 *
 * The ids are kept in the Antsurance_Coverage_Agent__c custom setting so the claim page can read
 * them without a deploy. They are not secrets: they are useless without the API key, which stays
 * in the Anthropic external credential and is never read by this code.
 */
public with sharing class AntsuranceCoverageAgentSetup {
    @TestVisible
    private static final String AGENT_NAME = 'Antsurance claims coverage agent (Salesforce)';
    @TestVisible
    private static final String ENVIRONMENT_NAME = 'antsurance-crm-coverage';
    @TestVisible
    private static final String SKILL_NAME = 'antsurance-coverage';
    private static final String SKILL_RESOURCE = 'antsuranceCoverageSkill';
    private static final Integer PAGE_SIZE = 100;
    // Where the environment notes the ids of the skill and the agent that go with it.
    private static final String SKILL_NOTE = 'coverage_skill_id';
    private static final String AGENT_NOTE = 'coverage_agent_id';
    private static final Integer MAX_PAGES = 30;
    private static final Integer CALLOUTS_KEPT_BACK = 8;
    private static final String TOO_MANY =
        'This Claude workspace holds more {0} than setup can search in one go, so it stopped rather than risk making a second one of the same name. ' +
        'If the coverage agent was set up here before, put its ids in the Antsurance Coverage Agent custom setting by hand; otherwise use a workspace of its own.';
    /** What one investigation may spend at list price before the platform pauses it, in cents. */
    public static final Integer BUILT_IN_BUDGET_CENTS = 100;

    private static final String INSTRUCTIONS =
        'You are the claims coverage agent at Antsurance, an insurance carrier. An adjuster has a claim open in Salesforce and asks one question: does the policy respond to this loss? ' +
        'You work the question step by step with your tools and record a finding for the adjuster to confirm. The adjuster decides; you advise.\n\n' +
        'How you work:\n' +
        '- Use the antsurance-coverage skill for the method, and follow its order of work.\n' +
        '- Every fact comes from a tool. Start with read_claim and read_policy. Then read what bears on the answer: the file notes, the attached documents, what the photos show, earlier claims by the same customer. ' +
        'Read a document when its name suggests it bears on the cause, the date or the extent of the loss. Do not read what cannot change the answer.\n' +
        '- You cannot ask the adjuster anything while you work. The file is all you have. What it does not answer becomes a question for the insured or a fact that would change the verdict.\n' +
        '- Tools give each record a key in square brackets. A finding cites exactly one key. Only a coverage, or an endorsement that is not an exclusion, can be named as responding.\n' +
        '- You have the coverages and endorsements as the system records them, not the wording of the policy forms. Never invent policy language, a fact, a figure or a name.\n' +
        '- When the file is silent or mixed on something that decides the answer, the verdict is Needs review.\n' +
        '- Finish by calling record_finding exactly once. If it reports a problem, fix it and call it again. ' +
        'Then tell the adjuster, in two short sentences and plain words, what you found and what is still open.\n\n' +
        AntsuranceClaimRules.RESERVE_RULE +
        ' You answer whether the policy responds, not how much to reserve. Do not write a finding, a question or a closing remark about the reserve or whether it is enough: the claim analysis does that.\n\n' +
        'Write in plain words and complete sentences. Write money with a dollar sign and thousands separators, and dates month first, like Sep 28, 2026. ' +
        AntsuranceClaimRules.LASTING_WORDS +
        'Refer to coverages and people by their names, not their keys. Do not use dashes as punctuation, and do not use Markdown. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH;

    /**
     * @description Thrown when setup cannot finish. The message says what to do about it.
     */
    public class SetupException extends Exception {
    }

    /**
     * @description Makes sure the environment, the skill and the agent exist, creating what is
     * missing, and keeps their ids.
     * @return What it found and what it made, one line each
     * @throws SetupException when Managed Agents cannot be reached or refuses this key
     */
    public static String run() {
        return ensure(false);
    }

    /**
     * @description As run, and also sends the current skill file and agent definition, each as a
     * new version. Run it after changing the skill, the tools or the instructions.
     * @return What it found, made and updated, one line each
     * @throws SetupException when Managed Agents cannot be reached or refuses this key
     */
    public static String refresh() {
        return ensure(true);
    }

    private static String ensure(Boolean sendCurrent) {
        Antsurance_Coverage_Agent__c ids = Antsurance_Coverage_Agent__c.getOrgDefaults();
        List<String> report = new List<String>();
        try {
            // Every callout comes before the save at the end: a callout cannot follow a save in one transaction.
            Map<String, Object> environment = environment(ids.Environment_Id__c, report);
            Map<String, Object> noted = environment.get('metadata') instanceof Map<String, Object> ? (Map<String, Object>) environment.get('metadata') : new Map<String, Object>();
            ids.Environment_Id__c = (String) environment.get('id');
            ids.Skill_Id__c = skill(ids.Skill_Id__c ?? (String) noted.get(SKILL_NOTE), sendCurrent, report);
            ids.Agent_Id__c = agent(ids.Agent_Id__c ?? (String) noted.get(AGENT_NOTE), ids.Skill_Id__c, sendCurrent, report);
            if (noted.get(SKILL_NOTE) != ids.Skill_Id__c || noted.get(AGENT_NOTE) != ids.Agent_Id__c) {
                // The environment is the one thing found by name, so it carries the other two ids for an org that has lost them.
                AntsuranceCoverageAgentApi.post(
                    '/v1/environments/' + ids.Environment_Id__c,
                    '{"metadata":{' + JSON.serialize(SKILL_NOTE) + ':' + JSON.serialize(ids.Skill_Id__c) + ',' + JSON.serialize(AGENT_NOTE) + ':' + JSON.serialize(ids.Agent_Id__c) + '}}'
                );
            }
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            throw new SetupException(
                e.kind == 'not_allowed'
                    ? 'This Claude API key cannot use Managed Agents. Nothing was set up, and the claim page will not offer the coverage agent. The API said: ' + e.detail
                    : 'Setup stopped: ' + e.getMessage() + (String.isBlank(e.detail) ? '' : ' The API said: ' + e.detail),
                e
            );
        }
        if (ids.Session_Budget_Cents__c == null) {
            ids.Session_Budget_Cents__c = BUILT_IN_BUDGET_CENTS;
        }
        upsert ids;
        report.add('Kept in the Antsurance Coverage Agent custom setting. The claim page now offers "Investigate with the coverage agent".');
        return String.join(report, '\n');
    }

    private static Map<String, Object> environment(String knownId, List<String> report) {
        Map<String, Object> existing = live('/v1/environments/', knownId);
        if (existing == null) {
            existing = named('/v1/environments', 'name', ENVIRONMENT_NAME, PAGE_SIZE, true);
        }
        if (existing != null) {
            report.add('Environment "' + ENVIRONMENT_NAME + '": already there.');
            return existing;
        }
        // Deny by default: the agent's tools run in Salesforce, so its sandbox needs to reach nothing.
        Map<String, Object> created = AntsuranceCoverageAgentApi.post(
            '/v1/environments',
            '{"name":' + JSON.serialize(ENVIRONMENT_NAME) +
                ',"description":"Sessions of the Antsurance claims coverage agent, started from Salesforce. No outbound network: the agent reads through tools that run in Salesforce."' +
                ',"config":{"type":"cloud","networking":{"type":"limited"}}}'
        );
        report.add('Environment "' + ENVIRONMENT_NAME + '": created.');
        return created;
    }

    private static String skill(String knownId, Boolean sendCurrent, List<String> report) {
        Map<String, Object> existing = knownId == null ? null : quietly('/v1/skills/' + knownId, false);
        if (existing == null) {
            existing = named('/v1/skills?source=custom', 'display_name', SKILL_NAME, PAGE_SIZE, false);
        }
        if (existing == null) {
            Map<String, Object> created = AntsuranceCoverageAgentApi.uploadSkill('/v1/skills', SKILL_NAME, skillFile());
            report.add('Skill "' + SKILL_NAME + '": uploaded.');
            return (String) created.get('id');
        }
        String skillId = (String) existing.get('id');
        if (sendCurrent) {
            AntsuranceCoverageAgentApi.uploadSkill('/v1/skills/' + skillId + '/versions', SKILL_NAME, skillFile());
            report.add('Skill "' + SKILL_NAME + '": a new version uploaded.');
        } else {
            report.add('Skill "' + SKILL_NAME + '": already there.');
        }
        return skillId;
    }

    /**
     * The agent is found by the id this org kept, or the id noted on the environment, never by
     * searching the workspace's agents: a workspace can hold thousands, each listed with its whole
     * instructions.
     */
    private static String agent(String knownId, String skillId, Boolean sendCurrent, List<String> report) {
        Map<String, Object> existing = live('/v1/agents/', knownId);
        if (existing == null) {
            Map<String, Object> created = save('/v1/agents', skillId);
            report.add('Agent "' + AGENT_NAME + '": created at version ' + created.get('version') + '.');
            return (String) created.get('id');
        }
        String agentId = (String) existing.get('id');
        if (sendCurrent) {
            // No version is sent, so this replaces whatever is there: this class owns the agent.
            Map<String, Object> updated = save('/v1/agents/' + agentId, skillId);
            report.add('Agent "' + AGENT_NAME + '": updated to version ' + updated.get('version') + '.');
        } else {
            report.add('Agent "' + AGENT_NAME + '": already there, at version ' + existing.get('version') + '.');
        }
        return agentId;
    }

    /** Creates or updates the agent. Fast output is asked for when the org's setting says so, and dropped if this account does not have it. */
    private static Map<String, Object> save(String path, String skillId) {
        if (AntsuranceAiSettings.useFastMode()) {
            try {
                return AntsuranceCoverageAgentApi.post(path, definition(skillId, true));
            } catch (AntsuranceCoverageAgentApi.ApiException e) {
                if (e.status != 400) {
                    throw e;
                }
            }
        }
        return AntsuranceCoverageAgentApi.post(path, definition(skillId, false));
    }

    /** The agent as Managed Agents stores it: the model, the instructions, the tools and the skill. */
    @TestVisible
    private static String definition(String skillId, Boolean fast) {
        return '{"name":' + JSON.serialize(AGENT_NAME) +
            ',"description":"Works one coverage question on one claim for an adjuster in Salesforce. Its tools run in Salesforce as the signed-in user; it records a finding for a person to confirm."' +
            ',"model":{"id":' + JSON.serialize(AntsuranceAiSettings.model()) + ',"effort":"medium"' + (fast ? ',"speed":"fast"' : '') + '}' +
            ',"system":' + JSON.serialize(INSTRUCTIONS) +
            // Only the file reader is on, because a skill is read from the sandbox. No shell, no writing, no web.
            ',"tools":[{"type":"agent_toolset_20260401","default_config":{"enabled":false},"configs":[{"name":"read","enabled":true,"permission_policy":{"type":"always_allow"}}]},' +
            AntsuranceCoverageAgentTools.definitions().substring(1) +
            ',"skills":[{"type":"custom","skill_id":' + JSON.serialize(skillId) + ',"version":"latest"}]' +
            ',"metadata":{"app":"antsurance-crm","role":"claims-coverage","surface":"salesforce"}}';
    }

    /** The resource behind an id this org kept, when it is still there and not archived. */
    private static Map<String, Object> live(String path, String knownId) {
        Map<String, Object> found = knownId == null ? null : quietly(path + knownId, true);
        return found == null || found.get('archived_at') != null ? null : found;
    }

    /** A GET that answers null when the resource is gone, and throws for anything else. */
    private static Map<String, Object> quietly(String path, Boolean isManagedAgents) {
        try {
            return isManagedAgents ? AntsuranceCoverageAgentApi.get(path) : AntsuranceCoverageAgentApi.getSkills(path);
        } catch (AntsuranceCoverageAgentApi.ApiException e) {
            if (e.kind == 'not_found') {
                return null;
            }
            throw e;
        }
    }

    /**
     * The first resource of this name that is not archived, looking through the pages of a list.
     * Each page is searched as text and parsed only when the name is on it, which keeps a busy
     * workspace cheap to search.
     */
    private static Map<String, Object> named(String path, String field, String name, Integer pageSize, Boolean isManagedAgents) {
        String quoted = JSON.serialize(name);
        String page;
        for (Integer turn = 0; turn < MAX_PAGES; turn++) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts() - CALLOUTS_KEPT_BACK) {
                throw new SetupException(TOO_MANY.replace('{0}', path.substringAfterLast('/').substringBefore('?')));
            }
            String listed = AntsuranceCoverageAgentApi.getText(
                path + (path.contains('?') ? '&' : '?') + 'limit=' + pageSize + (page == null ? '' : '&page=' + EncodingUtil.urlEncode(page, 'UTF-8')),
                isManagedAgents
            );
            if (listed.contains(quoted)) {
                for (Object item : items((Map<String, Object>) JSON.deserializeUntyped(listed))) {
                    Map<String, Object> entry = (Map<String, Object>) item;
                    if (entry.get(field) == name && entry.get('archived_at') == null) {
                        return entry;
                    }
                }
            }
            // The cursor is the last field of the page; read it without parsing the page.
            String cursor = listed.substringAfterLast('"next_page":').trim();
            page = cursor.startsWith('"') ? cursor.substringBetween('"', '"') : null;
            if (String.isBlank(page)) {
                return null;
            }
        }
        // More pages than were searched: creating now could make a second one of the same name.
        throw new SetupException(TOO_MANY.replace('{0}', path.substringAfterLast('/').substringBefore('?')));
    }

    private static List<Object> items(Map<String, Object> listed) {
        return listed.get('data') instanceof List<Object> ? (List<Object>) listed.get('data') : new List<Object>();
    }

    private static String skillFile() {
        List<StaticResource> files = [SELECT Body FROM StaticResource WHERE Name = :SKILL_RESOURCE LIMIT 1];
        if (files.isEmpty()) {
            throw new SetupException('The skill file is missing. Deploy the static resource ' + SKILL_RESOURCE + ' and run this again.');
        }
        return files[0].Body.toString();
    }
}
