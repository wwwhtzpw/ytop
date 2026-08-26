-- File Name: awr_top_sql_last_day_opt.sql
-- Purpose: YashanDB Top-N AWR SQL last N days, shared object collect
-- Created: 20260311  by  huangtingzhong
-- Updated: 20260809 by huangtingzhong (LITERAL SQL via CLOB; no 32K truncate)
-- Updated: 20260809 by huangtingzhong (GET_PER display -> AVG_GETS)
-- Updated: 20260809 by huangtingzhong (ACCEPT days/username/exclude_user CSV)
--
-- Params: same as awr_top_sql_last_day.sql
--   days / username / exclude_user (CSV ok; Enter = default)
--          collected once across all SQL_IDs). Output SQL text, plan, v$sql/v$sqlstats,
--          and object/table/index info via DBMS_OUTPUT. No DDL.

SET SERVEROUTPUT ON


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | AWR Top-N SQL last N days (opt, shared objects)                        |
PROMPT | days         : Enter = 1 (last day); N = last N calendar days          |
PROMPT | username     : Enter = all; else include schema(s), comma-separated    |
PROMPT | exclude_user : Enter = none; else exclude schema(s), comma-separated   |
PROMPT +------------------------------------------------------------------------+
PROMPT

ACCEPT days PROMPT 'Enter days (Enter=1 last day): '
ACCEPT username PROMPT 'Enter username/schema(s) (Enter=no filter, CSV ok): '
ACCEPT exclude_user PROMPT 'Enter exclude_user(s) (Enter=no exclude, CSV ok): '

DECLARE
    v_days_in   VARCHAR2(64)   := TRIM('&&days');
    v_user_raw  VARCHAR2(4000) := TRIM('&&username');
    v_excl_raw  VARCHAR2(4000) := TRIM('&&exclude_user');
    v_user      VARCHAR2(4000);
    v_excl      VARCHAR2(4000);
    v_days      NUMBER;                 -- last N days (default 1)
    v_top_n     NUMBER        := 10;    -- top N SQL_ID per day by CPU
    v_sql_id    VARCHAR2(64);
    v_line      VARCHAR2(32767);
    v_count     NUMBER := 0;
    v_awr_filt  VARCHAR2(4000);         -- schema filter fragment for dynamic AWR SQL

    -- object owner/name records instead of GTT
    TYPE t_obj_rec IS RECORD (obj_owner VARCHAR2(128), obj_name VARCHAR2(128));
    TYPE t_obj_tab IS TABLE OF t_obj_rec;
    TYPE t_idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), status VARCHAR2(20), partitioned VARCHAR2(3));
    TYPE t_idx_tab IS TABLE OF t_idx_rec;
    plan_objs    t_obj_tab := t_obj_tab();
    table_objs   t_obj_tab := t_obj_tab();
    table_objs_idx t_obj_tab := t_obj_tab();
    index_objs   t_idx_tab := t_idx_tab();
    full_seg_objs t_obj_tab := t_obj_tab();
    in_list_plan   VARCHAR2(32767);
    in_list_table  VARCHAR2(32767);
    uv_table       VARCHAR2(32767);
    uv_plan        VARCHAR2(32767);
    in_list_index  VARCHAR2(32767);
    in_list_seg    VARCHAR2(32767);
    -- all TOP SQL_IDs for object and perf queries
    TYPE t_sqlid_tab IS TABLE OF VARCHAR2(64);
    sql_id_list    t_sqlid_tab := t_sqlid_tab();
    in_list_sql_id VARCHAR2(32767);
    -- v$sql_plan: map PLAN_HASH_VALUE via TO_CHAR to avoid YAS-04458.
    TYPE t_phv_tab IS TABLE OF VARCHAR2(40);
    phv_list       t_phv_tab := t_phv_tab();
    phv            VARCHAR2(40);
    v_ord_seq      NUMBER := 0;
    w_id           NUMBER;
    w_pid          NUMBER;
    w_ord          NUMBER;
    w_op           NUMBER;
    w_name         NUMBER;
    w_rows         NUMBER;
    w_cost         NUMBER;
    w_time         NUMBER;
    c_max_text     CONSTANT NUMBER := 120;
    v_op_txt       VARCHAR2(4000);
    v_name_txt     VARCHAR2(4000);
    v_display_pid  NUMBER;
    TYPE t_ord_map IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_plan_rec IS RECORD (
        id NUMBER, parent_id NUMBER, position NUMBER, operation VARCHAR2(4000), options VARCHAR2(4000)
    );
    TYPE t_plan_tab IS TABLE OF t_plan_rec;
    TYPE t_child_tab IS TABLE OF NUMBER;
    g_ord          t_ord_map;
    g_disp_parent  t_ord_map;
    g_plan_rows    t_plan_tab;

    -- perf row types store raw numbers; fmt_num_kw/fmt_time_us on output
    TYPE r_sqlarea_row IS RECORD (
        r_sql_id VARCHAR2(64), plan_hash_value VARCHAR2(100),
        executions NUMBER, cpu_per_exec NUMBER, ela_per_exec NUMBER, disk_per_exec NUMBER, get_per_exec NUMBER,
        rows_per_exec NUMBER, rows_per_fetches NUMBER, app_wait_per NUMBER, con_wait_per NUMBER, clu_wait_per NUMBER,
        user_io_wait_per NUMBER, plsql_wait_per NUMBER, outline VARCHAR2(200)
    );
    TYPE t_sqlarea_tab IS TABLE OF r_sqlarea_row;
    TYPE r_vsql_row IS RECORD (
        r_sql_id VARCHAR2(64), plan_hash_value VARCHAR2(100), c VARCHAR2(10), username VARCHAR2(128), f_l_time VARCHAR2(50),
        executions NUMBER, cpu_per_exec NUMBER, ela_per_exec NUMBER, disk_per_exec NUMBER, get_per_exec NUMBER,
        rows_per_exec NUMBER, rows_per_fetches NUMBER, app_pre_exec NUMBER, con_pre_exec NUMBER, clu_wait_per NUMBER,
        user_io_wait_per NUMBER, plsql_wait_per NUMBER
    );
    TYPE t_vsql_tab IS TABLE OF r_vsql_row;
    TYPE r_awr_row IS RECORD (
        r_sql_id VARCHAR2(64), end_time VARCHAR2(20), i VARCHAR2(5), username VARCHAR2(128), plan_hash_value VARCHAR2(100),
        executions NUMBER, cpu_per_exec NUMBER, ela_per_exec NUMBER, disk_per_exec NUMBER, get_per_exec NUMBER,
        rows_per_exec NUMBER, rows_per_fetches NUMBER, write_per_exec NUMBER, iowait_per_exec NUMBER, sorts_per_exec NUMBER,
        app_pre_exec NUMBER, con_pre_exec NUMBER, clu_wait_per NUMBER, plsql_wait_per NUMBER
    );
    TYPE t_awr_tab IS TABLE OF r_awr_row;

    -- last-day TOP SQL by CPU, distinct SQL_ID
    CURSOR c_top_sql IS
        WITH snap_range AS (
            SELECT MIN(s.SNAP_ID) AS bid,
                   MAX(s.SNAP_ID) AS eid,
                   MAX(s.DBID) AS DBID,
                   MAX(s.INSTANCE_NUMBER) AS INSTANCE_NUMBER
            FROM SYS.WRM$_SNAPSHOT s
            WHERE s.INSTANCE_NUMBER = (SELECT instance_number FROM v$instance)
              AND TRUNC(s.BEGIN_INTERVAL_TIME) >= TRUNC(SYSDATE) - v_days
        ),
        agg AS (
            SELECT d.SQL_ID,
                   SUM(d.CPU_TIME_DELTA)     AS cput,
                   SUM(d.ELAPSED_TIME_DELTA) AS elap,
                   SUM(d.EXECUTIONS_DELTA)   AS execs,
                   SUM(d.BUFFER_GETS_DELTA)  AS bget
            FROM SYS.WRH$_SQLSTAT d
            JOIN snap_range sr ON d.SNAP_ID > sr.bid AND d.SNAP_ID <= sr.eid
             AND d.DBID = sr.DBID AND d.INSTANCE_NUMBER = sr.INSTANCE_NUMBER
            WHERE (v_user IS NULL
                   OR INSTR(',' || v_user || ',',
                            ',' || UPPER(TRIM(d.parsing_schema_name)) || ',') > 0)
              AND (v_excl IS NULL
                   OR INSTR(',' || v_excl || ',',
                            ',' || UPPER(TRIM(d.parsing_schema_name)) || ',') = 0)
            GROUP BY d.SQL_ID
            HAVING NVL(SUM(d.CPU_TIME_DELTA), 0) > 0 OR NVL(SUM(d.BUFFER_GETS_DELTA), 0) > 0
        ),
        rn AS (
            SELECT SQL_ID,
                   ROW_NUMBER() OVER (ORDER BY cput DESC NULLS LAST, SQL_ID) AS rk
            FROM agg
        )
        SELECT SQL_ID FROM rn WHERE rk <= v_top_n;

    PROCEDURE put_line(s VARCHAR2) IS
        v_max NUMBER := 32000;
        v_len NUMBER;
        v_off NUMBER := 1;
    BEGIN
        IF s IS NULL THEN DBMS_OUTPUT.PUT_LINE(''); RETURN; END IF;
        v_len := LENGTH(s);
        WHILE v_off <= v_len LOOP
            DBMS_OUTPUT.PUT_LINE(SUBSTR(s, v_off, v_max));
            v_off := v_off + v_max;
        END LOOP;
    END;

    -- UTF8: SUBSTR into VARCHAR2(4000) may exceed byte limit; keep emit chunk small
    PROCEDURE put_clob(p_text IN CLOB) IS
        c_chunk CONSTANT PLS_INTEGER := 1000;
        v_len   NUMBER;
        v_off   NUMBER := 1;
        v_buf   VARCHAR2(4000);
    BEGIN
        IF p_text IS NULL THEN
            RETURN;
        END IF;
        v_len := NVL(DBMS_LOB.GETLENGTH(p_text), 0);
        IF v_len = 0 THEN
            RETURN;
        END IF;
        WHILE v_off <= v_len LOOP
            v_buf := DBMS_LOB.SUBSTR(p_text, LEAST(c_chunk, v_len - v_off + 1), v_off);
            DBMS_OUTPUT.PUT_LINE(v_buf);
            v_off := v_off + c_chunk;
        END LOOP;
    END;

    -- number fmt: <1K plain, <10K K, else W for EXEC/DISK_GETS/ROWS
    FUNCTION fmt_num_kw(p_val NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN RETURN NULL; END IF;
        IF p_val < 1000 THEN RETURN TO_CHAR(ROUND(p_val, 2)); END IF;
        IF p_val < 10000 THEN RETURN TO_CHAR(ROUND(p_val/1000, 2)) || 'K'; END IF;
        RETURN TO_CHAR(ROUND(p_val/10000, 2)) || 'W';
    END fmt_num_kw;

    -- time input in microseconds, output ms/s/m/h per exec
        FUNCTION fmt_time_us(p_us NUMBER) RETURN VARCHAR2 IS
        v_ms NUMBER;
    BEGIN
        IF p_us IS NULL THEN RETURN NULL; END IF;
        v_ms := p_us / 1000;  -- microseconds to milliseconds
        IF v_ms < 1000 THEN RETURN ROUND(v_ms, 2) || 'ms'; END IF;
        IF v_ms/1000 < 60 THEN RETURN ROUND(v_ms/1000, 2) || 's'; END IF;
        IF v_ms/1000/60 < 60 THEN RETURN ROUND(v_ms/1000/60, 2) || 'm'; END IF;
        RETURN ROUND(v_ms/1000/60/60, 2) || 'h';
    END fmt_time_us;

    FUNCTION find_tab_access_parent(p_id NUMBER, p_parent_id NUMBER) RETURN NUMBER IS
        v_tab_id NUMBER := NULL;
    BEGIN
        FOR i IN 1 .. g_plan_rows.COUNT LOOP
            IF g_plan_rows(i).parent_id = p_parent_id
               AND g_plan_rows(i).id < p_id
               AND (
                     g_plan_rows(i).operation LIKE '%BY INDEX ROWID%'
                     OR NVL(g_plan_rows(i).options, ' ') LIKE '%INDEX ROWID%'
                   ) THEN
                IF v_tab_id IS NULL OR g_plan_rows(i).id > v_tab_id THEN
                    v_tab_id := g_plan_rows(i).id;
                END IF;
            END IF;
        END LOOP;
        RETURN v_tab_id;
    END find_tab_access_parent;

    PROCEDURE load_plan_rows(p_sql VARCHAR2, p_phv VARCHAR2) IS
    BEGIN
        -- One row per id for this PHV (collapse multi-child / multi-address copies)
        SELECT id, parent_id, position, operation, options
          BULK COLLECT INTO g_plan_rows
          FROM (
            SELECT id, parent_id, position, operation, options,
                   ROW_NUMBER() OVER (
                     PARTITION BY id
                     ORDER BY child_number NULLS LAST, child_address, address
                   ) AS rn
              FROM v$sql_plan
             WHERE sql_id = p_sql
               AND TO_CHAR(plan_hash_value) = p_phv
               AND id IS NOT NULL
               AND operation IS NOT NULL
          )
         WHERE rn = 1;
    END load_plan_rows;

    PROCEDURE build_display_parent IS
    BEGIN
        g_disp_parent.DELETE;
        FOR i IN 1 .. g_plan_rows.COUNT LOOP
            IF g_plan_rows(i).parent_id IS NULL
               OR g_plan_rows(i).operation NOT LIKE 'INDEX%' THEN
                g_disp_parent(g_plan_rows(i).id) := g_plan_rows(i).parent_id;
            ELSE
                v_display_pid := find_tab_access_parent(
                    g_plan_rows(i).id, g_plan_rows(i).parent_id
                );
                IF v_display_pid IS NOT NULL THEN
                    g_disp_parent(g_plan_rows(i).id) := v_display_pid;
                ELSE
                    g_disp_parent(g_plan_rows(i).id) := g_plan_rows(i).parent_id;
                END IF;
            END IF;
        END LOOP;
    END build_display_parent;

    FUNCTION plan_position(p_id NUMBER) RETURN NUMBER IS
    BEGIN
        FOR i IN 1 .. g_plan_rows.COUNT LOOP
            IF g_plan_rows(i).id = p_id THEN
                RETURN NVL(g_plan_rows(i).position, 0);
            END IF;
        END LOOP;
        RETURN 0;
    END plan_position;

    FUNCTION list_display_children(p_parent_id NUMBER) RETURN t_child_tab IS
        v_children t_child_tab := t_child_tab();
        v_swap     NUMBER;
        v_pos_i    NUMBER;
        v_pos_j    NUMBER;
    BEGIN
        FOR i IN 1 .. g_plan_rows.COUNT LOOP
            IF NVL(g_disp_parent(g_plan_rows(i).id), -1) = NVL(p_parent_id, -1) THEN
                v_children.EXTEND;
                v_children(v_children.COUNT) := g_plan_rows(i).id;
            END IF;
        END LOOP;
        IF v_children.COUNT > 1 THEN
            FOR i IN 1 .. v_children.COUNT - 1 LOOP
                FOR j IN i + 1 .. v_children.COUNT LOOP
                    v_pos_i := plan_position(v_children(i));
                    v_pos_j := plan_position(v_children(j));
                    IF v_pos_j < v_pos_i
                       OR (v_pos_j = v_pos_i AND v_children(j) < v_children(i)) THEN
                        v_swap := v_children(i);
                        v_children(i) := v_children(j);
                        v_children(j) := v_swap;
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
        RETURN v_children;
    END list_display_children;

    PROCEDURE walk_plan_ord(p_parent_id NUMBER, io_ord IN OUT NUMBER) IS
        v_children t_child_tab;
    BEGIN
        v_children := list_display_children(p_parent_id);
        FOR i IN 1 .. v_children.COUNT LOOP
            walk_plan_ord(v_children(i), io_ord);
            io_ord := io_ord + 1;
            g_ord(v_children(i)) := io_ord;
        END LOOP;
    END walk_plan_ord;

    FUNCTION grow_w(p_cur NUMBER, p_txt VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(NVL(p_cur, 0), NVL(LENGTH(p_txt), 0));
    END grow_w;

    FUNCTION cell_l(p_txt VARCHAR2, p_w NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN LPAD(SUBSTR(NVL(p_txt, ' '), 1, p_w), p_w);
    END cell_l;

    FUNCTION cell_r(p_txt VARCHAR2, p_w NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RPAD(SUBSTR(NVL(p_txt, ' '), 1, p_w), p_w);
    END cell_r;

BEGIN
    DBMS_OUTPUT.ENABLE(1000000);

    IF v_days_in IS NULL OR LENGTH(v_days_in) = 0 THEN
        v_days := 1;
    ELSE
        BEGIN
            v_days := TO_NUMBER(v_days_in);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(30301,
                    'Invalid days="' || NVL(v_days_in, '')
                    || '"; expect positive number or Enter');
        END;
    END IF;
    IF v_days IS NULL OR v_days <= 0 THEN
        RAISE_APPLICATION_ERROR(30301,
            'Invalid days=' || NVL(TO_CHAR(v_days), 'NULL') || '; must be > 0');
    END IF;

    DECLARE
        PROCEDURE norm_csv(p_in IN VARCHAR2, p_out OUT VARCHAR2) IS
            v_rest VARCHAR2(4000);
            v_tok  VARCHAR2(128);
            v_out  VARCHAR2(4000) := NULL;
            v_pos  NUMBER;
        BEGIN
            p_out := NULL;
            IF p_in IS NULL OR LENGTH(TRIM(p_in)) = 0 THEN
                RETURN;
            END IF;
            v_rest := UPPER(TRIM(p_in)) || ',';
            LOOP
                v_pos := INSTR(v_rest, ',');
                EXIT WHEN v_pos = 0 OR v_rest IS NULL;
                v_tok := TRIM(SUBSTR(v_rest, 1, v_pos - 1));
                IF v_pos < LENGTH(v_rest) THEN
                    v_rest := SUBSTR(v_rest, v_pos + 1);
                ELSE
                    v_rest := NULL;
                END IF;
                IF v_tok IS NOT NULL AND LENGTH(v_tok) > 0 THEN
                    IF v_out IS NULL THEN
                        v_out := v_tok;
                    ELSIF INSTR(',' || v_out || ',', ',' || v_tok || ',') = 0 THEN
                        v_out := v_out || ',' || v_tok;
                    END IF;
                END IF;
            END LOOP;
            p_out := v_out;
        END;
    BEGIN
        norm_csv(v_user_raw, v_user);
        norm_csv(v_excl_raw, v_excl);
    END;

    v_awr_filt := '';
    IF v_user IS NOT NULL THEN
        v_awr_filt := v_awr_filt
            || ' AND INSTR('',''||''' || REPLACE(v_user, '''', '''''')
            || '''||'','','',''||UPPER(TRIM(a.parsing_schema_name))||'','')>0';
    END IF;
    IF v_excl IS NOT NULL THEN
        v_awr_filt := v_awr_filt
            || ' AND INSTR('',''||''' || REPLACE(v_excl, '''', '''''')
            || '''||'','','',''||UPPER(TRIM(a.parsing_schema_name))||'','')=0';
    END IF;

    put_line('collect_top: start'
        || ' days=' || TO_CHAR(v_days)
        || ' user=' || NVL(v_user, 'ALL')
        || ' excl=' || NVL(v_excl, 'NONE')
        || ' top_n=' || TO_CHAR(v_top_n));

    -- 1) collect all TOP SQL_IDs into list
    FOR rec IN c_top_sql LOOP
        v_count := v_count + 1;
        sql_id_list.EXTEND(1);
        sql_id_list(sql_id_list.COUNT) := rec.SQL_ID;
    END LOOP;
    IF sql_id_list.COUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('No SQL_ID found. Exit.');
        RETURN;
    END IF;
    -- 2) build SQL_ID IN list for queries
    in_list_sql_id := '';
    FOR i IN 1..sql_id_list.COUNT LOOP
        IF i > 1 THEN in_list_sql_id := in_list_sql_id || ','; END IF;
        in_list_sql_id := in_list_sql_id || '''' || REPLACE(sql_id_list(i), '''', '''''') || '''';
    END LOOP;

    -- 3) collect objects for all SQL_IDs once
    plan_objs    := t_obj_tab();
    table_objs   := t_obj_tab();
    table_objs_idx := t_obj_tab();
    index_objs   := t_idx_tab();
    full_seg_objs := t_obj_tab();
    EXECUTE IMMEDIATE
        'SELECT DISTINCT OBJECT_OWNER, OBJECT_NAME FROM V$SQL_PLAN WHERE SQL_ID IN (' || in_list_sql_id || ') AND OBJECT_NAME IS NOT NULL'
        BULK COLLECT INTO plan_objs;

        in_list_plan := '(NULL,NULL)';
        IF plan_objs IS NOT NULL AND plan_objs.COUNT > 0 THEN
            in_list_plan := '';
            FOR i IN 1..plan_objs.COUNT LOOP
                IF i > 1 THEN in_list_plan := in_list_plan || ','; END IF;
                in_list_plan := in_list_plan || '(''' || REPLACE(plan_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(plan_objs(i).obj_name, '''', '''''') || ''')';
            END LOOP;
        END IF;
        -- Build dual-union for plan objects (small-set drive; avoid IN semi-join on dba_indexes)
        uv_plan := 'SELECT CAST(NULL AS VARCHAR2(128)) AS owner, CAST(NULL AS VARCHAR2(128)) AS name FROM dual WHERE 1=0';
        IF plan_objs IS NOT NULL AND plan_objs.COUNT > 0 THEN
            uv_plan := '';
            FOR i IN 1..plan_objs.COUNT LOOP
                IF i > 1 THEN uv_plan := uv_plan || ' UNION ALL '; END IF;
                uv_plan := uv_plan || 'SELECT ''' || REPLACE(plan_objs(i).obj_owner, '''', '''''') || ''' AS owner, ''' || REPLACE(plan_objs(i).obj_name, '''', '''''') || ''' AS name FROM dual';
            END LOOP;
        END IF;
        EXECUTE IMMEDIATE
            'SELECT DISTINCT i.table_owner, i.table_name FROM dba_indexes i JOIN (' || uv_plan || ') p ON i.owner = p.owner AND i.index_name = p.name'
            BULK COLLECT INTO table_objs_idx;
        table_objs := table_objs_idx;
        FOR i IN 1..plan_objs.COUNT LOOP
            DECLARE
                found BOOLEAN := FALSE;
            BEGIN
                FOR j IN 1..table_objs.COUNT LOOP
                    IF table_objs(j).obj_owner = plan_objs(i).obj_owner AND table_objs(j).obj_name = plan_objs(i).obj_name THEN
                        found := TRUE; EXIT;
                    END IF;
                END LOOP;
                IF NOT found THEN
                    table_objs.EXTEND(1);
                    table_objs(table_objs.COUNT).obj_owner := plan_objs(i).obj_owner;
                    table_objs(table_objs.COUNT).obj_name  := plan_objs(i).obj_name;
                END IF;
            END;
        END LOOP;
        in_list_table := '(NULL,NULL)';
        uv_table := 'SELECT CAST(NULL AS VARCHAR2(128)) AS owner, CAST(NULL AS VARCHAR2(128)) AS table_name FROM dual WHERE 1=0';
        IF table_objs IS NOT NULL AND table_objs.COUNT > 0 THEN
            in_list_table := '';
            uv_table := '';
            FOR i IN 1..table_objs.COUNT LOOP
                IF i > 1 THEN
                    in_list_table := in_list_table || ',';
                    uv_table := uv_table || ' UNION ALL ';
                END IF;
                in_list_table := in_list_table || '(''' || REPLACE(table_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(table_objs(i).obj_name, '''', '''''') || ''')';
                uv_table := uv_table || 'SELECT ''' || REPLACE(table_objs(i).obj_owner, '''', '''''') || ''' AS owner, ''' || REPLACE(table_objs(i).obj_name, '''', '''''') || ''' AS table_name FROM dual';
            END LOOP;
        END IF;
        EXECUTE IMMEDIATE
            'SELECT i.OWNER, i.INDEX_NAME, i.status, i.PARTITIONED FROM DBA_INDEXES i JOIN (' || uv_table || ') x ON i.TABLE_OWNER = x.owner AND i.TABLE_NAME = x.table_name WHERE i.status NOT IN (''VALID'')'
            BULK COLLECT INTO index_objs;
        in_list_index := NULL;
        FOR ix IN 1..NVL(index_objs.COUNT, 0) LOOP
            IF index_objs(ix).partitioned = 'YES' THEN
                IF in_list_index IS NOT NULL THEN in_list_index := in_list_index || ','; END IF;
                in_list_index := NVL(in_list_index, '') || '(''' || REPLACE(index_objs(ix).owner, '''', '''''') || ''',''' || REPLACE(index_objs(ix).index_name, '''', '''''') || ''')';
            END IF;
        END LOOP;
        IF in_list_index IS NULL OR in_list_index = '' THEN in_list_index := '(NULL,NULL)'; END IF;
        -- deduped plan-union-table list for OBJECT SIZE
        full_seg_objs := table_objs;
        FOR i IN 1..plan_objs.COUNT LOOP
            DECLARE
                found BOOLEAN := FALSE;
            BEGIN
                FOR j IN 1..full_seg_objs.COUNT LOOP
                    IF full_seg_objs(j).obj_owner = plan_objs(i).obj_owner AND full_seg_objs(j).obj_name = plan_objs(i).obj_name THEN
                        found := TRUE; EXIT;
                    END IF;
                END LOOP;
                IF NOT found THEN
                    full_seg_objs.EXTEND(1);
                    full_seg_objs(full_seg_objs.COUNT).obj_owner := plan_objs(i).obj_owner;
                    full_seg_objs(full_seg_objs.COUNT).obj_name  := plan_objs(i).obj_name;
                END IF;
            END;
        END LOOP;
        in_list_seg := '(NULL,NULL)';
        IF full_seg_objs IS NOT NULL AND full_seg_objs.COUNT > 0 THEN
            in_list_seg := '';
            FOR i IN 1..full_seg_objs.COUNT LOOP
                IF i > 1 THEN in_list_seg := in_list_seg || ','; END IF;
                in_list_seg := in_list_seg || '(''' || REPLACE(full_seg_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(full_seg_objs(i).obj_name, '''', '''''') || ''')';
            END LOOP;
        END IF;

    -- 4) per SQL_ID perf sections; object sections printed once at end
    FOR sql_idx IN 1..sql_id_list.COUNT LOOP
        v_sql_id := sql_id_list(sql_idx);
        DBMS_OUTPUT.PUT_LINE('Processing SQL_ID: ' || v_sql_id);

        put_line('****************************************************************************************');
        put_line('SQL_ID: ' || v_sql_id);
        put_line('****************************************************************************************');
        put_line('');
        put_line('LITERAL SQL');
        put_line('****************************************************************************************');

        -- LITERAL SQL: full sql_fulltext as CLOB (no VARCHAR2 32K cap)
        DECLARE
            lv_sql_text CLOB;
            lv_schema   VARCHAR2(128);
            lv_len      NUMBER;
        BEGIN
            SELECT parsing_schema_name, sql_fulltext
              INTO lv_schema, lv_sql_text
              FROM (
                SELECT parsing_schema_name, sql_fulltext
                  FROM V$SQL
                 WHERE SQL_ID = v_sql_id
                   AND sql_fulltext IS NOT NULL
                 ORDER BY DBMS_LOB.GETLENGTH(sql_fulltext) DESC NULLS LAST
              )
             WHERE ROWNUM = 1;
            lv_len := NVL(DBMS_LOB.GETLENGTH(lv_sql_text), 0);
            put_line('Schema: ' || lv_schema || '  chars=' || TO_CHAR(lv_len));
            put_clob(lv_sql_text);
            put_line('--------------------------------------------------------');
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                put_line('Schema: (not found)');
                put_line('(SQL text not in V$SQL)');
                put_line('--------------------------------------------------------');
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PLAN from v$sql_plan');
        put_line( '****************************************************************************************');

        /* PLAN: TO_CHAR DISTINCT PHV list; detail filter TO_CHAR(plan_hash_value) */
        phv_list := t_phv_tab();
        EXECUTE IMMEDIATE
            'SELECT DISTINCT TO_CHAR(plan_hash_value) FROM v$sql_plan WHERE sql_id = :1 ORDER BY 1'
            BULK COLLECT INTO phv_list USING v_sql_id;

        FOR phv_idx IN 1..NVL(phv_list.COUNT, 0) LOOP
            phv := phv_list(phv_idx);
            /* Nested FOR: use DBMS_OUTPUT if put_line fails with YAS-04243 */
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('============================================================================');
            DBMS_OUTPUT.PUT_LINE('Plan Hash Value: ' || NVL(phv, '(null)'));
            DBMS_OUTPUT.PUT_LINE('============================================================================');
            DBMS_OUTPUT.PUT_LINE('');
            g_ord.DELETE;
            load_plan_rows(v_sql_id, phv);
            build_display_parent;
            v_ord_seq := 0;
            walk_plan_ord(0, v_ord_seq);
            v_ord_seq := v_ord_seq + 1;
            g_ord(0) := v_ord_seq;


            -- Pass 1: measure column widths for this plan
            w_id   := LENGTH('Id');
            w_pid  := LENGTH('Pid');
            w_ord  := LENGTH('Ord');
            w_op   := LENGTH('Operation');
            w_name := LENGTH('Name');
            w_rows := LENGTH('Rows');
            w_cost := LENGTH('Cost');
            w_time := LENGTH('Time');
            FOR det IN (
                SELECT id, parent_id, depth, position, operation, options, object_owner, object_name, object_type,
                       cost, cardinality, access_predicates, filter_predicates, partition_start, partition_stop,
                       time AS plan_time
                  FROM v$sql_plan
                 WHERE sql_id = v_sql_id
                   AND TO_CHAR(plan_hash_value) = phv
                   AND id IS NOT NULL
                   AND operation IS NOT NULL
                   AND child_number = (
                         SELECT MIN(sp2.child_number)
                           FROM v$sql_plan sp2
                          WHERE sp2.sql_id = v_sql_id
                            AND TO_CHAR(sp2.plan_hash_value) = phv
                       )
                 ORDER BY id
            ) LOOP
                v_op_txt := LPAD(' ', det.depth*2) || det.operation || NVL(' '||det.options,'');
                IF det.object_name IS NOT NULL THEN
                    v_name_txt := det.object_owner||'.'||det.object_name;
                    IF det.object_type IS NOT NULL THEN
                        v_name_txt := v_name_txt || ' [' || det.object_type || ']';
                    END IF;
                ELSE
                    v_name_txt := '';
                END IF;
                w_id   := grow_w(w_id, TO_CHAR(det.id));
                IF g_disp_parent(det.id) IS NOT NULL THEN
                    w_pid := grow_w(w_pid, TO_CHAR(g_disp_parent(det.id)));
                END IF;
                w_ord  := grow_w(w_ord, TO_CHAR(g_ord(det.id)));
                w_op   := grow_w(w_op, v_op_txt);
                w_name := grow_w(w_name, v_name_txt);
                w_rows := grow_w(w_rows, TO_CHAR(det.cardinality));
                w_cost := grow_w(w_cost, TO_CHAR(det.cost));
                w_time := grow_w(w_time, TO_CHAR(det.plan_time));
                IF LENGTH(TRIM(NVL(det.access_predicates, ''))) > 0 THEN
                    w_op := grow_w(w_op, '  -> Access: ' || det.access_predicates);
                END IF;
                IF LENGTH(TRIM(NVL(det.filter_predicates, ''))) > 0 THEN
                    w_op := grow_w(w_op, '  -> Filter: ' || det.filter_predicates);
                END IF;
                IF NVL(det.partition_start, 0) <> 0 OR NVL(det.partition_stop, 0) <> 0 THEN
                    w_op := grow_w(w_op, '  -> Partition: ' || NVL(TO_CHAR(det.partition_start), '?') || '..' ||
                                         NVL(TO_CHAR(det.partition_stop), '?'));
                END IF;
            END LOOP;
            w_op   := LEAST(w_op, c_max_text);
            w_name := LEAST(w_name, c_max_text);

            DBMS_OUTPUT.PUT_LINE('|' || cell_l('Id', w_id) || '|' || cell_l('Pid', w_pid) || '|' || cell_l('Ord', w_ord) || '|' ||
                                 cell_r('Operation', w_op) || '|' || cell_r('Name', w_name) || '|' ||
                                 cell_r('Rows', w_rows) || '|' || cell_r('Cost', w_cost) || '|' || cell_r('Time', w_time) || '|');
            DBMS_OUTPUT.PUT_LINE('|' || LPAD('-', w_id, '-') || '|' || LPAD('-', w_pid, '-') || '|' || LPAD('-', w_ord, '-') || '|' ||
                                 RPAD('-', w_op, '-') || '|' || RPAD('-', w_name, '-') || '|' ||
                                 RPAD('-', w_rows, '-') || '|' || RPAD('-', w_cost, '-') || '|' || RPAD('-', w_time, '-') || '|');

            -- Pass 2: print with measured widths
            FOR det IN (
                SELECT id, parent_id, depth, position, operation, options, object_owner, object_name, object_type,
                       cost, cardinality, access_predicates, filter_predicates, partition_start, partition_stop,
                       time AS plan_time
                  FROM v$sql_plan
                 WHERE sql_id = v_sql_id
                   AND TO_CHAR(plan_hash_value) = phv
                   AND id IS NOT NULL
                   AND operation IS NOT NULL
                   AND child_number = (
                         SELECT MIN(sp2.child_number)
                           FROM v$sql_plan sp2
                          WHERE sp2.sql_id = v_sql_id
                            AND TO_CHAR(sp2.plan_hash_value) = phv
                       )
                 ORDER BY id
            ) LOOP
                v_op_txt := LPAD(' ', det.depth*2) || det.operation || NVL(' '||det.options,'');
                IF det.object_name IS NOT NULL THEN
                    v_name_txt := det.object_owner||'.'||det.object_name;
                    IF det.object_type IS NOT NULL THEN
                        v_name_txt := v_name_txt || ' [' || det.object_type || ']';
                    END IF;
                ELSE
                    v_name_txt := '';
                END IF;
                v_line := '|' || cell_l(NVL(TO_CHAR(det.id), ' '), w_id) || '|' ||
                          cell_l(CASE WHEN g_disp_parent(det.id) IS NULL
                                      THEN ' ' ELSE TO_CHAR(g_disp_parent(det.id)) END, w_pid) || '|' ||
                          cell_l(TO_CHAR(g_ord(det.id)), w_ord) || '|' ||
                          cell_r(v_op_txt, w_op) || '|' ||
                          cell_r(v_name_txt, w_name) || '|' ||
                          cell_r(TO_CHAR(det.cardinality), w_rows) || '|' ||
                          cell_r(TO_CHAR(det.cost), w_cost) || '|' ||
                          cell_r(TO_CHAR(det.plan_time), w_time) || '|';
                DBMS_OUTPUT.PUT_LINE(SUBSTR(NVL(v_line, ' '), 1, 32000));
                IF LENGTH(TRIM(NVL(det.access_predicates, ''))) > 0 THEN
                    DBMS_OUTPUT.PUT_LINE(SUBSTR('|' || cell_l(' ', w_id) || '|' || cell_l(' ', w_pid) || '|' || cell_l(' ', w_ord) || '|' ||
                                              cell_r('  -> Access: ' || det.access_predicates, w_op) || '|' ||
                                              cell_r(' ', w_name) || '|' || cell_r(' ', w_rows) || '|' || cell_r(' ', w_cost) || '|' || cell_r(' ', w_time) || '|', 1, 32000));
                END IF;
                IF LENGTH(TRIM(NVL(det.filter_predicates, ''))) > 0 THEN
                    DBMS_OUTPUT.PUT_LINE(SUBSTR('|' || cell_l(' ', w_id) || '|' || cell_l(' ', w_pid) || '|' || cell_l(' ', w_ord) || '|' ||
                                              cell_r('  -> Filter: ' || det.filter_predicates, w_op) || '|' ||
                                              cell_r(' ', w_name) || '|' || cell_r(' ', w_rows) || '|' || cell_r(' ', w_cost) || '|' || cell_r(' ', w_time) || '|', 1, 32000));
                END IF;
                IF NVL(det.partition_start, 0) <> 0 OR NVL(det.partition_stop, 0) <> 0 THEN
                    DBMS_OUTPUT.PUT_LINE(SUBSTR('|' || cell_l(' ', w_id) || '|' || cell_l(' ', w_pid) || '|' || cell_l(' ', w_ord) || '|' ||
                                              cell_r('  -> Partition: ' || NVL(TO_CHAR(det.partition_start), '?') || '..' ||
                                                   NVL(TO_CHAR(det.partition_stop), '?'), w_op) || '|' ||
                                              cell_r(' ', w_name) || '|' || cell_r(' ', w_rows) || '|' || cell_r(' ', w_cost) || '|' || cell_r(' ', w_time) || '|', 1, 32000));
                END IF;
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('============================================================================');
        END LOOP;

        put_line( '');
        DBMS_OUTPUT.PUT_LINE('--- Output done for SQL_ID: ' || v_sql_id || ' ---');
    END LOOP;

    -- 4b) unified perf query with sql_id IN list
    put_line( '');
    put_line( '+------------------------------------------------------------------------+');
    put_line( '| infromation  from v$sqlstats (all TOP SQLs, one query)                 |');
    put_line( '+------------------------------------------------------------------------+');
    put_line( '');
    put_line(RPAD('SQL_ID',14) || ' ' || RPAD('PHV',10) || ' ' || RPAD('EXEC',8) || ' ' || RPAD('CPU_PER',10) || ' ' || RPAD('ELA_PER',10) || ' ' || RPAD('DISK_PER',9) || ' ' || RPAD('AVG_GETS',9) || ' ' || RPAD('ROWS_PER',9) || ' ' || RPAD('ROW_FETCH',10) || ' ' || RPAD('APP_PER',10) || ' ' || RPAD('CON_WPER',10) || ' ' || RPAD('CLU_PER',10) || ' ' || RPAD('UIO_PER',10) || ' ' || RPAD('PLSQL_PER',10) || ' ' || RPAD('OUTLINE',18));

    DECLARE
        sqlarea_coll t_sqlarea_tab;
        v_sq VARCHAR2(32767);
    BEGIN
        v_sq := 'SELECT sql_id AS r_sql_id, TO_CHAR(PLAN_HASH_VALUE)||'''' AS plan_hash_value, EXECUTIONS AS executions, '
            || 'CPU_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS cpu_per_exec, ELAPSED_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS ela_per_exec, '
            || 'DISK_READS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS disk_per_exec, BUFFER_GETS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS get_per_exec, '
            || 'ROWS_PROCESSED/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_exec, fetches/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_fetches, '
            || 'APPLICATION_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS app_wait_per, CONCURRENCY_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS con_wait_per, '
            || 'CLUSTER_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS clu_wait_per, USER_IO_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS user_io_wait_per, '
            || 'PLSQL_EXEC_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS plsql_wait_per, CAST(NULL AS VARCHAR(64)) AS outline '
            || 'FROM v$sqlarea WHERE sql_id IN (' || in_list_sql_id || ') ORDER BY sql_id';
        EXECUTE IMMEDIATE v_sq BULK COLLECT INTO sqlarea_coll;
        FOR i IN 1..NVL(sqlarea_coll.COUNT,0) LOOP
            v_line := RPAD(SUBSTR(NVL(sqlarea_coll(i).r_sql_id,' '),1,14),14) || ' '
                || RPAD(SUBSTR(NVL(sqlarea_coll(i).plan_hash_value,' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(sqlarea_coll(i).executions),' '),1,8),8) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).cpu_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).ela_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(sqlarea_coll(i).disk_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(sqlarea_coll(i).get_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(sqlarea_coll(i).rows_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(sqlarea_coll(i).rows_per_fetches),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).app_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).con_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).clu_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).user_io_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(sqlarea_coll(i).plsql_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(sqlarea_coll(i).outline,' '),1,18),18);
            put_line(v_line);
        END LOOP;
    END;

    -- 4c) unified v$sql query with sql_id IN list
    put_line( '');
    put_line( '+------------------------------------------------------------------------+');
    put_line( '| information from v$sql (all TOP SQLs, one query)                      |');
    put_line( '+------------------------------------------------------------------------+');
    put_line( '');
    put_line(RPAD('SQL_ID',14) || ' ' || RPAD('EXEC',8) || ' ' || RPAD('PHV',10) || ' ' || RPAD('C',3) || ' ' || RPAD('USERNAME',15) || ' ' || RPAD('CPU_PER',10) || ' ' || RPAD('ELA_PER',10) || ' ' || RPAD('DISK_PER',9) || ' ' || RPAD('AVG_GETS',9) || ' ' || RPAD('ROWS_PER',9) || ' ' || RPAD('ROW_FETCH',10) || ' ' || RPAD('APP_PER',10) || ' ' || RPAD('CON_PER',10) || ' ' || RPAD('CLU_PER',10) || ' ' || RPAD('UIO_PER',10) || ' ' || RPAD('PLSQL_PER',10) || ' ' || RPAD('F_L_TIME',12));

    DECLARE
        vsql_coll t_vsql_tab;
        v_sq2 VARCHAR2(32767);
    BEGIN
        v_sq2 := 'SELECT sql_id AS r_sql_id, TO_CHAR(PLAN_HASH_VALUE)||'''' AS plan_hash_value, child_number||'''' AS c, PARSING_SCHEMA_NAME AS username, '
            || 'SUBSTR(FIRST_LOAD_TIME, 6, 10) || ''.'' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time, '
            || 'EXECUTIONS AS executions, CPU_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS cpu_per_exec, ELAPSED_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS ela_per_exec, '
            || 'DISK_READS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS disk_per_exec, BUFFER_GETS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS get_per_exec, '
            || 'ROWS_PROCESSED/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_exec, ROWS_PROCESSED/DECODE(FETCHES,0,1,FETCHES) AS rows_per_fetches, '
            || 'APPLICATION_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS app_pre_exec, CONCURRENCY_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS con_pre_exec, '
            || 'CLUSTER_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS clu_wait_per, USER_IO_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS user_io_wait_per, '
            || 'PLSQL_EXEC_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS plsql_wait_per '
            || 'FROM v$sql WHERE sql_id IN (' || in_list_sql_id || ') ORDER BY sql_id, TO_CHAR(PLAN_HASH_VALUE)';
        EXECUTE IMMEDIATE v_sq2 BULK COLLECT INTO vsql_coll;
        FOR i IN 1..NVL(vsql_coll.COUNT,0) LOOP
            v_line := RPAD(SUBSTR(NVL(vsql_coll(i).r_sql_id,' '),1,14),14) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(vsql_coll(i).executions),' '),1,8),8) || ' '
                || RPAD(SUBSTR(NVL(vsql_coll(i).plan_hash_value,' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(vsql_coll(i).c,' '),1,3),3) || ' '
                || RPAD(SUBSTR(NVL(vsql_coll(i).username,' '),1,15),15) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).cpu_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).ela_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(vsql_coll(i).disk_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(vsql_coll(i).get_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(vsql_coll(i).rows_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(vsql_coll(i).rows_per_fetches),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).app_pre_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).con_pre_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).clu_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).user_io_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(vsql_coll(i).plsql_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(vsql_coll(i).f_l_time,' '),1,12),12);
            put_line(v_line);
        END LOOP;
    END;

        put_line( '');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '| information from awr (all TOP SQLs) sysdate-' || v_days
            || ' user=' || NVL(v_user, 'ALL')
            || ' excl=' || NVL(v_excl, 'NONE'));
        put_line( '+------------------------------------------------------------------------+');
        put_line( '');
        put_line(RPAD('SQL_ID',14) || ' ' || RPAD('END_TIME',8) || ' ' || RPAD('I',2) || ' ' || RPAD('USERNAME',15) || ' ' || RPAD('PHV',10) || ' ' || RPAD('EXEC',8) || ' ' || RPAD('CPU_PER',10) || ' ' || RPAD('ELA_PER',10) || ' ' || RPAD('DISK_PER',9) || ' ' || RPAD('AVG_GETS',9) || ' ' || RPAD('ROWS_PER',9) || ' ' || RPAD('ROW_FETCH',10) || ' ' || RPAD('WRITE_PER',9) || ' ' || RPAD('IOWAIT_PER',10) || ' ' || RPAD('SORT_PER',10) || ' ' || RPAD('APP_PER',10) || ' ' || RPAD('CON_PER',10) || ' ' || RPAD('CLU_PER',10) || ' ' || RPAD('PLSQL_PER',10));

    DECLARE
        awr_coll t_awr_tab;
        v_sq_awr VARCHAR2(32767);
    BEGIN
        v_sq_awr := 'SELECT a.sql_id AS r_sql_id, TO_CHAR(b.END_INTERVAL_TIME, ''dd hh24'') AS end_time, TRIM(TO_CHAR(a.instance_number)) AS i, a.parsing_schema_name AS username, TO_CHAR(a.plan_hash_value)||'''' AS plan_hash_value, '
            || 'executions_delta AS executions, cpu_time_delta/DECODE(executions_delta,0,1,executions_delta) AS cpu_per_exec, elapsed_time_delta/DECODE(executions_delta,0,1,executions_delta) AS ela_per_exec, '
            || 'disk_reads_delta/DECODE(executions_delta,0,1,executions_delta) AS disk_per_exec, BUFFER_GETS_DELTA/DECODE(executions_delta,0,1,executions_delta) AS get_per_exec, '
            || 'rows_processed_delta/DECODE(executions_delta,0,1,executions_delta) AS rows_per_exec, fetches_delta/DECODE(executions_delta,0,1,executions_delta) AS rows_per_fetches, '
            || 'direct_writes_delta/DECODE(executions_delta,0,1,executions_delta) AS write_per_exec, IOWAIT_DELTA/DECODE(executions_delta,0,1,executions_delta) AS iowait_per_exec, sorts_delta/DECODE(executions_delta,0,1,executions_delta) AS sorts_per_exec, '
            || 'apwait_delta/DECODE(executions_delta,0,1,executions_delta) AS app_pre_exec, ccwait_delta/DECODE(executions_delta,0,1,executions_delta) AS con_pre_exec, '
            || 'clwait_delta/DECODE(executions_delta,0,1,executions_delta) AS clu_wait_per, plsexec_time_delta/DECODE(executions_delta,0,1,executions_delta) AS plsql_wait_per '
            || 'FROM SYS.WRH$_SQLSTAT a, SYS.WRM$_SNAPSHOT b WHERE a.sql_id IN (' || in_list_sql_id || ') AND a.snap_id = b.snap_id AND b.END_INTERVAL_TIME > SYSDATE - ' || v_days || ' AND a.instance_number = b.instance_number'
            || v_awr_filt
            || ' ORDER BY a.sql_id, 1';
        EXECUTE IMMEDIATE v_sq_awr BULK COLLECT INTO awr_coll;
        FOR i IN 1..NVL(awr_coll.COUNT,0) LOOP
            v_line := RPAD(SUBSTR(NVL(awr_coll(i).r_sql_id,' '),1,14),14) || ' '
                || RPAD(SUBSTR(NVL(awr_coll(i).end_time,' '),1,8),8) || ' '
                || RPAD(SUBSTR(NVL(awr_coll(i).i,' '),1,2),2) || ' '
                || RPAD(SUBSTR(NVL(awr_coll(i).username,' '),1,15),15) || ' '
                || RPAD(SUBSTR(NVL(awr_coll(i).plan_hash_value,' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).executions),' '),1,8),8) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).cpu_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).ela_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).disk_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).get_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).rows_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).rows_per_fetches),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).write_per_exec),' '),1,9),9) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).iowait_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_num_kw(awr_coll(i).sorts_per_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).app_pre_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).con_pre_exec),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).clu_wait_per),' '),1,10),10) || ' '
                || RPAD(SUBSTR(NVL(fmt_time_us(awr_coll(i).plsql_wait_per),' '),1,10),10);
            put_line(v_line);
        END LOOP;
    END;

    -- 5) object sections once without SQL_ID
    put_line( '');
    put_line( '****************************************************************************************');
    put_line( 'OBJECT SIZE');
    put_line( '****************************************************************************************');
    put_line(RPAD('OWNER',15) || RPAD('SEGMENT_NAME',25) || RPAD('SEGMENT_TYPE',20) || RPAD('SEGMENT_SIZE',15));

        DECLARE
            TYPE seg_rec IS RECORD (owner VARCHAR2(128), segment_name VARCHAR2(128), segment_type VARCHAR2(20), segment_size VARCHAR2(64));
            TYPE seg_tab IS TABLE OF seg_rec;
            seg_coll seg_tab;
            seg_name_disp VARCHAR2(256);
            is_tbl BOOLEAN;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT b.owner, b.segment_name, b.segment_type, TO_CHAR(TRUNC(b.bytes/1024/1024))||''M'' AS segment_size FROM (
                    SELECT owner, segment_name, segment_type, SUM(bytes) bytes FROM dba_segments
                    WHERE (owner, segment_name) IN (' || in_list_seg || ') GROUP BY owner, segment_type, segment_name
                ) b ORDER BY b.owner, b.segment_name'
                BULK COLLECT INTO seg_coll;
            FOR i IN 1..NVL(seg_coll.COUNT, 0) LOOP
                is_tbl := FALSE;
                FOR j IN 1..table_objs.COUNT LOOP
                    IF table_objs(j).obj_owner = seg_coll(i).owner AND table_objs(j).obj_name = seg_coll(i).segment_name THEN
                        is_tbl := TRUE; EXIT;
                    END IF;
                END LOOP;
                seg_name_disp := CASE WHEN is_tbl THEN '***' || seg_coll(i).segment_name ELSE seg_coll(i).segment_name END;
                v_line := RPAD(SUBSTR(NVL(seg_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(seg_name_disp,' '),1,25),25) || RPAD(SUBSTR(NVL(seg_coll(i).segment_type,' '),1,20),20) || RPAD(SUBSTR(NVL(seg_coll(i).segment_size,' '),1,15),15);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'TABLES');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('L_T',5) || RPAD('DEGREE',7) || RPAD('PART',5) || RPAD('NUM_ROWS',10) || RPAD('BLOCKS',10) || RPAD('EMPTY_BLOCKS',13) || RPAD('AVG_SPACE',11) || RPAD('AVG_ROW_LEN',12) || RPAD('BLOCK_SIZE',11) || RPAD('AVG_SIZE',10) || RPAD('STALE_STATS',12) || RPAD('LAST_ANALYZED',19));

        DECLARE
            TYPE tbl_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), l_t VARCHAR2(20), degree VARCHAR2(40), part VARCHAR2(3), num_rows VARCHAR2(40), blocks VARCHAR2(40), empty_blocks VARCHAR2(40), avg_space VARCHAR2(40), avg_row_len VARCHAR2(40), block_size VARCHAR2(40), avg_size VARCHAR2(40), stale_stats VARCHAR2(20), last_analyzed DATE);
            TYPE tbl_tab IS TABLE OF tbl_rec;
            tbl_coll tbl_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.TABLE_NAME, a.LOGGING||''.''||a.TEMPORARY AS l_t, LTRIM(a.DEGREE) AS degree, a.PARTITIONED AS part, a.NUM_ROWS||'''' AS num_rows, a.BLOCKS||'''' AS blocks, a.EMPTY_BLOCKS||'''' AS empty_blocks, b.AVG_SPACE||'''' AS avg_space, b.AVG_ROW_LEN||'''' AS avg_row_len, TO_CHAR(TRUNC((b.blocks*tp.block_size)/1024/1024)) AS block_size, TO_CHAR(TRUNC((b.AVG_ROW_LEN*b.NUM_ROWS)/1024/1024)) AS avg_size, b.STALE_STATS||'''' AS stale_stats, a.LAST_ANALYZED FROM (' || uv_table || ') x JOIN DBA_TABLES a ON a.owner = x.owner AND a.table_name = x.table_name LEFT JOIN dba_tab_statistics b ON b.owner = a.owner AND b.table_name = a.table_name AND b.object_type = ''TABLE'' LEFT JOIN dba_tablespaces tp ON tp.tablespace_name = a.tablespace_name ORDER BY a.owner, a.table_name'
                BULK COLLECT INTO tbl_coll;
            FOR i IN 1..NVL(tbl_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(tbl_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(tbl_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(tbl_coll(i).l_t,' '),1,5),5) || RPAD(SUBSTR(NVL(tbl_coll(i).degree,' '),1,7),7) || RPAD(SUBSTR(NVL(tbl_coll(i).part,' '),1,5),5) || RPAD(SUBSTR(NVL(tbl_coll(i).num_rows,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).blocks,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).empty_blocks,' '),1,13),13) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_space,' '),1,11),11) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_row_len,' '),1,12),12) || RPAD(SUBSTR(NVL(tbl_coll(i).block_size,' '),1,11),11) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_size,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).stale_stats,' '),1,12),12) || RPAD(SUBSTR(NVL(TO_CHAR(tbl_coll(i).last_analyzed,'yyyy-mm-dd hh24:mi:ss'),' '),1,19),19);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'TABLE COLUMNS');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || ' ' || RPAD('TABLE_NAME',25) || ' ' || RPAD('COLUMN_NAME',15) || ' ' || RPAD('D_TYPE',20) || ' ' || RPAD('NUM_DISTINCT',13) || ' ' || RPAD('N',2) || ' ' || RPAD('NUM_NULLS',10) || ' ' || RPAD('DENSITY',14) || ' ' || RPAD('NUM_BUCKETS',12) || ' ' || RPAD('AVG_COL_LEN',12) || ' ' || RPAD('SAMPLE_SIZE',12) || ' ' || RPAD('HISTOGRAM',10) || ' ' || RPAD('LAST_ANALYZED',19));

        DECLARE
            TYPE col_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), column_name VARCHAR2(128), d_type VARCHAR2(64), num_distinct VARCHAR2(40), n VARCHAR2(10), num_nulls VARCHAR2(40), density VARCHAR2(40), num_buckets VARCHAR2(40), avg_col_len VARCHAR2(40), sample_size VARCHAR2(40), histogram VARCHAR2(10), last_analyzed DATE);
            TYPE col_tab IS TABLE OF col_rec;
            col_coll col_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.OWNER, a.TABLE_NAME, a.COLUMN_NAME, a.data_type||''(''||a.data_length||'')'' AS d_type, b.NUM_DISTINCT||'''' AS num_distinct, a.NULLABLE||'''' AS n, b.NUM_NULLS||'''' AS num_nulls, SUBSTR(NVL(TO_CHAR(b.DENSITY,''FM999999999990.999999999999''),'' ''),1,14) AS density, b.NUM_BUCKETS||'''' AS num_buckets, b.AVG_COL_LEN||'''' AS avg_col_len, b.sample_size||'''' AS sample_size, SUBSTR(b.HISTOGRAM,1,5) AS histogram, b.LAST_ANALYZED FROM (' || uv_table || ') x JOIN DBA_TAB_COLS a ON a.owner = x.owner AND a.table_name = x.table_name LEFT JOIN DBA_TAB_COL_STATISTICS b ON b.owner = a.owner AND b.table_name = a.table_name AND b.column_name = a.column_name ORDER BY a.owner, a.table_name, a.COLUMN_ID'
                BULK COLLECT INTO col_coll;
            FOR i IN 1..NVL(col_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(col_coll(i).owner,' '),1,15),15) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).table_name,' '),1,25),25) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).column_name,' '),1,15),15) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).d_type,' '),1,20),20) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).num_distinct,' '),1,13),13) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).n,' '),1,2),2) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).num_nulls,' '),1,10),10) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).density,' '),1,14),14) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).num_buckets,' '),1,12),12) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).avg_col_len,' '),1,12),12) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).sample_size,' '),1,12),12) || ' '
                    || RPAD(SUBSTR(NVL(col_coll(i).histogram,' '),1,10),10) || ' '
                    || RPAD(SUBSTR(NVL(TO_CHAR(col_coll(i).last_analyzed,'yyyy-mm-dd hh24:mi:ss'),' '),1,19),19);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'INDEX STATUS');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('INDEX_NAME',20) || RPAD('PARTITION_NAME',20) || RPAD('SUBPARTITION_NAME',20) || RPAD('STATUS',10));

        FOR ix IN 1..NVL(index_objs.COUNT, 0) LOOP
            IF index_objs(ix).partitioned = 'NO' THEN
                v_line := RPAD(SUBSTR(NVL(index_objs(ix).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(index_objs(ix).index_name,' '),1,20),20) || RPAD(' ',20) || RPAD(' ',20) || RPAD(SUBSTR(NVL(index_objs(ix).status,' '),1,10),10);
                put_line(v_line);
            END IF;
        END LOOP;
        DECLARE
            TYPE idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), partition_name VARCHAR2(128), subpartition_name VARCHAR2(128), status VARCHAR2(20));
            TYPE idx_tab IS TABLE OF idx_rec;
            idx_coll idx_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT p.INDEX_OWNER, p.INDEX_NAME, PARTITION_NAME, '' '' AS subpartition_name, p.status FROM dba_ind_partitions p WHERE (p.INDEX_OWNER, p.INDEX_NAME) IN (' || in_list_index || ') AND p.status NOT IN (''USABLE'') ORDER BY 1,2,3'
                BULK COLLECT INTO idx_coll;
            FOR i IN 1..NVL(idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).subpartition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).status,' '),1,10),10);
                put_line(v_line);
            END LOOP;
            EXECUTE IMMEDIATE
                'SELECT p.INDEX_OWNER, p.INDEX_NAME, PARTITION_NAME, SUBPARTITION_NAME, p.status FROM dba_ind_subpartitions p WHERE (p.INDEX_OWNER, p.INDEX_NAME) IN (' || in_list_index || ') AND p.status NOT IN (''USABLE'') ORDER BY 1,2,3,4'
                BULK COLLECT INTO idx_coll;
            FOR i IN 1..NVL(idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).subpartition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).status,' '),1,10),10);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'INDEX INFO');
        put_line( '****************************************************************************************');
        put_line(RPAD('TABLE_OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('INDEX_NAME',20) || RPAD('UCPTV',6) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16) || RPAD('DESCEND',10));

        DECLARE
            TYPE idx2_rec IS RECORD (table_owner VARCHAR2(128), table_name VARCHAR2(128), index_name VARCHAR2(128), ucptv VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER, descend VARCHAR2(10));
            TYPE idx2_tab IS TABLE OF idx2_rec;
            idx2_coll idx2_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT A.TABLE_OWNER, A.TABLE_NAME, A.INDEX_NAME, DECODE(A.UNIQUENESS,''UNIQUE'',''U'',''NONUNIQUE'',''N'',''O'')||DECODE(A.COMPRESSION,''ENABLED'',''E'',''DISABLED'',''N'',''O'')||DECODE(A.PARTITIONED,''YES'',''Y'',''NO'',''N'',''O'')||DECODE(A.TEMPORARY,''Y'',''Y'',''N'',''N'',''O'')||DECODE(A.VISIBILITY,''VISIBLE'',''V'',''INVISIBLE'',''I'',''O'') AS ucptv, B.COLUMN_NAME, B.COLUMN_POSITION, B.DESCEND FROM (' || uv_table || ') x JOIN DBA_INDEXES A ON A.table_owner = x.owner AND A.table_name = x.table_name JOIN DBA_IND_COLUMNS B ON A.OWNER = B.INDEX_OWNER AND A.INDEX_NAME = B.INDEX_NAME ORDER BY A.table_owner, A.table_name, A.index_name, B.COLUMN_POSITION'
                BULK COLLECT INTO idx2_coll;
            FOR i IN 1..NVL(idx2_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx2_coll(i).table_owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx2_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(idx2_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx2_coll(i).ucptv,' '),1,6),6) || RPAD(SUBSTR(NVL(idx2_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(idx2_coll(i).column_position),' '),1,16),16) || RPAD(SUBSTR(NVL(idx2_coll(i).descend,' '),1,10),10);
                put_line(v_line);
            END LOOP;
        END;

        -- PARTITION INDEX section like sql.sql
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PARTITION INDEX');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('INDEX_NAME',20) || RPAD('PART_TYPE',15) || RPAD('SUBPART_TYPE',15) || RPAD('PART_COUNT',11) || RPAD('KEY_COUNT',10) || RPAD('SUBKEY_COUT',12) || RPAD('LOCALITY',10) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16));

        DECLARE
            TYPE part_idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), part_type VARCHAR2(20), subpart_type VARCHAR2(20), part_count VARCHAR2(20), key_count VARCHAR2(20), subkey_cout VARCHAR2(20), locality VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER);
            TYPE part_idx_tab IS TABLE OF part_idx_rec;
            part_idx_coll part_idx_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.name AS index_name, b.partitioning_type AS part_type, b.subpartitioning_type AS subpart_type, b.partition_count||'''' AS part_count, b.PARTITIONING_KEY_COUNT||'''' AS key_count, b.SUBPARTITIONING_KEY_COUNT||'''' AS subkey_cout, b.LOCALITY||'''' AS locality, a.COLUMN_NAME, a.COLUMN_POSITION FROM DBA_PART_KEY_COLUMNS a JOIN dba_part_indexes b ON a.name = b.index_name AND a.owner = b.owner JOIN dba_indexes i ON i.owner = b.owner AND i.index_name = b.index_name JOIN (' || uv_table || ') x ON i.table_owner = x.owner AND i.table_name = x.table_name ORDER BY a.owner, a.name, a.column_position'
                BULK COLLECT INTO part_idx_coll;
            FOR i IN 1..NVL(part_idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(part_idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(part_idx_coll(i).part_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).subpart_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).part_count,' '),1,11),11) || RPAD(SUBSTR(NVL(part_idx_coll(i).key_count,' '),1,10),10) || RPAD(SUBSTR(NVL(part_idx_coll(i).subkey_cout,' '),1,12),12) || RPAD(SUBSTR(NVL(part_idx_coll(i).locality,' '),1,10),10) || RPAD(SUBSTR(NVL(part_idx_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(part_idx_coll(i).column_position),' '),1,16),16);
                put_line(v_line);
            END LOOP;
        END;

        -- PARTITION TABLE section like sql.sql
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PARTITION TABLE');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('PART_TYPE',15) || RPAD('SUBPART_TYPE',15) || RPAD('PART_COUNT',11) || RPAD('KEY_COUNT',10) || RPAD('SUBKEY_COUT',12) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16));

        DECLARE
            TYPE part_tbl_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), part_type VARCHAR2(20), subpart_type VARCHAR2(20), part_count VARCHAR2(20), key_count VARCHAR2(20), subkey_cout VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER);
            TYPE part_tbl_tab IS TABLE OF part_tbl_rec;
            part_tbl_coll part_tbl_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.name AS table_name, b.partitioning_type AS part_type, b.subpartitioning_type AS subpart_type, b.partition_count||'''' AS part_count, b.PARTITIONING_KEY_COUNT||'''' AS key_count, b.SUBPARTITIONING_KEY_COUNT||'''' AS subkey_cout, a.COLUMN_NAME, a.COLUMN_POSITION FROM DBA_PART_KEY_COLUMNS a JOIN dba_part_tables b ON a.name = b.table_name AND a.owner = b.owner JOIN (' || uv_table || ') x ON a.owner = x.owner AND a.name = x.table_name ORDER BY a.NAME, a.COLUMN_POSITION'
                BULK COLLECT INTO part_tbl_coll;
            FOR i IN 1..NVL(part_tbl_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(part_tbl_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(part_tbl_coll(i).part_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).subpart_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).part_count,' '),1,11),11) || RPAD(SUBSTR(NVL(part_tbl_coll(i).key_count,' '),1,10),10) || RPAD(SUBSTR(NVL(part_tbl_coll(i).subkey_cout,' '),1,12),12) || RPAD(SUBSTR(NVL(part_tbl_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(part_tbl_coll(i).column_position),' '),1,16),16);
                put_line(v_line);
            END LOOP;
        END;

        -- partition details from DBA_TAB_PARTITIONS like sql.sql
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'display every partition  info');
        put_line( '****************************************************************************************');
        put_line(RPAD('TABLE_NAME',25) || RPAD('PARTITION_NAME',20) || RPAD('HIGH_VALUE',25) || RPAD('HIGH_VALUE_LENGTH',19) || RPAD('TABLESPACE_NAME',16) || RPAD('NUM_ROWS',10) || RPAD('BLOCKS',10) || RPAD('T_SIZE',10) || RPAD('EMPTY_BLOCKS',13) || RPAD('LAST_ANALYZED',19) || RPAD('AVG_SPACE',11) || RPAD('SPCNT',5));

        DECLARE
            TYPE tab_part_rec IS RECORD (table_name VARCHAR2(128), partition_name VARCHAR2(128), high_value VARCHAR2(4000), high_value_length VARCHAR2(20), tablespace_name VARCHAR2(128), num_rows VARCHAR2(20), blocks VARCHAR2(20), t_size VARCHAR2(20), empty_blocks VARCHAR2(20), last_analyzed VARCHAR2(20), avg_space VARCHAR2(20), spcnt VARCHAR2(20));
            TYPE tab_part_tab IS TABLE OF tab_part_rec;
            tab_part_coll tab_part_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT p.table_name, p.PARTITION_NAME, SUBSTR(p.HIGH_VALUE,1,25) AS high_value, TO_CHAR(p.HIGH_VALUE_LENGTH) AS high_value_length, p.TABLESPACE_NAME, p.NUM_ROWS||'''' AS num_rows, p.BLOCKS||'''' AS blocks, TO_CHAR(ROUND(p.blocks*8/1024,2))||''KB'' AS t_size, p.EMPTY_BLOCKS||'''' AS empty_blocks, TO_CHAR(p.LAST_ANALYZED,''yyyy-mm-dd hh24:mi:ss'') AS last_analyzed, p.AVG_SPACE||'''' AS avg_space, SUBSTR(p.SUBPARTITION_COUNT||'''',1,5) AS spcnt FROM DBA_TAB_PARTITIONS p JOIN (' || uv_table || ') x ON p.table_owner = x.owner AND p.table_name = x.table_name ORDER BY p.table_name, p.PARTITION_POSITION'
                BULK COLLECT INTO tab_part_coll;
            FOR i IN 1..NVL(tab_part_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(tab_part_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(tab_part_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(tab_part_coll(i).high_value,' '),1,25),25) || RPAD(SUBSTR(NVL(tab_part_coll(i).high_value_length,' '),1,19),19) || RPAD(SUBSTR(NVL(tab_part_coll(i).tablespace_name,' '),1,16),16) || RPAD(SUBSTR(NVL(tab_part_coll(i).num_rows,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).blocks,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).t_size,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).empty_blocks,' '),1,13),13) || RPAD(SUBSTR(NVL(tab_part_coll(i).last_analyzed,' '),1,19),19) || RPAD(SUBSTR(NVL(tab_part_coll(i).avg_space,' '),1,11),11) || RPAD(SUBSTR(NVL(tab_part_coll(i).spcnt,' '),1,5),5);
                put_line(v_line);
            END LOOP;
        END;

    DBMS_OUTPUT.PUT_LINE('Done. Total SQL_IDs written: ' || v_count);
END;
/

-- ============================================================================
-- Verification (optimized collect_top.sql):
-- 1) Run awr_sql_by_cpu_by_day.sql first with days_back=1 for TOP SQL_ID list.
-- 2) Pass all TOP SQL_IDs; collect objects once without duplication.
-- 3) Perf sections include SQL_ID column; object sections once without SQL_ID.
-- 4) Perf columns match sql.sql with SQL_ID; objects are union of all SQL.
-- 5) YashanDB: selecting PLAN_HASH_VALUE in PL/SQL may raise YAS-04458;
--    Plan section uses TO_CHAR(plan_hash_value) for DISTINCT and filters.
-- 6) Some builds: use DBMS_OUTPUT.PUT_LINE in plan section if put_line fails.
-- ============================================================================
