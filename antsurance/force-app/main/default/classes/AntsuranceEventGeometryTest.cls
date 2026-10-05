@IsTest
private class AntsuranceEventGeometryTest {
    // The geometry works in doubles; these let a test write its coordinates as plain numbers.
    private static Double milesBetween(Decimal latitude1, Decimal longitude1, Decimal latitude2, Decimal longitude2) {
        return AntsuranceEventGeometry.milesBetween(latitude1.doubleValue(), longitude1.doubleValue(), latitude2.doubleValue(), longitude2.doubleValue());
    }

    private static Boolean inside(AntsuranceEventGeometry.Footprint area, Decimal latitude, Decimal longitude) {
        return area.contains(latitude.doubleValue(), longitude.doubleValue());
    }

    private static Double outside(AntsuranceEventGeometry.Footprint area, Decimal latitude, Decimal longitude) {
        return area.milesOutside(latitude.doubleValue(), longitude.doubleValue());
    }

    @IsTest
    static void aDegreeOfLatitudeIsAboutSixtyNineMiles() {
        Double miles = milesBetween(40.0, -90.0, 41.0, -90.0);
        Assert.isTrue(Math.abs(miles - 69.09) < 0.2, 'One degree north is about 69 miles, got ' + miles);
        Assert.isTrue(milesBetween(40.0, -90.0, 40.0, -90.0) < 0.0001, 'A point is no distance from itself');
        Double east = milesBetween(40.0, -90.0, 40.0, -89.0);
        Assert.isTrue(Math.abs(east - 52.93) < 0.3, 'One degree east at 40 north is about 53 miles, got ' + east);
    }

    @IsTest
    static void aCircleHoldsWhatIsWithinItsRadius() {
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(40.0, -90.0, 10, null);
        Assert.isFalse(area.isOutline(), 'A center and a radius make a circle');
        Assert.isTrue(inside(area, 40.1, -90.0), 'About 7 miles north is inside');
        Assert.isFalse(inside(area, 40.2, -90.0), 'About 14 miles north is not');
        Double beyond = outside(area, 40.2, -90.0);
        Assert.isTrue(Math.abs(beyond - 3.82) < 0.2, 'It is about 3.8 miles past the edge, got ' + beyond);
        Assert.isTrue(outside(area, 40.0, -90.0) < 0, 'The center is well inside');
        Assert.isTrue(Math.abs(area.reachMiles() - 10) < 0.0001, 'A circle reaches its radius');
        Assert.isTrue(Math.abs(area.middle()[0] - 40) < 0.0001, 'And its middle is its center');
    }

    @IsTest
    static void aBoxAroundACircleReachesPastItsEdge() {
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(40.0, -90.0, 10, null);
        List<Double> box = area.boundingBox(3);
        Assert.isTrue(box[0] < 39.82 && box[0] > 39.80, 'Thirteen miles south, got ' + box[0]);
        Assert.isTrue(box[1] > 40.18 && box[1] < 40.20, 'Thirteen miles north, got ' + box[1]);
        Assert.isTrue(box[2] < -90.24 && box[3] > -89.76, 'And wider in longitude, where a degree is shorter');
    }

    @IsTest
    static void anOutlineHoldsWhatIsInsideItsCorners() {
        String outline = '40.0,-90.2; 40.2,-90.2; 40.2,-90.0; 40.0,-90.0';
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(null, null, null, outline);
        Assert.isTrue(area.isOutline(), 'Four corners make an outline');
        Assert.isTrue(inside(area, 40.1, -90.1), 'The middle of the square is inside');
        Assert.isFalse(inside(area, 40.3, -90.1), 'North of it is not');
        Assert.isFalse(inside(area, 40.1, -89.9), 'Nor east of it');
        Double beyond = outside(area, 40.3, -90.1);
        Assert.isTrue(Math.abs(beyond - 6.9) < 0.2, 'A tenth of a degree north of the top edge is about 6.9 miles out, got ' + beyond);
        Assert.isTrue(outside(area, 40.1, -90.1) <= 0, 'Inside counts as no distance out');
        Assert.isTrue(Math.abs(area.middle()[0] - 40.1) < 0.0001, 'Its middle is the average of its corners');
        Assert.isTrue(area.reachMiles() > 8 && area.reachMiles() < 10, 'And it reaches to its farthest corner, got ' + area.reachMiles());
        List<Double> box = area.boundingBox(0);
        Assert.isTrue(Math.abs(box[0] - 40) < 0.0001, 'The box starts at the southern corners');
        Assert.isTrue(Math.abs(box[1] - 40.2) < 0.0001, 'And ends at the northern ones');
    }

    @IsTest
    static void anLShapedOutlineLeavesItsNotchOutside() {
        // An L: the top right quarter of the square is cut away.
        String outline = '40.0,-90.2; 40.2,-90.2; 40.2,-90.1; 40.1,-90.1; 40.1,-90.0; 40.0,-90.0';
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(41, -88, 5, outline);
        Assert.isTrue(area.isOutline(), 'An outline wins over a center and a radius');
        Assert.isTrue(inside(area, 40.15, -90.15), 'The upper left arm is inside');
        Assert.isTrue(inside(area, 40.05, -90.05), 'So is the lower right arm');
        Assert.isFalse(inside(area, 40.15, -90.05), 'The notch is outside');
    }

    @IsTest
    static void pointsThatAreNotPointsAreLeftOut() {
        List<List<Double>> points = AntsuranceEventGeometry.parsePoints('40.0,-90.0; not a point; 95,10; 40.1 , -90.1\n40.2,-90.2;;');
        Assert.areEqual(3, points.size(), 'Three pairs are real and in range');
        Assert.isTrue(Math.abs(points[1][0] - 40.1) < 0.0001, 'Spaces around the comma are fine');
        Assert.isTrue(AntsuranceEventGeometry.parsePoints(null).isEmpty(), 'No text, no points');
    }

    @IsTest
    static void anEventWithNeitherACircleNorAnOutlineHasNoArea() {
        Assert.isNull(AntsuranceEventGeometry.footprint(null, -90, 10, null), 'No center');
        Assert.isNull(AntsuranceEventGeometry.footprint(40, -90, 0, null), 'No radius');
        Assert.isNull(AntsuranceEventGeometry.footprint(40, -90, null, '40.0,-90.0; 40.1,-90.1'), 'Two corners are not an outline');
    }
}
