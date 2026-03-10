-- File Name:kill_sess_by_where.sql
-- Purpose: kill sessions according to filter conditions on session table columns provided as input
-- Created: 20251208  by  huangtingzhong

set serveroutput on
DECLARE
    v_sql   VARCHAR2 (1000);
    debug   VARCHAR2 (3) := &debug;
    v_sid   varchar2(1000);
    session_mode   VARCHAR2 (20)   := 'KILL';

    PROCEDURE Execsql (input Varchar2,execsql VARCHAR2, output VARCHAR2)
    IS
    BEGIN
        IF output = '1'
        THEN
            DBMS_OUTPUT.put_line ('Detailed information:' || input);
            DBMS_OUTPUT.put_line ('ExecSQL is:' || execsql);
        ELSE
            DBMS_OUTPUT.put_line (
                TO_CHAR (SYSDATE, 'yyyy-mm-dd hh24:mi:ss') || ':' || execsql);

            EXECUTE IMMEDIATE execsql;
        END IF;
        EXCEPTION
            WHEN OTHERS THEN
              DBMS_OUTPUT.put_line('Find Error on :'||SQLERRM||':'||execsql);
    END Execsql;
BEGIN
        FOR cur_session    IN
            (SELECT * FROM v$session s
                WHERE s.username NOT IN ('SYSTEM','SYS','SYSMAN','DBSNMP')
                and S.USERNAME IS NOT NULL
                and &where
              )
    LOOP
      BEGIN


        if (upper(session_mode) = 'KILL') then
          v_sql := 'alter system kill session '|| CHR (39)||cur_session.sid||','||cur_session.serial# || CHR (39);
        end if;


        Execsql (cur_session.program||':'||cur_session.username||':'||':'||cur_session.sid||':'||cur_session.exec_status,v_sql, debug);
        EXCEPTION
            WHEN OTHERS THEN
              DBMS_OUTPUT.put_line('Find Error on :'||SQLERRM||':'||cur_session.sid);
        END;
    END LOOP;
END;
/
