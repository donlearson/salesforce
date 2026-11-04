import { LightningElement } from 'lwc';
import getSnapshots from '@salesforce/apex/UkgSnapshotController.getSnapshots';
import requestRefresh from '@salesforce/apex/UkgSnapshotController.requestRefresh';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * ukgHoursDashboardCached.js
 * * Cached twin of ukgHoursDashboard. Same KPI tiles, tabs, and math - but instead of
 * calling UKG on every page load, it reads scheduled snapshots stored in Salesforce
 * (UKG_Snapshot__c, refreshed by UkgSnapshotRefreshJob). One Apex call, no UKG
 * callouts at view time, so it can't hit UKG's API limits.
 * * Each snapshot is the exact JSON the original dashboard's Apex methods return, so
 * everything below the data-loading section is unchanged from ukgHoursDashboard.
 */
export default class UkgHoursDashboardCached extends LightningElement {
    weekEndDates = [];
    pw2Summaries = [];
    hw2Summaries = [];
    benchSummaries = [];

    // Monthly (70-day window) raw data - each associate entry carries Apex-computed
    // Current Month / Last Month To Date / Last Month Total totals, bucketed
    // server-side via the report's Counter Date column (the actual date the time was
    // logged), so no client-side date-bucketing is needed here.
    monthlyPw2Summaries = [];
    monthlyHw2Summaries = [];
    monthlyBenchSummaries = [];
    // The date (yyyy-MM-dd) Apex calculated Current Month through - either the last
    // completed Saturday, or the last day of the previous month if fewer than 7 days
    // have elapsed in the new one. Authoritative from the server so the "(Through ...)"
    // label always matches the actual bucket math, not a client-side re-derivation of it.
    monthlyAsOfDate = null;

    isLoading = true;
    error = null;

    // Snapshot state (see applySnapshots)
    snapshots = {};
    hasAllData = false;
    dataAsOf = null;
    failedDatasets = [];
    isRefreshing = false;
    refreshMessage = null;
    _pollTimer = null;

    activeTab = 'pw2';
    searchTerm = '';

    connectedCallback() {
        this.loadSnapshots(true);
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // Refresh = ask Apex to queue a snapshot refresh (cooldown-protected server-side),
    // then poll the stored snapshots until every dataset has been re-attempted.
    async handleRefresh() {
        if (this.isRefreshing) return;
        this.refreshMessage = null;
        try {
            const result = await requestRefresh();
            this.refreshMessage = result.message;
            if (result.started) {
                this.isRefreshing = true;
                this.startPolling();
            }
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'UKG Hours Dashboard Refresh Error',
                    message: this.getErrorMessage(error),
                    variant: 'error'
                })
            );
        }
    }

    startPolling() {
        this.stopPolling();
        // Done when the OLDEST last-attempt across all datasets is newer than the newest
        // one seen before the click - i.e. every dataset has been attempted since.
        const baselineMs = this.latestAttemptMs;
        let polls = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(async () => {
            polls += 1;
            await this.loadSnapshots(false);
            if (this.oldestAttemptMs > baselineMs) {
                this.stopPolling();
                this.isRefreshing = false;
                this.refreshMessage = this.failedDatasets.length ? null : 'Refresh complete.';
            } else if (polls >= 24) {
                this.stopPolling();
                this.isRefreshing = false;
                this.refreshMessage = 'Still refreshing in the background - reload in a minute to see the new data.';
            }
        }, 10000);
    }

    stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    async loadSnapshots(showSpinner) {
        if (showSpinner) {
            this.isLoading = true;
        }
        this.error = null;

        try {
            const snapshots = await getSnapshots();
            this.applySnapshots(snapshots);
        } catch (error) {
            this.error = error;
            this.clearData();

            const evt = new ShowToastEvent({
                title: 'UKG Hours Dashboard Retrieval Error',
                message: this.getErrorMessage(error),
                variant: 'error',
            });
            this.dispatchEvent(evt);
        } finally {
            if (showSpinner) {
                this.isLoading = false;
            }
        }
    }

    clearData() {
        this.weekEndDates = [];
        this.pw2Summaries = [];
        this.hw2Summaries = [];
        this.benchSummaries = [];
        this.monthlyPw2Summaries = [];
        this.monthlyHw2Summaries = [];
        this.monthlyBenchSummaries = [];
        this.monthlyAsOfDate = null;
        this.hasAllData = false;
        this.dataAsOf = null;
        this.failedDatasets = [];
    }

    parseSnapshotPayload(snapshot) {
        if (!snapshot || !snapshot.payload) return null;
        try {
            return JSON.parse(snapshot.payload);
        } catch (e) {
            console.error('Failed to parse UKG snapshot payload', e);
            return null;
        }
    }

    toMillis(value) {
        return value ? new Date(value).getTime() : 0;
    }

    get attemptTimes() {
        return Object.values(this.snapshots || {}).map((s) => this.toMillis(s.lastAttemptAt));
    }

    get latestAttemptMs() {
        return Math.max(0, ...this.attemptTimes);
    }

    get oldestAttemptMs() {
        const times = this.attemptTimes;
        return times.length ? Math.min(...times) : 0;
    }

    applySnapshots(snapshots) {
        this.snapshots = snapshots || {};
        const labels = {
            BILLABLE_WEEKLY: 'weekly billable',
            BILLABLE_MONTHLY: 'monthly billable',
            BENCH_WEEKLY: 'weekly bench',
            BENCH_MONTHLY: 'monthly bench'
        };

        const billable = this.parseSnapshotPayload(this.snapshots.BILLABLE_WEEKLY);
        const bench = this.parseSnapshotPayload(this.snapshots.BENCH_WEEKLY);
        const monthlyBillable = this.parseSnapshotPayload(this.snapshots.BILLABLE_MONTHLY);
        const monthlyBench = this.parseSnapshotPayload(this.snapshots.BENCH_MONTHLY);

        this.weekEndDates = (billable && billable.weekEndDates) || [];
        this.pw2Summaries = this.mapSummaries(billable && billable.pw2Summaries, true);
        this.hw2Summaries = this.mapSummaries(billable && billable.hw2Summaries, true);
        this.benchSummaries = this.mapSummaries(bench && bench.summaries, false);

        this.monthlyPw2Summaries = (monthlyBillable && monthlyBillable.pw2Summaries) || [];
        this.monthlyHw2Summaries = (monthlyBillable && monthlyBillable.hw2Summaries) || [];
        this.monthlyBenchSummaries = (monthlyBench && monthlyBench.summaries) || [];
        this.monthlyAsOfDate = (monthlyBillable && monthlyBillable.asOfDate) || null;

        this.hasAllData = Boolean(billable && bench && monthlyBillable && monthlyBench);

        // "Data as of" is the OLDEST successful refresh across the datasets - the
        // dashboard is only as fresh as its stalest piece.
        const refreshed = Object.values(this.snapshots)
            .map((s) => this.toMillis(s.refreshedAt))
            .filter((ms) => ms > 0);
        this.dataAsOf = refreshed.length ? Math.min(...refreshed) : null;

        this.failedDatasets = Object.keys(this.snapshots)
            .filter((key) => this.snapshots[key].status === 'ERROR')
            .map((key) => labels[key] || key);
    }

    // --- Snapshot freshness banner ---

    get dataAsOfLabel() {
        if (!this.dataAsOf) return null;
        const when = new Intl.DateTimeFormat('en-US', {
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
        }).format(new Date(this.dataAsOf));
        const minutes = Math.max(0, Math.round((Date.now() - this.dataAsOf) / 60000));
        let age;
        if (minutes < 60) {
            age = `${minutes} min ago`;
        } else if (minutes < 1440) {
            age = `${Math.floor(minutes / 60)} hr ago`;
        } else {
            age = `${Math.floor(minutes / 1440)} days ago`;
        }
        return `${when} (${age})`;
    }

    get hasFailedDatasets() {
        return this.failedDatasets.length > 0;
    }

    get failedDatasetsMessage() {
        return `The last refresh failed for: ${this.failedDatasets.join(', ')}. Showing the previous data for those.`;
    }

    // At least one dataset has never been stored - the scheduled job (or first manual
    // refresh) hasn't completed yet.
    get showEmptyState() {
        return !this.isLoading && !this.error && !this.hasAllData;
    }

    mapSummaries(summaries, hasSegments) {
        const list = summaries || [];

        const processed = list.map((item, index) => {
            const contactId = item.contactId;
            const userName = item.userName;
            const linkUrl = contactId ? `/lightning/r/Contact/${contactId}/view` : '';

            const base = {
                ...item,
                id: index,
                contactIconLink: linkUrl,
                contactName: userName
            };

            if (!hasSegments) {
                return base;
            }

            return {
                ...base,
                hasW1Segments: (item.w1_15hSegments > 0 || item.w1_24hSegments > 0),
                hasW2Segments: (item.w2_15hSegments > 0 || item.w2_24hSegments > 0),
                hasW3Segments: (item.w3_15hSegments > 0 || item.w3_24hSegments > 0),
                hasW4Segments: (item.w4_15hSegments > 0 || item.w4_24hSegments > 0),
                hasW5Segments: (item.w5_15hSegments > 0 || item.w5_24hSegments > 0),
                hasTotalSegments: (item.total15hSegments > 0 || item.total24hSegments > 0)
            };
        });

        processed.sort((a, b) => {
            const nameA = (a.contactName || '').toUpperCase();
            const nameB = (b.contactName || '').toUpperCase();
            if (nameA < nameB) return -1;
            if (nameA > nameB) return 1;
            return 0;
        });

        return processed;
    }

    // --- Week-over-week deltas (computed client-side from data already in the 5-week payload) ---

    sumField(list, field) {
        return list.reduce((acc, s) => acc + (Number(s[field]) || 0), 0);
    }

    computeDelta(current, prior, comparisonLabel = 'last week') {
        if (!prior) {
            return { pct: null, direction: 'flat', label: `N/A vs ${comparisonLabel}` };
        }
        const pct = ((current - prior) / prior) * 100;
        return {
            pct,
            direction: pct > 0 ? 'up' : pct < 0 ? 'down' : 'flat',
            label: `${pct >= 0 ? '+' : ''}${pct.toFixed(1)}% vs ${comparisonLabel}`
        };
    }

    deltaClassFor(delta) {
        if (delta.direction === 'up') return 'slds-text-color_success';
        if (delta.direction === 'down') return 'slds-text-color_error';
        return 'slds-text-color_weak';
    }

    get pw2CurrentWeekTotal() {
        return this.sumField(this.pw2Summaries, 'w1Hours');
    }

    get pw2PriorWeekTotal() {
        return this.sumField(this.pw2Summaries, 'w2Hours');
    }

    get pw2Delta() {
        return this.computeDelta(this.pw2CurrentWeekTotal, this.pw2PriorWeekTotal);
    }

    get pw2DeltaClass() {
        return this.deltaClassFor(this.pw2Delta);
    }

    get hw2CurrentWeekTotal() {
        return this.sumField(this.hw2Summaries, 'w1Hours');
    }

    get hw2PriorWeekTotal() {
        return this.sumField(this.hw2Summaries, 'w2Hours');
    }

    get hw2Delta() {
        return this.computeDelta(this.hw2CurrentWeekTotal, this.hw2PriorWeekTotal);
    }

    get hw2DeltaClass() {
        return this.deltaClassFor(this.hw2Delta);
    }

    get totalBillableCurrentWeekTotal() {
        return this.pw2CurrentWeekTotal + this.hw2CurrentWeekTotal;
    }

    get totalBillablePriorWeekTotal() {
        return this.pw2PriorWeekTotal + this.hw2PriorWeekTotal;
    }

    get totalBillableDelta() {
        return this.computeDelta(this.totalBillableCurrentWeekTotal, this.totalBillablePriorWeekTotal);
    }

    get totalBillableDeltaClass() {
        return this.deltaClassFor(this.totalBillableDelta);
    }

    get benchCurrentWeekTotal() {
        return this.sumField(this.benchSummaries, 'w1Hours');
    }

    get benchPriorWeekTotal() {
        return this.sumField(this.benchSummaries, 'w2Hours');
    }

    get benchDelta() {
        return this.computeDelta(this.benchCurrentWeekTotal, this.benchPriorWeekTotal);
    }

    get benchDeltaClass() {
        return this.deltaClassFor(this.benchDelta);
    }

    // --- Holiday-aware PW2 capacity / Avg Utilization ---
    // Expected capacity = 8 hrs/weekday * (5 minus however many of the 6 major
    // US holidays fall on a Mon-Fri within the target week). Headcount is the
    // count of distinct associates present in the current PW2 report response
    // (an accepted approximation - it undercounts anyone with zero logged hours
    // who therefore doesn't appear in the report at all).

    // weekEndDateStr is the Saturday ending the work week; Monday of that same
    // Mon-Fri work week is 5 days earlier. Parsed the same safe way as
    // formattedWeekHeaders below to avoid the UTC-shift bug of new Date(string).
    mondayForWeekEnd(weekEndDateStr) {
        const [y, m, d] = weekEndDateStr.split('-').map((p) => parseInt(p, 10));
        const saturday = new Date(y, m - 1, d);
        const monday = new Date(saturday);
        monday.setDate(saturday.getDate() - 5);
        return monday;
    }

    // Monday of the most recent (Last Week) work week - the cutoff used to decide
    // whether a terminated associate should still count toward Last Week utilization.
    get startOfLastWeek() {
        return this.weekEndDates.length ? this.mondayForWeekEnd(this.weekEndDates[0]) : null;
    }

    weekdayDatesForWeekEnd(weekEndDateStr) {
        const monday = this.mondayForWeekEnd(weekEndDateStr);
        return [0, 1, 2, 3, 4].map((offset) => {
            const d = new Date(monday);
            d.setDate(monday.getDate() + offset);
            return d;
        });
    }

    nthWeekdayOfMonth(year, monthIndex, weekday, n) {
        const first = new Date(year, monthIndex, 1);
        const offset = (weekday - first.getDay() + 7) % 7;
        return new Date(year, monthIndex, 1 + offset + (n - 1) * 7);
    }

    lastWeekdayOfMonth(year, monthIndex, weekday) {
        const lastDay = new Date(year, monthIndex + 1, 0);
        lastDay.setDate(lastDay.getDate() - ((lastDay.getDay() - weekday + 7) % 7));
        return lastDay;
    }

    // HPG's observed-holiday rule: a holiday landing on Saturday is observed the
    // preceding Friday, and on Sunday the following Monday - EXCEPT New Year's Day,
    // which always shifts to the following Monday regardless of Saturday or Sunday.
    // Only fixed-calendar-date holidays (New Year's, July 4th, Christmas) can ever
    // land on a weekend; the "Nth weekday of month" holidays (Memorial Day, Labor Day,
    // Thanksgiving) are always weekday-anchored and never need shifting.
    observedHolidayDate(date, isNewYearsDay) {
        const dayOfWeek = date.getDay(); // 0 = Sunday, 6 = Saturday
        if (dayOfWeek === 6) {
            const observed = new Date(date);
            observed.setDate(date.getDate() + (isNewYearsDay ? 2 : -1));
            return observed;
        }
        if (dayOfWeek === 0) {
            const observed = new Date(date);
            observed.setDate(date.getDate() + 1);
            return observed;
        }
        return date;
    }

    getMajorHolidays(year) {
        return [
            this.observedHolidayDate(new Date(year, 0, 1), true), // New Year's Day
            this.lastWeekdayOfMonth(year, 4, 1), // Memorial Day (last Monday of May) - always a Monday
            this.observedHolidayDate(new Date(year, 6, 4), false), // July 4th
            this.nthWeekdayOfMonth(year, 8, 1, 1), // Labor Day (1st Monday of September) - always a Monday
            this.nthWeekdayOfMonth(year, 10, 4, 4), // Thanksgiving (4th Thursday of November) - always a Thursday
            this.observedHolidayDate(new Date(year, 11, 25), false) // Christmas
        ];
    }

    // A "billable day" is a Mon-Fri weekday that isn't one of the 6 major holidays.
    // Returns a count from 0-5 for the work week ending on weekEndDateStr.
    billableDayCountForWeekEnd(weekEndDateStr) {
        const weekdays = this.weekdayDatesForWeekEnd(weekEndDateStr);
        const year = this.mondayForWeekEnd(weekEndDateStr).getFullYear();
        // Covers the rare work-week that spans a year boundary (late Dec / early Jan).
        const holidays = [year - 1, year, year + 1].flatMap((y) => this.getMajorHolidays(y));
        const isHoliday = (d) =>
            holidays.some(
                (h) => h.getFullYear() === d.getFullYear() && h.getMonth() === d.getMonth() && h.getDate() === d.getDate()
            );
        return weekdays.filter((d) => !isHoliday(d)).length;
    }

    capacityHoursForWeekEnd(weekEndDateStr) {
        return this.billableDayCountForWeekEnd(weekEndDateStr) * 8;
    }

    get expectedCapacityHoursPerAssociate() {
        if (!this.weekEndDates.length) return 0;
        return this.capacityHoursForWeekEnd(this.weekEndDates[0]);
    }

    // --- Billable hours per billable day (all billable hours - PW2 + HW2/1099 - current vs. prior week) ---

    get currentWeekBillableDays() {
        return this.weekEndDates.length ? this.billableDayCountForWeekEnd(this.weekEndDates[0]) : 0;
    }

    get priorWeekBillableDays() {
        return this.weekEndDates.length > 1 ? this.billableDayCountForWeekEnd(this.weekEndDates[1]) : 0;
    }

    get totalBillablePerDayCurrent() {
        return this.currentWeekBillableDays ? this.totalBillableCurrentWeekTotal / this.currentWeekBillableDays : null;
    }

    get totalBillablePerDayPrior() {
        return this.priorWeekBillableDays ? this.totalBillablePriorWeekTotal / this.priorWeekBillableDays : null;
    }

    get formattedTotalBillablePerDayCurrent() {
        return this.totalBillablePerDayCurrent === null ? 'N/A' : `${this.totalBillablePerDayCurrent.toFixed(1)} hrs/day`;
    }

    get formattedTotalBillablePerDayPrior() {
        return this.totalBillablePerDayPrior === null ? 'N/A' : `${this.totalBillablePerDayPrior.toFixed(1)} hrs/day`;
    }

    get totalBillablePerDayDelta() {
        if (this.totalBillablePerDayCurrent === null || this.totalBillablePerDayPrior === null) {
            return { pct: null, direction: 'flat', label: 'N/A vs last week' };
        }
        return this.computeDelta(this.totalBillablePerDayCurrent, this.totalBillablePerDayPrior);
    }

    get totalBillablePerDayDeltaClass() {
        return this.deltaClassFor(this.totalBillablePerDayDelta);
    }

    // --- Current Month / Last Month To Date / Last Month Total ---
    // Apex already buckets each associate's hours into these 3 date-precise buckets
    // using the report's Counter Date column, so this is just simple aggregation
    // (sums + billable-day counts over arbitrary date ranges) - no week-to-month
    // attribution needed here, unlike the weekly tile above. Percentages only ever
    // compare Current Month against Last Month To Date (the fair, same-elapsed-days
    // comparison); Last Month Total is shown for context only.

    sumMonthlyField(list, field) {
        return (list || []).reduce((acc, s) => acc + (Number(s[field]) || 0), 0);
    }

    // referenceAsOfDate is authoritative from Apex (monthlyAsOfDate): the last
    // completed Saturday, or, if fewer than 7 days have elapsed in the new month, the
    // last day of the previous month (so Current Month shows the last full month
    // instead of an almost-empty new one). Deriving referenceMonthStart FROM this date
    // works in both cases - it's always the 1st of whichever month Current Month
    // actually refers to.
    get referenceAsOfDate() {
        if (!this.monthlyAsOfDate) return new Date();
        const [y, m, d] = this.monthlyAsOfDate.split('-').map((p) => parseInt(p, 10));
        return new Date(y, m - 1, d);
    }

    get referenceMonthStart() {
        const d = this.referenceAsOfDate;
        return new Date(d.getFullYear(), d.getMonth(), 1);
    }

    get currentMonthLabel() {
        const formatter = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
        return `Through ${formatter.format(this.referenceAsOfDate)}`;
    }

    get startOfLastMonth() {
        const s = this.referenceMonthStart;
        return new Date(s.getFullYear(), s.getMonth() - 1, 1);
    }

    get endOfLastMonth() {
        const s = this.referenceMonthStart;
        return new Date(s.getFullYear(), s.getMonth(), 0);
    }

    get lastMonthToDateCutoff() {
        const daysInLastMonth = this.endOfLastMonth.getDate();
        const cutoffDay = Math.min(this.referenceAsOfDate.getDate(), daysInLastMonth);
        const lastMonthStart = this.startOfLastMonth;
        return new Date(lastMonthStart.getFullYear(), lastMonthStart.getMonth(), cutoffDay);
    }

    // Counts Mon-Fri weekdays that aren't a major holiday, inclusive of both ends.
    billableDayCountBetween(startDate, endDate) {
        if (startDate > endDate) return 0;
        const years = new Set();
        for (let y = startDate.getFullYear(); y <= endDate.getFullYear(); y++) {
            years.add(y);
        }
        const holidays = [...years].flatMap((y) => this.getMajorHolidays(y));
        const isHoliday = (d) =>
            holidays.some(
                (h) => h.getFullYear() === d.getFullYear() && h.getMonth() === d.getMonth() && h.getDate() === d.getDate()
            );
        let count = 0;
        const cursor = new Date(startDate);
        while (cursor <= endDate) {
            const dayOfWeek = cursor.getDay();
            if (dayOfWeek >= 1 && dayOfWeek <= 5 && !isHoliday(cursor)) {
                count += 1;
            }
            cursor.setDate(cursor.getDate() + 1);
        }
        return count;
    }

    get currentMonthBillableDays() {
        return this.billableDayCountBetween(this.referenceMonthStart, this.referenceAsOfDate);
    }

    get lastMonthToDateBillableDays() {
        return this.billableDayCountBetween(this.startOfLastMonth, this.lastMonthToDateCutoff);
    }

    get lastMonthTotalBillableDays() {
        return this.billableDayCountBetween(this.startOfLastMonth, this.endOfLastMonth);
    }

    get currentMonthPw2Total() {
        return this.sumMonthlyField(this.monthlyPw2Summaries, 'currentMonthHours');
    }

    get lastMonthToDatePw2Total() {
        return this.sumMonthlyField(this.monthlyPw2Summaries, 'lastMonthToDateHours');
    }

    get lastMonthTotalPw2Total() {
        return this.sumMonthlyField(this.monthlyPw2Summaries, 'lastMonthTotalHours');
    }

    get currentMonthHw2Total() {
        return this.sumMonthlyField(this.monthlyHw2Summaries, 'currentMonthHours');
    }

    get lastMonthToDateHw2Total() {
        return this.sumMonthlyField(this.monthlyHw2Summaries, 'lastMonthToDateHours');
    }

    get lastMonthTotalHw2Total() {
        return this.sumMonthlyField(this.monthlyHw2Summaries, 'lastMonthTotalHours');
    }

    get currentMonthTotalBillable() {
        return this.currentMonthPw2Total + this.currentMonthHw2Total;
    }

    get lastMonthToDateTotalBillable() {
        return this.lastMonthToDatePw2Total + this.lastMonthToDateHw2Total;
    }

    get lastMonthTotalTotalBillable() {
        return this.lastMonthTotalPw2Total + this.lastMonthTotalHw2Total;
    }

    get monthlyTotalBillableDelta() {
        return this.computeDelta(this.currentMonthTotalBillable, this.lastMonthToDateTotalBillable, 'last month to date');
    }

    get monthlyTotalBillableDeltaClass() {
        return this.deltaClassFor(this.monthlyTotalBillableDelta);
    }

    get currentMonthBenchTotal() {
        return this.sumMonthlyField(this.monthlyBenchSummaries, 'currentMonthHours');
    }

    get lastMonthToDateBenchTotal() {
        return this.sumMonthlyField(this.monthlyBenchSummaries, 'lastMonthToDateHours');
    }

    get lastMonthTotalBenchTotal() {
        return this.sumMonthlyField(this.monthlyBenchSummaries, 'lastMonthTotalHours');
    }

    get monthlyBenchDelta() {
        return this.computeDelta(this.currentMonthBenchTotal, this.lastMonthToDateBenchTotal, 'last month to date');
    }

    get monthlyBenchDeltaClass() {
        return this.deltaClassFor(this.monthlyBenchDelta);
    }

    get currentMonthBillablePerDay() {
        return this.currentMonthBillableDays ? this.currentMonthTotalBillable / this.currentMonthBillableDays : null;
    }

    get lastMonthToDateBillablePerDay() {
        return this.lastMonthToDateBillableDays ? this.lastMonthToDateTotalBillable / this.lastMonthToDateBillableDays : null;
    }

    get lastMonthTotalBillablePerDay() {
        return this.lastMonthTotalBillableDays ? this.lastMonthTotalTotalBillable / this.lastMonthTotalBillableDays : null;
    }

    get formattedCurrentMonthBillablePerDay() {
        return this.currentMonthBillablePerDay === null ? 'N/A' : `${this.currentMonthBillablePerDay.toFixed(1)} hrs/day`;
    }

    get formattedLastMonthToDateBillablePerDay() {
        return this.lastMonthToDateBillablePerDay === null ? 'N/A' : `${this.lastMonthToDateBillablePerDay.toFixed(1)} hrs/day`;
    }

    get formattedLastMonthTotalBillablePerDay() {
        return this.lastMonthTotalBillablePerDay === null ? 'N/A' : `${this.lastMonthTotalBillablePerDay.toFixed(1)} hrs/day`;
    }

    get monthlyBillablePerDayDelta() {
        if (this.currentMonthBillablePerDay === null || this.lastMonthToDateBillablePerDay === null) {
            return { pct: null, direction: 'flat', label: 'N/A vs last month to date' };
        }
        return this.computeDelta(this.currentMonthBillablePerDay, this.lastMonthToDateBillablePerDay, 'last month to date');
    }

    get monthlyBillablePerDayDeltaClass() {
        return this.deltaClassFor(this.monthlyBillablePerDayDelta);
    }

    // Monthly Avg Utilization - Current Month only, same billable-only / APL-separate
    // approach as the weekly tile, summed over however many billable days have
    // elapsed this month.
    get monthlyPw2Headcount() {
        return this.monthlyPw2Summaries.length;
    }

    get monthlyPw2AplTotal() {
        return this.sumMonthlyField(this.monthlyPw2Summaries, 'currentMonthAplHours');
    }

    get currentMonthCapacityHours() {
        return this.monthlyPw2Headcount * this.currentMonthBillableDays * 8;
    }

    get currentMonthAvgUtilizationPct() {
        return this.currentMonthCapacityHours ? (this.currentMonthPw2Total / this.currentMonthCapacityHours) * 100 : null;
    }

    get formattedCurrentMonthAvgUtilizationPct() {
        return this.currentMonthAvgUtilizationPct === null ? 'N/A' : `${this.currentMonthAvgUtilizationPct.toFixed(1)}%`;
    }

    get currentMonthAvgAplPct() {
        return this.currentMonthCapacityHours ? (this.monthlyPw2AplTotal / this.currentMonthCapacityHours) * 100 : null;
    }

    get formattedCurrentMonthAvgAplPct() {
        return this.currentMonthAvgAplPct === null ? 'N/A' : `${this.currentMonthAvgAplPct.toFixed(1)}%`;
    }

    get currentMonthAvgUtilizationInclAplPct() {
        if (this.currentMonthAvgUtilizationPct === null || this.currentMonthAvgAplPct === null) return null;
        return this.currentMonthAvgUtilizationPct + this.currentMonthAvgAplPct;
    }

    get formattedCurrentMonthAvgUtilizationInclAplPct() {
        return this.currentMonthAvgUtilizationInclAplPct === null ? 'N/A' : `${this.currentMonthAvgUtilizationInclAplPct.toFixed(1)}%`;
    }

    get pw2Headcount() {
        return this.pw2SummariesActiveForUtilization.length;
    }

    // Terminated associates still appear in the general PW2 table/totals (they may
    // have logged real hours during the week), but per the business rule they should
    // be excluded from Last Week utilization (headcount and hours) - and from Low
    // Utilization highlighting - once their termination date precedes the start of
    // the most recent (Mon-Fri) work week. An active associate (no termination date)
    // always counts.
    isActiveForLastWeekUtilization(summary) {
        if (!summary.terminationDate) return true;
        const cutoff = this.startOfLastWeek;
        if (!cutoff) return true;
        const [y, m, d] = summary.terminationDate.split('-').map((p) => parseInt(p, 10));
        const terminationDate = new Date(y, m - 1, d);
        return terminationDate >= cutoff;
    }

    get pw2SummariesActiveForUtilization() {
        return this.pw2Summaries.filter((s) => this.isActiveForLastWeekUtilization(s));
    }

    // Utilization is billable hours only - APL is time off, not utilization, so it's
    // never blended into this number. Holiday isn't factored in here either: the
    // expectedCapacityHoursPerAssociate denominator already subtracts holiday weekdays
    // company-wide, so adding per-associate Holiday hours to the numerator would double-count.
    individualBillableHours(summary) {
        return Number(summary.w1Hours || 0);
    }

    individualAplHours(summary) {
        return Number(summary.w1_aplHours || 0);
    }

    // Numerator for Last Week utilization - excludes terminated associates the same
    // way pw2Headcount does, so the % reflects only the active-for-the-week roster.
    // Distinct from pw2CurrentWeekTotal, which stays unfiltered for the KPI tile.
    get pw2UtilizationHoursTotal() {
        return this.sumField(this.pw2SummariesActiveForUtilization, 'w1Hours');
    }

    get avgUtilizationPct() {
        const denom = this.pw2Headcount * this.expectedCapacityHoursPerAssociate;
        return denom ? (this.pw2UtilizationHoursTotal / denom) * 100 : null;
    }

    get formattedAvgUtilizationPct() {
        return this.avgUtilizationPct === null ? 'N/A' : `${this.avgUtilizationPct.toFixed(1)}%`;
    }

    // Separate figure: how much of capacity APL alone accounts for, so a low
    // utilization number can be read alongside "how much of that gap is approved
    // leave" without pretending APL counts as utilization.
    get pw2AplTotal() {
        return this.sumField(this.pw2SummariesActiveForUtilization, 'w1_aplHours');
    }

    get avgAplPct() {
        const denom = this.pw2Headcount * this.expectedCapacityHoursPerAssociate;
        return denom ? (this.pw2AplTotal / denom) * 100 : null;
    }

    get formattedAvgAplPct() {
        return this.avgAplPct === null ? 'N/A' : `${this.avgAplPct.toFixed(1)}%`;
    }

    // "What the number would be" if APL were counted - purely informational, shown
    // alongside the two figures above, not used anywhere as the real utilization number.
    get avgUtilizationInclAplPct() {
        if (this.avgUtilizationPct === null || this.avgAplPct === null) return null;
        return this.avgUtilizationPct + this.avgAplPct;
    }

    get formattedAvgUtilizationInclAplPct() {
        return this.avgUtilizationInclAplPct === null ? 'N/A' : `${this.avgUtilizationInclAplPct.toFixed(1)}%`;
    }

    // --- Bench alerts ---

    get benchAlerts() {
        return this.benchSummaries
            .filter((s) => Number(s.w1Hours) > 0)
            .sort((a, b) => Number(b.w1Hours) - Number(a.w1Hours));
    }

    get hasBenchAlerts() {
        return this.benchAlerts.length > 0;
    }

    // --- Low PW2 utilization alerts ---
    // Same billable-only capacity math as the company-wide Avg Utilization tile, applied
    // per associate - APL time is time off, not utilization, so an associate on approved
    // leave still shows up here (that's correct), but their APL hours are surfaced as an
    // annotation so it reads as "explained by leave" rather than a performance flag. Note
    // this carries the same approximation as the tile above: there's no roster data
    // distinguishing full-time vs. part-time PW2 associates, so a part-time associate at
    // their own full capacity may still show here.

    get lowUtilizationAlerts() {
        const capacity = this.expectedCapacityHoursPerAssociate;
        if (!capacity) return [];
        return this.pw2SummariesActiveForUtilization
            .filter((s) => this.individualBillableHours(s) < capacity)
            .map((s) => {
                const billableHours = this.individualBillableHours(s);
                const aplHours = this.individualAplHours(s);
                return {
                    ...s,
                    utilizationDisplay: `${((billableHours / capacity) * 100).toFixed(0)}%`,
                    timeOffNote: aplHours > 0 ? ` (+${aplHours.toFixed(1)} APL)` : ''
                };
            })
            .sort((a, b) => this.individualBillableHours(a) - this.individualBillableHours(b));
    }

    get hasLowUtilizationAlerts() {
        return this.lowUtilizationAlerts.length > 0;
    }

    // --- Tabs ---

    handleTabActive(event) {
        this.activeTab = event.target.value;
    }

    get isPw2Tab() {
        return this.activeTab === 'pw2';
    }

    get isHw2Tab() {
        return this.activeTab === 'hw2';
    }

    get isBenchTab() {
        return this.activeTab === 'bench';
    }

    // --- Period dropdown (stub - "Previous Quarter" is disabled in markup) ---

    // --- Client-side name search, shared across all three tabs ---

    handleSearchChange(event) {
        this.searchTerm = (event.target.value || '').trim().toLowerCase();
    }

    filterByName(list) {
        if (!this.searchTerm) return list;
        return list.filter((s) => (s.contactName || '').toLowerCase().includes(this.searchTerm));
    }

    // PW2 rows only - flags associates under 100% utilization (billable hours under the
    // week's expected capacity) for row highlighting. Utilization doesn't apply to
    // HW2/1099 or Bench, so this flag is PW2-specific. Maps over the FULL pw2Summaries
    // list (terminated associates still appear in the table if they logged hours), but
    // withholds the low-utilization highlight from anyone terminated before the start
    // of the most recent work week.
    get pw2SummariesWithUtilizationFlag() {
        const capacity = this.expectedCapacityHoursPerAssociate;
        return this.pw2Summaries.map((s) => ({
            ...s,
            rowClass:
                capacity && this.individualBillableHours(s) < capacity && this.isActiveForLastWeekUtilization(s)
                    ? 'slds-hint-parent low-utilization-row'
                    : 'slds-hint-parent'
        }));
    }

    get filteredPw2Summaries() {
        return this.filterByName(this.pw2SummariesWithUtilizationFlag);
    }

    get filteredHw2Summaries() {
        return this.filterByName(this.hw2Summaries);
    }

    get filteredBenchSummaries() {
        return this.filterByName(this.benchSummaries);
    }

    // --- Per-tab column totals (footer row), computed over the currently filtered/visible rows ---

    computeColumnTotals(list) {
        return {
            w1: this.sumField(list, 'w1Hours'),
            w2: this.sumField(list, 'w2Hours'),
            w3: this.sumField(list, 'w3Hours'),
            w4: this.sumField(list, 'w4Hours'),
            w5: this.sumField(list, 'w5Hours'),
            total: this.sumField(list, 'total5WeekHours')
        };
    }

    get pw2ColumnTotals() {
        return this.computeColumnTotals(this.filteredPw2Summaries);
    }

    get hw2ColumnTotals() {
        return this.computeColumnTotals(this.filteredHw2Summaries);
    }

    get benchColumnTotals() {
        return this.computeColumnTotals(this.filteredBenchSummaries);
    }

    // --- Shared week-header formatting ---

    get formattedWeekHeaders() {
        const dateFormatter = new Intl.DateTimeFormat('en-US', { month: '2-digit', day: '2-digit', year: '2-digit' });
        return this.weekEndDates.map((dateStr) => {
            let formatted = dateStr;
            try {
                const dateParts = dateStr.split('-').map((p) => parseInt(p, 10));
                const date = new Date(dateParts[0], dateParts[1] - 1, dateParts[2]);
                formatted = dateFormatter.format(date);
            } catch (e) {
                console.error('Failed to parse date string:', dateStr, e);
            }
            return {
                date: dateStr,
                formatted: formatted
            };
        });
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        } else if (error.body && error.body.exceptionType && error.body.stackTrace) {
            return `Apex Error: ${error.body.exceptionType}`;
        }
        return 'An unknown error occurred while fetching UKG data.';
    }

    get showDashboard() {
        return !this.isLoading && !this.error && this.hasAllData && this.weekEndDates.length > 0;
    }
}