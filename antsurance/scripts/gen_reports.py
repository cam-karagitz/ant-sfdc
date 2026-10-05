#!/usr/bin/env python3
"""Writes the Antsurance report types, report folders, reports, dashboard folders and dashboards.

    python3 scripts/gen_reports.py force-app/main/default

Everything it writes lives under reportTypes/, reports/ and dashboards/. Edit the definitions
below and rerun; do not hand-edit the generated XML.
"""
import os
import sys
import zlib
from xml.sax.saxutils import escape as esc

ROOT = sys.argv[1]
# An org allows only a few dashboards that run as whoever is viewing them (three in a new Developer Edition
# org), so the three book-wide dashboards run as one named user who can see everything, and the three working
# queues (claims, service, the sales pipeline) run as the viewer. Pass another username as the second argument.
RUNNING_USER = sys.argv[2] if len(sys.argv) > 2 else 'ck+antsurance.e1c24d7ee816@agentforce.com'
NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"'
HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'


def write(path, body):
    full = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as handle:
        handle.write(HEAD + body.rstrip('\n') + '\n')


# ====================================================================== report types
FIELD_NAMES = {
    'Account__c.Customer_Segment__c': 'Customer Segment', 'Account.Customer_Segment__c': 'Customer Segment', 'Account__c': 'Customer',
    'Policy__c.Line_of_Business__c': 'Line of Business', 'Policy__c.Agency__c': 'Agency', 'Opportunity.Line_of_Business__c': 'Line of Business',
    'Opportunity.StageName': 'Sale Stage', 'Opportunity.Type': 'Sale Type', 'Account__c.BillingCity': 'Customer City', 'Account__c.BillingState': 'Customer State',
    'Account__c.Customer_Since__c': 'Customer Since', 'Account': 'Customer', 'Opportunity': 'Policy Sale'
}
def report_type(name, label, description, base, category, sections, joins=()):
    """sections: [(heading, table, [field or (field, checked)])]. joins: child relationship names, nested in order."""
    join_xml = ''
    for depth, relationship in reversed(list(enumerate(joins))):
        pad = '    ' * (depth + 1)
        join_xml = f'{pad}<join>\n{join_xml}{pad}    <outerJoin>false</outerJoin>\n{pad}    <relationship>{relationship}</relationship>\n{pad}</join>\n'
    section_xml = ''
    for heading, table, fields in sections:
        columns = ''
        for field in fields:
            field_name, checked = (field[0], field[1]) if isinstance(field, tuple) else (field, False)
            # A field reached through a lookup is labelled "Parent: Field" unless it is given a shorter name here.
            display = FIELD_NAMES.get(field_name)
            columns += ('        <columns>\n'
                        f'            <checkedByDefault>{str(checked).lower()}</checkedByDefault>\n'
                        + (f'            <displayNameOverride>{esc(display)}</displayNameOverride>\n' if display else '') +
                        f'            <field>{field_name}</field>\n'
                        f'            <table>{table}</table>\n'
                        '        </columns>\n')
        section_xml += f'    <sections>\n{columns}        <masterLabel>{esc(heading)}</masterLabel>\n    </sections>\n'
    write(f'reportTypes/{name}.reportType-meta.xml',
          f'<ReportType {NS}>\n    <baseObject>{base}</baseObject>\n    <category>{category}</category>\n    <deployed>true</deployed>\n'
          f'    <description>{esc(description)}</description>\n{join_xml}    <label>{esc(label)}</label>\n{section_xml}</ReportType>')


POLICY_FIELDS = [('Name', True), ('Account__c', True), ('Line_of_Business__c', True), ('Status__c', True), ('Annual_Premium__c', True),
                 'Coverage_Limit__c', 'Deductible__c', ('Effective_Date__c', True), ('Expiration_Date__c', True), 'Days_to_Renewal__c',
                 'Payment_Status__c', 'Billing_Frequency__c', 'Producer__c', 'Agency__c', 'Sold_Through__c', 'Primary_Insured__c', 'Insured_Item__c',
                 'Account__c.Customer_Segment__c', 'Account__c.BillingCity', 'Account__c.BillingState', 'Account__c.Customer_Since__c', 'CreatedDate',
                 'Incurred_Losses__c', 'Loss_Ratio__c']
# A shorter set for the report types that add a child object.
POLICY_CORE = [('Name', True), ('Account__c', True), ('Line_of_Business__c', True), ('Status__c', True), 'Annual_Premium__c',
               'Effective_Date__c', 'Expiration_Date__c', 'Agency__c', 'Sold_Through__c', 'Account__c.Customer_Segment__c']

report_type('Ants_Policies', 'Policies', 'Every policy with its customer, line, status, premium, term, billing and producing agency. The base for book of business, renewal and retention reporting.',
            'Policy__c', 'other', [('Policy', 'Policy__c', POLICY_FIELDS)])
report_type('Ants_Policy_Coverages', 'Policies with Coverages', 'Each coverage on a policy with its limit, deductible and share of premium. Use for coverage mix.',
            'Policy__c', 'other',
            [('Policy', 'Policy__c', POLICY_CORE),
             ('Coverage', 'Policy__c.Coverages__r', [('Name', True), ('Category__c', True), ('Limit_Amount__c', True), 'Limit_Type__c', ('Deductible_Amount__c', True),
                                                     ('Premium_Amount__c', True), 'Premium_Share__c', 'Status__c', 'Effective_Date__c'])],
            joins=['Coverages__r'])
report_type('Ants_Policy_Participants', 'Policies with Participants', 'The people on each policy: named insureds, drivers and their driving records. Use for driver risk reporting.',
            'Policy__c', 'other',
            [('Policy', 'Policy__c', POLICY_CORE),
             ('Participant', 'Policy__c.Participants__r', [('Name', True), ('Role__c', True), 'Status__c', 'Relationship_to_Insured__c', ('Driver_Rating__c', True),
                                                           'Violations_Past_3_Years__c', 'Accidents_Past_3_Years__c', 'Years_Licensed__c', 'License_State__c',
                                                           'Good_Student_Discount__c', 'Is_Primary__c', 'Primary_Vehicle__c', 'Contact__c', 'Effective_Date__c'])],
            joins=['Participants__r'])
report_type('Ants_Policy_Assets', 'Policies with Insured Assets', 'What each policy insures: vehicles, homes, buildings and fleets with their insured values. Use for exposure reporting.',
            'Policy__c', 'other',
            [('Policy', 'Policy__c', POLICY_CORE),
             ('Insured asset', 'Policy__c.Assets__r', [('Name', True), ('Asset_Type__c', True), ('Insured_Value__c', True), 'Identifier__c', 'Model_Year__c',
                                                      'Location__c', 'Use__c', 'Lienholder__c'])],
            joins=['Assets__r'])
report_type('Ants_Policy_Endorsements', 'Policies with Endorsements', 'The forms, discounts and lienholder clauses attached to each policy and what each does to the premium.',
            'Policy__c', 'other',
            [('Policy', 'Policy__c', POLICY_CORE),
             ('Endorsement', 'Policy__c.Endorsements__r', [('Name', True), ('Type__c', True), 'Form_Number__c', 'Status__c', ('Premium_Change__c', True),
                                                           'Limit_Amount__c', 'Effective_Date__c'])],
            joins=['Endorsements__r'])
report_type('Ants_Cases', 'Claims and Service Requests', 'Every claim and service request with its policy, line of business, loss details, reserve and payments. The base for claims and service reporting.',
            'Case', 'cases',
            [('Case', 'Case', [('CaseNumber', True), ('Subject', True), ('Status', True), 'Priority', 'Origin', 'IsClosed', 'CreatedDate', 'ClosedDate',
                               'Owner', ('Account', True), 'Contact', 'RecordType', 'Account.Customer_Segment__c', 'Handled_By__c', 'Days_Open__c']),
             ('Claim', 'Case', [('Severity__c', True), 'Loss_Type__c', 'Date_of_Loss__c', ('Reported_Date__c', True), 'Loss_Location__c', 'Estimated_Loss__c',
                                ('Reserve_Amount__c', True), ('Paid_Amount__c', True), 'Outstanding_Reserve__c', 'Coverage_Check__c', 'SIU_Referral__c',
                                'Subrogation_Potential__c']),
             ('Service request', 'Case', ['Request_Type__c']),
             ('Policy', 'Case', [('Policy__c', True), 'Policy__c.Line_of_Business__c', 'Policy__c.Status__c', 'Policy__c.Annual_Premium__c', 'Policy__c.Agency__c'])])
report_type('Ants_Accounts', 'Customers and Agencies', 'Households, businesses and agencies with policies in force, premium in force and how long they have been customers.',
            'Account', 'accounts',
            [('Account', 'Account', [('Name', True), 'RecordType', ('Customer_Segment__c', True), 'Customer_Since__c', ('Active_Policies__c', True),
                                     ('Premium_in_Force__c', True), 'BillingCity', 'BillingState', 'Industry', 'NumberOfEmployees', 'Owner', 'CreatedDate'])])
report_type('Ants_Quotes', 'Quotes on Policy Sales', 'Every quote with its premium, terms, status, age and the policy sale it belongs to. Use for quote follow-up and underwriter workload.',
            'Quote', 'quotes',
            [('Quote', 'Quote', [('Name', True), ('QuoteNumber', True), ('Status', True), ('Annual_Premium__c', True), 'Coverage_Limit__c', 'Deductible__c',
                                 ('Issued_Date__c', True), 'Days_Since_Issued__c', 'ExpirationDate', 'Underwriter__c', 'CreatedDate']),
             ('Policy sale', 'Quote', [('Opportunity', True), 'Opportunity.Line_of_Business__c', 'Opportunity.StageName', 'Opportunity.Type', 'Opportunity.CloseDate'])])
report_type('Ants_Leads', 'Leads', 'Prospects with the product they asked about, where they came from and how far they have got.',
            'Lead', 'leads',
            [('Lead', 'Lead', [('FirstName', True), ('LastName', True), ('Company', True), ('Status', True), ('LeadSource', True), ('Product_Interest__c', True),
                               'Rating', 'City', 'State', 'IsConverted', 'Owner', 'CreatedDate'])])
report_type('Ants_File_Notes', 'File Notes', 'Notes written on claims, policies and customers, by type and author. Use for adjuster activity.',
            'File_Note__c', 'other',
            [('File note', 'File_Note__c', [('Name', True), ('Note_Type__c', True), ('Note_Date__c', True), ('Author_Name__c', True), 'Case__c', 'Policy__c',
                                            'Account__c', 'Case__c.Status', 'Case__c.Severity__c', 'CreatedDate'])])


# ====================================================================== report folders
def folder(kind, name, label):
    tag = 'ReportFolder' if kind == 'reports' else 'DashboardFolder'
    suffix = 'reportFolder' if kind == 'reports' else 'dashboardFolder'
    write(f'{kind}/{name}.{suffix}-meta.xml',
          f'<{tag} {NS}>\n    <folderShares>\n        <accessLevel>Manage</accessLevel>\n        <sharedTo>AllInternalUsers</sharedTo>\n'
          f'        <sharedToType>Group</sharedToType>\n    </folderShares>\n    <name>{esc(label)}</name>\n</{tag}>')


EXEC, BOOK, CLAIMS, SALES, RENEW, SERVICE = 'Ants_Executive', 'Ants_Book', 'Ants_Claims', 'Ants_Sales', 'Ants_Renewals', 'Ants_Service'
for dev, label in [(EXEC, 'Executive'), (BOOK, 'Book of Business and Underwriting'), (CLAIMS, 'Claims'), (SALES, 'Sales and Quotes'),
                   (RENEW, 'Renewals and Retention'), (SERVICE, 'Service and Operations')]:
    folder('reports', dev, label)


# ====================================================================== reports
def bucket(label, source, ranges, kind='number'):
    """ranges: [(from or None, to or None, label)]. Returns (developer name, xml)."""
    dev = 'BucketField_' + str(zlib.crc32((label + source).encode()) % 100000000)
    values = ''
    for low, high, name in ranges:
        values += '        <values>\n            <sourceValues>\n'
        if low is not None:
            values += f'                <from>{low}</from>\n'
        if high is not None:
            values += f'                <to>{high}</to>\n'
        values += f'            </sourceValues>\n            <value>{esc(name)}</value>\n        </values>\n'
    xml = (f'    <buckets>\n        <bucketType>{kind}</bucketType>\n        <developerName>{dev}</developerName>\n        <masterLabel>{esc(label)}</masterLabel>\n'
           f'        <nullTreatment>n</nullTreatment>\n        <sourceColumnName>{source}</sourceColumnName>\n        <useOther>false</useOther>\n{values}    </buckets>\n')
    return dev, xml


def formula(dev, label, expression, datatype='percent', scale=0):
    return (f'    <aggregates>\n        <calculatedFormula>{esc(expression)}</calculatedFormula>\n        <datatype>{datatype}</datatype>\n'
            f'        <developerName>{dev}</developerName>\n        <isActive>true</isActive>\n        <isCrossBlock>false</isCrossBlock>\n'
            f'        <masterLabel>{esc(label)}</masterLabel>\n        <scale>{scale}</scale>\n    </aggregates>\n')


REPORTS = []   # (folder, developer name, label), in the order written
# A report with no time window of its own covers all time, which the metadata spells as a custom range on a date column.
ALL_TIME_COLUMN = {
    'Ants_Policies__c': 'Policy__c$CreatedDate', 'Ants_Policy_Coverages__c': 'Policy__c$Effective_Date__c', 'Ants_Policy_Participants__c': 'Policy__c$Effective_Date__c',
    'Ants_Policy_Assets__c': 'Policy__c$Effective_Date__c', 'Ants_Policy_Endorsements__c': 'Policy__c$Effective_Date__c', 'Ants_Cases__c': 'Case$CreatedDate',
    'Ants_Accounts__c': 'Account$CreatedDate', 'Ants_Quotes__c': 'Quote$CreatedDate', 'Ants_Leads__c': 'Lead$CreatedDate', 'Ants_File_Notes__c': 'File_Note__c$CreatedDate'
}


def report(folder_name, dev, label, description, report_type_name, columns, group=(), across=(), filters=(), logic=None, chart=None,
           time=None, buckets=(), formulas=(), details=False, fmt=None, params=(), scope='organization', sort=None, limit=None):
    """columns: field or (field, 'Sum' | ['Sum', 'Average']). group/across: field or (field, granularity) or
    (field, granularity, sort column, aggregate). filters: (column, operator, value). chart: (type, grouping, [(aggregate, column)], title[, second grouping])."""
    assert len(label) <= 40, label
    # The Reports list shows the description in a column about 35 characters wide and hyphenates a word
    # mid-way when a longer one wraps ("commer-" / "cial"). One line cannot break.
    assert len(description) <= 34, (label, len(description))
    fmt = fmt or ('Matrix' if across else 'Summary' if group else 'Tabular')
    details = details or fmt == 'Tabular'   # a plain list is nothing but its detail rows
    xml = f'<Report {NS}>\n'
    xml += ''.join(formulas)
    xml += ''.join(b[1] for b in buckets)
    if chart:
        chart_type, grouping, summaries, title = chart[:4]
        second = chart[4] if len(chart) > 4 else None
        xml += '    <chart>\n        <backgroundColor1>#FFFFFF</backgroundColor1>\n        <backgroundColor2>#FFFFFF</backgroundColor2>\n        <backgroundFadeDir>Diagonal</backgroundFadeDir>\n'
        for aggregate, column in summaries:
            xml += '        <chartSummaries>\n' + (f'            <aggregate>{aggregate}</aggregate>\n' if aggregate else '') + f'            <axisBinding>y</axisBinding>\n            <column>{column}</column>\n        </chartSummaries>\n'
        xml += (f'        <chartType>{chart_type}</chartType>\n        <enableHoverLabels>true</enableHoverLabels>\n        <expandOthers>true</expandOthers>\n'
                f'        <groupingColumn>{grouping}</groupingColumn>\n')
        if second or chart_type in ('Donut', 'Pie', 'Funnel'):
            xml += '        <legendPosition>Right</legendPosition>\n'
        xml += '        <location>CHART_TOP</location>\n'
        if second:
            xml += f'        <secondaryGroupingColumn>{second}</secondaryGroupingColumn>\n'
        # Stacked charts do not take value labels.
        show_values = '' if second else '        <showValues>true</showValues>\n'
        xml += ('        <showAxisLabels>true</showAxisLabels>\n        <showPercentage>false</showPercentage>\n        <showTotal>false</showTotal>\n' + show_values +
                '        <size>Medium</size>\n        <summaryAxisRange>Auto</summaryAxisRange>\n        <textColor>#000000</textColor>\n        <textSize>12</textSize>\n'
                f'        <title>{esc(title)}</title>\n        <titleColor>#000000</titleColor>\n        <titleSize>18</titleSize>\n    </chart>\n')
    # A field that is grouped on cannot also be a column, and a summary formula shows without being listed.
    grouped = {g[0] if isinstance(g, tuple) else g for g in list(group) + list(across)}
    for column in columns:
        field, aggregates = column if isinstance(column, tuple) else (column, [])
        if field in grouped or field.startswith('FORMULA'):
            continue
        aggregates = [aggregates] if isinstance(aggregates, str) else aggregates
        xml += '    <columns>\n' + ''.join(f'        <aggregateTypes>{a}</aggregateTypes>\n' for a in aggregates) + f'        <field>{field}</field>\n    </columns>\n'
    xml += f'    <description>{esc(description)}</description>\n'
    if filters:
        xml += '    <filter>\n' + (f'        <booleanFilter>{logic}</booleanFilter>\n' if logic else '')
        for column, operator, value in filters:
            xml += (f'        <criteriaItems>\n            <column>{column}</column>\n            <columnToColumn>false</columnToColumn>\n            <isUnlocked>true</isUnlocked>\n'
                    f'            <operator>{operator}</operator>\n            <value>{esc(str(value))}</value>\n        </criteriaItems>\n')
        xml += '    </filter>\n'
    xml += f'    <format>{fmt}</format>\n'

    def grouping(tag, spec):
        spec = spec if isinstance(spec, tuple) else (spec,)
        field = spec[0]
        granularity = spec[1] if len(spec) > 1 and spec[1] else 'Day'
        out = f'    <{tag}>\n'
        if len(spec) > 3:
            out += f'        <aggregateType>{spec[3]}</aggregateType>\n'
        out += f'        <dateGranularity>{granularity}</dateGranularity>\n        <field>{field}</field>\n'
        if len(spec) > 2 and spec[2]:
            out += f'        <sortByName>{spec[2]}</sortByName>\n        <sortOrder>Desc</sortOrder>\n        <sortType>Aggregate</sortType>\n'
        else:
            out += '        <sortOrder>Asc</sortOrder>\n'
        return out + f'    </{tag}>\n'

    xml += ''.join(grouping('groupingsAcross', g) for g in across)
    xml += ''.join(grouping('groupingsDown', g) for g in group)
    xml += f'    <name>{esc(label)}</name>\n'
    for name, value in params:
        xml += f'    <params>\n        <name>{name}</name>\n        <value>{esc(value)}</value>\n    </params>\n'
    xml += f'    <reportType>{report_type_name}</reportType>\n'
    if limit:
        xml += f'    <rowLimit>{limit}</rowLimit>\n'
    xml += f'    <scope>{scope}</scope>\n    <showDetails>{str(details).lower()}</showDetails>\n    <showGrandTotal>true</showGrandTotal>\n    <showSubTotals>true</showSubTotals>\n'
    if sort:
        xml += f'    <sortColumn>{sort[0]}</sortColumn>\n    <sortOrder>{sort[1]}</sortOrder>\n'
    date_column, interval = time or (ALL_TIME_COLUMN.get(report_type_name), 'INTERVAL_CUSTOM')
    if date_column:
        xml += f'    <timeFrameFilter>\n        <dateColumn>{date_column}</dateColumn>\n        <interval>{interval}</interval>\n    </timeFrameFilter>\n'
    xml += '</Report>'
    write(f'reports/{folder_name}/{dev}.report-meta.xml', xml)
    REPORTS.append((folder_name, dev, label))


# ---- column names
P = 'Policy__c$'
P_NAME, P_ACCOUNT, P_LINE, P_STATUS, P_PREMIUM = P + 'Name', P + 'Account__c', P + 'Line_of_Business__c', P + 'Status__c', P + 'Annual_Premium__c'
P_LIMIT, P_DEDUCTIBLE, P_EFFECTIVE, P_EXPIRES, P_DAYS = P + 'Coverage_Limit__c', P + 'Deductible__c', P + 'Effective_Date__c', P + 'Expiration_Date__c', P + 'Days_to_Renewal__c'
P_PAYMENT, P_BILLING, P_AGENCY, P_SEGMENT, P_ITEM = P + 'Payment_Status__c', P + 'Billing_Frequency__c', P + 'Sold_Through__c', P + 'Account__c.Customer_Segment__c', P + 'Insured_Item__c'
P_CREATED = P + 'CreatedDate'
COV, PART, ASSET, ENDO = 'Policy__c.Coverages__r$', 'Policy__c.Participants__r$', 'Policy__c.Assets__r$', 'Policy__c.Endorsements__r$'
C = 'Case$'
C_NUMBER, C_SUBJECT, C_STATUS, C_PRIORITY, C_ORIGIN, C_CLOSED, C_OWNER, C_ACCOUNT, C_TYPE = (C + 'CaseNumber', C + 'Subject', C + 'Status', C + 'Priority',
                                                                                         C + 'Origin', C + 'IsClosed', C + 'Owner', C + 'Account', C + 'RecordType')
C_SEVERITY, C_LOSS, C_LOSS_DATE, C_REPORTED, C_ESTIMATE = C + 'Severity__c', C + 'Loss_Type__c', C + 'Date_of_Loss__c', C + 'Reported_Date__c', C + 'Estimated_Loss__c'
C_RESERVE, C_PAID, C_OUTSTANDING, C_COVERAGE, C_SIU, C_SUBRO = (C + 'Reserve_Amount__c', C + 'Paid_Amount__c', C + 'Outstanding_Reserve__c', C + 'Coverage_Check__c',
                                                               C + 'SIU_Referral__c', C + 'Subrogation_Potential__c')
C_REQUEST, C_POLICY, C_LINE, C_CREATED = C + 'Request_Type__c', C + 'Policy__c', C + 'Policy__c.Line_of_Business__c', C + 'CreatedDate'
A = 'Account$'
Q = 'Quote$'
L = 'Lead$'
N = 'File_Note__c$'

P_INCURRED, C_HANDLER, C_DAYS = P + 'Incurred_Losses__c', C + 'Handled_By__c', C + 'Days_Open__c'

IN_FORCE = (P_STATUS, 'equals', 'Active,Pending Renewal')
CLAIM = (C_TYPE, 'equals', 'Case.Claim')
REQUEST = (C_TYPE, 'equals', 'Case.Policy_Service')
OPEN_CASE = (C_CLOSED, 'equals', '0')
POLICY_LIST = [P_NAME, P_ACCOUNT, P_STATUS, (P_PREMIUM, 'Sum'), P_EFFECTIVE, P_EXPIRES]
CLAIM_LIST = [C_NUMBER, C_SUBJECT, C_ACCOUNT, C_POLICY, C_STATUS, C_REPORTED, (C_RESERVE, 'Sum'), (C_PAID, 'Sum'), (C_OUTSTANDING, 'Sum')]

# ---------------------------------------------------------------- Executive
report(EXEC, 'Premium_in_Force_by_Line', 'Book by Line', 'Premium in force, by line.',
       'Ants_Policies__c', POLICY_LIST, group=[(P_LINE, None, P_PREMIUM, 'Sum')], filters=[IN_FORCE],
       chart=('HorizontalBar', P_LINE, [('Sum', P_PREMIUM)], 'Premium in force by line'))
report(EXEC, 'Premium_in_Force_by_Segment', 'Premium by Segment', 'Personal against commercial.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE], group=[(P_SEGMENT, None, P_PREMIUM, 'Sum')], filters=[IN_FORCE],
       chart=('HorizontalBar', P_SEGMENT, [('Sum', P_PREMIUM)], 'Premium in force by segment'))
report(EXEC, 'Policies_by_Status', 'Policies by Status', 'Every policy, by status.',
       'Ants_Policies__c', [P_NAME, P_ACCOUNT, P_LINE, (P_PREMIUM, 'Sum'), P_EXPIRES], group=[P_STATUS],
       chart=('HorizontalBar', P_STATUS, [(None, 'RowCount')], 'Policies by status'))
report(EXEC, 'Top_Customers_by_Premium', 'Top Customers by Premium', 'Customers ranked by premium.',
       'Ants_Policies__c', [P_NAME, P_LINE, P_STATUS, (P_PREMIUM, 'Sum'), P_EXPIRES], group=[(P_ACCOUNT, None, P_PREMIUM, 'Sum')], filters=[IN_FORCE],
       chart=('HorizontalBar', P_ACCOUNT, [('Sum', P_PREMIUM)], 'Top customers by premium'))
report(EXEC, 'Written_Premium_by_Month', 'Written Premium by Month', 'By the month each policy began.',
       'Ants_Policies__c', [P_NAME, P_ACCOUNT, P_LINE, P_STATUS, (P_PREMIUM, 'Sum')], group=[(P_EFFECTIVE, 'Month')], filters=[IN_FORCE],
       chart=('VerticalColumn', P_EFFECTIVE, [('Sum', P_PREMIUM)], 'Written premium by effective month'))
report(EXEC, 'Incurred_Losses_by_Line', 'Incurred Losses by Line', 'Reserves and payments, by line.',
       'Ants_Cases__c', CLAIM_LIST + [(C_ESTIMATE, 'Sum')], group=[(C_LINE, None, C_RESERVE, 'Sum')], filters=[CLAIM],
       chart=('HorizontalBar', C_LINE, [('Sum', C_RESERVE), ('Sum', C_PAID)], 'Reserved and paid by line'))
report(EXEC, 'Loss_Ratio_by_Line', 'Loss Ratio by Line', 'Losses over premium, by line.',
       'Ants_Policies__c', [P_NAME, P_ACCOUNT, P_STATUS, (P_PREMIUM, 'Sum'), (P_INCURRED, 'Sum'), 'FORMULA1'], group=[P_LINE], filters=[IN_FORCE],
       formulas=[formula('FORMULA1', 'Loss Ratio', 'Policy__c.Incurred_Losses__c:SUM / Policy__c.Annual_Premium__c:SUM')],
       chart=('HorizontalBar', P_LINE, [(None, 'FORMULA1')], 'Loss ratio by line'))
report(EXEC, 'Open_Claims_Exposure', 'Open Reserve', 'Open reserve, by severity.',
       'Ants_Cases__c', CLAIM_LIST, group=[C_SEVERITY], filters=[CLAIM, OPEN_CASE],
       chart=('HorizontalBar', C_SEVERITY, [('Sum', C_OUTSTANDING)], 'Outstanding reserve by severity'))

# ---------------------------------------------------------------- Book of business and underwriting
report(BOOK, 'Policy_Register', 'Policy Register', 'Policies in force, largest first.',
       'Ants_Policies__c', [P_NAME, P_ACCOUNT, P_LINE, P_STATUS, P_PREMIUM, P_LIMIT, P_DEDUCTIBLE, P_EFFECTIVE, P_EXPIRES, P_AGENCY], filters=[IN_FORCE],
       sort=(P_PREMIUM, 'Desc'))
report(BOOK, 'Premium_by_Agency', 'Premium by Agency', 'Premium in force, by agency.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE], group=[(P_AGENCY, None, P_PREMIUM, 'Sum')], filters=[IN_FORCE],
       chart=('HorizontalBar', P_AGENCY, [('Sum', P_PREMIUM)], 'Premium in force by agency'))
report(BOOK, 'Premium_by_Line_and_Status', 'Premium by Status', 'Premium by status, across lines.',
       'Ants_Policies__c', [(P_PREMIUM, 'Sum')], group=[P_STATUS], across=[P_LINE],
       chart=('HorizontalBar', P_STATUS, [('Sum', P_PREMIUM)], 'Premium by status'))
report(BOOK, 'Policy_Terms_by_Line', 'Average Premium', 'Average terms, by line.',
       'Ants_Policies__c', [P_NAME, P_ACCOUNT, (P_PREMIUM, ['Sum', 'Average']), (P_LIMIT, 'Average'), (P_DEDUCTIBLE, 'Average')], group=[P_LINE], filters=[IN_FORCE],
       chart=('HorizontalBar', P_LINE, [('Average', P_PREMIUM)], 'Average premium by line'))
report(BOOK, 'Billing_Plans', 'Billing Plans', 'Policies by billing plan.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE, P_PAYMENT], group=[P_BILLING], filters=[IN_FORCE],
       chart=('HorizontalBar', P_BILLING, [(None, 'RowCount')], 'Policies by billing plan'))
report(BOOK, 'Coverage_Mix_by_Category', 'Coverage Mix by Category', 'Premium by coverage category.',
       'Ants_Policy_Coverages__c', [P_NAME, P_LINE, COV + 'Name', (COV + 'Limit_Amount__c', 'Average'), (COV + 'Deductible_Amount__c', 'Average'), (COV + 'Premium_Amount__c', 'Sum')],
       group=[(COV + 'Category__c', None, COV + 'Premium_Amount__c', 'Sum')], filters=[IN_FORCE, (COV + 'Status__c', 'equals', 'Active')],
       chart=('HorizontalBar', COV + 'Category__c', [('Sum', COV + 'Premium_Amount__c')], 'Premium by coverage category'))
report(BOOK, 'Coverages_by_Line', 'Coverages by Line of Business', 'Coverages each line carries.',
       'Ants_Policy_Coverages__c', [(COV + 'Premium_Amount__c', 'Sum')], group=[P_LINE], across=[COV + 'Category__c'], filters=[IN_FORCE])
report(BOOK, 'Insured_Assets_by_Type', 'Insured Value', 'Insured value, by asset type.',
       'Ants_Policy_Assets__c', [P_NAME, P_ACCOUNT, ASSET + 'Name', (ASSET + 'Insured_Value__c', 'Sum'), ASSET + 'Location__c'],
       group=[(ASSET + 'Asset_Type__c', None, ASSET + 'Insured_Value__c', 'Sum')], filters=[IN_FORCE, (ASSET + 'Insured_Value__c', 'greaterThan', '0')],
       chart=('HorizontalBar', ASSET + 'Asset_Type__c', [('Sum', ASSET + 'Insured_Value__c')], 'Insured value by asset type'))
report(BOOK, 'Drivers_by_Rating', 'Drivers by Rating Tier', 'Active drivers, by rating tier.',
       'Ants_Policy_Participants__c', [P_NAME, P_ACCOUNT, PART + 'Name', (PART + 'Violations_Past_3_Years__c', 'Sum'), (PART + 'Accidents_Past_3_Years__c', 'Sum'), PART + 'Years_Licensed__c'],
       group=[PART + 'Driver_Rating__c'], filters=[(PART + 'Role__c', 'equals', 'Driver'), (PART + 'Status__c', 'equals', 'Active')],
       chart=('HorizontalBar', PART + 'Driver_Rating__c', [(None, 'RowCount')], 'Drivers by rating tier'))
report(BOOK, 'Drivers_with_Incidents', 'Drivers with Violations or Accidents', 'Violations or accidents, 3 years.',
       'Ants_Policy_Participants__c', [PART + 'Name', P_NAME, P_ACCOUNT, PART + 'Driver_Rating__c', PART + 'Violations_Past_3_Years__c', PART + 'Accidents_Past_3_Years__c',
                                       PART + 'Years_Licensed__c', P_EXPIRES],
       filters=[(PART + 'Role__c', 'equals', 'Driver'), (PART + 'Violations_Past_3_Years__c', 'greaterThan', '0'), (PART + 'Accidents_Past_3_Years__c', 'greaterThan', '0')],
       logic='1 AND (2 OR 3)', sort=(PART + 'Violations_Past_3_Years__c', 'Desc'))
report(BOOK, 'Endorsements_by_Type', 'Endorsements by Type', 'Forms on policies in force.',
       'Ants_Policy_Endorsements__c', [P_NAME, P_LINE, ENDO + 'Name', ENDO + 'Form_Number__c', (ENDO + 'Premium_Change__c', 'Sum')],
       group=[ENDO + 'Type__c'], filters=[IN_FORCE, (ENDO + 'Status__c', 'equals', 'Active')],
       chart=('HorizontalBar', ENDO + 'Type__c', [(None, 'RowCount')], 'Endorsements by type'))
report(BOOK, 'Customers_by_Segment', 'Customer Segments', 'Households and businesses.',
       'Ants_Accounts__c', [A + 'Name', (A + 'Active_Policies__c', 'Sum'), (A + 'Premium_in_Force__c', 'Sum'), A + 'Customer_Since__c', A + 'BillingCity'],
       group=[A + 'Customer_Segment__c'], filters=[(A + 'Customer_Segment__c', 'notEqual', 'Agency Partner')],
       chart=('HorizontalBar', A + 'Customer_Segment__c', [(None, 'RowCount')], 'Customers by segment'))
_held = bucket('Policies Held', A + 'Active_Policies__c', [(None, 0, 'None in force'), (0, 1, 'One policy'), (1, 2, 'Two policies'), (2, None, 'Three or more')])
report(BOOK, 'Customers_by_Policies_Held', 'Customers by Policies Held', 'One policy is the cross-sell list.',
       'Ants_Accounts__c', [A + 'Name', A + 'Customer_Segment__c', (A + 'Active_Policies__c', 'Sum'), (A + 'Premium_in_Force__c', 'Sum')],
       group=[_held[0]], buckets=[_held], filters=[(A + 'Customer_Segment__c', 'notEqual', 'Agency Partner')],
       chart=('VerticalColumn', _held[0], [(None, 'RowCount')], 'Customers by policies held'))

# ---------------------------------------------------------------- Claims
report(CLAIMS, 'Open_Claims_by_Status', 'Open Claim Status', 'Open claims, by handling status.',
       'Ants_Cases__c', CLAIM_LIST + [C_SEVERITY], group=[C_STATUS], filters=[CLAIM, OPEN_CASE],
       chart=('HorizontalBar', C_STATUS, [(None, 'RowCount')], 'Open claims by status'))
report(CLAIMS, 'Open_Claims_by_Severity', 'Open Claims by Severity', 'Open claims, by severity.',
       'Ants_Cases__c', CLAIM_LIST, group=[C_SEVERITY], filters=[CLAIM, OPEN_CASE],
       chart=('HorizontalBar', C_SEVERITY, [(None, 'RowCount')], 'Open claims by severity'))
report(CLAIMS, 'Claims_by_Loss_Type', 'Claims by Loss Type', 'All claims, by cause of loss.',
       'Ants_Cases__c', CLAIM_LIST, group=[(C_LOSS, None, C_RESERVE, 'Sum')], filters=[CLAIM],
       chart=('HorizontalBar', C_LOSS, [('Sum', C_RESERVE)], 'Reserved by loss type'))
report(CLAIMS, 'Claims_by_Line_and_Severity', 'Claims by Line', 'Claims by line, across severity.',
       'Ants_Cases__c', [(C_RESERVE, 'Sum')], group=[C_LINE], across=[C_SEVERITY], filters=[CLAIM],
       chart=('HorizontalBar', C_LINE, [(None, 'RowCount')], 'Claims by line'))
report(CLAIMS, 'Reserves_and_Payments_by_Status', 'Reserves by Status', 'Reserved and paid, by status.',
       'Ants_Cases__c', CLAIM_LIST + ['FORMULA1'], group=[C_STATUS], filters=[CLAIM],
       formulas=[formula('FORMULA1', 'Paid Share of Reserve', 'Case.Paid_Amount__c:SUM / Case.Reserve_Amount__c:SUM')],
       chart=('HorizontalBar', C_STATUS, [('Sum', C_RESERVE), ('Sum', C_PAID)], 'Reserved and paid by status'))
report(CLAIMS, 'Claims_Reported_by_Month', 'Claims Reported by Month', 'Claims by month reported.',
       'Ants_Cases__c', [C_NUMBER, C_SUBJECT, C_ACCOUNT, C_SEVERITY, (C_ESTIMATE, 'Sum'), (C_RESERVE, 'Sum')], group=[(C_REPORTED, 'Month')], filters=[CLAIM],
       chart=('VerticalColumn', C_REPORTED, [(None, 'RowCount')], 'Claims reported by month'))
_claim_age = bucket('Claim Age', C_DAYS, [(None, 30, 'Up to 30 days'), (30, 60, '31 to 60 days'), (60, 90, '61 to 90 days'), (90, None, 'Over 90 days')])
report(CLAIMS, 'Open_Claims_by_Age', 'Open Claim Aging', 'Open claims in 30-day bands.',
       'Ants_Cases__c', CLAIM_LIST + [C_SEVERITY, C_DAYS], group=[_claim_age[0]], buckets=[_claim_age], filters=[CLAIM, OPEN_CASE], details=True,
       chart=('VerticalColumn', _claim_age[0], [(None, 'RowCount')], 'Open claim aging'))
report(CLAIMS, 'Open_Claims_by_Week_Reported', 'Open Claims by Week Reported', 'Open claims by week reported.',
       'Ants_Cases__c', CLAIM_LIST + [C_SEVERITY], group=[(C_REPORTED, 'Week')], filters=[CLAIM, OPEN_CASE],
       chart=('VerticalColumn', C_REPORTED, [(None, 'RowCount')], 'Open claims by week reported'))
report(CLAIMS, 'Large_Open_Claims', 'Large Open Claims', '$25,000 or more still to pay.',
       'Ants_Cases__c', [C_NUMBER, C_SUBJECT, C_ACCOUNT, C_POLICY, C_STATUS, C_REPORTED, (C_RESERVE, 'Sum'), (C_PAID, 'Sum'), (C_OUTSTANDING, 'Sum')],
       group=[C_SEVERITY], filters=[CLAIM, OPEN_CASE, (C_OUTSTANDING, 'greaterOrEqual', '25000')], details=True)
report(CLAIMS, 'Open_Claims_by_Owner', 'Open Claims by Adjuster', 'Open claims, by adjuster.',
       'Ants_Cases__c', CLAIM_LIST + [C_SEVERITY], group=[C_HANDLER], filters=[CLAIM, OPEN_CASE],
       chart=('HorizontalBar', C_HANDLER, [(None, 'RowCount')], 'Open claims by adjuster'))
report(CLAIMS, 'SIU_Referrals', 'SIU Referrals', 'Claims referred to SIU.',
       'Ants_Cases__c', CLAIM_LIST + [C_LOSS], group=[C_STATUS], filters=[CLAIM, (C_SIU, 'equals', '1')], details=True)
report(CLAIMS, 'Coverage_Check_Problems', 'Coverage Check Problems', 'Losses outside the policy term.',
       'Ants_Cases__c', CLAIM_LIST + [C_LOSS_DATE], group=[C_COVERAGE],
       filters=[CLAIM, (C_COVERAGE, 'equals', 'Outside policy term,Policy not in force')], details=True)
report(CLAIMS, 'Subrogation_Opportunities', 'Subrogation Opportunities', 'Another party may owe recovery.',
       'Ants_Cases__c', CLAIM_LIST + [C_LOSS], group=[C_STATUS], filters=[CLAIM, (C_SUBRO, 'equals', '1')], details=True)
report(CLAIMS, 'Closed_Claims_Paid_by_Line', 'Closed Claims Paid by Line', 'Paid on closed claims, by line.',
       'Ants_Cases__c', [C_NUMBER, C_SUBJECT, C_ACCOUNT, C_LOSS, (C_PAID, ['Sum', 'Average'])], group=[(C_LINE, None, C_PAID, 'Sum')], filters=[CLAIM, (C_CLOSED, 'equals', '1')],
       chart=('HorizontalBar', C_LINE, [('Sum', C_PAID)], 'Paid on closed claims by line'))
report(CLAIMS, 'Claims_by_Customer_Segment', 'Claims by Segment', 'Claims by customer segment.',
       'Ants_Cases__c', CLAIM_LIST + [C_SEVERITY], group=[C + 'Account.Customer_Segment__c'], filters=[CLAIM],
       chart=('HorizontalBar', C + 'Account.Customer_Segment__c', [('Sum', C_RESERVE)], 'Reserved by customer segment'))
report(CLAIMS, 'File_Notes_by_Author', 'File Notes by Author', 'Who is working their files.',
       'Ants_File_Notes__c', [N + 'Name', N + 'Note_Date__c'], group=[N + 'Author_Name__c'], across=[N + 'Note_Type__c'],
       chart=('HorizontalBar', N + 'Author_Name__c', [(None, 'RowCount')], 'File notes by author'))

# ---------------------------------------------------------------- Sales and quotes (standard opportunity report type)
OPP_LIST = ['OPPORTUNITY_NAME', 'ACCOUNT_NAME', 'TYPE', ('AMOUNT', 'Sum'), 'CLOSE_DATE']
OPP_LINE = 'Opportunity.Line_of_Business__c'
OPEN_SALES = [('open', 'open'), ('probability', '>0'), ('co', '1')]
ALL_SALES = [('open', 'all'), ('probability', '>0'), ('co', '1')]
CLOSED_SALES = [('open', 'closed'), ('probability', '>0'), ('co', '1')]
WON_SALES = [('open', 'closedwon'), ('probability', '>0'), ('co', '1')]
ANY_CLOSE = ('CLOSE_DATE', 'INTERVAL_CUSTOM')
report(SALES, 'Open_Pipeline_by_Stage', 'Pipeline by Stage', 'Open sales premium, by stage.',
       'Opportunity', OPP_LIST + [OPP_LINE], group=['STAGE_NAME'], params=OPEN_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', 'STAGE_NAME', [('Sum', 'AMOUNT')], 'Open pipeline by stage'))
report(SALES, 'Open_Pipeline_by_Line', 'Open Pipeline by Line', 'Open sales, by line.',
       'Opportunity', OPP_LIST + ['STAGE_NAME'], group=[(OPP_LINE, None, 'AMOUNT', 'Sum')], params=OPEN_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', OPP_LINE, [('Sum', 'AMOUNT')], 'Open pipeline by line'))
report(SALES, 'Pipeline_by_Type_and_Stage', 'Open Pipeline by Type', 'Open sales, by type of sale.',
       'Opportunity', [('AMOUNT', 'Sum')], group=['TYPE'], across=['STAGE_NAME'], params=OPEN_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', 'TYPE', [('Sum', 'AMOUNT')], 'Open pipeline by type'))
report(SALES, 'Sales_by_Type', 'New Business, Renewals and Cross-Sell', 'Every sale, by type.',
       'Opportunity', OPP_LIST + ['STAGE_NAME', OPP_LINE], group=['TYPE'], params=ALL_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', 'TYPE', [('Sum', 'AMOUNT')], 'Premium by type of sale'))
report(SALES, 'Win_Rate_by_Line', 'Win Rate by Line', 'Share of closed sales that bound.',
       'Opportunity', OPP_LIST + ['STAGE_NAME', 'FORMULA1'], group=[OPP_LINE], params=CLOSED_SALES, time=ANY_CLOSE,
       formulas=[formula('FORMULA1', 'Win Rate', 'WON:SUM / CLOSED:SUM')],
       chart=('HorizontalBar', OPP_LINE, [(None, 'FORMULA1')], 'Win rate by line'))
report(SALES, 'Sales_Closing_Next_60_Days', 'Sales Closing in the Next 60 Days', 'Open sales closing in 60 days.',
       'Opportunity', OPP_LIST + [OPP_LINE], group=['STAGE_NAME'], params=OPEN_SALES, time=('CLOSE_DATE', 'INTERVAL_NEXT60'), details=True,
       chart=('HorizontalBar', 'STAGE_NAME', [('Sum', 'AMOUNT')], 'Closing in the next 60 days'))
report(SALES, 'Bound_Premium_by_Month', 'Bound Premium by Month', 'Bound premium, by month closed.',
       'Opportunity', OPP_LIST + [OPP_LINE], group=[('CLOSE_DATE', 'Month')], params=WON_SALES, time=ANY_CLOSE,
       chart=('VerticalColumn', 'CLOSE_DATE', [('Sum', 'AMOUNT')], 'Bound premium by month'))
report(SALES, 'Bound_Premium_by_Line', 'Bound Premium by Line', 'Bound premium, by line.',
       'Opportunity', OPP_LIST + ['STAGE_NAME'], group=[(OPP_LINE, None, 'AMOUNT', 'Sum')], params=WON_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', OPP_LINE, [('Sum', 'AMOUNT')], 'Bound premium by line'))
Q_LIST = [Q + 'QuoteNumber', Q + 'Name', Q + 'Opportunity', (Q + 'Annual_Premium__c', 'Sum'), Q + 'Issued_Date__c', Q + 'Days_Since_Issued__c', Q + 'Underwriter__c']
report(SALES, 'Quotes_by_Status', 'Quotes by Status', 'Every quote, by status.',
       'Ants_Quotes__c', Q_LIST, group=[Q + 'Status'],
       chart=('HorizontalBar', Q + 'Status', [(None, 'RowCount')], 'Quotes by status'))
_age = bucket('Quote Age', Q + 'Days_Since_Issued__c', [(None, 7, 'Up to 7 days'), (7, 14, '8 to 14 days'), (14, 30, '15 to 30 days'), (30, None, 'Over 30 days')])
report(SALES, 'Open_Quotes_by_Age', 'Open Quotes by Age', 'Unanswered quotes, by age.',
       'Ants_Quotes__c', Q_LIST + [Q + 'Status'], group=[_age[0]], buckets=[_age], filters=[(Q + 'Status', 'equals', 'Issued,Presented')],
       chart=('VerticalColumn', _age[0], [('Sum', Q + 'Annual_Premium__c')], 'Open quoted premium by age'))
report(SALES, 'Stale_Quotes', 'Quotes Waiting', 'Out 15 days or more, no answer.',
       'Ants_Quotes__c', [Q + 'QuoteNumber', Q + 'Name', Q + 'Opportunity', (Q + 'Annual_Premium__c', 'Sum'), Q + 'Issued_Date__c', Q + 'Days_Since_Issued__c',
                          Q + 'ExpirationDate', Q + 'Underwriter__c'],
       group=[Q + 'Status'], filters=[(Q + 'Status', 'equals', 'Issued,Presented'), (Q + 'Days_Since_Issued__c', 'greaterOrEqual', '15')], details=True)
report(SALES, 'Quotes_by_Underwriter', 'Quotes by Underwriter', 'Quotes, by underwriter.',
       'Ants_Quotes__c', [(Q + 'Annual_Premium__c', 'Sum')], group=[Q + 'Underwriter__c'], across=[Q + 'Status'],
       chart=('HorizontalBar', Q + 'Underwriter__c', [(None, 'RowCount')], 'Quotes by underwriter'))
L_LIST = [L + 'FirstName', L + 'LastName', L + 'Company', L + 'Status', L + 'City']
report(SALES, 'Leads_by_Source', 'Leads by Source', 'Open leads, by source.',
       'Ants_Leads__c', L_LIST + [L + 'Product_Interest__c'], group=[L + 'LeadSource'], filters=[(L + 'IsConverted', 'equals', '0')],
       chart=('HorizontalBar', L + 'LeadSource', [(None, 'RowCount')], 'Leads by source'))
report(SALES, 'Leads_by_Product_Interest', 'Leads by Product Interest', 'Open leads, by product.',
       'Ants_Leads__c', [L + 'Company', L + 'LastName'], group=[L + 'Product_Interest__c'], across=[L + 'Status'], filters=[(L + 'IsConverted', 'equals', '0')],
       chart=('HorizontalBar', L + 'Product_Interest__c', [(None, 'RowCount')], 'Leads by product interest'))

# ---------------------------------------------------------------- Renewals and retention
_window = bucket('Renewal Window', P_DAYS, [(None, 30, 'Next 30 days'), (30, 60, '31 to 60 days'), (60, None, '61 to 90 days')])
DUE_90 = [IN_FORCE, (P_DAYS, 'greaterOrEqual', '0'), (P_DAYS, 'lessOrEqual', '90')]
report(RENEW, 'Renewals_Due_30_60_90', 'Renewals Due', 'Expiring in the next 90 days.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE, P_DAYS], group=[_window[0]], buckets=[_window], filters=DUE_90, details=True,
       chart=('VerticalColumn', _window[0], [('Sum', P_PREMIUM)], 'Premium up for renewal'))
report(RENEW, 'Renewals_Due_by_Line', 'Renewals Due by Line', 'Next 90 days, by line.',
       'Ants_Policies__c', POLICY_LIST + [P_DAYS], group=[(P_LINE, None, P_PREMIUM, 'Sum')], filters=DUE_90,
       chart=('HorizontalBar', P_LINE, [('Sum', P_PREMIUM)], 'Renewals due by line'))
report(RENEW, 'Renewals_Due_by_Agency', 'Renewals Due by Agency', 'Next 90 days, by agency.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE, P_DAYS], group=[(P_AGENCY, None, P_PREMIUM, 'Sum')], filters=DUE_90, details=True,
       chart=('HorizontalBar', P_AGENCY, [('Sum', P_PREMIUM)], 'Renewals due by agency'))
report(RENEW, 'Pending_Renewal_Policies', 'Policies Pending Renewal', 'Flagged by the renewal run.',
       'Ants_Policies__c', POLICY_LIST + [P_DAYS, P_AGENCY], group=[P_LINE], filters=[(P_STATUS, 'equals', 'Pending Renewal')], details=True,
       chart=('HorizontalBar', P_LINE, [('Sum', P_PREMIUM)], 'Premium pending renewal'))
report(RENEW, 'Lapsed_and_Cancelled_Policies', 'Policies Lost', 'Lapsed, cancelled or expired.',
       'Ants_Policies__c', POLICY_LIST + [P_LINE, P_PAYMENT], group=[P_STATUS], filters=[(P_STATUS, 'equals', 'Lapsed,Cancelled,Expired')], details=True,
       chart=('HorizontalBar', P_STATUS, [('Sum', P_PREMIUM)], 'Premium lost by reason'))
report(RENEW, 'Past_Due_Policies', 'Past Due Policies', 'Payment past due, by line.',
       'Ants_Policies__c', POLICY_LIST + [P_STATUS, P_BILLING], group=[P_LINE], filters=[(P_PAYMENT, 'equals', 'Past Due')], details=True,
       chart=('HorizontalBar', P_LINE, [('Sum', P_PREMIUM)], 'Past due premium by line'))
report(RENEW, 'Renewal_Sales_by_Stage', 'Renewal Sales by Stage', 'Open renewal sales, by stage.',
       'Opportunity', OPP_LIST + [OPP_LINE], group=['STAGE_NAME'], filters=[('TYPE', 'equals', 'Renewal')], params=OPEN_SALES, time=ANY_CLOSE,
       chart=('HorizontalBar', 'STAGE_NAME', [('Sum', 'AMOUNT')], 'Renewal premium by stage'))
report(RENEW, 'Customer_Tenure', 'Customers by Year Joined', 'By the year they first bought.',
       'Ants_Accounts__c', [A + 'Name', A + 'Customer_Segment__c', (A + 'Active_Policies__c', 'Sum'), (A + 'Premium_in_Force__c', 'Sum')],
       group=[(A + 'Customer_Since__c', 'Year')], filters=[(A + 'Customer_Segment__c', 'notEqual', 'Agency Partner')],
       chart=('VerticalColumn', A + 'Customer_Since__c', [(None, 'RowCount')], 'Customers by year joined'))

# ---------------------------------------------------------------- Service and operations
REQUEST_LIST = [C_NUMBER, C_SUBJECT, C_ACCOUNT, C_POLICY, C_STATUS, C_PRIORITY, C_CREATED]
report(SERVICE, 'Open_Requests_by_Type', 'Open Requests', 'Open requests, by type.',
       'Ants_Cases__c', REQUEST_LIST, group=[C_REQUEST], filters=[REQUEST, OPEN_CASE],
       chart=('HorizontalBar', C_REQUEST, [(None, 'RowCount')], 'Open requests by type'))
report(SERVICE, 'Service_Requests_by_Status', 'Service Requests by Status', 'All service requests, by status.',
       'Ants_Cases__c', REQUEST_LIST + [C_REQUEST], group=[C_STATUS], filters=[REQUEST],
       chart=('HorizontalBar', C_STATUS, [(None, 'RowCount')], 'Service requests by status'))
report(SERVICE, 'Cases_by_Channel', 'Work by Channel', 'Phone, web, email or agent.',
       'Ants_Cases__c', [C_NUMBER, C_SUBJECT], group=[C_ORIGIN], across=[C_TYPE],
       chart=('HorizontalBar', C_ORIGIN, [(None, 'RowCount')], 'Claims and requests by channel'))
report(SERVICE, 'Open_Requests_by_Week_Opened', 'Open Service Request Aging', 'Open requests, by week received.',
       'Ants_Cases__c', REQUEST_LIST + [C_REQUEST], group=[(C_REPORTED, 'Week')], filters=[REQUEST, OPEN_CASE],
       chart=('VerticalColumn', C_REPORTED, [(None, 'RowCount')], 'Open requests by week received'))
report(SERVICE, 'Requests_by_Type_and_Priority', 'Requests by Priority', 'Requests by priority and type.',
       'Ants_Cases__c', [C_NUMBER, C_SUBJECT], group=[C_PRIORITY], across=[C_REQUEST], filters=[REQUEST],
       chart=('HorizontalBar', C_PRIORITY, [(None, 'RowCount')], 'Service requests by priority'))
report(SERVICE, 'File_Notes_by_Type', 'File Notes by Type', 'Notes on files, by type.',
       'Ants_File_Notes__c', [N + 'Name', N + 'Author_Name__c', N + 'Note_Date__c', N + 'Case__c', N + 'Policy__c'], group=[N + 'Note_Type__c'],
       chart=('HorizontalBar', N + 'Note_Type__c', [(None, 'RowCount')], 'File notes by type'))
TASK_LIST = ['SUBJECT', 'DUE_DATE', 'STATUS', 'WHAT_NAME', 'WHO_NAME']
OPEN_TASKS = [('closed', 'open'), ('type', 't')]
report(SERVICE, 'Open_Tasks_by_Priority', 'Open Tasks', 'Open tasks, by priority.',
       'Activity', TASK_LIST + ['ASSIGNED'], group=['PRIORITY'], params=OPEN_TASKS, time=('DUE_DATE', 'INTERVAL_CUSTOM'),
       chart=('HorizontalBar', 'PRIORITY', [(None, 'RowCount')], 'Open tasks by priority'))
report(SERVICE, 'Overdue_Tasks', 'Overdue Tasks', 'Past due, by owner.',
       'Activity', TASK_LIST + ['PRIORITY'], group=['ASSIGNED'], filters=[('DUE_DATE', 'lessThan', 'TODAY')], params=OPEN_TASKS,
       time=('DUE_DATE', 'INTERVAL_CUSTOM'), details=True,
       chart=('HorizontalBar', 'ASSIGNED', [(None, 'RowCount')], 'Overdue tasks by owner'))
report(SERVICE, 'Tasks_Due_by_Week', 'Open Tasks by Week Due', 'Open tasks, by week due.',
       'Activity', TASK_LIST + ['PRIORITY', 'ASSIGNED'], group=[('DUE_DATE', 'Week')], params=OPEN_TASKS, time=('DUE_DATE', 'INTERVAL_CUSTOM'),
       chart=('VerticalColumn', 'DUE_DATE', [(None, 'RowCount')], 'Open tasks by week due'))


# ====================================================================== dashboards
LEAD_DASH, UW_DASH, OPS_DASH = 'Ants_Leadership', 'Ants_Underwriting_and_Sales', 'Ants_Claims_and_Service'
for dev, label in [(LEAD_DASH, 'Leadership'), (UW_DASH, 'Underwriting and Sales'), (OPS_DASH, 'Claims and Service')]:
    folder('dashboards', dev, label)

REPORT_FOLDER = {dev: folder_name for folder_name, dev, _ in REPORTS}
REPORT_LABEL = {dev: label for _, dev, label in REPORTS}
COUNT = (None, 'RowCount')
# A dashboard takes one of Salesforce's named palettes, not a list of colours, and the palette's first
# colour draws every single-series chart. Only "branding" (Branding in the dashboard's Properties) leads
# with the theme's clay; every other warm palette (Fire, Sunrise, Heat) opens on a pale yellow, and "dusk"
# on a pale blue. Branding's later colours are browns nobody can tell apart, so every chart here shows one
# series: a category is read from its label on the axis, never from a colour in a legend.
PALETTE = 'branding'
DASHBOARDS = []


def component(kind, report_name, header, measure, footer='', grouping=None, second=None, sort='RowValueDescending', top=None, columns=None,
              decimals=None, axis_max=None):
    """One dashboard tile. kind: Metric, Bar, Column, Donut, Funnel, BarStacked, ColumnStacked, Line or FlexTable.
    decimals: decimal places on the figures; -1 lets Salesforce choose. axis_max: the top of the value axis, for a
    count small enough that an automatic axis would be marked in halves."""
    assert len(header) <= 40, header
    aggregate, column = measure if measure else (None, None)
    assert kind != 'Metric' or len(footer) <= 24, footer   # a longer footer is cut off on a metric tile
    # A metric tile is narrow, and its "View Report (...)" link gets under half of it: about 180px at a
    # 1568px window, which is 21 average characters of report name. "Open Requests by Type" (21) was cut
    # where "Open Claims by Status" (21) fitted, so the limit here leaves room for wide letters.
    assert kind != 'Metric' or len(REPORT_LABEL[report_name]) <= 19, REPORT_LABEL[report_name]
    # At a 1,440px window the link has room for about 13 characters before its closing bracket is cut. The
    # lead dashboard's two reports are named to fit ("Book by Line", "Open Reserve"); the other dashboards'
    # reports keep fuller names, which are cut at that width and whole from about 1,560px.
    # One series a chart: see PALETTE. A donut is one series too, but its slices take neighbouring shades
    # of the theme colour that cannot be told apart, so no dashboard uses one now; the kind is still accepted.
    assert kind in ('Metric', 'Bar', 'Column', 'Line', 'Donut', 'FlexTable') and not second, (kind, header)
    if decimals is None:
        decimals = -1
    xml = '                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>\n'
    if kind not in ('Metric', 'FlexTable'):
        if axis_max:
            xml += f'                <chartAxisRange>Manual</chartAxisRange>\n                <chartAxisRangeMax>{axis_max}</chartAxisRangeMax>\n                <chartAxisRangeMin>0</chartAxisRangeMin>\n'
        else:
            xml += '                <chartAxisRange>Auto</chartAxisRange>\n'
    if measure:
        xml += ('                <chartSummary>\n' + (f'                    <aggregate>{aggregate}</aggregate>\n' if aggregate else '') +
                ('' if kind == 'Metric' else '                    <axisBinding>y</axisBinding>\n') + f'                    <column>{column}</column>\n                </chartSummary>\n')
    xml += f'                <componentType>{kind}</componentType>\n'
    if kind != 'FlexTable':
        xml += f'                <decimalPrecision>{decimals}</decimalPrecision>\n                <displayUnits>Auto</displayUnits>\n'
    if kind not in ('Metric', 'FlexTable'):
        xml += '                <drillEnabled>false</drillEnabled>\n                <drillToDetailEnabled>false</drillToDetailEnabled>\n                <enableHover>true</enableHover>\n                <expandOthers>false</expandOthers>\n'
    if kind == 'FlexTable':
        xml += '                <flexComponentProperties>\n'
        # Table tiles name a report's detail columns as Object.Field, where the report itself writes Object$Field.
        for name in columns:
            xml += f'                    <flexTableColumn>\n                        <reportColumn>{name.replace("$", ".")}</reportColumn>\n                        <showSubTotal>false</showSubTotal>\n                        <showTotal>false</showTotal>\n                        <type>detail</type>\n                    </flexTableColumn>\n'
        # A table must say how it is sorted: by the column named in `sort`, largest first.
        xml += (f'                    <flexTableSortInfo>\n                        <sortColumn>{sort.replace("$", ".")}</sortColumn>\n                        <sortOrder>2</sortOrder>\n                    </flexTableSortInfo>\n'
                '                    <hideChatterPhotos>true</hideChatterPhotos>\n                </flexComponentProperties>\n')
    if footer:
        xml += f'                <footer>{esc(footer)}</footer>\n'
    for name in [grouping, second]:
        if name:
            xml += f'                <groupingColumn>{name}</groupingColumn>\n'
    xml += f'                <header>{esc(header)}</header>\n'
    if kind == 'Metric':
        # A metric tile colours its figure by range. With no ranges set every figure takes the low colour,
        # so all three are ink and no figure reads as an alarm.
        xml += '                <indicatorHighColor>#141413</indicatorHighColor>\n                <indicatorLowColor>#141413</indicatorLowColor>\n                <indicatorMiddleColor>#141413</indicatorMiddleColor>\n'
    if kind in ('Donut', 'Funnel') or second:
        xml += '                <legendPosition>Right</legendPosition>\n'
    if top:
        xml += f'                <maxValuesDisplayed>{top}</maxValuesDisplayed>\n'
    xml += f'                <report>{REPORT_FOLDER[report_name]}/{report_name}</report>\n'
    if kind in ('Donut', 'Funnel'):
        # A share on a donut always prints with two decimals ("21.38%"), so the segments carry their values instead.
        xml += '                <showPercentage>false</showPercentage>\n                <showTotal>true</showTotal>\n                <showValues>true</showValues>\n'
    elif kind == 'Line':
        # A line's first figure prints on top of its own point and the axis beside it; the points answer to hover instead.
        xml += '                <showValues>false</showValues>\n'
    elif kind not in ('Metric', 'FlexTable') and not second:
        xml += '                <showValues>true</showValues>\n'
    if kind not in ('Metric', 'FlexTable'):
        xml += f'                <sortBy>{sort}</sortBy>\n                <useReportChart>false</useReportChart>\n'
    return xml


# Reports renamed short for the metric tiles keep a fuller heading on their chart tiles.
CHART_TITLES = {
    'Premium_in_Force_by_Line': 'Premium in force by line', 'Policy_Terms_by_Line': 'Average premium by line', 'Customers_by_Segment': 'Customers by segment',
    'Insured_Assets_by_Type': 'Insured value by type', 'Open_Claims_by_Status': 'Open claims by status', 'Open_Pipeline_by_Stage': 'Open pipeline by stage',
    'Renewals_Due_30_60_90': 'Renewals due by window', 'Lapsed_and_Cancelled_Policies': 'Lapsed and cancelled', 'Open_Requests_by_Type': 'Open requests by type',
    'Open_Tasks_by_Priority': 'Open tasks by priority', 'Open_Claims_Exposure': 'Reserve by severity',
}


def chart(kind, report_name, measure, footer, grouping, second=None, header=None, **options):
    """A chart tile headed with its report's own name, so the tile and its View Report link read the same."""
    assert footer, report_name   # a tile with no caption leaves a blank band under its chart
    label = REPORT_LABEL[report_name]
    header = header or CHART_TITLES.get(report_name) or label[0] + label[1:].lower().replace(' siu ', ' SIU ')
    return component(kind, report_name, header, measure, footer, grouping, second, **options)


def dashboard(folder_name, dev, title, description, rows, company_wide=False):
    """rows: [(height, [(width, component xml)])]. Every row is four tiles of 3, two of 6 or one of 12, so tile
    edges line up down the page."""
    assert len(description) <= 36, (title, len(description))   # the Dashboards list fits about 36 characters a line and hyphenates what wraps
    grid, top = '', 0
    for height, tiles in rows:
        left = 0
        assert [width for width, _ in tiles] in ([3, 3, 3, 3], [6, 6], [12]), (title, top)
        for width, tile in tiles:
            grid += (f'        <dashboardGridComponents>\n            <colSpan>{width}</colSpan>\n            <columnIndex>{left}</columnIndex>\n            <dashboardComponent>\n'
                     f'{tile}            </dashboardComponent>\n            <rowIndex>{top}</rowIndex>\n            <rowSpan>{height}</rowSpan>\n        </dashboardGridComponents>\n')
            left += width
        top += height
    write(f'dashboards/{folder_name}/{dev}.dashboard-meta.xml',
          f'<Dashboard {NS}>\n    <backgroundEndColor>#FFFFFF</backgroundEndColor>\n    <backgroundFadeDirection>Diagonal</backgroundFadeDirection>\n    <backgroundStartColor>#FFFFFF</backgroundStartColor>\n'
          f'    <chartTheme>light</chartTheme>\n    <colorPalette>{PALETTE}</colorPalette>\n    <dashboardChartTheme>light</dashboardChartTheme>\n    <dashboardColorPalette>{PALETTE}</dashboardColorPalette>\n'
          f'    <dashboardGridLayout>\n{grid}        <numberOfColumns>12</numberOfColumns>\n        <rowHeight>36</rowHeight>\n    </dashboardGridLayout>\n'
          f'    <dashboardType>{"SpecifiedUser" if company_wide else "LoggedInUser"}</dashboardType>\n    <description>{esc(description)}</description>\n    <isGridLayout>true</isGridLayout>\n'
          + (f'    <runningUser>{RUNNING_USER}</runningUser>\n' if company_wide else '') +
          f'    <textColor>#000000</textColor>\n    <title>{esc(title)}</title>\n    <titleColor>#000000</titleColor>\n    <titleSize>12</titleSize>\n</Dashboard>')
    DASHBOARDS.append((folder_name, dev, title))


# Tile heights, in grid rows. A metric tile is tall enough for its figure to be the largest thing on it.
METRIC, CHART, TABLE = 4, 8, 9
SUM = 'Sum'
ASC = 'RowLabelAscending'
QUOTES_WAITING = 'Quotes waiting 15 days or more'   # the one name for this measure, here and on the Home page


def metrics(*tiles):
    return (METRIC, [(3, tile) for tile in tiles])


def pair(left, right):
    return (CHART, [(6, left), (6, right)])


def full(tile, height=CHART):
    return (height, [(12, tile)])


# Which chart for which shape, so the six dashboards do not read as one template repeated:
#   a ranking of named things (lines, customers, adjusters)   horizontal bar, longest first
#   a short set of short names (age bands, windows, priorities)  column, for five or fewer; more are turned and cut
#   a run of months                                            line, or a column where each month stands alone
#   a split in two (personal against commercial)               two bars. Not a donut: the theme palette draws its
#                                                              two slices in clays too close to tell apart, so the
#                                                              legend's dots look the same (UI audit 4, A4-50)
# A run of months or weeks takes a full-width tile: at half width the date labels are turned on their
# side and the longest is cut ("Septembe...").
TIME = 7

dashboard(LEAD_DASH, 'Executive_Overview', 'Executive Overview', 'The book, losses and pipeline.', [
    metrics(component('Metric', 'Premium_in_Force_by_Line', 'Premium in force', (SUM, P_PREMIUM), 'Annual premium'),
            component('Metric', 'Premium_in_Force_by_Line', 'Policies in force', COUNT, 'Active or renewing'),
            component('Metric', 'Open_Claims_Exposure', 'Open claims', COUNT, 'Claims not yet closed'),
            component('Metric', 'Open_Claims_Exposure', 'Outstanding reserve', (SUM, C_OUTSTANDING), 'On open claims')),
    pair(chart('Bar', 'Premium_in_Force_by_Line', (SUM, P_PREMIUM), 'Annual premium by line of business', P_LINE),
         chart('Bar', 'Loss_Ratio_by_Line', (None, 'FORMULA1'), 'Incurred losses over premium in force', P_LINE, decimals=0)),
    full(chart('Line', 'Written_Premium_by_Month', (SUM, P_PREMIUM), 'By the month each policy took effect', P_EFFECTIVE, sort=ASC), TIME),
    pair(chart('Bar', 'Top_Customers_by_Premium', (SUM, P_PREMIUM), 'The ten largest, by annual premium in force', P_ACCOUNT, top=10),
         chart('Bar', 'Premium_in_Force_by_Segment', (SUM, P_PREMIUM), 'Personal against commercial', P_SEGMENT)),
    pair(chart('Bar', 'Policies_by_Status', COUNT, 'Every policy', P_STATUS),
         chart('Bar', 'Open_Pipeline_by_Stage', (SUM, 'AMOUNT'), 'Premium on open policy sales', 'STAGE_NAME', sort=ASC)),
    pair(chart('Column', 'Renewals_Due_30_60_90', (SUM, P_PREMIUM), 'Premium expiring in the next 90 days', _window[0], sort=ASC),
         # A bar, not a column: a column prints the measure's name up its side, where "Sum of Outstanding Reserve" is cut short.
         chart('Bar', 'Open_Claims_Exposure', (SUM, C_OUTSTANDING), 'Outstanding on open claims', C_SEVERITY)),
], company_wide=True)

dashboard(OPS_DASH, 'Claims_Operations', 'Claims Operations', 'Open claims, reserves, payments.', [
    metrics(component('Metric', 'Open_Claims_by_Status', 'Open claims', COUNT, 'Claims not yet closed'),
            component('Metric', 'Open_Claims_by_Status', 'Outstanding reserve', (SUM, C_OUTSTANDING), 'On open claims'),
            component('Metric', 'Reserves_and_Payments_by_Status', 'Paid to date', (SUM, C_PAID), 'Open and closed claims'),
            component('Metric', 'Large_Open_Claims', 'Large open claims', COUNT, '$25,000 or more to pay')),
    pair(chart('Bar', 'Open_Claims_by_Status', COUNT, 'Where each open claim is in handling', C_STATUS, axis_max=10),
         chart('Column', 'Open_Claims_by_Severity', COUNT, 'How serious they are', C_SEVERITY, axis_max=12)),
    pair(chart('Column', 'Open_Claims_by_Age', COUNT, 'How long open claims have been open', _claim_age[0], sort=ASC),
         chart('Bar', 'Open_Claims_by_Owner', COUNT, 'Who is carrying the open claims', C_HANDLER)),
    full(chart('Line', 'Claims_Reported_by_Month', COUNT, 'Is claim volume rising?', C_REPORTED, sort=ASC), TIME),
    pair(chart('Bar', 'Claims_by_Loss_Type', (SUM, C_RESERVE), 'Reserved: what is driving losses', C_LOSS),
         chart('Bar', 'Claims_by_Line_and_Severity', COUNT, 'Claim counts for each line of business', C_LINE)),
    pair(chart('Bar', 'Closed_Claims_Paid_by_Line', (SUM, C_PAID), 'Paid on closed claims', C_LINE),
         chart('Bar', 'Claims_by_Customer_Segment', (SUM, C_RESERVE), 'Reserved, personal against commercial', C + 'Account.Customer_Segment__c')),
    pair(chart('Bar', 'File_Notes_by_Author', COUNT, 'Who is working their files', N + 'Author_Name__c'),
         # Seven statuses with long names: as columns at half width their labels are turned and cut.
         chart('Bar', 'Reserves_and_Payments_by_Status', (SUM, C_RESERVE), 'Reserved at each stage of handling', C_STATUS)),
    # Four columns is what a full-width table shows without cutting the last one off. A table tile cannot be
    # cut to a number of rows and scrolls inside itself when it is too short: a row takes about 27px and the
    # heading and footer about 90px, so nine grid rows (324px) hold the seven or eight claims this size.
    full(component('FlexTable', 'Large_Open_Claims', 'Large open claims', None, 'Open claims with $25,000 or more still to pay, largest first',
                   columns=[C_SUBJECT, C_ACCOUNT + '.Name', C_STATUS, C_OUTSTANDING], sort=C_OUTSTANDING), TABLE),
])

dashboard(UW_DASH, 'Book_of_Business', 'Book of Business', 'Premium, coverage mix, driver risk.', [
    metrics(component('Metric', 'Premium_in_Force_by_Line', 'Premium in force', (SUM, P_PREMIUM), 'Annual premium'),
            component('Metric', 'Policy_Terms_by_Line', 'Average premium', ('Average', P_PREMIUM), 'Per policy in force'),
            component('Metric', 'Customers_by_Segment', 'Customers', COUNT, 'Households, businesses'),
            component('Metric', 'Insured_Assets_by_Type', 'Insured value', (SUM, ASSET + 'Insured_Value__c'), 'Across all assets')),
    pair(chart('Bar', 'Premium_by_Line_and_Status', (SUM, P_PREMIUM), 'Where the book is healthy and where it leaks', P_STATUS),
         chart('Bar', 'Premium_by_Agency', (SUM, P_PREMIUM), 'Direct means Antsurance sold the policy itself', P_AGENCY)),
    pair(chart('Bar', 'Coverage_Mix_by_Category', (SUM, COV + 'Premium_Amount__c'), 'Premium on active coverages', COV + 'Category__c'),
         chart('Bar', 'Insured_Assets_by_Type', (SUM, ASSET + 'Insured_Value__c'), 'What the book insures', ASSET + 'Asset_Type__c')),
    pair(chart('Bar', 'Policy_Terms_by_Line', ('Average', P_PREMIUM), 'Per policy in force', P_LINE, decimals=0),
         chart('Bar', 'Customers_by_Segment', COUNT, 'Households against businesses', A + 'Customer_Segment__c')),
    pair(chart('Column', 'Customers_by_Policies_Held', COUNT, 'One-policy customers are the cross-sell list', _held[0], sort=ASC),
         chart('Column', 'Billing_Plans', COUNT, 'How often policies are billed', P_BILLING)),
    pair(chart('Column', 'Drivers_by_Rating', COUNT, 'Active drivers on auto policies', PART + 'Driver_Rating__c'),
         chart('Bar', 'Endorsements_by_Type', COUNT, 'Forms attached to policies in force', ENDO + 'Type__c')),
], company_wide=True)

dashboard(UW_DASH, 'Sales_Pipeline_and_Quotes', 'Sales Pipeline and Quotes', 'Pipeline, quotes and win rate.', [
    metrics(component('Metric', 'Open_Pipeline_by_Stage', 'Open pipeline', (SUM, 'AMOUNT'), 'On open policy sales'),
            component('Metric', 'Open_Pipeline_by_Stage', 'Open sales', COUNT, 'Not yet closed'),
            component('Metric', 'Open_Quotes_by_Age', 'Quotes awaiting an answer', COUNT, 'Issued or presented'),
            component('Metric', 'Stale_Quotes', QUOTES_WAITING, COUNT, 'Each one needs a call')),
    pair(chart('Bar', 'Open_Pipeline_by_Stage', (SUM, 'AMOUNT'), 'Premium at each stage', 'STAGE_NAME', sort=ASC),
         chart('Bar', 'Open_Pipeline_by_Line', (SUM, 'AMOUNT'), 'Which products the pipeline is made of', OPP_LINE)),
    full(chart('Column', 'Bound_Premium_by_Month', (SUM, 'AMOUNT'), 'Premium on sales that bound', 'CLOSE_DATE', sort=ASC), TIME),
    pair(chart('Bar', 'Pipeline_by_Type_and_Stage', (SUM, 'AMOUNT'), 'New business, renewals and cross-sell', 'TYPE'),
         # Not the win rate: with a few closed sales a line, each bar reads 0%, 50% or 100%. That report stays in the folder.
         chart('Bar', 'Bound_Premium_by_Line', (SUM, 'AMOUNT'), 'Which products the bound premium came from', OPP_LINE)),
    pair(chart('Bar', 'Quotes_by_Status', COUNT, 'Every quote', Q + 'Status'),
         chart('Column', 'Open_Quotes_by_Age', (SUM, Q + 'Annual_Premium__c'), 'Quoted premium by how long it has been out', _age[0], sort=ASC)),
    pair(chart('Bar', 'Quotes_by_Underwriter', COUNT, 'Who priced them', Q + 'Underwriter__c'),
         chart('Bar', 'Sales_Closing_Next_60_Days', (SUM, 'AMOUNT'), 'Premium due to close, by stage', 'STAGE_NAME', sort=ASC,
               header='Closing in the next 60 days')),
    pair(chart('Bar', 'Leads_by_Source', COUNT, 'Open leads', L + 'LeadSource', axis_max=12),
         chart('Bar', 'Leads_by_Product_Interest', COUNT, 'What open leads asked about', L + 'Product_Interest__c', axis_max=8)),
    # A table tile cannot be cut to a number of rows, so this one is tall enough for every waiting quote.
    full(component('FlexTable', 'Stale_Quotes', QUOTES_WAITING, None, 'Longest wait first. Each one needs a call.',
                   columns=[Q + 'Name', Q + 'Opportunity.Name', Q + 'Annual_Premium__c', Q + 'Days_Since_Issued__c'],
                   sort=Q + 'Days_Since_Issued__c'), 13),
])

dashboard(UW_DASH, 'Renewals_and_Retention', 'Renewals and Retention', 'Renewals due and premium at risk.', [
    metrics(component('Metric', 'Renewals_Due_30_60_90', 'Premium up for renewal', (SUM, P_PREMIUM), 'Next 90 days'),
            component('Metric', 'Renewals_Due_30_60_90', 'Policies up for renewal', COUNT, 'Next 90 days'),
            component('Metric', 'Past_Due_Policies', 'Past due premium', (SUM, P_PREMIUM), 'At risk of lapsing'),
            component('Metric', 'Lapsed_and_Cancelled_Policies', 'Premium lost', (SUM, P_PREMIUM), 'Lapsed or cancelled')),
    pair(chart('Column', 'Renewals_Due_30_60_90', (SUM, P_PREMIUM), 'Premium expiring in each 30-day window', _window[0], sort=ASC),
         chart('Bar', 'Renewals_Due_by_Line', (SUM, P_PREMIUM), 'Next 90 days', P_LINE)),
    pair(chart('Bar', 'Renewals_Due_by_Agency', (SUM, P_PREMIUM), 'Next 90 days', P_AGENCY),
         chart('Bar', 'Renewal_Sales_by_Stage', (SUM, 'AMOUNT'), 'How far each renewal has got', 'STAGE_NAME', sort=ASC)),
    pair(chart('Bar', 'Pending_Renewal_Policies', (SUM, P_PREMIUM), 'Policies the renewal run has flagged', P_LINE),
         chart('Column', 'Lapsed_and_Cancelled_Policies', (SUM, P_PREMIUM), 'Premium lost, by reason', P_STATUS)),
    pair(chart('Bar', 'Past_Due_Policies', (SUM, P_PREMIUM), 'Premium with a payment past due, by line', P_LINE),
         chart('Column', 'Customer_Tenure', COUNT, 'How long the book has been held', A + 'Customer_Since__c', sort=ASC)),
], company_wide=True)

dashboard(OPS_DASH, 'Service_and_Operations', 'Service and Operations', 'Service requests and tasks due.', [
    metrics(component('Metric', 'Open_Requests_by_Type', 'Open service requests', COUNT, 'Not yet closed'),
            component('Metric', 'Open_Tasks_by_Priority', 'Open tasks', COUNT, 'Assigned to you'),
            component('Metric', 'Overdue_Tasks', 'Overdue tasks', COUNT, 'Due date has passed'),
            component('Metric', 'File_Notes_by_Type', 'File notes written', COUNT, 'On all files')),
    pair(chart('Bar', 'Open_Requests_by_Type', COUNT, 'What customers are asking for', C_REQUEST, axis_max=10),
         chart('Column', 'Service_Requests_by_Status', COUNT, 'All service requests', C_STATUS)),
    pair(chart('Column', 'Requests_by_Type_and_Priority', COUNT, 'All service requests', C_PRIORITY),
         chart('Bar', 'Cases_by_Channel', COUNT, 'How claims and requests arrive', C_ORIGIN)),
    full(chart('Column', 'Open_Requests_by_Week_Opened', COUNT, 'Open requests by the week they came in', C_REPORTED, sort=ASC), TIME),
    pair(chart('Bar', 'File_Notes_by_Type', COUNT, 'Contact, investigation, reserve, payment and more', N + 'Note_Type__c'),
         chart('Column', 'Open_Tasks_by_Priority', COUNT, 'Your open tasks, high priority first', 'PRIORITY')),
    full(chart('Column', 'Tasks_Due_by_Week', COUNT, 'The work coming up', 'DUE_DATE', sort=ASC), TIME),
])

print(f'{len(REPORTS)} reports in {len(set(r[0] for r in REPORTS))} folders, {len(DASHBOARDS)} dashboards in {len(set(d[0] for d in DASHBOARDS))} folders')

