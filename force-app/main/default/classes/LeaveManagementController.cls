public with sharing class LeaveManagementController implements Schedulable {

    private static final Decimal ANNUAL_ENTITLEMENT = 12;
    private static final Decimal CARRY_OVER_CAP     = 6;
    private static final String  TYPE_ANNUAL        = 'Annual leave';
    private static final String  ACCRUAL_ANNIVERSARY = 'Anniversary';
    private static final String  TYPE_REFRESH       = 'Refresh Leave';

    /*
     * Opens the Remark on every Refreshment Leave Draft the job creates, so a generated
     * Draft can be told apart from one the employee raised.
     */
    public static final String REFRESH_SCHEDULE_NOTE = 'Refreshment Leave scheduled automatically';

    // Test hooks. Tests drive the clock and the configuration through these rather
    // than depending on System.today() or the org's Custom Metadata rows.
    @TestVisible private static Date todayOverride;
    @TestVisible private static List<Refresh_Leave_Rule__mdt> ruleOverride;
    @TestVisible private static List<Leave_Type_Policy__mdt> policyOverride;

    public void execute(SchedulableContext sc) {
        runDaily();
    }

    public static void runDaily() {
        runDaily(todayOverride != null ? todayOverride : System.today());
    }

    /*
     * Runs the grants as at a specific date. Public so a missed run can be replayed
     * for the date it should have happened. Every grant is guarded by Granted_On__c,
     * so replaying a date that already ran changes nothing.
     */
    public static void runDaily(Date today) {
        Map<String, Leave_Balance__c> staged = new Map<String, Leave_Balance__c>();
        List<ApplicationItem__c> refreshDrafts = new List<ApplicationItem__c>();
        List<String> logDetails = new List<String>{
            'Run Date: ' + System.now(),
            'Effective Date: ' + today,
            '--------------------------------------'
        };

        try {
            Integer resettled = LeaveAccrualService.sweep(LeaveAccrualService.asOfDate());
            if (resettled > 0) {
                logDetails.add('ACCRUAL ' + resettled + ' balance row(s) recalculated');
            }

            if (today.month() == 1 && today.day() == 1) {
                grantAnnualLeave(today, staged, logDetails);
            }
            grantNewHireLeave(today, staged, logDetails);
            grantRefreshLeave(today, staged, refreshDrafts, logDetails);
            // Expiry runs last so it evaluates the dates this run has just written,
            // not the stale ones still in the database.
            expireLeave(today, staged, logDetails);

            if (!staged.isEmpty()) {
                // The upsert re-enters LeaveBalanceTrigger, which recalculates the
                // accrual on every staged row — so a grant, a carry-over or an expiry
                // written above lands with its derived figures already correct.
                upsert staged.values() External_Key__c;
            }
            // After the upsert, because the Drafts are measured against the Refresh
            // balance on insert and would be split off to Annual leave without it.
            insertRefreshDrafts(refreshDrafts, logDetails);
            if (!staged.isEmpty() || resettled > 0 || !refreshDrafts.isEmpty()) {
                createLogFile(String.join(logDetails, '\n'));
            }
        } catch (Exception e) {
            System.debug('An unexpected error has occurred: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Rethrow in tests so logic and configuration errors surface instead of being swallowed.
            if (Test.isRunningTest()) throw e;
        }
    }

    private static void grantAnnualLeave(Date today, Map<String, Leave_Balance__c> staged,
                                         List<String> logDetails) {
        Integer yr = today.year();
        List<User> employees = employeesStartedBy(today);
        if (employees.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(employees), new Set<Integer>{ yr, yr - 1 });

        for (User usr : employees) {
            for (Leave_Type_Policy__mdt policy : activePolicies()) {
                Leave_Balance__c row = stage(staged, existing, usr.Id, policy, yr);
                if (ACCRUAL_ANNIVERSARY.equals(policy.Accrual_Method__c) || row.Granted_On__c != null) {
                    continue;
                }

                row.Entitlement_Days__c = policy.Entitlement_Days__c;
                row.Used_Days__c        = 0;
                row.Granted_On__c       = today;

                if (TYPE_ANNUAL.equals(policy.Leave_Type__c)) {
                    Leave_Balance__c prior = existing.get(balanceKey(usr.Id, TYPE_ANNUAL, yr - 1));
                    Decimal priorAvailable = prior == null ? 0 : zeroIfNull(prior.Available_Balance__c);
                    if (priorAvailable < 0) priorAvailable = 0;
                    Decimal carryOver = priorAvailable > CARRY_OVER_CAP ? CARRY_OVER_CAP : priorAvailable;

                    row.Entitlement_Days__c  = ANNUAL_ENTITLEMENT;
                    row.Carry_Over_Days__c   = carryOver;
                    row.Carry_Over_Expiry__c = Date.newInstance(yr, 6, 30);

                    logDetails.add('ANNUAL  ' + usr.Name
                        + ' | start=' + usr.Start_Date__c
                        + ' | priorAvailable=' + priorAvailable
                        + ' | carryOver=' + carryOver);
                }
            }
        }
    }
    private static void grantNewHireLeave(Date today, Map<String, Leave_Balance__c> staged,
                                          List<String> logDetails) {
        Integer yr = today.year();
        List<User> newHires = [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE AND Start_Date__c = :today
        ];
        if (newHires.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(newHires), new Set<Integer>{ yr });

        for (User usr : newHires) {
            for (Leave_Type_Policy__mdt policy : activePolicies()) {
                Leave_Balance__c row = stage(staged, existing, usr.Id, policy, yr);
                if (ACCRUAL_ANNIVERSARY.equals(policy.Accrual_Method__c) || row.Granted_On__c != null) {
                    continue;
                }
                row.Entitlement_Days__c = TYPE_ANNUAL.equals(policy.Leave_Type__c)
                    ? 13 - usr.Start_Date__c.month()
                    : policy.Entitlement_Days__c;
                row.Used_Days__c  = 0;
                row.Granted_On__c = today;
            }
            logDetails.add('NEWHIRE ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | annual=' + (13 - usr.Start_Date__c.month()));
        }
    }

    /*
     * Refreshment Leave is granted, and its Draft raised, this many months ahead of the
     * anniversary month, so the employee sees the dates before they arrive. A constant
     * rather than configuration, to keep the change free of new fields; 0 restores
     * granting on the 1st of the anniversary month itself.
     */
    private static final Integer REFRESH_LEAD_MONTHS = 1;
    @TestVisible private static Integer leadMonthsOverride;

    private static Integer refreshLeadMonths() {
        return leadMonthsOverride != null ? leadMonthsOverride : REFRESH_LEAD_MONTHS;
    }

    /*
     * Every anniversary month from this one up to the lead time ahead. The month ahead is
     * the normal case. The months before it are a catch-up: if the job did not run during
     * the lead month, the grant is still made when the anniversary month itself arrives,
     * and the Granted_On__c guard keeps a grant made on time from being made twice.
     */
    private static void grantRefreshLeave(Date today, Map<String, Leave_Balance__c> staged,
                                          List<ApplicationItem__c> drafts,
                                          List<String> logDetails) {
        List<Refresh_Leave_Rule__mdt> rules = getRules();
        Leave_Type_Policy__mdt refreshPolicy = anniversaryPolicy();
        if (rules.isEmpty() || refreshPolicy == null) return;

        for (Integer ahead = 0; ahead <= refreshLeadMonths(); ahead++) {
            grantRefreshLeaveFor(today.toStartOfMonth().addMonths(ahead), today, rules,
                                 refreshPolicy, staged, drafts, logDetails);
        }
    }

    /*
     * Grants for one anniversary month. Everything about the grant is measured against
     * that month, not against the run date: the tier, the leave year the balance belongs
     * to, and the window. Measured on the run date a month early, a third anniversary
     * reads as thirty-five months and gets the second-year tier, a January anniversary
     * granted in December lands in the wrong year, and a window counted from the grant
     * closes before the leave begins.
     */
    private static void grantRefreshLeaveFor(Date monthStart, Date today,
                                             List<Refresh_Leave_Rule__mdt> rules,
                                             Leave_Type_Policy__mdt refreshPolicy,
                                             Map<String, Leave_Balance__c> staged,
                                             List<ApplicationItem__c> drafts,
                                             List<String> logDetails) {
        Integer yr = monthStart.year();

        List<User> candidates = [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c < :monthStart
              AND CALENDAR_MONTH(Start_Date__c) = :monthStart.month()
        ];
        if (candidates.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(candidates), new Set<Integer>{ yr });
        // One query for the rest of that year: a schedule never runs past December 31.
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(
            monthStart, Date.newInstance(yr, 12, 31));

        for (User usr : candidates) {
            /*
             * Entitlement is decided before the row is touched, because stage() does not
             * merely read — it puts the row in the staged map and everything there is
             * upserted. Staging first meant somebody in their joining month with no
             * completed year, who matches no tier, still had an empty Refresh Leave row
             * written for them. Harmless-looking, and it made the expiry sweep churn.
             */
            Integer years = usr.Start_Date__c.monthsBetween(monthStart) / 12;
            Refresh_Leave_Rule__mdt rule = tierFor(rules, years);
            if (rule == null) continue;

            Leave_Balance__c row = stage(staged, existing, usr.Id, refreshPolicy, yr);
            if (row.Granted_On__c != null) continue;

            // Calculate anniversary here so it can be used for the Expiry_Date__c
            Date anniversary = anniversaryIn(usr.Start_Date__c, yr);

            row.Entitlement_Days__c = rule.Days_Granted__c;
            row.Used_Days__c        = 0;
            // Expiry date is now exactly 1 month after the specific anniversary date
            row.Expiry_Date__c      = anniversary.addMonths(1).addDays(-1);
            row.Granted_On__c       = today;

            /*
             * The Draft is raised here, with the grant, so the Granted_On__c guard above
             * that stops the grant repeating stops the Draft repeating too.
             */
            // From the anniversary itself, or from today on a catch-up run that missed it.
            List<Date> schedule = refreshScheduleFor(
                anniversary, rule.Days_Granted__c, today, holidays);
                
            if (schedule.isEmpty()) {
                logDetails.add('REFRESH ' + usr.Name + ' | no business day left in ' + yr
                    + ' after ' + today + ', no Draft raised');
            } else {
                Date lastDay = schedule[schedule.size() - 1];
                /*
                 * A safeguard. With the window running to the end of the month after the
                 * anniversary month, five days from any anniversary fit inside it. A rule
                 * configured with no window, or with many more days, could still run past
                 * it, and the split would then move the days beyond it to Annual leave as
                 * soon as the Draft is saved. The window is stretched instead.
                 */
                if (lastDay > row.Expiry_Date__c) {
                    row.Expiry_Date__c = lastDay;
                }
                drafts.add(refreshDraft(usr, anniversary, schedule, rule.Days_Granted__c));
            }

            logDetails.add('REFRESH ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | years=' + years
                + ' | granted=' + rule.Days_Granted__c
                + ' | expires=' + row.Expiry_Date__c
                + (schedule.isEmpty() ? '' : ' | scheduled=' + schedule[0] + '..'
                    + schedule[schedule.size() - 1]));
        }
    }

    /*
     * Partial success, so one employee's Draft failing a validation rule cannot take
     * everybody else's with it. A failure is logged rather than retried: the grant has
     * already been saved, so the Granted_On__c guard keeps tomorrow's run from raising
     * it again, and the employee can still raise the request by hand.
     */
    private static void insertRefreshDrafts(List<ApplicationItem__c> drafts, List<String> logDetails) {
        if (drafts.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.insert(drafts, false);
        for (Integer i = 0; i < results.size(); i++) {
            ApplicationItem__c draft = drafts[i];
            String who = draft.OwnerId + ' | ' + draft.Term_From__c
                + (draft.Term_To__c == null ? '' : '..' + draft.Term_To__c);
            if (results[i].isSuccess()) {
                logDetails.add('DRAFT   ' + who);
                continue;
            }
            List<String> errors = new List<String>();
            for (Database.Error err : results[i].getErrors()) {
                errors.add(err.getMessage());
            }
            logDetails.add('DRAFT FAILED ' + who + ' | ' + String.join(errors, '; '));
        }
    }

    private static ApplicationItem__c refreshDraft(User usr, Date anniversary, List<Date> schedule,
                                                   Decimal daysGranted) {
        String remark = REFRESH_SCHEDULE_NOTE + ' for your service anniversary on '
            + slashed(anniversary) + '.';
        if (schedule.size() < daysGranted) {
            remark += ' Only ' + schedule.size() + ' of ' + plain(daysGranted)
                + ' day(s) fit before the year ends; book the rest separately.';
        }
        remark += ' To take it on another date, change the dates before submitting.';
        return new ApplicationItem__c(
            RecordTypeId    = Schema.SObjectType.ApplicationItem__c
                                  .getRecordTypeInfosByDeveloperName()
                                  .get('Leave_Request').getRecordTypeId(),
            OwnerId         = usr.Id,
            Request_Type__c = TYPE_REFRESH,
            Period_Leave__c = 'All day',
            Term_From__c    = schedule[0],
            Term_To__c      = schedule.size() == 1 ? null : schedule[schedule.size() - 1],
            Status__c       = 'Draft',
            Remark__c       = remark.left(255)
        );
    }

    /**
     * The business days a Refreshment grant is taken on: from firstDay, moved to the next
     * business day when it is a weekend or a holiday, then onward until the granted days
     * are used up.
     *
     * The engine passes the service anniversary, so the leave starts on it, or on the
     * next business day when it falls on a weekend or a holiday.
     *
     * Whole days only. A half day in the grant stays in the balance for the employee to
     * book, rather than being guessed as a morning or an afternoon.
     *
     * Never starts before notBefore, so a job that missed the anniversary schedules from
     * the day it runs rather than in the past. Never crosses December 31, because a
     * request cannot span two years and the balance belongs to one: a late-December
     * anniversary gets the days left in the year, and the Remark says how many were cut.
     *
     * @param holidays dated Holiday rows covering the range. Recurring holidays carry no
     *                 date and are not seen, the same as everywhere else in leave.
     */
    public static List<Date> refreshScheduleFor(Date firstDay, Decimal daysGranted,
                                                Date notBefore, Set<Date> holidays) {
        List<Date> days = new List<Date>();
        Integer wanted = daysGranted == null ? 0 : daysGranted.intValue();
        Date cursor = (notBefore != null && notBefore > firstDay) ? notBefore : firstDay;
        while (days.size() < wanted && cursor.year() == firstDay.year()) {
            if (!ApplicationItemTriggerLogic.isWeekend(cursor)
                    && (holidays == null || !holidays.contains(cursor))) {
                days.add(cursor);
            }
            cursor = cursor.addDays(1);
        }
        return days;
    }

    /** The service anniversary in a given year. February 29 falls on the 28th in a common year. */
    public static Date anniversaryIn(Date startDate, Integer yr) {
        Integer day = startDate.day();
        if (startDate.month() == 2 && day == 29 && !Date.isLeapYear(yr)) {
            day = 28;
        }
        return Date.newInstance(yr, startDate.month(), day);
    }

    /* YYYY/MM/DD, the format the stakeholders asked for, regardless of the user's locale. */
    private static String slashed(Date d) {
        return d.year() + '/' + String.valueOf(d.month()).leftPad(2, '0')
            + '/' + String.valueOf(d.day()).leftPad(2, '0');
    }

    private static String plain(Decimal value) {
        return value.stripTrailingZeros().toPlainString();
    }

    private static void expireLeave(Date today, Map<String, Leave_Balance__c> staged,
                                    List<String> logDetails) {
        List<Leave_Balance__c> candidates = [
            SELECT Id, External_Key__c, Employee__r.Name, Leave_Type__c, Leave_Year__c,
                   Entitlement_Days__c, Used_Days__c, Carry_Over_Days__c,
                   Carry_Over_Expiry__c, Expiry_Date__c, Granted_On__c,
                   Accrual_Method__c, Locked_During_Probation__c, Status__c
            FROM Leave_Balance__c
            WHERE Status__c = 'Active'
              AND ((Carry_Over_Expiry__c != NULL AND Carry_Over_Expiry__c < :today)
                OR (Expiry_Date__c != NULL AND Expiry_Date__c < :today))
        ];

        /*
         * What each row's carry over actually paid for: the approved leave DATED on or
         * before the expiry.
         *
         * Used_Days__c cannot answer this. It is the whole year's leave and says nothing
         * about when it was taken, so inferring from it credited carry over back to
         * somebody whose only absence was in August - days that should have lapsed on
         * June 30 returned as spendable ones.
         *
         * Measured from Balance_Applied_Days__c and Term_From__c rather than from the
         * Carry_Over_Days_Used__c attribution, because those two are present on every
         * request INCLUDING the ones a migration linked up. A row whose history predates
         * the attribution would otherwise look as though its carry over had never been
         * spent, and lose days that were.
         */
        Map<Id, Decimal> spentInWindow = new Map<Id, Decimal>();
        Map<Id, Decimal> appliedTotal = new Map<Id, Decimal>();
        Set<Id> haveRequests = new Set<Id>();
        Map<Id, Date> expiryById = new Map<Id, Date>();
        for (Leave_Balance__c c : candidates) {
            if (c.Carry_Over_Expiry__c != null) {
                expiryById.put(c.Id, c.Carry_Over_Expiry__c);
            }
        }
        if (!expiryById.isEmpty()) {
            for (ApplicationItem__c appl : [
                SELECT Leave_Balance__c, Term_From__c, Balance_Applied_Days__c
                FROM ApplicationItem__c
                WHERE Leave_Balance__c IN :expiryById.keySet() AND Status__c = 'Approved'
                  AND Term_From__c != NULL AND Balance_Applied_Days__c != NULL
            ]) {
                haveRequests.add(appl.Leave_Balance__c);
                Decimal runningAll = zeroIfNull(appliedTotal.get(appl.Leave_Balance__c));
                appliedTotal.put(appl.Leave_Balance__c,
                                 runningAll + zeroIfNull(appl.Balance_Applied_Days__c));
                Date cutoff = expiryById.get(appl.Leave_Balance__c);
                if (appl.Term_From__c > cutoff) {
                    continue;
                }
                Decimal running = zeroIfNull(spentInWindow.get(appl.Leave_Balance__c));
                spentInWindow.put(appl.Leave_Balance__c,
                                  running + zeroIfNull(appl.Balance_Applied_Days__c));
            }
        }

        for (Leave_Balance__c queried : candidates) {
            // Read the staged instance where one exists: a grant earlier in this run
            // may have already replaced the expiry date the query matched on.
            Leave_Balance__c row = staged.containsKey(queried.External_Key__c)
                ? staged.get(queried.External_Key__c)
                : queried;

            Boolean carryExpired = row.Carry_Over_Expiry__c != null && row.Carry_Over_Expiry__c < today;
            Boolean windowExpired = row.Expiry_Date__c != null && row.Expiry_Date__c < today;
            if (!carryExpired && !windowExpired) continue;

            Boolean lapsed = false;

            Decimal carriedIn = zeroIfNull(row.Carry_Over_Days__c);
            // An empty bucket has already been swept, or never had anything in it.
            // Either way there is nothing to do, and skipping keeps the row from
            // being re-staged every night for the rest of the year.
            if (carryExpired && carriedIn > 0) {
                Decimal used = zeroIfNull(row.Used_Days__c);
                /*
                 * Capped at what was carried in, so a row whose attribution was written
                 * before this rule existed cannot give back more than it ever held.
                 */
                /*
                 * With no linked request at all there is no evidence of WHEN the leave was
                 * taken, so the old assumption stands: treat the consumption as having come
                 * out of the carry over. That covers a row whose figures were set by hand
                 * and one whose requests were never linked, and it is deliberately not the
                 * August case - a row whose only leave falls after the expiry HAS requests,
                 * measures zero inside the window, and correctly lapses the lot.
                 */
                Decimal consumed;
                if (haveRequests.contains(queried.Id)) {
                    Decimal spent = zeroIfNull(spentInWindow.get(queried.Id));
                    consumed = carriedIn < spent ? carriedIn : spent;
                } else {
                    consumed = carriedIn < used ? carriedIn : used;
                }
                if (consumed > used) {
                    consumed = used;
                }

                /*
                 * The lapsed days are CHARGED to Used_Days__c, and Carry_Over_Days__c is
                 * left holding what was carried in.
                 *
                 * Zeroing the bucket balanced just as well - Available is
                 * Accrued + CarriedIn - Used either way - but it destroyed the one number
                 * the balance card is built to show. carryRemaining reads
                 * MAX(0, CarriedIn - Used) and the card renders it as "remaining / carried
                 * in", so a swept row read "0 / 0" to every employee from July onwards and
                 * the "6 carried in, 2 lapsed" story this field exists for could not be
                 * told. Charging the lapse keeps the arithmetic and keeps the record.
                 */
                Decimal lapsedDays = carriedIn - consumed;
                Decimal settled = haveRequests.contains(queried.Id)
                    ? zeroIfNull(appliedTotal.get(queried.Id)) + lapsedDays
                    : used + lapsedDays;

                /*
                 * Recomputed from the requests rather than incremented, because the bucket
                 * is no longer emptied and this row will be looked at again every night for
                 * the rest of the year. An increment would add the same lapse each time;
                 * a total lands on the same answer however often it runs. The by-hand
                 * branch is self-limiting: once Used covers the carried amount there is
                 * nothing left to lapse.
                 */
                if (settled != used) {
                    logDetails.add('EXPIRE  ' + row.Employee__r.Name
                        + ' | carryOver lapsed=' + lapsedDays
                        + ' of ' + carriedIn + ', spent=' + consumed
                        + ' on ' + row.Carry_Over_Expiry__c);
                    row.Used_Days__c = settled;
                    lapsed = true;
                }
            }

            if (windowExpired) {
                Decimal granted  = zeroIfNull(row.Entitlement_Days__c);
                Decimal used     = zeroIfNull(row.Used_Days__c);
                Decimal consumed = granted < used ? granted : used;
                // Already swept on an earlier run: nothing left to drop, so the row is
                // left alone and Expiry_Date__c keeps standing as the lapse date.
                if (granted > consumed) {
                    logDetails.add('EXPIRE  ' + row.Employee__r.Name
                        + ' | ' + row.Leave_Type__c + ' lapsed=' + (granted - consumed)
                        + ' of ' + granted + ' on ' + row.Expiry_Date__c);
                    row.Entitlement_Days__c = consumed;
                    lapsed = true;
                }
            }

            if (lapsed) staged.put(row.External_Key__c, row);
        }
    }

    // ------------------------------------------------------------------ helpers

    /*
     * The working instance for one employee, leave type and year. Reads the staged
     * map first so several grants on the same day accumulate onto one record, then
     * the database, then creates a new row from the policy.
     */
    private static Leave_Balance__c stage(Map<String, Leave_Balance__c> staged,
                                          Map<String, Leave_Balance__c> existing,
                                          Id employeeId, Leave_Type_Policy__mdt policy, Integer yr) {
        String key = balanceKey(employeeId, policy.Leave_Type__c, yr);
        if (staged.containsKey(key)) {
            return staged.get(key);
        }
        Leave_Balance__c row = existing.get(key);
        if (row == null) {
            row = new Leave_Balance__c(
                Employee__c                = employeeId,
                Leave_Type__c              = policy.Leave_Type__c,
                Leave_Year__c              = yr,
                External_Key__c            = key,
                Entitlement_Days__c        = policy.Entitlement_Days__c,
                Accrual_Method__c          = policy.Accrual_Method__c,
                Locked_During_Probation__c = policy.Locked_During_Probation__c == true,
                Used_Days__c               = 0,
                Pending_Days__c            = 0,
                Carry_Over_Days__c         = 0,
                Status__c                  = 'Active'
            );
        }
        staged.put(key, row);
        return row;
    }

    private static Map<String, Leave_Balance__c> loadBalances(Set<Id> employeeIds, Set<Integer> years) {
        Map<String, Leave_Balance__c> byKey = new Map<String, Leave_Balance__c>();
        List<Decimal> yearValues = new List<Decimal>();
        for (Integer y : years) yearValues.add(y);

        for (Leave_Balance__c bal : [
            SELECT Id, External_Key__c, Employee__c, Leave_Type__c, Leave_Year__c,
                   Entitlement_Days__c, Accrued_To_Date__c, Available_Balance__c,
                   Used_Days__c, Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Expiry_Date__c, Granted_On__c, Accrual_Method__c,
                   Locked_During_Probation__c, Pending_Days__c, Status__c
            FROM Leave_Balance__c
            WHERE Employee__c IN :employeeIds AND Leave_Year__c IN :yearValues
        ]) {
            byKey.put(bal.External_Key__c, bal);
        }
        return byKey;
    }

    private static List<User> employeesStartedBy(Date today) {
        // Start_Date__c <= today excludes future joiners, who receive the pro-rated
        // new-hire grant on their joining date instead of a full year's entitlement.
        return [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c <= :today
        ];
    }

    private static Set<Id> idsOf(List<User> users) {
        Set<Id> ids = new Set<Id>();
        for (User u : users) ids.add(u.Id);
        return ids;
    }

    /*
     * Must match ApplicationItemTriggerLogic.balanceKey and
     * scripts/apex/03_backfill_leave_balances.apex exactly.
     */
    private static String balanceKey(Id employeeId, String leaveType, Integer yr) {
        return employeeId + '-' + leaveType + '-' + yr;
    }

    @TestVisible
    private static List<Leave_Type_Policy__mdt> activePolicies() {
        List<Leave_Type_Policy__mdt> source = policyOverride != null
            ? policyOverride
            : Leave_Type_Policy__mdt.getAll().values();
        List<Leave_Type_Policy__mdt> active = new List<Leave_Type_Policy__mdt>();
        for (Leave_Type_Policy__mdt p : source) {
            if (p.Active__c == true) active.add(p);
        }
        return active;
    }

    /** The single type granted on an anniversary — Refreshment Leave. */
    private static Leave_Type_Policy__mdt anniversaryPolicy() {
        for (Leave_Type_Policy__mdt p : activePolicies()) {
            if (ACCRUAL_ANNIVERSARY.equals(p.Accrual_Method__c)) return p;
        }
        return null;
    }

    private static Refresh_Leave_Rule__mdt tierFor(List<Refresh_Leave_Rule__mdt> rules, Integer years) {
        Refresh_Leave_Rule__mdt best = null;
        for (Refresh_Leave_Rule__mdt r : rules) {
            if (r.Active__c != true || r.Years_of_Service__c == null) continue;
            if (r.Years_of_Service__c > years) continue;
            if (best == null || r.Years_of_Service__c > best.Years_of_Service__c) {
                best = r;
            }
        }
        return best;
    }

    @TestVisible
    private static List<Refresh_Leave_Rule__mdt> getRules() {
        return ruleOverride != null ? ruleOverride : Refresh_Leave_Rule__mdt.getAll().values();
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }

    private static void createLogFile(String logDetails) {
        try {
            Error_Log__c log = new Error_Log__c();
            log.Process_Type__c = 'Annual Leave Calculation';
            insert log;

            ContentVersion cv = new ContentVersion();
            cv.Title = 'Leave_Calculation_Log_' + System.now().format('yyyyMMdd_HHmmss');
            cv.PathOnClient = 'Log_' + System.now().format('yyyyMMdd_HHmmss') + '.txt';
            cv.VersionData = Blob.valueOf(logDetails);
            cv.FirstPublishLocationId = log.Id;
            insert cv;
        } catch (Exception e) {
            System.debug('Failed to create log file: ' + e.getMessage());
        }
    }
}