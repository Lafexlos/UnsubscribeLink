/**
 * Runs the checks shown on the setup check screen of the Unsubscribe Link Setup flow.
 * Runs without sharing so the Public Id counts cover every Contact and Lead, not only
 * the ones the running user can see. It returns only booleans and counts.
 */
public without sharing class SetupCheckInvocable {
  private static final String SITE_STATUS_ACTIVE = 'Active';
  private static final String NETWORK_STATUS_LIVE = 'Live';
  private static final String NETWORK_SITE_TYPE_PREFIX = 'ChatterNetwork';
  private static final String NETWORK_PATH_SUFFIX = '/s';
  // Dynamic query so the class still compiles in orgs without Experience Cloud.
  private static final String NETWORK_QUERY = 'SELECT Id, Status, UrlPathPrefix FROM Network';

  @InvocableMethod(
    label='Run Unsubscribe Link Setup Check'
    description='Checks the site, the org-wide email address and the Public Ids on Contacts and Leads'
  )
  public static List<SetupCheckResult> runSetupCheck(
    List<SetupCheckRequest> requests
  ) {
    List<SetupCheckResult> results = new List<SetupCheckResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }

    Set<Id> siteIds = new Set<Id>();
    Set<String> addresses = new Set<String>();
    for (SetupCheckRequest request : requests) {
      if (request.siteId != null) {
        siteIds.add(request.siteId);
      }
      if (String.isNotBlank(request.orgWideEmailAddress)) {
        addresses.add(request.orgWideEmailAddress.toLowerCase());
      }
    }

    Map<Id, Site> sitesById = new Map<Id, Site>(
      [
        SELECT Id, Status, SiteType, UrlPathPrefix
        FROM Site
        WHERE Id IN :siteIds
      ]
    );
    List<SObject> networks = siteIds.isEmpty()
      ? new List<SObject>()
      : queryNetworks();
    Set<String> verifiedAddresses = getVerifiedAddresses(addresses);

    // COUNT() uses one query row, so this works for orgs of any size.
    Integer contactsMissing = [
      SELECT COUNT()
      FROM Contact
      WHERE Email != NULL AND Public_Id__c = NULL
    ];
    Integer leadsMissing = [
      SELECT COUNT()
      FROM Lead
      WHERE Email != NULL AND Public_Id__c = NULL AND IsConverted = FALSE
    ];

    for (SetupCheckRequest request : requests) {
      SetupCheckResult result = new SetupCheckResult();
      result.siteIsPublished = isSitePublished(
        sitesById.get(request.siteId),
        networks
      );
      result.orgWideEmailIsVerified =
        String.isNotBlank(request.orgWideEmailAddress) &&
        verifiedAddresses.contains(request.orgWideEmailAddress.toLowerCase());
      result.contactsMissingPublicId = contactsMissing;
      result.leadsMissingPublicId = leadsMissing;
      result.allPublicIdsSet = isEveryPublicIdSet(contactsMissing, leadsMissing);
      results.add(result);
    }
    return results;
  }

  @TestVisible
  private static Boolean isEveryPublicIdSet(
    Integer contactsMissing,
    Integer leadsMissing
  ) {
    return contactsMissing == 0 && leadsMissing == 0;
  }

  @TestVisible
  private static Boolean isSitePublished(Site site, List<SObject> networks) {
    if (site == null || site.Status != SITE_STATUS_ACTIVE) {
      return false;
    }
    if (
      site.SiteType == null ||
      !site.SiteType.startsWith(NETWORK_SITE_TYPE_PREFIX)
    ) {
      return true;
    }
    String sitePath = normalizePath(site.UrlPathPrefix);
    for (SObject network : networks) {
      if (normalizePath((String) network.get('UrlPathPrefix')) == sitePath) {
        return (String) network.get('Status') == NETWORK_STATUS_LIVE;
      }
    }
    return false;
  }

  private static String normalizePath(String path) {
    if (String.isBlank(path)) {
      return '';
    }
    return path.removeEnd(NETWORK_PATH_SUFFIX);
  }

  private static List<SObject> queryNetworks() {
    if (Schema.getGlobalDescribe().get('Network') == null) {
      return new List<SObject>();
    }
    return Database.query(NETWORK_QUERY);
  }

  private static Set<String> getVerifiedAddresses(Set<String> addresses) {
    Set<String> verified = new Set<String>();
    if (addresses.isEmpty()) {
      return verified;
    }
    for (OrgWideEmailAddress owa : [
      SELECT Address
      FROM OrgWideEmailAddress
      WHERE Address IN :addresses AND IsVerified = TRUE
    ]) {
      verified.add(owa.Address.toLowerCase());
    }
    return verified;
  }

  public class SetupCheckRequest {
    @InvocableVariable(
      required=false
      label='Site Id'
      description='Id of the Experience site that hosts the unsubscribe page'
    )
    public Id siteId;

    @InvocableVariable(
      required=false
      label='Org-Wide Email Address'
      description='Address that sends the confirmation emails'
    )
    public String orgWideEmailAddress;
  }

  public class SetupCheckResult {
    @InvocableVariable(
      label='Site Is Published'
      description='True when the site exists, is active and its Experience Cloud site is live'
    )
    public Boolean siteIsPublished;

    @InvocableVariable(
      label='Org-Wide Email Is Verified'
      description='True when the org-wide email address exists and is verified'
    )
    public Boolean orgWideEmailIsVerified;

    @InvocableVariable(
      label='All Public Ids Set'
      description='True when every Contact and unconverted Lead with an email address has a Public Id'
    )
    public Boolean allPublicIdsSet;

    @InvocableVariable(
      label='Contacts Missing Public Id'
      description='Number of Contacts with an email address and no Public Id'
    )
    public Integer contactsMissingPublicId;

    @InvocableVariable(
      label='Leads Missing Public Id'
      description='Number of unconverted Leads with an email address and no Public Id'
    )
    public Integer leadsMissingPublicId;
  }
}
