"""One-off generator: page layouts, Lightning record pages, app navigation and page assignment."""
import os, sys, re
# Run with -I (as the docs say) and Python leaves this folder off its path, so it is put back for gen_shared.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_shared import OWN_TABS
ROOT = sys.argv[1]
NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"'
HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'
def write(path, body):
    full = os.path.join(ROOT, path); os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w').write(HEAD + body.strip('\n') + '\n')
def esc(s): return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

# =============================================================== page layouts
def layout_item(f):
    name, behavior = (f if isinstance(f, tuple) else (f, 'Edit'))
    return f'            <layoutItems>\n                <behavior>{behavior}</behavior>\n                <field>{name}</field>\n            </layoutItems>\n'
def section(label, left, right=None):
    cols = '        <layoutColumns>\n' + ''.join(layout_item(f) for f in left) + '        </layoutColumns>\n'
    if right is not None:
        cols += '        <layoutColumns>\n' + ''.join(layout_item(f) for f in right) + '        </layoutColumns>\n'
    style = 'OneColumn' if right is None else 'TwoColumnsTopToBottom'
    return (f'    <layoutSections>\n        <customLabel>true</customLabel>\n        <detailHeading>true</detailHeading>\n        <editHeading>true</editHeading>\n'
            f'        <label>{esc(label)}</label>\n{cols}        <style>{style}</style>\n    </layoutSections>\n')
def related(name, fields, sort=None):
    body = '    <relatedLists>\n' + ''.join(f'        <fields>{f}</fields>\n' for f in fields) + f'        <relatedList>{name}</relatedList>\n'
    if sort: body += f'        <sortField>{sort[0]}</sortField>\n        <sortOrder>{sort[1]}</sortOrder>\n'
    return body + '    </relatedLists>\n'
# The Activity panel's composer shows these in this order on every page, so it reads the same everywhere.
COMPOSER = ['LogACall', 'NewTask', 'NewEvent', 'SendEmail']
def composer():
    items = ''.join(f'        <platformActionListItems>\n            <actionName>{name}</actionName>\n            <actionType>QuickAction</actionType>\n            <sortOrder>{index}</sortOrder>\n        </platformActionListItems>\n'
                    for index, name in enumerate(COMPOSER))
    return f'    <platformActionList>\n        <actionListContext>Record</actionListContext>\n{items}    </platformActionList>\n'
def layout(name, sections, related_lists=(), activities=False):
    write(f'layouts/{name}.layout-meta.xml', f'<Layout {NS}>\n' + ''.join(sections) + (composer() if activities else '') + ''.join(related_lists) +
          '    <showEmailCheckbox>false</showEmailCheckbox>\n    <showHighlightsPanel>false</showHighlightsPanel>\n    <showInteractionLogPanel>false</showInteractionLogPanel>\n'
          '    <showRunAssignmentRulesCheckbox>false</showRunAssignmentRulesCheckbox>\n    <showSubmitAndAttachButton>false</showSubmitAndAttachButton>\n</Layout>')
R, RO = 'Required', 'Readonly'
# Related lists carry five columns at most, with short headers, so nothing is cut off in the page's main column.
# The record type and priority of a case are left out: the subject says which it is, and priority follows severity.
CASE_LIST = ['CASES.CASE_NUMBER', 'CASES.SUBJECT', 'CASES.STATUS', 'Reported_Date__c']
OPP_LIST = ['OPPORTUNITY.NAME', 'OPPORTUNITY.STAGE_NAME', 'OPPORTUNITY.AMOUNT', 'OPPORTUNITY.CLOSE_DATE']
POLICY_LIST = ['NAME', 'Line_of_Business__c', 'Status__c', 'Annual_Premium__c', 'Expiration_Date__c']
ASSET_LIST = ['NAME', 'Asset_Type__c', 'Identifier__c', 'Insured_Value__c']
COVERAGE_LIST = ['NAME', 'Limit_Amount__c', 'Limit_Type__c', 'Deductible_Amount__c', 'Premium_Amount__c']
# A participant's name already carries the role ("Maria Reyes, Named Insured"), so the role has no column of its own.
PARTICIPANT_LIST = ['NAME', 'Status__c', 'Relationship_to_Insured__c', 'Effective_Date__c']
ENDORSEMENT_LIST = ['NAME', 'Form_Number__c', 'Type__c', 'Premium_Change__c']
POLICY_CASE_LIST = ['CASES.CASE_NUMBER', 'CASES.SUBJECT', 'CASES.STATUS', 'Reserve_Amount__c']
# Household members have no job title, so their list shows their place in the household instead.
MEMBER_LIST = ['FULL_NAME', 'Household_Role__c', 'CONTACT.EMAIL', 'CONTACT.PHONE1']
STAFF_LIST = ['FULL_NAME', 'CONTACT.TITLE', 'CONTACT.EMAIL', 'CONTACT.PHONE1']
# Tasks, calls and events show in the Activity panel on every record page, so the layouts leave out the
# Open Activities and Activity History related lists, which would repeat them. Files are left out too:
# claims have a Documents tab, policies and sales have their documents, and an empty upload box adds nothing.
WEB = section('Web Details', ['SuppliedName', 'SuppliedEmail'], ['SuppliedPhone', 'SuppliedCompany'])

layout('Policy__c-Policy Layout', [
    section('Policy', [('Name', R), ('Account__c', R), 'Primary_Insured__c'], ['Line_of_Business__c', 'Status__c', 'Producer__c']),
    section('Term and Billing', ['Effective_Date__c', 'Expiration_Date__c', ('Days_to_Renewal__c', RO)], ['Billing_Frequency__c', 'Payment_Status__c']),
    section('Coverage', ['Annual_Premium__c', 'Coverage_Limit__c'], ['Deductible__c', 'Insured_Item__c']),
    section('Underwriting', ['Underwriting_Notes__c'])],
    [related('Policy_Asset__c.Policy__c', ASSET_LIST), related('Policy_Coverage__c.Policy__c', COVERAGE_LIST), related('Policy_Participant__c.Policy__c', PARTICIPANT_LIST),
     related('Policy_Endorsement__c.Policy__c', ENDORSEMENT_LIST), related('Case.Policy__c', POLICY_CASE_LIST)], activities=True)
layout('Policy_Coverage__c-Policy Coverage Layout', [
    section('Coverage', [('Name', R), ('Policy__c', R), 'Category__c', 'Status__c', 'Effective_Date__c'],
            ['Limit_Amount__c', 'Limit_Type__c', 'Deductible_Amount__c', 'Premium_Amount__c', ('Premium_Share__c', RO)]),
    section('What Is Covered', ['What_Is_Covered__c'])])
layout('Policy_Participant__c-Policy Participant Layout', [
    section('Participant', [('Name', R), ('Policy__c', R), 'Contact__c', 'Relationship_to_Insured__c'], ['Role__c', 'Status__c', 'Is_Primary__c', 'Effective_Date__c', 'Expiration_Date__c']),
    section('Driver', ['License_Number__c', 'License_State__c', 'Date_Licensed__c', ('Years_Licensed__c', RO), 'Primary_Vehicle__c'],
            ['Driver_Rating__c', 'Violations_Past_3_Years__c', 'Accidents_Past_3_Years__c', 'Good_Student_Discount__c']),
    section('Notes', ['Notes__c'])])
layout('Policy_Endorsement__c-Policy Endorsement Layout', [
    section('Form', [('Name', R), ('Policy__c', R), 'Form_Number__c', 'Type__c'], ['Status__c', 'Effective_Date__c', 'Premium_Change__c', 'Limit_Amount__c']),
    section('Description', ['Description__c'])])
layout('Policy_Asset__c-Insured Asset Layout', [
    section('Asset', [('Name', R), ('Policy__c', R), 'Asset_Type__c', 'Identifier__c', 'Model_Year__c'], ['Insured_Value__c', 'Use__c', 'Lienholder__c']),
    section('Location and Details', ['Location__c', 'Details__c'])])
layout('File_Note__c-File Note Layout', [
    section('Note', [('Name', RO), 'Note_Type__c', 'Note_Date__c', 'Author_Name__c'], ['Case__c', 'Policy__c', 'Account__c']),
    section('Text', ['Body__c'])])
layout('Quote-Antsurance Quote Layout', [
    section('Quote', [('QuoteNumber', RO), ('Name', R), 'OpportunityId', ('AccountId', RO), 'Status', 'Underwriter__c'],
            ['Annual_Premium__c', 'Coverage_Limit__c', 'Deductible__c', 'Issued_Date__c', 'ExpirationDate', ('Days_Since_Issued__c', RO)]),
    section('Coverage Summary', ['Description'])], activities=True)
layout('Case-Claim Layout', [
    section('Claim', [('CaseNumber', RO), ('Status', R), 'Priority', 'Handled_By__c', ('OwnerId', 'Edit')], ['AccountId', 'ContactId', 'Policy__c', ('Origin', R)]),
    section('Loss Details', ['Date_of_Loss__c', 'Reported_Date__c', 'Loss_Type__c'], ['Severity__c', 'Loss_Location__c', ('Coverage_Check__c', RO)]),
    section('Financials', ['Estimated_Loss__c', 'Reserve_Amount__c', 'Paid_Amount__c'], [('Outstanding_Reserve__c', RO), 'SIU_Referral__c', 'Subrogation_Potential__c']),
    section('Description', ['Subject', 'Description']), WEB], activities=True)
layout('Case-Policy Service Layout', [
    section('Request', [('CaseNumber', RO), ('Status', R), 'Priority', 'Request_Type__c', 'Handled_By__c', ('OwnerId', 'Edit')], ['AccountId', 'ContactId', 'Policy__c', ('Origin', R), 'Reported_Date__c']),
    section('Description', ['Subject', 'Description']), WEB], activities=True)
def customer_related(contact_columns):
    return [related('Policy__c.Account__c', POLICY_LIST), related('RelatedContactList', contact_columns),
            related('RelatedCaseList', CASE_LIST), related('RelatedOpportunityList', OPP_LIST)]
layout('Account-Household Layout', [
    section('Household', [('Name', R), 'Phone', 'ParentId', ('OwnerId', 'Edit')], ['Customer_Segment__c', 'Customer_Since__c', ('Active_Policies__c', RO), ('Premium_in_Force__c', RO)]),
    section('Address', ['BillingAddress'], ['Description']),
    section('Customer Brief', ['Customer_Brief__c'])],
    customer_related(MEMBER_LIST), activities=True)
layout('Account-Business Layout', [
    section('Business', [('Name', R), 'Phone', 'Website', 'ParentId', ('OwnerId', 'Edit')], ['Customer_Segment__c', 'Customer_Since__c', ('Active_Policies__c', RO), ('Premium_in_Force__c', RO)]),
    section('Profile', ['Industry', 'NumberOfEmployees'], ['Type', 'AnnualRevenue']),
    section('Address', ['BillingAddress'], ['Description']),
    section('Customer Brief', ['Customer_Brief__c'])],
    customer_related(STAFF_LIST), activities=True)
layout('Account-Agency Layout', [
    section('Agency', [('Name', R), 'Phone', 'Website', 'ParentId', ('OwnerId', 'Edit')], ['Customer_Segment__c', 'Type', 'Industry']),
    section('Address', ['BillingAddress'], ['Description']),
    section('Agency Brief', ['Customer_Brief__c'])],
    [related('Policy__c.Producer__c', ['NAME', 'Account__c', 'Line_of_Business__c', 'Status__c', 'Annual_Premium__c']),
     related('RelatedContactList', STAFF_LIST)], activities=True)
layout('Contact-Antsurance Contact Layout', [
    section('Contact', [('Name', R), 'AccountId', 'Title', ('OwnerId', 'Edit')], ['Email', 'Phone', 'MobilePhone', 'Preferred_Contact_Method__c']),
    section('Household', ['Household_Role__c', 'Primary_Member__c'], ['Birthdate', 'Licensed_Driver__c']),
    section('Address', ['MailingAddress'], [])],
    # On a person's own page their name would repeat down the list, so it leads with the policy.
    [related('Policy_Participant__c.Contact__c', ['Policy__c', 'Role__c', 'Status__c', 'Effective_Date__c']), related('RelatedCaseList', CASE_LIST)], activities=True)
layout('Opportunity-Policy Sale Layout', [
    section('Policy Sale', [('Name', R), 'AccountId', 'Type', 'Line_of_Business__c', ('OwnerId', 'Edit')], [('StageName', R), ('CloseDate', R), 'Amount', 'Probability', 'Policy__c']),
    section('Details', ['LeadSource', 'NextStep'], ['Description'])],
    [related('RelatedQuoteList', ['QUOTE.NAME', 'QUOTE.STATUS', 'Annual_Premium__c', 'Deductible__c', 'QUOTE.EXPIRATIONDATE'])], activities=True)
layout('Lead-Antsurance Lead Layout', [
    section('Lead', [('Name', R), ('Company', R), 'Title', ('OwnerId', 'Edit')], [('Status', R), 'Product_Interest__c', 'LeadSource', 'Rating']),
    section('Contact Details', ['Email', 'Phone'], ['Address']),
    section('Notes', ['Description'])],
    [], activities=True)

# =============================================================== Lightning record pages
class Page:
    def __init__(self): self.regions = []; self.n = {}
    def ident(self, base):
        self.n[base] = self.n.get(base, 0) + 1
        return base if self.n[base] == 1 else f'{base}{self.n[base]}'
    def prop(self, name, value):
        return f'                <componentInstanceProperties>\n                    <name>{name}</name>\n                    <value>{esc(str(value))}</value>\n                </componentInstanceProperties>\n'
    def visibility(self, when, pad):
        """A visibility rule. `when` is (field, value), (field, value, operator) or a list of those, all of which must hold;
        ('ANY', [those]) holds when any one of them does. The operator is EQUAL unless given; NE means "is not"."""
        joiner = ' AND '
        if isinstance(when, tuple) and when[0] == 'ANY':
            joiner, when = ' OR ', when[1]
        criteria = when if isinstance(when, list) else [when]
        sp = ' ' * pad
        body = f'{sp}<visibilityRule>\n'
        if len(criteria) > 1:
            body += f'{sp}    <booleanFilter>{joiner.join(str(i + 1) for i in range(len(criteria)))}</booleanFilter>\n'
        for criterion in criteria:
            field_name, expected, operator = (tuple(criterion) + ('EQUAL',))[:3]
            body += (f'{sp}    <criteria>\n{sp}        <leftValue>{{!Record.{field_name}}}</leftValue>\n{sp}        <operator>{operator}</operator>\n'
                     f'{sp}        <rightValue>{esc(str(expected))}</rightValue>\n{sp}    </criteria>\n')
        return body + f'{sp}</visibilityRule>\n'
    def listprop(self, name, values):
        # A value can be (value, field, expected) or (value, [criteria]): the item then shows only while the rule holds.
        def item(v):
            if isinstance(v, tuple):
                when = v[1] if len(v) == 2 else (v[1], v[2])
                rule = self.visibility(when, 28)
                return f'                        <valueListItems>\n                            <value>{v[0]}</value>\n{rule}                        </valueListItems>\n'
            return f'                        <valueListItems>\n                            <value>{v}</value>\n                        </valueListItems>\n'
        return (f'                <componentInstanceProperties>\n                    <name>{name}</name>\n                    <valueList>\n' +
                ''.join(item(v) for v in values) +
                '                    </valueList>\n                </componentInstanceProperties>\n')
    def component(self, name, props=''):
        ident = self.ident(name.replace(':', '_'))
        return f'        <itemInstances>\n            <componentInstance>\n{props}                <componentName>{name}</componentName>\n                <identifier>{ident}</identifier>\n            </componentInstance>\n        </itemInstances>\n'
    def field(self, f, where):
        # A field is a name, (name, behavior) or (name, behavior, when): the last shows only while the rule holds (see visibility).
        name, behavior, when = (f + (None,))[:3] if isinstance(f, tuple) else (f, 'none', None)
        rule = self.visibility(when, 16) if when else ''
        return (f'        <itemInstances>\n            <fieldInstance>\n                <fieldInstanceProperties>\n                    <name>uiBehavior</name>\n                    <value>{behavior}</value>\n'
                f'                </fieldInstanceProperties>\n                <fieldItem>Record.{name}</fieldItem>\n                <identifier>{self.ident("Record" + name + where)}</identifier>\n{rule}            </fieldInstance>\n        </itemInstances>\n')
    def region(self, name, items, kind='Facet'):
        self.regions.append(f'    <flexiPageRegions>\n{"".join(items)}        <name>{name}</name>\n        <type>{kind}</type>\n    </flexiPageRegions>\n')
    def field_section(self, label, left, right=None, when=None):
        # `when` shows the whole section only while the rule holds (see visibility).
        key = re.sub(r'\W+', '', label)
        columns = []
        for index, fields in enumerate([left] if right is None else [left, right], start=1):
            facet = f'Facet-{key}-Column{index}'
            self.region(facet, [self.field(f, f'{key}Column{index}') for f in fields])
            columns.append(self.component('flexipage:column', self.prop('body', facet)))
        self.region(f'Facet-{key}-Columns', columns)
        section = self.component('flexipage:fieldSection', self.prop('columns', f'Facet-{key}-Columns') + self.prop('horizontalAlignment', 'false') + self.prop('label', label))
        if when:
            section = section.replace('            </componentInstance>\n', self.visibility(when, 16) + '            </componentInstance>\n')
        return section
    def related_list(self, parent, relationship, rows, label=None, columns=None, sort=None):
        """One related list on its own, so a tab holds exactly the lists it should and each loads by itself.
        With a label it is a dynamic list: its own title, columns and sort order, instead of the page layout's.
        Columns are named as they are in a page layout's related list ("CASES.SUBJECT", "NAME", "Reserve_Amount__c")."""
        if label is None:
            return self.component('force:relatedListSingleContainer', self.prop('parentFieldApiName', f'{parent}.Id') + self.prop('relatedListApiName', relationship) +
                                  self.prop('relatedListComponentOverride', 'ADVGRID') + self.prop('rowsToDisplay', rows) + self.prop('showActionBar', 'true'))
        sort_field, sort_order = sort or ('__DEFAULT__', 'Default')
        return self.component('lst:dynamicRelatedList', self.listprop('actionNames', ['New']) + '                <componentInstanceProperties>\n                    <name>adminFilters</name>\n                </componentInstanceProperties>\n' +
                              self.prop('maxRecordsToDisplay', rows) + self.prop('parentFieldApiName', f'{parent}.Id') + self.prop('relatedListApiName', relationship) +
                              self.prop('relatedListDisplayType', 'ADVGRID') + self.listprop('relatedListFieldAliases', columns) + self.prop('relatedListLabel', label) +
                              self.prop('showActionBar', 'true') + self.prop('sortFieldAlias', sort_field) + self.prop('sortFieldOrder', sort_order))
    def tab(self, body, title, ident, active=False):
        props = (self.prop('active', 'true') if active else '') + self.prop('body', body) + self.prop('title', title)
        self.n[ident] = 1
        return f'        <itemInstances>\n            <componentInstance>\n{props}                <componentName>flexipage:tab</componentName>\n                <identifier>{ident}</identifier>\n            </componentInstance>\n        </itemInstances>\n'

def custom(p, component, props=None, when=None):
    """A custom LWC with optional design properties. With `when` it shows only while the rule holds (see Page.visibility)."""
    body = ''.join(p.prop(k, v) for k, v in (props or {}).items())
    ident = p.ident('c_' + component)
    rule = p.visibility(when, 16) if when else ''
    return f'        <itemInstances>\n            <componentInstance>\n{body}                <componentName>{component}</componentName>\n                <identifier>{ident}</identifier>\n{rule}            </componentInstance>\n        </itemInstances>\n'

# Each list is drawn by the dynamic related list component, with its own title and columns. Set this to False to
# fall back to the standard single list, which takes its title and columns from the page layout.
OWN_TITLES = True
def exists(kind, name):
    """True once a component another stream owns is in the project, so a page can refer to it."""
    return os.path.exists(os.path.join(ROOT, kind, name))
# Stock related lists take about ten seconds to draw, so the pages use our own list component, which reads the
# same rows through Lightning Data Service and draws them at once. Set this to False to go back to the stock lists.
OWN_LISTS = exists('lwc', 'antsuranceRelatedList')
def own_list(relationship, child, title, fields, stock, parent_field=None, sort=None, empty=None, rows=None, icon=None, component=None, note=None, merge=None):
    """One related list. `fields` are our component's columns ("Path|Header|kind"), the first three being the
    ones that stay when the list is narrow; `stock` are the same columns as a page layout names them, for the
    stock list. `parent_field` is the child's lookup to this record: with it the list offers New.
    `icon` leads each row with an icon from the shared mapping ("asset:Asset_Type__c", or a kind alone such as "person").
    `component` names a component of our own that draws this list in place of the table, when it exists.
    `sort` may name several fields, comma-separated. `note` is one line under the title saying how to read the list.
    `merge` ("GroupPath|JoinPath") shows one row for each record at the end of GroupPath, with JoinPath's values joined."""
    return {'relationship': relationship, 'child': child, 'title': title, 'fields': fields, 'stock': stock,
            'parent_field': parent_field, 'sort': sort, 'empty': empty, 'rows': rows, 'icon': icon, 'component': component, 'note': note, 'merge': merge}
NOTES_TAB = ('File Notes', 'notesTabContent', 'notesTab', [('antsuranceFileNotes', None)])
def record_page(name, label, description, sobject, primary, secondary, actions, sections, sidebar=(), lists=(), second_lists=None, first_tab='detail',
                main_top=(), extra_tabs=(), activity=True, lead_tabs=(), rows=6, main_bottom=(), visible=None, side_sections=()):
    """One Lightning record page.

    secondary:  the two or three highlight fields the page's summary card does not already show (may be empty).
    actions:    header buttons, the main one first. Delete always ends up in the overflow menu.
    visible:    how many of them show as buttons, when fewer than all should. An action hidden by a rule does not
                count, so the next one slides into view: put any ruled action after the ones that must show.
    lists:        the related lists on the Related tab, three at most, none that a card on the page already shows.
                  Each comes from own_list(). With no lists the page has no Related tab.
    second_lists: (tab title, lists) for the rest, on a tab named for what it holds.
    side_sections: field sections for the sidebar, one column each, on a page whose main column is one piece of writing.
    sections:   the fields. Edit and Clone open exactly the fields a page carries in its sections, not the page layout
                (seen on Oct 5: Edit on a coverage offered four fields and no limit). So a page either carries every
                field a person may change, in a Details tab that comes last, or carries no sections at all, and then
                Edit opens the whole page layout. New always opens the page layout.
    lead_tabs:  tabs of our own that come first, the first one open. Details comes last on every page that has them.
    """
    p = Page()
    # Delete sits behind the overflow arrow on every page: everything before it shows, up to four buttons.
    ahead_of_delete = [a for a in actions if (a[0] if isinstance(a, tuple) else a) != 'Delete']
    visible_actions = min(len(ahead_of_delete), visible or 4)
    highlights = p.listprop('actionNames', actions) + p.prop('numVisibleActions', visible_actions) + p.prop('primaryField', 'Facet-PrimaryFields')
    p.region('Facet-PrimaryFields', [p.field(primary, 'PrimaryField')])
    if secondary:
        p.region('Facet-SecondaryFields', [p.field(f, 'SecondaryField') for f in secondary])
        highlights += p.prop('secondaryFields', 'Facet-SecondaryFields')
    p.region('header', [p.component('record_flexipage:dynamicHighlights', highlights)], 'Region')
    detail_items = [p.field_section(*s) for s in sections]
    tabs = {'detail': ('detailTabContent', 'Standard.Tab.detail', 'detailTab')}
    order = ['detail']
    def one_list(spec):
        shown = spec['rows'] or rows
        if spec['component'] and exists('lwc', spec['component']):
            return custom(p, spec['component'], {})
        if OWN_LISTS:
            props = {'childObject': spec['child'], 'emptyText': spec['empty'] or 'Nothing here yet.', 'fields': ', '.join(spec['fields']), 'relatedListId': spec['relationship'], 'rows': shown}
            if spec['icon']:
                props['icon'] = spec['icon']
            if spec['note']:
                props['note'] = spec['note']
            if spec['merge']:
                props['mergeBy'] = spec['merge']
            if spec['parent_field']:
                props['parentField'] = spec['parent_field']
            if spec['sort']:
                props['sortBy'] = spec['sort']
            props['title'] = spec['title']
            return custom(p, 'antsuranceRelatedList', props)
        if OWN_TITLES:
            return p.related_list(sobject, spec['relationship'], shown, label=spec['title'], columns=spec['stock'])
        return p.related_list(sobject, spec['relationship'], shown)
    if lists:
        assert len(lists) <= 3, f'{name}: at most three related lists on the first tab'
        p.region('relatedTabContent', [one_list(spec) for spec in lists])
        tabs['related'] = ('relatedTabContent', 'Standard.Tab.relatedLists', 'relatedListsTab')
        order = ['detail', 'related'] if first_tab == 'detail' else ['related', 'detail']
    if second_lists:
        second_title, second = second_lists
        p.region('secondTabContent', [one_list(spec) for spec in second])
        tabs['second'] = ('secondTabContent', second_title, 'secondTab')
        order.insert(order.index('related') + 1, 'second')
    for title, facet, ident, components in extra_tabs:
        p.region(facet, [custom(p, *item) for item in components])
        tabs[ident] = (facet, title, ident)
    # Extra tabs sit after the first tab (and the second list tab, when the first tab is Related), so notes and documents are one click from the default view.
    head = 2 if len(order) > 1 and order[1] == 'second' else 1
    order = order[:head] + [ident for _, _, ident, _ in extra_tabs] + order[head:]
    # Lead tabs come first and open by default, for a page whose main job is a component rather than the fields.
    for title, facet, ident, components in lead_tabs:
        p.region(facet, [custom(p, *item) for item in components])
        tabs[ident] = (facet, title, ident)
    order = [ident for _, _, ident, _ in lead_tabs] + order
    main = [custom(p, *item) for item in main_top]
    if order == ['detail']:
        # A page whose only tab would be Details shows its fields directly: one tab on its own is not a choice.
        main += detail_items
    else:
        p.region('detailTabContent', detail_items)
        p.region('maintabs', [p.tab(*tabs[key], active=(index == 0)) for index, key in enumerate(order)])
        main.append(p.component('flexipage:tabset', p.prop('tabs', 'maintabs')))
    # Components under the fields: on a small record's page, what it belongs to and its neighbours.
    main += [custom(p, *item) for item in main_bottom]
    p.region('main', main, 'Region')
    side = [custom(p, *item) for item in sidebar] + [p.field_section(*s) for s in side_sections]
    if activity:
        # The Activity panel stands on its own under the cards. There is no Chatter tab beside it: feeds are not used here.
        side.append(p.component('runtime_sales_activities:activityPanel', p.prop('showLegacyActivityComposer', 'false')))
    p.region('sidebar', side, 'Region')
    write(f'flexipages/{name}.flexipage-meta.xml', f'<FlexiPage {NS}>\n' + ''.join(p.regions) +
          f'    <description>{esc(description)}</description>\n    <masterLabel>{label}</masterLabel>\n    <sobjectType>{sobject}</sobjectType>\n'
          '    <template>\n        <name>flexipage:recordHomeTemplateDesktop</name>\n    </template>\n    <type>RecordPage</type>\n</FlexiPage>')

def brief(field_name, title, empty, quiet=False):
    props = {'emptyText': empty, 'fieldApiName': field_name}
    if quiet:
        # Draws nothing at all while the field is empty.
        props['hideWhenEmpty'] = 'true'
    props['title'] = title
    return ('antsuranceMarkdownField', props)

REQ, READ = 'required', 'readonly'
# The closing day has nothing to say until the case is closed, so it only shows then.
CLOSED_ON = ('Closed_On__c', READ, ('IsClosed', 'true'))
# Days Open counts up while the case is open. Once it closes, the card beside the fields says how long it took.
STILL_OPEN_FOR = ('Days_Open__c', READ, ('IsClosed', 'false'))
# A money field with nothing in it says nothing, so it shows only once it holds an amount.
def when_set(field_name, behavior='none'):
    return (field_name, behavior, (field_name, 0, 'GT'))
NOT_DRAFT = ('Status', 'Draft', 'NE')
BINDABLE = [('IsClosed', 'false'), ('StageName', 'Submission Received', 'NE')]
# A quote can be bound once it has gone out and until it is bound, declined or lapsed.
QUOTE_BINDABLE = [('Status', 'Draft', 'NE'), ('Status', 'Declined', 'NE'), ('Status', 'Expired', 'NE'), ('Status', 'Bound', 'NE')]
def while_open(action):
    """An action that only makes sense, and only shows, while the record is still open."""
    return (action, 'IsClosed', 'false')
# Header actions. Each record page lists its own, which replaces whatever the page layout offers: a standard button
# nobody lists here is simply not on the page. So every page was checked against what Salesforce offers for the
# object.
# An action Salesforce hides because it does not apply to the record (the portal login on a contact with no login)
# gives up its place in the row just as one hidden by a rule does. Wherever such an action is listed, count what
# shows without it, and keep enough actions that always show ahead of Delete that it can never become a button.
# Change Owner is Salesforce's own: owners are off the pages' fields, and a record's owner is who its automated
# tasks go to, so handing a customer, a lead, a sale or an open claim to someone else is one step behind the arrow.
CHANGE_OWNER = 'ChangeOwnerOne'
# A claim or a request has no activity composer (cases keep theirs in the feed, which these pages do not carry), so
# logging a call and setting a follow-up are header actions there. Email is left out: it hangs when opened on a case.
CASE_ACTIVITY = ['Case.LogACall', 'Global.NewTask', 'Global.NewEvent']

# The lists, each with our columns and the stock columns it replaces.
L_ASSETS = own_list('Assets__r', 'Policy_Asset__c', 'What Is Insured', ['Name|Insured|link', 'Asset_Type__c|Type', 'Insured_Value__c|Value|money', 'Identifier__c|Reference'], ASSET_LIST,
                    parent_field='Policy__c', sort='Name', empty='Nothing is listed as insured on this policy yet.', icon='asset:Asset_Type__c')
L_COVERAGES = own_list('Coverages__r', 'Policy_Coverage__c', 'Coverages', ['Name|Coverage|link', 'Limit_Amount__c|Limit|money', 'Limit_Type__c|Basis', 'Deductible_Amount__c|Deductible|money', 'Premium_Amount__c|Premium|money'], COVERAGE_LIST,
                       parent_field='Policy__c', sort='-Premium_Amount__c', empty='No coverages on this policy yet.', rows=10, icon='coverage:Name',
                       component='antsurancePolicyCoverages')
L_PARTICIPANTS = own_list('Participants__r', 'Policy_Participant__c', 'Participants', ['Name|Participant|link', 'Relationship_to_Insured__c|Relationship', 'Status__c|Status|chip', 'Effective_Date__c|Since|date'], PARTICIPANT_LIST,
                          # Roles in the order the picklist gives them, so the named insured leads on every policy (one
                          # person can hold two roles, and "Driver" sorts ahead of "Named Insured" by name). Then the primary, then by name.
                          parent_field='Policy__c', sort='Role__c,-Is_Primary__c,Name', empty='Nobody is listed on this policy yet.', icon='role:Role__c')
L_ENDORSEMENTS = own_list('Endorsements__r', 'Policy_Endorsement__c', 'Endorsements', ['Name|Form|link', 'Form_Number__c|Number', 'Premium_Change__c|Premium change|money', 'Type__c|Type'], ENDORSEMENT_LIST,
                          # The coverages add up to the annual premium, so the page says these amounts are not on top of it.
                          parent_field='Policy__c', sort='Name', empty='No endorsements on this policy.', icon='kind:Type__c',
                          note='Premium changes here are already in the coverage premiums. They are not added to the annual premium again.')
L_POLICY_CASES = own_list('Cases__r', 'Case', 'Claims and Service Requests', ['Subject|Claim or request|link', 'Kind__c|Type', 'Status|Status|chip', 'Outstanding_Reserve__c|Still to pay|money', 'Reported_Date__c|Reported|date', 'CaseNumber|Number'], POLICY_CASE_LIST,
                          # No New on this list. It opened the stock form for a service request only, never a claim, with the
                          # customer and contact left blank. The header's File a Claim and New Service Request fill those in.
                          sort='-Reported_Date__c', empty='No claims or service requests on this policy.', icon='kind:Kind__c')
def cases_for(empty, parent_field=None):
    # A customer's or a person's claims and service requests under their own title: the standard list would be headed "Cases".
    # The list offers New only where `parent_field` is given: on a page whose header has no action that starts one.
    return own_list('Cases', 'Case', 'Claims and Service Requests', ['Subject|Claim or request|link', 'Kind__c|Type', 'Status|Status|chip', 'Reported_Date__c|Reported|date', 'CaseNumber|Number'], CASE_LIST,
                    parent_field=parent_field, sort='-Reported_Date__c', empty=empty, icon='kind:Kind__c')
def people(title, role_column, stock, empty, sort='Name'):
    return own_list('Contacts', 'Contact', title, ['Name|Name|link', role_column, 'Phone|Phone', 'Email|Email'], stock, parent_field='AccountId', sort=sort, empty=empty, icon='person')
L_SALES = own_list('Opportunities', 'Opportunity', 'Policy Sales', ['Name|Policy sale|link', 'StageName|Stage|chip', 'Amount|Amount|money', 'CloseDate|Close date|date'], OPP_LIST,
                   parent_field='AccountId', sort='-CloseDate', empty='No policy sales with this customer yet.', icon='line:Line_of_Business__c')
# An agency's page is about the business it has written, so that list leads its main column, largest premium first, and shows more rows.
L_PRODUCED = own_list('Policies_Produced__r', 'Policy__c', 'Policies Produced', ['Name|Policy|link', 'Account__r.Name|Policyholder|lookup', 'Annual_Premium__c|Premium|money', 'Line_of_Business__c|Line', 'Status__c|Status|chip', 'Expiration_Date__c|Expires|date'],
                      ['NAME', 'Account__c', 'Line_of_Business__c', 'Status__c', 'Annual_Premium__c'], sort='-Annual_Premium__c', empty='This agency has not produced a policy yet.', rows=10, icon='line:Line_of_Business__c')
# On a person's own page their name would repeat down the list, so it leads with the policy. A person can hold two
# roles on one policy, so the list shows one row for each policy with the roles joined, and its count matches the card.
L_ON_POLICIES = own_list('Policy_Roles__r', 'Policy_Participant__c', 'On These Policies', ['Policy__r.Name|Policy|lookup', 'Role__c|Roles', 'Status__c|Status|chip', 'Policy__r.Line_of_Business__c|Line', 'Effective_Date__c|Since|date'],
                         ['Policy__c', 'Role__c', 'Status__c', 'Effective_Date__c'], sort='-Effective_Date__c', empty='This person is not on a policy.', icon='line:Policy__r.Line_of_Business__c',
                         merge='Policy__r.Name|Role__c')

# One flat status bar on leads, claims, service requests and policy sales. Salesforce's own Path is not used:
# it does not draw on leads in this org, and its filled "Mark Status as Complete" button outranked the real actions.
STATUS_PATH = [('antsuranceStatusPath', None)]
# Claude in claims: a stored brief above the tabs, a Documents tab that reads attached files, and filing a claim from pasted text.
CLAIM_BRIEF = [('antsuranceClaimBrief', None)] if exists('lwc', 'antsuranceClaimBrief') else []
# The coverage check sits between the status bar and the brief: one slim band until the adjuster opens the reasoning.
COVERAGE_CHECK = [('antsuranceCoverageCheck', None)] if exists('lwc', 'antsuranceCoverageCheck') else []
CLAIM_DOCS_TAB = [('Documents', 'claimDocsTabContent', 'claimDocsTab', [('antsuranceClaimDocuments', None)])] if exists('lwc', 'antsuranceClaimDocuments') else []
# The claim analysis: the evidence docket and the one-button run that ends in an adjuster's report.
CLAIM_ANALYSIS_TAB = [('Analysis', 'claimAnalysisTabContent', 'claimAnalysisTab', [('antsuranceClaimAnalysis', None)])] if exists('lwc', 'antsuranceClaimAnalysis') else []
CLAUDE_CLAIM_ON_POLICY = ['Policy__c.File_Claim_With_Claude'] if exists('quickActions', 'Policy__c.File_Claim_With_Claude.quickAction-meta.xml') else []
CLAUDE_CLAIM_ON_CUSTOMER = ['Account.File_Claim_With_Claude'] if exists('quickActions', 'Account.File_Claim_With_Claude.quickAction-meta.xml') else []
# With Claude's claim action in the org it is the one claim button, and the plain form waits behind the arrow.
POLICY_ACTIONS = ((CLAUDE_CLAIM_ON_POLICY + ['Policy__c.New_Service_Request', 'Edit', ('Policy__c.Add_Driver', 'Line_of_Business__c', 'Personal Auto'), 'Policy__c.File_Claim', 'Delete'])
                  if CLAUDE_CLAIM_ON_POLICY else
                  ['Policy__c.File_Claim', 'Policy__c.New_Service_Request', 'Edit', ('Policy__c.Add_Driver', 'Line_of_Business__c', 'Personal Auto'), 'Delete'])
# The underwriter's review of a referred quote: why it was referred, Claude's memo and the decision. It shows only when there is something to review.
UNDERWRITING_REVIEW = [('antsuranceUnderwritingReview', None)] if exists('lwc', 'antsuranceUnderwritingReview') else []
# A renewal outreach card on the policy: it shows only while the policy is pending renewal.
RENEWAL_OUTREACH = [('antsuranceRenewalOutreach', None)] if exists('lwc', 'antsuranceRenewalOutreach') else []
# Documents: declarations, ID cards and certificates on a policy, and the proposal on a sale. Before the
# documents component existed the policy page showed the declarations viewer on its own.
if exists('lwc', 'antsuranceDocuments'):
    DEC_TAB = [('Documents', 'documentsTabContent', 'documentsTab', [('antsuranceDocuments', None)])]
    SALE_DOCS_TAB = [('Documents', 'documentsTabContent', 'documentsTab', [('antsuranceDocuments', None)])]
else:
    DEC_TAB = [('Declarations', 'decTabContent', 'decTab', [('antsuranceDecPageViewer', None)])] if exists('lwc', 'antsuranceDecPageViewer') else []
    SALE_DOCS_TAB = []

# Highlights: where a page has a summary card, the panel under the title carries only what the card does not show.
# Tabs: a page with related lists opens on them; a page with none has no Related tab and opens on its details.

# A policy has no status bar: Active, Lapsed, Cancelled and Expired are not steps in a sequence, and the card shows the status.
record_page('Policy_Record_Page', 'Policy Record Page', 'Policy page: an insurance card, what the policy insures and covers, its documents and file notes.', 'Policy__c',
    # The strip holds the person to deal with and nothing longer. Each field there sits in a column about thirty
    # characters wide at full width and about eighteen at 1,024: "Copperfield Property Management" broke over two
    # lines in it, and so did an agency's name once the page was narrow (a formula made to hold the line broke
    # mid-word instead). The policy card names the policyholder and the producer in full, each linked, as an
    # insurance card names the insured and the agent.
    'Name', ['Primary_Insured__c'],
    # One button files a claim: with Claude, which also takes it by hand. A service request and Edit sit beside it on
    # every policy. Behind the arrow: Add a Driver (personal auto only, the only policies that rate drivers), the plain
    # claim form and Delete. The ruled action comes after the three that must show, so it cannot push Edit out of view.
    POLICY_ACTIONS,
    [('Policy', [('Name', REQ), ('Account__c', READ), 'Primary_Insured__c'], ['Line_of_Business__c', 'Status__c', 'Producer__c']),
     ('Term and Billing', ['Effective_Date__c', 'Expiration_Date__c', ('Days_to_Renewal__c', READ)], ['Billing_Frequency__c', 'Payment_Status__c']),
     ('Coverage', ['Annual_Premium__c', 'Coverage_Limit__c', ('Incurred_Losses__c', READ)], ['Deductible__c', 'Insured_Item__c', ('Loss_Ratio__c', READ)])],
    sidebar=[('antsurancePolicySummary', None), brief('Underwriting_Notes__c', 'Underwriting notes', 'No underwriting notes yet.')],
    # Claude's renewal draft is long writing, so it sits in the wide column above the tabs; it draws nothing unless the policy is pending renewal.
    main_top=RENEWAL_OUTREACH,
    # What the policy covers and insures and what has been claimed on it come first, so a claims person lands on the claims.
    # Who is on it and its forms are one tab over, named for what it holds. Salesforce capitalizes every word of a tab
    # title, so it uses an ampersand: "People And Endorsements" reads as a mistake.
    first_tab='related', lists=[L_COVERAGES, L_ASSETS, L_POLICY_CASES],
    second_lists=('People & Endorsements', [L_PARTICIPANTS, L_ENDORSEMENTS]), extra_tabs=DEC_TAB + [NOTES_TAB], visible=3)

CASE_STRIP = ['CaseNumber', 'Policy__c', 'ContactId']
# A closed claim is a record to keep, so Delete goes away with Record a Payment once it closes.
# The owner, the priority and the subject are left off the details: Handled By, Severity and the page title say the same.
record_page('Claim_Record_Page', 'Claim Record Page', 'Claim page: the status bar, a reserve meter, loss details, documents and the file notes.', 'Case',
    # The strip holds short values only: each sits in a column about thirty characters wide, and a customer's name
    # ("Copperfield Property Management") broke over two lines there. The person to call is in the strip; the
    # customer is named in full, linked, at the foot of the card beside the tabs (antsuranceCaseSummary), because
    # on a business's claim the two are different and both matter.
    'Subject', CASE_STRIP,
    # Two buttons: the payment and Edit on an open claim. Once it closes, the payment, Change Owner and Delete go, and
    # Log a Call takes the second place: a call about a closed claim is still worth recording.
    [while_open('Case.Record_Payment'), 'Edit'] + CASE_ACTIVITY + [while_open(CHANGE_OWNER), while_open('Delete')],
    [('Claim', [('CaseNumber', READ), ('Status', REQ), 'Handled_By__c', CLOSED_ON], ['AccountId', 'ContactId', 'Policy__c', 'Origin']),
     ('Loss Details', ['Date_of_Loss__c', 'Reported_Date__c', STILL_OPEN_FOR, 'Loss_Type__c'], ['Severity__c', 'Loss_Location__c', ('Coverage_Check__c', READ)]),
     ('Financials', ['Estimated_Loss__c', 'Reserve_Amount__c', 'Paid_Amount__c'], [('Outstanding_Reserve__c', READ), 'SIU_Referral__c', 'Subrogation_Potential__c']),
     # The subject is the page's title, and Edit opens only what the page carries, so it sits here to be changed.
     ('What Happened', ['Subject', 'Description'])],
    # The Documents tab holds a claim's files, so there is nothing left for a Related tab to show.
    # The file comes first: notes, documents, analysis. The plain fields are the last tab, not the one a claim opens on.
    sidebar=[('antsuranceCaseSummary', None)], lead_tabs=[NOTES_TAB] + CLAIM_DOCS_TAB + CLAIM_ANALYSIS_TAB, main_top=STATUS_PATH + COVERAGE_CHECK + CLAIM_BRIEF, visible=2)
record_page('Policy_Service_Record_Page', 'Policy Service Record Page', 'Policy service request page: the status bar, what was asked for and the file notes.', 'Case',
    'Subject', CASE_STRIP,
    # Most requests arrive and are answered by phone, so Log a Call shows beside Edit, open or closed.
    ['Edit'] + CASE_ACTIVITY + [while_open(CHANGE_OWNER), while_open('Delete')],
    [('Request', [('CaseNumber', READ), ('Status', REQ), 'Request_Type__c', 'Handled_By__c'], ['AccountId', 'ContactId', 'Policy__c', 'Origin']),
     ('Timing', ['Reported_Date__c', CLOSED_ON], [STILL_OPEN_FOR]),
     ('What Was Asked', ['Subject', 'Description'])],
    # What was asked is the page's content, so it sits above the tabs as written; the file notes open first and the
    # plain fields come last.
    sidebar=[('antsuranceCaseSummary', None)], lead_tabs=[NOTES_TAB], visible=2,
    main_top=STATUS_PATH + [brief('Description', 'What was asked', 'Nothing written about this request yet.')])

# Customers: one page each for a household, a business and an agency, because they hold different facts.
CUSTOMER_ACTIONS = ((CLAUDE_CLAIM_ON_CUSTOMER + ['Account.New_Service_Request', 'Edit', 'Account.File_Claim', CHANGE_OWNER, 'Delete'])
                    if CLAUDE_CLAIM_ON_CUSTOMER else ['Account.File_Claim', 'Account.New_Service_Request', 'Edit', CHANGE_OWNER, 'Delete'])
# No New here either: the header's two actions start a claim or a request with the policy chosen.
CUSTOMER_CASES = cases_for('No claims or service requests from this customer.')
# The glance card already shows the policies as tiles with "View all", so the first tab does not list them again.
def customer_lists(people_list):
    return [people_list, CUSTOMER_CASES, L_SALES]
def customer_page(name, label, description, sections, brief_title, brief_empty, lists, actions=CUSTOMER_ACTIONS, notes=True, visible=3):
    # No highlight fields: the card beside the tabs carries the phone, the segment and the counts.
    record_page(name, label, description, 'Account', 'Name', [], actions, sections, visible=visible,
        # The brief leads the main column, so it is the first thing read and the two columns end nearer each other.
        main_top=[brief('Customer_Brief__c', brief_title, brief_empty)], sidebar=[('antsuranceCustomerSummary', None)],
        first_tab='related', lists=lists, extra_tabs=[NOTES_TAB] if notes else [])
customer_page('Household_Record_Page', 'Household Record Page', 'Household page: who is in the household, how its policies are performing, the customer brief and file notes.',
    [('Household', [('Name', REQ), 'Phone', 'Customer_Segment__c'], ['Customer_Since__c', ('Active_Policies__c', READ), ('Premium_in_Force__c', READ)]),
     ('Home Address', ['BillingAddress'])],
    'Customer brief', 'No brief written for this customer yet.', customer_lists(people('Household Members', 'Household_Role__c|Role', MEMBER_LIST, 'Nobody is listed in this household yet.', sort='-Primary_Member__c,Name')))
customer_page('Business_Record_Page', 'Business Record Page', 'Business customer page: the company, how its policies are performing, the customer brief and file notes.',
    [('Business', [('Name', REQ), 'Phone', 'Website'], ['Industry', 'NumberOfEmployees', 'AnnualRevenue']),
     ('Customer', ['Customer_Since__c', 'Customer_Segment__c', 'Type'], [('Active_Policies__c', READ), ('Premium_in_Force__c', READ)]),
     ('Address', ['BillingAddress'])],
    'Customer brief', 'No brief written for this customer yet.', customer_lists(people('Contacts', 'Title|Title', STAFF_LIST, 'No contacts at this business yet.')))
# An agency holds no policies of its own and files no claims, so its page drops those counts and actions.
customer_page('Agency_Record_Page', 'Agency Record Page', 'Agency page: the agency, the policies it has produced and the people there.',
    [('Agency', [('Name', REQ), 'Phone'], ['Website']),
     ('Address', ['BillingAddress'])],
    # The wide column carries the content: the policies the agency has produced, then the people there.
    'Agency brief', 'No brief written for this agency yet.', [L_PRODUCED, people('People at the Agency', 'Title|Title', STAFF_LIST, 'Nobody is listed at this agency yet.')], actions=['Edit', CHANGE_OWNER, 'Delete'], notes=False, visible=1)

# "Read a submission": a broker's application and loss runs are dropped here and Claude fills the quote's answers for a
# person to check. At rest it is one quiet row, so it sits above the quotes it leads to, on the sale and on the lead.
# A broker sends a submission for a business, so the card shows on the commercial lines only: on a household's auto
# or home it asked for documents nobody sends.
COMMERCIAL_LINES = ['Commercial Property', 'General Liability', 'Workers Compensation', 'Commercial Auto']
def submission(line_field):
    if not exists('lwc', 'antsuranceSubmissionIntake'):
        return []
    return [('antsuranceSubmissionIntake', None, ('ANY', [(line_field, line) for line in COMMERCIAL_LINES]))]
# A bound or declined sale is a record to keep, so Delete goes away with the quoting buttons once it closes.
record_page('Policy_Sale_Record_Page', 'Policy Sale Record Page', 'Policy sale page: the status bar, the quotes laid out as options, binding and the proposal.', 'Opportunity',
    # The amount is left to the quote board, which shows each option's price in whole dollars.
    # A sale is named for its customer ("Copperfield Property Management - ..."), so the strip does not say it again:
    # a long customer name broke over two lines there. The customer is linked in Details.
    # The type of sale ("Cross-Sell") is a word for reports, not for the top of the page, so it stays in Details.
    # The line of business is said in words on the quote board, beside its icon: in the strip "Workers Compensation"
    # broke over two lines on a small screen, and a strip column is too narrow for a line's full name.
    'Name', ['CloseDate'],
    # There is nothing to bind until the sale has been worked past the first stage and something has been priced.
    # A hidden action gives up its place in the row, so Delete carries the same rule as Bind Policy: otherwise it
    # would slide out of the overflow menu and sit beside Edit on a sale that has only just come in.
    # Change Owner hands an open sale to someone else. On a sale that has only just come in, Bind Policy and Delete are
    # hidden and it takes the third place, which is when a submission is assigned; after that it waits behind the arrow.
    [while_open('Opportunity.Generate_Quote'), ('Opportunity.Bind_Policy', BINDABLE), 'Edit', while_open(CHANGE_OWNER), ('Delete', BINDABLE)],
    [('Policy Sale', [('Name', REQ), 'AccountId', 'Type', 'Line_of_Business__c'], [('StageName', REQ), ('CloseDate', REQ), 'Amount', 'Policy__c']),
     ('Source and Next Step', ['LeadSource', 'NextStep'], ['Description'])],
    # The quote board above the tabs is the list of quotes, so the page has no Related tab to repeat it.
    # The proposal and the other documents open first; the plain fields are the last tab.
    main_top=STATUS_PATH + submission('Line_of_Business__c') + [('antsuranceQuoteBoard', None)], lead_tabs=SALE_DOCS_TAB, visible=3)
record_page('Quote_Record_Page', 'Quote Record Page', 'Quote page: the configurator and its answers, the terms offered and what the option includes.', 'Quote',
    # A quote is named for its option alone ("Standard limits"), so the header says which sale it belongs to and what it costs.
    # No strip: the card beside the tabs names the sale, the premium, the number and the status, and the sale's long
    # name broke over two lines in the strip.
    'Name', [], # A hidden action gives up its place in the row, so Delete carries Bind This Quote's rule: otherwise it would slide
    # out of the menu and sit beside Edit on a draft or a bound quote.
    [('Quote.Bind_Quote', QUOTE_BINDABLE), 'Edit', ('Delete', QUOTE_BINDABLE)],
    [('Quote', [('QuoteNumber', READ), ('Name', REQ), 'OpportunityId', 'Status', 'Underwriter__c'],
      # A draft has not gone to the customer, so it has no issue date, expiry or age to show yet.
      ['Annual_Premium__c', 'Coverage_Limit__c', 'Deductible__c', ('Issued_Date__c', 'none', NOT_DRAFT), ('ExpirationDate', 'none', NOT_DRAFT), ('Days_Since_Issued__c', READ, NOT_DRAFT)])],
    sidebar=[('antsuranceQuoteSummary', None), brief('Description', 'What this option includes', 'Nothing written about this option yet.')],
    # The underwriting review holds Claude's memo, which is long writing, so it sits in the wide column above the tabs.
    main_top=UNDERWRITING_REVIEW,
    lead_tabs=[('Configuration', 'configurationTabContent', 'configurationTab', [('antsuranceQuoteConfigurator', None)])])

# The records under a policy have no lists of their own, so their pages are a card beside the details.
# A coverage or an insured asset is a small record with half a page to spare. Under its fields it shows the policy's
# coverages, the one being viewed marked: where this record sits, and a step to its neighbours.
POLICY_COVERAGES_BELOW = [('antsurancePolicyCoverages', {'parentField': 'Policy__c'})] if exists('lwc', 'antsurancePolicyCoverages') else []
POLICY_COVERAGES_RAIL = [('antsurancePolicyCoverages', {'parentField': 'Policy__c', 'rows': '8'})] if exists('lwc', 'antsurancePolicyCoverages') else []
# A participant record is one role on one policy. Under its fields sits the person's file: every policy they are on
# and in what roles, the claims and requests that name them, and who else is on this policy.
PERSON_FILE_BELOW = [('antsurancePersonFile', None)] if exists('lwc', 'antsurancePersonFile') else []
record_page('Policy_Participant_Record_Page', 'Policy Participant Record Page', 'Participant page: the person, their role and, for a driver, the license and record they are rated on.', 'Policy_Participant__c',
    # The header strip carries the policy and the person, as the coverage and asset pages carry their policy.
    'Name', ['Policy__c', 'Contact__c'], ['Edit', 'Delete'],
    # The card says most of this, so the fields are the last tab, behind the person's file. They are every field,
    # because Edit opens only what the page carries.
    [('Participant', [('Name', REQ), ('Policy__c', READ), 'Contact__c', 'Relationship_to_Insured__c'], ['Role__c', 'Status__c', 'Is_Primary__c', 'Effective_Date__c', 'Expiration_Date__c']),
     # Only a driver has a license and a record to rate, so the section shows only for that role.
     ('Driver', ['License_Number__c', 'License_State__c', 'Date_Licensed__c', ('Years_Licensed__c', READ), 'Primary_Vehicle__c'],
      ['Driver_Rating__c', 'Violations_Past_3_Years__c', 'Accidents_Past_3_Years__c', 'Good_Student_Discount__c'], ('Role__c', 'Driver'))],
    # Notes show once there is one; until then Edit is where a note starts, not an empty box in the rail.
    sidebar=[('antsuranceParticipantSummary', None), brief('Notes__c', 'Notes', 'No notes on this participant.', quiet=True)], activity=False,
    lead_tabs=[('Policies & Claims', 'personFileTabContent', 'personFileTab', PERSON_FILE_BELOW)] if PERSON_FILE_BELOW else [])
record_page('Policy_Coverage_Record_Page', 'Policy Coverage Record Page', 'Coverage page: limit, deductible, what it covers and its share of the premium.', 'Policy_Coverage__c',
    # The header strip carries the way back to the policy; the card beside the fields links the policyholder too.
    # Clone starts a second coverage on the same policy from this one's limit, deductible and wording.
    'Name', ['Policy__c'], ['Edit', 'Clone', 'Delete'],
    # The card shows the limit, what it is measured by, the deductible, the premium and its share, and names the
    # policy. The fields are the last tab, behind the policy's coverages, and they are every field: with only four
    # of them on the page, Edit could not change a limit, a deductible or a premium.
    [('Coverage', [('Name', REQ), ('Policy__c', READ), 'Category__c', 'Status__c', 'Effective_Date__c'],
      ['Limit_Amount__c', 'Limit_Type__c', 'Deductible_Amount__c', 'Premium_Amount__c', ('Premium_Share__c', READ)]),
     ('What Is Covered', ['What_Is_Covered__c'])],
    sidebar=[('antsuranceCoverageSummary', None)], activity=False, visible=1,
    lead_tabs=[('Policy Coverages', 'policyCoveragesTabContent', 'policyCoveragesTab', POLICY_COVERAGES_BELOW)] if POLICY_COVERAGES_BELOW else [])
record_page('Policy_Endorsement_Record_Page', 'Policy Endorsement Record Page', 'Endorsement page: the form, what it does to the premium, the policy it sits on and what it changes.', 'Policy_Endorsement__c',
    'Name', [], ['Edit', 'Delete'],
    # No field sections: the card shows the form number, type, status, date, premium effect, limit and policy, so a
    # block of the same fields under it said everything twice. Edit opens every field, from the page layout.
    [],
    main_top=[('antsuranceEndorsementSummary', None)], sidebar=[brief('Description__c', 'What this form does', 'No description yet.')], activity=False)
# Under the viewer, the claims and requests on the policy the asset is insured on, and what else that policy insures,
# both read one step up through the asset's lookup. The viewer alone is shorter than the coverages beside it, which
# left the wide column empty below it.
ASSET_POLICY_CASES = [('antsuranceRelatedList', {
    'childObject': 'Case', 'emptyText': 'No claims or service requests on this policy.',
    'fields': ', '.join(['Subject|Claim or request|link', 'Kind__c|Type', 'Status|Status|chip', 'Outstanding_Reserve__c|Still to pay|money', 'Reported_Date__c|Reported|date', 'CaseNumber|Number']),
    'icon': 'kind:Kind__c', 'relatedListId': 'Cases__r', 'rows': 5, 'sortBy': '-Reported_Date__c', 'through': 'Policy__c',
    'title': 'Claims and requests on this policy'}),
    # And what else the policy insures: the other vehicles or buildings on the same schedule, this one left out.
    ('antsuranceRelatedList', {
    'childObject': 'Policy_Asset__c', 'emptyText': 'Nothing else is insured on this policy.',
    'fields': ', '.join(['Name|Insured|link', 'Asset_Type__c|Type', 'Insured_Value__c|Value|money', 'Identifier__c|Reference']),
    'icon': 'asset:Asset_Type__c', 'relatedListId': 'Assets__r', 'rows': 5, 'sortBy': 'Name', 'through': 'Policy__c',
    'title': 'Also insured on this policy'})] if OWN_LISTS else []
record_page('Insured_Asset_Record_Page', 'Insured Asset Record Page', 'Insured asset page: a photo or map of what is insured beside its details, the claims on its policy and what else it insures.', 'Policy_Asset__c',
    # The header strip carries the way back to the policy; the viewer beside the details links the policyholder too.
    # Clone adds the next vehicle or building on a schedule from this one, with only what differs left to change.
    'Name', ['Policy__c'], ['Edit', 'Clone', 'Delete'],
    # No field sections: the viewer shows every field once, labeled for the kind of asset ("Year built" on a home,
    # "Model year" and "VIN" on a vehicle), and leaves out what an asset does not have. Edit opens every field.
    [],
    # The asset is the subject, so it takes the main column (the viewer lays itself out wide there: picture or map
    # beside the facts). The policy's coverages, which the coverage page also shows, step back to the rail.
    # In the rail the card shows eight coverages at a time and steps to the rest, so it stays under a screen.
    main_top=[('antsuranceAssetViewer', None)], main_bottom=ASSET_POLICY_CASES, sidebar=POLICY_COVERAGES_RAIL, activity=False, visible=1)

# A file note opened on its own, from search, a report or a link. It had no page of ours, so it fell back to the
# stock page, whose header led with New Contact and New Lead. The note is the subject, so it takes the wide column
# as written; what it is filed under sits beside it.
record_page('File_Note_Record_Page', 'File Note Record Page', 'File note page: the note as written, beside who wrote it and the claim, policy and customer it is filed under.', 'File_Note__c',
    'Name', [], ['Edit', 'Delete'], [],
    main_top=[brief('Body__c', 'Note', 'Nothing written in this note.')],
    side_sections=[('Filed Under', ['Note_Type__c', 'Note_Date__c', 'Author_Name__c', 'Case__c', 'Policy__c', 'Account__c'])], activity=False)

# The contact card shows the name, role, household and how to reach the person, so the highlights panel repeats none of it.
# "Log in to Experience as User" is Salesforce's own button (LoginToNetworkAsUser): it opens the customer portal
# as this contact, and Salesforce shows it only on a contact who has a portal login.
record_page('Contact_Record_Page', 'Contact Record Page', 'Contact page: who the person is to the customer, how to reach them and the policies they are on.', 'Contact',
    'Name', [], ['LoginToNetworkAsUser', 'Edit', 'EnableCustomerPortal', CHANGE_OWNER, 'Delete'],
    [('Contact', [('Name', REQ), 'AccountId', 'Title'], ['Email', 'Phone', 'MobilePhone', 'Preferred_Contact_Method__c']),
     ('Household', ['Household_Role__c', 'Primary_Member__c'], ['Birthdate', 'Licensed_Driver__c']),
     ('Address', ['MailingAddress'])],
    # The wide column carries the content: the policies the person is on, then the claims and requests they are the contact for.
    sidebar=[('antsuranceContactSummary', None)], first_tab='related',
    # A contact's header has no action that starts a request, so this list keeps New: it opens a service request
    # with the person filled in, and Salesforce fills the customer from the contact on saving.
    lists=[L_ON_POLICIES, cases_for('No claims or service requests with this person as the contact.', parent_field='ContactId')],
    # One button shows. On a contact with a portal login it is the login; on anyone else Salesforce hides that
    # action and the next one, Edit, takes its place. With two showing, Delete slid out as a button on every
    # contact without a login (seen on Oct 5). Behind the arrow: Enable Customer User, which Salesforce offers only
    # on a contact with no login yet (it is how one is given), then Change Owner and Delete.
    visible=1)
# The lead's card leads the sidebar: what they asked about, how warm they are and how to reach them.
LEAD_CARD = [('antsuranceLeadSummary', None)] if exists('lwc', 'antsuranceLeadSummary') else []
record_page('Lead_Record_Page', 'Lead Record Page', 'Lead page: the status bar, what the lead wants and what is known about them.', 'Lead',
    # No highlight fields: the status bar and the fields sit right under the name, so a strip would only repeat them.
    'Name', [], ['Convert', 'Edit', CHANGE_OWNER, 'Delete'],
    # The card shows what they asked about, how warm they are, where they came from and how to reach them, and the bar
    # shows the status. What is known about them is writing, so it opens first in the wide column. The fields are the
    # last tab and they are every field: with only the name and address on the page, Edit could not change an email,
    # a phone number or what the lead asked about.
    [('Lead', [('Name', REQ), ('Company', REQ), 'Product_Interest__c'], [('Status', REQ), 'Rating', 'LeadSource']),
     ('Contact Details', ['Email', 'Phone'], ['Address'])],
    sidebar=LEAD_CARD, main_top=STATUS_PATH + submission('Product_Interest__c'), visible=2,
    lead_tabs=[('Notes', 'leadNotesTabContent', 'leadNotesTab', [brief('Description', 'What we know', 'Nothing noted about this lead yet.')])])

# =============================================================== app: navigation and page assignment
def override(page, sobject, record_type=None):
    if record_type is None:
        return (f'    <actionOverrides>\n        <actionName>View</actionName>\n        <comment>Antsurance record page for this object.</comment>\n        <content>{page}</content>\n        <formFactor>Large</formFactor>\n'
                f'        <skipRecordTypeSelect>false</skipRecordTypeSelect>\n        <type>Flexipage</type>\n        <pageOrSobjectType>{sobject}</pageOrSobjectType>\n    </actionOverrides>\n')
    return (f'    <profileActionOverrides>\n        <actionName>View</actionName>\n        <content>{page}</content>\n        <formFactor>Large</formFactor>\n        <pageOrSobjectType>{sobject}</pageOrSobjectType>\n'
            f'        <recordType>{sobject}.{record_type}</recordType>\n        <type>Flexipage</type>\n        <profile>Admin</profile>\n    </profileActionOverrides>\n')
# Home: the cockpit is the app's own Home page, so the address /lightning/page/home and every other route to Home land
# on it, and the stock Home (a sales chart and an assistant list) cannot be reached inside the app. It is assigned here,
# in the app, and not as the org's default.
# The stock Home template keeps a third of the width for a sidebar, so the page uses a template of our own with one
# full-width region (aura/antsuranceHomeTemplate): page templates can only be written as Aura components.
HOME_PAGE = 'Antsurance_Home_Page' if exists('lwc', 'antsuranceHomePage') and exists('aura', 'antsuranceHomeTemplate') else None
if HOME_PAGE:
    home = Page()
    home.region('main', [custom(home, 'antsuranceHomePage')], 'Region')
    write(f'flexipages/{HOME_PAGE}.flexipage-meta.xml', f'<FlexiPage {NS}>\n' + ''.join(home.regions) +
          '    <description>The Antsurance cockpit as the app\'s Home page.</description>\n    <masterLabel>Antsurance Home Page</masterLabel>\n'
          '    <template>\n        <name>c:antsuranceHomeTemplate</name>\n    </template>\n    <type>HomePage</type>\n</FlexiPage>')
# With the cockpit assigned as the app's Home page, the bar's Home item is the standard Home, so there is one Home
# however it is reached. The Antsurance_Home tab stays defined, for links that still point at /lightning/n/Antsurance_Home.
HOME_TAB = 'standard-home' if HOME_PAGE else 'Antsurance_Home'
def home_override():
    if not HOME_PAGE:
        return ''
    return (f'    <profileActionOverrides>\n        <actionName>Tab</actionName>\n        <content>{HOME_PAGE}</content>\n        <formFactor>Large</formFactor>\n'
            '        <pageOrSobjectType>standard-home</pageOrSobjectType>\n        <type>Flexipage</type>\n        <profile>Admin</profile>\n    </profileActionOverrides>\n')
# A customer of no particular record type gets the business page; the three record types get their own below.
APP_PAGES = [('Business_Record_Page', 'Account'), ('Contact_Record_Page', 'Contact'), ('Lead_Record_Page', 'Lead'), ('Insured_Asset_Record_Page', 'Policy_Asset__c'), ('Policy_Sale_Record_Page', 'Opportunity'), ('Policy_Coverage_Record_Page', 'Policy_Coverage__c'),
             ('File_Note_Record_Page', 'File_Note__c'), ('Policy_Endorsement_Record_Page', 'Policy_Endorsement__c'), ('Policy_Participant_Record_Page', 'Policy_Participant__c'), ('Policy_Record_Page', 'Policy__c'),
             ('Quote_Record_Page', 'Quote')]
# The stock Tasks tab draws as a narrow strip on some cold loads and names a claim by its number, so the app's
# Tasks item is our own tab. The stock list is one link away from it.
OWN_TASKS = exists('lwc', 'antsuranceTasks')
if OWN_TASKS:
    write('tabs/Antsurance_Tasks.tab-meta.xml', f'''<CustomTab {NS}>
    <description>My open tasks, grouped by when they are due, each named for who and what it is about.</description>
    <label>Tasks</label>
    <lwcComponent>antsuranceTasks</lwcComponent>
    <motif>Custom18: Form</motif>
</CustomTab>''')
TASKS_TAB = 'Antsurance_Tasks' if OWN_TASKS else 'standard-Task'
# Pages of our own that are tabs (Claude at Work, Event Response): in the navigation once their tab file exists.
OWN_PAGES = [name for name in OWN_TABS if exists('tabs', name + '.tab-meta.xml')]
OWN_PAGE_TABS = ''.join(f'    <tabs>{name}</tabs>\n' for name in OWN_PAGES)
write('applications/Antsurance.app-meta.xml', f'''<CustomApplication {NS}>
{"".join(override(page, sobject) for page, sobject in APP_PAGES)}    <brand>
        <headerColor>#C15F3C</headerColor>
        <logo>Claude_Spark</logo>
        <logoVersion>1</logoVersion>
        <shouldOverrideOrgTheme>false</shouldOverrideOrgTheme>
    </brand>
    <description>Antsurance's CRM: customers, policies, claims, service requests, quotes and sales.</description>
    <formFactors>Small</formFactors>
    <formFactors>Large</formFactors>
    <isNavAutoTempTabsDisabled>false</isNavAutoTempTabsDisabled>
    <isNavPersonalizationDisabled>false</isNavPersonalizationDisabled>
    <isNavTabPersistenceDisabled>false</isNavTabPersistenceDisabled>
    <isOmniPinnedViewEnabled>false</isOmniPinnedViewEnabled>
    <label>Antsurance</label>
    <navType>Standard</navType>
{home_override()}{override('Agency_Record_Page', 'Account', 'Agency')}{override('Business_Record_Page', 'Account', 'Business')}{override('Household_Record_Page', 'Account', 'Household')}{override('Claim_Record_Page', 'Case', 'Claim')}{override('Policy_Service_Record_Page', 'Case', 'Policy_Service')}    <tabs>{HOME_TAB}</tabs>
    <tabs>Antsurance_Claude</tabs>
    <tabs>standard-Account</tabs>
    <tabs>standard-Contact</tabs>
    <tabs>Policy__c</tabs>
    <tabs>standard-Case</tabs>
    <tabs>standard-Opportunity</tabs>
    <tabs>standard-Quote</tabs>
    <tabs>standard-Lead</tabs>
    <tabs>{TASKS_TAB}</tabs>
{OWN_PAGE_TABS}    <tabs>standard-report</tabs>
    <tabs>standard-Dashboard</tabs>
    <uiType>Lightning</uiType>
    <utilityBar>Antsurance_UtilityBar</utilityBar>
</CustomApplication>''')

# =============================================================== profile: layouts and tabs
p = os.path.join(ROOT, 'profiles/Admin.profile-meta.xml'); t = open(p).read()
t = re.sub(r'    <layoutAssignments>.*?</layoutAssignments>\n', '', t, flags=re.S)
def assign(layout_name, record_type=None):
    return '    <layoutAssignments>\n        <layout>' + layout_name + '</layout>\n' + (f'        <recordType>{record_type}</recordType>\n' if record_type else '') + '    </layoutAssignments>\n'
assignments = ''.join([
    assign('Account-Household Layout'), assign('Account-Agency Layout', 'Account.Agency'), assign('Account-Business Layout', 'Account.Business'), assign('Account-Household Layout', 'Account.Household'),
    assign('Case-Policy Service Layout'), assign('Case-Claim Layout', 'Case.Claim'), assign('Case-Policy Service Layout', 'Case.Policy_Service'),
    assign('Contact-Antsurance Contact Layout'), assign('File_Note__c-File Note Layout'), assign('Lead-Antsurance Lead Layout'),
    assign('Opportunity-Policy Sale Layout'), assign('Opportunity-Policy Sale Layout', 'Opportunity.Policy_Sale'),
    assign('Policy_Asset__c-Insured Asset Layout'), assign('Policy_Coverage__c-Policy Coverage Layout'), assign('Policy_Endorsement__c-Policy Endorsement Layout'),
    assign('Policy_Participant__c-Policy Participant Layout'), assign('Policy__c-Policy Layout'), assign('Quote-Antsurance Quote Layout')])
t = t.replace('    <recordTypeVisibilities>', assignments + '    <recordTypeVisibilities>', 1)
# Quotes and Tasks are on the navigation bar; the child objects have tabs only so they get their own icons.
t = re.sub(r'    <tabVisibilities>.*?</tabVisibilities>\n', '', t, flags=re.S)
TABS = [('Antsurance_Claude', 'DefaultOn'), ('Antsurance_Home', 'DefaultOn')] + ([('Antsurance_Tasks', 'DefaultOn')] if OWN_TASKS else []) + [(name, 'DefaultOn') for name in OWN_PAGES] + [('File_Note__c', 'DefaultOff'), ('Policy_Asset__c', 'DefaultOff'), ('Policy_Coverage__c', 'DefaultOff'), ('Policy_Endorsement__c', 'DefaultOff'),
        ('Policy_Participant__c', 'DefaultOff'), ('Policy__c', 'DefaultOn'), ('standard-Quote', 'DefaultOn'), ('standard-Task', 'DefaultOn')]
tab_xml = ''.join(f'    <tabVisibilities>\n        <tab>{tab}</tab>\n        <visibility>{visibility}</visibility>\n    </tabVisibilities>\n' for tab, visibility in TABS)
t = t.replace('    <userLicense>', tab_xml + '    <userLicense>', 1)
open(p, 'w').write(t)
print('pages generated')
