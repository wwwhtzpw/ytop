-- File Name:sql.sql
-- Purpose: display sql tuning information
-- Created: 20251201  by  huangtingzhong



set heading on;
set serveroutput on;
prompt
prompt ****************************************************************************************
prompt LITERAL SQL
prompt ****************************************************************************************


DECLARE
  LVC_SQL_TEXT      VARCHAR2(32000);
  LVC_ORIG_SQL_TEXT VARCHAR2(32000);
  LN_CHILD          NUMBER := 10000;
  LVC_BIND          VARCHAR2(200);
  LVC_NAME          VARCHAR2(30);
  LN_BIND_COUNT     NUMBER := 0;
  CURSOR C1 IS
    SELECT CHILD_NUMBER, NAME, POSITION, DATATYPE_STRING, VALUE_STRING
      -- add
      ,sql_id
      -- add end
      FROM V$SQL_BIND_CAPTURE
     WHERE SQL_ID = '&&sqlid'
     ORDER BY CHILD_NUMBER, POSITION;
BEGIN

  SELECT SQL_FULLTEXT
    INTO LVC_ORIG_SQL_TEXT
    FROM V$SQL
   WHERE SQL_ID = '&&sqlid'
     AND ROWNUM = 1;

  SELECT parsing_schema_name
    INTO LVC_NAME
    FROM v$sql
   WHERE sql_id = '&&sqlid'
     AND ROWNUM = 1;


  SELECT COUNT(*)
    INTO LN_BIND_COUNT
    FROM V$SQL_BIND_CAPTURE
   WHERE SQL_ID = '&&sqlid' and ROWNUM=1;


  IF LN_BIND_COUNT = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Schema: ' || LVC_NAME);
    DBMS_OUTPUT.PUT_LINE(LVC_ORIG_SQL_TEXT);
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
    RETURN;
  END IF;


  FOR R1 IN C1 LOOP
    IF (R1.CHILD_NUMBER <> LN_CHILD) THEN
      IF LN_CHILD <> 10000 THEN
        DBMS_OUTPUT.PUT_LINE(LVC_NAME);
        DBMS_OUTPUT.PUT_LINE(LVC_SQL_TEXT);
        DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------');
      END IF;
      LN_CHILD     := R1.CHILD_NUMBER;
      LVC_SQL_TEXT := LVC_ORIG_SQL_TEXT;
    END IF;

    -- add
    select parsing_schema_name into LVC_NAME from v$sql where sql_id=r1.sql_id and child_number=r1.CHILD_NUMBER;
    -- add end

    IF R1.NAME LIKE ':SYS_B_%' THEN
      LVC_BIND := ':"'||substr(R1.NAME,2)||'"';
    ELSE
      LVC_BIND := R1.NAME;
    END IF;

    IF r1.VALUE_STRING IS NOT NULL THEN
      IF R1.DATATYPE_STRING = 'NUMBER' THEN
        LVC_SQL_TEXT := REGEXP_REPLACE(LVC_SQL_TEXT, LVC_BIND, R1.VALUE_STRING,1,1,'i');
      ELSIF R1.DATATYPE_STRING LIKE 'VARCHAR%' THEN
        LVC_SQL_TEXT := REGEXP_REPLACE(LVC_SQL_TEXT, LVC_BIND, ''''||R1.VALUE_STRING||'''',1,1,'i');
      ELSE
        LVC_SQL_TEXT := REGEXP_REPLACE(LVC_SQL_TEXT, LVC_BIND, ''''||R1.VALUE_STRING||'''',1,1,'i');
      END IF;
    ELSE
       LVC_SQL_TEXT := REGEXP_REPLACE(LVC_SQL_TEXT, LVC_BIND, 'NULL',1,1,'i');
    END IF;
  END LOOP;


  DBMS_OUTPUT.PUT_LINE(LVC_NAME);
  DBMS_OUTPUT.PUT_LINE(LVC_SQL_TEXT);
END;
/

prompt ****************************************************************************************
prompt PLAN from v$ash_plan
prompt ****************************************************************************************

DECLARE
    v_sql_id VARCHAR2(13) := '&&sqlid';
    v_format VARCHAR2(30) := NVL(UPPER('TYPICAL'), 'TYPICAL');
    v_prev_plan_hash BIGINT := NULL;
    v_plan_count NUMBER := 0;


    CURSOR c_plans IS
        SELECT DISTINCT plan_hash_value
        FROM v$sql_plan
        WHERE sql_id = v_sql_id
        ORDER BY plan_hash_value;


    CURSOR c_plan_details(p_plan_hash BIGINT) IS
        SELECT
            id,
            parent_id,
            depth,
            position,
            operation,
            options,
            object_owner,
            object_name,
            object_type,
            optimizer,
            cost,
            cardinality,
            bytes,
            cpu_cost,
            io_cost,
            access_predicates,
            filter_predicates,
            partition_start,
            partition_stop,
            other_tag,
            other
        FROM v$sql_plan
        WHERE sql_id = v_sql_id
          AND plan_hash_value = p_plan_hash
        ORDER BY id;


    FUNCTION get_indent(p_depth INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN LPAD(' ', (p_depth * 2), ' ');
    END;


    FUNCTION format_operation(
        p_operation VARCHAR2,
        p_options VARCHAR2,
        p_object_owner VARCHAR2,
        p_object_name VARCHAR2,
        p_object_type VARCHAR2
    ) RETURN VARCHAR2 IS
        v_result VARCHAR2(4000);
    BEGIN
        v_result := p_operation;
        IF p_options IS NOT NULL THEN
            v_result := v_result || ' ' || p_options;
        END IF;
        IF p_object_name IS NOT NULL THEN
            v_result := v_result || ' (' || p_object_name || ')';
        END IF;
        RETURN v_result;
    END;


    FUNCTION format_stats(
        p_cost BIGINT,
        p_cardinality BIGINT,
        p_bytes BIGINT,
        p_cpu_cost BIGINT,
        p_io_cost BIGINT
    ) RETURN VARCHAR2 IS
        v_result VARCHAR2(400);
    BEGIN
        v_result := '';
        IF p_cost IS NOT NULL THEN
            v_result := v_result || 'Cost=' || p_cost;
        END IF;
        IF p_cardinality IS NOT NULL THEN
            IF v_result IS NOT NULL THEN
                v_result := v_result || ' ';
            END IF;
            v_result := v_result || 'Card=' || p_cardinality;
        END IF;
        IF p_bytes IS NOT NULL THEN
            IF v_result IS NOT NULL THEN
                v_result := v_result || ' ';
            END IF;
            v_result := v_result || 'Bytes=' || p_bytes;
        END IF;
        RETURN v_result;
    END;

BEGIN

    FOR rec_plan IN c_plans LOOP
        v_plan_count := v_plan_count + 1;

        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('============================================================================');
        DBMS_OUTPUT.PUT_LINE('Plan Hash Value: ' || rec_plan.plan_hash_value);
        DBMS_OUTPUT.PUT_LINE('============================================================================');
        DBMS_OUTPUT.PUT_LINE('');


        DBMS_OUTPUT.PUT_LINE('|' ||
                            LPAD('Id', 4) || '|' ||
                            RPAD('Operation', 39) || '|' ||
                            RPAD('Name', 29) || '|' ||
                            RPAD('Rows', 11) || '|' ||
                            RPAD('Cost', 9) || '|' ||
                            RPAD('Time', 9) || '|');

        DBMS_OUTPUT.PUT_LINE('|' ||
                            LPAD('-', 4, '-') || '|' ||
                            LPAD('-', 39, '-') || '|' ||
                            LPAD('-', 29, '-') || '|' ||
                            LPAD('-', 11, '-') || '|' ||
                            LPAD('-', 9, '-') || '|' ||
                            LPAD('-', 9, '-') || '|');


        FOR rec_detail IN c_plan_details(rec_plan.plan_hash_value) LOOP
            DECLARE
                v_indent VARCHAR2(100) := get_indent(rec_detail.depth);
                v_operation VARCHAR2(4000);
                v_object_info VARCHAR2(200);
                v_stats VARCHAR2(400);
                v_id_str VARCHAR2(10);
                v_operation_str VARCHAR2(40);
                v_name_str VARCHAR2(30);
                v_rows_str VARCHAR2(12);
                v_cost_str VARCHAR2(10);
                v_time_str VARCHAR2(10);
            BEGIN

                v_operation := v_indent || rec_detail.operation;
                IF rec_detail.options IS NOT NULL THEN
                    v_operation := v_operation || ' ' || rec_detail.options;
                END IF;


                IF rec_detail.object_name IS NOT NULL THEN
                    v_object_info := rec_detail.object_owner || '.' || rec_detail.object_name;
                    IF rec_detail.object_type IS NOT NULL THEN
                        v_object_info := v_object_info || ' [' || rec_detail.object_type || ']';
                    END IF;
                ELSE
                    v_object_info := '';
                END IF;


                v_id_str := LPAD(TO_CHAR(rec_detail.id), 4);
                v_operation_str := RPAD(SUBSTR(NVL(v_operation, ' '), 1, 39), 39);
                v_name_str := RPAD(SUBSTR(NVL(v_object_info, ' '), 1, 29), 29);
                v_rows_str := RPAD(NVL(TO_CHAR(rec_detail.cardinality), ' '), 11);
                v_cost_str := RPAD(NVL(TO_CHAR(rec_detail.cost), ' '), 9);
                v_time_str := RPAD(' ', 9);


                DBMS_OUTPUT.PUT_LINE(
                    '|' || v_id_str || '|' ||
                    v_operation_str || '|' ||
                    v_name_str || '|' ||
                    v_rows_str || '|' ||
                    v_cost_str || '|' ||
                    v_time_str || '|'
                );

                IF rec_detail.access_predicates IS NOT NULL THEN
                    DBMS_OUTPUT.PUT_LINE(
                        '|' || LPAD(' ', 4) || '|' ||
                        RPAD('  -> Access: ' || SUBSTR(rec_detail.access_predicates, 1, 26), 39) || '|' ||
                        RPAD(' ', 29) || '|' ||
                        RPAD(' ', 11) || '|' ||
                        RPAD(' ', 9) || '|' ||
                        RPAD(' ', 9) || '|'
                    );
                END IF;

                IF rec_detail.filter_predicates IS NOT NULL THEN
                    DBMS_OUTPUT.PUT_LINE(
                        '|' || LPAD(' ', 4) || '|' ||
                        RPAD('  -> Filter: ' || SUBSTR(rec_detail.filter_predicates, 1, 26), 39) || '|' ||
                        RPAD(' ', 29) || '|' ||
                        RPAD(' ', 11) || '|' ||
                        RPAD(' ', 9) || '|' ||
                        RPAD(' ', 9) || '|'
                    );
                END IF;
                IF rec_detail.partition_start IS NOT NULL OR rec_detail.partition_stop IS NOT NULL THEN
                    DBMS_OUTPUT.PUT_LINE(
                        '|' || LPAD(' ', 4) || '|' ||
                        RPAD('  -> Partition: ' ||
                             NVL(TO_CHAR(rec_detail.partition_start), '?') || '..' ||
                             NVL(TO_CHAR(rec_detail.partition_stop), '?'), 39) || '|' ||
                        RPAD(' ', 29) || '|' ||
                        RPAD(' ', 11) || '|' ||
                        RPAD(' ', 9) || '|' ||
                        RPAD(' ', 9) || '|'
                    );
                END IF;

            END;
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('============================================================================');

    END LOOP;
END;
/

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | infromation  from v$sqlstats               |
PROMPT +------------------------------------------------------------------------+
PROMPT

col  EXEC                   for   a10
col  CPU_PRE_EXEC           for   a12
col  ELA_PRE_EXEC           for   a12
col  DISK_PRE_EXEC          for   a13
col  GET_PRE_EXEC           for   a12
col  ROWS_PRE_EXEC          for   a13
col  APP_WAIT_PRE           for   a12
col  CLU_WAIT_PER           for   a12
col  USER_IO_WAIT_PER       for   a15
col  USER_IO_WAIT_PER       for   a15
col  ROWS_PRE_FETCHES       for   a15
col  CON_WAIT_PER           for   a12
col  PLSQL_WAIT_PER         for   a14
col  OUTLINE                for   a20
col  F_L_TIME               for   a15
col  APP_PRE_EXEC           for   a12
col  CON_PRE_EXEC           for   a12
col  USERNAME               for   a15
col  C                      for   a3
col  PLAN_HASH_VALUE        for   a15
col  IOWAIT_PRE_EXEC        for   a15
col  WRITE_PRE_EXEC         for   a14
col  i                      for   a1
col  SORTS_PRE_EXEC         for   a15
col  SEGMENT_NAME           for   a25

SELECT PLAN_HASH_VALUE||'' PLAN_HASH_VALUE,
        CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
        END AS EXEC,
       CASE
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
        END AS CPU_PRE_EXEC,
       CASE
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
        END AS ELA_PRE_EXEC,
       CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
        END AS DISK_PRE_EXEC,
       CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_PRE_EXEC,
       CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_PRE_EXEC,
       CASE
        WHEN fetches/ DECODE(executions, 0, 1, executions) < 1000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions),2))
        WHEN fetches / DECODE(executions, 0, 1, executions) < 10000 THEN TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches / DECODE(executions, 0, 1, executions) / 10000, 2)) || 'W'
        END AS ROWS_PRE_FETCHES,
      CASE
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS APP_WAIT_PRE,
        CASE
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CON_WAIT_PER,
         case
               WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CLU_WAIT_PER,
               CASE
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS USER_IO_WAIT_PER,
    CASE
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS PLSQL_WAIT_PER,
    OUTLINE_CATEGORY outline
  FROM v$sqlarea
where sql_id = '&&sqlid';

PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from v$sql                 |
PROMPT +------------------------------------------------------------------------+
PROMPT


SELECT
    CASE
        WHEN EXECUTIONS < 1000 THEN TO_CHAR(EXECUTIONS)
        WHEN EXECUTIONS < 10000 THEN TO_CHAR(ROUND(EXECUTIONS / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(EXECUTIONS / 10000, 2)) || 'W'
    END AS EXEC,
    PLAN_HASH_VALUE||'' PLAN_HASH_VALUE,
    child_number||'' AS c,
    PARSING_SCHEMA_NAME AS username,
      CASE
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CPU_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CPU_PRE_EXEC,
    CASE
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(ELAPSED_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS ELA_PRE_EXEC,
    CASE
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(DISK_READS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS DISK_PRE_EXEC,
    CASE
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS GET_PRE_EXEC,
    CASE
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS),2))
        WHEN ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 10000, 2)) || 'W'
    END AS ROWS_PRE_EXEC,
    CASE
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 1000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES),2))
        WHEN ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) < 10000
            THEN TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(ROWS_PROCESSED / DECODE(FETCHES, 0, 1, FETCHES) / 10000, 2)) || 'W'
    END AS ROWS_PRE_FETCHES,
  CASE
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(APPLICATION_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS APP_PRE_EXEC,
        CASE
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CONCURRENCY_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CON_PRE_EXEC,
        CASE
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(CLUSTER_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CLU_WAIT_PER,
        CASE
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(USER_IO_WAIT_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS USER_IO_WAIT_PER,
        CASE
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 < 1000
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000, 2) || 'ms'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60, 2) || 's'
        WHEN PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 < 60
            THEN ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(PLSQL_EXEC_TIME / DECODE(EXECUTIONS, 0, 1, EXECUTIONS) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS PLSQL_WAIT_PER,
    SUBSTR(FIRST_LOAD_TIME, 6, 10) || '.' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time
FROM v$sql s
WHERE sql_id = '&&sqlid'
ORDER BY plan_hash_value;


PROMPT
PROMPT +------------------------------------------------------------------------+
PROMPT | information from awr   sysdate-7                                       |
PROMPT +------------------------------------------------------------------------+
PROMPT

SELECT TO_CHAR (END_INTERVAL_TIME, 'dd hh24') end_time,
         TRIM (a.instance_number) i,
         a.parsing_schema_name as username,
         a.plan_hash_value||'' plan_hash_value,
      CASE
        WHEN executions_delta < 1000 THEN TO_CHAR(executions_delta)
        WHEN executions_delta < 10000 THEN TO_CHAR(ROUND(executions_delta / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(executions_delta / 10000, 2)) || 'W'
    END AS EXEC,
    CASE
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(cpu_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CPU_PRE_EXEC,
    CASE
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(elapsed_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS ELA_PRE_EXEC,
    CASE
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS DISK_PRE_EXEC,
        CASE
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(BUFFER_GETS_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS GET_PRE_EXEC,
    CASE
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(rows_processed_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_PRE_EXEC,
    CASE
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(fetches_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS ROWS_PRE_FETCHES,
    CASE
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(direct_writes_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS WRITE_PRE_EXEC,
    CASE
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(IOWAIT_DELTA / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS IOWAIT_PRE_EXEC,
    -- CASE
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
    --     WHEN parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
    --     ELSE TO_CHAR(ROUND(parse_calls_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    -- END AS PARSE_PRE_EXEC,
    CASE
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 1000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta),2))
        WHEN sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) < 10000 THEN TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2)) || 'K'
        ELSE TO_CHAR(ROUND(sorts_delta / DECODE(executions_delta, 0, 1, executions_delta) / 10000, 2)) || 'W'
    END AS SORTS_PRE_EXEC,
    CASE
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(apwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS APP_PRE_EXEC,
    CASE
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(ccwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CON_PRE_EXEC,
    CASE
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(clwait_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS CLU_WAIT_PER,
    CASE
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 < 1000 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000, 2) || 'ms'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60, 2) || 's'
        WHEN plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 < 60 THEN ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60, 2) || 'm'
        ELSE ROUND(plsexec_time_delta / DECODE(executions_delta, 0, 1, executions_delta) / 1000 / 60 / 60 / 60, 2) || 'h'
    END AS PLSQL_WAIT_PER
    FROM WRH$_SQLSTAT  a, WRM$_SNAPSHOT b
   WHERE     a.sql_id = '&&sqlid'
         AND a.snap_id = b.snap_id
         AND b.END_INTERVAL_TIME > SYSDATE - 5
         AND a.instance_number = b.instance_number
ORDER BY 1
/

prompt
prompt ****************************************************************************************
prompt OBJECT SIZE
prompt ****************************************************************************************

col owner              for   a15
col table_name         for   a25
col l_t                for   a5
col degree             for   a6
col part               for   a4
col LAST_ANALYZED      for   a25
col NUM_ROWS           for   a10
col blocks             for   a10
col EMPTY_BLOCKS       for   a5
col COLUMN_NAME        for   a15
col d_type             for   a20
col NUM_DISTINCT       for   a10
col N                  for   a1
col NUM_NULLS          for   a8
col sample_size        for   a10
col HISTOGRAM          for   a10


col segment_size for a15
WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid'  AND OBJECT_NAME IS NOT NULL)),
     tt
     AS (SELECT /*+materialize  no_merge */
                DISTINCT table_owner, table_name
           FROM (SELECT table_owner, table_name
                   FROM dba_indexes
                  WHERE (owner, index_name) IN
                            (SELECT object_owner, object_name
                               FROM t)
                 UNION
                 SELECT owner, table_name
                   FROM dba_tables
                  WHERE (owner, table_name) IN
                            (SELECT object_owner, object_name FROM t)))
SELECT owner,
                    (SELECT '***'
                       FROM tt
                      WHERE     b.owner = tt.table_owner
                            AND b.segment_name = tt.table_name)
                 || segment_name
                     segment_name,
                 segment_type,
                 trunc(bytes/1024/1024)||'M' segment_size
            FROM (SELECT owner,
                         segment_name,
                         segment_type,
                         sum(bytes) bytes
                   from dba_segments a
                    where (a.owner, a.segment_name) IN (SELECT object_owner, object_name FROM t union select table_owner,table_name from tt)
                    GROUP BY owner, segment_type, segment_name)  b
ORDER BY owner, segment_name
/



prompt
prompt ****************************************************************************************
prompt TABLES
prompt ****************************************************************************************


WITH t
     AS (SELECT /*+ materialize */
               DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
  SELECT a.owner,
         a.TABLE_NAME,
         -- TABLESPACE_NAME,
         a.LOGGING||'.'||a.TEMPORARY l_t,
         LTRIM (a.DEGREE) DEGREE,
         a.PARTITIONED as part,
         a.NUM_ROWS||'' NUM_ROWS,
         a.BLOCKS||'' BLOCKS,
         a.EMPTY_BLOCKS||'' EMPTY_BLOCKS,
         b.AVG_SPACE,
         b.AVG_ROW_LEN,
         trunc((b.blocks*tp.block_size)/1024/1024) block_size,
         trunc((b.AVG_ROW_LEN*b.NUM_ROWS)/1024/1024) avg_size,
         b.STALE_STATS,
         a.LAST_ANALYZED
    FROM DBA_TABLES a
        , dba_tab_statistics b
        ,dba_tablespaces tp
   WHERE     (a.OWNER, a.TABLE_NAME) IN
                (SELECT table_owner, table_name
                   FROM dba_indexes
                  WHERE (owner, index_name) IN (SELECT * FROM t)
                 UNION ALL
                 SELECT * FROM t)
           AND a.owner = b.owner(+)
         AND a.table_name = b.table_name(+)
         and a.tablespace_name=tp.tablespace_name
ORDER BY owner, table_name;




prompt
prompt ****************************************************************************************
prompt TABLE COLUMNS
prompt ****************************************************************************************

WITH t
     AS (SELECT /*+ materialize */
               DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
SELECT a.OWNER,
       a.TABLE_NAME,
       a.COLUMN_NAME,
       a.data_type || '(' || a.data_length || ')' d_type,
       b.NUM_DISTINCT||'' NUM_DISTINCT,
       a.NULLABLE||'' N,
       b.NUM_NULLS||'' NUM_NULLS,
       b.DENSITY,
       b.NUM_BUCKETS,
       b.AVG_COL_LEN,
       b.sample_size||'' sample_size,
       substr(b.HISTOGRAM,0,5) HISTOGRAM,
       b.LAST_ANALYZED
  FROM DBA_TAB_COLS a,DBA_TAB_COL_STATISTICS b
 WHERE (a.OWNER, a.TABLE_NAME) IN
       (SELECT table_owner,table_name FROM dba_indexes
         WHERE (owner,index_name) IN (SELECT * FROM t)
        UNION ALL SELECT * FROM t)
       and a.owner=b.owner(+) and a.table_name=b.table_name(+) and a.column_name=b.column_name(+)
 ORDER BY owner,table_name,COLUMN_ID;



prompt
prompt ****************************************************************************************
prompt INDEX STATUS
prompt ****************************************************************************************

col index_name                 for a20
col PARTITION_NAME             for a20
col SUBPARTITION_NAME          for a20
WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL)),
     tt
     AS (SELECT /*+ materialize */
               i.OWNER,
                i.INDEX_NAME,
                i.status,
                PARTITIONED
           FROM DBA_INDEXES i
          WHERE     (i.TABLE_OWNER, i.TABLE_NAME) IN (SELECT table_owner,
                                                             table_name
                                                        FROM dba_indexes
                                                       WHERE (owner,
                                                              index_name) IN (SELECT *
                                                                                FROM t)
                                                      UNION ALL
                                                      SELECT * FROM t)
                AND i.status NOT IN ('VALID'))
SELECT OWNER,
       INDEX_NAME,
       '' PARTITION_NAME,
       '' SUBPARTITION_NAME,
       status
  FROM tt
 WHERE tt.PARTITIONED = 'NO'
UNION ALL
SELECT p.INDEX_OWNER,
       p.INDEX_NAME,
       PARTITION_NAME,
       '' SUBPARTITION_NAME,
       p.status
  FROM dba_ind_partitions p
 WHERE     (p.INDEX_OWNER, p.INDEX_NAME) IN (SELECT index_owner, INDEX_NAME
                                               FROM tt
                                              WHERE tt.PARTITIONED = 'YES')
       AND p.status NOT IN ('USABLE')
UNION ALL
SELECT p.INDEX_OWNER,
       p.INDEX_NAME,
       PARTITION_NAME,
       SUBPARTITION_NAME,
       p.status
  FROM dba_ind_subpartitions p
 WHERE     (p.INDEX_OWNER, p.INDEX_NAME) IN (SELECT index_owner, INDEX_NAME
                                               FROM tt
                                              WHERE tt.PARTITIONED = 'YES')
       AND p.status NOT IN ('USABLE')
ORDER BY 1,2,3,4
/

prompt
prompt ****************************************************************************************
prompt INDEX INFO
prompt ****ucptdvs "UNIQUENESS COMPRESSION PARTITIONED TEMPORARY  VISIBILITY                "**
prompt ****************************************************************************************
WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
SELECT A.TABLE_OWNER,
       A.TABLE_NAME,
       A.INDEX_NAME,
          DECODE (A.UNIQUENESS,  'UNIQUE', 'U',  'NONUNIQUE', 'N',  'O')
       || DECODE (A.COMPRESSION,  'ENABLED', 'E',  'DISABLED', 'N',  'O')
       || DECODE (A.PARTITIONED,  'YES', 'Y',  'NO', 'N',  'O')
       || DECODE (A.TEMPORARY,  'Y', 'Y',  'N', 'N',  'O')
       || DECODE (A.VISIBILITY,  'VISIBLE', 'V',  'INVISIBLE', 'I',  'O')
                       ucptv,
        B.COLUMN_NAME,
        B.COLUMN_POSITION,
        B.DESCEND
        FROM DBA_INDEXES A, DBA_IND_COLUMNS B
              WHERE     (A.OWNER, A.table_name) IN (SELECT table_owner, table_name
                                                      FROM dba_indexes
                                                     WHERE (owner, index_name) IN (SELECT *
                                                                                     FROM t)
                                                    UNION ALL
                                                    SELECT * FROM t)
                    AND A.OWNER = B.INDEX_OWNER
                    AND A.INDEX_NAME = B.INDEX_NAME
           ORDER BY table_owner,
                    table_name,
                    index_name,
                    COLUMN_POSITION
/


prompt
prompt ****************************************************************************************
prompt PARTITION INDEX
prompt ****************************************************************************************

WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
SELECT a.owner,
       a.name index_name,
       b.partitioning_type part_type,
       b.subpartitioning_type subpart_type,
       b.partition_count part_count,
       b.PARTITIONING_KEY_COUNT key_count,
       b.SUBPARTITIONING_KEY_COUNT subkey_cout,
       b.LOCALITY,
       a.COLUMN_NAME,
       a.COLUMN_POSITION
  FROM DBA_PART_KEY_COLUMNS a, dba_part_indexes b
 WHERE     a.name = b.index_name
       AND (b.owner, b.index_name) IN (SELECT owner, index_name
                                         FROM dba_indexes
                                        WHERE (table_owner, table_name) IN (SELECT table_owner,
                                                                                   table_name
                                                                              FROM dba_indexes
                                                                             WHERE (owner,
                                                                                    index_name) IN (SELECT *
                                                                                                      FROM t)
                                                                            UNION ALL
                                                                            SELECT *
                                                                              FROM t))
       AND a.owner = b.owner
ORDER BY a.owner,a.name,a.column_position
/


prompt
prompt ****************************************************************************************
prompt PARTITION TABLE
prompt ****************************************************************************************


WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
SELECT a.owner,
       a.name table_name,
       b.partitioning_type part_type,
       b.subpartitioning_type subpart_type,
       b.partition_count part_count,
       b.PARTITIONING_KEY_COUNT key_count,
       b.SUBPARTITIONING_KEY_COUNT subkey_cout,
       a.COLUMN_NAME,
       a.COLUMN_POSITION
  FROM DBA_PART_KEY_COLUMNS a, dba_part_tables b
 WHERE a.name = b.table_name
   AND (a.owner, a.name) in (SELECT table_owner, table_name
                               FROM dba_indexes
                              WHERE (owner, index_name) IN (SELECT * FROM t)
                             UNION ALL
                             SELECT * FROM t)
   AND a.owner = b.owner
 ORDER BY a.NAME, a.COLUMN_POSITION
/



prompt
prompt ****************************************************************************************
prompt display every partition  info
prompt ****************************************************************************************

col tablespace_name         for a15
col HIGH_VALUE              for a25
col t_size                  for a10

WITH t
     AS (SELECT /*+ materialize */
                DISTINCT OBJECT_OWNER, OBJECT_NAME
           FROM (SELECT OBJECT_OWNER, OBJECT_NAME
                   FROM V$SQL_PLAN
                  WHERE SQL_ID = '&&sqlid' AND OBJECT_NAME IS NOT NULL))
SELECT table_name ,PARTITION_NAME,
       HIGH_VALUE,
       HIGH_VALUE_LENGTH,
       TABLESPACE_NAME,
       NUM_ROWS||'' NUM_ROWS,
       BLOCKS||'' BLOCKS,
       round(blocks * 8 / 1024, 2) || 'KB' t_size,
       EMPTY_BLOCKS||'' EMPTY_BLOCKS,
       to_char(LAST_ANALYZED, 'yyyy-mm-dd') LAST_ANALYZED,
       AVG_SPACE||'' AVG_SPACE,
       SUBPARTITION_COUNT||'' SUBPART_COUNT
  FROM sys.DBA_TAB_PARTITIONS
 WHERE (table_owner, table_name) in
       (SELECT table_owner, table_name
          FROM dba_indexes
         WHERE (owner, index_name) IN (SELECT * FROM t)
        UNION ALL
        SELECT * FROM t)
 ORDER BY table_name,PARTITION_POSITION
/




