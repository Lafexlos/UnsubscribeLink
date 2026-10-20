@IsTest
private class UnsubscribeRequestSchedulerTest {
  @IsTest
  static void scheduledRunStartsTheBatch() {
    Contact contact = new Contact(LastName = 'Scheduled', Email = 'scheduled@scheduler.example.com');
    insert contact;
    String publicId = UnsubscribeLinkBuilder.CONTACT_LETTER + [SELECT Public_Id__c FROM Contact WHERE Id = :contact.Id].Public_Id__c;
    Unsubscribe__c request = new Unsubscribe__c(Public_Id__c = publicId, Pending_Key__c = publicId);
    insert request;

    Test.startTest();
    new UnsubscribeRequestScheduler().execute((SchedulableContext) null);
    Test.stopTest();

    Assert.areEqual(
      UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED,
      [SELECT Status__c FROM Unsubscribe__c WHERE Id = :request.Id].Status__c,
      'The scheduled run should process the Request through the batch'
    );
  }

  @IsTest
  static void scheduledRunWithNothingPendingChangesNothing() {
    Unsubscribe__c done = new Unsubscribe__c(Unsubscribe_Email__c = 'done@scheduler.example.com', Status__c = 'Unsubscribed');
    insert done;

    Test.startTest();
    new UnsubscribeRequestScheduler().execute((SchedulableContext) null);
    Test.stopTest();

    Assert.areEqual(
      'Unsubscribed',
      [SELECT Status__c FROM Unsubscribe__c WHERE Id = :done.Id].Status__c,
      'Processed Requests are left alone'
    );
  }
}
