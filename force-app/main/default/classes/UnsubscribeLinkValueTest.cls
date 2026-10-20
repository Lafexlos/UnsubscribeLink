@IsTest
private class UnsubscribeLinkValueTest {
  private static final String UUID_V4 = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  private static final String CONTACT_ID_18 = '003000000000001AAA';
  private static final String LEAD_ID_15 = '00Q000000000001';

  @IsTest
  static void contactAndLeadPublicIdsAreValid() {
    UnsubscribeLinkValue contactLink = UnsubscribeLinkValue.parse('C' + UUID_V4, false);
    UnsubscribeLinkValue leadLink = UnsubscribeLinkValue.parse(' L' + UUID_V4.toUpperCase() + ' ', false);

    Assert.isTrue(contactLink.isValid(), 'C plus a UUID v4 should be valid');
    Assert.areEqual(Contact.SObjectType, contactLink.objectType, 'C means Contact');
    Assert.areEqual(UUID_V4, contactLink.publicId, 'Public Id should drop the letter');
    Assert.isNull(contactLink.recordId, 'A Public Id link has no record Id');
    Assert.areEqual(Lead.SObjectType, leadLink.objectType, 'L means Lead, spaces and case are ignored');
  }

  @IsTest
  static void malformedValuesAreInvalid() {
    List<String> values = new List<String>{
      null,
      '',
      'X' + UUID_V4,
      UUID_V4,
      'C' + UUID_V4.replace('-41d3-', '-11d3-'),
      'C' + UUID_V4 + '0',
      'C' + UUID_V4 + '+Click here',
      '001000000000001'
    };
    for (String value : values) {
      Assert.isFalse(UnsubscribeLinkValue.parse(value, true).isValid(), 'Should be invalid: ' + value);
    }
  }

  @IsTest
  static void legacyRecordIdsNeedTheSetting() {
    Assert.isFalse(UnsubscribeLinkValue.parse(CONTACT_ID_18, false).isValid(), 'Legacy Ids are off by default');

    UnsubscribeLinkValue contactLink = UnsubscribeLinkValue.parse(CONTACT_ID_18, true);
    UnsubscribeLinkValue leadLink = UnsubscribeLinkValue.parse(LEAD_ID_15, true);

    Assert.areEqual(Contact.SObjectType, contactLink.objectType, '003 means Contact');
    Assert.areEqual(Id.valueOf(CONTACT_ID_18), contactLink.recordId, 'Record Id should be kept');
    Assert.areEqual(Lead.SObjectType, leadLink.objectType, '00Q means Lead');
    Assert.areEqual(18, String.valueOf(leadLink.recordId).length(), 'A 15-character Id becomes an 18-character Id');
  }

  @IsTest
  static void legacySettingIsReadFromSetup() {
    Assert.isFalse(UnsubscribeLinkValue.legacyRecordIdsAccepted(), 'No setup record means off');

    insert new Unsubscribe_Link_Setup__c(Accept_Legacy_Record_Id_Links__c = true);

    Assert.isTrue(UnsubscribeLinkValue.legacyRecordIdsAccepted(), 'Setting on the setup record should be used');
  }
}
