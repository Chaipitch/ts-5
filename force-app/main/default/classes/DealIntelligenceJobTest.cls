@isTest
private class DealIntelligenceJobTest {

    private static final String MOM_SUBJECT = 'Web Meeting - 1. Initial Meeting / Hearing';
    private static final String LONG_TEXT =
        'Customer confirmed a budget for next year and asked how data migration from their legacy system would work.';

    /** Every call gets the same small answer (score 60), or the given error status. */
    private class GeminiMock implements HttpCalloutMock {
        Integer calls = 0;
        Integer status = 200;
        String retryDelay;

        GeminiMock() {}

        GeminiMock(Integer status) {
            this.status = status;
        }

        public HttpResponse respond(HttpRequest req) {
            calls++;
            if (status != 200) {
                HttpResponse busy = new HttpResponse();
                busy.setStatusCode(status);
                busy.setStatus(status == 503 ? 'Service Unavailable' : 'Error');
                busy.setBody('{"error":{"code":' + status + ',"message":"This model is currently experiencing high demand."'
                    + (retryDelay == null ? '' : ',"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"' + retryDelay + '"}]')
                    + '}}');
                return busy;
            }
            String text = JSON.serialize(new Map<String, Object>{
                '31_Customer_Seriousness_Score__c' => 60,
                '32_Reason_for_Seriousness_Score__c' => 'Budget confirmed.'
            });
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{
                    new Map<String, Object>{
                        'content' => new Map<String, Object>{
                            'parts' => new List<Object>{ new Map<String, Object>{ 'text' => text } }
                        }
                    }
                },
                'usageMetadata' => new Map<String, Object>{ 'promptTokenCount' => 100, 'candidatesTokenCount' => 10 }
            }));
            return res;
        }
    }

    @TestSetup
    static void makeData() {
        DealIntelligenceJob.realTimeOn = false;
        List<Opportunity> opps = new List<Opportunity>();
        for (String name : new List<String>{ 'AIDI Job', 'AIDI Retry' }) {
            opps.add(withCreateRequirements(new Opportunity(
                Name = name,
                StageName = firstValue(Opportunity.StageName.getDescribe()),
                Your_Win_Confidence__c = firstValue(Opportunity.Your_Win_Confidence__c.getDescribe()),
                CloseDate = Date.today().addMonths(3)
            )));
        }
        insert as system opps;
        // Retry tests run the job directly, and a callout can't follow DML in the same
        // test, so their meeting is made here.
        Event retry = failedMom(LONG_TEXT, 1);   // failed once, so the retry run takes it
        retry.WhatId = opps[1].Id;
        insert as system retry;
    }

    private static List<Id> retryMeeting() {
        return new List<Id>(new Map<Id, Event>([
            SELECT Id FROM Event WHERE What.Name = 'AIDI Retry' WITH SYSTEM_MODE
        ]).keySet());
    }

    /*
     * What Production asks of a new Opportunity on top of the required fields: an
     * Amount, a Lead Source (any but Partners, which also wants a Prime Partner) and
     * the CredenData screenshot note.
     */
    private static Opportunity withCreateRequirements(Opportunity opp) {
        opp.Amount = 100000;
        opp.Update_CredenData_Screen_shot__c = 'Test data';
        for (Schema.PicklistEntry entry : Opportunity.LeadSource.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() != 'Partners') {
                opp.LeadSource = entry.getValue();
                break;
            }
        }
        return opp;
    }

    private static String firstValue(Schema.DescribeFieldResult describe) {
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Opportunity theOpp() {
        return (Opportunity) Database.query(
            'SELECT Id, Customer_Seriousness_Score__c FROM Opportunity WHERE Name = \'AIDI Job\' LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
    }

    private static Event mom(String description, Integer daysAgo) {
        Datetime starts = Datetime.now().addDays(-daysAgo);
        return new Event(
            WhatId = theOpp().Id,
            Type = 'Web Meeting',
            Subject = MOM_SUBJECT,
            Description = description,
            StartDateTime = starts,
            EndDateTime = starts.addHours(1)
        );
    }

    private static Event failedMom(String description, Integer daysAgo) {
        Event e = mom(description, daysAgo);
        e.IsFailed__c = true;
        return e;
    }

    private static Integer ticked() {
        return [SELECT COUNT() FROM Event WHERE What.Name = 'AIDI Job' AND AI_Processed__c = true WITH SYSTEM_MODE];
    }

    // ---- Real-time

    @isTest
    static void loggingAMeetingAnalysesItInTheBackground() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        insert as system mom(LONG_TEXT, 0);
        Test.stopTest();

        System.assertEquals(1, ticked());
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c);
    }

    private static Event processedMom() {
        Event e = mom(LONG_TEXT, 1);
        e.AI_Processed__c = true;   // analysed already, so inserting it queues nothing
        insert as system e;
        return e;
    }

    private static Integer jobsStarted() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DealIntelligenceJob' WITH SYSTEM_MODE];
    }

    @isTest
    static void editingTheNotesAnalysesTheMeetingAgain() {
        Event e = processedMom();
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        update as system new Event(Id = e.Id, Description = LONG_TEXT + ' They also asked for a demo next week.');
        Test.stopTest();

        System.assertEquals(1, jobsStarted(), 'one job, and its own tick queued no other');
        System.assertEquals(1, ticked(), 'ticked again once analysed');
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c, 'the new notes reached the deal');
    }

    @isTest
    static void anEditThatLeavesTheNotesAloneCallsNothing() {
        Event e = processedMom();

        Test.startTest();
        update as system new Event(Id = e.Id, Location = 'Head office');
        Test.stopTest();

        System.assertEquals(0, jobsStarted());
        System.assertEquals(1, ticked(), 'still counted as analysed');
    }

    @isTest
    static void notesEditedTooShortAreNotSent() {
        Event e = processedMom();

        Test.startTest();
        update as system new Event(Id = e.Id, Description = 'called, no answer');
        Test.stopTest();

        System.assertEquals(0, jobsStarted(), 'below the minimum length, as for a new meeting');
    }

    @isTest
    static void shortNoteDoesNotStartAJob() {
        Test.startTest();
        insert as system mom('called, no answer', 0);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DealIntelligenceJob' WITH SYSTEM_MODE
        ]);
    }

    @isTest
    static void eachJobTakesOnlyAFewMeetings() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        List<Event> moms = new List<Event>();
        for (Integer i = 0; i < DealIntelligenceJob.PER_TRANSACTION + 1; i++) {
            moms.add(mom(LONG_TEXT, i));
        }

        Test.startTest();
        insert as system moms;
        Test.stopTest();

        // Tests can't chain jobs, so only the first job's share is done here; outside
        // tests the next job takes the rest.
        System.assertEquals(DealIntelligenceJob.PER_TRANSACTION, mock.calls);
        System.assertEquals(DealIntelligenceJob.PER_TRANSACTION, ticked());
    }

    // ---- Backfill

    @isTest
    static void retryRunTakesOnlyFailedMeetings() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        DealIntelligenceJob.realTimeOn = false;
        update as system new Event(Id = retryMeeting()[0], IsFailed__c = false);   // out of the way
        Event failedOld = failedMom(LONG_TEXT, 400);       // failed earlier; any meeting date
        Event neverTried = mom(LONG_TEXT, 30);             // past meeting, never sent: left alone
        Event failedShort = failedMom('called, no answer', 10);
        insert as system new List<Event>{ failedOld, neverTried, failedShort };

        Test.startTest();
        DealIntelligenceJob.runBackfill();
        Test.stopTest();

        System.assertEquals(1, mock.calls, 'only the failed meeting with a real note is sent');
        Event done = [SELECT AI_Processed__c, IsFailed__c FROM Event WHERE Id = :failedOld.Id WITH SYSTEM_MODE];
        System.assertEquals(true, done.AI_Processed__c);
        System.assertEquals(false, done.IsFailed__c, 'the flag is cleared once it succeeds');
        System.assertEquals(false, [SELECT AI_Processed__c FROM Event WHERE Id = :neverTried.Id WITH SYSTEM_MODE].AI_Processed__c,
            'past meetings that never failed are not processed');
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c);
    }

    @isTest
    static void busyMeetingIsQueuedAgainAfterADelay() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(503));
        List<Id> ids = retryMeeting();

        Test.startTest();
        new DealIntelligenceJob.RealTime(ids).execute(null);
        Test.stopTest();

        DealIntelligenceJob.RealTime next = DealIntelligenceJob.queuedInTest;
        System.assertNotEquals(null, next, 'a retry is queued');
        System.assertEquals(ids, next.pending);
        System.assertEquals(2, next.attempts.get(ids[0]), 'the retry is the second attempt');
        System.assertEquals(DealIntelligenceJob.RETRY_DELAY_MINUTES, DealIntelligenceJob.queuedDelayInTest);

        System.assertEquals(false, [SELECT AI_Processed__c FROM Event WHERE Id = :ids[0] WITH SYSTEM_MODE].AI_Processed__c);
        Gemini_Opty_Log__c log = [SELECT Status__c, Error_Message__c FROM Gemini_Opty_Log__c WHERE Opportunity__r.Name = 'AIDI Retry' WITH SYSTEM_MODE];
        System.assertEquals('Fail', log.Status__c);
        System.assert(log.Error_Message__c.contains('HTTP 503'), log.Error_Message__c);
    }

    @isTest
    static void rateLimitWaitsForTheHourlyRetry() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(429));

        Test.startTest();
        new DealIntelligenceJob.RealTime(retryMeeting()).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest, 'no quick retry for a 429');
        System.assert(DealIntelligenceJob.rateLimitRetryInTest, 'the rate-limit retry is scheduled');
        System.assertEquals(DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES, DealIntelligenceJob.rateLimitRetryMinutesInTest,
            'Gemini gave no wait, so it is treated as a used-up quota: an hour');
        System.assertEquals(false, [SELECT AI_Processed__c FROM Event WHERE Id = :retryMeeting()[0] WITH SYSTEM_MODE].AI_Processed__c);
    }

    @isTest
    static void hourlyRetryIsScheduledOnlyOnce() {
        DealIntelligenceJob.scheduleForRealInTest = true;
        // No startTest/stopTest: the scheduled job must not actually run here.
        DealIntelligenceJob.scheduleRateLimitRetry(DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES);
        DealIntelligenceJob.scheduleRateLimitRetry(DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES);

        List<CronTrigger> retries = [
            SELECT NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :DealIntelligenceJob.RATE_LIMIT_RETRY_NAME
        ];
        System.assertEquals(1, retries.size(), 'one retry an hour, however many jobs hit the limit');
        Long minutes = (retries[0].NextFireTime.getTime() - Datetime.now().getTime()) / 60000;
        System.assert(minutes >= DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES - 2 && minutes <= DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES,
            'fires in about an hour: ' + minutes + ' minutes');
    }

    @isTest
    static void perMinuteLimitRetriesInMinutes() {
        GeminiMock mock = new GeminiMock(429);
        mock.retryDelay = '14s';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new DealIntelligenceJob.RealTime(retryMeeting()).execute(null);
        Test.stopTest();

        System.assertEquals(DealIntelligenceJob.SHORT_WAIT_MINUTES, DealIntelligenceJob.rateLimitRetryMinutesInTest);
    }

    @isTest
    static void waitFollowsWhatGeminiAsks() {
        System.assertEquals(60, DealIntelligenceJob.waitMinutes(null), 'no wait given: assume a used-up quota');
        System.assertEquals(2, DealIntelligenceJob.waitMinutes(14));
        System.assertEquals(5, DealIntelligenceJob.waitMinutes(200), 'a minute more than the 4 minutes asked');
        System.assertEquals(11, DealIntelligenceJob.waitMinutes(600));
        System.assertEquals(60, DealIntelligenceJob.waitMinutes(601));
        System.assertEquals(60, DealIntelligenceJob.waitMinutes(49995), 'daily quota: an hour');
    }

    @isTest
    static void soonerRetryReplacesALaterOne() {
        DealIntelligenceJob.scheduleForRealInTest = true;
        DealIntelligenceJob.scheduleRateLimitRetry(60);
        DealIntelligenceJob.scheduleRateLimitRetry(2);
        DealIntelligenceJob.scheduleRateLimitRetry(60);

        List<CronTrigger> retries = [
            SELECT NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :DealIntelligenceJob.RATE_LIMIT_RETRY_NAME
        ];
        System.assertEquals(1, retries.size());
        Long minutes = (retries[0].NextFireTime.getTime() - Datetime.now().getTime()) / 60000;
        System.assert(minutes <= 2, 'the 2-minute retry wins: ' + minutes);
    }

    @isTest
    static void dealsHeldBackByRateLimitGoFirst() {
        DealIntelligenceJob.realTimeOn = false;
        insert as system new List<Event>{ failedMom(LONG_TEXT, 20), failedMom(LONG_TEXT, 10) };
        Id retryId = retryMeeting()[0];
        insert as system new Gemini_Opty_Log__c(
            Event_Id__c = retryId,
            Status__c = 'Fail',
            Error_Message__c = 'HTTP 429 Too Many Requests (Gemini asks to wait 14 s)'
        );

        List<SObject> order = (List<SObject>) new DealIntelligenceJob().start(null);

        System.assertEquals(retryId, order[0].Id, 'the deal that hit the limit comes first');
        System.assertEquals(3, order.size(), 'then everything else still pending');
    }

    @isTest
    static void backfillStopsCallingAtTheFirstRateLimit() {
        GeminiMock mock = new GeminiMock(429);
        Test.setMock(HttpCalloutMock.class, mock);
        DealIntelligenceJob.realTimeOn = false;
        insert as system new List<Event>{ failedMom(LONG_TEXT, 20), failedMom(LONG_TEXT, 10) };

        Test.startTest();
        DealIntelligenceJob.runBackfill();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Gemini_Opty_Log__c WITH SYSTEM_MODE], 'one refused call, the rest held back');
        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE AI_Processed__c = true WITH SYSTEM_MODE]);
    }

    @isTest
    static void hourlyRetryRunsTheBackfill() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        new DealIntelligenceJob().execute((SchedulableContext) null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'DealIntelligenceJob' WITH SYSTEM_MODE]);
        System.assertEquals(true, [SELECT AI_Processed__c FROM Event WHERE Id = :retryMeeting()[0] WITH SYSTEM_MODE].AI_Processed__c);
    }

    @isTest
    static void nightlyBackfillIsScheduledOnlyOnce() {
        // No startTest/stopTest: the scheduled job must not actually run here.
        Id first = DealIntelligenceJob.scheduleNightly();
        Id second = DealIntelligenceJob.scheduleNightly();

        System.assertEquals(first, second, 'switching it on twice changes nothing');
        CronTrigger nightly = [
            SELECT CronExpression, NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :DealIntelligenceJob.NIGHTLY_NAME
        ];
        System.assertEquals(DealIntelligenceJob.NIGHTLY_CRON, nightly.CronExpression);
        System.assertEquals(2, nightly.NextFireTime.hour(), 'runs at 02:00');
    }

    @isTest
    static void nightlyBackfillPicksUpWhatIsWaiting() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        new DealIntelligenceJob.Nightly().execute(null);
        Test.stopTest();

        System.assertEquals(true, [SELECT AI_Processed__c FROM Event WHERE Id = :retryMeeting()[0] WITH SYSTEM_MODE].AI_Processed__c);
    }

    @isTest
    static void givesUpAfterTheLastAttempt() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(503));
        List<Id> ids = retryMeeting();
        Map<Id, Integer> attempts = new Map<Id, Integer>{ ids[0] => DealIntelligenceJob.MAX_ATTEMPTS };

        Test.startTest();
        new DealIntelligenceJob.RealTime(ids, attempts).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest, 'no more retries; the backfill can still pick it up');
    }

    @isTest
    static void otherErrorsAreNotRetried() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(500));

        Test.startTest();
        new DealIntelligenceJob.RealTime(retryMeeting()).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest);
    }
}