/**
 * Reads the varRecId value of an Unsubscribe Link. The value is C or L followed
 * by the Public Id of a Contact or Lead. Links from the unmanaged predecessor app
 * carry the 15- or 18-character record Id instead (ADR 0001). Those count only
 * when the Admin turned on Accept_Legacy_Record_Id_Links__c, because record Ids
 * are much easier to guess than Public Ids.
 *
 * Used by the guest's existence check and by the Unsubscribe Request batch, so
 * both accept exactly the same links.
 *
 * Runs without sharing because it only reads the org-wide setup record, which the
 * site guest user can't see.
 */
public without sharing class UnsubscribeLinkValue {
  // Same patterns as the Public_Id_Format validation rule on Unsubscribe__c
  private static final Pattern PUBLIC_ID_PATTERN = Pattern.compile(
    '[CL][0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}'
  );
  private static final Pattern LEGACY_RECORD_ID_PATTERN = Pattern.compile(
    '(003|00Q)[a-zA-Z0-9]{12}([a-zA-Z0-9]{3})?'
  );

  // Contact or Lead, null when the value is not a link this org accepts
  public SObjectType objectType { get; private set; }
  // The Public Id without its C or L, set for Public Id links
  public String publicId { get; private set; }
  // The record Id, set for legacy links
  public Id recordId { get; private set; }

  public Boolean isValid() {
    return objectType != null;
  }

  public static UnsubscribeLinkValue parse(
    String value,
    Boolean acceptLegacyRecordIds
  ) {
    UnsubscribeLinkValue link = new UnsubscribeLinkValue();
    if (String.isBlank(value)) {
      return link;
    }
    String trimmed = value.trim();
    if (PUBLIC_ID_PATTERN.matcher(trimmed).matches()) {
      String letter = trimmed.left(1);
      link.objectType = letter == UnsubscribeLinkBuilder.CONTACT_LETTER
        ? Contact.SObjectType
        : Lead.SObjectType;
      link.publicId = trimmed.substring(1);
      return link;
    }
    if (
      acceptLegacyRecordIds &&
      LEGACY_RECORD_ID_PATTERN.matcher(trimmed).matches()
    ) {
      link.setLegacyRecordId(trimmed);
    }
    return link;
  }

  private void setLegacyRecordId(String value) {
    try {
      Id parsed = Id.valueOf(value);
      SObjectType parsedType = parsed.getSObjectType();
      if (parsedType == Contact.SObjectType || parsedType == Lead.SObjectType) {
        objectType = parsedType;
        recordId = parsed;
      }
    } catch (StringException e) {
      // An 18-character value with a wrong case suffix is not an Id
      objectType = null;
    }
  }

  // Blank or missing setup means legacy links are off, the safe default
  public static Boolean legacyRecordIdsAccepted() {
    List<Unsubscribe_Link_Setup__c> setups = [
      SELECT Accept_Legacy_Record_Id_Links__c
      FROM Unsubscribe_Link_Setup__c
      ORDER BY CreatedDate
      LIMIT 1
    ];
    return !setups.isEmpty() && setups[0].Accept_Legacy_Record_Id_Links__c;
  }
}
