import { LightningElement } from 'lwc';
import getPW2Entries from '@salesforce/apex/UkgBillableHoursW2Controller.getTimeEntries';
import getHW2Entries from '@salesforce/apex/UkgBillableHoursController.getTimeEntries';
import getBenchEntries from '@salesforce/apex/UkgDataController.getTimeEntries';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * ukgHoursDashboard.js
 * * Unified dashboard combining the three standalone UKG hours trackers
 * (PW2 billable, HW2/1099 billable, bench time) into one tabbed view with
 * KPI tiles, week-over-week deltas, and a bench-time alerts panel.
 * * Calls the same three existing Apex controllers in parallel and does all
 * aggregation/comparison math client-side; none of the underlying Apex was
 * modified for this component.
 */
export default class UkgHoursDashboard extends LightningElement {
    weekEndDates = [];
    pw2Summaries = [];
    hw2Summaries = [];
    benchSummaries = [];

    isLoading = true;
    error = null;

    activeTab = 'pw2';
    selectedPeriod = 'last5';
    searchTerm = '';

    connectedCallback() {
        this.fetchAll();
    }

    handleRefresh() {
        this.fetchAll();
    }

    async fetchAll() {
        this.isLoading = true;
        this.error = null;

        try {
            const [pw2, hw2, bench] = await Promise.all([
                getPW2Entries({ contactId: null }),
                getHW2Entries({ contactId: null }),
                getBenchEntries({ contactId: null })
            ]);

            this.weekEndDates = pw2.weekEndDates || [];
            this.pw2Summaries = this.mapSummaries(pw2.summaries, true);
            this.hw2Summaries = this.mapSummaries(hw2.summaries, true);
            this.benchSummaries = this.mapSummaries(bench.summaries, false);
        } catch (error) {
            this.error = error;
            this.pw2Summaries = [];
            this.hw2Summaries = [];
            this.benchSummaries = [];

            const evt = new ShowToastEvent({
                title: 'UKG Hours Dashboard Retrieval Error',
                message: this.getErrorMessage(error),
                variant: 'error',
            });
            this.dispatchEvent(evt);
        } finally {
            this.isLoading = false;
        }
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

    computeDelta(current, prior) {
        if (!prior) {
            return { pct: null, direction: 'flat', label: 'N/A vs last week' };
        }
        const pct = ((current - prior) / prior) * 100;
        return {
            pct,
            direction: pct > 0 ? 'up' : pct < 0 ? 'down' : 'flat',
            label: `${pct >= 0 ? '+' : ''}${pct.toFixed(1)}% vs last week`
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

    get targetWeekMonday() {
        // weekEndDates[0] is the most recent Saturday; Monday of that same
        // Mon-Fri work week is 5 days earlier. Parsed the same safe way as
        // formattedWeekHeaders below to avoid the UTC-shift bug of new Date(string).
        const [y, m, d] = this.weekEndDates[0].split('-').map((p) => parseInt(p, 10));
        const saturday = new Date(y, m - 1, d);
        const monday = new Date(saturday);
        monday.setDate(saturday.getDate() - 5);
        return monday;
    }

    get weekdayDatesInTargetWeek() {
        const monday = this.targetWeekMonday;
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

    getMajorHolidays(year) {
        return [
            new Date(year, 0, 1), // New Year's Day
            this.lastWeekdayOfMonth(year, 4, 1), // Memorial Day (last Monday of May)
            new Date(year, 6, 4), // July 4th
            this.nthWeekdayOfMonth(year, 8, 1, 1), // Labor Day (1st Monday of September)
            this.nthWeekdayOfMonth(year, 10, 4, 4), // Thanksgiving (4th Thursday of November)
            new Date(year, 11, 25) // Christmas
        ];
    }

    get expectedCapacityHoursPerAssociate() {
        if (!this.weekEndDates.length) return 0;

        const weekdays = this.weekdayDatesInTargetWeek;
        const year = this.targetWeekMonday.getFullYear();
        // Covers the rare work-week that spans a year boundary (late Dec / early Jan).
        const holidays = [year - 1, year, year + 1].flatMap((y) => this.getMajorHolidays(y));
        const isHoliday = (d) =>
            holidays.some(
                (h) => h.getFullYear() === d.getFullYear() && h.getMonth() === d.getMonth() && h.getDate() === d.getDate()
            );
        const holidayWeekdaysInWeek = weekdays.filter(isHoliday).length;
        return (5 - holidayWeekdaysInWeek) * 8;
    }

    get pw2Headcount() {
        return this.pw2Summaries.length;
    }

    // "Effective present hours" = billable hours + approved time off (APL + Holiday), so
    // an associate on approved leave isn't penalized in the utilization math. Falls back
    // to 0 for the two time-off fields if the UKG report hasn't been updated with the new
    // APL/Holiday columns yet - Apex already defaults them to 0 in that case too.
    individualEffectiveHours(summary) {
        return Number(summary.w1Hours || 0) + Number(summary.w1_aplHours || 0) + Number(summary.w1_holidayHours || 0);
    }

    get pw2EffectivePresentHours() {
        return this.pw2Summaries.reduce((acc, s) => acc + this.individualEffectiveHours(s), 0);
    }

    get avgUtilizationPct() {
        const denom = this.pw2Headcount * this.expectedCapacityHoursPerAssociate;
        return denom ? (this.pw2EffectivePresentHours / denom) * 100 : null;
    }

    get formattedAvgUtilizationPct() {
        return this.avgUtilizationPct === null ? 'N/A' : `${this.avgUtilizationPct.toFixed(1)}%`;
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
    // Same capacity figure and effective-hours (billable + APL + Holiday) calc used for
    // the company-wide Avg Utilization tile, applied per associate. Note this carries the
    // same approximation as that tile: there's no roster data distinguishing full-time vs.
    // part-time PW2 associates, so a part-time associate at their own full capacity may
    // still show here.

    get lowUtilizationAlerts() {
        const capacity = this.expectedCapacityHoursPerAssociate;
        if (!capacity) return [];
        return this.pw2Summaries
            .filter((s) => this.individualEffectiveHours(s) < capacity)
            .map((s) => {
                const effectiveHours = this.individualEffectiveHours(s);
                const timeOffHours = Number(s.w1_aplHours || 0) + Number(s.w1_holidayHours || 0);
                return {
                    ...s,
                    utilizationDisplay: `${((effectiveHours / capacity) * 100).toFixed(0)}%`,
                    timeOffNote: timeOffHours > 0 ? ` (+${timeOffHours.toFixed(1)} PTO/Holiday)` : ''
                };
            })
            .sort((a, b) => this.individualEffectiveHours(a) - this.individualEffectiveHours(b));
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

    handlePeriodChange(event) {
        this.selectedPeriod = event.target.value;
    }

    // --- Client-side name search, shared across all three tabs ---

    handleSearchChange(event) {
        this.searchTerm = (event.target.value || '').trim().toLowerCase();
    }

    filterByName(list) {
        if (!this.searchTerm) return list;
        return list.filter((s) => (s.contactName || '').toLowerCase().includes(this.searchTerm));
    }

    // PW2 rows only - flags associates under 100% utilization (effective hours,
    // i.e. billable + APL + Holiday, under the week's expected capacity) for row
    // highlighting. Utilization doesn't apply to HW2/1099 or Bench, so this flag
    // is PW2-specific.
    get pw2SummariesWithUtilizationFlag() {
        const capacity = this.expectedCapacityHoursPerAssociate;
        return this.pw2Summaries.map((s) => ({
            ...s,
            rowClass: capacity && this.individualEffectiveHours(s) < capacity ? 'slds-hint-parent low-utilization-row' : 'slds-hint-parent'
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
        return !this.isLoading && !this.error && this.weekEndDates.length > 0;
    }
}
