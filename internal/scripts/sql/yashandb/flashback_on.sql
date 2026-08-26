-- File Name: flashback_on.sql
-- Purpose: Enable or disable database flashback after user confirmation
-- Created: 20260706  by  huangtingzhong
--
-- Usage: ytop -f flashback_on.sql
-- Confirm: 1=ALTER DATABASE FLASHBACK ON; 0=FLASHBACK OFF; other/Enter=no action

SET SERVEROUTPUT ON
SET VERIFY OFF
SET FEEDBACK OFF


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | Database FLASHBACK ON / OFF                                            |
PROMPT +------------------------------------------------------------------------+
PROMPT | 1 = ALTER DATABASE FLASHBACK ON  (requires ARCHIVELOG)                 |
PROMPT | 0 = ALTER DATABASE FLASHBACK OFF                                     |
PROMPT | Enter or any other value = no action                                   |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT confirm PROMPT 'Confirm (1=on, 0=off, Enter/other=no action): '

DECLARE
  v_confirm   VARCHAR2(32) := TRIM('&&confirm');
  v_flashback VARCHAR2(8);
  v_log_mode  VARCHAR2(32);
  v_start_ts  DATE;
  v_elapsed_ms NUMBER;
BEGIN
  IF v_confirm IS NULL OR v_confirm NOT IN ('0', '1') THEN
    RETURN;
  END IF;

  SELECT UPPER(TRIM(flashback_on)),
         UPPER(TRIM(log_mode))
    INTO v_flashback, v_log_mode
    FROM v$database;

  DBMS_OUTPUT.PUT_LINE('log_mode=' || v_log_mode || ', flashback_on=' || v_flashback);

  IF v_confirm = '1' THEN
    IF v_flashback = 'YES' THEN
      DBMS_OUTPUT.PUT_LINE('FLASHBACK_ON is already YES. No action taken.');
      RETURN;
    END IF;

    IF v_log_mode NOT LIKE '%ARCHIVE%' THEN
      DBMS_OUTPUT.PUT_LINE('ERROR: database must be in ARCHIVELOG mode before enabling flashback.');
      RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('Executing: ALTER DATABASE FLASHBACK ON');
    v_start_ts := SYSDATE;
    EXECUTE IMMEDIATE 'ALTER DATABASE FLASHBACK ON';
    v_elapsed_ms := ROUND((SYSDATE - v_start_ts) * 86400 * 1000);
    DBMS_OUTPUT.PUT_LINE('Done in ' || v_elapsed_ms || ' ms');
  ELSIF v_confirm = '0' THEN
    IF v_flashback = 'NO' THEN
      DBMS_OUTPUT.PUT_LINE('FLASHBACK_ON is already NO. No action taken.');
      RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('Executing: ALTER DATABASE FLASHBACK OFF');
    v_start_ts := SYSDATE;
    EXECUTE IMMEDIATE 'ALTER DATABASE FLASHBACK OFF';
    v_elapsed_ms := ROUND((SYSDATE - v_start_ts) * 86400 * 1000);
    DBMS_OUTPUT.PUT_LINE('Done in ' || v_elapsed_ms || ' ms');
  END IF;

  SELECT UPPER(TRIM(flashback_on))
    INTO v_flashback
    FROM v$database;
  DBMS_OUTPUT.PUT_LINE('FLASHBACK_ON after=' || v_flashback);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
    RAISE;
END;
/
