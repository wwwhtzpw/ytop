
SET SERVEROUTPUT ON

DECLARE
  v_sid          NUMBER;
  v_inst_id      NUMBER;
  v_interval_sec NUMBER;
  v_count        NUMBER;

  TYPE t_snap IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
  TYPE t_stat_list IS TABLE OF VARCHAR2(128);
  TYPE t_num_arr IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  TYPE t_stat_deltas IS TABLE OF t_num_arr INDEX BY VARCHAR2(128);
  TYPE t_date_arr IS TABLE OF DATE INDEX BY PLS_INTEGER;

  v_before       t_snap;
  v_after        t_snap;
  v_stat_list    t_stat_list := t_stat_list();
  v_deltas       t_stat_deltas;
  v_sample_times t_date_arr;
  v_stat         VARCHAR2(128);
  v_delta        NUMBER;
  v_sql        VARCHAR2(4000);
  v_header     VARCHAR2(32767);
  v_line       VARCHAR2(32767);
  v_val        NUMBER;
BEGIN
  -- Params (default when null/empty)
  BEGIN
    IF TRIM('&&inst_id') IS NULL THEN v_inst_id := 1; ELSE v_inst_id := TO_NUMBER(TRIM('&&inst_id')); END IF;
  EXCEPTION WHEN OTHERS THEN v_inst_id := 1; END;
  BEGIN
    IF TRIM('&&sid') IS NULL THEN v_sid := 0; ELSE v_sid := TO_NUMBER(TRIM('&&sid')); END IF;
  EXCEPTION WHEN OTHERS THEN v_sid := 0; END;
  BEGIN
    IF TRIM('&&interval_sec') IS NULL THEN v_interval_sec := 5; ELSE v_interval_sec := TO_NUMBER(TRIM('&&interval_sec')); END IF;
  EXCEPTION WHEN OTHERS THEN v_interval_sec := 5; END;
  BEGIN
    IF TRIM('&&count') IS NULL THEN v_count := 2; ELSE v_count := TO_NUMBER(TRIM('&&count')); END IF;
  EXCEPTION WHEN OTHERS THEN v_count := 2; END;
  v_count := LEAST(10, GREATEST(1, v_count));

  -- First sample
  FOR r IN (
    SELECT STAT_NAME, VALUE
      FROM GV$SESS_TIME_MODEL
     WHERE SID = v_sid AND INST_ID = v_inst_id
     ORDER BY STAT_ID
  ) LOOP
    v_stat_list.EXTEND;
    v_stat_list(v_stat_list.COUNT) := r.STAT_NAME;
    v_before(r.STAT_NAME) := r.VALUE;
  END LOOP;

  IF v_stat_list.COUNT = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No GV$SESS_TIME_MODEL rows for SID=' || v_sid || ', INST_ID=' || v_inst_id);
    RETURN;
  END IF;

  -- Sample N times and compute deltas
  FOR v_period IN 1 .. v_count LOOP
    DBMS_LOCK.SLEEP(v_interval_sec);

    v_after.DELETE;
    FOR r IN (
      SELECT STAT_NAME, VALUE
        FROM GV$SESS_TIME_MODEL
       WHERE SID = v_sid AND INST_ID = v_inst_id
       ORDER BY STAT_ID
    ) LOOP
      v_after(r.STAT_NAME) := r.VALUE;
    END LOOP;

    v_sample_times(v_period) := SYSDATE;
    FOR i IN 1 .. v_stat_list.COUNT LOOP
      v_stat := v_stat_list(i);
      IF v_after.EXISTS(v_stat) THEN
        v_delta := v_after(v_stat) - v_before(v_stat);
        v_deltas(v_stat)(v_period) := v_delta;
      END IF;
    END LOOP;
    v_before := v_after;
  END LOOP;

  -- Pivot: col1=SNAP_TIME, rest=each STAT_NAME
  v_header := RPAD('SNAP_TIME', 20);
  FOR i IN 1 .. v_stat_list.COUNT LOOP
    v_stat := v_stat_list(i);
    v_header := v_header || LPAD(REPLACE(SUBSTR(NVL(v_stat, ' '), 1, 18), ' ', '_'), 20);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(v_header);
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 20 + v_stat_list.COUNT * 20, '-'));

  -- One row per period (SNAP_TIME + deltas)
  FOR p IN 1 .. v_count LOOP
    v_line := RPAD(TO_CHAR(NVL(v_sample_times(p), SYSDATE), 'yyyy-mm-dd hh24:mi:ss'), 20);
    FOR i IN 1 .. v_stat_list.COUNT LOOP
      v_stat := v_stat_list(i);
      IF v_deltas.EXISTS(v_stat) AND v_deltas(v_stat).EXISTS(p) THEN
        v_val := v_deltas(v_stat)(p);
        v_line := v_line || LPAD(TO_CHAR(v_val), 20);
      ELSE
        v_line := v_line || LPAD('', 20);
      END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(v_line);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('Session SID=' || v_sid || ', INST_ID=' || v_inst_id || ', interval=' || v_interval_sec || 's, count=' || v_count);
  DBMS_OUTPUT.PUT_LINE('STAT_NAME cols (all): ' || v_stat_list.COUNT);
END;
/
