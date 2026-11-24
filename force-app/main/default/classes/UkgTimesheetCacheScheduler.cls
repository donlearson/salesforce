/**
 * UkgTimesheetCacheScheduler
 * Refreshes the Weekly Time Sheet cache at :22, clear of the top of the hour (other
 * UKG integrations) and of the cached dashboard (:17) and bonus (:47) refreshes,
 * which share the same UKG API limits.
 *
 *   Every day, 7:22am:            all 8 cached weeks (also removes older weeks)
 *   Sun-Tue, hourly 8:22-7:22pm:  the current week and the 2 before it, where
 *                                 submissions and approvals happen
 * Each week is 2 UKG calls (login + report). Times are in the scheduling user's time zone.
 *
 * To turn on (Execute Anonymous):  UkgTimesheetCacheScheduler.scheduleDefault();
 * To turn off:                     UkgTimesheetCacheScheduler.unschedule();
 * To fill the cache right away:    UkgTimesheetCacheScheduler.refreshNow(8);
 */
public with sharing class UkgTimesheetCacheScheduler implements Schedulable {

    private static final String JOB_NAME_PREFIX = 'UKG Timesheet Cache';
    private static final String FULL_JOB = JOB_NAME_PREFIX + ' Daily (all weeks)';
    private static final String RECENT_JOB = JOB_NAME_PREFIX + ' Hourly (Sun-Tue)';
    private static final Map<String, String> CRON_BY_JOB_NAME = new Map<String, String>{
        FULL_JOB => '0 22 7 ? * *',
        RECENT_JOB => '0 22 8-19 ? * SUN,MON,TUE'
    };

    private Integer weekCount;

    public UkgTimesheetCacheScheduler(Integer weekCount) {
        this.weekCount = weekCount;
    }

    public void execute(SchedulableContext sc) {
        // Callouts aren't allowed in Schedulable.execute, so hand off to the Queueable.
        refreshNow(weekCount);
    }

    /** Queues a refresh of the most recent weeks unless one is already running. */
    public static Id refreshNow(Integer weeks) {
        if (UkgTimesheetCache.isRefreshInFlight()) {
            return null;
        }
        Integer count = Math.min(Math.max(weeks == null ? UkgTimesheetCache.RECENT_WEEKS : weeks, 1), UkgTimesheetCache.WEEKS_KEPT);
        return System.enqueueJob(new UkgTimesheetCacheJob(UkgTimesheetCache.recentWeeks(count)));
    }

    public static void scheduleDefault() {
        unschedule();
        System.schedule(FULL_JOB, CRON_BY_JOB_NAME.get(FULL_JOB), new UkgTimesheetCacheScheduler(UkgTimesheetCache.WEEKS_KEPT));
        System.schedule(RECENT_JOB, CRON_BY_JOB_NAME.get(RECENT_JOB), new UkgTimesheetCacheScheduler(UkgTimesheetCache.RECENT_WEEKS));
    }

    public static void unschedule() {
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :(JOB_NAME_PREFIX + '%')
        ]) {
            System.abortJob(ct.Id);
        }
    }
}
