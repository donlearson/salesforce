import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getWeek from '@salesforce/apex/UkgTimesheetController.getWeek';

const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function parseIso(iso) {
    const [y, m, d] = iso.split('-').map(Number);
    return new Date(y, m - 1, d);
}

function toIso(date) {
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    return `${date.getFullYear()}-${m}-${d}`;
}

function addDays(iso, n) {
    const date = parseIso(iso);
    date.setDate(date.getDate() + n);
    return toIso(date);
}

function shortDate(iso) {
    const date = parseIso(iso);
    return `${date.getMonth() + 1}/${date.getDate()}`;
}

function fmt(value) {
    const n = Number(value) || 0;
    if (n === 0) return '';
    return Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/0$/, '');
}

function dayClass(i, hovered, extra = '') {
    let cls = 'num day';
    if (i === 0 || i === 6) cls += ' weekend';
    if (i === hovered) cls += ' col-hover';
    return extra ? `${cls} ${extra}` : cls;
}

function cells(hours, prefix, hovered) {
    return (hours || []).map((h, i) => {
        const value = fmt(h);
        return {
            key: `${prefix}-${i}`,
            col: i,
            value: value || '–',
            className: dayClass(i, hovered, value ? '' : 'is-empty')
        };
    });
}

export default class UkgTimesheetWeek extends NavigationMixin(LightningElement) {
    @api recordId;

    week;
    weekStart; // yyyy-MM-dd (Sunday) once loaded; undefined = server default
    weekEnd; // yyyy-MM-dd (Saturday): what the date picker shows
    isLoading = false;
    error;
    expanded = new Set();
    hoveredCol = -1; // day column under the mouse, highlighted top to bottom

    connectedCallback() {
        this.load();
    }

    async load(weekStart) {
        this.isLoading = true;
        this.error = undefined;
        try {
            const wasAllExpanded = this.allExpanded;
            this.week = await getWeek({ contactId: this.recordId, weekStart: weekStart || null });
            this.expanded = wasAllExpanded ? new Set(this.week.clients.map((c) => c.key)) : new Set();
            this.weekStart = this.week.weekStart;
            this.weekEnd = this.week.weekEnd;
        } catch (e) {
            this.week = undefined;
            this.error = (e && e.body && e.body.message) || 'Unable to load time from UKG.';
        } finally {
            this.isLoading = false;
        }
    }

    // ---- header / navigation ----

    get weekLabel() {
        if (!this.week) return '';
        const end = parseIso(this.week.weekEnd);
        return `Week ending ${end.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}`;
    }

    get weekRange() {
        if (!this.week) return '';
        return `${shortDate(this.week.weekStart)} – ${shortDate(this.week.weekEnd)}`;
    }

    get isCurrentOrFuture() {
        if (!this.week) return true;
        return parseIso(this.week.weekEnd) >= new Date(new Date().toDateString());
    }

    handlePrev() {
        this.load(addDays(this.weekStart, -7));
    }

    handleNext() {
        this.load(addDays(this.weekStart, 7));
    }

    handleThisWeek() {
        this.load(toIso(new Date()));
    }

    // The picker is "week ending": any date picked snaps to that week's Saturday.
    handleDatePick(event) {
        const picked = event.target.value;
        if (!picked) return;
        const date = parseIso(picked);
        const saturday = addDays(picked, 6 - date.getDay());
        event.target.value = saturday;
        this.weekEnd = saturday;
        this.load(saturday);
    }

    handleRefresh() {
        this.load(this.weekStart);
    }

    // ---- state ----

    get showNoUkgId() {
        return this.week && this.week.hasUkgId === false;
    }

    get hasData() {
        return this.week && this.week.hasUkgId !== false && (this.week.clients.length || this.week.nonBillable.length || this.week.onCall.length);
    }

    get showEmpty() {
        return this.week && this.week.hasUkgId !== false && !this.hasData;
    }

    get approvalLabel() {
        const states = (this.week && this.week.approvalStates) || [];
        return states.join(', ');
    }

    get approvalBadgeClass() {
        const states = (this.week && this.week.approvalStates) || [];
        const allApproved = states.length > 0 && states.every((s) => s.toLowerCase().startsWith('approved'));
        return allApproved ? 'slds-badge slds-theme_success' : 'slds-badge slds-theme_warning';
    }

    // ---- grid ----

    get dayHeaders() {
        if (!this.week) return [];
        return this.week.days.map((iso, i) => ({
            key: iso,
            name: DAY_NAMES[i],
            date: shortDate(iso),
            col: i,
            className: dayClass(i, this.hoveredCol)
        }));
    }

    get clientRows() {
        if (!this.week) return [];
        return this.week.clients.map((c) => {
            const isOpen = this.expanded.has(c.key);
            return {
                key: c.key,
                name: c.clientName,
                accountId: c.accountId,
                hasAccount: !!c.accountId,
                cells: cells(c.hours, c.key, this.hoveredCol),
                total: fmt(c.total),
                canExpand: c.projects.length > 0,
                isOpen,
                icon: isOpen ? 'utility:chevrondown' : 'utility:chevronright',
                projects: isOpen
                    ? c.projects.map((p) => ({
                          key: p.key,
                          name: p.label,
                          detail: [p.activityCode, p.task].filter(Boolean).join(' · '),
                          cells: cells(p.hours, p.key, this.hoveredCol),
                          total: fmt(p.total)
                      }))
                    : []
            };
        });
    }

    get nonBillableRows() {
        return this.lineRows(this.week && this.week.nonBillable);
    }

    get onCallRows() {
        return this.lineRows(this.week && this.week.onCall);
    }

    get hasClients() {
        return this.week && this.week.clients.length > 0;
    }

    get hasNonBillable() {
        return this.week && this.week.nonBillable.length > 0;
    }

    get hasOnCall() {
        return this.week && this.week.onCall.length > 0;
    }

    lineRows(rows) {
        return (rows || []).map((r) => ({ key: r.key, name: r.label, cells: cells(r.hours, r.key, this.hoveredCol), total: fmt(r.total) }));
    }

    get billableTotalCells() {
        return cells(this.week.billableDayTotals, 'bt', this.hoveredCol);
    }

    get nonBillableTotalCells() {
        return cells(this.week.nonBillableDayTotals, 'nt', this.hoveredCol);
    }

    get dayTotalCells() {
        return cells(this.week.dayTotals, 'dt', this.hoveredCol);
    }

    get billableTotal() {
        return fmt(this.week.billableTotal) || '0';
    }

    get nonBillableTotal() {
        return fmt(this.week.nonBillableTotal) || '0';
    }

    get weekTotal() {
        return fmt(this.week.weekTotal) || '0';
    }

    get allExpanded() {
        return this.week && this.week.clients.length > 0 && this.week.clients.every((c) => this.expanded.has(c.key));
    }

    get expandAllLabel() {
        return this.allExpanded ? 'Collapse all' : 'Show activity codes';
    }

    toggleAll() {
        this.expanded = this.allExpanded ? new Set() : new Set(this.week.clients.map((c) => c.key));
    }

    handleHover(event) {
        const cell = event.target.closest('[data-col]');
        const col = cell ? Number(cell.dataset.col) : -1;
        if (col !== this.hoveredCol) this.hoveredCol = col;
    }

    clearHover() {
        this.hoveredCol = -1;
    }

    toggleClient(event) {
        const key = event.currentTarget.dataset.key;
        const next = new Set(this.expanded);
        if (next.has(key)) next.delete(key);
        else next.add(key);
        this.expanded = next;
    }

    openAccount(event) {
        event.preventDefault();
        event.stopPropagation();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'Account', actionName: 'view' }
        });
    }
}
