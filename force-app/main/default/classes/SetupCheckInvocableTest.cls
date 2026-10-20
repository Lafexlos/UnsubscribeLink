@isTest
private class SetupCheckInvocableTest {
  private static final String EMAIL_DOMAIN = '@setupcheck.example.com';
  private static final String UNKNOWN_ADDRESS = 'nobody' + EMAIL_DOMAIN;

  private static SetupCheckInvocable.SetupCheckResult runSingle(
    Id siteId,
    String address
  ) {
    SetupCheckInvocable.SetupCheckRequest request = new SetupCheckInvocable.SetupCheckRequest();
    request.siteId = siteId;
    request.orgWideEmailAddress = address;
    List<SetupCheckInvocable.SetupCheckResult> results = SetupCheckInvocable.runSetupCheck(
      new List<SetupCheckInvocable.SetupCheckRequest>{ request }
    );
    Assert.areEqual(1, results.size(), 'Expected one result per request');
    return results[0];
  }

  private static Site buildSite(String status, String siteType, String path) {
    return (Site) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{ 'type' => 'Site' },
          'Status' => status,
          'SiteType' => siteType,
          'UrlPathPrefix' => path
        }
      ),
      Site.class
    );
  }

  private static List<SObject> buildNetworks(String status, String path) {
    return (List<SObject>) JSON.deserialize(
      JSON.serialize(
        new List<Object>{
          new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Network' },
            'Status' => status,
            'UrlPathPrefix' => path
          }
        }
      ),
      List<SObject>.class
    );
  }

  @isTest
  static void publicIdsAllSetPasses() {
    insert new Contact(
      LastName = 'Set',
      Email = 'contact' + EMAIL_DOMAIN,
      Public_Id__c = 'contact-public-id'
    );
    insert new Lead(
      LastName = 'Set',
      Company = 'Setup Check',
      Email = 'lead' + EMAIL_DOMAIN,
      Public_Id__c = 'lead-public-id'
    );
    // Records without an email address are not counted.
    insert new Contact(LastName = 'No Email');

    Test.startTest();
    SetupCheckInvocable.SetupCheckResult result = runSingle(null, null);
    Test.stopTest();

    Assert.areEqual(0, result.contactsMissingPublicId, 'No Contact should be missing a Public Id');
    Assert.areEqual(0, result.leadsMissingPublicId, 'No Lead should be missing a Public Id');
    Assert.isTrue(result.allPublicIdsSet, 'Public Id check should pass');
  }

  @isTest
  static void publicIdsMissingFails() {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < 3; i++) {
      contacts.add(new Contact(LastName = 'Missing ' + i, Email = 'c' + i + EMAIL_DOMAIN));
    }
    insert contacts;
    insert new Lead(LastName = 'Missing', Company = 'Setup Check', Email = 'l' + EMAIL_DOMAIN);

    // Automation that assigns Public Ids on save may be active in the org,
    // so compare against what is actually missing after the inserts.
    Integer expectedContacts = [
      SELECT COUNT()
      FROM Contact
      WHERE Email != NULL AND Public_Id__c = NULL
    ];
    Integer expectedLeads = [
      SELECT COUNT()
      FROM Lead
      WHERE Email != NULL AND Public_Id__c = NULL AND IsConverted = FALSE
    ];

    Test.startTest();
    SetupCheckInvocable.SetupCheckResult result = runSingle(null, null);
    Test.stopTest();

    Assert.areEqual(expectedContacts, result.contactsMissingPublicId, 'Contact count should match the records missing a Public Id');
    Assert.areEqual(expectedLeads, result.leadsMissingPublicId, 'Lead count should match the records missing a Public Id');
    Assert.areEqual(
      expectedContacts == 0 && expectedLeads == 0,
      result.allPublicIdsSet,
      'Public Id check should fail when any record is missing a Public Id'
    );
  }

  @isTest
  static void anyMissingPublicIdFailsTheCheck() {
    Assert.isFalse(SetupCheckInvocable.isEveryPublicIdSet(3, 0), 'Missing Contacts should fail');
    Assert.isFalse(SetupCheckInvocable.isEveryPublicIdSet(0, 1), 'Missing Leads should fail');
    Assert.isTrue(SetupCheckInvocable.isEveryPublicIdSet(0, 0), 'Nothing missing should pass');
  }

  @isTest
  static void convertedLeadsAreNotCounted() {
    Lead lead = new Lead(LastName = 'Converted', Company = 'Setup Check', Email = 'conv' + EMAIL_DOMAIN);
    insert lead;
    LeadStatus convertedStatus = [
      SELECT ApiName
      FROM LeadStatus
      WHERE IsConverted = TRUE
      LIMIT 1
    ];
    Database.LeadConvert convert = new Database.LeadConvert();
    convert.setLeadId(lead.Id);
    convert.setConvertedStatus(convertedStatus.ApiName);
    convert.setDoNotCreateOpportunity(true);
    Database.convertLead(convert);
    // The converted Contact gets a Public Id so only the Lead could be counted.
    Contact converted = [SELECT Id FROM Contact WHERE Email = :lead.Email];
    converted.Public_Id__c = 'converted-contact-id';
    update converted;

    Test.startTest();
    SetupCheckInvocable.SetupCheckResult result = runSingle(null, null);
    Test.stopTest();

    Assert.areEqual(0, result.leadsMissingPublicId, 'Converted Leads should not be counted');
    Assert.isTrue(result.allPublicIdsSet, 'Public Id check should pass');
  }

  @isTest
  static void missingSiteAndAddressFail() {
    Test.startTest();
    SetupCheckInvocable.SetupCheckResult result = runSingle(null, UNKNOWN_ADDRESS);
    Test.stopTest();

    Assert.isFalse(result.siteIsPublished, 'Site check should fail without a site');
    Assert.isFalse(result.orgWideEmailIsVerified, 'Unknown address should fail');
  }

  @isTest
  static void blankAddressFails() {
    SetupCheckInvocable.SetupCheckResult result = runSingle(null, '');

    Assert.isFalse(result.orgWideEmailIsVerified, 'Blank address should fail');
  }

  @isTest
  static void verifiedAddressPasses() {
    List<OrgWideEmailAddress> verified = [
      SELECT Address
      FROM OrgWideEmailAddress
      WHERE IsVerified = TRUE
      LIMIT 1
    ];
    if (verified.isEmpty()) {
      // Verification needs a click in a real inbox, so a test can't create one.
      return;
    }

    SetupCheckInvocable.SetupCheckResult result = runSingle(
      null,
      verified[0].Address.toUpperCase()
    );

    Assert.isTrue(result.orgWideEmailIsVerified, 'Verified address should pass, ignoring case');
  }

  @isTest
  static void handlesSeveralRequests() {
    SetupCheckInvocable.SetupCheckRequest first = new SetupCheckInvocable.SetupCheckRequest();
    SetupCheckInvocable.SetupCheckRequest second = new SetupCheckInvocable.SetupCheckRequest();
    second.orgWideEmailAddress = UNKNOWN_ADDRESS;

    Test.startTest();
    List<SetupCheckInvocable.SetupCheckResult> results = SetupCheckInvocable.runSetupCheck(
      new List<SetupCheckInvocable.SetupCheckRequest>{ first, second }
    );
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    Assert.areEqual(2, results.size(), 'Expected one result per request');
    Assert.isTrue(queriesUsed <= 5, 'Queries should not grow with the number of requests');
    Assert.isFalse(results[1].orgWideEmailIsVerified, 'Unknown address should fail');
  }

  @isTest
  static void emptyRequestsReturnEmptyResults() {
    Assert.isTrue(
      SetupCheckInvocable.runSetupCheck(new List<SetupCheckInvocable.SetupCheckRequest>()).isEmpty(),
      'No requests should give no results'
    );
  }

  @isTest
  static void activeSiteWithLiveNetworkPasses() {
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite('Active', 'ChatterNetwork', 'Unsubscribe'),
        buildNetworks('Live', 'Unsubscribe')
      ),
      'Active site with a live network should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite('Active', 'ChatterNetworkPicasso', 'Unsubscribe/s'),
        buildNetworks('Live', 'Unsubscribe')
      ),
      'The /s path of a live network should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite('Active', 'Visualforce', 'unsubscribe'),
        new List<SObject>()
      ),
      'An active non-Experience site should pass'
    );
  }

  @isTest
  static void inactiveOrUnpublishedSiteFails() {
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite('Inactive', 'ChatterNetwork', 'Unsubscribe'),
        buildNetworks('Live', 'Unsubscribe')
      ),
      'Inactive site should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite('Active', 'ChatterNetwork', 'Unsubscribe'),
        buildNetworks('UnderConstruction', 'Unsubscribe')
      ),
      'Site whose network is not live should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite('Active', 'ChatterNetwork', 'Unsubscribe'),
        buildNetworks('Live', 'Other')
      ),
      'Site with no matching network should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(null, new List<SObject>()),
      'Missing site should fail'
    );
  }
}
