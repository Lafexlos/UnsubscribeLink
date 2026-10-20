/**
 * Runs the checks shown on the setup check screen of the Unsubscribe Link Setup flow.
 * It also checks that the Unsubscribe Request batch is scheduled, not in an error
 * state, and owned by an active user, because the job stops when its owner is
 * deactivated (ADR 0002).
 * Runs without sharing so the Public Id counts cover every Contact and Lead, not only
 * the ones the running user can see. It returns only booleans and counts.
 */
public without sharing class SetupCheckInvocable {
  private static final String SITE_STATUS_ACTIVE = 'Active';
  private static final String NETWORK_STATUS_LIVE = 'Live';
  private static final String NETWORK_SITE_TYPE_PREFIX = 'ChatterNetwork';
  // Experience site paths can carry a '/s' or 'vforcesite' suffix that the Network path lacks.
  private static final List<String> SITE_PATH_SUFFIXES = new List<String>{
    '/s',
    'vforcesite'
  };
  // Dynamic query so the class still compiles in orgs without Experience Cloud.
  private static final String NETWORK_QUERY = 'SELECT Id, Name, Status, UrlPathPrefix FROM Network';
  // CronTrigger states in which the job will not run again
  private static final Set<String> BROKEN_JOB_STATES = new Set<String>{
    'ERROR',
    'COMPLETE',
    'DELETED'
  };

  @InvocableMethod(
    label='Run Unsubscribe Link Setup Check'
    description='Checks the site, the org-wide email address, the Public Ids on Contacts and Leads, and the scheduled Unsubscribe Request batch'
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
        SELECT Id, MasterLabel, Status, SiteType, UrlPathPrefix
        FROM Site
        WHERE Id IN :siteIds
      ]
    );
    List<SObject> networks = siteIds.isEmpty()
      ? new List<SObject>()
      : queryNetworks();
    Set<String> verifiedAddresses = collectVerifiedAddresses(
      queryOrgWideAddresses(addresses)
    );

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
    Boolean batchIsScheduled = isBatchScheduled();

    for (SetupCheckRequest request : requests) {
      results.add(
        buildResult(
          isSitePublished(sitesById.get(request.siteId), networks),
          isAddressVerified(request.orgWideEmailAddress, verifiedAddresses),
          contactsMissing,
          leadsMissing,
          batchIsScheduled
        )
      );
    }
    return results;
  }

  @TestVisible
  private static SetupCheckResult buildResult(
    Boolean siteIsPublished,
    Boolean orgWideEmailIsVerified,
    Integer contactsMissing,
    Integer leadsMissing,
    Boolean batchIsScheduled
  ) {
    SetupCheckResult result = new SetupCheckResult();
    result.batchIsScheduled = batchIsScheduled;
    result.siteIsPublished = siteIsPublished;
    result.orgWideEmailIsVerified = orgWideEmailIsVerified;
    result.contactsMissingPublicId = contactsMissing;
    result.leadsMissingPublicId = leadsMissing;
    result.allPublicIdsSet = isEveryPublicIdSet(contactsMissing, leadsMissing);
    return result;
  }

  private static Boolean isBatchScheduled() {
    List<CronTrigger> jobs = [
      SELECT State, OwnerId
      FROM CronTrigger
      WHERE CronJobDetail.Name = :ScheduleRequestBatchInvocable.JOB_NAME
      LIMIT 1
    ];
    if (jobs.isEmpty()) {
      return false;
    }
    // CronTrigger has no Owner relationship, so the owner is read separately
    List<User> owners = [
      SELECT IsActive
      FROM User
      WHERE Id = :jobs[0].OwnerId
    ];
    return isJobHealthy(
      jobs[0].State,
      !owners.isEmpty() && owners[0].IsActive
    );
  }

  @TestVisible
  private static Boolean isJobHealthy(String state, Boolean ownerIsActive) {
    return String.isNotBlank(state) &&
      !BROKEN_JOB_STATES.contains(state) &&
      ownerIsActive;
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
    SObject network = findNetwork(site, networks);
    return network != null &&
      (String) network.get('Status') == NETWORK_STATUS_LIVE;
  }

  // Network has no field that points to its Site, so match on the path first
  // and fall back to the site label, which Salesforce sets to the Network name.
  private static SObject findNetwork(Site site, List<SObject> networks) {
    String sitePath = normalizePath(site.UrlPathPrefix);
    for (SObject network : networks) {
      if (normalizePath((String) network.get('UrlPathPrefix')) == sitePath) {
        return network;
      }
    }
    for (SObject network : networks) {
      String networkName = (String) network.get('Name');
      if (
        String.isNotBlank(networkName) &&
        networkName.equalsIgnoreCase(site.MasterLabel)
      ) {
        return network;
      }
    }
    return null;
  }

  private static String normalizePath(String path) {
    if (String.isBlank(path)) {
      return '';
    }
    String normalized = path.toLowerCase();
    for (String suffix : SITE_PATH_SUFFIXES) {
      normalized = normalized.removeEnd(suffix);
    }
    return normalized;
  }

  private static List<SObject> queryNetworks() {
    if (Schema.getGlobalDescribe().get('Network') == null) {
      return new List<SObject>();
    }
    return Database.query(NETWORK_QUERY);
  }

  private static List<OrgWideEmailAddress> queryOrgWideAddresses(
    Set<String> addresses
  ) {
    if (addresses.isEmpty()) {
      return new List<OrgWideEmailAddress>();
    }
    return [
      SELECT Address, IsVerified
      FROM OrgWideEmailAddress
      WHERE Address IN :addresses
    ];
  }

  @TestVisible
  private static Set<String> collectVerifiedAddresses(
    List<OrgWideEmailAddress> records
  ) {
    Set<String> verified = new Set<String>();
    for (OrgWideEmailAddress owa : records) {
      if (owa.IsVerified && String.isNotBlank(owa.Address)) {
        verified.add(owa.Address.toLowerCase());
      }
    }
    return verified;
  }

  @TestVisible
  private static Boolean isAddressVerified(
    String address,
    Set<String> verifiedAddresses
  ) {
    return String.isNotBlank(address) &&
      verifiedAddresses.contains(address.toLowerCase());
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

    @InvocableVariable(
      label='Batch Is Scheduled'
      description='True when the Unsubscribe Request batch is scheduled, not in an error state, and its owner is active'
    )
    public Boolean batchIsScheduled;
  }
}
