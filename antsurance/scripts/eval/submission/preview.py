#!/usr/bin/env python3
"""Prints what the card will show for a saved run, without calling Claude and without saving anything.

It takes the readings from runs/<run>/readings.json and asks the deployed code for: what the card
offers on the sale and on a lead, the answers as read and what they price to in the configurator,
and the same after a person settles the open answers. (A refused file cannot be shown this way:
the refusal is an error only a page can receive. The Apex tests cover it.)

    python3 -I scripts/eval/submission/preview.py --org <alias> --run v2

One `sf` command.
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run import apex, chunks, literal, MARK  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--org', required=True)
    parser.add_argument('--run', required=True)
    args = parser.parse_args()
    expected = json.load(open(os.path.join(HERE, 'expected.json')))
    readings = json.load(open(os.path.join(HERE, 'runs', args.run, 'readings.json')))
    say = lambda label, value: f"System.debug(LoggingLevel.ERROR, '{MARK}{label}: ' + {value});"
    printed = apex(args.org, '\n'.join([
        chunks('readings', json.dumps(readings)),
        f"Id saleId = [SELECT Id FROM Opportunity WHERE Name = {literal(expected['sale'])} LIMIT 1].Id;",
        'AntsuranceSubmissionIntake.Context onSale = AntsuranceSubmissionIntake.getContext(saleId);',
        say('On the sale', "onSale.recordKind + ', ' + onSale.lineOfBusiness + ' for ' + onSale.customerName + ', can read ' + onSale.canRead + ', can quote ' + onSale.canQuote + ', files ' + onSale.files.size() + ', sample documents ' + onSale.samples.size()"),
        'for (AntsuranceSubmissionIntake.FileItem sample : onSale.samples) {',
        say('Sample', "sample.title + ' (' + sample.sizeLabel + ')'"),
        '}',
        "List<Lead> leads = [SELECT Id, Company FROM Lead WHERE Product_Interest__c = 'Workers Compensation' AND IsConverted = false ORDER BY Company LIMIT 1];",
        'if (!leads.isEmpty()) {',
        'AntsuranceSubmissionIntake.Context onLead = AntsuranceSubmissionIntake.getContext(leads[0].Id);',
        say('On a lead', "onLead.recordKind + ', ' + onLead.lineOfBusiness + ' for ' + onLead.customerName + ', can read ' + onLead.canRead + ', can quote ' + onLead.canQuote + ', sample documents ' + onLead.samples.size()"),
        '}',
        'AntsuranceSubmissionIntake.Assembly asRead = AntsuranceSubmissionIntake.assemble(saleId, readings, null);',
        "AntsuranceQuoteConfigurator.Pricing first = AntsuranceQuoteConfigurator.price(onSale.lineOfBusiness, asRead.answersJson, null);",
        say('As read', "asRead.settled + ' settled, ' + asRead.conflicts + ' disputed, ' + asRead.notFound + ' not found'"),
        say('Handed to the configurator', 'asRead.answersJson'),
        say('Priced by the configurator', "'$' + first.premium.format() + ' a year, limit $' + first.limitAmount.format() + ', referrals ' + first.referrals"),
        "AntsuranceSubmissionIntake.Assembly settled = AntsuranceSubmissionIntake.assemble(saleId, readings, '{\"priorClaims\":\"4plus\",\"drugFree\":\"false\",\"employees\":\"25\"}');",
        "AntsuranceQuoteConfigurator.Pricing second = AntsuranceQuoteConfigurator.price(onSale.lineOfBusiness, settled.answersJson, null);",
        say('After the person settles claims (four or more), drug-free (no) and corrects employees to 25', "settled.settled + ' settled, ' + settled.conflicts + ' disputed, ' + settled.notFound + ' not found'"),
        say('Handed to the configurator', 'settled.answersJson'),
        say('Priced by the configurator', "'$' + second.premium.format() + ' a year, referrals ' + second.referrals"),
    ]))
    out = '\n'.join(printed)
    open(os.path.join(HERE, 'runs', args.run, 'preview.txt'), 'w').write(out + '\n')
    print(out)


if __name__ == '__main__':
    main()
