/**
 * UkgTimesheetController
 * Backs the ukgTimesheetWeek LWC on the Contact record page. Pulls one Sunday-
 * Saturday week from the UKG Review report (123617418), filtered by the
 * Contact's UKG_ID__c (EmplAccountId), and pivots it into:
 *   - Billable hours by client (Project New Name (1)) x day, with project detail
 *   - Non-billable / time off by activity code (or time-off name) x day
 *   - On-call units by activity code x day (kept out of hour totals)
 * Billable / non-billable / on-call rules match UkgReviewDataController.
 * Client names are matched to Salesforce Accounts by exact name so each client
 * row can link to its Account.
 */
public with sharing class UkgTimesheetController {

    private static final String REPORT_ID = '123617418';
    private static final String NO_CLIENT_LABEL = '(No client)';
    // A known Sunday, used to find the start of a week independent of user locale.
    private static final Date SUNDAY_REFERENCE = Date.newInstance(1900, 1, 7);

    // ---------------------------------------------------------------------
    // Wrapper types
    // ---------------------------------------------------------------------

    public class TimesheetWeek {
        @AuraEnabled public Boolean hasUkgId = true;
        @AuraEnabled public String weekStart;          // yyyy-MM-dd (Sunday)
        @AuraEnabled public String weekEnd;            // yyyy-MM-dd (Saturday)
        @AuraEnabled public List<String> days = new List<String>(); // 7 x yyyy-MM-dd
        @AuraEnabled public List<ClientRow> clients = new List<ClientRow>();
        @AuraEnabled public List<LineRow> nonBillable = new List<LineRow>();
        @AuraEnabled public List<LineRow> onCall = new List<LineRow>();
        @AuraEnabled public List<Decimal> billableDayTotals = zeroes();
        @AuraEnabled public List<Decimal> nonBillableDayTotals = zeroes();
        @AuraEnabled public List<Decimal> dayTotals = zeroes();
        @AuraEnabled public Decimal billableTotal = 0;
        @AuraEnabled public Decimal nonBillableTotal = 0;
        @AuraEnabled public Decimal weekTotal = 0;
        @AuraEnabled public List<String> approvalStates = new List<String>();
        @AuraEnabled public Boolean hasTaskColumn = false;
    }

    public class ClientRow {
        @AuraEnabled public String key;
        @AuraEnabled public String clientName;
        @AuraEnabled public Id accountId;
        @AuraEnabled public List<Decimal> hours = zeroes();
        @AuraEnabled public Decimal total = 0;
        @AuraEnabled public List<LineRow> projects = new List<LineRow>();
    }

    public class LineRow {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String activityCode; // project rows only
        @AuraEnabled public String task;         // project rows only (when the report has a Task column)
        @AuraEnabled public List<Decimal> hours = zeroes();
        @AuraEnabled public Decimal total = 0;
    }

    // Column positions, resolved from the CSV header (falls back to the known layout).
    private class Columns {
        Integer activityCode = 3;
        Integer workDate = 4;
        Integer hours = 5;
        Integer isTimeOff = 9;
        Integer timeOffName = 10;
        Integer approvalState = 12;
        Integer client = 15;
        Integer project = 16;
        Integer subProject = 17;
        Integer task = -1;       // only present if a Task column is added to the UKG report
    }

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

    /**
     * @param contactId  Contact record Id (from the record page).
     * @param weekStart  Any date in the desired week, yyyy-MM-dd. Blank = the most
     *                   recently completed Sunday-Saturday week.
     */
    @AuraEnabled
    public static TimesheetWeek getWeek(Id contactId, String weekStart) {
        Date sunday = resolveWeekStart(weekStart);
        TimesheetWeek result = new TimesheetWeek();
        result.weekStart = formatDate(sunday);
        result.weekEnd = formatDate(sunday.addDays(6));
        for (Integer i = 0; i < 7; i++) {
            result.days.add(formatDate(sunday.addDays(i)));
        }

        List<Contact> contacts = [SELECT UKG_ID__c FROM Contact WHERE Id = :contactId LIMIT 1];
        if (contacts.isEmpty() || String.isBlank(contacts[0].UKG_ID__c)) {
            result.hasUkgId = false;
            return result;
        }

        UKG_Integration_Settings__mdt settings = loadSettings();
        String token = login(settings);
        String csv = fetchReport(token, settings.Company_Short_Name__c, contacts[0].UKG_ID__c, sunday, sunday.addDays(6));
        buildWeek(result, csv, sunday);
        return result;
    }

    // ---------------------------------------------------------------------
    // Week math
    // ---------------------------------------------------------------------

    @TestVisible
    private static Date resolveWeekStart(String weekStart) {
        Date anchor;
        if (String.isNotBlank(weekStart)) {
            try {
                anchor = Date.valueOf(weekStart.trim());
            } catch (Exception e) {
                throw new AuraHandledException('Invalid week date: ' + weekStart);
            }
        } else {
            // Default to the last completed week (associates often submit late).
            anchor = Date.today().addDays(-7);
        }
        return toSunday(anchor);
    }

    private static Date toSunday(Date d) {
        Integer offset = Math.mod(SUNDAY_REFERENCE.daysBetween(d), 7);
        if (offset < 0) offset += 7;
        return d.addDays(-offset);
    }

    private static String formatDate(Date d) {
        return DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('yyyy-MM-dd');
    }

    private static List<Decimal> zeroes() {
        return new List<Decimal>{ 0, 0, 0, 0, 0, 0, 0 };
    }

    // ---------------------------------------------------------------------
    // UKG callouts
    // ---------------------------------------------------------------------

    private static UKG_Integration_Settings__mdt loadSettings() {
        List<UKG_Integration_Settings__mdt> rows = [
            SELECT Api_Key__c, Login_Username__c, Login_Password__c, Company_Short_Name__c
            FROM UKG_Integration_Settings__mdt
            WHERE DeveloperName = 'ukgLogin'
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Company_Short_Name__c)) {
            throw new AuraHandledException('Configuration Error: UKG Integration Settings record "ukgLogin" is missing or incomplete.');
        }
        return rows[0];
    }

    private static String login(UKG_Integration_Settings__mdt s) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/login');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('api-key', s.Api_Key__c);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'credentials' => new Map<String, String>{
                'username' => s.Login_Username__c,
                'password' => s.Login_Password__c,
                'company' => s.Company_Short_Name__c
            }
        }));
        req.setTimeout(60000);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            throw new AuraHandledException('UKG login failed: check network or Named Credential.');
        }
        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('UKG login failed: ' + res.getStatus());
        }
        String token = (String) ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('token');
        if (String.isBlank(token)) {
            throw new AuraHandledException('UKG login failed: no token returned.');
        }
        return token;
    }

    private static String fetchReport(String token, String companyShortName, String ukgAccountId, Date fromDate, Date toDate) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/report/saved/' + REPORT_ID);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'text/csv');
        req.setHeader('Authorization', 'Bearer ' + token);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'company' => new Map<String, String>{ 'short_name' => companyShortName },
            'filters' => new List<Object>{
                new Map<String, Object>{
                    'field_name' => 'EmplAccountId',
                    'operator' => '=',
                    'values' => new List<String>{ ukgAccountId }
                }
            },
            'selectors' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'Date',
                    'name' => 'PPDate',
                    'parameters' => new Map<String, String>{
                        'RangeType' => '2',
                        'FromDate' => formatDate(fromDate),
                        'ToDate' => formatDate(toDate)
                    }
                }
            }
        }));
        req.setTimeout(60000);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            throw new AuraHandledException('UKG report call failed: check network or Named Credential.');
        }
        if (res.getStatusCode() == 503) {
            throw new AuraHandledException('UKG is unavailable right now. Please try again later.');
        }
        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('UKG report error (' + res.getStatusCode() + '): ' + res.getStatus());
        }
        return res.getBody();
    }

    // ---------------------------------------------------------------------
    // CSV -> week grid
    // ---------------------------------------------------------------------

    @TestVisible
    private static void buildWeek(TimesheetWeek week, String csv, Date sunday) {
        List<String> lines = splitLines(csv);
        if (lines.isEmpty()) return;

        Columns col = resolveColumns(parseCsvLine(lines[0]));
        week.hasTaskColumn = col.task >= 0;

        Map<String, ClientRow> clientsByKey = new Map<String, ClientRow>();
        Map<String, Map<String, LineRow>> projectsByClient = new Map<String, Map<String, LineRow>>();
        Map<String, LineRow> nonBillableByKey = new Map<String, LineRow>();
        Map<String, LineRow> onCallByKey = new Map<String, LineRow>();
        Set<String> approvalStates = new Set<String>();

        for (Integer i = 1; i < lines.size(); i++) {
            if (String.isBlank(lines[i])) continue;
            List<String> v = parseCsvLine(lines[i]);

            Date workDate = parseUsDate(cell(v, col.workDate));
            if (workDate == null) continue;
            Integer dayIndex = sunday.daysBetween(workDate);
            if (dayIndex < 0 || dayIndex > 6) continue;

            Decimal hours;
            try {
                hours = Decimal.valueOf(cell(v, col.hours).replace(',', ''));
            } catch (Exception e) {
                continue;
            }
            if (hours == 0) continue;

            String state = cell(v, col.approvalState);
            if (String.isNotBlank(state)) approvalStates.add(state);

            String code = cell(v, col.activityCode);
            String timeOffName = cell(v, col.timeOffName);
            Boolean isTimeOff = isTruthy(cell(v, col.isTimeOff)) || String.isNotBlank(timeOffName);

            if (isTimeOff) {
                String label = String.isNotBlank(timeOffName) ? 'Time Off: ' + timeOffName : 'Time Off';
                addToLine(nonBillableByKey, label, dayIndex, hours);
                addToTotals(week.nonBillableDayTotals, dayIndex, hours);
            } else if (isOnCall(code)) {
                addToLine(onCallByKey, code, dayIndex, hours);
            } else if (isBillable(code)) {
                String clientName = cell(v, col.client);
                if (String.isBlank(clientName)) clientName = NO_CLIENT_LABEL;
                String clientKey = clientName.toLowerCase();

                ClientRow client = clientsByKey.get(clientKey);
                if (client == null) {
                    client = new ClientRow();
                    client.key = 'c' + clientsByKey.size();
                    client.clientName = clientName;
                    clientsByKey.put(clientKey, client);
                    projectsByClient.put(clientKey, new Map<String, LineRow>());
                }
                client.hours[dayIndex] += hours;
                client.total += hours;

                String projectLabel = joinNonBlank(new List<String>{ cell(v, col.project), cell(v, col.subProject) }, ' / ');
                if (String.isBlank(projectLabel)) projectLabel = clientName;
                String task = cell(v, col.task);
                // One detail row per project + activity code + task, like the UKG timesheet.
                String detailKey = projectLabel + '|' + code + '|' + task;
                Map<String, LineRow> details = projectsByClient.get(clientKey);
                LineRow detail = details.get(detailKey);
                if (detail == null) {
                    detail = new LineRow();
                    detail.label = projectLabel;
                    detail.activityCode = code;
                    detail.task = task;
                    details.put(detailKey, detail);
                }
                detail.hours[dayIndex] += hours;
                detail.total += hours;

                addToTotals(week.billableDayTotals, dayIndex, hours);
            } else {
                String label = String.isNotBlank(code) ? code : 'Other';
                addToLine(nonBillableByKey, label, dayIndex, hours);
                addToTotals(week.nonBillableDayTotals, dayIndex, hours);
            }
        }

        // Link clients to Salesforce Accounts by name, ignoring company suffixes
        // (UKG "Archbold Medical Center, Inc" = Salesforce "Archbold Medical Center").
        Set<String> names = new Set<String>();
        for (ClientRow c : clientsByKey.values()) {
            if (c.clientName != NO_CLIENT_LABEL) {
                names.add(c.clientName);
                names.add(stripCompanySuffix(c.clientName));
            }
        }
        Map<String, Id> accountIdByName = new Map<String, Id>();
        if (!names.isEmpty()) {
            for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :names ORDER BY CreatedDate ASC]) {
                String k = stripCompanySuffix(a.Name).toLowerCase();
                if (!accountIdByName.containsKey(k)) accountIdByName.put(k, a.Id);
            }
        }

        for (String clientKey : clientsByKey.keySet()) {
            ClientRow c = clientsByKey.get(clientKey);
            c.accountId = accountIdByName.get(stripCompanySuffix(c.clientName).toLowerCase());
            List<LineRow> details = new List<LineRow>(projectsByClient.get(clientKey).values());
            details.sort(new DetailSorter());
            for (Integer d = 0; d < details.size(); d++) details[d].key = c.key + 'p' + d;
            c.projects = details;
            week.clients.add(c);
        }
        week.clients.sort(new ClientSorter());
        week.nonBillable = sortedLines(nonBillableByKey.values(), 'n');
        week.onCall = sortedLines(onCallByKey.values(), 'o');

        for (Integer d = 0; d < 7; d++) {
            week.billableTotal += week.billableDayTotals[d];
            week.nonBillableTotal += week.nonBillableDayTotals[d];
            week.dayTotals[d] = week.billableDayTotals[d] + week.nonBillableDayTotals[d];
        }
        week.weekTotal = week.billableTotal + week.nonBillableTotal;
        week.approvalStates = new List<String>(approvalStates);
        week.approvalStates.sort();
    }

    // Activity code rules (same as UkgReviewDataController).
    private static Boolean isOnCall(String code) {
        return code.startsWith('177-')
            || code.containsIgnoreCase('15 Hour On-Call Unit')
            || code.containsIgnoreCase('24 Hour On-Call Unit');
    }

    private static Boolean isBillable(String code) {
        if (code.startsWith('176') || code.startsWith('184') || code.startsWith('187')) return false;
        return code.startsWith('1') || code.startsWith('217');
    }

    private static Boolean isTruthy(String s) {
        if (String.isBlank(s)) return false;
        String t = s.trim().toLowerCase();
        return t == 'true' || t == 'yes' || t == 'y' || t == '1';
    }

    private static void addToLine(Map<String, LineRow> rows, String label, Integer dayIndex, Decimal hours) {
        LineRow row = rows.get(label);
        if (row == null) {
            row = new LineRow();
            row.label = label;
            rows.put(label, row);
        }
        row.hours[dayIndex] += hours;
        row.total += hours;
    }

    private static void addToTotals(List<Decimal> totals, Integer dayIndex, Decimal hours) {
        totals[dayIndex] += hours;
    }

    private static List<LineRow> sortedLines(List<LineRow> rows, String keyPrefix) {
        List<LineRow> result = new List<LineRow>(rows);
        result.sort(new LineSorter());
        for (Integer i = 0; i < result.size(); i++) {
            result[i].key = keyPrefix + i;
        }
        return result;
    }

    private class ClientSorter implements Comparator<ClientRow> {
        public Integer compare(ClientRow a, ClientRow b) {
            if (a.total != b.total) return a.total > b.total ? -1 : 1;
            return a.clientName.compareTo(b.clientName);
        }
    }

    private class DetailSorter implements Comparator<LineRow> {
        public Integer compare(LineRow a, LineRow b) {
            Integer r = a.label.compareTo(b.label);
            if (r != 0) return r;
            r = (a.activityCode == null ? '' : a.activityCode).compareTo(b.activityCode == null ? '' : b.activityCode);
            if (r != 0) return r;
            return (a.task == null ? '' : a.task).compareTo(b.task == null ? '' : b.task);
        }
    }

    private class LineSorter implements Comparator<LineRow> {
        public Integer compare(LineRow a, LineRow b) {
            if (a.total != b.total) return a.total > b.total ? -1 : 1;
            return a.label.compareTo(b.label);
        }
    }

    private static final List<String> COMPANY_SUFFIXES = new List<String>{
        ', inc.', ', inc', ' inc.', ' inc', ', llc', ' llc', ', ltd', ' ltd'
    };

    @TestVisible
    private static String stripCompanySuffix(String name) {
        String s = name.trim();
        for (String suffix : COMPANY_SUFFIXES) {
            if (s.toLowerCase().endsWith(suffix)) {
                return s.substring(0, s.length() - suffix.length()).trim();
            }
        }
        return s;
    }

    private static String joinNonBlank(List<String> parts, String sep) {
        List<String> kept = new List<String>();
        for (String p : parts) {
            if (String.isNotBlank(p)) kept.add(p);
        }
        return String.join(kept, sep);
    }

    // ---------------------------------------------------------------------
    // CSV helpers
    // ---------------------------------------------------------------------

    private static Columns resolveColumns(List<String> header) {
        Columns c = new Columns();
        Map<String, Integer> idx = new Map<String, Integer>();
        for (Integer i = 0; i < header.size(); i++) {
            idx.put(header[i].trim().toLowerCase(), i);
        }
        c.activityCode = idx.containsKey('activity codes') ? idx.get('activity codes') : c.activityCode;
        c.workDate = idx.containsKey('date') ? idx.get('date') : c.workDate;
        c.hours = idx.containsKey('hours') ? idx.get('hours') : c.hours;
        c.isTimeOff = idx.containsKey('is time off') ? idx.get('is time off') : c.isTimeOff;
        c.timeOffName = idx.containsKey('time off name') ? idx.get('time off name') : c.timeOffName;
        c.approvalState = idx.containsKey('approval state') ? idx.get('approval state') : c.approvalState;
        c.client = idx.containsKey('project new name (1)') ? idx.get('project new name (1)') : c.client;
        c.project = idx.containsKey('project new name (2)') ? idx.get('project new name (2)') : c.project;
        c.subProject = idx.containsKey('project new name (3)') ? idx.get('project new name (3)') : c.subProject;
        // Task: exact "Task" header preferred, else the first header containing "task".
        if (idx.containsKey('task')) {
            c.task = idx.get('task');
        } else {
            for (String h : idx.keySet()) {
                if (h.contains('task')) { c.task = idx.get(h); break; }
            }
        }
        return c;
    }

    private static String cell(List<String> values, Integer index) {
        if (index == null || index < 0 || index >= values.size()) return '';
        String v = values[index];
        return v == null ? '' : v.trim();
    }

    private static Date parseUsDate(String raw) {
        if (String.isBlank(raw)) return null;
        List<String> parts = raw.trim().split('/');
        if (parts.size() != 3) return null;
        try {
            return Date.newInstance(Integer.valueOf(parts[2].trim()), Integer.valueOf(parts[0].trim()), Integer.valueOf(parts[1].trim()));
        } catch (Exception e) {
            return null;
        }
    }

    // Line splitting without regex (avoids "Regex too complicated" on large CSVs).
    private static List<String> splitLines(String data) {
        List<String> lines = new List<String>();
        if (data == null) return lines;
        Integer start = 0;
        Integer idx = data.indexOf('\n');
        while (idx != -1) {
            lines.add(data.substring(start, idx).removeEnd('\r'));
            start = idx + 1;
            idx = data.indexOf('\n', start);
        }
        if (start < data.length()) lines.add(data.substring(start).removeEnd('\r'));
        return lines;
    }

    // Quote-aware CSV line parser: handles commas inside quotes and "" escapes.
    @TestVisible
    private static List<String> parseCsvLine(String line) {
        List<String> out = new List<String>();
        Integer n = line.length();
        Integer i = 0;
        while (i <= n) {
            if (i < n && line.substring(i, i + 1) == '"') {
                String value = '';
                i++;
                while (i < n) {
                    Integer q = line.indexOf('"', i);
                    if (q == -1) { value += line.substring(i); i = n; break; }
                    value += line.substring(i, q);
                    if (q + 1 < n && line.substring(q + 1, q + 2) == '"') {
                        value += '"';
                        i = q + 2;
                    } else {
                        i = q + 1;
                        break;
                    }
                }
                out.add(value);
                Integer comma = line.indexOf(',', i);
                if (comma == -1) break;
                i = comma + 1;
                if (i == n) { out.add(''); break; }
            } else {
                Integer comma = line.indexOf(',', i);
                if (comma == -1) { out.add(line.substring(i)); break; }
                out.add(line.substring(i, comma));
                i = comma + 1;
                if (i == n) { out.add(''); break; }
            }
        }
        return out;
    }
}
