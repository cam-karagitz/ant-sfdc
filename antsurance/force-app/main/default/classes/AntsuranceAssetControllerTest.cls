@IsTest
private class AntsuranceAssetControllerTest {
    private static final String ARTICLE =
        '{"type":"standard","title":"Rivian R1T",' +
        '"thumbnail":{"source":"https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/R1T.jpg/330px-R1T.jpg","width":330,"height":186},' +
        '"originalimage":{"source":"https://upload.wikimedia.org/wikipedia/commons/a/ab/R1T.jpg","width":4032,"height":2268},' +
        '"content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Rivian_R1T"}}}';

    /** Answers by article title and records what was asked for. */
    private class WikipediaMock implements HttpCalloutMock {
        private final Map<String, String> bodiesByTitle;
        public List<HttpRequest> requests = new List<HttpRequest>();

        WikipediaMock(Map<String, String> bodiesByTitle) {
            this.bodiesByTitle = bodiesByTitle;
        }

        public HttpResponse respond(HttpRequest request) {
            requests.add(request);
            String title = request.getEndpoint().substringAfterLast('/');
            HttpResponse response = new HttpResponse();
            response.setStatusCode(bodiesByTitle.containsKey(title) ? 200 : 404);
            response.setBody(bodiesByTitle.containsKey(title) ? bodiesByTitle.get(title) : '{}');
            return response;
        }
    }

    @IsTest
    static void aModelThatIsNotInTheTableIsLookedUpWithoutItsYear() {
        WikipediaMock mock = new WikipediaMock(new Map<String, String>{ 'Rivian_R1T' => ARTICLE });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAssetController.Photo photo = AntsuranceAssetController.getVehiclePhoto('2022 Rivian R1T');
        Test.stopTest();

        Assert.areEqual('Rivian R1T', photo.title, 'Returns the article title');
        Assert.areEqual('https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/R1T.jpg/960px-R1T.jpg', photo.imageUrl, 'Asks for a card-sized thumbnail');
        Assert.areEqual('https://en.wikipedia.org/wiki/Rivian_R1T', photo.pageUrl, 'Links back to the article');
        Assert.areEqual('Wikipedia', photo.source, 'And credits it');
        Assert.areEqual(photo.pageUrl, photo.articleUrl, 'The article is also where to read about the model');
        Assert.isTrue(mock.requests[0].getEndpoint().endsWith('/page/summary/Rivian_R1T'), 'The model year is left out of the lookup');
        Assert.isTrue(mock.requests[0].getHeader('User-Agent').startsWith('AntsuranceDemoCRM'), 'Says who is asking');
    }

    @IsTest
    static void fallsBackFromTheTrimToTheModel() {
        WikipediaMock mock = new WikipediaMock(new Map<String, String>{ 'Acura_TLX' => ARTICLE.replace('4032', '640') });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAssetController.Photo photo = AntsuranceAssetController.getVehiclePhoto('2019 Acura TLX A-Spec');
        Test.stopTest();

        Assert.areEqual(2, mock.requests.size(), 'Tries the full name, then make and model');
        Assert.isTrue(photo.imageUrl.contains('/330px-'), 'A small original keeps the thumbnail as given');
    }

    @IsTest
    static void returnsNothingWhenThereIsNoUsablePhoto() {
        Test.setMock(
            HttpCalloutMock.class,
            new WikipediaMock(new Map<String, String>{ 'Mystery_Car' => '{"type":"disambiguation","title":"Mystery Car"}', 'Plain_Page' => '{"type":"standard","title":"Plain Page"}' })
        );

        Test.startTest();
        AntsuranceAssetController.Photo ambiguous = AntsuranceAssetController.getVehiclePhoto('Mystery Car');
        AntsuranceAssetController.Photo noPicture = AntsuranceAssetController.getVehiclePhoto('Plain Page');
        AntsuranceAssetController.Photo unknown = AntsuranceAssetController.getVehiclePhoto('2020 Nothing Here');
        AntsuranceAssetController.Photo blank = AntsuranceAssetController.getVehiclePhoto('  ');
        Test.stopTest();

        Assert.isNull(ambiguous, 'A disambiguation page is not a photo');
        Assert.isNull(noPicture, 'An article without a picture is skipped');
        Assert.isNull(unknown, 'An unknown vehicle has no photo');
        Assert.isNull(blank, 'A blank name makes no request');
    }

    @IsTest
    static void aModelInTheTableGetsThePhotoOfItsOwnGeneration() {
        WikipediaMock mock = new WikipediaMock(new Map<String, String>());
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAssetController.Photo tenth = AntsuranceAssetController.getVehiclePhoto('2019 Honda Accord');
        AntsuranceAssetController.Photo eleventh = AntsuranceAssetController.getVehiclePhoto('2024 Honda Accord');
        AntsuranceAssetController.Photo withTrim = AntsuranceAssetController.getVehiclePhoto('2019 Honda Accord Sport');
        AntsuranceAssetController.Photo punctuated = AntsuranceAssetController.getVehiclePhoto('2020 Nissan Rogue');
        AntsuranceAssetController.Photo oneWord = AntsuranceAssetController.getVehiclePhoto('2017 Mazda3');
        Test.stopTest();

        Assert.areEqual(0, mock.requests.size(), 'A model in the table needs no lookup');
        // The address Wikimedia itself gives for this file at this width.
        Assert.areEqual('https://thumb.wikimedia.org/wikipedia/commons/thumb/6/68/2018_Honda_Accord_front_3.29.18.jpg/960px-2018_Honda_Accord_front_3.29.18.jpg', tenth.imageUrl, 'A 2019 Accord shows the body sold from 2018 to 2022');
        Assert.areEqual('https://commons.wikimedia.org/wiki/File:2018_Honda_Accord_front_3.29.18.jpg', tenth.pageUrl, 'Credited to the file\'s own page, which names its author and license');
        Assert.areEqual('Wikimedia Commons', tenth.source, 'And says where that is');
        Assert.areEqual('https://en.wikipedia.org/wiki/Honda_Accord', tenth.articleUrl, 'The article about the model is a separate link');
        Assert.areEqual('2018 to 2022 Honda Accord', tenth.title, 'Named for the years the photo stands for');
        Assert.areNotEqual(tenth.imageUrl, eleventh.imageUrl, 'A 2024 Accord shows the later body');
        Assert.areEqual(tenth.imageUrl, withTrim.imageUrl, 'A trim after the model changes nothing');
        Assert.areEqual(
            'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/57/Nissan_Rogue_%28T32%29_facelift_%28United_States%29.jpg/960px-Nissan_Rogue_%28T32%29_facelift_%28United_States%29.jpg',
            punctuated.imageUrl,
            'Brackets in a file name are encoded the way Wikimedia does it'
        );
        Assert.isTrue(oneWord.imageUrl.contains('2018_Mazda3_Sport'), 'A one-word model is found: ' + oneWord.imageUrl);
    }

    @IsTest
    static void aModelYearOutsideTheTableFallsBackToTheLookup() {
        WikipediaMock mock = new WikipediaMock(new Map<String, String>{ 'Honda_Accord' => ARTICLE });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceAssetController.Photo older = AntsuranceAssetController.getVehiclePhoto('2009 Honda Accord');
        AntsuranceAssetController.Photo noYear = AntsuranceAssetController.getVehiclePhoto('Honda Accord');
        Test.stopTest();

        Assert.areEqual('Wikipedia', older.source, 'A generation the table does not hold is looked up');
        Assert.areEqual('Wikipedia', noYear.source, 'And so is a vehicle named without its year');
        Assert.isNull(AntsuranceAssetController.generationPhoto('2019 Honda Accordion'), 'A longer word that starts the same is another model');
    }

    @IsTest
    static void everyRowOfTheTableIsWellFormed() {
        Set<String> seen = new Set<String>();
        for (String row : AntsuranceAssetController.GENERATIONS) {
            List<String> parts = row.split('\\|');
            Assert.areEqual(4, parts.size(), 'Model, first year, last year, file: ' + row);
            Integer first = Integer.valueOf(parts[1]);
            Integer last = Integer.valueOf(parts[2]);
            Assert.isTrue(first <= last && first > 1980 && last < 2040, 'Years in order: ' + row);
            Assert.isTrue(parts[3].endsWith('.jpg'), 'A photograph: ' + row);
            // Two rows for one model must not claim the same year.
            for (Integer year = first; year <= last; year++) {
                Assert.isTrue(seen.add(parts[0] + ' ' + year), 'One photo for ' + parts[0] + ' in ' + year);
            }
            Assert.isNotNull(AntsuranceAssetController.generationPhoto(first + ' ' + parts[0]), 'Found by its own name: ' + row);
        }
    }

    @IsTest
    static void namesAreCleanedBeforeLookup() {
        Assert.areEqual(new List<String>{ 'Ford F-150 Lariat', 'Ford F-150' }, AntsuranceAssetController.candidateTitles('2021 Ford F-150 Lariat'), 'Keeps hyphens, drops the year');
        Assert.areEqual(new List<String>{ 'Mazda3' }, AntsuranceAssetController.candidateTitles('2017 Mazda3'), 'A one-word model has one candidate');
        Assert.areEqual(new List<String>{ 'Kia Telluride' }, AntsuranceAssetController.candidateTitles('Kia/Telluride?'), 'Other punctuation is removed');
    }
}
