/**
 * Processes the Unsubscribe Requests that the guest flow records (ADR 0002).
 * Scheduled by the setup flow, so it runs as the Admin who ran that flow.
 *
 * Picks up Pending Requests, and Error Requests that have retries left. Each
 * Request gets its email address from the Contact or Lead behind its Public Id,
 * or from the address the Recipient typed in. The batch then sets Email Opt Out
 * on every Contact and every unconverted Lead with that address, sends the
 * Confirmation Email when the setup asks for it, and sets the final status:
 * - Unsubscribed when every matching record was opted out,
 * - Error when an update failed. It is retried until Max_Retry_Attempts__c,
 *   then its Pending Key is cleared so a new click can create a new Request,
 * - Not Found when no Contact or Lead matches. This is final.
 *
 * finish() sends one digest to the error recipient when anything needs the
 * Admin's attention, then deletes Not Found Requests older than Retention_Days__c.
 *
 * Runs without sharing so it sees every Contact, Lead and Request, whoever
 * scheduled it.
 */
public without sharing class UnsubscribeRequestBatch implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
  public static final Integer BATCH_SIZE = 50;
  public static final String STATUS_PENDING = 'Pending';
  public static final String STATUS_UNSUBSCRIBED = 'Unsubscribed';
  public static final String STATUS_ERROR = 'Error';
  public static final String STATUS_NOT_FOUND = 'Not Found';

  @TestVisible
  private static final Integer DEFAULT_MAX_ATTEMPTS = 5;
  @TestVisible
  private static final Integer DEFAULT_RETENTION_DAYS = 30;
  // Keeps finish() well under the DML row limit
  @TestVisible
  private static final Integer MAX_DELETES_PER_RUN = 5000;
  private static final String SEND_CONFIRMATION_YES = 'Yes';
  private static final String BATCH_JOB_TYPE = 'BatchApex';
  private static final Set<String> RUNNING_JOB_STATUSES = new Set<String>{
    'Holding',
    'Queued',
    'Preparing',
    'Processing'
  };
  // The Confirmation Email goes to an address that just opted out
  private static final String CONFIRMATION_OPT_OUT_POLICY = 'SEND';
  private static final Integer ERROR_MESSAGE_LENGTH = Unsubscribe__c.Error_Message__c.getDescribe()
    .getLength();

  // Replaced in tests to simulate failed opt-out updates
  @TestVisible
  private static RecordWriter writer = new RecordWriter();
  @TestVisible
  private static List<Messaging.SingleEmailMessage> sentConfirmations = new List<Messaging.SingleEmailMessage>();
  @TestVisible
  private static Messaging.SingleEmailMessage sentDigest;

  // Counts for the digest. Database.Stateful keeps them across chunks.
  @TestVisible
  private Integer unsubscribedCount = 0;
  @TestVisible
  private Integer retryingCount = 0;
  @TestVisible
  private Integer gaveUpCount = 0;
  @TestVisible
  private Integer notFoundCount = 0;
  @TestVisible
  private Integer emailFailureCount = 0;

  @TestVisible
  private RequestSettings settings;

  public void execute(SchedulableContext context) {
    // A slow run must not overlap the next one
    if (isAlreadyRunning()) {
      return;
    }
    Database.executeBatch(new UnsubscribeRequestBatch(), BATCH_SIZE);
  }

  public Database.QueryLocator start(Database.BatchableContext context) {
    Integer maxAttempts = getSettings().maxAttempts;
    // Error Requests with no attempts were set by the old flows and are not retried
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          Status__c,
          Public_Id__c,
          Pending_Key__c,
          Unsubscribe_Email__c,
          Attempt_Count__c
        FROM Unsubscribe__c
        WHERE
          Status__c = :STATUS_PENDING
          OR (Status__c = :STATUS_ERROR
          AND Attempt_Count__c > 0
          AND Attempt_Count__c < :maxAttempts)
        ORDER BY CreatedDate
      ]
    );
  }

  public void execute(
    Database.BatchableContext context,
    List<Unsubscribe__c> scope
  ) {
    processRequests(scope);
  }

  public void finish(Database.BatchableContext context) {
    sendDigest();
    deleteExpiredNotFoundRequests();
  }

  @TestVisible
  private void processRequests(List<Unsubscribe__c> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }
    RequestSettings config = getSettings();
    Map<Id, SObject> linkedRecords = findLinkedRecords(
      requests,
      config.acceptLegacyRecordIds
    );

    // Lower-case address per Request. Requests without one end as Not Found.
    Map<Id, String> addressByRequestId = new Map<Id, String>();
    for (Unsubscribe__c request : requests) {
      String address = String.isBlank(request.Public_Id__c)
        ? request.Unsubscribe_Email__c
        : (String) linkedRecords.get(request.Id)?.get('Email');
      if (String.isNotBlank(address)) {
        addressByRequestId.put(request.Id, address.trim().toLowerCase());
      }
    }

    AddressMatches matches = findRecordsByAddress(
      new Set<String>(addressByRequestId.values())
    );
    Map<String, String> errorByAddress = optOut(matches);

    Set<String> addressesToConfirm = new Set<String>();
    List<Unsubscribe__c> updates = new List<Unsubscribe__c>();
    for (Unsubscribe__c request : requests) {
      String address = addressByRequestId.get(request.Id);
      SObject matchedRecord = String.isBlank(request.Public_Id__c)
        ? matches.firstRecordByAddress.get(address)
        : linkedRecords.get(request.Id);
      if (address == null || matchedRecord == null) {
        markNotFound(request);
      } else if (errorByAddress.containsKey(address)) {
        markError(request, errorByAddress.get(address), config.maxAttempts);
      } else {
        markUnsubscribed(request, matchedRecord);
        addressesToConfirm.add(address);
      }
      updates.add(request);
    }
    update updates;

    sendConfirmationEmails(addressesToConfirm, config);
  }

  // Maps each Request with a Public Id to its Contact or Lead.
  // Converted Leads are included, because a link sent before conversion must still resolve.
  private static Map<Id, SObject> findLinkedRecords(
    List<Unsubscribe__c> requests,
    Boolean acceptLegacyRecordIds
  ) {
    Map<Id, UnsubscribeLinkValue> linkByRequestId = new Map<Id, UnsubscribeLinkValue>();
    Set<String> contactPublicIds = new Set<String>();
    Set<String> leadPublicIds = new Set<String>();
    Set<Id> contactIds = new Set<Id>();
    Set<Id> leadIds = new Set<Id>();
    for (Unsubscribe__c request : requests) {
      if (String.isBlank(request.Public_Id__c)) {
        continue;
      }
      UnsubscribeLinkValue link = UnsubscribeLinkValue.parse(
        request.Public_Id__c,
        acceptLegacyRecordIds
      );
      if (!link.isValid()) {
        continue;
      }
      linkByRequestId.put(request.Id, link);
      Boolean isContact = link.objectType == Contact.SObjectType;
      if (link.recordId != null) {
        (isContact ? contactIds : leadIds).add(link.recordId);
      } else {
        (isContact ? contactPublicIds : leadPublicIds).add(link.publicId);
      }
    }
    if (linkByRequestId.isEmpty()) {
      return new Map<Id, SObject>();
    }

    Map<String, SObject> recordByKey = new Map<String, SObject>();
    for (Contact c : [
      SELECT Id, Email, Public_Id__c
      FROM Contact
      WHERE Public_Id__c IN :contactPublicIds OR Id IN :contactIds
    ]) {
      addRecordKeys(recordByKey, c, Contact.SObjectType);
    }
    for (Lead l : [
      SELECT Id, Email, Public_Id__c
      FROM Lead
      WHERE Public_Id__c IN :leadPublicIds OR Id IN :leadIds
    ]) {
      addRecordKeys(recordByKey, l, Lead.SObjectType);
    }

    Map<Id, SObject> recordByRequestId = new Map<Id, SObject>();
    for (Id requestId : linkByRequestId.keySet()) {
      SObject record = recordByKey.get(recordKey(linkByRequestId.get(requestId)));
      if (record != null) {
        recordByRequestId.put(requestId, record);
      }
    }
    return recordByRequestId;
  }

  private static void addRecordKeys(
    Map<String, SObject> recordByKey,
    SObject record,
    SObjectType objectType
  ) {
    recordByKey.put(String.valueOf(record.Id), record);
    String publicId = (String) record.get('Public_Id__c');
    if (String.isNotBlank(publicId)) {
      recordByKey.put(objectType + ':' + publicId, record);
    }
  }

  private static String recordKey(UnsubscribeLinkValue link) {
    return link.recordId != null
      ? String.valueOf(link.recordId)
      : link.objectType + ':' + link.publicId;
  }

  // Every Contact and Lead per address, and the ones that still need opting out
  private static AddressMatches findRecordsByAddress(Set<String> addresses) {
    AddressMatches matches = new AddressMatches();
    if (addresses.isEmpty()) {
      return matches;
    }
    // Email comparisons in SOQL ignore case
    for (Contact c : [
      SELECT Id, Email, HasOptedOutOfEmail
      FROM Contact
      WHERE Email IN :addresses
    ]) {
      matches.add(c, !c.HasOptedOutOfEmail);
    }
    // Converted Leads count as a match but can't be updated
    for (Lead l : [
      SELECT Id, Email, HasOptedOutOfEmail, IsConverted
      FROM Lead
      WHERE Email IN :addresses
    ]) {
      matches.add(l, !l.HasOptedOutOfEmail && !l.IsConverted);
    }
    return matches;
  }

  // Returns the first error per address. Updates that succeed are kept.
  private static Map<String, String> optOut(AddressMatches matches) {
    Map<String, String> errorByAddress = new Map<String, String>();
    collectErrors(
      matches.contactsToOptOut,
      writer.updateRecords(matches.contactsToOptOut),
      matches.addressByRecordId,
      errorByAddress
    );
    collectErrors(
      matches.leadsToOptOut,
      writer.updateRecords(matches.leadsToOptOut),
      matches.addressByRecordId,
      errorByAddress
    );
    return errorByAddress;
  }

  @TestVisible
  private static void collectErrors(
    List<SObject> records,
    List<Database.SaveResult> results,
    Map<Id, String> addressByRecordId,
    Map<String, String> errorByAddress
  ) {
    for (Integer i = 0; i < results.size(); i++) {
      Database.SaveResult result = results[i];
      String address = addressByRecordId.get(records[i].Id);
      if (result.isSuccess() || errorByAddress.containsKey(address)) {
        continue;
      }
      List<Database.Error> errors = result.getErrors();
      errorByAddress.put(
        address,
        errors.isEmpty() ? '' : errors[0].getStatusCode() + ': ' + errors[0].getMessage()
      );
    }
  }

  private void markUnsubscribed(Unsubscribe__c request, SObject record) {
    request.Status__c = STATUS_UNSUBSCRIBED;
    request.Unsubscribe_Email__c = (String) record.get('Email');
    if (record.getSObjectType() == Contact.SObjectType) {
      request.Contact__c = record.Id;
    } else {
      request.Lead__c = record.Id;
    }
    request.Error_Message__c = null;
    request.Pending_Key__c = null;
    request.Processed_Date__c = Datetime.now();
    unsubscribedCount++;
  }

  private void markError(
    Unsubscribe__c request,
    String message,
    Integer maxAttempts
  ) {
    Decimal attempts = request.Attempt_Count__c == null
      ? 1
      : request.Attempt_Count__c + 1;
    request.Status__c = STATUS_ERROR;
    request.Attempt_Count__c = attempts;
    request.Error_Message__c = message.left(ERROR_MESSAGE_LENGTH);
    if (attempts >= maxAttempts) {
      // Gave up: a new click can now create a fresh Request
      request.Pending_Key__c = null;
      gaveUpCount++;
    } else {
      retryingCount++;
    }
  }

  private void markNotFound(Unsubscribe__c request) {
    request.Status__c = STATUS_NOT_FOUND;
    request.Pending_Key__c = null;
    request.Processed_Date__c = Datetime.now();
    notFoundCount++;
  }

  // One send per chunk. Failures only count toward the digest.
  private void sendConfirmationEmails(
    Set<String> addresses,
    RequestSettings config
  ) {
    if (addresses.isEmpty() || !config.canSendConfirmation()) {
      return;
    }
    List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
    for (String address : addresses) {
      Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
      message.setToAddresses(new List<String>{ address });
      message.setOrgWideEmailAddressId(config.orgWideAddressId);
      message.setSubject(System.Label.Confirmation_Email_Subject);
      message.setHtmlBody(config.confirmationBody);
      message.setOptOutPolicy(CONFIRMATION_OPT_OUT_POLICY);
      message.setSaveAsActivity(false);
      messages.add(message);
    }
    sentConfirmations.addAll(messages);
    try {
      for (Messaging.SendEmailResult result : Messaging.sendEmail(messages, false)) {
        if (!result.isSuccess()) {
          emailFailureCount++;
        }
      }
    } catch (Exception e) {
      // For example the daily email limit or email deliverability turned off
      System.debug(LoggingLevel.ERROR, 'Confirmation emails failed: ' + e.getMessage());
      emailFailureCount += messages.size();
    }
  }

  @TestVisible
  private Boolean needsAttention() {
    return retryingCount + gaveUpCount + notFoundCount + emailFailureCount > 0;
  }

  private void sendDigest() {
    RequestSettings config = getSettings();
    if (!needsAttention() || String.isBlank(config.errorRecipient)) {
      return;
    }
    Messaging.SingleEmailMessage digest = new Messaging.SingleEmailMessage();
    digest.setToAddresses(new List<String>{ config.errorRecipient.trim() });
    if (config.orgWideAddressId != null) {
      digest.setOrgWideEmailAddressId(config.orgWideAddressId);
    }
    digest.setSubject(System.Label.Request_Digest_Subject);
    digest.setPlainTextBody(buildDigestBody());
    digest.setSaveAsActivity(false);
    sentDigest = digest;
    try {
      Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ digest });
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'Unsubscribe Request digest failed: ' + e.getMessage());
    }
  }

  @TestVisible
  private String buildDigestBody() {
    return String.join(
      new List<String>{
        System.Label.Request_Digest_Intro,
        '',
        fill(System.Label.Request_Digest_Unsubscribed, unsubscribedCount),
        fill(System.Label.Request_Digest_Retrying, retryingCount),
        fill(System.Label.Request_Digest_Gave_Up, gaveUpCount),
        fill(System.Label.Request_Digest_Not_Found, notFoundCount),
        fill(System.Label.Request_Digest_Email_Failures, emailFailureCount),
        '',
        System.Label.Request_Digest_Next_Steps
      },
      '\n'
    );
  }

  // Plain replace, because String.format treats apostrophes in translations as quotes
  private static String fill(String template, Integer value) {
    return template.replace('{0}', String.valueOf(value));
  }

  private void deleteExpiredNotFoundRequests() {
    Datetime cutoff = Datetime.now().addDays(-getSettings().retentionDays);
    List<Unsubscribe__c> expired = [
      SELECT Id
      FROM Unsubscribe__c
      WHERE Status__c = :STATUS_NOT_FOUND AND Processed_Date__c < :cutoff
      ORDER BY Processed_Date__c
      LIMIT :MAX_DELETES_PER_RUN
    ];
    if (!expired.isEmpty()) {
      Database.delete(expired, false);
    }
  }

  private static Boolean isAlreadyRunning() {
    // getName() is Namespace.ClassName inside the package, ClassName without one
    String fullName = UnsubscribeRequestBatch.class.getName();
    Boolean hasNamespace = fullName.contains('.');
    String namespace = hasNamespace ? fullName.substringBefore('.') : null;
    String className = hasNamespace ? fullName.substringAfter('.') : fullName;
    return ![
        SELECT Id
        FROM AsyncApexJob
        WHERE
          JobType = :BATCH_JOB_TYPE
          AND ApexClass.Name = :className
          AND ApexClass.NamespacePrefix = :namespace
          AND Status IN :RUNNING_JOB_STATUSES
        LIMIT 1
      ]
      .isEmpty();
  }

  private RequestSettings getSettings() {
    if (settings == null) {
      settings = loadSettings();
    }
    return settings;
  }

  @TestVisible
  private class RequestSettings {
    @TestVisible
    private Integer maxAttempts = DEFAULT_MAX_ATTEMPTS;
    @TestVisible
    private Integer retentionDays = DEFAULT_RETENTION_DAYS;
    @TestVisible
    private Boolean acceptLegacyRecordIds = false;
    @TestVisible
    private Boolean sendConfirmation = false;
    @TestVisible
    private Id orgWideAddressId;
    @TestVisible
    private String confirmationBody;
    @TestVisible
    private String errorRecipient;

    private Boolean canSendConfirmation() {
      return sendConfirmation &&
        orgWideAddressId != null &&
        String.isNotBlank(confirmationBody);
    }
  }

  // Defaults apply when there is no setup record or a field is blank
  private static RequestSettings loadSettings() {
    RequestSettings config = new RequestSettings();
    List<Unsubscribe_Link_Setup__c> setups = [
      SELECT
        Max_Retry_Attempts__c,
        Retention_Days__c,
        Accept_Legacy_Record_Id_Links__c,
        Send_Confirmation_Email__c,
        Org_Wide_Email_Address__c,
        Confirmation_Email_Text__c,
        Error_Email_Recipient__c
      FROM Unsubscribe_Link_Setup__c
      ORDER BY CreatedDate
      LIMIT 1
    ];
    if (setups.isEmpty()) {
      return config;
    }
    Unsubscribe_Link_Setup__c setup = setups[0];
    if (setup.Max_Retry_Attempts__c != null && setup.Max_Retry_Attempts__c >= 1) {
      config.maxAttempts = setup.Max_Retry_Attempts__c.intValue();
    }
    if (setup.Retention_Days__c != null && setup.Retention_Days__c >= 1) {
      config.retentionDays = setup.Retention_Days__c.intValue();
    }
    config.acceptLegacyRecordIds = setup.Accept_Legacy_Record_Id_Links__c;
    config.sendConfirmation = setup.Send_Confirmation_Email__c == SEND_CONFIRMATION_YES;
    config.confirmationBody = setup.Confirmation_Email_Text__c;
    config.errorRecipient = setup.Error_Email_Recipient__c;
    config.orgWideAddressId = findVerifiedAddressId(setup.Org_Wide_Email_Address__c);
    return config;
  }

  private static Id findVerifiedAddressId(String address) {
    if (String.isBlank(address)) {
      return null;
    }
    List<OrgWideEmailAddress> verified = [
      SELECT Id
      FROM OrgWideEmailAddress
      WHERE Address = :address AND IsVerified = TRUE
      LIMIT 1
    ];
    return verified.isEmpty() ? null : verified[0].Id;
  }

  // Contacts and Leads found by address
  private class AddressMatches {
    private List<Contact> contactsToOptOut = new List<Contact>();
    private List<Lead> leadsToOptOut = new List<Lead>();
    private Map<Id, String> addressByRecordId = new Map<Id, String>();
    // Used to link a type-in Request to a record, a Contact before a Lead
    private Map<String, SObject> firstRecordByAddress = new Map<String, SObject>();

    private void add(SObject record, Boolean needsOptOut) {
      String address = ((String) record.get('Email')).toLowerCase();
      addressByRecordId.put(record.Id, address);
      if (!firstRecordByAddress.containsKey(address)) {
        firstRecordByAddress.put(address, record);
      }
      if (!needsOptOut) {
        return;
      }
      if (record instanceof Contact) {
        contactsToOptOut.add(new Contact(Id = record.Id, HasOptedOutOfEmail = true));
      } else {
        leadsToOptOut.add(new Lead(Id = record.Id, HasOptedOutOfEmail = true));
      }
    }
  }

  // Partial-success update, so one failing record doesn't block the others
  public virtual class RecordWriter {
    public virtual List<Database.SaveResult> updateRecords(List<SObject> records) {
      if (records.isEmpty()) {
        return new List<Database.SaveResult>();
      }
      return Database.update(records, false);
    }
  }
}
