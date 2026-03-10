
COL o_t_i              FORMAT A30 HEADING 'Index_Name'
COL Tablespacename     FORMAT A20 HEADING 'Tablespace_Name'
COL status             FORMAT A10 HEADING 'Status'
COL index_type         FORMAT A20 HEADING 'Index_Type'
COL uniqueness         FORMAT A12 HEADING 'Uniqueness'
COL logging            FORMAT A8  HEADING 'Logging'
COL partitioned        FORMAT A12 HEADING 'Partitioned'
COL Columnname         FORMAT A30 HEADING 'Column|Name'


SELECT b.index_name o_t_i,
       a.Tablespace_Name Tablespacename,
       a.status,
       a.index_type,
       a.uniqueness,
       a.pct_free,
       a.logging logging,
       a.blevel blevel,
       a.distinct_keys d_keys,
       a.leaf_blocks,
       a.num_rows,
       a.partitioned,
       b.Column_Position Columnpost,
       b.Column_Name     Columnname
  FROM dba_indexes a, dba_ind_Columns b
 WHERE a.owner = nvl(upper('&owner'),a.owner)
   and a.Table_Name = nvl(upper('&name'), a.table_name) 
   and a.index_name=nvl(upper('&indexname'),a.index_name)
   AND b.Index_Name = a.Index_Name
   and a.owner=b.index_owner
   and a.table_owner=b.index_owner
 ORDER BY o_t_i,Columnpost;
