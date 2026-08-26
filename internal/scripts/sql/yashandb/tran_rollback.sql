-- File Name: tran_rollback.sql
-- Purpose: Estimate TX rollback ETA via dual-sample USED_UBLK (V$ROLLBACK)
-- Created: 20260803 by huangtingzhong
-- Oracle ref: V$FAST_START_TRANSACTIONS undoblocks/cputime ETA
-- Yashan: no V$FAST_START_*; dual-sample USED_UBLK on RB/residual/open undo TX
--
-- Params:
--   interval_sec  sample gap seconds (default 5, clamp 1..60)
--   sid           optional SID filter (empty=all candidates)
--   min_ublk      min USED_UBLK for open-TX candidates (default 100)
--
-- Notes:
--   User ROLLBACK often leaves V$ROLLBACK empty and RESIDUAL=FALSE; USED_UBLK
--   still decreases on the OPEN TX. Script includes those open undo TX, but
--   prints ETA only when UBLK decreases (DONE>0). GROW rows are suppressed
--   unless SID filter is set.

SET SERVEROUTPUT ON


ACCEPT interval_sec PROMPT 'Enter sample interval seconds (default 5): '
ACCEPT sid PROMPT 'Enter SID filter (empty=all rollback/undo candidates): '
ACCEPT min_ublk PROMPT 'Enter min USED_UBLK for open TX candidates (default 100): '

DECLARE
  c_line_w CONSTANT PLS_INTEGER := 200;

  TYPE t_num IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
  TYPE t_str IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(64);
  TYPE t_keys IS TABLE OF VARCHAR2(64) INDEX BY PLS_INTEGER;

  v_interval   NUMBER;
  v_sid_filter NUMBER;
  v_min_ublk   NUMBER;
  v_sid_raw    VARCHAR2(32) := TRIM('&&sid');
  v_t0         DATE;
  v_t1         DATE;
  v_elapsed    NUMBER;
  v_cnt0       PLS_INTEGER := 0;
  v_cnt1       PLS_INTEGER := 0;
  v_key        VARCHAR2(64);
  v_keys       t_keys;
  v_n          PLS_INTEGER := 0;
  v_printed    PLS_INTEGER := 0;

  v_ublk0      t_num;
  v_ublk1      t_num;
  v_sid0       t_num;
  v_sid1       t_num;
  v_inst0      t_num;
  v_inst1      t_num;
  v_sort0      t_num;
  v_sort1      t_num;
  v_rb0        t_num;
  v_rb1        t_num;
  v_resid0     t_str;
  v_resid1     t_str;
  v_txstat0    t_str;
  v_txstat1    t_str;
  v_user0      t_str;
  v_user1      t_str;
  v_event0     t_str;
  v_event1     t_str;
  v_inpri0     t_str;
  v_inpri1     t_str;
  v_kind0      t_str;
  v_kind1      t_str;

  v_done       NUMBER;
  v_rate       NUMBER;
  v_eta        NUMBER;
  v_line       VARCHAR2(400);
  v_eta_txt    VARCHAR2(32);
  v_rate_txt   VARCHAR2(32);
  v_rb_stat    VARCHAR2(16);
  v_xid_txt    VARCHAR2(32);
  v_show       BOOLEAN;

  PROCEDURE put_line_c(p IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(SUBSTR(p, 1, c_line_w));
  END;

  PROCEDURE snap_into(
    p_ublk   IN OUT NOCOPY t_num,
    p_sid    IN OUT NOCOPY t_num,
    p_inst   IN OUT NOCOPY t_num,
    p_sort   IN OUT NOCOPY t_num,
    p_rb     IN OUT NOCOPY t_num,
    p_resid  IN OUT NOCOPY t_str,
    p_txstat IN OUT NOCOPY t_str,
    p_user   IN OUT NOCOPY t_str,
    p_event  IN OUT NOCOPY t_str,
    p_inpri  IN OUT NOCOPY t_str,
    p_kind   IN OUT NOCOPY t_str,
    p_cnt    OUT PLS_INTEGER
  ) IS
    v_k VARCHAR2(64);
  BEGIN
    p_ublk.DELETE;
    p_sid.DELETE;
    p_inst.DELETE;
    p_sort.DELETE;
    p_rb.DELETE;
    p_resid.DELETE;
    p_txstat.DELETE;
    p_user.DELETE;
    p_event.DELETE;
    p_inpri.DELETE;
    p_kind.DELETE;
    p_cnt := 0;

    FOR r IN (
      SELECT x.inst_id,
             x.xid,
             x.sid,
             x.kind,
             x.in_priority,
             x.sort_pos,
             x.rb_pos,
             x.used_ublk,
             x.residual,
             x.tx_status,
             x.username,
             x.wait_event
        FROM (
              -- 1) rollback queue
              SELECT r.inst_id,
                     r.xid,
                     r.sid,
                     'RB' AS kind,
                     r.in_priority,
                     r.sort_pos,
                     r.rb_pos,
                     NVL(t.used_ublk, 0) AS used_ublk,
                     NVL(t.residual, '-') AS residual,
                     NVL(t.status, '-') AS tx_status,
                     NVL(s.username, '-') AS username,
                     NVL(s.wait_event, '-') AS wait_event
                FROM gv$rollback r
                LEFT JOIN gv$transaction t
                  ON r.inst_id = t.inst_id AND r.xid = t.xid
                LEFT JOIN gv$session s
                  ON r.inst_id = s.inst_id AND r.sid = s.sid
              UNION ALL
              -- 2) residual TX not already in rollback queue
              SELECT t.inst_id,
                     t.xid,
                     t.sid,
                     'RES' AS kind,
                     CAST(NULL AS VARCHAR2(8)) AS in_priority,
                     CAST(NULL AS NUMBER) AS sort_pos,
                     CAST(NULL AS NUMBER) AS rb_pos,
                     NVL(t.used_ublk, 0) AS used_ublk,
                     NVL(t.residual, '-') AS residual,
                     NVL(t.status, '-') AS tx_status,
                     NVL(s.username, '-') AS username,
                     NVL(s.wait_event, '-') AS wait_event
                FROM gv$transaction t
                LEFT JOIN gv$session s
                  ON t.inst_id = s.inst_id AND t.sid = s.sid
               WHERE UPPER(NVL(t.residual, 'FALSE')) = 'TRUE'
                 AND NOT EXISTS (
                       SELECT 1
                         FROM gv$rollback r
                        WHERE r.inst_id = t.inst_id AND r.xid = t.xid
                     )
              UNION ALL
              -- 3) open undo TX (user ROLLBACK path; V$ROLLBACK often empty)
              SELECT t.inst_id,
                     t.xid,
                     t.sid,
                     'TX' AS kind,
                     CAST(NULL AS VARCHAR2(8)) AS in_priority,
                     CAST(NULL AS NUMBER) AS sort_pos,
                     CAST(NULL AS NUMBER) AS rb_pos,
                     NVL(t.used_ublk, 0) AS used_ublk,
                     NVL(t.residual, '-') AS residual,
                     NVL(t.status, '-') AS tx_status,
                     NVL(s.username, '-') AS username,
                     NVL(s.wait_event, '-') AS wait_event
                FROM gv$transaction t
                LEFT JOIN gv$session s
                  ON t.inst_id = s.inst_id AND t.sid = s.sid AND t.xid = s.xid
               WHERE t.status = 'OPEN'
                 AND NVL(t.used_ublk, 0) >= v_min_ublk
                 AND UPPER(NVL(t.residual, 'FALSE')) != 'TRUE'
                 AND NOT EXISTS (
                       SELECT 1
                         FROM gv$rollback r
                        WHERE r.inst_id = t.inst_id AND r.xid = t.xid
                     )
                 AND (s.sid IS NULL OR NVL(s.type, 'USER') != 'BACKGROUND')
             ) x
       WHERE v_sid_filter IS NULL OR x.sid = v_sid_filter
    ) LOOP
      v_k := TO_CHAR(r.inst_id) || '.' || TO_CHAR(r.xid);
      -- prefer RB/RES over TX when same xid appears (should not, by filters)
      IF p_ublk.EXISTS(v_k) AND p_kind(v_k) IN ('RB', 'RES') AND r.kind = 'TX' THEN
        NULL;
      ELSE
        IF NOT p_ublk.EXISTS(v_k) THEN
          p_cnt := p_cnt + 1;
        END IF;
        p_ublk(v_k)   := r.used_ublk;
        p_sid(v_k)    := r.sid;
        p_inst(v_k)   := r.inst_id;
        p_sort(v_k)   := r.sort_pos;
        p_rb(v_k)     := r.rb_pos;
        p_resid(v_k)  := SUBSTR(r.residual, 1, 8);
        p_txstat(v_k) := SUBSTR(r.tx_status, 1, 8);
        p_user(v_k)   := SUBSTR(r.username, 1, 16);
        p_event(v_k)  := SUBSTR(r.wait_event, 1, 28);
        p_inpri(v_k)  := SUBSTR(NVL(r.in_priority, '-'), 1, 5);
        p_kind(v_k)   := r.kind;
      END IF;
    END LOOP;
  END;

  FUNCTION fmt_sec(p_sec IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF p_sec IS NULL THEN
      RETURN '-';
    ELSIF p_sec < 1 THEN
      RETURN TO_CHAR(ROUND(p_sec * 1000)) || 'MS';
    ELSIF p_sec < 10000 THEN
      RETURN TO_CHAR(ROUND(p_sec)) || 'S';
    ELSIF p_sec < 36000 THEN
      RETURN TO_CHAR(ROUND(p_sec / 60)) || 'M';
    ELSE
      RETURN TO_CHAR(ROUND(p_sec / 3600)) || 'H';
    END IF;
  END;

  FUNCTION xid_disp(p_key IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(p_key, INSTR(p_key, '.') + 1, 14);
  END;
BEGIN
  BEGIN
    IF TRIM('&&interval_sec') IS NULL THEN
      v_interval := 5;
    ELSE
      v_interval := TO_NUMBER(TRIM('&&interval_sec'));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_interval := 5;
  END;
  v_interval := LEAST(60, GREATEST(1, NVL(v_interval, 5)));

  BEGIN
    IF v_sid_raw IS NULL THEN
      v_sid_filter := NULL;
    ELSE
      v_sid_filter := TO_NUMBER(v_sid_raw);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_sid_filter := NULL;
  END;

  BEGIN
    IF TRIM('&&min_ublk') IS NULL THEN
      v_min_ublk := 100;
    ELSE
      v_min_ublk := TO_NUMBER(TRIM('&&min_ublk'));
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_min_ublk := 100;
  END;
  IF v_min_ublk < 0 THEN
    v_min_ublk := 0;
  END IF;

  put_line_c('=== TRAN ROLLBACK ETA (USED_UBLK dual sample) ===');
  put_line_c('interval=' || TO_CHAR(v_interval) || 's' ||
             ' sid_filter=' || NVL(TO_CHAR(v_sid_filter), 'ALL') ||
             ' min_ublk=' || TO_CHAR(v_min_ublk) ||
             ' note=no V$FAST_START_*; ETA=remain/(done/elapsed)');

  snap_into(v_ublk0, v_sid0, v_inst0, v_sort0, v_rb0, v_resid0, v_txstat0,
            v_user0, v_event0, v_inpri0, v_kind0, v_cnt0);
  v_t0 := SYSDATE;

  IF v_cnt0 = 0 THEN
    put_line_c('No candidates (GV$ROLLBACK / residual / open TX ublk>=min).');
    put_line_c('Hint: run during ROLLBACK; lower min_ublk; or use rollback_stat.sql');
    RETURN;
  END IF;

  put_line_c('snap0=' || TO_CHAR(v_t0, 'YYYY-MM-DD HH24:MI:SS') ||
             ' targets=' || TO_CHAR(v_cnt0) ||
             ' sleeping ' || TO_CHAR(v_interval) || 's ...');

  DBMS_LOCK.SLEEP(v_interval);

  snap_into(v_ublk1, v_sid1, v_inst1, v_sort1, v_rb1, v_resid1, v_txstat1,
            v_user1, v_event1, v_inpri1, v_kind1, v_cnt1);
  v_t1 := SYSDATE;
  v_elapsed := (v_t1 - v_t0) * 86400;
  IF v_elapsed < 0.1 THEN
    v_elapsed := v_interval;
  END IF;

  put_line_c('snap1=' || TO_CHAR(v_t1, 'YYYY-MM-DD HH24:MI:SS') ||
             ' targets=' || TO_CHAR(v_cnt1) ||
             ' elapsed=' || TO_CHAR(ROUND(v_elapsed, 2)) || 's');
  put_line_c(
    RPAD('KIND', 4) || ' ' ||
    RPAD('I.SID', 8) || ' ' ||
    RPAD('XID', 14) || ' ' ||
    LPAD('UBLK0', 8) || ' ' ||
    LPAD('UBLK1', 8) || ' ' ||
    LPAD('DONE', 7) || ' ' ||
    LPAD('RATE/S', 8) || ' ' ||
    RPAD('ETA', 6) || ' ' ||
    RPAD('EST_DONE', 19) || ' ' ||
    RPAD('RES', 5) || ' ' ||
    RPAD('SORT/RB', 11) || ' ' ||
    RPAD('USER', 12) || ' ' ||
    RPAD('WAIT', 20)
  );
  put_line_c(RPAD('-', c_line_w, '-'));

  v_key := v_ublk0.FIRST;
  WHILE v_key IS NOT NULL LOOP
    v_n := v_n + 1;
    v_keys(v_n) := v_key;
    v_key := v_ublk0.NEXT(v_key);
  END LOOP;

  FOR i IN 1 .. v_n LOOP
    v_key := v_keys(i);
    v_xid_txt := xid_disp(v_key);

    IF NOT v_ublk1.EXISTS(v_key) THEN
      -- finished during sample: show if was RB/RES or had undo
      IF v_kind0(v_key) IN ('RB', 'RES')
         OR NVL(v_ublk0(v_key), 0) >= v_min_ublk
         OR v_sid_filter IS NOT NULL THEN
        put_line_c(
          RPAD(NVL(v_kind0(v_key), '-'), 4) || ' ' ||
          RPAD(TO_CHAR(v_inst0(v_key)) || '.' || TO_CHAR(v_sid0(v_key)), 8) || ' ' ||
          RPAD(v_xid_txt, 14) || ' ' ||
          LPAD(TO_CHAR(v_ublk0(v_key)), 8) || ' ' ||
          LPAD('-', 8) || ' ' ||
          LPAD('-', 7) || ' ' ||
          LPAD('-', 8) || ' ' ||
          RPAD('DONE', 6) || ' ' ||
          RPAD('finished in sample', 19) || ' ' ||
          RPAD(NVL(v_resid0(v_key), '-'), 5) || ' ' ||
          RPAD('-', 11) || ' ' ||
          RPAD(NVL(v_user0(v_key), '-'), 12) || ' ' ||
          RPAD(NVL(v_event0(v_key), '-'), 20)
        );
        v_printed := v_printed + 1;
      END IF;
    ELSE
      v_done := NVL(v_ublk0(v_key), 0) - NVL(v_ublk1(v_key), 0);

      IF v_done > 0 AND v_elapsed > 0 THEN
        v_rate := v_done / v_elapsed;
        IF v_rate > 0 THEN
          v_eta := NVL(v_ublk1(v_key), 0) / v_rate;
        ELSE
          v_eta := NULL;
        END IF;
        v_rate_txt := TO_CHAR(ROUND(v_rate, 2));
        v_eta_txt := fmt_sec(v_eta);
      ELSIF v_done < 0 THEN
        v_rate := NULL;
        v_eta := NULL;
        v_rate_txt := 'GROW';
        v_eta_txt := 'N/A';
      ELSE
        v_rate := NULL;
        v_eta := NULL;
        v_rate_txt := '0';
        v_eta_txt := 'STALL';
      END IF;

      -- TX kind: only show rolling (DONE>0) unless SID filtered
      v_show := FALSE;
      IF v_kind1(v_key) IN ('RB', 'RES') OR v_kind0(v_key) IN ('RB', 'RES') THEN
        v_show := TRUE;
      ELSIF v_sid_filter IS NOT NULL THEN
        v_show := TRUE;
      ELSIF v_done > 0 THEN
        v_show := TRUE;
      END IF;

      IF v_show THEN
        IF v_sort1(v_key) IS NOT NULL AND v_rb1(v_key) IS NOT NULL THEN
          IF v_sort1(v_key) > v_rb1(v_key) THEN
            v_rb_stat := 'QUEUED';
          ELSE
            v_rb_stat := 'REACH';
          END IF;
        ELSE
          v_rb_stat := '-';
        END IF;

        v_line :=
          RPAD(NVL(v_kind1(v_key), v_kind0(v_key)), 4) || ' ' ||
          RPAD(TO_CHAR(v_inst1(v_key)) || '.' || TO_CHAR(v_sid1(v_key)), 8) || ' ' ||
          RPAD(v_xid_txt, 14) || ' ' ||
          LPAD(TO_CHAR(NVL(v_ublk0(v_key), 0)), 8) || ' ' ||
          LPAD(TO_CHAR(NVL(v_ublk1(v_key), 0)), 8) || ' ' ||
          LPAD(TO_CHAR(v_done), 7) || ' ' ||
          LPAD(v_rate_txt, 8) || ' ' ||
          RPAD(v_eta_txt, 6) || ' ' ||
          RPAD(
            CASE
              WHEN v_eta IS NOT NULL THEN
                TO_CHAR(v_t1 + v_eta / 86400, 'YYYY-MM-DD HH24:MI:SS')
              ELSE '-'
            END, 19) || ' ' ||
          RPAD(NVL(v_resid1(v_key), '-'), 5) || ' ' ||
          RPAD(
            CASE
              WHEN v_sort1(v_key) IS NULL THEN '-'
              ELSE TO_CHAR(v_sort1(v_key)) || '/' || TO_CHAR(v_rb1(v_key))
            END, 11) || ' ' ||
          RPAD(NVL(v_user1(v_key), '-'), 12) || ' ' ||
          RPAD(NVL(v_event1(v_key), '-'), 20);

        put_line_c(v_line);
        put_line_c('  tx=' || NVL(v_txstat1(v_key), '-') ||
                   ' in_pri=' || NVL(v_inpri1(v_key), '-') ||
                   ' rb_stat=' || v_rb_stat ||
                   ' gap=' ||
                   CASE
                     WHEN v_sort1(v_key) IS NULL OR v_rb1(v_key) IS NULL THEN '-'
                     ELSE TO_CHAR(v_sort1(v_key) - v_rb1(v_key))
                   END);
        v_printed := v_printed + 1;
      END IF;
    END IF;
  END LOOP;

  -- New RB/RES at snap1 only
  v_key := v_ublk1.FIRST;
  WHILE v_key IS NOT NULL LOOP
    IF NOT v_ublk0.EXISTS(v_key)
       AND v_kind1(v_key) IN ('RB', 'RES') THEN
      put_line_c(
        RPAD(NVL(v_kind1(v_key), '-'), 4) || ' ' ||
        RPAD(TO_CHAR(v_inst1(v_key)) || '.' || TO_CHAR(v_sid1(v_key)), 8) || ' ' ||
        RPAD(xid_disp(v_key), 14) || ' ' ||
        LPAD('-', 8) || ' ' ||
        LPAD(TO_CHAR(NVL(v_ublk1(v_key), 0)), 8) || ' ' ||
        LPAD('-', 7) || ' ' ||
        LPAD('NEW', 8) || ' ' ||
        RPAD('N/A', 6) || ' ' ||
        RPAD('appeared at snap1', 19) || ' ' ||
        RPAD(NVL(v_resid1(v_key), '-'), 5) || ' ' ||
        RPAD(
          CASE
            WHEN v_sort1(v_key) IS NULL THEN '-'
            ELSE TO_CHAR(v_sort1(v_key)) || '/' || TO_CHAR(v_rb1(v_key))
          END, 11) || ' ' ||
        RPAD(NVL(v_user1(v_key), '-'), 12) || ' ' ||
        RPAD(NVL(v_event1(v_key), '-'), 20)
      );
      v_printed := v_printed + 1;
    END IF;
    v_key := v_ublk1.NEXT(v_key);
  END LOOP;

  IF v_printed = 0 THEN
    put_line_c('No rolling TX in this interval (open undo may be GROW/STALL; suppressed).');
    put_line_c('Hint: re-run during ROLLBACK, or set SID filter to force TX rows.');
  END IF;

  put_line_c('=== END (DONE>0=>ETA; GROW=ublk up; STALL=flat; DONE=finished) ===');
END;
/
