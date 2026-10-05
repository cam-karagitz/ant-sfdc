import { LightningElement } from 'lwc';

/**
 * The cockpit as a Home page. The Antsurance app assigns the page that holds this as its Home, so
 * every route to Home (the address /lightning/page/home, a bookmark, the app's landing) shows the
 * cockpit and the stock Home with its sales chart cannot be reached inside the app.
 */
export default class AntsuranceHomePage extends LightningElement {}
