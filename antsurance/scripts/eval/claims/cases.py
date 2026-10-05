"""Intake accuracy cases. Answers were written by hand before any run; none come from a model.

Dates in messages are relative, so expected dates are computed from the run date.
`sample` cases use the sample text the form itself offers for that customer (the demo path).
`split` is 'tune' (looked at while adjusting the prompt) or 'held' (scored only at the end).
"""
import datetime as dt

TODAY = dt.date.today()

def last(weekday):
    """Most recent given weekday strictly before today (Mon=0)."""
    d = TODAY - dt.timedelta(days=1)
    while d.weekday() != weekday:
        d -= dt.timedelta(days=1)
    return d

def ago(days):
    return TODAY - dt.timedelta(days=days)

def spoken(d):
    return f"{d.day} {d.strftime('%B')}"

MON, TUE, WED, THU, FRI, SAT, SUN = range(7)

CASES = [
    dict(id='auto-email-sample', split='tune', account='Reyes Household', sample='auto-email',
         is_claim=True, line='Personal Auto', date=last(SAT), loss_type='Collision', severity={'Low'}, estimate=4200,
         origin='Email', reporter='Maria Reyes', location=['Ogden'], keep=['NPD-26-118204', 'K47 2291', 'State Farm']),
    dict(id='home-web-sample', split='tune', account='Reyes Household', sample='home-web',
         is_claim=True, line='Homeowners', date=ago(1), loss_type='Water Damage', severity={'Medium'}, estimate=None,
         origin='Web', reporter='Maria Reyes', location=['524 W Spring'], keep=['dishwasher', '$380'], needs_missing=True),
    dict(id='auto-call-sample', split='tune', account='Reyes Household', sample='auto-call',
         is_claim=True, line='Personal Auto', date=ago(1), loss_type='Glass', severity={'Low'}, estimate=None,
         origin='Phone', reporter='Maria Reyes', location=['I-88'], keep=['gravel truck']),
    dict(id='billing-sample', split='tune', account='Reyes Household', sample='not-a-claim', is_claim=False),
    dict(id='lapsed-auto', split='tune', account='Castellano Household',
         message=("Subject: backed into a pole\n\nHi, I backed into a concrete pole in my apartment garage on Tuesday night. "
                  "The rear bumper on my Escape is cracked and the left tail light is smashed. Nobody else was involved. "
                  "Wauwatosa Collision gave me an estimate of $1,850. Can I get this fixed under my policy?\n\nLucia Castellano"),
         is_claim=True, line='Personal Auto', date=last(TUE), loss_type='Collision', severity={'Low'}, estimate=1850,
         origin='Email', reporter='Lucia Castellano', location=['garage'], keep=['Wauwatosa Collision'], watch=['laps']),
    dict(id='renters-bike', split='tune', account='Lindqvist Household',
         message=("Online claim form\n\nName: Erik Lindqvist\nWhat happened: My bike was stolen from the locked storage room in the basement of my building. "
                  "I found the lock cut when I went down this morning. It is a Trek Domane, I paid $2,200 for it in April and have the receipt. "
                  "Madison police took a report over the phone, case number 2026-271904.\nWhere: 123 W Washington Ave, Madison"),
         is_claim=True, line='Renters', date=ago(0), loss_type='Theft', severity={'Low'}, estimate=2200,
         origin='Web', reporter='Erik Lindqvist', location=['123 W Washington'], keep=['2026-271904', 'Trek']),
    dict(id='limb-on-car', split='tune', account='Okafor Household',
         message=("Subject: Storm damage to our car\n\nHello,\n\nA big limb came down off the maple in last night's storm and landed on the Subaru in our driveway. "
                  "The windshield is smashed and the hood and roof are dented. The house and fence are fine. "
                  "Evanston Auto Body looked at it today and said $3,900.\n\nThanks,\nAmara Okafor"),
         is_claim=True, line='Personal Auto', date=ago(1), loss_type='Wind or Hail', severity={'Low'}, estimate=3900,
         origin='Email', reporter='Amara Okafor', location=['2620 Central Park', 'driveway'], keep=['Evanston Auto Body']),
    dict(id='apartment-fire-agent', split='tune', account='Copperfield Property Management',
         message=("Subject: New loss, Copperfield Property Management\n\nHi team,\n\nI am the broker for Copperfield Property Management and am reporting this for them. "
                  "Early on Sunday morning a fire started in a second-floor unit at their building at 2218 W Armitage Ave, Chicago, and spread to the unit above. "
                  "The fire department put it out but six units cannot be lived in. Two tenants were treated for smoke inhalation at the hospital and released. "
                  "Their restoration contractor's first rough number is $380,000. Fire department incident number is 26-1184-C.\n\n"
                  "Please assign an adjuster today.\n\nHal Brennan\nPrairie Shield Insurance Agency"),
         is_claim=True, line='Commercial Property', date=last(SUN), loss_type='Fire', severity={'Catastrophic'}, estimate=380000,
         origin='Agent', reporter='', location=['2218 W Armitage'], keep=['26-1184-C', 'six units']),
    dict(id='taproom-slip-call', split='tune', account='Bluestem Brewing Company',
         message=("Call from Joe Mancini at Bluestem, 2:40pm. A guest, Margaret Doyle, slipped on a wet floor near the taproom bar on Friday evening about 7:15 and went down hard on her wrist. "
                  "Staff called an ambulance, she was seen in the ER and sent home the same night with a broken wrist in a cast. Wet floor sign was out per Joe. "
                  "There is camera footage and two staff saw it. Her daughter phoned today saying they expect the medical bills to be covered. No figure mentioned."),
         is_claim=True, line='General Liability', date=last(FRI), loss_type='Bodily Injury', severity={'Medium'}, estimate=None,
         origin='Phone', reporter='Joe Mancini', location=['taproom'], keep=['Margaret Doyle', 'camera']),
    dict(id='saw-injury', split='tune', account='Ridgeline Roofing & Solar',
         message=("Subject: Employee injury this morning\n\nHi,\n\nReporting an injury. One of our crew, Tomas Vega, cut his left hand on a circular saw at about 7:50 this morning on a job site in Wheaton. "
                  "His supervisor drove him to the ER at Central DuPage. He needed nine stitches and was sent home. The doctor has him off work for two weeks. "
                  "The saw guard was in place and we have photos and the supervisor's statement.\n\nWhat forms do you need from us?\n\nMiguel Ortega\nSafety Director, Ridgeline Roofing & Solar"),
         is_claim=True, line='Workers Compensation', date=ago(0), loss_type='Bodily Injury', severity={'Medium'}, estimate=None,
         origin='Email', reporter='Miguel Ortega', location=['Wheaton'], keep=['Tomas Vega', 'Central DuPage']),
    dict(id='truck-canopy', split='tune', account='Sagebrush Freight Lines',
         message=("Subject: Truck damage at a customer site\n\nHello,\n\nYesterday afternoon one of our drivers backed a trailer into the loading dock canopy at a customer's warehouse, 4100 W 42nd Pl in Chicago. "
                  "The canopy is bent and one support post is cracked. Their facilities manager says the repair will be about $7,500 and wants our insurance details. "
                  "Our trailer has a crushed rear corner, no estimate on that yet. The driver was not hurt.\n\nPlease open a claim.\n\nLena Fischer\nSagebrush Freight Lines"),
         is_claim=True, line='Commercial Auto', date=ago(1), loss_type='Collision', severity={'Medium'}, estimate=7500,
         origin='Email', reporter='Lena Fischer', location=['4100 W 42nd'], keep=['canopy'], needs_missing=True),
    dict(id='scratched-floors', split='tune', account='Marigold Cafe & Catering',
         message=("Subject: Client says we damaged their floor\n\nHi,\n\nWe catered a party at a client's home in Winnetka on Saturday. The client, Paul Hendry, emailed today to say our crew gouged "
                  "the hardwood floor in the dining room when they rolled the warming cabinets in. He sent a flooring quote for $3,400 and wants us to pay for it. "
                  "My crew lead says they did use the cabinets in that room.\n\nWhat do I do?\n\nRosa Delgado"),
         is_claim=True, line='General Liability', date=last(SAT), loss_type='Liability', severity={'Low'}, estimate=3400,
         origin='Email', reporter='Rosa Delgado', location=['Winnetka'], keep=['Paul Hendry']),
    # Held out: not looked at while tuning.
    dict(id='keyed-car', split='held', account='Abernathy Household',
         message=(f"Hi, this is Grace Abernathy. Someone keyed both sides of the Lexus and slashed a tire while it was parked on the street outside our house on the night of {spoken(ago(4))}. "
                  "Nothing was taken from the car. I reported it to Naperville police, report 26-PD-4471. The dealer body shop quoted $2,750 to repaint both sides and replace the tire."),
         is_claim=True, line='Personal Auto', date=ago(4), loss_type='Vandalism', severity={'Low'}, estimate=2750,
         reporter='Grace Abernathy', location=['Keim', 'outside', 'street'], keep=['26-PD-4471']),
    dict(id='quote-request', split='held', account='Nakamura Household',
         message=("Subject: Second home\n\nHi,\n\nWe are closing on a cottage in Saugatuck, Michigan at the end of next month and need it insured from the closing date. "
                  "Can you send a quote, and tell us whether it can go on our existing policy?\n\nThanks,\nKenji Nakamura"),
         is_claim=False),
    dict(id='vague-accident', split='held', account='Reyes Household',
         message="hi my wife was in an accident today, she is ok but the car is pretty banged up. please call me asap. Daniel",
         is_claim=True, line='Personal Auto', date=ago(0), loss_type='Collision', severity={'Low', 'Medium'}, estimate=None,
         reporter='Daniel Reyes', location=[], needs_missing=True),
    dict(id='add-driver', split='held', account='Okafor Household',
         message=("Hello, our daughter Adaeze just turned 17 and got her license last week. Please add her to the auto policy starting Monday and let us know what it does to the premium. "
                  "Thank you, Chinedu Okafor"),
         is_claim=False),
    dict(id='foot-through-ceiling', split='held', account='Ridgeline Roofing & Solar',
         message=("Call from Dana Kowalski, Ridgeline, 10:05am. While running conduit in the attic at a customer's house in Glen Ellyn on Wednesday, one of the crew stepped off a joist and put his foot through the hallway ceiling. "
                  "He was not hurt. Homeowner is Sheila Watts, she wants it repaired and repainted. Ridgeline's drywall sub quoted $1,400. Dana asks whether to pay it themselves or claim."),
         is_claim=True, line='General Liability', date=last(WED), loss_type='Liability', severity={'Low'}, estimate=1400,
         origin='Phone', reporter='Dana Kowalski', location=['Glen Ellyn'], keep=['Sheila Watts']),
    dict(id='deer-strike', split='held', account='Lindqvist Household',
         message=("Subject: Hit a deer\n\nHi,\n\nI hit a deer on Highway 151 just south of Verona on Sunday evening around 8. I am fine. The front of the Mazda is smashed in, the radiator is leaking "
                  "and it had to be towed to Budd's Auto Body in Verona. They think it will be about $6,300.\n\nErik Lindqvist"),
         is_claim=True, line='Personal Auto', date=last(SUN), loss_type='Collision', severity={'Medium'}, estimate=6300,
         origin='Email', reporter='Erik Lindqvist', location=['151', 'Verona'], keep=["Budd's Auto Body"]),
]
