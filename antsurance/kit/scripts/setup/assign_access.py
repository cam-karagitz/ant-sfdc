#!/usr/bin/env python3
"""Gives people access to Antsurance, through permission sets only. It never edits a profile.

Without --yes it only shows the plan and changes nothing.

Who gets access (pick one):
  --only-me                  Just the person signed in. The safe start: nobody else sees a new app, tab or page.
  --users a@x.com,b@x.com    The people you name (by username).
  --group Some_Group         The members of a public group (its API name).
  --propose                  Read how the org is set up and write a proposal to .install/access-proposal.json. Changes nothing.
  --apply-proposal           Assign what the proposal file says (edit the file first if you like).
  --remove-users a@x.com     Take access away again.

  --desk a@x.com             Also give these people the desk (approving what Claude prepared). With --only-me you get it.

What access means:
  Antsurance CRM      the app, its tabs, record types, fields and code
  Antsurance Claude   the Home page, the Claude chat, and use of the stored Claude API key
  Antsurance Desk     run a shift and approve or dismiss what Claude prepared (for leads and managers)
People are also added to the public group "Antsurance Users", which is what shares our list views, reports and dashboards.

With --capability PART it gives access to one part of the app instead of the whole app: the part's own permission set
and those of what it needs (deploy_phase.py --list names the parts). The desk is offered only where the part holds it.

Usage: python3 scripts/setup/assign_access.py --target-org <alias> --only-me --yes
       python3 scripts/setup/assign_access.py --target-org <alias> --capability automation --users a@x.com
"""
import argparse
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capabilities  # noqa: E402
from _common import KIT_ROOT, STATE_DIR, SetupError, announce, api_version, batch, delete_ids, describe_org, guard_production, in_list, load_state, main, now, records, rest, save_state, sf, soql, stage_project, tooling  # noqa: E402

BASE_SETS = ['Antsurance_CRM', 'Antsurance_Claude']
DESK_SET = 'Antsurance_Desk'
# The set whose holders see our record pages. None when what is installed has no pages of ours.
PAGES_SET = 'Antsurance_CRM'
WHAT = 'Antsurance'
GROUP = 'Antsurance_Users'


def for_capability(name, kit=None):
    """Points this script at one part of the app: its permission sets and those of what it needs."""
    global BASE_SETS, DESK_SET, PAGES_SET, WHAT
    entry = capabilities.named(name, kit)
    if entry['kind'] not in ('layer', 'slice'):
        raise SetupError('"%s" has no access of its own to give: it comes with the whole app. Run this without --capability.' % entry['label'])
    BASE_SETS = capabilities.access_sets(name, kit)
    if not BASE_SETS:
        raise SetupError('"%s" has no permission set: nothing in it needs one. People need the sets of what it is built on.' % entry['label'])
    needed = [capabilities.named(other, kit) for other in capabilities.chain(name, kit)]
    DESK_SET = 'Antsurance_Desk' if any('Antsurance_Desk' in (part.get('alsoHolds') or []) for part in needed) else None
    with_pages = [part['permissionSet'] for part in needed if (part.get('members') or {}).get('CustomApplication') == ['Antsurance']]
    PAGES_SET = with_pages[0] if with_pages else None
    WHAT = '"%s"' % entry['label']
    return entry


def our_sets():
    return BASE_SETS + ([DESK_SET] if DESK_SET else [])
PROPOSAL = os.path.join(STATE_DIR, 'access-proposal.json')
# Words in a profile, role or permission set name that suggest someone works with customers, policies or claims.
WORKS_HERE = re.compile(r'claim|adjust|underwrit|service|support|sales|agent|broker|insur|account|policy|customer|csr', re.I)
LEADS = re.compile(r'manager|supervisor|lead|director|head|vp|chief|admin', re.I)
USER_FIELDS = 'Id, Username, Name, IsActive, Profile.Name, ProfileId, Profile.UserLicense.Name, UserRole.Name'


def find_users(org, usernames):
    answers = batch(org, [('users', soql('SELECT %s FROM User WHERE Username IN (%s)' % (USER_FIELDS, in_list(usernames))))])
    found = records(answers['users'])
    missing = sorted(set(name.lower() for name in usernames) - {row['Username'].lower() for row in found})
    if missing:
        raise SetupError('No user in the org has this username: ' + ', '.join(missing))
    return found


def group_users(org, group):
    answers = batch(org, [('members', soql("SELECT UserOrGroupId FROM GroupMember WHERE Group.DeveloperName = '%s'" % group.replace("'", "\\'")))])
    ids = [row['UserOrGroupId'] for row in records(answers['members']) if row['UserOrGroupId'].startswith('005')]
    if not ids:
        raise SetupError('The public group "%s" does not exist or has no people in it directly.' % group)
    answers = batch(org, [('users', soql('SELECT %s FROM User WHERE Id IN (%s)' % (USER_FIELDS, in_list(ids))))])
    return records(answers['users'])


def org_basics(org):
    """Our permission sets and group as they are in the org, and who already has what."""
    answers = batch(org, [
        ('sets', soql('SELECT Id, Name FROM PermissionSet WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(our_sets()))),
        ('group', soql("SELECT Id FROM Group WHERE DeveloperName = '%s' AND Type = 'Regular'" % GROUP)),
        ('assigned', soql('SELECT Id, AssigneeId, PermissionSet.Name FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)' % in_list(our_sets()))),
        ('members', soql("SELECT Id, UserOrGroupId FROM GroupMember WHERE Group.DeveloperName = '%s'" % GROUP)),
    ])
    sets = {row['Name']: row['Id'] for row in records(answers['sets'])}
    missing = [name for name in our_sets() if name not in sets]
    if missing:
        raise SetupError('These permission sets are not in the org yet: %s. Install %s first.' % (', '.join(missing), 'the app (the core phase)' if WHAT == 'Antsurance' else WHAT))
    groups = records(answers['group'])
    assigned = {}
    for row in records(answers['assigned']):
        assigned.setdefault(row['AssigneeId'], {})[row['PermissionSet']['Name']] = row['Id']
    members = {row['UserOrGroupId']: row['Id'] for row in records(answers['members'])}
    return sets, (groups[0]['Id'] if groups else None), assigned, members


def propose(org):
    """Suggests who should get access, from profiles, roles and the permission sets people hold. Changes nothing."""
    answers = batch(org, [
        ('users', soql("SELECT %s FROM User WHERE IsActive = true AND Profile.UserLicense.Name = 'Salesforce' ORDER BY Name LIMIT 2000" % USER_FIELDS)),
        ('held', soql('SELECT AssigneeId, PermissionSet.Label FROM PermissionSetAssignment WHERE PermissionSet.IsOwnedByProfile = false AND Assignee.IsActive = true LIMIT 5000')),
        ('admins', soql('SELECT Id FROM Profile WHERE PermissionsModifyAllData = true')),
    ])
    held = {}
    for row in records(answers['held']):
        held.setdefault(row['AssigneeId'], []).append((row.get('PermissionSet') or {}).get('Label') or '')
    admin_profiles = {row['Id'] for row in records(answers['admins'])}
    people = []
    for user in records(answers['users']):
        profile = (user.get('Profile') or {}).get('Name') or ''
        role = (user.get('UserRole') or {}).get('Name') or ''
        signals = ' '.join([profile, role] + held.get(user['Id'], []))
        is_admin = user.get('ProfileId') in admin_profiles
        works_here = bool(WORKS_HERE.search(signals))
        leads = bool(LEADS.search(role)) or bool(LEADS.search(profile))
        entry = {'username': user['Username'], 'name': user['Name'], 'profile': profile, 'role': role, 'access': False, 'desk': False, 'why': ''}
        if is_admin:
            entry.update(access=True, desk=True, why='administrator')
        elif works_here:
            entry.update(access=True, desk=leads, why='profile, role or permission sets suggest customer, policy or claims work' + (', and a lead' if leads else ''))
        else:
            entry['why'] = 'nothing suggests they work with customers, policies or claims'
        people.append(entry)
    return people


def show_proposal(people):
    chosen = [person for person in people if person['access']]
    print('Proposed: %d of %d people on a Salesforce license get access; %d of them also get the desk.' % (len(chosen), len(people), len([p for p in chosen if p['desk']])))
    by_profile = {}
    for person in people:
        key = (person['profile'], person['access'], person['desk'])
        by_profile.setdefault(key, []).append(person['name'])
    for (profile, access, desk), names in sorted(by_profile.items(), key=lambda item: (not item[0][1], item[0][0])):
        what = 'access + desk' if desk else 'access' if access else 'no access'
        shown = ', '.join(names[:4]) + (' and %d more' % (len(names) - 4) if len(names) > 4 else '')
        print('  %-14s %-34s %3d: %s' % (what, profile[:34], len(names), shown))


def plan_for(users, desk_usernames, sets, group_id, assigned, members):
    desk = {name.lower() for name in desk_usernames}
    new_assignments, new_members, skipped, lines = [], [], [], []
    for user in users:
        license = ((user.get('Profile') or {}).get('UserLicense') or {}).get('Name')
        if not user.get('IsActive'):
            skipped.append('%s is inactive' % user['Username'])
            continue
        if license != 'Salesforce':
            skipped.append('%s is on a "%s" license; the app needs a Salesforce license' % (user['Username'], license))
            continue
        wanted = BASE_SETS + ([DESK_SET] if DESK_SET and user['Username'].lower() in desk else [])
        have = assigned.get(user['Id'], {})
        adding = [name for name in wanted if name not in have]
        for name in adding:
            new_assignments.append({'attributes': {'type': 'PermissionSetAssignment'}, 'AssigneeId': user['Id'], 'PermissionSetId': sets[name]})
        if group_id and user['Id'] not in members:
            new_members.append({'attributes': {'type': 'GroupMember'}, 'GroupId': group_id, 'UserOrGroupId': user['Id']})
        lines.append('  %s (%s, profile %s): %s' % (user['Name'], user['Username'], (user.get('Profile') or {}).get('Name'),
                                                 'add ' + ', '.join(adding) if adding else 'already has everything'))
    return new_assignments, new_members, skipped, lines


def insert_all(org, rows):
    problems = []
    for start in range(0, len(rows), 200):
        reply = rest(org, '/services/data/v%s/composite/sobjects' % api_version(), 'POST', {'allOrNone': False, 'records': rows[start:start + 200]})
        for result in reply or []:
            if not result.get('success'):
                problems += ['%s: %s' % (error.get('statusCode'), error.get('message')) for error in result.get('errors', [])]
    return problems


def delete_all(org, ids):
    return delete_ids(org, ids)


def page_assignments(org):
    """Makes the app show our record pages to every profile that now has people with access.

    Salesforce chooses a record page per app, record type and profile. This edits our own app, not anyone's profile.
    """
    if not PAGES_SET:
        return []
    answers = batch(org, [('profiles', soql("SELECT Assignee.ProfileId FROM PermissionSetAssignment WHERE PermissionSet.Name = '%s' AND PermissionSet.NamespacePrefix = null AND Assignee.IsActive = true" % PAGES_SET))])
    profile_ids = sorted({(row.get('Assignee') or {}).get('ProfileId') for row in records(answers['profiles'])} - {None})
    if not profile_ids:
        return []
    # A profile's API name is only readable one profile at a time.
    full_names = set()
    for profile_id in profile_ids:
        ok, rows = tooling(org, "SELECT FullName FROM Profile WHERE Id = '%s'" % profile_id)
        if not ok or not rows or not rows[0].get('FullName'):
            raise SetupError('Access was given, but the org would not say what one of the profiles is called, so the app could not be told which record pages to show it: %s' % (rows if not ok else profile_id))
        full_names.add(rows[0]['FullName'])
    full_names = sorted(full_names)
    app_path = os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'applications', 'Antsurance.app-meta.xml')
    with open(app_path, encoding='utf-8') as handle:
        app = handle.read()
    blocks = re.findall(r'[ \t]*<profileActionOverrides>.*?</profileActionOverrides>\n', app, re.S)
    template = [block for block in blocks if '<profile>Admin</profile>' in block]
    if not template:
        return []
    extra = ''
    for name in full_names:
        if name != 'Admin':
            extra += ''.join(block.replace('<profile>Admin</profile>', '<profile>%s</profile>' % name.replace('&', '&amp;')) for block in template)
    if not extra:
        return full_names
    last = app.rindex(template[-1]) + len(template[-1])
    staged = os.path.join(KIT_ROOT, 'stage', 'access')
    if os.path.isdir(staged):
        shutil.rmtree(staged)
    os.makedirs(os.path.join(staged, 'applications'))
    with open(os.path.join(staged, 'applications', 'Antsurance.app-meta.xml'), 'w', encoding='utf-8') as handle:
        handle.write(app[:last] + extra + app[last:])
    project = stage_project('access')
    reply = sf(['project', 'deploy', 'start', '--target-org', org, '--source-dir', 'access', '--ignore-conflicts', '--wait', '30'], allow_failure=True, cwd=project)
    result = reply.get('result') or {}
    if result.get('status') != 'Succeeded':
        failures = (result.get('details') or {}).get('componentFailures') or []
        failures = [failures] if isinstance(failures, dict) else failures
        raise SetupError('Access was given, but the app could not be told which record pages to show these profiles: %s' %
                         ('; '.join(str(f.get('problem')) for f in failures[:3]) or reply.get('message')))
    return full_names


def run():
    parser = argparse.ArgumentParser(description='Give people access to Antsurance through permission sets. Never edits a profile.')
    parser.add_argument('--target-org', required=True)
    who = parser.add_mutually_exclusive_group(required=True)
    who.add_argument('--only-me', action='store_true')
    who.add_argument('--users')
    who.add_argument('--group')
    who.add_argument('--propose', action='store_true')
    who.add_argument('--apply-proposal', action='store_true')
    who.add_argument('--remove-users')
    parser.add_argument('--desk', default='', help='Usernames who also get the desk, separated by commas')
    parser.add_argument('--capability', metavar='PART', help='Give access to one part of the app and what it needs, not the whole app. deploy_phase.py --list names the parts.')
    parser.add_argument('--yes', action='store_true', help='Make the change. Without it, only the plan is shown.')
    parser.add_argument('--allow-production', action='store_true')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    if args.capability:
        entry = for_capability(args.capability)
        print('Access to %s is %s%s.' % (WHAT, ', '.join(BASE_SETS), ', and %s for the desk' % DESK_SET if DESK_SET else ''))
        del entry

    if args.propose:
        print('Target org: %s (%s). Reading who uses the org. This changes nothing.' % (alias, org['name']))
        people = propose(alias)
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(PROPOSAL, 'w') as handle:
            json.dump({'org': org['orgId'], 'proposedAt': now(), 'people': people}, handle, indent=2)
        show_proposal(people)
        print('Written to %s. Set "access" or "desk" to true or false for anyone to change it, then run with --apply-proposal --yes.' % os.path.relpath(PROPOSAL, KIT_ROOT))
        return

    announce(org, 'change who has access to %s' % WHAT if args.yes else 'show who would get access to %s (plan only, nothing changes)' % WHAT)
    guard_production(org, args.allow_production)
    sets, group_id, assigned, members = org_basics(alias)

    if args.remove_users:
        users = find_users(alias, [name.strip() for name in args.remove_users.split(',') if name.strip()])
        ids = []
        for user in users:
            ids += list(assigned.get(user['Id'], {}).values())
            if user['Id'] in members:
                ids.append(members[user['Id']])
            print('  %s: remove %s' % (user['Username'], ', '.join(assigned.get(user['Id'], {})) or 'nothing (has no access)'))
        if not args.yes:
            print('Plan only. Nothing was changed. Run again with --yes to remove this access.')
            return
        problems = delete_all(alias, ids) if ids else []
        if problems:
            raise SetupError('Some access could not be removed: ' + '; '.join(problems[:5]))
        print('Removed.')
        return

    desk = [name.strip() for name in args.desk.split(',') if name.strip()]
    mode = 'only me'
    if args.only_me:
        users = find_users(alias, [org['username']])
        desk = [org['username']]
    elif args.users:
        mode = 'people named'
        users = find_users(alias, [name.strip() for name in args.users.split(',') if name.strip()])
    elif args.group:
        mode = 'group ' + args.group
        users = group_users(alias, args.group)
    else:
        mode = 'proposal'
        if not os.path.exists(PROPOSAL):
            raise SetupError('There is no proposal yet. Run with --propose first.')
        with open(PROPOSAL) as handle:
            proposal = json.load(handle)
        if proposal.get('org') != org['orgId']:
            raise SetupError('The proposal file was made for a different org. Run with --propose against this one.')
        chosen = [person for person in proposal['people'] if person.get('access')]
        if not chosen:
            raise SetupError('The proposal gives nobody access.')
        users = find_users(alias, [person['username'] for person in chosen])
        desk = [person['username'] for person in chosen if person.get('desk')]

    new_assignments, new_members, skipped, lines = plan_for(users, desk, sets, group_id, assigned, members)
    print('Access plan (%s): people %d, permission set assignments to add %d.' % (mode, len(lines), len(new_assignments)))
    print('\n'.join(lines[:60]) + ('\n  and %d more.' % (len(lines) - 60) if len(lines) > 60 else ''))
    for line in skipped:
        print('  SKIPPED: ' + line)
    print('No profile is edited. Everyone not listed keeps exactly what they have.')
    if not args.yes:
        print('Plan only. Nothing was changed. Run again with --yes to assign.')
        return

    problems = insert_all(alias, new_assignments + new_members) if new_assignments or new_members else []
    if problems:
        raise SetupError('Some access could not be given: ' + '; '.join(sorted(set(problems))[:5]))
    profiles = page_assignments(alias)
    state = load_state(org)
    state['access'] = {'mode': mode, 'at': now(), 'people': sorted(user['Username'] for user in users), 'desk': sorted(desk) if DESK_SET else [], 'profilesWithOurPages': profiles,
                       'sets': our_sets()}
    state['phases']['access'] = {'at': now(), 'outcome': 'assigned', 'detail': {'mode': mode, 'people': len(lines)}}
    save_state(org, state)
    print('Done. %d assignment%s added. To open it up to more people later, run this again with --users, --group or --propose.' % (len(new_assignments), '' if len(new_assignments) == 1 else 's'))


if __name__ == '__main__':
    main(run)
