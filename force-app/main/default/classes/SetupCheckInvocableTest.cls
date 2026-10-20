@isTest
private class SetupCheckInvocableTest {
  private static final String EMAIL_DOMAIN = '@setupcheck.example.com';
  private static final String UNKNOWN_ADDRESS = 'nobody' + EMAIL_DOMAIN;
  private static final String SITE_LABEL = 'Unsubscribe';
  private static final String SITE_PATH = 'Unsubscribe';

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

  // Shapes below match the Site and Network records of a real Experience site:
  // Site 'Unsubscribe' (ChatterNetwork, path 'Unsubscribe'),
  // Site 'Unsubscribe1' (ChatterNetworkPicasso, path 'Unsubscribe/s') and
  // Network 'Unsubscribe' (path 'Unsubscribe').
  private static Site buildSite(
    String label,
    String status,
    String siteType,
    String path
  ) {
    return (Site) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{ 'type' => 'Site' },
          'MasterLabel' => label,
          'Status' => status,
          'SiteType' => siteType,
          'UrlPathPrefix' => path
        }
      ),
      Site.class
    );
  }

  private static List<SObject> buildNetworks(
    String name,
    String status,
    String path
  ) {
    return (List<SObject>) JSON.deserialize(
      JSON.serialize(
        new List<Object>{
          new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Network' },
            'Name' => name,
            'Status' => status,
            'UrlPathPrefix' => path
          }
        }
      ),
      List<SObject>.class
    );
  }

  private static OrgWideEmailAddress buildAddress(
    String address,
    Boolean isVerified
  ) {
    return (OrgWideEmailAddress) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{
            'type' => 'OrgWideEmailAddress'
          },
          'Address' => address,
          'IsVerified' => isVerified
        }
      ),
      OrgWideEmailAddress.class
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
  static void missingPublicIdsFailTheCheck() {
    // Automation that assigns Public Ids on save makes missing ids impossible
    // to set up with data, so the result is built from fixed counts.
    SetupCheckInvocable.SetupCheckResult result = SetupCheckInvocable.buildResult(
      true,
      true,
      3,
      1
    );

    Assert.areEqual(3, result.contactsMissingPublicId, 'Contact count should be passed through');
    Assert.areEqual(1, result.leadsMissingPublicId, 'Lead count should be passed through');
    Assert.isFalse(result.allPublicIdsSet, 'Public Id check should fail');
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
  static void verifiedAddressPasses() {
    Set<String> verified = SetupCheckInvocable.collectVerifiedAddresses(
      new List<OrgWideEmailAddress>{ buildAddress('Sender' + EMAIL_DOMAIN, true) }
    );

    Assert.isTrue(
      SetupCheckInvocable.isAddressVerified('sender' + EMAIL_DOMAIN, verified),
      'Verified address should pass, ignoring case'
    );
  }

  @isTest
  static void unverifiedOrBlankAddressFails() {
    Set<String> verified = SetupCheckInvocable.collectVerifiedAddresses(
      new List<OrgWideEmailAddress>{
        buildAddress('pending' + EMAIL_DOMAIN, false),
        buildAddress('sender' + EMAIL_DOMAIN, true)
      }
    );

    Assert.isFalse(
      SetupCheckInvocable.isAddressVerified('pending' + EMAIL_DOMAIN, verified),
      'Unverified address should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isAddressVerified(UNKNOWN_ADDRESS, verified),
      'Address that is not an org-wide address should fail'
    );
    Assert.isFalse(SetupCheckInvocable.isAddressVerified('', verified), 'Blank address should fail');
    Assert.isFalse(SetupCheckInvocable.isAddressVerified(null, verified), 'Null address should fail');
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
    List<SObject> liveNetwork = buildNetworks(SITE_LABEL, 'Live', SITE_PATH);

    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetwork', SITE_PATH),
        liveNetwork
      ),
      'Active site with a live network should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetworkPicasso', SITE_PATH + '/s'),
        liveNetwork
      ),
      'The /s path of a live network should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetwork', 'unsubscribevforcesite'),
        liveNetwork
      ),
      'A vforcesite path of a live network should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetwork', 'somethingelse'),
        liveNetwork
      ),
      'A site whose label matches a live network name should pass'
    );
    Assert.isTrue(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'Visualforce', 'unsubscribe'),
        new List<SObject>()
      ),
      'An active non-Experience site should pass'
    );
  }

  @isTest
  static void inactiveOrUnpublishedSiteFails() {
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Inactive', 'ChatterNetwork', SITE_PATH),
        buildNetworks(SITE_LABEL, 'Live', SITE_PATH)
      ),
      'Inactive site should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetwork', SITE_PATH),
        buildNetworks(SITE_LABEL, 'UnderConstruction', SITE_PATH)
      ),
      'Site whose network is not live should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(
        buildSite(SITE_LABEL, 'Active', 'ChatterNetwork', SITE_PATH),
        buildNetworks('Other', 'Live', 'other')
      ),
      'Site with no matching network should fail'
    );
    Assert.isFalse(
      SetupCheckInvocable.isSitePublished(null, new List<SObject>()),
      'Missing site should fail'
    );
  }
}
