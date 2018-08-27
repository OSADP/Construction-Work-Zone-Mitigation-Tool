-- a function to generate multiple routes with "via". each route is in routing.altbase_1 ... altbase_n

drop function if exists npmrds_dijkstra_ll_via(
      _out_tablename text
    , _route_tablename text
    , _srid int
    , _via_tablename text
    , _edge_tablename text
    , _edge_geomfield text
    , _edge_costfield text
    , _edge_reversecostfield text
    , _edge_speedfield text);
--_odtablename: {npmrds.odregional, npmrds.odnational)
--_mytol is the tolerance for looking for vertices around an OD pair's points.
--_n_verts is the number of vertices close to the O and D form many-to-many

create function npmrds_dijkstra_ll_via(
      _out_tablename text
    , _route_tablename text default 'routing.baseroute'
    , _srid int default 32614        --EPSG code for projected data, e.g., 32614 = UTM 12 N
    , _via_tablename text default 'routing.via_vertex' --tablename containing "via" vertices
    , _edge_tablename text default 'npmrds.roads_topo' -- the name of the table containing network data, assume has columns id, source, target.      e.g., npmrds.roads_noded
    , _edge_geomfield text default 'the_geom_32614' -- column name containing network geometry.       e.g., the_geom_32614
    , _edge_costfield text default 'cost_truck' -- column representing costs
    , _edge_reversecostfield text default 'reverse_cost_truck' -- column representing reverse costs
    , _edge_speedfield text default 'speed_truck' -- column containing speed
)
    
returns void as
$$
#variable_conflict use_column

--declare variables that are instantiated at run time
DECLARE
    _mysql text;            --the SQL string
    _via_sql text;          --the SQL for getting origin and destination 
    _via_vid int;           --the vertex ID used in the loop
    _vrec record;           --record with via vertex id
    _route record;          --record
    _routenum int;          --route number for multiple runs
    _start_vertex int;        --origin vertex id
    _end_vertex text;         --destination vertex id
    _od_sql text;           --sql to get input parameters
    _odrec record;          --results of that sql
    _origin_lat float;
    _origin_lon float;
    _dest_lat float;
    _dest_lon float;
--    _time_start timestamptz;
    --for dropping alternates before we start
    _dropsql text;
    _dropsql2 text;
    _droprec record;
    --for getting the best alternates
    bestalt_sql text; 

--begin the logic
BEGIN

--#######################################
--input table parameters
_od_sql := 'select start_vertex, end_vertex, origin_lat, origin_lon, dest_lat, dest_lon from '|| _route_tablename ||' group by start_vertex, end_vertex, origin_lat, origin_lon, dest_lat, dest_lon';

execute _od_sql into _odrec;

_start_vertex := _odrec.start_vertex;
_end_vertex := _odrec.end_vertex;
_origin_lat := _odrec.origin_lat;
_origin_lon := _odrec.origin_lon;
_dest_lat := _odrec.dest_lat;
_dest_lon := _odrec.dest_lon;
--_time_start := _odrec.time_start;

--raise notice '%', _odrec;

--####################################### 
--"via" ids
_via_sql := '
select id as via_vid from '|| _via_tablename ||' order by id;
';
--raise notice 'vsql: %', _vsql;

--#######################################
--loop over all via points
for _vrec in execute _via_sql loop

--raise notice 'vrec: %, %', _routenum, _vrec;

--"via" vertext ID for this record
_via_vid:= _vrec.via_vid;

_mysql := '
drop table if exists routing.'|| _out_tablename || _via_vid ||';
create table routing.'|| _out_tablename || _via_vid ||' as
with
--edges
e as (select *, id as edge, '|| _edge_geomfield ||' as geom_e, '|| _edge_costfield ||', '|| _edge_reversecostfield ||' from '|| _edge_tablename ||')
--route using pgr_disjkstravia
, nd as (select pgr_dijkstravia(''SELECT id, source, target, '|| _edge_costfield ||' as cost, '|| _edge_reversecostfield ||' as reversecost FROM '|| _edge_tablename ||' where '|| _edge_costfield ||' is not null'', array['|| _start_vertex ||', '|| _via_vid ||', '|| _end_vertex ||'], true) as c)
, n0 as (select (c).* from nd)
, n as (select start_vid ||''_''|| end_vid as sevid, * from n0)
--join to edges
, nj as (select n.*, e.'|| _edge_geomfield ||', e.'|| _edge_speedfield ||', roadname::text, tmc::text, (st_length('|| _edge_geomfield ||') / 1609.34)::float as length_mi from n left join e using(edge) where '|| _edge_geomfield ||' is not null order by path_id, path_seq)
--note route_agg_cost is the running total across any sub-routes
--, tx as (select *, time_start + interval ''1 hour'' * route_agg_cost as time_start_of_segment, time_start + interval ''1 hour'' * (cost + route_agg_cost) as time_end_of_segment from nj, tm)
, f as (select path_id
    , '|| _vrec.via_vid ||' as routenum
    , row_number() over() as rgid
    , '|| _origin_lat ||' as origin_lat
    , '|| _origin_lon ||' origin_lon
    , '|| _dest_lat ||' as dest_lat
    , '|| _dest_lon ||' as dest_lon
    , roadname
    , tmc
    , '|| _edge_speedfield ||'
    , cost as hours
    --, time_start_of_segment
    --, time_end_of_segment
    , length_mi
    , '|| _edge_geomfield ||'::geometry(LineString, '|| _srid ||')
    , array['|| _start_vertex ||', '|| _via_vid ||', '|| _end_vertex ||'] as start_via_end_id
    from nj)
select * from f
;'
;

--execute _mysql into _route;
--raise notice '%', _mysql;

execute _mysql;

--######## end the loop
end loop;


--########
--loop over all via points to create an aggregate of all alternate routes, to support finding the best 2
_routenum := 0;
for _vrec in execute _via_sql loop
    _routenum := _routenum + 1;
    --raise notice '%', _routenum;
    if _routenum = 1 then
        execute 'drop table if exists routing.'|| _out_tablename ||'all; create table routing.'|| _out_tablename ||'all as select * from routing.'|| _out_tablename || _vrec.via_vid ||'';
    else
        execute 'insert into routing.'|| _out_tablename ||'all select * from routing.'|| _out_tablename || _vrec.via_vid ||'';
    end if;
end loop;

--########
--now find the best 2 of the alternate routes, 
bestalt_sql := '
drop table if exists routing.'|| _out_tablename ||'best;
create table routing.'|| _out_tablename ||'best as
with
routeagg0 as (select routenum, count(distinct path_id), sum(hours) as hours_tot from routing.'|| _out_tablename ||'all group by routenum)
, routeagg1 as (select routenum, hours_tot from routeagg0 where count > 1 order by hours_tot asc limit 2)
select * from routing.'|| _out_tablename ||'all where routenum in (select routenum from routeagg1) order by routenum, rgid;

drop table if exists routing.'|| _out_tablename ||'best1;
create table routing.'|| _out_tablename ||'best1 as 
with 
--first routenum
rn as (select distinct routenum from routing.'|| _out_tablename ||'best group by routenum order by routenum asc limit 1)
select * from routing.'|| _out_tablename ||'best where routenum in (select routenum from rn);

drop table if exists routing.'|| _out_tablename ||'best2;
create table routing.'|| _out_tablename ||'best2 as 
with 
--second routenum
rn as (select distinct routenum from routing.'|| _out_tablename ||'best group by routenum order by routenum desc limit 1)
select * from routing.'|| _out_tablename ||'best where routenum in (select routenum from rn);

--drop the copy with both 2 best alterntives
drop table if exists routing.'|| _out_tablename ||'best;
';

execute bestalt_sql;

--######## terminate
return;

end;

$$ language 'plpgsql';


-- run example
select * from npmrds_dijkstra_ll_via(_out_tablename := 'altbase_', _route_tablename := 'routing.baseroute');
