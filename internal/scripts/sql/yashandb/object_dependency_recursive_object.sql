-- File Name: object_dependency_recursive_object.sql
-- Purpose: Recursive forward dependency tree via nested PL/SQL procedure
-- Created: 20260801 by huangtingzhong
--
-- Params: &&owner, &&object_name, &&object_type (required)
-- Note: nested PROCEDURE (no CREATE PROCEDURE); Oracle uses schema recur_object

SET SERVEROUTPUT ON


ACCEPT owner PROMPT 'Enter owner (e.g. SYS): '
ACCEPT object_name PROMPT 'Enter object name (e.g. DBA_ALL_TABLES): '
ACCEPT object_type PROMPT 'Enter object type (e.g. VIEW): '

DECLARE
  v_owner       VARCHAR2(128) := UPPER(TRIM('&&owner'));
  v_object_name VARCHAR2(128) := UPPER(TRIM('&&object_name'));
  v_object_type VARCHAR2(128) := UPPER(TRIM('&&object_type'));
  TYPE t_seen IS TABLE OF BOOLEAN INDEX BY VARCHAR2(400);
  v_seen t_seen;

  PROCEDURE recur_object(
    p_owner  VARCHAR2,
    p_name   VARCHAR2,
    p_type   VARCHAR2,
    p_level  NUMBER
  ) IS
    v_object_id NUMBER;
    v_last_ddl  VARCHAR2(30);
    v_ts        VARCHAR2(75);
    v_status    VARCHAR2(30);
    v_key       VARCHAR2(400);
  BEGIN
    v_key := p_owner || '.' || p_name || '.' || p_type;
    IF v_seen.EXISTS(v_key) THEN
      RETURN;
    END IF;
    v_seen(v_key) := TRUE;

    BEGIN
      SELECT object_id,
             TO_CHAR(last_ddl_time, 'yyyy-mm-dd hh24:mi:ss'),
             timestamp,
             status
        INTO v_object_id, v_last_ddl, v_ts, v_status
        FROM dba_objects
       WHERE owner = p_owner
         AND object_name = p_name
         AND object_type = p_type;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE(
          'No record found for: ' || p_owner || ' ' || p_name || ' ' || p_type
        );
        RETURN;
    END;

    DBMS_OUTPUT.PUT_LINE(
      'Level: ' || p_level
      || ' ' || v_object_id
      || ' ' || p_owner
      || ' ' || p_name
      || ' ' || p_type
      || ' ' || v_last_ddl
      || ' ' || v_ts
      || ' ' || v_status
    );

    FOR c_rec IN (
      SELECT referenced_owner, referenced_name, referenced_type
        FROM dba_dependencies
       WHERE owner = p_owner
         AND name = p_name
         AND type = p_type
    ) LOOP
      recur_object(
        c_rec.referenced_owner,
        c_rec.referenced_name,
        c_rec.referenced_type,
        p_level + 1
      );
    END LOOP;
  END recur_object;
BEGIN
  IF v_owner IS NULL OR v_object_name IS NULL OR v_object_type IS NULL THEN
    RAISE_APPLICATION_ERROR(30601, 'owner, object_name and object_type are required');
  END IF;
  recur_object(v_owner, v_object_name, v_object_type, 0);
END;
/
