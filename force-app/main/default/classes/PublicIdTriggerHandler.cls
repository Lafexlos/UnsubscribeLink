/**
 * Called from the before insert and before update triggers on Contact and Lead.
 * Gives every record without a Public Id a new one and sets its
 * Part1_Unsubscribe_Link__c. Replaces the Draft flows
 * Contact_After_Create_Update_Set_Public_Id and Lead_After_Create_Update_Set_Public_Id.
 *
 * Without the Unsubscribe Link Setup record or the Unsubscribe site, the record
 * still gets its Public Id and the link is left as it is. The setup flow's
 * backfill batch fills the link later. This handler never blocks a save.
 *
 * Admins can turn it off for large imports with the hierarchy custom setting
 * Unsubscribe_Link_Settings__c.Disable_Public_Id_Assignment__c.
 *
 * Runs without sharing because it only reads the org-wide setup record and the
 * site domain, which every user creating Contacts or Leads needs.
 */
public without sharing class PublicIdTriggerHandler {
  private static final String PUBLIC_ID_FIELD = 'Public_Id__c';
  private static final Map<SObjectType, SObjectField> LINK_FIELDS = new Map<SObjectType, SObjectField>{
    Contact.SObjectType => Contact.Part1_Unsubscribe_Link__c,
    Lead.SObjectType => Lead.Part1_Unsubscribe_Link__c
  };

  // Loaded once per transaction, so the trigger runs at most two queries
  private static LinkSettings linkSettings;

  public static void assignPublicIds(List<SObject> records) {
    if (records == null || records.isEmpty() || isAssignmentDisabled()) {
      return;
    }

    List<SObject> recordsWithoutPublicId = new List<SObject>();
    for (SObject record : records) {
      if (String.isBlank((String) record.get(PUBLIC_ID_FIELD))) {
        // UUIDUtility only fills null values, so clear blank strings first
        record.put(PUBLIC_ID_FIELD, null);
        recordsWithoutPublicId.add(record);
      }
    }
    if (recordsWithoutPublicId.isEmpty()) {
      return;
    }

    UUIDUtility.generateUUIDsForRecords(recordsWithoutPublicId, PUBLIC_ID_FIELD);
    setUnsubscribeLinks(recordsWithoutPublicId);
  }

  private static void setUnsubscribeLinks(List<SObject> records) {
    SObjectType objectType = records[0].getSObjectType();
    SObjectField linkField = LINK_FIELDS.get(objectType);
    String objectTypeLetter = UnsubscribeLinkBuilder.objectTypeLetter(objectType);
    LinkSettings settings = getLinkSettings();
    if (linkField == null || objectTypeLetter == null || !settings.isComplete()) {
      return;
    }

    // A long link text could exceed the field length and fail the save.
    // Cutting the end only shortens the text after '+', the URL stays whole.
    Integer maxLength = linkField.getDescribe().getLength();
    for (SObject record : records) {
      String link = UnsubscribeLinkBuilder.buildLink(
        settings.siteBaseUrl,
        objectTypeLetter,
        (String) record.get(PUBLIC_ID_FIELD),
        settings.linkText
      );
      record.put(linkField, link.left(maxLength));
    }
  }

  private static Boolean isAssignmentDisabled() {
    Unsubscribe_Link_Settings__c settings = Unsubscribe_Link_Settings__c.getInstance();
    return settings != null && settings.Disable_Public_Id_Assignment__c;
  }

  private static LinkSettings getLinkSettings() {
    if (linkSettings == null) {
      linkSettings = loadLinkSettings();
    }
    return linkSettings;
  }

  // Same lookups as the replaced flows: the setup record for the link text,
  // and the domain of the site named Unsubscribe
  private static LinkSettings loadLinkSettings() {
    LinkSettings settings = new LinkSettings();
    try {
      List<Unsubscribe_Link_Setup__c> setups = [
        SELECT Link_Text__c
        FROM Unsubscribe_Link_Setup__c
        ORDER BY CreatedDate
        LIMIT 1
      ];
      if (setups.isEmpty()) {
        return settings;
      }
      List<DomainSite> domainSites = [
        SELECT Domain.Domain
        FROM DomainSite
        WHERE Site.Name = :UnsubscribeLinkBuilder.SITE_NAME
        LIMIT 1
      ];
      if (domainSites.isEmpty()) {
        return settings;
      }
      settings.setValues(domainSites[0].Domain?.Domain, setups[0].Link_Text__c);
    } catch (QueryException e) {
      System.debug(
        LoggingLevel.ERROR,
        'PublicIdTriggerHandler could not read link settings: ' + e.getMessage()
      );
    }
    return settings;
  }

  // Lets tests set a site domain, because test orgs may have no site
  @TestVisible
  private static void useLinkSettings(String siteDomain, String linkText) {
    linkSettings = new LinkSettings();
    linkSettings.setValues(siteDomain, linkText);
  }

  private class LinkSettings {
    private String siteBaseUrl;
    private String linkText;

    private void setValues(String siteDomain, String linkText) {
      if (String.isNotBlank(siteDomain)) {
        this.siteBaseUrl = UnsubscribeLinkBuilder.siteBaseUrlForDomain(siteDomain);
      }
      this.linkText = linkText;
    }

    private Boolean isComplete() {
      return siteBaseUrl != null;
    }
  }
}
