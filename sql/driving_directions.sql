--driving directions from a route table

drop function if exists driving_directions(_tablename text, _geomfield text);
create function driving_directions(_tablename text, _geomfield text)
returns void as 

$$

declare 
    _sql text;
    _out_tablename text;

begin

--the output tablename is the same as the input, with "_driving" appended
_out_tablename := _tablename ||'_driving';

_sql := '
--generates contiguous roadway names with time and distance estimates
drop table if exists '|| _out_tablename ||';
create table '|| _out_tablename ||' as 
with
e as (select row_number() over() as seq, * from '|| _tablename ||')
--group records by street name
, mjx as (select row_number() OVER(ORDER BY seq ASC) - row_number() OVER(PARTITION BY roadname ORDER BY seq ASC) AS grp, * from e order by seq)
--sequential number of group for proper sorting -- important because some street names may be repeated out of sequence
, g as (select row_number() over() as grpid, * from (select distinct min(seq) over(partition by grp) as seq, grp from mjx order by seq) as foo)
--join back with network
, ng as (select g.grpid, mjx.* from mjx join g using(grp) order by seq)
--summarize by grpid
, f1 as (select roadname
    , round(sum(hours)::numeric * 60) as minutes
    , round(sum(length_mi::numeric),1) as miles
    , date_trunc(''minute'', min(time_start_of_segment) + interval ''30 second'') as time_start_leg
    , date_trunc(''minute'', max(time_end_of_segment) + interval ''30 second'') as time_end_leg
    , st_collect('|| _geomfield ||') as '|| _geomfield ||'
    from ng group by grpid, roadname order by grpid)
select * from f1 order by time_start_leg;

--summary table for entire route, total time and distance
drop table if exists '|| _out_tablename ||'_sum;
create table '|| _out_tablename ||'_sum as 
    select sum(minutes) as total_minutes
    , sum(miles) as total_miles from '|| _out_tablename ||';
';


execute _sql;

end;

$$ language 'plpgsql';

select * from driving_directions('routing.bestroute','the_geom_32614');

select * from routing.bestroute;
