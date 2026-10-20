@IsTest
private class PublicIdTriggerHandlerTest {
  private static final Integer BULK_SIZE = 250;
  private static final Integer UUID_LENGTH = 36;
  private static final Integer MAX_QUERIES_PER_TRANSACTION = 2;
  private static final String SITE_DOMAIN = 'example.my.site.com';
  private static final String LINK_TEXT = 'Click here to unsubscribe.';
  private static final String EXISTING_PUBLIC_ID = 'existing-public-id';
  private static final String EXISTING_LINK = 'https://example.com/unsubscribe+keep me';

  private static String expectedLink(String objectTypeLetter, String publicId) {
    return 'https://' +
      SITE_DOMAIN +
      '/Unsubscribe/s/unsubscribe?varRecId=' +
      objectTypeLetter +
      publicId +
      '+' +
      LINK_TEXT;
  }

  private static List<Contact> buildContacts(Integer count) {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < count; i++) {
      contacts.add(new Contact(LastName = 'Trigger Contact ' + i));
    }
    return contacts;
  }

  private static List<Lead> buildLeads(Integer count) {
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < count; i++) {
      leads.add(new Lead(LastName = 'Trigger Lead ' + i, Company = 'Test Co'));
    }
    return leads;
  }

  private static void setAssignmentDisabled(Boolean isDisabled) {
    Unsubscribe_Link_Settings__c settings = Unsubscribe_Link_Settings__c.getOrgDefaults();
    settings.Disable_Public_Id_Assignment__c = isDisabled;
    upsert settings;
  }

  @IsTest
  static void testBulkInsertContactsSetsPublicIdAndLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);

    // Act
    Test.startTest();
    insert buildContacts(BULK_SIZE);
    Test.stopTest();

    // Assert
    Set<String> publicIds = new Set<String>();
    for (Contact c : [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact]) {
      Assert.areEqual(UUID_LENGTH, c.Public_Id__c.length(), 'Public Id should be a UUID');
      Assert.areEqual(
        expectedLink(UnsubscribeLinkBuilder.CONTACT_LETTER, c.Public_Id__c),
        c.Part1_Unsubscribe_Link__c,
        'Link should match the format of the replaced flow'
      );
      publicIds.add(c.Public_Id__c);
    }
    Assert.areEqual(BULK_SIZE, publicIds.size(), 'Every Contact should get its own Public Id');
  }

  @IsTest
  static void testBulkInsertLeadsSetsPublicIdAndLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);

    // Act
    Test.startTest();
    insert buildLeads(BULK_SIZE);
    Test.stopTest();

    // Assert
    Set<String> publicIds = new Set<String>();
    for (Lead l : [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Lead]) {
      Assert.areEqual(UUID_LENGTH, l.Public_Id__c.length(), 'Public Id should be a UUID');
      Assert.areEqual(
        expectedLink(UnsubscribeLinkBuilder.LEAD_LETTER, l.Public_Id__c),
        l.Part1_Unsubscribe_Link__c,
        'Link should match the format of the replaced flow'
      );
      publicIds.add(l.Public_Id__c);
    }
    Assert.areEqual(BULK_SIZE, publicIds.size(), 'Every Lead should get its own Public Id');
  }

  @IsTest
  static void testBulkInsertUsesConstantNumberOfQueries() {
    // Arrange
    TestDataFactory.createULSetup();
    List<Contact> contacts = buildContacts(BULK_SIZE);
    List<Lead> leads = buildLeads(BULK_SIZE);

    // Act
    Test.startTest();
    insert contacts;
    insert leads;
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    // Assert
    Assert.isTrue(
      queriesUsed <= MAX_QUERIES_PER_TRANSACTION,
      'Trigger should query the setup record and site once, used ' + queriesUsed
    );
  }

  @IsTest
  static void testInsertWithSetupRecordUsesUnsubscribeSiteDomain() {
    // Arrange
    TestDataFactory.createULSetup();
    List<DomainSite> domainSites = [
      SELECT Domain.Domain
      FROM DomainSite
      WHERE Site.Name = :UnsubscribeLinkBuilder.SITE_NAME
      LIMIT 1
    ];

    // Act
    Test.startTest();
    insert buildContacts(1);
    Test.stopTest();

    // Assert
    Contact c = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact];
    Assert.areEqual(UUID_LENGTH, c.Public_Id__c.length(), 'Public Id should be a UUID');
    if (domainSites.isEmpty()) {
      Assert.isNull(c.Part1_Unsubscribe_Link__c, 'Without a site the link should stay blank');
    } else {
      String expected = UnsubscribeLinkBuilder.buildLink(
        UnsubscribeLinkBuilder.siteBaseUrlForDomain(domainSites[0].Domain.Domain),
        UnsubscribeLinkBuilder.CONTACT_LETTER,
        c.Public_Id__c,
        'Click here to unsubscribe'
      );
      Assert.areEqual(expected, c.Part1_Unsubscribe_Link__c, 'Link should use the Unsubscribe site domain');
    }
  }

  @IsTest
  static void testInsertKeepsExistingPublicIdAndLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);
    Contact contact = new Contact(
      LastName = 'Existing',
      Public_Id__c = EXISTING_PUBLIC_ID,
      Part1_Unsubscribe_Link__c = EXISTING_LINK
    );

    // Act
    Test.startTest();
    insert contact;
    Test.stopTest();

    // Assert
    Contact saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];
    Assert.areEqual(EXISTING_PUBLIC_ID, saved.Public_Id__c, 'An existing Public Id must never change');
    Assert.areEqual(EXISTING_LINK, saved.Part1_Unsubscribe_Link__c, 'An existing link must not change');
  }

  @IsTest
  static void testUpdateSetsPublicIdWhenRecordNeverHadOne() {
    // Arrange
    setAssignmentDisabled(true);
    Lead lead = buildLeads(1)[0];
    insert lead;
    setAssignmentDisabled(false);
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);

    // Act
    Test.startTest();
    lead.FirstName = 'Updated';
    update lead;
    Test.stopTest();

    // Assert
    Lead saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Lead WHERE Id = :lead.Id];
    Assert.areEqual(UUID_LENGTH, saved.Public_Id__c.length(), 'Update should set a missing Public Id');
    Assert.areEqual(
      expectedLink(UnsubscribeLinkBuilder.LEAD_LETTER, saved.Public_Id__c),
      saved.Part1_Unsubscribe_Link__c,
      'Update should set the link with the new Public Id'
    );
  }

  @IsTest
  static void testUpdateKeepsExistingPublicId() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);
    Contact contact = buildContacts(1)[0];
    insert contact;
    Contact inserted = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];

    // Act
    Test.startTest();
    inserted.FirstName = 'Updated';
    update inserted;
    Test.stopTest();

    // Assert
    Contact saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];
    Assert.areEqual(inserted.Public_Id__c, saved.Public_Id__c, 'Update must not change the Public Id');
    Assert.areEqual(
      inserted.Part1_Unsubscribe_Link__c,
      saved.Part1_Unsubscribe_Link__c,
      'Update must not change the link'
    );
  }

  @IsTest
  static void testUpdateClearingPublicIdRestoresIdAndLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);
    Contact contact = buildContacts(1)[0];
    insert contact;
    Contact inserted = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];

    // Act
    Test.startTest();
    update new Contact(Id = contact.Id, Public_Id__c = null, Part1_Unsubscribe_Link__c = null);
    Test.stopTest();

    // Assert
    Contact saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];
    Assert.areEqual(inserted.Public_Id__c, saved.Public_Id__c, 'A cleared Public Id should get its old value back');
    Assert.areEqual(
      inserted.Part1_Unsubscribe_Link__c,
      saved.Part1_Unsubscribe_Link__c,
      'A cleared link should get its old value back'
    );
  }

  @IsTest
  static void testUpdateClearingPublicIdWithBypassOnRestoresIdAndLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);
    Lead lead = buildLeads(1)[0];
    insert lead;
    Lead inserted = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Lead WHERE Id = :lead.Id];
    setAssignmentDisabled(true);

    // Act
    Test.startTest();
    update new Lead(Id = lead.Id, Public_Id__c = null, Part1_Unsubscribe_Link__c = null);
    Test.stopTest();

    // Assert
    Lead saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Lead WHERE Id = :lead.Id];
    Assert.areEqual(inserted.Public_Id__c, saved.Public_Id__c, 'Bypass must not stop a cleared Public Id from being restored');
    Assert.areEqual(
      inserted.Part1_Unsubscribe_Link__c,
      saved.Part1_Unsubscribe_Link__c,
      'Bypass must not stop a cleared link from being restored'
    );
  }

  @IsTest
  static void testUpdateClearingOnlyPublicIdKeepsNewLink() {
    // Arrange
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);
    Contact contact = buildContacts(1)[0];
    insert contact;
    Contact inserted = [SELECT Public_Id__c FROM Contact WHERE Id = :contact.Id];

    // Act
    Test.startTest();
    update new Contact(Id = contact.Id, Public_Id__c = null, Part1_Unsubscribe_Link__c = EXISTING_LINK);
    Test.stopTest();

    // Assert
    Contact saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :contact.Id];
    Assert.areEqual(inserted.Public_Id__c, saved.Public_Id__c, 'A cleared Public Id should get its old value back');
    Assert.areEqual(EXISTING_LINK, saved.Part1_Unsubscribe_Link__c, 'A link set in the same update should be kept');
  }

  @IsTest
  static void testBypassForCurrentUserSkipsAssignment() {
    // Arrange
    insert new Unsubscribe_Link_Settings__c(
      SetupOwnerId = UserInfo.getUserId(),
      Disable_Public_Id_Assignment__c = true
    );
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, LINK_TEXT);

    // Act
    Test.startTest();
    insert buildContacts(BULK_SIZE);
    insert buildLeads(BULK_SIZE);
    Test.stopTest();

    // Assert
    List<Contact> stampedContacts = [SELECT Id FROM Contact WHERE Public_Id__c != NULL OR Part1_Unsubscribe_Link__c != NULL];
    List<Lead> stampedLeads = [SELECT Id FROM Lead WHERE Public_Id__c != NULL OR Part1_Unsubscribe_Link__c != NULL];
    Assert.isTrue(stampedContacts.isEmpty(), 'Bypass should leave Contacts without Public Id and link');
    Assert.isTrue(stampedLeads.isEmpty(), 'Bypass should leave Leads without Public Id and link');
  }

  @IsTest
  static void testNoSetupRecordSetsPublicIdOnly() {
    // Arrange: no Unsubscribe_Link_Setup__c record exists
    Contact withoutLink = new Contact(LastName = 'No Link');
    Contact withLink = new Contact(LastName = 'Old Link', Part1_Unsubscribe_Link__c = EXISTING_LINK);

    // Act
    Test.startTest();
    insert new List<Contact>{ withoutLink, withLink };
    Test.stopTest();

    // Assert
    Contact savedWithoutLink = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :withoutLink.Id];
    Contact savedWithLink = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact WHERE Id = :withLink.Id];
    Assert.areEqual(UUID_LENGTH, savedWithoutLink.Public_Id__c.length(), 'Public Id should be set before setup runs');
    Assert.isNull(savedWithoutLink.Part1_Unsubscribe_Link__c, 'Link should stay blank before setup runs');
    Assert.areEqual(EXISTING_LINK, savedWithLink.Part1_Unsubscribe_Link__c, 'Handler should not clear a link it cannot build');
  }

  @IsTest
  static void testLongLinkTextIsCutToFieldLength() {
    // Arrange
    Integer maxLength = Contact.Part1_Unsubscribe_Link__c.getDescribe().getLength();
    PublicIdTriggerHandler.useLinkSettings(SITE_DOMAIN, 'x'.repeat(maxLength));

    // Act
    Test.startTest();
    insert buildContacts(1);
    Test.stopTest();

    // Assert
    Contact saved = [SELECT Public_Id__c, Part1_Unsubscribe_Link__c FROM Contact];
    Assert.areEqual(maxLength, saved.Part1_Unsubscribe_Link__c.length(), 'Link should be cut to the field length');
    Assert.isTrue(
      saved.Part1_Unsubscribe_Link__c.startsWith(
        'https://' + SITE_DOMAIN + '/Unsubscribe/s/unsubscribe?varRecId=C' + saved.Public_Id__c + '+'
      ),
      'Cutting should only shorten the link text'
    );
  }
}
