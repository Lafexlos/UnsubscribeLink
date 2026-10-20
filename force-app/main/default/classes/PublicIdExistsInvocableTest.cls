@IsTest
private class PublicIdExistsInvocableTest {
  private static final Integer BULK_SIZE = 200;

  private static List<Boolean> check(List<String> linkValues) {
    List<PublicIdExistsInvocable.LinkCheckRequest> requests = new List<PublicIdExistsInvocable.LinkCheckRequest>();
    for (String linkValue : linkValues) {
      PublicIdExistsInvocable.LinkCheckRequest request = new PublicIdExistsInvocable.LinkCheckRequest();
      request.linkValue = linkValue;
      requests.add(request);
    }
    List<Boolean> answers = new List<Boolean>();
    for (PublicIdExistsInvocable.LinkCheckResult result : PublicIdExistsInvocable.checkLinks(requests)) {
      answers.add(result.linkExists);
    }
    Assert.areEqual(linkValues.size(), answers.size(), 'Expected one result per request');
    return answers;
  }

  private static Contact insertContact() {
    Contact contact = new Contact(LastName = 'Exists', Email = 'exists@check.example.com');
    insert contact;
    return [SELECT Id, Public_Id__c FROM Contact WHERE Id = :contact.Id];
  }

  private static Lead insertLead() {
    Lead lead = new Lead(LastName = 'Exists', Company = 'Check', Email = 'lead@check.example.com');
    insert lead;
    return [SELECT Id, Public_Id__c FROM Lead WHERE Id = :lead.Id];
  }

  @IsTest
  static void existingContactAndLeadLinksPass() {
    Contact contact = insertContact();
    Lead lead = insertLead();

    List<Boolean> answers = check(
      new List<String>{
        UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c,
        UnsubscribeLinkBuilder.LEAD_LETTER + lead.Public_Id__c
      }
    );

    Assert.isTrue(answers[0], 'Contact link should exist');
    Assert.isTrue(answers[1], 'Lead link should exist');
  }

  @IsTest
  static void wrongLetterOrUnknownIdFails() {
    Contact contact = insertContact();

    List<Boolean> answers = check(
      new List<String>{
        UnsubscribeLinkBuilder.LEAD_LETTER + contact.Public_Id__c,
        UnsubscribeLinkBuilder.CONTACT_LETTER + UUID.randomUUID().toString()
      }
    );

    Assert.isFalse(answers[0], 'A Contact Public Id with L should not match');
    Assert.isFalse(answers[1], 'An unknown Public Id should not match');
  }

  @IsTest
  static void malformedValuesFailWithoutQueries() {
    Test.startTest();
    List<Boolean> answers = check(new List<String>{ null, '', 'not-a-link', 'C1234', '<script>' });
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    for (Boolean answer : answers) {
      Assert.isFalse(answer, 'Malformed values should fail');
    }
    Assert.areEqual(1, queriesUsed, 'Only the setup record should be read');
  }

  @IsTest
  static void deletedRecordFails() {
    Contact contact = insertContact();
    String linkValue = UnsubscribeLinkBuilder.CONTACT_LETTER + contact.Public_Id__c;
    delete contact;

    Assert.isFalse(check(new List<String>{ linkValue })[0], 'A deleted record should not count');
  }

  @IsTest
  static void legacyRecordIdNeedsTheSetting() {
    Contact contact = insertContact();
    String legacyValue = String.valueOf(contact.Id).left(15);

    Boolean withoutSetting = check(new List<String>{ legacyValue })[0];
    insert new Unsubscribe_Link_Setup__c(Accept_Legacy_Record_Id_Links__c = true);
    Boolean withSetting = check(new List<String>{ legacyValue })[0];

    Assert.isFalse(withoutSetting, 'Legacy links are off by default');
    Assert.isTrue(withSetting, 'Legacy links work once the Admin turns them on');
  }

  @IsTest
  static void legacyLeadIdOfAnotherObjectFails() {
    insert new Unsubscribe_Link_Setup__c(Accept_Legacy_Record_Id_Links__c = true);
    Account account = new Account(Name = 'Not a person');
    insert account;

    Assert.isFalse(check(new List<String>{ String.valueOf(account.Id) })[0], 'Only Contact and Lead Ids count');
  }

  @IsTest
  static void bulkChecksUseConstantQueries() {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < BULK_SIZE; i++) {
      contacts.add(new Contact(LastName = 'Bulk ' + i));
    }
    insert contacts;
    List<String> linkValues = new List<String>();
    for (Contact c : [SELECT Public_Id__c FROM Contact]) {
      linkValues.add(UnsubscribeLinkBuilder.CONTACT_LETTER + c.Public_Id__c);
    }

    Test.startTest();
    List<Boolean> answers = check(linkValues);
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    Assert.isFalse(answers.contains(false), 'Every link should exist');
    Assert.isTrue(queriesUsed <= 3, 'Queries should not grow with the number of links, used ' + queriesUsed);
  }

  @IsTest
  static void emptyRequestsReturnEmptyResults() {
    Assert.isTrue(
      PublicIdExistsInvocable.checkLinks(new List<PublicIdExistsInvocable.LinkCheckRequest>()).isEmpty(),
      'No requests should give no results'
    );
  }
}
