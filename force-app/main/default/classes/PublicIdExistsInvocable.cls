/**
 * The guest's existence check (ADR 0002). Tells the unsubscribe flow whether the
 * varRecId value of an Unsubscribe Link belongs to a Contact or Lead, and nothing
 * else about the record.
 *
 * Checks the format first, so junk values cost no query. Legacy record Id links
 * count only when the Admin turned on Accept_Legacy_Record_Id_Links__c. Deleted
 * records don't count. Converted Leads do, because a link sent before the
 * conversion must keep working (ADR 0001).
 *
 * Runs without sharing because the site guest user can't see Contacts or Leads.
 * It reads by exact Public Id or record Id and returns only true or false.
 */
public without sharing class PublicIdExistsInvocable {
  @InvocableMethod(
    label='Check Unsubscribe Link Exists'
    description='Returns true when the link value matches a Contact or Lead. Returns nothing else about the record.'
  )
  public static List<LinkCheckResult> checkLinks(List<LinkCheckRequest> requests) {
    List<LinkCheckResult> results = new List<LinkCheckResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }

    Boolean acceptLegacyRecordIds = UnsubscribeLinkValue.legacyRecordIdsAccepted();
    List<UnsubscribeLinkValue> links = new List<UnsubscribeLinkValue>();
    Set<String> contactPublicIds = new Set<String>();
    Set<String> leadPublicIds = new Set<String>();
    Set<Id> contactIds = new Set<Id>();
    Set<Id> leadIds = new Set<Id>();
    for (LinkCheckRequest request : requests) {
      UnsubscribeLinkValue link = UnsubscribeLinkValue.parse(
        request?.linkValue,
        acceptLegacyRecordIds
      );
      links.add(link);
      if (!link.isValid()) {
        continue;
      }
      Boolean isContact = link.objectType == Contact.SObjectType;
      if (link.recordId != null) {
        (isContact ? contactIds : leadIds).add(link.recordId);
      } else {
        (isContact ? contactPublicIds : leadPublicIds).add(link.publicId);
      }
    }

    Set<String> foundKeys = findExistingKeys(
      contactPublicIds,
      leadPublicIds,
      contactIds,
      leadIds
    );
    for (UnsubscribeLinkValue link : links) {
      LinkCheckResult result = new LinkCheckResult();
      result.linkExists = link.isValid() && foundKeys.contains(keyFor(link));
      results.add(result);
    }
    return results;
  }

  private static Set<String> findExistingKeys(
    Set<String> contactPublicIds,
    Set<String> leadPublicIds,
    Set<Id> contactIds,
    Set<Id> leadIds
  ) {
    Set<String> keys = new Set<String>();
    if (!contactPublicIds.isEmpty() || !contactIds.isEmpty()) {
      for (Contact c : [
        SELECT Id, Public_Id__c
        FROM Contact
        WHERE Public_Id__c IN :contactPublicIds OR Id IN :contactIds
      ]) {
        addKeys(keys, c, Contact.SObjectType);
      }
    }
    if (!leadPublicIds.isEmpty() || !leadIds.isEmpty()) {
      for (Lead l : [
        SELECT Id, Public_Id__c
        FROM Lead
        WHERE Public_Id__c IN :leadPublicIds OR Id IN :leadIds
      ]) {
        addKeys(keys, l, Lead.SObjectType);
      }
    }
    return keys;
  }

  private static void addKeys(
    Set<String> keys,
    SObject record,
    SObjectType objectType
  ) {
    keys.add(String.valueOf(record.Id));
    String publicId = (String) record.get('Public_Id__c');
    if (String.isNotBlank(publicId)) {
      keys.add(objectType + ':' + publicId);
    }
  }

  private static String keyFor(UnsubscribeLinkValue link) {
    return link.recordId != null
      ? String.valueOf(link.recordId)
      : link.objectType + ':' + link.publicId;
  }

  public class LinkCheckRequest {
    @InvocableVariable(
      required=false
      label='Link Value'
      description='The varRecId value from the Unsubscribe Link'
    )
    public String linkValue;
  }

  public class LinkCheckResult {
    @InvocableVariable(
      label='Link Exists'
      description='True when the link value matches a Contact or Lead'
    )
    public Boolean linkExists;
  }
}
