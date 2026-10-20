@IsTest
private class UnsubscribeRequestBatchTest {
  private static final Integer BULK_SIZE = 200;
  private static final String EMAIL_DOMAIN = '@requestbatch.example.com';
  private static final String SHARED_ADDRESS = 'shared' + EMAIL_DOMAIN;
  private static final String UNKNOWN_ADDRESS = 'nobody' + EMAIL_DOMAIN;
  private static final String ERROR_RECIPIENT = 'admin' + EMAIL_DOMAIN;
  private static final String CONFIRMATION_TEXT = 'You are unsubscribed.';
  private static final String SIMULATED_ERROR = 'Record is locked';

  // Returns a failed result for every record, like a validation rule or a lock would
  private class FailingWriter extends UnsubscribeRequestBatch.RecordWriter {
    public override List<Database.SaveResult> updateRecords(List<SObject> records) {
      List<Database.SaveResult> results = new List<Database.SaveResult>();
      for (SObject record : records) {
        results.add(
          (Database.SaveResult) JSON.deserialize(
            JSON.serialize(
              new Map<String, Object>{
                'success' => false,
                'id' => record.Id,
                'errors' => new List<Object>{
                  new Map<String, Object>{
                    'statusCode' => 'UNABLE_TO_LOCK_ROW',
                    'message' => SIMULATED_ERROR,
                    'fields' => new List<String>()
                  }
                }
              }
            ),
            Database.SaveResult.class
          )
        );
      }
      return results;
    }
  }

  private static Contact insertContact(String lastName, String email) {
    Contact contact = new Contact(LastName = lastName, Email = email);
    insert contact;
    return [SELECT Id, Email, Public_Id__c FROM Contact WHERE Id = :contact.Id];
  }

  private static Lead insertLead(String lastName, String email) {
    Lead lead = new Lead(LastName = lastName, Company = 'Batch Test', Email = email);
    insert lead;
    return [SELECT Id, Email, Public_Id__c FROM Lead WHERE Id = :lead.Id];
  }

  private static Unsubscribe__c linkRequest(String publicId) {
    return new Unsubscribe__c(Public_Id__c = publicId, Pending_Key__c = publicId);
  }

  private static Unsubscribe__c typeInRequest(String address) {
    return new Unsubscribe__c(
      Unsubscribe_Email__c = address,
      Pending_Key__c = 'E:' + address.toLowerCase()
    );
  }

  private static void insertSetup(Boolean acceptLegacyRecordIds) {
    insert new Unsubscribe_Link_Setup__c(
      Accept_Legacy_Record_Id_Links__c = acceptLegacyRecordIds,
      Error_Email_Recipient__c = ERROR_RECIPIENT,
      Max_Retry_Attempts__c = 3,
      Retention_Days__c = 10
    );
  }

  // Runs the batch the way the scheduler does, for at most one chunk of Requests
  private static void runBatch() {
    Test.startTest();
    Database.executeBatch(new UnsubscribeRequestBatch(), UnsubscribeRequestBatch.BATCH_SIZE);
    Test.stopTest();
  }

  // The fields start() selects, for tests that call processRequests directly
  private static List<Unsubscribe__c> queueRequests() {
    return [
      SELECT Id, Status__c, Public_Id__c, Pending_Key__c, Unsubscribe_Email__c, Attempt_Count__c
      FROM Unsubscribe__c
    ];
  }

  private static Unsubscribe__c reload(Id requestId) {
    return [
      SELECT
        Status__c,
        Unsubscribe_Email__c,
        Contact__c,
        Lead__c,
        Pending_Key__c,
        Attempt_Count__c,
        Error_Message__c,
        Processed_Date__c
      FROM Unsubscribe__c
      WHERE Id = :requestId
    ];
  }

  @IsTest
  static void contactLinkOptsOutEveryRecordWithTheAddress() {
    Contact linked = insertContact('Linked', SHARED_ADDRESS);
    Contact sameAddress = insertContact('Same Address', SHARED_ADDRESS.toUpperCase());
    Lead sameAddressLead = insertLead('Same Address', SHARED_ADDRESS);
    Contact otherAddress = insertContact('Other', 'other' + EMAIL_DOMAIN);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + linked.Public_Id__c);
    insert request;

    runBatch();

    Unsubscribe__c saved = reload(request.Id);
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, saved.Status__c, 'Request should be Unsubscribed');
    Assert.areEqual(linked.Id, saved.Contact__c, 'Request should point to the linked Contact');
    Assert.areEqual(SHARED_ADDRESS, saved.Unsubscribe_Email__c, 'Request should hold the address');
    Assert.isNull(saved.Pending_Key__c, 'A processed Request should free its Pending Key');
    Assert.isNotNull(saved.Processed_Date__c, 'Processed date should be set');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :linked.Id].HasOptedOutOfEmail, 'Linked Contact should be opted out');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :sameAddress.Id].HasOptedOutOfEmail, 'Address match should ignore case');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Lead WHERE Id = :sameAddressLead.Id].HasOptedOutOfEmail, 'Lead with the address should be opted out');
    Assert.isFalse([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :otherAddress.Id].HasOptedOutOfEmail, 'Other addresses must not change');
  }

  @IsTest
  static void leadLinkSetsTheLeadLookup() {
    Lead linked = insertLead('Linked', SHARED_ADDRESS);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.LEAD_LETTER + linked.Public_Id__c);
    insert request;

    runBatch();

    Unsubscribe__c saved = reload(request.Id);
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, saved.Status__c, 'Request should be Unsubscribed');
    Assert.areEqual(linked.Id, saved.Lead__c, 'Request should point to the linked Lead');
    Assert.isNull(saved.Contact__c, 'A Lead link should not set the Contact');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Lead WHERE Id = :linked.Id].HasOptedOutOfEmail, 'Lead should be opted out');
  }

  @IsTest
  static void linkToConvertedLeadStillResolves() {
    Lead lead = insertLead('Converted', SHARED_ADDRESS);
    LeadStatus convertedStatus = [SELECT ApiName FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1];
    Database.LeadConvert convert = new Database.LeadConvert();
    convert.setLeadId(lead.Id);
    convert.setConvertedStatus(convertedStatus.ApiName);
    convert.setDoNotCreateOpportunity(true);
    Database.LeadConvertResult converted = Database.convertLead(convert);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.LEAD_LETTER + lead.Public_Id__c);
    insert request;

    runBatch();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, reload(request.Id).Status__c, 'A link sent before conversion should still work');
    Assert.isTrue(
      [SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :converted.getContactId()].HasOptedOutOfEmail,
      'The Contact created by the conversion should be opted out'
    );
    Assert.isFalse([SELECT HasOptedOutOfEmail FROM Lead WHERE Id = :lead.Id].HasOptedOutOfEmail, 'Converted Leads are not updated');
  }

  @IsTest
  static void unknownPublicIdEndsAsNotFound() {
    Contact untouched = insertContact('Untouched', SHARED_ADDRESS);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + UUID.randomUUID().toString());
    insert request;

    runBatch();

    Unsubscribe__c saved = reload(request.Id);
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_NOT_FOUND, saved.Status__c, 'Unknown link should be Not Found');
    Assert.isNull(saved.Pending_Key__c, 'Not Found is final, so the Pending Key is freed');
    Assert.isFalse([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :untouched.Id].HasOptedOutOfEmail, 'No Contact should change');
  }

  @IsTest
  static void contactWithoutEmailEndsAsNotFound() {
    Contact noEmail = insertContact('No Email', null);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + noEmail.Public_Id__c);
    insert request;

    runBatch();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_NOT_FOUND, reload(request.Id).Status__c, 'A record without an address should be Not Found');
  }

  @IsTest
  static void legacyRecordIdNeedsTheSetting() {
    insertSetup(false);
    Contact linked = insertContact('Legacy', SHARED_ADDRESS);
    Unsubscribe__c request = linkRequest(String.valueOf(linked.Id).left(15));
    insert request;

    runBatch();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_NOT_FOUND, reload(request.Id).Status__c, 'Legacy links are off by default');
    Assert.isFalse([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :linked.Id].HasOptedOutOfEmail, 'Contact must not change');
  }

  @IsTest
  static void legacyRecordIdWorksWhenAccepted() {
    insertSetup(true);
    Contact contact = insertContact('Legacy Contact', SHARED_ADDRESS);
    Lead lead = insertLead('Legacy Lead', 'lead' + EMAIL_DOMAIN);
    Unsubscribe__c contactRequest = linkRequest(String.valueOf(contact.Id).left(15));
    Unsubscribe__c leadRequest = linkRequest(String.valueOf(lead.Id));
    insert new List<Unsubscribe__c>{ contactRequest, leadRequest };

    runBatch();

    Assert.areEqual(contact.Id, reload(contactRequest.Id).Contact__c, '15-character Contact Id should resolve');
    Assert.areEqual(lead.Id, reload(leadRequest.Id).Lead__c, '18-character Lead Id should resolve');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Lead WHERE Id = :lead.Id].HasOptedOutOfEmail, 'Lead should be opted out');
  }

  @IsTest
  static void typeInMatchesByAddress() {
    Contact contact = insertContact('Typed', SHARED_ADDRESS);
    Unsubscribe__c request = typeInRequest(SHARED_ADDRESS.toUpperCase());
    insert request;

    runBatch();

    Unsubscribe__c saved = reload(request.Id);
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, saved.Status__c, 'Typed address with a match should be Unsubscribed');
    Assert.areEqual(contact.Id, saved.Contact__c, 'Request should point to the matching Contact');
    Assert.isNull(saved.Pending_Key__c, 'Pending Key should be freed');
    Assert.isTrue([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :contact.Id].HasOptedOutOfEmail, 'Contact should be opted out');
  }

  @IsTest
  static void typeInWithoutMatchEndsAsNotFound() {
    Unsubscribe__c request = typeInRequest(UNKNOWN_ADDRESS);
    insert request;

    runBatch();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_NOT_FOUND, reload(request.Id).Status__c, 'Typed address without a match should be Not Found');
  }

  @IsTest
  static void alreadyOptedOutAddressIsStillUnsubscribed() {
    Contact contact = new Contact(LastName = 'Opted Out', Email = SHARED_ADDRESS, HasOptedOutOfEmail = true);
    insert contact;
    Unsubscribe__c request = typeInRequest(SHARED_ADDRESS);
    insert request;

    runBatch();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, reload(request.Id).Status__c, 'Each click is its own Request, even for an opted-out address');
  }

  @IsTest
  static void failedUpdateIsRetriedThenGivenUp() {
    insertSetup(false);
    Contact contact = insertContact('Locked', SHARED_ADDRESS);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c);
    insert request;
    UnsubscribeRequestBatch.writer = new FailingWriter();
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();

    // Max_Retry_Attempts__c is 3 in the setup
    batch.processRequests(queueRequests());
    Unsubscribe__c afterFirst = reload(request.Id);
    batch.processRequests(queueRequests());
    batch.processRequests(queueRequests());
    Unsubscribe__c afterLast = reload(request.Id);

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_ERROR, afterFirst.Status__c, 'Failed update should set Error');
    Assert.areEqual(1, afterFirst.Attempt_Count__c, 'First failure should count one attempt');
    Assert.isTrue(afterFirst.Error_Message__c.contains(SIMULATED_ERROR), 'Error message should be stored');
    Assert.areEqual(request.Pending_Key__c, afterFirst.Pending_Key__c, 'A Request that will be retried keeps its Pending Key');
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_ERROR, afterLast.Status__c, 'Request should stay Error after the last attempt');
    Assert.areEqual(3, afterLast.Attempt_Count__c, 'Every attempt should be counted');
    Assert.isNull(afterLast.Pending_Key__c, 'After the last attempt the Pending Key is cleared');
    Assert.areEqual(2, batch.retryingCount, 'Two attempts should be reported as retrying');
    Assert.areEqual(1, batch.gaveUpCount, 'The last attempt should be reported once as given up');
  }

  @IsTest
  static void collectErrorsKeepsTheFirstErrorPerAddress() {
    Contact first = insertContact('First', SHARED_ADDRESS);
    Contact second = insertContact('Second', SHARED_ADDRESS);
    List<SObject> records = new List<SObject>{ first, second };
    List<Database.SaveResult> results = new FailingWriter().updateRecords(records);
    Map<String, String> errorByAddress = new Map<String, String>();

    UnsubscribeRequestBatch.collectErrors(
      records,
      results,
      new Map<Id, String>{ first.Id => SHARED_ADDRESS, second.Id => SHARED_ADDRESS },
      errorByAddress
    );

    Assert.areEqual(1, errorByAddress.size(), 'One error per address');
    Assert.areEqual('UNABLE_TO_LOCK_ROW: ' + SIMULATED_ERROR, errorByAddress.get(SHARED_ADDRESS), 'Error should name the status code and message');
  }

  @IsTest
  static void startSelectsPendingAndRetryableErrorsOnly() {
    insertSetup(false);
    Unsubscribe__c pending = typeInRequest('pending' + EMAIL_DOMAIN);
    Unsubscribe__c retryable = new Unsubscribe__c(Unsubscribe_Email__c = 'retry' + EMAIL_DOMAIN, Status__c = 'Error', Attempt_Count__c = 2);
    Unsubscribe__c exhausted = new Unsubscribe__c(Unsubscribe_Email__c = 'done' + EMAIL_DOMAIN, Status__c = 'Error', Attempt_Count__c = 3);
    Unsubscribe__c oldFlowError = new Unsubscribe__c(Unsubscribe_Email__c = 'old' + EMAIL_DOMAIN, Status__c = 'Error');
    Unsubscribe__c unsubscribed = new Unsubscribe__c(Unsubscribe_Email__c = 'ok' + EMAIL_DOMAIN, Status__c = 'Unsubscribed');
    Unsubscribe__c notFound = new Unsubscribe__c(Unsubscribe_Email__c = 'nf' + EMAIL_DOMAIN, Status__c = 'Not Found');
    insert new List<Unsubscribe__c>{ pending, retryable, exhausted, oldFlowError, unsubscribed, notFound };

    Database.QueryLocatorIterator iterator = new UnsubscribeRequestBatch().start(null).iterator();
    Set<Id> selected = new Set<Id>();
    while (iterator.hasNext()) {
      selected.add(iterator.next().Id);
    }

    Assert.areEqual(new Set<Id>{ pending.Id, retryable.Id }, selected, 'Only Pending and retryable Error Requests should be selected');
  }

  @IsTest
  static void loweredLimitFreesStuckErrorRequests() {
    // Max_Retry_Attempts__c is 3 in the setup, these Requests failed under a higher limit
    insertSetup(false);
    Contact contact = insertContact('Stuck', SHARED_ADDRESS);
    Unsubscribe__c stuck = new Unsubscribe__c(
      Public_Id__c = UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c,
      Pending_Key__c = UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c,
      Status__c = 'Error',
      Attempt_Count__c = 4,
      Error_Message__c = SIMULATED_ERROR
    );
    Unsubscribe__c alreadyFreed = new Unsubscribe__c(
      Unsubscribe_Email__c = 'freed' + EMAIL_DOMAIN,
      Status__c = 'Error',
      Attempt_Count__c = 4
    );
    insert new List<Unsubscribe__c>{ stuck, alreadyFreed };

    Database.QueryLocatorIterator iterator = new UnsubscribeRequestBatch().start(null).iterator();
    Set<Id> selected = new Set<Id>();
    while (iterator.hasNext()) {
      selected.add(iterator.next().Id);
    }
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();
    List<Unsubscribe__c> picked = new List<Unsubscribe__c>();
    for (Unsubscribe__c request : queueRequests()) {
      if (selected.contains(request.Id)) {
        picked.add(request);
      }
    }
    batch.processRequests(picked);
    Unsubscribe__c saved = reload(stuck.Id);

    Assert.areEqual(new Set<Id>{ stuck.Id }, selected, 'Only the Request that still blocks its link should be picked up');
    Assert.isNull(saved.Pending_Key__c, 'The Pending Key should be freed');
    Assert.areEqual(UnsubscribeRequestBatch.STATUS_ERROR, saved.Status__c, 'The Request should stay Error');
    Assert.areEqual(4, saved.Attempt_Count__c, 'No new attempt should be made');
    Assert.isFalse([SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :contact.Id].HasOptedOutOfEmail, 'Nothing should be retried');
    Assert.areEqual(1, batch.gaveUpCount, 'The stuck Request should be reported as given up');
    Assert.isTrue(batch.needsAttention(), 'Given-up Requests belong in the digest');

    UnsubscribeRequestBatch nextRun = new UnsubscribeRequestBatch();
    Database.QueryLocatorIterator nextIterator = nextRun.start(null).iterator();
    Assert.isFalse(nextIterator.hasNext(), 'A freed Request is not picked up again, so it is reported once');
  }

  @IsTest
  static void bulkRequestsUseConstantQueries() {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < BULK_SIZE; i++) {
      contacts.add(new Contact(LastName = 'Bulk ' + i, Email = 'bulk' + i + EMAIL_DOMAIN));
    }
    insert contacts;
    List<Unsubscribe__c> requests = new List<Unsubscribe__c>();
    for (Contact c : [SELECT Public_Id__c FROM Contact]) {
      requests.add(linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + c.Public_Id__c));
    }
    insert requests;
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();

    Test.startTest();
    batch.processRequests(queueRequests());
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    Assert.isTrue(queriesUsed <= 10, 'Queries should not grow with the number of Requests, used ' + queriesUsed);
    Assert.areEqual(BULK_SIZE, batch.unsubscribedCount, 'Every Request should be Unsubscribed');
    Assert.areEqual(
      BULK_SIZE,
      [SELECT COUNT() FROM Contact WHERE HasOptedOutOfEmail = TRUE],
      'Every Contact should be opted out'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Unsubscribe__c WHERE Status__c != :UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED],
      'No Request should be left over'
    );
  }

  @IsTest
  static void confirmationEmailIsSentOncePerAddress() {
    Contact first = insertContact('First', SHARED_ADDRESS);
    Contact second = insertContact('Second', SHARED_ADDRESS);
    insert new List<Unsubscribe__c>{
      linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + first.Public_Id__c),
      linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + second.Public_Id__c)
    };
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();
    batch.settings = new UnsubscribeRequestBatch.RequestSettings();
    batch.settings.sendConfirmation = true;
    // Any Id works, a real send is not possible in a test
    batch.settings.orgWideAddressId = UserInfo.getUserId();
    batch.settings.confirmationBody = CONFIRMATION_TEXT;

    batch.processRequests(queueRequests());

    Assert.areEqual(1, UnsubscribeRequestBatch.sentConfirmations.size(), 'One email per address');
    Messaging.SingleEmailMessage message = UnsubscribeRequestBatch.sentConfirmations[0];
    Assert.areEqual(new List<String>{ SHARED_ADDRESS }, message.getToAddresses(), 'Email should go to the address');
    Assert.areEqual(CONFIRMATION_TEXT, message.getHtmlBody(), 'Body should be the setup text');
    Assert.areEqual(System.Label.Confirmation_Email_Subject, message.getSubject(), 'Subject should come from the label');
    Assert.areEqual(1, batch.emailFailureCount, 'A send that fails should only be counted');
  }

  @IsTest
  static void noConfirmationEmailWithoutVerifiedAddress() {
    Contact contact = insertContact('No Email', SHARED_ADDRESS);
    insert linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c);
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();
    batch.settings = new UnsubscribeRequestBatch.RequestSettings();
    batch.settings.sendConfirmation = true;
    batch.settings.confirmationBody = CONFIRMATION_TEXT;

    batch.processRequests(queueRequests());

    Assert.isTrue(UnsubscribeRequestBatch.sentConfirmations.isEmpty(), 'No email without a verified org-wide address');
    Assert.areEqual(1, batch.unsubscribedCount, 'The Request should still be Unsubscribed');
  }

  @IsTest
  static void digestIsSentOnlyWhenSomethingNeedsAttention() {
    insertSetup(false);
    UnsubscribeRequestBatch quiet = new UnsubscribeRequestBatch();
    quiet.unsubscribedCount = 5;
    quiet.finish(null);
    Messaging.SingleEmailMessage quietDigest = UnsubscribeRequestBatch.sentDigest;

    UnsubscribeRequestBatch busy = new UnsubscribeRequestBatch();
    busy.notFoundCount = 312;
    busy.retryingCount = 2;
    busy.finish(null);
    Messaging.SingleEmailMessage busyDigest = UnsubscribeRequestBatch.sentDigest;

    Assert.isNull(quietDigest, 'No digest when every Request was Unsubscribed');
    Assert.isNotNull(busyDigest, 'Digest expected when Requests need attention');
    Assert.areEqual(new List<String>{ ERROR_RECIPIENT }, busyDigest.getToAddresses(), 'Digest goes to the error recipient');
    Assert.isTrue(
      busyDigest.getPlainTextBody().contains(System.Label.Request_Digest_Not_Found.replace('{0}', '312')),
      'Digest should report the Not Found count'
    );
    Assert.isTrue(
      busyDigest.getPlainTextBody().contains(System.Label.Request_Digest_Retrying.replace('{0}', '2')),
      'Digest should report the Error count'
    );
  }

  @IsTest
  static void noDigestWithoutRecipient() {
    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();
    batch.notFoundCount = 1;

    batch.finish(null);

    Assert.isNull(UnsubscribeRequestBatch.sentDigest, 'No setup record means no recipient and no digest');
  }

  @IsTest
  static void finishDeletesOnlyExpiredNotFoundRequests() {
    // Retention_Days__c is 10 in the setup
    insertSetup(false);
    Unsubscribe__c expired = new Unsubscribe__c(Unsubscribe_Email__c = 'old' + EMAIL_DOMAIN, Status__c = 'Not Found', Processed_Date__c = Datetime.now().addDays(-11));
    Unsubscribe__c recent = new Unsubscribe__c(Unsubscribe_Email__c = 'new' + EMAIL_DOMAIN, Status__c = 'Not Found', Processed_Date__c = Datetime.now().addDays(-9));
    Unsubscribe__c oldUnsubscribed = new Unsubscribe__c(Unsubscribe_Email__c = 'kept' + EMAIL_DOMAIN, Status__c = 'Unsubscribed', Processed_Date__c = Datetime.now().addDays(-100));
    insert new List<Unsubscribe__c>{ expired, recent, oldUnsubscribed };

    new UnsubscribeRequestBatch().finish(null);

    Set<Id> remaining = new Map<Id, Unsubscribe__c>([SELECT Id FROM Unsubscribe__c]).keySet();
    Assert.isFalse(remaining.contains(expired.Id), 'Expired Not Found Request should be deleted');
    Assert.isTrue(remaining.contains(recent.Id), 'Recent Not Found Request should be kept');
    Assert.isTrue(remaining.contains(oldUnsubscribed.Id), 'Unsubscribed Requests are history and are kept');
  }

  @IsTest
  static void settingsFallBackToDefaults() {
    insert new Unsubscribe_Link_Setup__c(Max_Retry_Attempts__c = null, Retention_Days__c = null);

    UnsubscribeRequestBatch batch = new UnsubscribeRequestBatch();
    batch.start(null);

    Assert.areEqual(UnsubscribeRequestBatch.DEFAULT_MAX_ATTEMPTS, batch.settings.maxAttempts, 'Blank retries should use the default');
    Assert.areEqual(UnsubscribeRequestBatch.DEFAULT_RETENTION_DAYS, batch.settings.retentionDays, 'Blank retention should use the default');
    Assert.isFalse(batch.settings.acceptLegacyRecordIds, 'Legacy links are off by default');
  }

  @IsTest
  static void schedulerStartsTheBatch() {
    Contact contact = insertContact('Scheduled', SHARED_ADDRESS);
    Unsubscribe__c request = linkRequest(UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c);
    insert request;

    Test.startTest();
    new UnsubscribeRequestBatch().execute((SchedulableContext) null);
    Test.stopTest();

    Assert.areEqual(UnsubscribeRequestBatch.STATUS_UNSUBSCRIBED, reload(request.Id).Status__c, 'The scheduled run should process the Request');
  }

  @IsTest
  static void schedulerSkipsWhileARunIsQueued() {
    Test.startTest();
    Database.executeBatch(new UnsubscribeRequestBatch(), UnsubscribeRequestBatch.BATCH_SIZE);
    new UnsubscribeRequestBatch().execute((SchedulableContext) null);
    Integer queuedRuns = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'BatchApex' AND ApexClass.Name = 'UnsubscribeRequestBatch'
    ];
    Test.stopTest();

    Assert.areEqual(1, queuedRuns, 'A second run should not start while one is queued');
  }
}
