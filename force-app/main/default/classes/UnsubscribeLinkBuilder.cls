/**
 * Builds the value stored in Part1_Unsubscribe_Link__c on Contacts and Leads.
 * The value is the site base URL, the unsubscribe page with the varRecId
 * parameter (object letter plus Public Id), then '+' and the link text.
 * The Unsubscribe Link formula fields split the value on '+'.
 *
 * Links already sent must keep working (ADR 0001), so keep this format as is.
 */
public with sharing class UnsubscribeLinkBuilder {
  public static final String SITE_NAME = 'Unsubscribe';
  public static final String CONTACT_LETTER = 'C';
  public static final String LEAD_LETTER = 'L';
  private static final String URL_SCHEME = 'https://';
  private static final String SITE_PATH = '/' + SITE_NAME + '/s/';
  private static final String PAGE_AND_PARAMETER = 'unsubscribe?varRecId=';
  private static final String LINK_TEXT_SEPARATOR = '+';

  // Site base URL for a site domain such as example.my.site.com
  public static String siteBaseUrlForDomain(String siteDomain) {
    return URL_SCHEME + siteDomain + SITE_PATH;
  }

  // C for Contact, L for Lead, null for any other object
  public static String objectTypeLetter(SObjectType objectType) {
    if (objectType == Contact.SObjectType) {
      return CONTACT_LETTER;
    }
    if (objectType == Lead.SObjectType) {
      return LEAD_LETTER;
    }
    return null;
  }

  public static String buildLink(
    String siteBaseUrl,
    String objectTypeLetter,
    String publicId,
    String linkText
  ) {
    // A missing link text leaves the text after '+' empty, as the flows did
    String safeLinkText = (linkText == null) ? '' : linkText;
    return siteBaseUrl +
      PAGE_AND_PARAMETER +
      objectTypeLetter +
      publicId +
      LINK_TEXT_SEPARATOR +
      safeLinkText;
  }
}
