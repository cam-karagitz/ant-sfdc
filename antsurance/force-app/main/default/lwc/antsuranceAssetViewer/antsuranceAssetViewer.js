import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';
import NAME from '@salesforce/schema/Policy_Asset__c.Name';
import TYPE from '@salesforce/schema/Policy_Asset__c.Asset_Type__c';
import IDENTIFIER from '@salesforce/schema/Policy_Asset__c.Identifier__c';
import MODEL_YEAR from '@salesforce/schema/Policy_Asset__c.Model_Year__c';
import LOCATION from '@salesforce/schema/Policy_Asset__c.Location__c';
import LATITUDE from '@salesforce/schema/Policy_Asset__c.Latitude__c';
import LONGITUDE from '@salesforce/schema/Policy_Asset__c.Longitude__c';
import USE from '@salesforce/schema/Policy_Asset__c.Use__c';
import DETAILS from '@salesforce/schema/Policy_Asset__c.Details__c';
import VALUE from '@salesforce/schema/Policy_Asset__c.Insured_Value__c';
import LIENHOLDER from '@salesforce/schema/Policy_Asset__c.Lienholder__c';
import POLICY_ID from '@salesforce/schema/Policy_Asset__c.Policy__c';
import POLICY_NAME from '@salesforce/schema/Policy_Asset__c.Policy__r.Name';
import POLICY_LINE from '@salesforce/schema/Policy_Asset__c.Policy__r.Line_of_Business__c';
import HOLDER_ID from '@salesforce/schema/Policy_Asset__c.Policy__r.Account__c';
import HOLDER_NAME from '@salesforce/schema/Policy_Asset__c.Policy__r.Account__r.Name';
import getVehiclePhoto from '@salesforce/apex/AntsuranceAssetController.getVehiclePhoto';
import { loadBrandFonts } from 'c/antsuranceFonts';
import { assetIcon } from 'c/antsuranceIcons';

const FIELDS = [NAME, TYPE, POLICY_ID];
// Asset types that are someone's home, which the property sites list by address.
const HOME_TYPES = ['Dwelling', 'Rented Residence'];
// Street level on the web map's zoom scale, and the size of one map tile in pixels.
const MAP_ZOOM = 16;
const TILE_SIZE = 256;
// Tiles drawn either side of the one the asset is on: 5 across and 3 down cover the widest card.
const TILE_COLUMNS_EACH_SIDE = 2;
const TILE_ROWS_EACH_SIDE = 1;
// The coverage whose limit pays for each kind of property, by the coverage's name. A vehicle is settled
// at actual cash value with no limit amount, so it has nothing to compare.
const COVERAGE_FOR = {
    Dwelling: 'dwelling',
    'Commercial Building': 'building',
    'Business Property': 'business personal property',
    'Rented Residence': 'personal property'
};
const COVERAGE_FIELDS = ['Policy_Coverage__c.Name', 'Policy_Coverage__c.Limit_Amount__c'];
// Below this share of the value, most property policies pay a partial loss in proportion (coinsurance).
const FULL_PAYMENT_FROM = 80;
const OPTIONAL_FIELDS = [IDENTIFIER, MODEL_YEAR, LOCATION, LATITUDE, LONGITUDE, USE, DETAILS, VALUE, LIENHOLDER, POLICY_NAME, POLICY_LINE, HOLDER_ID, HOLDER_NAME];

/**
 * Shows what a policy insures: for a vehicle, a photo of the model as it was built in that model year;
 * for a home or building, a street map. Beside it, the facts that matter and links out to look the asset up.
 */
export default class AntsuranceAssetViewer extends NavigationMixin(LightningElement) {
    @api recordId;
    asset;
    photo;
    errorMessage;
    // The policy's coverages, read only for property that has a limit to compare with its value.
    coverages;

    connectedCallback() {
        loadBrandFonts(this);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS, optionalFields: OPTIONAL_FIELDS })
    wiredAsset({ data, error }) {
        if (data) {
            const insuredValue = getFieldValue(data, VALUE);
            this.errorMessage = undefined;
            this.asset = {
                name: getFieldValue(data, NAME),
                type: getFieldValue(data, TYPE) ?? 'Asset',
                identifier: getFieldValue(data, IDENTIFIER),
                modelYear: getFieldValue(data, MODEL_YEAR),
                location: getFieldValue(data, LOCATION),
                latitude: getFieldValue(data, LATITUDE),
                longitude: getFieldValue(data, LONGITUDE),
                use: getFieldValue(data, USE),
                details: getFieldValue(data, DETAILS),
                insuredAmount: insuredValue === null || insuredValue === undefined ? undefined : Number(insuredValue),
                insuredValue:
                    insuredValue === null || insuredValue === undefined
                        ? undefined
                        : new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(insuredValue),
                lienholder: getFieldValue(data, LIENHOLDER),
                policyId: getFieldValue(data, POLICY_ID),
                policyName: getFieldValue(data, POLICY_NAME),
                policyLine: getFieldValue(data, POLICY_LINE),
                holderId: getFieldValue(data, HOLDER_ID),
                holderName: getFieldValue(data, HOLDER_NAME)
            };
        } else if (error) {
            this.asset = undefined;
            this.errorMessage = error.body?.message ?? 'This asset could not be loaded.';
        }
    }

    /** The policy to read coverages from: only for property with a value and a coverage that pays for it. */
    get policyToCompare() {
        return this.asset?.insuredAmount > 0 && COVERAGE_FOR[this.asset.type] ? this.asset.policyId : undefined;
    }

    @wire(getRelatedListRecords, { parentRecordId: '$policyToCompare', relatedListId: 'Coverages__r', fields: COVERAGE_FIELDS, pageSize: 50 })
    wiredCoverages({ data }) {
        this.coverages = data ? data.records : undefined;
    }

    /**
     * How the limit that pays for this property compares with its insured value. It is shown only
     * when both numbers exist: a home insured for its full value, or one that is under-insured.
     */
    get toValue() {
        const wanted = COVERAGE_FOR[this.asset?.type];
        const coverage = this.coverages?.find((record) => String(record.fields.Name.value).trim().toLowerCase() === wanted);
        const limit = Number(coverage?.fields.Limit_Amount__c.value ?? 0);
        const value = this.asset?.insuredAmount;
        if (!coverage || !(limit > 0) || !(value > 0)) {
            return undefined;
        }
        const money = new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 });
        const percent = Math.round((limit / value) * 100);
        const name = coverage.fields.Name.value;
        let tone = 'full';
        let text = `The ${name} limit of ${money.format(limit)} covers the full insured value.`;
        if (percent > 100) {
            text = `The ${name} limit of ${money.format(limit)} is above the ${money.format(value)} insured value.`;
        } else if (percent < FULL_PAYMENT_FROM) {
            tone = 'short';
            text = `The ${name} limit of ${money.format(limit)} leaves ${money.format(value - limit)} of the value uninsured. Below ${FULL_PAYMENT_FROM}%, a partial loss may not be paid in full.`;
        } else if (percent < 100) {
            tone = 'near';
            text = `The ${name} limit of ${money.format(limit)} leaves ${money.format(value - limit)} of the value uninsured on a total loss.`;
        }
        return {
            percent: `${percent}%`,
            text,
            label: `Insured to ${percent}% of value`,
            className: `c-value c-value_${tone}`,
            fillStyle: `width: ${Math.min(percent, 100)}%`,
            markStyle: `left: ${FULL_PAYMENT_FROM}%`
        };
    }

    get typeIconName() {
        return assetIcon(this.asset?.type).name;
    }

    get isVehicle() {
        return this.asset?.type === 'Vehicle';
    }

    // Only vehicles are looked up; the wire stays idle for everything else.
    get vehicleName() {
        return this.isVehicle ? this.asset.name : undefined;
    }

    @wire(getVehiclePhoto, { vehicle: '$vehicleName' })
    wiredPhoto({ data }) {
        this.photo = data ?? undefined;
    }

    /** The frame takes a photograph's shape when it holds one; a map or a placeholder keeps the steady frame. */
    get mediaClass() {
        return this.isVehicle && this.photo ? 'c-asset__media c-asset__media_photo' : 'c-asset__media';
    }

    get photoAlt() {
        return `${this.photo.title}, a photo of the model`;
    }

    get placeholderText() {
        return 'No photo found for this model';
    }

    get hasCoordinates() {
        const { latitude, longitude } = this.asset;
        return latitude !== null && latitude !== undefined && longitude !== null && longitude !== undefined;
    }

    get hasMap() {
        return this.hasCoordinates;
    }

    /**
     * Where the asset sits on the web map's tile grid at MAP_ZOOM, as fractional tile numbers.
     * This is the standard "slippy map" formula; nothing is geocoded.
     */
    get tilePosition() {
        const { latitude, longitude } = this.asset;
        const tilesAcross = 2 ** MAP_ZOOM;
        const latitudeRadians = (latitude * Math.PI) / 180;
        return {
            x: ((longitude + 180) / 360) * tilesAcross,
            y: ((1 - Math.log(Math.tan(latitudeRadians) + 1 / Math.cos(latitudeRadians)) / Math.PI) / 2) * tilesAcross
        };
    }

    /** A block of tiles around the asset, wide enough to fill the frame at any card width. */
    get mapTiles() {
        const { x, y } = this.tilePosition;
        const tiles = [];
        for (let row = -TILE_ROWS_EACH_SIDE; row <= TILE_ROWS_EACH_SIDE; row++) {
            for (let column = -TILE_COLUMNS_EACH_SIDE; column <= TILE_COLUMNS_EACH_SIDE; column++) {
                const tileX = Math.floor(x) + column;
                const tileY = Math.floor(y) + row;
                tiles.push({
                    key: `${tileX}-${tileY}`,
                    url: `https://tile.openstreetmap.org/${MAP_ZOOM}/${tileX}/${tileY}.png`,
                    style: `left: ${(column + TILE_COLUMNS_EACH_SIDE) * TILE_SIZE}px; top: ${(row + TILE_ROWS_EACH_SIDE) * TILE_SIZE}px`
                });
            }
        }
        return tiles;
    }

    /** Slides the block of tiles so the asset's own spot sits under the pin at the center of the frame. */
    get mapStyle() {
        const { x, y } = this.tilePosition;
        const left = (x - Math.floor(x) + TILE_COLUMNS_EACH_SIDE) * TILE_SIZE;
        const top = (y - Math.floor(y) + TILE_ROWS_EACH_SIDE) * TILE_SIZE;
        return `left: calc(50% - ${left.toFixed(0)}px); top: calc(50% - ${top.toFixed(0)}px)`;
    }

    get mapLabel() {
        return `Map of the area around ${this.asset.location ?? this.asset.name}`;
    }

    /** A home is named after its address, so its location line would say the same thing twice. */
    get nameRepeatsLocation() {
        const { name, location } = this.asset;
        return Boolean(name && location) && location.toLowerCase().startsWith(name.toLowerCase());
    }

    /** The fuller of the two when they repeat: the address with its ZIP code. */
    get headline() {
        return this.nameRepeatsLocation ? this.asset.location : this.asset.name;
    }

    get showLocation() {
        return Boolean(this.asset.location) && !this.nameRepeatsLocation;
    }

    get locationLabel() {
        return this.isVehicle ? `Garaged at ${this.asset.location}` : this.asset.location;
    }

    get facts() {
        const { identifier, modelYear, insuredValue, use, lienholder } = this.asset;
        return [
            { label: this.isVehicle ? 'VIN' : 'Reference', value: identifier, valueClass: 'c-asset__mono' },
            { label: this.isVehicle ? 'Model year' : 'Year built', value: modelYear },
            { label: 'Insured value', value: insuredValue },
            { label: 'Use', value: use },
            { label: this.isVehicle ? 'Lienholder' : 'Mortgagee', value: lienholder }
        ].filter((fact) => fact.value);
    }

    /** Places to look the asset up. Each opens in a new browser tab. */
    get links() {
        const links = [];
        const { name, modelYear, location } = this.asset;
        if (this.isVehicle) {
            const [make, ...model] = name.replace(/^(19|20)\d{2}\s+/, '').split(/\s+/);
            if (modelYear && make && model.length) {
                links.push({
                    label: 'Safety and recalls',
                    url: `https://www.nhtsa.gov/vehicle/${encodeURIComponent(modelYear)}/${encodeURIComponent(make.toUpperCase())}/${encodeURIComponent(model[0].toUpperCase())}`
                });
            }
            // The article about the model. A photo chosen for the model year is credited to its own page, not the article.
            if (this.photo?.articleUrl) {
                links.push({ label: 'About this model', url: this.photo.articleUrl });
            }
        }
        // Homes are at real addresses, so the property sites can find them. Zillow writes an address as
        // words joined by hyphens, for example 524-W-Spring-Ave,-Naperville,-IL-60540.
        if (HOME_TYPES.includes(this.asset.type) && location) {
            links.push({ label: 'View on Zillow', url: `https://www.zillow.com/homes/${encodeURIComponent(location.trim().replace(/\s+/g, '-'))}_rb/` });
            links.push({ label: 'Open in Google Maps', url: `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(location)}` });
        } else if (this.hasCoordinates) {
            links.push({
                label: 'Open in Google Maps',
                url: `https://www.google.com/maps/search/?api=1&query=${this.asset.latitude},${this.asset.longitude}`
            });
        }
        return links;
    }

    get policyUrl() {
        return `/lightning/r/Policy__c/${this.asset.policyId}/view`;
    }

    get holderUrl() {
        return `/lightning/r/Account/${this.asset.holderId}/view`;
    }

    /** Opens the policy or the policyholder. A modified click is left to the browser, for a new tab. */
    handleOpenRecord(event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.recordId, actionName: 'view' }
        });
    }
}
