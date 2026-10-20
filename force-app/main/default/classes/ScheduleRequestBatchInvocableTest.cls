@IsTest
private class ScheduleRequestBatchInvocableTest {
  private static List<ScheduleRequestBatchInvocable.ScheduleResult> run(String intervalHours) {
    ScheduleRequestBatchInvocable.ScheduleRequest request = new ScheduleRequestBatchInvocable.ScheduleRequest();
    request.intervalHours = intervalHours;
    return ScheduleRequestBatchInvocable.scheduleBatch(
      new List<ScheduleRequestBatchInvocable.ScheduleRequest>{ request }
    );
  }

  private static List<CronTrigger> scheduledJobs() {
    return [
      SELECT Id, CronExpression, State, OwnerId
      FROM CronTrigger
      WHERE CronJobDetail.Name = :ScheduleRequestBatchInvocable.JOB_NAME
    ];
  }

  @IsTest
  static void schedulesTheBatchAsTheRunningUser() {
    Test.startTest();
    List<ScheduleRequestBatchInvocable.ScheduleResult> results = run('6');
    Test.stopTest();

    List<CronTrigger> jobs = scheduledJobs();
    Assert.areEqual(1, jobs.size(), 'One job should be scheduled');
    Assert.areEqual(jobs[0].Id, results[0].jobId, 'The job Id should be returned');
    Assert.areEqual('0 0 0/6 * * ?', jobs[0].CronExpression, 'Job should run every 6 hours');
    Assert.areEqual(UserInfo.getUserId(), jobs[0].OwnerId, 'Job should run as the user who ran the setup');
  }

  @IsTest
  static void reschedulingReplacesTheEarlierJob() {
    Test.startTest();
    run('1');
    run('12');
    Test.stopTest();

    List<CronTrigger> jobs = scheduledJobs();
    Assert.areEqual(1, jobs.size(), 'Running the setup again must not add a second job');
    Assert.areEqual('0 0 0/12 * * ?', jobs[0].CronExpression, 'The new interval should apply');
  }

  @IsTest
  static void cronExpressionCoversEveryInterval() {
    Assert.areEqual('0 0 0/1 * * ?', ScheduleRequestBatchInvocable.cronExpression(1), 'Hourly');
    Assert.areEqual('0 0 0/8 * * ?', ScheduleRequestBatchInvocable.cronExpression(8), 'Every 8 hours');
    Assert.areEqual('0 0 0 * * ?', ScheduleRequestBatchInvocable.cronExpression(24), 'Daily at midnight');
  }

  @IsTest
  static void unknownIntervalsUseTheDefault() {
    Integer defaultHours = ScheduleRequestBatchInvocable.DEFAULT_INTERVAL_HOURS;
    Assert.areEqual(defaultHours, ScheduleRequestBatchInvocable.parseInterval(null), 'Blank uses the default');
    Assert.areEqual(defaultHours, ScheduleRequestBatchInvocable.parseInterval('5'), 'A value not on the picklist uses the default');
    Assert.areEqual(defaultHours, ScheduleRequestBatchInvocable.parseInterval('abc'), 'Text uses the default');
    Assert.areEqual(24, ScheduleRequestBatchInvocable.parseInterval(' 24 '), 'A picklist value is used');
  }

  @IsTest
  static void emptyRequestsScheduleNothing() {
    // Scheduled jobs are not isolated from org data, so remove one the org may have
    for (CronTrigger job : scheduledJobs()) {
      System.abortJob(job.Id);
    }

    Test.startTest();
    List<ScheduleRequestBatchInvocable.ScheduleResult> results = ScheduleRequestBatchInvocable.scheduleBatch(
      new List<ScheduleRequestBatchInvocable.ScheduleRequest>()
    );
    Test.stopTest();

    Assert.isTrue(results.isEmpty(), 'No requests should give no results');
    Assert.isTrue(scheduledJobs().isEmpty(), 'Nothing should be scheduled');
  }

  @IsTest
  static void manyRequestsScheduleOneJob() {
    List<ScheduleRequestBatchInvocable.ScheduleRequest> requests = new List<ScheduleRequestBatchInvocable.ScheduleRequest>();
    for (Integer i = 0; i < 200; i++) {
      ScheduleRequestBatchInvocable.ScheduleRequest request = new ScheduleRequestBatchInvocable.ScheduleRequest();
      request.intervalHours = '2';
      requests.add(request);
    }

    Test.startTest();
    List<ScheduleRequestBatchInvocable.ScheduleResult> results = ScheduleRequestBatchInvocable.scheduleBatch(requests);
    Test.stopTest();

    Assert.areEqual(200, results.size(), 'Expected one result per request');
    Assert.areEqual(1, scheduledJobs().size(), 'Only one job can exist');
  }
}
