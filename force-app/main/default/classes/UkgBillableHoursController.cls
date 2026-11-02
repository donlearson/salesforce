/**
 * UkgBillableHoursController
 * * Thin delegator for HW2/1099 billable hours. The actual UKG callout and CSV
 * parsing now live in UkgBillableHoursW2Controller.getAllTimeEntries(), which
 * fetches the catch-all report (covering both PW2 and HW2/1099 profiles) once
 * and splits rows via the TimesheetProfile column. This class just calls that
 * shared method and maps the HW2/1099 slice into its own return shape, so
 * ukgBillableHoursTracker's contract is unchanged.
 */
public with sharing class UkgBillableHoursController {

    // --- Inner Classes for Data Transfer and Aggregation ---

    // Wrapper class to send the list of summaries and the dynamic column headers to the LWC
    public class BenchTimeWrapper {
        @AuraEnabled public List<UserWeeklyBillableSummary> summaries { get; set; }
        // The 5 week-end dates (Saturdays) found in the report. Index 0 is W1 (most recent).
        @AuraEnabled public List<String> weekEndDates { get; set; }

        // Explicit constructor
        public BenchTimeWrapper(List<UserWeeklyBillableSummary> summaries, List<String> weekEndDates) {
            this.summaries = summaries;
            this.weekEndDates = weekEndDates;
        }
    }

    public class UserWeeklyBillableSummary {
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String contactId { get; set; } // Salesforce Contact Id
        // These fields will hold the aggregated hours for the last 5 weeks (W1 = Most Recent)
        @AuraEnabled public Decimal w1Hours { get; set; }
        @AuraEnabled public Decimal w2Hours { get; set; }
        @AuraEnabled public Decimal w3Hours { get; set; }
        @AuraEnabled public Decimal w4Hours { get; set; }
        @AuraEnabled public Decimal w5Hours { get; set; }
        @AuraEnabled public Decimal total5WeekHours { get; set; }

        // On-Call Segments
        @AuraEnabled public Decimal w1_15hSegments { get; set; }
        @AuraEnabled public Decimal w1_24hSegments { get; set; }
        @AuraEnabled public Decimal w2_15hSegments { get; set; }
        @AuraEnabled public Decimal w2_24hSegments { get; set; }
        @AuraEnabled public Decimal w3_15hSegments { get; set; }
        @AuraEnabled public Decimal w3_24hSegments { get; set; }
        @AuraEnabled public Decimal w4_15hSegments { get; set; }
        @AuraEnabled public Decimal w4_24hSegments { get; set; }
        @AuraEnabled public Decimal w5_15hSegments { get; set; }
        @AuraEnabled public Decimal w5_24hSegments { get; set; }
        @AuraEnabled public Decimal total15hSegments { get; set; }
        @AuraEnabled public Decimal total24hSegments { get; set; }

        // Time Off (APL + Holiday) - carried over from the shared parse for parity with
        // the PW2 shape, even though this employee type isn't held to a utilization target.
        @AuraEnabled public Decimal w1_aplHours { get; set; }
        @AuraEnabled public Decimal w2_aplHours { get; set; }
        @AuraEnabled public Decimal w3_aplHours { get; set; }
        @AuraEnabled public Decimal w4_aplHours { get; set; }
        @AuraEnabled public Decimal w5_aplHours { get; set; }
        @AuraEnabled public Decimal total5WeekAplHours { get; set; }
        @AuraEnabled public Decimal w1_holidayHours { get; set; }
        @AuraEnabled public Decimal w2_holidayHours { get; set; }
        @AuraEnabled public Decimal w3_holidayHours { get; set; }
        @AuraEnabled public Decimal w4_holidayHours { get; set; }
        @AuraEnabled public Decimal w5_holidayHours { get; set; }
        @AuraEnabled public Decimal total5WeekHolidayHours { get; set; }

        public UserWeeklyBillableSummary() {
            w1Hours = 0.0; w2Hours = 0.0; w3Hours = 0.0; w4Hours = 0.0; w5Hours = 0.0; total5WeekHours = 0.0;
            w1_15hSegments = 0.0; w1_24hSegments = 0.0;
            w2_15hSegments = 0.0; w2_24hSegments = 0.0;
            w3_15hSegments = 0.0; w3_24hSegments = 0.0;
            w4_15hSegments = 0.0; w4_24hSegments = 0.0;
            w5_15hSegments = 0.0; w5_24hSegments = 0.0;
            total15hSegments = 0.0; total24hSegments = 0.0;
            w1_aplHours = 0.0; w2_aplHours = 0.0; w3_aplHours = 0.0; w4_aplHours = 0.0; w5_aplHours = 0.0; total5WeekAplHours = 0.0;
            w1_holidayHours = 0.0; w2_holidayHours = 0.0; w3_holidayHours = 0.0; w4_holidayHours = 0.0; w5_holidayHours = 0.0; total5WeekHolidayHours = 0.0;
        }
    }

    /**
     * Retrieves grouped billable hours entries for HW2/1099 by delegating to the
     * shared consolidated fetch+parse and mapping that slice into this class's shape.
     */
    @AuraEnabled
    public static BenchTimeWrapper getTimeEntries(Id contactId) {
        UkgBillableHoursW2Controller.CombinedBillableHoursWrapper combined = UkgBillableHoursW2Controller.getAllTimeEntries(contactId);

        List<UserWeeklyBillableSummary> mapped = new List<UserWeeklyBillableSummary>();
        for (UkgBillableHoursW2Controller.UserWeeklyBillableSummary src : combined.hw2Summaries) {
            UserWeeklyBillableSummary dest = new UserWeeklyBillableSummary();
            dest.userName = src.userName;
            dest.contactId = src.contactId;
            dest.w1Hours = src.w1Hours;
            dest.w2Hours = src.w2Hours;
            dest.w3Hours = src.w3Hours;
            dest.w4Hours = src.w4Hours;
            dest.w5Hours = src.w5Hours;
            dest.total5WeekHours = src.total5WeekHours;
            dest.w1_15hSegments = src.w1_15hSegments;
            dest.w1_24hSegments = src.w1_24hSegments;
            dest.w2_15hSegments = src.w2_15hSegments;
            dest.w2_24hSegments = src.w2_24hSegments;
            dest.w3_15hSegments = src.w3_15hSegments;
            dest.w3_24hSegments = src.w3_24hSegments;
            dest.w4_15hSegments = src.w4_15hSegments;
            dest.w4_24hSegments = src.w4_24hSegments;
            dest.w5_15hSegments = src.w5_15hSegments;
            dest.w5_24hSegments = src.w5_24hSegments;
            dest.total15hSegments = src.total15hSegments;
            dest.total24hSegments = src.total24hSegments;
            dest.w1_aplHours = src.w1_aplHours;
            dest.w2_aplHours = src.w2_aplHours;
            dest.w3_aplHours = src.w3_aplHours;
            dest.w4_aplHours = src.w4_aplHours;
            dest.w5_aplHours = src.w5_aplHours;
            dest.total5WeekAplHours = src.total5WeekAplHours;
            dest.w1_holidayHours = src.w1_holidayHours;
            dest.w2_holidayHours = src.w2_holidayHours;
            dest.w3_holidayHours = src.w3_holidayHours;
            dest.w4_holidayHours = src.w4_holidayHours;
            dest.w5_holidayHours = src.w5_holidayHours;
            dest.total5WeekHolidayHours = src.total5WeekHolidayHours;
            mapped.add(dest);
        }

        return new BenchTimeWrapper(mapped, combined.weekEndDates);
    }
}
