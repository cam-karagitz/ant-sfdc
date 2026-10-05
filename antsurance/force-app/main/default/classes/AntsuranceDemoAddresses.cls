/**
 * @description The second address set for the demo households: invented street names, so no sample
 * customer sits at a real home. AntsuranceDemoData asks here for each household's street. With the switch
 * off it gets back the street it passed in; with it on, the invented one for that household.
 * Town, state and postal code stay as they are, so maps still open on the right town.
 */
public inherited sharing class AntsuranceDemoAddresses {
    /** Turn on before seeding to place every household at an invented address. */
    public static Boolean useSample = false;

    // household key => invented street
    @TestVisible
    private static final Map<String, String> SAMPLE_STREETS = new Map<String, String>{
        'reyes' => '151 Quillfeather Ave',
        'okafor' => '288 Marrowgate Ave',
        'lindqvist' => '425 Thistlewick Ave Apt 603',
        'nakamura' => '562 Pennyharbor Ave',
        'castellano' => '699 Oakenmere Blvd',
        'abernathy' => '836 Larkmantle Rd',
        'dubois' => '973 Fennelmoor Ave Apt 3N',
        'whitfield' => '230 Wrenhollow Rd',
        'petrovic' => '367 Ambergate Ave',
        'haddad' => '504 Bramblecote Ln',
        'alvarez' => '641 Cinderbrook St',
        'bianchi' => '778 Dapplewood Ave',
        'chen' => '915 Elderquay St',
        'dlamini' => '172 Foxlantern Ave Apt 803',
        'eriksen' => '309 Glimmerfield Ave',
        'fitzgerald' => '446 Hazelmoor Ave',
        'goldberg' => '583 Ironwillow Ln',
        'hosseini' => '720 Juniperwick Ave Apt 302',
        'ivanov' => '857 Kestrelmere St',
        'jankowski' => '114 Lanternrow St',
        'kaplan' => '251 Mossbarrow Ave Apt 301',
        'larsen' => '388 Otterbeck Dr',
        'mbeki' => '525 Pipersedge Ave',
        'nguyen' => '662 Quarrywren Ct',
        'ortiz' => '799 Russetdown St Apt 5B',
        'park' => '936 Sablebrook Ln',
        'quinn' => '193 Tanglewick Ave',
        'rahman' => '330 Umberfold Ave',
        'schmidt' => '467 Velvetmere Ave',
        'takahashi' => '604 Willowquill St Apt 1107',
        'adeyemi' => '741 Yarrowgate Ct',
        'gupta' => '878 Zephyrholt Dr',
        'castro' => '135 Applemantle Ln',
        'delgado' => '272 Birchlantern Ave Apt 203',
        'jovanovic' => '409 Cobblewren Ave',
        'engel' => '546 Dovecotter Ave',
        'novak' => '683 Emberquay Ave Apt 401',
        'farouk' => '820 Fernbarrow Ln',
        'hoang' => '957 Goldenwick St Apt 107',
        'ibrahim' => '214 Heronfold St',
        'kowalczyk' => '351 Inkwellow Ave',
        'lombardi' => '488 Jasperholt Ave',
        'okonjo' => '625 Kindlemoor Ln',
        'quist' => '762 Lindenquay Ave',
        'cohen' => '899 Merrowfield St'
    };

    /**
     * @description The street to store for a household.
     * @param key The household's key in the seed
     * @param street The street the seed has for it
     * @return The invented street when the switch is on and the household has one, otherwise the street given
     */
    public static String street(String key, String street) {
        if (!useSample || street == null) {
            return street;
        }
        String sample = SAMPLE_STREETS.get(key);
        return sample == null ? street : sample;
    }
}
