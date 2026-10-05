/**
 * @description The geometry behind the Event response page: how far two points on the map are from
 * each other, and whether a point lies inside the area an event crossed. An area is a circle (a
 * center and a radius in miles) or an outline of corner points.
 */
public inherited sharing class AntsuranceEventGeometry {
    private static final Double EARTH_RADIUS_MILES = 3958.7613;
    private static final Double MILES_PER_DEGREE_OF_LATITUDE = 69.0934;
    /** Keeps the east-west margin finite near the poles. */
    private static final Double SMALLEST_COSINE = 0.1;

    /**
     * @description The area an event crossed.
     */
    public class Footprint {
        public Double centerLatitude;
        public Double centerLongitude;
        public Double radiusMiles;
        /** Corner points as [latitude, longitude] pairs. When there are three or more, they are the area and the radius is ignored. */
        public List<List<Double>> points = new List<List<Double>>();

        /** Whether the area is drawn from corner points instead of a circle. */
        public Boolean isOutline() {
            return points.size() >= 3;
        }

        /**
         * @description Whether a point lies inside the area. A point on the edge counts as inside.
         * @param latitude The point's latitude in decimal degrees
         * @param longitude The point's longitude in decimal degrees
         * @return True when the point is inside
         */
        public Boolean contains(Double latitude, Double longitude) {
            return milesOutside(latitude, longitude) <= 0;
        }

        /**
         * @description How far a point is beyond the edge of the area, in miles. Zero or less means inside.
         * @param latitude The point's latitude in decimal degrees
         * @param longitude The point's longitude in decimal degrees
         * @return Miles past the edge; negative or zero when the point is inside
         */
        public Double milesOutside(Double latitude, Double longitude) {
            if (!isOutline()) {
                return milesBetween(centerLatitude, centerLongitude, latitude, longitude) - radiusMiles;
            }
            if (isInsideOutline(latitude, longitude, points)) {
                return 0;
            }
            Double nearest;
            for (Integer index = 0; index < points.size(); index++) {
                List<Double> startPoint = points[index];
                List<Double> endPoint = points[Math.mod(index + 1, points.size())];
                Double miles = milesToSegment(latitude, longitude, startPoint, endPoint);
                if (nearest == null || miles < nearest) {
                    nearest = miles;
                }
            }
            return nearest;
        }

        /**
         * @description A box around the area, widened by a margin, for a first cut in a query.
         * @param marginMiles How far past the edge the box should reach
         * @return South, north, west and east limits in decimal degrees, in that order
         */
        public List<Double> boundingBox(Double marginMiles) {
            Double south;
            Double north;
            Double west;
            Double east;
            if (isOutline()) {
                for (List<Double> point : points) {
                    south = south == null || point[0] < south ? point[0] : south;
                    north = north == null || point[0] > north ? point[0] : north;
                    west = west == null || point[1] < west ? point[1] : west;
                    east = east == null || point[1] > east ? point[1] : east;
                }
            } else {
                south = centerLatitude;
                north = centerLatitude;
                west = centerLongitude;
                east = centerLongitude;
                marginMiles += radiusMiles;
            }
            Double latitudeMargin = marginMiles / MILES_PER_DEGREE_OF_LATITUDE;
            Double widest = Math.max(Math.abs(south), Math.abs(north));
            Double longitudeMargin = marginMiles / (MILES_PER_DEGREE_OF_LATITUDE * Math.max(SMALLEST_COSINE, Math.cos(widest * Math.PI / 180)));
            return new List<Double>{ south - latitudeMargin, north + latitudeMargin, west - longitudeMargin, east + longitudeMargin };
        }

        /** The middle of the area: the circle's center, or the average of an outline's corners. */
        public List<Double> middle() {
            if (!isOutline()) {
                return new List<Double>{ centerLatitude, centerLongitude };
            }
            Double latitude = 0;
            Double longitude = 0;
            for (List<Double> point : points) {
                latitude += point[0];
                longitude += point[1];
            }
            return new List<Double>{ latitude / points.size(), longitude / points.size() };
        }

        /** How far the area reaches from its middle, in miles: the radius, or the farthest corner. */
        public Double reachMiles() {
            if (!isOutline()) {
                return radiusMiles;
            }
            List<Double> center = middle();
            Double farthest = 0;
            for (List<Double> point : points) {
                farthest = Math.max(farthest, milesBetween(center[0], center[1], point[0], point[1]));
            }
            return farthest;
        }
    }

    /**
     * @description Builds the area from an event's settings.
     * @param centerLatitude Latitude of the center, or null when an outline is given
     * @param centerLongitude Longitude of the center, or null when an outline is given
     * @param radiusMiles Radius in miles, or null when an outline is given
     * @param outline Corner points as text, "latitude,longitude; latitude,longitude; ...", or blank
     * @return The area, or null when the settings describe neither a circle nor an outline
     */
    public static Footprint footprint(Decimal centerLatitude, Decimal centerLongitude, Decimal radiusMiles, String outline) {
        Footprint area = new Footprint();
        area.points = parsePoints(outline);
        if (area.isOutline()) {
            return area;
        }
        area.points = new List<List<Double>>();
        if (centerLatitude == null || centerLongitude == null || radiusMiles == null || radiusMiles <= 0) {
            return null;
        }
        area.centerLatitude = centerLatitude.doubleValue();
        area.centerLongitude = centerLongitude.doubleValue();
        area.radiusMiles = radiusMiles.doubleValue();
        return area;
    }

    /**
     * @description Reads corner points written as "latitude,longitude; latitude,longitude". Pairs that
     * are not two numbers in range are left out.
     * @param text The points as text
     * @return The points as [latitude, longitude] pairs
     */
    public static List<List<Double>> parsePoints(String text) {
        List<List<Double>> points = new List<List<Double>>();
        if (String.isBlank(text)) {
            return points;
        }
        for (String pair : text.split('[;\\n]')) {
            List<String> parts = pair.trim().split('\\s*,\\s*');
            if (parts.size() != 2) {
                continue;
            }
            try {
                Double latitude = Double.valueOf(parts[0].trim());
                Double longitude = Double.valueOf(parts[1].trim());
                if (Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180) {
                    points.add(new List<Double>{ latitude, longitude });
                }
            } catch (TypeException e) {
                continue;
            }
        }
        return points;
    }

    /**
     * @description The distance between two points over the earth's surface (the haversine formula).
     * @param latitude1 First point's latitude in decimal degrees
     * @param longitude1 First point's longitude in decimal degrees
     * @param latitude2 Second point's latitude in decimal degrees
     * @param longitude2 Second point's longitude in decimal degrees
     * @return Miles between the two points
     */
    public static Double milesBetween(Double latitude1, Double longitude1, Double latitude2, Double longitude2) {
        Double toRadians = Math.PI / 180;
        Double latitudeGap = (latitude2 - latitude1) * toRadians;
        Double longitudeGap = (longitude2 - longitude1) * toRadians;
        Double half =
            Math.sin(latitudeGap / 2) * Math.sin(latitudeGap / 2) +
            Math.cos(latitude1 * toRadians) * Math.cos(latitude2 * toRadians) * Math.sin(longitudeGap / 2) * Math.sin(longitudeGap / 2);
        return 2 * EARTH_RADIUS_MILES * Math.asin(Math.min(1, Math.sqrt(half)));
    }

    /**
     * @description Whether a point lies inside an outline, by counting how many edges a line drawn
     * east from the point crosses: an odd count means inside.
     * @param latitude The point's latitude
     * @param longitude The point's longitude
     * @param points The outline's corners as [latitude, longitude] pairs
     * @return True when the point is inside the outline
     */
    public static Boolean isInsideOutline(Double latitude, Double longitude, List<List<Double>> points) {
        Boolean inside = false;
        Integer last = points.size() - 1;
        for (Integer index = 0; index < points.size(); index++) {
            Double thisLatitude = points[index][0];
            Double thisLongitude = points[index][1];
            Double lastLatitude = points[last][0];
            Double lastLongitude = points[last][1];
            Boolean straddles = (thisLatitude > latitude) != (lastLatitude > latitude);
            if (straddles && longitude < (lastLongitude - thisLongitude) * (latitude - thisLatitude) / (lastLatitude - thisLatitude) + thisLongitude) {
                inside = !inside;
            }
            last = index;
        }
        return inside;
    }

    /** Miles from a point to the nearest spot on one edge of an outline, treating the small area as flat. */
    private static Double milesToSegment(Double latitude, Double longitude, List<Double> startPoint, List<Double> endPoint) {
        Double milesPerDegreeOfLongitude = MILES_PER_DEGREE_OF_LATITUDE * Math.cos(latitude * Math.PI / 180);
        Double startX = (startPoint[1] - longitude) * milesPerDegreeOfLongitude;
        Double startY = (startPoint[0] - latitude) * MILES_PER_DEGREE_OF_LATITUDE;
        Double endX = (endPoint[1] - longitude) * milesPerDegreeOfLongitude;
        Double endY = (endPoint[0] - latitude) * MILES_PER_DEGREE_OF_LATITUDE;
        Double alongX = endX - startX;
        Double alongY = endY - startY;
        Double lengthSquared = alongX * alongX + alongY * alongY;
        Double share = 0;
        if (lengthSquared > 0) {
            share = Math.max(0, Math.min(1, -(startX * alongX + startY * alongY) / lengthSquared));
        }
        Double nearestX = startX + share * alongX;
        Double nearestY = startY + share * alongY;
        return Math.sqrt(nearestX * nearestX + nearestY * nearestY);
    }
}
