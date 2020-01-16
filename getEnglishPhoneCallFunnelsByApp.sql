/*
executionMasks:
  jwt-role-glg: 0
glgjwtComment: 'Deny All'
*/

--parameters
--@startDate DATE
--@endDate DATE

--test
--DECLARE @startDate DATE = '10-1-2019';
--DECLARE @endDate DATE = '10-2-2019';

-- localhost:9730/epiquery1/glgdev/reporting/getEnglishPhoneCallFunnelsByApp.sql?startDate=1-1-2020&endDate=1-1-2020

SET ANSI_NULLS ON
SET QUOTED_IDENTIFIER ON
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
SET NOCOUNT ON

DECLARE @DayAfterEndDate AS DATE
SET @DayAfterEndDate = DATEADD(day, 1, @endDate);

drop table if exists #consultations;
SELECT DISTINCT c.consultation_id
      ,c.title
      ,tax.segment
      ,tax.pod
      ,tax.team
      ,c.primary_rm_person_id
      ,cast(convert(NVARCHAR(4), c.created_date, 112) + replace(str(datepart(mm, c.created_date), 2), ' ', '0') AS INT) AS month
      ,c.product_type_category_id
      ,c.has_alternative_language
into #consultations
    FROM consult.consultation c
    INNER JOIN person p ON c.primary_rm_person_id = p.person_id
    INNER JOIN user_table u ON u.person_id = p.person_id
    CROSS APPLY (
      SELECT TOP 1 taxonomy_id
      FROM employee.user_business_unit ubu
      WHERE ubu.user_id = u.user_id
      ORDER BY start_date DESC
      ) team
    LEFT JOIN employee.USER_BUSINESS_UNIT_TAXONOMY tax ON tax.taxonomy_id = team.taxonomy_id
    WHERE c.created_date >= @startDate
      AND c.created_date < @DayAfterEndDate
      AND c.PRODUCT_TYPE_CATEGORY_ID IN (1, 14, 15, 16); -- phone calls and SP


drop table if exists #attached;
    SELECT month
      ,c.segment
      ,c.pod
      ,c.team
      ,c.primary_rm_person_id
      ,c.product_type_category_id
      ,c.has_alternative_language
      ,mcmsr.created_by
      ,mcmsr.app_name app_name
      ,mcmsr.meeting_id
      ,mcmsr.create_date as attach_date
      ,c.consultation_id AS consultation_id
      ,0 as accepted
      ,0 as paid
      ,CASE 
        WHEN cp.scheduled_date IS NULL
          THEN 0
        ELSE 1
        END AS scheduled
      ,0 as invited
      ,0 as given
      ,0 as declined
      ,0 as declinedBadFit
      ,0 as declinedTooBusy
      ,0 as declinedConflicted
into #attached
    FROM #consultations c
    INNER JOIN consult.consultation_participant cp ON c.consultation_id = cp.consultation_id
    INNER JOIN council_member cm ON cm.person_id = cp.person_id
      AND cm.lead_ind = 0
    INNER JOIN MEETING_COUNCIL_MEMBER_STATUS_RELATION mcmsr ON mcmsr.meeting_id = cp.meeting_id
      AND mcmsr.meeting_participant_status_id = 2;

-- These indexes should make the joins below run faster
CREATE NONCLUSTERED INDEX ix_tempAttachedMeetingId ON #attached (meeting_id);
CREATE NONCLUSTERED INDEX ix_tempAttachedConsultationId ON #attached (consultation_id);

-- Eliminate duplicate attaches for the same meeting, keeping the oldest
delete from #attached where attach_date > (select min(attach_date) from #attached at where at.meeting_id = #attached.meeting_id);

-- Set the various other MCMSR transition flags
update #attached
  set invited = 1
from #attached
INNER JOIN MEETING_COUNCIL_MEMBER_STATUS_RELATION mcmsr ON mcmsr.meeting_id = #attached.meeting_id
  AND mcmsr.meeting_participant_status_id = 3;

update #attached
  set accepted = 1
from #attached
INNER JOIN MEETING_COUNCIL_MEMBER_STATUS_RELATION mcmsr ON mcmsr.meeting_id = #attached.meeting_id
  AND mcmsr.meeting_participant_status_id = 4;

update #attached
  set given = 1
from #attached
INNER JOIN MEETING_COUNCIL_MEMBER_STATUS_RELATION mcmsr ON mcmsr.meeting_id = #attached.meeting_id
  AND mcmsr.meeting_participant_status_id = 10;

update #attached
  set declined = 1
from #attached
INNER JOIN MEETING_COUNCIL_MEMBER_STATUS_RELATION mcmsr ON mcmsr.meeting_id = #attached.meeting_id
  AND mcmsr.meeting_participant_status_id = 5;

-- Set the paid flag from the is_TPV view
UPDATE #attached
  SET paid = 1
FROM #attached
INNER JOIN consult.is_TPV tpv ON tpv.meeting_id = #attached.meeting_id;

-- For declined meetings, set the decline reason where known
UPDATE #attached
  SET declinedBadFit = IIF(declinedBadFit > 0, 1, IIF(cp.council_member_comment='DECLINE_CHOICE_NO_RELEVANT_EXPERTISE', 1, 0)),
      declinedTooBusy = IIF(declinedTooBusy > 0, 1, IIF(cp.council_member_comment='DECLINE_CHOICE_TOO_BUSY', 1, 0)),
      declinedConflicted = IIF(declinedConflicted > 0, 1, IIF(cp.council_member_comment='DECLINE_CHOICE_CONFLICT_OF_INTEREST', 1, 0))
FROM #attached
INNER JOIN consult.consultation_participant cp ON #attached.meeting_id = cp.meeting_id
WHERE #attached.declined > 0;


WITH rollup AS (
    SELECT month
      ,segment
      ,pod
      ,team
      ,primary_rm_person_id
      ,created_by as attached_by_user_id
      ,app_name
      ,product_type_category_id
      ,has_alternative_language
      ,sum(paid) AS tpv
      ,sum(scheduled) scheduled
      ,sum(given) given
      ,sum(declined) AS declined
      ,sum(declinedBadFit) AS 'declined-bad-fit'
      ,sum(declinedTooBusy) AS 'declined-too-busy'
      ,sum(declinedConflicted) AS 'declined-conflicted'
      ,sum(accepted) AS accepted
      ,sum(invited) AS invited
      ,count(1) attaches
    FROM #attached
    GROUP BY month
      ,segment
      ,pod
      ,team
      ,primary_rm_person_id
      ,created_by
      ,app_name
      ,product_type_category_id
      ,has_alternative_language
    )
SELECT
  p.first_name + ' ' + p.last_name AS attached_by
  ,p2.first_name + ' ' + p2.last_name AS primary_rm
  ,ptc.category_name
  ,rollup.*
FROM rollup
LEFT JOIN user_table ut ON ut.user_id = rollup.attached_by_user_id
LEFT JOIN person p ON p.person_id = ut.person_id
join person p2 ON p2.person_id = primary_rm_person_id
join product_type_category ptc ON ptc.product_type_category_id = rollup.product_type_category_id

