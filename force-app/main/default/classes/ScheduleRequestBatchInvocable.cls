/**
 * Schedules UnsubscribeRequestBatch from the setup flow, as the Admin running it
 * (ADR 0002). The job runs UnsubscribeRequestScheduler, which starts the batch by
 * name so the batch stays deployable while the job is scheduled. Any earlier schedule with the same job name is aborted first, so
 * running the setup again applies a new interval and moves the job to the Admin
 * who ran it last.
 *
 * Errors are not caught, so the setup flow's fault path can show them.
 */
public with sharing class ScheduleRequestBatchInvocable {
  public static final String JOB_NAME = 'Unsubscribe Link Request Batch';
  @TestVisible
  private static final Integer DEFAULT_INTERVAL_HOURS = 1;
  // Same values as the Batch_Interval_Hours__c picklist. They divide a day evenly.
  private static final Set<Integer> ALLOWED_INTERVAL_HOURS = new Set<Integer>{
    1,
    2,
    3,
    4,
    6,
    8,
    12,
    24
  };
  private static final Integer HOURS_PER_DAY = 24;

  @InvocableMethod(
    label='Schedule Unsubscribe Request Batch'
    description='Schedules the batch that processes Unsubscribe Requests, replacing any earlier schedule'
  )
  public static List<ScheduleResult> scheduleBatch(
    List<ScheduleRequest> requests
  ) {
    List<ScheduleResult> results = new List<ScheduleResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }
    // Only one schedule can exist, so the first request decides the interval
    ScheduleResult result = new ScheduleResult();
    result.jobId = schedule(parseInterval(requests[0].intervalHours));
    for (ScheduleRequest request : requests) {
      results.add(result);
    }
    return results;
  }

  private static Id schedule(Integer intervalHours) {
    for (CronTrigger existing : [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :JOB_NAME
    ]) {
      System.abortJob(existing.Id);
    }
    return System.schedule(
      JOB_NAME,
      cronExpression(intervalHours),
      new UnsubscribeRequestScheduler()
    );
  }

  @TestVisible
  private static Integer parseInterval(String intervalHours) {
    if (String.isBlank(intervalHours) || !intervalHours.trim().isNumeric()) {
      return DEFAULT_INTERVAL_HOURS;
    }
    Integer hours = Integer.valueOf(intervalHours.trim());
    return ALLOWED_INTERVAL_HOURS.contains(hours)
      ? hours
      : DEFAULT_INTERVAL_HOURS;
  }

  // On the hour, every intervalHours hours starting at midnight
  @TestVisible
  private static String cronExpression(Integer intervalHours) {
    String hourField = intervalHours == HOURS_PER_DAY
      ? '0'
      : '0/' + intervalHours;
    return '0 0 ' + hourField + ' * * ?';
  }

  public class ScheduleRequest {
    @InvocableVariable(
      required=false
      label='Interval Hours'
      description='Batch_Interval_Hours__c from the setup record. Blank or unknown values use 1 hour.'
    )
    public String intervalHours;
  }

  public class ScheduleResult {
    @InvocableVariable(
      label='Job Id'
      description='Id of the scheduled job'
    )
    public Id jobId;
  }
}
