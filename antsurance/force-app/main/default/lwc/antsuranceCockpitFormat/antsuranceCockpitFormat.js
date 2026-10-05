import LOCALE from '@salesforce/i18n/locale';
import CURRENCY from '@salesforce/i18n/currency';

const MS_PER_DAY = 86400000;
export const PLACEHOLDER = '–';

// A book at or under the first loss ratio is doing well; above the second it needs attention.
export const HEALTHY_LOSS_RATIO = 70;
export const HIGH_LOSS_RATIO = 85;

/** Whole dollars: $149,500. */
export function money(amount) {
    return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, maximumFractionDigits: 0 }).format(amount ?? 0);
}

const MILLION = 1000000;
const HUNDRED_THOUSAND = 100000;

/** A headline figure: $1.9M, $745K, $16.6K. Hundreds of thousands need no decimal to be read at a glance. */
export function compactMoney(amount) {
    const value = amount ?? 0;
    const digits = Math.abs(value) >= HUNDRED_THOUSAND && Math.abs(value) < MILLION ? 0 : 1;
    return new Intl.NumberFormat(LOCALE, { style: 'currency', currency: CURRENCY, notation: 'compact', maximumFractionDigits: digits }).format(value);
}

export function count(value) {
    return new Intl.NumberFormat(LOCALE).format(value ?? 0);
}

/** "1 task", "6 tasks". */
export function plural(value, one, many) {
    return `${count(value)} ${value === 1 ? one : many ?? `${one}s`}`;
}

/** A date-only value from Apex ("2026-10-31") as a local date, so it does not slip a day in western time zones. */
export function toDate(value) {
    return value ? new Date(`${value}T00:00:00`) : undefined;
}

/** Whole days from one date-only value to another; negative when the second is earlier. */
export function daysBetween(from, to) {
    return Math.round((toDate(to).getTime() - toDate(from).getTime()) / MS_PER_DAY);
}

/** Oct 31. */
export function shortDate(value) {
    return value ? new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' }).format(toDate(value)) : '';
}

/** Oct 31, 2026. */
export function fullDate(value) {
    return value ? new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric', year: 'numeric' }).format(toDate(value)) : '';
}

/** 9:41 AM. */
export function clockTime(value) {
    return value ? new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' }).format(new Date(value)) : '';
}
