-- File Name: job_disable.sql
-- Purpose: Disable a DBMS_SCHEDULER job by owner and job name
-- Created: 20260730 by huangtingzhong
--
-- Usage: ytop -f job_disable.sql
-- Inputs: owner (required), jobname (required), confirm (1=DISABLE, other=abort)
-- Notes:
--   Calls DBMS_SCHEDULER.DISABLE('owner.jobname') for non-RUNNING jobs.
--   If state=RUNNING, stop first with job_stop.sql (STOP_JOB).

SET SERVEROUTPUT ON
SET VERIFY OFF
SET FEEDBACK OFF


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Disable DBMS_SCHEDULER job (DISABLE)                                   |
PROMPT +------------------------------------------------------------------------+
PROMPT | Enter owner + jobname, then confirm=1 to disable.                      |
PROMPT | If RUNNING, use job_stop.sql first. Example: SYS / HTZ_LONG_JOB_1      |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT owner   PROMPT 'Enter owner (schema, required): '
ACCEPT jobname PROMPT 'Enter jobname (required): '
ACCEPT confirm PROMPT 'Confirm disable (1=DISABLE, Enter/other=abort): '

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Job status BEFORE disable                                              |
PROMPT +------------------------------------------------------------------------+

col OWNER      for a10
col JOB_NAME   for a22
col STATE      for a9
col ENABLED    for a5
col JOB_TYPE   for a12
col I          for a1
col LAST_START for a19
col NEXT_RUN   for a19

SELECT
    SUBSTR(owner, 1, 10) AS owner,
    SUBSTR(job_name, 1, 22) AS job_name,
    SUBSTR(state, 1, 9) AS state,
    CASE WHEN enabled THEN 'TRUE' ELSE 'FALSE' END AS enabled,
    SUBSTR(NVL(job_type, '-'), 1, 12) AS job_type,
    SUBSTR(TO_CHAR(NVL(running_instance, 0)), 1, 1) AS i,
    TO_CHAR(last_start_date, 'YYYY-MM-DD HH24:MI:SS') AS last_start,
    TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') AS next_run
  FROM dba_scheduler_jobs
 WHERE owner = UPPER(TRIM('&&owner'))
   AND job_name = UPPER(TRIM('&&jobname'))
/

DECLARE
  v_owner    VARCHAR2(128) := UPPER(TRIM('&&owner'));
  v_jobname  VARCHAR2(128) := UPPER(TRIM('&&jobname'));
  v_confirm  VARCHAR2(32)  := TRIM('&&confirm');
  v_fullname   VARCHAR2(260);
  v_state    VARCHAR2(32);
  v_enabled  BOOLEAN;
  v_cnt      NUMBER;
BEGIN
  IF v_owner IS NULL OR v_jobname IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: owner and jobname are required.');
    RETURN;
  END IF;

  IF v_confirm IS NULL OR v_confirm <> '1' THEN
    DBMS_OUTPUT.PUT_LINE('Aborted: confirm is not 1. No DISABLE executed.');
    RETURN;
  END IF;

  SELECT COUNT(*)
    INTO v_cnt
    FROM dba_scheduler_jobs
   WHERE owner = v_owner
     AND job_name = v_jobname;

  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: job not found: '||v_owner||'.'||v_jobname);
    RETURN;
  END IF;

  SELECT state, enabled
    INTO v_state, v_enabled
    FROM dba_scheduler_jobs
   WHERE owner = v_owner
     AND job_name = v_jobname;

  DBMS_OUTPUT.PUT_LINE('owner='||v_owner||' jobname='||v_jobname
    ||' state='||v_state
    ||' enabled='||CASE WHEN v_enabled THEN 'TRUE' ELSE 'FALSE' END);

  IF NOT v_enabled THEN
    DBMS_OUTPUT.PUT_LINE('Job is already DISABLED. No action taken.');
    RETURN;
  END IF;

  IF v_state = 'RUNNING' THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: job is RUNNING. Use job_stop.sql (STOP_JOB) first, then DISABLE.');
    RETURN;
  END IF;

  v_fullname := v_owner||'.'||v_jobname;
  DBMS_OUTPUT.PUT_LINE('Executing: DBMS_SCHEDULER.DISABLE('''||v_fullname||''')');
  DBMS_SCHEDULER.DISABLE(job_name => v_fullname);
  DBMS_OUTPUT.PUT_LINE('DISABLE completed.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: '||SQLERRM);
    RAISE;
END;
/

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Job status AFTER disable                                               |
PROMPT +------------------------------------------------------------------------+

SELECT
    SUBSTR(owner, 1, 10) AS owner,
    SUBSTR(job_name, 1, 22) AS job_name,
    SUBSTR(state, 1, 9) AS state,
    CASE WHEN enabled THEN 'TRUE' ELSE 'FALSE' END AS enabled,
    SUBSTR(NVL(job_type, '-'), 1, 12) AS job_type,
    SUBSTR(TO_CHAR(NVL(running_instance, 0)), 1, 1) AS i,
    TO_CHAR(last_start_date, 'YYYY-MM-DD HH24:MI:SS') AS last_start,
    TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') AS next_run
  FROM dba_scheduler_jobs
 WHERE owner = UPPER(TRIM('&&owner'))
   AND job_name = UPPER(TRIM('&&jobname'))
/

PROMPT --- End of job_disable ---
