/**
 * UkgSnapshotRefreshScheduler
 * * Kicks off a snapshot refresh on a schedule that deliberately avoids the top of the
 * hour (other UKG integrations all run on the hour and share the same API call limits).
 * * To turn on (Execute Anonymous):   UkgSnapshotRefreshScheduler.scheduleDefault();
 * To turn off:                        UkgSnapshotRefreshScheduler.unschedule();
 * Sun-Tue: hourly at :17 from 7am to 7pm (the busy days around the weekly close).
 * Wed-Sat: once a day at 7:17am. Anything else is a manual refresh.
 * Times are in the scheduling user's time zone.
 */
public with sharing class UkgSnapshotRefreshScheduler implements Schedulable {

    private static final String JOB_NAME_PREFIX = 'UKG Snapshot Refresh';
    private static final Map<String, String> CRON_BY_JOB_NAME = new Map<String, String>{
        JOB_NAME_PREFIX + ' Hourly (Sun-Tue)' => '0 17 7-19 ? * SUN,MON,TUE',
        JOB_NAME_PREFIX + ' Daily (Wed-Sat)' => '0 17 7 ? * WED,THU,FRI,SAT'
    };

    public void execute(SchedulableContext sc) {
        // Callouts aren't allowed in Schedulable.execute, so hand off to the Queueable.
        UkgSnapshotService.enqueueRefresh();
    }

    public static void scheduleDefault() {
        unschedule();
        for (String jobName : CRON_BY_JOB_NAME.keySet()) {
            System.schedule(jobName, CRON_BY_JOB_NAME.get(jobName), new UkgSnapshotRefreshScheduler());
        }
    }

    public static void unschedule() {
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :(JOB_NAME_PREFIX + '%')
        ]) {
            System.abortJob(ct.Id);
        }
    }
}
