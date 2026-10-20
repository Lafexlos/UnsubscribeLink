@IsTest
private class UnsubscribeLinkBuilderTest {
  private static final String SITE_DOMAIN = 'example.my.site.com';
  private static final String PUBLIC_ID = '0f8fad5b-d9cb-469f-a165-70867728950e';

  @IsTest
  static void testSiteBaseUrlForDomain() {
    // Act
    String baseUrl = UnsubscribeLinkBuilder.siteBaseUrlForDomain(SITE_DOMAIN);

    // Assert
    Assert.areEqual(
      'https://example.my.site.com/Unsubscribe/s/',
      baseUrl,
      'Base URL should match the format the setup flows used'
    );
  }

  @IsTest
  static void testBuildLinkForContact() {
    // Arrange
    String baseUrl = UnsubscribeLinkBuilder.siteBaseUrlForDomain(SITE_DOMAIN);

    // Act
    String link = UnsubscribeLinkBuilder.buildLink(
      baseUrl,
      UnsubscribeLinkBuilder.objectTypeLetter(Contact.SObjectType),
      PUBLIC_ID,
      'Click here to unsubscribe.'
    );

    // Assert
    Assert.areEqual(
      'https://example.my.site.com/Unsubscribe/s/unsubscribe?varRecId=C' +
        PUBLIC_ID +
        '+Click here to unsubscribe.',
      link,
      'Contact link format must not change, links already sent depend on it'
    );
  }

  @IsTest
  static void testBuildLinkForLeadWithoutLinkText() {
    // Arrange
    String baseUrl = UnsubscribeLinkBuilder.siteBaseUrlForDomain(SITE_DOMAIN);

    // Act
    String link = UnsubscribeLinkBuilder.buildLink(
      baseUrl,
      UnsubscribeLinkBuilder.objectTypeLetter(Lead.SObjectType),
      PUBLIC_ID,
      null
    );

    // Assert
    Assert.areEqual(
      'https://example.my.site.com/Unsubscribe/s/unsubscribe?varRecId=L' +
        PUBLIC_ID +
        '+',
      link,
      'A missing link text should leave the text after + empty, not "null"'
    );
  }

  @IsTest
  static void testObjectTypeLetterForOtherObject() {
    // Act
    String letter = UnsubscribeLinkBuilder.objectTypeLetter(Account.SObjectType);

    // Assert
    Assert.isNull(letter, 'Only Contact and Lead have an object letter');
  }
}
