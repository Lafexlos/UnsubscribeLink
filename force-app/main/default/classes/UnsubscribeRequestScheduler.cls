/**
 * The class the setup flow schedules. It only starts UnsubscribeRequestBatch.
 *
 * Salesforce blocks deploying a scheduled class, and the code it depends on,
 * while the job is scheduled. This class names the batch only as a string, so
 * the batch can change in a deployment or package upgrade while the job stays
 * scheduled. Keep logic out of this class: changing it means unscheduling first.
 */
public with sharing class UnsubscribeRequestScheduler implements Schedulable {
  private static final String BATCH_CLASS_NAME = 'UnsubscribeRequestBatch';

  public void execute(SchedulableContext context) {
    Schedulable batchStarter = (Schedulable) Type.forName(
        namespacePrefix(),
        BATCH_CLASS_NAME
      )
      .newInstance();
    batchStarter.execute(context);
  }

  // getName() is Namespace.ClassName inside the package, ClassName without one
  private static String namespacePrefix() {
    String fullName = UnsubscribeRequestScheduler.class.getName();
    return fullName.contains('.') ? fullName.substringBefore('.') : '';
  }
}
