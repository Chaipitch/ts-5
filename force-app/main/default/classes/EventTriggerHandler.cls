public class EventTriggerHandler {
    
    EventTriggerLogic logic = new EventTriggerLogic();

    public void onBeforeUpdate (List<Event> newList, Map<Id, Event> oldMap) {
        logic.checkApplicationItemPreventEditCalendar(newList, 'edit');
        DealIntelligenceJob.reopenEdited(newList, oldMap);
    }

    public void onBeforeDelete (List<Event> oldList) {
        logic.checkApplicationItemPreventEditCalendar(oldList, 'delete');
    }

    public void onAfterInsert (List<Event> newList) {
        DealIntelligenceJob.enqueueFor(newList);
    }

    public void onAfterUpdate (List<Event> newList, Map<Id, Event> oldMap) {
        DealIntelligenceJob.enqueueEdited(newList, oldMap);
    }
    
}