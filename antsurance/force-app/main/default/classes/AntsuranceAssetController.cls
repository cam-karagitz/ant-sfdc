/**
 * @description Finds a representative photo for an insured vehicle. The photo is of the model, not the
 * customer's own car, and is shown with a link back to where it came from.
 *
 * A model changes shape every few years, so the photo has to be of the right generation: a 2019 Accord
 * beside a picture of the 2023 body reads as the wrong car. For the models in GENERATIONS the photo is one
 * chosen for the model years it covers, a freely licensed file on Wikimedia Commons. Any other vehicle is
 * looked up on Wikipedia's public page summary API, which gives the article's lead picture: usually the
 * newest generation, so right for a recent car and a fair guess for an older one.
 */
public with sharing class AntsuranceAssetController {
    private static final String SUMMARY_ENDPOINT = 'https://en.wikipedia.org/api/rest_v1/page/summary/';
    // Wikimedia asks API clients to say who they are.
    private static final String USER_AGENT = 'AntsuranceDemoCRM/1.0 (Salesforce demo org; insured asset viewer)';
    private static final Integer TIMEOUT_MS = 8000;
    private static final Integer MAX_NAME_LENGTH = 80;
    // Wikimedia serves thumbnails at set widths; this one suits a card.
    private static final String CARD_WIDTH = '/960px-';
    private static final Integer CARD_WIDTH_PX = 960;
    private static final String COMMONS_THUMBNAILS = 'https://thumb.wikimedia.org/wikipedia/commons/thumb/';
    private static final String COMMONS_FILE_PAGE = 'https://commons.wikimedia.org/wiki/File:';
    private static final String WIKIPEDIA_ARTICLE = 'https://en.wikipedia.org/wiki/';

    // A photo for each generation of a model: "Make Model|first model year|last model year|file on Wikimedia Commons".
    // Each file was looked at: the body style sold in those model years, seen from the front, in landscape,
    // at least 1,200 pixels wide, and under a free license (its Commons page names the author and the license).
    // To add a model, find a file whose title names the model year at commons.wikimedia.org and add a row.
    @TestVisible
    private static final List<String> GENERATIONS = new List<String>{
        'Audi Q5|2018|2020|2018 Audi Q5 S Line TDi Quattro S-A 2.0 Front.jpg',
        'BMW X5|2019|2023|2020 BMW X5 xDrive 40i, front left.jpg',
        'Buick LaCrosse|2017|2019|2018 Buick LaCrosse Essence 2.5L, front 8.24.19.jpg',
        'Chevrolet Equinox|2022|2024|2022 Chevrolet Equinox LT (facelift), front 6.2.22.jpg',
        'Chevrolet Malibu|2016|2018|2017 Chevrolet Malibu LT front 3.27.18.jpg',
        'Ford Escape|2013|2016|2014 Ford Escape Titanium in Sterling Gray Metallic, front right, 04-26-2025.jpg',
        'Ford Escape|2017|2019|2018 Ford Escape Titanium 2.0L front 5.19.19.jpg',
        'Ford Expedition|2007|2014|2012 Ford Expedition -- NHTSA.jpg',
        'Ford Explorer|2020|2024|2020 Ford Explorer XLT, front 9.7.20.jpg',
        'Ford F-150|2021|2023|2021 Ford F-150 SuperCrew, front 4.28.21.jpg',
        'Ford Maverick|2022|2024|2022 Ford Maverick XL, front 5.4.22.jpg',
        'GMC Sierra|2016|2018|2018 GMC Sierra 1500 SLT, front 5.19.20.jpg',
        'Honda Accord|2018|2022|2018 Honda Accord front 3.29.18.jpg',
        'Honda Accord|2023|2026|2024 Honda Accord EX in Platinum White Pearl, front right, 2024-10-07.jpg',
        'Honda Civic|2019|2021|2019 Honda Civic LX sedan, front left, 05-07-2024.jpg',
        'Honda CR-V|2023|2026|2023 Honda CR-V EX AWD in Lunar Silver Metallic, front left.jpg',
        'Honda Fit|2015|2020|2015 Honda Fit LX in Crystal Black Peal, Front Right, 05-20-2023.jpg',
        'Honda Odyssey|2018|2020|2018 Honda Odyssey EX-L 3.5L, front 8.23.19.jpg',
        'Hyundai Elantra|2021|2023|2021 Hyundai Elantra Essential, Front Left, 11-29-2020.jpg',
        'Hyundai Kona|2018|2021|2020 Hyundai Kona SEL, Front Left, 07-20-2021.jpg',
        'Hyundai Tucson|2022|2024|2022 Hyundai Tucson SEL, front 5.2.22.jpg',
        'Jeep Grand Cherokee|2017|2021|2021 Jeep Grand Cherokee Laredo.jpg',
        'Kia Sportage|2023|2025|2023 Kia Sportage SX-Prestige in Wolf Gray, front left.jpg',
        'Lexus ES|2019|2021|2019 Lexus ES 350, front 11.9.19.jpg',
        'Lexus RX|2023|2026|2023 Lexus RX 350 Premium Plus in Matador Red Mica, front left (cropped).jpg',
        'Mazda CX-5|2017|2021|2019 Mazda CX-5 SE-L NAV+ Diesel 2.2 Front.jpg',
        'Mazda3|2014|2018|2018 Mazda3 Sport, Front Left, 10-16-2020.jpg',
        'Mazda3|2019|2025|2023 Mazda3 Sport GS in Platinum Quartz Metallic, Front Left, 10-09-2023.jpg',
        'Nissan Leaf|2018|2022|2019 Nissan Leaf N-Connecta.jpg',
        'Nissan Rogue|2017|2020|Nissan Rogue (T32) facelift (United States).jpg',
        'Subaru Forester|2022|2024|2022 Subaru Forester (SK) IMG 9937.jpg',
        'Subaru Outback|2020|2022|2020 Subaru Outback AWD, front.jpg',
        'Tesla Model 3|2017|2023|2020 Tesla Model 3.jpg',
        'Tesla Model Y|2020|2024|2020 Tesla Model Y, front 5.16.21.jpg',
        'Toyota Camry|2021|2024|2022 Toyota Camry SE Standard Package in Celestial Silver Metallic, Front Left, 08-06-2022.jpg',
        'Toyota Corolla|2014|2016|2015 Toyota Corolla LE front 5.6.18.jpg',
        'Toyota Highlander|2017|2019|2019 Toyota Highlander SE in Blizzard Pearl, front left, 07-02-2026.jpg',
        'Toyota RAV4|2019|2025|2021 Toyota RAV4 XLE AWD, front right.jpg',
        'Toyota Sienna|2021|2025|2021 Toyota Sienna LE, front 7.2.22.jpg',
        'Toyota Tacoma|2016|2023|2016 Toyota Tacoma TRD Sport Access Cab 3.5L front 5.14.19.jpg',
        'Volkswagen Golf|2018|2021|2019 Volkswagen Golf in Deep Black Pearl, Front Left, 01-30-2022.jpg',
        'Volkswagen Jetta|2022|2024|2022 Volkswagen Jetta VII 1X7A0154.jpg',
        'Volvo XC60|2018|2021|2019 Volvo XC60 T8 Inscription Hybrid 2.0.jpg'
    };

    /**
     * @description A photo and where it came from.
     */
    public class Photo {
        @AuraEnabled
        public String imageUrl;
        /** Where the photo came from, for attribution: the file's page on Wikimedia Commons, or the Wikipedia article. */
        @AuraEnabled
        public String pageUrl;
        /** What to call that source in the credit line. */
        @AuraEnabled
        public String source;
        /** The Wikipedia article about the model, for further reading. */
        @AuraEnabled
        public String articleUrl;
        @AuraEnabled
        public String title;
    }

    /**
     * @description Looks up a photo for a vehicle described like "2022 Toyota RAV4 XLE".
     * @param vehicle The asset name: an optional model year, the make, then the model
     * @return The photo, or null when nothing suitable is found or Wikipedia cannot be reached
     */
    @AuraEnabled(cacheable=true)
    public static Photo getVehiclePhoto(String vehicle) {
        Photo chosen = generationPhoto(vehicle);
        if (chosen != null) {
            return chosen;
        }
        for (String title : candidateTitles(vehicle)) {
            Photo photo = fetch(title);
            if (photo != null) {
                return photo;
            }
        }
        return null;
    }

    /** The photo chosen for this model in this model year, or null when the model or the year is not in GENERATIONS. */
    @TestVisible
    private static Photo generationPhoto(String vehicle) {
        if (String.isBlank(vehicle) || !Pattern.matches('^\\s*(19|20)\\d{2}\\s.*', vehicle)) {
            return null;
        }
        Integer modelYear = Integer.valueOf(vehicle.trim().left(4));
        List<String> titles = candidateTitles(vehicle);
        String named = titles.isEmpty() ? '' : titles[0].toLowerCase();
        for (String row : GENERATIONS) {
            List<String> parts = row.split('\\|');
            String model = parts[0].toLowerCase();
            Boolean isModel = named == model || named.startsWith(model + ' ');
            if (isModel && modelYear >= Integer.valueOf(parts[1]) && modelYear <= Integer.valueOf(parts[2])) {
                Photo photo = new Photo();
                photo.title = parts[1] + ' to ' + parts[2] + ' ' + parts[0];
                photo.imageUrl = commonsThumbnail(parts[3]);
                photo.pageUrl = COMMONS_FILE_PAGE + encoded(parts[3]);
                photo.source = 'Wikimedia Commons';
                photo.articleUrl = WIKIPEDIA_ARTICLE + parts[0].replace(' ', '_');
                return photo;
            }
        }
        return null;
    }

    /**
     * A Commons file at card width. Wikimedia files a picture under the first one and two characters of
     * the MD5 digest of its name, with underscores for spaces.
     */
    @TestVisible
    private static String commonsThumbnail(String fileName) {
        String digest = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(fileName.replace(' ', '_'))));
        String name = encoded(fileName);
        return COMMONS_THUMBNAILS + digest.left(1) + '/' + digest.left(2) + '/' + name + CARD_WIDTH + name;
    }

    private static String encoded(String fileName) {
        return EncodingUtil.urlEncode(fileName.replace(' ', '_'), 'UTF-8');
    }

    /** Article titles to try, most specific first: "Toyota RAV4 XLE", then "Toyota RAV4". */
    @TestVisible
    private static List<String> candidateTitles(String vehicle) {
        List<String> titles = new List<String>();
        if (String.isBlank(vehicle)) {
            return titles;
        }
        // Keep letters, digits, spaces and hyphens only, and drop a leading model year.
        String cleaned = vehicle.left(MAX_NAME_LENGTH).replaceAll('[^A-Za-z0-9 \\-]', ' ').trim().replaceAll('^(19|20)\\d{2}\\s+', '').replaceAll('\\s+', ' ');
        List<String> words = cleaned.split(' ');
        if (String.isBlank(cleaned) || words.isEmpty()) {
            return titles;
        }
        titles.add(cleaned);
        if (words.size() > 2) {
            titles.add(words[0] + ' ' + words[1]);
        }
        return titles;
    }

    private static Photo fetch(String title) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(SUMMARY_ENDPOINT + EncodingUtil.urlEncode(title.replace(' ', '_'), 'UTF-8'));
        request.setMethod('GET');
        request.setHeader('User-Agent', USER_AGENT);
        request.setHeader('Accept', 'application/json');
        request.setTimeout(TIMEOUT_MS);
        try {
            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() != 200) {
                return null;
            }
            Map<String, Object> page = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            Map<String, Object> thumbnail = (Map<String, Object>) page.get('thumbnail');
            // A disambiguation page or an article without a picture is no use here.
            if (page.get('type') != 'standard' || thumbnail == null) {
                return null;
            }
            Photo photo = new Photo();
            photo.title = (String) page.get('title');
            photo.imageUrl = cardSized((String) thumbnail.get('source'), (Map<String, Object>) page.get('originalimage'));
            Map<String, Object> urls = (Map<String, Object>) page.get('content_urls');
            Map<String, Object> desktop = urls == null ? null : (Map<String, Object>) urls.get('desktop');
            photo.pageUrl = desktop == null ? null : (String) desktop.get('page');
            photo.source = 'Wikipedia';
            photo.articleUrl = photo.pageUrl;
            return photo;
        } catch (Exception e) {
            // A photo is a nicety: without one the viewer shows a placeholder.
            return null;
        }
    }

    /** The thumbnail at card width when the original is large enough, otherwise as given. */
    private static String cardSized(String thumbnailUrl, Map<String, Object> original) {
        Integer originalWidth = original == null ? 0 : (Integer) original.get('width');
        return originalWidth >= CARD_WIDTH_PX ? thumbnailUrl.replaceAll('/\\d+px-', CARD_WIDTH) : thumbnailUrl;
    }
}
